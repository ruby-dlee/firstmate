from __future__ import annotations

from collections import Counter
from datetime import UTC, datetime
from typing import Any

from .audit import append_audit
from .cooldowns import read_cooldown
from .enrollment import recover_pending_codex_transactions
from .identity import identity_conflict, refresh_provider_identity_anchors_if_due
from .leases import active_leases, bind_lease, get_active_lease, new_lease, write_lease
from .locks import (
    provider_maintenance_active,
    provider_selection_refresh_lock,
    state_lock,
)
from .models import Profile, Registry
from .providers import auth_status
from .provision import profile_is_provisioned
from .quota import quota_routeability, read_quota, refresh_due_quotas
from .util import atomic_write_json, task_key


def _last_selected(registry: Registry) -> dict[str, str]:
    path = registry.settings.state_dir / "selection.json"
    try:
        import json

        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return raw if isinstance(raw, dict) else {}


def _stamp_selection(registry: Registry, profile_id: str) -> None:
    selected = _last_selected(registry)
    selected[profile_id] = datetime.now(UTC).isoformat()
    atomic_write_json(registry.settings.state_dir / "selection.json", selected)


def _candidate_record(
    registry: Registry,
    profile: Profile,
    active_count: int,
    last_selected: str,
    registry_order: int,
    authentication: str,
) -> dict[str, Any]:
    quota = read_quota(registry, profile.id)
    fresh = quota.get("fresh") is True
    headroom = quota.get("headroom_percent") if fresh else None
    routeability = quota_routeability(
        registry,
        profile,
        quota=quota,
        authentication=authentication,
    )
    return {
        "profile": profile,
        "active": active_count,
        "quota": quota,
        "fresh": fresh,
        "headroom": headroom,
        "eligible": routeability["eligible"],
        "selection_mode": routeability["mode"],
        "block_reason": routeability["reason"],
        "last_selected": last_selected,
        "registry_order": registry_order,
    }


def _choose(
    records: list[dict[str, Any]], penalty: int, *, ignore_reserve: bool = False
) -> dict[str, Any]:
    fresh = [
        record
        for record in records
        if record["fresh"]
        and (record["eligible"] or (ignore_reserve and record["block_reason"] == "quota_reserve"))
    ]
    if fresh:
        return max(
            fresh,
            key=lambda item: (
                float(item["headroom"])
                + (item["profile"].weight - 1) * 5
                - item["active"] * penalty,
                -item["active"],
                item["last_selected"] == "",
                _inverse_timestamp(item["last_selected"]),
                -item["registry_order"],
            ),
        )
    fallback = [record for record in records if record["eligible"] and not record["fresh"]]
    if not fallback:
        reasons = sorted({str(record["block_reason"]) for record in records})
        if reasons == ["quota_reserve"]:
            raise ValueError("all eligible profiles are at or below their quota reserve")
        detail = ", ".join(reasons) or "unknown"
        raise ValueError(f"no remotely verified profile is routeable: {detail}")
    return min(
        fallback,
        key=lambda item: (
            item["active"] / item["profile"].weight,
            item["last_selected"],
            item["registry_order"],
        ),
    )


def _inverse_timestamp(value: str) -> float:
    if not value:
        return float("inf")
    try:
        return -datetime.fromisoformat(value).timestamp()
    except ValueError:
        return float("inf")


