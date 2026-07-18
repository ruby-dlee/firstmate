from __future__ import annotations

import json
import os
import re
import subprocess
import unicodedata
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import UTC, datetime
from hashlib import sha256
from pathlib import Path
from typing import Any

from .config import verified_quota_runtime
from .locks import DirectoryLock
from .models import Profile, Registry
from .paths import current_user_home, current_user_name, ensure_private_dir
from .providers import credential_file_state, identity_fingerprint, provider_environment
from .provision import (
    profile_is_provisioned,
    verified_configured_provider_binary,
    verified_provider_binary,
)
from .util import (
    atomic_write_bytes,
    atomic_write_json,
    read_private_bytes,
    read_private_json,
    unlink_private_file,
    utc_now,
)

PRIMARY_WINDOWS = {"five_hour", "seven_day", "weekly", "week"}
AUTH_FAILURE_RE = re.compile(r"sign[- ]?in|required|reauth|token.*(?:revoked|invalid)", re.I)
RATE_LIMIT_RE = re.compile(r"rate.?limit", re.I)
HARD_BLOCKED_STATUSES = {"auth_required", "rate_limited", "error"}
KNOWN_STATUSES = HARD_BLOCKED_STATUSES | {"fresh", "stale", "unavailable"}
SAFE_TOKEN_RE = re.compile(r"[A-Za-z0-9_.:-]{1,128}")


def _quota_runtime_environment(
    profile: Profile, *, default_provider_home: bool = False
) -> dict[str, str]:
    """Return the provider environment without ambient Node/npm injection hooks."""
    env = provider_environment(profile, default_provider_home=default_provider_home)
    for name in tuple(env):
        normalized = name.lower()
        if (
            name.startswith(("NODE_", "DYLD_", "LD_", "PYTHON"))
            or normalized.startswith("npm_config_")
            or name
            in {
                "BASH_ENV",
                "ENV",
                "SHELLOPTS",
                "BASHOPTS",
                "PERL5OPT",
                "PERLLIB",
                "RUBYOPT",
                "RUBYLIB",
                "ELECTRON_RUN_AS_NODE",
                "INIT_CWD",
            }
        ):
            env.pop(name, None)
    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    return env


@dataclass(frozen=True)
class QuotaCacheSnapshot:
    existed: bool
    payload: bytes = b""
    mode: int = 0o600


def quota_path(registry: Registry, profile_id: str) -> Path:
    return registry.settings.state_dir / "quota" / f"{profile_id}.json"


def snapshot_quota_cache(registry: Registry, profile_id: str) -> QuotaCacheSnapshot:
    path = quota_path(registry, profile_id)
    try:
        payload = read_private_bytes(path, label="quota cache")
    except FileNotFoundError:
        return QuotaCacheSnapshot(False)
    return QuotaCacheSnapshot(
        True,
        payload,
        0o600,
    )


def restore_quota_cache(
    registry: Registry,
    profile_id: str,
    snapshot: QuotaCacheSnapshot,
) -> None:
    path = quota_path(registry, profile_id)
    if snapshot.existed:
        atomic_write_bytes(path, snapshot.payload, mode=snapshot.mode)
        return
    unlink_private_file(path, label="quota cache")


def discard_quota_cache(registry: Registry, profile_id: str) -> None:
    restore_quota_cache(registry, profile_id, QuotaCacheSnapshot(False))


def has_remote_identity_proof(quota: dict[str, Any]) -> bool:
    fingerprint = quota.get("identity_fingerprint")
    return (
        quota.get("status") == "fresh"
        and quota.get("verified_at") is not None
        and quota.get("headroom_percent") is not None
        and isinstance(quota.get("windows"), list)
        and bool(quota["windows"])
        and isinstance(fingerprint, str)
        and len(fingerprint) == 64
    )


def _number(value: Any) -> float | None:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return max(0.0, min(100.0, float(value)))
    return None


