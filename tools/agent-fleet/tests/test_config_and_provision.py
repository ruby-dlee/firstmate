from __future__ import annotations

import json
import os
import shlex
import stat
import subprocess
import sys
from dataclasses import replace
from pathlib import Path

import pytest

from agent_fleet.config import (
    DEFAULT_QUOTA_BINARY,
    DEFAULT_QUOTA_NODE_BINARY,
    DEFAULT_QUOTA_RELEASE,
    initial_registry,
    load_registry,
    quota_binary_digest,
    quota_release_tree_digest,
    save_registry,
    set_profile_enabled,
    set_profile_safety_policy,
    verified_quota_binary,
    verified_quota_runtime,
    without_profile,
)
from agent_fleet.doctor import run_doctor
from agent_fleet.provision import (
    profile_hook_health,
    profile_is_provisioned,
    provision_profile,
)
from agent_fleet.quota import refresh_quota
from agent_fleet.scheduler import select_and_acquire


def test_default_quota_paths_pin_the_sealed_017_release() -> None:
    release = "~/.local/libexec/agent-fleet/quota-axi/releases/0.1.7-9f2dde87-sealed"
    assert release == DEFAULT_QUOTA_RELEASE
    assert f"{release}/bin/quota-axi" == DEFAULT_QUOTA_BINARY
    assert f"{release}/runtime/node" == DEFAULT_QUOTA_NODE_BINARY
    assert all(
        "0.1.6" not in path
        for path in (DEFAULT_QUOTA_RELEASE, DEFAULT_QUOTA_BINARY, DEFAULT_QUOTA_NODE_BINARY)
    )


def test_initial_registry_is_dynamic_disabled_and_private(
    fleet: tuple[object, Path],
) -> None:
    _, path = fleet
    registry = load_registry(path)
    assert sorted(registry.profiles) == [
        "claude-1",
        "claude-2",
        "claude-3",
        "codex-1",
        "codex-2",
    ]
    assert not any(profile.enabled for profile in registry.profiles.values())
    assert stat.S_IMODE(path.stat().st_mode) == 0o600


