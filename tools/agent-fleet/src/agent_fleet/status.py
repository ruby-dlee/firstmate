from __future__ import annotations

from collections import Counter
from typing import Any

from .cooldowns import read_cooldown
from .identity import (
    identity_binding_conflict,
    identity_conflict,
    probe_provider_external_observation,
    verify_identity_bundle,
)
from .leases import active_leases
from .locks import provider_selection_refresh_lock
from .models import SUPPORTED_PROVIDERS, Profile, Registry
from .provision import profile_is_provisioned
from .quota import quota_routeability, read_quota
from .routeability import source_attested_live_proofs


def _public_routeability(
    registry: Registry,
    profile: Profile,
    authentication: str,
    proof: dict[str, Any] | None,
    live_failure: str | None,
    provider_failures: dict[str, str],
    observed_external: dict[str, Any] | None,
) -> tuple[dict[str, Any], dict[str, Any], str | None]:
    quota = proof["quota"] if proof is not None else read_quota(registry, profile.id)
    routeability = quota_routeability(
        registry,
        profile,
        quota=quota,
        authentication=authentication,
    )
    binding_conflict = (
        identity_binding_conflict(
            registry,
            profile,
            quota,
            proof["source_contract"],
            observed_external=observed_external,
        )
        if proof is not None
        else None
    )
    conflict = (
        identity_conflict(
            registry,
            profile,
            quota,
            observed_external=observed_external,
        )
        if proof is not None
        else None
    )
    if live_failure is not None:
        routeability = {
            "eligible": False,
            "mode": "blocked",
            "reason": f"fresh_live_identity_proof_required:{live_failure}",
        }
    elif provider_failures:
        failed_profile = sorted(provider_failures)[0]
        routeability = {
            "eligible": False,
            "mode": "blocked",
            "reason": (
                "provider_identity_proof_incomplete:"
                f"{failed_profile}:{provider_failures[failed_profile]}"
            ),
        }
    elif binding_conflict is not None or conflict is not None:
        routeability = {
            "eligible": False,
            "mode": "blocked",
            "reason": binding_conflict or conflict,
        }
    return quota, routeability, binding_conflict


def _provider_live_snapshot(
    registry: Registry,
    provider_name: str,
    provider_scope: list[Profile],
) -> tuple[
    dict[str, dict[str, Any]],
    dict[str, str],
    dict[str, str],
    dict[str, Any] | None,
]:
    proof_scope = [profile for profile in provider_scope if profile_is_provisioned(profile)]
    failures = {
        profile.id: "profile_unprovisioned"
        for profile in provider_scope
        if not profile_is_provisioned(profile)
    }
    if not proof_scope:
        return {}, failures, {}, None
    with provider_selection_refresh_lock(
        registry.settings.state_dir,
        provider_name,
        registry.settings.lock_stale_seconds,
    ):
        proofs, live_failures = source_attested_live_proofs(registry, proof_scope)
        failures.update(live_failures)
        authentications = {
            profile_id: "authenticated" for profile_id in proofs
        }
        try:
            observed_external = probe_provider_external_observation(
                registry,
                provider_name,
            )
        except (OSError, TimeoutError, ValueError) as exc:
            observed_external = None
            if isinstance(exc, TimeoutError):
                reason = "external_identity_timeout"
            elif isinstance(exc, OSError):
                reason = "external_identity_unavailable"
            else:
                reason = "external_identity_indeterminate"
            failures[f"{provider_name}-external"] = reason
        else:
            bundle = verify_identity_bundle(
                registry,
                provider_name,
                observed_external=observed_external,
            )
            if bundle["status"] != "verified":
                failures[f"{provider_name}-external"] = (
                    f"identity_bundle_{bundle.get('reason', 'invalid')}"
                )
    return proofs, failures, authentications, observed_external


