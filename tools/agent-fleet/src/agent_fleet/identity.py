from __future__ import annotations

import json
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from .models import Profile, Registry
from .providers import identity_fingerprint
from .quota import has_remote_identity_proof, probe_quota, read_quota
from .util import atomic_write_json, utc_now


def _anchor_path(registry: Registry, provider: str, kind: str) -> Path:
    return registry.settings.state_dir / "identity-anchors" / f"{provider}-{kind}.json"


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
        payload = json.loads(_anchor_path(registry, provider, kind).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
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


def _refresh_desktop_identity_anchor(
    registry: Registry,
    provider: str,
    desktop_file: Path,
) -> dict[str, Any]:
    try:
        payload = json.loads(desktop_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        payload = None
    identifier = payload.get("lastKnownAccountUuid") if isinstance(payload, dict) else None
    if not desktop_file.exists():
        desktop_status = "absent"
    elif isinstance(identifier, str) and identifier:
        desktop_status = "present"
    else:
        desktop_status = "error"
    result = {
        "schema": 1,
        "provider": provider,
        "kind": "desktop",
        "status": desktop_status,
        "identity_fingerprint": (
            identity_fingerprint(provider, identifier)
            if isinstance(identifier, str) and identifier
            else None
        ),
        "refreshed_at": utc_now(),
    }
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
    if provider_config.base_home is not None and provider_config.base_home.exists():
        base = Profile(
            id=f"{provider}-base-anchor",
            provider=provider,
            home=provider_config.base_home,
            pools=(f"{provider}-manual",),
            enabled=False,
            safety_policy="desktop_shared",
        )
        try:
            quota = probe_quota(
                registry,
                base,
                timeout=timeout,
                allow_keychain_prompt=allow_keychain_prompt,
            )
        except (OSError, TimeoutError, ValueError) as exc:
            base_result = {
                "schema": 1,
                "provider": provider,
                "kind": "base",
                "status": "error",
                "reason": type(exc).__name__,
                "identity_fingerprint": None,
                "refreshed_at": utc_now(),
            }
        else:
            status = str(quota.get("status", "unavailable"))
            fingerprint = quota.get("identity_fingerprint")
            reason = quota.get("reason")
            if status == "fresh" and not _quota_identity_is_verified(quota):
                status = "error"
                reason = "base_identity_unavailable"
                fingerprint = None
            base_result = {
                "schema": 1,
                "provider": provider,
                "kind": "base",
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
    timeout: int = 4,
) -> None:
    provider_config = registry.require_provider(provider)
    due = False
    if provider_config.base_home is not None and provider_config.base_home.exists():
        current = _read_anchor(registry, provider, "base")
        age = _age_seconds(current.get("refreshed_at"))
        due = age is None or age > registry.settings.quota_stale_seconds
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
        if require_complete_worker_set and other.safety_policy == "worker" and not has_recent_proof:
            return f"managed_identity_unverified:{other.id}"
        if not has_recent_proof:
            continue
        if not isinstance(other_fingerprint, str) or len(other_fingerprint) != 64:
            if require_complete_worker_set and other.safety_policy == "worker":
                return f"managed_identity_unverified:{other.id}"
            continue
        if other_fingerprint == fingerprint:
            return f"managed:{other.id}"
    provider_config = registry.require_provider(profile.provider)
    if provider_config.base_home is not None and profile.home == provider_config.base_home:
        return "base_home_overlap"
    if provider_config.base_home is not None and provider_config.base_home.exists():
        base = _read_anchor(registry, profile.provider, "base")
        base_status = str(base.get("status", "unavailable"))
        base_fingerprint = base.get("identity_fingerprint")
        if (
            base_status != "fresh"
            or not _anchor_is_fresh(registry, base)
            or not isinstance(base_fingerprint, str)
            or len(base_fingerprint) != 64
        ):
            return f"base_identity_unverified:{base.get('reason') or base_status}"
        if base_fingerprint == fingerprint:
            return "base_identity"
    if profile.provider == "claude" and provider_config.desktop_identity_file is not None:
        desktop = _read_anchor(registry, profile.provider, "desktop")
        desktop_status = desktop.get("status")
        desktop_fingerprint = desktop.get("identity_fingerprint")
        if not _anchor_is_fresh(registry, desktop):
            return "desktop_identity_unverified"
        # A configured Desktop anchor is a required safety boundary. Missing
        # state is not evidence that Desktop is signed out: it can also mean
        # the configured path moved or became unreadable. Operators who do not
        # have/use Desktop must opt out explicitly with
        # desktop_identity_file = false.
        if desktop_status == "absent":
            return "desktop_identity_unverified"
        if (
            desktop_status != "present"
            or not isinstance(desktop_fingerprint, str)
            or len(desktop_fingerprint) != 64
        ):
            return "desktop_identity_unverified"
        if desktop_fingerprint == fingerprint:
            return "desktop_identity"
    return None
