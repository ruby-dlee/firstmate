from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
from dataclasses import replace
from pathlib import Path

import pytest

from agent_fleet.config import initial_registry, save_registry
from agent_fleet.identity import (
    adopt_provider_identity_bundle,
    refresh_provider_identity_anchors,
)
from agent_fleet.models import ProviderConfig, Registry
from agent_fleet.provision import provision_profile
from agent_fleet.quota import inspect_credential_source_contract, read_quota, refresh_quota


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
    quota_release = tmp_path / "quota-release"
    quota_entrypoint = (
        quota_release / "node_modules" / "quota-axi" / "dist" / "bin" / "quota-axi.js"
    )
    quota_entrypoint.parent.mkdir(parents=True)
    quota_entrypoint.write_text(
        """#!/usr/bin/env python3
import json
import os
import pwd
import sys
from datetime import UTC, datetime
provider = sys.argv[sys.argv.index("--provider") + 1]
profile = os.environ["AGENT_FLEET_PROFILE"]
if "auth" in sys.argv:
    if provider == "claude":
        credential = os.path.join(os.environ["CLAUDE_CONFIG_DIR"], ".credentials.json")
        sources = [
            {
                "source": "oauth-file",
                "path": credential,
                "status": "available" if os.path.exists(credential) else "missing",
            },
            {
                "source": "keychain",
                "status": "missing",
                "account": pwd.getpwuid(os.getuid()).pw_name,
            },
        ]
    else:
        credential = os.path.join(os.environ["CODEX_HOME"], "auth.json")
        sources = [
            {
                "source": "auth-json",
                "path": credential,
                "status": "available" if os.path.exists(credential) else "missing",
            },
            {
                "source": "cli-rpc",
                "path": os.environ["QUOTA_AXI_CODEX_BINARY"],
                "status": "available",
            },
        ]
    print(json.dumps({"schemaVersion": 1, "auth": [{"provider": provider, "sources": sources}]}))
    raise SystemExit
fixture_control = __FIXTURE_CONTROL__
if os.path.exists(fixture_control):
    with open(fixture_control, encoding="utf-8") as handle:
        fixture_dir = handle.read().strip()
    fixture_path = os.path.join(fixture_dir, profile + ".json")
    if os.path.exists(fixture_path):
        with open(fixture_path, encoding="utf-8") as handle:
            print(handle.read())
        raise SystemExit
print(json.dumps({
    "providers": [{
        "provider": provider,
        "account": {
            "accountId": profile + "-account",
            "email": profile + "@example.invalid",
        },
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
""".replace(
            "__FIXTURE_CONTROL__",
            repr(str(state / "test-quota-fixture-dir")),
        ),
        encoding="utf-8",
    )
    quota_entrypoint.chmod(0o444)
    quota_dependency = quota_release / "node_modules" / "quota-axi" / "dist" / "src" / "quota.js"
    quota_dependency.parent.mkdir(parents=True)
    quota_dependency.write_text("export const fixture = true;\n", encoding="utf-8")
    quota_dependency.chmod(0o644)
    quota_node = quota_release / "runtime" / "node"
    quota_node.parent.mkdir(parents=True)
    quota_node.write_text(
        f'#!/bin/sh\nexec {str(sys.executable)!r} "$@"\n',
        encoding="utf-8",
    )
    quota_node.chmod(0o755)
    quota_binary = quota_release / "bin" / "quota-axi"
    quota_binary.parent.mkdir()
    quota_binary.write_text(
        f'#!/bin/sh\nexec {str(sys.executable)!r} {str(quota_entrypoint)!r} "$@"\n',
        encoding="utf-8",
    )
    quota_binary.chmod(0o755)
    monkeypatch.setenv("AGENT_FLEET_QUOTA_BIN", str(quota_binary))
    monkeypatch.setenv("AGENT_FLEET_QUOTA_NODE_BIN", str(quota_node))
    registry = initial_registry(3, 2)
    registry = replace(
        registry,
        settings=replace(registry.settings, quota_binary=quota_binary),
    )
    providers: dict[str, ProviderConfig] = {}
    desktop_file = tmp_path / "desktop" / "claude-config.json"
    desktop_file.parent.mkdir(parents=True)
    desktop_file.parent.chmod(0o700)
    desktop_file.write_text(
        json.dumps({"lastKnownAccountUuid": "desktop-captain-account"}),
        encoding="utf-8",
    )
    desktop_file.chmod(0o600)
    for name, provider in registry.providers.items():
        base = tmp_path / "base" / name
        base.mkdir(parents=True)
        base.chmod(0o700)
        credential = base / (".credentials.json" if name == "claude" else "auth.json")
        credential.write_text(
            json.dumps(
                {"claudeAiOauth": {"accessToken": "base-test-token"}}
                if name == "claude"
                else {"tokens": {"access_token": "base-test-token"}}
            ),
            encoding="utf-8",
        )
        credential.chmod(0o600)
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
        if name == "codex":
            binary.write_text(
                f"""#!{sys.executable}
import json
import os
import sys

if "app-server" not in sys.argv:
    raise SystemExit(0)
profile = os.environ["AGENT_FLEET_PROFILE"]
fixture_control = {str(state / "test-quota-fixture-dir")!r}
for line in sys.stdin:
    message = json.loads(line)
    if message.get("method") == "initialize":
        print(json.dumps({{"id": message["id"], "result": {{}}}}), flush=True)
    elif message.get("method") == "account/read":
        email = profile + "@example.invalid"
        if os.path.exists(fixture_control):
            with open(fixture_control, encoding="utf-8") as handle:
                fixture_dir = handle.read().strip()
            fixture_path = os.path.join(fixture_dir, profile + ".json")
            if os.path.exists(fixture_path):
                with open(fixture_path, encoding="utf-8") as handle:
                    fixture_payload = json.load(handle)
                fixture_providers = fixture_payload.get("providers")
                if isinstance(fixture_providers, list) and fixture_providers:
                    account = fixture_providers[0].get("account")
                    if isinstance(account, dict):
                        fixture_email = account.get("email")
                        account_id = account.get("accountId")
                        if isinstance(fixture_email, str) and fixture_email:
                            email = fixture_email
                        elif isinstance(account_id, str) and account_id.endswith("-account"):
                            email = account_id.removesuffix("-account") + "@example.invalid"
        result = {{
            "account": {{
                "type": "chatgpt",
                "email": email,
                "planType": "test",
            }},
            "requiresOpenaiAuth": True,
        }}
        print(json.dumps({{"id": message["id"], "result": result}}), flush=True)
""",
                encoding="utf-8",
            )
        else:
            binary.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        binary.chmod(binary.stat().st_mode | stat.S_IXUSR)
        providers[name] = replace(
            provider,
            binary=binary,
            base_home=base,
            hooks_source=None,
            shared_entries=(shared,),
            desktop_identity_file=desktop_file if name == "claude" else None,
            trusted_projects=(trusted_project.resolve(),),
        )
    registry = replace(registry, providers=providers)
    save_registry(registry, config)
    for profile in registry.profiles.values():
        if profile.safety_policy != "worker":
            continue
        provision_profile(registry, profile)
        credential = profile.home / (
            ".credentials.json" if profile.provider == "claude" else "auth.json"
        )
        credential.write_text(
            json.dumps(
                {"claudeAiOauth": {"accessToken": "worker-test-token"}}
                if profile.provider == "claude"
                else {"tokens": {"access_token": "worker-test-token"}}
            ),
            encoding="utf-8",
        )
        credential.chmod(0o600)
        refresh_quota(registry, profile)
    for provider in registry.providers:
        refresh_provider_identity_anchors(registry, provider)
        proofs = {
            profile.id: (
                read_quota(registry, profile.id),
                inspect_credential_source_contract(registry, profile),
            )
            for profile in registry.profiles.values()
            if profile.provider == provider and profile.safety_policy == "worker"
        }
        adopt_provider_identity_bundle(
            registry,
            provider,
            proofs,
        )
    return registry, config
