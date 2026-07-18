from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
from dataclasses import replace
from datetime import UTC, datetime
from pathlib import Path

import pytest

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


def test_fresh_quota_selects_best_safe_profile(
    fleet: tuple[object, Path], monkeypatch, tmp_path: Path
) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, ["codex-1", "codex-2"])
    fixtures = tmp_path / "quota"
    fixtures.mkdir()
    _quota_fixture(fixtures / "codex-1.json", "codex", 82)
    _quota_fixture(fixtures / "codex-2.json", "codex", 37)
    monkeypatch.setenv("AGENT_FLEET_QUOTA_FIXTURE_DIR", str(fixtures))
    for profile_id in ("codex-1", "codex-2"):
        refresh_quota(registry, registry.require_profile(profile_id))

    selected = select_and_acquire(registry, task="quota-task", pool="codex-crew", provider="codex")
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
    monkeypatch.setenv("AGENT_FLEET_QUOTA_FIXTURE_DIR", str(fixtures))
    for profile_id in ("claude-1", "claude-2"):
        refresh_quota(registry, registry.require_profile(profile_id))

    selected = select_and_acquire(
        registry, task="reserve-task", pool="claude-crew", provider="claude"
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
    monkeypatch.setenv("AGENT_FLEET_QUOTA_FIXTURE_DIR", str(fixtures))
    refresh_quota(registry, registry.require_profile("codex-1"))

    with pytest.raises(ValueError, match="quota reserve"):
        select_and_acquire(
            registry,
            task="new-task",
            pool="codex-crew",
            provider="codex",
            profile_id="codex-1",
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
        ],
        cwd=project_root,
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
    )
    with pytest.raises(ValueError, match="live worker lease"):
        select_and_acquire(
            registry,
            task="resumed-task",
            pool="codex-crew",
            profile_id="codex-1",
            ignore_reserve=True,
            recovery_reservation=True,
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
    )
    assert selected["dry_run"] is True
    assert selected["lease"] is None
    assert active_leases(registry) == []
    assert not (registry.settings.state_dir / "selection.json").exists()


def test_cooldown_excludes_profile(fleet: tuple[object, Path]) -> None:
    _, config = fleet
    registry = _enable_and_provision(load_registry(config), config, ["codex-1", "codex-2"])
    set_cooldown(registry, "codex-1", seconds=60, reason="spawn-failure")
    selected = select_and_acquire(
        registry,
        task="cooldown-task",
        pool="codex-crew",
        provider="codex",
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
    monkeypatch.setenv("AGENT_FLEET_QUOTA_FIXTURE_DIR", str(fixtures))

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
    monkeypatch.setenv("AGENT_FLEET_QUOTA_FIXTURE_DIR", str(fixtures))
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
    monkeypatch.setenv("AGENT_FLEET_QUOTA_FIXTURE_DIR", str(fixtures))
    for profile_id in ("codex-1", "codex-2"):
        refresh_quota(registry, registry.require_profile(profile_id))

    with pytest.raises(ValueError, match="duplicate_provider_identity"):
        select_and_acquire(
            registry,
            task="duplicate-account",
            pool="codex-crew",
            provider="codex",
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
            ],
            cwd=project_root,
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
