from __future__ import annotations

import json
import os
import re
import stat
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from .locks import DirectoryLock
from .models import Profile, Registry
from .paths import ensure_private_dir
from .providers import auth_probe, identity_fingerprint, provider_environment
from .util import atomic_write_bytes, atomic_write_json, utc_now

PRIMARY_WINDOWS = {"five_hour", "seven_day", "weekly", "week"}
AUTH_FAILURE_RE = re.compile(r"sign[- ]?in|required|reauth|token.*(?:revoked|invalid)", re.I)
RATE_LIMIT_RE = re.compile(r"rate.?limit", re.I)
HARD_BLOCKED_STATUSES = {"auth_required", "rate_limited", "error"}
FALLBACK_STATUSES = {"fresh", "stale", "unavailable"}
KNOWN_STATUSES = HARD_BLOCKED_STATUSES | FALLBACK_STATUSES
SAFE_TOKEN_RE = re.compile(r"[A-Za-z0-9_.:-]{1,128}")


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
        current = path.lstat()
    except FileNotFoundError:
        return QuotaCacheSnapshot(False)
    if not stat.S_ISREG(current.st_mode) or current.st_uid != os.getuid():
        raise ValueError(f"quota cache must be a current-user regular file: {path}")
    return QuotaCacheSnapshot(
        True,
        path.read_bytes(),
        stat.S_IMODE(current.st_mode),
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
    try:
        current = path.lstat()
    except FileNotFoundError:
        return
    if not stat.S_ISREG(current.st_mode) or current.st_uid != os.getuid():
        raise ValueError(f"refusing to remove unexpected quota cache path: {path}")
    path.unlink()


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
    identifier = account.get("accountId") or account.get("account_id")
    if not isinstance(identifier, str) or not identifier:
        return None
    return identity_fingerprint(profile.provider, identifier)


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
        return {
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
            "refreshed_at": now,
        }

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
    return {
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
        "refreshed_at": utc_now(),
    }


def _load_raw_quota(
    registry: Registry,
    profile: Profile,
    *,
    timeout: int = 30,
    allow_keychain_prompt: bool = False,
) -> dict[str, Any]:
    binary = registry.settings.quota_binary
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError(f"configured quota-axi candidate is not executable: {binary}")
    cache = profile.home / ".agent-fleet-quota-cache"
    ensure_private_dir(cache)
    env = provider_environment(profile)
    env.pop("AGENT_FLEET_QUOTA_FIXTURE_DIR", None)
    env.pop("AGENT_FLEET_TEST_QUOTA_FIXTURE_DIR", None)
    env["XDG_CACHE_HOME"] = str(cache)
    if profile.provider == "codex":
        env["QUOTA_AXI_CODEX_BINARY"] = str(registry.require_provider("codex").binary)
    try:
        argv = [str(binary), "--provider", profile.provider, "--json", "--full"]
        if allow_keychain_prompt and profile.provider == "claude":
            argv.append("--allow-keychain-prompt")
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
) -> dict[str, Any]:
    raw = _load_raw_quota(
        registry,
        profile,
        timeout=timeout,
        allow_keychain_prompt=allow_keychain_prompt,
    )
    normalized = _normalize(profile, raw)
    if profile.provider == "claude":
        probe = auth_probe(registry, profile)
        fingerprint = probe.get("identity_fingerprint")
        existing = normalized.get("identity_fingerprint")
        if fingerprint and existing and fingerprint != existing:
            normalized["status"] = "error"
            normalized["reason"] = "identity_source_mismatch"
            normalized["verified_at"] = None
            normalized["identity_fingerprint"] = None
            normalized["identity_source"] = None
        elif fingerprint:
            normalized["identity_fingerprint"] = fingerprint
            normalized["identity_source"] = probe.get("identity_source")
    return normalized


def store_quota(
    registry: Registry,
    profile: Profile,
    normalized: dict[str, Any],
) -> dict[str, Any]:
    normalized = dict(normalized)
    normalized["profile"] = profile.id
    normalized["provider"] = profile.provider
    path = quota_path(registry, profile.id)
    try:
        previous = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        previous = {}
    if isinstance(previous, dict):
        if not normalized.get("verified_at") and _parse_time(previous.get("verified_at")):
            normalized["verified_at"] = previous["verified_at"]
        fingerprint = normalized.get("identity_fingerprint")
        fingerprint_is_verified = (
            normalized.get("status") == "fresh"
            and normalized.get("verified_at") is not None
            and normalized.get("headroom_percent") is not None
            and isinstance(fingerprint, str)
            and len(fingerprint) == 64
        )
        previous_fingerprint = previous.get("identity_fingerprint")
        if (
            not fingerprint_is_verified
            and isinstance(previous_fingerprint, str)
            and len(previous_fingerprint) == 64
            and _parse_time(previous.get("verified_at")) is not None
        ):
            normalized["identity_fingerprint"] = previous_fingerprint
            normalized["identity_source"] = "previous-verified-quota-account"
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
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
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
    if status in FALLBACK_STATUSES and current.get("verified_recent") is True:
        return {
            "eligible": True,
            "mode": "verified-fallback",
            "reason": "recent_remote_verification",
        }
    reason = "remote_verification_expired" if current.get("verified_at") else "remote_unverified"
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
