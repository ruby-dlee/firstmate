from __future__ import annotations

import ctypes
import errno
import hashlib
import json
import os
import re
import stat
import subprocess
import uuid
from contextlib import suppress
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Literal

from .paths import ensure_private_dir, open_private_dir, open_user_dir

SAFE_ID = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$")
ProcessIdentityState = Literal["same", "dead", "indeterminate"]
_SYSTEM_PS = Path("/bin/ps") if Path("/bin/ps").is_file() else Path("/usr/bin/ps")


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
    encoded = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode()
    atomic_write_bytes(path, encoded, mode=mode)


def atomic_write_bytes(path: Path, payload: bytes, mode: int = 0o600) -> None:
    ensure_private_dir(path.parent)
    parent_fd = open_private_dir(path.parent)
    temporary = f".{path.name}.{uuid.uuid4().hex}.tmp"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = -1
    installed = False
    try:
        try:
            existing = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            existing = None
        if existing is not None and (
            not stat.S_ISREG(existing.st_mode)
            or existing.st_uid != os.getuid()
            or stat.S_IMODE(existing.st_mode) != mode
            or existing.st_nlink != 1
        ):
            raise ValueError(
                f"refusing to replace unsafe Fleet file (expected current-user {mode:04o} "
                f"single-link regular file): {path}"
            )
        descriptor = os.open(temporary, flags, mode, dir_fd=parent_fd)
        os.fchmod(descriptor, mode)
        opened = os.fstat(descriptor)
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            view = view[written:]
        os.fsync(descriptor)
        os.replace(temporary, path.name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
        installed = True
        current = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
        if (
            (current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino)
            or not stat.S_ISREG(current.st_mode)
            or current.st_uid != os.getuid()
            or stat.S_IMODE(current.st_mode) != mode
            or current.st_nlink != 1
        ):
            raise RuntimeError(f"Fleet atomic write changed during installation: {path}")
        os.fsync(parent_fd)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if not installed:
            with suppress(FileNotFoundError):
                os.unlink(temporary, dir_fd=parent_fd)
        os.close(parent_fd)


def read_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def _fsync_directory(path: Path) -> None:
    descriptor = open_private_dir(path)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _read_private_bytes_with_parent(path: Path, *, label: str, parent_fd: int) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = -1
    try:
        descriptor = os.open(path.name, flags, dir_fd=parent_fd)
    except FileNotFoundError:
        raise
    except OSError as exc:
        raise ValueError(f"{label} is unsafe or unreadable: {path}") from exc
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != os.getuid()
            or stat.S_IMODE(opened.st_mode) != 0o600
            or opened.st_nlink != 1
        ):
            raise ValueError(
                f"{label} must be a current-user 0600 single-link regular file: {path}"
            )
        current = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
        if (current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino):
            raise ValueError(f"{label} changed while opening: {path}")
        with os.fdopen(descriptor, "rb") as handle:
            descriptor = -1
            payload = handle.read()
            after = os.fstat(handle.fileno())
            if (
                after.st_dev != opened.st_dev
                or after.st_ino != opened.st_ino
                or after.st_size != opened.st_size
                or after.st_mtime_ns != opened.st_mtime_ns
                or after.st_ctime_ns != opened.st_ctime_ns
            ):
                raise ValueError(f"{label} changed while reading: {path}")
            return payload
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def read_private_bytes(path: Path, *, label: str) -> bytes:
    """Read a private file whose Fleet-owned parent must have mode 0700."""

    parent_fd = open_private_dir(path.parent)
    try:
        return _read_private_bytes_with_parent(path, label=label, parent_fd=parent_fd)
    finally:
        os.close(parent_fd)


def read_owned_private_bytes(path: Path, *, label: str) -> bytes:
    """Read a 0600 file below a current-user, non-writable provider directory."""

    parent_fd = open_user_dir(path.parent)
    try:
        return _read_private_bytes_with_parent(path, label=label, parent_fd=parent_fd)
    finally:
        os.close(parent_fd)


def read_private_json(path: Path, *, label: str) -> Any:
    try:
        return json.loads(read_private_bytes(path, label=label))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"corrupt {label}: {path}") from exc


def read_owned_private_json(path: Path, *, label: str) -> Any:
    try:
        return json.loads(read_owned_private_bytes(path, label=label))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"corrupt {label}: {path}") from exc


def _rename_noreplace_at(
    source_parent: int,
    source_name: str,
    destination_parent: int,
    destination_name: str,
) -> None:
    """Atomically rename one directory entry without replacing another."""

    libc = ctypes.CDLL(None, use_errno=True)
    kernel = os.uname().sysname.lower()
    if kernel == "darwin":
        try:
            rename = libc.renameatx_np
        except AttributeError as exc:  # pragma: no cover - unsupported Darwin
            raise ValueError("atomic no-replace rename is unavailable") from exc
        rename.argtypes = [
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        ]
        flags = 0x00000004  # RENAME_EXCL
    elif kernel == "linux":
        try:
            rename = libc.renameat2
        except AttributeError as exc:  # pragma: no cover - unsupported libc
            raise ValueError("atomic no-replace rename is unavailable") from exc
        rename.argtypes = [
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        ]
        flags = 0x00000001  # RENAME_NOREPLACE
    else:  # pragma: no cover - supported production/test platforms are Darwin/Linux
        raise ValueError("atomic no-replace rename is unavailable")
    rename.restype = ctypes.c_int
    ctypes.set_errno(0)
    result = rename(
        source_parent,
        os.fsencode(source_name),
        destination_parent,
        os.fsencode(destination_name),
        flags,
    )
    if result == 0:
        return
    error = ctypes.get_errno()
    if error == errno.EEXIST:
        raise FileExistsError(error, os.strerror(error))
    if error in {errno.EINVAL, errno.ENOSYS, getattr(errno, "ENOTSUP", errno.EINVAL)}:
        raise ValueError("atomic no-replace rename is unsupported by this filesystem")
    raise OSError(error, os.strerror(error))


