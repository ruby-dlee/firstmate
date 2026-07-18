from __future__ import annotations

import json
import os
import re
import stat
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

from .audit import append_audit
from .leases import get_active_lease
from .locks import state_lock
from .models import Registry
from .projects import lexical_path
from .util import (
    atomic_write_json,
    read_private_json,
    task_key,
    unlink_private_file,
    utc_now,
    validate_id,
)

SESSION_KEYS = ("session_id", "sessionId")
UTC_TIMESTAMP = re.compile(
    r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
    r"(?:\.[0-9]+)?(?:Z|\+00:00)\Z"
)


def validate_turn_end_path(path: Path) -> Path:
    exact = lexical_path(path)
    if str(exact) != str(path) or not exact.name.endswith(".turn-ended"):
        raise ValueError("turn-end marker must be an exact absolute .turn-ended path")
    try:
        parent = exact.parent.lstat()
    except OSError as exc:
        raise ValueError("turn-end marker parent is unavailable") from exc
    if (
        not stat.S_ISDIR(parent.st_mode)
        or parent.st_uid != os.getuid()
        or stat.S_IMODE(parent.st_mode) & 0o022
        or exact.parent.resolve() != exact.parent
    ):
        raise ValueError("turn-end marker parent must be a private current-user directory")
    try:
        current = exact.lstat()
    except FileNotFoundError:
        return exact
    if (
        not stat.S_ISREG(current.st_mode)
        or current.st_uid != os.getuid()
        or stat.S_IMODE(current.st_mode) != 0o600
        or current.st_nlink != 1
    ):
        raise ValueError("turn-end marker must be a safe current-user regular file")
    return exact


def _touch_turn_end(path: Path) -> None:
    expected_parent = path.parent.lstat()
    flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    parent_fd = os.open(path.parent, flags)
    try:
        opened_parent = os.fstat(parent_fd)
        if (
            not stat.S_ISDIR(opened_parent.st_mode)
            or opened_parent.st_uid != os.getuid()
            or stat.S_IMODE(opened_parent.st_mode) & 0o022
            or (opened_parent.st_dev, opened_parent.st_ino)
            != (expected_parent.st_dev, expected_parent.st_ino)
        ):
            raise ValueError("turn-end marker parent changed before signal")
        file_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            file_flags |= os.O_NOFOLLOW
        created = False
        try:
            descriptor = os.open(path.name, file_flags, 0o600, dir_fd=parent_fd)
            created = True
        except FileExistsError:
            file_flags = os.O_WRONLY
            if hasattr(os, "O_NOFOLLOW"):
                file_flags |= os.O_NOFOLLOW
            descriptor = os.open(path.name, file_flags, dir_fd=parent_fd)
        try:
            if created:
                os.fchmod(descriptor, 0o600)
            opened = os.fstat(descriptor)
            current = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
            if (
                not stat.S_ISREG(opened.st_mode)
                or opened.st_uid != os.getuid()
                or stat.S_IMODE(opened.st_mode) != 0o600
                or opened.st_nlink != 1
                or (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino)
            ):
                raise ValueError("turn-end marker changed before signal")
            os.utime(descriptor, None)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        os.fsync(parent_fd)
    finally:
        os.close(parent_fd)


def session_path(registry: Registry, task: str) -> Path:
    return registry.settings.state_dir / "sessions" / f"{task_key(task)}.json"


def _collect_session_ids(value: Any, found: set[str]) -> None:
    if isinstance(value, dict):
        for key in SESSION_KEYS:
            if key not in value:
                continue
            item = value[key]
            if not isinstance(item, str) or not item:
                raise ValueError("SessionStart hook payload contains an invalid session id")
            found.add(item)
        for key, item in value.items():
            if key not in SESSION_KEYS:
                _collect_session_ids(item, found)
    elif isinstance(value, list):
        for item in value:
            _collect_session_ids(item, found)


def _find_session_id(value: Any) -> str:
    found: set[str] = set()
    _collect_session_ids(value, found)
    if not found:
        raise ValueError("SessionStart hook payload did not contain a session id")
    if len(found) != 1:
        raise ValueError("SessionStart hook payload contained multiple session ids")
    return next(iter(found))


def _valid_timestamp(value: Any) -> bool:
    if not isinstance(value, str) or UTC_TIMESTAMP.fullmatch(value) is None:
        return False
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return False
    return parsed.tzinfo is not None and parsed.utcoffset() is not None and not parsed.utcoffset()


