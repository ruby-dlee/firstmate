from __future__ import annotations

import argparse
import os
import subprocess
import sys
from collections.abc import Callable, Iterator
from contextlib import ExitStack, contextmanager
from pathlib import Path
from typing import Any

from . import __version__
from .audit import read_audit
from .config import (
    initial_registry,
    load_registry,
    save_registry,
    set_profile_enabled,
    set_profile_safety_policy,
    with_profile,
    without_profile,
)
from .cooldowns import clear_cooldown, set_cooldown
from .doctor import run_doctor
from .enrollment import (
    CodexAuthTransaction,
    activate_codex_promotion,
    create_codex_login_stage,
    discard_codex_promotion,
    discard_codex_stage,
    finalize_codex_promotion,
    prepare_codex_promotion,
    recover_pending_codex_transaction,
    recover_pending_codex_transactions,
    rollback_codex_promotion,
)
from .identity import (
    identity_conflict,
    refresh_provider_identity_anchors,
    refresh_provider_identity_anchors_if_due,
)
from .leases import active_leases, release_lease
from .locks import provider_enrollment_lock, state_lock
from .models import PROFILE_SAFETY_POLICIES, SUPPORTED_PROVIDERS, Profile, Registry
from .output import emit
from .paths import default_config_path, expand_path
from .providers import (
    auth_probe,
    auth_status,
    login_argv,
    provider_argv,
    provider_environment,
    resume_argv,
)
from .provision import profile_is_provisioned, provision_profile
from .quota import (
    probe_quota,
    quota_routeability,
    read_quota,
    refresh_due_quotas,
    refresh_quota,
    snapshot_quota_cache,
    store_quota,
)
from .scheduler import select_and_acquire
from .sessions import get_session, read_hook_payload, record_session_from_hook, remove_session
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
    init.add_argument("--force", action="store_true")

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
        item = profile_commands.add_parser(name)
        item.add_argument("profile_id")
        item.add_argument(
            "--browser-login",
            action="store_true",
            help="use Codex browser callback instead of isolated device authorization",
        )
        item.add_argument(
            "--access-token",
            action="store_true",
            help="read a supported Codex access token from non-interactive stdin",
        )
        enable_group = item.add_mutually_exclusive_group()
        enable_group.add_argument("--enable", action="store_true")
        enable_group.add_argument("--no-enable", action="store_true", help=argparse.SUPPRESS)
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
    acquire = lease_commands.add_parser("acquire")
    acquire.add_argument("--profile", required=True)
    acquire.add_argument("--task", required=True)
    acquire.add_argument("--pool")
    lease_commands.add_parser("list")
    release = lease_commands.add_parser("release")
    release.add_argument("--task", required=True)
    release.add_argument("--force", action="store_true")

    execute = commands.add_parser("exec")
    _add_route_arguments(execute, required=False)
    execute.add_argument("provider_args", nargs=argparse.REMAINDER)

    resume = commands.add_parser("resume")
    resume.add_argument("--task")
    resume.add_argument("--profile")
    resume.add_argument("--session")
    resume.add_argument("--pool")
    resume.add_argument("provider_args", nargs=argparse.REMAINDER)

    session = commands.add_parser("session")
    session_commands = session.add_subparsers(dest="session_command", required=True)
    for name in ("status", "remove"):
        item = session_commands.add_parser(name)
        item.add_argument("--task", required=True)

    hook = commands.add_parser("hook")
    hook_commands = hook.add_subparsers(dest="hook_command", required=True)
    hook_commands.add_parser("session-start")

    doctor = commands.add_parser("doctor")
    doctor.add_argument("--workspace", type=Path)
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


def _task(value: str) -> str:
    if not value.strip() or len(value) > 512 or any(ord(char) < 32 for char in value):
        raise ValueError("task id must be 1-512 printable characters")
    return value


def _strip_separator(values: list[str]) -> list[str]:
    return values[1:] if values[:1] == ["--"] else values


