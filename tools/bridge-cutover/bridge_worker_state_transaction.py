#!/usr/bin/env python3
"""Restartable six-worker state snapshot, verification, and rollback gate.

This driver never enrolls an account, starts a provider, opens a browser,
reads Keychain values, or touches reserve/Desktop homes.  It snapshots only
the explicit managed state for the six Fleet workers plus the two atomic
non-secret provider identity bundles.  Credential files are immutable guards:
only the six declared ``.credentials.json``/``auth.json`` paths are opened and
read, their bytes are hashed in memory, and they are never copied into the
snapshot.  Reserve/Desktop homes are never statted, opened, or read.
"""

from __future__ import annotations

import argparse
import ctypes
import errno
import fcntl
import hashlib
import importlib.util
import json
import os
import pwd
import shutil
import stat
import sys
import uuid
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType
from typing import Any, Callable, Mapping, Sequence


SCHEMA_VERSION = 1
JOURNAL_SCHEMA_VERSION = 2
SNAPSHOT_SCHEMA_VERSION = 1
MAX_MANIFEST_BYTES = 1_000_000
MAX_JOURNAL_BYTES = 2_000_000
MAX_FILE_BYTES = 16 * 1024 * 1024
MAX_TREE_ENTRIES = 20_000
SHA256 = __import__("re").compile(r"^[0-9a-f]{64}$")
SAFE_NAME = __import__("re").compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")

WORKERS = {
    "claude-1": "claude",
    "claude-2": "claude",
    "codex-1": "codex",
    "codex-2": "codex",
    "codex-3": "codex",
    "codex-4": "codex",
}
RESERVES = {"claude-3", "codex-5"}
MUTABLE_PATHS = {
    "claude": (
        ".claude.json",
        "settings.json",
        ".agent-fleet-hooks.json",
        ".agent-fleet-provider-binary.json",
        ".agent-fleet-profile.json",
        "hooks",
        "plugins",
        "CLAUDE.md",
        "skills",
    ),
    "codex": (
        "config.toml",
        "hooks.json",
        ".agent-fleet-hooks.json",
        ".agent-fleet-provider-binary.json",
        ".agent-fleet-profile.json",
        "hooks",
        "plugins",
        "AGENTS.md",
        "skills",
        "rules",
    ),
}
CREDENTIAL_GUARD = {"claude": ".credentials.json", "codex": "auth.json"}


class WorkerStateError(RuntimeError):
    """A manifest, state, guard, verification, or recovery refusal."""


class InjectedFailure(RuntimeError):
    """A deterministic test-only crash boundary."""


@dataclass
class BoundaryController:
    fail_after: int | None = None
    count: int = 0

    def hit(self, label: str) -> None:
        self.count += 1
        if self.fail_after == self.count:
            raise InjectedFailure(f"injected failure after {label}")


@dataclass(frozen=True)
class Worker:
    profile: str
    provider: str
    home: Path
    plan_sha256: str


@dataclass(frozen=True)
class Manifest:
    path: Path
    fingerprint: str
    transaction_id: str
    apply_opt_in: bool
    snapshot_parent: Path
    lock_path: Path
    journal_path: Path
    snapshot_path: Path
    cutover_manifest_path: Path
    bundle_path: Path
    bundle_sha256: str
    candidate_registry_path: Path
    candidate_registry_sha256: str
    candidate_release: Path
    candidate_pythonpath: Path
    candidate_version: str
    workers: tuple[Worker, ...]
    identity_bundles: dict[str, Path]
    sealed_plans: dict[str, dict[str, Any]]


def _exact_keys(
    value: Mapping[str, Any], required: set[str], optional: set[str], label: str
) -> None:
    missing = required - set(value)
    unknown = set(value) - required - optional
    if missing:
        raise WorkerStateError(f"{label} is missing keys: {', '.join(sorted(missing))}")
    if unknown:
        raise WorkerStateError(f"{label} has unknown keys: {', '.join(sorted(unknown))}")


def _absolute(value: Any, label: str) -> Path:
    if not isinstance(value, str) or not value or "\x00" in value or "$" in value:
        raise WorkerStateError(f"{label} must be a literal absolute or explicit ~/ path")
    if value.startswith("~/"):
        value = os.path.join(pwd.getpwuid(os.getuid()).pw_dir, value[2:])
    if not os.path.isabs(value) or os.path.normpath(value) != value:
        raise WorkerStateError(f"{label} must be absolute and normalized: {value!r}")
    return Path(value)


def _relative(value: Any, label: str) -> str:
    if (
        not isinstance(value, str)
        or not value
        or "\x00" in value
        or "$" in value
        or os.path.isabs(value)
        or os.path.normpath(value) != value
        or any(part in {"", ".", ".."} for part in Path(value).parts)
    ):
        raise WorkerStateError(f"{label} must be a safe normalized relative path")
    return value


def _paths_overlap(left: Path, right: Path) -> bool:
    return left == right or left in right.parents or right in left.parents


def _hash_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _read_stable_file(path: Path, label: str) -> tuple[bytes, os.stat_result]:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        raise WorkerStateError(f"cannot open {label}: {path}: {exc}") from exc
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise WorkerStateError(f"{label} must be a single-link regular file: {path}")
        if before.st_size > MAX_FILE_BYTES:
            raise WorkerStateError(f"{label} exceeds {MAX_FILE_BYTES} bytes: {path}")
        chunks: list[bytes] = []
        remaining = before.st_size
        while remaining:
            block = os.read(fd, min(1024 * 1024, remaining))
            if not block:
                raise WorkerStateError(f"{label} changed while being read: {path}")
            chunks.append(block)
            remaining -= len(block)
        if os.read(fd, 1):
            raise WorkerStateError(f"{label} grew while being read: {path}")
        after = os.fstat(fd)
        stable_fields = (
            "st_dev",
            "st_ino",
            "st_mode",
            "st_nlink",
            "st_uid",
            "st_gid",
            "st_size",
            "st_mtime_ns",
            "st_ctime_ns",
        )
        if any(getattr(before, key) != getattr(after, key) for key in stable_fields):
            raise WorkerStateError(f"{label} changed while being read: {path}")
        return b"".join(chunks), after
    finally:
        os.close(fd)


def _sha256(path: Path, label: str) -> str:
    return _hash_bytes(_read_stable_file(path, label)[0])


def _read_json(path: Path, label: str, limit: int) -> Any:
    payload, _ = _read_stable_file(path, label)
    if len(payload) > limit:
        raise WorkerStateError(f"{label} exceeds {limit} bytes")
    try:
        return json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise WorkerStateError(f"{label} is not valid UTF-8 JSON: {exc}") from exc


def _canonical_bytes(value: Any) -> bytes:
    try:
        return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")
    except (TypeError, ValueError) as exc:
        raise WorkerStateError(f"value is not canonical JSON: {exc}") from exc


def _fsync_directory(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _write_atomic(path: Path, payload: bytes, mode: int = 0o600) -> None:
    tag = hashlib.sha256(str(path).encode("utf-8")).hexdigest()[:16]
    temporary = path.parent / f".{path.name}.bridge-write-{tag}"
    if os.path.lexists(temporary):
        partial, info = _read_stable_file(temporary, "interrupted atomic write")
        if (
            info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != mode
            or not payload.startswith(partial)
        ):
            raise WorkerStateError(
                f"interrupted atomic write is not attributable: {temporary}"
            )
        temporary.unlink()
        _fsync_directory(path.parent)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(temporary, flags, mode)
    try:
        os.fchmod(fd, mode)
        offset = 0
        while offset < len(payload):
            offset += os.write(fd, payload[offset:])
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(temporary, path)
    _fsync_directory(path.parent)


def _private_directory(path: Path, label: str) -> None:
    try:
        info = os.lstat(path)
    except FileNotFoundError as exc:
        raise WorkerStateError(f"{label} does not exist: {path}") from exc
    if not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) & 0o077:
        raise WorkerStateError(f"{label} must be a real private directory: {path}")
    if Path(os.path.realpath(path)) != path:
        raise WorkerStateError(f"{label} must be canonical: {path}")


def _safe_parent_chain(path: Path, label: str) -> None:
    ancestor = path.parent
    missing: list[Path] = []
    while True:
        try:
            info = os.lstat(ancestor)
        except FileNotFoundError:
            missing.append(ancestor)
            if ancestor.parent == ancestor:
                raise WorkerStateError(f"{label} has no existing parent")
            ancestor = ancestor.parent
            continue
        if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
            raise WorkerStateError(f"{label} parent chain is not real directories")
        if Path(os.path.realpath(ancestor)) != ancestor:
            raise WorkerStateError(f"{label} parent chain is non-canonical")
        break
    for candidate in reversed(missing):
        if candidate.name in {"", ".", ".."}:
            raise WorkerStateError(f"{label} parent chain is unsafe")


