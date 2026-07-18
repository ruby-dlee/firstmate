from __future__ import annotations

import json
import os
import shutil
import socket
import time
import uuid
from pathlib import Path
from typing import Any

from .paths import ensure_private_dir
from .util import atomic_write_json, process_matches, process_start_token


class DirectoryLock:
    """Portable inter-process lock based on atomic directory creation."""

    def __init__(
        self,
        path: Path,
        *,
        stale_seconds: int,
        timeout: float = 10.0,
        purpose: str = "exclusive",
    ):
        self.path = path
        self.stale_seconds = stale_seconds
        self.timeout = timeout
        self.nonce = uuid.uuid4().hex
        process_start = process_start_token(os.getpid())
        if process_start is None:
            raise RuntimeError("cannot acquire a Fleet lock without a verified process start token")
        self.owner = {
            "schema": 1,
            "pid": os.getpid(),
            "process_start": process_start,
            "hostname": socket.gethostname(),
            "created_unix": time.time(),
            "nonce": self.nonce,
            "purpose": purpose,
        }
        self.acquired = False

    @property
    def owner_path(self) -> Path:
        return self.path / "owner.json"

    def _owner(self) -> dict[str, Any] | None:
        try:
            value = json.loads(self.owner_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return None
        return value if isinstance(value, dict) else None

    def _age(self, owner: dict[str, Any] | None) -> float:
        if owner is not None and isinstance(owner.get("created_unix"), (int, float)):
            return max(0.0, time.time() - float(owner["created_unix"]))
        try:
            return max(0.0, time.time() - self.path.stat().st_mtime)
        except FileNotFoundError:
            return 0.0

    def _reclaim_if_stale(self) -> bool:
        owner = self._owner()
        if self._age(owner) <= self.stale_seconds:
            return False
        if owner is not None:
            if owner.get("hostname") != socket.gethostname():
                return False
            pid = owner.get("pid")
            if isinstance(pid, int) and process_matches(pid, owner.get("process_start")):
                return False
        tombstone = self.path.with_name(f".{self.path.name}.stale.{uuid.uuid4().hex}")
        try:
            os.replace(self.path, tombstone)
        except FileNotFoundError:
            return True
        except OSError:
            return False
        shutil.rmtree(tombstone, ignore_errors=True)
        return True

    def held(self) -> bool:
        """Return whether a live owner holds this lock, reclaiming stale state."""

        if not self.path.exists():
            return False
        self._reclaim_if_stale()
        return self.path.exists()

    def acquire(self) -> None:
        ensure_private_dir(self.path.parent)
        deadline = time.monotonic() + self.timeout
        while True:
            try:
                self.path.mkdir(mode=0o700)
            except FileExistsError:
                self._reclaim_if_stale()
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"timed out acquiring state lock: {self.path}") from None
                time.sleep(0.05)
                continue
            try:
                atomic_write_json(self.owner_path, self.owner)
            except BaseException:
                shutil.rmtree(self.path, ignore_errors=True)
                raise
            self.acquired = True
            return

    def release(self) -> None:
        if not self.acquired:
            return
        owner = self._owner()
        if owner is None or owner.get("nonce") != self.nonce:
            raise RuntimeError(f"state lock ownership changed unexpectedly: {self.path}")
        tombstone = self.path.with_name(f".{self.path.name}.release.{self.nonce}")
        os.replace(self.path, tombstone)
        shutil.rmtree(tombstone, ignore_errors=False)
        self.acquired = False

    def __enter__(self) -> DirectoryLock:
        self.acquire()
        return self

    def __exit__(self, exc_type: object, exc: object, traceback: object) -> None:
        self.release()


def state_lock(state_dir: Path, stale_seconds: int, *, timeout: float = 10.0) -> DirectoryLock:
    return DirectoryLock(
        state_dir / "locks" / "registry.lock",
        stale_seconds=stale_seconds,
        timeout=timeout,
    )


def provider_enrollment_lock(
    state_dir: Path,
    provider: str,
    stale_seconds: int,
    *,
    timeout: float = 10.0,
) -> DirectoryLock:
    return DirectoryLock(
        state_dir / "locks" / f"provider-enrollment-{provider}.lock",
        stale_seconds=stale_seconds,
        timeout=timeout,
        purpose="maintenance",
    )


def provider_selection_refresh_lock(
    state_dir: Path,
    provider: str,
    stale_seconds: int,
    *,
    timeout: float = 10.0,
) -> DirectoryLock:
    return DirectoryLock(
        state_dir / "locks" / f"provider-enrollment-{provider}.lock",
        stale_seconds=stale_seconds,
        timeout=timeout,
        purpose="selection-refresh",
    )


def provider_maintenance_active(
    state_dir: Path,
    provider: str,
    stale_seconds: int,
) -> bool:
    lock = provider_enrollment_lock(
        state_dir,
        provider,
        stale_seconds,
        timeout=0,
    )
    if not lock.held():
        return False
    owner = lock._owner()
    # mkdir necessarily precedes the atomic owner.json write. Avoid treating
    # that tiny initialization window as auth maintenance and spuriously
    # rejecting a concurrent selection; an owner that stays absent remains
    # fail-closed.
    for _ in range(10):
        if owner is not None:
            break
        time.sleep(0.005)
        owner = lock._owner()
    # A missing/corrupt owner is fail-closed. Selection refreshes use the same
    # exclusion primitive to serialize quota writes, but they are not auth
    # maintenance and therefore do not block another lease commit.
    return owner is None or owner.get("purpose") != "selection-refresh"
