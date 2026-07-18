#!/usr/bin/env python3
"""Build Quota AXI twice from exact offline inputs and emit a sealed proof.

This helper is deliberately separate from the sealed-runtime builder.  It is
the producer of generated npm bytes; the runtime builder is an independent
consumer/verifier of the resulting package and proof.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import io
import json
import os
import posixpath
import shutil
import stat
import subprocess
import tarfile
from collections.abc import Mapping, Sequence
from pathlib import Path, PurePosixPath
from typing import Any, Callable


class ProofError(RuntimeError):
    pass


SHA256 = __import__("re").compile(r"^[0-9a-f]{64}$")
COMMIT = __import__("re").compile(r"^[0-9a-f]{40}$")
SRI = __import__("re").compile(r"^sha512-[A-Za-z0-9+/]+={0,2}$")
VERSION = __import__("re").compile(r"^[0-9]+(?:\.[0-9]+){1,3}(?:[-+][A-Za-z0-9._-]+)?$")
MAX_SPEC = 1_000_000
JOURNAL_SCHEMA = 2
JOURNAL_PHASES = ("planned", "workspace", "package", "proof", "complete")


def _canonical(value: Any) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode()


def _sha_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _safe_ancestry(path: Path, label: str, *, system_only: bool = False) -> None:
    current = path
    saw_private_user_directory = False
    while True:
        try:
            info = os.lstat(current)
        except FileNotFoundError as exc:
            raise ProofError(f"{label} ancestry is missing: {current}") from exc
        if not stat.S_ISDIR(info.st_mode):
            raise ProofError(f"{label} ancestry is not a real directory: {current}")
        mode = stat.S_IMODE(info.st_mode)
        if info.st_uid == os.getuid() and not system_only:
            if mode & 0o022:
                raise ProofError(
                    f"{label} has group/world-writable user ancestry: {current}"
                )
            saw_private_user_directory = True
        elif info.st_uid == 0:
            if mode & 0o022:
                sticky = bool(mode & stat.S_ISVTX)
                if system_only or not sticky or not saw_private_user_directory:
                    raise ProofError(f"{label} has unsafe root-owned ancestry: {current}")
        else:
            raise ProofError(
                f"{label} ancestry is not owned by current uid or root: {current}"
            )
        if current == current.parent:
            return
        current = current.parent


def _regular_bytes(path: Path, label: str) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    try:
        before = os.fstat(fd)
        if (
            not stat.S_ISREG(before.st_mode)
            or (before.st_nlink != 1 and before.st_uid != 0)
            or before.st_uid not in {os.getuid(), 0}
            or stat.S_IMODE(before.st_mode) & 0o022
        ):
            raise ProofError(f"not an owned, safe single-link regular file: {path}")
        _safe_ancestry(path.parent, label, system_only=before.st_uid == 0)
        payload = bytearray()
        while True:
            block = os.read(fd, 1024 * 1024)
            if not block:
                break
            payload.extend(block)
        after = os.fstat(fd)
        current = os.lstat(path)
        before_identity = (
            before.st_dev,
            before.st_ino,
            before.st_uid,
            before.st_mode,
            before.st_nlink,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
        )
        if before_identity != (
            after.st_dev,
            after.st_ino,
            after.st_uid,
            after.st_mode,
            after.st_nlink,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        ) or before_identity != (
            current.st_dev,
            current.st_ino,
            current.st_uid,
            current.st_mode,
            current.st_nlink,
            current.st_size,
            current.st_mtime_ns,
            current.st_ctime_ns,
        ):
            raise ProofError(f"file changed while hashing: {path}")
        return bytes(payload)
    finally:
        os.close(fd)


def _sha(path: Path) -> str:
    return _sha_bytes(_regular_bytes(path, "offline build input"))


def _tree(root: Path) -> str:
    if not root.is_dir() or root.is_symlink():
        raise ProofError(f"tree root is not a real directory: {root}")
    _safe_ancestry(root, "offline input tree")
    digest = hashlib.sha256(b"bridge-offline-tree-v1\0")
    for path in sorted(root.rglob("*"), key=lambda p: p.relative_to(root).as_posix().encode()):
        relative = path.relative_to(root).as_posix()
        info = os.lstat(path)
        if stat.S_ISDIR(info.st_mode):
            kind, payload = b"dir", b""
        elif stat.S_ISREG(info.st_mode) and info.st_nlink == 1:
            kind, payload = b"file", bytes.fromhex(_sha(path))
        elif stat.S_ISLNK(info.st_mode):
            target = os.readlink(path)
            if not target or "$" in target or os.path.isabs(target):
                raise ProofError(f"tree symlink is unsafe: {path} -> {target!r}")
            resolved = Path(os.path.realpath(path.parent / target))
            try:
                resolved.relative_to(root)
            except ValueError as exc:
                raise ProofError(f"tree symlink escapes: {path} -> {target}") from exc
            resolved_info = os.lstat(resolved)
            if not stat.S_ISREG(resolved_info.st_mode) or resolved_info.st_nlink != 1:
                raise ProofError(f"tree symlink target is not a regular file: {path}")
            kind, payload = b"symlink", hashlib.sha256(target.encode()).digest()
        else:
            raise ProofError(f"unsupported tree entry: {path}")
        digest.update(relative.encode() + b"\0" + kind + b"\0" + payload)
    return digest.hexdigest()


def _strict_json(path: Path, label: str) -> dict[str, Any]:
    payload = _regular_bytes(path, label)
    if len(payload) > MAX_SPEC:
        raise ProofError(f"{label} is too large")

    def pairs(values: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in values:
            if key in result:
                raise ProofError(f"{label} repeats key {key!r}")
            result[key] = value
        return result

    try:
        value = json.loads(payload, object_pairs_hook=pairs)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProofError(f"{label} is invalid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise ProofError(f"{label} must be an object")
    return value


def _exact(value: Any, keys: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise ProofError(f"{label} keys are not exact")
    return value


def _path(value: Any, label: str, *, absent: bool = False) -> Path:
    if not isinstance(value, str) or not os.path.isabs(value) or os.path.normpath(value) != value:
        raise ProofError(f"{label} must be an absolute normalized path")
    result = Path(value)
    anchor = result.parent if absent else result
    if Path(os.path.realpath(anchor)) != anchor:
        raise ProofError(f"{label} is noncanonical")
    if not absent and not result.exists():
        raise ProofError(f"{label} does not exist")
    return result


def _relative(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value or "\x00" in value or "$" in value:
        raise ProofError(f"{label} must be a non-empty literal relative path")
    pure = PurePosixPath(value)
    if pure.is_absolute() or any(part in {"", ".", ".."} for part in pure.parts):
        raise ProofError(f"{label} must be normalized and relative")
    if pure.as_posix() != value:
        raise ProofError(f"{label} must use canonical POSIX separators")
    return value


def _pin(raw: Any, label: str, *, directory: bool = False) -> tuple[Path, str]:
    value = _exact(raw, {"path", "sha256" if not directory else "tree_sha256"}, label)
    path = _path(value["path"], f"{label}.path")
    expected = value["tree_sha256" if directory else "sha256"]
    if not isinstance(expected, str) or not SHA256.fullmatch(expected):
        raise ProofError(f"{label} digest is invalid")
    observed = _tree(path) if directory else _sha(path)
    if observed != expected:
        raise ProofError(f"{label} digest mismatch")
    return path, expected


def _archive_source(
    git: Path, repo: Path, commit: str, destination: Path
) -> dict[str, tuple[str, bytes]]:
    environment = {
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "HOME": "/var/empty",
        "PATH": "/usr/bin:/bin",
        "LANG": "C",
        "LC_ALL": "C",
    }
    resolved = subprocess.run(
        [str(git), "--no-replace-objects", "-C", str(repo), "rev-parse", f"{commit}^{{commit}}"],
        check=False,
        capture_output=True,
        text=True,
        env=environment,
        timeout=30,
    )
    if resolved.returncode or resolved.stdout.strip() != commit:
        raise ProofError("source commit is unavailable or ambiguous")
    git_sha256 = _sha(git)
    completed = subprocess.run(
        [str(git), "--no-replace-objects", "-C", str(repo), "archive", "--format=tar", commit],
        check=False,
        capture_output=True,
        env=environment,
        timeout=60,
    )
    if completed.returncode:
        raise ProofError(completed.stderr.decode(errors="replace"))
    if _sha(git) != git_sha256:
        raise ProofError("git identity changed during source archive")
    members: dict[str, tuple[str, bytes]] = {}
    symlinks: list[tuple[Path, str, str]] = []
    with tarfile.open(fileobj=io.BytesIO(completed.stdout), mode="r:") as archive:
        for member in archive.getmembers():
            pure = PurePosixPath(member.name)
            if pure.is_absolute() or ".." in pure.parts:
                raise ProofError("source archive path escapes")
            target = destination.joinpath(*pure.parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            relative = pure.as_posix()
            if relative in members:
                raise ProofError(f"source archive repeats member: {relative}")
            if member.isfile():
                extracted = archive.extractfile(member)
                if extracted is None:
                    raise ProofError("source archive member cannot be read")
                payload = extracted.read()
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(payload)
                members[relative] = ("file", payload)
            elif member.issym():
                link_target = member.linkname
                if (
                    not link_target
                    or "$" in link_target
                    or PurePosixPath(link_target).is_absolute()
                ):
                    raise ProofError(f"source archive symlink is unsafe: {member.name}")
                resolved = posixpath.normpath(posixpath.join(pure.parent.as_posix(), link_target))
                if resolved == ".." or resolved.startswith("../"):
                    raise ProofError(f"source archive symlink escapes: {member.name}")
                members[relative] = (
                    "symlink",
                    link_target.encode("utf-8"),
                )
                symlinks.append((target, link_target, resolved))
            else:
                raise ProofError(f"source archive contains non-file: {member.name}")
    for target, link_target, resolved in symlinks:
        if members.get(resolved, (None, b""))[0] != "file":
            raise ProofError(f"source archive symlink does not resolve to a file: {target}")
        target.parent.mkdir(parents=True, exist_ok=True)
        os.symlink(link_target, target)
    return members


def _archive_digest(members: Mapping[str, tuple[str, bytes]]) -> str:
    digest = hashlib.sha256(b"bridge-git-archive-v1\0")
    for relative in sorted(members, key=lambda value: value.encode("utf-8")):
        digest.update(relative.encode("utf-8"))
        kind, payload = members[relative]
        digest.update(b"\0" + kind.encode("ascii") + b"\0")
        digest.update(hashlib.sha256(payload).digest())
    return digest.hexdigest()


def _package_members(path: Path) -> dict[str, bytes]:
    members: dict[str, bytes] = {}
    with tarfile.open(path, mode="r:*") as archive:
        for member in archive.getmembers():
            pure = PurePosixPath(member.name)
            if not pure.parts or pure.parts[0] != "package":
                raise ProofError("packed member is outside package/")
            if member.isdir():
                continue
            if not member.isfile() or len(pure.parts) == 1:
                raise ProofError("packed member is linked or special")
            relative = PurePosixPath(*pure.parts[1:]).as_posix()
            if relative in members or ".." in PurePosixPath(relative).parts:
                raise ProofError("packed member path is repeated or unsafe")
            extracted = archive.extractfile(member)
            if extracted is None:
                raise ProofError("packed member cannot be read")
            members[relative] = extracted.read()
    return members


def _json_changes(before: Any, after: Any, prefix: str = "$") -> list[dict[str, Any]]:
    if isinstance(before, dict) and isinstance(after, dict):
        changes: list[dict[str, Any]] = []
        for key in sorted(set(before) | set(after)):
            child = f"{prefix}.{key}"
            if key not in before:
                changes.append({"path": child, "before": None, "after": after[key]})
            elif key not in after:
                changes.append({"path": child, "before": before[key], "after": None})
            else:
                changes.extend(_json_changes(before[key], after[key], child))
        return changes
    if before != after:
        return [{"path": prefix, "before": before, "after": after}]
    return []


def _lock_proof(
    lock: Mapping[str, Any],
    resolved_artifacts: Mapping[Path, str],
    lock_parent: Path,
) -> dict[str, Any]:
    if lock.get("lockfileVersion") != 3 or not isinstance(lock.get("packages"), dict):
        raise ProofError("build lock must be package-lock v3")
    packages = lock["packages"]
    records: list[dict[str, str]] = []
    for install_path in sorted(key for key in packages if key):
        value = packages[install_path]
        if not isinstance(value, dict):
            raise ProofError(f"lock record is not an object: {install_path}")
        version = value.get("version")
        integrity = value.get("integrity")
        resolved = value.get("resolved")
        if (
            not isinstance(version, str)
            or not isinstance(integrity, str)
            or not SRI.fullmatch(integrity)
        ):
            raise ProofError(f"lock record lacks exact version/SRI: {install_path}")
        if not isinstance(resolved, str) or not resolved:
            raise ProofError(f"lock record lacks exact resolved artifact: {install_path}")
        if resolved.startswith("file:"):
            raw_path = resolved.removeprefix("file:")
            if not raw_path or "$" in raw_path or "\x00" in raw_path:
                raise ProofError(f"lock file artifact path is unsafe: {install_path}")
            unresolved = Path(raw_path)
            if not unresolved.is_absolute():
                unresolved = lock_parent / unresolved
            resolved_path = Path(os.path.realpath(unresolved))
            if not resolved_path.is_absolute() or resolved_path not in resolved_artifacts:
                raise ProofError(f"lock file artifact is not an exact retained pin: {install_path}")
        elif not resolved.startswith("https://registry.npmjs.org/"):
            raise ProofError(f"lock record uses an unsupported resolved artifact: {install_path}")
        records.append(
            {
                "install_path": install_path,
                "version": version,
                "integrity": integrity,
                "resolved": resolved,
            }
        )
    referenced_files = {
        Path(
            os.path.realpath(
                Path(record["resolved"].removeprefix("file:"))
                if Path(record["resolved"].removeprefix("file:")).is_absolute()
                else lock_parent / Path(record["resolved"].removeprefix("file:"))
            )
        )
        for record in records
        if record["resolved"].startswith("file:")
    }
    if referenced_files != set(resolved_artifacts):
        raise ProofError("resolved-artifact pins are not the exact lock file closure")
    return {
        "lockfile_version": 3,
        "packages_sha256": _sha_bytes(_canonical(packages)),
        "records": records,
    }


def _run(argv: Sequence[str], cwd: Path, env: Mapping[str, str], timeout: int = 300) -> str:
    result = subprocess.run(
        list(argv),
        cwd=cwd,
        env=dict(env),
        check=False,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if result.returncode:
        raise ProofError(
            f"command failed {list(argv)!r}: {result.stderr.strip() or result.stdout.strip()}"
        )
    return result.stdout.strip()


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _lock_path(package: Path, proof: Path) -> Path:
    pair = _canonical(
        {
            "package_path": str(package),
            "proof_path": str(proof),
        }
    )
    digest = _sha_bytes(b"bridge-quota-output-pair-v1\0" + pair)
    return package.parent / f".quota-proof-output-{digest[:32]}.lock"


def _journal_path(scratch: Path, build_id: str) -> Path:
    return scratch / f".quota-proof-{build_id[:32]}.journal.json"


def _open_build_lock(path: Path) -> int:
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags, 0o600)
    try:
        info = os.fstat(descriptor)
        current = os.lstat(path)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid()
            or info.st_nlink != 1
            or stat.S_IMODE(info.st_mode) != 0o600
            or (info.st_dev, info.st_ino) != (current.st_dev, current.st_ino)
        ):
            raise ProofError(f"offline-build lock is not attributable: {path}")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise ProofError(
                "a Quota offline build for these output destinations is already running"
            ) from exc
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def _file_identity(path: Path) -> tuple[int, int, str]:
    info = os.lstat(path)
    return info.st_dev, info.st_ino, _sha(path)


def _replace_owned_json(
    path: Path,
    previous: tuple[int, int, str] | None,
    value: Mapping[str, Any],
) -> tuple[int, int, str]:
    payload = _canonical(value)
    digest = _sha_bytes(payload)
    staging = path.with_name(f".{path.name}.bridge-swap-{digest[:32]}")
    if os.path.lexists(staging):
        info = os.lstat(staging)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid()
            or info.st_nlink != 1
            or stat.S_IMODE(info.st_mode) != 0o600
        ):
            raise ProofError(f"journal staging path is not attributable: {staging}")
        staged = _regular_bytes(staging, "journal staging")
        if len(staged) > len(payload) or not payload.startswith(staged):
            raise ProofError(f"journal staging payload is not attributable: {staging}")
        staging.unlink()
        _fsync_directory(staging.parent)
    if previous is None:
        if os.path.lexists(path):
            raise ProofError(f"offline-build journal appeared unexpectedly: {path}")
    else:
        if not os.path.lexists(path) or _file_identity(path) != previous:
            raise ProofError(f"offline-build journal changed concurrently: {path}")
    descriptor = os.open(
        staging,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        os.fchmod(descriptor, 0o600)
        remaining = memoryview(payload)
        while remaining:
            count = os.write(descriptor, remaining)
            if count <= 0:
                raise ProofError("short write while updating offline-build journal")
            remaining = remaining[count:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    if previous is not None and _file_identity(path) != previous:
        raise ProofError(f"offline-build journal changed before replacement: {path}")
    os.replace(staging, path)
    _fsync_directory(path.parent)
    return _file_identity(path)


def _journal_value(
    *,
    spec_path: Path,
    spec_sha256: str,
    build_id: str,
    phase: str,
    workspaces: Sequence[Path],
    package_path: Path,
    proof_path: Path,
    package_generation: Mapping[str, Any] | None = None,
    proof_generation: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    if phase not in JOURNAL_PHASES:
        raise ProofError(f"invalid offline-build journal phase: {phase}")
    return {
        "schema_version": JOURNAL_SCHEMA,
        "spec_path": str(spec_path),
        "spec_sha256": spec_sha256,
        "build_id": build_id,
        "phase": phase,
        "workspaces": [str(path) for path in workspaces],
        "package_path": str(package_path),
        "proof_path": str(proof_path),
        "package_generation": (
            None if package_generation is None else dict(package_generation)
        ),
        "proof_generation": (
            None if proof_generation is None else dict(proof_generation)
        ),
    }


def _output_generation(
    path: Path,
    payload: bytes,
    build_id: str,
    identity: tuple[int, int, str] | None = None,
) -> dict[str, Any]:
    digest = _sha_bytes(payload)
    generation = hashlib.sha256(
        b"bridge-quota-output-generation-v1\0"
        + bytes.fromhex(build_id)
        + str(path).encode("utf-8")
        + bytes.fromhex(digest)
    ).hexdigest()
    staging = path.with_name(
        f".{path.name}.bridge-write-{generation[:24]}-{digest[:16]}"
    )
    return {
        "path": str(path),
        "staging_path": str(staging),
        "generation": generation,
        "sha256": digest,
        "size": len(payload),
        "dev": None if identity is None else identity[0],
        "ino": None if identity is None else identity[1],
    }


def _validate_output_generation(
    value: Any,
    expected_path: Path,
    build_id: str,
    label: str,
) -> dict[str, Any] | None:
    if value is None:
        return None
    if not isinstance(value, dict) or set(value) != {
        "path", "staging_path", "generation", "sha256", "size", "dev", "ino"
    }:
        raise ProofError(f"{label} generation fields are not exact")
    if (
        value["path"] != str(expected_path)
        or not isinstance(value["generation"], str)
        or not SHA256.fullmatch(value["generation"])
        or not isinstance(value["sha256"], str)
        or not SHA256.fullmatch(value["sha256"])
        or not isinstance(value["size"], int)
        or isinstance(value["size"], bool)
        or value["size"] < 0
    ):
        raise ProofError(f"{label} generation identity is invalid")
    expected_generation = hashlib.sha256(
        b"bridge-quota-output-generation-v1\0"
        + bytes.fromhex(build_id)
        + str(expected_path).encode("utf-8")
        + bytes.fromhex(value["sha256"])
    ).hexdigest()
    expected_staging = expected_path.with_name(
        f".{expected_path.name}.bridge-write-"
        f"{expected_generation[:24]}-{value['sha256'][:16]}"
    )
    if (
        value["generation"] != expected_generation
        or value["staging_path"] != str(expected_staging)
    ):
        raise ProofError(f"{label} generation binding is invalid")
    identity = (value["dev"], value["ino"])
    if identity == (None, None):
        return value
    if not all(isinstance(item, int) and not isinstance(item, bool) and item >= 0 for item in identity):
        raise ProofError(f"{label} generation inode is invalid")
    return value


def _read_owned_journal(path: Path, expected_base: Mapping[str, Any]) -> tuple[dict[str, Any], tuple[int, int, str]]:
    info = os.lstat(path)
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != os.getuid()
        or info.st_nlink != 1
        or stat.S_IMODE(info.st_mode) != 0o600
    ):
        raise ProofError(f"offline-build journal is not attributable: {path}")
    value = _strict_json(path, "offline-build journal")
    if set(value) != {
        "schema_version", "spec_path", "spec_sha256", "build_id", "phase",
        "workspaces", "package_path", "proof_path", "package_generation", "proof_generation",
    }:
        raise ProofError("offline-build journal fields are not exact")
    for key, expected in expected_base.items():
        if value.get(key) != expected:
            raise ProofError("offline-build journal belongs to another build")
    if value["schema_version"] != JOURNAL_SCHEMA or value["phase"] not in JOURNAL_PHASES:
        raise ProofError("offline-build journal schema/phase is invalid")
    package = _validate_output_generation(
        value["package_generation"],
        Path(value["package_path"]),
        value["build_id"],
        "package",
    )
    proof = _validate_output_generation(
        value["proof_generation"],
        Path(value["proof_path"]),
        value["build_id"],
        "proof",
    )
    if value["phase"] in {"planned", "workspace"} and (package is not None or proof is not None):
        raise ProofError("pre-publication journal unexpectedly owns output generations")
    if value["phase"] == "package" and (package is None or proof is not None):
        raise ProofError("package journal does not own the exact package generation")
    if value["phase"] in {"proof", "complete"} and (package is None or proof is None):
        raise ProofError("proof/complete journal does not own both output generations")
    return value, (info.st_dev, info.st_ino, _sha(path))


def _cleanup_output_generation(
    value: Mapping[str, Any] | None,
    *,
    completed: bool,
) -> None:
    if value is None:
        return
    path = Path(value["path"])
    staging = Path(value["staging_path"])
    existing = [candidate for candidate in (path, staging) if os.path.lexists(candidate)]
    if completed and existing != [path]:
        raise ProofError("completed offline-build output generation is incomplete")
    if value["dev"] is None:
        if existing:
            raise ProofError(
                "offline-build output exists without journaled inode ownership: "
                f"{existing[0]}"
            )
        return
    for candidate in existing:
        info, observed_digest = _output_generation_identity(candidate)
        if (
            (info.st_dev, info.st_ino) != (value["dev"], value["ino"])
            or info.st_size > value["size"]
            or (
                candidate == path
                and (
                    info.st_size != value["size"]
                    or observed_digest != value["sha256"]
                )
            )
            or (
                candidate == staging
                and info.st_size == value["size"]
                and observed_digest != value["sha256"]
            )
        ):
            raise ProofError(f"offline-build output generation changed: {candidate}")
    if completed:
        if os.lstat(path).st_nlink != 1:
            raise ProofError("completed offline-build output has unexpected hard links")
        return
    for candidate in existing:
        current = os.lstat(candidate)
        if (current.st_dev, current.st_ino) != (value["dev"], value["ino"]):
            raise ProofError(
                f"offline-build output generation changed before cleanup: {candidate}"
            )
        candidate.unlink()
        _fsync_directory(candidate.parent)


def _output_generation_identity(
    path: Path,
    *,
    mode: int = 0o600,
) -> tuple[os.stat_result, str]:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != os.getuid()
            or before.st_nlink not in {1, 2}
            or stat.S_IMODE(before.st_mode) != mode
        ):
            raise ProofError(f"offline-build output generation is unsafe: {path}")
        payload = bytearray()
        while True:
            block = os.read(descriptor, 1024 * 1024)
            if not block:
                break
            payload.extend(block)
        after = os.fstat(descriptor)
        current = os.lstat(path)
        fields = (
            "st_dev", "st_ino", "st_uid", "st_mode", "st_nlink", "st_size",
            "st_mtime_ns", "st_ctime_ns",
        )
        if any(
            getattr(before, field) != getattr(value, field)
            for field in fields
            for value in (after, current)
        ):
            raise ProofError(f"offline-build output generation changed: {path}")
        return after, _sha_bytes(bytes(payload))
    finally:
        os.close(descriptor)


def _recover_journal_state(
    journal: Mapping[str, Any],
    markers: Sequence[Mapping[str, Any]],
) -> bool:
    workspaces = [Path(value) for value in journal["workspaces"]]
    for path, marker in zip(workspaces, markers, strict=True):
        _recover_workspace(path, marker)
    if journal["phase"] == "complete":
        _cleanup_output_generation(journal["package_generation"], completed=True)
        _cleanup_output_generation(journal["proof_generation"], completed=True)
        return True
    _cleanup_output_generation(journal["proof_generation"], completed=False)
    _cleanup_output_generation(journal["package_generation"], completed=False)
    return False


def _workspace_marker(
    spec_path: Path,
    spec_sha256: str,
    path: Path,
    build_index: int,
) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "spec_path": str(spec_path),
        "spec_sha256": spec_sha256,
        "path": str(path),
        "build_index": build_index,
    }


def _remove_workspace(path: Path, expected: Mapping[str, Any]) -> None:
    if not os.path.lexists(path):
        return
    info = os.lstat(path)
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.getuid()
        or stat.S_IMODE(info.st_mode) != 0o700
    ):
        raise ProofError(f"offline-build workspace is not attributable: {path}")
    marker = _strict_json(path / ".bridge-quota-build-workspace.json", "workspace marker")
    if marker != expected:
        raise ProofError(f"offline-build workspace belongs to another build: {path}")
    shutil.rmtree(path)
    _fsync_directory(path.parent)


def _recover_workspace(path: Path, expected: Mapping[str, Any]) -> None:
    """Remove only a journal-planned workspace, including pre-marker crashes."""

    if not os.path.lexists(path):
        return
    info = os.lstat(path)
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.getuid()
        or stat.S_IMODE(info.st_mode) != 0o700
    ):
        raise ProofError(f"offline-build workspace is not attributable: {path}")
    marker = path / ".bridge-quota-build-workspace.json"
    marker_payload = _canonical(expected)
    marker_digest = _sha_bytes(marker_payload)
    marker_staging = marker.with_name(
        f".{marker.name}.bridge-write-{marker_digest[:32]}"
    )
    names = {child.name for child in path.iterdir()}
    if marker.name in names:
        if _strict_json(marker, "workspace marker") != expected:
            raise ProofError(f"offline-build workspace belongs to another build: {path}")
    else:
        allowed = {marker_staging.name}
        if names - allowed:
            raise ProofError(
                f"offline-build workspace has no ownership marker and is not empty: {path}"
            )
        if marker_staging.name in names:
            staged = _regular_bytes(marker_staging, "workspace marker staging")
            staged_info = os.lstat(marker_staging)
            if (
                staged_info.st_uid != os.getuid()
                or staged_info.st_nlink != 1
                or stat.S_IMODE(staged_info.st_mode) != 0o400
                or len(staged) > len(marker_payload)
                or not marker_payload.startswith(staged)
            ):
                raise ProofError(
                    f"offline-build workspace marker staging is not attributable: {path}"
                )
    shutil.rmtree(path)
    _fsync_directory(path.parent)


def _create_workspace(path: Path, marker: Mapping[str, Any]) -> None:
    if path.exists() or path.is_symlink():
        raise ProofError(f"offline-build workspace already exists: {path}")
    path.mkdir(mode=0o700)
    marker_path = path / ".bridge-quota-build-workspace.json"
    _publish_bytes_no_replace(marker_path, _canonical(marker), 0o400)
    _fsync_directory(path)


def _publish_bytes_no_replace(
    path: Path,
    payload: bytes,
    mode: int = 0o600,
    *,
    staging_path: Path | None = None,
    before_publish: Callable[[tuple[int, int, str]], None] | None = None,
) -> tuple[int, int, str]:
    if path.exists() or path.is_symlink():
        raise ProofError(f"refusing to overwrite output: {path}")
    digest = _sha_bytes(payload)
    staging = staging_path or path.with_name(
        f".{path.name}.bridge-write-{digest[:32]}"
    )
    if os.path.lexists(staging):
        raise ProofError(
            f"output staging exists without journaled inode ownership: {staging}"
        )
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(staging, flags, mode)
    identity: tuple[int, int, str] | None = None
    try:
        try:
            os.fchmod(descriptor, mode)
            staged_info = os.fstat(descriptor)
            if (
                not stat.S_ISREG(staged_info.st_mode)
                or staged_info.st_uid != os.getuid()
                or staged_info.st_nlink != 1
                or stat.S_IMODE(staged_info.st_mode) != mode
            ):
                raise ProofError(f"new output staging inode is unsafe: {staging}")
            identity = (staged_info.st_dev, staged_info.st_ino, digest)
            if before_publish is not None:
                before_publish(identity)
            remaining = memoryview(payload)
            while remaining:
                count = os.write(descriptor, remaining)
                if count <= 0:
                    raise ProofError(f"short write while publishing: {path}")
                remaining = remaining[count:]
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        staged_info, staged_digest = _output_generation_identity(staging, mode=mode)
        if (
            identity is None
            or (staged_info.st_dev, staged_info.st_ino) != identity[:2]
            or staged_info.st_size != len(payload)
            or staged_digest != digest
        ):
            raise ProofError(f"output generation changed before publication: {staging}")
        os.link(staging, path, follow_symlinks=False)
        _fsync_directory(path.parent)
        staging.unlink()
        _fsync_directory(path.parent)
    except Exception as exc:
        if identity is not None and os.path.lexists(staging):
            current, _ = _output_generation_identity(staging, mode=mode)
            if (current.st_dev, current.st_ino) != identity[:2]:
                raise ProofError(
                    f"output generation changed during publication: {staging}"
                ) from exc
            current = os.lstat(staging)
            if (current.st_dev, current.st_ino) != identity[:2]:
                raise ProofError(
                    f"output generation changed before exception cleanup: {staging}"
                ) from exc
            staging.unlink()
            _fsync_directory(staging.parent)
        raise
    assert identity is not None
    info = os.lstat(path)
    if info.st_nlink != 1 or _sha(path) != digest:
        raise ProofError(f"published output identity is invalid: {path}")
    if (info.st_dev, info.st_ino) != identity[:2]:
        raise ProofError(f"published output inode changed: {path}")
    return identity


def _unlink_owned(path: Path, identity: tuple[int, int, str]) -> None:
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_nlink != 1
        or (info.st_dev, info.st_ino, _sha(path)) != identity
    ):
        raise ProofError(f"refusing to remove output whose identity changed: {path}")
    path.unlink()
    _fsync_directory(path.parent)


def _one_build(
    *,
    base: Path,
    git: Path,
    repo: Path,
    commit: str,
    node: Path,
    node_sha256: str,
    node_version: str,
    npm_root: Path,
    npm_entry: str,
    npm_version: str,
    npm_cache: Path,
    lock_path: Path,
    build_package_json: Path,
    compiler_relative: str,
    compiler_sha256: str,
    compiler_args: Sequence[str],
) -> tuple[Path, dict[str, bytes], dict[str, tuple[str, bytes]]]:
    source = base / "source"
    source.mkdir()
    source_members = _archive_source(git, repo, commit, source)
    shutil.copy2(lock_path, source / "package-lock.json")
    shutil.copy2(build_package_json, source / "package.json")
    private_tools = base / "tools"
    private_tools.mkdir()
    shutil.copy2(node, private_tools / "node")
    if _sha(private_tools / "node") != node_sha256:
        raise ProofError("private Node copy differs from its pinned source")
    shutil.copytree(npm_root, private_tools / "npm", symlinks=True)
    if _tree(private_tools / "npm") != _tree(npm_root):
        raise ProofError("private npm closure differs from its pinned source")
    private_cache = base / "npm-cache"
    shutil.copytree(npm_cache, private_cache, symlinks=True)
    if _tree(private_cache) != _tree(npm_cache):
        raise ProofError("private npm cache differs from its pinned source")
    env = {
        "HOME": str(base / "home"),
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin",
        "SOURCE_DATE_EPOCH": "1580601600",
        "TMPDIR": str(base / "tmp"),
        "npm_config_audit": "false",
        "npm_config_fund": "false",
        "npm_config_offline": "true",
        "npm_config_update_notifier": "false",
    }
    Path(env["HOME"]).mkdir()
    Path(env["TMPDIR"]).mkdir()
    npm = private_tools / "npm" / npm_entry
    if _run([str(private_tools / "node"), "--version"], source, env) != f"v{node_version}":
        raise ProofError("private Node empirical version differs from its pin")
    if _run([str(private_tools / "node"), str(npm), "--version"], source, env) != npm_version:
        raise ProofError("private npm empirical version differs from its pin")
    _run(
        [
            str(private_tools / "node"),
            str(npm),
            "ci",
            "--offline",
            "--ignore-scripts",
            "--no-audit",
            "--no-fund",
            "--cache",
            str(private_cache),
        ],
        source,
        env,
        600,
    )
    compiler = source.joinpath(*PurePosixPath(compiler_relative).parts)
    if _sha(compiler) != compiler_sha256:
        raise ProofError("installed compiler digest differs from its pin")
    _run([str(private_tools / "node"), str(compiler), *compiler_args], source, env, 600)
    (source / "package.json").write_bytes(source_members["package.json"][1])
    pack_dir = base / "pack"
    pack_dir.mkdir()
    output = _run(
        [
            str(private_tools / "node"),
            str(npm),
            "pack",
            "--ignore-scripts",
            "--json",
            "--pack-destination",
            str(pack_dir),
        ],
        source,
        env,
        300,
    )
    try:
        packed = json.loads(output)
        filename = packed[0]["filename"]
    except (json.JSONDecodeError, KeyError, IndexError, TypeError) as exc:
        raise ProofError("npm pack did not return its exact JSON result") from exc
    tarball = pack_dir / filename
    return tarball, _package_members(tarball), source_members


def build(spec_path: Path) -> tuple[Path, Path]:
    spec_path = _path(str(spec_path), "Quota build spec")
    raw = _strict_json(spec_path, "Quota build spec")
    required = {
        "schema_version",
        "role",
        "version",
        "source_repo",
        "source_commit",
        "source_tree_sha256",
        "git",
        "node",
        "npm",
        "npm_cache",
        "build_lock",
        "build_package_json",
        "resolved_artifacts",
        "compiler",
        "package_tarball",
        "proof",
        "scratch_parent",
    }
    _exact(raw, required, "Quota build spec")
    if raw["schema_version"] != 1 or raw["role"] not in {"candidate", "rollback"}:
        raise ProofError("Quota build spec schema/role is invalid")
    if not isinstance(raw["version"], str) or not VERSION.fullmatch(raw["version"]):
        raise ProofError("Quota build version is invalid")
    commit = raw["source_commit"]
    if not isinstance(commit, str) or not COMMIT.fullmatch(commit):
        raise ProofError("source commit is not exact")
    repo = _path(raw["source_repo"], "source_repo")
    if not repo.is_dir() or repo.is_symlink():
        raise ProofError("source_repo must be a real directory")
    _safe_ancestry(repo, "source_repo")
    if not isinstance(raw["source_tree_sha256"], str) or not SHA256.fullmatch(
        raw["source_tree_sha256"]
    ):
        raise ProofError("source tree digest is invalid")
    helper_path = Path(os.path.realpath(__file__))
    helper_sha256 = _sha(helper_path)
    git, git_sha256 = _pin(raw["git"], "git")
    if git != Path("/usr/bin/git") or os.lstat(git).st_uid != 0:
        raise ProofError("git must be the immutable root-owned /usr/bin/git")
    node_raw = _exact(raw["node"], {"path", "sha256", "version"}, "node")
    node = _path(node_raw["path"], "node.path")
    if (
        not isinstance(node_raw["sha256"], str)
        or not SHA256.fullmatch(node_raw["sha256"])
        or _sha(node) != node_raw["sha256"]
        or not isinstance(node_raw["version"], str)
        or not node_raw["version"].startswith("20.")
    ):
        raise ProofError("Node 20 identity is invalid")
    npm_raw = _exact(raw["npm"], {"root", "tree_sha256", "entry", "version"}, "npm")
    npm_root = _path(npm_raw["root"], "npm.root")
    if _tree(npm_root) != npm_raw["tree_sha256"]:
        raise ProofError("npm closure tree mismatch")
    npm_entry = _relative(npm_raw["entry"], "npm.entry")
    if not isinstance(npm_raw["version"], str) or not VERSION.fullmatch(npm_raw["version"]):
        raise ProofError("npm version is invalid")
    npm_entry_path = npm_root.joinpath(*PurePosixPath(npm_entry).parts)
    if not npm_entry_path.is_file():
        raise ProofError("npm entry is missing")
    npm_cache, npm_cache_tree = _pin(raw["npm_cache"], "npm_cache", directory=True)
    lock_path, lock_sha = _pin(raw["build_lock"], "build_lock")
    lock = _strict_json(lock_path, "build lock")
    build_package_path, build_package_sha = _pin(raw["build_package_json"], "build_package_json")
    build_package = _strict_json(build_package_path, "build package.json")
    if build_package.get("name") != "quota-axi" or build_package.get("version") != raw["version"]:
        raise ProofError("build package.json identity differs from the source role")
    if not isinstance(raw["resolved_artifacts"], list):
        raise ProofError("resolved_artifacts must be a path-sorted array")
    resolved_artifacts: dict[Path, str] = {}
    previous = ""
    for index, artifact_raw in enumerate(raw["resolved_artifacts"]):
        artifact, digest = _pin(artifact_raw, f"resolved_artifacts[{index}]")
        if str(artifact) <= previous or artifact in resolved_artifacts:
            raise ProofError("resolved_artifacts must be unique and path-sorted")
        previous = str(artifact)
        resolved_artifacts[artifact] = digest
    lock_proof = _lock_proof(lock, resolved_artifacts, lock_path.parent)
    compiler = _exact(raw["compiler"], {"relative_path", "sha256", "args"}, "compiler")
    compiler["relative_path"] = _relative(compiler["relative_path"], "compiler.relative_path")
    if not isinstance(compiler["sha256"], str) or not SHA256.fullmatch(compiler["sha256"]):
        raise ProofError("compiler digest is invalid")
    if not isinstance(compiler["args"], list) or not all(
        isinstance(v, str) for v in compiler["args"]
    ):
        raise ProofError("compiler args must be exact strings")
    package_path = _path(raw["package_tarball"], "package_tarball", absent=True)
    proof_path = _path(raw["proof"], "proof", absent=True)
    _safe_ancestry(package_path.parent, "package_tarball output")
    _safe_ancestry(proof_path.parent, "proof output")
    scratch = _path(raw["scratch_parent"], "scratch_parent")
    if not scratch.is_dir() or scratch.is_symlink():
        raise ProofError("scratch_parent must be a real directory")
    _safe_ancestry(scratch, "scratch_parent")
    spec_sha256 = _sha(spec_path)
    build_id = hashlib.sha256(
        b"bridge-quota-offline-build-v1\0" + bytes.fromhex(spec_sha256)
    ).hexdigest()
    workspaces = (
        scratch / f".quota-proof-{build_id[:32]}-a",
        scratch / f".quota-proof-{build_id[:32]}-b",
    )
    markers = tuple(
        _workspace_marker(spec_path, spec_sha256, path, index)
        for index, path in enumerate(workspaces, start=1)
    )
    journal_path = _journal_path(scratch, build_id)
    lock_descriptor = _open_build_lock(_lock_path(package_path, proof_path))
    expected_journal = {
        "schema_version": JOURNAL_SCHEMA,
        "spec_path": str(spec_path),
        "spec_sha256": spec_sha256,
        "build_id": build_id,
        "workspaces": [str(path) for path in workspaces],
        "package_path": str(package_path),
        "proof_path": str(proof_path),
    }
    created: list[tuple[Path, Mapping[str, Any]]] = []
    journal: dict[str, Any] | None = None
    journal_identity: tuple[int, int, str] | None = None
    try:
        if os.path.lexists(journal_path):
            journal, journal_identity = _read_owned_journal(
                journal_path, expected_journal
            )
            if _recover_journal_state(journal, markers):
                return package_path, proof_path
            journal = _journal_value(
                spec_path=spec_path,
                spec_sha256=spec_sha256,
                build_id=build_id,
                phase="planned",
                workspaces=workspaces,
                package_path=package_path,
                proof_path=proof_path,
            )
            journal_identity = _replace_owned_json(
                journal_path, journal_identity, journal
            )
        else:
            if package_path.exists() or package_path.is_symlink() or proof_path.exists() or proof_path.is_symlink():
                raise ProofError("output package/proof exists without an attributable journal")
            for path in workspaces:
                if os.path.lexists(path):
                    raise ProofError(
                        f"offline-build workspace exists without an ownership journal: {path}"
                    )
            journal = _journal_value(
                spec_path=spec_path,
                spec_sha256=spec_sha256,
                build_id=build_id,
                phase="planned",
                workspaces=workspaces,
                package_path=package_path,
                proof_path=proof_path,
            )
            journal_identity = _replace_owned_json(journal_path, None, journal)
        for path, marker in zip(workspaces, markers, strict=True):
            _create_workspace(path, marker)
            created.append((path, marker))
        journal = _journal_value(
            spec_path=spec_path,
            spec_sha256=spec_sha256,
            build_id=build_id,
            phase="workspace",
            workspaces=workspaces,
            package_path=package_path,
            proof_path=proof_path,
        )
        journal_identity = _replace_owned_json(
            journal_path, journal_identity, journal
        )
        builds = []
        for path in workspaces:
            builds.append(
                _one_build(
                    base=path,
                    git=git,
                    repo=repo,
                    commit=commit,
                    node=node,
                    node_sha256=node_raw["sha256"],
                    node_version=node_raw["version"],
                    npm_root=npm_root,
                    npm_entry=npm_entry,
                    npm_version=npm_raw["version"],
                    npm_cache=npm_cache,
                    lock_path=lock_path,
                    build_package_json=build_package_path,
                    compiler_relative=compiler["relative_path"],
                    compiler_sha256=compiler["sha256"],
                    compiler_args=compiler["args"],
                )
            )
        first_tar, first_members, source_members = builds[0]
        second_tar, second_members, second_source_members = builds[1]
        if (
            source_members != second_source_members
            or first_members != second_members
            or _sha(first_tar) != _sha(second_tar)
        ):
            raise ProofError("two offline Quota builds are not byte-for-byte deterministic")
        if _archive_digest(source_members) != raw["source_tree_sha256"]:
            raise ProofError("exact source archive tree digest differs from its pin")
        if (
            _sha(helper_path) != helper_sha256
            or _sha(git) != git_sha256
            or _sha(node) != node_raw["sha256"]
            or _tree(npm_root) != npm_raw["tree_sha256"]
            or _tree(npm_cache) != npm_cache_tree
            or _sha(lock_path) != lock_sha
            or _sha(build_package_path) != build_package_sha
            or any(_sha(path) != digest for path, digest in resolved_artifacts.items())
        ):
            raise ProofError("a pinned offline build input changed while it was consumed")
        source_package = json.loads(source_members["package.json"][1])
        packed_package = json.loads(first_members["package.json"])
        if (
            packed_package.get("name") != "quota-axi"
            or packed_package.get("version") != raw["version"]
        ):
            raise ProofError("packed Quota identity is wrong")
        generated = []
        for relative, payload in sorted(first_members.items()):
            source_payload = source_members.get(relative)
            if source_payload == ("file", payload):
                continue
            if relative == "package.json":
                continue
            if not relative.startswith("dist/"):
                raise ProofError(f"non-source package member is outside dist/: {relative}")
            generated.append(
                {"path": relative, "sha256": _sha_bytes(payload), "size": len(payload)}
            )
        proof = {
            "schema_version": 1,
            "kind": "quota-axi-offline-deterministic-build",
            "role": raw["role"],
            "version": raw["version"],
            "source": {
                "repo": str(repo),
                "commit": commit,
                "tree_sha256": raw["source_tree_sha256"],
                "package_json_sha256": _sha_bytes(source_members["package.json"][1]),
            },
            "toolchain": {
                "helper": {
                    "path": str(helper_path),
                    "sha256": helper_sha256,
                },
                "git": raw["git"],
                "node": node_raw,
                "npm": npm_raw,
                "npm_cache_path": str(npm_cache),
                "npm_cache_tree_sha256": npm_cache_tree,
                "build_package_json": {
                    "path": str(build_package_path),
                    "sha256": build_package_sha,
                },
                "resolved_artifacts": [
                    {"path": str(path), "sha256": digest}
                    for path, digest in resolved_artifacts.items()
                ],
                "compiler": compiler,
            },
            "build_lock": {"path": str(lock_path), "sha256": lock_sha, **lock_proof},
            "build_package_json_normalization": {
                "source_sha256": _sha_bytes(source_members["package.json"][1]),
                "build_sha256": build_package_sha,
                "changes": _json_changes(source_package, build_package),
            },
            "npm_package_json_normalization": {
                "source_sha256": _sha_bytes(source_members["package.json"][1]),
                "packed_sha256": _sha_bytes(first_members["package.json"]),
                "changes": _json_changes(source_package, packed_package),
            },
            "generated_members": generated,
            "package_members": [
                {"path": path, "sha256": _sha_bytes(payload), "size": len(payload)}
                for path, payload in sorted(first_members.items())
            ],
            "package_tarball_sha256": _sha(first_tar),
            "builds": 2,
            "member_maps_match": True,
            "tar_digests_match": True,
        }
        package_payload = first_tar.read_bytes()
        proof_payload = _canonical(proof)
        journal = _journal_value(
            spec_path=spec_path,
            spec_sha256=spec_sha256,
            build_id=build_id,
            phase="package",
            workspaces=workspaces,
            package_path=package_path,
            proof_path=proof_path,
            package_generation=_output_generation(
                package_path, package_payload, build_id
            ),
        )
        journal_identity = _replace_owned_json(
            journal_path, journal_identity, journal
        )
        package_generation = dict(journal["package_generation"])

        def bind_package(identity: tuple[int, int, str]) -> None:
            nonlocal journal, journal_identity, package_generation
            package_generation = _output_generation(
                package_path, package_payload, build_id, identity
            )
            journal = {**journal, "package_generation": package_generation}
            journal_identity = _replace_owned_json(
                journal_path, journal_identity, journal
            )

        _publish_bytes_no_replace(
            package_path,
            package_payload,
            staging_path=Path(package_generation["staging_path"]),
            before_publish=bind_package,
        )
        proof_generation = _output_generation(proof_path, proof_payload, build_id)
        journal = {
            **journal,
            "phase": "proof",
            "proof_generation": proof_generation,
        }
        journal_identity = _replace_owned_json(
            journal_path, journal_identity, journal
        )

        def bind_proof(identity: tuple[int, int, str]) -> None:
            nonlocal journal, journal_identity, proof_generation
            proof_generation = _output_generation(
                proof_path, proof_payload, build_id, identity
            )
            journal = {**journal, "proof_generation": proof_generation}
            journal_identity = _replace_owned_json(
                journal_path, journal_identity, journal
            )

        _publish_bytes_no_replace(
            proof_path,
            proof_payload,
            staging_path=Path(proof_generation["staging_path"]),
            before_publish=bind_proof,
        )
        journal = {**journal, "phase": "complete"}
        journal_identity = _replace_owned_json(
            journal_path, journal_identity, journal
        )
        for path, marker in reversed(created):
            _remove_workspace(path, marker)
        created.clear()
    except Exception:
        if journal is not None:
            completed = _recover_journal_state(journal, markers)
            if completed:
                raise
            planned = _journal_value(
                spec_path=spec_path,
                spec_sha256=spec_sha256,
                build_id=build_id,
                phase="planned",
                workspaces=workspaces,
                package_path=package_path,
                proof_path=proof_path,
            )
            if journal_identity is not None:
                _replace_owned_json(journal_path, journal_identity, planned)
        raise
    finally:
        fcntl.flock(lock_descriptor, fcntl.LOCK_UN)
        os.close(lock_descriptor)
    return package_path, proof_path


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        package, proof = build(args.spec)
    except (ProofError, OSError, subprocess.TimeoutExpired) as exc:
        parser.error(str(exc))
    print(json.dumps({"package": str(package), "proof": str(proof)}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
