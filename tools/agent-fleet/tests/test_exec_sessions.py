from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
from dataclasses import replace
from pathlib import Path

from agent_fleet.config import load_registry, save_registry
from agent_fleet.provision import provision_profile
from agent_fleet.scheduler import select_and_acquire
from agent_fleet.sessions import get_session, record_session_from_hook


def _fake_provider(path: Path) -> None:
    path.write_text(
        """#!/usr/bin/env python3
import json
import os
import sys
print(json.dumps({
    "argv": sys.argv[1:],
    "profile": os.environ.get("AGENT_FLEET_PROFILE"),
    "task": os.environ.get("AGENT_FLEET_TASK_ID"),
    "codex_home": os.environ.get("CODEX_HOME"),
    "claude_home": os.environ.get("CLAUDE_CONFIG_DIR"),
    "has_openai_key": "OPENAI_API_KEY" in os.environ,
    "has_anthropic_key": "ANTHROPIC_API_KEY" in os.environ,
}))
""",
        encoding="utf-8",
    )
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


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

    project_root = Path(__file__).parents[1]
    env = dict(os.environ)
    env["PYTHONPATH"] = str(project_root / "src")
    env["OPENAI_API_KEY"] = "must-not-reach-provider"
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "agent_fleet",
            "--config",
            str(config),
            "exec",
            "--task",
            "exec-task",
            "--pool",
            "codex-crew",
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
        check=True,
    )
    payload = json.loads(result.stdout)
    assert payload["argv"][-1:] == ["example-argument"]
    assert payload["argv"][:4] == [
        "--disable",
        "plugins",
        "--disable",
        "plugin_sharing",
    ]
    assert payload["profile"] == "codex-1"
    assert payload["task"] == "exec-task"
    assert payload["codex_home"] == str(profile.home)
    assert payload["claude_home"] is None
    assert payload["has_openai_key"] is False


def test_session_hook_persists_profile_and_provider_session(
    fleet: tuple[object, Path], monkeypatch
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
    )
    monkeypatch.setenv("AGENT_FLEET_TASK_ID", "hook-task")
    monkeypatch.setenv("AGENT_FLEET_PROFILE", "claude-1")
    monkeypatch.setenv("AGENT_FLEET_PROVIDER", "claude")

    result = record_session_from_hook(
        registry, {"hook_event_name": "SessionStart", "session_id": "session-123"}
    )
    mapping = get_session(registry, "hook-task")
    assert result["recorded"] is True
    assert mapping["profile"] == "claude-1"
    assert mapping["provider"] == "claude"
    assert mapping["session_id"] == "session-123"
    assert mapping["pool"] == "claude-crew"

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
    assert "worker resume requires --task" in result.stderr


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
    assert "worker exec requires --task" in result.stderr


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
        assert (
            "refuses" in json.loads(result.stdout)["error"]
            or "disabled" in json.loads(result.stdout)["error"]
        )


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
    )
    try:
        select_and_acquire(
            registry,
            task="owned-task",
            pool="claude-crew",
            profile_id="claude-1",
            bind_pid=os.getpid() + 1,
        )
    except ValueError as exc:
        assert "already owned" in str(exc)
    else:
        raise AssertionError("live lease was rebound")
