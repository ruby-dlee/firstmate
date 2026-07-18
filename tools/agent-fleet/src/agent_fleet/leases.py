from __future__ import annotations

import json
import socket
import time
from pathlib import Path
from typing import Any

from .audit import append_audit
from .models import Registry
from .util import atomic_write_json, process_matches, process_start_token, task_key, utc_now


def lease_path(registry: Registry, task: str) -> Path:
    return registry.settings.state_dir / "leases" / f"{task_key(task)}.json"


def _read(path: Path) -> dict[str, Any] | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def lease_is_active(lease: dict[str, Any], *, grace_seconds: int) -> bool:
    state = lease.get("state")
    if state == "running":
        pid = lease.get("pid")
        process_start = lease.get("process_start")
        return (
            isinstance(pid, int)
            and isinstance(process_start, str)
            and bool(process_start)
            and process_matches(pid, process_start)
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
        if lease is not None and lease_is_active(
            lease, grace_seconds=registry.settings.lease_grace_seconds
        ):
            active.append(lease)
        elif prune:
            path.unlink(missing_ok=True)
    return active


def get_active_lease(registry: Registry, task: str) -> dict[str, Any] | None:
    path = lease_path(registry, task)
    lease = _read(path)
    if lease is None:
        return None
    if lease.get("task") != task:
        raise ValueError(f"task hash collision or corrupt lease: {path}")
    if lease_is_active(lease, grace_seconds=registry.settings.lease_grace_seconds):
        return lease
    return None


def new_lease(task: str, profile_id: str, pool: str, *, pid: int | None) -> dict[str, Any]:
    process_start = process_start_token(pid) if pid is not None else None
    if pid is not None and process_start is None:
        raise ValueError("cannot bind worker lease without a verified process start token")
    payload: dict[str, Any] = {
        "schema": 1,
        "task": task,
        "profile": profile_id,
        "pool": pool,
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
    atomic_write_json(lease_path(registry, str(lease["task"])), lease)


def bind_lease(registry: Registry, lease: dict[str, Any], pid: int) -> dict[str, Any]:
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
    running_live = lease.get("state") == "running" and lease_is_active(
        lease, grace_seconds=registry.settings.lease_grace_seconds
    )
    if running_live and not force:
        raise ValueError("lease is active; pass --force only after confirming the worker stopped")
    path.unlink()
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
