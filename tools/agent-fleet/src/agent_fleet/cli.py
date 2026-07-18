from __future__ import annotations

import argparse
import os
import sys
from collections.abc import Callable, Iterator
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import ExitStack, contextmanager
from dataclasses import replace
from pathlib import Path
from typing import Any

from . import __version__
from .audit import append_audit, read_audit
from .config import (
    initial_registry,
    load_registry,
    save_registry,
    set_profile_enabled,
    set_profile_safety_policy,
    with_profile,
    with_provider,
    without_profile,
)
from .cooldowns import clear_cooldown, set_cooldown
from .doctor import run_doctor
from .enrollment import (
    recover_pending_codex_transactions,
)
from .identity import (
    adopt_provider_identity_bundle,
    identity_binding_conflict,
    identity_conflict,
    refresh_provider_identity_anchors,
    verify_identity_bundle,
)
from .leases import active_leases, release_lease
from .locks import provider_enrollment_lock, state_lock
from .models import PROFILE_SAFETY_POLICIES, SUPPORTED_PROVIDERS, Profile, Registry
from .output import emit, preflight
from .paths import default_config_path, expand_path
from .projects import (
    lexical_path,
    register_trusted_project,
    remove_trusted_project,
)
from .providers import (
    WorkerArguments,
    auth_probe,
    auth_status,
    managed_argv,
    provider_environment,
    resume_argv,
    validate_worker_arguments,
)
from .provision import (
    prepare_profile_launch,
    profile_is_provisioned,
    provision_profile,
    verified_agent_fleet_hook_entrypoint,
    verified_provider_binary,
)
from .quota import (
    has_remote_identity_proof,
    inspect_credential_source_contract,
    probe_quota,
    quota_routeability,
    read_quota,
    refresh_quota,
    store_quota,
)
from .scheduler import select_and_acquire
from .sessions import (
    get_session,
    read_hook_payload,
    record_session_from_hook,
    record_turn_end_from_hook,
    remove_session,
    validate_turn_end_path,
)
from .status import pool_status, profile_status
from .util import validate_id


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="agent-fleet")
    parser.add_argument("--config", type=Path, default=default_config_path())
    parser.add_argument(
        "--format",
        choices=("toon", "json", "human"),
        default=os.environ.get("AGENT_FLEET_FORMAT", "toon"),
    )
    commands = parser.add_subparsers(dest="command", required=True)

    init = commands.add_parser("init", help="create a disabled profile registry")
    init.add_argument("--claude", type=int, default=0)
    init.add_argument("--codex", type=int, default=0)

    project = commands.add_parser("project")
    project_commands = project.add_subparsers(dest="project_command", required=True)
    project_list = project_commands.add_parser("list")
    project_list.add_argument("--provider", choices=SUPPORTED_PROVIDERS)
    for name in ("register", "remove"):
        item = project_commands.add_parser(name)
        item.add_argument("path", type=Path)
        item.add_argument("--provider", choices=SUPPORTED_PROVIDERS, required=True)

    profile = commands.add_parser("profile")
    profile_commands = profile.add_subparsers(dest="profile_command", required=True)
    profile_commands.add_parser("list")
    add = profile_commands.add_parser("add")
    add.add_argument("profile_id")
    add.add_argument("--provider", choices=SUPPORTED_PROVIDERS, required=True)
    add.add_argument("--home", type=Path)
    add.add_argument("--pool", action="append", dest="pools")
    add.add_argument("--weight", type=int, default=1)
    add.add_argument("--max-concurrent", type=int, default=2)
    add.add_argument("--reserve-percent", type=int, default=15)
    add.add_argument(
        "--safety-policy",
        choices=PROFILE_SAFETY_POLICIES,
        default="worker",
    )
    remove = profile_commands.add_parser("remove")
    remove.add_argument("profile_id")
    for name in ("enable", "disable"):
        item = profile_commands.add_parser(name)
        item.add_argument("profile_id")
    for name in ("login", "enroll"):
        item = profile_commands.add_parser(
            name,
            help="verify an already pinned credential without invoking provider login",
        )
        item.add_argument("profile_id")
    identity = profile_commands.add_parser("identity")
    identity_commands = identity.add_subparsers(dest="identity_command", required=True)
    identity_adopt = identity_commands.add_parser("adopt")
    identity_adopt.add_argument("profile_id")
    identity_adopt.add_argument("--allow-keychain-prompt", action="store_true")
    for name in ("provision", "status", "auth-status", "verify"):
        item = profile_commands.add_parser(name)
        item.add_argument("profile_id", nargs="?")
        item.add_argument("--all", action="store_true")
        if name == "verify":
            item.add_argument("--allow-keychain-prompt", action="store_true")
    cooldown = profile_commands.add_parser("cooldown")
    cooldown.add_argument("profile_id")
    cooldown.add_argument("--seconds", type=int, required=True)
    cooldown.add_argument("--reason", required=True)
    cooldown_clear = profile_commands.add_parser("cooldown-clear")
    cooldown_clear.add_argument("profile_id")
    policy = profile_commands.add_parser("policy")
    policy.add_argument("profile_id")
    policy.add_argument("--safety-policy", choices=PROFILE_SAFETY_POLICIES, required=True)

    pool = commands.add_parser("pool")
    pool_commands = pool.add_subparsers(dest="pool_command", required=True)
    pool_status_parser = pool_commands.add_parser("status")
    pool_status_parser.add_argument("--pool", required=True)
    pool_status_parser.add_argument("--provider", choices=SUPPORTED_PROVIDERS)

    choose = commands.add_parser("choose")
    _add_route_arguments(choose)
    choose.add_argument("--dry-run", action="store_true")

    quota = commands.add_parser("quota")
    quota_commands = quota.add_subparsers(dest="quota_command", required=True)
    for name in ("refresh", "show"):
        item = quota_commands.add_parser(name)
        item.add_argument("profile_id", nargs="?")
        item.add_argument("--all", action="store_true")
        if name == "refresh":
            item.add_argument("--allow-keychain-prompt", action="store_true")

    lease = commands.add_parser("lease")
    lease_commands = lease.add_subparsers(dest="lease_command", required=True)
    lease_choose = lease_commands.add_parser("choose")
    _add_route_arguments(lease_choose)
    recover = lease_commands.add_parser("recover")
    recover.add_argument("--task", required=True)
    recover.add_argument("--workspace", type=Path, required=True)
    acquire = lease_commands.add_parser("acquire")
    acquire.add_argument("--profile", required=True)
    acquire.add_argument("--task", required=True)
    acquire.add_argument("--pool")
    acquire.add_argument("--workspace", type=Path, required=True)
    lease_commands.add_parser("list")
    release = lease_commands.add_parser("release")
    release.add_argument("--task", required=True)
    release.add_argument("--force", action="store_true")

    execute = commands.add_parser("exec")
    _add_route_arguments(execute, required=False)
    execute.add_argument("--turn-end", type=Path)
    execute.add_argument("provider_args", nargs=argparse.REMAINDER)

    resume = commands.add_parser("resume")
    resume.add_argument("--task")
    resume.add_argument("--profile")
    resume.add_argument("--session")
    resume.add_argument("--pool")
    resume.add_argument("--workspace", type=Path)
    resume.add_argument("--turn-end", type=Path)
    resume.add_argument("provider_args", nargs=argparse.REMAINDER)

    session = commands.add_parser("session")
    session_commands = session.add_subparsers(dest="session_command", required=True)
    for name in ("status", "remove"):
        item = session_commands.add_parser(name)
        item.add_argument("--task", required=True)

    hook = commands.add_parser("hook")
    hook_commands = hook.add_subparsers(dest="hook_command", required=True)
    hook_commands.add_parser("session-start")
    hook_commands.add_parser("turn-end")

    doctor = commands.add_parser("doctor")
    doctor.add_argument("--workspace", type=Path)
    doctor.add_argument("--project", type=Path)
    commands.add_parser("status")
    commands.add_parser("contract")
    commands.add_parser("version")
    audit = commands.add_parser("audit")
    audit.add_argument("--limit", type=int, default=100)
    return parser