def _mutate(registry: Registry, operation: Callable[[Registry], Registry], path: Path) -> Registry:
    with state_lock(
        registry.settings.state_dir,
        registry.settings.lock_stale_seconds,
    ):
        current = load_registry(path)
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
            for provider in sorted(providers):
                recover_pending_codex_transactions(registry, provider)
            with state_lock(
                registry.settings.state_dir,
                registry.settings.lock_stale_seconds,
            ):
                current = load_registry(config_path)
                for profile_id in require_disabled:
                    if current.require_profile(profile_id).enabled:
                        raise ValueError(f"disable {profile_id} before provider maintenance")
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
        "contract_version": 1,
        "cli_version": __version__,
        "formats": ["json", "toon", "human"],
        "selection_fields": [
            "profile",
            "provider",
            "pool",
            "decision_reason",
            "quota_fresh",
            "headroom_percent",
            "active_lease_count",
            "degraded",
        ],
        "commands": {
            "pool_summary": "pool status --pool <pool> [--provider <provider>]",
            "dry_run": "choose --pool <pool> --task <task> --dry-run",
            "atomic_choose": "lease choose --pool <pool> --task <task>",
            "explicit_acquire": "lease acquire --profile <profile> --task <task>",
            "recover": "lease recover --task <task>",
            "release": "lease release --task <task>",
            "exec": "exec --profile <profile> [--task <task> --pool <pool>] -- <argv>",
            "resume_task": "resume --task <task> -- <argv>",
            "resume_explicit": "managed task/session mapping required",
            "session_status": "session status --task <task>",
            "session_remove": "session remove --task <task>",
            "profile_enroll": "profile enroll <profile>",
            "profile_verify": "profile verify <profile>|--all",
        },
    }


