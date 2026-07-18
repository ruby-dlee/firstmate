from __future__ import annotations

import os
import pwd
import stat
from contextlib import suppress
from pathlib import Path


def current_user_home() -> Path:
    """Return the canonical passwd home, never the caller-controlled HOME."""

    try:
        configured = pwd.getpwuid(os.getuid()).pw_dir
    except (KeyError, OSError) as exc:
        raise ValueError("cannot resolve the current user's passwd home") from exc
    candidate = Path(configured)
    if not candidate.is_absolute() or "\x00" in configured:
        raise ValueError("current user's passwd home is not an absolute path")
    resolved = Path(os.path.realpath(candidate))
    try:
        metadata = resolved.lstat()
    except OSError as exc:
        raise ValueError("current user's passwd home is unavailable") from exc
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or stat.S_IMODE(metadata.st_mode) & 0o022
    ):
        raise ValueError("current user's passwd home has unsafe ownership or permissions")
    return resolved


def _expand_current_user(value: str | Path) -> str:
    raw = str(value)
    if "\x00" in raw or "$" in raw:
        raise ValueError("paths must be literal and cannot contain NUL or environment expansion")
    if raw == "~":
        return str(current_user_home())
    if raw.startswith("~/"):
        return str(current_user_home() / raw[2:])
    if raw.startswith("~"):
        raise ValueError("named-user home expansion is not supported")
    if not Path(raw).is_absolute():
        raise ValueError("paths must be absolute or use the current-user ~/ prefix")
    return raw


def expand_path(value: str | Path) -> Path:
    return Path(_expand_current_user(value)).resolve()


def expand_lexical_path(value: str | Path) -> Path:
    return Path(os.path.abspath(_expand_current_user(value)))


def default_config_path() -> Path:
    override = os.environ.get("AGENT_FLEET_CONFIG")
    if override:
        return expand_path(override)
    return current_user_home() / ".config" / "agent-fleet" / "accounts.toml"


def default_state_dir() -> Path:
    override = os.environ.get("AGENT_FLEET_STATE_DIR")
    if override:
        return expand_path(override)
    return current_user_home() / ".local" / "state" / "agent-fleet"


def default_share_dir() -> Path:
    override = os.environ.get("AGENT_FLEET_SHARE_DIR")
    if override:
        return expand_path(override)
    return current_user_home() / ".local" / "share" / "agent-fleet"


def _open_checked_dir(path: Path, *, create: bool, require_private: bool) -> int:
    absolute = Path(os.path.abspath(path))
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(absolute.anchor or "/", flags)
    try:
        parts = absolute.parts[1:] if absolute.is_absolute() else absolute.parts
        for index, name in enumerate(parts):
            created = False
            try:
                child = os.open(name, flags, dir_fd=descriptor)
            except FileNotFoundError:
                if not create:
                    raise
                try:
                    os.mkdir(name, mode=0o700, dir_fd=descriptor)
                except FileExistsError:
                    pass
                else:
                    created = True
                try:
                    child = os.open(name, flags, dir_fd=descriptor)
                except OSError as exc:
                    raise ValueError(f"unsafe private directory path: {absolute}") from exc
            except OSError as exc:
                raise ValueError(f"unsafe private directory path: {absolute}") from exc
            try:
                opened = os.fstat(child)
                if not stat.S_ISDIR(opened.st_mode):
                    raise ValueError(f"unsafe private directory path: {absolute}")
                if created:
                    os.fchmod(child, 0o700)
                    opened = os.fstat(child)
                    with suppress(OSError):
                        os.fsync(descriptor)
                if index == len(parts) - 1:
                    mode = stat.S_IMODE(opened.st_mode)
                    if opened.st_uid != os.getuid() or (
                        mode != 0o700 if require_private else bool(mode & 0o022)
                    ):
                        expectation = "mode 0700" if require_private else "no group/world write"
                        raise ValueError(
                            f"directory must be current-user owned with {expectation}: {absolute}"
                        )
            except BaseException:
                os.close(child)
                raise
            os.close(descriptor)
            descriptor = child

        opened = os.fstat(descriptor)
        current = os.stat(absolute, follow_symlinks=False)
        if (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino):
            raise ValueError(f"private directory changed during verification: {absolute}")
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def open_private_dir(path: Path) -> int:
    """Open one existing current-user 0700 directory without following links."""

    return _open_checked_dir(path, create=False, require_private=True)


def open_user_dir(path: Path) -> int:
    """Open a current-user non-group/world-writable directory without links."""

    return _open_checked_dir(path, create=False, require_private=False)


def ensure_private_dir(path: Path) -> None:
    """Create or verify a current-user 0700 directory without following links.

    Existing directories are policy inputs, not repair targets: rejecting an
    unsafe mode avoids chmodding a path that changed between inspection and
    mutation. Missing components are created and chmodded only through the
    already-open parent descriptor that this call verified.
    """

    descriptor = _open_checked_dir(path, create=True, require_private=True)
    os.close(descriptor)
