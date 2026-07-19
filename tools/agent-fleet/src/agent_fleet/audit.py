from __future__ import annotations

import json
import os
import stat
from collections import deque
from pathlib import Path
from typing import Any

from .models import Registry
from .paths import ensure_private_dir, open_private_dir
from .util import read_private_bytes, utc_now


def audit_path(registry: Registry) -> Path:
    return registry.settings.state_dir / "audit.jsonl"


def append_audit(registry: Registry, event: str, fields: dict[str, Any]) -> None:
    path = audit_path(registry)
    ensure_private_dir(path.parent)
    payload = {"schema": 1, "at": utc_now(), "event": event, **fields}
    encoded = (json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n").encode()
    parent_fd = open_private_dir(path.parent)
    flags = os.O_APPEND | os.O_CREAT | os.O_WRONLY | getattr(os, "O_NOFOLLOW", 0)
    created = False
    try:
        try:
            descriptor = os.open(path.name, flags | os.O_EXCL, 0o600, dir_fd=parent_fd)
            created = True
        except FileExistsError:
            descriptor = os.open(path.name, flags, 0o600, dir_fd=parent_fd)
        opened = os.fstat(descriptor)
        current = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != os.getuid()
            or opened.st_nlink != 1
            or (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino)
        ):
            raise ValueError(f"audit log must be a current-user single-link regular file: {path}")
        if created:
            os.fchmod(descriptor, 0o600)
        elif stat.S_IMODE(opened.st_mode) != 0o600:
            raise ValueError(f"audit log must have mode 0600: {path}")
        os.write(descriptor, encoded)
        os.fsync(descriptor)
        os.fsync(parent_fd)
    finally:
        if "descriptor" in locals():
            os.close(descriptor)
        os.close(parent_fd)


def read_audit(registry: Registry, *, limit: int = 100) -> list[dict[str, Any]]:
    if limit < 1 or limit > 10_000:
        raise ValueError("audit limit must be between 1 and 10000")
    path = audit_path(registry)
    try:
        raw = read_private_bytes(path, label="audit log")
    except FileNotFoundError:
        return []
    rows: deque[dict[str, Any]] = deque(maxlen=limit)
    for line in raw.splitlines():
        try:
            value = json.loads(line)
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
        if isinstance(value, dict):
            rows.append(value)
    return list(rows)
