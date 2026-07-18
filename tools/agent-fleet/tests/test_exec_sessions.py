from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from pathlib import Path

import pytest

from agent_fleet.config import load_registry, save_registry
from agent_fleet.identity import adopt_provider_identity_bundle
from agent_fleet.leases import active_leases
from agent_fleet.models import Registry
from agent_fleet.provision import provision_profile
from agent_fleet.quota import inspect_credential_source_contract, read_quota
from agent_fleet.scheduler import select_and_acquire
from agent_fleet.sessions import (
    _touch_turn_end,
    get_session,
    record_session_from_hook,
    record_turn_end_from_hook,
    session_path,
    validate_turn_end_path,
)
from agent_fleet.util import atomic_write_json, utc_now


def _fake_provider(path: Path) -> None:
    path.write_text(
        """#!/usr/bin/env python3
import json
import os
import sys
if "app-server" in sys.argv:
    for line in sys.stdin:
        message = json.loads(line)
        if message.get("method") == "initialize":
            print(json.dumps({"id": message["id"], "result": {}}), flush=True)
        elif message.get("method") == "account/read":
            print(json.dumps({
                "id": message["id"],
                "result": {
                    "account": {
                        "type": "chatgpt",
                        "email": "codex-base-anchor@example.invalid",
                        "planType": "test",
                    },
                    "requiresOpenaiAuth": True,
                },
            }), flush=True)
    raise SystemExit
print(json.dumps({
    "argv": sys.argv[1:],
    "profile": os.environ.get("AGENT_FLEET_PROFILE"),
    "task": os.environ.get("AGENT_FLEET_TASK_ID"),
    "turn_end": os.environ.get("AGENT_FLEET_TURN_END"),
    "cwd": os.getcwd(),
    "codex_home": os.environ.get("CODEX_HOME"),
    "claude_home": os.environ.get("CLAUDE_CONFIG_DIR"),
    "has_openai_key": "OPENAI_API_KEY" in os.environ,
    "has_anthropic_key": "ANTHROPIC_API_KEY" in os.environ,
    "fleet_environment": sorted(
        name for name in os.environ if name.startswith("AGENT_FLEET_")
    ),
    "injection_environment": sorted(
        name for name in (
            "BROWSER", "GIT_ASKPASS", "HTTP_PROXY", "PYTHONPATH", "QUOTA_AXI_FAKE"
        ) if name in os.environ
    ),
    "path": os.environ.get("PATH"),
}))
""",
        encoding="utf-8",
    )
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def _rebind_profile(registry: Registry, profile_id: str) -> None:
    profile = registry.require_profile(profile_id)
    workers = [
        candidate
        for candidate in registry.profiles.values()
        if candidate.provider == profile.provider and candidate.safety_policy == "worker"
    ]
    for candidate in workers:
        provision_profile(registry, candidate)
    adopt_provider_identity_bundle(
        registry,
        profile.provider,
        {
            candidate.id: (
                read_quota(registry, candidate.id),
                inspect_credential_source_contract(registry, candidate),
            )
            for candidate in workers
        },
    )


