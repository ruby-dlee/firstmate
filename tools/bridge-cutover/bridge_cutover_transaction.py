#!/usr/bin/env python3
"""Restartable, fail-closed Bridge cutover transaction driver.

The driver intentionally knows nothing about a particular installation.  Every
path and every acceptable old/new state comes from an explicit JSON manifest.
The default command is a read-only plan.  Mutations require both a CLI action
flag and ``"apply_opt_in": true`` in the manifest.

Only Python's standard library is used so the driver remains usable while the
runtime symlinks it is intended to switch are themselves in transition.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import pwd
import re
import stat
import subprocess
import sys
import tomllib
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence


SCHEMA_VERSION = 1
JOURNAL_SCHEMA_VERSION = 2
MAX_MANIFEST_BYTES = 1_000_000
MAX_JOURNAL_BYTES = 4_000_000
MAX_JOURNAL_HISTORY_ENTRIES = 20_000
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
KNOWN_BROAD_PATHS = {
    "/",
    "/Users",
    "/home",
    "/opt",
    "/srv",
    "/tmp",
    "/private/tmp",
    "/var",
    "/private/var",
}


class CutoverError(RuntimeError):
    """A validation or safety refusal."""


class InjectedFailure(RuntimeError):
    """A deterministic test-only crash at a durability boundary."""


class BoundaryController:
    """Records durability boundaries and optionally fails once at one label."""

    def __init__(self, fail_at: str | None = None) -> None:
        self.fail_at = fail_at
        self.seen: list[str] = []
        self._failed = False

    def hit(self, label: str) -> None:
        self.seen.append(label)
        if self.fail_at == label and not self._failed:
            self._failed = True
            raise InjectedFailure(f"injected failure at {label}")


@dataclass(frozen=True)
class ReleaseProof:
    relative_path: str
    path: Path
    sha256: str
    mode: int


@dataclass(frozen=True)
class SymlinkOperation:
    name: str
    path: Path
    old_target: str
    new_target: str
    old_target_path: Path
    new_target_path: Path
    old_proofs: tuple[ReleaseProof, ...]
    new_proofs: tuple[ReleaseProof, ...]
    old_tree_sha256: str
    new_tree_sha256: str


@dataclass(frozen=True)
class RegularFileOperation:
    name: str
    path: Path
    old_source: Path
    new_source: Path
    old_sha256: str
    new_sha256: str
    mode: int


@dataclass(frozen=True)
class RegistryOperation(RegularFileOperation):
    """The unique regular-file operation that owns the account registry."""


Operation = SymlinkOperation | RegularFileOperation


@dataclass(frozen=True)
class QuietPoint:
    profile_ids: tuple[str, ...]
    worker_profile_ids: tuple[str, ...]
    never_enroll_profile_ids: tuple[str, ...]
    routing_absent_paths: tuple[Path, ...]
    backend_path: Path
    backend_sha256: str
    state_quiet_paths: tuple[Path, ...]
    forbidden_process_tokens: tuple[str, ...]
    ps_binary: Path
    ps_binary_sha256: str


@dataclass(frozen=True)
class Manifest:
    path: Path
    fingerprint: str
    transaction_id: str
    apply_opt_in: bool
    allowed_roots: tuple[Path, ...]
    lock_path: Path
    journal_path: Path
    quiet_point: QuietPoint
    operations: tuple[Operation, ...]


def _require_exact_keys(
    value: Mapping[str, Any], required: set[str], optional: set[str], label: str
) -> None:
    missing = required - set(value)
    unknown = set(value) - required - optional
    if missing:
        raise CutoverError(f"{label} is missing keys: {', '.join(sorted(missing))}")
    if unknown:
        raise CutoverError(f"{label} has unknown keys: {', '.join(sorted(unknown))}")


def _explicit_absolute_path(value: Any, label: str) -> Path:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise CutoverError(f"{label} must be a non-empty absolute path string")
    if "$" in value:
        raise CutoverError(f"{label} may not contain shell-variable syntax")
    if value.startswith("~/"):
        value = os.path.join(pwd.getpwuid(os.getuid()).pw_dir, value[2:])
    if value != os.path.normpath(value) or not os.path.isabs(value):
        raise CutoverError(f"{label} must be an absolute normalized path: {value!r}")
    return Path(value)


def _normalized_relative_path(value: Any, label: str) -> Path:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise CutoverError(f"{label} must be a non-empty relative path string")
    if "$" in value:
        raise CutoverError(f"{label} may not contain shell-variable syntax")
    if os.path.isabs(value) or value != os.path.normpath(value):
        raise CutoverError(f"{label} must be a normalized relative path: {value!r}")
    parts = Path(value).parts
    if not parts or any(part in ("", ".", "..") for part in parts):
        raise CutoverError(f"{label} may not contain '.' or '..': {value!r}")
    return Path(value)


def _parse_symlink_target(value: Any, link_parent: Path, label: str) -> tuple[str, Path]:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise CutoverError(f"{label} must be a non-empty path string")
    if os.path.isabs(value):
        resolved = _explicit_absolute_path(value, label)
    else:
        relative = _normalized_relative_path(value, label)
        resolved = link_parent / relative
    return value, resolved


def _lstat(path: Path, label: str) -> os.stat_result:
    try:
        return os.lstat(path)
    except FileNotFoundError as exc:
        raise CutoverError(f"{label} does not exist: {path}") from exc


def _require_single_link(info: os.stat_result, path: Path, label: str) -> None:
    if info.st_nlink != 1:
        raise CutoverError(f"{label} must have exactly one hard link: {path}")


def _require_owner(
    info: os.stat_result,
    path: Path,
    label: str,
    *,
    allow_root: bool = False,
) -> None:
    allowed_uids = {os.getuid()}
    if allow_root:
        allowed_uids.add(0)
    if info.st_uid not in allowed_uids:
        expected = "root or current uid" if allow_root else "current uid"
        raise CutoverError(
            f"{label} owner uid is {info.st_uid}; expected {expected}: {path}"
        )


def _require_regular(
    path: Path,
    label: str,
    expected_mode: int | None = None,
    *,
    allow_root: bool = False,
) -> None:
    info = _lstat(path, label)
    if not stat.S_ISREG(info.st_mode):
        raise CutoverError(f"{label} must be a regular non-symlink file: {path}")
    _require_owner(info, path, label, allow_root=allow_root)
    _require_single_link(info, path, label)
    if expected_mode is not None and stat.S_IMODE(info.st_mode) != expected_mode:
        raise CutoverError(
            f"{label} mode is {stat.S_IMODE(info.st_mode):04o}; "
            f"expected {expected_mode:04o}: {path}"
        )


def _require_directory(path: Path, label: str, private: bool = False) -> None:
    info = _lstat(path, label)
    if not stat.S_ISDIR(info.st_mode):
        raise CutoverError(f"{label} must be a real directory, not a symlink: {path}")
    _require_owner(info, path, label)
    if private and stat.S_IMODE(info.st_mode) & 0o077:
        raise CutoverError(
            f"{label} must not grant group/other permissions: {path} "
            f"({stat.S_IMODE(info.st_mode):04o})"
        )


def _is_relative_to(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def _owning_root(path: Path, roots: Sequence[Path], label: str) -> Path:
    matches = [root for root in roots if path != root and _is_relative_to(path, root)]
    if len(matches) != 1:
        raise CutoverError(
            f"{label} must be strictly beneath exactly one allowed root: {path}"
        )
    return matches[0]


def _require_real_parent_chain(path: Path, root: Path, label: str) -> None:
    """Refuse redirection through a symlink between an allowed root and path."""

    _require_directory(root, "allowed root")
    parent = path.parent
    if not _is_relative_to(parent, root) and parent != root:
        raise CutoverError(f"{label} parent escapes its allowed root: {path}")
    flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        current_fd = os.open(root, flags)
    except OSError as exc:
        raise CutoverError(f"cannot safely open allowed root {root}: {exc}") from exc
    try:
        root_info = os.fstat(current_fd)
        if not stat.S_ISDIR(root_info.st_mode):
            raise CutoverError(f"allowed root is not a directory: {root}")
        _require_owner(root_info, root, "allowed root")
        current_path = root
        for part in parent.relative_to(root).parts:
            try:
                next_fd = os.open(part, flags, dir_fd=current_fd)
            except OSError as exc:
                raise CutoverError(
                    f"{label} parent component is missing, not a directory, or a symlink: "
                    f"{part}: {exc}"
                ) from exc
            os.close(current_fd)
            current_fd = next_fd
            current_path /= part
            component_info = os.fstat(current_fd)
            if not stat.S_ISDIR(component_info.st_mode):
                raise CutoverError(
                    f"{label} parent component is not a directory: {part}"
                )
            _require_owner(
                component_info,
                current_path,
                f"{label} parent component",
            )
    finally:
        os.close(current_fd)


def _open_regular_readonly(
    path: Path,
    label: str,
    expected_mode: int | None = None,
    *,
    allow_root: bool = False,
) -> tuple[int, os.stat_result]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        raise CutoverError(f"cannot safely open {label}: {path}: {exc}") from exc
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise CutoverError(f"{label} must be a regular non-symlink file: {path}")
        _require_owner(info, path, label, allow_root=allow_root)
        _require_single_link(info, path, label)
        if expected_mode is not None and stat.S_IMODE(info.st_mode) != expected_mode:
            raise CutoverError(
                f"{label} mode is {stat.S_IMODE(info.st_mode):04o}; "
                f"expected {expected_mode:04o}: {path}"
            )
        return fd, info
    except BaseException:
        os.close(fd)
        raise


def _require_stable_regular_fd(
    fd: int,
    before: os.stat_result,
    path: Path,
    label: str,
) -> None:
    after = os.fstat(fd)
    _require_single_link(after, path, label)
    before_identity = (
        before.st_dev,
        before.st_ino,
        before.st_mode,
        before.st_size,
        before.st_mtime_ns,
        before.st_ctime_ns,
        before.st_nlink,
        before.st_uid,
    )
    after_identity = (
        after.st_dev,
        after.st_ino,
        after.st_mode,
        after.st_size,
        after.st_mtime_ns,
        after.st_ctime_ns,
        after.st_nlink,
        after.st_uid,
    )
    if after_identity != before_identity:
        raise CutoverError(f"{label} changed while reading: {path}")


def _sha256_fd(fd: int, max_bytes: int | None = None) -> str:
    digest = hashlib.sha256()
    total = 0
    while True:
        block = os.read(fd, 1024 * 1024)
        if not block:
            break
        total += len(block)
        if max_bytes is not None and total > max_bytes:
            raise CutoverError("file exceeds safety size limit")
        digest.update(block)
    return digest.hexdigest()


def _sha256_file(
    path: Path,
    max_bytes: int | None = None,
    *,
    label: str = "file",
    expected_mode: int | None = None,
) -> str:
    fd, info = _open_regular_readonly(path, label, expected_mode)
    try:
        digest = _sha256_fd(fd, max_bytes)
        _require_stable_regular_fd(fd, info, path, label)
        return digest
    finally:
        os.close(fd)


def _read_stable_bytes(
    path: Path,
    label: str,
    expected_mode: int | None = None,
    max_bytes: int = MAX_MANIFEST_BYTES,
    *,
    allow_root: bool = False,
) -> bytes:
    fd, info = _open_regular_readonly(
        path, label, expected_mode, allow_root=allow_root
    )
    try:
        chunks: list[bytes] = []
        total = 0
        while True:
            block = os.read(fd, min(1024 * 1024, max_bytes + 1 - total))
            if not block:
                break
            total += len(block)
            if total > max_bytes:
                raise CutoverError(f"{label} exceeds {max_bytes} bytes: {path}")
            chunks.append(block)
        _require_stable_regular_fd(fd, info, path, label)
        current = os.lstat(path)
        if (
            current.st_dev != info.st_dev
            or current.st_ino != info.st_ino
            or current.st_mode != info.st_mode
            or current.st_nlink != info.st_nlink
        ):
            raise CutoverError(f"{label} path changed while reading: {path}")
        return b"".join(chunks)
    finally:
        os.close(fd)


def _tree_hash_field(digest: Any, value: bytes) -> None:
    digest.update(len(value).to_bytes(8, "big"))
    digest.update(value)


def _validate_release_entry_policy(path: Path, info: os.stat_result, label: str) -> None:
    if info.st_uid != os.getuid():
        raise CutoverError(
            f"{label} owner uid is {info.st_uid}; expected current uid {os.getuid()}: {path}"
        )
    if not stat.S_ISLNK(info.st_mode) and stat.S_IMODE(info.st_mode) & 0o022:
        raise CutoverError(f"{label} is group- or other-writable: {path}")
    if stat.S_ISREG(info.st_mode):
        _require_single_link(info, path, label)


def _release_tree_sha256_once(root: Path, label: str) -> str:
    root_info = _lstat(root, label)
    if not stat.S_ISDIR(root_info.st_mode):
        raise CutoverError(f"{label} must be a real release directory: {root}")
    _validate_release_entry_policy(root, root_info, label)
    digest = hashlib.sha256()
    digest.update(b"bridge-release-tree-v1\x00")

    def record_header(kind: bytes, relative: bytes, mode: int) -> None:
        digest.update(kind)
        _tree_hash_field(digest, relative)
        digest.update(mode.to_bytes(4, "big"))

    record_header(b"D", b"", stat.S_IMODE(root_info.st_mode))

    def walk(directory: Path) -> None:
        try:
            entries = sorted(
                list(os.scandir(directory)), key=lambda entry: os.fsencode(entry.name)
            )
        except OSError as exc:
            raise CutoverError(f"cannot scan {label}: {directory}: {exc}") from exc
        for entry in entries:
            path = Path(entry.path)
            relative = os.fsencode(str(path.relative_to(root)))
            try:
                info = entry.stat(follow_symlinks=False)
            except OSError as exc:
                raise CutoverError(f"cannot stat {label} entry: {path}: {exc}") from exc
            _validate_release_entry_policy(path, info, label)
            mode = stat.S_IMODE(info.st_mode)
            if stat.S_ISDIR(info.st_mode):
                record_header(b"D", relative, mode)
                walk(path)
            elif stat.S_ISREG(info.st_mode):
                record_header(b"F", relative, mode)
                digest.update(info.st_size.to_bytes(8, "big"))
                fd, opened = _open_regular_readonly(path, label, mode)
                try:
                    if (opened.st_dev, opened.st_ino, opened.st_size) != (
                        info.st_dev,
                        info.st_ino,
                        info.st_size,
                    ):
                        raise CutoverError(f"{label} entry changed while opening: {path}")
                    while True:
                        block = os.read(fd, 1024 * 1024)
                        if not block:
                            break
                        digest.update(block)
                    _require_stable_regular_fd(fd, opened, path, label)
                finally:
                    os.close(fd)
            elif stat.S_ISLNK(info.st_mode):
                record_header(b"L", relative, mode)
                try:
                    payload = os.readlink(path)
                except OSError as exc:
                    raise CutoverError(f"cannot read {label} symlink: {path}: {exc}") from exc
                _tree_hash_field(digest, os.fsencode(payload))
                lexical = (
                    Path(os.path.normpath(payload))
                    if os.path.isabs(payload)
                    else Path(os.path.normpath(path.parent / payload))
                )
                if not _is_relative_to(lexical, root):
                    raise CutoverError(f"{label} symlink escapes release tree: {path} -> {payload}")
                if not os.path.exists(path):
                    raise CutoverError(f"{label} symlink is dangling or cyclic: {path} -> {payload}")
                resolved = Path(os.path.realpath(path))
                if not _is_relative_to(resolved, root):
                    raise CutoverError(f"{label} symlink resolves outside release tree: {path}")
            else:
                raise CutoverError(f"{label} contains a special file: {path}")

    walk(root)
    after_root = _lstat(root, label)
    if (
        after_root.st_dev != root_info.st_dev
        or after_root.st_ino != root_info.st_ino
        or after_root.st_mode != root_info.st_mode
    ):
        raise CutoverError(f"{label} root changed while hashing: {root}")
    return digest.hexdigest()


def compute_release_tree_sha256(root: Path, label: str = "release tree") -> str:
    """Return a stable full-tree digest or refuse an unsafe/active tree."""

    if not root.is_absolute() or Path(os.path.normpath(str(root))) != root:
        raise CutoverError(f"{label} root must be an absolute normalized path: {root}")
    if Path(os.path.realpath(root)) != root:
        raise CutoverError(f"{label} root is symlinked or non-canonical: {root}")
    first = _release_tree_sha256_once(root, label)
    second = _release_tree_sha256_once(root, label)
    if first != second:
        raise CutoverError(f"{label} changed between consecutive snapshots: {root}")
    return first


def _read_json_file(
    path: Path,
    max_bytes: int,
    label: str,
    expected_mode: int | None = None,
) -> Any:
    fd, info = _open_regular_readonly(path, label, expected_mode)
    try:
        if info.st_size > max_bytes:
            raise CutoverError(f"{label} exceeds {max_bytes} bytes: {path}")
        chunks: list[bytes] = []
        total = 0
        while True:
            block = os.read(fd, min(1024 * 1024, max_bytes + 1 - total))
            if not block:
                break
            total += len(block)
            if total > max_bytes:
                raise CutoverError(f"{label} exceeds {max_bytes} bytes: {path}")
            chunks.append(block)
        payload = b"".join(chunks)
        _require_stable_regular_fd(fd, info, path, label)
        return json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CutoverError(f"{label} is not valid UTF-8 JSON: {path}: {exc}") from exc
    finally:
        os.close(fd)


def _parse_mode(value: Any, label: str) -> int:
    if not isinstance(value, str) or not re.fullmatch(r"0[0-7]{3}", value):
        raise CutoverError(f"{label} must be a four-digit octal string")
    return int(value, 8)


def _parse_hash(value: Any, label: str) -> str:
    if not isinstance(value, str) or not SHA256.fullmatch(value):
        raise CutoverError(f"{label} must be a lowercase SHA-256 digest")
    return value


def _parse_proof_mode(value: Any, label: str) -> int:
    if not isinstance(value, str) or not re.fullmatch(r"0[0-7]{3}", value):
        raise CutoverError(f"{label} must be a four-digit octal string")
    mode = int(value, 8)
    if mode & 0o022:
        raise CutoverError(f"{label} must not be group- or other-writable")
    return mode


def _validate_release_proof(proof: ReleaseProof, label: str) -> None:
    fd, info = _open_regular_readonly(proof.path, label, proof.mode)
    try:
        if info.st_uid != os.getuid():
            raise CutoverError(
                f"{label} owner uid is {info.st_uid}; expected current uid {os.getuid()}: "
                f"{proof.path}"
            )
        digest = _sha256_fd(fd)
        _require_stable_regular_fd(fd, info, proof.path, label)
    finally:
        os.close(fd)
    if digest != proof.sha256:
        raise CutoverError(
            f"{label} SHA-256 is {digest}; expected {proof.sha256}: {proof.path}"
        )


def compute_release_proof(
    release_root: Path, relative_path: str, label: str = "release proof"
) -> dict[str, str]:
    """Build one proof object with the exact validator used by manifests."""

    if Path(os.path.realpath(release_root)) != release_root:
        raise CutoverError(f"{label} release root is symlinked or non-canonical")
    _require_directory(release_root, f"{label} release root")
    relative = _normalized_relative_path(relative_path, f"{label}.relative_path")
    path = release_root / relative
    _require_real_parent_chain(path, release_root, label)
    fd, info = _open_regular_readonly(path, label)
    try:
        if info.st_uid != os.getuid():
            raise CutoverError(
                f"{label} owner uid is {info.st_uid}; expected current uid {os.getuid()}"
            )
        mode = stat.S_IMODE(info.st_mode)
        if mode & 0o022:
            raise CutoverError(f"{label} must not be group- or other-writable")
        digest = _sha256_fd(fd)
        _require_stable_regular_fd(fd, info, path, label)
    finally:
        os.close(fd)
    return {
        "relative_path": str(relative),
        "sha256": digest,
        "mode": f"{mode:04o}",
    }


def _parse_release_proofs(
    values: Any,
    target_path: Path,
    roots: Sequence[Path],
    label: str,
) -> tuple[ReleaseProof, ...]:
    if not isinstance(values, list) or not values:
        raise CutoverError(f"{label} must be a non-empty array")
    proofs: list[ReleaseProof] = []
    seen: set[Path] = set()
    for index, value in enumerate(values):
        proof_label = f"{label}[{index}]"
        if not isinstance(value, dict):
            raise CutoverError(f"{proof_label} must be an object")
        _require_exact_keys(
            value,
            {"relative_path", "sha256", "mode"},
            set(),
            proof_label,
        )
        relative = _normalized_relative_path(
            value["relative_path"], f"{proof_label}.relative_path"
        )
        proof_path = target_path / relative
        if proof_path in seen:
            raise CutoverError(f"duplicate release proof path: {proof_path}")
        seen.add(proof_path)
        _owning_root(proof_path, roots, f"{proof_label}.relative_path")
        _require_real_parent_chain(proof_path, target_path, proof_label)
        proof = ReleaseProof(
            relative_path=str(relative),
            path=proof_path,
            sha256=_parse_hash(value["sha256"], f"{proof_label}.sha256"),
            mode=_parse_proof_mode(value["mode"], f"{proof_label}.mode"),
        )
        _validate_release_proof(proof, proof_label)
        proofs.append(proof)
    return tuple(proofs)


def _parse_quiet_point(value: Any, roots: Sequence[Path]) -> QuietPoint:
    if not isinstance(value, dict):
        raise CutoverError("quiet_point must be an object")
    _require_exact_keys(
        value,
        {
            "profile_ids",
            "worker_profile_ids",
            "never_enroll_profile_ids",
            "routing_absent_paths",
            "backend_path",
            "backend_sha256",
            "state_quiet_paths",
            "forbidden_process_tokens",
            "ps_binary",
            "ps_binary_sha256",
        },
        set(),
        "quiet_point",
    )
    profile_values = value["profile_ids"]
    if (
        not isinstance(profile_values, list)
        or not profile_values
        or not all(isinstance(item, str) and item for item in profile_values)
        or profile_values != sorted(set(profile_values))
    ):
        raise CutoverError("quiet_point.profile_ids must be sorted and unique")
    worker_values = value["worker_profile_ids"]
    reserve_values = value["never_enroll_profile_ids"]
    for values, name in (
        (worker_values, "worker_profile_ids"),
        (reserve_values, "never_enroll_profile_ids"),
    ):
        if (
            not isinstance(values, list)
            or values != sorted(set(values))
            or not all(isinstance(item, str) and item for item in values)
        ):
            raise CutoverError(f"quiet_point.{name} must be sorted and unique")
    if (
        not worker_values
        or not reserve_values
        or set(worker_values) & set(reserve_values)
        or sorted([*worker_values, *reserve_values]) != profile_values
    ):
        raise CutoverError(
            "quiet_point worker and never-enroll profiles must exactly partition profile_ids"
        )
    routing_values = value["routing_absent_paths"]
    state_values = value["state_quiet_paths"]
    if not isinstance(routing_values, list) or not routing_values:
        raise CutoverError("quiet_point.routing_absent_paths must be non-empty")
    if not isinstance(state_values, list) or not state_values:
        raise CutoverError("quiet_point.state_quiet_paths must be non-empty")
    routing_paths = tuple(
        _explicit_absolute_path(item, f"quiet_point.routing_absent_paths[{index}]")
        for index, item in enumerate(routing_values)
    )
    state_paths = tuple(
        _explicit_absolute_path(item, f"quiet_point.state_quiet_paths[{index}]")
        for index, item in enumerate(state_values)
    )
    if len(set(routing_paths)) != len(routing_paths):
        raise CutoverError("quiet_point.routing_absent_paths contains duplicates")
    if len(set(state_paths)) != len(state_paths):
        raise CutoverError("quiet_point.state_quiet_paths contains duplicates")
    backend = _explicit_absolute_path(value["backend_path"], "quiet_point.backend_path")
    for index, path in enumerate((*routing_paths, backend, *state_paths)):
        root = _owning_root(path, roots, f"quiet point path[{index}]")
        _require_real_parent_chain(path, root, f"quiet point path[{index}]")
    _require_regular(backend, "quiet-point backend file")
    tokens = value["forbidden_process_tokens"]
    if (
        not isinstance(tokens, list)
        or not tokens
        or not all(
            isinstance(token, str)
            and token.startswith("/")
            and len(token) > 1
            and "\x00" not in token
            and "$" not in token
            for token in tokens
        )
        or len(tokens) != len(set(tokens))
    ):
        raise CutoverError(
            "quiet_point.forbidden_process_tokens must be unique absolute tokens"
        )
    ps_binary = _explicit_absolute_path(value["ps_binary"], "quiet_point.ps_binary")
    _require_regular(ps_binary, "quiet-point ps binary", allow_root=True)
    if not stat.S_IMODE(os.lstat(ps_binary).st_mode) & 0o100:
        raise CutoverError("quiet-point ps binary must be owner-executable")
    return QuietPoint(
        profile_ids=tuple(profile_values),
        worker_profile_ids=tuple(worker_values),
        never_enroll_profile_ids=tuple(reserve_values),
        routing_absent_paths=routing_paths,
        backend_path=backend,
        backend_sha256=_parse_hash(value["backend_sha256"], "quiet_point.backend_sha256"),
        state_quiet_paths=state_paths,
        forbidden_process_tokens=tuple(tokens),
        ps_binary=ps_binary,
        ps_binary_sha256=_parse_hash(
            value["ps_binary_sha256"], "quiet_point.ps_binary_sha256"
        ),
    )


def load_manifest(path_value: str | os.PathLike[str]) -> Manifest:
    manifest_path = _explicit_absolute_path(os.fspath(path_value), "manifest path")
    if Path(os.path.realpath(manifest_path)) != manifest_path:
        raise CutoverError(
            f"manifest path has a symlinked or non-canonical component: {manifest_path}"
        )
    raw = _read_json_file(manifest_path, MAX_MANIFEST_BYTES, "manifest")
    if not isinstance(raw, dict):
        raise CutoverError("manifest root must be an object")
    _require_exact_keys(
        raw,
        {
            "schema_version",
            "transaction_id",
            "apply_opt_in",
            "allowed_roots",
            "lock_path",
            "journal_path",
            "quiet_point",
            "operations",
        },
        set(),
        "manifest",
    )
    if raw["schema_version"] != SCHEMA_VERSION:
        raise CutoverError(f"unsupported manifest schema: {raw['schema_version']!r}")
    transaction_id = raw["transaction_id"]
    if not isinstance(transaction_id, str) or not SAFE_NAME.fullmatch(transaction_id):
        raise CutoverError("transaction_id must be a safe 1-64 character identifier")
    if not isinstance(raw["apply_opt_in"], bool):
        raise CutoverError("apply_opt_in must be a boolean")
    if not isinstance(raw["allowed_roots"], list) or not raw["allowed_roots"]:
        raise CutoverError("allowed_roots must be a non-empty array")

    home = Path(os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir))
    roots: list[Path] = []
    for index, root_value in enumerate(raw["allowed_roots"]):
        root = _explicit_absolute_path(root_value, f"allowed_roots[{index}]")
        if str(root) in KNOWN_BROAD_PATHS or root == home or _is_relative_to(home, root):
            raise CutoverError(f"allowed root is root/home/broad and is refused: {root}")
        _require_directory(root, f"allowed_roots[{index}]")
        if Path(os.path.realpath(root)) != root:
            raise CutoverError(f"allowed root has a symlinked or non-canonical ancestor: {root}")
        roots.append(root)
    if len(set(roots)) != len(roots):
        raise CutoverError("allowed_roots contains duplicates")
    for left in roots:
        for right in roots:
            if left != right and _is_relative_to(left, right):
                raise CutoverError(f"allowed_roots must not overlap: {left} and {right}")

    quiet_point = _parse_quiet_point(raw["quiet_point"], roots)

    lock_path = _explicit_absolute_path(raw["lock_path"], "lock_path")
    lock_root = _owning_root(lock_path, roots, "lock_path")
    _require_real_parent_chain(lock_path, lock_root, "lock_path")
    _require_directory(lock_path.parent, "lock parent", private=True)
    _require_regular(lock_path, "lock file", 0o600)

    journal_path = _explicit_absolute_path(raw["journal_path"], "journal_path")
    journal_root = _owning_root(journal_path, roots, "journal_path")
    _require_real_parent_chain(journal_path, journal_root, "journal_path")
    _require_directory(journal_path.parent, "journal parent", private=True)
    if journal_path.parent != lock_path.parent or journal_path == lock_path:
        raise CutoverError("lock_path must be a distinct file beside journal_path")

    operation_values = raw["operations"]
    if not isinstance(operation_values, list) or not operation_values:
        raise CutoverError("operations must be a non-empty array")
    operations: list[Operation] = []
    names: set[str] = set()
    explicit_paths: set[Path] = {manifest_path, lock_path, journal_path}
    release_proof_paths: set[Path] = set()
    registry_count = 0
    for index, operation_value in enumerate(operation_values):
        label = f"operations[{index}]"
        if not isinstance(operation_value, dict):
            raise CutoverError(f"{label} must be an object")
        kind = operation_value.get("kind")
        if kind == "symlink":
            _require_exact_keys(
                operation_value,
                {
                    "kind",
                    "name",
                    "path",
                    "old_target",
                    "new_target",
                    "old_proofs",
                    "new_proofs",
                    "old_tree_sha256",
                    "new_tree_sha256",
                },
                set(),
                label,
            )
        elif kind in {"registry", "regular-file"}:
            _require_exact_keys(
                operation_value,
                {
                    "kind",
                    "name",
                    "path",
                    "old_source",
                    "new_source",
                    "old_sha256",
                    "new_sha256",
                    "mode",
                },
                set(),
                label,
            )
        else:
            raise CutoverError(
                f"{label}.kind must be 'symlink', 'registry', or 'regular-file'"
            )
        name = operation_value["name"]
        if not isinstance(name, str) or not SAFE_NAME.fullmatch(name):
            raise CutoverError(f"{label}.name must be a safe identifier")
        if name in names:
            raise CutoverError(f"duplicate operation name: {name}")
        names.add(name)
        path = _explicit_absolute_path(operation_value["path"], f"{label}.path")
        root = _owning_root(path, roots, f"{label}.path")
        _require_real_parent_chain(path, root, f"{label}.path")
        if path in explicit_paths:
            raise CutoverError(f"duplicate operational path: {path}")
        explicit_paths.add(path)

        if kind == "symlink":
            old_target, old_target_path = _parse_symlink_target(
                operation_value["old_target"], path.parent, f"{label}.old_target"
            )
            new_target, new_target_path = _parse_symlink_target(
                operation_value["new_target"], path.parent, f"{label}.new_target"
            )
            if old_target == new_target or old_target_path == new_target_path:
                raise CutoverError(f"{label} old and new targets must differ")
            for target_name, target_path in (
                ("old_target", old_target_path),
                ("new_target", new_target_path),
            ):
                target_root = _owning_root(target_path, roots, f"{label}.{target_name}")
                _require_real_parent_chain(target_path, target_root, f"{label}.{target_name}")
                _require_directory(target_path, f"{label}.{target_name}")
            old_proofs = _parse_release_proofs(
                operation_value["old_proofs"],
                old_target_path,
                roots,
                f"{label}.old_proofs",
            )
            new_proofs = _parse_release_proofs(
                operation_value["new_proofs"],
                new_target_path,
                roots,
                f"{label}.new_proofs",
            )
            old_tree_sha256 = _parse_hash(
                operation_value["old_tree_sha256"], f"{label}.old_tree_sha256"
            )
            new_tree_sha256 = _parse_hash(
                operation_value["new_tree_sha256"], f"{label}.new_tree_sha256"
            )
            old_tree_observed = compute_release_tree_sha256(
                old_target_path, f"{label} old release tree"
            )
            new_tree_observed = compute_release_tree_sha256(
                new_target_path, f"{label} new release tree"
            )
            if old_tree_observed != old_tree_sha256:
                raise CutoverError(
                    f"{label} old release tree SHA-256 is {old_tree_observed}; "
                    f"expected {old_tree_sha256}"
                )
            if new_tree_observed != new_tree_sha256:
                raise CutoverError(
                    f"{label} new release tree SHA-256 is {new_tree_observed}; "
                    f"expected {new_tree_sha256}"
                )
            for proof in (*old_proofs, *new_proofs):
                if proof.path in explicit_paths:
                    raise CutoverError(f"duplicate operational/proof path: {proof.path}")
                explicit_paths.add(proof.path)
                release_proof_paths.add(proof.path)
            operations.append(
                SymlinkOperation(
                    name=name,
                    path=path,
                    old_target=old_target,
                    new_target=new_target,
                    old_target_path=old_target_path,
                    new_target_path=new_target_path,
                    old_proofs=old_proofs,
                    new_proofs=new_proofs,
                    old_tree_sha256=old_tree_sha256,
                    new_tree_sha256=new_tree_sha256,
                )
            )
        else:
            if kind == "registry":
                registry_count += 1
            old_source = _explicit_absolute_path(
                operation_value["old_source"], f"{label}.old_source"
            )
            new_source = _explicit_absolute_path(
                operation_value["new_source"], f"{label}.new_source"
            )
            if len({path, old_source, new_source}) != 3:
                raise CutoverError(f"{label} path and source paths must be distinct")
            for source_name, source_path in (
                ("old_source", old_source),
                ("new_source", new_source),
            ):
                source_root = _owning_root(source_path, roots, f"{label}.{source_name}")
                _require_real_parent_chain(source_path, source_root, f"{label}.{source_name}")
                if source_path in explicit_paths and not (
                    kind == "regular-file" and source_path in release_proof_paths
                ):
                    raise CutoverError(f"duplicate operational path: {source_path}")
                explicit_paths.add(source_path)
            mode = _parse_mode(operation_value["mode"], f"{label}.mode")
            expected_mode = 0o600 if kind == "registry" else 0o555
            if mode != expected_mode:
                raise CutoverError(
                    f"{label}.mode must be {expected_mode:04o} for {kind} safety"
                )
            operation_type = RegistryOperation if kind == "registry" else RegularFileOperation
            operations.append(
                operation_type(
                    name=name,
                    path=path,
                    old_source=old_source,
                    new_source=new_source,
                    old_sha256=_parse_hash(
                        operation_value["old_sha256"], f"{label}.old_sha256"
                    ),
                    new_sha256=_parse_hash(
                        operation_value["new_sha256"], f"{label}.new_sha256"
                    ),
                    mode=mode,
                )
            )
    if registry_count != 1:
        raise CutoverError("manifest must contain exactly one registry operation")

    derived_temps = [_temp_path(journal_path, transaction_id, "journal")]
    for operation in operations:
        derived_temps.extend(
            (
                _temp_path(operation.path, transaction_id, "forward"),
                _temp_path(operation.path, transaction_id, "rollback"),
            )
        )
    if len(set(derived_temps)) != len(derived_temps):
        raise CutoverError("derived transaction temporary paths collide")
    collisions = set(derived_temps) & explicit_paths
    if collisions:
        raise CutoverError(
            "derived temporary path collides with an explicit manifest path: "
            + ", ".join(str(path) for path in sorted(collisions))
        )

    canonical = json.dumps(raw, sort_keys=True, separators=(",", ":")).encode("utf-8")
    fingerprint = hashlib.sha256(canonical).hexdigest()
    return Manifest(
        path=manifest_path,
        fingerprint=fingerprint,
        transaction_id=transaction_id,
        apply_opt_in=raw["apply_opt_in"],
        allowed_roots=tuple(roots),
        lock_path=lock_path,
        journal_path=journal_path,
        quiet_point=quiet_point,
        operations=tuple(operations),
    )


def _temp_path(path: Path, transaction_id: str, purpose: str) -> Path:
    return path.with_name(f".{path.name}.{transaction_id}.{purpose}.tmp")


def _verify_temp_regular(
    path: Path, label: str, modes: int | tuple[int, ...] = 0o600
) -> None:
    if not os.path.lexists(path):
        return
    expected_modes = (modes,) if isinstance(modes, int) else modes
    _require_regular(path, label)
    observed_mode = stat.S_IMODE(os.lstat(path).st_mode)
    if observed_mode not in expected_modes:
        rendered = ", ".join(f"{mode:04o}" for mode in expected_modes)
        raise CutoverError(
            f"{label} mode is {observed_mode:04o}; expected one of {rendered}: {path}"
        )


def _verify_temp_symlink(path: Path, target: str, label: str) -> None:
    if not os.path.lexists(path):
        return
    info = os.lstat(path)
    if not stat.S_ISLNK(info.st_mode) or os.readlink(path) != target:
        raise CutoverError(f"{label} is not the exact expected staged symlink: {path}")


def _validate_artifacts(manifest: Manifest) -> None:
    journal_temp = _temp_path(manifest.journal_path, manifest.transaction_id, "journal")
    _verify_temp_regular(journal_temp, "journal temporary file")
    for operation in manifest.operations:
        if isinstance(operation, SymlinkOperation):
            _verify_temp_symlink(
                _temp_path(operation.path, manifest.transaction_id, "forward"),
                operation.new_target,
                f"{operation.name} forward temporary link",
            )
            _verify_temp_symlink(
                _temp_path(operation.path, manifest.transaction_id, "rollback"),
                operation.old_target,
                f"{operation.name} rollback temporary link",
            )
        else:
            temp_modes = (
                (0o600, operation.mode)
                if isinstance(operation, RegularFileOperation)
                and not isinstance(operation, RegistryOperation)
                else operation.mode
            )
            _verify_temp_regular(
                _temp_path(operation.path, manifest.transaction_id, "forward"),
                f"{operation.name} forward temporary regular file",
                temp_modes,
            )
            _verify_temp_regular(
                _temp_path(operation.path, manifest.transaction_id, "rollback"),
                f"{operation.name} rollback temporary regular file",
                temp_modes,
            )


def _revalidate_manifest_ancestry(manifest: Manifest) -> None:
    """Repeat all parent-chain checks while holding the transaction lock."""

    for root in manifest.allowed_roots:
        _require_directory(root, "allowed root")
        if Path(os.path.realpath(root)) != root:
            raise CutoverError(f"allowed root ancestry changed: {root}")
    for label, path in (
        ("lock_path", manifest.lock_path),
        ("journal_path", manifest.journal_path),
    ):
        root = _owning_root(path, manifest.allowed_roots, label)
        _require_real_parent_chain(path, root, label)
    _require_directory(manifest.lock_path.parent, "transaction private directory", private=True)
    for operation in manifest.operations:
        paths: list[tuple[str, Path]] = [(f"{operation.name}.path", operation.path)]
        if isinstance(operation, SymlinkOperation):
            paths.extend(
                (
                    (f"{operation.name}.old_target", operation.old_target_path),
                    (f"{operation.name}.new_target", operation.new_target_path),
                )
            )
            paths.extend(
                (f"{operation.name}.old_proof", proof.path)
                for proof in operation.old_proofs
            )
            paths.extend(
                (f"{operation.name}.new_proof", proof.path)
                for proof in operation.new_proofs
            )
        else:
            paths.extend(
                (
                    (f"{operation.name}.old_source", operation.old_source),
                    (f"{operation.name}.new_source", operation.new_source),
                )
            )
        for label, path in paths:
            root = _owning_root(path, manifest.allowed_roots, label)
            _require_real_parent_chain(path, root, label)


@contextmanager
def _transaction_lock(manifest: Manifest) -> Iterable[None]:
    fd, _ = _open_regular_readonly(manifest.lock_path, "transaction lock", 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise CutoverError(
                f"another cutover driver holds the transaction lock: {manifest.lock_path}"
            ) from exc
        _revalidate_manifest_ancestry(manifest)
        yield
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)


def _validate_release_binding(
    target_path: Path,
    proofs: Sequence[ReleaseProof],
    expected_tree_sha256: str,
    label: str,
) -> None:
    _require_directory(target_path, f"{label} target")
    for index, proof in enumerate(proofs):
        _require_real_parent_chain(proof.path, target_path, f"{label} proof[{index}]")
        _validate_release_proof(proof, f"{label} proof[{index}]")
    observed = compute_release_tree_sha256(target_path, f"{label} tree")
    if observed != expected_tree_sha256:
        raise CutoverError(
            f"{label} tree SHA-256 is {observed}; expected {expected_tree_sha256}"
        )


def _validate_symlink_release_bindings(operation: SymlinkOperation) -> None:
    _validate_release_binding(
        operation.old_target_path,
        operation.old_proofs,
        operation.old_tree_sha256,
        f"{operation.name} old release",
    )
    _validate_release_binding(
        operation.new_target_path,
        operation.new_proofs,
        operation.new_tree_sha256,
        f"{operation.name} new release",
    )


def _validate_all_release_bindings(manifest: Manifest) -> None:
    for operation in manifest.operations:
        if isinstance(operation, SymlinkOperation):
            _validate_symlink_release_bindings(operation)


def _validate_quiet_point(manifest: Manifest) -> None:
    registry = next(
        operation
        for operation in manifest.operations
        if isinstance(operation, RegistryOperation)
    )
    payload = _read_stable_bytes(
        registry.path,
        "quiet-point live registry",
        registry.mode,
    )
    registry_digest = hashlib.sha256(payload).hexdigest()
    if registry_digest not in {registry.old_sha256, registry.new_sha256}:
        raise CutoverError(
            f"quiet-point live registry has unknown SHA-256: {registry_digest}"
        )
    try:
        raw = tomllib.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, tomllib.TOMLDecodeError) as exc:
        raise CutoverError(f"quiet-point live registry is not valid UTF-8 TOML: {exc}") from exc
    profiles = raw.get("profiles") if isinstance(raw, dict) else None
    if not isinstance(profiles, dict):
        raise CutoverError("quiet-point live registry has no profiles table")
    if tuple(sorted(profiles)) != manifest.quiet_point.profile_ids:
        raise CutoverError("quiet-point registry profile set mismatch")
    for profile_id, profile in profiles.items():
        if not isinstance(profile, dict) or profile.get("enabled", False) is not False:
            raise CutoverError(f"quiet point has an enabled profile: {profile_id}")
        expected_policy = (
            "worker"
            if profile_id in manifest.quiet_point.worker_profile_ids
            else "desktop_shared"
        )
        if profile.get("safety_policy") != expected_policy:
            raise CutoverError(
                f"quiet-point profile {profile_id} safety_policy is not {expected_policy}"
            )
        pools = profile.get("pools", [])
        if not isinstance(pools, list) or not all(isinstance(pool, str) for pool in pools):
            raise CutoverError(f"quiet-point profile {profile_id} pools are invalid")
        if expected_policy != "worker" and any(pool.endswith("-crew") for pool in pools):
            raise CutoverError(
                f"quiet-point never-enroll profile {profile_id} is in a crew pool"
            )

    quiet = manifest.quiet_point
    backend_payload = _read_stable_bytes(quiet.backend_path, "quiet-point backend")
    if hashlib.sha256(backend_payload).hexdigest() != quiet.backend_sha256:
        raise CutoverError("quiet-point backend SHA-256 changed")
    try:
        backend_value = backend_payload.decode("utf-8").strip()
    except UnicodeDecodeError as exc:
        raise CutoverError("quiet-point backend is not UTF-8") from exc
    if backend_value != "tmux":
        raise CutoverError(f"quiet-point backend must be tmux: {backend_value!r}")
    ps_payload = _read_stable_bytes(
        quiet.ps_binary, "quiet-point ps binary", allow_root=True
    )
    if hashlib.sha256(ps_payload).hexdigest() != quiet.ps_binary_sha256:
        raise CutoverError("quiet-point ps binary SHA-256 changed")

    for path in quiet.routing_absent_paths:
        root = _owning_root(path, manifest.allowed_roots, "quiet-point routing path")
        _require_real_parent_chain(path, root, "quiet-point routing path")
        if os.path.lexists(path):
            raise CutoverError(f"quiet-point routing path must be absent: {path}")
    for path in quiet.state_quiet_paths:
        root = _owning_root(path, manifest.allowed_roots, "quiet-point state path")
        _require_real_parent_chain(path, root, "quiet-point state path")
        if not os.path.lexists(path):
            continue
        flags = (
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
        )
        try:
            fd = os.open(path, flags)
        except OSError as exc:
            raise CutoverError(f"cannot safely open quiet-point state path {path}: {exc}") from exc
        try:
            before = os.fstat(fd)
            if not stat.S_ISDIR(before.st_mode):
                raise CutoverError(f"quiet-point state path is not a directory: {path}")
            if before.st_uid != os.getuid():
                raise CutoverError(
                    f"quiet-point state path is not owned by current uid: {path}"
                )
            names = os.listdir(fd)
            after = os.fstat(fd)
            identity_before = (
                before.st_dev,
                before.st_ino,
                before.st_mode,
                before.st_mtime_ns,
                before.st_ctime_ns,
            )
            identity_after = (
                after.st_dev,
                after.st_ino,
                after.st_mode,
                after.st_mtime_ns,
                after.st_ctime_ns,
            )
            if identity_before != identity_after:
                raise CutoverError(f"quiet-point state path changed while scanning: {path}")
            current = os.lstat(path)
            if (
                current.st_dev != before.st_dev
                or current.st_ino != before.st_ino
                or current.st_mode != before.st_mode
            ):
                raise CutoverError(
                    f"quiet-point state path was substituted while scanning: {path}"
                )
            if names:
                summary = ", ".join(sorted(names)[:5])
                raise CutoverError(f"quiet-point state path is not empty: {path}: {summary}")
        finally:
            os.close(fd)

    env = {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"}
    try:
        completed = subprocess.run(
            [str(quiet.ps_binary), "-axo", "pid=,command="],
            check=False,
            capture_output=True,
            text=True,
            env=env,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise CutoverError(f"quiet-point process probe failed: {exc}") from exc
    if completed.returncode != 0:
        raise CutoverError(
            f"quiet-point process probe exited {completed.returncode}: "
            f"{completed.stderr.strip()}"
        )
    for line in completed.stdout.splitlines():
        fields = line.strip().split(maxsplit=1)
        if len(fields) != 2 or not fields[0].isdigit():
            continue
        pid = int(fields[0])
        command = fields[1]
        if pid == os.getpid():
            continue
        for token in quiet.forbidden_process_tokens:
            if token in command:
                raise CutoverError(
                    f"quiet-point Fleet process token is active: {token}: pid {pid}"
                )


def _validate_operation_static(operation: Operation) -> None:
    if isinstance(operation, SymlinkOperation):
        _validate_symlink_release_bindings(operation)
        return
    old_digest = _sha256_file(
        operation.old_source,
        label=f"{operation.name} old source",
        expected_mode=operation.mode,
    )
    new_digest = _sha256_file(
        operation.new_source,
        label=f"{operation.name} new source",
        expected_mode=operation.mode,
    )
    if old_digest != operation.old_sha256:
        raise CutoverError(
            f"{operation.name} old source SHA-256 is {old_digest}; "
            f"expected {operation.old_sha256}"
        )
    if new_digest != operation.new_sha256:
        raise CutoverError(
            f"{operation.name} new source SHA-256 is {new_digest}; "
            f"expected {operation.new_sha256}"
        )
    if old_digest == new_digest:
        raise CutoverError(f"{operation.name} old/new regular-file hashes must differ")


def _observe_operation(operation: Operation) -> str:
    if isinstance(operation, SymlinkOperation):
        info = _lstat(operation.path, f"{operation.name} live link")
        if not stat.S_ISLNK(info.st_mode):
            raise CutoverError(f"{operation.name} live path is not a symlink: {operation.path}")
        target = os.readlink(operation.path)
        if target == operation.old_target:
            return "old"
        if target == operation.new_target:
            return "new"
        raise CutoverError(
            f"{operation.name} live link has an unknown target: {target!r}; "
            "only the exact manifest old/new targets are accepted"
        )
    digest = _sha256_file(
        operation.path,
        label=f"{operation.name} live regular file",
        expected_mode=operation.mode,
    )
    if digest == operation.old_sha256:
        return "old"
    if digest == operation.new_sha256:
        return "new"
    raise CutoverError(
        f"{operation.name} live regular file has unknown SHA-256 {digest}; "
        "only the exact manifest old/new hashes are accepted"
    )


def observe(manifest: Manifest) -> tuple[list[str], int]:
    _validate_quiet_point(manifest)
    _validate_artifacts(manifest)
    states: list[str] = []
    for operation in manifest.operations:
        _validate_operation_static(operation)
        states.append(_observe_operation(operation))
    seen_old = False
    for state in states:
        if state == "old":
            seen_old = True
        elif seen_old:
            raise CutoverError(
                "observed old/new states are not a valid transaction prefix; "
                "refusing an out-of-order or externally modified state"
            )
    prefix_new = next((index for index, state in enumerate(states) if state == "old"), len(states))
    return states, prefix_new


def _new_journal(manifest: Manifest) -> dict[str, Any]:
    return {
        "schema_version": JOURNAL_SCHEMA_VERSION,
        "transaction_id": manifest.transaction_id,
        "manifest_sha256": manifest.fingerprint,
        "direction": None,
        "post_install_irreversible_boundary": False,
        "sequence": 0,
        "history": [],
    }


def _load_journal(manifest: Manifest) -> dict[str, Any] | None:
    path = manifest.journal_path
    if not os.path.lexists(path):
        return None
    raw = _read_json_file(path, MAX_JOURNAL_BYTES, "journal", expected_mode=0o600)
    if not isinstance(raw, dict):
        raise CutoverError("journal root must be an object")
    _require_exact_keys(
        raw,
        {
            "schema_version",
            "transaction_id",
            "manifest_sha256",
            "direction",
            "post_install_irreversible_boundary",
            "sequence",
            "history",
        },
        set(),
        "journal",
    )
    if raw["schema_version"] != JOURNAL_SCHEMA_VERSION:
        raise CutoverError("journal schema version mismatch")
    if raw["transaction_id"] != manifest.transaction_id:
        raise CutoverError("journal transaction_id does not match manifest")
    if raw["manifest_sha256"] != manifest.fingerprint:
        raise CutoverError("journal manifest SHA-256 does not match this manifest")
    if raw["direction"] not in (None, "forward", "rollback"):
        raise CutoverError("journal direction is invalid")
    if not isinstance(raw["post_install_irreversible_boundary"], bool):
        raise CutoverError("journal post-install irreversible boundary is invalid")
    if not isinstance(raw["sequence"], int) or raw["sequence"] < 0:
        raise CutoverError("journal sequence is invalid")
    if (
        not isinstance(raw["history"], list)
        or len(raw["history"]) > MAX_JOURNAL_HISTORY_ENTRIES
    ):
        raise CutoverError("journal history is invalid or too large")
    return raw


def _serialize_bounded_journal(journal: dict[str, Any]) -> bytes:
    """Deterministically retain the largest latest-history suffix that fits."""

    history = journal.get("history")
    if not isinstance(history, list):
        raise CutoverError("journal history is invalid")
    if len(history) > MAX_JOURNAL_HISTORY_ENTRIES:
        del history[: len(history) - MAX_JOURNAL_HISTORY_ENTRIES]

    def serialize() -> bytes:
        return (
            json.dumps(journal, sort_keys=True, separators=(",", ":")) + "\n"
        ).encode("utf-8")

    payload = serialize()
    if len(payload) <= MAX_JOURNAL_BYTES:
        return payload
    if not history:
        raise CutoverError(
            f"journal metadata exceeds the {MAX_JOURNAL_BYTES}-byte write limit"
        )

    # Binary-search the largest suffix that fits. A suffix keeps the most
    # recent recovery evidence and pruning is deterministic for identical input.
    original = list(history)
    low = 1
    high = len(original)
    best_count = 0
    best_payload: bytes | None = None
    while low <= high:
        count = (low + high) // 2
        history[:] = original[-count:]
        candidate = serialize()
        if len(candidate) <= MAX_JOURNAL_BYTES:
            best_count = count
            best_payload = candidate
            low = count + 1
        else:
            high = count - 1
    if best_payload is None:
        history[:] = original
        raise CutoverError(
            "latest journal checkpoint alone exceeds the safe write limit; "
            "refusing to replace the readable journal"
        )
    history[:] = original[-best_count:]
    return best_payload


def _observe_load_and_seal(
    manifest: Manifest, boundaries: BoundaryController
) -> tuple[list[str], int, dict[str, Any] | None]:
    """Validate exact state, validate its journal, then seal observed parents."""

    states, prefix_new = observe(manifest)
    journal = _load_journal(manifest)
    _seal_observed_parents(manifest, boundaries)
    if (
        journal
        and journal["post_install_irreversible_boundary"]
        and prefix_new != len(manifest.operations)
    ):
        raise CutoverError(
            "post-install irreversible boundary is marked but installed state is not fully new"
        )
    return states, prefix_new, journal


def _write_all(fd: int, payload: bytes) -> None:
    offset = 0
    while offset < len(payload):
        written = os.write(fd, payload[offset:])
        if written <= 0:
            raise OSError("short write")
        offset += written


def _open_exact_temp(path: Path, mode: int) -> int:
    if os.path.lexists(path):
        _require_regular(path, "temporary file", mode)
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NONBLOCK", 0)
    flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags, mode)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise CutoverError(f"temporary path is not a regular file: {path}")
        _require_owner(info, path, "temporary file")
        _require_single_link(info, path, "temporary file")
        os.fchmod(fd, mode)
        return fd
    except BaseException:
        os.close(fd)
        raise


def _fsync_directory(path: Path) -> None:
    flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    fd = os.open(path, flags)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _seal_observed_parents(
    manifest: Manifest, boundaries: BoundaryController
) -> None:
    """Seal any replace observed after an interrupted pre-fsync execution."""

    seen: set[Path] = set()
    for operation in manifest.operations:
        parent = operation.path.parent
        if parent in seen:
            continue
        seen.add(parent)
        label = f"recovery-operation-dir:{operation.name}"
        boundaries.hit(f"before_fsync:{label}")
        _fsync_directory(parent)
        boundaries.hit(f"after_fsync:{label}")

    # Keep this separate even if a future manifest co-locates the journal and
    # an operation. It is the explicit durability seal for the recovery record.
    label = "recovery-journal-dir"
    boundaries.hit(f"before_fsync:{label}")
    _fsync_directory(manifest.journal_path.parent)
    boundaries.hit(f"after_fsync:{label}")


def _write_journal_atomic(
    manifest: Manifest,
    journal: dict[str, Any],
    checkpoint: str,
    boundaries: BoundaryController,
) -> None:
    payload = _serialize_bounded_journal(journal)
    boundaries.hit(f"before_journal:{checkpoint}")
    temp = _temp_path(manifest.journal_path, manifest.transaction_id, "journal")
    fd = _open_exact_temp(temp, 0o600)
    try:
        _write_all(fd, payload)
        boundaries.hit(f"before_fsync:journal-temp:{checkpoint}")
        os.fsync(fd)
        boundaries.hit(f"after_fsync:journal-temp:{checkpoint}")
    finally:
        os.close(fd)
    boundaries.hit(f"before_replace:journal:{checkpoint}")
    _require_regular(temp, "staged journal", 0o600)
    os.replace(temp, manifest.journal_path)
    boundaries.hit(f"after_replace:journal:{checkpoint}")
    boundaries.hit(f"before_fsync:journal-dir:{checkpoint}")
    _fsync_directory(manifest.journal_path.parent)
    boundaries.hit(f"after_fsync:journal-dir:{checkpoint}")
    boundaries.hit(f"after_journal:{checkpoint}")


def _checkpoint(
    manifest: Manifest,
    journal: dict[str, Any],
    phase: str,
    moment: str,
    states: Sequence[str],
    boundaries: BoundaryController,
) -> None:
    journal["sequence"] += 1
    journal["history"].append(
        {
            "sequence": journal["sequence"],
            "phase": phase,
            "moment": moment,
            "observed": list(states),
        }
    )
    _write_journal_atomic(manifest, journal, f"{phase}.{moment}", boundaries)


def _replace_symlink(
    manifest: Manifest,
    operation: SymlinkOperation,
    direction: str,
    target: str,
    boundaries: BoundaryController,
) -> None:
    temp = _temp_path(operation.path, manifest.transaction_id, direction)
    if os.path.lexists(temp):
        _verify_temp_symlink(temp, target, f"{operation.name} temporary link")
    else:
        boundaries.hit(f"before_prepare:{direction}:{operation.name}")
        os.symlink(target, temp)
        boundaries.hit(f"after_prepare:{direction}:{operation.name}")
    _revalidate_manifest_ancestry(manifest)
    _validate_all_release_bindings(manifest)
    expected_current = "old" if direction == "forward" else "new"
    observed = _observe_operation(operation)
    if observed != expected_current:
        raise CutoverError(
            f"{operation.name} changed during preparation; expected "
            f"{expected_current}, observed {observed}"
        )
    boundaries.hit(f"before_replace:{direction}:{operation.name}")
    _validate_quiet_point(manifest)
    os.replace(temp, operation.path)
    boundaries.hit(f"after_replace:{direction}:{operation.name}")
    boundaries.hit(f"before_fsync:{direction}-dir:{operation.name}")
    _fsync_directory(operation.path.parent)
    boundaries.hit(f"after_fsync:{direction}-dir:{operation.name}")


def _replace_regular_file(
    manifest: Manifest,
    operation: RegularFileOperation,
    direction: str,
    source: Path,
    expected_hash: str,
    boundaries: BoundaryController,
) -> None:
    temp = _temp_path(operation.path, manifest.transaction_id, direction)
    boundaries.hit(f"before_prepare:{direction}:{operation.name}")
    prepared = False
    if os.path.lexists(temp) and operation.mode != 0o600:
        _require_regular(temp, f"{operation.name} staged regular file")
        temp_mode = stat.S_IMODE(os.lstat(temp).st_mode)
        if temp_mode == operation.mode:
            if _sha256_file(
                temp,
                label=f"{operation.name} staged regular file",
                expected_mode=operation.mode,
            ) != expected_hash:
                raise CutoverError(
                    f"{operation.name} staged regular-file hash verification failed"
                )
            prepared = True
        elif temp_mode != 0o600:
            raise CutoverError(
                f"{operation.name} staged regular-file mode is {temp_mode:04o}; "
                f"expected 0600 or {operation.mode:04o}"
            )
    if prepared:
        fd, _ = _open_regular_readonly(
            temp, f"{operation.name} staged regular file", operation.mode
        )
        try:
            boundaries.hit(f"before_fsync:{direction}-temp:{operation.name}")
            os.fsync(fd)
            boundaries.hit(f"after_fsync:{direction}-temp:{operation.name}")
        finally:
            os.close(fd)
    else:
        source_fd, source_info = _open_regular_readonly(
            source, f"{operation.name} {direction} regular-file source", operation.mode
        )
        try:
            fd = _open_exact_temp(temp, 0o600)
            try:
                while True:
                    block = os.read(source_fd, 1024 * 1024)
                    if not block:
                        break
                    _write_all(fd, block)
                _require_stable_regular_fd(
                    source_fd,
                    source_info,
                    source,
                    f"{operation.name} {direction} regular-file source",
                )
                os.fchmod(fd, operation.mode)
                boundaries.hit(f"before_fsync:{direction}-temp:{operation.name}")
                os.fsync(fd)
                boundaries.hit(f"after_fsync:{direction}-temp:{operation.name}")
            finally:
                os.close(fd)
        finally:
            os.close(source_fd)
    if _sha256_file(
        temp,
        label=f"{operation.name} staged regular file",
        expected_mode=operation.mode,
    ) != expected_hash:
        raise CutoverError(f"{operation.name} staged regular-file hash verification failed")
    boundaries.hit(f"after_prepare:{direction}:{operation.name}")
    _revalidate_manifest_ancestry(manifest)
    _validate_all_release_bindings(manifest)
    expected_current = "old" if direction == "forward" else "new"
    observed = _observe_operation(operation)
    if observed != expected_current:
        raise CutoverError(
            f"{operation.name} changed during preparation; expected "
            f"{expected_current}, observed {observed}"
        )
    boundaries.hit(f"before_replace:{direction}:{operation.name}")
    _validate_quiet_point(manifest)
    _require_regular(temp, f"{operation.name} staged regular file", operation.mode)
    if _observe_operation(operation) != expected_current:
        raise CutoverError(
            f"{operation.name} changed immediately before replacement"
        )
    os.replace(temp, operation.path)
    boundaries.hit(f"after_replace:{direction}:{operation.name}")
    boundaries.hit(f"before_fsync:{direction}-dir:{operation.name}")
    _fsync_directory(operation.path.parent)
    boundaries.hit(f"after_fsync:{direction}-dir:{operation.name}")


def _mutate_operation(
    manifest: Manifest,
    operation: Operation,
    direction: str,
    boundaries: BoundaryController,
) -> None:
    if isinstance(operation, SymlinkOperation):
        target = operation.new_target if direction == "forward" else operation.old_target
        _replace_symlink(manifest, operation, direction, target, boundaries)
    else:
        source = operation.new_source if direction == "forward" else operation.old_source
        digest = operation.new_sha256 if direction == "forward" else operation.old_sha256
        _replace_regular_file(manifest, operation, direction, source, digest, boundaries)


def _plan_locked(
    manifest: Manifest, boundaries: BoundaryController | None = None
) -> dict[str, Any]:
    boundary_controller = boundaries or BoundaryController()
    states, prefix_new, journal = _observe_load_and_seal(manifest, boundary_controller)
    irreversible = bool(journal and journal["post_install_irreversible_boundary"])
    return {
        "mode": "plan",
        "transaction_id": manifest.transaction_id,
        "manifest_sha256": manifest.fingerprint,
        "apply_opt_in": manifest.apply_opt_in,
        "post_install_irreversible_boundary": irreversible,
        "states": [
            {"name": operation.name, "state": state}
            for operation, state in zip(manifest.operations, states)
        ],
        "forward_pending": [operation.name for operation in manifest.operations[prefix_new:]],
        "rollback_pending": [
            operation.name for operation in reversed(manifest.operations[:prefix_new])
        ],
        "rollback_allowed": not irreversible,
    }


def _execute_locked(
    manifest: Manifest,
    direction: str,
    boundaries: BoundaryController | None = None,
) -> dict[str, Any]:
    if direction not in ("forward", "rollback"):
        raise ValueError("direction must be forward or rollback")
    boundary_controller = boundaries or BoundaryController()
    states, prefix_new, loaded_journal = _observe_load_and_seal(
        manifest, boundary_controller
    )
    if not manifest.apply_opt_in:
        raise CutoverError("manifest apply_opt_in is false; mutation is refused")
    journal = loaded_journal or _new_journal(manifest)
    if journal["post_install_irreversible_boundary"] and direction == "rollback":
        raise CutoverError("rollback is forbidden after the post-install irreversible boundary")
    journal["direction"] = direction
    _checkpoint(
        manifest,
        journal,
        direction,
        "start",
        states,
        boundary_controller,
    )

    if direction == "forward":
        indexes: Iterable[int] = range(prefix_new, len(manifest.operations))
        desired = "new"
    else:
        indexes = range(prefix_new - 1, -1, -1)
        desired = "old"

    for index in indexes:
        operation = manifest.operations[index]
        states, current_prefix = observe(manifest)
        expected_current = "old" if direction == "forward" else "new"
        if states[index] != expected_current:
            raise CutoverError(
                f"{operation.name} changed before mutation; expected {expected_current}, "
                f"observed {states[index]}"
            )
        _checkpoint(
            manifest,
            journal,
            operation.name,
            f"before-{direction}",
            states,
            boundary_controller,
        )
        _revalidate_manifest_ancestry(manifest)
        _validate_all_release_bindings(manifest)
        _mutate_operation(manifest, operation, direction, boundary_controller)
        states, new_prefix = observe(manifest)
        if states[index] != desired:
            raise CutoverError(f"{operation.name} did not reach {desired} state")
        if direction == "forward" and new_prefix != current_prefix + 1:
            raise CutoverError(f"{operation.name} produced an unexpected transaction position")
        if direction == "rollback" and new_prefix != current_prefix - 1:
            raise CutoverError(f"{operation.name} produced an unexpected rollback position")
        _checkpoint(
            manifest,
            journal,
            operation.name,
            f"after-{direction}",
            states,
            boundary_controller,
        )

    states, prefix_new = observe(manifest)
    expected_prefix = len(manifest.operations) if direction == "forward" else 0
    if prefix_new != expected_prefix:
        raise CutoverError(f"{direction} did not converge to the expected endpoint")
    _checkpoint(
        manifest,
        journal,
        direction,
        "complete",
        states,
        boundary_controller,
    )
    return {
        "mode": direction,
        "transaction_id": manifest.transaction_id,
        "manifest_sha256": manifest.fingerprint,
        "states": [
            {"name": operation.name, "state": state}
            for operation, state in zip(manifest.operations, states)
        ],
        "post_install_irreversible_boundary": journal[
            "post_install_irreversible_boundary"
        ],
        "converged": True,
    }


def _mark_post_install_irreversible_boundary_locked(
    manifest: Manifest, boundaries: BoundaryController | None = None
) -> dict[str, Any]:
    boundary_controller = boundaries or BoundaryController()
    states, prefix_new, journal = _observe_load_and_seal(manifest, boundary_controller)
    if not manifest.apply_opt_in:
        raise CutoverError("manifest apply_opt_in is false; mutation is refused")
    if prefix_new != len(manifest.operations):
        raise CutoverError(
            "cannot mark the post-install irreversible boundary before the transaction is fully forward"
        )
    if journal is None:
        raise CutoverError(
            "cannot mark the post-install irreversible boundary without a completed transaction journal"
        )
    if journal["post_install_irreversible_boundary"]:
        return {
            "mode": "mark-post-install-irreversible-boundary",
            "transaction_id": manifest.transaction_id,
            "post_install_irreversible_boundary": True,
            "converged": True,
        }
    _checkpoint(
        manifest,
        journal,
        "post-install-irreversible-boundary",
        "before-mark",
        states,
        boundary_controller,
    )
    journal["post_install_irreversible_boundary"] = True
    _checkpoint(
        manifest,
        journal,
        "post-install-irreversible-boundary",
        "after-mark",
        states,
        boundary_controller,
    )
    return {
        "mode": "mark-post-install-irreversible-boundary",
        "transaction_id": manifest.transaction_id,
        "post_install_irreversible_boundary": True,
        "converged": True,
    }


def plan(
    manifest: Manifest, boundaries: BoundaryController | None = None
) -> dict[str, Any]:
    with _transaction_lock(manifest):
        return _plan_locked(manifest, boundaries)


def execute(
    manifest: Manifest,
    direction: str,
    boundaries: BoundaryController | None = None,
) -> dict[str, Any]:
    with _transaction_lock(manifest):
        return _execute_locked(manifest, direction, boundaries)


def mark_post_install_irreversible_boundary(
    manifest: Manifest, boundaries: BoundaryController | None = None
) -> dict[str, Any]:
    """Persist only the rollback boundary; never enroll or invoke a provider.

    This operation performs the same transaction-state and quiet-point checks
    as the cutover itself, then updates the private journal.  It deliberately
    has no provider, browser, Keychain, authentication, or enrollment action.
    """
    with _transaction_lock(manifest):
        return _mark_post_install_irreversible_boundary_locked(manifest, boundaries)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", help="absolute path to the explicit JSON manifest")
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument("--apply", action="store_true", help="apply/reconcile forward")
    actions.add_argument(
        "--rollback",
        action="store_true",
        help="rollback before the post-install irreversible boundary",
    )
    actions.add_argument(
        "--mark-post-install-irreversible-boundary",
        action="store_true",
        help="make rollback permanently unavailable; performs no auth or enrollment",
    )
    parser.add_argument(
        "--inject-failure-at",
        metavar="BOUNDARY",
        help=argparse.SUPPRESS,
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        manifest = load_manifest(args.manifest)
        boundaries: BoundaryController | None = None
        if args.inject_failure_at:
            if os.environ.get("BRIDGE_CUTOVER_ALLOW_FAILURE_INJECTION") != "1":
                raise CutoverError(
                    "failure injection requires BRIDGE_CUTOVER_ALLOW_FAILURE_INJECTION=1"
                )
            boundaries = BoundaryController(args.inject_failure_at)
        if args.apply:
            result = execute(manifest, "forward", boundaries)
        elif args.rollback:
            result = execute(manifest, "rollback", boundaries)
        elif args.mark_post_install_irreversible_boundary:
            result = mark_post_install_irreversible_boundary(manifest, boundaries)
        else:
            result = plan(manifest, boundaries)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    except InjectedFailure as exc:
        print(f"injected-crash: {exc}", file=sys.stderr)
        return 75
    except (CutoverError, OSError) as exc:
        print(f"refused: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
