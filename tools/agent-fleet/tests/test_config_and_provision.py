from __future__ import annotations

import json
import os
import stat
from dataclasses import replace
from pathlib import Path

import pytest

from agent_fleet.config import load_registry
from agent_fleet.provision import (
    profile_hook_health,
    profile_is_provisioned,
    provision_profile,
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


def test_provision_merges_hooks_and_shares_only_declared_workflow_assets(
    fleet: tuple[object, Path],
) -> None:
    _, path = fleet
    registry = load_registry(path)
    profile = registry.require_profile("codex-1")
    result = provision_profile(registry, profile)

    assert result["shared_entries"] == ["AGENTS.md"]
    assert profile_is_provisioned(profile)
    assert (profile.home / "AGENTS.md").is_symlink()
    assert not (profile.home / "auth.json").exists()
    hooks = json.loads((profile.home / "hooks.json").read_text(encoding="utf-8"))
    commands = [
        hook["command"] for group in hooks["hooks"]["SessionStart"] for hook in group["hooks"]
    ]
    assert "base-hook" in commands
    assert any("agent-fleet" in command for command in commands)
    config = (profile.home / "config.toml").read_text(encoding="utf-8")
    assert 'cli_auth_credentials_store = "file"' in config
    assert "hooks = true" in config
    health = profile_hook_health(registry, profile)
    assert health["agent_fleet_session_hook"] is True
    assert health["inherited_workflow_hooks"] is True
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
    (profile.home / "AGENTS.md").write_text("attacker-owned\n", encoding="utf-8")
    with pytest.raises(ValueError, match="refusing to replace"):
        provision_profile(registry, profile)
