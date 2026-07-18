from __future__ import annotations

import json
import os
from collections import deque
from pathlib import Path
from typing import Any

from .models import Registry
from .paths import ensure_private_dir
from .util import utc_now


def audit_path(registry: Registry) -> Path:
    return registry.settings.state_dir / "audit.jsonl"


def append_audit(registry: Registry, event: str, fields: dict[str, Any]) -> None:
    path = audit_path(registry)
    ensure_private_dir(path.parent)
    payload = {"schema": 1, "at": utc_now(), "event": event, **fields}
    encoded = (json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n").encode()
    descriptor = os.open(path, os.O_APPEND | os.O_CREAT | os.O_WRONLY, 0o600)
    try:
        os.write(descriptor, encoded)
        os.fsync(descriptor)
        os.fchmod(descriptor, 0o600)
    finally:
        os.close(descriptor)


def read_audit(registry: Registry, *, limit: int = 100) -> list[dict[str, Any]]:
    if limit < 1 or limit > 10_000:
        raise ValueError("audit limit must be between 1 and 10000")
    path = audit_path(registry)
    if not path.exists():
        return []
    rows: deque[dict[str, Any]] = deque(maxlen=limit)
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(value, dict):
                rows.append(value)
    return list(rows)
