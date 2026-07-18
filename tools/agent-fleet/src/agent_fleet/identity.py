from __future__ import annotations

import os
import unicodedata
from datetime import UTC, datetime
from hashlib import sha256
from pathlib import Path
from typing import Any

from .models import Profile, Registry
from .paths import current_user_home
from .providers import credential_file_state, identity_fingerprint
from .quota import has_remote_identity_proof, probe_quota, read_quota
from .util import atomic_write_json, read_owned_private_json, read_private_json, utc_now


def _anchor_path(registry: Registry, provider: str, kind: str) -> Path:
    return registry.settings.state_dir / "identity-anchors" / f"{provider}-{kind}.json"


def identity_bundle_path(registry: Registry, provider: str) -> Path:
    return registry.settings.state_dir / "identity-bindings" / f"{provider}-bundle.json"


def _stable_profile_home(profile: Profile) -> str:
    try:
        resolved = profile.home.resolve(strict=True)
    except OSError as exc:
        raise ValueError(f"managed profile home is unavailable: {profile.home}") from exc
    if not resolved.is_dir() or resolved != Path(os.path.realpath(profile.home)):
        raise ValueError(f"managed profile home is not stable: {profile.home}")
    return str(resolved)


def read_identity_binding(registry: Registry, profile: Profile) -> dict[str, Any]:
    try:
        bundle = read_private_json(
            identity_bundle_path(registry, profile.provider),
            label="provider identity bundle",
        )
    except (FileNotFoundError, ValueError):
        return {"status": "unavailable", "reason": "identity_binding_missing"}
    if (
        not isinstance(bundle, dict)
        or bundle.get("schema") != 1
        or bundle.get("provider") != profile.provider
        or not isinstance(bundle.get("workers"), dict)
    ):
        return {"status": "unavailable", "reason": "identity_binding_invalid"}
    payload = bundle["workers"].get(profile.id)
    if not isinstance(payload, dict):
        return {"status": "unavailable", "reason": "identity_binding_missing"}
    return {"schema": 1, **payload}


def _external_observation(registry: Registry, provider: str) -> dict[str, Any]:
    configured = registry.require_provider(provider)
    observation: dict[str, Any] = {"provider": provider}
    if configured.base_home is not None:
        base = _read_anchor(registry, provider, "base")
        status = base.get("status")
        fingerprint = base.get("identity_fingerprint")
        if status not in {"absent", "present"}:
            raise ValueError(f"{provider} base identity is indeterminate")
        if status == "present" and not (
            isinstance(fingerprint, str) and len(fingerprint) == 64
        ):
            raise ValueError(f"{provider} base identity fingerprint is unavailable")
        observation["base"] = {
            "home": str(configured.base_home),
            "status": status,
            "identity_fingerprint": fingerprint if status == "present" else None,
        }
    if provider == "claude" and configured.desktop_identity_file is not None:
        desktop = _desktop_identity_snapshot(provider, configured.desktop_identity_file)
        status = desktop.get("status")
        fingerprint = desktop.get("identity_fingerprint")
        if status not in {"absent", "present"}:
            raise ValueError("Claude Desktop identity is indeterminate")
        if status == "present" and not (
            isinstance(fingerprint, str) and len(fingerprint) == 64
        ):
            raise ValueError("Claude Desktop identity fingerprint is unavailable")
        observation["desktop"] = {
            "path": str(configured.desktop_identity_file),
            "status": status,
            "identity_fingerprint": fingerprint if status == "present" else None,
        }
    return observation


