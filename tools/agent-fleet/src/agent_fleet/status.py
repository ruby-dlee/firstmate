from __future__ import annotations

from collections import Counter
from typing import Any

from .cooldowns import read_cooldown
from .identity import identity_conflict, refresh_provider_identity_anchors_if_due
from .leases import active_leases
from .models import SUPPORTED_PROVIDERS, Registry
from .providers import auth_status
from .provision import profile_is_provisioned
from .quota import quota_routeability, read_quota, refresh_due_quotas


def profile_status(registry: Registry, profile_id: str) -> dict[str, Any]:
    profile = registry.require_profile(profile_id)
    if profile.safety_policy == "worker":
        refresh_provider_identity_anchors_if_due(registry, profile.provider)
    leases = active_leases(registry)
    provisioned = profile_is_provisioned(profile)
    authentication = auth_status(registry, profile) if provisioned else "not-provisioned"
    quota = read_quota(registry, profile.id)
    routeability = quota_routeability(
        registry,
        profile,
        quota=quota,
        authentication=authentication,
    )
    conflict = identity_conflict(registry, profile, quota)
    if conflict is not None:
        routeability = {
            "eligible": False,
            "mode": "blocked",
            "reason": conflict,
        }
    return {
        **profile.public_dict(),
        "provisioned": provisioned,
        "auth_status": authentication,
        "active_leases": sum(lease.get("profile") == profile.id for lease in leases),
        "cooldown": read_cooldown(registry, profile.id),
        "quota": quota,
        "routeability": routeability,
    }


def pool_status(
    registry: Registry,
    *,
    pool: str,
    provider: str | None = None,
) -> dict[str, Any]:
    leases = active_leases(registry)
    counts = Counter(str(lease.get("profile")) for lease in leases)
    providers = [provider] if provider else list(SUPPORTED_PROVIDERS)
    for provider_name in providers:
        refresh_provider_identity_anchors_if_due(registry, provider_name)
    scoped = [
        profile
        for profile in registry.profiles.values()
        if profile.provider in providers and pool in profile.pools and profile.enabled
    ]
    refresh_due_quotas(registry, scoped)
    summaries: list[dict[str, Any]] = []
    for provider_name in providers:
        profiles: list[dict[str, Any]] = []
        for profile in registry.profiles.values():
            if profile.provider != provider_name or pool not in profile.pools:
                continue
            provisioned = profile_is_provisioned(profile)
            authentication = auth_status(registry, profile) if provisioned else "not-provisioned"
            quota = read_quota(registry, profile.id)
            fresh = quota.get("fresh") is True
            headroom = quota.get("headroom_percent") if fresh else None
            cooldown = read_cooldown(registry, profile.id)
            capacity = counts[profile.id] < profile.max_concurrent
            routeability = quota_routeability(
                registry,
                profile,
                quota=quota,
                authentication=authentication,
            )
            conflict = identity_conflict(registry, profile, quota)
            if conflict is not None:
                routeability = {
                    "eligible": False,
                    "mode": "blocked",
                    "reason": conflict,
                }
            eligible = (
                profile.enabled
                and provisioned
                and capacity
                and cooldown is None
                and routeability["eligible"]
            )
            adjusted = (
                float(headroom)
                + (profile.weight - 1) * 5
                - counts[profile.id] * registry.settings.active_lease_penalty
                if eligible and fresh
                else None
            )
            profiles.append(
                {
                    "profile": profile.id,
                    "enabled": profile.enabled,
                    "provisioned": provisioned,
                    "auth_status": authentication,
                    "active_leases": counts[profile.id],
                    "max_concurrent": profile.max_concurrent,
                    "quota_fresh": fresh,
                    "quota_status": quota.get("status"),
                    "verified_recent": quota.get("verified_recent"),
                    "headroom_percent": headroom,
                    "adjusted_headroom_percent": adjusted,
                    "reserve_percent": profile.reserve_percent,
                    "cooldown": cooldown,
                    "eligible": eligible,
                    "routeability_reason": routeability["reason"],
                    "identity_fingerprint": quota.get("identity_fingerprint"),
                }
            )
        fresh_eligible = [item for item in profiles if item["eligible"] and item["quota_fresh"]]
        fallback_eligible = [
            item for item in profiles if item["eligible"] and not item["quota_fresh"]
        ]
        mode = (
            "quota"
            if fresh_eligible
            else "verified-fallback"
            if fallback_eligible
            else "unavailable"
        )
        eligible_profiles = fresh_eligible or fallback_eligible
        summaries.append(
            {
                "provider": provider_name,
                "available": bool(eligible_profiles),
                "selection_mode": mode,
                "degraded": mode == "verified-fallback",
                "best_adjusted_headroom_percent": max(
                    (float(item["adjusted_headroom_percent"]) for item in fresh_eligible),
                    default=None,
                ),
                "eligible_profiles": len(eligible_profiles),
                "active_leases": sum(counts[item["profile"]] for item in profiles),
                "profiles": profiles,
            }
        )
    return {"schema": 1, "pool": pool, "providers": summaries}
