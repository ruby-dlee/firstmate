from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tomllib
from dataclasses import replace
from pathlib import Path

from agent_fleet import __version__
from agent_fleet.config import load_registry, save_registry
from agent_fleet.doctor import run_doctor
from agent_fleet.providers import identity_fingerprint
from agent_fleet.provision import provision_profile
from agent_fleet.quota import quota_path
from agent_fleet.util import atomic_write_json, utc_now


def _auth_ok_binary(path: Path) -> None:
    path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def test_contract_and_version_do_not_require_registry(tmp_path: Path) -> None:
    project_root = Path(__file__).parents[1]
    env = dict(os.environ)
    env["PYTHONPATH"] = str(project_root / "src")
    missing = tmp_path / "missing.toml"
    for command in ("contract", "version"):
        result = subprocess.run(
            [
                sys.executable,
                "-m",
                "agent_fleet",
                "--format",
                "json",
                "--config",
                str(missing),
                command,
            ],
            cwd=Path.cwd(),
            env=env,
            text=True,
            capture_output=True,
            check=True,
        )
        payload = json.loads(result.stdout)
        assert payload["contract_version"] == 1


def test_runtime_version_matches_package_metadata() -> None:
    project_root = Path(__file__).parents[1]
    metadata = tomllib.loads((project_root / "pyproject.toml").read_text(encoding="utf-8"))
    assert __version__ == metadata["project"]["version"]


def test_pool_status_reports_provider_level_fallback(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    binary = tmp_path / "auth-ok"
    _auth_ok_binary(binary)
    providers = dict(registry.providers)
    providers["codex"] = replace(providers["codex"], binary=binary)
    profiles = dict(registry.profiles)
    for profile_id in ("codex-1", "codex-2"):
        profiles[profile_id] = replace(profiles[profile_id], enabled=True)
    registry = replace(registry, providers=providers, profiles=profiles)
    save_registry(registry, config)
    registry = load_registry(config)
    for profile_id in ("codex-1", "codex-2"):
        provision_profile(registry, registry.require_profile(profile_id))
        now = utc_now()
        atomic_write_json(
            quota_path(registry, profile_id),
            {
                "schema": 1,
                "profile": profile_id,
                "provider": "codex",
                "status": "stale",
                "headroom_percent": 50,
                "windows": [],
                "identity_fingerprint": identity_fingerprint("codex", f"{profile_id}-account"),
                "verified_at": now,
                "refreshed_at": now,
            },
        )

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
            "pool",
            "status",
            "--pool",
            "codex-crew",
            "--provider",
            "codex",
        ],
        cwd=Path.cwd(),
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )
    provider = json.loads(result.stdout)["providers"][0]
    assert provider["available"] is True
    assert provider["selection_mode"] == "verified-fallback"
    assert provider["degraded"] is True


def test_enroll_uses_codex_device_auth_then_verifies_while_disabled(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    log = tmp_path / "provider-argv.jsonl"
    binary = tmp_path / "provider"
    binary.write_text(
        """#!/usr/bin/env python3
import json
import os
import sys
if sys.argv[1:] == ["login", "--device-auth"]:
    home = os.environ["CODEX_HOME"]
    with open(os.path.join(home, "auth.json"), "w", encoding="utf-8") as handle:
        json.dump({"tokens": "fake-test-only"}, handle)
with open(os.environ["FAKE_PROVIDER_LOG"], "a", encoding="utf-8") as handle:
    handle.write(json.dumps(sys.argv[1:]) + "\\n")
""",
        encoding="utf-8",
    )
    binary.chmod(binary.stat().st_mode | stat.S_IXUSR)
    providers = dict(registry.providers)
    providers["codex"] = replace(providers["codex"], binary=binary)
    registry = replace(registry, providers=providers)
    save_registry(registry, config)

    project_root = Path(__file__).parents[1]
    env = dict(os.environ)
    env["PYTHONPATH"] = str(project_root / "src")
    env["FAKE_PROVIDER_LOG"] = str(log)
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
            "codex-1",
        ],
        cwd=Path.cwd(),
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )

    payload = json.loads(result.stdout)
    calls = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]
    assert calls[0] == ["login", "--device-auth"]
    assert ["login", "status"] in calls
    assert payload["credential_verified"] is True
    assert payload["enabled"] is False
    assert load_registry(config).require_profile("codex-1").enabled is False