def test_exec_uses_selected_home_and_clears_ambient_credentials(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    fake = tmp_path / "fake-provider"
    _fake_provider(fake)
    providers = dict(registry.providers)
    providers["codex"] = replace(providers["codex"], binary=fake)
    profiles = dict(registry.profiles)
    profiles["codex-1"] = replace(profiles["codex-1"], enabled=True)
    registry = replace(registry, providers=providers, profiles=profiles)
    save_registry(registry, config)
    registry = load_registry(config)
    profile = registry.require_profile("codex-1")
    provision_profile(registry, profile)
    _rebind_profile(registry, profile.id)

    project_root = Path(__file__).parents[1]
    env = dict(os.environ)
    env["PYTHONPATH"] = str(project_root / "src")
    env["OPENAI_API_KEY"] = "must-not-reach-provider"
    env["AGENT_FLEET_ROGUE"] = "must-not-reach-provider"
    env["AGENT_FLEET_PROFILE"] = "ambient-wrong-profile"
    env["QUOTA_AXI_FAKE"] = "must-not-reach-provider"
    env["BROWSER"] = "evil-browser"
    env["GIT_ASKPASS"] = "evil-askpass"
    env["HTTP_PROXY"] = "http://evil.invalid"
    supervisor = tmp_path / "supervisor"
    supervisor.mkdir()
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "agent_fleet",
            "--format",
            "json",
            "--config",
            str(config),
            "exec",
            "--task",
            "exec-task",
            "--pool",
            "codex-crew",
            "--profile",
            "codex-1",
            "--workspace",
            str(Path.cwd()),
            "--turn-end",
            str(tmp_path / "exec-task.turn-ended"),
            "--",
            "--dangerously-bypass-approvals-and-sandbox",
            "example-argument",
        ],
        cwd=supervisor,
        env=env,
        text=True,
        capture_output=True,
        timeout=20,
        check=False,
    )
    assert result.returncode == 0, result.stdout
    payload = json.loads(result.stdout)
    assert payload["argv"][-2:] == ["--", "example-argument"]
    assert payload["argv"][:4] == [
        "--disable",
        "plugins",
        "--disable",
        "plugin_sharing",
    ]
    assert payload["profile"] == "codex-1"
    assert payload["task"] == "exec-task"
    assert payload["turn_end"] == str(tmp_path / "exec-task.turn-ended")
    assert payload["cwd"] == str(Path.cwd())
    assert payload["codex_home"] == str(profile.home)
    assert payload["claude_home"] is None
    assert payload["has_openai_key"] is False
    assert payload["fleet_environment"] == [
        "AGENT_FLEET_POOL",
        "AGENT_FLEET_PROFILE",
        "AGENT_FLEET_PROVIDER",
        "AGENT_FLEET_TASK_ID",
        "AGENT_FLEET_TURN_END",
        "AGENT_FLEET_WORKSPACE",
    ]
    assert payload["injection_environment"] == []
    assert "/usr/bin" in payload["path"].split(os.pathsep)


def test_turn_end_marker_creation_is_umask_independent_and_rejects_hardlinks(
    tmp_path: Path,
) -> None:
    parent = tmp_path / "private"
    parent.mkdir(mode=0o700)
    parent.chmod(0o700)
    marker = parent / "task.turn-ended"
    previous_umask = os.umask(0o777)
    try:
        _touch_turn_end(validate_turn_end_path(marker))
    finally:
        os.umask(previous_umask)

    current = marker.lstat()
    assert stat.S_IMODE(current.st_mode) == 0o600
    assert current.st_nlink == 1
    alias = parent / "alias"
    os.link(marker, alias)
    with pytest.raises(ValueError, match="safe current-user regular file"):
        validate_turn_end_path(marker)
    with pytest.raises(ValueError, match="changed before signal"):
        _touch_turn_end(marker)