def adopt_provider_identity_bundle(
    registry: Registry,
    provider: str,
    proofs: dict[str, tuple[dict[str, Any], dict[str, Any]]],
    *,
    allow_keychain_prompt: bool = False,
) -> dict[str, Any]:
    workers = sorted(
        (
            profile
            for profile in registry.profiles.values()
            if profile.provider == provider and profile.safety_policy == "worker"
        ),
        key=lambda profile: profile.id,
    )
    expected_ids = {profile.id for profile in workers}
    if set(proofs) != expected_ids:
        raise ValueError("identity bundle requires one proof for every provider worker")
    refresh_provider_identity_anchors(
        registry,
        provider,
        allow_keychain_prompt=allow_keychain_prompt,
    )
    fingerprints: set[str] = set()
    bindings: dict[str, dict[str, Any]] = {}
    for profile in workers:
        quota, source_contract = proofs[profile.id]
        if not has_remote_identity_proof(quota):
            raise ValueError(f"cannot bind stale or unverified identity for {profile.id}")
        fingerprint = quota.get("identity_fingerprint")
        if not isinstance(fingerprint, str) or fingerprint in fingerprints:
            raise ValueError("provider identity bundle contains duplicate remote identities")
        fingerprints.add(fingerprint)
        bindings[profile.id] = {
            "profile": profile.id,
            "provider": profile.provider,
            "stable_home": _stable_profile_home(profile),
            "remote_fingerprint": fingerprint,
            "credential_source_contract": source_contract,
        }
    external = _external_observation(registry, provider)
    for kind in ("base", "desktop"):
        observation = external.get(kind)
        if (
            isinstance(observation, dict)
            and observation.get("status") == "present"
            and observation.get("identity_fingerprint") in fingerprints
        ):
            raise ValueError(
                f"provider identity bundle conflicts with final {kind} identity"
            )
    payload = {
        "schema": 1,
        "provider": provider,
        "external": external,
        "workers": bindings,
        "adopted_at": utc_now(),
    }
    atomic_write_json(identity_bundle_path(registry, provider), payload)
    return payload


def verify_identity_bundle(
    registry: Registry,
    provider: str,
    *,
    compare_live_external: bool = False,
) -> dict[str, Any]:
    """Validate a provider bundle without invoking a provider or reading reserves."""

    try:
        payload = read_private_json(
            identity_bundle_path(registry, provider),
            label="provider identity bundle",
        )
    except (FileNotFoundError, ValueError) as exc:
        return {"provider": provider, "status": "invalid", "reason": type(exc).__name__}
    reason: str | None = None
    if not isinstance(payload, dict) or set(payload) != {
        "schema",
        "provider",
        "external",
        "workers",
        "adopted_at",
    }:
        reason = "closed_schema"
    elif payload.get("schema") != 1 or payload.get("provider") != provider:
        reason = "provider_or_schema"
    try:
        adopted = datetime.fromisoformat(str(payload.get("adopted_at", "")).replace("Z", "+00:00"))
    except ValueError:
        adopted = None
    if reason is None and (adopted is None or adopted.tzinfo is None):
        reason = "adopted_at"
    expected_workers = {
        profile.id: profile
        for profile in registry.profiles.values()
        if profile.provider == provider and profile.safety_policy == "worker"
    }
    workers = payload.get("workers") if isinstance(payload, dict) else None
    if reason is None and (
        not isinstance(workers, dict) or set(workers) != set(expected_workers)
    ):
        reason = "worker_set"
    if reason is None:
        for profile_id, profile in expected_workers.items():
            binding = workers[profile_id]
            if not isinstance(binding, dict) or set(binding) != {
                "profile",
                "provider",
                "stable_home",
                "remote_fingerprint",
                "credential_source_contract",
            }:
                reason = f"worker_schema:{profile_id}"
                break
            fingerprint = binding.get("remote_fingerprint")
            if (
                binding.get("profile") != profile.id
                or binding.get("provider") != provider
                or binding.get("stable_home") != _stable_profile_home(profile)
                or not isinstance(fingerprint, str)
                or len(fingerprint) != 64
                or any(character not in "0123456789abcdef" for character in fingerprint)
            ):
                reason = f"worker_identity:{profile_id}"
                break
            contract = binding.get("credential_source_contract")
            if not isinstance(contract, dict):
                reason = f"credential_source:{profile_id}"
                break
            if provider == "claude":
                allowed = (
                    set(contract) == {"kind", "path"}
                    and contract.get("kind") == "oauth-file"
                    and contract.get("path") == str(profile.home / ".credentials.json")
                ) or (
                    set(contract) == {"kind", "service", "config_home"}
                    and contract.get("kind") == "keychain"
                    and contract.get("config_home") == str(profile.home)
                    and contract.get("service")
                    == "Claude Code-credentials-"
                    + sha256(
                        unicodedata.normalize("NFC", str(profile.home)).encode()
                    ).hexdigest()[:8]
                )
            else:
                allowed = (
                    set(contract) == {"kind", "path", "cli_rpc_path"}
                    and contract.get("kind") == "auth-json"
                    and contract.get("path") == str(profile.home / "auth.json")
                    and isinstance(contract.get("cli_rpc_path"), str)
                    and Path(contract["cli_rpc_path"]).is_absolute()
                )
            if not allowed:
                reason = f"credential_source:{profile_id}"
                break
    external = payload.get("external") if isinstance(payload, dict) else None
    if reason is None and not isinstance(external, dict):
        reason = "external_schema"
    if reason is None:
        configured = registry.require_provider(provider)
        expected_external_keys = {"provider"}
        if configured.base_home is not None:
            expected_external_keys.add("base")
        if provider == "claude" and configured.desktop_identity_file is not None:
            expected_external_keys.add("desktop")
        if set(external) != expected_external_keys or external.get("provider") != provider:
            reason = "external_schema"
        for kind in expected_external_keys - {"provider"}:
            item = external.get(kind)
            path_key = "home" if kind == "base" else "path"
            expected_path = (
                str(configured.base_home)
                if kind == "base"
                else str(configured.desktop_identity_file)
            )
            if (
                not isinstance(item, dict)
                or set(item) != {path_key, "status", "identity_fingerprint"}
                or item.get(path_key) != expected_path
                or item.get("status") not in {"absent", "present"}
            ):
                reason = f"external_{kind}"
                break
            fingerprint = item.get("identity_fingerprint")
            if item.get("status") == "absent":
                valid_fingerprint = fingerprint is None
            else:
                valid_fingerprint = (
                    isinstance(fingerprint, str)
                    and len(fingerprint) == 64
                    and all(character in "0123456789abcdef" for character in fingerprint)
                )
            if not valid_fingerprint:
                reason = f"external_{kind}_fingerprint"
                break
    if reason is None and compare_live_external:
        try:
            current = _external_observation(registry, provider)
        except ValueError:
            reason = "external_indeterminate"
        else:
            if external != current:
                reason = "external_changed"
    return {
        "provider": provider,
        "status": "verified" if reason is None else "invalid",
        "reason": reason,
    }