def _select_and_acquire(
    registry: Registry,
    *,
    task: str,
    pool: str,
    provider: str | None = None,
    profile_id: str | None = None,
    bind_pid: int | None = None,
    dry_run: bool = False,
    explicit_profile: bool = False,
    ignore_reserve: bool = False,
    recovery_reservation: bool = False,
) -> dict[str, Any]:
    if ignore_reserve and profile_id is None:
        raise ValueError("ignoring quota reserve requires an explicit profile")
    if recovery_reservation and not ignore_reserve:
        raise ValueError("recovery reservation must ignore the new-task quota reserve")
    scoped_provider_names = {
        profile.provider
        for profile in registry.profiles.values()
        if profile.safety_policy == "worker"
        and (explicit_profile or pool in profile.pools)
        and (provider is None or profile.provider == provider)
        and (profile_id is None or profile.id == profile_id)
    }
    scoped_profiles = [
        profile
        for profile in registry.profiles.values()
        if profile.enabled
        and profile.safety_policy == "worker"
        and (explicit_profile or pool in profile.pools)
        and (provider is None or profile.provider == provider)
        and (profile_id is None or profile.id == profile_id)
        and profile_is_provisioned(profile)
    ]
    # Quota/identity writes share the provider maintenance interlock, but a
    # selection does not hold it while committing its lease. The state-lock
    # check below closes both races: maintenance either owns the marker first
    # (selection refuses) or observes the newly committed lease and aborts.
    for provider_name in sorted(scoped_provider_names):
        if provider_maintenance_active(
            registry.settings.state_dir,
            provider_name,
            registry.settings.lock_stale_seconds,
        ):
            raise ValueError(
                f"provider maintenance is in progress for {provider_name}; "
                "refusing to start a new Fleet lease"
            )
        try:
            with provider_selection_refresh_lock(
                registry.settings.state_dir,
                provider_name,
                registry.settings.lock_stale_seconds,
            ):
                recover_pending_codex_transactions(registry, provider_name)
                refresh_provider_identity_anchors_if_due(registry, provider_name)
                refresh_due_quotas(
                    registry,
                    [profile for profile in scoped_profiles if profile.provider == provider_name],
                )
        except TimeoutError as exc:
            raise ValueError(
                f"provider maintenance is in progress for {provider_name}; "
                "refusing to start a new Fleet lease"
            ) from exc
    authentication = {profile.id: auth_status(registry, profile) for profile in scoped_profiles}
    with state_lock(
        registry.settings.state_dir,
        registry.settings.lock_stale_seconds,
    ):
        blocked_provider = next(
            (
                provider_name
                for provider_name in sorted(scoped_provider_names)
                if provider_maintenance_active(
                    registry.settings.state_dir,
                    provider_name,
                    registry.settings.lock_stale_seconds,
                )
            ),
            None,
        )
        if blocked_provider is not None:
            raise ValueError(
                f"provider maintenance is in progress for {blocked_provider}; "
                "refusing to start a new Fleet lease"
            )
        leases = active_leases(registry, prune=True)
        existing = get_active_lease(registry, task)
        if existing is not None:
            profile = registry.require_profile(str(existing.get("profile")))
            if recovery_reservation and existing.get("state") == "running":
                raise ValueError("task already has a live worker lease; refusing recovery")
            if existing.get("pool") != pool:
                raise ValueError(f"task already owns a lease in pool {existing.get('pool')}")
            if provider is not None and profile.provider != provider:
                raise ValueError(f"task is already bound to provider {profile.provider}")
            if profile_id is not None and profile.id != profile_id:
                raise ValueError(f"task is already bound to profile {profile.id}")
            if existing.get("state") != "running":
                if not profile.enabled or not profile_is_provisioned(profile):
                    raise ValueError("sticky profile is disabled or unprovisioned")
                quota = read_quota(registry, profile.id)
                routeability = quota_routeability(
                    registry,
                    profile,
                    quota=quota,
                    authentication=authentication.get(profile.id, auth_status(registry, profile)),
                    # The reservation already passed new-task policy. Binding it
                    # must recheck auth/readiness without applying reserve twice.
                    ignore_reserve=True,
                )
                if not routeability["eligible"]:
                    raise ValueError(f"sticky profile is not routeable: {routeability['reason']}")
                conflict = identity_conflict(registry, profile, quota)
                if conflict is not None:
                    raise ValueError(f"sticky profile identity is not routeable: {conflict}")
            else:
                quota = read_quota(registry, profile.id)
            if bind_pid is not None and not dry_run:
                owner_pid = existing.get("pid")
                if (
                    existing.get("state") == "running"
                    and isinstance(owner_pid, int)
                    and owner_pid != bind_pid
                ):
                    raise ValueError(f"task lease is already owned by live process {owner_pid}")
                existing = bind_lease(registry, existing, bind_pid)
                append_audit(
                    registry,
                    "lease-bound",
                    {
                        "profile": profile.id,
                        "provider": profile.provider,
                        "pool": pool,
                        "task_key": task_key(task),
                    },
                )
            return {
                "schema": 1,
                "task": task,
                "pool": pool,
                "profile": profile.id,
                "provider": profile.provider,
                "decision_reason": "sticky",
                "quota_fresh": quota.get("fresh"),
                "headroom_percent": quota.get("headroom_percent"),
                "active_lease_count": sum(lease.get("profile") == profile.id for lease in leases),
                "degraded": False,
                "dry_run": dry_run,
                "lease": existing,
            }

        counts = Counter(str(lease.get("profile")) for lease in leases)
        candidates = [
            profile
            for profile in registry.profiles.values()
            if profile.enabled
            and profile.safety_policy == "worker"
            and (explicit_profile or pool in profile.pools)
            and (provider is None or profile.provider == provider)
            and (profile_id is None or profile.id == profile_id)
            and profile_is_provisioned(profile)
            and read_cooldown(registry, profile.id) is None
            and counts[profile.id] < profile.max_concurrent
        ]
        if not candidates:
            constraint = profile_id or provider or pool
            raise ValueError(f"no enabled, provisioned profile has capacity for {constraint}")
        last_selected = _last_selected(registry)
        registry_order = {profile_id: index for index, profile_id in enumerate(registry.profiles)}
        records = [
            _candidate_record(
                registry,
                profile,
                counts[profile.id],
                last_selected.get(profile.id, ""),
                registry_order[profile.id],
                authentication.get(profile.id, "unknown"),
            )
            for profile in candidates
        ]
        for record in records:
            conflict = identity_conflict(registry, record["profile"], record["quota"])
            if conflict is not None:
                record["eligible"] = False
                record["selection_mode"] = "blocked"
                record["block_reason"] = (
                    "duplicate_provider_identity"
                    if conflict.startswith(("managed:", "base_", "desktop_"))
                    else conflict
                )
        selected = _choose(
            records,
            registry.settings.active_lease_penalty,
            ignore_reserve=ignore_reserve,
        )
        profile = selected["profile"]
        quota = selected["quota"]
        if ignore_reserve:
            reason = "sticky-resume"
        else:
            reason = "quota" if selected["fresh"] else "verified-fallback"
        lease = None
        if not dry_run:
            lease = new_lease(task, profile.id, pool, pid=bind_pid)
            write_lease(registry, lease)
            _stamp_selection(registry, profile.id)
            append_audit(
                registry,
                "lease-selected",
                {
                    "profile": profile.id,
                    "provider": profile.provider,
                    "pool": pool,
                    "task_key": task_key(task),
                    "decision_reason": reason,
                    "lease_state": lease["state"],
                },
            )
        return {
            "schema": 1,
            "task": task,
            "pool": pool,
            "profile": profile.id,
            "provider": profile.provider,
            "decision_reason": reason,
            "quota_fresh": quota.get("fresh"),
            "headroom_percent": quota.get("headroom_percent"),
            "active_lease_count": counts[profile.id],
            "degraded": not selected["fresh"],
            "dry_run": dry_run,
            "lease": lease,
        }


def select_and_acquire(
    registry: Registry,
    *,
    task: str,
    pool: str,
    provider: str | None = None,
    profile_id: str | None = None,
    bind_pid: int | None = None,
    dry_run: bool = False,
    explicit_profile: bool = False,
    ignore_reserve: bool = False,
    recovery_reservation: bool = False,
) -> dict[str, Any]:
    return _select_and_acquire(
        registry,
        task=task,
        pool=pool,
        provider=provider,
        profile_id=profile_id,
        bind_pid=bind_pid,
        dry_run=dry_run,
        explicit_profile=explicit_profile,
        ignore_reserve=ignore_reserve,
        recovery_reservation=recovery_reservation,
    )
