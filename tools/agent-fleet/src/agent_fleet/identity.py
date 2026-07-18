from __future__ import annotations

import json
import os
import select
import stat
import subprocess
import time
import unicodedata
import uuid
from collections.abc import Callable
from contextlib import suppress
from dataclasses import replace
from datetime import UTC, datetime
from hashlib import sha256
from pathlib import Path
from typing import Any

from .executables import CONTROL_PATH, validated_safe_directory
from .models import Profile, Registry
from .paths import current_user_home, current_user_name, ensure_private_dir, open_private_dir
from .providers import identity_fingerprint
from .quota import has_remote_identity_proof, probe_quota, read_quota
from .util import (
    atomic_write_bytes,
    atomic_write_json,
    process_identity_state,
    process_start_token,
    read_owned_private_bytes,
    read_owned_private_json,
    read_private_json,
    utc_now,
)

_CODEX_RPC_STDOUT_LIMIT = 64 * 1024
_CODEX_RPC_STDERR_LIMIT = 4 * 1024
_CLAUDE_DEFAULT_KEYCHAIN_SERVICE = "Claude Code-credentials"
_CLAUDE_KEYCHAIN_MARKER_PAYLOAD = b"granted\n"
_CLAUDE_KEYCHAIN_METADATA_LIMIT = 64 * 1024
_CLAUDE_KEYCHAIN_METADATA_TIMEOUT = 5
_SECURITY_BINARY = Path("/usr/bin/security")


