from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

from .models import Registry
from .util import atomic_write_json, utc_now, validate_id


def cooldown_path(registry: Registry, profile_id: str) -> Path:
    return registry.settings.state_dir / "cooldowns" / f"{profile_id}.json"


def read_cooldown(registry: Registry, profile_id: str) -> dict[str, Any] | None:
    path = cooldown_path(registry, profile_id)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(value, dict) or value.get("profile") != profile_id:
        return None
    expires = value.get("expires_unix")
    if not isinstance(expires, (int, float)) or float(expires) <= time.time():
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
    path = cooldown_path(registry, profile_id)
    existed = path.exists()
    path.unlink(missing_ok=True)
    return {"profile": profile_id, "cooldown_cleared": existed}
