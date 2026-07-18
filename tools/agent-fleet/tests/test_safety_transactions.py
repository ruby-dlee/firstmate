from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
from dataclasses import replace
from pathlib import Path

import pytest

from agent_fleet import enrollment, leases, locks
from agent_fleet.config import load_registry, save_registry
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
from agent_fleet.leases import bind_lease, new_lease
from agent_fleet.locks import provider_enrollment_lock
from agent_fleet.providers import provider_environment
from agent_fleet.provision import provision_profile
from agent_fleet.quota import quota_path, snapshot_quota_cache
from agent_fleet.scheduler import select_and_acquire
from agent_fleet.util import atomic_write_json


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


def test_lease_creation_and_binding_require_process_start_tokens(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    _, config = fleet
    registry = load_registry(config)
    monkeypatch.setattr(leases, "process_start_token", lambda _pid: None)
    with pytest.raises(ValueError, match="verified process start token"):
        new_lease("no-start-token", "codex-1", "codex-crew", pid=os.getpid())
    with pytest.raises(ValueError, match="verified process start token"):
        bind_lease(
            registry,
            new_lease("reserved", "codex-1", "codex-crew", pid=None),
            os.getpid(),
        )


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


def test_missing_configured_desktop_anchor_fails_closed(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, "claude-1")
    desktop_file = registry.require_provider("claude").desktop_identity_file
    assert desktop_file is not None
    desktop_file.unlink()
    with pytest.raises(ValueError, match="duplicate_provider_identity"):
        select_and_acquire(
            registry,
            task="missing-desktop-anchor",
            pool="claude-crew",
            profile_id="claude-1",
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

    with pytest.raises(ValueError, match="duplicate_provider_identity"):
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
    environment = provider_environment(profile, "managed-task")
    assert environment["CLAUDE_CONFIG_DIR"] == str(profile.home)
    assert environment["DISABLE_LOGIN_COMMAND"] == "1"
    assert environment["DISABLE_LOGOUT_COMMAND"] == "1"
    assert "CLAUDE_CODE_OAUTH_TOKEN" not in environment
    assert "ANTHROPIC_API_KEY" not in environment
    assert "CODEX_HOME" not in environment
    assert "AGENT_FLEET_QUOTA_FIXTURE_DIR" not in environment
