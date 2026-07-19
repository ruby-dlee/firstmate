from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from .models import Registry
from .paths import open_private_dir
from .util import SAFE_ID, read_private_json


def credential_recovery_journal_root(registry: Registry) -> Path:
    return registry.settings.state_dir / "transactions" / "credential-recovery"


def pending_credential_recovery_journals(
    registry: Registry,
) -> tuple[tuple[Path, dict[str, Any]], ...]:
    """Discover durable journals without trusting the current worker topology."""

    root = credential_recovery_journal_root(registry)
    try:
        descriptor = open_private_dir(root)
    except FileNotFoundError:
        return ()
    else:
        os.close(descriptor)

    pending: list[tuple[Path, dict[str, Any]]] = []
    for path in sorted(root.glob("*.json"), key=lambda candidate: candidate.name):
        payload = read_private_json(path, label="credential recovery journal fence")
        if not isinstance(payload, dict):
            raise ValueError(f"invalid pending credential recovery journal: {path}")
        provider = payload.get("provider")
        profile = payload.get("profile")
        if (
            payload.get("schema") != 1
            or payload.get("kind") != "credential-recovery"
            or not isinstance(provider, str)
            or SAFE_ID.fullmatch(provider) is None
            or not isinstance(profile, str)
            or SAFE_ID.fullmatch(profile) is None
            or payload.get("journal") != str(path)
            or path.name != f"{provider}-{profile}.json"
        ):
            raise ValueError(f"invalid pending credential recovery journal: {path}")
        pending.append((path, payload))
    return tuple(pending)


def assert_no_pending_credential_recovery(
    registry: Registry,
    providers: set[str] | None = None,
    *,
    operation: str,
) -> None:
    matching = [
        payload
        for _path, payload in pending_credential_recovery_journals(registry)
        if providers is None or payload["provider"] in providers
    ]
    if not matching:
        return
    labels = ", ".join(
        sorted(f"{payload['provider']}:{payload['profile']}" for payload in matching)
    )
    raise ValueError(
        f"pending credential recovery blocks {operation}: {labels}; "
        "run the matching explicit recover-login or initialize-login command first"
    )
