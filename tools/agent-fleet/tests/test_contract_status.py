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
from agent_fleet.identity import adopt_provider_identity_bundle, identity_bundle_path
from agent_fleet.providers import identity_fingerprint
from agent_fleet.provision import provision_profile
from agent_fleet.quota import (
    inspect_credential_source_contract,
    quota_path,
    read_quota,
)
from agent_fleet.status import pool_status
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
        assert payload["contract_version"] == 2
        if command == "contract":
            assert "workspace" in payload["selection_fields"]


def test_runtime_version_matches_package_metadata() -> None:
    project_root = Path(__file__).parents[1]
    metadata = tomllib.loads((project_root / "pyproject.toml").read_text(encoding="utf-8"))
    assert __version__ == metadata["project"]["version"]


def test_pool_status_uses_live_proof_instead_of_stale_cache(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profiles = dict(registry.profiles)
    for profile_id in ("codex-1", "codex-2"):
        profiles[profile_id] = replace(profiles[profile_id], enabled=True)
    registry = replace(registry, profiles=profiles)
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

    provider = pool_status(
        registry,
        pool="codex-crew",
        provider="codex",
    )["providers"][0]
    assert provider["available"] is True
    assert provider["selection_mode"] == "quota"
    assert provider["degraded"] is False


def test_enroll_is_a_verified_noop_without_invoking_codex_login(
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
    credential = os.path.join(home, "auth.json")
    with open(credential, "w", encoding="utf-8") as handle:
        json.dump({"tokens": {"access_token": "fake-test-only"}}, handle)
    os.chmod(credential, 0o600)
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
    registry = load_registry(config)
    workers = [
        profile
        for profile in registry.profiles.values()
        if profile.provider == "codex" and profile.safety_policy == "worker"
    ]
    for profile in workers:
        provision_profile(registry, profile)
    adopt_provider_identity_bundle(
        registry,
        "codex",
        {
            profile.id: (
                read_quota(registry, profile.id),
                inspect_credential_source_contract(registry, profile),
            )
            for profile in workers
        },
    )

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
        check=False,
    )
    assert result.returncode == 0, result.stderr

    payload = json.loads(result.stdout)
    assert not log.exists()
    assert payload["credential_verified"] is True
    assert payload["no_op"] is True
    assert payload["provider_login_invoked"] is False
    assert payload["enabled"] is False
    assert load_registry(config).require_profile("codex-1").enabled is False


def test_enroll_missing_credentials_refuses_before_provider_or_browser(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    marker = tmp_path / "provider-login-ran"
    binary = tmp_path / "codex-provider"
    binary.write_text(
        f"#!/bin/sh\nprintf ran > {str(marker)!r}\n",
        encoding="utf-8",
    )
    binary.chmod(0o755)
    providers = dict(registry.providers)
    providers["codex"] = replace(providers["codex"], binary=binary)
    registry = replace(registry, providers=providers)
    save_registry(registry, config)
    profile = registry.require_profile("codex-1")
    provision_profile(registry, profile)
    (profile.home / "auth.json").unlink()
    project_root = Path(__file__).parents[1]
    environment = {**os.environ, "PYTHONPATH": str(project_root / "src")}

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
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 2
    assert "requires future transactional maintenance tooling" in json.loads(
        result.stdout
    )["error"]
    assert not marker.exists()


def test_enroll_existing_unpinned_identity_directs_batch_adoption(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    registry = load_registry(config)
    identity_bundle_path(registry, "codex").unlink()
    project_root = Path(__file__).parents[1]
    environment = {**os.environ, "PYTHONPATH": str(project_root / "src")}

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
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 2
    assert "profile identity adopt codex-1" in json.loads(result.stdout)["error"]


def test_enroll_help_exposes_no_interactive_or_replacement_flags(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    project_root = Path(__file__).parents[1]
    environment = {**os.environ, "PYTHONPATH": str(project_root / "src")}

    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "agent_fleet",
            "--config",
            str(config),
            "profile",
            "enroll",
            "--help",
        ],
        cwd=Path.cwd(),
        env=environment,
        text=True,
        capture_output=True,
        check=True,
    )

    assert "--browser-login" not in result.stdout
    assert "--access-token" not in result.stdout
    assert "--replace" not in result.stdout


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
    (registry.settings.state_dir / "test-quota-fixture-dir").write_text(
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


def test_enable_requires_fresh_proof_for_every_enabled_provider_worker(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    profiles = dict(registry.profiles)
    profiles["codex-2"] = replace(profiles["codex-2"], enabled=True)
    registry = replace(registry, profiles=profiles)
    save_registry(registry, config)
    provision_profile(registry, registry.require_profile("codex-1"))
    provision_profile(registry, registry.require_profile("codex-2"))
    fixtures = tmp_path / "enable-proof-fixtures"
    fixtures.mkdir()
    (fixtures / "codex-2.json").write_text(
        json.dumps(
            {
                "providers": [
                    {
                        "provider": "codex",
                        "state": {"status": "auth_required", "reason": "logged_out"},
                        "windows": [],
                    }
                ]
            }
        ),
        encoding="utf-8",
    )
    (registry.settings.state_dir / "test-quota-fixture-dir").write_text(
        str(fixtures),
        encoding="utf-8",
    )
    project_root = Path(__file__).parents[1]
    environment = {**os.environ, "PYTHONPATH": str(project_root / "src")}

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
            "enable",
            "codex-1",
        ],
        cwd=Path.cwd(),
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 2
    assert "provider enable proof set is incomplete" in json.loads(result.stdout)["error"]
    observed = load_registry(config)
    assert observed.require_profile("codex-1").enabled is False
    assert observed.require_profile("codex-2").enabled is True


def test_claude_enrollment_refuses_remote_failure_without_mutating_prior_proof(
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
    (registry.settings.state_dir / "test-quota-fixture-dir").write_text(
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
        check=False,
    )

    payload = json.loads(result.stdout)
    stored = json.loads(quota_path(registry, "claude-1").read_text(encoding="utf-8"))
    assert result.returncode == 2
    assert payload["ok"] is False
    assert "no provider/browser login was invoked" in payload["error"]
    assert stored == old_quota


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