def test_verify_keeps_a_remotely_rejected_profile_disabled(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    provision_profile(registry, registry.require_profile("codex-1"))
    fixtures = tmp_path / "quota"
    fixtures.mkdir()
    (fixtures / "codex-1.json").write_text(
        json.dumps(
            {
                "providers": [
                    {
                        "provider": "codex",
                        "state": {"status": "auth_required"},
                        "windows": [],
                    }
                ]
            }
        ),
        encoding="utf-8",
    )

    project_root = Path(__file__).parents[1]
    env = dict(os.environ)
    env["PYTHONPATH"] = str(project_root / "src")
    registry.settings.quota_binary.with_name("quota-fixture-dir").write_text(
        str(fixtures), encoding="utf-8"
    )
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
            "verify",
            "codex-1",
        ],
        cwd=Path.cwd(),
        env=env,
        text=True,
        capture_output=True,
        check=True,
    )

    payload = json.loads(result.stdout)
    assert payload["ready"] is False
    assert payload["profiles"][0]["enabled"] is False
    assert load_registry(config).require_profile("codex-1").enabled is False


def test_claude_enrollment_discards_prelogin_identity_proof(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    old_quota = json.loads(quota_path(registry, "claude-1").read_text(encoding="utf-8"))
    assert old_quota.get("identity_fingerprint")
    fixtures = tmp_path / "quota"
    fixtures.mkdir()
    keychain_required = {
        "providers": [
            {
                "provider": "claude",
                "state": {"status": "auth_required", "reason": "keychain_access_required"},
                "windows": [],
            }
        ]
    }
    (fixtures / "claude-1.json").write_text(json.dumps(keychain_required), encoding="utf-8")
    base = {
        "providers": [
            {
                "provider": "claude",
                "account": {"accountId": "base-account"},
                "state": {"status": "fresh", "refreshedAt": utc_now()},
                "windows": [{"id": "five_hour", "kind": "session", "percentRemaining": 80}],
            }
        ]
    }
    (fixtures / "claude-base-anchor.json").write_text(json.dumps(base), encoding="utf-8")

    project_root = Path(__file__).parents[1]
    env = dict(os.environ)
    env["PYTHONPATH"] = str(project_root / "src")
    registry.settings.quota_binary.with_name("quota-fixture-dir").write_text(
        str(fixtures), encoding="utf-8"
    )
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
            "claude-1",
        ],
        cwd=Path.cwd(),
        env=env,
        text=True,
        capture_output=True,
        timeout=20,
        check=True,
    )

    payload = json.loads(result.stdout)
    stored = json.loads(quota_path(registry, "claude-1").read_text(encoding="utf-8"))
    assert payload["verification_pending"] is True
    assert payload["credential_verified"] is False
    assert stored.get("identity_fingerprint") is None
    assert stored["reason"] == "keychain_access_required"


def test_toon_preflight_precedes_registry_mutation(tmp_path: Path) -> None:
    project_root = Path(__file__).parents[1]
    config = tmp_path / "accounts.toml"
    env = dict(os.environ)
    env["PYTHONPATH"] = str(project_root / "src")
    env["PATH"] = str(tmp_path)
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
        ],
        cwd=tmp_path,
        env=env,
        text=True,
        capture_output=True,
        timeout=20,
        check=False,
    )
    assert result.returncode == 2
    assert "TOON output requested" in result.stderr
    assert not config.exists()


def test_doctor_splits_supervision_workspace_from_provider_project_and_reserves(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profiles = dict(registry.profiles)
    profiles["claude-1"] = replace(profiles["claude-1"], enabled=True)
    registry = replace(registry, profiles=profiles)
    save_registry(registry, config)
    registry = load_registry(config)
    provision_profile(registry, registry.require_profile("claude-1"))
    for profile in registry.profiles.values():
        if profile.id != "claude-1":
            quota_path(registry, profile.id).unlink(missing_ok=True)
    supervisor = tmp_path / "supervisor"
    (supervisor / ".claude").mkdir(parents=True)
    (supervisor / ".codex").mkdir(parents=True)
    hooks = {"hooks": {"PreToolUse": [], "Stop": []}}
    (supervisor / ".claude" / "settings.json").write_text(json.dumps(hooks), encoding="utf-8")
    (supervisor / ".codex" / "hooks.json").write_text(json.dumps(hooks), encoding="utf-8")

    result = run_doctor(
        registry,
        config,
        workspace=supervisor,
        project=Path.cwd(),
    )
    checks = {check["name"]: check for check in result["checks"]}

    assert checks["workspace:claude:supervision-hooks"]["ok"] is True
    assert checks["workspace:codex:supervision-hooks"]["ok"] is True
    assert checks["project:claude-1:provider-bootstrap"]["ok"] is True
    assert checks["profile:claude-1:remote-identity-proof"]["required"] is True
    assert checks["profile:claude-2:remote-identity-proof"]["required"] is False
    assert checks["project:claude-2:provider-bootstrap"]["required"] is False
