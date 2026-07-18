from __future__ import annotations

import io
import json
import os
import pwd
import signal
import sys
import time
from collections.abc import Callable
from dataclasses import replace
from hashlib import sha256
from pathlib import Path
from typing import Any

import pytest

from agent_fleet import recovery
from agent_fleet import util as util_module
from agent_fleet.config import load_registry, save_registry
from agent_fleet.identity import (
    identity_bundle_path,
    install_provider_identity_bundle,
    read_identity_binding,
    refresh_provider_identity_anchors,
)
from agent_fleet.locks import provider_enrollment_lock
from agent_fleet.models import Profile, Registry
from agent_fleet.quota import quota_path
from agent_fleet.recovery import (
    RecoveryHooks,
    SecurityKeychain,
    initialize_profile_login,
    recover_pending_profile_recoveries,
    recover_profile_login,
)
from agent_fleet.sessions import session_path
from agent_fleet.util import (
    atomic_write_bytes,
    atomic_write_json,
    process_identity_state,
    process_start_token,
    read_private_json,
)


class FakeKeychain:
    def __init__(self) -> None:
        self.items: dict[tuple[str, str], bytes] = {}
        self.operations: list[tuple[str, str, str]] = []

    def exists(self, service: str, account: str) -> bool:
        self.operations.append(("exists", service, account))
        return (service, account) in self.items

    def put(self, service: str, account: str, value: bytes) -> None:
        self.items[(service, account)] = value

    def get(self, service: str, account: str) -> bytes:
        return self.items[(service, account)]

    def copy(self, source: str, destination: str, account: str) -> None:
        self.operations.append(("copy", source, account))
        self.operations.append(("copy-to", destination, account))
        try:
            value = self.items[(source, account)]
        except KeyError as exc:
            raise ValueError("fixture scoped Keychain source missing") from exc
        self.items[(destination, account)] = value

    def delete(self, service: str, account: str, *, missing_ok: bool = False) -> None:
        self.operations.append(("delete", service, account))
        if (service, account) not in self.items and not missing_ok:
            raise ValueError("fixture scoped Keychain item missing")
        self.items.pop((service, account), None)


class FileKeychain:
    """Process-shared fake used only by kill/restart tests."""

    def __init__(self, root: Path, *, crash_during_backup: bool = False) -> None:
        self.root = root
        self.root.mkdir(mode=0o700, exist_ok=True)
        self.root.chmod(0o700)
        self.crash_during_backup = crash_during_backup
        self.crash_after_delete_service: str | None = None
        self.operations: list[tuple[str, str, str]] = []

    def _path(self, service: str, account: str) -> Path:
        digest = sha256(f"{service}\0{account}".encode()).hexdigest()
        return self.root / digest

    def exists(self, service: str, account: str) -> bool:
        return self._path(service, account).exists()

    def put(self, service: str, account: str, value: bytes) -> None:
        atomic_write_bytes(self._path(service, account), value)

    def get(self, service: str, account: str) -> bytes:
        return self._path(service, account).read_bytes()

    def copy(self, source: str, destination: str, account: str) -> None:
        value = self.get(source, account)
        if self.crash_during_backup and "agent-fleet-backup" in destination:
            atomic_write_bytes(self._path(destination, account), value[:1])
            os._exit(92)
        self.put(destination, account, value)

    def delete(self, service: str, account: str, *, missing_ok: bool = False) -> None:
        path = self._path(service, account)
        if not path.exists() and not missing_ok:
            raise ValueError("fixture scoped Keychain item missing")
        path.unlink(missing_ok=True)
        if service == self.crash_after_delete_service:
            os._exit(97)


