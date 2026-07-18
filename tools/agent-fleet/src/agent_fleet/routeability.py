from __future__ import annotations

from collections.abc import Callable, Iterable
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any

from .models import Profile, Registry
from .quota import (
    has_remote_identity_proof,
    inspect_credential_source_contract,
    probe_quota,
)


class LiveIdentityProofFailure(ValueError):
    pass


def _safe_proof_failure(quota: dict[str, Any]) -> str:
    reason = quota.get("reason")
    if (
        isinstance(reason, str)
        and 0 < len(reason) <= 128
        and all(character.isalnum() or character in "_.:-" for character in reason)
    ):
        return reason
    return "fresh_remote_identity_proof_unavailable"


def source_attested_live_proof(
    registry: Registry,
    profile: Profile,
    *,
    probe: Callable[[Registry, Profile], dict[str, Any]] = probe_quota,
) -> tuple[dict[str, Any], dict[str, Any]]:
    try:
        source_before = inspect_credential_source_contract(registry, profile)
    except (OSError, TimeoutError, ValueError) as exc:
        raise LiveIdentityProofFailure("credential_source_unverified") from exc
    quota = probe(registry, profile)
    try:
        source_after = inspect_credential_source_contract(registry, profile)
    except (OSError, TimeoutError, ValueError) as exc:
        raise LiveIdentityProofFailure("credential_source_unverified") from exc
    if source_before != source_after:
        raise LiveIdentityProofFailure("credential_source_changed")
    if not has_remote_identity_proof(quota):
        raise LiveIdentityProofFailure(_safe_proof_failure(quota))
    return quota, source_after


def live_quota_view(quota: dict[str, Any]) -> dict[str, Any]:
    """Add read-time freshness fields without writing the live proof to cache."""

    return {
        **quota,
        "age_seconds": 0,
        "verification_age_seconds": 0,
        "verified_recent": True,
        "fresh": True,
    }


def source_attested_live_proofs(
    registry: Registry,
    profiles: Iterable[Profile],
    *,
    probe: Callable[[Registry, Profile], dict[str, Any]] = probe_quota,
) -> tuple[dict[str, dict[str, Any]], dict[str, str]]:
    scoped = list(profiles)
    proofs: dict[str, dict[str, Any]] = {}
    failures: dict[str, str] = {}
    if not scoped:
        return proofs, failures
    with ThreadPoolExecutor(max_workers=min(8, len(scoped))) as executor:
        pending = {
            executor.submit(
                source_attested_live_proof,
                registry,
                profile,
                probe=probe,
            ): profile
            for profile in scoped
        }
        for future in as_completed(pending):
            profile = pending[future]
            try:
                quota, source_contract = future.result()
            except (OSError, TimeoutError, ValueError) as exc:
                failures[profile.id] = (
                    str(exc)
                    if isinstance(exc, LiveIdentityProofFailure)
                    else type(exc).__name__
                )
            else:
                proofs[profile.id] = {
                    "quota": live_quota_view(quota),
                    "stored_quota": quota,
                    "source_contract": source_contract,
                }
    return proofs, failures