def _credential_snapshot(profile: Profile) -> tuple[str, tuple[Any, ...] | str | None]:
    path = profile.home / (".credentials.json" if profile.provider == "claude" else "auth.json")
    try:
        before = path.lstat()
    except FileNotFoundError:
        return "absent", None
    except OSError as exc:
        return "indeterminate", str(exc)
    try:
        payload = read_owned_private_bytes(path, label=f"{profile.provider} credential file")
        metadata = path.lstat()
    except (OSError, ValueError) as exc:
        return "indeterminate", str(exc)
    fields = (
        "st_dev",
        "st_ino",
        "st_uid",
        "st_mode",
        "st_nlink",
        "st_size",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    if any(getattr(before, field) != getattr(metadata, field) for field in fields):
        return "indeterminate", "credential file changed while snapshotting"
    return (
        "present",
        (
            metadata.st_dev,
            metadata.st_ino,
            metadata.st_uid,
            metadata.st_mode,
            metadata.st_nlink,
            metadata.st_size,
            metadata.st_mtime_ns,
            metadata.st_ctime_ns,
            sha256(payload).hexdigest(),
        ),
    )


def _credential_payload_for_snapshot(
    profile: Profile,
    expected: tuple[str, tuple[Any, ...] | str | None],
) -> bytes | None:
    if expected[0] == "absent":
        if _credential_snapshot(profile) != expected:
            raise ValueError("credential file appeared while preparing identity shadow")
        return None
    if expected[0] != "present" or not isinstance(expected[1], tuple):
        raise ValueError("credential file is unavailable for identity shadow")
    path = profile.home / (
        ".credentials.json" if profile.provider == "claude" else "auth.json"
    )
    payload = read_owned_private_bytes(path, label=f"{profile.provider} credential file")
    if sha256(payload).hexdigest() != expected[1][-1] or _credential_snapshot(profile) != expected:
        raise ValueError("credential file changed while preparing identity shadow")
    return payload


def _claude_keychain_marker_path() -> Path:
    return (
        current_user_home()
        / ".cache"
        / "quota-axi"
        / "claude-keychain-access-granted"
    )


def _claude_keychain_marker_snapshot() -> tuple[
    str, tuple[Any, ...] | str | None
]:
    """Attest Quota AXI's non-secret default-service consent marker."""

    path = _claude_keychain_marker_path()
    try:
        before = path.lstat()
    except FileNotFoundError:
        return "absent", None
    except OSError as exc:
        return "indeterminate", type(exc).__name__
    try:
        payload = read_owned_private_bytes(path, label="Claude Keychain consent marker")
        metadata = path.lstat()
    except (OSError, ValueError) as exc:
        return "indeterminate", type(exc).__name__
    fields = (
        "st_dev",
        "st_ino",
        "st_uid",
        "st_mode",
        "st_nlink",
        "st_size",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    if (
        payload != _CLAUDE_KEYCHAIN_MARKER_PAYLOAD
        or any(getattr(before, field) != getattr(metadata, field) for field in fields)
    ):
        return "indeterminate", "marker_changed_or_invalid"
    return (
        "present",
        (
            metadata.st_dev,
            metadata.st_ino,
            metadata.st_uid,
            metadata.st_mode,
            metadata.st_nlink,
            metadata.st_size,
            metadata.st_mtime_ns,
            metadata.st_ctime_ns,
            sha256(payload).hexdigest(),
        ),
    )


def _claude_keychain_marker_payload_for_snapshot(
    expected: tuple[str, tuple[Any, ...] | str | None],
) -> bytes | None:
    if expected[0] == "absent":
        if _claude_keychain_marker_snapshot() != expected:
            raise ValueError("Claude Keychain consent marker appeared during proof setup")
        return None
    if expected[0] != "present" or not isinstance(expected[1], tuple):
        raise ValueError("Claude Keychain consent marker is unsafe")
    if _claude_keychain_marker_snapshot() != expected:
        raise ValueError("Claude Keychain consent marker changed during proof setup")
    return _CLAUDE_KEYCHAIN_MARKER_PAYLOAD


def _verified_security_binary() -> Path:
    try:
        metadata = _SECURITY_BINARY.lstat()
    except OSError as exc:
        raise ValueError("macOS Keychain metadata control is unavailable") from exc
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != 0
        or stat.S_IMODE(metadata.st_mode) & 0o022
        or not os.access(_SECURITY_BINARY, os.X_OK)
    ):
        raise ValueError("macOS Keychain metadata control is unsafe")
    return _SECURITY_BINARY


def _claude_keychain_metadata_snapshot(*, timeout: int) -> tuple[str, str | None]:
    """Read bounded non-secret metadata for the canonical unsuffixed item."""

    security = _verified_security_binary()
    passwd_name = current_user_name()
    environment = {
        "HOME": str(current_user_home()),
        "USER": passwd_name,
        "LOGNAME": passwd_name,
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LC_ALL": "C",
        "LANG": "C",
        "NO_COLOR": "1",
        "TERM": "dumb",
    }
    try:
        result = subprocess.run(
            [
                str(security),
                "find-generic-password",
                "-s",
                _CLAUDE_DEFAULT_KEYCHAIN_SERVICE,
                "-a",
                passwd_name,
            ],
            env=environment,
            cwd=current_user_home(),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=max(1, min(timeout, _CLAUDE_KEYCHAIN_METADATA_TIMEOUT)),
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ValueError("Claude Keychain metadata proof failed") from exc
    if result.returncode == 44:
        return "absent", None
    if result.returncode != 0:
        raise ValueError("Claude Keychain metadata proof failed")
    if not isinstance(result.stdout, bytes) or not isinstance(result.stderr, bytes):
        raise ValueError("Claude Keychain metadata proof returned an invalid stream")
    if len(result.stdout) + len(result.stderr) > _CLAUDE_KEYCHAIN_METADATA_LIMIT:
        raise ValueError("Claude Keychain metadata proof exceeded its limit")
    metadata = b"stdout\0" + result.stdout + b"\0stderr\0" + result.stderr
    if metadata == b"stdout\0\0stderr\0":
        raise ValueError("Claude Keychain metadata proof was empty")
    return "present", sha256(metadata).hexdigest()


def _claude_keychain_grant_path(registry: Registry) -> Path:
    return registry.settings.state_dir / "identity-anchors" / "claude-keychain-grant.json"


def _claude_keychain_grant_contract(
    registry: Registry,
    metadata_digest: str,
) -> dict[str, Any]:
    from .config import verified_quota_runtime

    node_binary, quota_binary = verified_quota_runtime(registry.settings)
    return {
        "schema": 1,
        "provider": "claude",
        "service": _CLAUDE_DEFAULT_KEYCHAIN_SERVICE,
        "account": current_user_name(),
        "canonical_home": str(current_user_home()),
        "security_binary": str(_SECURITY_BINARY),
        "quota_binary": str(quota_binary),
        "quota_binary_sha256": registry.settings.quota_binary_sha256,
        "quota_node_binary": str(node_binary),
        "quota_node_sha256": registry.settings.quota_node_sha256,
        "quota_release_tree_sha256": registry.settings.quota_release_tree_sha256,
        "keychain_metadata_sha256": metadata_digest,
        "marker_sha256": sha256(_CLAUDE_KEYCHAIN_MARKER_PAYLOAD).hexdigest(),
    }


def _claude_keychain_grant_matches(registry: Registry, metadata_digest: str) -> bool:
    try:
        payload = read_private_json(
            _claude_keychain_grant_path(registry),
            label="Claude Keychain grant contract",
        )
        expected = _claude_keychain_grant_contract(registry, metadata_digest)
    except (FileNotFoundError, OSError, ValueError):
        return False
    if not isinstance(payload, dict) or set(payload) != set(expected) | {"granted_at"}:
        return False
    granted_at = payload.get("granted_at")
    try:
        parsed = datetime.fromisoformat(str(granted_at).replace("Z", "+00:00"))
    except ValueError:
        return False
    return parsed.tzinfo is not None and all(
        payload.get(key) == value for key, value in expected.items()
    )


def _record_claude_keychain_grant(registry: Registry, metadata_digest: str) -> None:
    marker = _claude_keychain_marker_path()
    ensure_private_dir(marker.parent)
    atomic_write_bytes(marker, _CLAUDE_KEYCHAIN_MARKER_PAYLOAD, mode=0o600)
    if _claude_keychain_marker_snapshot()[0] != "present":
        raise ValueError("Claude Keychain consent marker installation failed")
    atomic_write_json(
        _claude_keychain_grant_path(registry),
        {
            **_claude_keychain_grant_contract(registry, metadata_digest),
            "granted_at": utc_now(),
        },
    )


_SHADOW_OWNER_FILE = "owner.json"
_SHADOW_OWNERLESS_GRACE_SECONDS = 5
_SHADOW_OWNER_KEYS = {
    "schema",
    "kind",
    "provider",
    "nonce",
    "pid",
    "process_start",
    "directory_name",
    "directory_dev",
    "directory_ino",
    "created_at",
}


def _shadow_name_matches(name: str, provider: str, nonce: str) -> bool:
    expected = f".{provider}-base-{nonce}"
    if name == expected:
        return True
    prefix = expected + ".deleting-"
    suffix = name.removeprefix(prefix)
    return name.startswith(prefix) and len(suffix) == 32 and all(
        character in "0123456789abcdef" for character in suffix
    )


def _validate_shadow_owner(
    owner: object,
    name: str,
    identity: tuple[int, int],
) -> tuple[int, str]:
    if not isinstance(owner, dict) or set(owner) != _SHADOW_OWNER_KEYS:
        raise ValueError("invalid identity shadow owner")
    provider = owner.get("provider")
    nonce = owner.get("nonce")
    pid = owner.get("pid")
    process_start = owner.get("process_start")
    if (
        owner.get("schema") != 1
        or owner.get("kind") != "base-identity-shadow"
        or provider not in {"claude", "codex"}
        or not isinstance(nonce, str)
        or len(nonce) != 32
        or any(character not in "0123456789abcdef" for character in nonce)
        or not _shadow_name_matches(name, provider, nonce)
        or owner.get("directory_name") != f".{provider}-base-{nonce}"
        or owner.get("directory_dev") != identity[0]
        or owner.get("directory_ino") != identity[1]
        or not isinstance(pid, int)
        or isinstance(pid, bool)
        or not isinstance(process_start, str)
        or not process_start
    ):
        raise ValueError("identity shadow owner mismatch")
    return pid, process_start


def _private_shadow_regular(metadata: os.stat_result) -> bool:
    return (
        stat.S_ISREG(metadata.st_mode)
        and metadata.st_uid == os.getuid()
        and stat.S_IMODE(metadata.st_mode) & 0o077 == 0
        and metadata.st_nlink == 1
    )


def _remove_shadow_payload_entry(directory_fd: int, name: str) -> None:
    """Remove one owner-journaled payload entry without following links."""

    metadata = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    if not stat.S_ISDIR(metadata.st_mode):
        # Provider probes legitimately create cache files, sockets, and links
        # with their own modes.  Unlinking a non-directory entry cannot follow
        # a symlink or traverse a hard link, so inode-pin the directory entry
        # itself instead of requiring provider-controlled mode/link metadata.
        if metadata.st_uid != os.getuid():
            raise ValueError("unsafe identity shadow payload owner")
        current = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if (current.st_dev, current.st_ino) != (metadata.st_dev, metadata.st_ino):
            raise ValueError("identity shadow payload changed during cleanup")
        os.unlink(name, dir_fd=directory_fd)
        return
    if metadata.st_uid != os.getuid():
        raise ValueError("unsafe identity shadow payload directory")
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(name, flags, dir_fd=directory_fd)
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISDIR(opened.st_mode)
            or opened.st_uid != os.getuid()
            or (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino)
        ):
            raise ValueError("identity shadow payload directory changed during cleanup")
        for child in sorted(os.listdir(descriptor)):
            _remove_shadow_payload_entry(descriptor, child)
        os.fsync(descriptor)
        current = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISDIR(current.st_mode)
            or current.st_uid != os.getuid()
            or (current.st_dev, current.st_ino) != (metadata.st_dev, metadata.st_ino)
            or (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino)
        ):
            raise ValueError("identity shadow payload directory changed during cleanup")
        os.rmdir(name, dir_fd=directory_fd)
    finally:
        os.close(descriptor)


