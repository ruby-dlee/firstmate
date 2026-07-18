from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

from agent_fleet.config import load_registry
from agent_fleet.projects import resolve_trusted_project
from agent_fleet.providers import managed_argv, resume_argv, validate_worker_arguments
from agent_fleet.provision import (
    codex_hooks_ready,
    prepare_profile_launch,
    profile_launch_ready,
    provision_profile,
)


def test_claude_bootstrap_preserves_opaque_state_and_ignores_base_state(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = registry.require_profile("claude-1")
    provision_profile(registry, profile)
    base_home = registry.require_provider("claude").base_home
    assert base_home is not None
    (base_home / ".claude.json").write_text(
        json.dumps({"oauthAccount": {"secret": "must-not-copy"}}), encoding="utf-8"
    )
    state_path = profile.home / ".claude.json"
    state_path.write_text(
        json.dumps(
            {
                "oauthAccount": {"accountUuid": "opaque-worker"},
                "projects": {"/unrelated": {"opaque": True}},
            }
        ),
        encoding="utf-8",
    )
    state_path.chmod(0o600)

    project = prepare_profile_launch(registry, profile, Path.cwd())
    state = json.loads(state_path.read_text(encoding="utf-8"))

    assert state["oauthAccount"] == {"accountUuid": "opaque-worker"}
    assert state["projects"]["/unrelated"] == {"opaque": True}
    assert "secret" not in json.dumps(state)
    assert state["hasCompletedOnboarding"] is True
    for root in {project.active_root, project.canonical_root}:
        assert state["projects"][str(root)]["hasTrustDialogAccepted"] is True
    assert profile_launch_ready(registry, profile, Path.cwd()) is True


def test_linked_worktree_matches_registered_git_common_dir(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    registered = Path.cwd()
    (registered / "tracked.txt").write_text("tracked\n", encoding="utf-8")
    subprocess.run(["git", "add", "tracked.txt"], cwd=registered, check=True)
    subprocess.run(
        [
            "git",
            "-c",
            "user.name=Agent Fleet Tests",
            "-c",
            "user.email=agent-fleet@example.invalid",
            "commit",
            "-qm",
            "fixture",
        ],
        cwd=registered,
        check=True,
    )
    linked = tmp_path / "linked-worktree"
    subprocess.run(
        ["git", "worktree", "add", "-q", "-b", "linked-test", str(linked)],
        cwd=registered,
        check=True,
    )

    project = resolve_trusted_project(registry, "codex", linked)

    assert project.active_root == linked
    assert project.canonical_root == registered


def test_unrelated_and_symlinked_workspaces_fail_closed(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    unrelated = tmp_path / "unrelated"
    unrelated.mkdir()
    subprocess.run(["git", "init", "-q", str(unrelated)], check=True)
    with pytest.raises(ValueError, match="not registered"):
        resolve_trusted_project(registry, "claude", unrelated)
    linked = tmp_path / "project-link"
    linked.symlink_to(Path.cwd(), target_is_directory=True)
    with pytest.raises(ValueError, match="must not be symlinked"):
        resolve_trusted_project(registry, "claude", linked)


def test_codex_launch_uses_exact_managed_prefix_for_new_and_resume(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = registry.require_profile("codex-1")
    provision_profile(registry, profile)
    project = prepare_profile_launch(registry, profile, Path.cwd())
    trust = f'projects.{json.dumps(str(project.active_root))}.trust_level="trusted"'
    prefix = [
        "--disable",
        "plugins",
        "--disable",
        "plugin_sharing",
        "-c",
        trust,
        "--dangerously-bypass-hook-trust",
    ]

    assert managed_argv(registry, profile, project.active_root, ["--full-auto"])[1:] == [
        *prefix,
        "--full-auto",
    ]
    assert resume_argv(
        registry,
        profile,
        "session-1",
        ["--full-auto"],
        active_root=project.active_root,
    )[1:] == ["resume", *prefix, "session-1", "--full-auto"]


def test_codex_launch_refuses_changed_hooks_markers_sources_and_project_hooks(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = registry.require_profile("codex-1")
    provision_profile(registry, profile)
    assert codex_hooks_ready(registry, profile) is True

    hooks_path = profile.home / "hooks.json"
    hooks = json.loads(hooks_path.read_text(encoding="utf-8"))
    hooks["hooks"]["SessionStart"].append({"matcher": "", "hooks": []})
    hooks_path.write_text(json.dumps(hooks), encoding="utf-8")
    assert codex_hooks_ready(registry, profile) is False

    provision_profile(registry, profile)
    marker = profile.home / ".agent-fleet-hooks.json"
    marker_payload = json.loads(marker.read_text(encoding="utf-8"))
    marker_payload["agent_fleet_version"] = "0.0.0"
    marker.write_text(json.dumps(marker_payload), encoding="utf-8")
    assert codex_hooks_ready(registry, profile) is False

    provision_profile(registry, profile)
    source = registry.require_provider("codex").hooks_source
    assert source is not None
    source.write_text(source.read_text(encoding="utf-8") + "\n", encoding="utf-8")
    assert codex_hooks_ready(registry, profile) is False

    provision_profile(registry, profile)
    project_hooks = Path.cwd() / ".codex" / "hooks.json"
    project_hooks.parent.mkdir()
    project_hooks.write_text("{}\n", encoding="utf-8")
    with pytest.raises(ValueError, match="refuses project hooks"):
        prepare_profile_launch(registry, profile, Path.cwd())


def test_codex_worker_arguments_cannot_reenable_managed_surfaces(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    profile = load_registry(config).require_profile("codex-1")
    for arguments in (
        ["login"],
        ["resume", "other"],
        ["--enable=plugin_sharing"],
        ["--config", 'projects."/tmp".trust_level="trusted"'],
        ["-C", "/tmp"],
    ):
        with pytest.raises(ValueError):
            validate_worker_arguments(profile, arguments)