def identity_binding_conflict(
    registry: Registry,
    profile: Profile,
    quota: dict[str, Any],
    credential_source_contract: dict[str, Any] | None,
) -> str | None:
    try:
        bundle = read_private_json(
            identity_bundle_path(registry, profile.provider),
            label="provider identity bundle",
        )
    except (FileNotFoundError, ValueError):
        return "identity_binding_missing"
    if (
        not isinstance(bundle, dict)
        or bundle.get("schema") != 1
        or bundle.get("provider") != profile.provider
        or not isinstance(bundle.get("workers"), dict)
        or not isinstance(bundle.get("external"), dict)
    ):
        return "identity_binding_invalid"
    expected_workers = {
        candidate.id
        for candidate in registry.profiles.values()
        if candidate.provider == profile.provider and candidate.safety_policy == "worker"
    }
    if set(bundle["workers"]) != expected_workers:
        return "identity_binding_worker_set_changed"
    binding = bundle["workers"].get(profile.id)
    if not isinstance(binding, dict):
        return "identity_binding_missing"
    if binding.get("profile") != profile.id or binding.get("provider") != profile.provider:
        return "identity_binding_profile_mismatch"
    try:
        stable_home = _stable_profile_home(profile)
    except ValueError:
        return "identity_binding_home_unavailable"
    if binding.get("stable_home") != stable_home:
        return "identity_binding_home_mismatch"
    if quota.get("identity_fingerprint") != binding.get("remote_fingerprint"):
        return "identity_binding_remote_mismatch"
    if credential_source_contract is None:
        return "credential_source_unverified"
    if binding.get("credential_source_contract") != credential_source_contract:
        return "credential_source_changed"
    try:
        current = _external_observation(registry, profile.provider)
    except ValueError:
        return "external_identity_indeterminate"
    if bundle["external"] != current:
        return "external_identity_changed"
    return None


def _age_seconds(value: Any) -> int | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    return max(0, int((datetime.now(UTC) - parsed.astimezone(UTC)).total_seconds()))


def _read_anchor(registry: Registry, provider: str, kind: str) -> dict[str, Any]:
    try:
        payload = read_private_json(_anchor_path(registry, provider, kind), label="identity anchor")
    except (FileNotFoundError, ValueError):
        return {"status": "unavailable", "reason": "identity_anchor_missing"}
    return (
        payload
        if isinstance(payload, dict)
        else {
            "status": "unavailable",
            "reason": "identity_anchor_invalid",
        }
    )