def _add_route_arguments(
    parser: argparse.ArgumentParser,
    *,
    required: bool = True,
) -> None:
    parser.add_argument("--task", required=required)
    parser.add_argument("--pool", required=required)
    parser.add_argument("--provider", choices=SUPPORTED_PROVIDERS)
    parser.add_argument("--profile")
    parser.add_argument("--workspace", type=Path, required=required)


def _task(value: str) -> str:
    if not value.strip() or len(value) > 512 or any(ord(char) < 32 for char in value):
        raise ValueError("task id must be 1-512 printable characters")
    return value


def _strip_separator(values: list[str]) -> list[str]:
    return values[1:] if values[:1] == ["--"] else values


def _validate_candidate_arguments(
    registry: Registry,
    arguments: list[str],
    *,
    pool: str,
    provider: str | None,
    profile_id: str | None,
) -> dict[str, WorkerArguments]:
    if profile_id is not None:
        candidates = [registry.require_profile(profile_id)]
    else:
        candidates = [
            profile
            for profile in registry.profiles.values()
            if profile.enabled
            and profile.safety_policy == "worker"
            and pool in profile.pools
            and (provider is None or profile.provider == provider)
        ]
    parsed: dict[str, WorkerArguments] = {}
    for profile in candidates:
        if provider is not None and profile.provider != provider:
            continue
        if profile.provider in parsed:
            continue
        parsed[profile.provider] = validate_worker_arguments(
            profile,
            arguments,
            operation="exec",
        )
    return parsed


def _mutate(registry: Registry, operation: Callable[[Registry], Registry], path: Path) -> Registry:
    with state_lock(
        registry.settings.state_dir,
        registry.settings.lock_stale_seconds,
    ):
        current = load_registry(path)
        if current != registry:
            raise ValueError("registry changed before mutation; retry the command")
        updated = operation(current)
        save_registry(updated, path)
        return updated


@contextmanager
def _provider_maintenance(
    registry: Registry,
    config_path: Path,
    providers: set[str],
    *,
    require_disabled: tuple[str, ...] = (),
) -> Iterator[Registry]:
    """Serialize provider maintenance and re-read mutable registry state."""

    try:
        with ExitStack() as locks:
            for provider in sorted(providers):
                locks.enter_context(
                    provider_enrollment_lock(
                        registry.settings.state_dir,
                        provider,
                        registry.settings.lock_stale_seconds,
                    )
                )
            with state_lock(
                registry.settings.state_dir,
                registry.settings.lock_stale_seconds,
            ):
                current = load_registry(config_path)
                if current != registry:
                    raise ValueError(
                        "registry changed before provider maintenance; retry the command"
                    )
                for profile_id in require_disabled:
                    if current.require_profile(profile_id).enabled:
                        raise ValueError(f"disable {profile_id} before provider maintenance")
            for provider in sorted(providers):
                recover_pending_codex_transactions(current, provider)
            yield current
    except TimeoutError as exc:
        names = ", ".join(sorted(providers))
        raise ValueError(f"provider maintenance is already in progress for {names}") from exc


def _profiles_for(registry: Registry, profile_id: str | None, all_profiles: bool) -> list[Profile]:
    if all_profiles:
        if profile_id is not None:
            raise ValueError("use a profile id or --all, not both")
        return [registry.profiles[key] for key in sorted(registry.profiles)]
    if profile_id is None:
        raise ValueError("profile id is required unless --all is used")
    return [registry.require_profile(profile_id)]


