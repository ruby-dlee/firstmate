from __future__ import annotations

import io
import json
import os
import pwd
from dataclasses import replace
from hashlib import sha256
from pathlib import Path
from typing import Any

import pytest

from agent_fleet import recovery
from agent_fleet.config import load_registry, save_registry
from agent_fleet.identity import (
    adopt_provider_identity_bundle,
    identity_bundle_path,
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


class FakeRecovery:
    def __init__(self, registry: Registry) -> None:
        self.registry = registry
        self.identity_by_profile = {
            profile.id: str(
                read_identity_binding(registry, profile).get("remote_fingerprint", "")
            )
            for profile in registry.profiles.values()
        }
        self.keychain = FakeKeychain()
        self.login_calls: list[tuple[list[str], dict[str, str], Path]] = []
        self.fail_login = False
        self.fail_stable: set[str] = set()
        self.fingerprint_override: dict[str, str] = {}
        self.stable_fingerprint_override: dict[str, str] = {}
        self.proof_exception: str | None = None

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
        child_started(os.getpid(), start)
        if self.fail_login:
            return 9
        if environment.get("AGENT_FLEET_PROVIDER") == "codex":
            atomic_write_json(
                cwd / "auth.json",
                {"tokens": {"access_token": "fixture-recovered-value"}},
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
        if self.proof_exception is not None:
            raise ValueError(self.proof_exception)
        if profile.id in self.fail_stable and "credential-recovery" not in str(profile.home):
            raise ValueError("fixture remote ejection")
        binding = read_identity_binding(registry, profile)
        fingerprint = self.fingerprint_override.get(
            profile.id,
            str(binding.get("remote_fingerprint") or self.identity_by_profile[profile.id]),
        )
        if (
            profile.id in self.stable_fingerprint_override
            and "credential-recovery" not in str(profile.home)
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
    def adopt(
        registry: Registry,
        provider: str,
        proofs: dict[str, tuple[dict[str, Any], dict[str, Any]]],
        prompt: bool,
    ) -> dict[str, Any]:
        return adopt_provider_identity_bundle(
            registry,
            provider,
            proofs,
            allow_keychain_prompt=prompt,
        )

    def hooks(self) -> RecoveryHooks:
        return RecoveryHooks(
            login=self.login,
            inspect_source=self.inspect,
            prove=self.prove,
            refresh_anchors=self.refresh,
            adopt_bundle=self.adopt,
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
    "binding-installed",
    "committed",
]


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
    assert b"fixture-recovered-value" in (
        registry.require_profile("codex-1").home / "auth.json"
    ).read_bytes()
    assert not list(
        (registry.settings.state_dir / "transactions" / "credential-recovery").glob("*.json")
    )


def test_recovery_login_and_claude_browser_modes_are_explicit(
    fleet: tuple[Registry, Path]
) -> None:
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
    fleet: tuple[Registry, Path]
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
    assert recover_pending_profile_recoveries(
        registry,
        "codex",
        hooks=FakeRecovery(registry).hooks(),
    ) == []
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
    fleet: tuple[Registry, Path]
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
    fleet: tuple[Registry, Path]
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
    fleet: tuple[Registry, Path]
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


def test_missing_target_binding_fails_before_provider_login(
    fleet: tuple[Registry, Path]
) -> None:
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
    bundle["workers"][profile_id]["remote_fingerprint"] = anchor_payload[
        "identity_fingerprint"
    ]
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
    fleet: tuple[Registry, Path]
) -> None:
    registry, config = _loaded(fleet)
    fake = FakeRecovery(registry)

    def inject(phase: str) -> None:
        if phase != "stage-verified":
            return
        roots = list(
            (registry.settings.state_dir / "staging" / "credential-recovery").rglob(
                "*.login-*"
            )
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
    fleet: tuple[Registry, Path]
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
    fleet: tuple[Registry, Path]
) -> None:
    registry, config = _loaded(fleet)
    auth = registry.require_profile("codex-1").home / "auth.json"
    os.link(auth, auth.with_name("auth-hardlink-fixture"))
    fake = FakeRecovery(registry)
    with pytest.raises(ValueError, match="single-link"):
        recover_profile_login(registry, "codex-1", config, hooks=fake.hooks())
    assert fake.login_calls == []


def test_result_audit_and_journal_never_contain_fake_credential_value(
    fleet: tuple[Registry, Path]
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
    fleet: tuple[Registry, Path]
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
    fleet: tuple[Registry, Path]
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
    fleet: tuple[Registry, Path]
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
    fleet: tuple[Registry, Path]
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
    fleet: tuple[Registry, Path]
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
            "provider_side_revocation_possible": crash_phase
            not in {"intent", "stage-ready"},
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
) -> None:
    calls: list[tuple[list[str], Any]] = []

    class Process:
        def __init__(self, argv, *, stdin, stdout, stderr):
            calls.append((list(argv), stdin))
            self.stdout = io.BytesIO(b"fixture-secret-that-must-not-enter-argv")
            self.returncode = 0

        def wait(self):
            return self.returncode

        def poll(self):
            return self.returncode

        def kill(self):
            self.returncode = -9

    monkeypatch.setattr(recovery.subprocess, "Popen", Process)
    SecurityKeychain().copy(
        "Claude Code-credentials-11111111",
        "Claude Code-credentials-22222222",
        "fixture-user",
    )
    all_arguments = [argument for argv, _stdin in calls for argument in argv]
    assert "fixture-secret-that-must-not-enter-argv" not in all_arguments
    assert all("-a" in argv and argv[argv.index("-a") + 1] == "fixture-user" for argv, _ in calls)
    assert calls[1][0][-1] == "-w"
    assert isinstance(calls[1][1], io.BytesIO)
