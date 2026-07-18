from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import threading
from contextlib import contextmanager
from dataclasses import replace
from datetime import UTC, datetime
from pathlib import Path

import pytest

import agent_fleet.scheduler as scheduler_module
from agent_fleet.config import (
    load_registry,
    quota_binary_digest,
    quota_release_tree_digest,
    save_registry,
)
from agent_fleet.cooldowns import set_cooldown
from agent_fleet.leases import active_leases, release_lease
from agent_fleet.provision import provision_profile
from agent_fleet.quota import quota_path, refresh_quota
from agent_fleet.scheduler import select_and_acquire
from agent_fleet.sessions import session_path
from agent_fleet.util import atomic_write_json


def _enable_and_provision(registry, config: Path, ids: list[str], *, reserve: int = 15):
    profiles = dict(registry.profiles)
    for profile_id in ids:
        profiles[profile_id] = replace(
            profiles[profile_id], enabled=True, reserve_percent=reserve, max_concurrent=50
        )
    registry = replace(registry, profiles=profiles)
    save_registry(registry, config)
    registry = load_registry(config)
    for profile_id in ids:
        provision_profile(registry, registry.require_profile(profile_id))
    return registry


def _quota_fixture(path: Path, provider: str, remaining: int) -> None:
    def write(target: Path, account: str) -> None:
        target.write_text(
            json.dumps(
                {
                    "providers": [
                        {
                            "provider": provider,
                            "account": {
                                "accountId": account,
                                "email": account.removesuffix("-account")
                                + "@example.invalid",
                            },
                            "state": {
                                "status": "fresh",
                                "refreshedAt": datetime.now(UTC).isoformat(),
                            },
                            "windows": [
                                {
                                    "id": "five_hour",
                                    "kind": "session",
                                    "percentRemaining": remaining,
                                }
                            ],
                        }
                    ]
                }
            ),
            encoding="utf-8",
        )

    write(path, f"{path.stem}-account")
    base = path.parent / f"{provider}-base-anchor.json"
    if not base.exists():
        write(base, f"{provider}-base-anchor-account")


def _use_quota_fixtures(registry, fixtures: Path) -> None:
    (registry.settings.state_dir / "test-quota-fixture-dir").write_text(
        str(fixtures), encoding="utf-8"
    )


def _sealed_quota_runtime(
    root: Path,
    quota_source: str,
    *,
    node_source: str | None = None,
) -> tuple[Path, Path, str]:
    quota_entrypoint = root / "node_modules" / "quota-axi" / "dist" / "bin" / "quota-axi.js"
    quota_entrypoint.parent.mkdir(parents=True)
    quota_entrypoint.write_text(quota_source, encoding="utf-8")
    quota_entrypoint.chmod(0o444)
    dependency = root / "node_modules" / "quota-axi" / "dist" / "src" / "quota.js"
    dependency.parent.mkdir(parents=True)
    dependency.write_text("export const sealedTestDependency = true;\n", encoding="utf-8")
    dependency.chmod(0o644)
    node_binary = root / "runtime" / "node"
    node_binary.parent.mkdir(parents=True)
    node_binary.write_text(
        node_source or f'#!/bin/sh\nexec {str(sys.executable)!r} "$@"\n',
        encoding="utf-8",
    )
    node_binary.chmod(0o755)
    quota_binary = root / "bin" / "quota-axi"
    quota_binary.parent.mkdir()
    quota_binary.write_text(
        f'#!/bin/sh\nexec {str(sys.executable)!r} {str(quota_entrypoint)!r} "$@"\n',
        encoding="utf-8",
    )
    quota_binary.chmod(0o755)
    return node_binary, quota_binary, quota_release_tree_digest(quota_binary, node_binary)


def _with_quota_runtime(registry, node: Path, quota: Path, tree_digest: str):
    return replace(
        registry,
        settings=replace(
            registry.settings,
            quota_binary=quota,
            quota_binary_sha256=quota_binary_digest(quota),
            quota_node_binary=node,
            quota_node_sha256=quota_binary_digest(node),
            quota_release_tree_sha256=tree_digest,
        ),
    )