def _contract() -> dict[str, Any]:
    return {
        "contract_version": 2,
        "cli_version": __version__,
        "formats": ["json", "toon", "human"],
        "selection_fields": [
            "profile",
            "provider",
            "pool",
            "workspace",
            "decision_reason",
            "quota_fresh",
            "headroom_percent",
            "active_lease_count",
            "degraded",
        ],
        "commands": {
            "pool_summary": "pool status --pool <pool> [--provider <provider>]",
            "dry_run": "choose --pool <pool> --task <task> --workspace <path> --dry-run",
            "atomic_choose": "lease choose --pool <pool> --task <task> --workspace <path>",
            "explicit_acquire": (
                "lease acquire --profile <profile> --task <task> --workspace <path>"
            ),
            "recover": "lease recover --task <task> --workspace <path>",
            "release": "lease release --task <task>",
            "exec": (
                "exec --profile <profile> --task <task> --pool <pool> --workspace <path> "
                "--turn-end <path> -- <argv>"
            ),
            "resume_task": ("resume --task <task> --workspace <path> --turn-end <path> -- <argv>"),
            "resume_explicit": "managed task/session mapping required",
            "session_status": "session status --task <task>",
            "session_remove": "session remove --task <task>",
            "profile_enroll": "profile enroll <profile> (verified pinned no-op only)",
            "profile_verify": "profile verify <profile>|--all",
            "project_register": "project register --provider <provider> <git-worktree>",
            "project_remove": "project remove --provider <provider> <git-worktree>",
            "project_list": "project list [--provider <provider>]",
        },
    }


def _credential_is_remotely_verified(quota: dict[str, Any]) -> bool:
    return has_remote_identity_proof(quota)


def _cached_credential_proof_is_usable(quota: dict[str, Any]) -> bool:
    fingerprint = quota.get("identity_fingerprint")
    return (
        quota.get("verified_recent") is True
        and quota.get("status") not in {"auth_required", "rate_limited", "error"}
        and quota.get("headroom_percent") is not None
        and isinstance(fingerprint, str)
        and len(fingerprint) == 64
    )


def _verification_reason(result: dict[str, Any]) -> str:
    return str(
        result.get("identity_binding_conflict")
        or result.get("identity_conflict")
        or result.get("remote_reason")
        or result.get("remote_status")
        or result.get("local_auth")
        or "remote_unverified"
    )


def _evaluate_remote_profile(
    registry: Registry,
    profile: Profile,
    authentication: str,
    quota: dict[str, Any],
    *,
    require_complete_worker_set: bool = True,
    credential_source_contract: dict[str, Any] | None = None,
    require_binding: bool = True,
) -> dict[str, Any]:
    conflict = identity_conflict(
        registry,
        profile,
        quota,
        require_complete_worker_set=require_complete_worker_set,
    )
    route_conflict = identity_conflict(registry, profile, quota)
    binding_conflict = (
        identity_binding_conflict(
            registry,
            profile,
            quota,
            credential_source_contract,
        )
        if require_binding
        else None
    )
    remotely_verified = _credential_is_remotely_verified(quota)
    credential_verified = (
        authentication == "authenticated"
        and remotely_verified
        and conflict is None
        and binding_conflict is None
    )
    routeability = quota_routeability(
        registry,
        profile,
        quota=quota,
        authentication=authentication,
        ignore_reserve=True,
    )
    if route_conflict is not None or binding_conflict is not None:
        routeability = {
            "eligible": False,
            "mode": "blocked",
            "reason": binding_conflict or route_conflict,
        }
    return {
        "profile": profile.id,
        "provider": profile.provider,
        "local_auth": authentication,
        "remote_status": quota.get("status"),
        "remote_reason": quota.get("reason"),
        "credential_verified": credential_verified,
        "identity_conflict": conflict,
        "identity_binding_conflict": binding_conflict,
        "identity_set_block": route_conflict,
        "routeability": routeability,
    }


def _verify_remote_profile(
    registry: Registry,
    profile: Profile,
    *,
    allow_keychain_prompt: bool,
    require_complete_worker_set: bool = False,
) -> dict[str, Any]:
    provision_profile(registry, profile)
    source_before = inspect_credential_source_contract(
        registry,
        profile,
        allow_keychain_prompt=allow_keychain_prompt,
    )
    authentication = str(
        auth_probe(profile, binary=verified_provider_binary(registry, profile))["status"]
    )
    refresh_provider_identity_anchors(
        registry,
        profile.provider,
        allow_keychain_prompt=allow_keychain_prompt,
    )
    candidate = probe_quota(
        registry,
        profile,
        allow_keychain_prompt=allow_keychain_prompt,
    )
    source_after = inspect_credential_source_contract(
        registry,
        profile,
        allow_keychain_prompt=allow_keychain_prompt,
    )
    if source_before != source_after:
        raise ValueError("credential source changed during remote verification")
    store_quota(registry, profile, candidate)
    quota = read_quota(registry, profile.id)
    return _evaluate_remote_profile(
        registry,
        profile,
        authentication,
        quota,
        require_complete_worker_set=require_complete_worker_set,
        credential_source_contract=source_after,
    )


def _provider_has_active_lease(registry: Registry, provider: str) -> bool:
    for lease in active_leases(registry):
        profile_id = lease.get("profile")
        if (
            isinstance(profile_id, str)
            and registry.require_profile(profile_id).provider == provider
        ):
            return True
    return False