def profile_status(registry: Registry, profile_id: str) -> dict[str, Any]:
    profile = registry.require_profile(profile_id)
    if profile.safety_policy != "worker":
        return {
            **profile.public_dict(),
            "provisioned": False,
            "auth_status": "external-reserve",
            "active_leases": 0,
            "cooldown": None,
            "quota": {},
            "live_identity_failure": None,
            "identity_binding_conflict": None,
            "routeability": {
                "eligible": False,
                "mode": "blocked",
                "reason": "external_reserve_never_routed",
            },
        }
    leases = active_leases(registry)
    provisioned = profile_is_provisioned(profile)
    provider_scope = [
        candidate
        for candidate in registry.profiles.values()
        if candidate.provider == profile.provider
        and candidate.safety_policy == "worker"
        and (candidate.enabled or candidate.id == profile.id)
    ]
    proofs, failures, authentications, observed_external = _provider_live_snapshot(
        registry,
        profile.provider,
        provider_scope,
    )
    authentication = (
        authentications.get(profile.id, "unknown")
        if provisioned
        else "not-provisioned"
    )
    proof = proofs.get(profile.id)
    live_failure = failures.get(profile.id)
    if proof is None and live_failure is None:
        live_failure = "profile_unprovisioned"
    quota, routeability, binding_conflict = _public_routeability(
        registry,
        profile,
        authentication,
        proof,
        live_failure,
        failures,
        observed_external,
    )
    return {
        **profile.public_dict(),
        "provisioned": provisioned,
        "auth_status": authentication,
        "active_leases": sum(lease.get("profile") == profile.id for lease in leases),
        "cooldown": read_cooldown(registry, profile.id),
        "quota": quota,
        "live_identity_failure": live_failure,
        "identity_binding_conflict": binding_conflict,
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
    summaries: list[dict[str, Any]] = []
    for provider_name in providers:
        provider_scope = [
            profile
            for profile in registry.profiles.values()
            if profile.provider == provider_name
            and profile.safety_policy == "worker"
            and profile.enabled
        ]
        proofs, failures, authentications, observed_external = _provider_live_snapshot(
            registry,
            provider_name,
            provider_scope,
        )
        profiles: list[dict[str, Any]] = []
        for profile in registry.profiles.values():
            if profile.provider != provider_name or pool not in profile.pools:
                continue
            if profile.safety_policy != "worker":
                profiles.append(
                    {
                        "profile": profile.id,
                        "enabled": False,
                        "provisioned": False,
                        "auth_status": "external-reserve",
                        "active_leases": 0,
                        "max_concurrent": profile.max_concurrent,
                        "quota_fresh": False,
                        "live_identity_failure": None,
                        "identity_binding_conflict": None,
                        "headroom_percent": None,
                        "cooldown": None,
                        "routeability": {
                            "eligible": False,
                            "mode": "blocked",
                            "reason": "external_reserve_never_routed",
                        },
                        "eligible": False,
                        "adjusted_headroom": None,
                    }
                )
                continue
            provisioned = profile_is_provisioned(profile)
            authentication = (
                authentications.get(profile.id, "unknown")
                if provisioned
                else "not-provisioned"
            )
            proof = proofs.get(profile.id)
            live_failure = failures.get(profile.id)
            if proof is None and live_failure is None:
                live_failure = (
                    "profile_disabled" if not profile.enabled else "profile_unprovisioned"
                )
            quota, routeability, binding_conflict = _public_routeability(
                registry,
                profile,
                authentication,
                proof,
                live_failure,
                failures,
                observed_external,
            )
            fresh = proof is not None
            headroom = quota.get("headroom_percent") if fresh else None
            cooldown = read_cooldown(registry, profile.id)
            capacity = counts[profile.id] < profile.max_concurrent
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
                    "cached_quota_fresh": read_quota(registry, profile.id).get("fresh") is True,
                    "quota_status": quota.get("status"),
                    "verified_recent": quota.get("verified_recent"),
                    "headroom_percent": headroom,
                    "adjusted_headroom_percent": adjusted,
                    "reserve_percent": profile.reserve_percent,
                    "cooldown": cooldown,
                    "live_identity_failure": live_failure,
                    "identity_binding_conflict": binding_conflict,
                    "eligible": eligible,
                    "routeability_reason": routeability["reason"],
                    "identity_fingerprint": quota.get("identity_fingerprint"),
                }
            )
        fresh_eligible = [item for item in profiles if item["eligible"] and item["quota_fresh"]]
        mode = "quota" if fresh_eligible else "unavailable"
        eligible_profiles = fresh_eligible
        summaries.append(
            {
                "provider": provider_name,
                "available": bool(eligible_profiles),
                "selection_mode": mode,
                "degraded": False,
                "best_adjusted_headroom_percent": max(
                    (float(item["adjusted_headroom_percent"]) for item in fresh_eligible),
                    default=None,
                ),
                "eligible_profiles": len(eligible_profiles),
                "live_identity_failures": failures,
                "identity_binding_conflicts": {
                    item["profile"]: item["identity_binding_conflict"]
                    for item in profiles
                    if item.get("identity_binding_conflict") is not None
                },
                "active_leases": sum(counts[item["profile"]] for item in profiles),
                "profiles": profiles,
            }
        )
    return {"schema": 1, "pool": pool, "providers": summaries}