def _remove_identity_shadow(parent: Path, name: str, identity: tuple[int, int]) -> bool:
    """Quarantine and journal-delete one inode-pinned private identity shadow."""

    parent_fd = open_private_dir(parent)
    descriptor = -1
    quarantine = name
    try:
        flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(name, flags, dir_fd=parent_fd)
        except FileNotFoundError:
            return False
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISDIR(opened.st_mode)
            or opened.st_uid != os.getuid()
            or stat.S_IMODE(opened.st_mode) != 0o700
            or (opened.st_dev, opened.st_ino) != identity
        ):
            raise ValueError("identity shadow changed before cleanup")
        current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if (current.st_dev, current.st_ino) != identity:
            raise ValueError("identity shadow path changed before cleanup")
        if ".deleting-" not in name:
            quarantine = f"{name}.deleting-{uuid.uuid4().hex}"
            os.replace(name, quarantine, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
            os.fsync(parent_fd)
        quarantined = os.stat(quarantine, dir_fd=parent_fd, follow_symlinks=False)
        if (quarantined.st_dev, quarantined.st_ino) != identity:
            raise ValueError("identity shadow changed during cleanup")
        names = sorted(os.listdir(descriptor))
        if _SHADOW_OWNER_FILE in names:
            owner = read_private_json(
                parent / quarantine / _SHADOW_OWNER_FILE,
                label="identity shadow owner",
            )
            _validate_shadow_owner(owner, quarantine, identity)
            owner_metadata = os.stat(
                _SHADOW_OWNER_FILE,
                dir_fd=descriptor,
                follow_symlinks=False,
            )
            if not _private_shadow_regular(owner_metadata):
                raise ValueError("unsafe identity shadow owner")
            for child in names:
                if child != _SHADOW_OWNER_FILE:
                    _remove_shadow_payload_entry(descriptor, child)
            os.fsync(descriptor)
            if os.listdir(descriptor) != [_SHADOW_OWNER_FILE]:
                raise ValueError("identity shadow changed before owner cleanup")
            current_owner = os.stat(
                _SHADOW_OWNER_FILE,
                dir_fd=descriptor,
                follow_symlinks=False,
            )
            if (
                not _private_shadow_regular(current_owner)
                or (current_owner.st_dev, current_owner.st_ino)
                != (owner_metadata.st_dev, owner_metadata.st_ino)
            ):
                raise ValueError("identity shadow owner changed during cleanup")
            os.unlink(_SHADOW_OWNER_FILE, dir_fd=descriptor)
        else:
            for child in names:
                metadata = os.stat(child, dir_fd=descriptor, follow_symlinks=False)
                if not _recoverable_owner_temporary_name(child, metadata):
                    raise ValueError("nonempty ownerless identity shadow")
                _remove_shadow_payload_entry(descriptor, child)
        os.fsync(descriptor)
        if os.listdir(descriptor):
            raise ValueError("identity shadow changed before final cleanup")
        os.rmdir(quarantine, dir_fd=parent_fd)
        os.fsync(parent_fd)
        return True
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(parent_fd)


def _recoverable_owner_temporary_name(name: str, metadata: os.stat_result) -> bool:
    prefix = f".{_SHADOW_OWNER_FILE}."
    suffix = name.removeprefix(prefix).removesuffix(".tmp")
    return (
        name.startswith(prefix)
        and name.endswith(".tmp")
        and len(suffix) == 32
        and all(character in "0123456789abcdef" for character in suffix)
        and _private_shadow_regular(metadata)
        and stat.S_IMODE(metadata.st_mode) == 0o600
    )


def _recoverable_owner_temporary(entry: os.DirEntry[str]) -> bool:
    try:
        metadata = entry.stat(follow_symlinks=False)
    except OSError:
        return False
    return _recoverable_owner_temporary_name(entry.name, metadata)


def _publish_shadow_owner(
    root: Path,
    payload: dict[str, Any],
    test_hook: Callable[[str, Path], None] | None,
) -> None:
    """Publish the non-secret owner journal with a recognizable crash temporary."""

    parent_fd = open_private_dir(root)
    temporary = f".{_SHADOW_OWNER_FILE}.{uuid.uuid4().hex}.tmp"
    descriptor = -1
    installed = False
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(temporary, flags, 0o600, dir_fd=parent_fd)
        os.fchmod(descriptor, 0o600)
        encoded = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode()
        view = memoryview(encoded)
        while view:
            written = os.write(descriptor, view)
            view = view[written:]
        os.fsync(descriptor)
        if test_hook is not None:
            test_hook("owner_temp_fsynced", root)
        os.replace(temporary, _SHADOW_OWNER_FILE, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
        installed = True
        os.fsync(parent_fd)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if not installed:
            with suppress(FileNotFoundError):
                os.unlink(temporary, dir_fd=parent_fd)
        os.close(parent_fd)


def _recover_stale_identity_shadows(parent: Path) -> dict[str, list[str]]:
    """Remove only journaled dead probes; preserve live, foreign, and unsafe entries."""

    ensure_private_dir(parent)
    result: dict[str, list[str]] = {
        "removed": [],
        "live": [],
        "pending": [],
        "foreign": [],
        "unsafe": [],
    }
    for entry in sorted(os.scandir(parent), key=lambda item: item.name):
        name = entry.name
        if not name.startswith((".claude-base-", ".codex-base-")):
            result["foreign"].append(name)
            continue
        root = parent / name
        try:
            metadata = entry.stat(follow_symlinks=False)
            if (
                not stat.S_ISDIR(metadata.st_mode)
                or metadata.st_uid != os.getuid()
                or stat.S_IMODE(metadata.st_mode) != 0o700
            ):
                raise ValueError("unsafe shadow directory")
            try:
                owner = read_private_json(
                    root / _SHADOW_OWNER_FILE,
                    label="identity shadow owner",
                )
            except FileNotFoundError:
                with os.scandir(root) as contents:
                    entries = list(contents)
                age = max(0.0, time.time() - metadata.st_mtime)
                recoverable = not entries or all(
                    _recoverable_owner_temporary(candidate) for candidate in entries
                )
                if not recoverable:
                    raise ValueError("nonempty ownerless identity shadow") from None
                if age < _SHADOW_OWNERLESS_GRACE_SECONDS:
                    result["pending"].append(name)
                elif _remove_identity_shadow(
                    parent,
                    name,
                    (metadata.st_dev, metadata.st_ino),
                ):
                    result["removed"].append(name)
                continue
            pid, process_start = _validate_shadow_owner(
                owner,
                name,
                (metadata.st_dev, metadata.st_ino),
            )
            state = process_identity_state(pid, process_start)
            if state == "same":
                result["live"].append(name)
            elif state == "dead":
                if _remove_identity_shadow(
                    parent,
                    name,
                    (metadata.st_dev, metadata.st_ino),
                ):
                    result["removed"].append(name)
            else:
                result["unsafe"].append(name)
        except (OSError, ValueError):
            result["unsafe"].append(name)
    return result


class _BaseIdentityShadow:
    """Private crash-recoverable provider home with one stable credential snapshot."""

    def __init__(
        self,
        registry: Registry,
        profile: Profile,
        snapshot: tuple[str, tuple[Any, ...] | str | None],
        *,
        claude_keychain_marker: bytes | None = None,
        test_hook: Callable[[str, Path], None] | None = None,
    ) -> None:
        self.registry = registry
        self.profile = profile
        self.snapshot = snapshot
        self.parent = registry.settings.state_dir / "identity-shadows"
        self.name: str | None = None
        self.identity: tuple[int, int] | None = None
        self.claude_keychain_marker = claude_keychain_marker
        self.test_hook = test_hook

    def __enter__(self) -> Profile:
        recovered = _recover_stale_identity_shadows(self.parent)
        if recovered["unsafe"]:
            raise ValueError("unsafe identity shadow requires operator inspection")
        start = process_start_token(os.getpid())
        if start is None:
            raise ValueError("cannot establish identity shadow owner process")
        nonce = uuid.uuid4().hex
        self.name = f".{self.profile.provider}-base-{nonce}"
        parent_fd = open_private_dir(self.parent)
        try:
            os.mkdir(self.name, mode=0o700, dir_fd=parent_fd)
            metadata = os.stat(self.name, dir_fd=parent_fd, follow_symlinks=False)
            self.identity = (metadata.st_dev, metadata.st_ino)
        finally:
            os.close(parent_fd)
        root = self.parent / self.name
        try:
            if self.test_hook is not None:
                self.test_hook("directory_created", root)
            _publish_shadow_owner(
                root,
                {
                    "schema": 1,
                    "kind": "base-identity-shadow",
                    "provider": self.profile.provider,
                    "nonce": nonce,
                    "pid": os.getpid(),
                    "process_start": start,
                    "directory_name": self.name,
                    "directory_dev": self.identity[0],
                    "directory_ino": self.identity[1],
                    "created_at": utc_now(),
                },
                self.test_hook,
            )
            if self.test_hook is not None:
                self.test_hook("owner_published", root)
            home = root if self.profile.provider == "codex" else root / ".claude"
            ensure_private_dir(home)
            payload = _credential_payload_for_snapshot(self.profile, self.snapshot)
            if payload is not None:
                name = (
                    ".credentials.json" if self.profile.provider == "claude" else "auth.json"
                )
                atomic_write_bytes(home / name, payload, mode=0o600)
            if self.claude_keychain_marker is not None:
                if self.profile.provider != "claude":
                    raise ValueError("Keychain consent marker is valid only for Claude")
                marker = root / ".cache" / "quota-axi" / "claude-keychain-access-granted"
                ensure_private_dir(marker.parent)
                atomic_write_bytes(marker, self.claude_keychain_marker, mode=0o600)
            if self.test_hook is not None:
                self.test_hook("credential_copied", root)
            if _credential_snapshot(self.profile) != self.snapshot:
                raise ValueError("credential file changed before isolated identity proof")
            return replace(self.profile, home=home)
        except BaseException:
            self._cleanup()
            raise

    def _cleanup(self) -> None:
        if self.name is not None and self.identity is not None:
            _remove_identity_shadow(self.parent, self.name, self.identity)
        self.name = None
        self.identity = None

    def __exit__(self, *_exc: object) -> None:
        self._cleanup()


def _rpc_response(
    process: subprocess.Popen[bytes],
    expected_id: int,
    stdout_buffer: bytearray,
    stderr_buffer: bytearray,
    message_count: list[int],
    deadline: float,
) -> dict[str, Any]:
    assert process.stdout is not None
    assert process.stderr is not None
    streams = {process.stdout.fileno(): "stdout", process.stderr.fileno(): "stderr"}
    while True:
        while b"\n" in stdout_buffer:
            raw, _, remainder = stdout_buffer.partition(b"\n")
            stdout_buffer[:] = remainder
            if not raw.strip():
                continue
            try:
                message = json.loads(raw)
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise ValueError("Codex app-server emitted malformed JSON") from exc
            if not isinstance(message, dict):
                raise ValueError("Codex app-server protocol response mismatch")
            message_count[0] += 1
            if message_count[0] > 32:
                raise ValueError("Codex app-server emitted too many protocol messages")
            if "id" not in message:
                if (
                    isinstance(message.get("method"), str)
                    and isinstance(message.get("params", {}), dict)
                    and "result" not in message
                    and "error" not in message
                ):
                    continue
                raise ValueError("Codex app-server notification was malformed")
            if message.get("id") != expected_id:
                raise ValueError("Codex app-server protocol response mismatch")
            if message.get("error") is not None or not isinstance(message.get("result"), dict):
                raise ValueError("Codex app-server returned an RPC error")
            return message["result"]
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Codex app-server identity proof timed out")
        ready, _, _ = select.select(list(streams), [], [], remaining)
        if not ready:
            raise TimeoutError("Codex app-server identity proof timed out")
        for descriptor in ready:
            chunk = os.read(descriptor, 4096)
            if not chunk:
                streams.pop(descriptor, None)
                if process.poll() is not None and not streams:
                    raise ValueError("Codex app-server exited before identity proof")
                continue
            if streams[descriptor] == "stdout":
                stdout_buffer.extend(chunk)
                if len(stdout_buffer) > _CODEX_RPC_STDOUT_LIMIT:
                    raise ValueError("Codex app-server identity response exceeded its limit")
            elif len(stderr_buffer) < _CODEX_RPC_STDERR_LIMIT:
                remaining_stderr = _CODEX_RPC_STDERR_LIMIT - len(stderr_buffer)
                stderr_buffer.extend(chunk[:remaining_stderr])


def _codex_app_server_identity(
    profile: Profile,
    binary: Path,
    *,
    timeout: int,
) -> dict[str, Any]:
    argv = [str(binary), "-s", "read-only", "-a", "untrusted", "app-server"]
    environment = {
        "HOME": str(profile.home),
        "CODEX_HOME": str(profile.home),
        "CODEX_SQLITE_HOME": str(profile.home),
        "PATH": CONTROL_PATH,
        "LC_ALL": "C",
        "NO_COLOR": "1",
        "TERM": "dumb",
        "AGENT_FLEET_PROFILE": profile.id,
        "AGENT_FLEET_PROVIDER": "codex",
    }
    try:
        process = subprocess.Popen(
            argv,
            cwd=profile.home,
            env=environment,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError as exc:
        raise ValueError("Codex app-server identity proof could not start") from exc
    assert process.stdin is not None
    stdout_buffer = bytearray()
    stderr_buffer = bytearray()
    message_count = [0]
    deadline = time.monotonic() + timeout
    try:
        initialize = {
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "agent-fleet",
                    "title": "Agent Fleet",
                    "version": "1",
                }
            },
        }
        process.stdin.write((json.dumps(initialize, separators=(",", ":")) + "\n").encode())
        process.stdin.flush()
        _rpc_response(process, 1, stdout_buffer, stderr_buffer, message_count, deadline)
        messages = (
            {"method": "initialized", "params": {}},
            {
                "id": 2,
                "method": "account/read",
                "params": {"refreshToken": False},
            },
        )
        for message in messages:
            process.stdin.write((json.dumps(message, separators=(",", ":")) + "\n").encode())
        process.stdin.flush()
        result = _rpc_response(
            process,
            2,
            stdout_buffer,
            stderr_buffer,
            message_count,
            deadline,
        )
    finally:
        with suppress(OSError):
            process.stdin.close()
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)
    if set(result) != {"account", "requiresOpenaiAuth"}:
        raise ValueError("Codex app-server account response schema mismatch")
    account = result["account"]
    requires_openai_auth = result["requiresOpenaiAuth"]
    if account is None and requires_openai_auth is True:
        return {"status": "absent", "identity_fingerprint": None}
    if not isinstance(account, dict) or account.get("type") != "chatgpt":
        raise ValueError("Codex app-server reported an unsupported account mode")
    if requires_openai_auth is not True:
        raise ValueError("Codex app-server account response is not OpenAI-hosted")
    email = account.get("email")
    if not isinstance(email, str) or not email.strip():
        raise ValueError("Codex app-server account identity is unavailable")
    return {
        "status": "present",
        "identity_fingerprint": identity_fingerprint("codex", email.strip().casefold()),
    }


