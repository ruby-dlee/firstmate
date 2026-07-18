from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any

from .audit import append_audit
from .leases import get_active_lease
from .locks import state_lock
from .models import Registry
from .util import atomic_write_json, task_key, utc_now, validate_id

SESSION_KEYS = ("session_id", "sessionId")


def session_path(registry: Registry, task: str) -> Path:
    return registry.settings.state_dir / "sessions" / f"{task_key(task)}.json"


def _find_session_id(value: Any) -> str | None:
    if isinstance(value, dict):
        for key in SESSION_KEYS:
            item = value.get(key)
            if isinstance(item, str) and item:
                return item
        for item in value.values():
            found = _find_session_id(item)
            if found:
                return found
    elif isinstance(value, list):
        for item in value:
            found = _find_session_id(item)
            if found:
                return found
    return None


def record_session_from_hook(registry: Registry, payload: dict[str, Any]) -> dict[str, Any]:
    task = os.environ.get("AGENT_FLEET_TASK_ID")
    profile_id = os.environ.get("AGENT_FLEET_PROFILE")
    provider = os.environ.get("AGENT_FLEET_PROVIDER")
    if not task or not profile_id or not provider:
        return {"recorded": False, "reason": "not_agent_fleet_launch"}
    session_id = _find_session_id(payload)
    if session_id is None:
        raise ValueError("SessionStart hook payload did not contain a session id")
    validate_id(session_id, "session id")
    profile = registry.require_profile(profile_id)
    if profile.provider != provider:
        raise ValueError("hook provider does not match registered profile")
    with state_lock(
        registry.settings.state_dir,
        registry.settings.lock_stale_seconds,
    ):
        lease = get_active_lease(registry, task)
        if lease is None or lease.get("profile") != profile.id:
            raise ValueError("hook task does not own a live lease for this profile")
        mapping = {
            "schema": 1,
            "task": task,
            "profile": profile.id,
            "provider": profile.provider,
            "pool": lease.get("pool"),
            "session_id": session_id,
            "updated_at": utc_now(),
        }
        atomic_write_json(session_path(registry, task), mapping)
        append_audit(
            registry,
            "session-recorded",
            {
                "task_key": task_key(task),
                "profile": profile.id,
                "provider": profile.provider,
                "pool": lease.get("pool"),
            },
        )
    return {
        "recorded": True,
        "task": task,
        "profile": profile.id,
        "provider": profile.provider,
    }


def read_hook_payload() -> dict[str, Any]:
    try:
        value = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        raise ValueError("SessionStart hook input is not valid JSON") from exc
    if not isinstance(value, dict):
        raise ValueError("SessionStart hook input must be a JSON object")
    return value


def get_session(registry: Registry, task: str) -> dict[str, Any]:
    path = session_path(registry, task)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ValueError(f"no recorded provider session for task: {task}") from exc
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid session mapping: {path}") from exc
    if not isinstance(value, dict) or value.get("task") != task:
        raise ValueError(f"corrupt session mapping: {path}")
    return value


def remove_session(registry: Registry, task: str) -> dict[str, Any]:
    mapping = get_session(registry, task)
    session_path(registry, task).unlink()
    append_audit(
        registry,
        "session-removed",
        {
            "task_key": task_key(task),
            "profile": mapping.get("profile"),
            "provider": mapping.get("provider"),
            "pool": mapping.get("pool"),
        },
    )
    return {
        "task": task,
        "profile": mapping.get("profile"),
        "provider": mapping.get("provider"),
        "removed": True,
    }