def test_initial_registry_resolves_quota_current_to_hash_pinned_release(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    release_root = tmp_path / "releases" / "0.1.6-test"
    release = release_root / "bin" / "quota-axi"
    release.parent.mkdir(parents=True)
    release.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    release.chmod(0o755)
    entrypoint = release_root / "node_modules" / "quota-axi" / "dist" / "bin" / "quota-axi.js"
    entrypoint.parent.mkdir(parents=True)
    entrypoint.write_text("export {};\n", encoding="utf-8")
    entrypoint.chmod(0o444)
    current = tmp_path / "current"
    current.mkdir(parents=True)
    (current / "quota-axi").symlink_to(release)
    node_release = release_root / "runtime" / "node"
    node_release.parent.mkdir(parents=True)
    node_release.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    node_release.chmod(0o755)
    node_current = tmp_path / "node-current"
    node_current.symlink_to(node_release)
    monkeypatch.setenv("AGENT_FLEET_QUOTA_BIN", str(current / "quota-axi"))
    monkeypatch.setenv("AGENT_FLEET_QUOTA_NODE_BIN", str(node_current))

    registry = initial_registry(1, 1)

    assert registry.settings.quota_binary == release
    assert registry.settings.quota_binary_sha256 == quota_binary_digest(release)
    assert registry.settings.quota_node_binary == node_release
    assert registry.settings.quota_node_sha256 == quota_binary_digest(node_release)
    assert registry.settings.quota_release_tree_sha256 == quota_release_tree_digest(
        release, node_release
    )


def test_legacy_exact_quota_runtime_migrates_once_but_symlinks_refuse(
    fleet: tuple[object, Path], tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    registry, path = fleet
    original = path.read_text(encoding="utf-8")
    legacy_text = (
        "\n".join(
            line
            for line in original.splitlines()
            if not line.startswith(
                (
                    "quota_binary_sha256 =",
                    "quota_node_binary =",
                    "quota_node_sha256 =",
                    "quota_release_tree_sha256 =",
                )
            )
        )
        + "\n"
    )
    monkeypatch.setenv("AGENT_FLEET_QUOTA_NODE_BIN", str(registry.settings.quota_node_binary))
    legacy = tmp_path / "legacy" / "accounts.toml"
    legacy.parent.mkdir(mode=0o700)
    legacy.write_text(legacy_text, encoding="utf-8")
    legacy.chmod(0o600)

    migrated = load_registry(legacy)
    assert migrated.settings.quota_binary_sha256 == quota_binary_digest(
        migrated.settings.quota_binary
    )
    assert migrated.settings.quota_node_sha256 == quota_binary_digest(
        migrated.settings.quota_node_binary
    )
    save_registry(migrated, legacy)
    assert load_registry(legacy).settings == migrated.settings

    quota_alias = tmp_path / "quota-current"
    quota_alias.symlink_to(registry.settings.quota_binary)
    binary_line = next(
        line for line in legacy_text.splitlines() if line.startswith("quota_binary =")
    )
    legacy.write_text(
        legacy_text.replace(binary_line, f"quota_binary = {json.dumps(str(quota_alias))}"),
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match="non-symlink release file"):
        load_registry(legacy)

    node_alias = tmp_path / "node-current"
    node_alias.symlink_to(registry.settings.quota_node_binary)
    node_line = f"quota_node_binary = {json.dumps(str(node_alias))}\n"
    legacy.write_text(
        legacy_text.replace("quota_stale_seconds =", node_line + "quota_stale_seconds ="),
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match="non-symlink release file"):
        load_registry(legacy)


def test_registry_rejects_quota_symlink_and_hash_drift(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    registry, path = fleet
    release = tmp_path / "standalone-quota-release"
    release.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    release.chmod(0o755)
    current = tmp_path / "quota-current"
    current.symlink_to(release)
    text = path.read_text(encoding="utf-8")
    binary_line = next(line for line in text.splitlines() if line.startswith("quota_binary ="))
    hash_line = next(line for line in text.splitlines() if line.startswith("quota_binary_sha256 ="))
    path.write_text(
        text.replace(binary_line, f"quota_binary = {json.dumps(str(current))}").replace(
            hash_line,
            f"quota_binary_sha256 = {json.dumps(quota_binary_digest(release))}",
        ),
        encoding="utf-8",
    )
    loaded = load_registry(path)
    with pytest.raises(ValueError, match="non-symlink release file"):
        verified_quota_binary(loaded.settings)

    pinned = replace(
        registry,
        settings=replace(
            registry.settings,
            quota_binary=release,
            quota_binary_sha256=quota_binary_digest(release),
        ),
    )
    save_registry(pinned, path)
    release.write_text("#!/bin/sh\nexit 9\n", encoding="utf-8")
    release.chmod(0o755)
    loaded = load_registry(path)
    with pytest.raises(ValueError, match="changed since registry creation"):
        verified_quota_binary(loaded.settings)


def test_quota_drift_blocks_selection_but_not_inventory_or_disable(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    _, path = fleet
    registry = load_registry(path)
    registry = set_profile_enabled(registry, "claude-1", True)
    save_registry(registry, path)
    execution_marker = tmp_path / "quota-executed"
    registry.settings.quota_binary.write_text(
        f"#!/bin/sh\ntouch {execution_marker}\nexit 0\n",
        encoding="utf-8",
    )
    registry.settings.quota_binary.chmod(0o755)

    drifted = load_registry(path)
    with pytest.raises(ValueError, match="changed since registry creation"):
        select_and_acquire(
            drifted,
            task="quota-drift-selection",
            pool="claude-crew",
            provider="claude",
            workspace=Path.cwd(),
        )
    doctor = run_doctor(drifted, path)
    quota_check = next(check for check in doctor["checks"] if check["name"] == "quota-axi")
    assert quota_check["ok"] is False

    project_root = Path(__file__).parents[1]
    environment = {**os.environ, "PYTHONPATH": str(project_root / "src")}
    disabled = subprocess.run(
        [
            sys.executable,
            "-m",
            "agent_fleet",
            "--config",
            str(path),
            "--format",
            "json",
            "profile",
            "disable",
            "claude-1",
        ],
        cwd=Path.cwd(),
        env=environment,
        capture_output=True,
        text=True,
        check=True,
    )
    assert json.loads(disabled.stdout)["enabled"] is False
    inventory = subprocess.run(
        [
            sys.executable,
            "-m",
            "agent_fleet",
            "--config",
            str(path),
            "--format",
            "json",
            "profile",
            "list",
        ],
        cwd=Path.cwd(),
        env=environment,
        capture_output=True,
        text=True,
        check=True,
    )
    profiles = json.loads(inventory.stdout)["profiles"]
    assert next(item for item in profiles if item["id"] == "claude-1")["enabled"] is False
    assert not execution_marker.exists()


def test_quota_dependency_drift_is_blocked_by_full_release_tree_pin(
    fleet: tuple[object, Path],
) -> None:
    _, path = fleet
    registry = load_registry(path)
    quota_hash = registry.settings.quota_binary_sha256
    node_hash = registry.settings.quota_node_sha256
    release_root = registry.settings.quota_node_binary.parent.parent
    dependency = release_root / "node_modules" / "quota-axi" / "dist" / "src" / "quota.js"
    dependency.write_text("export const fixture = false;\n", encoding="utf-8")
    dependency.chmod(0o644)

    drifted = load_registry(path)
    assert drifted.settings.quota_binary_sha256 == quota_hash
    assert drifted.settings.quota_node_sha256 == node_hash
    with pytest.raises(ValueError, match="release tree changed"):
        verified_quota_runtime(drifted.settings)


def test_quota_node_is_absolute_path_pinned_and_path_shadow_cannot_run(
    fleet: tuple[object, Path], tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    registry, path = fleet
    shadow_marker = tmp_path / "shadow-node-ran"
    shadow = tmp_path / "shadow"
    shadow.mkdir()
    shadow_node = shadow / "node"
    shadow_node.write_text(
        f"#!/bin/sh\ntouch {shlex.quote(str(shadow_marker))}\nexit 99\n",
        encoding="utf-8",
    )
    shadow_node.chmod(0o755)
    monkeypatch.setenv("PATH", f"{shadow}:{os.environ['PATH']}")

    refreshed = refresh_quota(registry, registry.require_profile("claude-1"))
    assert refreshed["status"] == "fresh"
    assert not shadow_marker.exists()

    pinned_node = tmp_path / "pinned-node"
    pinned_node.write_text(
        f'#!/bin/sh\nexec {shlex.quote(sys.executable)} "$@"\n',
        encoding="utf-8",
    )
    pinned_node.chmod(0o755)
    updated = replace(
        registry,
        settings=replace(
            registry.settings,
            quota_node_binary=pinned_node,
            quota_node_sha256=quota_binary_digest(pinned_node),
        ),
    )
    save_registry(updated, path)
    pinned_node.write_text("#!/bin/sh\nexit 88\n", encoding="utf-8")
    pinned_node.chmod(0o755)
    drifted = load_registry(path)
    with pytest.raises(ValueError, match="Node runtime changed since registry creation"):
        select_and_acquire(
            drifted,
            task="node-drift-selection",
            pool="claude-crew",
            provider="claude",
            workspace=Path.cwd(),
        )
    node_check = next(
        check for check in run_doctor(drifted, path)["checks"] if check["name"] == "quota-axi-node"
    )
    assert node_check["ok"] is False


def test_bridge_topology_keeps_desktop_and_manual_reserves_out_of_routing(
    fleet: tuple[object, Path],
) -> None:
    configured, path = fleet
    topology = initial_registry(3, 5)
    registry = replace(configured, profiles=topology.profiles)
    registry = set_profile_safety_policy(registry, "claude-3", "desktop_shared")
    registry = set_profile_safety_policy(registry, "codex-5", "desktop_shared")
    save_registry(registry, path)
    registry = load_registry(path)

    assert set(registry.profiles) == {
        "claude-1",
        "claude-2",
        "claude-3",
        "codex-1",
        "codex-2",
        "codex-3",
        "codex-4",
        "codex-5",
    }
    assert {
        profile.id for profile in registry.profiles.values() if profile.safety_policy == "worker"
    } == {"claude-1", "claude-2", "codex-1", "codex-2", "codex-3", "codex-4"}
    for profile_id in ("claude-1", "claude-2"):
        assert registry.require_profile(profile_id).pools == ("claude-crew", "claude-manual")
    for profile_id in ("codex-1", "codex-2", "codex-3", "codex-4"):
        assert registry.require_profile(profile_id).pools == ("codex-crew", "codex-manual")
    assert all(
        "claude-captain" not in profile.pools for profile in registry.profiles.values()
    )
    for profile_id in ("claude-3", "codex-5"):
        profile = registry.require_profile(profile_id)
        assert profile.safety_policy == "desktop_shared"
        assert profile.enabled is False
        assert f"{profile.provider}-crew" not in profile.pools
        with pytest.raises(ValueError, match="cannot be enabled for routing"):
            set_profile_enabled(registry, profile_id, True)

    profiles = dict(registry.profiles)
    profiles["codex-5"] = replace(
        profiles["codex-5"],
        pools=("codex-crew",),
    )
    with pytest.raises(ValueError, match="cannot join a worker crew pool"):
        save_registry(replace(registry, profiles=profiles), path)

    with pytest.raises(ValueError, match="external reserve profile"):
        select_and_acquire(
            registry,
            task="desktop-shared-must-not-route",
            pool="codex-manual",
            profile_id="codex-5",
            explicit_profile=True,
            dry_run=True,
            workspace=Path.cwd(),
        )


def test_every_external_reserve_classification_is_terminal(
    fleet: tuple[object, Path],
) -> None:
    registry, _ = fleet
    registry = set_profile_safety_policy(registry, "claude-2", "manual_only")
    assert (
        set_profile_safety_policy(registry, "claude-2", "manual_only")
        .require_profile("claude-2")
        .safety_policy
        == "manual_only"
    )

    for replacement in ("worker", "desktop_shared"):
        with pytest.raises(ValueError, match="manual_only classification is terminal"):
            set_profile_safety_policy(registry, "claude-2", replacement)
    with pytest.raises(ValueError, match="offline reviewed registry migration"):
        without_profile(registry, "claude-2")


def test_save_registry_preserves_existing_parent_mode(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    registry, _ = fleet
    parent = tmp_path / "shared-config"
    parent.mkdir(mode=0o755)
    path = parent / "accounts.toml"

    save_registry(registry, path)

    assert stat.S_IMODE(parent.stat().st_mode) == 0o755
    assert stat.S_IMODE(path.stat().st_mode) == 0o600


def test_save_registry_creates_only_missing_leaf_parent_private(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    registry, _ = fleet
    ancestor = tmp_path / "existing-ancestor"
    ancestor.mkdir(mode=0o755)
    leaf = ancestor / "agent-fleet"

    save_registry(registry, leaf / "accounts.toml")

    assert stat.S_IMODE(ancestor.stat().st_mode) == 0o755
    assert stat.S_IMODE(leaf.stat().st_mode) == 0o700


def test_save_registry_rejects_writable_symlinked_and_nonowned_parents(
    fleet: tuple[object, Path], tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    registry, _ = fleet
    writable = tmp_path / "writable-parent"
    writable.mkdir()
    writable.chmod(0o777)
    with pytest.raises(ValueError, match="not group/world writable"):
        save_registry(registry, writable / "accounts.toml")
    assert stat.S_IMODE(writable.stat().st_mode) == 0o777

    target = tmp_path / "symlink-target"
    target.mkdir(mode=0o700)
    linked = tmp_path / "linked-parent"
    linked.symlink_to(target, target_is_directory=True)
    with pytest.raises(ValueError, match="real directory"):
        save_registry(registry, linked / "accounts.toml")
    assert linked.is_symlink()
    assert list(target.iterdir()) == []

    nonowned = tmp_path / "nonowned-parent"
    nonowned.mkdir(mode=0o700)
    real_lstat = Path.lstat

    def foreign_lstat(path: Path):
        current = real_lstat(path)
        if path != nonowned:
            return current
        values = list(current)
        values[4] = os.getuid() + 1
        return os.stat_result(values)

    monkeypatch.setattr(Path, "lstat", foreign_lstat)
    with pytest.raises(ValueError, match="current-user owned"):
        save_registry(registry, nonowned / "accounts.toml")


def test_save_registry_rejects_non_directory_parent(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    registry, _ = fleet
    parent = tmp_path / "not-a-directory"
    parent.write_text("occupied\n", encoding="utf-8")

    with pytest.raises(ValueError, match="registry parent must be a real directory"):
        save_registry(registry, parent / "accounts.toml")


def test_save_registry_rejects_parent_creation_race(
    fleet: tuple[object, Path], tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    registry, _ = fleet
    parent = tmp_path / "raced-parent"
    original_mkdir = Path.mkdir

    def raced_mkdir(path: Path, *args, **kwargs) -> None:
        if path == parent:
            path.write_text("racer\n", encoding="utf-8")
            raise FileExistsError(path)
        original_mkdir(path, *args, **kwargs)

    monkeypatch.setattr(Path, "mkdir", raced_mkdir)
    with pytest.raises(ValueError, match="registry parent changed during creation"):
        save_registry(registry, parent / "accounts.toml")
    assert parent.read_text(encoding="utf-8") == "racer\n"


def test_provision_merges_hooks_and_shares_only_declared_workflow_assets(
    fleet: tuple[object, Path],
) -> None:
    _, path = fleet
    registry = load_registry(path)
    profile = registry.require_profile("codex-1")
    auth_before = (profile.home / "auth.json").read_bytes()
    result = provision_profile(registry, profile)

    assert result["shared_entries"] == ["AGENTS.md"]
    assert profile_is_provisioned(profile)
    assert (profile.home / "AGENTS.md").is_symlink()
    assert (profile.home / "auth.json").read_bytes() == auth_before
    hooks = json.loads((profile.home / "hooks.json").read_text(encoding="utf-8"))
    commands = [
        hook["command"] for group in hooks["hooks"]["SessionStart"] for hook in group["hooks"]
    ]
    assert "base-hook" not in commands
    assert any("agent-fleet" in command for command in commands)
    config = (profile.home / "config.toml").read_text(encoding="utf-8")
    assert 'cli_auth_credentials_store = "file"' in config
    assert "hooks = true" in config
    health = profile_hook_health(registry, profile)
    assert health["agent_fleet_session_hook"] is True
    assert health["release_owned_hooks"] is True
    assert health["herdr_session_hook"] is False


def test_profile_ids_reject_account_email(fleet: tuple[object, Path]) -> None:
    _, path = fleet
    text = path.read_text(encoding="utf-8")
    text += '\n[profiles."person@example.com"]\nprovider="claude"\npools=["claude-crew"]\n'
    path.write_text(text, encoding="utf-8")
    with pytest.raises(ValueError, match="invalid profile id"):
        load_registry(path)


def test_legacy_registry_without_desktop_field_migrates_to_safe_default(
    fleet: tuple[object, Path],
) -> None:
    _, path = fleet
    lines = [
        line
        for line in path.read_text(encoding="utf-8").splitlines()
        if not line.startswith("desktop_identity_file =")
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    registry = load_registry(path)
    assert (
        registry.require_provider("claude").desktop_identity_file
        == (Path.home() / "Library/Application Support/Claude/config.json").resolve()
    )


def test_explicit_desktop_anchor_opt_out_remains_supported(
    fleet: tuple[object, Path],
) -> None:
    _, path = fleet
    text = path.read_text(encoding="utf-8")
    line = next(item for item in text.splitlines() if item.startswith("desktop_identity_file ="))
    path.write_text(text.replace(line, "desktop_identity_file = false"), encoding="utf-8")
    assert load_registry(path).require_provider("claude").desktop_identity_file is None


def test_provision_refuses_symlink_profile_home(fleet: tuple[object, Path], tmp_path: Path) -> None:
    _, path = fleet
    registry = load_registry(path)
    external = tmp_path / "external"
    external.mkdir()
    symlink_home = tmp_path / "profile-link"
    symlink_home.symlink_to(external, target_is_directory=True)
    profile = replace(registry.require_profile("codex-1"), home=symlink_home)
    with pytest.raises(ValueError, match="cannot be a symlink"):
        provision_profile(registry, profile)


def test_shared_asset_install_refuses_existing_non_symlink(
    fleet: tuple[object, Path],
) -> None:
    _, path = fleet
    registry = load_registry(path)
    profile = registry.require_profile("codex-1")
    profile.home.mkdir(parents=True, exist_ok=True)
    os.chmod(profile.home, 0o700)
    (profile.home / "AGENTS.md").unlink()
    (profile.home / "AGENTS.md").write_text("attacker-owned\n", encoding="utf-8")
    with pytest.raises(ValueError, match="refusing to replace"):
        provision_profile(registry, profile)


@pytest.mark.parametrize(
    ("provider", "entry"),
    [("claude", ".claude.json"), ("codex", "auth.json")],
)
def test_registry_rejects_non_workflow_shared_entries(
    fleet: tuple[object, Path], provider: str, entry: str
) -> None:
    _, path = fleet
    text = path.read_text(encoding="utf-8")
    marker = f"[providers.{provider}]"
    before, after = text.split(marker, 1)
    section, remainder = after.split("\n[", 1)
    lines = [
        f'shared_entries = ["{entry}"]' if line.startswith("shared_entries =") else line
        for line in section.splitlines()
    ]
    path.write_text(before + marker + "\n".join(lines) + "\n[" + remainder, encoding="utf-8")
    with pytest.raises(ValueError, match="non-workflow assets"):
        load_registry(path)