def _quota_identity_is_verified(quota: dict[str, Any]) -> bool:
    return has_remote_identity_proof(quota)


def _managed_identity_has_recent_proof(quota: dict[str, Any]) -> bool:
    return _quota_identity_is_verified(quota) or quota.get("verified_recent") is True


def _anchor_is_fresh(registry: Registry, anchor: dict[str, Any]) -> bool:
    age = _age_seconds(anchor.get("refreshed_at"))
    return age is not None and age <= registry.settings.quota_stale_seconds


def _desktop_identity_snapshot(provider: str, desktop_file: Path) -> dict[str, Any]:
    try:
        payload = read_owned_private_json(desktop_file, label="desktop identity file")
    except FileNotFoundError:
        payload = None
        desktop_status = "absent"
        reason = "desktop_identity_missing"
    except ValueError as exc:
        payload = None
        desktop_status = "indeterminate"
        reason = type(exc).__name__
    else:
        desktop_status = "present"
        reason = None
    identifier = payload.get("lastKnownAccountUuid") if isinstance(payload, dict) else None
    if desktop_status == "present" and not (isinstance(identifier, str) and identifier):
        desktop_status = "indeterminate"
        reason = "desktop_identity_invalid"
    return {
        "schema": 1,
        "provider": provider,
        "kind": "desktop",
        "status": desktop_status,
        "reason": reason,
        "identity_fingerprint": (
            identity_fingerprint(provider, identifier)
            if isinstance(identifier, str) and identifier
            else None
        ),
        "refreshed_at": utc_now(),
    }


def _refresh_desktop_identity_anchor(
    registry: Registry,
    provider: str,
    desktop_file: Path,
) -> dict[str, Any]:
    result = _desktop_identity_snapshot(provider, desktop_file)
    atomic_write_json(_anchor_path(registry, provider, "desktop"), result)
    return result


def refresh_provider_identity_anchors(
    registry: Registry,
    provider: str,
    *,
    allow_keychain_prompt: bool = False,
    timeout: int = 30,
) -> dict[str, dict[str, Any]]:
    provider_config = registry.require_provider(provider)
    results: dict[str, dict[str, Any]] = {}
    if provider_config.base_home is not None:
        base = Profile(
            id=f"{provider}-base-anchor",
            provider=provider,
            home=provider_config.base_home,
            pools=(f"{provider}-manual",),
            enabled=False,
            safety_policy="desktop_shared",
        )
        file_state, file_reason = credential_file_state(base)
        if file_state == "indeterminate":
            base_result = {
                "schema": 1,
                "provider": provider,
                "kind": "base",
                "home": str(provider_config.base_home),
                "status": "indeterminate",
                "reason": file_reason or "credential_file_indeterminate",
                "identity_fingerprint": None,
                "refreshed_at": utc_now(),
            }
        elif provider == "codex" and file_state == "absent":
            base_result = {
                "schema": 1,
                "provider": provider,
                "kind": "base",
                "home": str(provider_config.base_home),
                "status": "absent",
                "reason": "credentials_missing",
                "identity_fingerprint": None,
                "refreshed_at": utc_now(),
            }
        else:
            try:
                default_provider_home = (
                    provider == "claude"
                    and provider_config.base_home == current_user_home() / ".claude"
                )
                quota = probe_quota(
                    registry,
                    base,
                    timeout=timeout,
                    allow_keychain_prompt=allow_keychain_prompt,
                    default_provider_home=default_provider_home,
                )
            except (OSError, TimeoutError, ValueError) as exc:
                base_result = {
                    "schema": 1,
                    "provider": provider,
                    "kind": "base",
                    "home": str(provider_config.base_home),
                    "status": "indeterminate",
                    "reason": type(exc).__name__,
                    "identity_fingerprint": None,
                    "refreshed_at": utc_now(),
                }
            else:
                fingerprint = quota.get("identity_fingerprint")
                reason = quota.get("reason")
                if _quota_identity_is_verified(quota):
                    status = "present"
                elif (
                    provider == "claude"
                    and file_state == "absent"
                    and quota.get("credential_state") == "absent"
                ):
                    status = "absent"
                    reason = "credentials_missing"
                    fingerprint = None
                else:
                    status = "indeterminate"
                    reason = reason or "base_identity_unavailable"
                    fingerprint = None
                base_result = {
                    "schema": 1,
                    "provider": provider,
                    "kind": "base",
                    "home": str(provider_config.base_home),
                    "status": status,
                    "reason": reason,
                    "identity_fingerprint": fingerprint,
                    "refreshed_at": utc_now(),
                }
        atomic_write_json(_anchor_path(registry, provider, "base"), base_result)
        results["base"] = base_result
    if provider == "claude" and provider_config.desktop_identity_file is not None:
        desktop_result = _refresh_desktop_identity_anchor(
            registry,
            provider,
            provider_config.desktop_identity_file,
        )
        results["desktop"] = desktop_result
    return results