def _parse_time(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo is not None else parsed.replace(tzinfo=UTC)


def _age_seconds(value: Any) -> int | None:
    parsed = _parse_time(value)
    if parsed is None:
        return None
    return max(0, int((datetime.now(UTC) - parsed.astimezone(UTC)).total_seconds()))


def _effective_status(status: str, error: str | None) -> tuple[str, str | None]:
    if status != "stale" or not error:
        return status, None
    if AUTH_FAILURE_RE.search(error):
        return "auth_required", "cached_after_auth_failure"
    if RATE_LIMIT_RE.search(error):
        return "rate_limited", "cached_after_rate_limit"
    return status, None


def _safe_token(value: Any, fallback: str) -> str:
    if isinstance(value, str) and SAFE_TOKEN_RE.fullmatch(value):
        return value
    return fallback


def _safe_reason(value: Any) -> str | None:
    if value is None:
        return None
    return _safe_token(value, "provider_reported_error")


def _normalized_windows(value: Any) -> list[dict[str, Any]]:
    windows: list[dict[str, Any]] = []
    if not isinstance(value, list):
        return windows
    for item in value:
        if not isinstance(item, dict):
            continue
        remaining = _number(item.get("remaining_percent"))
        if remaining is None:
            continue
        resets_at = item.get("resets_at")
        windows.append(
            {
                "id": _safe_token(item.get("id"), "unknown"),
                "kind": _safe_token(item.get("kind"), "unknown"),
                "remaining_percent": remaining,
                "resets_at": resets_at if _parse_time(resets_at) is not None else None,
            }
        )
    return windows


def _identity_fingerprint(profile: Profile, provider: dict[str, Any]) -> str | None:
    account = provider.get("account")
    if not isinstance(account, dict):
        return None
    email = account.get("email")
    identifier = (
        email.strip().casefold()
        if profile.provider == "codex" and isinstance(email, str) and email.strip()
        else account.get("accountId") or account.get("account_id")
    )
    if not isinstance(identifier, str) or not identifier:
        return None
    return identity_fingerprint(profile.provider, identifier)


def _claude_credential_state(provider: dict[str, Any]) -> str:
    attempts = provider.get("attempts")
    if not isinstance(attempts, list) or not attempts:
        return "indeterminate"
    relevant: dict[str, list[dict[str, Any]]] = {"oauth-file": [], "keychain": []}
    for attempt in attempts:
        if not isinstance(attempt, dict):
            return "indeterminate"
        source = attempt.get("source")
        status = attempt.get("status")
        error = attempt.get("error")
        if attempt.get("credentialPresent") is True:
            return "present"
        if source == "oauth" and status in {"success", "failed"}:
            return "present"
        if source in relevant:
            relevant[source].append(attempt)
        elif source not in {"cache"}:
            return "indeterminate"
        if not isinstance(source, str) or not isinstance(status, str):
            return "indeterminate"
        if error is not None and not isinstance(error, str):
            return "indeterminate"
    if all(
        entries
        and all(
            entry.get("status") == "skipped"
            and entry.get("error") == "credentials_missing"
            and entry.get("credentialPresent") is not True
            for entry in entries
        )
        for entries in relevant.values()
    ):
        return "absent"
    return "indeterminate"


def _claude_keychain_account(provider: dict[str, Any]) -> str | None:
    attempts = provider.get("attempts")
    if not isinstance(attempts, list):
        return None
    accounts = [
        attempt.get("account")
        for attempt in attempts
        if isinstance(attempt, dict) and attempt.get("source") == "keychain"
    ]
    expected = current_user_name()
    return expected if accounts == [expected] else None


def _normalize(profile: Profile, raw: dict[str, Any]) -> dict[str, Any]:
    if raw.get("profile") == profile.id and raw.get("schema") == 1:
        status = _safe_token(raw.get("status"), "unavailable")
        if status not in KNOWN_STATUSES:
            status = "unavailable"
        fingerprint = raw.get("identity_fingerprint")
        if not isinstance(fingerprint, str) or len(fingerprint) != 64:
            fingerprint = None
        windows = _normalized_windows(raw.get("windows"))
        verified_at = raw.get("verified_at")
        if _parse_time(verified_at) is None:
            verified_at = None
        now = utc_now()
        if status == "fresh" and verified_at is None:
            status = "error"
        credential_state = _safe_token(raw.get("credential_state"), "indeterminate")
        if credential_state not in {"present", "absent", "indeterminate"}:
            credential_state = "indeterminate"
        normalized = {
            "schema": 1,
            "profile": profile.id,
            "provider": profile.provider,
            "status": status,
            "reported_status": status,
            "reason": (
                "missing_remote_verification_timestamp"
                if status == "error" and raw.get("status") == "fresh"
                else _safe_reason(raw.get("reason"))
            ),
            "headroom_percent": _number(raw.get("headroom_percent")),
            "windows": windows,
            "verified_at": verified_at,
            "identity_fingerprint": fingerprint,
            "identity_source": "quota-account" if fingerprint else None,
            "credential_state": "present" if fingerprint else credential_state,
            "refreshed_at": now,
        }
        if profile.provider == "claude":
            account = raw.get("credential_keychain_account")
            normalized["credential_keychain_account"] = (
                current_user_name() if account == current_user_name() else None
            )
        return normalized

    providers = raw.get("providers", [])
    if not isinstance(providers, list):
        raise ValueError("quota-axi response has no providers array")
    provider = next(
        (
            item
            for item in providers
            if isinstance(item, dict) and item.get("provider") == profile.provider
        ),
        None,
    )
    if provider is None:
        raise ValueError(f"quota-axi response has no {profile.provider} result")
    state = provider.get("state", {})
    reported_status = _safe_token(
        state.get("status") if isinstance(state, dict) else None,
        "unavailable",
    )
    if reported_status not in KNOWN_STATUSES:
        reported_status = "unavailable"
    error = state.get("error") if isinstance(state, dict) else None
    error = error if isinstance(error, str) else None
    status, derived_reason = _effective_status(reported_status, error)
    windows_raw = provider.get("windows", [])
    windows: list[dict[str, Any]] = []
    if isinstance(windows_raw, list):
        for item in windows_raw:
            if not isinstance(item, dict):
                continue
            remaining = _number(item.get("percentRemaining"))
            if remaining is None:
                used = _number(item.get("percentUsed"))
                remaining = None if used is None else 100.0 - used
            if remaining is None:
                continue
            windows.append(
                {
                    "id": _safe_token(item.get("id"), "unknown"),
                    "kind": _safe_token(item.get("kind"), "unknown"),
                    "remaining_percent": remaining,
                    "resets_at": (
                        item.get("resetsAt")
                        if _parse_time(item.get("resetsAt")) is not None
                        else None
                    ),
                }
            )
    primary = [item for item in windows if item["id"] in PRIMARY_WINDOWS]
    if not primary:
        primary = [item for item in windows if item["kind"] in {"session", "weekly"}]
    headroom = min((item["remaining_percent"] for item in primary), default=None)
    reason = state.get("reason") if isinstance(state, dict) else None
    verified_at = state.get("refreshedAt") if isinstance(state, dict) else None
    if _parse_time(verified_at) is None:
        verified_at = None
        if status == "fresh":
            status = "error"
            derived_reason = "missing_remote_verification_timestamp"
    identity_fingerprint = _identity_fingerprint(profile, provider)
    credential_state = (
        _claude_credential_state(provider) if profile.provider == "claude" else "indeterminate"
    )
    if identity_fingerprint is not None:
        credential_state = "present"
    normalized = {
        "schema": 1,
        "profile": profile.id,
        "provider": profile.provider,
        "status": status,
        "reported_status": reported_status,
        "reason": derived_reason or _safe_reason(reason),
        "headroom_percent": headroom,
        "windows": windows,
        "verified_at": verified_at,
        "identity_fingerprint": identity_fingerprint,
        "identity_source": "quota-account" if identity_fingerprint else None,
        "credential_state": credential_state,
        "refreshed_at": utc_now(),
    }
    if profile.provider == "claude":
        normalized["credential_keychain_account"] = _claude_keychain_account(provider)
    return normalized


def _load_raw_quota(
    registry: Registry,
    profile: Profile,
    *,
    timeout: int = 30,
    allow_keychain_prompt: bool = False,
    default_provider_home: bool = False,
) -> dict[str, Any]:
    _node_binary, quota_binary = verified_quota_runtime(registry.settings)
    base_anchor = (
        profile.id == f"{profile.provider}-base-anchor"
        and profile.safety_policy == "desktop_shared"
    )
    if not base_anchor:
        credential_state, credential_reason = credential_file_state(profile)
        if credential_state == "indeterminate" or (
            profile.provider == "codex" and credential_state != "present"
        ):
            raise ValueError(
                f"unsafe or unavailable {profile.provider} credential storage for {profile.id}: "
                f"{credential_reason or credential_state}"
            )
    isolation_root = (
        profile.home
        if profile.provider == "codex"
        else profile.home.parent
    )
    cache = (
        isolation_root / ".cache"
        if base_anchor
        else profile.home / ".agent-fleet-quota-cache"
    )
    ensure_private_dir(cache)
    env = _quota_runtime_environment(profile, default_provider_home=default_provider_home)
    env.pop("AGENT_FLEET_QUOTA_FIXTURE_DIR", None)
    env.pop("AGENT_FLEET_TEST_QUOTA_FIXTURE_DIR", None)
    env["XDG_CACHE_HOME"] = str(cache)
    if base_anchor:
        env["HOME"] = str(isolation_root)
        for variable, name in (
            ("XDG_CONFIG_HOME", ".config"),
            ("XDG_DATA_HOME", ".local/share"),
            ("XDG_STATE_HOME", ".local/state"),
        ):
            location = isolation_root / name
            ensure_private_dir(location)
            env[variable] = str(location)
    provisioned = profile_is_provisioned(profile)
    if not provisioned and not base_anchor:
        raise ValueError(f"quota probe requires a provisioned profile: {profile.id}")
    if profile.provider == "codex":
        provider_binary = (
            verified_provider_binary(registry, profile)
            if provisioned
            else verified_configured_provider_binary(registry, profile.provider)
        )
        env["QUOTA_AXI_CODEX_BINARY"] = str(provider_binary)
    try:
        argv = [
            str(quota_binary),
            "--provider",
            profile.provider,
            "--json",
            "--full",
        ]
        if allow_keychain_prompt and profile.provider == "claude":
            argv.append("--allow-keychain-prompt")
        result = subprocess.run(
            argv,
            env=env,
            cwd=(profile.home if profile.home.exists() or not base_anchor else current_user_home()),
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise ValueError(f"quota refresh timed out for {profile.id}") from exc
    try:
        raw = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        if result.returncode != 0:
            detail = result.stderr.strip().splitlines()[-1:] or ["unknown error"]
            raise ValueError(f"quota refresh failed for {profile.id}: {detail[0]}") from exc
        raise ValueError(f"quota-axi emitted invalid JSON for {profile.id}") from exc
    if result.returncode != 0:
        providers = raw.get("providers") if isinstance(raw, dict) else None
        fresh = isinstance(providers, list) and any(
            isinstance(item, dict)
            and item.get("provider") == profile.provider
            and isinstance(item.get("state"), dict)
            and item["state"].get("status") == "fresh"
            for item in providers
        )
        if fresh:
            raise ValueError(f"quota-axi exited nonzero with untrusted fresh data for {profile.id}")
    if not isinstance(raw, dict):
        raise ValueError(f"quota response for {profile.id} must be an object")
    return raw


def probe_quota(
    registry: Registry,
    profile: Profile,
    *,
    timeout: int = 30,
    allow_keychain_prompt: bool = False,
    default_provider_home: bool = False,
) -> dict[str, Any]:
    raw = _load_raw_quota(
        registry,
        profile,
        timeout=timeout,
        allow_keychain_prompt=allow_keychain_prompt,
        default_provider_home=default_provider_home,
    )
    return _normalize(profile, raw)


def _claude_scoped_keychain_service(profile: Profile) -> str:
    stable_home = unicodedata.normalize("NFC", str(profile.home))
    suffix = sha256(stable_home.encode()).hexdigest()[:8]
    return f"Claude Code-credentials-{suffix}"


def inspect_credential_source_contract(
    registry: Registry,
    profile: Profile,
    *,
    timeout: int = 30,
    allow_keychain_prompt: bool = False,
    allow_absent: bool = False,
) -> dict[str, Any]:
    """Prove the non-secret credential source set used by one managed worker.

    This invokes only the sealed Quota AXI auth inspector. It never falls back
    to the Desktop/default home and never accepts Claude's unsuffixed Keychain
    service for a routed profile.
    """

    if profile.safety_policy != "worker":
        raise ValueError("external reserve profiles must not be remotely inspected")
    _node_binary, quota_binary = verified_quota_runtime(registry.settings)
    if not profile_is_provisioned(profile):
        raise ValueError(f"credential inspection requires a provisioned profile: {profile.id}")
    cache = profile.home / ".agent-fleet-quota-cache"
    ensure_private_dir(cache)
    env = _quota_runtime_environment(profile)
    env.pop("AGENT_FLEET_QUOTA_FIXTURE_DIR", None)
    env.pop("AGENT_FLEET_TEST_QUOTA_FIXTURE_DIR", None)
    env["XDG_CACHE_HOME"] = str(cache)
    if profile.provider == "codex":
        env["QUOTA_AXI_CODEX_BINARY"] = str(verified_provider_binary(registry, profile))
    argv = [str(quota_binary), "auth", "--provider", profile.provider, "--json"]
    if allow_keychain_prompt and profile.provider == "claude":
        argv.append("--allow-keychain-prompt")
    try:
        result = subprocess.run(
            argv,
            env=env,
            cwd=profile.home,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise ValueError(f"credential source inspection timed out for {profile.id}") from exc
    try:
        raw = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise ValueError(f"Quota AXI emitted invalid auth JSON for {profile.id}") from exc
    if result.returncode != 0 or not isinstance(raw, dict):
        raise ValueError(f"credential source inspection failed for {profile.id}")
    reports = raw.get("auth")
    if not isinstance(reports, list) or len(reports) != 1:
        raise ValueError(f"credential source inspection was incomplete for {profile.id}")
    report = reports[0]
    if not isinstance(report, dict) or report.get("provider") != profile.provider:
        raise ValueError(f"credential source inspection provider mismatch for {profile.id}")
    raw_sources = report.get("sources")
    if not isinstance(raw_sources, list):
        raise ValueError(f"credential source inspection has no sources for {profile.id}")
    sources: dict[str, dict[str, Any]] = {}
    for item in raw_sources:
        if not isinstance(item, dict):
            raise ValueError(f"credential source inspection is malformed for {profile.id}")
        source = item.get("source")
        status = item.get("status")
        if (
            not isinstance(source, str)
            or source in sources
            or status not in {"available", "missing", "invalid", "expired", "skipped"}
        ):
            raise ValueError(f"credential source inspection is ambiguous for {profile.id}")
        sources[source] = item
    if profile.provider == "claude":
        if set(sources) != {"oauth-file", "keychain"}:
            raise ValueError(f"Claude credential source set is incomplete for {profile.id}")
        expected_file = str(profile.home / ".credentials.json")
        file_source = sources["oauth-file"]
        keychain_source = sources["keychain"]
        expected_account = current_user_name()
        if (
            file_source.get("path") != expected_file
            or keychain_source.get("path") is not None
            or "account" in file_source
        ):
            raise ValueError(f"Claude credential source scope mismatch for {profile.id}")
        if (
            not expected_account
            or keychain_source.get("account") != expected_account
            or "account" in file_source
        ):
            raise ValueError(f"Claude Keychain account mismatch for {profile.id}")
        available = [
            source
            for source in (file_source, keychain_source)
            if source.get("status") == "available"
        ]
        if not available and all(
            source.get("status") == "missing" for source in (file_source, keychain_source)
        ):
            if allow_absent:
                return {"kind": "absent"}
            raise ValueError(f"Claude credentials are absent for {profile.id}")
        if len(available) != 1:
            raise ValueError(
                f"Claude worker {profile.id} requires exactly one authoritative credential source"
            )
        unavailable = keychain_source if available[0] is file_source else file_source
        if unavailable.get("status") != "missing":
            raise ValueError(
                f"Claude worker {profile.id} has an ambiguous or unreadable credential source"
            )
        if available[0] is file_source:
            return {"kind": "oauth-file", "path": expected_file}
        return {
            "kind": "keychain",
            "service": _claude_scoped_keychain_service(profile),
            "account": expected_account,
            "config_home": str(profile.home),
        }
    if set(sources) != {"auth-json", "cli-rpc"}:
        raise ValueError(f"Codex credential source set is incomplete for {profile.id}")
    auth_json = sources["auth-json"]
    expected_file = str(profile.home / "auth.json")
    if auth_json.get("path") != expected_file:
        raise ValueError(f"Codex auth.json scope mismatch for {profile.id}")
    if auth_json.get("status") == "missing" and allow_absent:
        return {"kind": "absent"}
    if auth_json.get("status") != "available":
        raise ValueError(f"Codex auth.json is unavailable for {profile.id}")
    cli_rpc = sources["cli-rpc"]
    expected_binary = str(verified_provider_binary(registry, profile))
    if cli_rpc.get("status") != "available" or cli_rpc.get("path") != expected_binary:
        raise ValueError(f"Codex CLI-RPC control path mismatch for {profile.id}")
    return {
        "kind": "auth-json",
        "path": expected_file,
        "cli_rpc_path": expected_binary,
    }


def store_quota(
    registry: Registry,
    profile: Profile,
    normalized: dict[str, Any],
) -> dict[str, Any]:
    normalized = dict(normalized)
    normalized["profile"] = profile.id
    normalized["provider"] = profile.provider
    path = quota_path(registry, profile.id)
    atomic_write_json(path, normalized)
    return normalized


def refresh_quota(
    registry: Registry,
    profile: Profile,
    *,
    timeout: int = 30,
    allow_keychain_prompt: bool = False,
) -> dict[str, Any]:
    normalized = probe_quota(
        registry,
        profile,
        timeout=timeout,
        allow_keychain_prompt=allow_keychain_prompt,
    )
    return store_quota(registry, profile, normalized)


def read_quota(registry: Registry, profile_id: str) -> dict[str, Any]:
    path = quota_path(registry, profile_id)
    try:
        value = read_private_json(path, label="quota cache")
    except FileNotFoundError:
        return {
            "schema": 1,
            "profile": profile_id,
            "status": "unavailable",
            "reason": "no_cache",
            "headroom_percent": None,
            "windows": [],
            "refreshed_at": None,
            "verified_at": None,
            "verified_recent": False,
            "fresh": False,
        }
    except ValueError:
        return {
            "schema": 1,
            "profile": profile_id,
            "status": "error",
            "reason": "unsafe_or_corrupt_cache",
            "headroom_percent": None,
            "windows": [],
            "refreshed_at": None,
            "verified_at": None,
            "verified_recent": False,
            "fresh": False,
        }
    if not isinstance(value, dict):
        return {"profile": profile_id, "status": "unavailable", "fresh": False}
    age = _age_seconds(value.get("refreshed_at"))
    verification_age = _age_seconds(value.get("verified_at"))
    value["age_seconds"] = age
    value["verification_age_seconds"] = verification_age
    value["verified_recent"] = (
        verification_age is not None
        and verification_age <= registry.settings.quota_verification_grace_seconds
    )
    value["fresh"] = (
        value.get("status") == "fresh"
        and age is not None
        and age <= registry.settings.quota_stale_seconds
        and _number(value.get("headroom_percent")) is not None
    )
    return value


def quota_routeability(
    registry: Registry,
    profile: Profile,
    *,
    quota: dict[str, Any] | None = None,
    authentication: str | None = None,
    ignore_reserve: bool = False,
) -> dict[str, Any]:
    current = quota or read_quota(registry, profile.id)
    if profile.safety_policy != "worker":
        return {
            "eligible": False,
            "mode": "blocked",
            "reason": f"safety_policy_{profile.safety_policy}",
        }
    if authentication is not None and authentication != "authenticated":
        return {
            "eligible": False,
            "mode": "blocked",
            "reason": f"local_auth_{authentication}",
        }
    status = str(current.get("status", "unavailable"))
    if status in HARD_BLOCKED_STATUSES:
        return {
            "eligible": False,
            "mode": "blocked",
            "reason": str(current.get("reason") or status),
        }
    if current.get("fresh") is True:
        headroom = _number(current.get("headroom_percent"))
        if headroom is None:
            return {"eligible": False, "mode": "blocked", "reason": "invalid_quota"}
        if not ignore_reserve and headroom <= profile.reserve_percent:
            return {"eligible": False, "mode": "quota", "reason": "quota_reserve"}
        return {"eligible": True, "mode": "quota", "reason": "fresh"}
    reason = (
        "fresh_remote_identity_proof_required"
        if status in {"stale", "unavailable"}
        else "remote_verification_expired"
        if current.get("verified_at")
        else "remote_unverified"
    )
    return {"eligible": False, "mode": "blocked", "reason": reason}


def refresh_due_quotas(
    registry: Registry,
    profiles: list[Profile],
    *,
    timeout: int = 4,
) -> dict[str, str | None]:
    due = [
        profile
        for profile in profiles
        if (age := read_quota(registry, profile.id).get("age_seconds")) is None
        or int(age) > registry.settings.quota_stale_seconds
    ]
    if not due:
        return {}

    def refresh_one(profile: Profile) -> None:
        lock = DirectoryLock(
            registry.settings.state_dir / "locks" / f"quota-{profile.id}.lock",
            stale_seconds=max(registry.settings.lock_stale_seconds, timeout + 1),
            timeout=timeout + 0.5,
        )
        with lock:
            age = read_quota(registry, profile.id).get("age_seconds")
            if age is not None and int(age) <= registry.settings.quota_stale_seconds:
                return
            refresh_quota(registry, profile, timeout=timeout)

    outcomes: dict[str, str | None] = {}
    with ThreadPoolExecutor(max_workers=min(8, len(due))) as executor:
        futures = {executor.submit(refresh_one, profile): profile.id for profile in due}
        for future in as_completed(futures):
            profile_id = futures[future]
            try:
                future.result()
            except (OSError, TimeoutError, ValueError) as exc:
                outcomes[profile_id] = str(exc)
            else:
                outcomes[profile_id] = None
    return outcomes
