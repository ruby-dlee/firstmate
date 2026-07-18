from __future__ import annotations

import os
import stat
from pathlib import Path

CONTROL_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"


def validated_safe_directory(path: Path, *, label: str) -> Path:
    """Return one physical executable-search directory with safe ancestry.

    Every component must be current-user or root owned and non-writable by
    group/other. A root-owned sticky writable directory is accepted only as an
    ancestor (for example /tmp above a private test directory), never as the
    executable-search directory itself.
    """

    if not path.is_absolute():
        raise ValueError(f"{label} must be absolute: {path}")
    try:
        resolved = path.resolve(strict=True)
    except OSError as exc:
        raise ValueError(f"{label} is unavailable: {path}") from exc
    current = resolved
    leaf = True
    while True:
        try:
            metadata = current.lstat()
        except OSError as exc:
            raise ValueError(f"{label} ancestry is unavailable: {current}") from exc
        mode = stat.S_IMODE(metadata.st_mode)
        if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid not in {0, os.getuid()}:
            raise ValueError(f"{label} has unsafe ownership or ancestry: {current}")
        writable = bool(mode & 0o022)
        sticky_root_ancestor = (
            not leaf and metadata.st_uid == 0 and bool(mode & stat.S_ISVTX)
        )
        if writable and not sticky_root_ancestor:
            raise ValueError(f"{label} has writable ancestry: {current}")
        if current == current.parent:
            break
        current = current.parent
        leaf = False
    return resolved


def validated_safe_executable(path: Path, *, label: str) -> Path:
    """Return one physical executable below safe current-user/root ancestry."""

    if not path.is_absolute():
        raise ValueError(f"{label} must be absolute: {path}")
    try:
        resolved = path.resolve(strict=True)
        metadata = resolved.stat()
    except OSError as exc:
        raise ValueError(f"{label} is unavailable: {path}") from exc
    mode = stat.S_IMODE(metadata.st_mode)
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid not in {0, os.getuid()}
        or mode & 0o022
        or not mode & 0o111
    ):
        raise ValueError(f"{label} must be a safely owned, non-writable executable: {path}")
    validated_safe_directory(resolved.parent, label=f"{label} parent")
    return resolved


def resolve_control_executable(name: str) -> Path:
    """Resolve a control binary only from the fixed operating-system PATH."""

    for directory in CONTROL_PATH.split(os.pathsep):
        candidate = Path(directory) / name
        try:
            return validated_safe_executable(candidate, label=name)
        except ValueError:
            continue
    raise ValueError(f"safe system {name} executable is unavailable")
