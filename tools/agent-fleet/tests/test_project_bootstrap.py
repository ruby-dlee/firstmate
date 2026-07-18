from __future__ import annotations

import hashlib
import json
import subprocess
from dataclasses import replace
from pathlib import Path

import pytest

from agent_fleet.config import load_registry
from agent_fleet.projects import (
    register_trusted_project,
    remove_trusted_project,
    resolve_trusted_project,
)
from agent_fleet.providers import (
    managed_argv,
    resume_argv,
    session_hook_command,
    validate_worker_arguments,
)
from agent_fleet.provision import (
    codex_hooks_ready,
    prepare_profile_launch,
    profile_launch_ready,
    profile_selection_ready,
    provision_profile,
)
from agent_fleet.scheduler import select_and_acquire


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
        assert state["projects"][str(root)]["hasCompletedProjectOnboarding"] is True
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


def test_provision_is_idempotent_and_bootstraps_only_canonical_claude_projects(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = registry.require_profile("claude-1")
    profile.home.mkdir(parents=True, exist_ok=True)
    state_path = profile.home / ".claude.json"
    state_path.write_text(
        json.dumps({"oauthAccount": {"opaque": "preserved"}, "projects": {}}),
        encoding="utf-8",
    )
    state_path.chmod(0o600)

    provision_profile(registry, profile)
    first = state_path.read_bytes()
    provision_profile(registry, profile)

    assert state_path.read_bytes() == first
    state = json.loads(first)
    assert state["oauthAccount"] == {"opaque": "preserved"}
    project = str(Path.cwd())
    assert state["projects"][project] == {
        "hasTrustDialogAccepted": True,
        "hasCompletedProjectOnboarding": True,
    }
    assert profile_launch_ready(registry, profile, Path.cwd()) is True


def test_linked_claude_project_trust_is_added_only_before_exec(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    registered = Path.cwd()
    (registered / "linked-trust.txt").write_text("tracked\n", encoding="utf-8")
    subprocess.run(["git", "add", "linked-trust.txt"], cwd=registered, check=True)
    subprocess.run(
        [
            "git",
            "-c",
            "user.name=Agent Fleet Tests",
            "-c",
            "user.email=agent-fleet@example.invalid",
            "commit",
            "-qm",
            "linked trust fixture",
        ],
        cwd=registered,
        check=True,
    )
    linked = tmp_path / "linked-trust-worktree"
    subprocess.run(
        ["git", "worktree", "add", "-q", "-b", "linked-trust", str(linked)],
        cwd=registered,
        check=True,
    )
    profile = registry.require_profile("claude-1")
    provision_profile(registry, profile)
    state_path = profile.home / ".claude.json"

    assert profile_selection_ready(registry, profile, linked) is True
    profiles = dict(registry.profiles)
    profiles[profile.id] = replace(profile, enabled=True)
    registry = replace(registry, profiles=profiles)
    select_and_acquire(
        registry,
        task="linked-dry-run",
        pool="claude-crew",
        profile_id=profile.id,
        dry_run=True,
        workspace=linked,
    )
    assert str(linked) not in json.loads(state_path.read_text(encoding="utf-8"))["projects"]

    prepare_profile_launch(registry, profile, linked)
    linked_state = json.loads(state_path.read_text(encoding="utf-8"))["projects"][str(linked)]
    assert linked_state["hasTrustDialogAccepted"] is True
    assert linked_state["hasCompletedProjectOnboarding"] is True


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


def test_trusted_project_registration_requires_exact_owned_git_root(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    nested = Path.cwd() / "nested"
    nested.mkdir()
    with pytest.raises(ValueError, match="canonical Git worktree root"):
        register_trusted_project(nested)
    _, config = fleet
    with pytest.raises(ValueError, match="workspace must name its Git worktree root"):
        resolve_trusted_project(load_registry(config), "codex", nested)
    symlink = tmp_path / "trusted-link"
    symlink.symlink_to(Path.cwd(), target_is_directory=True)
    with pytest.raises(ValueError, match="must not be symlinked"):
        register_trusted_project(symlink)


def test_project_removal_accepts_deleted_root_and_linked_common_dir(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    provider = registry.require_provider("codex")
    deleted = tmp_path / "deleted-project"
    configured = replace(provider, trusted_projects=(*provider.trusted_projects, deleted))
    registry = replace(registry, providers={**registry.providers, "codex": configured})
    assert remove_trusted_project(registry, "codex", deleted) == provider.trusted_projects

    registered = Path.cwd()
    (registered / "removal.txt").write_text("tracked\n", encoding="utf-8")
    subprocess.run(["git", "add", "removal.txt"], cwd=registered, check=True)
    subprocess.run(
        [
            "git",
            "-c",
            "user.name=Agent Fleet Tests",
            "-c",
            "user.email=agent-fleet@example.invalid",
            "commit",
            "-qm",
            "removal fixture",
        ],
        cwd=registered,
        check=True,
    )
    linked = tmp_path / "remove-linked"
    subprocess.run(
        ["git", "worktree", "add", "-q", "-b", "remove-linked", str(linked)],
        cwd=registered,
        check=True,
    )
    assert remove_trusted_project(registry, "codex", linked) == (deleted,)


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
    hooks_path = profile.home / "hooks.json"
    marker_payload = json.loads(marker.read_text(encoding="utf-8"))
    hooks = json.loads(hooks_path.read_text(encoding="utf-8"))
    command = "touch /tmp/not-agent-fleet"
    marker_payload["session_command"] = command
    hooks["hooks"]["SessionStart"][-1]["hooks"][0]["command"] = command
    marker_payload["hooks_hash"] = hashlib.sha256(
        json.dumps(hooks, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    marker.write_text(json.dumps(marker_payload), encoding="utf-8")
    hooks_path.write_text(json.dumps(hooks), encoding="utf-8")
    assert marker_payload["session_command"] != session_hook_command()
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


def test_codex_provision_validates_hook_source_before_profile_writes(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = replace(registry.require_profile("codex-1"), home=tmp_path / "new-profile")
    provider = registry.require_provider("codex")
    source_target = tmp_path / "source-target.json"
    source_target.write_text("{}\n", encoding="utf-8")
    source_link = tmp_path / "source-link.json"
    source_link.symlink_to(source_target)
    providers = dict(registry.providers)
    providers["codex"] = replace(provider, hooks_source=source_link)
    registry = replace(registry, providers=providers)

    with pytest.raises(ValueError, match="current-user regular file"):
        provision_profile(registry, profile)
    assert not profile.home.exists()


def test_codex_launch_refuses_profile_plugin_enablement(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = registry.require_profile("codex-1")
    provision_profile(registry, profile)
    config_path = profile.home / "config.toml"
    config_path.write_text(
        config_path.read_text(encoding="utf-8").replace(
            "hooks = true",
            "hooks = true\nplugins = true",
        ),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="config is not ready"):
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
        ["-cfeatures.plugins=true"],
        ["-pproduction"],
        ["--oss"],
        ["--local-provider=ollama"],
        ["--disable", "hooks"],
        ["-C", "/tmp"],
    ):
        with pytest.raises(ValueError):
            validate_worker_arguments(profile, arguments)

    validate_worker_arguments(
        profile,
        [
            "--model",
            "gpt-5",
            "--sandbox",
            "danger-full-access",
            "-cmodel_reasoning_effort=high",
            "-c",
            'notify=["bash","-c","touch /tmp/turn"]',
        ],
    )


def test_claude_worker_arguments_refuse_unmanaged_session_and_runtime_controls(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    profile = load_registry(config).require_profile("claude-1")
    for arguments in (
        ["-c"],
        ["-cother"],
        ["-rsession"],
        ["--settings=other.json"],
        ["--setting-sources", "project"],
        ["--bare"],
        ["--safe-mode"],
        ["--no-session-persistence"],
        ["--session-id=other"],
        ["--fork-session"],
        ["--worktree", "/tmp"],
        ["--tmux"],
        ["--background"],
        ["--from-pr=1"],
        ["--cloud"],
        ["--remote=task"],
        ["--teleport"],
        ["--setup-token=token"],
        ["--agents", "{}"],
    ):
        with pytest.raises(ValueError):
            validate_worker_arguments(profile, arguments)
