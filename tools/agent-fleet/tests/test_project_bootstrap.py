from __future__ import annotations

import hashlib
import json
import os
import subprocess
from dataclasses import replace
from pathlib import Path

import pytest

import agent_fleet.cli as cli_module
import agent_fleet.providers as providers_module
import agent_fleet.provision as provision_module
import agent_fleet.routeability as routeability_module
import agent_fleet.scheduler as scheduler_module
from agent_fleet.config import load_registry
from agent_fleet.doctor import run_doctor
from agent_fleet.leases import active_leases
from agent_fleet.projects import (
    enter_trusted_project,
    register_trusted_project,
    remove_trusted_project,
    resolve_trusted_project,
    revalidate_trusted_project,
)
from agent_fleet.providers import (
    managed_argv,
    resume_argv,
    session_hook_command,
    validate_worker_arguments,
)
from agent_fleet.provision import (
    claude_hooks_ready,
    codex_hooks_ready,
    prepare_profile_launch,
    profile_hook_health,
    profile_launch_ready,
    profile_selection_ready,
    provider_binary_ready,
    provision_profile,
    verified_agent_fleet_hook_entrypoint,
    verified_provider_binary,
)
from agent_fleet.quota import inspect_credential_source_contract
from agent_fleet.scheduler import select_and_acquire


def _file_snapshot(root: Path) -> dict[str, bytes]:
    return {
        str(path.relative_to(root)): path.read_bytes()
        for path in root.rglob("*")
        if path.is_file() and not path.is_symlink()
    }


def test_claude_bootstrap_rejects_opaque_state_and_ignores_base_state(
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

    before = state_path.read_bytes()
    with pytest.raises(ValueError, match="trust bootstrap failed"):
        prepare_profile_launch(registry, profile, Path.cwd())
    assert state_path.read_bytes() == before
    assert profile_launch_ready(registry, profile, Path.cwd()) is False


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


def test_trusted_project_validation_ignores_ambient_git(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    shadow = tmp_path / "shadow"
    shadow.mkdir()
    marker = tmp_path / "ambient-git-ran"
    fake_git = shadow / "git"
    fake_git.write_text(
        f"#!/bin/sh\ntouch '{marker}'\nprintf '%s\\n' \"$PWD\"\n",
        encoding="utf-8",
    )
    fake_git.chmod(0o755)
    non_repository = tmp_path / "not-a-repository"
    non_repository.mkdir()
    monkeypatch.setenv("PATH", str(shadow))

    with pytest.raises(ValueError, match="Git worktree"):
        register_trusted_project(non_repository)

    assert not marker.exists()


def test_trusted_project_rejects_writable_root_and_ancestry(tmp_path: Path) -> None:
    for name, writable_target in (("root", "root"), ("ancestor", "ancestor"), ("git", "git")):
        ancestor = tmp_path / name / "ancestor"
        repository = ancestor / "repository"
        repository.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(repository)], check=True)
        if writable_target == "root":
            repository.chmod(0o775)
        elif writable_target == "ancestor":
            ancestor.chmod(0o777)
        else:
            (repository / ".git").chmod(0o775)

        with pytest.raises(ValueError, match="writable"):
            register_trusted_project(repository)


