#!/usr/bin/env python3
"""Adopt sealed rollback runtimes without trusting the live legacy trees.

This is a deliberately separate transaction from the normal Bridge cutover.
It accepts only the exact raw legacy ``current`` link payloads and exact
all-disabled registry bytes as its initial state.  It validates only the new
sealed release trees, then atomically adopts Quota, Agent Fleet, and the
sealed-registry Quota path.  An interrupted, non-finalized adoption recovers
backward; a fully sealed adoption is irreversible and becomes the sole old
state accepted by the normal cutover transaction.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import pwd
import stat
import subprocess
import sys
import tomllib
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

import bridge_cutover_transaction as transaction


SCHEMA_VERSION = 1
JOURNAL_SCHEMA_VERSION = 1
MAX_MANIFEST_BYTES = 1_000_000
MAX_JOURNAL_BYTES = 1_000_000
EXPECTED_OPERATION_NAMES = ("quota-current", "agent-fleet-current")


class AdoptionError(RuntimeError):
    """A sealed-adoption validation, quiet-point, or recovery refusal."""


BoundaryController = transaction.BoundaryController
InjectedFailure = transaction.InjectedFailure


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
class SealedLinkOperation:
    name: str
    path: Path
    initial_target: str
    sealed_target: str
    sealed_release: Path
    sealed_proofs: tuple[dict[str, str], ...]
    sealed_tree_sha256: str


@dataclass(frozen=True)
class RegistryOperation:
    name: str
    path: Path
    initial_source: Path
    sealed_source: Path
    initial_sha256: str
    sealed_sha256: str
    mode: int


@dataclass(frozen=True)
class FrontDoorOperation:
    name: str
    path: Path
    initial_target: str
    sealed_source: Path
    sealed_sha256: str
    mode: int


Operation = SealedLinkOperation | FrontDoorOperation | RegistryOperation


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
    link_operations: tuple[SealedLinkOperation, ...]
    front_door_operation: FrontDoorOperation
    registry_operation: RegistryOperation

    @property
    def operations(self) -> tuple[Operation, ...]:
        return (
            *self.link_operations,
            self.front_door_operation,
            self.registry_operation,
        )


def _require_exact_keys(
    value: Mapping[str, Any], required: set[str], optional: set[str], label: str
) -> None:
    missing = required - set(value)
    unknown = set(value) - required - optional
    if missing:
        raise AdoptionError(f"{label} is missing keys: {', '.join(sorted(missing))}")
    if unknown:
        raise AdoptionError(f"{label} has unknown keys: {', '.join(sorted(unknown))}")


def _absolute(value: Any, label: str) -> Path:
    try:
        return transaction._explicit_absolute_path(value, label)
    except transaction.CutoverError as exc:
        raise AdoptionError(str(exc)) from exc


def _relative(value: Any, label: str) -> str:
    try:
        return str(transaction._normalized_relative_path(value, label))
    except transaction.CutoverError as exc:
        raise AdoptionError(str(exc)) from exc


def _symlink_target(value: Any, parent: Path, label: str) -> str:
    if not isinstance(value, str) or not value or "\x00" in value or "$" in value:
        raise AdoptionError(f"{label} must be a non-empty literal symlink payload")
    if os.path.isabs(value):
        try:
            transaction._explicit_absolute_path(value, label)
        except transaction.CutoverError as exc:
            raise AdoptionError(str(exc)) from exc
        return value
    if os.path.normpath(value) != value or any(
        part in {"", "."} for part in Path(value).parts
    ):
        raise AdoptionError(f"{label} must be a normalized relative symlink payload")
    return value


def _digest(value: Any, label: str) -> str:
    try:
        return transaction._parse_hash(value, label)
    except transaction.CutoverError as exc:
        raise AdoptionError(str(exc)) from exc


def _owning_root(path: Path, roots: Sequence[Path], label: str) -> Path:
    try:
        return transaction._owning_root(path, roots, label)
    except transaction.CutoverError as exc:
        raise AdoptionError(str(exc)) from exc


def _require_real_parent(path: Path, roots: Sequence[Path], label: str) -> None:
    root = _owning_root(path, roots, label)
    try:
        transaction._require_real_parent_chain(path, root, label)
    except transaction.CutoverError as exc:
        raise AdoptionError(str(exc)) from exc


def _require_regular(
    path: Path, label: str, expected_mode: int | None = None
) -> None:
    try:
        transaction._require_regular(path, label, expected_mode)
    except transaction.CutoverError as exc:
        raise AdoptionError(str(exc)) from exc


def _sha256(path: Path, label: str, expected_mode: int | None = None) -> str:
    try:
        return transaction._sha256_file(
            path,
            label=label,
            expected_mode=expected_mode,
        )
    except transaction.CutoverError as exc:
        raise AdoptionError(str(exc)) from exc


def _read_stable_bytes(
    path: Path,
    label: str,
    expected_mode: int | None = None,
    max_bytes: int = MAX_MANIFEST_BYTES,
    *,
    allow_root: bool = False,
) -> bytes:
    try:
        fd, info = transaction._open_regular_readonly(
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
                    raise AdoptionError(f"{label} exceeds {max_bytes} bytes")
                chunks.append(block)
            transaction._require_stable_regular_fd(fd, info, path, label)
            current = os.lstat(path)
            if (
                current.st_dev != info.st_dev
                or current.st_ino != info.st_ino
                or current.st_mode != info.st_mode
                or current.st_nlink != info.st_nlink
            ):
                raise AdoptionError(f"{label} path changed while reading: {path}")
            return b"".join(chunks)
        finally:
            os.close(fd)
    except transaction.CutoverError as exc:
        raise AdoptionError(str(exc)) from exc


def _validate_sealed_operation(operation: SealedLinkOperation) -> None:
    try:
        observed_tree = transaction.compute_release_tree_sha256(
            operation.sealed_release,
            f"{operation.name} sealed release",
        )
        if observed_tree != operation.sealed_tree_sha256:
            raise AdoptionError(
                f"{operation.name} sealed tree SHA-256 is {observed_tree}; "
                f"expected {operation.sealed_tree_sha256}"
            )
        for index, expected in enumerate(operation.sealed_proofs):
            observed = transaction.compute_release_proof(
                operation.sealed_release,
                expected["relative_path"],
                f"{operation.name} sealed proof[{index}]",
            )
            if observed != expected:
                raise AdoptionError(
                    f"{operation.name} sealed proof[{index}] does not match"
                )
    except transaction.CutoverError as exc:
        raise AdoptionError(str(exc)) from exc


def _parse_quiet_point(
    raw: Any,
    roots: Sequence[Path],
) -> QuietPoint:
    if not isinstance(raw, dict):
        raise AdoptionError("quiet_point must be an object")
    _require_exact_keys(
        raw,
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
    profiles = raw["profile_ids"]
    if (
        not isinstance(profiles, list)
        or not profiles
        or not all(isinstance(item, str) and item for item in profiles)
        or profiles != sorted(set(profiles))
    ):
        raise AdoptionError("quiet_point.profile_ids must be a sorted unique string array")
    workers = raw["worker_profile_ids"]
    reserves = raw["never_enroll_profile_ids"]
    for values, name in (
        (workers, "worker_profile_ids"),
        (reserves, "never_enroll_profile_ids"),
    ):
        if (
            not isinstance(values, list)
            or values != sorted(set(values))
            or not all(isinstance(item, str) and item for item in values)
        ):
            raise AdoptionError(f"quiet_point.{name} must be sorted and unique")
    if (
        not workers
        or not reserves
        or set(workers) & set(reserves)
        or sorted([*workers, *reserves]) != profiles
    ):
        raise AdoptionError(
            "quiet-point workers and never-enroll profiles must exactly partition profile_ids"
        )
    routing_values = raw["routing_absent_paths"]
    state_values = raw["state_quiet_paths"]
    if not isinstance(routing_values, list) or not routing_values:
        raise AdoptionError("quiet_point.routing_absent_paths must be non-empty")
    if not isinstance(state_values, list) or not state_values:
        raise AdoptionError("quiet_point.state_quiet_paths must be non-empty")
    routing_paths = tuple(
        _absolute(value, f"quiet_point.routing_absent_paths[{index}]")
        for index, value in enumerate(routing_values)
    )
    state_paths = tuple(
        _absolute(value, f"quiet_point.state_quiet_paths[{index}]")
        for index, value in enumerate(state_values)
    )
    if len(set(routing_paths)) != len(routing_paths):
        raise AdoptionError("quiet_point.routing_absent_paths contains duplicates")
    if len(set(state_paths)) != len(state_paths):
        raise AdoptionError("quiet_point.state_quiet_paths contains duplicates")
    backend = _absolute(raw["backend_path"], "quiet_point.backend_path")
    ps_binary = _absolute(raw["ps_binary"], "quiet_point.ps_binary")
    for index, path in enumerate((*routing_paths, backend, *state_paths)):
        _require_real_parent(path, roots, f"quiet point path[{index}]")
    _require_regular(backend, "quiet-point backend file")
    try:
        transaction._require_regular(
            ps_binary, "quiet-point ps binary", allow_root=True
        )
    except transaction.CutoverError as exc:
        raise AdoptionError(str(exc)) from exc
    if not stat.S_IMODE(os.lstat(ps_binary).st_mode) & 0o100:
        raise AdoptionError("quiet-point ps binary must be owner-executable")
    tokens = raw["forbidden_process_tokens"]
    if (
        not isinstance(tokens, list)
        or not tokens
        or not all(
            isinstance(token, str)
            and token.startswith("/")
            and "\x00" not in token
            and "$" not in token
            and len(token) > 1
            for token in tokens
        )
        or len(tokens) != len(set(tokens))
    ):
        raise AdoptionError(
            "quiet_point.forbidden_process_tokens must be unique absolute tokens"
        )
    return QuietPoint(
        profile_ids=tuple(profiles),
        worker_profile_ids=tuple(workers),
        never_enroll_profile_ids=tuple(reserves),
        routing_absent_paths=routing_paths,
        backend_path=backend,
        backend_sha256=_digest(
            raw["backend_sha256"], "quiet_point.backend_sha256"
        ),
        state_quiet_paths=state_paths,
        forbidden_process_tokens=tuple(tokens),
        ps_binary=ps_binary,
        ps_binary_sha256=_digest(
            raw["ps_binary_sha256"], "quiet_point.ps_binary_sha256"
        ),
    )


def load_manifest(path_value: str | os.PathLike[str]) -> Manifest:
    manifest_path = _absolute(os.fspath(path_value), "manifest path")
    if Path(os.path.realpath(manifest_path)) != manifest_path:
        raise AdoptionError(
            f"manifest path is symlinked or non-canonical: {manifest_path}"
        )
    try:
        raw = transaction._read_json_file(
            manifest_path, MAX_MANIFEST_BYTES, "adoption manifest"
        )
    except transaction.CutoverError as exc:
        raise AdoptionError(str(exc)) from exc
    if not isinstance(raw, dict):
        raise AdoptionError("adoption manifest root must be an object")
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
            "link_operations",
            "front_door_operation",
            "registry_operation",
        },
        set(),
        "adoption manifest",
    )
    if raw["schema_version"] != SCHEMA_VERSION:
        raise AdoptionError("unsupported adoption manifest schema")
    transaction_id = raw["transaction_id"]
    if (
        not isinstance(transaction_id, str)
        or not transaction.SAFE_NAME.fullmatch(transaction_id)
    ):
        raise AdoptionError("transaction_id must be a safe 1-64 character identifier")
    if not isinstance(raw["apply_opt_in"], bool):
        raise AdoptionError("apply_opt_in must be a boolean")
    root_values = raw["allowed_roots"]
    if not isinstance(root_values, list) or not root_values:
        raise AdoptionError("allowed_roots must be a non-empty array")
    roots = tuple(
        _absolute(value, f"allowed_roots[{index}]")
        for index, value in enumerate(root_values)
    )
    if len(set(roots)) != len(roots):
        raise AdoptionError("allowed_roots contains duplicates")
    home = Path(os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir))
    for root in roots:
        if (
            str(root) in transaction.KNOWN_BROAD_PATHS
            or root == home
            or transaction._is_relative_to(home, root)
        ):
            raise AdoptionError(f"allowed root is broad/home and refused: {root}")
        try:
            transaction._require_directory(root, "allowed root")
        except transaction.CutoverError as exc:
            raise AdoptionError(str(exc)) from exc
        if Path(os.path.realpath(root)) != root:
            raise AdoptionError(f"allowed root is non-canonical: {root}")
    for left in roots:
        for right in roots:
            if left != right and transaction._is_relative_to(left, right):
                raise AdoptionError(f"allowed roots overlap: {left} and {right}")
    lock_path = _absolute(raw["lock_path"], "lock_path")
    journal_path = _absolute(raw["journal_path"], "journal_path")
    for label, value in (("lock_path", lock_path), ("journal_path", journal_path)):
        _require_real_parent(value, roots, label)
    try:
        transaction._require_directory(lock_path.parent, "private transaction dir", True)
    except transaction.CutoverError as exc:
        raise AdoptionError(str(exc)) from exc
    if journal_path.parent != lock_path.parent or journal_path == lock_path:
        raise AdoptionError("lock and journal must be distinct siblings")
    _require_regular(lock_path, "adoption lock", 0o600)
    quiet_point = _parse_quiet_point(raw["quiet_point"], roots)

    operation_values = raw["link_operations"]
    if not isinstance(operation_values, list) or len(operation_values) != 2:
        raise AdoptionError("link_operations must contain exactly Quota and Agent Fleet")
    links: list[SealedLinkOperation] = []
    for index, value in enumerate(operation_values):
        label = f"link_operations[{index}]"
        if not isinstance(value, dict):
            raise AdoptionError(f"{label} must be an object")
        _require_exact_keys(
            value,
            {
                "name",
                "path",
                "initial_target",
                "sealed_target",
                "sealed_release",
                "sealed_proofs",
                "sealed_tree_sha256",
            },
            set(),
            label,
        )
        name = value["name"]
        if name != EXPECTED_OPERATION_NAMES[index]:
            raise AdoptionError(
                f"{label}.name must be exactly {EXPECTED_OPERATION_NAMES[index]}"
            )
        path = _absolute(value["path"], f"{label}.path")
        _require_real_parent(path, roots, f"{label}.path")
        initial_target = _relative(value["initial_target"], f"{label}.initial_target")
        sealed_target = _relative(value["sealed_target"], f"{label}.sealed_target")
        if initial_target == sealed_target:
            raise AdoptionError(f"{label} initial and sealed targets must differ")
        sealed_release = _absolute(value["sealed_release"], f"{label}.sealed_release")
        resolved = Path(os.path.normpath(path.parent / sealed_target))
        if resolved != sealed_release:
            raise AdoptionError(f"{label}.sealed_target does not resolve to sealed_release")
        _require_real_parent(sealed_release, roots, f"{label}.sealed_release")
        proofs = value["sealed_proofs"]
        if not isinstance(proofs, list) or not proofs:
            raise AdoptionError(f"{label}.sealed_proofs must be non-empty")
        parsed_proofs: list[dict[str, str]] = []
        seen_proofs: set[str] = set()
        for proof_index, proof in enumerate(proofs):
            proof_label = f"{label}.sealed_proofs[{proof_index}]"
            if not isinstance(proof, dict):
                raise AdoptionError(f"{proof_label} must be an object")
            _require_exact_keys(
                proof,
                {"relative_path", "sha256", "mode"},
                set(),
                proof_label,
            )
            relative = _relative(proof["relative_path"], f"{proof_label}.relative_path")
            if relative in seen_proofs:
                raise AdoptionError(f"duplicate sealed proof: {relative}")
            seen_proofs.add(relative)
            mode = proof["mode"]
            try:
                parsed_mode = transaction._parse_proof_mode(mode, f"{proof_label}.mode")
            except transaction.CutoverError as exc:
                raise AdoptionError(str(exc)) from exc
            parsed_proofs.append(
                {
                    "relative_path": relative,
                    "sha256": _digest(proof["sha256"], f"{proof_label}.sha256"),
                    "mode": f"{parsed_mode:04o}",
                }
            )
        operation = SealedLinkOperation(
            name=name,
            path=path,
            initial_target=initial_target,
            sealed_target=sealed_target,
            sealed_release=sealed_release,
            sealed_proofs=tuple(parsed_proofs),
            sealed_tree_sha256=_digest(
                value["sealed_tree_sha256"], f"{label}.sealed_tree_sha256"
            ),
        )
        _validate_sealed_operation(operation)
        links.append(operation)

    front_raw = raw["front_door_operation"]
    if not isinstance(front_raw, dict):
        raise AdoptionError("front_door_operation must be an object")
    _require_exact_keys(
        front_raw,
        {
            "name",
            "path",
            "initial_target",
            "sealed_source",
            "sealed_sha256",
            "mode",
        },
        set(),
        "front_door_operation",
    )
    if front_raw["name"] != "agent-fleet-front-door":
        raise AdoptionError(
            "front_door_operation.name must be agent-fleet-front-door"
        )
    front_path = _absolute(front_raw["path"], "front_door_operation.path")
    front_source = _absolute(
        front_raw["sealed_source"], "front_door_operation.sealed_source"
    )
    for label, value in (
        ("front_door_operation.path", front_path),
        ("front_door_operation.sealed_source", front_source),
    ):
        _require_real_parent(value, roots, label)
    if front_raw["mode"] != "0555":
        raise AdoptionError("front_door_operation.mode must be 0555")
    expected_front_source = links[1].sealed_release / "operator/agent-fleet"
    if front_source != expected_front_source:
        raise AdoptionError(
            "front_door_operation.sealed_source must be the sealed Agent Fleet operator payload"
        )
    front = FrontDoorOperation(
        name="agent-fleet-front-door",
        path=front_path,
        initial_target=_symlink_target(
            front_raw["initial_target"],
            front_path.parent,
            "front_door_operation.initial_target",
        ),
        sealed_source=front_source,
        sealed_sha256=_digest(
            front_raw["sealed_sha256"], "front_door_operation.sealed_sha256"
        ),
        mode=0o555,
    )
    resolved_front_target = Path(
        os.path.normpath(front.path.parent / front.initial_target)
    )
    if resolved_front_target != links[1].path / "bin/agent-fleet":
        raise AdoptionError(
            "front_door_operation.initial_target must resolve to the legacy Agent Fleet current launcher"
        )
    if _sha256(front_source, "sealed Agent Fleet front door", front.mode) != front.sealed_sha256:
        raise AdoptionError("sealed Agent Fleet front-door SHA-256 mismatch")

    registry_raw = raw["registry_operation"]
    if not isinstance(registry_raw, dict):
        raise AdoptionError("registry_operation must be an object")
    _require_exact_keys(
        registry_raw,
        {
            "name",
            "path",
            "initial_source",
            "sealed_source",
            "initial_sha256",
            "sealed_sha256",
            "mode",
        },
        set(),
        "registry_operation",
    )
    if registry_raw["name"] != "accounts-registry":
        raise AdoptionError("registry_operation.name must be accounts-registry")
    registry_path = _absolute(registry_raw["path"], "registry_operation.path")
    initial_source = _absolute(
        registry_raw["initial_source"], "registry_operation.initial_source"
    )
    sealed_source = _absolute(
        registry_raw["sealed_source"], "registry_operation.sealed_source"
    )
    if len({registry_path, initial_source, sealed_source}) != 3:
        raise AdoptionError("registry path and sources must be distinct")
    for label, value in (
        ("registry_operation.path", registry_path),
        ("registry_operation.initial_source", initial_source),
        ("registry_operation.sealed_source", sealed_source),
    ):
        _require_real_parent(value, roots, label)
    if registry_raw["mode"] != "0600":
        raise AdoptionError("registry_operation.mode must be 0600")
    registry = RegistryOperation(
        name="accounts-registry",
        path=registry_path,
        initial_source=initial_source,
        sealed_source=sealed_source,
        initial_sha256=_digest(
            registry_raw["initial_sha256"], "registry_operation.initial_sha256"
        ),
        sealed_sha256=_digest(
            registry_raw["sealed_sha256"], "registry_operation.sealed_sha256"
        ),
        mode=0o600,
    )
    if registry.initial_sha256 == registry.sealed_sha256:
        raise AdoptionError("initial and sealed registry hashes must differ")
    for label, source, expected in (
        ("initial registry source", initial_source, registry.initial_sha256),
        ("sealed registry source", sealed_source, registry.sealed_sha256),
    ):
        observed = _sha256(source, label, registry.mode)
        if observed != expected:
            raise AdoptionError(f"{label} SHA-256 mismatch")

    canonical = json.dumps(raw, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return Manifest(
        path=manifest_path,
        fingerprint=hashlib.sha256(canonical).hexdigest(),
        transaction_id=transaction_id,
        apply_opt_in=raw["apply_opt_in"],
        allowed_roots=roots,
        lock_path=lock_path,
        journal_path=journal_path,
        quiet_point=quiet_point,
        link_operations=tuple(links),
        front_door_operation=front,
        registry_operation=registry,
    )


def _validate_disabled_registry(manifest: Manifest) -> str:
    operation = manifest.registry_operation
    payload = _read_stable_bytes(
        operation.path, "live adoption registry", operation.mode
    )
    digest = hashlib.sha256(payload).hexdigest()
    if digest not in {operation.initial_sha256, operation.sealed_sha256}:
        raise AdoptionError(f"live registry has unknown SHA-256: {digest}")
    try:
        raw = tomllib.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, tomllib.TOMLDecodeError) as exc:
        raise AdoptionError(f"live registry is not valid UTF-8 TOML: {exc}") from exc
    profiles = raw.get("profiles") if isinstance(raw, dict) else None
    if not isinstance(profiles, dict):
        raise AdoptionError("live registry has no profiles table")
    if tuple(sorted(profiles)) != manifest.quiet_point.profile_ids:
        raise AdoptionError("live registry profile set does not match quiet-point contract")
    for profile_id, profile in profiles.items():
        if not isinstance(profile, dict) or profile.get("enabled", False) is not False:
            raise AdoptionError(f"quiet point has an enabled profile: {profile_id}")
        expected_policy = (
            "worker"
            if profile_id in manifest.quiet_point.worker_profile_ids
            else "desktop_shared"
        )
        if profile.get("safety_policy") != expected_policy:
            raise AdoptionError(
                f"profile {profile_id} safety_policy is not {expected_policy}"
            )
        pools = profile.get("pools", [])
        if not isinstance(pools, list) or not all(isinstance(pool, str) for pool in pools):
            raise AdoptionError(f"profile {profile_id} pools are invalid")
        if expected_policy != "worker" and any(pool.endswith("-crew") for pool in pools):
            raise AdoptionError(
                f"never-enroll profile {profile_id} is in a crew pool"
            )
    return digest


def _validate_quiet_point(manifest: Manifest) -> None:
    quiet = manifest.quiet_point
    _validate_disabled_registry(manifest)
    backend_payload = _read_stable_bytes(quiet.backend_path, "backend selector")
    backend_digest = hashlib.sha256(backend_payload).hexdigest()
    if backend_digest != quiet.backend_sha256:
        raise AdoptionError("backend selector SHA-256 changed")
    try:
        backend_value = backend_payload.decode("utf-8").strip()
    except UnicodeDecodeError as exc:
        raise AdoptionError("backend selector is not UTF-8") from exc
    if backend_value != "tmux":
        raise AdoptionError(f"backend must be tmux at adoption quiet point: {backend_value!r}")
    ps_payload = _read_stable_bytes(
        quiet.ps_binary, "quiet-point ps binary", allow_root=True
    )
    if hashlib.sha256(ps_payload).hexdigest() != quiet.ps_binary_sha256:
        raise AdoptionError("quiet-point ps binary SHA-256 changed")
    for path in quiet.routing_absent_paths:
        _require_real_parent(path, manifest.allowed_roots, "routing absence path")
        if os.path.lexists(path):
            raise AdoptionError(f"routing enable path must be absent: {path}")
    for path in quiet.state_quiet_paths:
        _require_real_parent(path, manifest.allowed_roots, "quiet state path")
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
            raise AdoptionError(f"cannot safely open quiet state path {path}: {exc}") from exc
        try:
            before = os.fstat(fd)
            if not stat.S_ISDIR(before.st_mode):
                raise AdoptionError(f"quiet state path must be a real directory: {path}")
            if before.st_uid != os.getuid():
                raise AdoptionError(
                    f"quiet state path is not owned by current uid: {path}"
                )
            try:
                names = os.listdir(fd)
            except OSError as exc:
                raise AdoptionError(f"cannot scan quiet state path {path}: {exc}") from exc
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
                raise AdoptionError(f"quiet state path changed while scanning: {path}")
            current = os.lstat(path)
            if (
                current.st_dev != before.st_dev
                or current.st_ino != before.st_ino
                or current.st_mode != before.st_mode
            ):
                raise AdoptionError(f"quiet state path was substituted while scanning: {path}")
            if names:
                summary = ", ".join(sorted(names)[:5])
                raise AdoptionError(f"quiet state path is not empty: {path}: {summary}")
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
        raise AdoptionError(f"process quiet-point probe failed: {exc}") from exc
    if completed.returncode != 0:
        raise AdoptionError(
            f"process quiet-point probe exited {completed.returncode}: "
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
                raise AdoptionError(
                    f"Fleet process token is active at quiet point: {token}: pid {pid}"
                )


def _observe_operation(operation: Operation) -> str:
    if isinstance(operation, SealedLinkOperation):
        try:
            info = os.lstat(operation.path)
        except FileNotFoundError as exc:
            raise AdoptionError(f"adoption link is missing: {operation.path}") from exc
        if not stat.S_ISLNK(info.st_mode):
            raise AdoptionError(f"adoption current path is not a symlink: {operation.path}")
        target = os.readlink(operation.path)
        if target == operation.initial_target:
            return "initial"
        if target == operation.sealed_target:
            return "sealed"
        raise AdoptionError(
            f"{operation.name} has unknown raw target {target!r}; "
            "only exact initial/sealed targets are accepted"
        )
    if isinstance(operation, FrontDoorOperation):
        try:
            info = os.lstat(operation.path)
        except FileNotFoundError as exc:
            raise AdoptionError(
                f"Agent Fleet front door is missing: {operation.path}"
            ) from exc
        if stat.S_ISLNK(info.st_mode):
            target = os.readlink(operation.path)
            if target == operation.initial_target:
                return "initial"
            raise AdoptionError(
                f"Agent Fleet front door has unknown initial target {target!r}"
            )
        digest = _sha256(
            operation.path, "live sealed Agent Fleet front door", operation.mode
        )
        if digest == operation.sealed_sha256:
            return "sealed"
        raise AdoptionError(
            f"live Agent Fleet front door has unknown SHA-256: {digest}"
        )
    digest = _sha256(operation.path, "live adoption registry", operation.mode)
    if digest == operation.initial_sha256:
        return "initial"
    if digest == operation.sealed_sha256:
        return "sealed"
    raise AdoptionError(f"live adoption registry has unknown SHA-256: {digest}")


def observe(manifest: Manifest) -> tuple[list[str], int]:
    for operation in manifest.link_operations:
        _validate_sealed_operation(operation)
    states = [_observe_operation(operation) for operation in manifest.operations]
    prefix = next(
        (index for index, state in enumerate(states) if state == "initial"),
        len(states),
    )
    if states != ["sealed"] * prefix + ["initial"] * (len(states) - prefix):
        raise AdoptionError("adoption states are not an exact sealed-prefix/initial-suffix")
    return states, prefix


def _new_journal(manifest: Manifest) -> dict[str, Any]:
    return {
        "schema_version": JOURNAL_SCHEMA_VERSION,
        "manifest_sha256": manifest.fingerprint,
        "status": "new",
        "sealed": False,
        "sequence": 0,
        "history": [],
    }


def _load_journal(manifest: Manifest) -> dict[str, Any] | None:
    if not os.path.lexists(manifest.journal_path):
        return None
    try:
        raw = transaction._read_json_file(
            manifest.journal_path,
            MAX_JOURNAL_BYTES,
            "adoption journal",
            0o600,
        )
    except transaction.CutoverError as exc:
        raise AdoptionError(str(exc)) from exc
    if not isinstance(raw, dict):
        raise AdoptionError("adoption journal root must be an object")
    _require_exact_keys(
        raw,
        {
            "schema_version",
            "manifest_sha256",
            "status",
            "sealed",
            "sequence",
            "history",
        },
        set(),
        "adoption journal",
    )
    if raw["schema_version"] != JOURNAL_SCHEMA_VERSION:
        raise AdoptionError("unsupported adoption journal schema")
    if raw["manifest_sha256"] != manifest.fingerprint:
        raise AdoptionError("adoption journal manifest SHA-256 mismatch")
    if raw["status"] not in {"new", "adopting", "recovering", "rolled-back", "sealed"}:
        raise AdoptionError("adoption journal has invalid status")
    if not isinstance(raw["sealed"], bool):
        raise AdoptionError("adoption journal sealed flag must be boolean")
    if raw["sealed"] != (raw["status"] == "sealed"):
        raise AdoptionError("adoption journal sealed/status mismatch")
    if not isinstance(raw["sequence"], int) or raw["sequence"] < 0:
        raise AdoptionError("adoption journal sequence is invalid")
    if not isinstance(raw["history"], list):
        raise AdoptionError("adoption journal history must be an array")
    return raw


def _write_journal(
    manifest: Manifest,
    journal: dict[str, Any],
    checkpoint: str,
    boundaries: BoundaryController,
) -> None:
    payload = (json.dumps(journal, sort_keys=True, separators=(",", ":")) + "\n").encode(
        "utf-8"
    )
    if len(payload) > MAX_JOURNAL_BYTES:
        raise AdoptionError("adoption journal exceeds safety limit")
    temp = transaction._temp_path(
        manifest.journal_path, manifest.transaction_id, "journal"
    )
    boundaries.hit(f"before_journal:{checkpoint}")
    try:
        fd = transaction._open_exact_temp(temp, 0o600)
        try:
            transaction._write_all(fd, payload)
            boundaries.hit(f"before_fsync:journal-temp:{checkpoint}")
            os.fsync(fd)
            boundaries.hit(f"after_fsync:journal-temp:{checkpoint}")
        finally:
            os.close(fd)
        boundaries.hit(f"before_replace:journal:{checkpoint}")
        transaction._require_regular(temp, "staged adoption journal", 0o600)
        os.replace(temp, manifest.journal_path)
        boundaries.hit(f"after_replace:journal:{checkpoint}")
        boundaries.hit(f"before_fsync:journal-dir:{checkpoint}")
        transaction._fsync_directory(manifest.journal_path.parent)
        boundaries.hit(f"after_fsync:journal-dir:{checkpoint}")
        boundaries.hit(f"after_journal:{checkpoint}")
    except transaction.CutoverError as exc:
        raise AdoptionError(str(exc)) from exc


def _checkpoint(
    manifest: Manifest,
    journal: dict[str, Any],
    status: str,
    states: Sequence[str],
    boundaries: BoundaryController,
) -> None:
    journal["status"] = status
    journal["sealed"] = status == "sealed"
    journal["sequence"] += 1
    journal["history"].append(
        {
            "sequence": journal["sequence"],
            "status": status,
            "states": list(states),
        }
    )
    _write_journal(manifest, journal, status, boundaries)


@contextmanager
def _lock(manifest: Manifest) -> Iterable[None]:
    try:
        fd, _ = transaction._open_regular_readonly(
            manifest.lock_path, "adoption lock", 0o600
        )
    except transaction.CutoverError as exc:
        raise AdoptionError(str(exc)) from exc
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise AdoptionError("another sealed-adoption process holds the lock") from exc
        yield
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)


def _replace_link(
    manifest: Manifest,
    operation: SealedLinkOperation,
    direction: str,
    boundaries: BoundaryController,
) -> None:
    target = (
        operation.sealed_target if direction == "forward" else operation.initial_target
    )
    expected = "initial" if direction == "forward" else "sealed"
    temp = transaction._temp_path(operation.path, manifest.transaction_id, direction)
    boundaries.hit(f"before_prepare:{direction}:{operation.name}")
    if os.path.lexists(temp):
        info = os.lstat(temp)
        if not stat.S_ISLNK(info.st_mode) or os.readlink(temp) != target:
            raise AdoptionError(f"unexpected staged adoption link: {temp}")
    else:
        os.symlink(target, temp)
    boundaries.hit(f"after_prepare:{direction}:{operation.name}")
    if _observe_operation(operation) != expected:
        raise AdoptionError(f"{operation.name} changed during {direction} preparation")
    _validate_quiet_point(manifest)
    for sealed in manifest.link_operations:
        _validate_sealed_operation(sealed)
    boundaries.hit(f"before_replace:{direction}:{operation.name}")
    if not stat.S_ISLNK(os.lstat(temp).st_mode) or os.readlink(temp) != target:
        raise AdoptionError(f"staged adoption link changed: {temp}")
    if _observe_operation(operation) != expected:
        raise AdoptionError(f"{operation.name} changed immediately before replacement")
    os.replace(temp, operation.path)
    boundaries.hit(f"after_replace:{direction}:{operation.name}")
    boundaries.hit(f"before_fsync:{direction}-dir:{operation.name}")
    transaction._fsync_directory(operation.path.parent)
    boundaries.hit(f"after_fsync:{direction}-dir:{operation.name}")


def _replace_front_door(
    manifest: Manifest,
    operation: FrontDoorOperation,
    direction: str,
    boundaries: BoundaryController,
) -> None:
    temp = transaction._temp_path(operation.path, manifest.transaction_id, direction)
    expected_state = "initial" if direction == "forward" else "sealed"
    boundaries.hit(f"before_prepare:{direction}:{operation.name}")
    if direction == "rollback":
        if os.path.lexists(temp):
            info = os.lstat(temp)
            if (
                not stat.S_ISLNK(info.st_mode)
                or os.readlink(temp) != operation.initial_target
            ):
                raise AdoptionError(f"unexpected staged front-door rollback: {temp}")
        else:
            os.symlink(operation.initial_target, temp)
    else:
        prepared = False
        if os.path.lexists(temp):
            _require_regular(temp, "staged adoption front door")
            temp_mode = stat.S_IMODE(os.lstat(temp).st_mode)
            if temp_mode == operation.mode:
                if (
                    _sha256(temp, "staged adoption front door", operation.mode)
                    != operation.sealed_sha256
                ):
                    raise AdoptionError("staged adoption front-door hash mismatch")
                prepared = True
            elif temp_mode != 0o600:
                raise AdoptionError(
                    f"staged adoption front-door mode is {temp_mode:04o}"
                )
        if prepared:
            try:
                output_fd, _ = transaction._open_regular_readonly(
                    temp, "staged adoption front door", operation.mode
                )
                try:
                    boundaries.hit(
                        f"before_fsync:{direction}-temp:{operation.name}"
                    )
                    os.fsync(output_fd)
                    boundaries.hit(
                        f"after_fsync:{direction}-temp:{operation.name}"
                    )
                finally:
                    os.close(output_fd)
            except transaction.CutoverError as exc:
                raise AdoptionError(str(exc)) from exc
        else:
            try:
                source_fd, source_info = transaction._open_regular_readonly(
                    operation.sealed_source,
                    "sealed Agent Fleet front-door source",
                    operation.mode,
                )
                try:
                    output_fd = transaction._open_exact_temp(temp, 0o600)
                    try:
                        while True:
                            block = os.read(source_fd, 1024 * 1024)
                            if not block:
                                break
                            transaction._write_all(output_fd, block)
                        transaction._require_stable_regular_fd(
                            source_fd,
                            source_info,
                            operation.sealed_source,
                            "sealed Agent Fleet front-door source",
                        )
                        os.fchmod(output_fd, operation.mode)
                        boundaries.hit(
                            f"before_fsync:{direction}-temp:{operation.name}"
                        )
                        os.fsync(output_fd)
                        boundaries.hit(
                            f"after_fsync:{direction}-temp:{operation.name}"
                        )
                    finally:
                        os.close(output_fd)
                finally:
                    os.close(source_fd)
            except transaction.CutoverError as exc:
                raise AdoptionError(str(exc)) from exc
        if (
            _sha256(temp, "staged adoption front door", operation.mode)
            != operation.sealed_sha256
        ):
            raise AdoptionError("staged adoption front-door hash mismatch")
    boundaries.hit(f"after_prepare:{direction}:{operation.name}")
    if _observe_operation(operation) != expected_state:
        raise AdoptionError("live Agent Fleet front door changed during preparation")
    _validate_quiet_point(manifest)
    for sealed in manifest.link_operations:
        _validate_sealed_operation(sealed)
    boundaries.hit(f"before_replace:{direction}:{operation.name}")
    if direction == "rollback":
        info = os.lstat(temp)
        if (
            not stat.S_ISLNK(info.st_mode)
            or os.readlink(temp) != operation.initial_target
        ):
            raise AdoptionError("staged Agent Fleet front-door rollback changed")
    else:
        if (
            _sha256(temp, "staged adoption front door", operation.mode)
            != operation.sealed_sha256
        ):
            raise AdoptionError(
                "staged adoption front-door hash changed immediately before replacement"
            )
    if _observe_operation(operation) != expected_state:
        raise AdoptionError("live Agent Fleet front door changed before replacement")
    os.replace(temp, operation.path)
    boundaries.hit(f"after_replace:{direction}:{operation.name}")
    boundaries.hit(f"before_fsync:{direction}-dir:{operation.name}")
    transaction._fsync_directory(operation.path.parent)
    boundaries.hit(f"after_fsync:{direction}-dir:{operation.name}")


def _replace_registry(
    manifest: Manifest,
    operation: RegistryOperation,
    direction: str,
    boundaries: BoundaryController,
) -> None:
    source = operation.sealed_source if direction == "forward" else operation.initial_source
    expected_hash = (
        operation.sealed_sha256 if direction == "forward" else operation.initial_sha256
    )
    expected_state = "initial" if direction == "forward" else "sealed"
    temp = transaction._temp_path(operation.path, manifest.transaction_id, direction)
    boundaries.hit(f"before_prepare:{direction}:{operation.name}")
    try:
        source_fd, source_info = transaction._open_regular_readonly(
            source, f"{operation.name} {direction} source", operation.mode
        )
        try:
            output_fd = transaction._open_exact_temp(temp, operation.mode)
            try:
                while True:
                    block = os.read(source_fd, 1024 * 1024)
                    if not block:
                        break
                    transaction._write_all(output_fd, block)
                transaction._require_stable_regular_fd(
                    source_fd,
                    source_info,
                    source,
                    f"{operation.name} {direction} source",
                )
                boundaries.hit(f"before_fsync:{direction}-temp:{operation.name}")
                os.fsync(output_fd)
                boundaries.hit(f"after_fsync:{direction}-temp:{operation.name}")
            finally:
                os.close(output_fd)
        finally:
            os.close(source_fd)
        observed = transaction._sha256_file(
            temp,
            label=f"{operation.name} staged registry",
            expected_mode=operation.mode,
        )
    except transaction.CutoverError as exc:
        raise AdoptionError(str(exc)) from exc
    if observed != expected_hash:
        raise AdoptionError("staged adoption registry hash mismatch")
    boundaries.hit(f"after_prepare:{direction}:{operation.name}")
    if _observe_operation(operation) != expected_state:
        raise AdoptionError("live adoption registry changed during preparation")
    _validate_quiet_point(manifest)
    for sealed in manifest.link_operations:
        _validate_sealed_operation(sealed)
    boundaries.hit(f"before_replace:{direction}:{operation.name}")
    if (
        _sha256(temp, "staged adoption registry", operation.mode)
        != expected_hash
    ):
        raise AdoptionError(
            "staged adoption registry hash changed immediately before replacement"
        )
    if _observe_operation(operation) != expected_state:
        raise AdoptionError("live adoption registry changed before replacement")
    os.replace(temp, operation.path)
    boundaries.hit(f"after_replace:{direction}:{operation.name}")
    boundaries.hit(f"before_fsync:{direction}-dir:{operation.name}")
    transaction._fsync_directory(operation.path.parent)
    boundaries.hit(f"after_fsync:{direction}-dir:{operation.name}")


def _replace_operation(
    manifest: Manifest,
    operation: Operation,
    direction: str,
    boundaries: BoundaryController,
) -> None:
    if isinstance(operation, SealedLinkOperation):
        _replace_link(manifest, operation, direction, boundaries)
    elif isinstance(operation, FrontDoorOperation):
        _replace_front_door(manifest, operation, direction, boundaries)
    else:
        _replace_registry(manifest, operation, direction, boundaries)


def _cleanup_temps(manifest: Manifest) -> None:
    parents: set[Path] = set()
    for operation in manifest.operations:
        for direction in ("forward", "rollback"):
            path = transaction._temp_path(
                operation.path, manifest.transaction_id, direction
            )
            if not os.path.lexists(path):
                continue
            info = os.lstat(path)
            if isinstance(operation, SealedLinkOperation):
                if not stat.S_ISLNK(info.st_mode):
                    raise AdoptionError(f"unexpected adoption temp artifact: {path}")
            elif isinstance(operation, FrontDoorOperation):
                if direction == "rollback":
                    if (
                        not stat.S_ISLNK(info.st_mode)
                        or os.readlink(path) != operation.initial_target
                    ):
                        raise AdoptionError(f"unexpected adoption temp artifact: {path}")
                else:
                    _require_regular(path, "adoption front-door temp")
                    if stat.S_IMODE(info.st_mode) not in {0o600, operation.mode}:
                        raise AdoptionError(f"unexpected adoption temp mode: {path}")
            else:
                _require_regular(path, "adoption registry temp", operation.mode)
            os.unlink(path)
            parents.add(path.parent)
    for parent in parents:
        transaction._fsync_directory(parent)


def _recover_locked(
    manifest: Manifest,
    journal: dict[str, Any],
    boundaries: BoundaryController,
) -> dict[str, Any]:
    _validate_quiet_point(manifest)
    states, prefix = observe(manifest)
    if journal.get("sealed"):
        raise AdoptionError("sealed adoption is irreversible; recovery is refused")
    _checkpoint(manifest, journal, "recovering", states, boundaries)
    for index in range(prefix - 1, -1, -1):
        operation = manifest.operations[index]
        _replace_operation(manifest, operation, "rollback", boundaries)
        states, new_prefix = observe(manifest)
        if new_prefix != index:
            raise AdoptionError("adoption recovery produced an invalid state prefix")
        _checkpoint(manifest, journal, "recovering", states, boundaries)
    _cleanup_temps(manifest)
    states, prefix = observe(manifest)
    if prefix != 0:
        raise AdoptionError("adoption recovery did not restore the exact initial state")
    _checkpoint(manifest, journal, "rolled-back", states, boundaries)
    return {
        "mode": "recover",
        "transaction_id": manifest.transaction_id,
        "states": states,
        "recovered": True,
        "sealed": False,
    }


def plan(manifest: Manifest) -> dict[str, Any]:
    with _lock(manifest):
        _validate_quiet_point(manifest)
        states, prefix = observe(manifest)
        journal = _load_journal(manifest)
        sealed = bool(journal and journal.get("sealed"))
        if sealed and prefix != len(manifest.operations):
            raise AdoptionError("sealed journal does not match fully sealed state")
        return {
            "mode": "plan",
            "transaction_id": manifest.transaction_id,
            "states": states,
            "sealed_prefix": prefix,
            "recovery_required": 0 < prefix < len(manifest.operations)
            or bool(journal and journal.get("status") in {"adopting", "recovering"}),
            "sealed": sealed,
        }


def recover(
    manifest: Manifest,
    boundaries: BoundaryController | None = None,
) -> dict[str, Any]:
    with _lock(manifest):
        _validate_quiet_point(manifest)
        journal = _load_journal(manifest) or _new_journal(manifest)
        return _recover_locked(manifest, journal, boundaries or BoundaryController())


def apply(
    manifest: Manifest,
    boundaries: BoundaryController | None = None,
) -> dict[str, Any]:
    controller = boundaries or BoundaryController()
    with _lock(manifest):
        if not manifest.apply_opt_in:
            raise AdoptionError("manifest apply_opt_in is false; adoption is refused")
        _validate_quiet_point(manifest)
        states, prefix = observe(manifest)
        journal = _load_journal(manifest) or _new_journal(manifest)
        if journal.get("sealed"):
            if prefix != len(manifest.operations):
                raise AdoptionError("sealed journal does not match fully sealed state")
            return {
                "mode": "apply",
                "transaction_id": manifest.transaction_id,
                "states": states,
                "sealed": True,
                "converged": True,
            }
        if prefix or journal.get("status") in {"adopting", "recovering"}:
            _recover_locked(manifest, journal, controller)
            raise AdoptionError(
                "incomplete adoption was recovered to initial; invoke apply again"
            )
        _checkpoint(manifest, journal, "adopting", states, controller)
        try:
            for index, operation in enumerate(manifest.operations):
                _replace_operation(manifest, operation, "forward", controller)
                states, new_prefix = observe(manifest)
                if new_prefix != index + 1:
                    raise AdoptionError("adoption produced an invalid state prefix")
                _checkpoint(manifest, journal, "adopting", states, controller)
            _validate_quiet_point(manifest)
            states, prefix = observe(manifest)
            if prefix != len(manifest.operations):
                raise AdoptionError("adoption did not reach the fully sealed state")
            _checkpoint(manifest, journal, "sealed", states, controller)
        except InjectedFailure:
            raise
        except BaseException:
            _recover_locked(manifest, journal, BoundaryController())
            raise
        _cleanup_temps(manifest)
        return {
            "mode": "apply",
            "transaction_id": manifest.transaction_id,
            "states": states,
            "sealed": True,
            "converged": True,
        }


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", help="absolute sealed-adoption manifest path")
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument("--apply", action="store_true", help="adopt and seal runtimes")
    actions.add_argument(
        "--recover",
        action="store_true",
        help="recover an interrupted, non-finalized adoption backward",
    )
    parser.add_argument("--inject-failure-at", help=argparse.SUPPRESS)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        manifest = load_manifest(args.manifest)
        controller: BoundaryController | None = None
        if args.inject_failure_at:
            if os.environ.get("BRIDGE_CUTOVER_ALLOW_FAILURE_INJECTION") != "1":
                raise AdoptionError("failure injection requires explicit test opt-in")
            controller = BoundaryController(args.inject_failure_at)
        if args.apply:
            result = apply(manifest, controller)
        elif args.recover:
            result = recover(manifest, controller)
        else:
            result = plan(manifest)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    except InjectedFailure as exc:
        print(f"injected-crash: {exc}", file=sys.stderr)
        return 75
    except (AdoptionError, OSError) as exc:
        print(f"refused: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
