from __future__ import annotations

import json
import multiprocessing
import os
import stat
import subprocess
import sys
import time
from dataclasses import replace
from datetime import UTC, datetime
from pathlib import Path

import pytest

import agent_fleet.cli as cli_module
import agent_fleet.quota as quota_module
import agent_fleet.scheduler as scheduler_module
from agent_fleet import enrollment, identity, leases, locks, util
from agent_fleet.config import (
    load_registry,
    save_registry,
    set_profile_enabled,
    set_profile_safety_policy,
)
from agent_fleet.cooldowns import clear_cooldown, cooldown_path, set_cooldown
from agent_fleet.enrollment import (
    activate_codex_promotion,
    create_codex_login_stage,
    discard_codex_promotion,
    discard_codex_stage,
    finalize_codex_promotion,
    prepare_codex_promotion,
    recover_pending_codex_transaction,
    rollback_codex_promotion,
)
from agent_fleet.identity import (
    adopt_provider_identity_bundle,
    identity_bundle_path,
    refresh_provider_identity_anchors,
)
from agent_fleet.leases import active_leases, bind_lease, lease_path, new_lease, release_lease
from agent_fleet.locks import DirectoryLock, provider_enrollment_lock
from agent_fleet.paths import current_user_home, current_user_name, ensure_private_dir
from agent_fleet.providers import (
    CONTROL_PATH,
    auth_probe,
    identity_fingerprint,
    provider_environment,
    validated_worker_path,
)
from agent_fleet.provision import provision_profile
from agent_fleet.quota import (
    inspect_credential_source_contract,
    quota_path,
    read_quota,
    snapshot_quota_cache,
)
from agent_fleet.recovery import recover_pending_profile_recoveries
from agent_fleet.scheduler import select_and_acquire
from agent_fleet.util import atomic_write_json


def _directory_lock_process(
    path: str,
    hook_phase: str | None,
    ready: multiprocessing.synchronize.Event,
    proceed: multiprocessing.synchronize.Event,
    release: multiprocessing.synchronize.Event,
    outcomes: multiprocessing.queues.Queue,
) -> None:
    def hook(phase: str, _path: Path) -> None:
        if phase != hook_phase:
            return
        ready.set()
        if not proceed.wait(timeout=10):
            raise RuntimeError(f"timed out at lock test hook {phase}")

    lock = DirectoryLock(
        Path(path),
        stale_seconds=0,
        timeout=8,
        test_hook=hook,
    )
    try:
        lock.acquire()
        outcomes.put(("entered", os.getpid()))
        if not release.wait(timeout=10):
            raise RuntimeError("timed out waiting to release test lock")
        lock.release()
        outcomes.put(("released", os.getpid()))
    except BaseException as exc:
        outcomes.put(("error", os.getpid(), type(exc).__name__, str(exc)))


def _state_snapshot(root: Path) -> dict[str, bytes]:
    return {
        str(path.relative_to(root)): path.read_bytes()
        for path in root.rglob("*")
        if path.is_file() and not path.is_symlink()
    }


def _crash_identity_shadow_after_phase(
    registry,
    profile,
    snapshot,
    phase: str,
    connection,
) -> None:
    def stop_at(current: str, root: Path) -> None:
        if current != phase:
            return
        connection.send(str(root))
        connection.close()
        os._exit(91)

    shadow = identity._BaseIdentityShadow(
        registry,
        profile,
        snapshot,
        test_hook=stop_at,
    )
    shadow.__enter__()
    raise AssertionError(f"identity shadow did not stop after {phase}")


def _codex_rpc_fixture(
    path: Path,
    *,
    account: object,
    requires_openai_auth: object = True,
    notification: bool = False,
    behavior: str = "normal",
    capture: Path | None = None,
) -> None:
    capture_literal = repr(str(capture)) if capture is not None else "None"
    path.write_text(
        f"""#!{sys.executable}
import json
import os
import sys
import time

capture = {capture_literal}
if capture is not None:
    with open(capture, "w", encoding="utf-8") as handle:
        json.dump({{"argv": sys.argv[1:], "env": dict(os.environ)}}, handle)
if {behavior!r} == "nonzero":
    raise SystemExit(19)
if {behavior!r} == "timeout":
    time.sleep(5)
if {behavior!r} == "malformed":
    print("not-json", flush=True)
    time.sleep(5)
for line in sys.stdin:
    message = json.loads(line)
    if message.get("method") == "initialize":
        print(json.dumps({{"id": message["id"], "result": {{}}}}), flush=True)
    elif message.get("method") == "account/read":
        if {notification!r}:
            notification_payload = {{"method": "codex/event/remote-control", "params": {{}}}}
            print(json.dumps(notification_payload), flush=True)
        result = {{"account": {account!r}, "requiresOpenaiAuth": {requires_openai_auth!r}}}
        print(json.dumps({{"id": message["id"], "result": result}}), flush=True)
""",
        encoding="utf-8",
    )
    path.chmod(0o755)


def _enable_and_provision(registry, config: Path, profile_id: str):
    profiles = dict(registry.profiles)
    profiles[profile_id] = replace(
        profiles[profile_id],
        enabled=True,
        max_concurrent=20,
    )
    registry = replace(registry, profiles=profiles)
    save_registry(registry, config)
    registry = load_registry(config)
    provision_profile(registry, registry.require_profile(profile_id))
    return registry


def _write_pending_credential_journal(
    registry,
    provider: str,
    profile_id: str,
) -> Path:
    root = registry.settings.state_dir / "transactions" / "credential-recovery"
    ensure_private_dir(root)
    path = root / f"{provider}-{profile_id}.json"
    atomic_write_json(
        path,
        {
            "schema": 1,
            "kind": "credential-recovery",
            "provider": provider,
            "profile": profile_id,
            "journal": str(path),
        },
    )
    return path


def _prepared_codex_transaction(registry):
    target = registry.require_profile("codex-1")
    provision_profile(registry, target)
    old_auth = target.home / "auth.json"
    old_auth.write_text('{"token":"old-test-token"}\n', encoding="utf-8")
    old_auth.chmod(0o600)
    old_quota = quota_path(registry, target.id).read_bytes()
    snapshot = snapshot_quota_cache(registry, target.id)
    stage = create_codex_login_stage(registry, target)
    staged_auth = stage.home / "auth.json"
    staged_auth.write_text('{"token":"new-test-token"}\n', encoding="utf-8")
    staged_auth.chmod(0o600)
    promotion = prepare_codex_promotion(registry, target, stage)
    return target, stage, promotion, snapshot, old_auth, old_quota