def _open_bound_directory(
    path: Path,
    label: str,
    *,
    expected: Mapping[str, Any] | None = None,
    allow_absent: bool = False,
) -> int | None:
    """Open a directory leaf without following it and bind its identity."""

    _safe_parent_chain(path, label)
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except FileNotFoundError:
        if allow_absent:
            return None
        raise WorkerStateError(f"{label} does not exist: {path}") from None
    except OSError as exc:
        raise WorkerStateError(f"cannot bind {label}: {path}: {exc}") from exc
    try:
        opened = os.fstat(fd)
        leaf = os.lstat(path)
        if (
            not stat.S_ISDIR(opened.st_mode)
            or not stat.S_ISDIR(leaf.st_mode)
            or stat.S_ISLNK(leaf.st_mode)
            or opened.st_dev != leaf.st_dev
            or opened.st_ino != leaf.st_ino
            or opened.st_uid != os.getuid()
            or Path(os.path.realpath(path)) != path
        ):
            raise WorkerStateError(f"{label} is not the bound canonical owned directory")
        if expected is not None and expected.get("type") == "dir" and any(
            opened_field != expected.get(key)
            for key, opened_field in (
                ("dev", opened.st_dev),
                ("ino", opened.st_ino),
                ("uid", opened.st_uid),
            )
        ):
            raise WorkerStateError(f"{label} identity changed after snapshot")
        return fd
    except Exception:
        os.close(fd)
        raise


def _assert_bound_directory(fd: int, path: Path, label: str) -> None:
    try:
        opened = os.fstat(fd)
        leaf = os.lstat(path)
    except OSError as exc:
        raise WorkerStateError(f"{label} identity disappeared: {path}: {exc}") from exc
    if (
        not stat.S_ISDIR(opened.st_mode)
        or not stat.S_ISDIR(leaf.st_mode)
        or stat.S_ISLNK(leaf.st_mode)
        or opened.st_dev != leaf.st_dev
        or opened.st_ino != leaf.st_ino
    ):
        raise WorkerStateError(f"{label} identity changed during transaction")


def _close_bound_directories(values: Mapping[str, int | None]) -> None:
    for fd in values.values():
        if fd is not None:
            os.close(fd)


