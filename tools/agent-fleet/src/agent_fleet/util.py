from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import tempfile
from contextlib import suppress
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

SAFE_ID = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$")


def validate_id(value: str, kind: str) -> str:
    if not SAFE_ID.fullmatch(value):
        raise ValueError(f"invalid {kind}: use 1-128 letters, numbers, dot, underscore, or hyphen")
    if "@" in value:
        raise ValueError(f"invalid {kind}: account emails are not allowed")
    return value


def utc_now() -> str:
    return datetime.now(UTC).isoformat()


def task_key(task: str) -> str:
    return hashlib.sha256(task.encode("utf-8")).hexdigest()


def atomic_write_json(path: Path, payload: Any, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, path)
        path.chmod(mode)
    except BaseException:
        with suppress(FileNotFoundError):
            os.unlink(temp_name)
        raise


def atomic_write_bytes(path: Path, payload: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, path)
        path.chmod(mode)
    except BaseException:
        with suppress(FileNotFoundError):
            os.unlink(temp_name)
        raise


def read_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def process_start_token(pid: int) -> str | None:
    try:
        result = subprocess.run(
            ["ps", "-p", str(pid), "-o", "lstart="],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError:
        return None
    token = result.stdout.strip()
    return token or None


def process_matches(pid: int, start_token: str | None) -> bool:
    if pid <= 0 or start_token is None:
        return False
    current = process_start_token(pid)
    if current is None:
        return False
    return current == start_token