def test_fresh_quota_selects_best_safe_profile(
    fleet: tuple[object, Path], monkeypatch, tmp_path: Path
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, ["codex-1", "codex-2"])
    fixtures = tmp_path / "quota"
    fixtures.mkdir()
    _quota_fixture(fixtures / "codex-1.json", "codex", 82)
    _quota_fixture(fixtures / "codex-2.json", "codex", 37)
    _use_quota_fixtures(registry, fixtures)
    for profile_id in ("codex-1", "codex-2"):
        refresh_quota(registry, registry.require_profile(profile_id))

    selected = select_and_acquire(
        registry,
        task="quota-task",
        pool="codex-crew",
        provider="codex",
        workspace=Path.cwd(),
    )
    assert selected["lease"]["profile"] == "codex-1"
    assert selected["decision_reason"] == "quota"


def test_fresh_profile_below_reserve_is_excluded(
    fleet: tuple[object, Path], monkeypatch, tmp_path: Path
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, ["claude-1", "claude-2"])
    profiles = dict(registry.profiles)
    profiles["claude-1"] = replace(profiles["claude-1"], reserve_percent=90)
    registry = replace(registry, profiles=profiles)
    save_registry(registry, config)
    fixtures = tmp_path / "quota"
    fixtures.mkdir()
    _quota_fixture(fixtures / "claude-1.json", "claude", 80)
    _quota_fixture(fixtures / "claude-2.json", "claude", 40)
    _use_quota_fixtures(registry, fixtures)
    for profile_id in ("claude-1", "claude-2"):
        refresh_quota(registry, registry.require_profile(profile_id))

    selected = select_and_acquire(
        registry,
        task="reserve-task",
        pool="claude-crew",
        provider="claude",
        workspace=Path.cwd(),
    )
    assert selected["lease"]["profile"] == "claude-2"


def test_sticky_resume_can_reacquire_its_profile_below_reserve(
    fleet: tuple[object, Path], monkeypatch, tmp_path: Path
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, ["codex-1"])
    fixtures = tmp_path / "quota"
    fixtures.mkdir()
    _quota_fixture(fixtures / "codex-1.json", "codex", 5)
    _use_quota_fixtures(registry, fixtures)
    refresh_quota(registry, registry.require_profile("codex-1"))

    with pytest.raises(ValueError, match="quota reserve"):
        select_and_acquire(
            registry,
            task="new-task",
            pool="codex-crew",
            provider="codex",
            profile_id="codex-1",
            workspace=Path.cwd(),
        )

    atomic_write_json(
        session_path(registry, "resumed-task"),
        {
            "schema": 1,
            "task": "resumed-task",
            "pool": "codex-crew",
            "profile": "codex-1",
            "provider": "codex",
            "workspace": str(Path.cwd()),
            "turn_end": str(tmp_path / "resumed-task.turn-ended"),
            "session_id": "sticky-session",
            "updated_at": datetime.now(UTC).isoformat(),
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
            "lease",
            "recover",
            "--task",
            "resumed-task",
            "--workspace",
            str(Path.cwd()),
        ],
        cwd=Path.cwd(),
        env=env,
        text=True,
        capture_output=True,
        timeout=20,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    selected = json.loads(result.stdout)
    assert selected["profile"] == "codex-1"
    assert selected["decision_reason"] == "sticky-resume"

    select_and_acquire(
        registry,
        task="resumed-task",
        pool="codex-crew",
        profile_id="codex-1",
        bind_pid=os.getpid(),
        workspace=Path.cwd(),
    )
    with pytest.raises(ValueError, match="live worker lease"):
        select_and_acquire(
            registry,
            task="resumed-task",
            pool="codex-crew",
            profile_id="codex-1",
            ignore_reserve=True,
            recovery_reservation=True,
            workspace=Path.cwd(),
        )


def test_reserved_lease_can_be_released_without_force(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, ["claude-1"])
    selected = select_and_acquire(
        registry,
        task="failed-pane-create",
        pool="claude-crew",
        profile_id="claude-1",
        workspace=Path.cwd(),
    )
    assert selected["lease"]["state"] == "reserved"

    released = release_lease(registry, "failed-pane-create")
    assert released["released"] is True
    assert active_leases(registry) == []


def test_dry_run_does_not_lease_or_change_selection(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, ["claude-1"])
    selected = select_and_acquire(
        registry,
        task="dry-run-task",
        pool="claude-crew",
        provider="claude",
        dry_run=True,
        workspace=Path.cwd(),
    )
    assert selected["dry_run"] is True
    assert selected["lease"] is None
    assert active_leases(registry) == []
    assert not (registry.settings.state_dir / "selection.json").exists()


def test_dry_run_is_a_read_only_snapshot(fleet: tuple[object, Path]) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, ["claude-1"])

    def snapshot(root: Path) -> dict[str, tuple[int, bytes]]:
        return {
            str(path.relative_to(root)): (stat.S_IMODE(path.stat().st_mode), path.read_bytes())
            for path in root.rglob("*")
            if path.is_file()
        }

    before = snapshot(registry.settings.state_dir) | {
        f"profile/{key}": value for key, value in snapshot(registry.settings.share_dir).items()
    }
    select_and_acquire(
        registry,
        task="read-only-dry-run",
        pool="claude-crew",
        provider="claude",
        dry_run=True,
        workspace=Path.cwd(),
    )
    after = snapshot(registry.settings.state_dir) | {
        f"profile/{key}": value for key, value in snapshot(registry.settings.share_dir).items()
    }
    assert after == before