def _run_profile_enrollment(
    registry: Registry,
    profile: Profile,
    config_path: Path,
) -> dict[str, Any]:
    if profile.safety_policy != "worker":
        raise ValueError(
            f"profile {profile.id} is {profile.safety_policy} capacity and must never be enrolled"
        )
    try:
        enrollment_lock = provider_enrollment_lock(
            registry.settings.state_dir,
            profile.provider,
            registry.settings.lock_stale_seconds,
            timeout=0.1,
        )
        with enrollment_lock:
            expected_registry = registry

            def safety_recheck() -> None:
                with state_lock(
                    expected_registry.settings.state_dir,
                    expected_registry.settings.lock_stale_seconds,
                ):
                    observed = load_registry(config_path)
                    if observed != expected_registry:
                        raise ValueError(
                            "registry changed during provider enrollment; "
                            "credentials were not committed"
                        )
                    enabled = sorted(
                        candidate.id
                        for candidate in observed.profiles.values()
                        if candidate.provider == profile.provider and candidate.enabled
                    )
                    if enabled:
                        raise ValueError(
                            f"disable every {profile.provider} profile before enrollment: "
                            + ", ".join(enabled)
                        )
                    if _provider_has_active_lease(observed, profile.provider):
                        raise ValueError(
                            f"refusing {profile.provider} login while any same-provider "
                            "Fleet lease is active"
                        )

            with state_lock(
                registry.settings.state_dir,
                registry.settings.lock_stale_seconds,
            ):
                current = load_registry(config_path)
                if current != registry:
                    raise ValueError(
                        "registry changed before provider enrollment; retry the command"
                    )
                current_profile = current.require_profile(profile.id)
                if current_profile.provider != profile.provider:
                    raise ValueError(
                        "profile provider changed before enrollment; retry the command"
                    )
                profile = current_profile
                if profile.safety_policy != "worker":
                    raise ValueError(
                        f"profile {profile.id} is {profile.safety_policy} capacity "
                        "and must never be enrolled"
                    )
                enabled = sorted(
                    candidate.id
                    for candidate in current.profiles.values()
                    if candidate.provider == profile.provider and candidate.enabled
                )
                if enabled:
                    raise ValueError(
                        f"disable every {profile.provider} profile before enrollment: "
                        + ", ".join(enabled)
                    )
                if _provider_has_active_lease(current, profile.provider):
                    raise ValueError(
                        f"refusing {profile.provider} login while any same-provider "
                        "Fleet lease is active"
                    )
            recover_pending_codex_transactions(current, profile.provider)
            registry = current
            expected_registry = current
            provision_profile(registry, profile)
            existing_source = inspect_credential_source_contract(
                registry,
                profile,
                allow_absent=True,
            )
            if existing_source.get("kind") == "absent":
                raise ValueError(
                    "credentials are absent; sealed enrollment refuses before provider/browser "
                    "login and requires future transactional maintenance tooling"
                )
            if existing_source.get("kind") != "absent":
                refresh_provider_identity_anchors(registry, profile.provider)
                try:
                    existing_quota = probe_quota(registry, profile)
                except (OSError, TimeoutError, ValueError):
                    existing_quota = {}
                source_after = inspect_credential_source_contract(registry, profile)
                if existing_source != source_after:
                    raise ValueError("credential source changed during enrollment preflight")
                existing_conflict = (
                    identity_conflict(
                        registry,
                        profile,
                        existing_quota,
                        require_complete_worker_set=False,
                    )
                    if has_remote_identity_proof(existing_quota)
                    else "remote_identity_unverified"
                )
                binding_conflict = (
                    identity_binding_conflict(
                        registry,
                        profile,
                        existing_quota,
                        source_after,
                    )
                    if existing_conflict is None
                    else existing_conflict
                )
                if binding_conflict is None:
                    store_quota(registry, profile, existing_quota)
                    return {
                        "profile": profile.id,
                        "provider": profile.provider,
                        "credential_verified": True,
                        "identity_binding_conflict": None,
                        "no_op": True,
                        "provider_login_invoked": False,
                        "enabled": False,
                    }
                if (
                    has_remote_identity_proof(existing_quota)
                    and existing_conflict is None
                    and binding_conflict != "identity_binding_remote_mismatch"
                ):
                    raise ValueError(
                        f"existing credentials for {profile.id} are fresh but not durably "
                        f"pinned ({binding_conflict}); run browser-free `agent-fleet profile "
                        f"identity adopt {profile.id}` while the provider is disabled and "
                        "drained; no provider/browser login was invoked"
                    )
                raise ValueError(
                    f"existing credentials for {profile.id} cannot be accepted as a pinned "
                    f"repeat ({binding_conflict}); credential replacement is disabled because "
                    "this release cannot atomically roll back provider-side token rotation. "
                    "Use future transactional maintenance tooling; no provider/browser login "
                    "was invoked"
                )
    except TimeoutError as exc:
        raise ValueError(
            f"another {profile.provider} enrollment or Fleet selection is in progress"
        ) from exc


def _verify_provider_enable_set(
    registry: Registry,
    target: Profile,
) -> list[dict[str, Any]]:
    """Require same-attempt proof for every routeable provider worker plus target."""

    profiles = sorted(
        (
            profile
            for profile in registry.profiles.values()
            if profile.provider == target.provider
            and profile.safety_policy == "worker"
            and (profile.enabled or profile.id == target.id)
        ),
        key=lambda profile: profile.id,
    )
    for profile in profiles:
        if not profile_is_provisioned(profile):
            raise ValueError(
                f"provision every enabled {target.provider} worker before enabling: "
                f"{profile.id}"
            )
    refresh_provider_identity_anchors(registry, target.provider)

    def prove(profile: Profile) -> tuple[dict[str, Any], dict[str, Any], str]:
        source_before = inspect_credential_source_contract(registry, profile)
        quota = probe_quota(registry, profile)
        source_after = inspect_credential_source_contract(registry, profile)
        if source_before != source_after:
            raise ValueError("credential_source_changed")
        if not has_remote_identity_proof(quota):
            reason = quota.get("reason")
            raise ValueError(
                str(reason) if isinstance(reason, str) else "fresh_identity_proof_unavailable"
            )
        authentication = auth_status(
            profile,
            binary=verified_provider_binary(registry, profile),
        )
        return quota, source_after, authentication

    proofs: dict[str, tuple[dict[str, Any], dict[str, Any], str]] = {}
    failures: dict[str, str] = {}
    with ThreadPoolExecutor(max_workers=min(8, len(profiles))) as executor:
        pending = {executor.submit(prove, profile): profile for profile in profiles}
        for future in as_completed(pending):
            profile = pending[future]
            try:
                proofs[profile.id] = future.result()
            except (OSError, TimeoutError, ValueError) as exc:
                failures[profile.id] = str(exc) or type(exc).__name__
    if failures:
        detail = ", ".join(
            f"{profile_id}:{failures[profile_id]}" for profile_id in sorted(failures)
        )
        raise ValueError(f"provider enable proof set is incomplete: {detail}")

    fingerprints: dict[str, str] = {}
    for profile in profiles:
        fingerprint = str(proofs[profile.id][0]["identity_fingerprint"])
        if fingerprint in fingerprints:
            raise ValueError(
                "provider enable proof set contains duplicate identities: "
                f"{fingerprints[fingerprint]}, {profile.id}"
            )
        fingerprints[fingerprint] = profile.id

    # Re-probe external/default identities after the worker proofs. The quota
    # caches written below are disposable snapshots; neither enable nor route
    # selection trusts them without another same-attempt source-attested proof.
    refresh_provider_identity_anchors(registry, target.provider)
    bundle = verify_identity_bundle(
        registry,
        target.provider,
        compare_live_external=True,
    )
    if bundle != {
        "provider": target.provider,
        "status": "verified",
        "reason": None,
    }:
        raise ValueError(
            "provider identity bundle is not valid for enable: "
            f"{bundle.get('reason', 'invalid')}"
        )
    for profile in profiles:
        store_quota(registry, profile, proofs[profile.id][0])

    results: list[dict[str, Any]] = []
    for profile in profiles:
        quota, source_contract, authentication = proofs[profile.id]
        result = _evaluate_remote_profile(
            registry,
            profile,
            authentication,
            quota,
            require_complete_worker_set=False,
            credential_source_contract=source_contract,
        )
        if not result["credential_verified"] or not result["routeability"]["eligible"]:
            raise ValueError(
                f"provider worker is not routeable for enable: {profile.id}:"
                f"{_verification_reason(result)}"
            )
        results.append(result)
    return results