def _load_module(path: Path, name: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise WorkerStateError(f"cannot import {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    except Exception as exc:
        raise WorkerStateError(f"cannot import {path}: {exc}") from exc
    return module


def load_manifest(path_value: str | os.PathLike[str]) -> Manifest:
    path = _absolute(os.fspath(path_value), "worker-state manifest path")
    if Path(os.path.realpath(path)) != path:
        raise WorkerStateError("worker-state manifest path is not canonical")
    raw = _read_json(path, "worker-state manifest", MAX_MANIFEST_BYTES)
    if not isinstance(raw, dict):
        raise WorkerStateError("worker-state manifest root must be an object")
    _exact_keys(
        raw,
        {
            "schema_version",
            "transaction_id",
            "apply_opt_in",
            "snapshot_parent",
            "lock_path",
            "journal_path",
            "snapshot_path",
            "cutover_manifest_path",
            "bundle_path",
            "bundle_sha256",
            "candidate_registry_path",
            "candidate_registry_sha256",
            "candidate_release",
            "candidate_pythonpath",
            "candidate_version",
            "workers",
            "identity_bundles",
            "sealed_plans",
        },
        set(),
        "worker-state manifest",
    )
    if raw["schema_version"] != SCHEMA_VERSION:
        raise WorkerStateError("unsupported worker-state manifest schema")
    transaction_id = raw["transaction_id"]
    if not isinstance(transaction_id, str) or not SAFE_NAME.fullmatch(transaction_id):
        raise WorkerStateError("transaction_id is not a safe identifier")
    if raw["apply_opt_in"] is not True:
        raise WorkerStateError("worker-state mutation is not opted in")
    snapshot_parent = _absolute(raw["snapshot_parent"], "snapshot_parent")
    _private_directory(snapshot_parent, "snapshot_parent")
    lock_path = _absolute(raw["lock_path"], "lock_path")
    journal_path = _absolute(raw["journal_path"], "journal_path")
    snapshot_path = _absolute(raw["snapshot_path"], "snapshot_path")
    expected = {
        "lock": snapshot_parent / f"{transaction_id}.lock",
        "journal": snapshot_parent / f"{transaction_id}.journal.json",
        "snapshot": snapshot_parent / f"{transaction_id}.snapshot",
    }
    if lock_path != expected["lock"] or journal_path != expected["journal"] or snapshot_path != expected["snapshot"]:
        raise WorkerStateError("worker-state runtime paths are not exact direct children")
    cutover_manifest_path = _absolute(
        raw["cutover_manifest_path"], "cutover_manifest_path"
    )
    bundle_path = _absolute(raw["bundle_path"], "bundle_path")
    candidate_registry_path = _absolute(
        raw["candidate_registry_path"], "candidate_registry_path"
    )
    candidate_release = _absolute(raw["candidate_release"], "candidate_release")
    candidate_pythonpath = _absolute(
        raw["candidate_pythonpath"], "candidate_pythonpath"
    )
    if candidate_pythonpath != candidate_release / "site-packages":
        raise WorkerStateError("candidate_pythonpath is not release-relative exact")
    for digest_label in ("bundle_sha256", "candidate_registry_sha256"):
        if not isinstance(raw[digest_label], str) or not SHA256.fullmatch(raw[digest_label]):
            raise WorkerStateError(f"{digest_label} is not a lowercase SHA-256")
    if _sha256(bundle_path, "bundle") != raw["bundle_sha256"]:
        raise WorkerStateError("bundle SHA-256 mismatch")
    if _sha256(candidate_registry_path, "candidate registry") != raw["candidate_registry_sha256"]:
        raise WorkerStateError("candidate registry SHA-256 mismatch")
    if raw["candidate_version"] != "0.2.0":
        raise WorkerStateError("candidate_version must be exactly 0.2.0")
    worker_values = raw["workers"]
    if not isinstance(worker_values, list) or len(worker_values) != len(WORKERS):
        raise WorkerStateError("workers must contain exactly six records")
    workers: list[Worker] = []
    for index, value in enumerate(worker_values):
        if not isinstance(value, dict):
            raise WorkerStateError(f"workers[{index}] must be an object")
        _exact_keys(
            value,
            {"profile", "provider", "home", "plan_sha256"},
            set(),
            f"workers[{index}]",
        )
        profile = value["profile"]
        if profile not in WORKERS or value["provider"] != WORKERS.get(profile):
            raise WorkerStateError(f"workers[{index}] is not an exact managed worker")
        if not isinstance(value["plan_sha256"], str) or not SHA256.fullmatch(
            value["plan_sha256"]
        ):
            raise WorkerStateError(f"workers[{index}].plan_sha256 is invalid")
        workers.append(
            Worker(
                profile=profile,
                provider=value["provider"],
                home=_absolute(value["home"], f"workers[{index}].home"),
                plan_sha256=value["plan_sha256"],
            )
        )
    if [worker.profile for worker in workers] != sorted(WORKERS):
        raise WorkerStateError("workers must be exactly profile-sorted")
    homes = [worker.home for worker in workers]
    if len(set(homes)) != len(homes):
        raise WorkerStateError("worker homes must be unique")
    for left in homes:
        for right in homes:
            if left != right and (left in right.parents or right in left.parents):
                raise WorkerStateError("worker homes may not overlap")
    plans = raw["sealed_plans"]
    if not isinstance(plans, dict) or set(plans) != set(WORKERS):
        raise WorkerStateError("sealed_plans must cover exactly six workers")
    for worker in workers:
        value = plans[worker.profile]
        if (
            not isinstance(value, dict)
            or set(value) != {"plan", "plan_sha256"}
            or value["plan_sha256"] != worker.plan_sha256
            or _hash_bytes(_canonical_bytes(value["plan"])) != worker.plan_sha256
        ):
            raise WorkerStateError(f"sealed plan is invalid for {worker.profile}")
        plan = value["plan"]
        if not isinstance(plan, dict) or plan.get("home") != str(worker.home):
            raise WorkerStateError(f"sealed plan home mismatch for {worker.profile}")
    identity_values = raw["identity_bundles"]
    if not isinstance(identity_values, dict) or set(identity_values) != {"claude", "codex"}:
        raise WorkerStateError("identity_bundles must contain exactly claude and codex")
    identity_bundles = {
        provider: _absolute(value, f"identity_bundles.{provider}")
        for provider, value in identity_values.items()
    }
    state_dir = identity_bundles["claude"].parent.parent
    if identity_bundles != {
        "claude": state_dir / "identity-bindings" / "claude-bundle.json",
        "codex": state_dir / "identity-bindings" / "codex-bundle.json",
    }:
        raise WorkerStateError("identity bundle paths are not the exact atomic pair")
    if any(path == worker.home or worker.home in path.parents for path in identity_bundles.values() for worker in workers):
        raise WorkerStateError("identity bundle paths overlap worker homes")
    protected = [bundle_path.parent, *homes, *identity_bundles.values()]
    if any(
        snapshot_parent == value
        or snapshot_parent in value.parents
        or value in snapshot_parent.parents
        for value in protected
    ):
        raise WorkerStateError(
            "snapshot_parent overlaps bundle, worker, or identity state"
        )
    mutable_roots = [*homes, state_dir, snapshot_parent]
    for index, mutable in enumerate(mutable_roots):
        for other in mutable_roots[index + 1 :]:
            if _paths_overlap(mutable, other):
                raise WorkerStateError("mutable worker/identity/snapshot roots overlap")
    immutable_inputs = [
        path,
        cutover_manifest_path,
        bundle_path,
        candidate_registry_path,
        candidate_release,
    ]
    for mutable in mutable_roots:
        for immutable in immutable_inputs:
            if _paths_overlap(mutable, immutable):
                raise WorkerStateError(
                    "mutable worker/identity/snapshot state overlaps immutable control input"
                )
    return Manifest(
        path=path,
        fingerprint=_hash_bytes(_canonical_bytes(raw)),
        transaction_id=transaction_id,
        apply_opt_in=True,
        snapshot_parent=snapshot_parent,
        lock_path=lock_path,
        journal_path=journal_path,
        snapshot_path=snapshot_path,
        cutover_manifest_path=cutover_manifest_path,
        bundle_path=bundle_path,
        bundle_sha256=raw["bundle_sha256"],
        candidate_registry_path=candidate_registry_path,
        candidate_registry_sha256=raw["candidate_registry_sha256"],
        candidate_release=candidate_release,
        candidate_pythonpath=candidate_pythonpath,
        candidate_version=raw["candidate_version"],
        workers=tuple(workers),
        identity_bundles=identity_bundles,
        sealed_plans={key: dict(value) for key, value in plans.items()},
    )


def _lock(manifest: Manifest) -> int:
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(manifest.lock_path, flags, 0o600)
    os.fchmod(fd, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    return fd


def _driver() -> ModuleType:
    return _load_module(
        Path(__file__).with_name("bridge_cutover_transaction.py"),
        f"_worker_state_cutover_{uuid.uuid4().hex}",
    )


def _quiet(manifest: Manifest) -> None:
    driver = _driver()
    try:
        cutover = driver.load_manifest(manifest.cutover_manifest_path)
        driver._validate_quiet_point(cutover)
    except Exception as exc:
        raise WorkerStateError(f"worker-state quiet point failed: {exc}") from exc
    if tuple(cutover.quiet_point.worker_profile_ids) != tuple(sorted(WORKERS)):
        raise WorkerStateError("cutover quiet point does not bind exactly six workers")
    if tuple(cutover.quiet_point.never_enroll_profile_ids) != tuple(sorted(RESERVES)):
        raise WorkerStateError("cutover quiet point does not bind exactly two reserves")


def _snapshot_node(path: Path, data_root: Path, key: str, counter: list[int]) -> dict[str, Any]:
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return {"type": "absent"}
    counter[0] += 1
    if counter[0] > MAX_TREE_ENTRIES:
        raise WorkerStateError("managed state exceeds the snapshot entry limit")
    if stat.S_ISREG(info.st_mode):
        payload, stable = _read_stable_file(path, "managed worker state")
        data_name = f"{key}-{_hash_bytes(payload)[:24]}.bin"
        data_path = data_root / data_name
        _write_atomic(data_path, payload, 0o600)
        return {
            "type": "file",
            "mode": f"{stat.S_IMODE(stable.st_mode):04o}",
            "sha256": _hash_bytes(payload),
            "size": len(payload),
            "data": data_name,
        }
    if stat.S_ISLNK(info.st_mode):
        target = os.readlink(path)
        if "\x00" in target or "$" in target:
            raise WorkerStateError(f"managed symlink has unsafe target: {path}")
        return {"type": "symlink", "target": target}
    if stat.S_ISDIR(info.st_mode):
        children: dict[str, Any] = {}
        with os.scandir(path) as iterator:
            entries = sorted(iterator, key=lambda entry: entry.name.encode("utf-8"))
        for entry in entries:
            name = _relative(entry.name, "managed directory entry")
            children[name] = _snapshot_node(
                path / name,
                data_root,
                f"{key}-{hashlib.sha256(name.encode()).hexdigest()[:12]}",
                counter,
            )
        return {
            "type": "dir",
            "mode": f"{stat.S_IMODE(info.st_mode):04o}",
            "entries": children,
        }
    raise WorkerStateError(f"managed state has unsupported file type: {path}")


def _credential_guard_at(parent_fd: int | None, relative: str) -> dict[str, Any]:
    if parent_fd is None:
        return {"state": "absent"}
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(relative, flags, dir_fd=parent_fd)
    except FileNotFoundError:
        return {"state": "absent"}
    except OSError as exc:
        raise WorkerStateError(f"cannot open credential guard {relative}: {exc}") from exc
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise WorkerStateError(
                f"credential guard must be a single-link regular file: {relative}"
            )
        if before.st_size > MAX_FILE_BYTES:
            raise WorkerStateError(f"credential guard exceeds {MAX_FILE_BYTES} bytes")
        chunks: list[bytes] = []
        remaining = before.st_size
        while remaining:
            block = os.read(fd, min(1024 * 1024, remaining))
            if not block:
                raise WorkerStateError("credential guard changed while being read")
            chunks.append(block)
            remaining -= len(block)
        if os.read(fd, 1):
            raise WorkerStateError("credential guard grew while being read")
        after = os.fstat(fd)
        stable_fields = (
            "st_dev",
            "st_ino",
            "st_mode",
            "st_nlink",
            "st_uid",
            "st_gid",
            "st_size",
            "st_mtime_ns",
            "st_ctime_ns",
        )
        if any(getattr(before, key) != getattr(after, key) for key in stable_fields):
            raise WorkerStateError("credential guard changed while being read")
        return {
            "state": "file",
            "sha256": _hash_bytes(b"".join(chunks)),
            "mode": f"{stat.S_IMODE(after.st_mode):04o}",
            "uid": after.st_uid,
            "dev": after.st_dev,
            "ino": after.st_ino,
            "size": after.st_size,
            "mtime_ns": after.st_mtime_ns,
        }
    finally:
        os.close(fd)


def _snapshot_manifest(manifest: Manifest, staging: Path) -> dict[str, Any]:
    data_root = staging / "data"
    data_root.mkdir(mode=0o700)
    workers: dict[str, Any] = {}
    counter = [0]
    for worker in manifest.workers:
        home_fd = _open_bound_directory(
            worker.home, f"worker home {worker.profile}", allow_absent=True
        )
        if home_fd is None:
            home_state: dict[str, Any] = {"type": "absent"}
        else:
            home_info = os.fstat(home_fd)
            home_state = {
                "type": "dir",
                "mode": f"{stat.S_IMODE(home_info.st_mode):04o}",
                "uid": home_info.st_uid,
                "dev": home_info.st_dev,
                "ino": home_info.st_ino,
            }
        try:
            mutable: dict[str, Any] = {}
            for relative in MUTABLE_PATHS[worker.provider]:
                target = worker.home / relative
                state = _snapshot_node(
                    target,
                    data_root,
                    f"{worker.profile}-{hashlib.sha256(relative.encode()).hexdigest()[:12]}",
                    counter,
                )
                if relative == "plugins" and state["type"] not in {"absent", "symlink"}:
                    raise WorkerStateError(
                        f"legacy plugins state is not an exact symlink/absence: {target}"
                    )
                if relative in {"CLAUDE.md", "AGENTS.md", "skills", "rules"} and state[
                    "type"
                ] not in {"absent", "symlink"}:
                    raise WorkerStateError(f"workflow state is not a symlink/absence: {target}")
                mutable[relative] = state
            if home_fd is not None:
                _assert_bound_directory(home_fd, worker.home, f"worker home {worker.profile}")
            credential_identity = _credential_guard_at(
                home_fd, CREDENTIAL_GUARD[worker.provider]
            )
        finally:
            if home_fd is not None:
                os.close(home_fd)
        workers[worker.profile] = {
            "provider": worker.provider,
            "home": str(worker.home),
            "home_state": home_state,
            "mutable": mutable,
            "credential_guard": {
                "relative_path": CREDENTIAL_GUARD[worker.provider],
                "identity": credential_identity,
            },
        }
    identity: dict[str, Any] = {}
    for provider, path in manifest.identity_bundles.items():
        identity[provider] = {
            "path": str(path),
            "state": _snapshot_node(
                path, data_root, f"identity-{provider}", counter
            ),
        }
        if identity[provider]["state"]["type"] not in {"absent", "file"}:
            raise WorkerStateError(f"identity bundle is not a regular file/absence: {path}")
    return {
        "schema_version": SNAPSHOT_SCHEMA_VERSION,
        "manifest_fingerprint": manifest.fingerprint,
        "workers": workers,
        "identity_bundles": identity,
    }


def _validate_identity_journal_state(
    value: Any,
    label: str,
    *,
    restore: bool = False,
) -> dict[str, Any]:
    if not isinstance(value, dict) or value.get("type") not in {"absent", "file"}:
        raise WorkerStateError(f"{label} is invalid")
    if value["type"] == "absent":
        if value != {"type": "absent"}:
            raise WorkerStateError(f"{label} absent fields are not exact")
        return value
    _exact_keys(
        value,
        {"type", "mode", "sha256", "size", *({"data"} if restore else set())},
        set(),
        label,
    )
    if (
        not isinstance(value["mode"], str)
        or not __import__("re").fullmatch(r"[0-7]{4}", value["mode"])
        or not isinstance(value["sha256"], str)
        or not SHA256.fullmatch(value["sha256"])
        or not isinstance(value["size"], int)
        or isinstance(value["size"], bool)
        or value["size"] < 0
    ):
        raise WorkerStateError(f"{label} file fields are invalid")
    if restore:
        _relative(value["data"], f"{label}.data")
    return value


def _journal(manifest: Manifest) -> dict[str, Any] | None:
    if not os.path.lexists(manifest.journal_path):
        return None
    value = _read_json(manifest.journal_path, "worker-state journal", MAX_JOURNAL_BYTES)
    if not isinstance(value, dict):
        raise WorkerStateError("worker-state journal must be an object")
    _exact_keys(
        value,
        {
            "schema_version",
            "manifest_fingerprint",
            "phase",
            "snapshot_sha256",
            "restore_completed",
            "identity_restore",
            "credential_drift",
            "terminal_outcome",
            "history",
        },
        set(),
        "worker-state journal",
    )
    if value["schema_version"] != JOURNAL_SCHEMA_VERSION:
        raise WorkerStateError("worker-state journal schema mismatch")
    if value["manifest_fingerprint"] != manifest.fingerprint:
        raise WorkerStateError("worker-state journal belongs to another manifest")
    if value["phase"] not in {
        "snapshotted",
        "provision_verified",
        "complete",
        "rolling_back",
        "rolled_back",
        "cleaning",
        "cleaned",
    }:
        raise WorkerStateError("worker-state journal phase is invalid")
    if not isinstance(value["snapshot_sha256"], str) or not SHA256.fullmatch(
        value["snapshot_sha256"]
    ):
        raise WorkerStateError("worker-state journal snapshot digest is invalid")
    allowed_restore_keys = {
        *(f"worker:{worker.profile}:{relative}" for worker in manifest.workers for relative in MUTABLE_PATHS[worker.provider]),
        "identity:claude",
        "identity:codex",
    }
    if (
        not isinstance(value["restore_completed"], list)
        or not all(
            isinstance(item, str) and item in allowed_restore_keys
            for item in value["restore_completed"]
        )
        or len(value["restore_completed"]) != len(set(value["restore_completed"]))
    ):
        raise WorkerStateError("worker-state journal restore list is invalid")
    identity_restore = value["identity_restore"]
    if identity_restore is not None:
        if not isinstance(identity_restore, dict):
            raise WorkerStateError("worker-state identity restore must be an object")
        _exact_keys(
            identity_restore,
            {"provider", "key", "phase", "authority", "restore_state"},
            set(),
            "worker-state identity restore",
        )
        provider = identity_restore["provider"]
        if (
            provider not in {"claude", "codex"}
            or identity_restore["key"] != f"identity:{provider}"
            or identity_restore["phase"] not in {"prepared", "exchanged"}
            or identity_restore["key"] in value["restore_completed"]
        ):
            raise WorkerStateError("worker-state identity restore phase/key is invalid")
        authority = identity_restore["authority"]
        if not isinstance(authority, dict):
            raise WorkerStateError("worker-state identity authority must be an object")
        _exact_keys(
            authority,
            {"state", "dev", "ino"},
            set(),
            "worker-state identity authority",
        )
        state = _validate_identity_journal_state(
            authority["state"], "worker-state identity authority state"
        )
        if state["type"] == "absent":
            if (authority["dev"], authority["ino"]) != (None, None):
                raise WorkerStateError("absent identity authority generation is invalid")
        else:
            if (
                not all(
                    isinstance(item, int) and not isinstance(item, bool) and item >= 0
                    for item in (authority["dev"], authority["ino"])
                )
            ):
                raise WorkerStateError("file identity authority generation is invalid")
        _validate_identity_journal_state(
            identity_restore["restore_state"],
            "worker-state identity restore state",
            restore=True,
        )
    if (
        not isinstance(value["credential_drift"], list)
        or not all(item in WORKERS for item in value["credential_drift"])
        or len(value["credential_drift"]) != len(set(value["credential_drift"]))
    ):
        raise WorkerStateError("worker-state journal credential drift list is invalid")
    if not isinstance(value["history"], list):
        raise WorkerStateError("worker-state journal history is invalid")
    if value["terminal_outcome"] not in {None, "complete", "rolled_back"}:
        raise WorkerStateError("worker-state journal terminal outcome is invalid")
    return value


def _write_journal(manifest: Manifest, value: Mapping[str, Any]) -> None:
    _write_atomic(manifest.journal_path, _canonical_bytes(value), 0o600)


def _event(value: dict[str, Any], name: str) -> None:
    # Deterministic history makes an interrupted journal temp byte-for-byte
    # attributable on restart. Wall-clock timestamps belong in operator logs,
    # not in the recovery authority.
    value["history"].append(
        {"event": name, "sequence": len(value["history"]) + 1}
    )


def begin(
    manifest: Manifest,
    boundaries: BoundaryController | None = None,
) -> dict[str, Any]:
    boundaries = boundaries or BoundaryController()
    lock_fd = _lock(manifest)
    try:
        existing = _journal(manifest)
        if existing is not None:
            return plan(manifest)
        _quiet(manifest)
        for worker in manifest.workers:
            _safe_parent_chain(worker.home, f"worker home {worker.profile}")
        for provider, path in manifest.identity_bundles.items():
            _safe_parent_chain(path, f"identity bundle {provider}")
        if os.path.lexists(manifest.snapshot_path):
            _private_directory(manifest.snapshot_path, "orphan worker-state snapshot")
            snapshot_sha256 = _sha256(
                manifest.snapshot_path / "snapshot.json", "orphan snapshot manifest"
            )
            _load_snapshot(manifest, {"snapshot_sha256": snapshot_sha256})
            recovered = {
                "schema_version": JOURNAL_SCHEMA_VERSION,
                "manifest_fingerprint": manifest.fingerprint,
                "phase": "snapshotted",
                "snapshot_sha256": snapshot_sha256,
                "restore_completed": [],
                "identity_restore": None,
                "credential_drift": [],
                "terminal_outcome": None,
                "history": [],
            }
            _event(recovered, "orphan-snapshot-recovered")
            _write_journal(manifest, recovered)
            return plan(manifest)
        staging = manifest.snapshot_parent / f".{manifest.transaction_id}.snapshot-staging"
        marker = staging / ".bridge-worker-snapshot.json"
        marker_payload = _canonical_bytes(
            {
                "schema_version": 1,
                "manifest_fingerprint": manifest.fingerprint,
                "transaction_id": manifest.transaction_id,
            }
        )
        if os.path.lexists(staging):
            _private_directory(staging, "interrupted worker-state snapshot staging")
            names = set(os.listdir(staging))
            marker_tag = hashlib.sha256(str(marker).encode("utf-8")).hexdigest()[:16]
            marker_temp = f".{marker.name}.bridge-write-{marker_tag}"
            if marker.name not in names:
                if names - {marker_temp}:
                    raise WorkerStateError(
                        "interrupted worker-state staging has no ownership marker"
                    )
                _write_atomic(marker, marker_payload, 0o600)
            observed_marker, _ = _read_stable_file(
                marker, "worker-state staging ownership marker"
            )
            if observed_marker != marker_payload:
                raise WorkerStateError(
                    "interrupted worker-state staging belongs to another manifest"
                )
            shutil.rmtree(staging)
            _fsync_directory(manifest.snapshot_parent)
        staging.mkdir(mode=0o700)
        try:
            _write_atomic(marker, marker_payload, 0o600)
            _fsync_directory(staging)
            snapshot = _snapshot_manifest(manifest, staging)
            snapshot_path = staging / "snapshot.json"
            _write_atomic(snapshot_path, _canonical_bytes(snapshot), 0o600)
            _fsync_directory(staging / "data")
            _fsync_directory(staging)
            boundaries.hit("snapshot-fsync")
            os.replace(staging, manifest.snapshot_path)
            _fsync_directory(manifest.snapshot_parent)
            boundaries.hit("snapshot-publish")
        except Exception:
            if staging.exists():
                shutil.rmtree(staging)
            raise
        snapshot_sha256 = _sha256(
            manifest.snapshot_path / "snapshot.json", "snapshot manifest"
        )
        journal = {
            "schema_version": JOURNAL_SCHEMA_VERSION,
            "manifest_fingerprint": manifest.fingerprint,
            "phase": "snapshotted",
            "snapshot_sha256": snapshot_sha256,
            "restore_completed": [],
            "identity_restore": None,
            "credential_drift": [],
            "terminal_outcome": None,
            "history": [],
        }
        _event(journal, "snapshot-published")
        _write_journal(manifest, journal)
        boundaries.hit("journal-publish")
        return plan(manifest)
    finally:
        os.close(lock_fd)


def _load_snapshot(manifest: Manifest, journal: Mapping[str, Any]) -> dict[str, Any]:
    _private_directory(manifest.snapshot_path, "worker-state snapshot")
    path = manifest.snapshot_path / "snapshot.json"
    if _sha256(path, "snapshot manifest") != journal["snapshot_sha256"]:
        raise WorkerStateError("snapshot manifest SHA-256 mismatch")
    value = _read_json(path, "snapshot manifest", MAX_JOURNAL_BYTES)
    if not isinstance(value, dict):
        raise WorkerStateError("snapshot manifest must be an object")
    _exact_keys(
        value,
        {"schema_version", "manifest_fingerprint", "workers", "identity_bundles"},
        set(),
        "snapshot manifest",
    )
    if (
        value["schema_version"] != SNAPSHOT_SCHEMA_VERSION
        or value["manifest_fingerprint"] != manifest.fingerprint
        or set(value["workers"]) != set(WORKERS)
        or set(value["identity_bundles"]) != {"claude", "codex"}
    ):
        raise WorkerStateError("snapshot manifest identity is not exact")
    return value


def _open_worker_homes(
    manifest: Manifest, snapshot: Mapping[str, Any]
) -> dict[str, int | None]:
    opened: dict[str, int | None] = {}
    try:
        for worker in manifest.workers:
            opened[worker.profile] = _open_bound_directory(
                worker.home,
                f"worker home {worker.profile}",
                expected=snapshot["workers"][worker.profile]["home_state"],
                allow_absent=True,
            )
        return opened
    except Exception:
        _close_bound_directories(opened)
        raise


def _guards_unchanged(
    manifest: Manifest,
    snapshot: Mapping[str, Any],
    home_fds: Mapping[str, int | None],
) -> None:
    for worker in manifest.workers:
        value = snapshot["workers"][worker.profile]
        guard = value["credential_guard"]
        try:
            observed = _credential_guard_at(
                home_fds[worker.profile], guard["relative_path"]
            )
        except WorkerStateError:
            observed = None
        if observed != guard["identity"]:
            raise WorkerStateError(
                f"credential guard changed for {worker.profile}; refusing state mutation"
            )


def _read_regular_at(
    parent_fd: int,
    name: str,
    label: str,
    *,
    include_generation: bool = False,
) -> dict[str, Any]:
    """Return a stable fd-relative regular-file identity without following links."""

    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(name, flags, dir_fd=parent_fd)
    except OSError as exc:
        raise WorkerStateError(f"cannot bind {label}: {exc}") from exc
    try:
        before = os.fstat(fd)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_uid != os.getuid()
            or before.st_size > MAX_FILE_BYTES
        ):
            raise WorkerStateError(f"{label} is not an owned single-link regular file")
        payload = bytearray()
        remaining = before.st_size
        while remaining:
            block = os.read(fd, min(1024 * 1024, remaining))
            if not block:
                raise WorkerStateError(f"{label} changed while being read")
            payload.extend(block)
            remaining -= len(block)
        if os.read(fd, 1):
            raise WorkerStateError(f"{label} grew while being read")
        after = os.fstat(fd)
        leaf = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if _file_identity(after) != _file_identity(before) or _file_identity(leaf) != _file_identity(before):
            raise WorkerStateError(f"{label} changed while being read")
        value = {
            "type": "file",
            "mode": f"{stat.S_IMODE(after.st_mode):04o}",
            "sha256": _hash_bytes(bytes(payload)),
            "size": len(payload),
        }
        if include_generation:
            value["generation"] = {"dev": after.st_dev, "ino": after.st_ino}
        return value
    finally:
        os.close(fd)


def _file_identity(info: os.stat_result) -> tuple[int, ...]:
    return (
        info.st_dev,
        info.st_ino,
        info.st_uid,
        info.st_mode,
        info.st_nlink,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def _node_matches_at(
    parent_fd: int | None,
    name: str,
    expected: Mapping[str, Any],
    *,
    exact_directory: bool,
) -> bool:
    """Compare one node fd-relatively; directory comparisons never follow links."""

    expected_type = expected.get("type")
    if parent_fd is None:
        return expected_type == "absent"
    try:
        before = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return expected_type == "absent"
    if expected_type == "absent":
        return False
    if expected_type == "file":
        try:
            observed = _read_regular_at(parent_fd, name, f"managed state {name}")
        except WorkerStateError:
            return False
        return (
            observed["mode"] == expected.get("mode")
            and observed["sha256"] == expected.get("sha256")
            and (
                "size" not in expected
                or observed["size"] == expected.get("size")
            )
        )
    if expected_type == "symlink":
        if not stat.S_ISLNK(before.st_mode):
            return False
        try:
            target = os.readlink(name, dir_fd=parent_fd)
            after = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        except OSError:
            return False
        return (
            _file_identity(after) == _file_identity(before)
            and target == expected.get("target")
        )
    if expected_type != "dir" or not stat.S_ISDIR(before.st_mode):
        return False
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        child_fd = os.open(name, flags, dir_fd=parent_fd)
    except OSError:
        return False
    try:
        opened = os.fstat(child_fd)
        leaf = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if (
            _file_identity(opened) != _file_identity(before)
            or _file_identity(leaf) != _file_identity(before)
            or f"{stat.S_IMODE(opened.st_mode):04o}" != expected.get("mode")
        ):
            return False
        if not exact_directory:
            return True
        entries = expected.get("entries", {})
        if not isinstance(entries, dict):
            return False
        names = set(os.listdir(child_fd))
        if names != set(entries):
            return False
        return all(
            _node_matches_at(
                child_fd,
                child,
                entries[child],
                exact_directory=True,
            )
            for child in names
        )
    finally:
        os.close(child_fd)


def _candidate_state(manifest: Manifest, worker: Worker, relative: str) -> dict[str, Any]:
    entries = {
        entry["relative_path"]: entry
        for entry in manifest.sealed_plans[worker.profile]["plan"]["entries"]
    }
    value = entries.get(relative)
    if value is None:
        return {"type": "absent"}
    state = dict(value)
    state.pop("relative_path", None)
    if state.get("type") == "dir":
        # Every managed planned directory other than the home root is an exact
        # empty directory. Unknown descendants are not attributable provisioning.
        state["entries"] = {}
    return state


def _assert_worker_entry_attributed(
    manifest: Manifest,
    worker: Worker,
    snapshot: Mapping[str, Any],
    home_fd: int | None,
    relative: str,
    observed_name: str | None = None,
) -> None:
    original = snapshot["workers"][worker.profile]["mutable"][relative]
    candidate = _candidate_state(manifest, worker, relative)
    name = observed_name or relative
    if _node_matches_at(home_fd, name, original, exact_directory=True):
        return
    if _node_matches_at(home_fd, name, candidate, exact_directory=True):
        return
    raise WorkerStateError(
        f"managed state drift is not attributable for {worker.profile}:{relative}"
    )


def _identity_file_state(path: Path) -> dict[str, Any]:
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return {"type": "absent"}
    if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise WorkerStateError(f"identity bundle has an unsupported live type: {path}")
    payload, stable = _read_stable_file(path, "identity bundle CAS")
    return {
        "type": "file",
        "mode": f"{stat.S_IMODE(stable.st_mode):04o}",
        "sha256": _hash_bytes(payload),
        "size": len(payload),
    }


def _identity_generation(path: Path) -> dict[str, Any]:
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return {"state": {"type": "absent"}, "dev": None, "ino": None}
    if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise WorkerStateError(f"identity bundle generation is unsupported: {path}")
    payload, stable = _read_stable_file(path, "identity bundle generation")
    return {
        "state": {
            "type": "file",
            "mode": f"{stat.S_IMODE(stable.st_mode):04o}",
            "sha256": _hash_bytes(payload),
            "size": len(payload),
        },
        "dev": stable.st_dev,
        "ino": stable.st_ino,
    }


def _identity_generation_at(parent_fd: int | None, name: str) -> dict[str, Any]:
    if parent_fd is None or not _lexists_at(parent_fd, name):
        return {"state": {"type": "absent"}, "dev": None, "ino": None}
    value = _read_regular_at(
        parent_fd,
        name,
        "identity displaced generation",
        include_generation=True,
    )
    generation = value.pop("generation")
    return {"state": value, **generation}


def _identity_matches_snapshot(current: Mapping[str, Any], original: Mapping[str, Any]) -> bool:
    if current.get("type") != original.get("type"):
        return False
    if current.get("type") == "absent":
        return True
    return all(current.get(key) == original.get(key) for key in ("mode", "sha256", "size"))


def _assert_identity_authority(
    path: Path, expected: Mapping[str, Any], provider: str
) -> None:
    if _identity_generation(path) != expected:
        raise WorkerStateError(
            f"{provider} identity changed immediately before restore"
        )


def _assert_identity_authority_at(
    parent_fd: int | None,
    name: str,
    expected: Mapping[str, Any],
    provider: str,
) -> None:
    if _identity_generation_at(parent_fd, name) != expected:
        raise WorkerStateError(
            f"{provider} identity displaced live state is not attributable"
        )


def _candidate_api(manifest: Manifest) -> tuple[ModuleType, Any]:
    prepare = _load_module(
        Path(__file__).with_name("prepare_bridge_cutover.py"),
        f"_worker_state_prepare_{uuid.uuid4().hex}",
    )
    try:
        prepare.validate_bundle(
            manifest.bundle_path,
            Path(__file__).with_name("bridge_cutover_transaction.py"),
        )
        api = prepare.load_agent_fleet_api(
            manifest.candidate_pythonpath,
            manifest.candidate_release,
            manifest.candidate_version,
            "worker-state candidate",
            require_provision_api=True,
        )
        raw = prepare._normalized_registry_raw(
            prepare._parse_registry_toml(
                manifest.candidate_registry_path, "worker-state candidate registry"
            ),
            "worker-state candidate registry",
        )
        driver = _driver()
        cutover = driver.load_manifest(manifest.cutover_manifest_path)
        live_registries = [
            operation
            for operation in cutover.operations
            if isinstance(operation, driver.RegistryOperation)
        ]
        if len(live_registries) != 1:
            raise ValueError("cutover manifest must bind exactly one registry operation")
        # Managed hook commands embed the live registry path, so verification must
        # rebuild plans against it, not against the bundled registry copy's path.
        registry = prepare._lexical_candidate_registry(
            api, raw, live_registries[0].path
        )
    except Exception as exc:
        raise WorkerStateError(f"cannot load exact candidate API/registry: {exc}") from exc
    return api, registry


def _verify_workers(manifest: Manifest) -> tuple[Any, Any]:
    api, registry = _candidate_api(manifest)
    if api.provision is None:
        raise WorkerStateError("candidate provision API is absent")
    for worker in manifest.workers:
        try:
            result = api.provision.verify_provisioned_profile(registry, worker.profile)
        except Exception as exc:
            raise WorkerStateError(
                f"provision verification failed for {worker.profile}: {exc}"
            ) from exc
        if not isinstance(result, dict):
            raise WorkerStateError(f"verification result is not an object: {worker.profile}")
        _exact_keys(
            result,
            {
                "schema",
                "profile",
                "provider",
                "status",
                "plan_sha256",
                "actual_entries",
                "mismatches",
            },
            set(),
            f"verification result {worker.profile}",
        )
        expected = manifest.sealed_plans[worker.profile]
        if (
            result["schema"] != 1
            or result["profile"] != worker.profile
            or result["provider"] != worker.provider
            or result["status"] != "verified"
            or result["plan_sha256"] != worker.plan_sha256
            or result["actual_entries"] != expected["plan"]["entries"]
            or result["mismatches"] != []
        ):
            raise WorkerStateError(
                f"provisioned state is not exact for {worker.profile}"
            )
    return api, registry


def verify_provisioned(manifest: Manifest) -> dict[str, Any]:
    lock_fd = _lock(manifest)
    try:
        journal = _journal(manifest)
        if journal is None or journal["phase"] not in {
            "snapshotted",
            "provision_verified",
        }:
            raise WorkerStateError("worker snapshot is not awaiting provision verification")
        _quiet(manifest)
        for worker in manifest.workers:
            _safe_parent_chain(worker.home, f"worker home {worker.profile}")
        for provider, path in manifest.identity_bundles.items():
            _safe_parent_chain(path, f"identity bundle {provider}")
        snapshot = _load_snapshot(manifest, journal)
        home_fds = _open_worker_homes(manifest, snapshot)
        try:
            _guards_unchanged(manifest, snapshot, home_fds)
            _verify_workers(manifest)
            for worker in manifest.workers:
                fd = home_fds[worker.profile]
                if fd is not None:
                    _assert_bound_directory(
                        fd, worker.home, f"worker home {worker.profile}"
                    )
        finally:
            _close_bound_directories(home_fds)
        if journal["phase"] != "provision_verified":
            journal["phase"] = "provision_verified"
            _event(journal, "six-worker-provision-verified")
            _write_journal(manifest, journal)
        return plan(manifest)
    finally:
        os.close(lock_fd)


def finalize(manifest: Manifest) -> dict[str, Any]:
    lock_fd = _lock(manifest)
    try:
        journal = _journal(manifest)
        if journal is None or journal["phase"] not in {
            "provision_verified",
            "complete",
        }:
            raise WorkerStateError("six-worker provision verification is incomplete")
        if journal["phase"] == "complete":
            return plan(manifest)
        _quiet(manifest)
        snapshot = _load_snapshot(manifest, journal)
        home_fds = _open_worker_homes(manifest, snapshot)
        try:
            _guards_unchanged(manifest, snapshot, home_fds)
            api, registry = _verify_workers(manifest)
            for worker in manifest.workers:
                fd = home_fds[worker.profile]
                if fd is not None:
                    _assert_bound_directory(
                        fd, worker.home, f"worker home {worker.profile}"
                    )
        finally:
            _close_bound_directories(home_fds)
        if api.identity is None:
            raise WorkerStateError("candidate identity API is absent")
        for provider in ("claude", "codex"):
            observed_path = api.identity.identity_bundle_path(registry, provider)
            if Path(observed_path) != manifest.identity_bundles[provider]:
                raise WorkerStateError(f"{provider} identity bundle path drifted")
            result = api.identity.verify_identity_bundle(
                registry, provider, compare_live_external=False
            )
            if result != {
                "provider": provider,
                "status": "verified",
                "reason": None,
            }:
                raise WorkerStateError(f"{provider} identity bundle is not verified")
        journal["phase"] = "complete"
        journal["terminal_outcome"] = "complete"
        _event(journal, "worker-state-transaction-finalized")
        _write_journal(manifest, journal)
        return plan(manifest)
    finally:
        os.close(lock_fd)


def _remove_path(path: Path) -> None:
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return
    if stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode):
        with os.scandir(path) as iterator:
            names = [entry.name for entry in iterator]
        for name in names:
            _remove_path(path / name)
        os.rmdir(path)
    else:
        os.unlink(path)


def _remove_entry_at(parent_fd: int, name: str) -> None:
    """Remove one direct child recursively without following any symlink."""

    try:
        info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    if stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode):
        flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
        child_fd = os.open(name, flags, dir_fd=parent_fd)
        try:
            opened = os.fstat(child_fd)
            if opened.st_dev != info.st_dev or opened.st_ino != info.st_ino:
                raise WorkerStateError("managed restore directory identity changed")
            for child in os.listdir(child_fd):
                _relative(child, "managed restore directory entry")
                _remove_entry_at(child_fd, child)
            os.fsync(child_fd)
        finally:
            os.close(child_fd)
        os.rmdir(name, dir_fd=parent_fd)
    else:
        os.unlink(name, dir_fd=parent_fd)


def _snapshot_file_payload(
    state: Mapping[str, Any], data_root: Path
) -> bytes:
    source = data_root / _relative(state.get("data"), "snapshot data path")
    payload, _ = _read_stable_file(source, "snapshot data")
    if len(payload) != state.get("size") or _hash_bytes(payload) != state.get("sha256"):
        raise WorkerStateError("snapshot data digest/size mismatch")
    return payload


def _materialize_node_at(
    state: Mapping[str, Any],
    parent_fd: int,
    name: str,
    data_root: Path,
) -> None:
    node_type = state.get("type")
    if node_type == "file":
        payload = _snapshot_file_payload(state, data_root)
        mode = int(state["mode"], 8)
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(name, flags, mode, dir_fd=parent_fd)
        try:
            os.fchmod(fd, mode)
            offset = 0
            while offset < len(payload):
                offset += os.write(fd, payload[offset:])
            os.fsync(fd)
        finally:
            os.close(fd)
        return
    if node_type == "symlink":
        os.symlink(state["target"], name, dir_fd=parent_fd)
        return
    if node_type == "dir":
        mode = int(state["mode"], 8)
        os.mkdir(name, mode, dir_fd=parent_fd)
        flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
        child_fd = os.open(name, flags, dir_fd=parent_fd)
        try:
            os.fchmod(child_fd, mode)
            entries = state.get("entries")
            if not isinstance(entries, dict):
                raise WorkerStateError("snapshot directory entries are invalid")
            for child in sorted(entries, key=lambda value: value.encode("utf-8")):
                _relative(child, "snapshot directory entry")
                _materialize_node_at(entries[child], child_fd, child, data_root)
            os.fsync(child_fd)
        finally:
            os.close(child_fd)
        return
    raise WorkerStateError("cannot materialize absent/unknown snapshot node")


def _rename_at(
    parent_fd: int,
    source: str,
    destination: str,
    *,
    exchange: bool,
) -> None:
    """Use a syscall-level exchange or no-replace rename within one bound dir."""

    libc = ctypes.CDLL(None, use_errno=True)
    source_bytes = os.fsencode(source)
    destination_bytes = os.fsencode(destination)
    if sys.platform == "darwin" and hasattr(libc, "renameatx_np"):
        function = libc.renameatx_np
        function.argtypes = [
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        ]
        function.restype = ctypes.c_int
        flag = 0x00000002 if exchange else 0x00000004
        result = function(
            parent_fd, source_bytes, parent_fd, destination_bytes, flag
        )
    elif sys.platform.startswith("linux") and hasattr(libc, "renameat2"):
        function = libc.renameat2
        function.argtypes = [
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        ]
        function.restype = ctypes.c_int
        flag = 0x2 if exchange else 0x1
        result = function(
            parent_fd, source_bytes, parent_fd, destination_bytes, flag
        )
    else:
        raise WorkerStateError(
            "atomic exchange/no-replace rename is unavailable on this platform"
        )
    if result != 0:
        error = ctypes.get_errno()
        raise WorkerStateError(
            f"atomic {'exchange' if exchange else 'no-replace rename'} failed for "
            f"{source} and {destination}: {os.strerror(error)}"
        )


def _lexists_at(parent_fd: int, name: str) -> bool:
    try:
        os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        return True
    except FileNotFoundError:
        return False


def _restore_node_at(
    state: Mapping[str, Any],
    parent_fd: int | None,
    name: str,
    data_root: Path,
    temporary_tag: str,
    pre_replace: Callable[[], None] | None = None,
    validate_displaced: Callable[[str], None] | None = None,
    boundaries: BoundaryController | None = None,
    exchange_label: str = "restore",
    exchange_phase: Callable[[str], None] | None = None,
) -> None:
    controller = boundaries or BoundaryController()
    node_type = state.get("type")
    if parent_fd is None:
        if node_type == "absent":
            if pre_replace is not None:
                pre_replace()
            return
        raise WorkerStateError("restore parent is absent for non-absent state")
    if node_type == "absent":
        temporary = f".{name}.restore-{temporary_tag}"
        if _lexists_at(parent_fd, temporary):
            if not _node_matches_at(parent_fd, name, state, exact_directory=True):
                raise WorkerStateError(
                    f"ambiguous interrupted absent restore is preserved: {temporary}"
                )
            if validate_displaced is not None:
                validate_displaced(temporary)
            _remove_entry_at(parent_fd, temporary)
            os.fsync(parent_fd)
            return
        if _node_matches_at(parent_fd, name, state, exact_directory=True):
            return
        if pre_replace is not None:
            pre_replace()
        controller.hit(f"immediately_before_exchange:{exchange_label}")
        _rename_at(parent_fd, name, temporary, exchange=False)
        if exchange_phase is not None:
            exchange_phase("exchanged")
        controller.hit(f"after_exchange:{exchange_label}")
        try:
            if validate_displaced is not None:
                validate_displaced(temporary)
        except Exception:
            try:
                _rename_at(parent_fd, temporary, name, exchange=False)
                os.fsync(parent_fd)
                if exchange_phase is not None:
                    exchange_phase("prepared")
            except WorkerStateError as restore_exc:
                raise WorkerStateError(
                    f"ambiguous displaced absent restore is preserved: {temporary}"
                ) from restore_exc
            raise
        _remove_entry_at(parent_fd, temporary)
        os.fsync(parent_fd)
        return
    temporary = f".{name}.restore-{temporary_tag}"
    try:
        if _lexists_at(parent_fd, temporary):
            if _node_matches_at(parent_fd, name, state, exact_directory=True):
                if validate_displaced is not None:
                    validate_displaced(temporary)
                _remove_entry_at(parent_fd, temporary)
                os.fsync(parent_fd)
                return
            if not _node_matches_at(
                parent_fd, temporary, state, exact_directory=True
            ):
                raise WorkerStateError(
                    f"ambiguous interrupted restore is preserved: {temporary}"
                )
        else:
            _materialize_node_at(state, parent_fd, temporary, data_root)
        if pre_replace is not None:
            pre_replace()
        controller.hit(f"immediately_before_exchange:{exchange_label}")
        _rename_at(parent_fd, temporary, name, exchange=True)
        if exchange_phase is not None:
            exchange_phase("exchanged")
        controller.hit(f"after_exchange:{exchange_label}")
        try:
            if validate_displaced is not None:
                validate_displaced(temporary)
        except Exception:
            try:
                _rename_at(parent_fd, temporary, name, exchange=True)
                _remove_entry_at(parent_fd, temporary)
                os.fsync(parent_fd)
                if exchange_phase is not None:
                    exchange_phase("prepared")
            except WorkerStateError as restore_exc:
                raise WorkerStateError(
                    f"ambiguous displaced restore is preserved: {temporary}"
                ) from restore_exc
            raise
        _remove_entry_at(parent_fd, temporary)
        os.fsync(parent_fd)
    except Exception:
        if (
            _lexists_at(parent_fd, temporary)
            and _node_matches_at(parent_fd, temporary, state, exact_directory=True)
            and not _node_matches_at(parent_fd, name, state, exact_directory=True)
        ):
            _remove_entry_at(parent_fd, temporary)
            os.fsync(parent_fd)
        raise


def _open_identity_parent(path: Path, state: Mapping[str, Any]) -> int | None:
    parent = path.parent
    if not os.path.lexists(parent):
        if state.get("type") == "absent":
            return None
        _safe_parent_chain(parent, f"identity bundle parent {path.name}")
        parent.mkdir(mode=0o700)
    return _open_bound_directory(parent, f"identity bundle parent {path.name}")


def _remove_bound_home_if_empty(path: Path, fd: int, label: str) -> None:
    _assert_bound_directory(fd, path, label)
    parent_fd = _open_bound_directory(path.parent, f"{label} parent")
    assert parent_fd is not None
    try:
        leaf = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
        opened = os.fstat(fd)
        if leaf.st_dev != opened.st_dev or leaf.st_ino != opened.st_ino:
            raise WorkerStateError(f"{label} leaf identity changed before removal")
        try:
            os.rmdir(path.name, dir_fd=parent_fd)
            os.fsync(parent_fd)
        except OSError as exc:
            # Credentials and any other unplanned state are deliberately kept.
            if exc.errno not in {errno.ENOTEMPTY, errno.EEXIST}:
                raise
    finally:
        os.close(parent_fd)


def rollback(
    manifest: Manifest,
    boundaries: BoundaryController | None = None,
) -> dict[str, Any]:
    boundaries = boundaries or BoundaryController()
    lock_fd = _lock(manifest)
    try:
        journal = _journal(manifest)
        if journal is None:
            raise WorkerStateError("worker-state snapshot does not exist")
        if journal["phase"] == "complete" or (
            journal["phase"] == "cleaned"
            and journal["terminal_outcome"] == "complete"
        ):
            raise WorkerStateError("worker-state transaction is finalized and irreversible")
        if journal["phase"] == "rolled_back" or (
            journal["phase"] == "cleaned"
            and journal["terminal_outcome"] == "rolled_back"
        ):
            return plan(manifest)
        if journal["phase"] == "cleaning":
            raise WorkerStateError("private snapshot cleanup must be resumed before rollback")
        _quiet(manifest)
        for provider, path in manifest.identity_bundles.items():
            _safe_parent_chain(path, f"identity bundle {provider}")
        snapshot = _load_snapshot(manifest, journal)
        home_fds = _open_worker_homes(manifest, snapshot)
        try:
            drifted = set(journal["credential_drift"])
            for worker in manifest.workers:
                guard = snapshot["workers"][worker.profile]["credential_guard"]
                try:
                    observed_guard = _credential_guard_at(
                        home_fds[worker.profile], guard["relative_path"]
                    )
                except WorkerStateError:
                    observed_guard = None
                if observed_guard != guard["identity"]:
                    drifted.add(worker.profile)
            # Refuse all unattributed managed-state drift before changing any
            # worker path. A partially completed prior rollback is accepted
            # because restored nodes exactly match the sealed snapshot.
            for worker in manifest.workers:
                for relative in MUTABLE_PATHS[worker.provider]:
                    _assert_worker_entry_attributed(
                        manifest,
                        worker,
                        snapshot,
                        home_fds[worker.profile],
                        relative,
                    )

            identity_authority: dict[str, dict[str, Any]] = {}
            identity_api: tuple[Any, Any] | None = None
            inflight_identity = journal["identity_restore"]
            for provider in ("claude", "codex"):
                if (
                    inflight_identity is not None
                    and inflight_identity["provider"] == provider
                ):
                    identity_authority[provider] = dict(
                        inflight_identity["authority"]
                    )
                    continue
                path = manifest.identity_bundles[provider]
                current_generation = _identity_generation(path)
                current = current_generation["state"]
                original = snapshot["identity_bundles"][provider]["state"]
                if not _identity_matches_snapshot(current, original):
                    candidate_generation = current_generation
                    if identity_api is None:
                        identity_api = _candidate_api(manifest)
                    api, registry = identity_api
                    if api.identity is None:
                        raise WorkerStateError("candidate identity API is absent")
                    result = api.identity.verify_identity_bundle(
                        registry, provider, compare_live_external=False
                    )
                    if result != {
                        "provider": provider,
                        "status": "verified",
                        "reason": None,
                    }:
                        raise WorkerStateError(
                            f"live {provider} identity drift is not attributable"
                        )
                    current_generation = _identity_generation(path)
                    if current_generation != candidate_generation:
                        raise WorkerStateError(
                            f"live {provider} identity changed during attribution"
                        )
                identity_authority[provider] = current_generation
            journal["credential_drift"] = sorted(drifted)
            if drifted:
                _event(journal, "credential-drift-preserved")
            journal["phase"] = "rolling_back"
            _event(journal, "rollback-started")
            _write_journal(manifest, journal)
            completed = set(journal["restore_completed"])
            data_root = manifest.snapshot_path / "data"
            for worker in manifest.workers:
                worker_snapshot = snapshot["workers"][worker.profile]
                home_fd = home_fds[worker.profile]
                for relative in MUTABLE_PATHS[worker.provider]:
                    key = f"worker:{worker.profile}:{relative}"
                    if key in completed:
                        continue
                    if home_fd is not None:
                        _assert_bound_directory(
                            home_fd, worker.home, f"worker home {worker.profile}"
                        )
                    temporary_tag = hashlib.sha256(
                        f"{manifest.transaction_id}:{key}".encode()
                    ).hexdigest()[:16]
                    _restore_node_at(
                        worker_snapshot["mutable"][relative],
                        home_fd,
                        relative,
                        data_root,
                        temporary_tag,
                        pre_replace=lambda worker=worker, relative=relative, home_fd=home_fd: (
                            _assert_worker_entry_attributed(
                                manifest,
                                worker,
                                snapshot,
                                home_fd,
                                relative,
                            )
                        ),
                        validate_displaced=lambda observed_name, worker=worker, relative=relative, home_fd=home_fd: (
                            _assert_worker_entry_attributed(
                                manifest,
                                worker,
                                snapshot,
                                home_fd,
                                relative,
                                observed_name,
                            )
                        ),
                        boundaries=boundaries,
                        exchange_label=f"worker:{worker.profile}:{relative}",
                    )
                    if home_fd is not None:
                        _assert_bound_directory(
                            home_fd, worker.home, f"worker home {worker.profile}"
                        )
                    boundaries.hit(f"restore:{key}")
                    journal["restore_completed"].append(key)
                    completed.add(key)
                    _event(journal, f"restored:{key}")
                    _write_journal(manifest, journal)

            drifted_providers = {WORKERS[profile] for profile in drifted}
            provider_order = ["claude", "codex"]
            if inflight_identity is not None:
                provider_order.remove(inflight_identity["provider"])
                provider_order.insert(0, inflight_identity["provider"])
            for provider in provider_order:
                key = f"identity:{provider}"
                invalidate = provider in drifted_providers
                if key in completed and not invalidate:
                    continue
                value = snapshot["identity_bundles"][provider]
                desired_state = {"type": "absent"} if invalidate else value["state"]
                identity_path = manifest.identity_bundles[provider]
                while True:
                    active = journal["identity_restore"]
                    if active is not None and active["provider"] != provider:
                        raise WorkerStateError(
                            "another identity restore generation must be resumed first"
                        )
                    if active is None:
                        authority = identity_authority.get(provider)
                        if authority is None:
                            authority = _identity_generation(identity_path)
                        active = {
                            "provider": provider,
                            "key": key,
                            "phase": "prepared",
                            "authority": authority,
                            "restore_state": desired_state,
                        }
                        journal["identity_restore"] = active
                        _event(journal, f"identity-restore-prepared:{provider}")
                        _write_journal(manifest, journal)
                    restore_state = active["restore_state"]
                    authority = active["authority"]
                    parent_fd = _open_identity_parent(identity_path, restore_state)
                    restore_already_complete = False
                    try:
                        temporary_tag = hashlib.sha256(
                            f"{manifest.transaction_id}:{key}".encode()
                        ).hexdigest()[:16]
                        temporary = (
                            f".{identity_path.name}.restore-{temporary_tag}"
                        )
                        if (
                            active["phase"] == "exchanged"
                            and restore_state.get("type") == "file"
                            and parent_fd is not None
                            and not _lexists_at(parent_fd, temporary)
                        ):
                            _snapshot_file_payload(restore_state, data_root)
                            _assert_bound_directory(
                                parent_fd,
                                identity_path.parent,
                                f"identity bundle parent {provider}",
                            )
                            if not _node_matches_at(
                                parent_fd,
                                identity_path.name,
                                restore_state,
                                exact_directory=True,
                            ) or _lexists_at(parent_fd, temporary):
                                raise WorkerStateError(
                                    "interrupted file identity restore live state is not exact; "
                                    "foreign state is preserved"
                                )
                            _assert_bound_directory(
                                parent_fd,
                                identity_path.parent,
                                f"identity bundle parent {provider}",
                            )
                            journal["identity_restore"] = None
                            if restore_state == desired_state and key not in completed:
                                journal["restore_completed"].append(key)
                                completed.add(key)
                            _event(
                                journal,
                                f"identity-restore-cleanup-observed:{provider}",
                            )
                            _write_journal(manifest, journal)
                            restore_already_complete = True
                        else:
                            def record_exchange_phase(
                                phase: str,
                                *,
                                provider: str = provider,
                            ) -> None:
                                current_restore = journal["identity_restore"]
                                if (
                                    current_restore is None
                                    or current_restore["provider"] != provider
                                ):
                                    raise WorkerStateError(
                                        "identity restore generation disappeared during exchange"
                                    )
                                current_restore["phase"] = phase
                                _event(
                                    journal,
                                    f"identity-restore-{phase}:{provider}",
                                )
                                _write_journal(manifest, journal)

                            _restore_node_at(
                                restore_state,
                                parent_fd,
                                identity_path.name,
                                data_root,
                                temporary_tag,
                                pre_replace=lambda provider=provider, identity_path=identity_path, authority=authority: (
                                    _assert_identity_authority(
                                        identity_path,
                                        authority,
                                        provider,
                                    )
                                ),
                                validate_displaced=lambda observed_name, provider=provider, parent_fd=parent_fd, authority=authority: (
                                    _assert_identity_authority_at(
                                        parent_fd,
                                        observed_name,
                                        authority,
                                        provider,
                                    )
                                ),
                                boundaries=boundaries,
                                exchange_label=f"identity:{provider}",
                                exchange_phase=record_exchange_phase,
                            )
                        if parent_fd is not None:
                            _assert_bound_directory(
                                parent_fd,
                                identity_path.parent,
                                f"identity bundle parent {provider}",
                            )
                    finally:
                        if parent_fd is not None:
                            os.close(parent_fd)
                    if restore_already_complete:
                        if restore_state != desired_state:
                            identity_authority[provider] = _identity_generation(
                                identity_path
                            )
                            continue
                        break
                    boundaries.hit(f"restore:{key}")
                    journal["identity_restore"] = None
                    if restore_state != desired_state:
                        identity_authority[provider] = _identity_generation(
                            identity_path
                        )
                        _event(journal, f"identity-restore-generation-finished:{provider}")
                        _write_journal(manifest, journal)
                        continue
                    break
                if key not in completed:
                    journal["restore_completed"].append(key)
                    completed.add(key)
                _event(
                    journal,
                    f"identity-invalidated:{provider}"
                    if invalidate
                    else f"restored:{key}",
                )
                _write_journal(manifest, journal)

            for worker in manifest.workers:
                home_state = snapshot["workers"][worker.profile]["home_state"]
                home_fd = home_fds[worker.profile]
                if home_fd is None:
                    continue
                if home_state["type"] == "absent":
                    _remove_bound_home_if_empty(
                        worker.home, home_fd, f"worker home {worker.profile}"
                    )
                else:
                    _assert_bound_directory(
                        home_fd, worker.home, f"worker home {worker.profile}"
                    )
                    os.fchmod(home_fd, int(home_state["mode"], 8))
                    os.fsync(home_fd)
        finally:
            _close_bound_directories(home_fds)
        journal["phase"] = "rolled_back"
        journal["terminal_outcome"] = "rolled_back"
        _event(journal, "rollback-complete")
        _write_journal(manifest, journal)
        return plan(manifest)
    finally:
        os.close(lock_fd)


def cleanup(
    manifest: Manifest,
    boundaries: BoundaryController | None = None,
) -> dict[str, Any]:
    """Manually remove private snapshot bytes after a terminal state."""

    boundaries = boundaries or BoundaryController()
    lock_fd = _lock(manifest)
    try:
        journal = _journal(manifest)
        if journal is None or journal["phase"] not in {
            "complete",
            "rolled_back",
            "cleaning",
            "cleaned",
        }:
            raise WorkerStateError(
                "snapshot cleanup is allowed only after complete or rolled-back state"
            )
        if journal["phase"] == "cleaned":
            return plan(manifest)
        if journal["phase"] != "cleaning":
            _load_snapshot(manifest, journal)
            journal["phase"] = "cleaning"
            _event(journal, "private-snapshot-cleanup-started")
            _write_journal(manifest, journal)
        boundaries.hit("cleanup-journal-published")
        if os.path.lexists(manifest.snapshot_path):
            _private_directory(
                manifest.snapshot_path, "worker-state snapshot being cleaned"
            )
            _remove_path(manifest.snapshot_path)
        _fsync_directory(manifest.snapshot_parent)
        boundaries.hit("cleanup-snapshot-removed")
        journal["phase"] = "cleaned"
        _event(journal, "private-snapshot-cleaned")
        _write_journal(manifest, journal)
        boundaries.hit("cleanup-journal-finalized")
        return plan(manifest)
    finally:
        os.close(lock_fd)


def plan(manifest: Manifest) -> dict[str, Any]:
    journal = _journal(manifest)
    phase = "not-started" if journal is None else journal["phase"]
    terminal_outcome = None if journal is None else journal["terminal_outcome"]
    return {
        "valid": True,
        "transaction_id": manifest.transaction_id,
        "phase": phase,
        "workers": [worker.profile for worker in manifest.workers],
        "reserves_touched": False,
        "credential_bytes_snapshotted": False,
        "identity_bundle_count": 2,
        "provision_verified": phase in {"provision_verified", "complete"}
        or (phase == "cleaned" and terminal_outcome == "complete"),
        "worker_state_ready": phase == "complete"
        or (phase == "cleaned" and terminal_outcome == "complete"),
        "rollback_available": phase in {
            "snapshotted",
            "provision_verified",
            "rolling_back",
        },
        "cleanup_policy": "explicit-manual-only-after-terminal-state",
        "cleanup_allowed": phase in {"complete", "rolled_back", "cleaning"},
        "snapshot_bytes_present": os.path.lexists(manifest.snapshot_path),
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest")
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--begin", action="store_true")
    action.add_argument("--verify-provisioned", action="store_true")
    action.add_argument("--finalize", action="store_true")
    action.add_argument("--rollback", action="store_true")
    action.add_argument("--cleanup", action="store_true")
    args = parser.parse_args(argv)
    try:
        manifest = load_manifest(args.manifest)
        if args.begin:
            result = begin(manifest)
        elif args.verify_provisioned:
            result = verify_provisioned(manifest)
        elif args.finalize:
            result = finalize(manifest)
        elif args.rollback:
            result = rollback(manifest)
        elif args.cleanup:
            result = cleanup(manifest)
        else:
            result = plan(manifest)
    except (WorkerStateError, InjectedFailure) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