def _credential_is_remotely_verified(quota: dict[str, Any]) -> bool:
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
        result.get("identity_conflict")
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
) -> dict[str, Any]:
    conflict = identity_conflict(
        registry,
        profile,
        quota,
        require_complete_worker_set=require_complete_worker_set,
    )
    route_conflict = identity_conflict(registry, profile, quota)
    remotely_verified = _credential_is_remotely_verified(quota) or (
        quota.get("fresh") is not True and _cached_credential_proof_is_usable(quota)
    )
    credential_verified = (
        authentication == "authenticated" and remotely_verified and conflict is None
    )
    routeability = quota_routeability(
        registry,
        profile,
        quota=quota,
        authentication=authentication,
        ignore_reserve=True,
    )
    if route_conflict is not None:
        routeability = {
            "eligible": False,
            "mode": "blocked",
            "reason": route_conflict,
        }
    return {
        "profile": profile.id,
        "provider": profile.provider,
        "local_auth": authentication,
        "remote_status": quota.get("status"),
        "remote_reason": quota.get("reason"),
        "credential_verified": credential_verified,
        "identity_conflict": conflict,
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
    authentication = str(auth_probe(registry, profile)["status"])
    refresh_provider_identity_anchors(
        registry,
        profile.provider,
        allow_keychain_prompt=allow_keychain_prompt,
    )
    cached = read_quota(registry, profile.id)
    candidate = probe_quota(
        registry,
        profile,
        allow_keychain_prompt=allow_keychain_prompt,
    )
    if (
        not allow_keychain_prompt
        and candidate.get("reason") == "keychain_access_required"
        and _cached_credential_proof_is_usable(cached)
    ):
        quota = cached
    else:
        store_quota(registry, profile, candidate)
        quota = read_quota(registry, profile.id)
    return _evaluate_remote_profile(
        registry,
        profile,
        authentication,
        quota,
        require_complete_worker_set=require_complete_worker_set,
    )


def _probe_enrollment_candidate(
    registry: Registry,
    profile: Profile,
) -> tuple[dict[str, Any], dict[str, Any]]:
    authentication = str(auth_probe(registry, profile)["status"])
    quota = probe_quota(registry, profile)
    quota = {**quota, "fresh": _credential_is_remotely_verified(quota)}
    result = _evaluate_remote_profile(
        registry,
        profile,
        authentication,
        quota,
        require_complete_worker_set=False,
    )
    return result, quota


def _provider_has_active_lease(registry: Registry, provider: str) -> bool:
    for lease in active_leases(registry):
        profile_id = lease.get("profile")
        if (
            isinstance(profile_id, str)
            and registry.require_profile(profile_id).provider == provider
        ):
            return True
    return False


def _enroll_codex_profile(
    registry: Registry,
    target: Profile,
    *,
    browser_login: bool,
    access_token: bool,
) -> dict[str, Any]:
    stage = create_codex_login_stage(target)
    promotion: Profile | None = None
    transaction: CodexAuthTransaction | None = None
    quota_snapshot = snapshot_quota_cache(registry, target.id)
    try:
        argv = login_argv(
            registry,
            stage,
            browser_login=browser_login,
            access_token=access_token,
        )
        completed = subprocess.run(
            argv,
            env=provider_environment(stage),
            check=False,
        )
        if completed.returncode != 0:
            raise ValueError(
                f"provider login failed for {target.id}; target credentials were unchanged"
            )
        refresh_provider_identity_anchors(registry, target.provider)
        staged_result, _ = _probe_enrollment_candidate(registry, stage)
        if not staged_result["credential_verified"]:
            raise ValueError(
                f"staged remote verification failed for {target.id}: "
                f"{_verification_reason(staged_result)}; target credentials were unchanged"
            )
        promotion = prepare_codex_promotion(registry, target, stage)
        promotion_result, _ = _probe_enrollment_candidate(registry, promotion)
        if not promotion_result["credential_verified"]:
            raise ValueError(
                f"promotion verification failed for {target.id}: "
                f"{_verification_reason(promotion_result)}; target credentials were unchanged"
            )
        transaction = activate_codex_promotion(
            registry,
            target,
            promotion,
            quota_snapshot,
        )
        try:
            target_result, target_quota = _probe_enrollment_candidate(registry, target)
            if not target_result["credential_verified"]:
                raise ValueError(
                    f"post-promotion verification failed for {target.id}: "
                    f"{_verification_reason(target_result)}"
                )
            store_quota(registry, target, target_quota)
            finalized = _evaluate_remote_profile(
                registry,
                target,
                str(auth_probe(registry, target)["status"]),
                read_quota(registry, target.id),
                require_complete_worker_set=False,
            )
            if not finalized["credential_verified"]:
                raise ValueError(
                    f"stored verification failed for {target.id}: {_verification_reason(finalized)}"
                )
        except BaseException:
            rollback_codex_promotion(registry, target, transaction)
            transaction = None
            raise
        finalize_codex_promotion(registry, target, transaction)
        transaction = None
        return finalized
    finally:
        if transaction is not None:
            rollback_codex_promotion(registry, target, transaction)
        else:
            # Activation can crash/fail after the journal is durable but before
            # returning its in-memory handle. Recover that case before deleting
            # any staging or promotion artifact.
            recover_pending_codex_transaction(registry, target)
        if promotion is not None and promotion.home.exists():
            discard_codex_promotion(promotion, target)
        if stage.home.exists():
            discard_codex_stage(stage, target)


def _run_profile_enrollment(
    registry: Registry,
    profile: Profile,
    args: argparse.Namespace,
    config_path: Path,
) -> dict[str, Any]:
    if args.browser_login and profile.provider != "codex":
        raise ValueError("--browser-login applies only to Codex profiles")
    if args.access_token and profile.provider != "codex":
        raise ValueError("--access-token applies only to Codex profiles")
    if args.browser_login and args.access_token:
        raise ValueError("choose --browser-login or --access-token, not both")
    if args.enable:
        raise ValueError(
            "enrollment and routing enable are separate phases; verify, then run "
            f"`agent-fleet profile enable {profile.id}`"
        )
    try:
        enrollment_lock = provider_enrollment_lock(
            registry.settings.state_dir,
            profile.provider,
            registry.settings.lock_stale_seconds,
            timeout=0.1,
        )
        with enrollment_lock:
            recover_pending_codex_transactions(registry, profile.provider)
            with state_lock(
                registry.settings.state_dir,
                registry.settings.lock_stale_seconds,
            ):
                current = load_registry(config_path)
                profile = current.require_profile(profile.id)
                if profile.enabled:
                    raise ValueError(
                        f"disable {profile.id} and drain all {profile.provider} leases "
                        "before enrollment"
                    )
                if _provider_has_active_lease(current, profile.provider):
                    raise ValueError(
                        f"refusing {profile.provider} login while any same-provider "
                        "Fleet lease is active"
                    )
            registry = current
            if args.access_token:
                print(
                    "Agent Fleet login safety: Codex will read the access token directly "
                    "from non-interactive stdin; Agent Fleet does not read or log it.",
                    file=sys.stderr,
                )
            else:
                if profile.provider == "claude":
                    browser_behavior = "Claude normally opens browser login automatically."
                elif args.browser_login:
                    browser_behavior = "Codex will use its browser callback login."
                else:
                    browser_behavior = (
                        "Codex device login prints a URL and code; it does not normally "
                        "open the browser automatically."
                    )
                print(
                    "Agent Fleet enrollment safety: login is not generally idempotent; "
                    "a raw Codex login revokes the selected home's existing refresh token "
                    "before OAuth, even when OAuth is cancelled. Agent Fleet uses an "
                    "isolated Codex staging home so retries cannot revoke the target. "
                    f"{browser_behavior} Use a fresh Guest/private window, close that "
                    "entire window after success, and never select provider Log out.",
                    file=sys.stderr,
                )
            if profile.provider == "codex":
                verified = _enroll_codex_profile(
                    registry,
                    profile,
                    browser_login=args.browser_login,
                    access_token=args.access_token,
                )
            else:
                provision_profile(registry, profile)
                completed = subprocess.run(
                    login_argv(registry, profile),
                    env=provider_environment(profile),
                    check=False,
                )
                if completed.returncode != 0:
                    raise ValueError(
                        f"provider login failed for {profile.id}; profile remains disabled"
                    )
                verified = _verify_remote_profile(
                    registry,
                    profile,
                    allow_keychain_prompt=False,
                )
                if (
                    not verified["credential_verified"]
                    and verified.get("remote_reason") == "keychain_access_required"
                ):
                    verified["verification_pending"] = True
                    verified["next_step"] = (
                        f"agent-fleet profile verify {profile.id} --allow-keychain-prompt"
                    )
                elif not verified["credential_verified"]:
                    raise ValueError(
                        f"remote verification failed for {profile.id}: "
                        f"{_verification_reason(verified)}; profile remains disabled"
                    )
            verified["enabled"] = False
            return verified
    except TimeoutError as exc:
        raise ValueError(
            f"another {profile.provider} enrollment or Fleet selection is in progress"
        ) from exc


def _require_routeable_profile(
    registry: Registry,
    profile: Profile,
    *,
    ignore_reserve: bool = False,
) -> None:
    refresh_provider_identity_anchors_if_due(registry, profile.provider)
    refresh_due_quotas(registry, [profile])
    authentication = auth_status(registry, profile)
    quota = read_quota(registry, profile.id)
    conflict = identity_conflict(registry, profile, quota)
    routeability = quota_routeability(
        registry,
        profile,
        quota=quota,
        authentication=authentication,
        ignore_reserve=ignore_reserve,
    )
    if conflict is not None:
        raise ValueError(f"profile duplicates enabled provider identity {conflict}")
    if not routeability["eligible"]:
        raise ValueError(f"profile is not routeable: {routeability['reason']}")


def _run(args: argparse.Namespace) -> Any | None:
    config_path = expand_path(args.config)
    if args.command == "version":
        return {"cli_version": __version__, "contract_version": 1}
    if args.command == "contract":
        return _contract()
    if args.command == "init":
        if config_path.exists() and not args.force:
            raise ValueError(f"registry already exists: {config_path}")
        registry = initial_registry(args.claude, args.codex)
        save_registry(registry, config_path)
        return {
            "registry": str(config_path),
            "profiles": [registry.profiles[key].public_dict() for key in sorted(registry.profiles)],
            "enabled": 0,
        }

    registry = load_registry(config_path)
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
        if args.profile_command in {"provision", "status", "auth-status", "verify"}:
            profiles = _profiles_for(registry, args.profile_id, args.all)
            if args.profile_command == "provision":
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
                providers = {profile.provider for profile in profiles}
                with _provider_maintenance(registry, config_path, providers) as current:
                    return {
                        "profiles": [profile_status(current, profile.id) for profile in profiles]
                    }
            if args.profile_command == "verify":
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
                    {"profile": profile.id, "status": auth_status(registry, profile)}
                    for profile in profiles
                ]
            }
        if args.profile_command in {"cooldown", "cooldown-clear"}:
            profile = registry.require_profile(args.profile_id)
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
                    verified = _verify_remote_profile(
                        current,
                        profile,
                        allow_keychain_prompt=False,
                        require_complete_worker_set=True,
                    )
                    if not verified["credential_verified"]:
                        raise ValueError(
                            f"profile is not remotely verified: {_verification_reason(verified)}"
                        )
                updated = _mutate(
                    current,
                    lambda item: set_profile_enabled(item, profile.id, enabled),
                    config_path,
                )
            return updated.require_profile(profile.id).public_dict()
        if args.profile_command in {"login", "enroll"}:
            return _run_profile_enrollment(registry, profile, args, config_path)

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
        )

    if args.command == "quota":
        profiles = _profiles_for(registry, args.profile_id, args.all)
        if args.quota_command == "refresh":
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
        return {"quota": [read_quota(registry, profile.id) for profile in profiles]}

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
            )
        if args.lease_command == "recover":
            task = _task(args.task)
            mapping = get_session(registry, task)
            profile = registry.require_profile(str(mapping.get("profile")))
            if mapping.get("provider") != profile.provider:
                raise ValueError("session mapping provider does not match its profile")
            pool = mapping.get("pool")
            if not isinstance(pool, str) or not pool:
                raise ValueError("session mapping has no pool")
            return select_and_acquire(
                registry,
                task=task,
                pool=validate_id(pool, "pool id"),
                provider=profile.provider,
                profile_id=profile.id,
                explicit_profile=True,
                ignore_reserve=True,
                recovery_reservation=True,
            )
        task = _task(args.task)
        return select_and_acquire(
            registry,
            task=task,
            pool=validate_id(args.pool, "pool id"),
            provider=args.provider,
            profile_id=args.profile,
        )

    if args.command == "exec":
        task = _task(args.task) if args.task else None
        if task is None:
            raise ValueError("worker exec requires --task so its provider lease is tracked")
        pool = args.pool or ("explicit" if args.profile else None)
        if pool is None:
            raise ValueError("exec with --task requires --pool or --profile")
        selected = select_and_acquire(
            registry,
            task=task,
            pool=validate_id(pool, "pool id"),
            provider=args.provider,
            profile_id=args.profile,
            bind_pid=os.getpid(),
            explicit_profile=pool == "explicit",
        )
        profile = registry.require_profile(str(selected["profile"]))
        argv = provider_argv(registry, profile, _strip_separator(args.provider_args))
        os.execvpe(argv[0], argv, provider_environment(profile, task))

    if args.command == "resume":
        task = _task(args.task) if args.task else None
        if task is None:
            raise ValueError("worker resume requires --task so its provider lease is tracked")
        mapping = get_session(registry, task)
        profile = registry.require_profile(str(mapping.get("profile")))
        if args.profile and args.profile != profile.id:
            raise ValueError("explicit profile does not match task session mapping")
        session_id = mapping.get("session_id")
        if args.session and args.session != session_id:
            raise ValueError("explicit session does not match task session mapping")
        pool = args.pool or str(mapping.get("pool"))
        if not pool or pool == "None":
            raise ValueError("session mapping has no pool; pass --pool")
        if not isinstance(session_id, str):
            raise ValueError("session mapping has no provider session id")
        validate_id(session_id, "session id")
        select_and_acquire(
            registry,
            task=task,
            pool=validate_id(str(pool), "pool id"),
            profile_id=profile.id,
            bind_pid=os.getpid(),
            explicit_profile=True,
            ignore_reserve=True,
        )
        argv = resume_argv(
            registry,
            profile,
            session_id,
            _strip_separator(args.provider_args),
        )
        os.execvpe(argv[0], argv, provider_environment(profile, task))

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
    if args.command == "doctor":
        return run_doctor(
            registry,
            config_path,
            workspace=expand_path(args.workspace) if args.workspace else None,
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
