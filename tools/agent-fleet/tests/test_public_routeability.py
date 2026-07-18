from __future__ import annotations

import json
import threading
import time
from dataclasses import replace
from datetime import UTC, datetime
from pathlib import Path

import agent_fleet.status as status_module
from agent_fleet.config import load_registry
from agent_fleet.status import pool_status, profile_status
from agent_fleet.util import atomic_write_json


def _enabled_worker(config: Path, profile_id: str):
    registry = load_registry(config)
    profiles = dict(registry.profiles)
    profiles[profile_id] = replace(profiles[profile_id], enabled=True)
    return replace(registry, profiles=profiles)


def _live_quota_fixture(
    root: Path,
    *,
    profile_id: str,
    provider: str,
    status: str,
    account_id: str,
) -> Path:
    root.mkdir()
    (root / f"{profile_id}.json").write_text(
        json.dumps(
            {
                "providers": [
                    {
                        "provider": provider,
                        "account": {"accountId": account_id},
                        "state": {
                            "status": status,
                            "refreshedAt": datetime.now(UTC).isoformat(),
                        },
                        "windows": [
                            {
                                "id": "five_hour",
                                "kind": "session",
                                "percentRemaining": 70,
                            }
                        ],
                    }
                ]
            }
        ),
        encoding="utf-8",
    )
    return root


def _profile(summary: dict, profile_id: str) -> dict:
    return next(item for item in summary["profiles"] if item["profile"] == profile_id)