def _anchor_path(registry: Registry, provider: str, kind: str) -> Path:
    return registry.settings.state_dir / "identity-anchors" / f"{provider}-{kind}.json"


def identity_bundle_path(registry: Registry, provider: str) -> Path:
    return registry.settings.state_dir / "identity-bindings" / f"{provider}-bundle.json"


def _stable_profile_home(profile: Profile) -> str:
    try:
        resolved = profile.home.resolve(strict=True)
    except OSError as exc:
        raise ValueError(f"managed profile home is unavailable: {profile.home}") from exc
    if not resolved.is_dir() or resolved != Path(os.path.realpath(profile.home)):
        raise ValueError(f"managed profile home is not stable: {profile.home}")
    return str(resolved)


def read_identity_binding(registry: Registry, profile: Profile) -> dict[str, Any]:
    try:
        bundle = read_private_json(
            identity_bundle_path(registry, profile.provider),
            label="provider identity bundle",
        )
    except (FileNotFoundError, ValueError):
        return {"status": "unavailable", "reason": "identity_binding_missing"}
    if (
        not isinstance(bundle, dict)
        or bundle.get("schema") != 1
        or bundle.get("provider") != profile.provider
        or not isinstance(bundle.get("workers"), dict)
    ):
        return {"status": "unavailable", "reason": "identity_binding_invalid"}
    payload = bundle["workers"].get(profile.id)
    if not isinstance(payload, dict):
        return {"status": "unavailable", "reason": "identity_binding_missing"}
    return {"schema": 1, **payload}