def test_trusted_project_revalidation_rejects_root_replacement(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    registry, _ = fleet
    repository = tmp_path / "replaceable-project"
    repository.mkdir()
    subprocess.run(["git", "init", "-q", str(repository)], check=True)
    providers = dict(registry.providers)
    providers["codex"] = replace(providers["codex"], trusted_projects=(repository,))
    registry = replace(registry, providers=providers)
    project = resolve_trusted_project(registry, "codex", repository)

    original = repository.with_name("replaceable-project-original")
    repository.rename(original)
    repository.mkdir()
    subprocess.run(["git", "init", "-q", str(repository)], check=True)

    with pytest.raises(ValueError, match="changed before provider launch"):
        revalidate_trusted_project(registry, "codex", repository, project)
    with pytest.raises(ValueError, match="changed before provider launch"):
        enter_trusted_project(project)


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
    assert set(state) == {"hasCompletedOnboarding", "projects"}
    assert state["hasCompletedOnboarding"] is True
    project = str(Path.cwd())
    assert state["projects"][project] == {
        "hasTrustDialogAccepted": True,
        "hasCompletedProjectOnboarding": True,
    }
    assert profile_launch_ready(registry, profile, Path.cwd()) is True


def test_closed_claude_state_keeps_auth_in_its_attested_source(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = registry.require_profile("claude-1")
    credential = profile.home / ".credentials.json"
    credential_before = credential.read_bytes()

    provision_profile(registry, profile)

    assert json.loads((profile.home / ".claude.json").read_text(encoding="utf-8")) == {
        "hasCompletedOnboarding": True,
        "projects": {
            str(Path.cwd()): {
                "hasCompletedProjectOnboarding": True,
                "hasTrustDialogAccepted": True,
            }
        },
    }
    assert credential.read_bytes() == credential_before
    assert inspect_credential_source_contract(registry, profile) == {
        "kind": "oauth-file",
        "path": str(credential),
    }


def test_unregistered_linked_claude_project_cannot_mutate_closed_trust_state(
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

    before = state_path.read_bytes()
    with pytest.raises(ValueError, match="trust bootstrap failed"):
        prepare_profile_launch(registry, profile, linked)
    assert state_path.read_bytes() == before


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
    notify = 'notify=["bash","-c","touch \'/tmp/codex-task.turn-ended\'"]'
    exec_arguments = [
        "--model",
        "gpt-5",
        "-c",
        'model_reasoning_effort="high"',
        "--dangerously-bypass-approvals-and-sandbox",
        "-c",
        notify,
        "login",
    ]
    parsed_exec = validate_worker_arguments(profile, exec_arguments, operation="exec")
    resume_arguments = exec_arguments[:-1]
    parsed_resume = validate_worker_arguments(profile, resume_arguments, operation="resume")

    binary = verified_provider_binary(registry, profile)
    hook_entrypoint = verified_agent_fleet_hook_entrypoint()
    managed_notify = "notify=" + json.dumps(
        [
            str(hook_entrypoint),
            "--config",
            str(registry.config_path),
            "--format",
            "json",
            "hook",
            "turn-end",
        ],
        separators=(",", ":"),
    )
    managed_options = [
        "--model",
        "gpt-5",
        "-c",
        'model_reasoning_effort="high"',
        "--dangerously-bypass-approvals-and-sandbox",
        "-c",
        managed_notify,
    ]
    assert managed_argv(
        registry,
        profile,
        project.active_root,
        parsed_exec,
        binary=binary,
        hook_entrypoint=hook_entrypoint,
    )[1:] == [
        *prefix,
        *managed_options,
        "--",
        "login",
    ]
    assert resume_argv(
        registry,
        profile,
        "session-1",
        parsed_resume,
        active_root=project.active_root,
        binary=binary,
        hook_entrypoint=hook_entrypoint,
    )[1:] == ["resume", *prefix, "session-1", *managed_options]
    assert "bash" not in managed_notify
    assert "touch" not in managed_notify


def test_profile_hooks_pin_release_entrypoint_and_ignore_path_or_current_switch(
    fleet: tuple[object, Path], tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = registry.require_profile("claude-1")
    release_one = tmp_path / "releases" / "one" / "bin"
    release_two = tmp_path / "releases" / "two" / "bin"
    release_one.mkdir(parents=True)
    release_two.mkdir(parents=True)
    for release, marker in ((release_one, "one"), (release_two, "two")):
        entrypoint = release / "agent-fleet"
        entrypoint.write_text(f"#!/bin/sh\necho {marker}\n", encoding="utf-8")
        entrypoint.chmod(0o755)
    current = tmp_path / "current"
    current.symlink_to(release_one.parent, target_is_directory=True)
    shadow = tmp_path / "shadow"
    shadow.mkdir()
    (shadow / "agent-fleet").write_text("#!/bin/sh\nexit 99\n", encoding="utf-8")
    (shadow / "agent-fleet").chmod(0o755)
    monkeypatch.setenv("PATH", f"{shadow}:{current / 'bin'}:{os.environ['PATH']}")
    monkeypatch.setattr(providers_module.sys, "executable", str(release_one / "python"))

    provision_profile(registry, profile)
    settings = json.loads((profile.home / "settings.json").read_text(encoding="utf-8"))
    marker = json.loads(
        (profile.home / provision_module.HOOK_MARKER_FILE).read_text(encoding="utf-8")
    )
    commands = [
        hook["command"]
        for groups in settings["hooks"].values()
        for group in groups
        for hook in group["hooks"]
    ]
    pinned = str(release_one / "agent-fleet")
    assert any(command.startswith(pinned + " ") for command in commands)
    assert all(str(shadow / "agent-fleet") not in command for command in commands)
    assert marker["agent_fleet_binary"]["resolved_path"] == pinned

    current.unlink()
    current.symlink_to(release_two.parent, target_is_directory=True)
    assert claude_hooks_ready(registry, profile) is True
    persisted = (profile.home / "settings.json").read_text(encoding="utf-8")
    assert str(release_two / "agent-fleet") not in persisted

    monkeypatch.setattr(providers_module.sys, "executable", str(release_two / "python"))
    assert claude_hooks_ready(registry, profile) is False
    assert profile_selection_ready(registry, profile, Path.cwd()) is False


def test_claude_launch_uses_positive_grammar_and_prompt_separator(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = registry.require_profile("claude-1")
    provision_profile(registry, profile)
    binary = verified_provider_binary(registry, profile)
    arguments = [
        "--dangerously-skip-permissions",
        "--model",
        "claude-opus-4-1",
        "--effort",
        "xhigh",
    ]
    parsed_exec = validate_worker_arguments(
        profile,
        [*arguments, "setup-token"],
        operation="exec",
    )
    parsed_resume = validate_worker_arguments(profile, arguments, operation="resume")

    assert managed_argv(
        registry,
        profile,
        Path.cwd(),
        parsed_exec,
        binary=binary,
    )[1:] == [
        *arguments,
        "--",
        "setup-token",
    ]
    assert resume_argv(
        registry,
        profile,
        "claude-session",
        parsed_resume,
        active_root=Path.cwd(),
        binary=binary,
    )[1:] == ["--resume", "claude-session", *arguments]


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
        json.dumps(hooks["hooks"], sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    marker.write_text(json.dumps(marker_payload), encoding="utf-8")
    hooks_path.write_text(json.dumps(hooks), encoding="utf-8")
    assert marker_payload["session_command"] != session_hook_command(registry.config_path)
    assert codex_hooks_ready(registry, profile) is False

    provision_profile(registry, profile)
    marker = profile.home / ".agent-fleet-hooks.json"
    marker_payload = json.loads(marker.read_text(encoding="utf-8"))
    marker_payload["agent_fleet_version"] = "0.0.0"
    marker.write_text(json.dumps(marker_payload), encoding="utf-8")
    assert codex_hooks_ready(registry, profile) is False

    provision_profile(registry, profile)
    project_hooks = Path.cwd() / ".codex" / "hooks.json"
    project_hooks.parent.mkdir()
    project_hooks.write_text("{}\n", encoding="utf-8")
    with pytest.raises(ValueError, match="refuses project control file"):
        prepare_profile_launch(registry, profile, Path.cwd())


@pytest.mark.parametrize(
    ("provider", "relative"),
    [
        ("claude", ".claude/settings.json"),
        ("claude", ".claude/settings.local.json"),
        ("claude", ".mcp.json"),
        ("codex", ".codex/config.toml"),
        ("codex", ".codex/hooks.json"),
        ("codex", ".mcp.json"),
    ],
)
@pytest.mark.parametrize("symlink", [False, True])
def test_selection_rejects_project_control_files_before_state_changes(
    fleet: tuple[object, Path],
    monkeypatch: pytest.MonkeyPatch,
    provider: str,
    relative: str,
    symlink: bool,
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = registry.require_profile(f"{provider}-1")
    profiles = dict(registry.profiles)
    profiles[profile.id] = replace(profile, enabled=True)
    registry = replace(registry, profiles=profiles)
    provision_profile(registry, registry.require_profile(profile.id))
    control = Path.cwd() / relative
    control.parent.mkdir(parents=True, exist_ok=True)
    if symlink:
        control.symlink_to(Path.cwd() / "missing-provider-control")
    else:
        control.write_text("{}\n", encoding="utf-8")
    state_before = _file_snapshot(registry.settings.state_dir)
    provider_calls: list[str] = []
    monkeypatch.setattr(
        scheduler_module,
        "recover_pending_codex_transactions",
        lambda *_args, **_kwargs: provider_calls.append("recovery"),
    )
    monkeypatch.setattr(
        scheduler_module,
        "refresh_provider_identity_anchors_if_due",
        lambda *_args, **_kwargs: provider_calls.append("identity"),
    )
    monkeypatch.setattr(
        scheduler_module,
        "probe_quota",
        lambda *_args, **_kwargs: provider_calls.append("quota"),
    )
    monkeypatch.setattr(
        routeability_module,
        "inspect_credential_source_contract",
        lambda *_args, **_kwargs: provider_calls.append("credential-source"),
    )

    assert (
        profile_selection_ready(registry, registry.require_profile(profile.id), Path.cwd()) is False
    )
    with pytest.raises(ValueError, match="project control file"):
        prepare_profile_launch(registry, registry.require_profile(profile.id), Path.cwd())
    with pytest.raises(ValueError, match="profile is not ready"):
        select_and_acquire(
            registry,
            task=f"blocked-{provider}-project-control",
            pool=f"{provider}-crew",
            profile_id=profile.id,
            workspace=Path.cwd(),
        )

    assert provider_calls == []
    assert active_leases(registry, prune=False) == []
    assert _file_snapshot(registry.settings.state_dir) == state_before


@pytest.mark.parametrize(
    ("provider", "relative"),
    [("claude", ".mcp.json"), ("codex", ".codex/config.toml")],
)
def test_launch_revalidation_rejects_late_project_control_injection(
    fleet: tuple[object, Path], provider: str, relative: str
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = registry.require_profile(f"{provider}-1")
    project = prepare_profile_launch(registry, profile, Path.cwd())
    control = Path.cwd() / relative
    control.parent.mkdir(parents=True, exist_ok=True)
    control.write_text("{}\n", encoding="utf-8")

    with pytest.raises(ValueError, match="refuses project control file"):
        revalidate_trusted_project(registry, provider, Path.cwd(), project)


@pytest.mark.parametrize(
    ("provider", "relative"),
    [("claude", ".mcp.json"), ("codex", ".codex/config.toml")],
)
def test_final_exec_gate_rejects_control_created_by_environment_builder(
    fleet: tuple[object, Path],
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    provider: str,
    relative: str,
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = registry.require_profile(f"{provider}-1")
    project = prepare_profile_launch(registry, profile, Path.cwd())
    control = project.active_root / relative
    exec_calls: list[tuple[object, ...]] = []

    def inject_control(*_args: object, **_kwargs: object) -> dict[str, str]:
        control.parent.mkdir(parents=True, exist_ok=True)
        control.write_text("{}\n", encoding="utf-8")
        return {"PATH": os.environ.get("PATH", "")}

    monkeypatch.setattr(cli_module, "provider_environment", inject_control)
    monkeypatch.setattr(
        cli_module.os,
        "execvpe",
        lambda *args: exec_calls.append(args),
    )

    with pytest.raises(ValueError, match="refuses project control file"):
        cli_module._exec_managed_provider(
            project,
            profile,
            ["/bin/false"],
            f"{provider}-final-gate",
            project.active_root,
            f"{provider}-crew",
            tmp_path / f"{provider}.turn-ended",
        )

    assert exec_calls == []


@pytest.mark.parametrize(
    ("provider", "instruction"),
    [("claude", "CLAUDE.md"), ("codex", "AGENTS.md")],
)
def test_project_instruction_files_remain_allowed(
    fleet: tuple[object, Path], provider: str, instruction: str
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = registry.require_profile(f"{provider}-1")
    profiles = dict(registry.profiles)
    profiles[profile.id] = replace(profile, enabled=True)
    registry = replace(registry, profiles=profiles)
    provision_profile(registry, registry.require_profile(profile.id))
    (Path.cwd() / instruction).write_text("managed instructions\n", encoding="utf-8")

    selected = select_and_acquire(
        registry,
        task=f"allowed-{provider}-instructions",
        pool=f"{provider}-crew",
        profile_id=profile.id,
        dry_run=True,
        workspace=Path.cwd(),
    )

    assert selected["profile"] == profile.id


def test_provider_binary_symlink_is_refused_before_profile_provisioning(
    fleet: tuple[object, Path],
    tmp_path: Path,
) -> None:
    _, config = fleet
    registry = load_registry(config)
    target = tmp_path / "codex-target"
    target.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    target.chmod(0o755)
    configured_binary = tmp_path / "codex-current"
    configured_binary.symlink_to(target)
    providers = dict(registry.providers)
    providers["codex"] = replace(providers["codex"], binary=configured_binary)
    registry = replace(registry, providers=providers)
    profile = registry.require_profile("codex-1")
    home_before = _file_snapshot(profile.home) if profile.home.exists() else {}

    with pytest.raises(ValueError, match="provider binary must be a current-user regular file"):
        provision_profile(registry, profile)

    assert configured_binary.is_symlink()
    assert _file_snapshot(profile.home) == home_before


def test_provider_binary_drift_stops_before_provider_or_state_changes(
    fleet: tuple[object, Path],
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    _, config = fleet
    registry = load_registry(config)
    first = tmp_path / "codex-v1"
    first.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    first.chmod(0o755)
    configured_binary = first
    providers = dict(registry.providers)
    providers["codex"] = replace(
        providers["codex"],
        binary=configured_binary,
    )
    profile = registry.require_profile("codex-1")
    profiles = dict(registry.profiles)
    profiles[profile.id] = replace(profile, enabled=True)
    registry = replace(registry, providers=providers, profiles=profiles)
    provision_profile(registry, registry.require_profile(profile.id))
    assert provider_binary_ready(registry, registry.require_profile(profile.id)) is True
    first.write_text("#!/bin/sh\nexit 9\n", encoding="utf-8")
    first.chmod(0o755)
    state_before = _file_snapshot(registry.settings.state_dir)
    provider_calls: list[str] = []
    monkeypatch.setattr(
        scheduler_module,
        "recover_pending_codex_transactions",
        lambda *_args, **_kwargs: provider_calls.append("recovery"),
    )
    monkeypatch.setattr(
        scheduler_module,
        "refresh_provider_identity_anchors_if_due",
        lambda *_args, **_kwargs: provider_calls.append("identity"),
    )
    monkeypatch.setattr(
        scheduler_module,
        "probe_quota",
        lambda *_args, **_kwargs: provider_calls.append("quota"),
    )
    monkeypatch.setattr(
        routeability_module,
        "inspect_credential_source_contract",
        lambda *_args, **_kwargs: provider_calls.append("credential-source"),
    )

    assert provider_binary_ready(registry, registry.require_profile(profile.id)) is False
    with pytest.raises(ValueError, match="provider binary changed"):
        prepare_profile_launch(registry, registry.require_profile(profile.id), Path.cwd())
    with pytest.raises(ValueError, match="profile is not ready"):
        select_and_acquire(
            registry,
            task="blocked-provider-content-replacement",
            pool="codex-crew",
            profile_id=profile.id,
            workspace=Path.cwd(),
        )

    doctor = run_doctor(registry, config, project=Path.cwd())
    binary_check = next(
        check for check in doctor["checks"] if check["name"] == "profile:codex-1:provider-binary"
    )
    assert binary_check["ok"] is False
    assert provider_calls == []
    assert active_leases(registry, prune=False) == []
    assert _file_snapshot(registry.settings.state_dir) == state_before


def test_provider_binary_drift_after_readiness_is_refused_before_argv_build(
    fleet: tuple[object, Path],
    tmp_path: Path,
) -> None:
    _, config = fleet
    registry = load_registry(config)
    binary = tmp_path / "codex-provider"
    binary.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    binary.chmod(0o755)
    providers = dict(registry.providers)
    providers["codex"] = replace(providers["codex"], binary=binary)
    registry = replace(registry, providers=providers)
    profile = registry.require_profile("codex-1")
    provision_profile(registry, profile)
    project = prepare_profile_launch(registry, profile, Path.cwd())
    arguments = validate_worker_arguments(
        profile,
        ["--dangerously-bypass-approvals-and-sandbox", "prompt"],
        operation="exec",
    )

    binary.write_text("#!/bin/sh\nexit 77\n", encoding="utf-8")
    binary.chmod(0o755)

    with pytest.raises(ValueError, match="provider binary changed"):
        managed_argv(
            registry,
            profile,
            project.active_root,
            arguments,
            binary=verified_provider_binary(registry, profile),
        )


def test_claude_provision_normalizes_non_hook_launch_controls_without_touching_auth(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = registry.require_profile("claude-1")
    profile.home.mkdir(parents=True, mode=0o700, exist_ok=True)
    profile.home.chmod(0o700)
    settings_path = profile.home / "settings.json"
    settings_path.write_text(
        json.dumps(
            {
                "theme": "dark",
                "permissions": {"allow": ["Read"]},
                "hooks": {
                    "SessionStart": [
                        {
                            "matcher": "startup",
                            "hooks": [
                                {
                                    "type": "command",
                                    "command": "spoof hook session-start",
                                }
                            ],
                        }
                    ],
                    "Stop": [{"hooks": [{"type": "command", "command": "profile-local-hook"}]}],
                },
            }
        ),
        encoding="utf-8",
    )
    settings_path.chmod(0o600)
    auth_path = profile.home / ".credentials.json"
    auth_path.write_bytes(b'{"oauth":"preserve-exactly"}\n')
    auth_path.chmod(0o600)
    auth_before = auth_path.read_bytes()

    provision_profile(registry, profile)
    first = settings_path.read_bytes()
    provision_profile(registry, profile)

    settings = json.loads(settings_path.read_text(encoding="utf-8"))
    assert settings_path.read_bytes() == first
    assert auth_path.read_bytes() == auth_before
    assert set(settings) == {"hooks"}
    commands = [
        entry["command"]
        for groups in settings["hooks"].values()
        for group in groups
        for entry in group["hooks"]
    ]
    assert commands.count("base-hook") == 0
    assert commands.count(session_hook_command(registry.config_path)) == 1
    assert "profile-local-hook" not in commands
    assert "spoof hook session-start" not in commands
    assert claude_hooks_ready(registry, profile) is True
    assert profile_hook_health(registry, profile)["closed_profile_hooks"] is True

    settings["permissions"] = {"allow": ["Bash"]}
    settings_path.write_text(json.dumps(settings), encoding="utf-8")
    settings_path.chmod(0o600)
    assert profile_selection_ready(registry, profile, Path.cwd()) is False


def test_claude_hook_readiness_refuses_co_tamper_duplicate_unsafe_and_source_drift(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = registry.require_profile("claude-1")
    provision_profile(registry, profile)
    settings_path = profile.home / "settings.json"
    marker_path = profile.home / ".agent-fleet-hooks.json"

    settings = json.loads(settings_path.read_text(encoding="utf-8"))
    marker = json.loads(marker_path.read_text(encoding="utf-8"))
    command = "touch /tmp/not-agent-fleet"
    settings["hooks"]["SessionStart"][-1]["hooks"][0]["command"] = command
    marker["session_command"] = command
    marker["hooks_hash"] = hashlib.sha256(
        json.dumps(settings["hooks"], sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    settings_path.write_text(json.dumps(settings), encoding="utf-8")
    marker_path.write_text(json.dumps(marker), encoding="utf-8")
    assert claude_hooks_ready(registry, profile) is False

    provision_profile(registry, profile)
    settings = json.loads(settings_path.read_text(encoding="utf-8"))
    settings["hooks"]["SessionStart"].append(settings["hooks"]["SessionStart"][-1].copy())
    settings_path.write_text(json.dumps(settings), encoding="utf-8")
    assert claude_hooks_ready(registry, profile) is False

    provision_profile(registry, profile)
    settings_path.chmod(0o644)
    assert claude_hooks_ready(registry, profile) is False


def test_declared_hook_source_is_never_inherited(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = registry.require_profile("claude-1")
    source = Path.cwd() / "mutable-base-hooks.json"
    source.write_text(
        json.dumps({"hooks": {"SessionStart": [{"hooks": [{"command": "base-hook"}]}]}})
    )
    source.chmod(0o600)
    provider = registry.require_provider("claude")
    providers = dict(registry.providers)
    providers["claude"] = replace(provider, hooks_source=source)
    registry = replace(registry, providers=providers)

    with pytest.raises(ValueError, match="hooks_source must be absent"):
        provision_profile(registry, profile)


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

    with pytest.raises(ValueError, match="hooks_source must be absent"):
        provision_profile(registry, profile)
    assert not profile.home.exists()


@pytest.mark.parametrize("provider_name", ["claude", "codex"])
def test_provision_refuses_missing_configured_hook_source(
    fleet: tuple[object, Path], tmp_path: Path, provider_name: str
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = replace(
        registry.require_profile(f"{provider_name}-1"),
        home=tmp_path / f"missing-source-{provider_name}",
    )
    providers = dict(registry.providers)
    providers[provider_name] = replace(
        providers[provider_name],
        hooks_source=tmp_path / f"absent-{provider_name}.json",
    )

    with pytest.raises(ValueError, match="hooks_source must be absent"):
        provision_profile(replace(registry, providers=providers), profile)
    assert not profile.home.exists()


@pytest.mark.parametrize("asset", ["provider", "hook"])
def test_provision_refuses_user_owned_sticky_writable_asset_ancestry(
    fleet: tuple[object, Path], tmp_path: Path, asset: str
) -> None:
    _, config = fleet
    registry = load_registry(config)
    sticky = tmp_path / "user-sticky"
    sticky.mkdir(mode=0o700)
    sticky.chmod(0o1777)
    providers = dict(registry.providers)
    provider = providers["codex"]
    candidate = sticky / ("codex" if asset == "provider" else "hooks.json")
    candidate.write_text("#!/bin/sh\nexit 0\n" if asset == "provider" else "{}\n")
    candidate.chmod(0o755 if asset == "provider" else 0o600)
    providers["codex"] = replace(
        provider,
        binary=candidate if asset == "provider" else provider.binary,
        hooks_source=candidate if asset == "hook" else provider.hooks_source,
    )
    profile = replace(registry.require_profile("codex-1"), home=tmp_path / f"sticky-{asset}")

    expected = (
        "group/world-writable ancestry" if asset == "provider" else "hooks_source must be absent"
    )
    with pytest.raises(ValueError, match=expected):
        provision_profile(replace(registry, providers=providers), profile)
    assert not profile.home.exists()


@pytest.mark.parametrize("provider_name", ["claude", "codex"])
def test_provision_rejects_group_or_world_writable_hook_source(
    fleet: tuple[object, Path], tmp_path: Path, provider_name: str
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = replace(
        registry.require_profile(f"{provider_name}-1"),
        home=tmp_path / f"new-{provider_name}-profile",
    )
    source = tmp_path / f"unsafe-{provider_name}-hooks.json"
    source.write_text("{}\n", encoding="utf-8")
    source.chmod(0o666)
    providers = dict(registry.providers)
    providers[provider_name] = replace(providers[provider_name], hooks_source=source)
    registry = replace(registry, providers=providers)

    with pytest.raises(ValueError, match="hooks_source must be absent"):
        provision_profile(registry, profile)

    assert not profile.home.exists()


@pytest.mark.parametrize("provider_name", ["claude", "codex"])
def test_provision_rejects_hook_source_before_reading_it(
    fleet: tuple[object, Path],
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    provider_name: str,
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = replace(
        registry.require_profile(f"{provider_name}-1"),
        home=tmp_path / f"swapped-{provider_name}-profile",
    )
    source = tmp_path / f"unread-{provider_name}-hooks.json"
    source.write_text("{}\n", encoding="utf-8")
    source.chmod(0o600)
    providers = dict(registry.providers)
    providers[provider_name] = replace(providers[provider_name], hooks_source=source)
    registry = replace(registry, providers=providers)
    real_read = Path.read_text

    def refuse_source_read(path: Path, *args, **kwargs):
        if path == source:
            raise AssertionError("mutable hook source was read")
        return real_read(path, *args, **kwargs)

    monkeypatch.setattr(Path, "read_text", refuse_source_read)

    with pytest.raises(ValueError, match="hooks_source must be absent"):
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


@pytest.mark.parametrize(
    "extra",
    [
        'model = "gpt-5"\n',
        '[mcp_servers.attacker]\ncommand = "false"\n',
        'notify = ["false"]\n',
        '[shell_environment_policy]\ninherit = "all"\n',
    ],
)
def test_codex_profile_config_rejects_every_unmanaged_launch_control(
    fleet: tuple[object, Path], extra: str
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = registry.require_profile("codex-1")
    provision_profile(registry, profile)
    config_path = profile.home / "config.toml"
    config_path.write_text(
        provision_module.CODEX_MANAGED_CONFIG_TEXT + "\n" + extra,
        encoding="utf-8",
    )

    assert profile_selection_ready(registry, profile, Path.cwd()) is False
    with pytest.raises(ValueError, match="config is not ready"):
        prepare_profile_launch(registry, profile, Path.cwd())


def test_codex_reprovision_normalizes_controls_and_preserves_auth_bytes(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profile = registry.require_profile("codex-1")
    provision_profile(registry, profile)
    auth_path = profile.home / "auth.json"
    auth_path.write_bytes(b'{"tokens":{"opaque":"preserve-exactly"}}\n')
    auth_path.chmod(0o600)
    auth_before = auth_path.read_bytes()
    config_path = profile.home / "config.toml"
    config_path.write_text(
        provision_module.CODEX_MANAGED_CONFIG_TEXT + '\nmodel = "attacker"\nnotify = ["false"]\n',
        encoding="utf-8",
    )
    config_path.chmod(0o600)

    provision_profile(registry, profile)
    first = config_path.read_bytes()
    provision_profile(registry, profile)

    assert first == provision_module.CODEX_MANAGED_CONFIG_TEXT.encode()
    assert config_path.read_bytes() == first
    assert auth_path.read_bytes() == auth_before
    config_path.write_text(first.decode() + '\nmodel = "tampered"\n', encoding="utf-8")
    config_path.chmod(0o600)
    assert profile_selection_ready(registry, profile, Path.cwd()) is False


def test_codex_worker_arguments_accept_only_firstmate_templates(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    profile = load_registry(config).require_profile("codex-1")
    for arguments in (
        ["login"],
        ["resume", "other"],
        ["--dangerously-bypass-approvals-and-sandbox"],
        ["--dangerously-bypass-approvals-and-sandbox", "one", "two"],
        ["--model=gpt-5", "--dangerously-bypass-approvals-and-sandbox", "prompt"],
        ["--model", "--remote", "--dangerously-bypass-approvals-and-sandbox", "prompt"],
        ["-cfeatures.plugins=true"],
        [
            "-c",
            "model_reasoning_effort=high",
            "--dangerously-bypass-approvals-and-sandbox",
            "prompt",
        ],
        [
            "-c",
            'model_reasoning_effort="max"',
            "--dangerously-bypass-approvals-and-sandbox",
            "prompt",
        ],
        ["--dangerously-bypass-approvals-and-sandbox", "--bg", "prompt"],
        [
            "--dangerously-bypass-approvals-and-sandbox",
            "-c",
            'notify=["bash","-c","touch /tmp/turn"]',
            "prompt",
        ],
        [
            "--dangerously-bypass-approvals-and-sandbox",
            "-c",
            'notify=["bash","-c","touch \'/tmp/x.turn-ended\'; rm -rf /tmp/x"]',
            "prompt",
        ],
    ):
        with pytest.raises(ValueError):
            validate_worker_arguments(profile, arguments, operation="exec")

    with pytest.raises(ValueError, match="no caller prompt or session"):
        validate_worker_arguments(
            profile,
            ["--dangerously-bypass-approvals-and-sandbox", "foreign-session"],
            operation="resume",
        )


def test_claude_worker_arguments_accept_only_firstmate_templates(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    profile = load_registry(config).require_profile("claude-1")
    for arguments in (
        ["agents"],
        ["auth", "login"],
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
        ["--dangerously-skip-permissions"],
        ["--dangerously-skip-permissions", "one", "two"],
        ["--dangerously-skip-permissions", "--bg", "prompt"],
        ["--dangerously-skip-permissions", "--model=opus", "prompt"],
    ):
        with pytest.raises(ValueError):
            validate_worker_arguments(profile, arguments, operation="exec")

    with pytest.raises(ValueError, match="no caller prompt or session"):
        validate_worker_arguments(
            profile,
            ["--dangerously-skip-permissions", "foreign-session"],
            operation="resume",
        )