def test_session_hook_persists_profile_and_provider_session(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profiles = dict(registry.profiles)
    profiles["claude-1"] = replace(profiles["claude-1"], enabled=True)
    registry = replace(registry, profiles=profiles)
    save_registry(registry, config)
    registry = load_registry(config)
    profile = registry.require_profile("claude-1")
    provision_profile(registry, profile)
    select_and_acquire(
        registry,
        task="hook-task",
        pool="claude-crew",
        profile_id="claude-1",
        bind_pid=os.getpid(),
        workspace=Path.cwd(),
    )
    monkeypatch.setenv("AGENT_FLEET_TASK_ID", "hook-task")
    monkeypatch.setenv("AGENT_FLEET_PROFILE", "claude-1")
    monkeypatch.setenv("AGENT_FLEET_PROVIDER", "claude")
    monkeypatch.setenv("AGENT_FLEET_POOL", "claude-crew")
    monkeypatch.setenv("AGENT_FLEET_WORKSPACE", str(Path.cwd()))
    monkeypatch.setenv("AGENT_FLEET_TURN_END", str(tmp_path / "hook-task.turn-ended"))

    result = record_session_from_hook(
        registry, {"hook_event_name": "SessionStart", "session_id": "session-123"}
    )
    mapping = get_session(registry, "hook-task")
    assert result["recorded"] is True
    assert mapping["profile"] == "claude-1"
    assert mapping["provider"] == "claude"
    assert mapping["session_id"] == "session-123"
    assert mapping["pool"] == "claude-crew"
    assert mapping["workspace"] == str(Path.cwd())
    assert mapping["turn_end"] == str(tmp_path / "hook-task.turn-ended")
    assert mapping["schema"] == 2
    assert mapping["session_event_seq"] == 1
    original_mapping = session_path(registry, "hook-task").read_bytes()
    repeated = record_session_from_hook(
        registry, {"hook_event_name": "SessionStart", "session_id": "session-123"}
    )
    assert repeated["idempotent"] is True
    assert repeated["session_event_seq"] == 2
    refreshed_mapping = session_path(registry, "hook-task").read_bytes()
    assert refreshed_mapping != original_mapping
    assert get_session(registry, "hook-task")["session_event_seq"] == 2
    with ThreadPoolExecutor(max_workers=4) as executor:
        concurrent = list(
            executor.map(
                lambda _: record_session_from_hook(
                    registry,
                    {"hook_event_name": "SessionStart", "session_id": "session-123"},
                ),
                range(8),
            )
        )
    assert sorted(result["session_event_seq"] for result in concurrent) == list(range(3, 11))
    refreshed_mapping = session_path(registry, "hook-task").read_bytes()
    assert get_session(registry, "hook-task")["session_event_seq"] == 10
    with pytest.raises(ValueError, match="already bound to another identity"):
        record_session_from_hook(
            registry, {"hook_event_name": "SessionStart", "session_id": "session-other"}
        )
    assert session_path(registry, "hook-task").read_bytes() == refreshed_mapping

    project_root = Path(__file__).parents[1]
    env = dict(os.environ)
    env["PYTHONPATH"] = str(project_root / "src")
    status = subprocess.run(
        [
            sys.executable,
            "-m",
            "agent_fleet",
            "--format",
            "json",
            "--config",
            str(config),
            "session",
            "status",
            "--task",
            "hook-task",
        ],
        cwd=Path.cwd(),
        env=env,
        text=True,
        capture_output=True,
        timeout=20,
        check=True,
    )
    assert json.loads(status.stdout)["session_id"] == "session-123"

    wrong_pool = subprocess.run(
        [
            sys.executable,
            "-m",
            "agent_fleet",
            "--format",
            "json",
            "--config",
            str(config),
            "resume",
            "--task",
            "hook-task",
            "--pool",
            "claude-other",
            "--workspace",
            str(Path.cwd()),
            "--turn-end",
            str(tmp_path / "hook-task.turn-ended"),
            "--",
            "--dangerously-skip-permissions",
        ],
        cwd=Path.cwd(),
        env=env,
        text=True,
        capture_output=True,
        timeout=20,
        check=False,
    )
    assert wrong_pool.returncode == 2
    assert "explicit pool does not match" in json.loads(wrong_pool.stdout)["error"]

    removed = subprocess.run(
        [
            sys.executable,
            "-m",
            "agent_fleet",
            "--format",
            "json",
            "--config",
            str(config),
            "session",
            "remove",
            "--task",
            "hook-task",
        ],
        cwd=Path.cwd(),
        env=env,
        text=True,
        capture_output=True,
        timeout=20,
        check=True,
    )
    assert json.loads(removed.stdout)["removed"] is True


def test_session_hook_rejects_cross_workspace_and_ambiguous_identity(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profiles = dict(registry.profiles)
    profiles["claude-1"] = replace(profiles["claude-1"], enabled=True)
    registry = replace(registry, profiles=profiles)
    provision_profile(registry, registry.require_profile("claude-1"))
    select_and_acquire(
        registry,
        task="guarded-hook-task",
        pool="claude-crew",
        profile_id="claude-1",
        bind_pid=os.getpid(),
        workspace=Path.cwd(),
    )
    monkeypatch.setenv("AGENT_FLEET_TASK_ID", "guarded-hook-task")
    monkeypatch.setenv("AGENT_FLEET_PROFILE", "claude-1")
    monkeypatch.setenv("AGENT_FLEET_PROVIDER", "claude")
    monkeypatch.setenv("AGENT_FLEET_POOL", "claude-crew")
    monkeypatch.setenv("AGENT_FLEET_WORKSPACE", str(tmp_path))
    monkeypatch.setenv("AGENT_FLEET_TURN_END", str(tmp_path / "guarded.turn-ended"))

    with pytest.raises(ValueError, match="exactly match its live lease"):
        record_session_from_hook(registry, {"session_id": "cross-workspace-session"})
    assert not session_path(registry, "guarded-hook-task").exists()


def test_turn_end_dispatcher_requires_exact_live_lease_and_session_binding(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profiles = dict(registry.profiles)
    profiles["codex-1"] = replace(profiles["codex-1"], enabled=True)
    registry = replace(registry, profiles=profiles)
    profile = registry.require_profile("codex-1")
    provision_profile(registry, profile)
    select_and_acquire(
        registry,
        task="codex-turn-end-task",
        pool="codex-crew",
        profile_id=profile.id,
        bind_pid=os.getpid(),
        workspace=Path.cwd(),
    )
    turn_end = tmp_path / "codex-turn-end-task.turn-ended"
    monkeypatch.setenv("AGENT_FLEET_TASK_ID", "codex-turn-end-task")
    monkeypatch.setenv("AGENT_FLEET_PROFILE", profile.id)
    monkeypatch.setenv("AGENT_FLEET_PROVIDER", "codex")
    monkeypatch.setenv("AGENT_FLEET_POOL", "codex-crew")
    monkeypatch.setenv("AGENT_FLEET_WORKSPACE", str(Path.cwd()))
    monkeypatch.setenv("AGENT_FLEET_TURN_END", str(turn_end))
    record_session_from_hook(registry, {"session_id": "codex-turn-session"})

    result = record_turn_end_from_hook(registry)
    assert result["recorded"] is True
    assert turn_end.is_file()
    turn_end.unlink()

    other = tmp_path / "other.turn-ended"
    monkeypatch.setenv("AGENT_FLEET_TURN_END", str(other))
    with pytest.raises(ValueError, match="does not match its SessionStart mapping"):
        record_turn_end_from_hook(registry)
    assert not other.exists()

    monkeypatch.setenv("AGENT_FLEET_TURN_END", str(turn_end))
    outside = tmp_path / "outside"
    outside.write_text("unchanged\n", encoding="utf-8")
    turn_end.symlink_to(outside)
    with pytest.raises(ValueError, match="safe current-user regular file"):
        record_turn_end_from_hook(registry)
    assert outside.read_text(encoding="utf-8") == "unchanged\n"
    turn_end.unlink()

    session_path(registry, "codex-turn-end-task").unlink()
    with pytest.raises(ValueError, match="no recorded provider session"):
        record_turn_end_from_hook(registry)
    assert not turn_end.exists()

    monkeypatch.setenv("AGENT_FLEET_WORKSPACE", str(Path.cwd()))
    with pytest.raises(ValueError, match="multiple session ids"):
        record_session_from_hook(
            registry,
            {
                "session_id": "first-session",
                "nested": {"sessionId": "second-session"},
            },
        )
    assert not session_path(registry, "guarded-hook-task").exists()


def test_session_mapping_requires_exact_workspace_schema(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    registry = load_registry(config)
    mapping = {
        "schema": 1,
        "task": "missing-workspace",
        "profile": "codex-1",
        "provider": "codex",
        "pool": "codex-crew",
        "session_id": "mapped-session",
        "updated_at": utc_now(),
    }
    atomic_write_json(session_path(registry, "missing-workspace"), mapping)

    with pytest.raises(ValueError, match="corrupt session mapping"):
        get_session(registry, "missing-workspace")

    mapping["workspace"] = str(Path.cwd())
    mapping["turn_end"] = str(registry.settings.state_dir / "missing-workspace.turn-ended")
    mapping["updated_at"] = "20260713T000000+00:00"
    atomic_write_json(session_path(registry, "missing-workspace"), mapping)
    with pytest.raises(ValueError, match="corrupt session mapping"):
        get_session(registry, "missing-workspace")


def test_legacy_session_mapping_migrates_only_on_same_binding_sessionstart(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profiles = dict(registry.profiles)
    profiles["claude-1"] = replace(profiles["claude-1"], enabled=True)
    registry = replace(registry, profiles=profiles)
    provision_profile(registry, registry.require_profile("claude-1"))
    select_and_acquire(
        registry,
        task="legacy-session-task",
        pool="claude-crew",
        profile_id="claude-1",
        bind_pid=os.getpid(),
        workspace=Path.cwd(),
    )
    turn_end = tmp_path / "legacy-session-task.turn-ended"
    legacy = {
        "schema": 1,
        "task": "legacy-session-task",
        "profile": "claude-1",
        "provider": "claude",
        "pool": "claude-crew",
        "workspace": str(Path.cwd()),
        "turn_end": str(turn_end),
        "session_id": "legacy-session",
        "updated_at": utc_now(),
    }
    atomic_write_json(session_path(registry, "legacy-session-task"), legacy)
    assert get_session(registry, "legacy-session-task")["session_event_seq"] == 0
    monkeypatch.setenv("AGENT_FLEET_TASK_ID", "legacy-session-task")
    monkeypatch.setenv("AGENT_FLEET_PROFILE", "claude-1")
    monkeypatch.setenv("AGENT_FLEET_PROVIDER", "claude")
    monkeypatch.setenv("AGENT_FLEET_POOL", "claude-crew")
    monkeypatch.setenv("AGENT_FLEET_WORKSPACE", str(Path.cwd()))
    monkeypatch.setenv("AGENT_FLEET_TURN_END", str(turn_end))

    before = session_path(registry, "legacy-session-task").read_bytes()
    with pytest.raises(ValueError, match="already bound to another identity"):
        record_session_from_hook(registry, {"session_id": "changed-session"})
    assert session_path(registry, "legacy-session-task").read_bytes() == before

    result = record_session_from_hook(registry, {"session_id": "legacy-session"})
    migrated = get_session(registry, "legacy-session-task")
    assert result["idempotent"] is True
    assert result["session_event_seq"] == 1
    assert migrated["schema"] == 2
    assert migrated["session_event_seq"] == 1


def test_live_task_cannot_cross_workspaces(fleet: tuple[object, Path], tmp_path: Path) -> None:
    _, config = fleet
    registry = load_registry(config)
    profiles = dict(registry.profiles)
    profiles["claude-1"] = replace(profiles["claude-1"], enabled=True)
    registry = replace(registry, profiles=profiles)
    provision_profile(registry, registry.require_profile("claude-1"))
    linked = tmp_path / "linked-worktree"
    subprocess.run(
        ["git", "worktree", "add", "-q", "-b", "cross-workspace", str(linked)],
        cwd=Path.cwd(),
        check=True,
    )
    selected = select_and_acquire(
        registry,
        task="workspace-owned-task",
        pool="claude-crew",
        profile_id="claude-1",
        bind_pid=os.getpid(),
        workspace=Path.cwd(),
    )
    assert selected["workspace"] == str(Path.cwd())
    assert selected["lease"]["workspace"] == str(Path.cwd())

    with pytest.raises(ValueError, match="already owns a lease for workspace"):
        select_and_acquire(
            registry,
            task="workspace-owned-task",
            pool="claude-crew",
            profile_id="claude-1",
            bind_pid=os.getpid(),
            workspace=linked,
        )


def test_direct_resume_without_managed_task_is_refused(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    fake = tmp_path / "fake-provider"
    _fake_provider(fake)
    providers = dict(registry.providers)
    providers["codex"] = replace(providers["codex"], binary=fake)
    profiles = dict(registry.profiles)
    profiles["codex-1"] = replace(profiles["codex-1"], enabled=True)
    registry = replace(registry, providers=providers, profiles=profiles)
    save_registry(registry, config)
    registry = load_registry(config)
    profile = registry.require_profile("codex-1")
    provision_profile(registry, profile)

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
            "resume",
            "--profile",
            "codex-1",
            "--session",
            "session-explicit",
            "--",
            "extra",
        ],
        cwd=Path.cwd(),
        env=env,
        text=True,
        capture_output=True,
        timeout=20,
        check=False,
    )
    assert result.returncode == 2
    assert "worker resume requires --task" in json.loads(result.stdout)["error"]


def test_direct_worker_exec_without_managed_task_is_refused(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    fake = tmp_path / "fake-provider"
    _fake_provider(fake)
    providers = dict(registry.providers)
    providers["codex"] = replace(providers["codex"], binary=fake)
    profiles = dict(registry.profiles)
    profiles["codex-1"] = replace(profiles["codex-1"], enabled=True)
    registry = replace(registry, providers=providers, profiles=profiles)
    save_registry(registry, config)
    registry = load_registry(config)
    provision_profile(registry, registry.require_profile("codex-1"))

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
            "exec",
            "--profile",
            "codex-1",
            "--",
            "example-argument",
        ],
        cwd=Path.cwd(),
        env=env,
        text=True,
        capture_output=True,
        timeout=20,
        check=False,
    )
    assert result.returncode == 2
    assert "worker exec requires --task" in json.loads(result.stdout)["error"]


@pytest.mark.parametrize(
    ("operation", "arguments", "expected"),
    [
        (
            "exec",
            ["--task", "missing-workspace", "--profile", "codex-1", "--turn-end", "/tmp/end"],
            "worker exec requires the task --workspace",
        ),
        (
            "exec",
            ["--task", "missing-turn-end", "--profile", "codex-1", "--workspace", "."],
            "worker exec requires the task --turn-end marker",
        ),
        (
            "resume",
            ["--task", "missing-workspace", "--turn-end", "/tmp/end"],
            "worker resume requires the task --workspace",
        ),
        (
            "resume",
            ["--task", "missing-turn-end", "--workspace", "."],
            "worker resume requires the task --turn-end marker",
        ),
    ],
)
def test_contract_v2_managed_commands_require_workspace_and_turn_end_before_lease(
    fleet: tuple[object, Path],
    operation: str,
    arguments: list[str],
    expected: str,
) -> None:
    _, config = fleet
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
            operation,
            *arguments,
            "--",
        ],
        cwd=Path.cwd(),
        env=env,
        text=True,
        capture_output=True,
        timeout=20,
        check=False,
    )

    assert result.returncode == 2
    assert expected in json.loads(result.stdout)["error"]
    assert active_leases(load_registry(config)) == []


def test_worker_exec_refuses_auth_resume_and_plugin_overrides(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    _, config = fleet
    project_root = Path(__file__).parents[1]
    env = dict(os.environ)
    env["PYTHONPATH"] = str(project_root / "src")
    for provider_args in (
        ["login"],
        ["resume", "foreign-session"],
        ["--enable", "plugins"],
        ["-c", 'projects."/tmp".trust_level="trusted"'],
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
                "exec",
                "--task",
                "guarded-exec",
                "--profile",
                "codex-1",
                "--workspace",
                str(Path.cwd()),
                "--turn-end",
                str(tmp_path / "guarded-exec.turn-ended"),
                "--",
                *provider_args,
            ],
            cwd=Path.cwd(),
            env=env,
            text=True,
            capture_output=True,
            timeout=20,
            check=False,
        )
        assert result.returncode == 2
        assert "managed Codex" in json.loads(result.stdout)["error"]
    assert active_leases(load_registry(config)) == []


def test_claude_short_continue_is_refused_before_lease_or_provider_exec(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    provider_log = tmp_path / "provider-ran"
    binary = tmp_path / "claude-provider"
    binary.write_text(
        f"#!/usr/bin/env python3\nfrom pathlib import Path\nPath({str(provider_log)!r}).touch()\n",
        encoding="utf-8",
    )
    binary.chmod(binary.stat().st_mode | stat.S_IXUSR)
    providers = dict(registry.providers)
    providers["claude"] = replace(providers["claude"], binary=binary)
    registry = replace(registry, providers=providers)
    save_registry(registry, config)
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
            "exec",
            "--task",
            "claude-continue-bypass",
            "--profile",
            "claude-1",
            "--workspace",
            str(Path.cwd()),
            "--turn-end",
            str(tmp_path / "claude-continue-bypass.turn-ended"),
            "--",
            "-c",
        ],
        cwd=Path.cwd(),
        env=env,
        text=True,
        capture_output=True,
        timeout=20,
        check=False,
    )

    assert result.returncode == 2
    assert not provider_log.exists()
    assert active_leases(load_registry(config)) == []