def _external_observation_from_snapshots(
    registry: Registry,
    provider: str,
    snapshots: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    configured = registry.require_provider(provider)
    observation: dict[str, Any] = {"provider": provider}
    if configured.base_home is not None:
        base = snapshots.get("base", {"status": "unavailable"})
        status = base.get("status")
        fingerprint = base.get("identity_fingerprint")
        if status not in {"absent", "present"}:
            raise ValueError(f"{provider} base identity is indeterminate")
        if status == "present" and not (
            isinstance(fingerprint, str) and len(fingerprint) == 64
        ):
            raise ValueError(f"{provider} base identity fingerprint is unavailable")
        observation["base"] = {
            "home": str(configured.base_home),
            "status": status,
            "identity_fingerprint": fingerprint if status == "present" else None,
        }
    if provider == "claude" and configured.desktop_identity_file is not None:
        desktop = snapshots.get("desktop", {"status": "unavailable"})
        status = desktop.get("status")
        fingerprint = desktop.get("identity_fingerprint")
        if status not in {"absent", "present"}:
            raise ValueError("Claude Desktop identity is indeterminate")
        if status == "present" and not (
            isinstance(fingerprint, str) and len(fingerprint) == 64
        ):
            raise ValueError("Claude Desktop identity fingerprint is unavailable")
        observation["desktop"] = {
            "path": str(configured.desktop_identity_file),
            "status": status,
            "identity_fingerprint": fingerprint if status == "present" else None,
        }
    return observation


def _external_observation(registry: Registry, provider: str) -> dict[str, Any]:
    configured = registry.require_provider(provider)
    snapshots: dict[str, dict[str, Any]] = {}
    if configured.base_home is not None:
        snapshots["base"] = _read_anchor(registry, provider, "base")
    if provider == "claude" and configured.desktop_identity_file is not None:
        snapshots["desktop"] = _desktop_identity_snapshot(
            provider,
            configured.desktop_identity_file,
        )
    return _external_observation_from_snapshots(registry, provider, snapshots)


def adopt_provider_identity_bundle(
    registry: Registry,
    provider: str,
    proofs: dict[str, tuple[dict[str, Any], dict[str, Any]]],
    *,
    allow_keychain_prompt: bool = False,
) -> dict[str, Any]:
    workers = sorted(
        (
            profile
            for profile in registry.profiles.values()
            if profile.provider == provider and profile.safety_policy == "worker"
        ),
        key=lambda profile: profile.id,
    )
    expected_ids = {profile.id for profile in workers}
    if set(proofs) != expected_ids:
        raise ValueError("identity bundle requires one proof for every provider worker")
    refresh_provider_identity_anchors(
        registry,
        provider,
        allow_keychain_prompt=allow_keychain_prompt,
    )
    fingerprints: set[str] = set()
    bindings: dict[str, dict[str, Any]] = {}
    for profile in workers:
        quota, source_contract = proofs[profile.id]
        if not has_remote_identity_proof(quota):
            raise ValueError(f"cannot bind stale or unverified identity for {profile.id}")
        fingerprint = quota.get("identity_fingerprint")
        if not isinstance(fingerprint, str) or fingerprint in fingerprints:
            raise ValueError("provider identity bundle contains duplicate remote identities")
        fingerprints.add(fingerprint)
        bindings[profile.id] = {
            "profile": profile.id,
            "provider": profile.provider,
            "stable_home": _stable_profile_home(profile),
            "remote_fingerprint": fingerprint,
            "credential_source_contract": source_contract,
        }
    refresh_provider_identity_anchors(
        registry,
        provider,
        allow_keychain_prompt=allow_keychain_prompt,
    )
    external = _external_observation(registry, provider)
    for kind in ("base", "desktop"):
        observation = external.get(kind)
        if (
            isinstance(observation, dict)
            and observation.get("status") == "present"
            and observation.get("identity_fingerprint") in fingerprints
        ):
            raise ValueError(
                f"provider identity bundle conflicts with final {kind} identity"
            )
    payload = {
        "schema": 1,
        "provider": provider,
        "external": external,
        "workers": bindings,
        "adopted_at": utc_now(),
    }
    atomic_write_json(identity_bundle_path(registry, provider), payload)
    return payload


def verify_identity_bundle(
    registry: Registry,
    provider: str,
    *,
    compare_live_external: bool = False,
    observed_external: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Validate a provider bundle without invoking a provider or reading reserves."""

    try:
        payload = read_private_json(
            identity_bundle_path(registry, provider),
            label="provider identity bundle",
        )
    except (FileNotFoundError, ValueError) as exc:
        return {"provider": provider, "status": "invalid", "reason": type(exc).__name__}
    reason: str | None = None
    if not isinstance(payload, dict) or set(payload) != {
        "schema",
        "provider",
        "external",
        "workers",
        "adopted_at",
    }:
        reason = "closed_schema"
    elif payload.get("schema") != 1 or payload.get("provider") != provider:
        reason = "provider_or_schema"
    try:
        adopted = datetime.fromisoformat(str(payload.get("adopted_at", "")).replace("Z", "+00:00"))
    except ValueError:
        adopted = None
    if reason is None and (adopted is None or adopted.tzinfo is None):
        reason = "adopted_at"
    expected_workers = {
        profile.id: profile
        for profile in registry.profiles.values()
        if profile.provider == provider and profile.safety_policy == "worker"
    }
    workers = payload.get("workers") if isinstance(payload, dict) else None
    if reason is None and (
        not isinstance(workers, dict) or set(workers) != set(expected_workers)
    ):
        reason = "worker_set"
    if reason is None:
        for profile_id, profile in expected_workers.items():
            binding = workers[profile_id]
            if not isinstance(binding, dict) or set(binding) != {
                "profile",
                "provider",
                "stable_home",
                "remote_fingerprint",
                "credential_source_contract",
            }:
                reason = f"worker_schema:{profile_id}"
                break
            fingerprint = binding.get("remote_fingerprint")
            if (
                binding.get("profile") != profile.id
                or binding.get("provider") != provider
                or binding.get("stable_home") != _stable_profile_home(profile)
                or not isinstance(fingerprint, str)
                or len(fingerprint) != 64
                or any(character not in "0123456789abcdef" for character in fingerprint)
            ):
                reason = f"worker_identity:{profile_id}"
                break
            contract = binding.get("credential_source_contract")
            if not isinstance(contract, dict):
                reason = f"credential_source:{profile_id}"
                break
            if provider == "claude":
                allowed = (
                    set(contract) == {"kind", "path"}
                    and contract.get("kind") == "oauth-file"
                    and contract.get("path") == str(profile.home / ".credentials.json")
                ) or (
                    set(contract) == {"kind", "service", "account", "config_home"}
                    and contract.get("kind") == "keychain"
                    and contract.get("config_home") == str(profile.home)
                    and contract.get("account") == current_user_name()
                    and contract.get("service")
                    == "Claude Code-credentials-"
                    + sha256(
                        unicodedata.normalize("NFC", str(profile.home)).encode()
                    ).hexdigest()[:8]
                )
            else:
                allowed = (
                    set(contract) == {"kind", "path", "cli_rpc_path"}
                    and contract.get("kind") == "auth-json"
                    and contract.get("path") == str(profile.home / "auth.json")
                    and isinstance(contract.get("cli_rpc_path"), str)
                    and Path(contract["cli_rpc_path"]).is_absolute()
                )
            if not allowed:
                reason = f"credential_source:{profile_id}"
                break
    external = payload.get("external") if isinstance(payload, dict) else None
    if reason is None and not isinstance(external, dict):
        reason = "external_schema"
    if reason is None:
        configured = registry.require_provider(provider)
        expected_external_keys = {"provider"}
        if configured.base_home is not None:
            expected_external_keys.add("base")
        if provider == "claude" and configured.desktop_identity_file is not None:
            expected_external_keys.add("desktop")
        if set(external) != expected_external_keys or external.get("provider") != provider:
            reason = "external_schema"
        for kind in expected_external_keys - {"provider"}:
            item = external.get(kind)
            path_key = "home" if kind == "base" else "path"
            expected_path = (
                str(configured.base_home)
                if kind == "base"
                else str(configured.desktop_identity_file)
            )
            if (
                not isinstance(item, dict)
                or set(item) != {path_key, "status", "identity_fingerprint"}
                or item.get(path_key) != expected_path
                or item.get("status") not in {"absent", "present"}
            ):
                reason = f"external_{kind}"
                break
            fingerprint = item.get("identity_fingerprint")
            if item.get("status") == "absent":
                valid_fingerprint = fingerprint is None
            else:
                valid_fingerprint = (
                    isinstance(fingerprint, str)
                    and len(fingerprint) == 64
                    and all(character in "0123456789abcdef" for character in fingerprint)
                )
            if not valid_fingerprint:
                reason = f"external_{kind}_fingerprint"
                break
    if reason is None and (compare_live_external or observed_external is not None):
        if observed_external is not None:
            current = observed_external
        else:
            try:
                current = _external_observation(registry, provider)
            except ValueError:
                reason = "external_indeterminate"
                current = None
        if reason is None and external != current:
            reason = "external_changed"
    return {
        "provider": provider,
        "status": "verified" if reason is None else "invalid",
        "reason": reason,
    }


def identity_binding_conflict(
    registry: Registry,
    profile: Profile,
    quota: dict[str, Any],
    credential_source_contract: dict[str, Any] | None,
    *,
    observed_external: dict[str, Any] | None = None,
) -> str | None:
    try:
        bundle = read_private_json(
            identity_bundle_path(registry, profile.provider),
            label="provider identity bundle",
        )
    except (FileNotFoundError, ValueError):
        return "identity_binding_missing"
    if (
        not isinstance(bundle, dict)
        or bundle.get("schema") != 1
        or bundle.get("provider") != profile.provider
        or not isinstance(bundle.get("workers"), dict)
        or not isinstance(bundle.get("external"), dict)
    ):
        return "identity_binding_invalid"
    expected_workers = {
        candidate.id
        for candidate in registry.profiles.values()
        if candidate.provider == profile.provider and candidate.safety_policy == "worker"
    }
    if set(bundle["workers"]) != expected_workers:
        return "identity_binding_worker_set_changed"
    binding = bundle["workers"].get(profile.id)
    if not isinstance(binding, dict):
        return "identity_binding_missing"
    if binding.get("profile") != profile.id or binding.get("provider") != profile.provider:
        return "identity_binding_profile_mismatch"
    try:
        stable_home = _stable_profile_home(profile)
    except ValueError:
        return "identity_binding_home_unavailable"
    if binding.get("stable_home") != stable_home:
        return "identity_binding_home_mismatch"
    if quota.get("identity_fingerprint") != binding.get("remote_fingerprint"):
        return "identity_binding_remote_mismatch"
    if credential_source_contract is None:
        return "credential_source_unverified"
    if binding.get("credential_source_contract") != credential_source_contract:
        return "credential_source_changed"
    if observed_external is None:
        try:
            current = _external_observation(registry, profile.provider)
        except ValueError:
            return "external_identity_indeterminate"
    else:
        current = observed_external
        if current.get("provider") != profile.provider:
            return "external_identity_indeterminate"
    if bundle["external"] != current:
        return "external_identity_changed"
    return None


def _age_seconds(value: Any) -> int | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    return max(0, int((datetime.now(UTC) - parsed.astimezone(UTC)).total_seconds()))


def _read_anchor(registry: Registry, provider: str, kind: str) -> dict[str, Any]:
    try:
        payload = read_private_json(_anchor_path(registry, provider, kind), label="identity anchor")
    except (FileNotFoundError, ValueError):
        return {"status": "unavailable", "reason": "identity_anchor_missing"}
    return (
        payload
        if isinstance(payload, dict)
        else {
            "status": "unavailable",
            "reason": "identity_anchor_invalid",
        }
    )


def _quota_identity_is_verified(quota: dict[str, Any]) -> bool:
    return has_remote_identity_proof(quota)


def _managed_identity_has_recent_proof(quota: dict[str, Any]) -> bool:
    return _quota_identity_is_verified(quota) or quota.get("verified_recent") is True


def _anchor_is_fresh(registry: Registry, anchor: dict[str, Any]) -> bool:
    age = _age_seconds(anchor.get("refreshed_at"))
    return age is not None and age <= registry.settings.quota_stale_seconds


def _desktop_identity_snapshot(provider: str, desktop_file: Path) -> dict[str, Any]:
    try:
        payload = read_owned_private_json(desktop_file, label="desktop identity file")
    except FileNotFoundError:
        payload = None
        desktop_status = "absent"
        reason = "desktop_identity_missing"
    except ValueError as exc:
        payload = None
        desktop_status = "indeterminate"
        reason = type(exc).__name__
    else:
        desktop_status = "present"
        reason = None
    identifier = payload.get("lastKnownAccountUuid") if isinstance(payload, dict) else None
    if desktop_status == "present" and not (isinstance(identifier, str) and identifier):
        desktop_status = "indeterminate"
        reason = "desktop_identity_invalid"
    return {
        "schema": 1,
        "provider": provider,
        "kind": "desktop",
        "status": desktop_status,
        "reason": reason,
        "identity_fingerprint": (
            identity_fingerprint(provider, identifier)
            if isinstance(identifier, str) and identifier
            else None
        ),
        "refreshed_at": utc_now(),
    }


def _refresh_desktop_identity_anchor(
    registry: Registry,
    provider: str,
    desktop_file: Path,
) -> dict[str, Any]:
    result = _desktop_identity_snapshot(provider, desktop_file)
    atomic_write_json(_anchor_path(registry, provider, "desktop"), result)
    return result


def _prepare_claude_default_keychain_probe(
    registry: Registry,
    *,
    allow_keychain_prompt: bool,
    timeout: int,
) -> tuple[
    str,
    str | None,
    bytes | None,
    tuple[str, tuple[Any, ...] | str | None],
]:
    """Authorize one shadowed default-Keychain probe without reading its value."""

    marker_snapshot = _claude_keychain_marker_snapshot()
    if marker_snapshot[0] == "indeterminate":
        raise ValueError("Claude Keychain consent marker is unsafe")
    metadata_state, metadata_digest = _claude_keychain_metadata_snapshot(timeout=timeout)
    if metadata_state == "absent":
        return metadata_state, None, None, marker_snapshot
    if metadata_state != "present" or not isinstance(metadata_digest, str):
        raise ValueError("Claude Keychain metadata is indeterminate")
    marker_payload = _claude_keychain_marker_payload_for_snapshot(marker_snapshot)
    if not allow_keychain_prompt:
        if marker_payload is None:
            raise ValueError("Claude Keychain consent has not been granted")
        if not _claude_keychain_grant_matches(registry, metadata_digest):
            raise ValueError("Claude Keychain grant contract is stale or unavailable")
    return metadata_state, metadata_digest, marker_payload, marker_snapshot


def _revalidate_claude_default_keychain_probe(
    registry: Registry,
    *,
    metadata_digest: str,
    marker_snapshot: tuple[str, tuple[Any, ...] | str | None],
    allow_keychain_prompt: bool,
    timeout: int,
) -> None:
    metadata_state, metadata_after = _claude_keychain_metadata_snapshot(timeout=timeout)
    if metadata_state != "present" or metadata_after != metadata_digest:
        raise ValueError("Claude Keychain item changed during identity proof")
    if _claude_keychain_marker_snapshot() != marker_snapshot:
        raise ValueError("Claude Keychain consent marker changed during identity proof")
    if allow_keychain_prompt:
        _record_claude_keychain_grant(registry, metadata_digest)
    elif not _claude_keychain_grant_matches(registry, metadata_digest):
        raise ValueError("Claude Keychain grant contract changed during identity proof")


def refresh_provider_identity_anchors(
    registry: Registry,
    provider: str,
    *,
    allow_keychain_prompt: bool = False,
    timeout: int = 30,
    write: bool = True,
) -> dict[str, dict[str, Any]]:
    provider_config = registry.require_provider(provider)
    results: dict[str, dict[str, Any]] = {}
    if provider_config.base_home is not None:
        base = Profile(
            id=f"{provider}-base-anchor",
            provider=provider,
            home=provider_config.base_home,
            pools=(f"{provider}-manual",),
            enabled=False,
            safety_policy="desktop_shared",
        )
        try:
            resolved_home = validated_safe_directory(base.home, label=f"{provider} base home")
            if resolved_home != base.home or resolved_home.stat().st_uid != os.getuid():
                raise ValueError(f"{provider} base home must be a physical current-user directory")
            file_before = _credential_snapshot(base)
            file_state = file_before[0]
            if file_state == "indeterminate":
                raise ValueError("credential_file_indeterminate")
        except (OSError, ValueError) as exc:
            base_result = {
                "schema": 1,
                "provider": provider,
                "kind": "base",
                "home": str(provider_config.base_home),
                "status": "indeterminate",
                "reason": type(exc).__name__,
                "identity_fingerprint": None,
                "refreshed_at": utc_now(),
            }
        else:
            try:
                default_provider_home = (
                    provider == "claude"
                    and provider_config.base_home == current_user_home() / ".claude"
                )
                keychain_probe: tuple[
                    str,
                    str | None,
                    bytes | None,
                    tuple[str, tuple[Any, ...] | str | None],
                ] | None = None
                if default_provider_home and file_state == "absent":
                    keychain_probe = _prepare_claude_default_keychain_probe(
                        registry,
                        allow_keychain_prompt=allow_keychain_prompt,
                        timeout=timeout,
                    )
                if keychain_probe is not None and keychain_probe[0] == "absent":
                    metadata_after, _ = _claude_keychain_metadata_snapshot(timeout=timeout)
                    if metadata_after != "absent":
                        raise ValueError("Claude Keychain item appeared during identity proof")
                    status = "absent"
                    reason = "credentials_missing"
                    fingerprint = None
                else:
                    marker_payload = keychain_probe[2] if keychain_probe is not None else None
                    with _BaseIdentityShadow(
                        registry,
                        base,
                        file_before,
                        claude_keychain_marker=marker_payload,
                    ) as shadow:
                        if provider == "codex":
                            from .provision import verified_configured_provider_binary

                            rpc_identity = _codex_app_server_identity(
                                shadow,
                                verified_configured_provider_binary(registry, provider),
                                timeout=timeout,
                            )
                            if rpc_identity["status"] == "absent":
                                if file_state != "absent":
                                    raise ValueError(
                                        "Codex file and app-server identities disagree"
                                    )
                                status = "absent"
                                reason = "credentials_missing"
                                fingerprint = None
                            else:
                                quota = probe_quota(registry, shadow, timeout=timeout)
                                fingerprint = quota.get("identity_fingerprint")
                                if (
                                    not _quota_identity_is_verified(quota)
                                    or fingerprint != rpc_identity["identity_fingerprint"]
                                ):
                                    raise ValueError(
                                        "Codex shadow Quota and app-server identities disagree"
                                    )
                                status = "present"
                                reason = None
                        else:
                            quota = probe_quota(
                                registry,
                                shadow,
                                timeout=timeout,
                                allow_keychain_prompt=allow_keychain_prompt,
                                default_provider_home=default_provider_home,
                            )
                            if (
                                keychain_probe is not None
                                and quota.get("credential_keychain_account")
                                != current_user_name()
                            ):
                                raise ValueError(
                                    "Quota runtime did not bind the exact Claude Keychain account"
                                )
                            fingerprint = quota.get("identity_fingerprint")
                            reason = quota.get("reason")
                            if _quota_identity_is_verified(quota):
                                status = "present"
                            elif (
                                file_state == "absent"
                                and keychain_probe is None
                                and quota.get("credential_state") == "absent"
                            ):
                                status = "absent"
                                reason = "credentials_missing"
                                fingerprint = None
                            else:
                                status = "indeterminate"
                                reason = reason or "base_identity_unavailable"
                                fingerprint = None
                    if keychain_probe is not None:
                        metadata_digest = keychain_probe[1]
                        if not isinstance(metadata_digest, str):
                            raise ValueError("Claude Keychain metadata digest is unavailable")
                        _revalidate_claude_default_keychain_probe(
                            registry,
                            metadata_digest=metadata_digest,
                            marker_snapshot=keychain_probe[3],
                            allow_keychain_prompt=(
                                allow_keychain_prompt and status == "present"
                            ),
                            timeout=timeout,
                        )
                if _credential_snapshot(base) != file_before:
                    raise ValueError(
                        f"credential file changed during isolated {provider} base identity proof"
                    )
            except (OSError, TimeoutError, ValueError) as exc:
                base_result = {
                    "schema": 1,
                    "provider": provider,
                    "kind": "base",
                    "home": str(provider_config.base_home),
                    "status": "indeterminate",
                    "reason": type(exc).__name__,
                    "identity_fingerprint": None,
                    "refreshed_at": utc_now(),
                }
            else:
                base_result = {
                    "schema": 1,
                    "provider": provider,
                    "kind": "base",
                    "home": str(provider_config.base_home),
                    "status": status,
                    "reason": reason,
                    "identity_fingerprint": fingerprint,
                    "refreshed_at": utc_now(),
                }
        if write:
            atomic_write_json(_anchor_path(registry, provider, "base"), base_result)
        results["base"] = base_result
    if provider == "claude" and provider_config.desktop_identity_file is not None:
        desktop_result = (
            _refresh_desktop_identity_anchor(
                registry,
                provider,
                provider_config.desktop_identity_file,
            )
            if write
            else _desktop_identity_snapshot(
                provider,
                provider_config.desktop_identity_file,
            )
        )
        results["desktop"] = desktop_result
    return results


def probe_provider_external_observation(
    registry: Registry,
    provider: str,
    *,
    timeout: int = 30,
) -> dict[str, Any]:
    snapshots = refresh_provider_identity_anchors(
        registry,
        provider,
        timeout=timeout,
        write=False,
    )
    return _external_observation_from_snapshots(registry, provider, snapshots)


def refresh_provider_identity_anchors_if_due(
    registry: Registry,
    provider: str,
    *,
    timeout: int = 30,
) -> None:
    provider_config = registry.require_provider(provider)
    # Default CLI/Desktop credentials can switch between any two route
    # attempts. Refresh both providers on every real selection so quota-cache
    # TTL cannot conceal an absent->duplicate transition.
    due = provider_config.base_home is not None
    if provider == "claude" and provider_config.desktop_identity_file is not None:
        # Desktop can switch accounts between two route attempts. This local
        # JSON read is cheap and must not inherit the base quota anchor's TTL.
        _refresh_desktop_identity_anchor(
            registry,
            provider,
            provider_config.desktop_identity_file,
        )
    if due:
        refresh_provider_identity_anchors(registry, provider, timeout=timeout)


def identity_conflict(
    registry: Registry,
    profile: Profile,
    quota: dict[str, Any],
    *,
    require_complete_worker_set: bool = True,
    observed_external: dict[str, Any] | None = None,
) -> str | None:
    fingerprint = quota.get("identity_fingerprint")
    if not isinstance(fingerprint, str) or len(fingerprint) != 64:
        return "identity_unavailable"
    if observed_external is not None and observed_external.get("provider") != profile.provider:
        return "external_identity_unverified"
    for other in registry.profiles.values():
        if (
            other.id == profile.id
            or other.provider != profile.provider
            or other.safety_policy != "worker"
        ):
            continue
        other_quota = read_quota(registry, other.id)
        other_fingerprint = other_quota.get("identity_fingerprint")
        has_recent_proof = _managed_identity_has_recent_proof(other_quota)
        required_worker = other.enabled
        if require_complete_worker_set and required_worker and not has_recent_proof:
            return f"managed_identity_unverified:{other.id}"
        if not has_recent_proof:
            continue
        if not isinstance(other_fingerprint, str) or len(other_fingerprint) != 64:
            if require_complete_worker_set and required_worker:
                return f"managed_identity_unverified:{other.id}"
            continue
        if other_fingerprint == fingerprint:
            return f"managed:{other.id}"
    provider_config = registry.require_provider(profile.provider)
    if provider_config.base_home is not None and profile.home == provider_config.base_home:
        return "base_home_overlap"
    if provider_config.base_home is not None:
        base = (
            observed_external.get("base", {})
            if observed_external is not None
            and observed_external.get("provider") == profile.provider
            else _read_anchor(registry, profile.provider, "base")
        )
        base_status = str(base.get("status", "unavailable"))
        base_fingerprint = base.get("identity_fingerprint")
        if base.get("home") != str(provider_config.base_home):
            return "base_identity_unverified:base_home_changed"
        if observed_external is None and not _anchor_is_fresh(registry, base):
            return "base_identity_unverified:stale"
        if base_status == "absent":
            pass
        elif base_status == "present":
            if not isinstance(base_fingerprint, str) or len(base_fingerprint) != 64:
                return "base_identity_unverified:missing_fingerprint"
            if base_fingerprint == fingerprint:
                return "base_identity"
        else:
            return f"base_identity_unverified:{base.get('reason') or base_status}"
    if profile.provider == "claude" and provider_config.desktop_identity_file is not None:
        desktop = (
            observed_external.get("desktop", {})
            if observed_external is not None
            and observed_external.get("provider") == profile.provider
            else _desktop_identity_snapshot(
                profile.provider,
                provider_config.desktop_identity_file,
            )
        )
        desktop_status = desktop.get("status")
        desktop_fingerprint = desktop.get("identity_fingerprint")
        if observed_external is None and not _anchor_is_fresh(registry, desktop):
            return "desktop_identity_unverified"
        if desktop_status == "absent":
            return None
        if desktop_status != "present":
            return "desktop_identity_unverified"
        if not isinstance(desktop_fingerprint, str) or len(desktop_fingerprint) != 64:
            return "desktop_identity_unverified"
        if desktop_fingerprint == fingerprint:
            return "desktop_identity"
    return None
