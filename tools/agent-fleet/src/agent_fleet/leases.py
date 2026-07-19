from __future__ import annotations

import math
import re
import socket
import time
from datetime import datetime
from pathlib import Path
from typing import Any

from .audit import append_audit
from .models import Registry
from .projects import lexical_path
from .util import (
    atomic_write_json,
    process_identity_state,
    process_start_token,
    read_private_json,
    task_key,
    unlink_private_file,
    utc_now,
)

UTC_TIMESTAMP = re.compile(
    r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
    r"(?:\.[0-9]+)?(?:Z|\+00:00)\Z"
)


def lease_path(registry: Registry, task: str) -> Path:
    return registry.settings.state_dir / "leases" / f"{task_key(task)}.json"


def _read(path: Path) -> dict[str, Any] | None:
    try:
        value = read_private_json(path, label="worker lease")
    except FileNotFoundError:
        return None
    if not isinstance(value, dict):
        raise ValueError(f"corrupt worker lease: {path}")
    return value


def _valid_timestamp(value: Any) -> bool:
    if not isinstance(value, str) or UTC_TIMESTAMP.fullmatch(value) is None:
        return False
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return False
    return parsed.tzinfo is not None and parsed.utcoffset() is not None and not parsed.utcoffset()


def _require_lease_shape(lease: dict[str, Any], path: Path | None = None) -> None:
    location = f": {path}" if path is not None else ""
    string_fields = ("task", "profile", "provider", "pool", "workspace", "hostname", "created_at")
    if (
        lease.get("schema") != 2
        or any(not isinstance(lease.get(field), str) or not lease[field] for field in string_fields)
        or not _valid_timestamp(lease.get("created_at"))
    ):
        raise ValueError(f"corrupt worker lease{location}")
    workspace = str(lease["workspace"])
    if str(lexical_path(Path(workspace))) != workspace:
        raise ValueError(f"worker lease workspace is not an exact absolute path{location}")
    created_unix = lease.get("created_unix")
    if (
        not isinstance(created_unix, (int, float))
        or isinstance(created_unix, bool)
        or not math.isfinite(float(created_unix))
        or not isinstance(lease.get("state"), str)
    ):
        raise ValueError(f"corrupt worker lease{location}")
    state = lease["state"]
    pid = lease.get("pid")
    process_start = lease.get("process_start")
    bound_at = lease.get("bound_at")
    if state == "reserved":
        if pid is not None or process_start is not None or bound_at is not None:
            raise ValueError(f"corrupt reserved worker lease{location}")
        return
    if state == "running" and (
        isinstance(pid, int)
        and not isinstance(pid, bool)
        and pid > 0
        and isinstance(process_start, str)
        and bool(process_start)
        and isinstance(bound_at, str)
        and bool(bound_at)
        and _valid_timestamp(bound_at)
    ):
        return
    raise ValueError(f"corrupt worker lease{location}")


def lease_is_active(lease: dict[str, Any], *, grace_seconds: int) -> bool:
    state = lease.get("state")
    if state == "running":
        pid = lease.get("pid")
        process_start = lease.get("process_start")
        return (
            isinstance(pid, int)
            and isinstance(process_start, str)
            and bool(process_start)
            and process_identity_state(pid, process_start) != "dead"
        )
    if state == "reserved":
        created = lease.get("created_unix")
        return isinstance(created, (int, float)) and time.time() - float(created) <= grace_seconds
    return False


def active_leases(registry: Registry, *, prune: bool = False) -> list[dict[str, Any]]:
    directory = registry.settings.state_dir / "leases"
    if not directory.exists():
        return []
    active: list[dict[str, Any]] = []
    for path in sorted(directory.glob("*.json")):
        lease = _read(path)
        if lease is None:
            continue
        _require_lease_shape(lease, path)
        if path.name != f"{task_key(str(lease['task']))}.json":
            raise ValueError(f"worker lease filename does not match its task: {path}")
        if lease_is_active(lease, grace_seconds=registry.settings.lease_grace_seconds):
            active.append(lease)
        elif prune:
            path.unlink(missing_ok=True)
    return active


def get_active_lease(registry: Registry, task: str) -> dict[str, Any] | None:
    path = lease_path(registry, task)
    lease = _read(path)
    if lease is None:
        return None
    _require_lease_shape(lease, path)
    if lease.get("task") != task:
        raise ValueError(f"task hash collision or corrupt lease: {path}")
    if lease_is_active(lease, grace_seconds=registry.settings.lease_grace_seconds):
        return lease
    return None


def new_lease(
    task: str,
    profile_id: str,
    pool: str,
    *,
    provider: str,
    workspace: Path,
    pid: int | None,
) -> dict[str, Any]:
    process_start = process_start_token(pid) if pid is not None else None
    if pid is not None and process_start is None:
        raise ValueError("cannot bind worker lease without a verified process start token")
    payload: dict[str, Any] = {
        "schema": 2,
        "task": task,
        "profile": profile_id,
        "provider": provider,
        "pool": pool,
        "workspace": str(lexical_path(workspace)),
        "state": "reserved" if pid is None else "running",
        "pid": pid,
        "process_start": process_start,
        "hostname": socket.gethostname(),
        "created_at": utc_now(),
        "created_unix": time.time(),
        "bound_at": utc_now() if pid is not None else None,
    }
    return payload


def write_lease(registry: Registry, lease: dict[str, Any]) -> None:
    _require_lease_shape(lease)
    atomic_write_json(lease_path(registry, str(lease["task"])), lease)


def bind_lease(registry: Registry, lease: dict[str, Any], pid: int) -> dict[str, Any]:
    _require_lease_shape(lease)
    process_start = process_start_token(pid)
    if process_start is None:
        raise ValueError("cannot bind worker lease without a verified process start token")
    bound = dict(lease)
    bound.update(
        {
            "state": "running",
            "pid": pid,
            "process_start": process_start,
            "hostname": socket.gethostname(),
            "bound_at": utc_now(),
        }
    )
    write_lease(registry, bound)
    return bound


def release_lease(registry: Registry, task: str, *, force: bool = False) -> dict[str, Any]:
    path = lease_path(registry, task)
    lease = _read(path)
    if lease is None or lease.get("task") != task:
        raise ValueError(f"no lease for task: {task}")
    _require_lease_shape(lease, path)
    running_live = lease.get("state") == "running" and lease_is_active(
        lease, grace_seconds=registry.settings.lease_grace_seconds
    )
    if running_live and not force:
        raise ValueError("lease is active; pass --force only after confirming the worker stopped")
    unlink_private_file(path, label="worker lease")
    append_audit(
        registry,
        "lease-released",
        {
            "task_key": task_key(task),
            "profile": lease.get("profile"),
            "pool": lease.get("pool"),
            "forced": force,
        },
    )
    return {"task": task, "profile": lease.get("profile"), "released": True}