def test_init_has_no_force_replacement_path(tmp_path: Path) -> None:
    project_root = Path(__file__).parents[1]
    config = tmp_path / "accounts.toml"
    env = dict(os.environ)
    env["PYTHONPATH"] = str(project_root / "src")
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "agent_fleet",
            "--config",
            str(config),
            "init",
            "--claude",
            "1",
            "--force",
        ],
        cwd=tmp_path,
        env=env,
        text=True,
        capture_output=True,
        timeout=20,
        check=False,
    )
    assert result.returncode == 2
    assert not config.exists()


def test_live_task_cannot_be_rebound(fleet: tuple[object, Path]) -> None:
    _, config = fleet
    registry = load_registry(config)
    profiles = dict(registry.profiles)
    profiles["claude-1"] = replace(profiles["claude-1"], enabled=True)
    registry = replace(registry, profiles=profiles)
    save_registry(registry, config)
    registry = load_registry(config)
    provision_profile(registry, registry.require_profile("claude-1"))
    select_and_acquire(
        registry,
        task="owned-task",
        pool="claude-crew",
        profile_id="claude-1",
        bind_pid=os.getpid(),
        workspace=Path.cwd(),
    )
    try:
        select_and_acquire(
            registry,
            task="owned-task",
            pool="claude-crew",
            profile_id="claude-1",
            bind_pid=os.getpid() + 1,
            workspace=Path.cwd(),
        )
    except ValueError as exc:
        assert "already owned" in str(exc)
    else:
        raise AssertionError("live lease was rebound")