def record_session_from_hook(registry: Registry, payload: dict[str, Any]) -> dict[str, Any]:
    task = os.environ.get("AGENT_FLEET_TASK_ID")
    profile_id = os.environ.get("AGENT_FLEET_PROFILE")
    provider = os.environ.get("AGENT_FLEET_PROVIDER")
    pool = os.environ.get("AGENT_FLEET_POOL")
    workspace = os.environ.get("AGENT_FLEET_WORKSPACE")
    turn_end = os.environ.get("AGENT_FLEET_TURN_END")
    if not task or not profile_id or not provider or not pool or not workspace or not turn_end:
        return {"recorded": False, "reason": "not_agent_fleet_launch"}
    session_id = _find_session_id(payload)
    validate_id(session_id, "session id")
    validate_id(pool, "pool id")
    exact_workspace = lexical_path(Path(workspace))
    if str(exact_workspace) != workspace:
        raise ValueError("hook workspace must be an exact absolute path")
    exact_turn_end = validate_turn_end_path(Path(turn_end))
    profile = registry.require_profile(profile_id)
    if profile.provider != provider:
        raise ValueError("hook provider does not match registered profile")
    with state_lock(
        registry.settings.state_dir,
        registry.settings.lock_stale_seconds,
    ):
        lease = get_active_lease(registry, task)
        if lease is None:
            raise ValueError("hook task does not own a live lease")
        expected = {
            "profile": profile.id,
            "provider": provider,
            "pool": pool,
            "workspace": workspace,
        }
        if any(lease.get(key) != value for key, value in expected.items()):
            raise ValueError("hook identity does not exactly match its live lease")
        existing_path = session_path(registry, task)
        if existing_path.exists() or existing_path.is_symlink():
            existing = get_session(registry, task)
            binding = {
                **expected,
                "task": task,
                "turn_end": str(exact_turn_end),
                "session_id": session_id,
            }
            if any(existing.get(key) != value for key, value in binding.items()):
                raise ValueError("SessionStart mapping is already bound to another identity")
            return {
                "recorded": True,
                "idempotent": True,
                "task": task,
                "profile": profile.id,
                "provider": profile.provider,
            }
        mapping = {
            "schema": 1,
            "task": task,
            "profile": profile.id,
            "provider": profile.provider,
            "pool": pool,
            "workspace": str(exact_workspace),
            "turn_end": str(exact_turn_end),
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
                "pool": pool,
            },
        )
    return {
        "recorded": True,
        "idempotent": False,
        "task": task,
        "profile": profile.id,
        "provider": profile.provider,
    }


def record_turn_end_from_hook(registry: Registry) -> dict[str, Any]:
    task = os.environ.get("AGENT_FLEET_TASK_ID")
    profile_id = os.environ.get("AGENT_FLEET_PROFILE")
    provider = os.environ.get("AGENT_FLEET_PROVIDER")
    pool = os.environ.get("AGENT_FLEET_POOL")
    workspace = os.environ.get("AGENT_FLEET_WORKSPACE")
    turn_end = os.environ.get("AGENT_FLEET_TURN_END")
    if not task or not profile_id or not provider or not pool or not workspace or not turn_end:
        return {"recorded": False, "reason": "not_agent_fleet_launch"}
    exact_workspace = lexical_path(Path(workspace))
    exact_turn_end = validate_turn_end_path(Path(turn_end))
    if str(exact_workspace) != workspace:
        raise ValueError("turn-end hook workspace must be an exact absolute path")
    with state_lock(
        registry.settings.state_dir,
        registry.settings.lock_stale_seconds,
    ):
        lease = get_active_lease(registry, task)
        mapping = get_session(registry, task)
        expected = {
            "profile": profile_id,
            "provider": provider,
            "pool": pool,
            "workspace": workspace,
        }
        if lease is None or any(lease.get(key) != value for key, value in expected.items()):
            raise ValueError("turn-end hook identity does not exactly match its live lease")
        if any(mapping.get(key) != value for key, value in expected.items()):
            raise ValueError("turn-end hook identity does not match its SessionStart mapping")
        if mapping.get("turn_end") != str(exact_turn_end):
            raise ValueError("turn-end hook marker does not match its SessionStart mapping")
        _touch_turn_end(exact_turn_end)
    return {"recorded": True, "task": task, "profile": profile_id}


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
        value = read_private_json(path, label="session mapping")
    except FileNotFoundError as exc:
        raise ValueError(f"no recorded provider session for task: {task}") from exc
    required = {
        "schema",
        "task",
        "profile",
        "provider",
        "pool",
        "workspace",
        "turn_end",
        "session_id",
        "updated_at",
    }
    if not isinstance(value, dict) or set(value) != required or value.get("schema") != 1:
        raise ValueError(f"corrupt session mapping: {path}")
    if value.get("task") != task or any(
        not isinstance(value.get(field), str) or not value[field]
        for field in ("profile", "provider", "pool", "workspace", "turn_end", "session_id")
    ):
        raise ValueError(f"corrupt session mapping: {path}")
    workspace = str(value["workspace"])
    turn_end = str(value["turn_end"])
    if (
        str(lexical_path(Path(workspace))) != workspace
        or str(lexical_path(Path(turn_end))) != turn_end
        or not Path(turn_end).name.endswith(".turn-ended")
        or not _valid_timestamp(value.get("updated_at"))
    ):
        raise ValueError(f"corrupt session mapping: {path}")
    profile = registry.require_profile(str(value["profile"]))
    if value["provider"] != profile.provider:
        raise ValueError("session mapping provider does not match its profile")
    validate_id(str(value["pool"]), "pool id")
    validate_id(str(value["session_id"]), "session id")
    return value


def remove_session(registry: Registry, task: str) -> dict[str, Any]:
    mapping = get_session(registry, task)
    unlink_private_file(session_path(registry, task), label="provider session mapping")
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
