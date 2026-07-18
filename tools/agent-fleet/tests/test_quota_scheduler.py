from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import threading
from dataclasses import replace
from datetime import UTC, datetime
from pathlib import Path

import pytest

import agent_fleet.scheduler as scheduler_module
from agent_fleet.config import load_registry, save_registry
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
                            "account": {"accountId": account},
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
    registry.settings.quota_binary.with_name("quota-fixture-dir").write_text(
        str(fixtures), encoding="utf-8"
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
            "session_id": "sticky-session",
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
        check=True,
    )
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
    binary = tmp_path / "quota-axi"
    binary.write_text(
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
        encoding="utf-8",
    )
    binary.chmod(binary.stat().st_mode | stat.S_IXUSR)
    registry = replace(
        registry,
        settings=replace(registry.settings, quota_binary=binary),
    )

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


def test_verified_stale_fallback_has_a_bounded_grace(
    fleet: tuple[object, Path], monkeypatch, tmp_path: Path
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
    assert selected["decision_reason"] == "verified-fallback"

    cached["verified_at"] = "2000-01-01T00:00:00+00:00"
    atomic_write_json(quota_path(registry, "claude-1"), cached)
    with pytest.raises(ValueError, match="remote_verification_expired"):
        select_and_acquire(
            registry,
            task="expired-proof",
            pool="claude-crew",
            profile_id="claude-1",
            dry_run=True,
            workspace=Path.cwd(),
        )


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
    binary = tmp_path / "quota-axi"
    binary.write_text(
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
        encoding="utf-8",
    )
    binary.chmod(binary.stat().st_mode | stat.S_IXUSR)
    registry = replace(
        registry,
        settings=replace(registry.settings, quota_binary=binary),
    )
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
    original_auth_status = scheduler_module.auth_status

    def blocked_auth_status(current_registry, profile):
        entered.set()
        assert proceed.wait(timeout=10)
        return original_auth_status(current_registry, profile)

    monkeypatch.setattr(scheduler_module, "auth_status", blocked_auth_status)
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