def rename_private_noreplace(source: Path, destination: Path) -> None:
    """Atomically move one path through verified private parent descriptors."""

    source_parent = open_private_dir(source.parent)
    destination_parent = (
        source_parent
        if source.parent == destination.parent
        else open_private_dir(destination.parent)
    )
    try:
        _rename_noreplace_at(
            source_parent,
            source.name,
            destination_parent,
            destination.name,
        )
    finally:
        if destination_parent != source_parent:
            os.close(destination_parent)
        os.close(source_parent)


def _matches_expected_stat(
    metadata: os.stat_result,
    expected: object,
    *,
    ctime: bool = True,
) -> bool:
    if not isinstance(expected, dict) or not {"dev", "ino"}.issubset(expected):
        return False
    observed = {
        "dev": metadata.st_dev,
        "ino": metadata.st_ino,
        "uid": metadata.st_uid,
        "mode": stat.S_IMODE(metadata.st_mode),
        "nlink": metadata.st_nlink,
        "size": metadata.st_size,
        "mtime_ns": metadata.st_mtime_ns,
        "ctime_ns": metadata.st_ctime_ns,
    }
    return all(
        (not ctime and key == "ctime_ns")
        or (key in observed and observed[key] == value)
        for key, value in expected.items()
    )


def unlink_private_file(
    path: Path,
    *,
    label: str,
    mode: int = 0o600,
    expected_stat: object | None = None,
) -> bool:
    """Remove one verified private file through its verified parent descriptor."""

    parent_fd = open_private_dir(path.parent)
    descriptor = -1
    quarantine = f".{path.name}.delete.{uuid.uuid4().hex}"
    moved = False
    try:
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(path.name, flags, dir_fd=parent_fd)
        except FileNotFoundError:
            return False
        except OSError as exc:
            raise ValueError(f"{label} is unsafe or unreadable: {path}") from exc
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != os.getuid()
            or stat.S_IMODE(opened.st_mode) != mode
            or opened.st_nlink != 1
        ):
            raise ValueError(
                f"{label} must be a current-user {mode:04o} single-link regular file: {path}"
            )
        if expected_stat is not None and not _matches_expected_stat(opened, expected_stat):
            raise ValueError(f"{label} changed before attributed removal: {path}")
        current = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
        identity = (opened.st_dev, opened.st_ino)
        if identity != (current.st_dev, current.st_ino):
            raise ValueError(f"{label} changed before removal: {path}")
        _rename_noreplace_at(parent_fd, path.name, parent_fd, quarantine)
        moved = True
        quarantined = os.stat(quarantine, dir_fd=parent_fd, follow_symlinks=False)
        if identity != (quarantined.st_dev, quarantined.st_ino) or (
            expected_stat is not None
            and not _matches_expected_stat(quarantined, expected_stat, ctime=False)
        ):
            try:
                _rename_noreplace_at(parent_fd, quarantine, parent_fd, path.name)
                moved = False
            except FileExistsError as exc:
                raise ValueError(
                    f"{label} changed during removal and both generations were preserved: {path}"
                ) from exc
            raise ValueError(f"{label} changed during attributed removal: {path}")
        try:
            os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise ValueError(
                f"{label} reappeared during removal and both generations were preserved: {path}"
            )
        os.unlink(quarantine, dir_fd=parent_fd)
        moved = False
        after = os.fstat(descriptor)
        if after.st_nlink != 0 or (after.st_dev, after.st_ino) != identity:
            raise RuntimeError(f"{label} removal identity was not stable: {path}")
        os.fsync(parent_fd)
        return True
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if moved:
            with suppress(OSError, ValueError):
                _rename_noreplace_at(parent_fd, quarantine, parent_fd, path.name)
        os.close(parent_fd)


def _process_start_token(pid: int) -> tuple[str | None, bool]:
    try:
        result = subprocess.run(
            [str(_SYSTEM_PS), "-p", str(pid), "-o", "lstart="],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError:
        return None, False
    if result.returncode != 0:
        return None, False
    token = result.stdout.strip()
    return (token or None), bool(token)


def process_start_token(pid: int) -> str | None:
    token, verified = _process_start_token(pid)
    return token if verified else None


def process_identity_state(pid: int, start_token: str | None) -> ProcessIdentityState:
    if pid <= 0 or not start_token:
        return "dead"
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return "dead"
    except (PermissionError, OSError):
        return "indeterminate"
    current, verified = _process_start_token(pid)
    if not verified or current is None:
        return "indeterminate"
    return "same" if current == start_token else "dead"


def process_matches(pid: int, start_token: str | None) -> bool:
    return process_identity_state(pid, start_token) == "same"