def test_codex_crash_recovery_rolls_back_auth_and_quota_before_cleanup(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    registry = load_registry(config)
    target, stage, promotion, snapshot, old_auth, old_quota = _prepared_codex_transaction(registry)
    transaction = activate_codex_promotion(
        registry,
        target,
        promotion,
        snapshot,
    )
    assert "new-test-token" in old_auth.read_text(encoding="utf-8")
    atomic_write_json(quota_path(registry, target.id), {"schema": 1, "new": True})

    with provider_enrollment_lock(
        registry.settings.state_dir,
        "codex",
        registry.settings.lock_stale_seconds,
    ):
        assert recover_pending_codex_transaction(registry, target) is True

    assert "old-test-token" in old_auth.read_text(encoding="utf-8")
    assert quota_path(registry, target.id).read_bytes() == old_quota
    assert not transaction.journal_path.exists()
    discard_codex_promotion(promotion, target)
    discard_codex_stage(registry, stage, target)


def test_codex_activation_failure_after_replace_is_recovered(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    _, config = fleet
    registry = load_registry(config)
    target, stage, promotion, snapshot, old_auth, old_quota = _prepared_codex_transaction(registry)
    real_fsync = enrollment._fsync_directory
    calls = 0

    def fail_after_replace(path: Path) -> None:
        nonlocal calls
        calls += 1
        if calls == 2:
            raise OSError("injected crash after auth replace")
        real_fsync(path)

    monkeypatch.setattr(enrollment, "_fsync_directory", fail_after_replace)
    with pytest.raises(OSError, match="injected crash"):
        activate_codex_promotion(registry, target, promotion, snapshot)
    monkeypatch.setattr(enrollment, "_fsync_directory", real_fsync)

    with provider_enrollment_lock(
        registry.settings.state_dir,
        "codex",
        registry.settings.lock_stale_seconds,
    ):
        assert recover_pending_codex_transaction(registry, target) is True
    assert "old-test-token" in old_auth.read_text(encoding="utf-8")
    assert quota_path(registry, target.id).read_bytes() == old_quota
    discard_codex_promotion(promotion, target)
    discard_codex_stage(registry, stage, target)


def test_codex_committed_crash_recovery_keeps_promoted_auth(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    _, config = fleet
    registry = load_registry(config)
    target, stage, promotion, snapshot, target_auth, _ = _prepared_codex_transaction(registry)
    transaction = activate_codex_promotion(registry, target, promotion, snapshot)
    real_unlink = Path.unlink

    def fail_journal_cleanup(path: Path, *args, **kwargs) -> None:
        if path == transaction.journal_path:
            raise OSError("injected crash after durable commit")
        real_unlink(path, *args, **kwargs)

    monkeypatch.setattr(Path, "unlink", fail_journal_cleanup)
    with pytest.raises(OSError, match="injected crash"):
        finalize_codex_promotion(registry, target, transaction)
    monkeypatch.setattr(Path, "unlink", real_unlink)

    with provider_enrollment_lock(
        registry.settings.state_dir,
        "codex",
        registry.settings.lock_stale_seconds,
    ):
        assert recover_pending_codex_transaction(registry, target) is True
    assert "new-test-token" in target_auth.read_text(encoding="utf-8")
    assert not transaction.journal_path.exists()
    discard_codex_promotion(promotion, target)
    discard_codex_stage(registry, stage, target)


def test_codex_rollback_recovery_is_idempotent_after_auth_restore(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    _, config = fleet
    registry = load_registry(config)
    target, stage, promotion, snapshot, target_auth, old_quota = _prepared_codex_transaction(
        registry
    )
    transaction = activate_codex_promotion(registry, target, promotion, snapshot)
    real_write_phase = enrollment._write_journal_phase

    def fail_after_auth_restore(path: Path, journal: dict, phase: str) -> None:
        if phase == "auth_restored":
            raise OSError("injected crash after auth restore")
        real_write_phase(path, journal, phase)

    monkeypatch.setattr(enrollment, "_write_journal_phase", fail_after_auth_restore)
    with pytest.raises(OSError, match="injected crash"):
        rollback_codex_promotion(registry, target, transaction)
    monkeypatch.setattr(enrollment, "_write_journal_phase", real_write_phase)

    assert recover_pending_codex_transaction(registry, target) is True
    assert "old-test-token" in target_auth.read_text(encoding="utf-8")
    assert quota_path(registry, target.id).read_bytes() == old_quota
    assert not transaction.journal_path.exists()
    discard_codex_promotion(promotion, target)
    discard_codex_stage(registry, stage, target)


def test_codex_stage_does_not_modify_custom_existing_parent(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    parent = tmp_path / "shared-parent"
    parent.mkdir(mode=0o755)
    profile = replace(registry.require_profile("codex-1"), home=parent / "codex-home")

    stage = create_codex_login_stage(registry, profile)

    assert stat.S_IMODE(parent.stat().st_mode) == 0o755
    assert stage.home.parent == registry.settings.state_dir / "staging" / "codex"
    discard_codex_stage(registry, stage, profile)


def test_provider_maintenance_marker_blocks_new_lease(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, "codex-1")
    with (
        provider_enrollment_lock(
            registry.settings.state_dir,
            "codex",
            registry.settings.lock_stale_seconds,
        ),
        pytest.raises(ValueError, match="provider maintenance is in progress"),
    ):
        select_and_acquire(
            registry,
            task="blocked-by-maintenance",
            pool="codex-crew",
            profile_id="codex-1",
            workspace=Path.cwd(),
        )


def test_provider_maintenance_rejects_stale_registry_before_recovery(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    _, config = fleet
    stale = load_registry(config)
    profiles = dict(stale.profiles)
    profiles["codex-1"] = replace(profiles["codex-1"], reserve_percent=42)
    save_registry(replace(stale, profiles=profiles), config)
    recovered: list[str] = []
    monkeypatch.setattr(
        cli_module,
        "recover_pending_codex_transactions",
        lambda *_args, **_kwargs: recovered.append("recovery"),
    )

    with (
        pytest.raises(ValueError, match="registry changed before provider maintenance"),
        cli_module._provider_maintenance(stale, config, {"codex"}),
    ):
        pass

    assert recovered == []


def test_enrollment_rejects_stale_registry_before_auth_recovery(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    _, config = fleet
    stale = load_registry(config)
    profile = stale.require_profile("codex-1")
    profiles = dict(stale.profiles)
    profiles[profile.id] = replace(profile, reserve_percent=41)
    save_registry(replace(stale, profiles=profiles), config)
    recovered: list[str] = []
    monkeypatch.setattr(
        cli_module,
        "recover_pending_codex_transactions",
        lambda *_args, **_kwargs: recovered.append("recovery"),
    )
    with pytest.raises(ValueError, match="registry changed before provider enrollment"):
        cli_module._run_profile_enrollment(stale, profile, config)

    assert recovered == []


def test_profile_add_obeys_provider_maintenance_lock(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    registry = load_registry(config)
    project_root = Path(__file__).parents[1]
    env = dict(os.environ)
    env["PYTHONPATH"] = str(project_root / "src")
    with provider_enrollment_lock(
        registry.settings.state_dir,
        "claude",
        registry.settings.lock_stale_seconds,
    ):
        result = subprocess.run(
            [
                sys.executable,
                "-m",
                "agent_fleet",
                "--format",
                "json",
                "--config",
                str(config),
                "profile",
                "add",
                "claude-4",
                "--provider",
                "claude",
            ],
            cwd=Path.cwd(),
            env=env,
            text=True,
            capture_output=True,
            timeout=20,
            check=False,
        )
    assert result.returncode == 2
    assert "provider maintenance is already in progress" in json.loads(result.stdout)["error"]
    assert "claude-4" not in load_registry(config).profiles


def test_dry_run_selection_never_enters_mutating_state_lock(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, "claude-1")
    state_before = _state_snapshot(registry.settings.state_dir)

    def refuse_state_lock(*_args, **_kwargs):
        raise AssertionError("dry-run selection entered the mutating state lock")

    monkeypatch.setattr(scheduler_module, "state_lock", refuse_state_lock)
    selected = select_and_acquire(
        registry,
        task="read-only-observe",
        pool="claude-crew",
        profile_id="claude-1",
        dry_run=True,
        workspace=Path.cwd(),
    )

    assert selected["dry_run"] is True
    assert selected["workspace"] == str(Path.cwd())
    assert _state_snapshot(registry.settings.state_dir) == state_before


def test_pending_credential_journal_fences_control_plane_after_policy_drift(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    registry = load_registry(config)
    journal_path = _write_pending_credential_journal(registry, "codex", "codex-1")

    with pytest.raises(ValueError, match="blocks profile selection"):
        select_and_acquire(
            registry,
            task="pending-credential-dry-run",
            pool="codex-crew",
            profile_id="codex-1",
            dry_run=True,
            workspace=Path.cwd(),
        )
    with pytest.raises(ValueError, match="blocks profile enablement change"):
        set_profile_enabled(registry, "codex-1", True)
    with pytest.raises(ValueError, match="blocks profile safety-policy change"):
        set_profile_safety_policy(registry, "codex-1", "manual_only")
    with pytest.raises(ValueError, match="blocks routing cooldown mutation"):
        set_cooldown(registry, "codex-1", seconds=60, reason="test fence")
    with pytest.raises(ValueError, match="blocks routing cooldown mutation"):
        clear_cooldown(registry, "codex-1")
    with pytest.raises(ValueError, match="blocks registry mutation"):
        cli_module._mutate(registry, lambda current: current, config)
    with (
        pytest.raises(ValueError, match="blocks provider maintenance"),
        cli_module._provider_maintenance(registry, config, {"codex"}),
    ):
        pass
    with pytest.raises(ValueError, match="blocks provider enrollment"):
        cli_module._run_profile_enrollment(
            registry,
            registry.require_profile("codex-1"),
            config,
        )

    profiles = dict(registry.profiles)
    profiles["codex-1"] = replace(
        profiles["codex-1"],
        enabled=False,
        pools=("codex-manual",),
        safety_policy="manual_only",
    )
    save_registry(replace(registry, profiles=profiles), config)
    drifted = load_registry(config)
    with pytest.raises(ValueError, match="blocks profile selection"):
        select_and_acquire(
            drifted,
            task="policy-hidden-pending-credential",
            pool="codex-crew",
            dry_run=True,
            workspace=Path.cwd(),
        )
    with (
        provider_enrollment_lock(
            drifted.settings.state_dir,
            "codex",
            drifted.settings.lock_stale_seconds,
        ),
        pytest.raises(ValueError, match="hidden by profile topology drift"),
    ):
        recover_pending_profile_recoveries(drifted, "codex")
    assert journal_path.exists()


def test_lease_creation_and_binding_require_process_start_tokens(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    _, config = fleet
    registry = load_registry(config)
    monkeypatch.setattr(leases, "process_start_token", lambda _pid: None)
    with pytest.raises(ValueError, match="verified process start token"):
        new_lease(
            "no-start-token",
            "codex-1",
            "codex-crew",
            provider="codex",
            workspace=Path.cwd(),
            pid=os.getpid(),
        )
    with pytest.raises(ValueError, match="verified process start token"):
        bind_lease(
            registry,
            new_lease(
                "reserved",
                "codex-1",
                "codex-crew",
                provider="codex",
                workspace=Path.cwd(),
                pid=None,
            ),
            os.getpid(),
        )


def test_corrupt_lease_state_never_routes_prunes_or_releases(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, "claude-1")
    corrupt = lease_path(registry, "corrupt-owner")
    corrupt.parent.mkdir(parents=True, exist_ok=True)
    corrupt.parent.chmod(0o700)
    corrupt.write_bytes(b'{"schema":2,"task":')
    corrupt.chmod(0o600)
    original = corrupt.read_bytes()

    with pytest.raises(ValueError, match="corrupt worker lease"):
        active_leases(registry, prune=True)
    assert corrupt.read_bytes() == original
    with pytest.raises(ValueError, match="corrupt worker lease"):
        select_and_acquire(
            registry,
            task="must-not-route",
            pool="claude-crew",
            profile_id="claude-1",
            workspace=Path.cwd(),
        )
    with pytest.raises(ValueError, match="corrupt worker lease"):
        release_lease(registry, "corrupt-owner", force=True)
    assert corrupt.read_bytes() == original

    corrupt.unlink()
    wrong = corrupt.parent / "wrong-filename.json"
    atomic_write_json(
        wrong,
        new_lease(
            "right-task",
            "claude-1",
            "claude-crew",
            provider="claude",
            workspace=Path.cwd(),
            pid=None,
        ),
    )
    wrong_bytes = wrong.read_bytes()
    with pytest.raises(ValueError, match="filename does not match"):
        active_leases(registry, prune=True)
    assert wrong.read_bytes() == wrong_bytes

    wrong.unlink()
    malformed_time = new_lease(
        "bad-time",
        "claude-1",
        "claude-crew",
        provider="claude",
        workspace=Path.cwd(),
        pid=None,
    )
    malformed_time["created_at"] = "yesterday"
    timed = lease_path(registry, "bad-time")
    atomic_write_json(timed, malformed_time)
    timed_bytes = timed.read_bytes()
    with pytest.raises(ValueError, match="corrupt worker lease"):
        active_leases(registry, prune=True)
    assert timed.read_bytes() == timed_bytes


def test_corrupt_cooldown_state_blocks_selection_without_rewrite(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, "codex-1")
    path = cooldown_path(registry, "codex-1")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.parent.chmod(0o700)
    path.write_bytes(b'{"schema":1,"profile":"someone-else"}')
    path.chmod(0o600)
    original = path.read_bytes()

    with pytest.raises(ValueError, match="corrupt cooldown state"):
        select_and_acquire(
            registry,
            task="cooldown-corrupt",
            pool="codex-crew",
            profile_id="codex-1",
            workspace=Path.cwd(),
        )
    assert path.read_bytes() == original


def test_lock_creation_requires_process_start_token(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    _, config = fleet
    registry = load_registry(config)
    monkeypatch.setattr(locks, "process_start_token", lambda _pid: None)
    with pytest.raises(RuntimeError, match="verified process start token"):
        provider_enrollment_lock(
            registry.settings.state_dir,
            "codex",
            registry.settings.lock_stale_seconds,
        )


def test_ensure_private_dir_rejects_symlink_non_directory_and_unsafe_mode(
    tmp_path: Path,
) -> None:
    target = tmp_path / "target"
    target.mkdir(mode=0o700)
    link = tmp_path / "link"
    link.symlink_to(target, target_is_directory=True)
    with pytest.raises(ValueError, match="unsafe private directory"):
        ensure_private_dir(link)
    assert stat.S_IMODE(target.stat().st_mode) == 0o700

    regular = tmp_path / "regular"
    regular.write_text("not a directory\n", encoding="utf-8")
    with pytest.raises(ValueError, match="unsafe private directory"):
        ensure_private_dir(regular)

    public = tmp_path / "public"
    public.mkdir(mode=0o755)
    public.chmod(0o755)
    with pytest.raises(ValueError, match="mode 0700"):
        ensure_private_dir(public)
    assert stat.S_IMODE(public.stat().st_mode) == 0o755


def test_ensure_private_dir_rejects_wrong_owner_without_mutation(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    target = tmp_path / "private"
    target.mkdir(mode=0o700)
    before = target.stat()
    monkeypatch.setattr(os, "getuid", lambda: before.st_uid + 1)
    with pytest.raises(ValueError, match="current-user owned"):
        ensure_private_dir(target)
    after = target.stat()
    assert (after.st_uid, stat.S_IMODE(after.st_mode)) == (
        before.st_uid,
        stat.S_IMODE(before.st_mode),
    )


def test_directory_lock_post_mkdir_race_never_overlaps_owners(tmp_path: Path) -> None:
    context = multiprocessing.get_context("spawn")
    path = tmp_path / "locks" / "post-mkdir.lock"
    path.parent.mkdir(mode=0o700)
    ready_a = context.Event()
    go_a = context.Event()
    release_a = context.Event()
    ready_b = context.Event()
    go_b = context.Event()
    go_b.set()
    release_b = context.Event()
    outcomes = context.Queue()
    first = context.Process(
        target=_directory_lock_process,
        args=(str(path), "post-mkdir", ready_a, go_a, release_a, outcomes),
    )
    second = context.Process(
        target=_directory_lock_process,
        args=(str(path), None, ready_b, go_b, release_b, outcomes),
    )
    first.start()
    assert ready_a.wait(timeout=10)
    second.start()
    kind, second_pid = outcomes.get(timeout=10)[:2]
    assert kind == "entered"
    assert second_pid == second.pid

    go_a.set()
    first.join(timeout=10)
    assert not first.is_alive()
    first_outcome = outcomes.get(timeout=10)
    assert first_outcome[0] == "error"
    assert first_outcome[1] == first.pid

    release_b.set()
    second.join(timeout=10)
    assert not second.is_alive()
    assert outcomes.get(timeout=10) == ("released", second.pid)
    assert not path.exists()


def test_directory_lock_rechecks_quarantined_owner_after_rename(tmp_path: Path) -> None:
    context = multiprocessing.get_context("spawn")
    path = tmp_path / "locks" / "post-rename.lock"
    path.parent.mkdir(mode=0o700)
    ready_a = context.Event()
    go_a = context.Event()
    release_a = context.Event()
    ready_b = context.Event()
    go_b = context.Event()
    release_b = context.Event()
    outcomes = context.Queue()
    first = context.Process(
        target=_directory_lock_process,
        args=(str(path), "post-mkdir", ready_a, go_a, release_a, outcomes),
    )
    second = context.Process(
        target=_directory_lock_process,
        args=(str(path), "post-reclaim-rename", ready_b, go_b, release_b, outcomes),
    )
    first.start()
    assert ready_a.wait(timeout=10)
    second.start()
    assert ready_b.wait(timeout=10)

    go_a.set()
    first.join(timeout=10)
    assert not first.is_alive()
    first_outcome = outcomes.get(timeout=10)
    assert first_outcome[0] == "error"
    assert first_outcome[1] == first.pid

    go_b.set()
    entered = outcomes.get(timeout=10)
    assert entered == ("entered", second.pid)
    release_b.set()
    second.join(timeout=10)
    assert not second.is_alive()
    assert outcomes.get(timeout=10) == ("released", second.pid)
    assert not path.exists()


def test_directory_lock_failed_creator_removes_its_exact_live_quarantine(
    tmp_path: Path,
) -> None:
    context = multiprocessing.get_context("spawn")
    path = tmp_path / "locks" / "three-contender.lock"
    path.parent.mkdir(mode=0o700)
    ready_a, go_a, release_a = context.Event(), context.Event(), context.Event()
    ready_b, go_b, release_b = context.Event(), context.Event(), context.Event()
    ready_c, go_c, release_c = context.Event(), context.Event(), context.Event()
    outcomes = context.Queue()
    first = context.Process(
        target=_directory_lock_process,
        args=(str(path), "post-mkdir", ready_a, go_a, release_a, outcomes),
    )
    reclaimer = context.Process(
        target=_directory_lock_process,
        args=(
            str(path),
            "post-reclaim-rename",
            ready_b,
            go_b,
            release_b,
            outcomes,
        ),
    )
    successor = context.Process(
        target=_directory_lock_process,
        args=(str(path), "pre-mkdir", ready_c, go_c, release_c, outcomes),
    )

    first.start()
    assert ready_a.wait(timeout=10)
    successor.start()
    assert ready_c.wait(timeout=10)
    reclaimer.start()
    assert ready_b.wait(timeout=10)

    go_c.set()
    assert outcomes.get(timeout=10) == ("entered", successor.pid)
    go_a.set()
    first.join(timeout=10)
    assert not first.is_alive()
    failed = outcomes.get(timeout=10)
    assert failed[0] == "error"
    assert failed[1] == first.pid
    assert not list(path.parent.glob(f".{path.name}.stale.*"))

    go_b.set()
    release_c.set()
    successor.join(timeout=10)
    assert not successor.is_alive()
    assert outcomes.get(timeout=10) == ("released", successor.pid)
    assert outcomes.get(timeout=10) == ("entered", reclaimer.pid)
    release_b.set()
    reclaimer.join(timeout=10)
    assert not reclaimer.is_alive()
    assert outcomes.get(timeout=10) == ("released", reclaimer.pid)
    assert not path.exists()
    assert not list(path.parent.glob(f".{path.name}.*"))


def test_indeterminate_process_probe_never_prunes_lease_or_reclaims_lock(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    lease = new_lease(
        "indeterminate-owner",
        "codex-1",
        "codex-crew",
        provider="codex",
        workspace=Path.cwd(),
        pid=os.getpid(),
    )
    leases.write_lease(registry, lease)
    path = lease_path(registry, "indeterminate-owner")
    before = path.read_bytes()
    lock_path = tmp_path / "locks" / "indeterminate.lock"
    owner = DirectoryLock(lock_path, stale_seconds=0)
    contender = DirectoryLock(lock_path, stale_seconds=0, timeout=0)
    owner.acquire()

    def failed_ps(*_args: object, **_kwargs: object) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess([], 2, "", "transient ps failure")

    monkeypatch.setattr(util.subprocess, "run", failed_ps)

    assert active_leases(registry, prune=True) == [lease]
    assert path.read_bytes() == before
    with pytest.raises(TimeoutError):
        contender.acquire()
    assert lock_path.exists()
    owner.release()


@pytest.mark.parametrize("profile_id", ["claude-1", "codex-1"])
def test_enrollment_refuses_while_managed_provider_launch_is_alive(
    fleet: tuple[object, Path], profile_id: str
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, profile_id)
    profile = registry.require_profile(profile_id)
    select_and_acquire(
        registry,
        task=f"live-{profile.provider}-worker",
        pool=f"{profile.provider}-crew",
        profile_id=profile.id,
        bind_pid=os.getpid(),
        workspace=Path.cwd(),
    )
    profiles = dict(registry.profiles)
    profiles[profile.id] = replace(profile, enabled=False)
    save_registry(replace(registry, profiles=profiles), config)

    project_root = Path(__file__).parents[1]
    env = dict(os.environ)
    env["PYTHONPATH"] = str(project_root / "src")
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "agent_fleet",
            "--format",
            "json",
            "--config",
            str(config),
            "profile",
            "enroll",
            profile.id,
        ],
        cwd=Path.cwd(),
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 2
    assert "while any same-provider Fleet lease is active" in json.loads(result.stdout)["error"]


def test_claude_desktop_switch_is_seen_on_the_next_selection(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, "claude-1")
    selected = select_and_acquire(
        registry,
        task="before-desktop-switch",
        pool="claude-crew",
        profile_id="claude-1",
        dry_run=True,
        workspace=Path.cwd(),
    )
    assert selected["profile"] == "claude-1"
    desktop_file = registry.require_provider("claude").desktop_identity_file
    assert desktop_file is not None
    desktop_file.write_text(
        json.dumps({"lastKnownAccountUuid": "claude-1-account"}),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="duplicate_provider_identity"):
        select_and_acquire(
            registry,
            task="after-desktop-switch",
            pool="claude-crew",
            profile_id="claude-1",
            dry_run=True,
            workspace=Path.cwd(),
        )


def test_bundle_adoption_rejects_final_external_identity_race(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    _, config = fleet
    registry = load_registry(config)
    workers = [
        profile
        for profile in registry.profiles.values()
        if profile.provider == "claude" and profile.safety_policy == "worker"
    ]
    proofs = {
        profile.id: (
            read_quota(registry, profile.id),
            inspect_credential_source_contract(registry, profile),
        )
        for profile in workers
    }
    worker_fingerprint = proofs[workers[0].id][0]["identity_fingerprint"]
    bundle_path = identity_bundle_path(registry, "claude")
    before = bundle_path.read_bytes()
    real_refresh = identity.refresh_provider_identity_anchors

    def switch_base_during_final_refresh(*args, **kwargs):
        result = real_refresh(*args, **kwargs)
        raced_base = {**result["base"], "identity_fingerprint": worker_fingerprint}
        atomic_write_json(
            registry.settings.state_dir / "identity-anchors" / "claude-base.json",
            raced_base,
        )
        return {**result, "base": raced_base}

    monkeypatch.setattr(
        identity,
        "refresh_provider_identity_anchors",
        switch_base_during_final_refresh,
    )

    with pytest.raises(ValueError, match="conflicts with final base identity"):
        adopt_provider_identity_bundle(registry, "claude", proofs)

    assert bundle_path.read_bytes() == before


def test_claude_default_anchor_environment_is_distinct_from_worker_home(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    _, config = fleet
    registry = load_registry(config)
    worker = registry.require_profile("claude-1")
    base = replace(worker, id="claude-base-anchor", home=current_user_home() / ".claude")
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", "/tmp/ambient-claude")
    monkeypatch.setenv("CLAUDE_SECURESTORAGE_CONFIG_DIR", "/tmp/ambient-storage")

    base_environment = provider_environment(base, default_provider_home=True)
    worker_environment = provider_environment(worker)

    assert "CLAUDE_CONFIG_DIR" not in base_environment
    assert "CLAUDE_SECURESTORAGE_CONFIG_DIR" not in base_environment
    assert worker_environment["CLAUDE_CONFIG_DIR"] == str(worker.home)
    assert "CLAUDE_SECURESTORAGE_CONFIG_DIR" not in worker_environment


def test_hostile_home_cannot_change_default_claude_base_semantics_or_read_it(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    fake_passwd_home = tmp_path / "passwd-home"
    canonical_base = fake_passwd_home / ".claude"
    canonical_base.mkdir(parents=True, mode=0o700)
    hostile_home = tmp_path / "hostile-home"
    hostile_home.mkdir(mode=0o700)
    monkeypatch.setenv("HOME", str(hostile_home))
    monkeypatch.setattr(identity, "current_user_home", lambda: fake_passwd_home)
    provider = registry.require_provider("claude")
    providers = dict(registry.providers)
    providers["claude"] = replace(provider, base_home=canonical_base)
    registry = replace(registry, providers=providers)
    observed: dict[str, object] = {"credential_homes": []}

    def no_live_credential_read(profile):
        observed["credential_homes"].append(profile.home)
        return "absent", None

    def fake_metadata(**_kwargs):
        observed["metadata_calls"] = int(observed.get("metadata_calls", 0)) + 1
        return "absent", None

    def unexpected_probe(*_args, **_kwargs):
        raise AssertionError("proven-absent Keychain should not invoke Quota")

    monkeypatch.setattr(identity, "_credential_snapshot", no_live_credential_read)
    monkeypatch.setattr(identity, "_claude_keychain_metadata_snapshot", fake_metadata)
    monkeypatch.setattr(identity, "probe_quota", unexpected_probe)

    result = refresh_provider_identity_anchors(registry, "claude")["base"]

    assert result["status"] == "absent"
    assert observed["metadata_calls"] == 2
    assert identity._claude_keychain_marker_path().is_relative_to(fake_passwd_home)
    assert canonical_base in observed["credential_homes"]
    assert hostile_home not in canonical_base.parents


@pytest.mark.parametrize("provider_name", ["claude", "codex"])
def test_base_identity_probe_uses_and_cleans_fleet_owned_shadow(
    fleet: tuple[object, Path], provider_name: str
) -> None:
    _, config = fleet
    registry = load_registry(config)
    base_home = registry.require_provider(provider_name).base_home
    assert base_home is not None
    before = _state_snapshot(base_home)

    refresh_provider_identity_anchors(registry, provider_name)

    assert _state_snapshot(base_home) == before
    shadow_parent = registry.settings.state_dir / "identity-shadows"
    assert shadow_parent.is_dir()
    assert list(shadow_parent.iterdir()) == []


@pytest.mark.parametrize(
    "phase",
    [
        "directory_created",
        "owner_temp_fsynced",
        "owner_published",
        "credential_copied",
    ],
)
def test_crashed_identity_shadow_is_recovered_only_after_owner_is_dead(
    fleet: tuple[object, Path], phase: str
) -> None:
    _, config = fleet
    registry = load_registry(config)
    provider = registry.require_provider("codex")
    assert provider.base_home is not None
    profile = replace(
        registry.require_profile("codex-1"),
        id="codex-base-anchor",
        home=provider.base_home,
        pools=("codex-manual",),
        enabled=False,
        safety_policy="desktop_shared",
    )
    snapshot = identity._credential_snapshot(profile)
    receive, send = multiprocessing.Pipe(duplex=False)
    process = multiprocessing.Process(
        target=_crash_identity_shadow_after_phase,
        args=(registry, profile, snapshot, phase, send),
    )
    process.start()
    send.close()
    leaked = Path(receive.recv())
    receive.close()
    process.join(timeout=10)
    assert process.exitcode == 91
    assert leaked.is_dir()
    if phase in {"directory_created", "owner_temp_fsynced"}:
        old = time.time() - identity._SHADOW_OWNERLESS_GRACE_SECONDS - 1
        os.utime(leaked, (old, old))

    result = identity._recover_stale_identity_shadows(leaked.parent)

    assert leaked.name in result["removed"]
    assert not leaked.exists()
    assert "base-test-token" not in repr(result)


def test_identity_shadow_cleanup_restart_keeps_owner_until_payload_is_gone(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    _, config = fleet
    registry = load_registry(config)
    provider = registry.require_provider("codex")
    assert provider.base_home is not None
    profile = replace(
        registry.require_profile("codex-1"),
        id="codex-base-anchor",
        home=provider.base_home,
        pools=("codex-manual",),
        enabled=False,
        safety_policy="desktop_shared",
    )
    shadow = identity._BaseIdentityShadow(
        registry,
        profile,
        identity._credential_snapshot(profile),
    )
    shadow_profile = shadow.__enter__()
    assert shadow.name is not None
    assert shadow.identity is not None
    root = shadow_profile.home
    extra = root / "second-private-payload"
    extra.write_text("must be restart-cleaned\n", encoding="utf-8")
    extra.chmod(0o600)
    original_remove = identity._remove_shadow_payload_entry
    removed = 0

    def crash_after_first_payload(directory_fd: int, name: str) -> None:
        nonlocal removed
        original_remove(directory_fd, name)
        removed += 1
        if removed == 1:
            raise RuntimeError("simulated process death during payload cleanup")

    monkeypatch.setattr(identity, "_remove_shadow_payload_entry", crash_after_first_payload)
    with pytest.raises(RuntimeError, match="simulated process death"):
        shadow._cleanup()

    deleting = list(shadow.parent.glob(f"{shadow.name}.deleting-*"))
    assert len(deleting) == 1
    assert (deleting[0] / "owner.json").is_file()
    assert any(path.name != "owner.json" for path in deleting[0].iterdir())

    monkeypatch.setattr(identity, "_remove_shadow_payload_entry", original_remove)
    monkeypatch.setattr(identity, "process_identity_state", lambda *_args: "dead")
    recovered = identity._recover_stale_identity_shadows(shadow.parent)

    assert deleting[0].name in recovered["removed"]
    assert not deleting[0].exists()
    shadow.name = None
    shadow.identity = None


def test_identity_shadow_recovery_preserves_live_foreign_and_unsafe_entries(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    provider = registry.require_provider("codex")
    assert provider.base_home is not None
    profile = replace(
        registry.require_profile("codex-1"),
        id="codex-base-anchor",
        home=provider.base_home,
        pools=("codex-manual",),
        enabled=False,
        safety_policy="desktop_shared",
    )
    snapshot = identity._credential_snapshot(profile)
    shadow = identity._BaseIdentityShadow(registry, profile, snapshot)
    shadow_profile = shadow.__enter__()
    assert shadow.name is not None
    parent = shadow_profile.home.parent if profile.provider == "claude" else shadow_profile.home
    shadow_parent = parent.parent
    foreign = shadow_parent / "foreign-sentinel"
    foreign.mkdir(mode=0o700)
    (foreign / "keep").write_text("foreign\n", encoding="utf-8")
    outside = tmp_path / "outside-shadow"
    outside.mkdir(mode=0o700)
    (outside / "keep").write_text("outside\n", encoding="utf-8")
    unsafe_link = shadow_parent / f".codex-base-{'a' * 32}"
    unsafe_link.symlink_to(outside, target_is_directory=True)
    ownerless = shadow_parent / f".codex-base-{'b' * 32}"
    ownerless.mkdir(mode=0o700)
    (ownerless / "credential-copy").write_text("must-survive\n", encoding="utf-8")
    hardlinked = shadow_parent / f".codex-base-{'c' * 32}"
    hardlinked.mkdir(mode=0o700)
    hardlinked_temp = hardlinked / f".owner.json.{'e' * 32}.tmp"
    hardlinked_temp.write_text("non-secret owner temporary\n", encoding="utf-8")
    hardlinked_temp.chmod(0o600)
    os.link(hardlinked_temp, tmp_path / "owner-temporary-hardlink")
    bad_mode = shadow_parent / f".codex-base-{'d' * 32}"
    bad_mode.mkdir(mode=0o700)
    bad_mode_temp = bad_mode / f".owner.json.{'f' * 32}.tmp"
    bad_mode_temp.write_text("non-secret owner temporary\n", encoding="utf-8")
    bad_mode_temp.chmod(0o644)
    old = time.time() - identity._SHADOW_OWNERLESS_GRACE_SECONDS - 1
    for candidate in (ownerless, hardlinked, bad_mode):
        os.utime(candidate, (old, old))

    result = identity._recover_stale_identity_shadows(shadow_parent)

    assert shadow.name in result["live"]
    assert foreign.name in result["foreign"]
    assert unsafe_link.name in result["unsafe"]
    assert ownerless.name in result["unsafe"]
    assert hardlinked.name in result["unsafe"]
    assert bad_mode.name in result["unsafe"]
    assert foreign.is_dir()
    assert unsafe_link.is_symlink()
    assert ownerless.is_dir()
    assert hardlinked.is_dir()
    assert bad_mode.is_dir()
    assert (outside / "keep").read_text(encoding="utf-8") == "outside\n"
    shadow.__exit__(None, None, None)


def test_claude_base_quota_is_shadowed_without_browser_or_provider_launch(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    base_home = registry.require_provider("claude").base_home
    assert base_home is not None
    provider_marker = tmp_path / "claude-provider-launched"
    provider_binary = tmp_path / "claude-provider"
    provider_binary.write_text(
        f"#!/bin/sh\n/usr/bin/touch {str(provider_marker)!r}\nexit 91\n",
        encoding="utf-8",
    )
    provider_binary.chmod(0o755)
    providers = dict(registry.providers)
    providers["claude"] = replace(providers["claude"], binary=provider_binary)
    registry = replace(registry, providers=providers)
    monkeypatch.setenv("BROWSER", "/tmp/ambient-browser")
    observed: dict[str, object] = {}
    real_run = subprocess.run

    def quota_result(argv, **kwargs):
        if "env" not in kwargs:
            return real_run(argv, **kwargs)
        observed["argv"] = argv
        observed["env"] = kwargs["env"]
        observed["cwd"] = kwargs["cwd"]
        return subprocess.CompletedProcess(
            argv,
            0,
            stdout=json.dumps(
                {
                    "providers": [
                        {
                            "provider": "claude",
                            "account": {"accountId": "claude-base-anchor-account"},
                            "state": {
                                "status": "fresh",
                                "refreshedAt": datetime.now(UTC).isoformat(),
                            },
                            "windows": [
                                {
                                    "id": "five_hour",
                                    "kind": "session",
                                    "percentRemaining": 80,
                                }
                            ],
                        }
                    ]
                }
            ),
            stderr="",
        )

    monkeypatch.setattr(quota_module.subprocess, "run", quota_result)
    before = _state_snapshot(base_home)

    result = refresh_provider_identity_anchors(registry, "claude")["base"]

    assert result["status"] == "present"
    assert _state_snapshot(base_home) == before
    assert not provider_marker.exists()
    environment = observed["env"]
    assert isinstance(environment, dict)
    assert environment["HOME"] != str(base_home)
    assert environment["CLAUDE_CONFIG_DIR"] != str(base_home)
    assert "BROWSER" not in environment
    assert observed["cwd"] != base_home
    assert str(observed["cwd"]).startswith(
        str(registry.settings.state_dir / "identity-shadows")
    )


def _default_claude_keychain_registry(
    registry,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
):
    passwd_home = tmp_path / "passwd-home"
    base_home = passwd_home / ".claude"
    base_home.mkdir(parents=True, mode=0o700)
    passwd_home.chmod(0o700)
    base_home.chmod(0o700)
    provider = registry.require_provider("claude")
    providers = dict(registry.providers)
    providers["claude"] = replace(provider, base_home=base_home)
    monkeypatch.setattr(identity, "current_user_home", lambda: passwd_home)
    return replace(registry, providers=providers), passwd_home, base_home


def _fresh_claude_base_quota(profile) -> dict[str, object]:
    return {
        "status": "fresh",
        "verified_at": datetime.now(UTC).isoformat(),
        "headroom_percent": 80,
        "windows": [{"id": "five_hour", "remaining_percent": 80}],
        "identity_fingerprint": identity_fingerprint(
            profile.provider, "keychain-base-account"
        ),
        "credential_state": "present",
        "credential_keychain_account": current_user_name(),
    }


def test_default_claude_keychain_marker_is_shadowed_only_for_bound_item_and_runtime(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _, config = fleet
    registry, passwd_home, _base_home = _default_claude_keychain_registry(
        load_registry(config), tmp_path, monkeypatch
    )
    metadata_digest = "a" * 64
    monkeypatch.setattr(
        identity,
        "_claude_keychain_metadata_snapshot",
        lambda **_kwargs: ("present", metadata_digest),
    )
    identity._record_claude_keychain_grant(registry, metadata_digest)
    observed: dict[str, object] = {}

    def fake_probe(_registry, profile, **kwargs):
        observed["profile_home"] = profile.home
        observed["kwargs"] = kwargs
        shadow_marker = (
            profile.home.parent
            / ".cache"
            / "quota-axi"
            / "claude-keychain-access-granted"
        )
        observed["marker"] = shadow_marker.read_bytes()
        observed["marker_mode"] = stat.S_IMODE(shadow_marker.stat().st_mode)
        return _fresh_claude_base_quota(profile)

    monkeypatch.setattr(identity, "probe_quota", fake_probe)
    result = refresh_provider_identity_anchors(registry, "claude")["base"]

    assert result["status"] == "present"
    assert observed["marker"] == b"granted\n"
    assert observed["marker_mode"] == 0o600
    assert observed["kwargs"] == {
        "timeout": 30,
        "allow_keychain_prompt": False,
        "default_provider_home": True,
    }
    assert str(observed["profile_home"]).startswith(
        str(registry.settings.state_dir / "identity-shadows")
    )
    assert (
        passwd_home / ".cache" / "quota-axi" / "claude-keychain-access-granted"
    ).read_bytes() == b"granted\n"


def test_explicit_default_claude_keychain_grant_persists_bound_contract(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _, config = fleet
    registry, passwd_home, _base_home = _default_claude_keychain_registry(
        load_registry(config), tmp_path, monkeypatch
    )
    metadata_digest = "b" * 64
    monkeypatch.setattr(
        identity,
        "_claude_keychain_metadata_snapshot",
        lambda **_kwargs: ("present", metadata_digest),
    )
    observed: list[dict[str, object]] = []

    def fake_probe(_registry, profile, **kwargs):
        observed.append(kwargs)
        marker = (
            profile.home.parent
            / ".cache"
            / "quota-axi"
            / "claude-keychain-access-granted"
        )
        assert not marker.exists()
        return _fresh_claude_base_quota(profile)

    monkeypatch.setattr(identity, "probe_quota", fake_probe)
    result = refresh_provider_identity_anchors(
        registry,
        "claude",
        allow_keychain_prompt=True,
    )["base"]

    assert result["status"] == "present"
    assert observed == [
        {
            "timeout": 30,
            "allow_keychain_prompt": True,
            "default_provider_home": True,
        }
    ]
    marker = passwd_home / ".cache" / "quota-axi" / "claude-keychain-access-granted"
    assert marker.read_bytes() == b"granted\n"
    assert stat.S_IMODE(marker.stat().st_mode) == 0o600
    contract = json.loads(identity._claude_keychain_grant_path(registry).read_text())
    assert contract["service"] == "Claude Code-credentials"
    assert contract["account"] == current_user_name()
    assert contract["keychain_metadata_sha256"] == metadata_digest
    assert contract["quota_binary_sha256"] == registry.settings.quota_binary_sha256
    assert contract["quota_node_sha256"] == registry.settings.quota_node_sha256
    assert (
        contract["quota_release_tree_sha256"]
        == registry.settings.quota_release_tree_sha256
    )


@pytest.mark.parametrize("account", [None, "different-user"])
def test_default_claude_keychain_rejects_quota_without_exact_attempt_account(
    fleet: tuple[object, Path],
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    account: str | None,
) -> None:
    _, config = fleet
    registry, _passwd_home, _base_home = _default_claude_keychain_registry(
        load_registry(config), tmp_path, monkeypatch
    )
    metadata_digest = "e" * 64
    monkeypatch.setattr(
        identity,
        "_claude_keychain_metadata_snapshot",
        lambda **_kwargs: ("present", metadata_digest),
    )
    identity._record_claude_keychain_grant(registry, metadata_digest)

    def fake_probe(_registry, profile, **_kwargs):
        quota = _fresh_claude_base_quota(profile)
        quota["credential_keychain_account"] = account
        return quota

    monkeypatch.setattr(identity, "probe_quota", fake_probe)
    result = refresh_provider_identity_anchors(registry, "claude")["base"]

    assert result["status"] == "indeterminate"
    assert result["identity_fingerprint"] is None


@pytest.mark.parametrize(
    ("accounts", "expected"),
    [
        ([], None),
        (["different-user"], None),
        (["exact", "exact"], None),
        (["exact"], "exact"),
    ],
)
def test_quota_normalization_requires_one_exact_claude_keychain_attempt_account(
    fleet: tuple[object, Path],
    accounts: list[str],
    expected: str | None,
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = registry.require_profile("claude-1")
    passwd_name = current_user_name()
    raw = {
        "providers": [
            {
                "provider": "claude",
                "account": {"accountId": "normalized-keychain-account"},
                "state": {
                    "status": "fresh",
                    "refreshedAt": datetime.now(UTC).isoformat(),
                },
                "windows": [
                    {
                        "id": "five_hour",
                        "kind": "session",
                        "percentRemaining": 80,
                    }
                ],
                "attempts": [
                    {
                        "source": "keychain",
                        "status": "success",
                        "account": passwd_name if account == "exact" else account,
                    }
                    for account in accounts
                ],
            }
        ]
    }

    normalized = quota_module._normalize(profile, raw)
    assert normalized["credential_keychain_account"] == (
        passwd_name if expected == "exact" else None
    )


@pytest.mark.parametrize("kind", ["symlink", "hardlink", "mode"])
def test_unsafe_default_claude_keychain_marker_fails_before_probe(
    fleet: tuple[object, Path],
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    kind: str,
) -> None:
    _, config = fleet
    registry, passwd_home, _base_home = _default_claude_keychain_registry(
        load_registry(config), tmp_path, monkeypatch
    )
    marker = passwd_home / ".cache" / "quota-axi" / "claude-keychain-access-granted"
    ensure_private_dir(marker.parent)
    outside = tmp_path / f"outside-marker-{kind}"
    outside.write_bytes(b"granted\n")
    outside.chmod(0o600)
    if kind == "symlink":
        marker.symlink_to(outside)
    elif kind == "hardlink":
        os.link(outside, marker)
    else:
        marker.write_bytes(b"granted\n")
        marker.chmod(0o644)
    touched: list[str] = []

    def unexpected_metadata(**_kwargs):
        touched.append("metadata")
        raise AssertionError("unsafe marker reached Keychain metadata inspection")

    def unexpected_probe(*_args, **_kwargs):
        touched.append("provider")
        raise AssertionError("unsafe marker reached Quota/provider inspection")

    monkeypatch.setattr(identity, "_claude_keychain_metadata_snapshot", unexpected_metadata)
    monkeypatch.setattr(identity, "probe_quota", unexpected_probe)
    monkeypatch.setenv("BROWSER", "/tmp/should-not-launch")

    result = refresh_provider_identity_anchors(registry, "claude")["base"]
    assert result["status"] == "indeterminate"
    assert touched == []


def test_stale_or_wrong_account_claude_keychain_contract_cannot_authorize_probe(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _, config = fleet
    registry, _passwd_home, _base_home = _default_claude_keychain_registry(
        load_registry(config), tmp_path, monkeypatch
    )
    enrolled_digest = "c" * 64
    observed_digest = "d" * 64
    identity._record_claude_keychain_grant(registry, enrolled_digest)
    contract_path = identity._claude_keychain_grant_path(registry)
    contract = json.loads(contract_path.read_text(encoding="utf-8"))
    contract["account"] = "different-user"
    atomic_write_json(contract_path, contract)
    monkeypatch.setattr(
        identity,
        "_claude_keychain_metadata_snapshot",
        lambda **_kwargs: ("present", observed_digest),
    )
    touched: list[str] = []

    def unexpected_probe(*_args, **_kwargs):
        touched.append("provider")
        raise AssertionError("stale Keychain contract reached provider inspection")

    monkeypatch.setattr(identity, "probe_quota", unexpected_probe)
    result = refresh_provider_identity_anchors(registry, "claude")["base"]

    assert result["status"] == "indeterminate"
    assert touched == []


def test_claude_keychain_metadata_uses_exact_account_closed_env_and_no_stdin(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _registry, _config = fleet
    passwd_home = tmp_path / "passwd-home"
    passwd_home.mkdir(mode=0o700)
    monkeypatch.setattr(identity, "current_user_home", lambda: passwd_home)
    monkeypatch.setattr(identity, "current_user_name", lambda: "captain-user")
    monkeypatch.setattr(identity, "_verified_security_binary", lambda: Path("/usr/bin/security"))
    monkeypatch.setenv("DYLD_INSERT_LIBRARIES", "/tmp/hostile.dylib")
    monkeypatch.setenv("LD_PRELOAD", "/tmp/hostile.so")
    observed: dict[str, object] = {}

    def fake_run(argv, **kwargs):
        observed["argv"] = argv
        observed["kwargs"] = kwargs
        return subprocess.CompletedProcess(
            argv,
            0,
            stdout=b'keychain: "login.keychain-db"\n"acct"="captain-user"\n',
            stderr=b"",
        )

    monkeypatch.setattr(identity.subprocess, "run", fake_run)
    state, digest = identity._claude_keychain_metadata_snapshot(timeout=99)

    assert state == "present"
    assert isinstance(digest, str) and len(digest) == 64
    assert observed["argv"] == [
        "/usr/bin/security",
        "find-generic-password",
        "-s",
        "Claude Code-credentials",
        "-a",
        "captain-user",
    ]
    kwargs = observed["kwargs"]
    assert kwargs["stdin"] is subprocess.DEVNULL
    assert kwargs["timeout"] == 5
    assert kwargs["cwd"] == passwd_home
    assert "DYLD_INSERT_LIBRARIES" not in kwargs["env"]
    assert "LD_PRELOAD" not in kwargs["env"]
    assert "-g" not in observed["argv"]
    assert "-w" not in observed["argv"]


@pytest.mark.parametrize("provider_name", ["claude", "codex"])
def test_base_credential_probe_accepts_current_user_0755_provider_home(
    fleet: tuple[object, Path], provider_name: str
) -> None:
    _, config = fleet
    registry = load_registry(config)
    base_home = registry.require_provider(provider_name).base_home
    assert base_home is not None
    base_home.chmod(0o755)

    result = refresh_provider_identity_anchors(registry, provider_name)["base"]

    assert result["status"] == "present"
    assert result["identity_fingerprint"] is not None
    assert stat.S_IMODE(base_home.stat().st_mode) == 0o755


@pytest.mark.parametrize("provider_name", ["claude", "codex"])
@pytest.mark.parametrize("mode", [0o775, 0o777])
def test_base_credential_probe_rejects_writable_provider_home(
    fleet: tuple[object, Path], provider_name: str, mode: int
) -> None:
    _, config = fleet
    registry = load_registry(config)
    base_home = registry.require_provider(provider_name).base_home
    assert base_home is not None
    base_home.chmod(mode)

    result = refresh_provider_identity_anchors(registry, provider_name)["base"]

    assert result["status"] == "indeterminate"
    assert result["identity_fingerprint"] is None
    assert stat.S_IMODE(base_home.stat().st_mode) == mode


@pytest.mark.parametrize("provider_name", ["claude", "codex"])
def test_base_credential_probe_rejects_symlinked_provider_home(
    fleet: tuple[object, Path], tmp_path: Path, provider_name: str
) -> None:
    _, config = fleet
    registry = load_registry(config)
    provider = registry.require_provider(provider_name)
    assert provider.base_home is not None
    linked = tmp_path / f"linked-{provider_name}-base"
    linked.symlink_to(provider.base_home, target_is_directory=True)
    providers = dict(registry.providers)
    providers[provider_name] = replace(provider, base_home=linked)
    registry = replace(registry, providers=providers)

    result = refresh_provider_identity_anchors(registry, provider_name)["base"]

    assert result["status"] == "indeterminate"
    assert result["identity_fingerprint"] is None


def test_codex_base_proof_uses_read_only_shadow_and_is_notification_tolerant(
    fleet: tuple[object, Path], tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _, config = fleet
    registry = load_registry(config)
    base_home = registry.require_provider("codex").base_home
    assert base_home is not None
    binary = tmp_path / "codex-rpc"
    capture = tmp_path / "codex-rpc-capture.json"
    _codex_rpc_fixture(
        binary,
        account={
            "type": "chatgpt",
            "email": "codex-base-anchor@example.invalid",
            "planType": "plus",
        },
        notification=True,
        capture=capture,
    )
    providers = dict(registry.providers)
    providers["codex"] = replace(providers["codex"], binary=binary)
    registry = replace(registry, providers=providers)
    monkeypatch.setenv("CODEX_RPC_AMBIENT_SENTINEL", "must-not-pass")
    before = _state_snapshot(base_home)

    result = refresh_provider_identity_anchors(registry, "codex", timeout=3)["base"]

    observed = json.loads(capture.read_text(encoding="utf-8"))
    assert result["status"] == "present"
    assert result["identity_fingerprint"] == identity_fingerprint(
        "codex", "codex-base-anchor@example.invalid"
    )
    assert observed["argv"] == ["-s", "read-only", "-a", "untrusted", "app-server"]
    shadow = observed["env"]["CODEX_HOME"]
    assert shadow != str(base_home)
    assert observed["env"]["HOME"] == shadow
    assert observed["env"]["CODEX_SQLITE_HOME"] == shadow
    assert not Path(shadow).exists()
    assert observed["env"]["PATH"] == CONTROL_PATH
    assert "CODEX_RPC_AMBIENT_SENTINEL" not in observed["env"]
    assert not any(argument in {"login", "auth", "browser"} for argument in observed["argv"])
    assert _state_snapshot(base_home) == before


def _isolated_codex_probe_profile(registry, root: Path):
    root.mkdir(mode=0o700)
    return replace(registry.require_profile("codex-1"), home=root)


def test_codex_app_server_null_openai_account_proves_absence(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = _isolated_codex_probe_profile(registry, tmp_path / "codex-shadow")
    binary = tmp_path / "codex-rpc-signed-out"
    _codex_rpc_fixture(binary, account=None)

    assert identity._codex_app_server_identity(profile, binary, timeout=3) == {
        "status": "absent",
        "identity_fingerprint": None,
    }


@pytest.mark.parametrize(
    ("account", "requires_openai_auth", "message"),
    [
        (
            {"type": "chatgpt", "email": None, "planType": "plus"},
            True,
            "identity is unavailable",
        ),
        (
            {"type": "apiKey", "email": "api@example.invalid"},
            True,
            "unsupported account mode",
        ),
        (
            {"type": "chatgpt", "email": "hosted@example.invalid"},
            False,
            "not OpenAI-hosted",
        ),
        (None, False, "unsupported account mode"),
    ],
)
def test_codex_app_server_rejects_ambiguous_or_non_fleet_accounts(
    fleet: tuple[object, Path],
    tmp_path: Path,
    account: object,
    requires_openai_auth: object,
    message: str,
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = _isolated_codex_probe_profile(registry, tmp_path / "codex-shadow")
    binary = tmp_path / "codex-rpc-ambiguous"
    _codex_rpc_fixture(
        binary,
        account=account,
        requires_openai_auth=requires_openai_auth,
    )

    with pytest.raises(ValueError, match=message):
        identity._codex_app_server_identity(profile, binary, timeout=3)


@pytest.mark.parametrize("behavior", ["nonzero", "malformed", "timeout"])
def test_codex_app_server_unavailable_protocol_fails_closed(
    fleet: tuple[object, Path], tmp_path: Path, behavior: str
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = _isolated_codex_probe_profile(registry, tmp_path / "codex-shadow")
    binary = tmp_path / f"codex-rpc-{behavior}"
    _codex_rpc_fixture(binary, account=None, behavior=behavior)

    with pytest.raises((TimeoutError, ValueError)):
        identity._codex_app_server_identity(profile, binary, timeout=1)


def test_codex_base_file_and_rpc_must_agree(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    _, config = fleet
    registry = load_registry(config)
    expected = identity_fingerprint("codex", "codex-base-anchor@example.invalid")

    agreed = refresh_provider_identity_anchors(registry, "codex")["base"]
    assert agreed["status"] == "present"
    assert agreed["identity_fingerprint"] == expected

    monkeypatch.setattr(
        identity,
        "_codex_app_server_identity",
        lambda *_args, **_kwargs: {
            "status": "present",
            "identity_fingerprint": identity_fingerprint("codex", "other@example.invalid"),
        },
    )
    mismatched = refresh_provider_identity_anchors(registry, "codex")["base"]
    assert mismatched["status"] == "indeterminate"
    assert mismatched["identity_fingerprint"] is None


def test_codex_missing_auth_json_uses_authoritative_rpc_presence_or_absence(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    _, config = fleet
    registry = load_registry(config)
    base_home = registry.require_provider("codex").base_home
    assert base_home is not None
    (base_home / "auth.json").unlink()
    expected = identity_fingerprint("codex", "codex-base-anchor@example.invalid")

    present = refresh_provider_identity_anchors(registry, "codex")["base"]
    assert present["status"] == "present"
    assert present["identity_fingerprint"] == expected

    monkeypatch.setattr(
        identity,
        "_codex_app_server_identity",
        lambda *_args, **_kwargs: {"status": "absent", "identity_fingerprint": None},
    )
    absent = refresh_provider_identity_anchors(registry, "codex")["base"]
    assert absent["status"] == "absent"
    assert absent["identity_fingerprint"] is None


def test_codex_base_credential_replacement_during_rpc_blocks_anchor(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    _, config = fleet
    registry = load_registry(config)
    base_home = registry.require_provider("codex").base_home
    assert base_home is not None
    auth = base_home / "auth.json"
    original = auth.read_bytes()

    def replace_credential(*_args, **_kwargs):
        replacement = base_home / "replacement-auth.json"
        replacement.write_bytes(original)
        replacement.chmod(0o600)
        replacement.replace(auth)
        return {
            "status": "present",
            "identity_fingerprint": identity_fingerprint(
                "codex", "codex-base-anchor@example.invalid"
            ),
        }

    monkeypatch.setattr(identity, "_codex_app_server_identity", replace_credential)

    result = refresh_provider_identity_anchors(registry, "codex")["base"]

    assert result["status"] == "indeterminate"
    assert result["identity_fingerprint"] is None


def test_codex_final_external_reprobe_cannot_replace_existing_bundle(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    _, config = fleet
    registry = load_registry(config)
    path = identity_bundle_path(registry, "codex")
    before = path.read_bytes()
    calls = 0
    base_fingerprint = identity_fingerprint("codex", "codex-base-anchor@example.invalid")
    worker_fingerprint = read_quota(registry, "codex-1")["identity_fingerprint"]

    def race_on_final_probe(*_args, **_kwargs):
        nonlocal calls
        calls += 1
        return {
            "status": "present",
            "identity_fingerprint": base_fingerprint if calls == 1 else worker_fingerprint,
        }

    monkeypatch.setattr(identity, "_codex_app_server_identity", race_on_final_probe)
    proofs = {
        profile.id: (
            read_quota(registry, profile.id),
            inspect_credential_source_contract(registry, profile),
        )
        for profile in registry.profiles.values()
        if profile.provider == "codex" and profile.safety_policy == "worker"
    }

    with pytest.raises(ValueError, match="base identity is indeterminate"):
        adopt_provider_identity_bundle(registry, "codex", proofs)

    assert path.read_bytes() == before


@pytest.mark.parametrize(
    ("provider", "worker_id", "reserve_id", "external_kind", "expected_conflict"),
    [
        ("claude", "claude-1", "claude-3", "desktop", "desktop_identity"),
        ("codex", "codex-1", "codex-5", "base", "base_identity"),
    ],
)
def test_external_reserve_quota_is_never_identity_authority(
    fleet: tuple[object, Path],
    monkeypatch: pytest.MonkeyPatch,
    provider: str,
    worker_id: str,
    reserve_id: str,
    external_kind: str,
    expected_conflict: str,
) -> None:
    _, config = fleet
    registry = load_registry(config)
    worker = registry.require_profile(worker_id)
    profiles = dict(registry.profiles)
    reserve_template = profiles.get(reserve_id, worker)
    profiles[reserve_id] = replace(
        reserve_template,
        id=reserve_id,
        provider=provider,
        home=worker.home.with_name(reserve_id),
        pools=(f"{provider}-manual",),
        enabled=False,
        safety_policy="desktop_shared",
    )
    registry = replace(registry, profiles=profiles)
    reserve = registry.require_profile(reserve_id)
    assert reserve.safety_policy == "desktop_shared"
    worker_quota = read_quota(registry, worker_id)
    fingerprint = worker_quota["identity_fingerprint"]
    atomic_write_json(quota_path(registry, reserve_id), worker_quota)
    real_read_quota = identity.read_quota
    reads: list[str] = []

    def guarded_read_quota(candidate_registry, profile_id: str):
        reads.append(profile_id)
        if profile_id == reserve_id:
            raise AssertionError("external reserve quota was read as routing identity authority")
        return real_read_quota(candidate_registry, profile_id)

    monkeypatch.setattr(identity, "read_quota", guarded_read_quota)
    observed = identity._external_observation(registry, provider)

    assert (
        identity.identity_conflict(
            registry,
            worker,
            worker_quota,
            observed_external=observed,
        )
        is None
    )
    assert reserve_id not in reads

    duplicate_external = json.loads(json.dumps(observed))
    duplicate_external[external_kind]["status"] = "present"
    duplicate_external[external_kind]["reason"] = None
    duplicate_external[external_kind]["identity_fingerprint"] = fingerprint
    assert (
        identity.identity_conflict(
            registry,
            worker,
            worker_quota,
            observed_external=duplicate_external,
        )
        == expected_conflict
    )
    assert reserve_id not in reads


def test_codex_base_switch_is_seen_on_next_selection(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, "codex-1")
    fixtures = tmp_path / "quota-fixtures"
    fixtures.mkdir()

    def write_base(account_id: str) -> None:
        (fixtures / "codex-base-anchor.json").write_text(
            json.dumps(
                {
                    "providers": [
                        {
                            "provider": "codex",
                            "account": {
                                "accountId": account_id,
                                "email": account_id.removesuffix("-account")
                                + "@example.invalid",
                            },
                            "state": {
                                "status": "fresh",
                                "refreshedAt": datetime.now(UTC).isoformat(),
                            },
                            "windows": [
                                {
                                    "id": "five_hour",
                                    "kind": "session",
                                    "percentRemaining": 80,
                                }
                            ],
                        }
                    ]
                }
            ),
            encoding="utf-8",
        )

    write_base("codex-base-anchor-account")
    (registry.settings.state_dir / "test-quota-fixture-dir").write_text(
        str(fixtures), encoding="utf-8"
    )
    selected = select_and_acquire(
        registry,
        task="before-codex-base-switch",
        pool="codex-crew",
        profile_id="codex-1",
        workspace=Path.cwd(),
    )
    assert selected["profile"] == "codex-1"
    release_lease(registry, "before-codex-base-switch")
    write_base("codex-1-account")

    with pytest.raises(ValueError, match="duplicate_provider_identity"):
        select_and_acquire(
            registry,
            task="after-codex-base-switch",
            pool="codex-crew",
            profile_id="codex-1",
            workspace=Path.cwd(),
        )


def test_claude_base_switch_is_seen_on_next_selection(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, "claude-1")
    fixtures = tmp_path / "claude-base-quota-fixtures"
    fixtures.mkdir()

    def write_base(account_id: str) -> None:
        (fixtures / "claude-base-anchor.json").write_text(
            json.dumps(
                {
                    "providers": [
                        {
                            "provider": "claude",
                            "account": {"accountId": account_id},
                            "state": {
                                "status": "fresh",
                                "refreshedAt": datetime.now(UTC).isoformat(),
                            },
                            "windows": [
                                {
                                    "id": "five_hour",
                                    "kind": "session",
                                    "percentRemaining": 80,
                                }
                            ],
                        }
                    ]
                }
            ),
            encoding="utf-8",
        )

    write_base("claude-base-anchor-account")
    (registry.settings.state_dir / "test-quota-fixture-dir").write_text(
        str(fixtures), encoding="utf-8"
    )
    selected = select_and_acquire(
        registry,
        task="before-claude-base-switch",
        pool="claude-crew",
        profile_id="claude-1",
        workspace=Path.cwd(),
    )
    assert selected["profile"] == "claude-1"
    release_lease(registry, "before-claude-base-switch")
    write_base("claude-1-account")

    with pytest.raises(ValueError, match="duplicate_provider_identity"):
        select_and_acquire(
            registry,
            task="after-claude-base-switch",
            pool="claude-crew",
            profile_id="claude-1",
            workspace=Path.cwd(),
        )


def test_missing_configured_desktop_identity_is_proven_absent(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, "claude-1")
    desktop_file = registry.require_provider("claude").desktop_identity_file
    assert desktop_file is not None
    desktop_file.unlink()
    refresh = refresh_provider_identity_anchors(registry, "claude")
    assert refresh["desktop"]["status"] == "absent"
    with pytest.raises(ValueError, match="external_changed"):
        select_and_acquire(
            registry,
            task="missing-desktop-anchor",
            pool="claude-crew",
            profile_id="claude-1",
            dry_run=True,
            workspace=Path.cwd(),
        )


def _quota_auth_result(
    provider: str,
    sources: list[dict[str, object]],
) -> subprocess.CompletedProcess[str]:
    normalized_sources = [
        {
            **source,
            **(
                {"account": current_user_name()}
                if provider == "claude" and source.get("source") == "keychain"
                else {}
            ),
        }
        for source in sources
    ]
    return subprocess.CompletedProcess(
        args=["quota-axi", "auth"],
        returncode=0,
        stdout=json.dumps(
            {
                "schemaVersion": 1,
                "auth": [{"provider": provider, "sources": normalized_sources}],
            }
        ),
        stderr="",
    )


@pytest.mark.parametrize(
    ("file_status", "keychain_status", "expected_kind", "error"),
    [
        (
            "available",
            "available",
            None,
            "requires exactly one authoritative credential source",
        ),
        (
            "invalid",
            "available",
            None,
            "ambiguous or unreadable credential source",
        ),
        ("missing", "available", "keychain", None),
    ],
)
def test_claude_source_contract_rejects_dual_or_ambiguous_sources_and_accepts_keychain_only(
    fleet: tuple[object, Path],
    monkeypatch: pytest.MonkeyPatch,
    file_status: str,
    keychain_status: str,
    expected_kind: str | None,
    error: str | None,
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = registry.require_profile("claude-1")
    result = _quota_auth_result(
        "claude",
        [
            {
                "source": "oauth-file",
                "path": str(profile.home / ".credentials.json"),
                "status": file_status,
            },
            {"source": "keychain", "status": keychain_status},
        ],
    )
    monkeypatch.setattr(quota_module.subprocess, "run", lambda *_args, **_kwargs: result)

    if error is not None:
        with pytest.raises(ValueError, match=error):
            inspect_credential_source_contract(registry, profile)
        return

    contract = inspect_credential_source_contract(registry, profile)
    assert contract["kind"] == expected_kind
    assert contract["config_home"] == str(profile.home)
    assert contract["service"].startswith("Claude Code-credentials-")
    assert contract["account"] == current_user_name()


@pytest.mark.parametrize("account", [None, "different-user"])
def test_claude_keychain_source_contract_requires_exact_passwd_account(
    fleet: tuple[object, Path],
    monkeypatch: pytest.MonkeyPatch,
    account: str | None,
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = registry.require_profile("claude-1")
    keychain_source: dict[str, object] = {
        "source": "keychain",
        "status": "available",
    }
    if account is not None:
        keychain_source["account"] = account
    result = subprocess.CompletedProcess(
        args=["quota-axi", "auth"],
        returncode=0,
        stdout=json.dumps(
            {
                "schemaVersion": 1,
                "auth": [
                    {
                        "provider": "claude",
                        "sources": [
                            {
                                "source": "oauth-file",
                                "path": str(profile.home / ".credentials.json"),
                                "status": "missing",
                            },
                            keychain_source,
                        ],
                    }
                ],
            }
        ),
        stderr="",
    )
    monkeypatch.setattr(quota_module.subprocess, "run", lambda *_args, **_kwargs: result)

    with pytest.raises(ValueError, match="credential source scope mismatch"):
        inspect_credential_source_contract(registry, profile)


@pytest.mark.parametrize("account", [None, "different-user"])
def test_identity_bundle_rejects_legacy_or_wrong_claude_keychain_account(
    fleet: tuple[object, Path], account: str | None
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = registry.require_profile("claude-1")
    path = identity_bundle_path(registry, "claude")
    payload = json.loads(path.read_text(encoding="utf-8"))
    contract: dict[str, object] = {
        "kind": "keychain",
        "service": quota_module._claude_scoped_keychain_service(profile),
        "config_home": str(profile.home),
    }
    if account is not None:
        contract["account"] = account
    payload["workers"][profile.id]["credential_source_contract"] = contract
    atomic_write_json(path, payload)

    result = identity.verify_identity_bundle(registry, "claude")
    assert result["status"] == "invalid"
    assert result["reason"] == f"credential_source:{profile.id}"


def test_identity_bundle_accepts_exact_claude_keychain_account(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = registry.require_profile("claude-1")
    path = identity_bundle_path(registry, "claude")
    payload = json.loads(path.read_text(encoding="utf-8"))
    payload["workers"][profile.id]["credential_source_contract"] = {
        "kind": "keychain",
        "service": quota_module._claude_scoped_keychain_service(profile),
        "account": current_user_name(),
        "config_home": str(profile.home),
    }
    atomic_write_json(path, payload)

    assert identity.verify_identity_bundle(registry, "claude")["status"] == "verified"


def test_codex_source_contract_rejects_wrong_cli_rpc_control_path(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = registry.require_profile("codex-1")
    result = _quota_auth_result(
        "codex",
        [
            {
                "source": "auth-json",
                "path": str(profile.home / "auth.json"),
                "status": "available",
            },
            {
                "source": "cli-rpc",
                "path": str(tmp_path / "ambient-codex"),
                "status": "available",
            },
        ],
    )
    monkeypatch.setattr(quota_module.subprocess, "run", lambda *_args, **_kwargs: result)

    with pytest.raises(ValueError, match="CLI-RPC control path mismatch"):
        inspect_credential_source_contract(registry, profile)


def test_manual_only_source_contract_fails_before_runtime_or_provider_touch(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = replace(
        registry.require_profile("claude-2"),
        enabled=False,
        safety_policy="manual_only",
    )
    touched: list[str] = []

    def unexpected_runtime(*_args, **_kwargs):
        touched.append("runtime")
        raise AssertionError("reserve inspection reached the sealed runtime")

    def unexpected_subprocess(*_args, **_kwargs):
        touched.append("subprocess")
        raise AssertionError("reserve inspection launched a provider-side process")

    monkeypatch.setattr(quota_module, "verified_quota_runtime", unexpected_runtime)
    monkeypatch.setattr(quota_module.subprocess, "run", unexpected_subprocess)

    with pytest.raises(ValueError, match="must not be remotely inspected"):
        inspect_credential_source_contract(registry, profile)
    assert touched == []


@pytest.mark.parametrize(
    ("attempts", "expected"),
    [
        (
            [
                {
                    "source": "oauth-file",
                    "status": "skipped",
                    "error": "credentials_missing",
                },
                {
                    "source": "keychain",
                    "status": "skipped",
                    "error": "credentials_missing",
                },
            ],
            "absent",
        ),
        (
            [
                {
                    "source": "oauth-file",
                    "status": "skipped",
                    "error": "credentials_missing",
                },
                {
                    "source": "keychain",
                    "status": "skipped",
                    "error": "keychain_prompt_required",
                    "credentialPresent": True,
                },
            ],
            "indeterminate",
        ),
        (
            [
                {
                    "source": "oauth-file",
                    "status": "skipped",
                    "error": "credentials_missing",
                },
                {
                    "source": "keychain",
                    "status": "skipped",
                    "error": "keychain_presence_check_failed",
                },
            ],
            "indeterminate",
        ),
        ([{"source": "keychain"}], "indeterminate"),
    ],
)
def test_claude_base_attempts_distinguish_absent_from_indeterminate(
    fleet: tuple[object, Path],
    tmp_path: Path,
    attempts: list[dict[str, object]],
    expected: str,
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, "claude-1")
    base_home = registry.require_provider("claude").base_home
    assert base_home is not None
    (base_home / ".credentials.json").unlink()
    fixtures = tmp_path / "base-attempt-fixtures"
    fixtures.mkdir()
    (fixtures / "claude-base-anchor.json").write_text(
        json.dumps(
            {
                "providers": [
                    {
                        "provider": "claude",
                        "state": {
                            "status": "auth_required",
                            "reason": "keychain_access_required",
                        },
                        "attempts": attempts,
                        "windows": [],
                    }
                ]
            }
        ),
        encoding="utf-8",
    )
    (registry.settings.state_dir / "test-quota-fixture-dir").write_text(
        str(fixtures), encoding="utf-8"
    )

    result = refresh_provider_identity_anchors(registry, "claude")["base"]
    assert result["status"] == expected
    if expected == "absent":
        with pytest.raises(ValueError, match="external_changed"):
            select_and_acquire(
                registry,
                task="proven-default-claude-absence",
                pool="claude-crew",
                profile_id="claude-1",
                dry_run=True,
                workspace=Path.cwd(),
            )
    else:
        with pytest.raises(ValueError, match="provider external identity proof failed"):
            select_and_acquire(
                registry,
                task="indeterminate-default-claude-identity",
                pool="claude-crew",
                profile_id="claude-1",
                dry_run=True,
                workspace=Path.cwd(),
            )


def test_base_refresh_uses_realistic_timeout_and_slow_success(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    _, config = fleet
    registry = load_registry(config)
    observed: list[int] = []

    def slow_success(_registry, profile, *, timeout, **_kwargs):
        observed.append(timeout)
        return {
            "status": "fresh",
            "verified_at": datetime.now(UTC).isoformat(),
            "headroom_percent": 80,
            "windows": [{"id": "five_hour", "remaining_percent": 80}],
            "identity_fingerprint": identity_fingerprint(profile.provider, "slow-base-account"),
        }

    monkeypatch.setattr(identity, "probe_quota", slow_success)
    identity.refresh_provider_identity_anchors_if_due(registry, "claude")
    assert observed == [30]


def test_base_refresh_timeout_is_indeterminate_and_fail_closed(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, "codex-1")

    def timeout(*_args, **_kwargs):
        raise TimeoutError("simulated base probe timeout")

    monkeypatch.setattr(identity, "probe_quota", timeout)
    identity.refresh_provider_identity_anchors_if_due(registry, "codex")
    with pytest.raises(ValueError, match="provider external identity proof failed"):
        select_and_acquire(
            registry,
            task="base-timeout-fails-closed",
            pool="codex-crew",
            profile_id="codex-1",
            dry_run=True,
            workspace=Path.cwd(),
        )


@pytest.mark.parametrize("provider_name", ["claude", "codex"])
@pytest.mark.parametrize("mutation", ["mode", "hardlink", "symlink"])
def test_worker_credential_storage_tampering_blocks_selection(
    fleet: tuple[object, Path],
    tmp_path: Path,
    provider_name: str,
    mutation: str,
) -> None:
    _, config = fleet
    profile_id = f"{provider_name}-1"
    registry = _enable_and_provision(load_registry(config), config, profile_id)
    profile = registry.require_profile(profile_id)
    credential = profile.home / (".credentials.json" if provider_name == "claude" else "auth.json")
    if mutation == "mode":
        credential.chmod(0o644)
    elif mutation == "hardlink":
        os.link(credential, tmp_path / f"{provider_name}-credential-alias")
    else:
        target = tmp_path / f"{provider_name}-credential-target"
        target.write_bytes(credential.read_bytes())
        target.chmod(0o600)
        credential.unlink()
        credential.symlink_to(target)

    with pytest.raises(ValueError, match="profile is not ready"):
        select_and_acquire(
            registry,
            task=f"{provider_name}-{mutation}-credential",
            pool=f"{provider_name}-crew",
            profile_id=profile_id,
            dry_run=True,
            workspace=Path.cwd(),
        )


def test_missing_configured_base_home_fails_closed(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, "codex-1")
    base_home = registry.require_provider("codex").base_home
    assert base_home is not None
    providers = dict(registry.providers)
    providers["codex"] = replace(
        providers["codex"],
        base_home=base_home.with_name("missing-codex-base"),
    )
    registry = replace(registry, providers=providers)

    with pytest.raises(ValueError, match="provider external identity proof failed"):
        select_and_acquire(
            registry,
            task="missing-base-home",
            pool="codex-crew",
            profile_id="codex-1",
            dry_run=True,
            workspace=Path.cwd(),
        )


def test_claude_worker_environment_blocks_login_logout_and_scrubs_ambient(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    _, config = fleet
    profile = load_registry(config).require_profile("claude-1")
    monkeypatch.setenv("CLAUDE_CODE_OAUTH_TOKEN", "poison")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "poison")
    monkeypatch.setenv("CODEX_HOME", "/tmp/poison")
    monkeypatch.setenv("AGENT_FLEET_QUOTA_FIXTURE_DIR", "/tmp/poison")
    monkeypatch.setenv("AGENT_FLEET_ROGUE", "poison")
    monkeypatch.setenv("QUOTA_AXI_FAKE", "poison")
    monkeypatch.setenv("USER", "attacker-controlled-user")
    monkeypatch.setenv("LOGNAME", "attacker-controlled-logname")
    environment = provider_environment(
        profile,
        "managed-task",
        Path.cwd(),
        "claude-crew",
        operation="worker",
    )
    control_environment = provider_environment(profile)
    for provider_env in (environment, control_environment):
        assert provider_env["USER"] == current_user_name()
        assert provider_env["LOGNAME"] == current_user_name()
    assert environment["CLAUDE_CONFIG_DIR"] == str(profile.home)
    assert environment["CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION"] == "false"
    assert environment["DISABLE_LOGIN_COMMAND"] == "1"
    assert environment["DISABLE_LOGOUT_COMMAND"] == "1"
    assert environment["AGENT_FLEET_WORKSPACE"] == str(Path.cwd())
    assert environment["AGENT_FLEET_POOL"] == "claude-crew"
    assert "CLAUDE_CODE_OAUTH_TOKEN" not in environment
    assert "ANTHROPIC_API_KEY" not in environment
    assert "CODEX_HOME" not in environment
    assert "AGENT_FLEET_QUOTA_FIXTURE_DIR" not in environment
    assert "AGENT_FLEET_ROGUE" not in environment
    assert "QUOTA_AXI_FAKE" not in environment


def test_worker_path_rejects_writable_leaf_and_ancestry(tmp_path: Path) -> None:
    safe = tmp_path / "safe" / "bin"
    safe.mkdir(parents=True)
    writable_leaf = tmp_path / "writable-leaf"
    writable_leaf.mkdir()
    writable_leaf.chmod(0o775)
    writable_parent = tmp_path / "writable-parent"
    writable_parent.mkdir()
    writable_parent.chmod(0o775)
    nested = writable_parent / "nested" / "bin"
    nested.mkdir(parents=True)

    path = validated_worker_path(
        os.pathsep.join((str(safe), str(writable_leaf), str(nested)))
    ).split(os.pathsep)

    assert str(safe.resolve()) in path
    assert str(writable_leaf.resolve()) not in path
    assert str(nested.resolve()) not in path


@pytest.mark.parametrize("profile_id", ["claude-1", "codex-1"])
def test_control_auth_probe_uses_closed_environment(
    fleet: tuple[object, Path],
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    profile_id: str,
) -> None:
    _, config = fleet
    profile = load_registry(config).require_profile(profile_id)
    captured = tmp_path / f"{profile_id}-auth-environment.json"
    binary = tmp_path / "codex-auth-probe"
    binary.write_text(
        """#!/usr/bin/env python3
import json
import os
from pathlib import Path
Path(os.environ["CAPTURE_AUTH_ENV"]).write_text(json.dumps(dict(os.environ)))
""",
        encoding="utf-8",
    )
    binary.chmod(0o755)
    monkeypatch.setenv("CAPTURE_AUTH_ENV", str(captured))
    monkeypatch.setenv("AGENT_FLEET_ROGUE", "poison")
    monkeypatch.setenv("QUOTA_AXI_FAKE", "poison")
    monkeypatch.setenv("BROWSER", "poison")
    monkeypatch.setenv("GIT_ASKPASS", "poison")
    monkeypatch.setenv("HTTP_PROXY", "http://poison.invalid")
    monkeypatch.setenv("USER", "attacker-controlled-user")
    monkeypatch.setenv("LOGNAME", "attacker-controlled-logname")

    result = auth_probe(profile, binary=binary)

    environment = json.loads(captured.read_text(encoding="utf-8"))
    assert result["status"] == "authenticated"
    assert environment["PATH"] == CONTROL_PATH
    assert environment["USER"] == current_user_name()
    assert environment["LOGNAME"] == current_user_name()
    assert {
        name for name in environment if name.startswith("AGENT_FLEET_")
    } == {"AGENT_FLEET_PROFILE", "AGENT_FLEET_PROVIDER"}
    assert not {
        "AGENT_FLEET_ROGUE",
        "QUOTA_AXI_FAKE",
        "BROWSER",
        "GIT_ASKPASS",
        "HTTP_PROXY",
    } & set(environment)