def test_pool_status_keeps_stale_live_proof_diagnostic_only(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    _, config = fleet
    registry = _enabled_worker(config, "codex-1")
    fixtures = _live_quota_fixture(
        tmp_path / "quota",
        profile_id="codex-1",
        provider="codex",
        status="stale",
        account_id="codex-1-account",
    )
    (registry.settings.state_dir / "test-quota-fixture-dir").write_text(
        str(fixtures), encoding="utf-8"
    )

    summary = pool_status(
        registry,
        pool="codex-crew",
        provider="codex",
    )["providers"][0]
    profile = _profile(summary, "codex-1")

    assert summary["available"] is False
    assert summary["selection_mode"] == "unavailable"
    assert summary["degraded"] is False
    assert summary["eligible_profiles"] == 0
    assert profile["eligible"] is False
    assert profile["quota_fresh"] is False
    assert profile["cached_quota_fresh"] is True
    assert profile["quota_status"] == "fresh"
    assert profile["live_identity_failure"] == "fresh_remote_identity_proof_unavailable"
    assert profile["routeability_reason"].startswith("fresh_live_identity_proof_required:")
    detail = profile_status(registry, "codex-1")
    assert detail["routeability"]["eligible"] is False
    assert detail["live_identity_failure"] == "fresh_remote_identity_proof_unavailable"


def test_pool_status_surfaces_durable_identity_binding_conflict(
    fleet: tuple[object, Path], tmp_path: Path
) -> None:
    _, config = fleet
    registry = _enabled_worker(config, "codex-1")
    fixtures = _live_quota_fixture(
        tmp_path / "quota",
        profile_id="codex-1",
        provider="codex",
        status="fresh",
        account_id="replacement-account",
    )
    (registry.settings.state_dir / "test-quota-fixture-dir").write_text(
        str(fixtures), encoding="utf-8"
    )

    summary = pool_status(
        registry,
        pool="codex-crew",
        provider="codex",
    )["providers"][0]
    profile = _profile(summary, "codex-1")

    assert summary["available"] is False
    assert summary["identity_binding_conflicts"] == {
        "codex-1": "identity_binding_remote_mismatch"
    }
    assert profile["quota_fresh"] is True
    assert profile["identity_binding_conflict"] == "identity_binding_remote_mismatch"
    assert profile["eligible"] is False
    assert profile["routeability_reason"] == "identity_binding_remote_mismatch"
    detail = profile_status(registry, "codex-1")
    assert detail["identity_binding_conflict"] == "identity_binding_remote_mismatch"
    assert detail["routeability"]["eligible"] is False


def test_public_status_uses_fresh_external_observation_when_anchor_is_stale(
    fleet: tuple[object, Path],
) -> None:
    _, config = fleet
    registry = _enabled_worker(config, "claude-1")
    anchor_path = registry.settings.state_dir / "identity-anchors" / "claude-base.json"
    stale_anchor = json.loads(anchor_path.read_text(encoding="utf-8"))
    stale_anchor["refreshed_at"] = "2000-01-01T00:00:00+00:00"
    atomic_write_json(anchor_path, stale_anchor)

    summary = pool_status(
        registry,
        pool="claude-crew",
        provider="claude",
    )["providers"][0]
    profile = _profile(summary, "claude-1")
    detail = profile_status(registry, "claude-1")

    assert summary["available"] is True
    assert summary["selection_mode"] == "quota"
    assert profile["eligible"] is True
    assert detail["routeability"]["eligible"] is True
    assert json.loads(anchor_path.read_text(encoding="utf-8")) == stale_anchor


def test_concurrent_public_status_proofs_are_provider_serialized(
    fleet: tuple[object, Path], monkeypatch
) -> None:
    _, config = fleet
    registry = _enabled_worker(config, "claude-1")
    first_probe_entered = threading.Event()
    release_first_probe = threading.Event()
    second_lock_attempted = threading.Event()
    guard = threading.Lock()
    real_proofs = status_module.source_attested_live_proofs
    real_provider_lock = status_module.provider_selection_refresh_lock
    proof_calls = 0
    lock_attempts = 0
    active_proofs = 0
    maximum_active_proofs = 0

    def blocked_proofs(*args, **kwargs):
        nonlocal active_proofs, maximum_active_proofs, proof_calls
        with guard:
            proof_calls += 1
            call_number = proof_calls
            active_proofs += 1
            maximum_active_proofs = max(maximum_active_proofs, active_proofs)
        try:
            if call_number == 1:
                first_probe_entered.set()
                assert release_first_probe.wait(timeout=10)
            return real_proofs(*args, **kwargs)
        finally:
            with guard:
                active_proofs -= 1

    def observed_provider_lock(*args, **kwargs):
        nonlocal lock_attempts
        with guard:
            lock_attempts += 1
            if lock_attempts == 2:
                second_lock_attempted.set()
        return real_provider_lock(*args, **kwargs)

    monkeypatch.setattr(status_module, "source_attested_live_proofs", blocked_proofs)
    monkeypatch.setattr(
        status_module,
        "provider_selection_refresh_lock",
        observed_provider_lock,
    )
    outcomes: dict[str, dict] = {}

    def inspect(name: str) -> None:
        try:
            outcomes[name] = pool_status(
                registry,
                pool="claude-crew",
                provider="claude",
            )["providers"][0]
        except ValueError as exc:
            outcomes[name] = {"error": str(exc)}

    first = threading.Thread(target=inspect, args=("first",))
    second = threading.Thread(target=inspect, args=("second",))
    first.start()
    assert first_probe_entered.wait(timeout=10)
    second.start()
    assert second_lock_attempted.wait(timeout=10)
    with guard:
        assert proof_calls == 1
        assert maximum_active_proofs == 1
    release_first_probe.set()
    first.join(timeout=10)
    second.join(timeout=10)

    assert not first.is_alive()
    assert not second.is_alive()
    assert all(summary.get("available") is True for summary in outcomes.values())
    assert proof_calls == 2
    assert maximum_active_proofs == 1


def test_external_reserve_status_does_not_probe_provider(
    fleet: tuple[object, Path], monkeypatch
) -> None:
    registry, _ = fleet
    profiles = dict(registry.profiles)
    profiles["claude-1"] = replace(
        profiles["claude-1"],
        enabled=False,
        pools=("claude-desktop-reserve",),
        safety_policy="desktop_shared",
    )
    registry = replace(registry, profiles=profiles)

    def unexpected(*_args, **_kwargs):
        raise AssertionError("external reserve status must not invoke a provider")

    for name in (
        "provider_selection_refresh_lock",
        "source_attested_live_proofs",
        "probe_provider_external_observation",
    ):
        monkeypatch.setattr(status_module, name, unexpected)

    detail = profile_status(registry, "claude-1")
    summary = pool_status(
        registry,
        pool="claude-desktop-reserve",
        provider="claude",
    )["providers"][0]

    assert detail["auth_status"] == "external-reserve"
    assert detail["routeability"]["reason"] == "external_reserve_never_routed"
    assert summary["available"] is False
    assert summary["profiles"][0]["routeability"]["reason"] == (
        "external_reserve_never_routed"
    )


def test_public_status_does_not_run_redundant_provider_auth(
    fleet: tuple[object, Path], monkeypatch
) -> None:
    _, config = fleet
    registry = _enabled_worker(config, "claude-1")
    auth_calls: list[str] = []

    def slow_auth(*_args, **_kwargs):
        auth_calls.append("called")
        time.sleep(6)
        return "authenticated"

    monkeypatch.setattr(status_module, "auth_status", slow_auth, raising=False)
    started = time.monotonic()
    summary = pool_status(
        registry,
        pool="claude-crew",
        provider="claude",
    )["providers"][0]
    elapsed = time.monotonic() - started

    assert summary["available"] is True
    assert auth_calls == []
    assert elapsed < 5