def refresh_provider_identity_anchors_if_due(
    registry: Registry,
    provider: str,
    *,
    timeout: int = 30,
) -> None:
    provider_config = registry.require_provider(provider)
    # Default CLI/Desktop credentials can switch between any two route
    # attempts. Refresh both providers on every real selection so quota-cache
    # TTL cannot conceal an absent->duplicate transition.
    due = provider_config.base_home is not None
    if provider == "claude" and provider_config.desktop_identity_file is not None:
        # Desktop can switch accounts between two route attempts. This local
        # JSON read is cheap and must not inherit the base quota anchor's TTL.
        _refresh_desktop_identity_anchor(
            registry,
            provider,
            provider_config.desktop_identity_file,
        )
    if due:
        refresh_provider_identity_anchors(registry, provider, timeout=timeout)


def identity_conflict(
    registry: Registry,
    profile: Profile,
    quota: dict[str, Any],
    *,
    require_complete_worker_set: bool = True,
) -> str | None:
    fingerprint = quota.get("identity_fingerprint")
    if not isinstance(fingerprint, str) or len(fingerprint) != 64:
        return "identity_unavailable"
    for other in registry.profiles.values():
        if other.id == profile.id or other.provider != profile.provider:
            continue
        other_quota = read_quota(registry, other.id)
        other_fingerprint = other_quota.get("identity_fingerprint")
        has_recent_proof = _managed_identity_has_recent_proof(other_quota)
        required_worker = other.enabled and other.safety_policy == "worker"
        if require_complete_worker_set and required_worker and not has_recent_proof:
            return f"managed_identity_unverified:{other.id}"
        if not has_recent_proof:
            continue
        if not isinstance(other_fingerprint, str) or len(other_fingerprint) != 64:
            if require_complete_worker_set and required_worker:
                return f"managed_identity_unverified:{other.id}"
            continue
        if other_fingerprint == fingerprint:
            return f"managed:{other.id}"
    provider_config = registry.require_provider(profile.provider)
    if provider_config.base_home is not None and profile.home == provider_config.base_home:
        return "base_home_overlap"
    if provider_config.base_home is not None:
        base = _read_anchor(registry, profile.provider, "base")
        base_status = str(base.get("status", "unavailable"))
        base_fingerprint = base.get("identity_fingerprint")
        if base.get("home") != str(provider_config.base_home):
            return "base_identity_unverified:base_home_changed"
        if not _anchor_is_fresh(registry, base):
            return "base_identity_unverified:stale"
        if base_status == "absent":
            pass
        elif base_status == "present":
            if not isinstance(base_fingerprint, str) or len(base_fingerprint) != 64:
                return "base_identity_unverified:missing_fingerprint"
            if base_fingerprint == fingerprint:
                return "base_identity"
        else:
            return f"base_identity_unverified:{base.get('reason') or base_status}"
    if profile.provider == "claude" and provider_config.desktop_identity_file is not None:
        desktop = _desktop_identity_snapshot(
            profile.provider,
            provider_config.desktop_identity_file,
        )
        desktop_status = desktop.get("status")
        desktop_fingerprint = desktop.get("identity_fingerprint")
        if not _anchor_is_fresh(registry, desktop):
            return "desktop_identity_unverified"
        if desktop_status == "absent":
            return None
        if desktop_status != "present":
            return "desktop_identity_unverified"
        if not isinstance(desktop_fingerprint, str) or len(desktop_fingerprint) != 64:
            return "desktop_identity_unverified"
        if desktop_fingerprint == fingerprint:
            return "desktop_identity"
    return None
