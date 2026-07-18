from __future__ import annotations

import json
import os
import stat
import subprocess
from dataclasses import replace
from pathlib import Path

import pytest

from agent_fleet.config import initial_registry, save_registry
from agent_fleet.identity import refresh_provider_identity_anchors
from agent_fleet.models import ProviderConfig, Registry
from agent_fleet.quota import refresh_quota


@pytest.fixture
def fleet(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> tuple[Registry, Path]:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    fake_ps = fake_bin / "ps"
    fake_ps.write_text("#!/bin/sh\necho fixture-process-start\n", encoding="utf-8")
    fake_ps.chmod(fake_ps.stat().st_mode | stat.S_IXUSR)
    monkeypatch.setenv("PATH", f"{fake_bin}:{os.environ.get('PATH', '')}")
    config = tmp_path / "config" / "accounts.toml"
    state = tmp_path / "state"
    share = tmp_path / "share"
    monkeypatch.setenv("AGENT_FLEET_CONFIG", str(config))
    monkeypatch.setenv("AGENT_FLEET_STATE_DIR", str(state))
    monkeypatch.setenv("AGENT_FLEET_SHARE_DIR", str(share))
    trusted_project = tmp_path / "trusted-project"
    trusted_project.mkdir()
    subprocess.run(
        ["git", "init", "-q", str(trusted_project)],
        check=True,
        capture_output=True,
        text=True,
    )
    monkeypatch.chdir(trusted_project)
    registry = initial_registry(3, 2)
    quota_binary = tmp_path / "quota-axi"
    quota_binary.write_text(
        """#!/usr/bin/env python3
import json
import os
import sys
from datetime import UTC, datetime
provider = sys.argv[sys.argv.index("--provider") + 1]
profile = os.environ["AGENT_FLEET_PROFILE"]
fixture_control = os.path.join(os.path.dirname(__file__), "quota-fixture-dir")
if os.path.exists(fixture_control):
    with open(fixture_control, encoding="utf-8") as handle:
        fixture_dir = handle.read().strip()
    with open(os.path.join(fixture_dir, profile + ".json"), encoding="utf-8") as handle:
        print(handle.read())
    raise SystemExit
print(json.dumps({
    "providers": [{
        "provider": provider,
        "account": {"accountId": profile + "-account"},
        "state": {
            "status": "fresh",
            "refreshedAt": datetime.now(UTC).isoformat(),
        },
        "windows": [{
            "id": "five_hour",
            "kind": "session",
            "percentRemaining": 80,
        }],
    }]
}))
""",
        encoding="utf-8",
    )
    quota_binary.chmod(quota_binary.stat().st_mode | stat.S_IXUSR)
    registry = replace(
        registry,
        settings=replace(registry.settings, quota_binary=quota_binary),
    )
    providers: dict[str, ProviderConfig] = {}
    desktop_file = tmp_path / "desktop" / "claude-config.json"
    desktop_file.parent.mkdir(parents=True)
    desktop_file.write_text(
        json.dumps({"lastKnownAccountUuid": "desktop-captain-account"}),
        encoding="utf-8",
    )
    for name, provider in registry.providers.items():
        base = tmp_path / "base" / name
        base.mkdir(parents=True)
        hooks = base / ("settings.json" if name == "claude" else "hooks.json")
        hooks.write_text(
            json.dumps(
                {
                    "hooks": {
                        "SessionStart": [
                            {
                                "matcher": "startup",
                                "hooks": [{"type": "command", "command": "base-hook"}],
                            }
                        ]
                    }
                }
            ),
            encoding="utf-8",
        )
        shared = "CLAUDE.md" if name == "claude" else "AGENTS.md"
        (base / shared).write_text("workflow rules\n", encoding="utf-8")
        binary = tmp_path / f"provider-{name}"
        binary.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        binary.chmod(binary.stat().st_mode | stat.S_IXUSR)
        providers[name] = replace(
            provider,
            binary=binary,
            base_home=base,
            hooks_source=hooks,
            shared_entries=(shared,),
            desktop_identity_file=desktop_file if name == "claude" else None,
            trusted_projects=(trusted_project.resolve(),),
        )
    registry = replace(registry, providers=providers)
    save_registry(registry, config)
    for profile in registry.profiles.values():
        refresh_quota(registry, profile)
    for provider in registry.providers:
        refresh_provider_identity_anchors(registry, provider)
    return registry, config