class FakeRecovery:
    def __init__(self, registry: Registry) -> None:
        self.registry = registry
        self.identity_by_profile = {
            profile.id: str(read_identity_binding(registry, profile).get("remote_fingerprint", ""))
            for profile in registry.profiles.values()
        }
        self.keychain = FakeKeychain()
        self.login_calls: list[tuple[list[str], dict[str, str], Path]] = []
        self.fail_login = False
        self.fail_stable: set[str] = set()
        self.fingerprint_override: dict[str, str] = {}
        self.stable_fingerprint_override: dict[str, str] = {}
        self.proof_exception: str | None = None
        self.claude_file_login = False
        self.proof_calls: list[str] = []

    def inspect(self, _registry: Registry, profile: Profile, _prompt: bool) -> dict[str, Any]:
        if profile.provider == "codex":
            path = profile.home / "auth.json"
            return (
                {
                    "kind": "auth-json",
                    "path": str(path),
                    "cli_rpc_path": str(_registry.require_provider("codex").binary),
                }
                if path.exists()
                else {"kind": "absent"}
            )
        path = profile.home / ".credentials.json"
        service = recovery._claude_service(profile.home)
        account = recovery._keychain_account()
        has_file = path.exists()
        has_keychain = self.keychain.exists(service, account)
        if has_file and has_keychain:
            raise ValueError("fixture ambiguous Claude source")
        if has_file:
            return {"kind": "oauth-file", "path": str(path)}
        if has_keychain:
            return {
                "kind": "keychain",
                "service": service,
                "config_home": str(profile.home),
                "account": account,
            }
        return {"kind": "absent"}

    def login(
        self,
        argv: list[str],
        environment: dict[str, str],
        cwd: Path,
        child_started,
    ) -> int:
        self.login_calls.append((list(argv), dict(environment), cwd))
        start = process_start_token(os.getpid())
        assert start is not None
        child_started(os.getpid(), start, os.getpid())
        if self.fail_login:
            return 9
        if environment.get("AGENT_FLEET_PROVIDER") == "codex":
            atomic_write_json(
                cwd / "auth.json",
                {"tokens": {"access_token": "fixture-recovered-value"}},
            )
        elif self.claude_file_login:
            atomic_write_json(
                cwd / ".credentials.json",
                {"oauth": {"access_token": "fixture-recovered-value"}},
            )
        else:
            account = recovery._keychain_account()
            self.keychain.put(
                recovery._claude_service(cwd),
                account,
                b"fixture-recovered-value",
            )
        return 0

    def prove(
        self,
        registry: Registry,
        profile: Profile,
        prompt: bool,
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        self.proof_calls.append(profile.id)
        if self.proof_exception is not None:
            raise ValueError(self.proof_exception)
        if profile.id in self.fail_stable and "credential-recovery" not in str(profile.home):
            raise ValueError("fixture remote ejection")
        binding = read_identity_binding(registry, profile)
        fingerprint = self.fingerprint_override.get(
            profile.id,
            str(binding.get("remote_fingerprint") or self.identity_by_profile[profile.id]),
        )
        if profile.id in self.stable_fingerprint_override and "credential-recovery" not in str(
            profile.home
        ):
            fingerprint = self.stable_fingerprint_override[profile.id]
        proof = {
            "schema": 1,
            "profile": profile.id,
            "provider": profile.provider,
            "status": "fresh",
            "verified_at": "2026-07-18T00:00:00+00:00",
            "refreshed_at": "2026-07-18T00:00:00+00:00",
            "headroom_percent": 80,
            "windows": [{"id": "five_hour"}],
            "identity_fingerprint": fingerprint,
        }
        return proof, self.inspect(registry, profile, prompt)

    @staticmethod
    def refresh(_registry: Registry, _provider: str, _prompt: bool) -> None:
        return None

    @staticmethod
    def install_bundle(
        registry: Registry,
        provider: str,
        payload: dict[str, Any],
        before_install: Callable[[], None] | None = None,
    ) -> dict[str, Any]:
        return install_provider_identity_bundle(
            registry,
            provider,
            payload,
            before_install=before_install,
        )

    def hooks(self) -> RecoveryHooks:
        return RecoveryHooks(
            login=self.login,
            inspect_source=self.inspect,
            prove=self.prove,
            refresh_anchors=self.refresh,
            install_bundle=self.install_bundle,
            keychain=self.keychain,
        )


def _loaded(fleet: tuple[Registry, Path]) -> tuple[Registry, Path]:
    _, config = fleet
    return load_registry(config), config


def _old_auth(registry: Registry, profile_id: str) -> bytes:
    profile = registry.require_profile(profile_id)
    name = ".credentials.json" if profile.provider == "claude" else "auth.json"
    return (profile.home / name).read_bytes()


def _initialize_kwargs(provider: str) -> dict[str, bool]:
    return {
        "browser_login": provider == "claude",
        "allow_keychain_prompt": provider == "claude",
    }


def _two_worker_initialization_topology(
    registry: Registry,
    config: Path,
    provider: str,
) -> tuple[Registry, FakeRecovery, str, str, str | None]:
    """Return a bundle-free provider with two workers and an optional reserve."""

    fake = FakeRecovery(registry)
    reserve_id: str | None = None
    if provider == "claude":
        reserve_id = "claude-3"
        profiles = dict(registry.profiles)
        reserve = profiles[reserve_id]
        profiles[reserve_id] = replace(
            reserve,
            enabled=False,
            pools=("claude-manual",),
            safety_policy="desktop_shared",
        )
        registry = replace(registry, profiles=profiles)
        save_registry(registry, config)
        registry = load_registry(config)
    identity_bundle_path(registry, provider).unlink()
    return registry, fake, f"{provider}-1", f"{provider}-2", reserve_id


def _expire_abandoned_provider_lock(registry: Registry, provider: str) -> None:
    owner_path = (
        registry.settings.state_dir
        / "locks"
        / f"provider-enrollment-{provider}.lock"
        / "owner.json"
    )
    owner = json.loads(owner_path.read_text(encoding="utf-8"))
    owner["created_unix"] = 0
    atomic_write_json(owner_path, owner)


DURABLE_RECOVERY_PHASES = [
    "intent",
    "stage-create-authorized",
    "stage-created",
    "stage-marker-ready",
    "stage-profile-ready",
    "stage-binary-ready",
    "stage-config-ready",
    "stage-cache-ready",
    "stage-ready",
    "login-running",
    "login-finished",
    "login-complete",
    "stage-proof-running",
    "stage-verified",
    "credential-backup-running",
    "credential-backup-ready",
    "credential-prepared",
    "credential-installed",
    "bundle-backup-running",
    "bundle-backup-ready",
    "bundle-install-authorized",
    "binding-installed",
    "committed",
]

PRE_LOGIN_PHASES = {
    "intent",
    "stage-create-authorized",
    "stage-created",
    "stage-marker-ready",
    "stage-profile-ready",
    "stage-binary-ready",
    "stage-config-ready",
    "stage-cache-ready",
    "stage-ready",
}


def _crash_transaction_at_phase(
    monkeypatch: pytest.MonkeyPatch,
    transaction: Callable[[], object],
    phase_to_crash: str,
) -> None:
    real_write = recovery._write_journal

    def crash_after_phase(path: Path, journal: dict[str, Any], phase: str) -> None:
        real_write(path, journal, phase)
        if phase == phase_to_crash:
            os._exit(91)

    monkeypatch.setattr(recovery, "_write_journal", crash_after_phase)
    pid = os.fork()
    if pid == 0:  # pragma: no cover - intentional crash child
        transaction()
        os._exit(0)
    _, status = os.waitpid(pid, 0)
    monkeypatch.setattr(recovery, "_write_journal", real_write)
    assert os.waitstatus_to_exitcode(status) == 91


def test_codex_recovery_is_staged_device_login_and_leaves_routing_disabled(
    fleet: tuple[Registry, Path],
) -> None:
    registry, config = _loaded(fleet)
    fake = FakeRecovery(registry)

    result = recover_profile_login(
        registry,
        "codex-1",
        config,
        hooks=fake.hooks(),
    )

    assert result["credential_recovered"] is True
    assert result["provider_ready"] is True
    assert result["enabled"] is False
    assert result["provider_side_revocation_locally_reversible"] is False
    argv, environment, stage = fake.login_calls[0]
    assert argv[-2:] == ["login", "--device-auth"]
    assert environment["CODEX_HOME"] == str(stage)
    assert environment["HOME"] == str(stage)
    assert not any("logout" in item for item in argv)
    assert (
        b"fixture-recovered-value"
        in (registry.require_profile("codex-1").home / "auth.json").read_bytes()
    )
    assert not list(
        (registry.settings.state_dir / "transactions" / "credential-recovery").glob("*.json")
    )


def test_recovery_login_and_claude_browser_modes_are_explicit(fleet: tuple[Registry, Path]) -> None:
    registry, config = _loaded(fleet)
    fake = FakeRecovery(registry)
    with pytest.raises(ValueError, match="requires the explicit --browser flag"):
        recover_profile_login(registry, "claude-1", config, hooks=fake.hooks())
    assert fake.login_calls == []

    fake.fail_login = True
    with pytest.raises(
        ValueError,
        match="provider_side_revocation_possible=true",
    ):
        recover_profile_login(registry, "codex-1", config, hooks=fake.hooks())
    assert len(fake.login_calls) == 1
    assert _old_auth(registry, "codex-1") == _old_auth(load_registry(config), "codex-1")
    assert not list(
        (registry.settings.state_dir / "transactions" / "credential-recovery").glob("*.json")
    )


def test_claude_recovery_uses_only_exact_scoped_services_and_ignores_hostile_user(
    fleet: tuple[Registry, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    registry, config = _loaded(fleet)
    monkeypatch.setenv("USER", "hostile-user")
    monkeypatch.setenv("LOGNAME", "hostile-logname")
    monkeypatch.setenv("PATH", "/hostile/path")
    monkeypatch.setenv("DYLD_INSERT_LIBRARIES", "/hostile/loader")
    monkeypatch.setenv("PYTHONPATH", "/hostile/python")
    monkeypatch.setenv("NODE_OPTIONS", "--require=/hostile/node")
    monkeypatch.setenv("BROWSER", "/hostile/browser")
    fake = FakeRecovery(registry)

    result = recover_profile_login(
        registry,
        "claude-1",
        config,
        browser_login=True,
        allow_keychain_prompt=True,
        hooks=fake.hooks(),
    )

    account = pwd.getpwuid(os.getuid()).pw_name
    target = registry.require_profile("claude-1")
    stable_service = recovery._claude_service(target.home)
    assert result["provider_ready"] is True
    assert (stable_service, account) in fake.keychain.items
    assert not (target.home / ".credentials.json").exists()
    argv, environment, stage = fake.login_calls[0]
    assert argv[-2:] == ["auth", "login"]
    assert environment["CLAUDE_CONFIG_DIR"] == str(stage)
    assert environment["USER"] == account
    assert environment["LOGNAME"] == account
    assert environment["PATH"] == recovery.CONTROL_PATH
    assert not {
        "DYLD_INSERT_LIBRARIES",
        "PYTHONPATH",
        "NODE_OPTIONS",
        "BROWSER",
    }.intersection(environment)
    assert all(operation[2] == account for operation in fake.keychain.operations)
    assert all(operation[1] != "Claude Code-credentials" for operation in fake.keychain.operations)
    assert not any("logout" in item for item in argv)


def test_claude_keychain_source_without_exact_passwd_account_fails_closed(
    fleet: tuple[Registry, Path],
) -> None:
    registry, _config = _loaded(fleet)
    target = registry.require_profile("claude-1")
    fake = FakeRecovery(registry)
    service = recovery._claude_service(target.home)
    account = recovery._keychain_account()
    fake.keychain.put(service, account, b"test-scoped-item")

    with pytest.raises(ValueError, match="exact home and account"):
        recovery._normalize_source_contract(
            fake.hooks(),
            target,
            {
                "kind": "keychain",
                "service": service,
                "config_home": str(target.home),
            },
        )


@pytest.mark.parametrize("profile_id", ["claude-3", "codex-2"])
def test_reserve_profiles_are_structurally_unreachable(
    fleet: tuple[Registry, Path], profile_id: str
) -> None:
    registry, config = _loaded(fleet)
    original = registry.require_profile(profile_id)
    profiles = dict(registry.profiles)
    profiles[profile_id] = replace(
        original,
        enabled=False,
        pools=(f"{original.provider}-manual",),
        safety_policy="desktop_shared",
    )
    registry = replace(registry, profiles=profiles)
    save_registry(registry, config)
    fake = FakeRecovery(registry)

    with pytest.raises(ValueError, match="has no recovery path"):
        recover_profile_login(
            registry,
            profile_id,
            config,
            browser_login=True,
            allow_keychain_prompt=True,
            hooks=fake.hooks(),
        )

    assert fake.login_calls == []
    assert fake.keychain.operations == []


def test_pending_recovery_filters_reserves_before_transaction_path_derivation(
    fleet: tuple[Registry, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    registry, _ = _loaded(fleet)
    profiles = dict(registry.profiles)
    reserve = profiles["codex-2"]
    profiles["codex-2"] = replace(
        reserve,
        pools=("codex-manual",),
        safety_policy="desktop_shared",
    )
    registry = replace(registry, profiles=profiles)
    derived: list[str] = []
    original = recovery._journal_path_for_worker

    def observed(registry: Registry, profile: Profile) -> Path:
        derived.append(profile.id)
        return original(registry, profile)

    monkeypatch.setattr(recovery, "_journal_path_for_worker", observed)
    assert (
        recover_pending_profile_recoveries(
            registry,
            "codex",
            hooks=FakeRecovery(registry).hooks(),
        )
        == []
    )
    assert "codex-2" not in derived


def test_recovery_refuses_enabled_worker_and_live_lease_before_login(
    fleet: tuple[Registry, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    registry, config = _loaded(fleet)
    profiles = dict(registry.profiles)
    profiles["codex-2"] = replace(profiles["codex-2"], enabled=True)
    enabled_registry = replace(registry, profiles=profiles)
    save_registry(enabled_registry, config)
    fake = FakeRecovery(enabled_registry)
    with pytest.raises(ValueError, match="disable every codex worker"):
        recover_profile_login(enabled_registry, "codex-1", config, hooks=fake.hooks())
    assert fake.login_calls == []

    save_registry(registry, config)
    monkeypatch.setattr(recovery, "active_leases", lambda _registry: [{"profile": "codex-2"}])
    with pytest.raises(ValueError, match="drain every codex worker lease"):
        recover_profile_login(registry, "codex-1", config, hooks=fake.hooks())
    assert fake.login_calls == []


def test_recovery_refuses_dormant_continuable_provider_session_without_live_lease(
    fleet: tuple[Registry, Path],
) -> None:
    registry, config = _loaded(fleet)
    fake = FakeRecovery(registry)
    task = "dormant-managed-task"
    workspace = config.parent.resolve()
    turn_end = workspace / "dormant-managed-task.turn-ended"
    atomic_write_json(
        session_path(registry, task),
        {
            "schema": 1,
            "task": task,
            "profile": "codex-2",
            "provider": "codex",
            "pool": "codex-crew",
            "workspace": str(workspace),
            "turn_end": str(turn_end),
            "session_id": "dormant-session",
            "updated_at": "2026-07-18T00:00:00+00:00",
        },
    )

    with pytest.raises(ValueError, match="continuable codex worker session mapping"):
        recover_profile_login(registry, "codex-1", config, hooks=fake.hooks())

    assert fake.login_calls == []


def test_registry_change_at_boundary_fails_closed_and_cleans_stage(
    fleet: tuple[Registry, Path],
) -> None:
    registry, config = _loaded(fleet)
    fake = FakeRecovery(registry)

    def change_registry(phase: str) -> None:
        if phase != "stage-ready":
            return
        changed = load_registry(config)
        profiles = dict(changed.profiles)
        profiles["codex-1"] = replace(profiles["codex-1"], reserve_percent=44)
        save_registry(replace(changed, profiles=profiles), config)

    with pytest.raises(ValueError, match="credential recovery failed"):
        recover_profile_login(
            registry,
            "codex-1",
            config,
            hooks=fake.hooks(),
            boundary_hook=change_registry,
        )
    assert fake.login_calls == []
    stage_root = registry.settings.state_dir / "staging" / "credential-recovery"
    assert not list(stage_root.rglob("*login*"))


def test_pinned_identity_mismatch_rolls_back_without_disclosure(
    fleet: tuple[Registry, Path],
) -> None:
    registry, config = _loaded(fleet)
    fake = FakeRecovery(registry)
    old = _old_auth(registry, "codex-1")
    fake.fingerprint_override["codex-1"] = read_identity_binding(
        registry,
        registry.require_profile("codex-2"),
    )["remote_fingerprint"]

    with pytest.raises(
        ValueError,
        match="provider_side_revocation_possible=true",
    ) as error:
        recover_profile_login(registry, "codex-1", config, hooks=fake.hooks())

    assert "fixture-recovered-value" not in str(error.value)
    assert _old_auth(registry, "codex-1") == old
    assert not list(
        (registry.settings.state_dir / "transactions" / "credential-recovery").glob("*.json")
    )


def test_missing_target_binding_fails_before_provider_login(fleet: tuple[Registry, Path]) -> None:
    registry, config = _loaded(fleet)
    identity_bundle_path(registry, "codex").unlink()
    fake = FakeRecovery(registry)
    with pytest.raises(ValueError, match="existing pinned identity"):
        recover_profile_login(registry, "codex-1", config, hooks=fake.hooks())
    assert fake.login_calls == []


@pytest.mark.parametrize(
    ("provider", "profile_id", "anchor", "reason"),
    [
        ("codex", "codex-1", "codex-base.json", "base_identity"),
        ("claude", "claude-1", "claude-desktop.json", "desktop_identity"),
    ],
)
def test_staged_login_conflicting_with_external_identity_is_rejected(
    fleet: tuple[Registry, Path],
    provider: str,
    profile_id: str,
    anchor: str,
    reason: str,
) -> None:
    registry, config = _loaded(fleet)
    anchor_payload = read_private_json(
        registry.settings.state_dir / "identity-anchors" / anchor,
        label="fixture identity anchor",
    )
    bundle_path = identity_bundle_path(registry, provider)
    bundle = read_private_json(bundle_path, label="fixture identity bundle")
    bundle["workers"][profile_id]["remote_fingerprint"] = anchor_payload["identity_fingerprint"]
    atomic_write_json(bundle_path, bundle)
    fake = FakeRecovery(registry)
    with pytest.raises(ValueError, match="credential recovery failed") as error:
        recover_profile_login(
            registry,
            profile_id,
            config,
            browser_login=provider == "claude",
            allow_keychain_prompt=provider == "claude",
            hooks=fake.hooks(),
        )
    assert len(fake.login_calls) == 1
    assert reason not in str(error.value)


def test_unrecorded_stage_entry_fails_closed_instead_of_cleanup(
    fleet: tuple[Registry, Path],
) -> None:
    registry, config = _loaded(fleet)
    fake = FakeRecovery(registry)

    def inject(phase: str) -> None:
        if phase != "stage-verified":
            return
        roots = list(
            (registry.settings.state_dir / "staging" / "credential-recovery").rglob("*.login-*")
        )
        assert len(roots) == 1
        unexpected = roots[0] / "unrecorded"
        unexpected.write_bytes(b"not-a-credential")
        unexpected.chmod(0o600)

    with pytest.raises(ValueError, match="local_rollback=incomplete_fail_closed"):
        recover_profile_login(
            registry,
            "codex-1",
            config,
            hooks=fake.hooks(),
            boundary_hook=inject,
        )
    assert list(
        (registry.settings.state_dir / "transactions" / "credential-recovery").glob("*.json")
    )


def test_target_remote_failure_rolls_back_but_peer_ejection_commits_disabled_recovery(
    fleet: tuple[Registry, Path],
) -> None:
    registry, config = _loaded(fleet)
    old = _old_auth(registry, "codex-1")
    target_failure = FakeRecovery(registry)
    target_failure.fail_stable.add("codex-1")
    with pytest.raises(ValueError, match="provider_side_revocation_possible=true"):
        recover_profile_login(registry, "codex-1", config, hooks=target_failure.hooks())
    assert _old_auth(registry, "codex-1") == old

    peer_failure = FakeRecovery(registry)
    peer_failure.fail_stable.add("codex-2")
    result = recover_profile_login(registry, "codex-1", config, hooks=peer_failure.hooks())
    assert result["credential_recovered"] is True
    assert result["provider_ready"] is False
    assert result["blocked_profiles"] == ["codex-2"]
    assert result["enabled"] is False
    assert b"fixture-recovered-value" in _old_auth(registry, "codex-1")


def test_hostile_hardlinked_credential_is_rejected_before_provider_action(
    fleet: tuple[Registry, Path],
) -> None:
    registry, config = _loaded(fleet)
    auth = registry.require_profile("codex-1").home / "auth.json"
    os.link(auth, auth.with_name("auth-hardlink-fixture"))
    fake = FakeRecovery(registry)
    with pytest.raises(ValueError, match="single-link"):
        recover_profile_login(registry, "codex-1", config, hooks=fake.hooks())
    assert fake.login_calls == []


def test_result_audit_and_journal_never_contain_fake_credential_value(
    fleet: tuple[Registry, Path],
) -> None:
    registry, config = _loaded(fleet)
    fake = FakeRecovery(registry)
    result = recover_profile_login(registry, "codex-1", config, hooks=fake.hooks())
    encoded = json.dumps(result, sort_keys=True)
    audit = (registry.settings.state_dir / "audit.jsonl").read_text(encoding="utf-8")
    assert "fixture-recovered-value" not in encoded
    assert "fixture-recovered-value" not in audit
    assert not list(
        (registry.settings.state_dir / "transactions" / "credential-recovery").glob("*.json")
    )


def test_failure_message_audit_and_journal_never_disclose_provider_text(
    fleet: tuple[Registry, Path],
) -> None:
    registry, config = _loaded(fleet)
    fake = FakeRecovery(registry)
    sentinel = "fixture-provider-output-that-must-not-escape"
    fake.proof_exception = sentinel
    with pytest.raises(ValueError) as error:
        recover_profile_login(registry, "codex-1", config, hooks=fake.hooks())
    audit = (registry.settings.state_dir / "audit.jsonl").read_text(encoding="utf-8")
    assert sentinel not in str(error.value)
    assert sentinel not in audit
    assert not list(
        (registry.settings.state_dir / "transactions" / "credential-recovery").glob("*.json")
    )


@pytest.mark.parametrize(
    ("provider", "profile_id"),
    [("codex", "codex-1"), ("claude", "claude-1")],
)
def test_initialize_refuses_existing_bundle_before_provider_login(
    fleet: tuple[Registry, Path], provider: str, profile_id: str
) -> None:
    registry, config = _loaded(fleet)
    fake = FakeRecovery(registry)

    with pytest.raises(ValueError, match="already exists; use recover-login"):
        initialize_profile_login(
            registry,
            profile_id,
            config,
            hooks=fake.hooks(),
            **_initialize_kwargs(provider),
        )

    assert fake.login_calls == []


@pytest.mark.parametrize("provider", ["codex", "claude"])
def test_initialize_durably_records_partial_batch_then_atomically_adopts_full_bundle(
    fleet: tuple[Registry, Path], provider: str
) -> None:
    registry, config = _loaded(fleet)
    registry, fake, first_id, second_id, reserve_id = _two_worker_initialization_topology(
        registry,
        config,
        provider,
    )
    reserve_before = _old_auth(registry, reserve_id) if reserve_id else None
    fake.fail_stable.add(second_id)

    partial = initialize_profile_login(
        registry,
        first_id,
        config,
        hooks=fake.hooks(),
        **_initialize_kwargs(provider),
    )

    provisional_path = recovery._provisional_path(registry, provider)
    provisional = read_private_json(
        provisional_path,
        label="test provisional identity batch",
    )
    assert partial["credential_initialized"] is True
    assert partial["credential_recovered"] is False
    assert partial["provider_ready"] is False
    assert partial["pending_initialization"] == [second_id]
    assert partial["provisional_workers"] == [first_id]
    assert set(provisional["workers"]) == {first_id}
    assert "fixture-recovered-value" not in json.dumps(provisional, sort_keys=True)
    assert not identity_bundle_path(registry, provider).exists()

    with pytest.raises(ValueError, match="already recorded"):
        initialize_profile_login(
            registry,
            first_id,
            config,
            hooks=fake.hooks(),
            **_initialize_kwargs(provider),
        )
    assert len(fake.login_calls) == 1

    fake.fail_stable.clear()
    completed = initialize_profile_login(
        registry,
        second_id,
        config,
        hooks=fake.hooks(),
        **_initialize_kwargs(provider),
    )

    assert completed["credential_initialized"] is True
    assert completed["provider_ready"] is True
    assert completed["pending_initialization"] == []
    assert not provisional_path.exists()
    assert not recovery._provisional_guard_path(registry, provider).exists()
    bundle = read_private_json(
        identity_bundle_path(registry, provider),
        label="test completed identity bundle",
    )
    assert set(bundle["workers"]) == {first_id, second_id}
    if provider == "claude":
        account = pwd.getpwuid(os.getuid()).pw_name
        assert all(
            binding["credential_source_contract"]["account"] == account
            for binding in bundle["workers"].values()
        )
    if reserve_id is not None:
        assert _old_auth(registry, reserve_id) == reserve_before
        reserve_service = recovery._claude_service(registry.require_profile(reserve_id).home)
        assert all(operation[1] != reserve_service for operation in fake.keychain.operations)


def test_initialize_rejects_wrong_promoted_identity_and_duplicate_or_external_staging(
    fleet: tuple[Registry, Path],
) -> None:
    registry, config = _loaded(fleet)
    fake = FakeRecovery(registry)
    identity_bundle_path(registry, "codex").unlink()
    old = _old_auth(registry, "codex-1")
    fake.stable_fingerprint_override["codex-1"] = sha256(b"wrong-promoted-account").hexdigest()

    with pytest.raises(ValueError, match="credential initialization failed"):
        initialize_profile_login(registry, "codex-1", config, hooks=fake.hooks())
    assert _old_auth(registry, "codex-1") == old
    assert not recovery._provisional_path(registry, "codex").exists()

    duplicate = FakeRecovery(registry)
    duplicate.fingerprint_override["codex-1"] = duplicate.identity_by_profile["codex-2"]
    with pytest.raises(ValueError, match="credential initialization failed"):
        initialize_profile_login(registry, "codex-1", config, hooks=duplicate.hooks())
    assert not recovery._provisional_path(registry, "codex").exists()

    external = FakeRecovery(registry)
    anchor = read_private_json(
        registry.settings.state_dir / "identity-anchors" / "codex-base.json",
        label="test Codex base anchor",
    )
    external.fingerprint_override["codex-1"] = anchor["identity_fingerprint"]
    with pytest.raises(ValueError, match="credential initialization failed"):
        initialize_profile_login(registry, "codex-1", config, hooks=external.hooks())
    assert not recovery._provisional_path(registry, "codex").exists()


@pytest.mark.parametrize(
    "failure",
    ["tamper", "stale", "topology", "state-root", "share-root", "config-path"],
)
def test_initialize_reproves_and_validates_provisional_batch_before_next_login(
    fleet: tuple[Registry, Path], failure: str
) -> None:
    registry, config = _loaded(fleet)
    registry, fake, first_id, second_id, _reserve = _two_worker_initialization_topology(
        registry,
        config,
        "codex",
    )
    fake.fail_stable.add(second_id)
    initialize_profile_login(registry, first_id, config, hooks=fake.hooks())
    assert len(fake.login_calls) == 1
    fake.fail_stable.clear()

    if failure == "tamper":
        provisional_path = recovery._provisional_path(registry, "codex")
        provisional = read_private_json(
            provisional_path,
            label="test provisional identity batch",
        )
        provisional["workers"][first_id]["identity_fingerprint"] = sha256(
            b"tampered-provisional-binding"
        ).hexdigest()
        atomic_write_json(provisional_path, provisional)
    elif failure == "stale":
        fake.fail_stable.add(first_id)
    elif failure == "topology":
        profiles = dict(registry.profiles)
        profiles[first_id] = replace(profiles[first_id], reserve_percent=91)
        registry = replace(registry, profiles=profiles)
        save_registry(registry, config)
        registry = load_registry(config)
    elif failure == "state-root":
        drifted_state = registry.settings.state_dir.parent / "drifted-agent-fleet-state"
        registry = replace(
            registry,
            settings=replace(registry.settings, state_dir=drifted_state),
        )
        save_registry(registry, config)
        registry = load_registry(config)
    elif failure == "share-root":
        drifted_share = registry.settings.share_dir.parent / "drifted-agent-fleet-share"
        registry = replace(
            registry,
            settings=replace(registry.settings, share_dir=drifted_share),
        )
        save_registry(registry, config)
        registry = load_registry(config)
    else:
        alternate_config = config.with_name("alternate-accounts.toml")
        save_registry(registry, alternate_config)
        config = alternate_config
        registry = load_registry(config)

    with pytest.raises(ValueError):
        initialize_profile_login(registry, second_id, config, hooks=fake.hooks())
    assert len(fake.login_calls) == 1


def test_initialize_reserve_target_never_derives_or_touches_reserve_state(
    fleet: tuple[Registry, Path],
) -> None:
    registry, config = _loaded(fleet)
    fake = FakeRecovery(registry)
    profiles = dict(registry.profiles)
    reserve = profiles["claude-3"]
    profiles[reserve.id] = replace(
        reserve,
        enabled=False,
        pools=("claude-manual",),
        safety_policy="desktop_shared",
    )
    registry = replace(registry, profiles=profiles)
    save_registry(registry, config)
    identity_bundle_path(registry, "claude").unlink()
    before = _old_auth(registry, reserve.id)

    with pytest.raises(ValueError, match="has no recovery path"):
        initialize_profile_login(
            registry,
            reserve.id,
            config,
            browser_login=True,
            allow_keychain_prompt=True,
            hooks=fake.hooks(),
        )

    assert fake.login_calls == []
    assert _old_auth(registry, reserve.id) == before
    assert fake.keychain.operations == []


def test_synthetic_external_anchor_refresh_never_reads_reserve_home(
    fleet: tuple[Registry, Path],
) -> None:
    registry, config = _loaded(fleet)
    registry, fake, first_id, second_id, reserve_id = _two_worker_initialization_topology(
        registry,
        config,
        "claude",
    )
    assert reserve_id == "claude-3"
    reserve = registry.require_profile(reserve_id)
    reserve_credential = reserve.home / ".credentials.json"
    before_payload = reserve_credential.read_bytes()
    before_stat = reserve_credential.stat()
    fake.fail_stable.add(second_id)
    refresh_calls: list[str] = []

    def refresh_synthetic_anchors(
        current: Registry,
        provider: str,
        prompt: bool,
    ) -> None:
        refresh_calls.append(provider)
        refresh_provider_identity_anchors(
            current,
            provider,
            allow_keychain_prompt=prompt,
        )

    hooks = replace(fake.hooks(), refresh_anchors=refresh_synthetic_anchors)
    reserve.home.chmod(0o000)
    try:
        result = initialize_profile_login(
            registry,
            first_id,
            config,
            browser_login=True,
            allow_keychain_prompt=True,
            hooks=hooks,
        )
    finally:
        reserve.home.chmod(0o700)

    after_stat = reserve_credential.stat()
    assert result["provider_ready"] is False
    assert refresh_calls == ["claude", "claude"]
    assert reserve_credential.read_bytes() == before_payload
    assert (
        after_stat.st_dev,
        after_stat.st_ino,
        after_stat.st_size,
        after_stat.st_mtime_ns,
        after_stat.st_ctime_ns,
    ) == (
        before_stat.st_dev,
        before_stat.st_ino,
        before_stat.st_size,
        before_stat.st_mtime_ns,
        before_stat.st_ctime_ns,
    )
    reserve_service = recovery._claude_service(reserve.home)
    assert all(operation[1] != reserve_service for operation in fake.keychain.operations)


def test_final_verification_failure_restores_credentials_without_touching_quota_cache(
    fleet: tuple[Registry, Path],
) -> None:
    registry, config = _loaded(fleet)
    fake = FakeRecovery(registry)
    before = {
        worker.id: quota_path(registry, worker.id).read_bytes()
        for worker in recovery._workers(registry, "codex")
    }

    def fail_after_final_proofs(phase: str) -> None:
        if phase == "final-verified":
            raise RuntimeError("injected post-proof failure")

    with pytest.raises(ValueError, match="credential recovery failed"):
        recover_profile_login(
            registry,
            "codex-1",
            config,
            hooks=fake.hooks(),
            boundary_hook=fail_after_final_proofs,
        )

    assert {
        worker.id: quota_path(registry, worker.id).read_bytes()
        for worker in recovery._workers(registry, "codex")
    } == before


def test_quota_cache_commit_contains_only_final_successful_worker_proofs(
    fleet: tuple[Registry, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    registry, config = _loaded(fleet)
    fake = FakeRecovery(registry)
    fake.fail_stable.add("codex-2")
    stored: list[str] = []
    real_store = recovery.store_quota

    def observed_store(registry: Registry, profile: Profile, proof: dict[str, Any]) -> None:
        stored.append(profile.id)
        real_store(registry, profile, proof)

    monkeypatch.setattr(recovery, "store_quota", observed_store)
    result = recover_profile_login(registry, "codex-1", config, hooks=fake.hooks())

    assert result["provider_ready"] is False
    assert result["blocked_profiles"] == ["codex-2"]
    assert stored == ["codex-1"]
    cached = read_private_json(
        quota_path(registry, "codex-1"),
        label="test committed quota cache",
    )
    assert cached["identity_fingerprint"] == fake.identity_by_profile["codex-1"]
    assert cached["verified_at"] == "2026-07-18T00:00:00+00:00"


def test_committed_transaction_rerun_fresh_verifies_without_provider_login(
    fleet: tuple[Registry, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    registry, config = _loaded(fleet)
    forward = FakeRecovery(registry)
    _crash_transaction_at_phase(
        monkeypatch,
        lambda: recover_profile_login(
            registry,
            "codex-1",
            config,
            hooks=forward.hooks(),
        ),
        "committed",
    )
    _expire_abandoned_provider_lock(registry, "codex")

    reloaded = load_registry(config)
    replay = FakeRecovery(reloaded)
    result = recover_profile_login(
        reloaded,
        "codex-1",
        config,
        hooks=replay.hooks(),
    )

    assert replay.login_calls == []
    assert replay.proof_calls == [worker.id for worker in recovery._workers(reloaded, "codex")]
    assert result["provider_login_invoked"] is False
    assert result["replayed_committed_transaction"] is True
    assert result["provider_ready"] is True
    assert not list(
        (reloaded.settings.state_dir / "transactions" / "credential-recovery").glob("*.json")
    )


def test_committed_replay_crash_retries_without_provider_login(
    fleet: tuple[Registry, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    registry, config = _loaded(fleet)
    _crash_transaction_at_phase(
        monkeypatch,
        lambda: recover_profile_login(
            registry,
            "codex-1",
            config,
            hooks=FakeRecovery(registry).hooks(),
        ),
        "committed",
    )
    _expire_abandoned_provider_lock(registry, "codex")
    real_consume = recovery._consume_committed_receipt

    def crash_before_receipt_consumption(*_args, **_kwargs) -> None:
        os._exit(92)

    monkeypatch.setattr(
        recovery,
        "_consume_committed_receipt",
        crash_before_receipt_consumption,
    )
    replay_registry = load_registry(config)
    pid = os.fork()
    if pid == 0:  # pragma: no cover - intentional replay crash child
        recover_profile_login(
            replay_registry,
            "codex-1",
            config,
            hooks=FakeRecovery(replay_registry).hooks(),
        )
        os._exit(0)
    _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == 92
    monkeypatch.setattr(recovery, "_consume_committed_receipt", real_consume)
    _expire_abandoned_provider_lock(replay_registry, "codex")

    final_registry = load_registry(config)
    final_replay = FakeRecovery(final_registry)
    result = recover_profile_login(
        final_registry,
        "codex-1",
        config,
        hooks=final_replay.hooks(),
    )
    assert final_replay.login_calls == []
    assert result["replayed_committed_transaction"] is True
    assert result["provider_login_invoked"] is False


@pytest.mark.parametrize("crash_phase", DURABLE_RECOVERY_PHASES)
def test_codex_sigkill_boundary_restart_is_locally_atomic(
    fleet: tuple[Registry, Path],
    monkeypatch: pytest.MonkeyPatch,
    crash_phase: str,
) -> None:
    registry, config = _loaded(fleet)
    old = _old_auth(registry, "codex-1")
    fake = FakeRecovery(registry)
    real_write = recovery._write_journal

    def crash_after_durable_phase(path: Path, journal: dict[str, Any], phase: str) -> None:
        real_write(path, journal, phase)
        if phase == crash_phase:
            os._exit(91)

    monkeypatch.setattr(recovery, "_write_journal", crash_after_durable_phase)
    pid = os.fork()
    if pid == 0:  # pragma: no cover - intentional crash child
        recover_profile_login(registry, "codex-1", config, hooks=fake.hooks())
        os._exit(0)
    _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == 91
    monkeypatch.setattr(recovery, "_write_journal", real_write)

    _expire_abandoned_provider_lock(registry, "codex")

    reloaded = load_registry(config)
    with provider_enrollment_lock(
        reloaded.settings.state_dir,
        "codex",
        reloaded.settings.lock_stale_seconds,
    ):
        recovered = recover_pending_profile_recoveries(
            reloaded,
            "codex",
            hooks=FakeRecovery(reloaded).hooks(),
        )
    assert recovered == [
        {
            "profile": "codex-1",
            "committed": crash_phase == "committed",
            "provider_side_revocation_possible": crash_phase not in PRE_LOGIN_PHASES,
        }
    ]
    current = _old_auth(reloaded, "codex-1")
    if crash_phase == "committed":
        assert b"fixture-recovered-value" in current
    else:
        assert current == old
    assert not list(
        (reloaded.settings.state_dir / "transactions" / "credential-recovery").glob("*.json")
    )


@pytest.mark.parametrize("provider", ["codex", "claude"])
@pytest.mark.parametrize(
    "construction_window",
    [
        "stage-mkdir",
        "marker-atomic-temporary",
        "profile-atomic-temporary",
        "binary-atomic-temporary",
        "cache-mkdir",
    ],
)
def test_sigkill_inside_stage_construction_is_safely_collectable(
    fleet: tuple[Registry, Path],
    monkeypatch: pytest.MonkeyPatch,
    provider: str,
    construction_window: str,
) -> None:
    registry, config = _loaded(fleet)
    profile_id = f"{provider}-1"
    old = _old_auth(registry, profile_id)
    fake = FakeRecovery(registry)
    real_mkdir = Path.mkdir
    real_ensure = recovery.ensure_private_dir
    real_replace = recovery.os.replace

    def crashing_mkdir(self: Path, *args, **kwargs) -> None:
        real_mkdir(self, *args, **kwargs)
        if (
            construction_window == "stage-mkdir"
            and ".login-" in self.name
            and "credential-recovery" in str(self.parent)
        ):
            os._exit(93)

    def crashing_ensure(path: Path) -> None:
        real_ensure(path)
        if (
            construction_window == "cache-mkdir"
            and path.name == ".cache"
            and ".login-" in path.parent.name
        ):
            os._exit(93)

    target_by_window = {
        "marker-atomic-temporary": recovery.RECOVERY_MARKER,
        "profile-atomic-temporary": ".agent-fleet-profile.json",
        "binary-atomic-temporary": recovery.PROVIDER_BINARY_MARKER_FILE,
    }

    def crashing_replace(source, destination, *args, **kwargs):
        target = target_by_window.get(construction_window)
        if target is not None and destination == target:
            os._exit(93)
        return real_replace(source, destination, *args, **kwargs)

    monkeypatch.setattr(Path, "mkdir", crashing_mkdir)
    monkeypatch.setattr(recovery, "ensure_private_dir", crashing_ensure)
    monkeypatch.setattr(recovery.os, "replace", crashing_replace)
    pid = os.fork()
    if pid == 0:  # pragma: no cover - intentional crash child
        recover_profile_login(
            registry,
            profile_id,
            config,
            hooks=fake.hooks(),
            **_initialize_kwargs(provider),
        )
        os._exit(0)
    _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == 93
    monkeypatch.setattr(Path, "mkdir", real_mkdir)
    monkeypatch.setattr(recovery, "ensure_private_dir", real_ensure)
    monkeypatch.setattr(recovery.os, "replace", real_replace)

    _expire_abandoned_provider_lock(registry, provider)
    reloaded = load_registry(config)
    with provider_enrollment_lock(
        reloaded.settings.state_dir,
        provider,
        reloaded.settings.lock_stale_seconds,
    ):
        recovered = recover_pending_profile_recoveries(
            reloaded,
            provider,
            hooks=FakeRecovery(reloaded).hooks(),
        )

    assert recovered == [
        {
            "profile": profile_id,
            "committed": False,
            "provider_side_revocation_possible": False,
        }
    ]
    assert _old_auth(reloaded, profile_id) == old
    transaction_root = reloaded.settings.state_dir / "transactions" / "credential-recovery"
    assert not list(transaction_root.glob("*.json"))
    stage_root = reloaded.settings.state_dir / "staging" / "credential-recovery" / provider
    assert not list(stage_root.iterdir())


def test_codex_sigkill_inside_config_atomic_write_is_safely_collectable(
    fleet: tuple[Registry, Path],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    registry, config = _loaded(fleet)
    old = _old_auth(registry, "codex-1")
    real_replace = recovery.os.replace

    def crashing_replace(source, destination, *args, **kwargs):
        if destination == "config.toml":
            os._exit(93)
        return real_replace(source, destination, *args, **kwargs)

    monkeypatch.setattr(recovery.os, "replace", crashing_replace)
    pid = os.fork()
    if pid == 0:  # pragma: no cover - intentional crash child
        recover_profile_login(
            registry,
            "codex-1",
            config,
            hooks=FakeRecovery(registry).hooks(),
        )
        os._exit(0)
    _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == 93
    monkeypatch.setattr(recovery.os, "replace", real_replace)
    _expire_abandoned_provider_lock(registry, "codex")

    reloaded = load_registry(config)
    with provider_enrollment_lock(
        reloaded.settings.state_dir,
        "codex",
        reloaded.settings.lock_stale_seconds,
    ):
        recover_pending_profile_recoveries(
            reloaded,
            "codex",
            hooks=FakeRecovery(reloaded).hooks(),
        )
    assert _old_auth(reloaded, "codex-1") == old


@pytest.mark.parametrize("provider", ["codex", "claude"])
@pytest.mark.parametrize(
    "rollback_crash",
    [
        "quarantine-authorized",
        "post-quarantine",
        "quarantined",
        "copy-running",
        "mid-copy",
        "prepared",
        "publish-authorized",
        "post-publish",
        "installed",
        "credential-complete",
    ],
)
def test_file_rollback_sigkill_is_restart_idempotent(
    fleet: tuple[Registry, Path],
    monkeypatch: pytest.MonkeyPatch,
    provider: str,
    rollback_crash: str,
) -> None:
    registry, config = _loaded(fleet)
    profile_id = f"{provider}-1"
    old = _old_auth(registry, profile_id)
    fake = FakeRecovery(registry)
    if provider == "claude":
        monkeypatch.setattr(recovery.sys, "platform", "linux")
        fake.claude_file_login = True
    real_forward_write = recovery._write_journal

    def crash_after_install(path: Path, journal: dict[str, Any], phase: str) -> None:
        real_forward_write(path, journal, phase)
        if phase == "credential-installed":
            os._exit(91)

    monkeypatch.setattr(recovery, "_write_journal", crash_after_install)
    pid = os.fork()
    if pid == 0:  # pragma: no cover - intentional crash child
        recover_profile_login(
            registry,
            profile_id,
            config,
            hooks=fake.hooks(),
            **_initialize_kwargs(provider),
        )
        os._exit(0)
    _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == 91
    monkeypatch.setattr(recovery, "_write_journal", real_forward_write)
    _expire_abandoned_provider_lock(registry, provider)

    journal_path = next(
        (registry.settings.state_dir / "transactions" / "credential-recovery").glob("*.json")
    )
    journal = json.loads(journal_path.read_text(encoding="utf-8"))
    rollback = Path(journal["paths"]["rollback_temp"])
    quarantine = Path(journal["paths"]["credential_quarantine"])
    original_quarantine = Path(journal["paths"]["credential_original_quarantine"])
    backup_copy_cases = {
        "copy-running",
        "mid-copy",
        "prepared",
        "publish-authorized",
        "post-publish",
    }
    if rollback_crash in backup_copy_cases:
        original_quarantine.unlink()
    stable_name = "auth.json" if provider == "codex" else ".credentials.json"
    stable = registry.require_profile(profile_id).home / stable_name
    real_recovery_write = recovery._write_recovery_journal
    real_copy = recovery._copy_private_file
    real_rename_noreplace = recovery._rename_noreplace
    phase_by_crash = {
        "quarantine-authorized": "credential-forward-rollback-quarantine-authorized",
        "quarantined": "credential-forward-rollback-quarantined",
        "copy-running": "rollback-file-copy-running",
        "prepared": "rollback-file-prepared",
        "publish-authorized": "rollback-file-publish-authorized",
        "installed": "rollback-file-installed",
        "credential-complete": "rollback-credential-complete",
    }

    def crash_recovery_phase(
        path: Path,
        payload: dict[str, Any],
        phase: str,
    ) -> None:
        real_recovery_write(path, payload, phase)
        if phase_by_crash.get(rollback_crash) == phase:
            os._exit(94)

    def crash_mid_copy(
        source: Path,
        destination: Path,
        *,
        destination_created: Callable[[os.stat_result], None] | None = None,
        expected_source_generation: object | None = None,
    ):
        if rollback_crash == "mid-copy" and destination == rollback:
            descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            os.fchmod(descriptor, 0o600)
            if destination_created is not None:
                destination_created(os.fstat(descriptor))
            os.write(descriptor, b"partial")
            os.fsync(descriptor)
            os.close(descriptor)
            os._exit(94)
        return real_copy(
            source,
            destination,
            destination_created=destination_created,
            expected_source_generation=expected_source_generation,
        )

    def crash_after_atomic_move(source: Path, destination: Path) -> None:
        real_rename_noreplace(source, destination)
        if rollback_crash == "post-quarantine" and source == stable and destination == quarantine:
            os._exit(94)
        if rollback_crash == "post-publish" and source == rollback and destination == stable:
            os._exit(94)

    monkeypatch.setattr(recovery, "_write_recovery_journal", crash_recovery_phase)
    monkeypatch.setattr(recovery, "_copy_private_file", crash_mid_copy)
    monkeypatch.setattr(recovery, "_rename_noreplace", crash_after_atomic_move)
    reloaded = load_registry(config)
    pid = os.fork()
    if pid == 0:  # pragma: no cover - intentional recovery crash child
        with provider_enrollment_lock(
            reloaded.settings.state_dir,
            provider,
            reloaded.settings.lock_stale_seconds,
        ):
            recover_pending_profile_recoveries(
                reloaded,
                provider,
                hooks=FakeRecovery(reloaded).hooks(),
            )
        os._exit(0)
    _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == 94
    monkeypatch.setattr(recovery, "_write_recovery_journal", real_recovery_write)
    monkeypatch.setattr(recovery, "_copy_private_file", real_copy)
    monkeypatch.setattr(recovery, "_rename_noreplace", real_rename_noreplace)
    _expire_abandoned_provider_lock(reloaded, provider)

    converged = load_registry(config)
    with provider_enrollment_lock(
        converged.settings.state_dir,
        provider,
        converged.settings.lock_stale_seconds,
    ):
        recovered = recover_pending_profile_recoveries(
            converged,
            provider,
            hooks=FakeRecovery(converged).hooks(),
        )
    assert recovered[0]["committed"] is False
    assert _old_auth(converged, profile_id) == old
    assert not rollback.exists()
    assert not quarantine.exists()
    assert not list(
        (converged.settings.state_dir / "transactions" / "credential-recovery").glob("*.json")
    )


@pytest.mark.parametrize(
    "restore_component",
    ["bundle", "provisional", "provisional_guard"],
)
@pytest.mark.parametrize("restore_crash", ["mid-copy", "post-replace"])
def test_metadata_restore_sigkill_is_restart_idempotent(
    fleet: tuple[Registry, Path],
    monkeypatch: pytest.MonkeyPatch,
    restore_component: str,
    restore_crash: str,
) -> None:
    registry, config = _loaded(fleet)
    provider = "codex"
    if restore_component == "bundle":
        target_id = "codex-1"
        old_credential = _old_auth(registry, target_id)
        bundle = identity_bundle_path(registry, provider)
        old_bundle = bundle.read_bytes()
        old_provisional = None
        old_guard = None
        fake = FakeRecovery(registry)

        def transaction() -> None:
            recover_profile_login(
                registry,
                target_id,
                config,
                hooks=fake.hooks(),
            )
    else:
        registry, fake, first_id, target_id, _reserve = _two_worker_initialization_topology(
            registry,
            config,
            provider,
        )
        fake.fail_stable.add(target_id)
        initialize_profile_login(registry, first_id, config, hooks=fake.hooks())
        fake.fail_stable.clear()
        old_credential = _old_auth(registry, target_id)
        bundle = identity_bundle_path(registry, provider)
        provisional = recovery._provisional_path(registry, provider)
        guard = recovery._provisional_guard_path(registry, provider)
        old_bundle = None
        old_provisional = provisional.read_bytes()
        old_guard = guard.read_bytes()

        def transaction() -> None:
            initialize_profile_login(
                registry,
                target_id,
                config,
                hooks=fake.hooks(),
            )

    real_forward_write = recovery._write_journal

    def crash_after_binding(path: Path, journal: dict[str, Any], phase: str) -> None:
        real_forward_write(path, journal, phase)
        if phase == "binding-installed":
            os._exit(91)

    monkeypatch.setattr(recovery, "_write_journal", crash_after_binding)
    pid = os.fork()
    if pid == 0:  # pragma: no cover - intentional crash child
        transaction()
        os._exit(0)
    _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == 91
    monkeypatch.setattr(recovery, "_write_journal", real_forward_write)
    _expire_abandoned_provider_lock(registry, provider)

    journal_path = next(
        (registry.settings.state_dir / "transactions" / "credential-recovery").glob("*.json")
    )
    journal = json.loads(journal_path.read_text(encoding="utf-8"))
    temp_key = {
        "bundle": "bundle_restore_temp",
        "provisional": "provisional_restore_temp",
        "provisional_guard": "provisional_guard_restore_temp",
    }[restore_component]
    restore_temp = Path(journal["paths"][temp_key])
    original_quarantine_key = {
        "bundle": "bundle_original_quarantine",
        "provisional": "provisional_original_quarantine",
        "provisional_guard": "provisional_guard_original_quarantine",
    }[restore_component]
    Path(journal["paths"][original_quarantine_key]).unlink()
    restore_target = {
        "bundle": bundle,
        "provisional": recovery._provisional_path(registry, provider),
        "provisional_guard": recovery._provisional_guard_path(registry, provider),
    }[restore_component]
    real_copy = recovery._copy_private_file
    real_rename_noreplace = recovery._rename_noreplace

    def crash_restore_copy(
        source: Path,
        destination: Path,
        *,
        destination_created: Callable[[os.stat_result], None] | None = None,
        expected_source_generation: object | None = None,
    ):
        if restore_crash == "mid-copy" and destination == restore_temp:
            descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            os.fchmod(descriptor, 0o600)
            if destination_created is not None:
                destination_created(os.fstat(descriptor))
            os.write(descriptor, b"partial")
            os.fsync(descriptor)
            os.close(descriptor)
            os._exit(95)
        return real_copy(
            source,
            destination,
            destination_created=destination_created,
            expected_source_generation=expected_source_generation,
        )

    def crash_restore_replace(source: Path, destination: Path) -> None:
        real_rename_noreplace(source, destination)
        if (
            restore_crash == "post-replace"
            and source == restore_temp
            and destination == restore_target
        ):
            os._exit(95)

    monkeypatch.setattr(recovery, "_copy_private_file", crash_restore_copy)
    monkeypatch.setattr(recovery, "_rename_noreplace", crash_restore_replace)
    reloaded = load_registry(config)
    pid = os.fork()
    if pid == 0:  # pragma: no cover - intentional recovery crash child
        with provider_enrollment_lock(
            reloaded.settings.state_dir,
            provider,
            reloaded.settings.lock_stale_seconds,
        ):
            recover_pending_profile_recoveries(
                reloaded,
                provider,
                hooks=FakeRecovery(reloaded).hooks(),
            )
        os._exit(0)
    _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == 95
    monkeypatch.setattr(recovery, "_copy_private_file", real_copy)
    monkeypatch.setattr(recovery, "_rename_noreplace", real_rename_noreplace)
    _expire_abandoned_provider_lock(reloaded, provider)

    converged = load_registry(config)
    with provider_enrollment_lock(
        converged.settings.state_dir,
        provider,
        converged.settings.lock_stale_seconds,
    ):
        recover_pending_profile_recoveries(
            converged,
            provider,
            hooks=FakeRecovery(converged).hooks(),
        )
    assert _old_auth(converged, target_id) == old_credential
    assert not restore_temp.exists()
    if restore_component == "bundle":
        assert bundle.read_bytes() == old_bundle
    else:
        assert not bundle.exists()
        assert recovery._provisional_path(converged, provider).read_bytes() == old_provisional
        assert recovery._provisional_guard_path(converged, provider).read_bytes() == old_guard


@pytest.mark.parametrize(
    ("component", "snapshot_existed"),
    [
        ("bundle", True),
        ("bundle", False),
        ("provisional", True),
        ("provisional", False),
        ("provisional_guard", True),
        ("provisional_guard", False),
    ],
)
def test_metadata_rollback_rejects_unknown_generation_without_overwrite(
    fleet: tuple[Registry, Path],
    monkeypatch: pytest.MonkeyPatch,
    component: str,
    snapshot_existed: bool,
) -> None:
    registry, config = _loaded(fleet)
    provider = "codex"
    if component == "bundle" and snapshot_existed:
        target_id = "codex-1"
        fake = FakeRecovery(registry)

        def transaction() -> object:
            return recover_profile_login(
                registry,
                target_id,
                config,
                hooks=fake.hooks(),
            )

        crash_phase = "binding-installed"
        target = identity_bundle_path(registry, provider)
    else:
        registry, fake, first_id, second_id, _reserve = _two_worker_initialization_topology(
            registry,
            config,
            provider,
        )
        fake.fail_stable.add(second_id)
        if snapshot_existed or component == "bundle":
            initialize_profile_login(registry, first_id, config, hooks=fake.hooks())
            fake.fail_stable.clear()
            target_id = second_id
        else:
            target_id = first_id

        def transaction() -> object:
            return initialize_profile_login(
                registry,
                target_id,
                config,
                hooks=fake.hooks(),
            )

        crash_phase = "binding-installed" if component == "bundle" else "provisional-installed"
        target = {
            "bundle": identity_bundle_path(registry, provider),
            "provisional": recovery._provisional_path(registry, provider),
            "provisional_guard": recovery._provisional_guard_path(registry, provider),
        }[component]

    _crash_transaction_at_phase(monkeypatch, transaction, crash_phase)
    journal_path = next(
        (registry.settings.state_dir / "transactions" / "credential-recovery").glob("*.json")
    )
    journal = read_private_json(journal_path, label="test credential recovery journal")
    assert journal[f"{component}_existed"] is snapshot_existed
    if component == "bundle":
        unknown = read_private_json(target, label="test transaction-installed bundle")
        unknown["external"] = {"provider": provider, "outside_transaction": True}
    else:
        unknown = {
            "schema": 1,
            "owner": "outside-transaction",
            "component": component,
        }
    atomic_write_json(target, unknown)
    unknown_bytes = target.read_bytes()
    _expire_abandoned_provider_lock(registry, provider)

    reloaded = load_registry(config)
    with (
        provider_enrollment_lock(
            reloaded.settings.state_dir,
            provider,
            reloaded.settings.lock_stale_seconds,
        ),
        pytest.raises(ValueError, match="unknown generation"),
    ):
        recover_pending_profile_recoveries(
            reloaded,
            provider,
            hooks=FakeRecovery(reloaded).hooks(),
        )

    assert target.read_bytes() == unknown_bytes
    assert journal_path.exists()


@pytest.mark.parametrize("snapshot_existed", [True, False])
def test_metadata_rollback_immediate_cas_rejects_pre_replace_race(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    snapshot_existed: bool,
) -> None:
    root = tmp_path / "metadata-cas"
    root.mkdir(mode=0o700)
    target = root / "target.json"
    backup = root / "backup.json"
    temporary = root / "restore.json"
    temporary_cleanup = root / "restore-cleanup.json"
    quarantine = root / "forward-quarantine.json"
    original_quarantine = root / "original-quarantine.json"
    journal_path = root / "journal.json"
    original = {"schema": 1, "generation": "original"}
    forward = {"schema": 1, "generation": "forward"}
    unknown = {"schema": 1, "generation": "outside-transaction"}
    if snapshot_existed:
        atomic_write_json(target, original)
        original_generation = recovery._file_generation(target, "test original metadata")
        atomic_write_json(backup, original)
    else:
        original_generation = None
    atomic_write_json(target, forward)
    journal: dict[str, Any] = {
        "bundle_original_generation": original_generation,
        "bundle_forward_generation": recovery._file_generation(
            target,
            "test forward metadata",
        ),
    }
    atomic_write_json(journal_path, journal)
    real_write = recovery._write_recovery_journal
    expected_phase = "bundle-forward-rollback-quarantine-authorized"

    def inject_unknown_generation(
        path: Path,
        payload: dict[str, Any],
        phase: str,
    ) -> None:
        real_write(path, payload, phase)
        if phase == expected_phase:
            atomic_write_json(target, unknown)

    monkeypatch.setattr(
        recovery,
        "_write_recovery_journal",
        inject_unknown_generation,
    )
    with pytest.raises(ValueError, match="changed (?:before|during) its quarantine move"):
        recovery._restore_snapshot_file(
            target=target,
            backup=backup,
            temporary=temporary,
            temporary_cleanup=temporary_cleanup,
            quarantine=quarantine,
            original_quarantine=original_quarantine,
            existed=snapshot_existed,
            key="bundle",
            label="test provider identity bundle",
            journal_path=journal_path,
            journal=journal,
        )

    assert read_private_json(target, label="test raced metadata") == unknown


def test_bundle_install_cas_runs_inside_atomic_writer_and_preserves_race(
    fleet: tuple[Registry, Path],
) -> None:
    registry, config = _loaded(fleet)
    fake = FakeRecovery(registry)
    hooks = fake.hooks()
    bundle = identity_bundle_path(registry, "codex")
    unknown = {"schema": 1, "owner": "outside-transaction"}
    rejected: list[str] = []

    def racing_install(
        current: Registry,
        provider: str,
        payload: dict[str, Any],
        before_install: Callable[[], None] | None,
    ) -> dict[str, Any]:
        atomic_write_json(bundle, unknown)
        try:
            return hooks.install_bundle(
                current,
                provider,
                payload,
                before_install,
            )
        except ValueError as exc:
            rejected.append(str(exc))
            raise

    with pytest.raises(ValueError, match="local_rollback=incomplete_fail_closed"):
        recover_profile_login(
            registry,
            "codex-1",
            config,
            hooks=replace(hooks, install_bundle=racing_install),
        )

    assert rejected == ["provider identity bundle changed before transaction installation"]
    assert read_private_json(bundle, label="test raced identity bundle") == unknown


@pytest.mark.parametrize(
    "cleanup_crash",
    [
        "stage-quarantine-authorized",
        "post-quarantine-rename",
        "stage-quarantined",
        "stage-quarantine-remove-authorized",
        "mid-rmtree",
        "stage-removed",
        "transaction-cleanup-complete",
    ],
)
def test_stage_quarantine_cleanup_sigkill_converges_without_orphan(
    fleet: tuple[Registry, Path],
    monkeypatch: pytest.MonkeyPatch,
    cleanup_crash: str,
) -> None:
    registry, config = _loaded(fleet)
    real_recovery_write = recovery._write_recovery_journal
    real_rename_noreplace = recovery._rename_noreplace
    real_rmtree = recovery.shutil.rmtree

    def crash_cleanup_phase(
        path: Path,
        journal: dict[str, Any],
        phase: str,
    ) -> None:
        real_recovery_write(path, journal, phase)
        if cleanup_crash == phase:
            os._exit(96)

    def crash_post_quarantine_rename(source: Path, destination: Path) -> None:
        real_rename_noreplace(source, destination)
        if (
            cleanup_crash == "post-quarantine-rename"
            and isinstance(source, Path)
            and ".login-" in source.name
            and isinstance(destination, Path)
            and ".cleanup-" in destination.name
        ):
            os._exit(96)

    def crash_mid_rmtree(path: Path, *args, **kwargs) -> None:
        if cleanup_crash == "mid-rmtree" and ".cleanup-" in path.name:
            victim = next(item for item in path.rglob("*") if item.is_file())
            victim.unlink()
            os._exit(96)
        real_rmtree(path, *args, **kwargs)

    monkeypatch.setattr(recovery, "_write_recovery_journal", crash_cleanup_phase)
    monkeypatch.setattr(recovery, "_rename_noreplace", crash_post_quarantine_rename)
    monkeypatch.setattr(recovery.shutil, "rmtree", crash_mid_rmtree)
    pid = os.fork()
    if pid == 0:  # pragma: no cover - intentional cleanup crash child
        recover_profile_login(
            registry,
            "codex-1",
            config,
            hooks=FakeRecovery(registry).hooks(),
        )
        os._exit(0)
    _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == 96
    monkeypatch.setattr(recovery, "_write_recovery_journal", real_recovery_write)
    monkeypatch.setattr(recovery, "_rename_noreplace", real_rename_noreplace)
    monkeypatch.setattr(recovery.shutil, "rmtree", real_rmtree)
    _expire_abandoned_provider_lock(registry, "codex")

    journal_path = next(
        (registry.settings.state_dir / "transactions" / "credential-recovery").glob("*.json")
    )
    journal = json.loads(journal_path.read_text(encoding="utf-8"))
    stage = Path(journal["paths"]["stage"])
    quarantine = Path(journal["paths"]["quarantine"])
    reloaded = load_registry(config)
    with provider_enrollment_lock(
        reloaded.settings.state_dir,
        "codex",
        reloaded.settings.lock_stale_seconds,
    ):
        recovered = recover_pending_profile_recoveries(
            reloaded,
            "codex",
            hooks=FakeRecovery(reloaded).hooks(),
        )

    assert recovered[0]["committed"] is True
    assert b"fixture-recovered-value" in _old_auth(reloaded, "codex-1")
    assert not stage.exists()
    assert not quarantine.exists()
    assert not journal_path.exists()


@pytest.mark.parametrize("deleted_generation", ["staged_service", "backup_service"])
def test_keychain_cleanup_delete_sigkill_retains_durable_rollback_state(
    fleet: tuple[Registry, Path],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    deleted_generation: str,
) -> None:
    registry, config = _loaded(fleet)
    keychain = FileKeychain(tmp_path / "fake-keychain")
    credential, stable_service, account, old = _prepare_claude_origin(
        registry,
        keychain,
        "keychain",
    )
    fake = FakeRecovery(registry)
    fake.keychain = keychain  # type: ignore[assignment]
    real_write = recovery._write_journal

    def crash_after_install(path: Path, journal: dict[str, Any], phase: str) -> None:
        real_write(path, journal, phase)
        if phase == "credential-installed":
            os._exit(91)

    monkeypatch.setattr(recovery, "_write_journal", crash_after_install)
    pid = os.fork()
    if pid == 0:  # pragma: no cover - intentional forward crash child
        recover_profile_login(
            registry,
            "claude-1",
            config,
            browser_login=True,
            allow_keychain_prompt=True,
            hooks=fake.hooks(),
        )
        os._exit(0)
    _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == 91
    monkeypatch.setattr(recovery, "_write_journal", real_write)
    _expire_abandoned_provider_lock(registry, "claude")

    journal_path = next(
        (registry.settings.state_dir / "transactions" / "credential-recovery").glob("*.json")
    )
    journal = json.loads(journal_path.read_text(encoding="utf-8"))
    service = str(journal[deleted_generation])
    backup_service = str(journal["backup_service"])
    keychain.crash_after_delete_service = service
    reloaded = load_registry(config)
    crash_controls = FakeRecovery(reloaded)
    crash_controls.keychain = keychain  # type: ignore[assignment]
    pid = os.fork()
    if pid == 0:  # pragma: no cover - intentional recovery crash child
        with provider_enrollment_lock(
            reloaded.settings.state_dir,
            "claude",
            reloaded.settings.lock_stale_seconds,
        ):
            recover_pending_profile_recoveries(
                reloaded,
                "claude",
                hooks=crash_controls.hooks(),
            )
        os._exit(0)
    _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == 97
    keychain.crash_after_delete_service = None

    interrupted = json.loads(journal_path.read_text(encoding="utf-8"))
    assert interrupted["local_credential_rollback_complete"] is True
    assert keychain.get(stable_service, account) == old
    if deleted_generation == "staged_service":
        assert keychain.exists(backup_service, account)
    else:
        assert not keychain.exists(backup_service, account)

    recovered = _recover_crashed_claude(reloaded, config, keychain)
    assert recovered[0]["committed"] is False
    assert keychain.get(stable_service, account) == old
    assert not credential.exists()
    assert len(list(keychain.root.iterdir())) == 1
    assert not journal_path.exists()


def test_recovery_refuses_live_keychain_helper_then_converges_after_it_exits(
    fleet: tuple[Registry, Path],
    tmp_path: Path,
) -> None:
    registry, config = _loaded(fleet)
    target = registry.require_profile("claude-1")
    credential = target.home / ".credentials.json"
    old = credential.read_bytes()
    credential.unlink()
    account = recovery._keychain_account()
    stable_service = recovery._claude_service(target.home)
    started = tmp_path / "keychain-helper-started"
    release = tmp_path / "keychain-helper-release"

    class BlockingSecurityKeychain(SecurityKeychain):
        def __init__(self, root: Path) -> None:
            self.root = root
            self.root.mkdir(mode=0o700)

        def _path(self, service: str, account_name: str) -> Path:
            digest = sha256(f"{service}\0{account_name}".encode()).hexdigest()
            return self.root / digest

        def exists(self, service: str, account_name: str) -> bool:
            return self._path(service, account_name).exists()

        def put(self, service: str, account_name: str, value: bytes) -> None:
            atomic_write_bytes(self._path(service, account_name), value)

        def get(self, service: str, account_name: str) -> bytes:
            return self._path(service, account_name).read_bytes()

        def copy(self, source: str, destination: str, account_name: str) -> None:
            value = self.get(source, account_name)
            if destination == stable_service and not release.exists():
                atomic_write_bytes(started, b"started")
                while not release.exists():
                    time.sleep(0.01)
            self.put(destination, account_name, value)

        def delete(
            self,
            service: str,
            account_name: str,
            *,
            missing_ok: bool = False,
        ) -> None:
            path = self._path(service, account_name)
            if not path.exists() and not missing_ok:
                raise ValueError("fixture scoped Keychain item missing")
            path.unlink(missing_ok=True)

    keychain = BlockingSecurityKeychain(tmp_path / "blocking-keychain")
    keychain.put(stable_service, account, old)
    fake = FakeRecovery(registry)
    fake.keychain = keychain  # type: ignore[assignment]
    pid = os.fork()
    if pid == 0:  # pragma: no cover - intentional transaction owner child
        recover_profile_login(
            registry,
            "claude-1",
            config,
            browser_login=True,
            allow_keychain_prompt=True,
            hooks=fake.hooks(),
        )
        os._exit(0)

    deadline = time.monotonic() + 10
    while not started.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    assert started.exists()
    os.kill(pid, signal.SIGKILL)
    _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == -signal.SIGKILL
    assert keychain.get(stable_service, account) == old
    _expire_abandoned_provider_lock(registry, "claude")

    journal_path = next(
        (registry.settings.state_dir / "transactions" / "credential-recovery").glob("*.json")
    )
    journal = json.loads(journal_path.read_text(encoding="utf-8"))
    operation = journal["keychain_operation"]
    helper_pid = int(operation["pid"])
    helper_start = str(operation["start"])
    reloaded = load_registry(config)
    blocked_controls = FakeRecovery(reloaded)
    blocked_controls.keychain = keychain  # type: ignore[assignment]
    with (
        provider_enrollment_lock(
            reloaded.settings.state_dir,
            "claude",
            reloaded.settings.lock_stale_seconds,
        ),
        pytest.raises(ValueError, match="Keychain operation is still live"),
    ):
        recover_pending_profile_recoveries(
            reloaded,
            "claude",
            hooks=blocked_controls.hooks(),
        )
    assert keychain.get(stable_service, account) == old

    atomic_write_bytes(release, b"release")
    deadline = time.monotonic() + 10
    while (
        process_identity_state(helper_pid, helper_start) != "dead" and time.monotonic() < deadline
    ):
        time.sleep(0.01)
    assert process_identity_state(helper_pid, helper_start) == "dead"

    converged = load_registry(config)
    recovery_controls = FakeRecovery(converged)
    recovery_controls.keychain = keychain  # type: ignore[assignment]
    with provider_enrollment_lock(
        converged.settings.state_dir,
        "claude",
        converged.settings.lock_stale_seconds,
    ):
        recovered = recover_pending_profile_recoveries(
            converged,
            "claude",
            hooks=recovery_controls.hooks(),
        )
    assert recovered[0]["committed"] is False
    assert keychain.get(stable_service, account) == old
    assert not credential.exists()
    assert len(list(keychain.root.iterdir())) == 1
    assert not journal_path.exists()


def test_provider_login_detached_group_fences_live_descendant_until_exit(
    tmp_path: Path,
) -> None:
    script = tmp_path / "provider-login-tree.py"
    ownership = tmp_path / "provider-login-ownership.json"
    descendant_started = tmp_path / "provider-login-descendant"
    release = tmp_path / "provider-login-release"
    script.write_text(
        "\n".join(
            [
                "import os",
                "import pathlib",
                "import sys",
                "import time",
                "started = pathlib.Path(sys.argv[1])",
                "release = pathlib.Path(sys.argv[2])",
                "child = os.fork()",
                "if child == 0:",
                "    started.write_text(str(os.getpid()), encoding='utf-8')",
                "    while not release.exists():",
                "        time.sleep(0.01)",
                "    os._exit(0)",
                "while not release.exists():",
                "    time.sleep(0.01)",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    owner = os.fork()
    if owner == 0:  # pragma: no cover - production-shaped login owner

        def record_child(pid: int, start: str, pgid: int) -> None:
            atomic_write_json(
                ownership,
                {"login_pid": pid, "login_start": start, "login_pgid": pgid},
            )

        try:
            recovery._system_login(
                [
                    sys.executable,
                    str(script),
                    str(descendant_started),
                    str(release),
                ],
                dict(os.environ),
                tmp_path,
                record_child,
            )
        except ValueError:
            os._exit(93)
        os._exit(0)

    deadline = time.monotonic() + 10
    while (
        not ownership.exists() or not descendant_started.exists()
    ) and time.monotonic() < deadline:
        time.sleep(0.01)
    assert ownership.exists()
    assert descendant_started.exists()
    journal = read_private_json(ownership, label="test provider login ownership")
    leader = int(journal["login_pid"])
    pgid = int(journal["login_pgid"])
    assert pgid == leader
    journal_path = tmp_path / "provider-login-recovery.json"
    atomic_write_json(journal_path, journal)

    with pytest.raises(ValueError, match="process group is still live"):
        recovery._ensure_login_operation_quiescent(journal_path, journal)
    os.kill(leader, signal.SIGKILL)
    _, status = os.waitpid(owner, 0)
    assert os.waitstatus_to_exitcode(status) == 93
    with pytest.raises(ValueError, match="process group is still live"):
        recovery._ensure_login_operation_quiescent(journal_path, journal)

    atomic_write_bytes(release, b"release")
    deadline = time.monotonic() + 10
    while recovery._process_group_state(pgid) != "dead" and time.monotonic() < deadline:
        time.sleep(0.01)
    if recovery._process_group_state(pgid) != "dead":
        os.killpg(pgid, signal.SIGKILL)
    assert recovery._process_group_state(pgid) == "dead"
    recovery._ensure_login_operation_quiescent(journal_path, journal)
    assert "login_pid" not in journal
    assert "login_start" not in journal
    assert "login_pgid" not in journal


def test_uncommitted_recovery_restart_after_stage_removal_needs_no_deleted_backup(
    fleet: tuple[Registry, Path],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    registry, config = _loaded(fleet)
    old_credential = _old_auth(registry, "codex-1")
    bundle = identity_bundle_path(registry, "codex")
    old_bundle = bundle.read_bytes()
    real_forward_write = recovery._write_journal

    def crash_after_binding(path: Path, journal: dict[str, Any], phase: str) -> None:
        real_forward_write(path, journal, phase)
        if phase == "binding-installed":
            os._exit(91)

    monkeypatch.setattr(recovery, "_write_journal", crash_after_binding)
    pid = os.fork()
    if pid == 0:  # pragma: no cover - intentional forward crash child
        recover_profile_login(
            registry,
            "codex-1",
            config,
            hooks=FakeRecovery(registry).hooks(),
        )
        os._exit(0)
    _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == 91
    monkeypatch.setattr(recovery, "_write_journal", real_forward_write)
    _expire_abandoned_provider_lock(registry, "codex")

    real_recovery_write = recovery._write_recovery_journal

    def crash_after_stage_removed(
        path: Path,
        journal: dict[str, Any],
        phase: str,
    ) -> None:
        real_recovery_write(path, journal, phase)
        if phase == "stage-removed":
            os._exit(98)

    monkeypatch.setattr(recovery, "_write_recovery_journal", crash_after_stage_removed)
    reloaded = load_registry(config)
    pid = os.fork()
    if pid == 0:  # pragma: no cover - intentional recovery crash child
        with provider_enrollment_lock(
            reloaded.settings.state_dir,
            "codex",
            reloaded.settings.lock_stale_seconds,
        ):
            recover_pending_profile_recoveries(
                reloaded,
                "codex",
                hooks=FakeRecovery(reloaded).hooks(),
            )
        os._exit(0)
    _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == 98
    monkeypatch.setattr(recovery, "_write_recovery_journal", real_recovery_write)
    _expire_abandoned_provider_lock(reloaded, "codex")

    journal_path = next(
        (registry.settings.state_dir / "transactions" / "credential-recovery").glob("*.json")
    )
    interrupted = json.loads(journal_path.read_text(encoding="utf-8"))
    assert interrupted["local_credential_rollback_complete"] is True
    assert interrupted["bundle_restore_complete"] is True
    assert interrupted["stage_cleanup_complete"] is True
    assert not Path(interrupted["paths"]["stage"]).exists()

    converged = load_registry(config)
    with provider_enrollment_lock(
        converged.settings.state_dir,
        "codex",
        converged.settings.lock_stale_seconds,
    ):
        recover_pending_profile_recoveries(
            converged,
            "codex",
            hooks=FakeRecovery(converged).hooks(),
        )
    assert _old_auth(converged, "codex-1") == old_credential
    assert bundle.read_bytes() == old_bundle
    assert not journal_path.exists()


def test_initialize_partial_commit_survives_restart_as_provisional_not_bundle(
    fleet: tuple[Registry, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    registry, config = _loaded(fleet)
    registry, fake, first_id, second_id, _reserve = _two_worker_initialization_topology(
        registry,
        config,
        "codex",
    )
    fake.fail_stable.add(second_id)
    real_write = recovery._write_journal

    def crash_after_partial_commit(path: Path, journal: dict[str, Any], phase: str) -> None:
        real_write(path, journal, phase)
        if phase == "committed":
            os._exit(91)

    monkeypatch.setattr(recovery, "_write_journal", crash_after_partial_commit)
    pid = os.fork()
    if pid == 0:  # pragma: no cover - intentional crash child
        initialize_profile_login(registry, first_id, config, hooks=fake.hooks())
        os._exit(0)
    _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == 91
    monkeypatch.setattr(recovery, "_write_journal", real_write)
    _expire_abandoned_provider_lock(registry, "codex")

    reloaded = load_registry(config)
    with provider_enrollment_lock(
        reloaded.settings.state_dir,
        "codex",
        reloaded.settings.lock_stale_seconds,
    ):
        recovered = recover_pending_profile_recoveries(
            reloaded,
            "codex",
            hooks=FakeRecovery(reloaded).hooks(),
        )

    assert recovered == [
        {
            "profile": first_id,
            "committed": True,
            "provider_side_revocation_possible": True,
        }
    ]
    provisional = read_private_json(
        recovery._provisional_path(reloaded, "codex"),
        label="test recovered provisional identity batch",
    )
    assert set(provisional["workers"]) == {first_id}
    guard = read_private_json(
        recovery._provisional_guard_path(reloaded, "codex"),
        label="test recovered initialization locator",
    )
    assert guard["generation"] == provisional["generation"]
    assert guard["contract_sha256"] == provisional["contract_sha256"]
    assert not identity_bundle_path(reloaded, "codex").exists()
    assert b"fixture-recovered-value" in _old_auth(reloaded, first_id)


def test_initialize_crash_between_bundle_adoption_and_provisional_removal_rolls_back(
    fleet: tuple[Registry, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    registry, config = _loaded(fleet)
    registry, fake, first_id, second_id, _reserve = _two_worker_initialization_topology(
        registry,
        config,
        "codex",
    )
    second_before = _old_auth(registry, second_id)
    fake.fail_stable.add(second_id)
    initialize_profile_login(registry, first_id, config, hooks=fake.hooks())
    first_after = _old_auth(registry, first_id)
    fake.fail_stable.clear()
    real_write = recovery._write_journal

    def crash_after_bundle_adopt(path: Path, journal: dict[str, Any], phase: str) -> None:
        real_write(path, journal, phase)
        if phase == "binding-installed":
            os._exit(91)

    monkeypatch.setattr(recovery, "_write_journal", crash_after_bundle_adopt)
    pid = os.fork()
    if pid == 0:  # pragma: no cover - intentional crash child
        initialize_profile_login(registry, second_id, config, hooks=fake.hooks())
        os._exit(0)
    _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == 91
    monkeypatch.setattr(recovery, "_write_journal", real_write)
    assert identity_bundle_path(registry, "codex").exists()
    _expire_abandoned_provider_lock(registry, "codex")

    reloaded = load_registry(config)
    with provider_enrollment_lock(
        reloaded.settings.state_dir,
        "codex",
        reloaded.settings.lock_stale_seconds,
    ):
        recovered = recover_pending_profile_recoveries(
            reloaded,
            "codex",
            hooks=FakeRecovery(reloaded).hooks(),
        )

    assert recovered[0]["profile"] == second_id
    assert recovered[0]["committed"] is False
    assert not identity_bundle_path(reloaded, "codex").exists()
    provisional = read_private_json(
        recovery._provisional_path(reloaded, "codex"),
        label="test rolled-back provisional identity batch",
    )
    assert set(provisional["workers"]) == {first_id}
    guard = read_private_json(
        recovery._provisional_guard_path(reloaded, "codex"),
        label="test rolled-back initialization locator",
    )
    assert guard["generation"] == provisional["generation"]
    assert _old_auth(reloaded, first_id) == first_after
    assert _old_auth(reloaded, second_id) == second_before


@pytest.mark.parametrize("written_component", ["provisional", "provisional_guard"])
def test_initialize_crash_after_planned_metadata_write_rolls_back(
    fleet: tuple[Registry, Path],
    monkeypatch: pytest.MonkeyPatch,
    written_component: str,
) -> None:
    registry, config = _loaded(fleet)
    registry, fake, first_id, second_id, _reserve = _two_worker_initialization_topology(
        registry,
        config,
        "codex",
    )
    fake.fail_stable.add(second_id)
    initialize_profile_login(registry, first_id, config, hooks=fake.hooks())
    fake.fail_stable.clear()
    provisional = recovery._provisional_path(registry, "codex")
    guard = recovery._provisional_guard_path(registry, "codex")
    original_provisional = provisional.read_bytes()
    original_guard = guard.read_bytes()
    second_before = _old_auth(registry, second_id)
    crash_target = provisional if written_component == "provisional" else guard
    real_rename_noreplace = recovery._rename_noreplace

    def crash_after_metadata_publish(source: Path, destination: Path) -> None:
        real_rename_noreplace(source, destination)
        if destination == crash_target and ".install-" in source.name:
            os._exit(94)

    monkeypatch.setattr(recovery, "_rename_noreplace", crash_after_metadata_publish)
    pid = os.fork()
    if pid == 0:  # pragma: no cover - intentional planned-generation crash
        initialize_profile_login(registry, second_id, config, hooks=fake.hooks())
        os._exit(0)
    _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == 94
    monkeypatch.setattr(recovery, "_rename_noreplace", real_rename_noreplace)
    _expire_abandoned_provider_lock(registry, "codex")

    reloaded = load_registry(config)
    with provider_enrollment_lock(
        reloaded.settings.state_dir,
        "codex",
        reloaded.settings.lock_stale_seconds,
    ):
        recover_pending_profile_recoveries(
            reloaded,
            "codex",
            hooks=FakeRecovery(reloaded).hooks(),
        )
    assert not identity_bundle_path(reloaded, "codex").exists()
    assert provisional.read_bytes() == original_provisional
    assert guard.read_bytes() == original_guard
    assert _old_auth(reloaded, second_id) == second_before


def test_initialize_crash_after_planned_bundle_write_rolls_back(
    fleet: tuple[Registry, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    registry, config = _loaded(fleet)
    registry, fake, first_id, second_id, _reserve = _two_worker_initialization_topology(
        registry,
        config,
        "codex",
    )
    fake.fail_stable.add(second_id)
    initialize_profile_login(registry, first_id, config, hooks=fake.hooks())
    fake.fail_stable.clear()
    provisional = recovery._provisional_path(registry, "codex")
    guard = recovery._provisional_guard_path(registry, "codex")
    original_provisional = provisional.read_bytes()
    original_guard = guard.read_bytes()
    second_before = _old_auth(registry, second_id)
    real_rename_noreplace = recovery._rename_noreplace
    bundle_path = identity_bundle_path(registry, "codex")

    def crash_after_bundle_write(source: Path, destination: Path) -> None:
        real_rename_noreplace(source, destination)
        if destination == bundle_path and ".install-" in source.name:
            os._exit(95)

    monkeypatch.setattr(recovery, "_rename_noreplace", crash_after_bundle_write)
    pid = os.fork()
    if pid == 0:  # pragma: no cover - intentional planned-generation crash
        initialize_profile_login(registry, second_id, config, hooks=fake.hooks())
        os._exit(0)
    _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == 95
    monkeypatch.setattr(recovery, "_rename_noreplace", real_rename_noreplace)
    _expire_abandoned_provider_lock(registry, "codex")

    reloaded = load_registry(config)
    with provider_enrollment_lock(
        reloaded.settings.state_dir,
        "codex",
        reloaded.settings.lock_stale_seconds,
    ):
        recover_pending_profile_recoveries(
            reloaded,
            "codex",
            hooks=FakeRecovery(reloaded).hooks(),
        )
    assert not identity_bundle_path(reloaded, "codex").exists()
    assert provisional.read_bytes() == original_provisional
    assert guard.read_bytes() == original_guard
    assert _old_auth(reloaded, second_id) == second_before


def test_initialize_crash_between_provisional_deletes_rolls_back(
    fleet: tuple[Registry, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    registry, config = _loaded(fleet)
    registry, fake, first_id, second_id, _reserve = _two_worker_initialization_topology(
        registry,
        config,
        "codex",
    )
    fake.fail_stable.add(second_id)
    initialize_profile_login(registry, first_id, config, hooks=fake.hooks())
    fake.fail_stable.clear()
    provisional = recovery._provisional_path(registry, "codex")
    guard = recovery._provisional_guard_path(registry, "codex")
    original_provisional = provisional.read_bytes()
    original_guard = guard.read_bytes()
    second_before = _old_auth(registry, second_id)
    real_rename_noreplace = recovery._rename_noreplace

    def crash_after_provisional_quarantine(source: Path, destination: Path) -> None:
        real_rename_noreplace(source, destination)
        if source == provisional and ".forward-" in destination.name:
            os._exit(96)

    monkeypatch.setattr(recovery, "_rename_noreplace", crash_after_provisional_quarantine)
    pid = os.fork()
    if pid == 0:  # pragma: no cover - intentional metadata-removal crash
        initialize_profile_login(registry, second_id, config, hooks=fake.hooks())
        os._exit(0)
    _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == 96
    monkeypatch.setattr(recovery, "_rename_noreplace", real_rename_noreplace)
    _expire_abandoned_provider_lock(registry, "codex")

    reloaded = load_registry(config)
    with provider_enrollment_lock(
        reloaded.settings.state_dir,
        "codex",
        reloaded.settings.lock_stale_seconds,
    ):
        recover_pending_profile_recoveries(
            reloaded,
            "codex",
            hooks=FakeRecovery(reloaded).hooks(),
        )
    assert not identity_bundle_path(reloaded, "codex").exists()
    assert provisional.read_bytes() == original_provisional
    assert guard.read_bytes() == original_guard
    assert _old_auth(reloaded, second_id) == second_before


def test_non_macos_claude_file_install_refuses_pre_replace_generation_race(
    fleet: tuple[Registry, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    registry, config = _loaded(fleet)
    target = registry.require_profile("claude-1")
    stable = target.home / ".credentials.json"
    unknown = {"claudeAiOauth": {"accessToken": "outside-transaction"}}
    fake = FakeRecovery(registry)
    fake.claude_file_login = True
    monkeypatch.setattr(recovery.sys, "platform", "linux")
    real_write = recovery._write_journal

    def race_after_prepare(path: Path, journal: dict[str, Any], phase: str) -> None:
        real_write(path, journal, phase)
        if phase == "credential-prepared":
            atomic_write_json(stable, unknown)

    monkeypatch.setattr(recovery, "_write_journal", race_after_prepare)
    with pytest.raises(ValueError, match="local_rollback=incomplete_fail_closed"):
        recover_profile_login(
            registry,
            "claude-1",
            config,
            browser_login=True,
            hooks=fake.hooks(),
        )

    assert read_private_json(stable, label="test raced Claude credential") == unknown
    assert list(
        (registry.settings.state_dir / "transactions" / "credential-recovery").glob("*.json")
    )


@pytest.mark.parametrize(
    (
        "profile_id",
        "original_state",
        "authorized_phase",
        "allow_absent_forward",
        "race_target",
    ),
    [
        (
            "codex-1",
            "present",
            "credential-forward-rollback-quarantine-authorized",
            False,
            "stable",
        ),
        (
            "codex-1",
            "absent",
            "credential-forward-rollback-quarantine-authorized",
            False,
            "stable",
        ),
        (
            "claude-1",
            "present",
            "credential-forward-rollback-quarantine-authorized",
            False,
            "stable",
        ),
        (
            "claude-1",
            "absent",
            "credential-forward-rollback-quarantine-authorized",
            False,
            "stable",
        ),
        ("claude-1", "removed", "rollback-file-publish-authorized", True, "stable"),
        ("codex-1", "present", "rollback-file-publish-authorized", False, "rollback"),
    ],
)
def test_file_credential_rollback_preserves_pre_mutation_race(
    fleet: tuple[Registry, Path],
    monkeypatch: pytest.MonkeyPatch,
    profile_id: str,
    original_state: str,
    authorized_phase: str,
    allow_absent_forward: bool,
    race_target: str,
) -> None:
    registry, _config = _loaded(fleet)
    target = registry.require_profile(profile_id)
    stable_name = ".credentials.json" if target.provider == "claude" else "auth.json"
    stable = target.home / stable_name
    backup = target.home / f".{stable_name}.race-backup"
    rollback = target.home / f".{stable_name}.race-rollback"
    rollback_cleanup = target.home / f".{stable_name}.race-rollback-cleanup"
    quarantine = target.home / f".{stable_name}.race-quarantine"
    original_quarantine = target.home / f".{stable_name}.race-original"
    journal_path = target.home / f".{stable_name}.race-journal"
    original = b'{"credential":"original-generation"}\n'
    forward = b'{"credential":"transaction-forward-generation"}\n'
    foreign = b'{"credential":"foreign-racing-generation"}\n'
    journal: dict[str, Any] = {}

    if original_state in {"present", "removed"}:
        atomic_write_bytes(stable, original)
        journal["original_credential_stat"] = recovery._stat_payload(
            recovery._private_file(stable, "test original credential")
        )
        atomic_write_bytes(backup, original)
    else:
        journal["original_credential_stat"] = None

    if original_state == "removed":
        stable.unlink()
    else:
        atomic_write_bytes(stable, forward)
        journal["installed_credential_stat"] = recovery._stat_payload(
            recovery._private_file(stable, "test transaction credential")
        )
    atomic_write_json(journal_path, journal)

    real_write = recovery._write_recovery_journal

    def inject_foreign_generation(
        path: Path,
        payload: dict[str, Any],
        phase: str,
    ) -> None:
        real_write(path, payload, phase)
        if phase == authorized_phase:
            atomic_write_bytes(rollback if race_target == "rollback" else stable, foreign)

    monkeypatch.setattr(recovery, "_write_recovery_journal", inject_foreign_generation)
    with pytest.raises(ValueError, match="credential"):
        recovery._rollback_file_credential(
            target,
            stable_name,
            backup,
            {
                "rollback_temp": rollback,
                "rollback_temp_cleanup": rollback_cleanup,
                "credential_quarantine": quarantine,
                "credential_original_quarantine": original_quarantine,
            },
            journal_path,
            journal,
            allow_absent_forward=allow_absent_forward,
        )

    if race_target == "rollback":
        assert not stable.exists()
        assert rollback.read_bytes() == foreign
        assert quarantine.read_bytes() == forward
    elif original_state == "removed":
        assert stable.read_bytes() == foreign
        assert rollback.read_bytes() == original
        assert not quarantine.exists()
    else:
        assert stable.read_bytes() == foreign
        assert not quarantine.exists()
    assert journal_path.exists()


def test_file_credential_rollback_preserves_stable_reappearance_after_quarantine(
    fleet: tuple[Registry, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    registry, _config = _loaded(fleet)
    target = registry.require_profile("codex-1")
    stable = target.home / "auth.json"
    backup = target.home / ".auth.json.reappearance-backup"
    rollback = target.home / ".auth.json.reappearance-rollback"
    rollback_cleanup = target.home / ".auth.json.reappearance-rollback-cleanup"
    quarantine = target.home / ".auth.json.reappearance-quarantine"
    original_quarantine = target.home / ".auth.json.reappearance-original"
    journal_path = target.home / ".auth.json.reappearance-journal"
    original = b'{"credential":"original-generation"}\n'
    forward = b'{"credential":"transaction-forward-generation"}\n'
    foreign = b'{"credential":"foreign-racing-generation"}\n'

    atomic_write_bytes(stable, original)
    journal: dict[str, Any] = {
        "original_credential_stat": recovery._stat_payload(
            recovery._private_file(stable, "test original credential")
        )
    }
    atomic_write_bytes(backup, original)
    atomic_write_bytes(stable, forward)
    journal["installed_credential_stat"] = recovery._stat_payload(
        recovery._private_file(stable, "test transaction credential")
    )
    atomic_write_json(journal_path, journal)

    real_rename_noreplace = recovery._rename_noreplace

    def reappear_after_quarantine(source: Path, destination: Path) -> None:
        real_rename_noreplace(source, destination)
        if source == stable and destination == quarantine:
            atomic_write_bytes(stable, foreign)

    monkeypatch.setattr(recovery, "_rename_noreplace", reappear_after_quarantine)
    with pytest.raises(ValueError, match="reappeared after its quarantine move"):
        recovery._rollback_file_credential(
            target,
            "auth.json",
            backup,
            {
                "rollback_temp": rollback,
                "rollback_temp_cleanup": rollback_cleanup,
                "credential_quarantine": quarantine,
                "credential_original_quarantine": original_quarantine,
            },
            journal_path,
            journal,
        )

    assert stable.read_bytes() == foreign
    assert quarantine.read_bytes() == forward
    assert not rollback.exists()
    assert journal_path.exists()

    with pytest.raises(ValueError, match="prior generation is quarantined"):
        recovery._rollback_file_credential(
            target,
            "auth.json",
            backup,
            {
                "rollback_temp": rollback,
                "rollback_temp_cleanup": rollback_cleanup,
                "credential_quarantine": quarantine,
                "credential_original_quarantine": original_quarantine,
            },
            journal_path,
            journal,
        )
    assert stable.read_bytes() == foreign
    assert quarantine.read_bytes() == forward


def test_file_credential_rollback_preserves_ambiguous_unverified_publish(
    fleet: tuple[Registry, Path],
) -> None:
    registry, _config = _loaded(fleet)
    target = registry.require_profile("codex-1")
    stable = target.home / "auth.json"
    backup = target.home / ".auth.json.ambiguous-backup"
    rollback = target.home / ".auth.json.ambiguous-rollback"
    rollback_cleanup = target.home / ".auth.json.ambiguous-rollback-cleanup"
    quarantine = target.home / ".auth.json.ambiguous-quarantine"
    original_quarantine = target.home / ".auth.json.ambiguous-original"
    journal_path = target.home / ".auth.json.ambiguous-journal"
    original = b'{"credential":"original-generation"}\n'
    forward = b'{"credential":"transaction-forward-generation"}\n'
    foreign = b'{"credential":"foreign-prepared-generation"}\n'

    atomic_write_bytes(stable, original)
    journal: dict[str, Any] = {
        "original_credential_generation": recovery._file_generation(
            stable,
            "test original credential",
        )
    }
    atomic_write_bytes(backup, original)
    atomic_write_bytes(stable, forward)
    journal["installed_credential_generation"] = recovery._file_generation(
        stable,
        "test transaction credential",
    )
    journal["credential-forward-rollback_observed_generation"] = journal[
        "installed_credential_generation"
    ]
    recovery._rename_noreplace(stable, quarantine)
    journal["credential-forward-rollback_quarantine_generation"] = recovery._file_generation(
        quarantine,
        "test quarantined credential",
    )
    atomic_write_bytes(rollback, original)
    journal["rollback-file_prepared_generation"] = recovery._file_generation(
        rollback,
        "test prepared credential",
    )
    journal["recovery_phase"] = "rollback-file-publish-authorized"
    atomic_write_json(journal_path, journal)

    atomic_write_bytes(rollback, foreign)
    recovery._rename_noreplace(rollback, stable)

    with pytest.raises(ValueError, match="prior generation is quarantined"):
        recovery._rollback_file_credential(
            target,
            "auth.json",
            backup,
            {
                "rollback_temp": rollback,
                "rollback_temp_cleanup": rollback_cleanup,
                "credential_quarantine": quarantine,
                "credential_original_quarantine": original_quarantine,
            },
            journal_path,
            journal,
        )

    assert stable.read_bytes() == foreign
    assert quarantine.read_bytes() == forward
    assert not rollback.exists()
    assert journal_path.exists()


def test_file_credential_rollback_binds_copy_fd_before_path_attribution(
    fleet: tuple[Registry, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    registry, _config = _loaded(fleet)
    target = registry.require_profile("codex-1")
    stable = target.home / "auth.json"
    backup = target.home / ".auth.json.copy-attribution-backup"
    rollback = target.home / ".auth.json.copy-attribution-rollback"
    rollback_cleanup = target.home / ".auth.json.copy-attribution-rollback-cleanup"
    quarantine = target.home / ".auth.json.copy-attribution-quarantine"
    original_quarantine = target.home / ".auth.json.copy-attribution-original"
    journal_path = target.home / ".auth.json.copy-attribution-journal"
    original = b'{"credential":"original-generation"}\n'
    forward = b'{"credential":"transaction-forward-generation"}\n'
    foreign = b'{"credential":"foreign-copy-close-generation"}\n'

    atomic_write_bytes(stable, original)
    journal: dict[str, Any] = {
        "original_credential_stat": recovery._stat_payload(
            recovery._private_file(stable, "test original credential")
        )
    }
    atomic_write_bytes(backup, original)
    atomic_write_bytes(stable, forward)
    journal["installed_credential_stat"] = recovery._stat_payload(
        recovery._private_file(stable, "test transaction credential")
    )
    atomic_write_json(journal_path, journal)

    real_copy = recovery._copy_private_file

    def replace_after_copy_close(
        source: Path,
        destination: Path,
        *,
        destination_created: Callable[[os.stat_result], None] | None = None,
        expected_source_generation: object | None = None,
    ) -> os.stat_result:
        copied = real_copy(
            source,
            destination,
            destination_created=destination_created,
            expected_source_generation=expected_source_generation,
        )
        if destination == rollback:
            atomic_write_bytes(rollback, foreign)
        return copied

    monkeypatch.setattr(recovery, "_copy_private_file", replace_after_copy_close)
    with pytest.raises(ValueError, match="changed before final attribution"):
        recovery._rollback_file_credential(
            target,
            "auth.json",
            backup,
            {
                "rollback_temp": rollback,
                "rollback_temp_cleanup": rollback_cleanup,
                "credential_quarantine": quarantine,
                "credential_original_quarantine": original_quarantine,
            },
            journal_path,
            journal,
        )

    assert not stable.exists()
    assert rollback.read_bytes() == foreign
    assert quarantine.read_bytes() == forward
    restarted = json.loads(journal_path.read_text(encoding="utf-8"))
    with pytest.raises(ValueError, match="changed before attributed cleanup"):
        recovery._rollback_file_credential(
            target,
            "auth.json",
            backup,
            {
                "rollback_temp": rollback,
                "rollback_temp_cleanup": rollback_cleanup,
                "credential_quarantine": quarantine,
                "credential_original_quarantine": original_quarantine,
            },
            journal_path,
            restarted,
        )
    assert rollback.read_bytes() == foreign
    assert quarantine.read_bytes() == forward
    assert journal_path.exists()


def test_quarantine_cleanup_rejects_replacement_after_generation_precheck(
    fleet: tuple[Registry, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    registry, _config = _loaded(fleet)
    target = registry.require_profile("codex-1")
    quarantine = target.home / ".auth.json.cleanup-race-quarantine"
    cleanup = target.home / ".auth.json.cleanup-race-tombstone"
    journal_path = target.home / ".auth.json.cleanup-race-journal"
    expected = b'{"credential":"transaction-forward-generation"}\n'
    foreign = b'{"credential":"foreign-cleanup-generation"}\n'
    atomic_write_bytes(quarantine, expected)
    expected_generation = recovery._file_generation(
        quarantine,
        "test cleanup credential",
    )
    journal: dict[str, Any] = {}
    atomic_write_json(journal_path, journal)
    real_rename = recovery._rename_noreplace

    def replace_before_attributed_move(source: Path, destination: Path) -> None:
        if source == quarantine and destination == cleanup:
            atomic_write_bytes(source, foreign)
        real_rename(source, destination)

    monkeypatch.setattr(recovery, "_rename_noreplace", replace_before_attributed_move)
    with pytest.raises(ValueError, match="changed during attributed cleanup move"):
        recovery._cleanup_owned_generation(
            quarantine,
            cleanup,
            expected_generation,
            key="test-cleanup",
            label="test cleanup credential",
            journal_path=journal_path,
            journal=journal,
        )

    assert quarantine.read_bytes() == foreign
    assert not cleanup.exists()


def test_cleanup_sigkill_after_real_rename_is_restart_discoverable(
    fleet: tuple[Registry, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    registry, _config = _loaded(fleet)
    target = registry.require_profile("codex-1")
    source = target.home / ".cleanup-kill-source"
    cleanup = target.home / ".cleanup-kill-tombstone"
    journal_path = target.home / ".cleanup-kill-journal"
    atomic_write_bytes(source, b"owned cleanup generation\n")
    expected = recovery._file_generation(source, "test cleanup source")
    journal: dict[str, Any] = {}
    atomic_write_json(journal_path, journal)
    real_rename = recovery._rename_noreplace

    def kill_after_rename(rename_source: Path, rename_destination: Path) -> None:
        real_rename(rename_source, rename_destination)
        if rename_source == source and rename_destination == cleanup:
            os._exit(96)

    monkeypatch.setattr(recovery, "_rename_noreplace", kill_after_rename)
    pid = os.fork()
    if pid == 0:  # pragma: no cover - intentional cleanup crash child
        recovery._cleanup_owned_generation(
            source,
            cleanup,
            expected,
            key="test-cleanup-kill",
            label="test cleanup kill generation",
            journal_path=journal_path,
            journal=journal,
        )
        os._exit(0)
    _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == 96
    monkeypatch.setattr(recovery, "_rename_noreplace", real_rename)
    assert not source.exists()
    assert cleanup.exists()

    restarted = json.loads(journal_path.read_text(encoding="utf-8"))
    recovery._cleanup_owned_generation(
        source,
        cleanup,
        expected,
        key="test-cleanup-kill",
        label="test cleanup kill generation",
        journal_path=journal_path,
        journal=restarted,
    )
    assert not source.exists()
    assert cleanup.read_bytes() == b""
    assert restarted["test-cleanup-kill_cleanup_complete"] is True
    retired_generation = restarted["test-cleanup-kill_retired_generation"]
    recovery._cleanup_owned_generation(
        source,
        cleanup,
        expected,
        key="test-cleanup-kill",
        label="test cleanup kill generation",
        journal_path=journal_path,
        journal=restarted,
    )
    assert recovery._same_file_generation(cleanup, retired_generation)


def test_retirement_scrubs_owned_inode_and_preserves_syscall_boundary_replacement(
    fleet: tuple[Registry, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    registry, _config = _loaded(fleet)
    target = registry.require_profile("codex-1")
    source = target.home / ".retire-race-source"
    cleanup = target.home / ".retire-race-marker"
    journal_path = target.home / ".retire-race-journal"
    secret = b"transaction-owned-secret-generation"
    foreign = b"foreign-replacement-must-survive"
    atomic_write_bytes(source, secret)
    expected = recovery._file_generation(source, "retirement race source")
    journal: dict[str, Any] = {}
    atomic_write_json(journal_path, journal)
    real_ftruncate = recovery.os.ftruncate

    def replace_at_descriptor_scrub(descriptor: int, length: int) -> None:
        atomic_write_bytes(cleanup, foreign)
        real_ftruncate(descriptor, length)

    monkeypatch.setattr(recovery.os, "ftruncate", replace_at_descriptor_scrub)
    with pytest.raises(ValueError, match="path changed while its owned inode was retired"):
        recovery._cleanup_owned_generation(
            source,
            cleanup,
            expected,
            key="test-retire-race",
            label="test retirement race generation",
            journal_path=journal_path,
            journal=journal,
        )

    assert not source.exists()
    assert cleanup.read_bytes() == foreign
    assert secret not in b"".join(
        path.read_bytes() for path in target.home.iterdir() if path.is_file()
    )


def test_owned_copy_kill_after_create_before_callback_preserves_ambiguity(
    fleet: tuple[Registry, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    registry, _config = _loaded(fleet)
    target = registry.require_profile("codex-1")
    source = target.home / "auth.json"
    destination = target.home / ".copy-before-callback"
    cleanup = target.home / ".copy-before-callback-cleanup"
    journal_path = target.home / ".copy-before-callback-journal"
    journal: dict[str, Any] = {}
    atomic_write_json(journal_path, journal)
    real_copy = recovery._copy_private_file

    def kill_before_callback(
        _source: Path,
        created: Path,
        *,
        destination_created: Callable[[os.stat_result], None] | None = None,
        expected_source_generation: object | None = None,
    ) -> os.stat_result:
        descriptor = os.open(created, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.fchmod(descriptor, 0o600)
        os.write(descriptor, b"ambiguous partial generation")
        os.fsync(descriptor)
        os.close(descriptor)
        os._exit(97)

    monkeypatch.setattr(recovery, "_copy_private_file", kill_before_callback)
    pid = os.fork()
    if pid == 0:  # pragma: no cover - intentional pre-attribution crash child
        recovery._prepare_owned_copy(
            source,
            destination,
            cleanup,
            key="test-pre-callback",
            label="test pre-callback copy",
            journal_path=journal_path,
            journal=journal,
        )
        os._exit(0)
    _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == 97
    monkeypatch.setattr(recovery, "_copy_private_file", real_copy)

    restarted = json.loads(journal_path.read_text(encoding="utf-8"))
    with pytest.raises(ValueError, match="no durable transaction ownership"):
        recovery._prepare_owned_copy(
            source,
            destination,
            cleanup,
            key="test-pre-callback",
            label="test pre-callback copy",
            journal_path=journal_path,
            journal=restarted,
        )
    assert destination.read_bytes() == b"ambiguous partial generation"
    assert journal_path.exists()


def test_repeated_partial_copy_crashes_use_bounded_distinct_retired_markers(
    fleet: tuple[Registry, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    registry, _config = _loaded(fleet)
    target = registry.require_profile("codex-1")
    source = target.home / "auth.json"
    destination = target.home / ".repeated-partial-copy"
    cleanup = target.home / ".repeated-partial-copy-retired"
    journal_path = target.home / ".repeated-partial-copy-journal"
    journal: dict[str, Any] = {}
    atomic_write_json(journal_path, journal)
    real_copy = recovery._copy_private_file

    def interrupt_copy(
        _source: Path,
        created: Path,
        *,
        destination_created: Callable[[os.stat_result], None] | None = None,
        expected_source_generation: object | None = None,
    ) -> os.stat_result:
        descriptor = os.open(created, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.fchmod(descriptor, 0o600)
        if destination_created is not None:
            destination_created(os.fstat(descriptor))
        os.write(descriptor, b"partial owned credential bytes")
        os.fsync(descriptor)
        os.close(descriptor)
        raise RuntimeError("simulated repeated copy crash")

    monkeypatch.setattr(recovery, "_copy_private_file", interrupt_copy)
    for _attempt in range(2):
        restarted = json.loads(journal_path.read_text(encoding="utf-8"))
        with pytest.raises(RuntimeError, match="simulated repeated copy crash"):
            recovery._prepare_owned_copy(
                source,
                destination,
                cleanup,
                key="test-repeated-copy",
                label="test repeated copy",
                journal_path=journal_path,
                journal=restarted,
            )

    monkeypatch.setattr(recovery, "_copy_private_file", real_copy)
    restarted = json.loads(journal_path.read_text(encoding="utf-8"))
    prepared = recovery._prepare_owned_copy(
        source,
        destination,
        cleanup,
        key="test-repeated-copy",
        label="test repeated copy",
        journal_path=journal_path,
        journal=restarted,
    )
    assert prepared["sha256"] == recovery._file_generation(source, "copy source")["sha256"]
    retired = sorted(target.home.glob(f"{cleanup.name}.test-repeated-copy.partial-*"))
    assert len(retired) == 2
    assert all(path.read_bytes() == b"" for path in retired)
    assert restarted["test-repeated-copy_partial_retirement_count"] == 2


def test_publish_rejects_same_inode_content_mutation_with_restored_mtime(
    fleet: tuple[Registry, Path],
) -> None:
    registry, _config = _loaded(fleet)
    target = registry.require_profile("codex-1")
    source = target.home / ".same-inode-prepared"
    destination = target.home / ".same-inode-published"
    journal_path = target.home / ".same-inode-journal"
    atomic_write_bytes(source, b"original-generation")
    expected = recovery._file_generation(source, "test prepared generation")
    with source.open("r+b") as handle:
        handle.write(b"tampered-generation")
        handle.flush()
        os.fsync(handle.fileno())
    os.utime(
        source,
        ns=(source.stat().st_atime_ns, expected["stat"]["mtime_ns"]),
    )
    journal: dict[str, Any] = {}
    atomic_write_json(journal_path, journal)

    with pytest.raises(ValueError, match="changed before publication"):
        recovery._publish_owned_generation(
            source,
            destination,
            expected,
            key="test-same-inode",
            label="test same-inode generation",
            journal_path=journal_path,
            journal=journal,
        )
    assert source.read_bytes() == b"tampered-generation"
    assert not destination.exists()


def test_metadata_restore_copy_binds_digest_verified_backup_generation(
    fleet: tuple[Registry, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    registry, _config = _loaded(fleet)
    target = registry.require_profile("codex-1")
    destination = target.home / ".metadata-restore-target"
    backup = target.home / ".metadata-restore-backup"
    temporary = target.home / ".metadata-restore-temporary"
    temporary_cleanup = target.home / ".metadata-restore-temporary-retired"
    quarantine = target.home / ".metadata-restore-forward"
    original_quarantine = target.home / ".metadata-restore-original"
    journal_path = target.home / ".metadata-restore-journal"
    original = b"metadata-original"
    tampered = b"metadata-tampered"
    atomic_write_bytes(destination, original)
    original_generation = recovery._file_generation(destination, "original metadata")
    atomic_write_bytes(backup, original)
    destination.unlink()
    journal: dict[str, Any] = {
        "bundle_original_generation": original_generation,
        "bundle_forward_absent": True,
    }
    atomic_write_json(journal_path, journal)
    real_prepare = recovery._prepare_owned_copy

    def mutate_after_digest_validation(
        source: Path,
        prepared: Path,
        cleanup: Path,
        **kwargs,
    ) -> dict[str, Any]:
        metadata = source.stat()
        with source.open("r+b") as handle:
            handle.write(tampered)
            handle.flush()
            os.fsync(handle.fileno())
        os.utime(source, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
        return real_prepare(source, prepared, cleanup, **kwargs)

    monkeypatch.setattr(recovery, "_prepare_owned_copy", mutate_after_digest_validation)
    with pytest.raises(ValueError, match="bound (?:source content|generation)"):
        recovery._restore_snapshot_file(
            target=destination,
            backup=backup,
            temporary=temporary,
            temporary_cleanup=temporary_cleanup,
            quarantine=quarantine,
            original_quarantine=original_quarantine,
            existed=True,
            key="bundle",
            label="provider identity bundle",
            journal_path=journal_path,
            journal=journal,
        )
    assert not destination.exists()
    assert backup.read_bytes() == tampered


def test_metadata_restore_rejects_same_content_backup_inode_substitution(
    fleet: tuple[Registry, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    registry, _config = _loaded(fleet)
    target = registry.require_profile("codex-1")
    destination = target.home / ".metadata-inode-target"
    backup = target.home / ".metadata-inode-backup"
    temporary = target.home / ".metadata-inode-temporary"
    temporary_cleanup = target.home / ".metadata-inode-temporary-retired"
    quarantine = target.home / ".metadata-inode-forward"
    original_quarantine = target.home / ".metadata-inode-original"
    journal_path = target.home / ".metadata-inode-journal"
    original = b"metadata-original"
    atomic_write_bytes(destination, original)
    original_generation = recovery._file_generation(destination, "original metadata")
    atomic_write_bytes(backup, original)
    backup_generation = recovery._file_generation(backup, "metadata backup")
    original_backup_inode = backup_generation["stat"]["ino"]
    destination.unlink()
    journal: dict[str, Any] = {
        "bundle_original_generation": original_generation,
        "bundle_forward_absent": True,
        "bundle-backup_prepared_generation": backup_generation,
    }
    atomic_write_json(journal_path, journal)
    real_copy = recovery._copy_private_file

    def substitute_before_descriptor_open(
        source: Path,
        prepared: Path,
        *,
        destination_created: Callable[[os.stat_result], None] | None = None,
        expected_source_generation: object | None = None,
    ) -> os.stat_result:
        assert source == backup
        atomic_write_bytes(source, original)
        return real_copy(
            source,
            prepared,
            destination_created=destination_created,
            expected_source_generation=expected_source_generation,
        )

    monkeypatch.setattr(recovery, "_copy_private_file", substitute_before_descriptor_open)
    with pytest.raises(ValueError, match="bound generation"):
        recovery._restore_snapshot_file(
            target=destination,
            backup=backup,
            temporary=temporary,
            temporary_cleanup=temporary_cleanup,
            quarantine=quarantine,
            original_quarantine=original_quarantine,
            existed=True,
            key="bundle",
            label="provider identity bundle",
            journal_path=journal_path,
            journal=journal,
        )
    assert backup.read_bytes() == original
    assert backup.stat().st_ino != original_backup_inode
    assert not destination.exists()
    assert not temporary.exists()


def test_credential_rollback_copy_binds_digest_verified_backup_generation(
    fleet: tuple[Registry, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    registry, _config = _loaded(fleet)
    target = registry.require_profile("codex-1")
    stable = target.home / "auth.json"
    backup = target.home / ".credential-restore-backup"
    rollback = target.home / ".credential-restore-temporary"
    rollback_cleanup = target.home / ".credential-restore-temporary-retired"
    quarantine = target.home / ".credential-restore-forward"
    original_quarantine = target.home / ".credential-restore-original"
    journal_path = target.home / ".credential-restore-journal"
    original = b"credential-original"
    tampered = b"credential-tampered"
    forward = b"credential-forward!"
    atomic_write_bytes(stable, original)
    original_generation = recovery._file_generation(stable, "original credential")
    atomic_write_bytes(backup, original)
    backup_generation = recovery._file_generation(backup, "credential backup")
    atomic_write_bytes(stable, forward)
    installed_generation = recovery._file_generation(stable, "installed credential")
    journal: dict[str, Any] = {
        "original_credential_generation": original_generation,
        "installed_credential_generation": installed_generation,
        "codex_backup-snapshot_prepared_generation": backup_generation,
    }
    atomic_write_json(journal_path, journal)
    real_prepare = recovery._prepare_owned_copy

    def mutate_after_digest_validation(
        source: Path,
        prepared: Path,
        cleanup: Path,
        **kwargs,
    ) -> dict[str, Any]:
        metadata = source.stat()
        with source.open("r+b") as handle:
            handle.write(tampered)
            handle.flush()
            os.fsync(handle.fileno())
        os.utime(source, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
        return real_prepare(source, prepared, cleanup, **kwargs)

    monkeypatch.setattr(recovery, "_prepare_owned_copy", mutate_after_digest_validation)
    with pytest.raises(ValueError, match="bound (?:source content|generation)"):
        recovery._rollback_file_credential(
            target,
            "auth.json",
            backup,
            {
                "rollback_temp": rollback,
                "rollback_temp_cleanup": rollback_cleanup,
                "credential_quarantine": quarantine,
                "credential_original_quarantine": original_quarantine,
            },
            journal_path,
            journal,
        )
    assert not stable.exists()
    assert quarantine.read_bytes() == forward
    assert backup.read_bytes() == tampered


def test_credential_rollback_rejects_same_content_backup_inode_substitution(
    fleet: tuple[Registry, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    registry, _config = _loaded(fleet)
    target = registry.require_profile("codex-1")
    stable = target.home / "auth.json"
    backup = target.home / ".credential-inode-backup"
    rollback = target.home / ".credential-inode-temporary"
    rollback_cleanup = target.home / ".credential-inode-temporary-retired"
    quarantine = target.home / ".credential-inode-forward"
    original_quarantine = target.home / ".credential-inode-original"
    journal_path = target.home / ".credential-inode-journal"
    original = b"credential-original"
    forward = b"credential-forward!"
    atomic_write_bytes(stable, original)
    original_generation = recovery._file_generation(stable, "original credential")
    atomic_write_bytes(backup, original)
    backup_generation = recovery._file_generation(backup, "credential backup")
    original_backup_inode = backup_generation["stat"]["ino"]
    atomic_write_bytes(stable, forward)
    installed_generation = recovery._file_generation(stable, "installed credential")
    journal: dict[str, Any] = {
        "original_credential_generation": original_generation,
        "installed_credential_generation": installed_generation,
        "codex_backup-snapshot_prepared_generation": backup_generation,
    }
    atomic_write_json(journal_path, journal)
    real_copy = recovery._copy_private_file

    def substitute_before_descriptor_open(
        source: Path,
        prepared: Path,
        *,
        destination_created: Callable[[os.stat_result], None] | None = None,
        expected_source_generation: object | None = None,
    ) -> os.stat_result:
        assert source == backup
        atomic_write_bytes(source, original)
        return real_copy(
            source,
            prepared,
            destination_created=destination_created,
            expected_source_generation=expected_source_generation,
        )

    monkeypatch.setattr(recovery, "_copy_private_file", substitute_before_descriptor_open)
    with pytest.raises(ValueError, match="bound generation"):
        recovery._rollback_file_credential(
            target,
            "auth.json",
            backup,
            {
                "rollback_temp": rollback,
                "rollback_temp_cleanup": rollback_cleanup,
                "credential_quarantine": quarantine,
                "credential_original_quarantine": original_quarantine,
            },
            journal_path,
            journal,
        )
    assert backup.read_bytes() == original
    assert backup.stat().st_ino != original_backup_inode
    assert not stable.exists()
    assert quarantine.read_bytes() == forward
    assert not rollback.exists()


def test_publish_never_overwrites_destination_reappearance(
    fleet: tuple[Registry, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    registry, _config = _loaded(fleet)
    target = registry.require_profile("codex-1")
    source = target.home / ".publish-race-prepared"
    destination = target.home / ".publish-race-destination"
    journal_path = target.home / ".publish-race-journal"
    atomic_write_bytes(source, b"transaction generation\n")
    expected = recovery._file_generation(source, "test publish source")
    foreign = b"foreign destination generation\n"
    journal: dict[str, Any] = {}
    atomic_write_json(journal_path, journal)
    real_write = recovery._write_recovery_journal

    def reappear_at_publication(
        path: Path,
        payload: dict[str, Any],
        phase: str,
    ) -> None:
        real_write(path, payload, phase)
        if phase == "test-publish-publish-authorized":
            atomic_write_bytes(destination, foreign)

    monkeypatch.setattr(recovery, "_write_recovery_journal", reappear_at_publication)
    with pytest.raises(ValueError, match="destination appeared"):
        recovery._publish_owned_generation(
            source,
            destination,
            expected,
            key="test-publish",
            label="test publish generation",
            journal_path=journal_path,
            journal=journal,
        )
    assert source.read_bytes() == b"transaction generation\n"
    assert destination.read_bytes() == foreign


@pytest.mark.parametrize("component", ["credential", "bundle"])
def test_forward_install_sigkill_after_original_quarantine_restores_on_restart(
    fleet: tuple[Registry, Path],
    monkeypatch: pytest.MonkeyPatch,
    component: str,
) -> None:
    registry, config = _loaded(fleet)
    target = registry.require_profile("codex-1")
    stable_auth = target.home / "auth.json"
    original_auth = stable_auth.read_bytes()
    bundle = identity_bundle_path(registry, "codex")
    original_bundle = bundle.read_bytes()
    real_rename = recovery._rename_noreplace

    def kill_after_original_quarantine(source: Path, destination: Path) -> None:
        real_rename(source, destination)
        credential_boundary = (
            component == "credential"
            and source == stable_auth
            and destination.name.endswith(".original")
        )
        bundle_boundary = (
            component == "bundle" and source == bundle and ".original-" in destination.name
        )
        if credential_boundary or bundle_boundary:
            os._exit(98)

    monkeypatch.setattr(recovery, "_rename_noreplace", kill_after_original_quarantine)
    pid = os.fork()
    if pid == 0:  # pragma: no cover - intentional forward quarantine crash child
        recover_profile_login(
            registry,
            "codex-1",
            config,
            hooks=FakeRecovery(registry).hooks(),
        )
        os._exit(0)
    _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == 98
    monkeypatch.setattr(recovery, "_rename_noreplace", real_rename)
    _expire_abandoned_provider_lock(registry, "codex")

    reloaded = load_registry(config)
    with provider_enrollment_lock(
        reloaded.settings.state_dir,
        "codex",
        reloaded.settings.lock_stale_seconds,
    ):
        recover_pending_profile_recoveries(
            reloaded,
            "codex",
            hooks=FakeRecovery(reloaded).hooks(),
        )
    assert stable_auth.read_bytes() == original_auth
    assert bundle.read_bytes() == original_bundle
    assert not list(
        (reloaded.settings.state_dir / "transactions" / "credential-recovery").glob("*.json")
    )


def test_forward_credential_publish_sigkill_before_installed_journal_converges(
    fleet: tuple[Registry, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    registry, config = _loaded(fleet)
    target = registry.require_profile("codex-1")
    stable_auth = target.home / "auth.json"
    original_auth = stable_auth.read_bytes()
    real_rename = recovery._rename_noreplace

    def kill_after_forward_publication(source: Path, destination: Path) -> None:
        real_rename(source, destination)
        if source.name.endswith(".new") and destination == stable_auth:
            os._exit(100)

    monkeypatch.setattr(recovery, "_rename_noreplace", kill_after_forward_publication)
    pid = os.fork()
    if pid == 0:  # pragma: no cover - intentional forward publication crash child
        recover_profile_login(
            registry,
            "codex-1",
            config,
            hooks=FakeRecovery(registry).hooks(),
        )
        os._exit(0)
    _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == 100
    monkeypatch.setattr(recovery, "_rename_noreplace", real_rename)
    _expire_abandoned_provider_lock(registry, "codex")

    reloaded = load_registry(config)
    with provider_enrollment_lock(
        reloaded.settings.state_dir,
        "codex",
        reloaded.settings.lock_stale_seconds,
    ):
        recovered = recover_pending_profile_recoveries(
            reloaded,
            "codex",
            hooks=FakeRecovery(reloaded).hooks(),
        )
    assert recovered[0]["committed"] is False
    assert stable_auth.read_bytes() == original_auth
    retirement = reloaded.settings.state_dir / "retired" / "credential-recovery"
    retired_files = [path for path in retirement.rglob("*") if path.is_file()]
    assert retired_files
    assert all(path.read_bytes() == b"" for path in retired_files)


@pytest.mark.parametrize("backup_component", ["credential", "bundle"])
def test_owned_backup_mid_copy_sigkill_is_collected_after_rollback(
    fleet: tuple[Registry, Path],
    monkeypatch: pytest.MonkeyPatch,
    backup_component: str,
) -> None:
    registry, config = _loaded(fleet)
    target = registry.require_profile("codex-1")
    stable_auth = target.home / "auth.json"
    original_auth = stable_auth.read_bytes()
    bundle = identity_bundle_path(registry, "codex")
    original_bundle = bundle.read_bytes()
    real_copy = recovery._copy_private_file

    def kill_mid_backup(
        source: Path,
        destination: Path,
        *,
        destination_created: Callable[[os.stat_result], None] | None = None,
        expected_source_generation: object | None = None,
    ) -> os.stat_result:
        credential_boundary = (
            backup_component == "credential" and destination.name == ".stable-auth.backup"
        )
        bundle_boundary = (
            backup_component == "bundle" and destination.name == ".identity-bundle.backup"
        )
        if credential_boundary or bundle_boundary:
            descriptor = os.open(
                destination,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
            )
            os.fchmod(descriptor, 0o600)
            if destination_created is not None:
                destination_created(os.fstat(descriptor))
            os.write(descriptor, b"attributed partial backup")
            os.fsync(descriptor)
            os.close(descriptor)
            os._exit(99)
        return real_copy(
            source,
            destination,
            destination_created=destination_created,
            expected_source_generation=expected_source_generation,
        )

    monkeypatch.setattr(recovery, "_copy_private_file", kill_mid_backup)
    pid = os.fork()
    if pid == 0:  # pragma: no cover - intentional backup crash child
        recover_profile_login(
            registry,
            "codex-1",
            config,
            hooks=FakeRecovery(registry).hooks(),
        )
        os._exit(0)
    _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == 99
    monkeypatch.setattr(recovery, "_copy_private_file", real_copy)
    _expire_abandoned_provider_lock(registry, "codex")

    reloaded = load_registry(config)
    with provider_enrollment_lock(
        reloaded.settings.state_dir,
        "codex",
        reloaded.settings.lock_stale_seconds,
    ):
        recover_pending_profile_recoveries(
            reloaded,
            "codex",
            hooks=FakeRecovery(reloaded).hooks(),
        )
    assert stable_auth.read_bytes() == original_auth
    assert bundle.read_bytes() == original_bundle
    stage_root = reloaded.settings.state_dir / "staging" / "credential-recovery" / "codex"
    assert not list(stage_root.iterdir())


def test_attributed_unlink_restoration_never_overwrites_reappearance(
    fleet: tuple[Registry, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    registry, _config = _loaded(fleet)
    target = registry.require_profile("codex-1")
    quarantine = target.home / ".auth.json.cleanup-restore-quarantine"
    expected = b'{"credential":"transaction-forward-generation"}\n'
    moved_foreign = b'{"credential":"foreign-moved-generation"}\n'
    reappeared = b'{"credential":"foreign-reappeared-generation"}\n'
    atomic_write_bytes(quarantine, expected)
    expected_stat = recovery._stat_payload(
        recovery._private_file(quarantine, "test cleanup credential")
    )
    real_rename = util_module._rename_noreplace_at

    def substitute_then_reappear(
        source_parent: int,
        source_name: str,
        destination_parent: int,
        destination_name: str,
    ) -> None:
        if source_name == quarantine.name:
            atomic_write_bytes(quarantine, moved_foreign)
        elif destination_name == quarantine.name:
            atomic_write_bytes(quarantine, reappeared)
        real_rename(
            source_parent,
            source_name,
            destination_parent,
            destination_name,
        )

    monkeypatch.setattr(util_module, "_rename_noreplace_at", substitute_then_reappear)
    with pytest.raises(ValueError, match="both generations were preserved"):
        util_module.unlink_private_file(
            quarantine,
            label="test cleanup credential",
            expected_stat=expected_stat,
        )

    preserved = list(target.home.glob(f".{quarantine.name}.delete.*"))
    assert quarantine.read_bytes() == reappeared
    assert len(preserved) == 1
    assert preserved[0].read_bytes() == moved_foreign


def _prepare_claude_origin(
    registry: Registry,
    keychain: FileKeychain,
    origin: str,
) -> tuple[Path, str, str, bytes]:
    target = registry.require_profile("claude-1")
    credential = target.home / ".credentials.json"
    old = credential.read_bytes()
    account = recovery._keychain_account()
    stable_service = recovery._claude_service(target.home)
    if origin in {"keychain", "absent"}:
        credential.unlink()
    if origin == "keychain":
        keychain.put(stable_service, account, old)
    return credential, stable_service, account, old


def _recover_crashed_claude(
    registry: Registry,
    config: Path,
    keychain: FileKeychain,
) -> list[dict[str, Any]]:
    _expire_abandoned_provider_lock(registry, "claude")
    reloaded = load_registry(config)
    controls = FakeRecovery(reloaded)
    controls.keychain = keychain  # type: ignore[assignment]
    with provider_enrollment_lock(
        reloaded.settings.state_dir,
        "claude",
        reloaded.settings.lock_stale_seconds,
    ):
        return recover_pending_profile_recoveries(
            reloaded,
            "claude",
            hooks=controls.hooks(),
        )


@pytest.mark.parametrize(
    ("field", "corrupt_value"),
    [
        ("keychain_account", "wrong-account"),
        ("staged_service", "Claude Code"),
        ("stable_service", "Claude Code-credentials"),
        ("backup_service", "Claude Code-agent-fleet-backup"),
    ],
)
def test_corrupt_claude_keychain_scope_journal_performs_no_keychain_operation(
    fleet: tuple[Registry, Path],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    field: str,
    corrupt_value: str,
) -> None:
    registry, config = _loaded(fleet)
    keychain = FileKeychain(tmp_path / "scope-keychain")
    _prepare_claude_origin(registry, keychain, "keychain")
    forward = FakeRecovery(registry)
    forward.keychain = keychain  # type: ignore[assignment]
    _crash_transaction_at_phase(
        monkeypatch,
        lambda: recover_profile_login(
            registry,
            "claude-1",
            config,
            browser_login=True,
            allow_keychain_prompt=True,
            hooks=forward.hooks(),
        ),
        "credential-installed",
    )
    journal_path = next(
        (registry.settings.state_dir / "transactions" / "credential-recovery").glob("*.json")
    )
    journal = read_private_json(journal_path, label="test Claude recovery journal")
    journal[field] = corrupt_value
    atomic_write_json(journal_path, journal)
    keychain_before = {path.name: path.read_bytes() for path in sorted(keychain.root.iterdir())}
    _expire_abandoned_provider_lock(registry, "claude")

    reloaded = load_registry(config)
    controls = FakeRecovery(reloaded)
    controls.keychain = keychain  # type: ignore[assignment]
    with (
        provider_enrollment_lock(
            reloaded.settings.state_dir,
            "claude",
            reloaded.settings.lock_stale_seconds,
        ),
        pytest.raises(ValueError, match="Keychain scope is not derived exactly"),
    ):
        recover_pending_profile_recoveries(
            reloaded,
            "claude",
            hooks=controls.hooks(),
        )

    assert {
        path.name: path.read_bytes() for path in sorted(keychain.root.iterdir())
    } == keychain_before
    assert journal_path.exists()


@pytest.mark.parametrize("crash_phase", DURABLE_RECOVERY_PHASES)
def test_claude_sigkill_boundary_restart_is_locally_atomic(
    fleet: tuple[Registry, Path],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    crash_phase: str,
) -> None:
    registry, config = _loaded(fleet)
    keychain = FileKeychain(tmp_path / "fake-keychain")
    credential, stable_service, account, old = _prepare_claude_origin(
        registry,
        keychain,
        "keychain",
    )
    fake = FakeRecovery(registry)
    fake.keychain = keychain  # type: ignore[assignment]
    real_write = recovery._write_journal

    def crash_after_durable_phase(path: Path, journal: dict[str, Any], phase: str) -> None:
        real_write(path, journal, phase)
        if phase == crash_phase:
            os._exit(91)

    monkeypatch.setattr(recovery, "_write_journal", crash_after_durable_phase)
    pid = os.fork()
    if pid == 0:  # pragma: no cover - intentional crash child
        recover_profile_login(
            registry,
            "claude-1",
            config,
            browser_login=True,
            allow_keychain_prompt=True,
            hooks=fake.hooks(),
        )
        os._exit(0)
    _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == 91
    monkeypatch.setattr(recovery, "_write_journal", real_write)

    recovered = _recover_crashed_claude(registry, config, keychain)
    assert recovered[0]["committed"] is (crash_phase == "committed")
    if crash_phase == "committed":
        assert keychain.get(stable_service, account) == b"fixture-recovered-value"
    else:
        assert keychain.get(stable_service, account) == old
    assert not credential.exists()
    assert len(list(keychain.root.iterdir())) == 1


@pytest.mark.parametrize(
    ("origin", "crash_point"),
    [
        ("keychain", "pre-copy"),
        ("keychain", "mid-copy"),
        ("keychain", "post-copy"),
        ("file", "pre-copy"),
        ("file", "post-copy"),
        ("absent", "pre-copy"),
        ("absent", "post-copy"),
    ],
)
def test_claude_backup_crash_recovery_never_uses_partial_generation(
    fleet: tuple[Registry, Path],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    origin: str,
    crash_point: str,
) -> None:
    registry, config = _loaded(fleet)
    keychain = FileKeychain(
        tmp_path / "fake-keychain",
        crash_during_backup=crash_point == "mid-copy",
    )
    credential, stable_service, account, old = _prepare_claude_origin(
        registry,
        keychain,
        origin,
    )
    fake = FakeRecovery(registry)
    fake.keychain = keychain  # type: ignore[assignment]
    real_write = recovery._write_journal
    crash_phase = (
        "credential-backup-running" if crash_point == "pre-copy" else "credential-backup-ready"
    )

    def crash_at_boundary(path: Path, journal: dict[str, Any], phase: str) -> None:
        real_write(path, journal, phase)
        if crash_point != "mid-copy" and phase == crash_phase:
            os._exit(91)

    monkeypatch.setattr(recovery, "_write_journal", crash_at_boundary)
    pid = os.fork()
    if pid == 0:  # pragma: no cover - intentional crash child
        recover_profile_login(
            registry,
            "claude-1",
            config,
            browser_login=True,
            allow_keychain_prompt=True,
            hooks=fake.hooks(),
        )
        os._exit(0)
    _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == (92 if crash_point == "mid-copy" else 91)
    monkeypatch.setattr(recovery, "_write_journal", real_write)

    _recover_crashed_claude(registry, config, keychain)
    if origin == "keychain":
        assert keychain.get(stable_service, account) == old
        assert not credential.exists()
        assert len(list(keychain.root.iterdir())) == 1
    elif origin == "file":
        assert credential.read_bytes() == old
        assert not keychain.exists(stable_service, account)
        assert not list(keychain.root.iterdir())
    else:
        assert not credential.exists()
        assert not keychain.exists(stable_service, account)
        assert not list(keychain.root.iterdir())


def test_security_keychain_copy_uses_exact_account_and_pipe_not_secret_argv(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    calls: list[tuple[list[str], Any, dict[str, str], Path]] = []
    verified_binary = Path("/verified/security")

    class Process:
        def __init__(self, argv, *, env, cwd, stdin, stdout, stderr):
            calls.append((list(argv), stdin, dict(env), Path(cwd)))
            self.stdout = io.BytesIO(b"fixture-secret-that-must-not-enter-argv")
            self.returncode = 0

        def wait(self):
            return self.returncode

        def poll(self):
            return self.returncode

        def kill(self):
            self.returncode = -9

    monkeypatch.setattr(recovery.subprocess, "Popen", Process)
    monkeypatch.setattr(SecurityKeychain, "_verified_binary", lambda self: verified_binary)
    monkeypatch.setattr(recovery, "_keychain_account", lambda: "fixture-user")
    monkeypatch.setattr(recovery, "current_user_home", lambda: tmp_path)
    SecurityKeychain().copy(
        "Claude Code-credentials-11111111",
        "Claude Code-credentials-22222222",
        "fixture-user",
    )
    all_arguments = [argument for argv, _stdin, _env, _cwd in calls for argument in argv]
    assert "fixture-secret-that-must-not-enter-argv" not in all_arguments
    assert all(
        "-a" in argv and argv[argv.index("-a") + 1] == "fixture-user"
        for argv, _stdin, _env, _cwd in calls
    )
    assert calls[1][0][-1] == "-w"
    assert isinstance(calls[1][1], io.BytesIO)
    assert all(argv[0] == str(verified_binary) for argv, *_rest in calls)
    expected_environment = {
        "HOME": str(tmp_path),
        "USER": "fixture-user",
        "LOGNAME": "fixture-user",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LC_ALL": "C",
        "LANG": "C",
        "NO_COLOR": "1",
        "TERM": "dumb",
    }
    assert all(environment == expected_environment for _a, _s, environment, _c in calls)
    assert all(cwd == tmp_path for _a, _s, _e, cwd in calls)


def test_security_keychain_exists_and_delete_ignore_hostile_environment(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    calls: list[tuple[list[str], dict[str, str], Path]] = []

    class Result:
        returncode = 0

    def run(argv, *, env, cwd, stdin, stdout, stderr, check):
        calls.append((list(argv), dict(env), Path(cwd)))
        return Result()

    for name in (
        "HOME",
        "USER",
        "LOGNAME",
        "PATH",
        "LC_ALL",
        "LANG",
        "NO_COLOR",
        "TERM",
        "DYLD_INSERT_LIBRARIES",
        "PYTHONPATH",
        "NODE_OPTIONS",
    ):
        monkeypatch.setenv(name, f"hostile-{name}")
    monkeypatch.setattr(recovery.subprocess, "run", run)
    monkeypatch.setattr(
        SecurityKeychain,
        "_verified_binary",
        lambda self: Path("/verified/security"),
    )
    monkeypatch.setattr(recovery, "_keychain_account", lambda: "fixture-user")
    monkeypatch.setattr(recovery, "current_user_home", lambda: tmp_path)

    keychain = SecurityKeychain()
    assert keychain.exists("Claude Code-credentials-11111111", "fixture-user") is True
    keychain.delete(
        "Claude Code-credentials-11111111",
        "fixture-user",
        missing_ok=True,
    )

    expected_environment = {
        "HOME": str(tmp_path),
        "USER": "fixture-user",
        "LOGNAME": "fixture-user",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LC_ALL": "C",
        "LANG": "C",
        "NO_COLOR": "1",
        "TERM": "dumb",
    }
    assert len(calls) == 2
    assert all(environment == expected_environment for _argv, environment, _cwd in calls)
    assert all(cwd == tmp_path for _argv, _environment, cwd in calls)


@pytest.mark.parametrize(
    "service",
    [
        "Claude Code",
        "Claude Code-credentials",
        "Claude Code-credentials-default",
        "Claude Code-credentials-1111111g",
        "Claude Code-agent-fleet-backup",
        "Claude Code-agent-fleet-backup-11111111",
        "Claude Code-unrelated-11111111",
    ],
)
def test_security_keychain_rejects_default_or_non_derived_service(
    monkeypatch: pytest.MonkeyPatch,
    service: str,
) -> None:
    monkeypatch.setattr(recovery, "_keychain_account", lambda: "fixture-user")
    with pytest.raises(ValueError, match="unscoped Claude Keychain operation"):
        SecurityKeychain().exists(service, "fixture-user")


def test_security_keychain_rejects_untrusted_binary(tmp_path: Path) -> None:
    binary = tmp_path / "security"
    binary.write_bytes(b"fixture")
    binary.chmod(0o775)
    keychain = SecurityKeychain()
    keychain.binary = binary

    with pytest.raises(ValueError, match="control is unsafe"):
        keychain.exists("Claude Code-credentials-11111111", recovery._keychain_account())