def _run(args: argparse.Namespace) -> Any | None:
    config_path = expand_path(args.config)
    if args.command == "version":
        return {"cli_version": __version__, "contract_version": 2}
    if args.command == "contract":
        return _contract()
    if args.command == "init":
        if config_path.exists():
            raise ValueError(f"registry already exists: {config_path}")
        registry = initial_registry(args.claude, args.codex)
        save_registry(registry, config_path)
        return {
            "registry": str(config_path),
            "profiles": [registry.profiles[key].public_dict() for key in sorted(registry.profiles)],
            "enabled": 0,
        }

    registry = load_registry(config_path)
    if args.command == "project":
        if args.project_command == "list":
            providers = [args.provider] if args.provider else list(SUPPORTED_PROVIDERS)
            return {
                "providers": [
                    {
                        "provider": provider,
                        "trusted_projects": [
                            str(path)
                            for path in registry.require_provider(provider).trusted_projects
                        ],
                    }
                    for provider in providers
                ]
            }
        with _provider_maintenance(registry, config_path, {args.provider}) as current:
            if _provider_has_active_lease(current, args.provider):
                raise ValueError(
                    f"refusing {args.provider} project maintenance while a Fleet lease is active"
                )
            provider = current.require_provider(args.provider)
            projects = set(provider.trusted_projects)
            if args.project_command == "register":
                projects.add(register_trusted_project(args.path))
            else:
                projects = set(remove_trusted_project(current, args.provider, args.path))
            updated = _mutate(
                current,
                lambda item: with_provider(
                    item,
                    replace(provider, trusted_projects=tuple(sorted(projects, key=str))),
                ),
                config_path,
            )
        return {
            "provider": args.provider,
            "trusted_projects": [
                str(path) for path in updated.require_provider(args.provider).trusted_projects
            ],
        }

    if args.command == "profile":
        if args.profile_command == "list":
            return {
                "profiles": [
                    registry.profiles[key].public_dict() for key in sorted(registry.profiles)
                ]
            }
        if args.profile_command == "add":
            profile_id = validate_id(args.profile_id, "profile id")
            with _provider_maintenance(
                registry,
                config_path,
                {args.provider},
            ) as current:
                if profile_id in current.profiles:
                    raise ValueError(f"profile already exists: {profile_id}")
                default_pools = [f"{args.provider}-manual"]
                if args.safety_policy == "worker":
                    default_pools.insert(0, f"{args.provider}-crew")
                pools = args.pools or default_pools
                pools = [validate_id(pool, "pool id") for pool in pools]
                if args.safety_policy != "worker" and f"{args.provider}-crew" in pools:
                    raise ValueError(
                        f"{args.safety_policy} profiles cannot join the worker crew pool"
                    )
                if args.weight < 1 or args.max_concurrent < 1:
                    raise ValueError("weight and max-concurrent must be positive integers")
                if not 0 <= args.reserve_percent <= 100:
                    raise ValueError("reserve-percent must be between 0 and 100")
                home = expand_path(
                    args.home
                    or current.settings.share_dir / "accounts" / args.provider / profile_id
                )
                profile = Profile(
                    id=profile_id,
                    provider=args.provider,
                    home=home,
                    pools=tuple(pools),
                    enabled=False,
                    weight=args.weight,
                    max_concurrent=args.max_concurrent,
                    reserve_percent=args.reserve_percent,
                    safety_policy=args.safety_policy,
                )
                updated = _mutate(
                    current,
                    lambda item: with_profile(item, profile),
                    config_path,
                )
            return updated.require_profile(profile_id).public_dict()
        if args.profile_command == "remove":
            profile = registry.require_profile(args.profile_id)
            if profile.safety_policy == "desktop_shared":
                raise ValueError(
                    f"desktop_shared profile {profile.id} cannot be removed by the live CLI"
                )
            with _provider_maintenance(
                registry,
                config_path,
                {profile.provider},
                require_disabled=(profile.id,),
            ) as current:
                if any(lease.get("profile") == profile.id for lease in active_leases(current)):
                    raise ValueError("cannot remove a profile with an active lease")
                _mutate(
                    current,
                    lambda item: without_profile(item, profile.id),
                    config_path,
                )
            return {"profile": profile.id, "removed": True, "home_deleted": False}
        if args.profile_command == "identity" and args.identity_command == "adopt":
            profile = registry.require_profile(args.profile_id)
            if profile.safety_policy != "worker":
                raise ValueError("external reserve profiles cannot adopt managed identities")
            if not profile_is_provisioned(profile):
                raise ValueError("provision the worker profile before identity adoption")
            with _provider_maintenance(
                registry,
                config_path,
                {profile.provider},
            ) as current:
                profile = current.require_profile(profile.id)
                enabled = sorted(
                    candidate.id
                    for candidate in current.profiles.values()
                    if candidate.provider == profile.provider and candidate.enabled
                )
                if enabled:
                    raise ValueError(
                        f"disable every {profile.provider} profile before identity adoption: "
                        + ", ".join(enabled)
                    )
                if _provider_has_active_lease(current, profile.provider):
                    raise ValueError(
                        f"drain every {profile.provider} lease before identity adoption"
                    )
                workers = sorted(
                    (
                        candidate
                        for candidate in current.profiles.values()
                        if candidate.provider == profile.provider
                        and candidate.safety_policy == "worker"
                    ),
                    key=lambda candidate: candidate.id,
                )
                for worker in workers:
                    if not profile_is_provisioned(worker):
                        raise ValueError(
                            f"provision every {profile.provider} worker before identity "
                            f"adoption: {worker.id}"
                        )
                refresh_provider_identity_anchors(
                    current,
                    profile.provider,
                    allow_keychain_prompt=args.allow_keychain_prompt,
                )
                proofs: dict[str, tuple[dict[str, Any], dict[str, Any]]] = {}
                fingerprints: dict[str, str] = {}
                for worker in workers:
                    source_before = inspect_credential_source_contract(
                        current,
                        worker,
                        allow_keychain_prompt=args.allow_keychain_prompt,
                    )
                    quota = probe_quota(
                        current,
                        worker,
                        allow_keychain_prompt=args.allow_keychain_prompt,
                    )
                    source_after = inspect_credential_source_contract(
                        current,
                        worker,
                        allow_keychain_prompt=args.allow_keychain_prompt,
                    )
                    if source_before != source_after or not has_remote_identity_proof(quota):
                        raise ValueError(
                            f"identity adoption requires a stable fresh proof for {worker.id}"
                        )
                    fingerprint = str(quota["identity_fingerprint"])
                    if fingerprint in fingerprints:
                        raise ValueError(
                            f"duplicate managed identity: {fingerprints[fingerprint]}, {worker.id}"
                        )
                    fingerprints[fingerprint] = worker.id
                    proofs[worker.id] = (quota, source_after)
                    store_quota(current, worker, quota)
                for worker in workers:
                    quota, _source = proofs[worker.id]
                    conflict = identity_conflict(
                        current,
                        worker,
                        quota,
                        require_complete_worker_set=False,
                    )
                    if conflict is not None:
                        raise ValueError(
                            f"identity adoption for {worker.id} conflicts with {conflict}"
                        )
                with state_lock(
                    current.settings.state_dir,
                    current.settings.lock_stale_seconds,
                ):
                    observed = load_registry(config_path)
                    if observed != current:
                        raise ValueError("registry changed during identity adoption")
                    if any(
                        candidate.enabled
                        for candidate in observed.profiles.values()
                        if candidate.provider == profile.provider
                    ) or _provider_has_active_lease(observed, profile.provider):
                        raise ValueError("provider became active during identity adoption")
                    bundle = adopt_provider_identity_bundle(
                        observed,
                        profile.provider,
                        proofs,
                        allow_keychain_prompt=args.allow_keychain_prompt,
                    )
                    append_audit(
                        observed,
                        "identity-adopted",
                        {
                            "profiles": [worker.id for worker in workers],
                            "provider": profile.provider,
                            "credential_sources": {
                                worker.id: proofs[worker.id][1]["kind"]
                                for worker in workers
                            },
                        },
                    )
                return {
                    "provider": profile.provider,
                    "identity_bundle": bundle,
                    "enabled": False,
                }
        if args.profile_command in {"provision", "status", "auth-status", "verify"}:
            profiles = _profiles_for(registry, args.profile_id, args.all)
            if args.profile_command == "provision":
                if args.all:
                    profiles = [
                        profile for profile in profiles if profile.safety_policy == "worker"
                    ]
                elif any(profile.safety_policy != "worker" for profile in profiles):
                    raise ValueError("external reserve profiles must not be provisioned")
                providers = {profile.provider for profile in profiles}
                ids = tuple(profile.id for profile in profiles)
                with _provider_maintenance(
                    registry,
                    config_path,
                    providers,
                    require_disabled=ids,
                ) as current:
                    return {
                        "profiles": [
                            provision_profile(current, current.require_profile(profile_id))
                            for profile_id in ids
                        ]
                    }
            if args.profile_command == "status":
                workers = [
                    profile for profile in profiles if profile.safety_policy == "worker"
                ]
                if not workers:
                    return {
                        "profiles": [profile_status(registry, profile.id) for profile in profiles]
                    }
                providers = {profile.provider for profile in workers}
                with _provider_maintenance(registry, config_path, providers) as current:
                    return {
                        "profiles": [profile_status(current, profile.id) for profile in profiles]
                    }
            if args.profile_command == "verify":
                if args.all:
                    profiles = [
                        profile for profile in profiles if profile.safety_policy == "worker"
                    ]
                elif any(profile.safety_policy != "worker" for profile in profiles):
                    raise ValueError("external reserve profiles must not be remotely verified")
                providers = {profile.provider for profile in profiles}
                ids = tuple(profile.id for profile in profiles)
                with _provider_maintenance(
                    registry,
                    config_path,
                    providers,
                    require_disabled=ids,
                ) as current:
                    results = [
                        _verify_remote_profile(
                            current,
                            current.require_profile(profile_id),
                            allow_keychain_prompt=args.allow_keychain_prompt,
                        )
                        for profile_id in ids
                    ]
                ready = all(result["credential_verified"] for result in results)
                for result in results:
                    result["enabled"] = False
                return {
                    "profiles": results,
                    "ready": ready,
                    "enabled_as_batch": None,
                    "next_step": (
                        "enable each verified worker profile explicitly"
                        if ready
                        else "resolve verification failures while profiles remain disabled"
                    ),
                }
            return {
                "profiles": [
                    {
                        "profile": profile.id,
                        "status": (
                            "external-reserve"
                            if profile.safety_policy != "worker"
                            else
                            auth_status(
                                profile,
                                binary=verified_provider_binary(registry, profile),
                            )
                            if profile_is_provisioned(profile)
                            else "not-provisioned"
                        ),
                    }
                    for profile in profiles
                ]
            }
        if args.profile_command in {"cooldown", "cooldown-clear"}:
            profile = registry.require_profile(args.profile_id)
            if profile.safety_policy != "worker":
                raise ValueError("external reserve profiles do not have routing cooldown state")
            with state_lock(
                registry.settings.state_dir,
                registry.settings.lock_stale_seconds,
            ):
                if args.profile_command == "cooldown":
                    return set_cooldown(
                        registry,
                        profile.id,
                        seconds=args.seconds,
                        reason=args.reason,
                    )
                return clear_cooldown(registry, profile.id)
        profile = registry.require_profile(args.profile_id)
        if args.profile_command == "policy":
            if (
                profile.safety_policy == "desktop_shared"
                and args.safety_policy != "desktop_shared"
            ):
                raise ValueError(
                    f"desktop_shared classification is terminal for {profile.id}; "
                    "use an offline reviewed registry migration"
                )
            with _provider_maintenance(
                registry,
                config_path,
                {profile.provider},
                require_disabled=(profile.id,),
            ) as current:
                updated = _mutate(
                    current,
                    lambda item: set_profile_safety_policy(
                        item,
                        profile.id,
                        args.safety_policy,
                    ),
                    config_path,
                )
            return updated.require_profile(profile.id).public_dict()
        if args.profile_command in {"enable", "disable"}:
            enabled = args.profile_command == "enable"
            if enabled and profile.safety_policy != "worker":
                raise ValueError(
                    f"{profile.safety_policy} profile {profile.id} cannot be enabled for routing"
                )
            with _provider_maintenance(
                registry,
                config_path,
                {profile.provider},
                require_disabled=(profile.id,) if enabled else (),
            ) as current:
                profile = current.require_profile(profile.id)
                if enabled:
                    if not profile_is_provisioned(profile):
                        raise ValueError("provision the profile before enabling it")
                    _verify_provider_enable_set(current, profile)
                updated = _mutate(
                    current,
                    lambda item: set_profile_enabled(item, profile.id, enabled),
                    config_path,
                )
            return updated.require_profile(profile.id).public_dict()
        if args.profile_command in {"login", "enroll"}:
            return _run_profile_enrollment(registry, profile, config_path)

    if args.command == "pool" and args.pool_command == "status":
        validate_id(args.pool, "pool id")
        providers = {args.provider} if args.provider else set(SUPPORTED_PROVIDERS)
        with _provider_maintenance(registry, config_path, providers) as current:
            return pool_status(current, pool=args.pool, provider=args.provider)

    if args.command == "choose":
        if not args.dry_run:
            raise ValueError("diagnostic choose requires --dry-run")
        return select_and_acquire(
            registry,
            task=_task(args.task),
            pool=validate_id(args.pool, "pool id"),
            provider=args.provider,
            profile_id=args.profile,
            dry_run=True,
            workspace=lexical_path(args.workspace),
            config_path=config_path,
        )

    if args.command == "quota":
        profiles = _profiles_for(registry, args.profile_id, args.all)
        if args.quota_command == "refresh":
            if args.all:
                profiles = [
                    profile for profile in profiles if profile.safety_policy == "worker"
                ]
            elif any(profile.safety_policy != "worker" for profile in profiles):
                raise ValueError("external reserve profiles must not be remotely refreshed")
            providers = {profile.provider for profile in profiles}
            ids = tuple(profile.id for profile in profiles)
            with _provider_maintenance(registry, config_path, providers) as current:
                return {
                    "quota": [
                        refresh_quota(
                            current,
                            current.require_profile(profile_id),
                            allow_keychain_prompt=args.allow_keychain_prompt,
                        )
                        for profile_id in ids
                    ]
                }
        return {
            "quota": [
                read_quota(registry, profile.id)
                if profile.safety_policy == "worker"
                else {
                    "profile": profile.id,
                    "provider": profile.provider,
                    "status": "external-reserve",
                    "safety_policy": profile.safety_policy,
                }
                for profile in profiles
            ]
        }

    if args.command == "lease":
        if args.lease_command == "list":
            return {"leases": active_leases(registry)}
        if args.lease_command == "release":
            task = _task(args.task)
            with state_lock(
                registry.settings.state_dir,
                registry.settings.lock_stale_seconds,
            ):
                return release_lease(registry, task, force=args.force)
        if args.lease_command == "acquire":
            task = _task(args.task)
            pool = validate_id(args.pool or "explicit", "pool id")
            return select_and_acquire(
                registry,
                task=task,
                pool=pool,
                profile_id=args.profile,
                explicit_profile=True,
                workspace=lexical_path(args.workspace),
                config_path=config_path,
            )
        if args.lease_command == "recover":
            task = _task(args.task)
            workspace = lexical_path(args.workspace)
            mapping = get_session(registry, task)
            profile = registry.require_profile(str(mapping["profile"]))
            pool = str(mapping["pool"])
            if lexical_path(Path(str(mapping["workspace"]))) != workspace:
                raise ValueError("session mapping workspace does not match recovery workspace")
            return select_and_acquire(
                registry,
                task=task,
                pool=validate_id(pool, "pool id"),
                provider=profile.provider,
                profile_id=profile.id,
                explicit_profile=True,
                ignore_reserve=True,
                recovery_reservation=True,
                workspace=workspace,
                config_path=config_path,
            )
        task = _task(args.task)
        return select_and_acquire(
            registry,
            task=task,
            pool=validate_id(args.pool, "pool id"),
            provider=args.provider,
            profile_id=args.profile,
            workspace=lexical_path(args.workspace),
            config_path=config_path,
        )

    if args.command == "exec":
        provider_args = _strip_separator(args.provider_args)
        task = _task(args.task) if args.task else None
        if task is None:
            raise ValueError("worker exec requires --task so its provider lease is tracked")
        if args.workspace is None:
            raise ValueError("worker exec requires the task --workspace")
        if args.turn_end is None:
            raise ValueError("worker exec requires the task --turn-end marker")
        workspace = lexical_path(args.workspace)
        turn_end = validate_turn_end_path(args.turn_end)
        pool = args.pool or ("explicit" if args.profile else None)
        if pool is None:
            raise ValueError("exec with --task requires --pool or --profile")
        pool = validate_id(pool, "pool id")
        parsed_arguments = _validate_candidate_arguments(
            registry,
            provider_args,
            pool=pool,
            provider=args.provider,
            profile_id=args.profile,
        )
        for candidate_arguments in parsed_arguments.values():
            if (
                candidate_arguments.notify_path is not None
                and candidate_arguments.notify_path != turn_end
            ):
                raise ValueError("managed Codex notify marker does not match --turn-end")
        hook_entrypoint = verified_agent_fleet_hook_entrypoint()
        selected = select_and_acquire(
            registry,
            task=task,
            pool=pool,
            provider=args.provider,
            profile_id=args.profile,
            bind_pid=os.getpid(),
            explicit_profile=pool == "explicit",
            workspace=workspace,
            config_path=config_path,
        )
        profile = registry.require_profile(str(selected["profile"]))
        worker_arguments = parsed_arguments.get(profile.provider)
        if worker_arguments is None:
            raise ValueError("selected provider was not validated before lease acquisition")
        project = prepare_profile_launch(registry, profile, workspace)
        argv = managed_argv(
            registry,
            profile,
            project.active_root,
            worker_arguments,
            binary=verified_provider_binary(registry, profile),
            hook_entrypoint=hook_entrypoint,
        )
        os.chdir(project.active_root)
        os.execvpe(
            argv[0],
            argv,
            provider_environment(
                profile,
                task,
                workspace,
                pool,
                turn_end,
                operation="worker",
            ),
        )

    if args.command == "resume":
        provider_args = _strip_separator(args.provider_args)
        task = _task(args.task) if args.task else None
        if task is None:
            raise ValueError("worker resume requires --task so its provider lease is tracked")
        if args.workspace is None:
            raise ValueError("worker resume requires the task --workspace")
        if args.turn_end is None:
            raise ValueError("worker resume requires the task --turn-end marker")
        workspace = lexical_path(args.workspace)
        turn_end = validate_turn_end_path(args.turn_end)
        hook_entrypoint = verified_agent_fleet_hook_entrypoint()
        mapping = get_session(registry, task)
        profile = registry.require_profile(str(mapping["profile"]))
        worker_arguments = validate_worker_arguments(
            profile,
            provider_args,
            operation="resume",
        )
        if worker_arguments.notify_path is not None and worker_arguments.notify_path != turn_end:
            raise ValueError("managed Codex notify marker does not match --turn-end")
        if args.profile and args.profile != profile.id:
            raise ValueError("explicit profile does not match task session mapping")
        session_id = str(mapping["session_id"])
        if lexical_path(Path(str(mapping["workspace"]))) != workspace:
            raise ValueError("session mapping workspace does not match resume workspace")
        if mapping["turn_end"] != str(turn_end):
            raise ValueError("session mapping turn-end marker does not match resume marker")
        if args.session and args.session != session_id:
            raise ValueError("explicit session does not match task session mapping")
        mapped_pool = str(mapping["pool"])
        if args.pool is not None and args.pool != mapped_pool:
            raise ValueError("explicit pool does not match task session mapping")
        pool = mapped_pool
        validate_id(session_id, "session id")
        select_and_acquire(
            registry,
            task=task,
            pool=validate_id(str(pool), "pool id"),
            profile_id=profile.id,
            bind_pid=os.getpid(),
            explicit_profile=True,
            ignore_reserve=True,
            workspace=workspace,
            config_path=config_path,
        )
        project = prepare_profile_launch(registry, profile, workspace)
        argv = resume_argv(
            registry,
            profile,
            session_id,
            worker_arguments,
            active_root=project.active_root,
            binary=verified_provider_binary(registry, profile),
            hook_entrypoint=hook_entrypoint,
        )
        os.chdir(project.active_root)
        os.execvpe(
            argv[0],
            argv,
            provider_environment(
                profile,
                task,
                workspace,
                pool,
                turn_end,
                operation="worker",
            ),
        )

    if args.command == "session":
        task = _task(args.task)
        if args.session_command == "status":
            return get_session(registry, task)
        with state_lock(
            registry.settings.state_dir,
            registry.settings.lock_stale_seconds,
        ):
            return remove_session(registry, task)

    if args.command == "hook" and args.hook_command == "session-start":
        record_session_from_hook(registry, read_hook_payload())
        return None
    if args.command == "hook" and args.hook_command == "turn-end":
        record_turn_end_from_hook(registry)
        return None
    if args.command == "doctor":
        return run_doctor(
            registry,
            config_path,
            workspace=lexical_path(args.workspace) if args.workspace else None,
            project=lexical_path(args.project) if args.project else None,
        )
    if args.command == "status":
        with _provider_maintenance(
            registry,
            config_path,
            set(SUPPORTED_PROVIDERS),
        ) as current:
            return {
                "schema": 1,
                "profiles": [
                    profile_status(current, profile_id) for profile_id in sorted(current.profiles)
                ],
                "leases": active_leases(current),
            }
    if args.command == "audit":
        return {"schema": 1, "events": read_audit(registry, limit=args.limit)}
    raise ValueError("unsupported command")


def main(argv: list[str] | None = None) -> int:
    parser = _parser()
    args = parser.parse_args(argv)
    try:
        if args.command not in {"exec", "resume"}:
            preflight(args.format)
        payload = _run(args)
        if payload is not None:
            emit(payload, args.format)
        return 0
    except (ValueError, TimeoutError, OSError) as exc:
        if args.format == "json":
            emit({"error": str(exc), "ok": False}, "json")
        else:
            print(f"agent-fleet: {exc}", file=sys.stderr)
        return 2
