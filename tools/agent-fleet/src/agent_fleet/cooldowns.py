from __future__ import annotations

import math
import time
from pathlib import Path
from typing import Any

from .models import Registry
from .transaction_fence import assert_no_pending_credential_recovery
from .util import (
    atomic_write_json,
    read_private_json,
    unlink_private_file,
    utc_now,
    validate_id,
)


def cooldown_path(registry: Registry, profile_id: str) -> Path:
    return registry.settings.state_dir / "cooldowns" / f"{profile_id}.json"


def read_cooldown(registry: Registry, profile_id: str) -> dict[str, Any] | None:
    path = cooldown_path(registry, profile_id)
    try:
        value = read_private_json(path, label="cooldown state")
    except FileNotFoundError:
        return None
    if (
        not isinstance(value, dict)
        or set(value) != {"schema", "profile", "reason", "created_at", "expires_unix"}
        or value.get("schema") != 1
        or value.get("profile") != profile_id
        or not isinstance(value.get("reason"), str)
        or not value["reason"]
        or not isinstance(value.get("created_at"), str)
        or not value["created_at"]
    ):
        raise ValueError(f"corrupt cooldown state: {path}")
    expires = value.get("expires_unix")
    if (
        not isinstance(expires, (int, float))
        or isinstance(expires, bool)
        or not math.isfinite(float(expires))
    ):
        raise ValueError(f"corrupt cooldown state: {path}")
    if float(expires) <= time.time():
        return None
    return value


def set_cooldown(
    registry: Registry,
    profile_id: str,
    *,
    seconds: int,
    reason: str,
) -> dict[str, Any]:
    validate_id(profile_id, "profile id")
    profile = registry.require_profile(profile_id)
    assert_no_pending_credential_recovery(
        registry,
        {profile.provider},
        operation="routing cooldown mutation",
    )
    if seconds < 1 or seconds > 86_400:
        raise ValueError("cooldown seconds must be between 1 and 86400")
    if not reason or len(reason) > 128 or any(ord(char) < 32 for char in reason):
        raise ValueError("cooldown reason must be 1-128 printable characters")
    payload = {
        "schema": 1,
        "profile": profile_id,
        "reason": reason,
        "created_at": utc_now(),
        "expires_unix": time.time() + seconds,
    }
    atomic_write_json(cooldown_path(registry, profile_id), payload)
    return payload


def clear_cooldown(registry: Registry, profile_id: str) -> dict[str, Any]:
    profile = registry.require_profile(profile_id)
    assert_no_pending_credential_recovery(
        registry,
        {profile.provider},
        operation="routing cooldown mutation",
    )
    path = cooldown_path(registry, profile_id)
    existed = unlink_private_file(path, label="cooldown state")
    return {"profile": profile_id, "cooldown_cleared": existed}