def test_cooldown_excludes_profile(fleet: tuple[object, Path]) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, ["codex-1", "codex-2"])
    set_cooldown(registry, "codex-1", seconds=60, reason="spawn-failure")
    selected = select_and_acquire(
        registry,
        task="cooldown-task",
        pool="codex-crew",
        provider="codex",
        workspace=Path.cwd(),
    )
    assert selected["profile"] == "codex-2"


def test_nonzero_quota_exit_preserves_structured_provider_status(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    node, binary, tree_digest = _sealed_quota_runtime(
        tmp_path / "custom-quota-release",
        """#!/usr/bin/env python3
import json
import sys
print(json.dumps({
    "providers": [{
        "provider": "claude",
        "account": {"accountId": "claude-1-account"},
        "state": {"status": "auth_required", "reason": "keychain_access_required"},
        "windows": [],
    }]
}))
sys.exit(1)
""",
    )
    registry = _with_quota_runtime(registry, node, binary, tree_digest)

    quota = refresh_quota(registry, registry.require_profile("claude-1"))
    assert quota["status"] == "auth_required"
    assert quota["reason"] == "keychain_access_required"
    assert quota["headroom_percent"] is None


def test_stale_cache_after_remote_auth_failure_is_never_selected(
    fleet: tuple[object, Path], monkeypatch, tmp_path: Path
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, ["codex-1"])
    fixtures = tmp_path / "quota"
    fixtures.mkdir()
    (fixtures / "codex-1.json").write_text(
        json.dumps(
            {
                "providers": [
                    {
                        "provider": "codex",
                        "state": {
                            "status": "stale",
                            "error": "Codex sign-in required",
                            "refreshedAt": datetime.now(UTC).isoformat(),
                        },
                        "windows": [
                            {
                                "id": "five_hour",
                                "kind": "session",
                                "percentRemaining": 76,
                            }
                        ],
                    }
                ]
            }
        ),
        encoding="utf-8",
    )
    _use_quota_fixtures(registry, fixtures)

    quota = refresh_quota(registry, registry.require_profile("codex-1"))

    assert quota["reported_status"] == "stale"
    assert quota["status"] == "auth_required"
    assert quota["reason"] == "cached_after_auth_failure"
    with pytest.raises(ValueError, match="cached_after_auth_failure"):
        select_and_acquire(
            registry,
            task="revoked-cache",
            pool="codex-crew",
            profile_id="codex-1",
            workspace=Path.cwd(),
        )
    assert active_leases(registry) == []


def test_dry_run_requires_a_same_attempt_fresh_proof_even_with_recent_cache(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, ["claude-1"])
    fixtures = tmp_path / "quota"
    fixtures.mkdir()
    _quota_fixture(fixtures / "claude-1.json", "claude", 70)
    _use_quota_fixtures(registry, fixtures)
    refresh_quota(registry, registry.require_profile("claude-1"))
    cached = json.loads(quota_path(registry, "claude-1").read_text(encoding="utf-8"))
    cached["status"] = "stale"
    cached["refreshed_at"] = datetime.now(UTC).isoformat()
    atomic_write_json(quota_path(registry, "claude-1"), cached)

    selected = select_and_acquire(
        registry,
        task="transient-outage",
        pool="claude-crew",
        profile_id="claude-1",
        dry_run=True,
        workspace=Path.cwd(),
    )
    assert selected["decision_reason"] == "quota"
    assert selected["identity_proof"] == "same-attempt-read-only"
    assert selected["degraded"] is False

    live = json.loads((fixtures / "claude-1.json").read_text(encoding="utf-8"))
    live["providers"][0]["state"]["status"] = "stale"
    (fixtures / "claude-1.json").write_text(json.dumps(live), encoding="utf-8")
    with pytest.raises(ValueError, match="fresh_remote_identity_proof_unavailable"):
        select_and_acquire(
            registry,
            task="stale-live-proof",
            pool="claude-crew",
            profile_id="claude-1",
            dry_run=True,
            workspace=Path.cwd(),
        )


def test_dry_run_surfaces_durable_identity_binding_conflict(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, ["claude-1"])
    fixtures = tmp_path / "quota"
    fixtures.mkdir()
    _quota_fixture(fixtures / "claude-1.json", "claude", 70)
    live = json.loads((fixtures / "claude-1.json").read_text(encoding="utf-8"))
    live["providers"][0]["account"]["accountId"] = "replacement-account"
    (fixtures / "claude-1.json").write_text(json.dumps(live), encoding="utf-8")
    _use_quota_fixtures(registry, fixtures)

    with pytest.raises(ValueError, match="identity_binding_remote_mismatch"):
        select_and_acquire(
            registry,
            task="binding-conflict",
            pool="claude-crew",
            profile_id="claude-1",
            dry_run=True,
            workspace=Path.cwd(),
        )


def test_dry_run_uses_fresh_external_observation_when_anchor_is_stale(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, ["claude-1"])
    anchor_path = registry.settings.state_dir / "identity-anchors" / "claude-base.json"
    stale_anchor = json.loads(anchor_path.read_text(encoding="utf-8"))
    stale_anchor["refreshed_at"] = "2000-01-01T00:00:00+00:00"
    atomic_write_json(anchor_path, stale_anchor)

    selected = select_and_acquire(
        registry,
        task="stale-anchor-fresh-observation",
        pool="claude-crew",
        profile_id="claude-1",
        dry_run=True,
        workspace=Path.cwd(),
    )

    assert selected["profile"] == "claude-1"
    assert selected["identity_proof"] == "same-attempt-read-only"
    assert json.loads(anchor_path.read_text(encoding="utf-8")) == stale_anchor


def test_dry_run_rejects_changed_external_observation(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, ["claude-1"])
    real_probe = scheduler_module.probe_provider_external_observation

    def changed_external_probe(current, provider: str):
        observed = real_probe(current, provider)
        observed["base"]["identity_fingerprint"] = "0" * 64
        return observed

    monkeypatch.setattr(
        scheduler_module,
        "probe_provider_external_observation",
        changed_external_probe,
    )

    with pytest.raises(
        ValueError,
        match="provider identity bundle changed before selection: claude:external_changed",
    ):
        select_and_acquire(
            registry,
            task="changed-external-dry-run",
            pool="claude-crew",
            profile_id="claude-1",
            dry_run=True,
            workspace=Path.cwd(),
        )
    assert active_leases(registry) == []


@pytest.mark.parametrize(
    ("failure", "reason"),
    [
        (TimeoutError("secret timeout detail"), "external_identity_timeout"),
        (OSError("secret OS detail"), "external_identity_unavailable"),
        (ValueError("secret parse detail"), "external_identity_indeterminate"),
    ],
)
def test_final_external_probe_errors_use_safe_categories(
    fleet: tuple[object, Path],
    monkeypatch: pytest.MonkeyPatch,
    failure: Exception,
    reason: str,
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, ["claude-1"])

    def failed_external_probe(*_args, **_kwargs):
        raise failure

    monkeypatch.setattr(
        scheduler_module,
        "probe_provider_external_observation",
        failed_external_probe,
    )

    with pytest.raises(
        ValueError,
        match=(
            "provider external identity proof failed before selection: "
            f"claude:{reason}"
        ),
    ) as raised:
        select_and_acquire(
            registry,
            task=f"safe-external-error-{reason}",
            pool="claude-crew",
            profile_id="claude-1",
            dry_run=True,
            workspace=Path.cwd(),
        )
    assert "secret" not in str(raised.value)


def test_selection_reproves_external_identity_after_worker_proofs(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, ["claude-1"])
    fixtures = tmp_path / "quota"
    fixtures.mkdir()
    _quota_fixture(fixtures / "claude-1.json", "claude", 70)
    _use_quota_fixtures(registry, fixtures)
    real_probe = scheduler_module.probe_provider_external_observation
    final_probes = 0

    def switch_base_before_final_probe(current, provider: str):
        nonlocal final_probes
        if provider == "claude":
            final_probes += 1
            _quota_fixture(fixtures / "claude-base-anchor.json", "claude", 70)
            payload = json.loads(
                (fixtures / "claude-base-anchor.json").read_text(encoding="utf-8")
            )
            payload["providers"][0]["account"]["accountId"] = "claude-1-account"
            (fixtures / "claude-base-anchor.json").write_text(
                json.dumps(payload),
                encoding="utf-8",
            )
        return real_probe(current, provider)

    monkeypatch.setattr(
        scheduler_module,
        "probe_provider_external_observation",
        switch_base_before_final_probe,
    )

    with pytest.raises(
        ValueError,
        match="duplicate_provider_identity before selection: claude:claude-1",
    ):
        select_and_acquire(
            registry,
            task="external-race",
            pool="claude-crew",
            profile_id="claude-1",
            workspace=Path.cwd(),
        )
    assert final_probes == 1
    assert active_leases(registry) == []


def test_final_external_probe_does_not_hold_global_state_lock(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, ["claude-1"])
    probe_entered = threading.Event()
    release_probe = threading.Event()
    real_probe = scheduler_module.probe_provider_external_observation

    def blocked_external_probe(current, provider: str):
        probe_entered.set()
        assert release_probe.wait(timeout=10)
        return real_probe(current, provider)

    monkeypatch.setattr(
        scheduler_module,
        "probe_provider_external_observation",
        blocked_external_probe,
    )
    outcome: dict[str, object] = {}

    def select() -> None:
        try:
            outcome["result"] = select_and_acquire(
                registry,
                task="slow-external-proof",
                pool="claude-crew",
                profile_id="claude-1",
                workspace=Path.cwd(),
            )
        except ValueError as exc:
            outcome["error"] = str(exc)

    worker = threading.Thread(target=select)
    worker.start()
    assert probe_entered.wait(timeout=10)
    try:
        with scheduler_module.state_lock(
            registry.settings.state_dir,
            registry.settings.lock_stale_seconds,
            timeout=0.25,
        ):
            pass
    finally:
        release_probe.set()
    worker.join(timeout=10)

    assert not worker.is_alive()
    assert "error" not in outcome
    assert outcome["result"]["profile"] == "claude-1"


def test_concurrent_dry_run_proof_bundles_are_provider_serialized(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, ["claude-1"])
    first_probe_entered = threading.Event()
    release_first_probe = threading.Event()
    second_lock_attempted = threading.Event()
    guard = threading.Lock()
    real_probe = scheduler_module.probe_quota
    real_provider_lock = scheduler_module.provider_selection_refresh_lock
    probe_calls = 0
    lock_attempts = 0
    active_probes = 0
    maximum_active_probes = 0

    def blocked_quota_probe(*args, **kwargs):
        nonlocal active_probes, maximum_active_probes, probe_calls
        with guard:
            probe_calls += 1
            call_number = probe_calls
            active_probes += 1
            maximum_active_probes = max(maximum_active_probes, active_probes)
        try:
            if call_number == 1:
                first_probe_entered.set()
                assert release_first_probe.wait(timeout=10)
            return real_probe(*args, **kwargs)
        finally:
            with guard:
                active_probes -= 1

    def observed_provider_lock(*args, **kwargs):
        nonlocal lock_attempts
        with guard:
            lock_attempts += 1
            if lock_attempts == 2:
                second_lock_attempted.set()
        return real_provider_lock(*args, **kwargs)

    monkeypatch.setattr(scheduler_module, "probe_quota", blocked_quota_probe)
    monkeypatch.setattr(
        scheduler_module,
        "provider_selection_refresh_lock",
        observed_provider_lock,
    )
    outcomes: dict[str, dict[str, object]] = {}

    def select(task: str) -> None:
        try:
            outcomes[task] = {
                "result": select_and_acquire(
                    registry,
                    task=task,
                    pool="claude-crew",
                    profile_id="claude-1",
                    dry_run=True,
                    workspace=Path.cwd(),
                )
            }
        except ValueError as exc:
            outcomes[task] = {"error": str(exc)}

    first = threading.Thread(target=select, args=("dry-run-one",))
    second = threading.Thread(target=select, args=("dry-run-two",))
    first.start()
    assert first_probe_entered.wait(timeout=10)
    second.start()
    assert second_lock_attempted.wait(timeout=10)
    with guard:
        assert probe_calls == 1
        assert maximum_active_probes == 1
    release_first_probe.set()
    first.join(timeout=10)
    second.join(timeout=10)

    assert not first.is_alive()
    assert not second.is_alive()
    assert set(outcomes) == {"dry-run-one", "dry-run-two"}
    assert all("error" not in outcome for outcome in outcomes.values())
    assert all(
        outcome["result"]["profile"] == "claude-1"
        for outcome in outcomes.values()
    )
    assert probe_calls == 2
    assert maximum_active_probes == 1


def test_duplicate_remote_identity_is_fail_closed(
    fleet: tuple[object, Path], monkeypatch, tmp_path: Path
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, ["codex-1", "codex-2"])
    fixtures = tmp_path / "quota"
    fixtures.mkdir()
    for profile_id in ("codex-1", "codex-2"):
        (fixtures / f"{profile_id}.json").write_text(
            json.dumps(
                {
                    "providers": [
                        {
                            "provider": "codex",
                            "account": {"accountId": "same-account"},
                            "state": {
                                "status": "fresh",
                                "refreshedAt": datetime.now(UTC).isoformat(),
                            },
                            "windows": [
                                {
                                    "id": "five_hour",
                                    "kind": "session",
                                    "percentRemaining": 80,
                                }
                            ],
                        }
                    ]
                }
            ),
            encoding="utf-8",
        )
    _use_quota_fixtures(registry, fixtures)
    for profile_id in ("codex-1", "codex-2"):
        refresh_quota(registry, registry.require_profile(profile_id))

    with pytest.raises(ValueError, match="duplicate_provider_identity"):
        select_and_acquire(
            registry,
            task="duplicate-account",
            pool="codex-crew",
            provider="codex",
            workspace=Path.cwd(),
        )


def test_interactive_claude_verification_explicitly_allows_keychain_prompt(
    fleet: tuple[object, Path], monkeypatch, tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    argv_log = tmp_path / "argv.json"
    node, binary, tree_digest = _sealed_quota_runtime(
        tmp_path / "custom-quota-release",
        """#!/usr/bin/env python3
import json
import os
import sys
from datetime import UTC, datetime
with open(os.environ["ARGV_LOG"], "w", encoding="utf-8") as handle:
    json.dump(sys.argv[1:], handle)
print(json.dumps({
    "providers": [{
        "provider": "claude",
        "account": {"accountId": "claude-1-account"},
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
    )
    registry = _with_quota_runtime(registry, node, binary, tree_digest)
    monkeypatch.setenv("ARGV_LOG", str(argv_log))

    refresh_quota(
        registry,
        registry.require_profile("claude-1"),
        allow_keychain_prompt=True,
    )

    assert "--allow-keychain-prompt" in json.loads(argv_log.read_text(encoding="utf-8"))


def test_production_quota_probe_ignores_legacy_fixture_environment(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    fixtures = tmp_path / "untrusted-fixtures"
    fixtures.mkdir()
    (fixtures / "codex-1.json").write_text(
        json.dumps({"schema": 1, "profile": "codex-1", "status": "fresh"}),
        encoding="utf-8",
    )
    monkeypatch.setenv("AGENT_FLEET_QUOTA_FIXTURE_DIR", str(fixtures))

    quota = refresh_quota(registry, registry.require_profile("codex-1"))

    assert quota["headroom_percent"] == 80
    assert quota["identity_fingerprint"] is not None


def test_quota_probe_scrubs_ambient_node_and_npm_injection(
    fleet: tuple[object, Path], monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    _, config = fleet
    registry = load_registry(config)
    sentinel = tmp_path / "node-options-executed"
    node_source = f"""#!{sys.executable}
import os
from pathlib import Path
import sys

if os.environ.get("PATH") != "/usr/bin:/bin:/usr/sbin:/sbin" or any(
    name.startswith("NODE_")
    or name.startswith("DYLD_")
    or name.startswith("LD_")
    or name.startswith("PYTHON")
    or name.lower().startswith("npm_config_")
    or (name.startswith("AGENT_FLEET_") and name not in {{
        "AGENT_FLEET_PROFILE", "AGENT_FLEET_PROVIDER"
    }})
    or name.startswith("QUOTA_AXI_") and name != "QUOTA_AXI_CODEX_BINARY"
    or name in {{
        "BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "PERL5OPT", "PERLLIB",
        "RUBYOPT", "RUBYLIB", "ELECTRON_RUN_AS_NODE", "INIT_CWD", "BROWSER",
        "GIT_ASKPASS", "HTTP_PROXY",
    }}
    for name in os.environ
):
    Path({str(sentinel)!r}).write_text("ambient runtime injection survived", encoding="utf-8")
os.execv(sys.executable, [sys.executable, *sys.argv[1:]])
"""
    release_root = registry.settings.quota_binary.parent.parent
    original_quota = (
        release_root / "node_modules" / "quota-axi" / "dist" / "bin" / "quota-axi.js"
    ).read_text(encoding="utf-8")
    node, quota, tree_digest = _sealed_quota_runtime(
        tmp_path / "custom-quota-release",
        original_quota,
        node_source=node_source,
    )
    registry = _with_quota_runtime(registry, node, quota, tree_digest)
    preload = tmp_path / "evil.js"
    preload.write_text(
        f"require('fs').writeFileSync({str(sentinel)!r}, 'executed');\n",
        encoding="utf-8",
    )
    monkeypatch.setenv("NODE_OPTIONS", f"--require={preload}")
    monkeypatch.setenv("NODE_PATH", str(tmp_path / "modules"))
    monkeypatch.setenv("NPM_CONFIG_USERCONFIG", str(tmp_path / "npmrc"))
    monkeypatch.setenv("npm_config_cache", str(tmp_path / "npm-cache"))
    monkeypatch.setenv("INIT_CWD", str(tmp_path))
    monkeypatch.setenv("DYLD_INSERT_LIBRARIES", str(tmp_path / "evil.dylib"))
    monkeypatch.setenv("BASH_ENV", str(tmp_path / "bash-env"))
    monkeypatch.setenv("PYTHONPATH", str(tmp_path / "python"))
    monkeypatch.setenv("AGENT_FLEET_ROGUE", "poison")
    monkeypatch.setenv("AGENT_FLEET_STATE_DIR", str(tmp_path / "poison-state"))
    monkeypatch.setenv("QUOTA_AXI_FAKE", "poison")
    monkeypatch.setenv("BROWSER", "poison")
    monkeypatch.setenv("GIT_ASKPASS", "poison")
    monkeypatch.setenv("HTTP_PROXY", "http://poison.invalid")
    hostile_bin = tmp_path / "hostile-bin"
    hostile_bin.mkdir()
    fake_security = hostile_bin / "security"
    fake_security.write_text(
        f"#!/bin/sh\nprintf ran > {str(sentinel)!r}\n",
        encoding="utf-8",
    )
    fake_security.chmod(0o755)
    monkeypatch.setenv("PATH", f"{hostile_bin}:{os.environ.get('PATH', '')}")

    quota = refresh_quota(registry, registry.require_profile("codex-1"))

    assert quota["status"] == "fresh"
    assert not sentinel.exists()


@pytest.mark.parametrize("mutation", ["disable", "remove", "revoke-project"])
def test_registry_change_during_selection_cannot_commit_a_stale_lease(
    fleet: tuple[object, Path],
    monkeypatch: pytest.MonkeyPatch,
    mutation: str,
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, ["codex-1"])
    entered = threading.Event()
    proceed = threading.Event()
    original_external_probe = scheduler_module.probe_provider_external_observation

    def blocked_external_probe(current, provider: str):
        entered.set()
        assert proceed.wait(timeout=10)
        return original_external_probe(current, provider)

    monkeypatch.setattr(
        scheduler_module,
        "probe_provider_external_observation",
        blocked_external_probe,
    )
    outcome: dict[str, object] = {}

    def select() -> None:
        try:
            outcome["result"] = select_and_acquire(
                registry,
                task=f"raced-{mutation}",
                pool="codex-crew",
                profile_id="codex-1",
                workspace=Path.cwd(),
                config_path=config,
            )
        except ValueError as exc:
            outcome["error"] = str(exc)

    worker = threading.Thread(target=select)
    worker.start()
    assert entered.wait(timeout=10)
    changed = load_registry(config)
    if mutation == "disable":
        profiles = dict(changed.profiles)
        profiles["codex-1"] = replace(profiles["codex-1"], enabled=False)
        changed = replace(changed, profiles=profiles)
    elif mutation == "remove":
        profiles = dict(changed.profiles)
        del profiles["codex-1"]
        changed = replace(changed, profiles=profiles)
    else:
        providers = dict(changed.providers)
        providers["codex"] = replace(providers["codex"], trusted_projects=())
        changed = replace(changed, providers=providers)
    save_registry(changed, config)
    proceed.set()
    worker.join(timeout=10)

    assert not worker.is_alive()
    assert outcome == {"error": "registry changed during selection; retry the lease request"}
    assert active_leases(registry) == []


def test_registry_change_before_provider_lock_aborts_before_refresh(
    fleet: tuple[object, Path],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, ["codex-1"])
    entered = threading.Event()
    proceed = threading.Event()
    events: list[str] = []
    original_load_registry = scheduler_module.load_registry

    @contextmanager
    def delayed_provider_lock(*_args, **_kwargs):
        entered.set()
        assert proceed.wait(timeout=10)
        yield

    def recorded_load_registry(path: Path):
        events.append("load")
        return original_load_registry(path)

    def unexpected(name: str, result=None):
        def record(*_args, **_kwargs):
            events.append(name)
            return result

        return record

    monkeypatch.setattr(
        scheduler_module,
        "provider_selection_refresh_lock",
        delayed_provider_lock,
    )
    monkeypatch.setattr(scheduler_module, "load_registry", recorded_load_registry)
    monkeypatch.setattr(
        scheduler_module,
        "resolve_trusted_project",
        unexpected("trusted-project"),
    )
    monkeypatch.setattr(
        scheduler_module,
        "profile_selection_ready",
        unexpected("readiness", True),
    )
    monkeypatch.setattr(
        scheduler_module,
        "recover_pending_codex_transactions",
        unexpected("recovery"),
    )
    monkeypatch.setattr(
        scheduler_module,
        "refresh_provider_identity_anchors_if_due",
        unexpected("identity"),
    )
    monkeypatch.setattr(scheduler_module, "probe_quota", unexpected("quota"))
    before_state = {
        path.relative_to(registry.settings.state_dir): path.read_bytes()
        for path in registry.settings.state_dir.rglob("*")
        if path.is_file()
    }
    outcome: dict[str, object] = {}

    def select() -> None:
        try:
            outcome["result"] = select_and_acquire(
                registry,
                task="pre-lock-registry-race",
                pool="codex-crew",
                profile_id="codex-1",
                workspace=Path.cwd(),
                config_path=config,
            )
        except ValueError as exc:
            outcome["error"] = str(exc)

    worker = threading.Thread(target=select)
    worker.start()
    assert entered.wait(timeout=10)
    changed = load_registry(config)
    profiles = dict(changed.profiles)
    profiles["codex-1"] = replace(profiles["codex-1"], enabled=False)
    save_registry(replace(changed, profiles=profiles), config)
    proceed.set()
    worker.join(timeout=10)

    assert not worker.is_alive()
    assert outcome == {"error": "registry changed before provider refresh; retry the lease request"}
    assert events == ["load"]
    after_state = {
        path.relative_to(registry.settings.state_dir): path.read_bytes()
        for path in registry.settings.state_dir.rglob("*")
        if path.is_file()
    }
    assert after_state == before_state
    assert active_leases(registry) == []


def test_concurrent_reservations_are_atomic_and_balanced(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, ["claude-1", "claude-2"])
    project_root = Path(__file__).parents[1]
    env = dict(os.environ)
    env["PYTHONPATH"] = str(project_root / "src")
    processes = [
        subprocess.Popen(
            [
                sys.executable,
                "-m",
                "agent_fleet",
                "--format",
                "json",
                "--config",
                str(config),
                "lease",
                "choose",
                "--task",
                f"concurrent-{index}",
                "--pool",
                "claude-crew",
                "--provider",
                "claude",
                "--workspace",
                str(Path.cwd()),
            ],
            cwd=Path.cwd(),
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        for index in range(12)
    ]
    results = [process.communicate(timeout=20) for process in processes]
    failures = [
        {"returncode": process.returncode, "stdout": stdout, "stderr": stderr}
        for process, (stdout, stderr) in zip(processes, results, strict=True)
        if process.returncode != 0
    ]
    assert failures == []
    leases = active_leases(registry)
    assert len(leases) == 12
    counts = {
        profile_id: sum(lease["profile"] == profile_id for lease in leases)
        for profile_id in ("claude-1", "claude-2")
    }
    assert abs(counts["claude-1"] - counts["claude-2"]) <= 1
