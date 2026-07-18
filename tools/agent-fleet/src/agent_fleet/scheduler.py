from __future__ import annotations

from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import ExitStack
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from .audit import append_audit
from .config import load_registry, verified_quota_runtime
from .cooldowns import read_cooldown
from .enrollment import recover_pending_codex_transactions
from .identity import (
    identity_binding_conflict,
    identity_conflict,
    refresh_provider_identity_anchors_if_due,
)
from .leases import active_leases, bind_lease, get_active_lease, new_lease, write_lease
from .locks import (
    provider_selection_refresh_lock,
    state_lock,
)
from .models import Profile, Registry
from .projects import lexical_path, resolve_trusted_project
from .providers import auth_status
from .provision import (
    profile_is_provisioned,
    profile_selection_ready,
    verified_provider_binary,
)
from .quota import (
    has_remote_identity_proof,
    inspect_credential_source_contract,
    probe_quota,
    quota_routeability,
    read_quota,
    store_quota,
)
from .util import atomic_write_json, read_private_json, task_key


def _last_selected(registry: Registry) -> dict[str, str]:
    path = registry.settings.state_dir / "selection.json"
    try:
        raw = read_private_json(path, label="selection state")
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
    quota: dict[str, Any] | None = None,
) -> dict[str, Any]:
    quota = quota if quota is not None else read_quota(registry, profile.id)
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
    workspace: Path,
    config_path: Path | None = None,
) -> dict[str, Any]:
    if profile_id is not None:
        requested = registry.require_profile(profile_id)
        if requested.safety_policy != "worker":
            raise ValueError(
                f"external reserve profile {requested.id} cannot participate in routing"
            )
    workspace = lexical_path(workspace)
    workspace_text = str(workspace)
    verified_quota_runtime(registry.settings)
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
        and profile.provider in scoped_provider_names
    ]

    def decide(
        authentication: dict[str, str],
        *,
        prune: bool,
        live_proofs: dict[str, dict[str, Any]] | None = None,
        live_failures: dict[str, str] | None = None,
    ) -> dict[str, Any]:
        live_proofs = live_proofs or {}
        live_failures = live_failures or {}
        leases = active_leases(registry, prune=prune)
        existing = get_active_lease(registry, task)
        if existing is not None:
            profile = registry.require_profile(str(existing.get("profile")))
            if existing.get("provider") != profile.provider:
                raise ValueError("task lease provider does not match its registered profile")
            if existing.get("workspace") != workspace_text:
                raise ValueError(
                    f"task already owns a lease for workspace {existing.get('workspace')}"
                )
            if recovery_reservation and existing.get("state") == "running":
                raise ValueError("task already has a live worker lease; refusing recovery")
            if existing.get("pool") != pool:
                raise ValueError(f"task already owns a lease in pool {existing.get('pool')}")
            if provider is not None and profile.provider != provider:
                raise ValueError(f"task is already bound to provider {profile.provider}")
            if profile_id is not None and profile.id != profile_id:
                raise ValueError(f"task is already bound to profile {profile.id}")
            if existing.get("state") != "running":
                if not dry_run and live_failures:
                    failed = ", ".join(
                        f"{profile_id}:{live_failures[profile_id]}"
                        for profile_id in sorted(live_failures)
                    )
                    raise ValueError(
                        "provider identity set is incomplete for sticky selection: " + failed
                    )
                if (
                    not profile.enabled
                    or not profile_is_provisioned(profile)
                    or not profile_selection_ready(registry, profile, workspace)
                ):
                    raise ValueError("sticky profile is disabled or unprovisioned")
                proof = live_proofs.get(profile.id)
                if not dry_run and proof is None:
                    raise ValueError(
                        "sticky profile has no same-attempt identity proof: "
                        + live_failures.get(profile.id, "probe_failed")
                    )
                quota = proof["quota"] if proof is not None else read_quota(registry, profile.id)
                routeability = quota_routeability(
                    registry,
                    profile,
                    quota=quota,
                    authentication=authentication.get(
                        profile.id,
                        auth_status(
                            profile,
                            binary=verified_provider_binary(registry, profile),
                        ),
                    ),
                    # The reservation already passed new-task policy. Binding it
                    # must recheck auth/readiness without applying reserve twice.
                    ignore_reserve=True,
                )
                if not routeability["eligible"]:
                    raise ValueError(f"sticky profile is not routeable: {routeability['reason']}")
                conflict = identity_conflict(registry, profile, quota)
                if conflict is not None:
                    raise ValueError(f"sticky profile identity is not routeable: {conflict}")
                if not dry_run:
                    binding_conflict = identity_binding_conflict(
                        registry,
                        profile,
                        quota,
                        proof["source_contract"],
                    )
                    if binding_conflict is not None:
                        raise ValueError(
                            "sticky profile identity binding is not routeable: "
                            f"{binding_conflict}"
                        )
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
                "workspace": workspace_text,
                "decision_reason": "sticky",
                "quota_fresh": quota.get("fresh"),
                "headroom_percent": quota.get("headroom_percent"),
                "active_lease_count": sum(lease.get("profile") == profile.id for lease in leases),
                "degraded": False,
                "dry_run": dry_run,
                "identity_proof": "snapshot-only" if dry_run else "same-attempt",
                "lease": existing,
            }

        if not dry_run and live_failures:
            failed = ", ".join(
                f"{profile_id}:{live_failures[profile_id]}"
                for profile_id in sorted(live_failures)
            )
            raise ValueError(
                "provider identity set is incomplete for this selection: " + failed
            )

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
                (
                    live_proofs[profile.id]["quota"]
                    if profile.id in live_proofs
                    else None
                ),
            )
            for profile in candidates
        ]
        for record in records:
            profile = record["profile"]
            if not dry_run and profile.id not in live_proofs:
                record["eligible"] = False
                record["selection_mode"] = "blocked"
                record["block_reason"] = (
                    "same_attempt_identity_probe_failed:"
                    + live_failures.get(profile.id, "probe_failed")
                )
                continue
            conflict = identity_conflict(registry, record["profile"], record["quota"])
            if conflict is not None:
                record["eligible"] = False
                record["selection_mode"] = "blocked"
                record["block_reason"] = (
                    "duplicate_provider_identity"
                    if conflict.startswith(("managed:", "base_", "desktop_"))
                    else conflict
                )
                continue
            if not dry_run:
                proof = live_proofs[profile.id]
                binding_conflict = identity_binding_conflict(
                    registry,
                    profile,
                    record["quota"],
                    proof["source_contract"],
                )
                if binding_conflict is not None:
                    record["eligible"] = False
                    record["selection_mode"] = "blocked"
                    record["block_reason"] = binding_conflict
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
            lease = new_lease(
                task,
                profile.id,
                pool,
                provider=profile.provider,
                workspace=workspace,
                pid=bind_pid,
            )
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
            "workspace": workspace_text,
            "decision_reason": reason,
            "quota_fresh": quota.get("fresh"),
            "headroom_percent": quota.get("headroom_percent"),
            "active_lease_count": counts[profile.id],
            "degraded": not selected["fresh"],
            "dry_run": dry_run,
            "identity_proof": "snapshot-only" if dry_run else "same-attempt",
            "lease": lease,
        }

    def validate_readiness() -> None:
        for provider_name in scoped_provider_names:
            resolve_trusted_project(registry, provider_name, workspace)
        for profile in scoped_profiles:
            if not profile_selection_ready(registry, profile, workspace):
                raise ValueError(f"profile is not ready for the registered workspace: {profile.id}")

    def require_current_registry(stage: str) -> None:
        if config_path is not None and load_registry(config_path) != registry:
            raise ValueError(f"registry changed {stage}; retry the lease request")

    def require_matching_live_binding() -> None:
        existing = get_active_lease(registry, task)
        if existing is None:
            return
        profile = registry.require_profile(str(existing.get("profile")))
        if existing.get("provider") != profile.provider:
            raise ValueError("task lease provider does not match its registered profile")
        if existing.get("workspace") != workspace_text:
            raise ValueError(f"task already owns a lease for workspace {existing.get('workspace')}")

    if dry_run:
        require_current_registry("before selection")
        require_matching_live_binding()
        validate_readiness()
        authentication = {profile.id: "authenticated" for profile in scoped_profiles}
        return decide(authentication, prune=False)

    try:
        with state_lock(
            registry.settings.state_dir,
            registry.settings.lock_stale_seconds,
        ):
            require_matching_live_binding()
        with ExitStack() as provider_locks:
            for provider_name in sorted(scoped_provider_names):
                provider_locks.enter_context(
                    provider_selection_refresh_lock(
                        registry.settings.state_dir,
                        provider_name,
                        registry.settings.lock_stale_seconds,
                    )
                )
            with state_lock(
                registry.settings.state_dir,
                registry.settings.lock_stale_seconds,
            ):
                require_matching_live_binding()
            require_current_registry("before provider refresh")
            validate_readiness()
            live_proofs: dict[str, dict[str, Any]] = {}
            live_failures: dict[str, str] = {}
            for provider_name in sorted(scoped_provider_names):
                recover_pending_codex_transactions(registry, provider_name)
                refresh_provider_identity_anchors_if_due(registry, provider_name)

            class SameAttemptProofFailure(ValueError):
                pass

            def prove(profile: Profile) -> tuple[dict[str, Any], dict[str, Any]]:
                source_before = inspect_credential_source_contract(registry, profile)
                quota = probe_quota(registry, profile)
                source_after = inspect_credential_source_contract(registry, profile)
                if source_before != source_after:
                    raise SameAttemptProofFailure("credential_source_changed")
                if not has_remote_identity_proof(quota):
                    reason = quota.get("reason")
                    safe_reason = (
                        reason
                        if isinstance(reason, str)
                        and 0 < len(reason) <= 128
                        and all(character.isalnum() or character in "_.:-" for character in reason)
                        else "fresh_remote_identity_proof_unavailable"
                    )
                    raise SameAttemptProofFailure(safe_reason)
                return quota, source_after

            if scoped_profiles:
                with ThreadPoolExecutor(max_workers=min(8, len(scoped_profiles))) as executor:
                    pending = {
                        executor.submit(prove, profile): profile for profile in scoped_profiles
                    }
                    for future in as_completed(pending):
                        profile = pending[future]
                        try:
                            quota, source_contract = future.result()
                            store_quota(registry, profile, quota)
                            live_proofs[profile.id] = {
                                "quota": read_quota(registry, profile.id),
                                "source_contract": source_contract,
                            }
                        except (OSError, TimeoutError, ValueError) as exc:
                            live_failures[profile.id] = (
                                str(exc)
                                if isinstance(exc, SameAttemptProofFailure)
                                else type(exc).__name__
                            )
            authentication = {
                profile.id: auth_status(
                    profile,
                    binary=verified_provider_binary(registry, profile),
                )
                for profile in scoped_profiles
            }
            with state_lock(
                registry.settings.state_dir,
                registry.settings.lock_stale_seconds,
            ):
                require_current_registry("during selection")
                return decide(
                    authentication,
                    prune=True,
                    live_proofs=live_proofs,
                    live_failures=live_failures,
                )
    except TimeoutError as exc:
        names = ", ".join(sorted(scoped_provider_names)) or "requested providers"
        raise ValueError(
            f"provider maintenance is in progress for {names}; refusing to start a new Fleet lease"
        ) from exc


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
    workspace: Path,
    config_path: Path | None = None,
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
        workspace=workspace,
        config_path=config_path,
    )
