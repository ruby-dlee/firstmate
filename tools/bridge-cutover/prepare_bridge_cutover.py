#!/usr/bin/env python3
"""Prepare, validate, refresh, and rehearse a Bridge cutover bundle.

This script is deliberately installation-agnostic and standard-library only.
It has no defaults for user homes, registries, release links, projects, or
provider binaries.  Every live path is bound by an absolute path in the strict
preparation specification or its validated bundle.

``prepare`` writes only to a new explicit output directory.  ``validate`` is
read-only.  ``refresh`` atomically replaces only an applied bundle's recorded
activation plan and worker-state manifest.  ``rehearse`` copies the bound
release trees and registry sources into a disposable private directory, then
exercises the existing restartable transaction driver there.  None of the
commands enrolls an account, launches a provider, changes routing, or operates
a live release link.
"""

from __future__ import annotations

import argparse
import base64
import copy
import csv
import ctypes
import dataclasses
import errno as errno_module
import fcntl
import hashlib
import importlib
import importlib.util
import json
import os
import pwd
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import tomllib
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType
from typing import Any, Mapping, Sequence


SCHEMA_VERSION = 2
BUNDLE_SCHEMA_VERSION = 2
QUOTA_CANDIDATE_VERSION = "0.1.7"
MAX_SPEC_BYTES = 1_000_000
MAX_REGISTRY_BYTES = 1_000_000
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
VERSION = re.compile(r"^[0-9]+(?:\.[0-9]+){1,3}(?:[-+][A-Za-z0-9._-]+)?$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
GIT_COMMIT = re.compile(r"^[0-9a-f]{40}$")

REQUIRED_INJECTION_ENVIRONMENT_EXACT_SCRUB = (
    "ENV",
    "GCONV_PATH",
    "LOCPATH",
    "NLSPATH",
    "PERL5OPT",
    "RUBYOPT",
    "SSLKEYLOGFILE",
)
REQUIRED_INJECTION_ENVIRONMENT_PREFIX_SCRUB = (
    "BASH_",
    "DYLD_",
    "ELECTRON_",
    "LD_",
    "MALLOC_",
    "NODE_",
    "NPM_CONFIG_",
    "PERL5",
    "PYTHON",
    "RUBY",
    "npm_config_",
)
REQUIRED_AGENT_FLEET_ENVIRONMENT_SCRUB = (
    "AGENT_FLEET_BIN",
    "AGENT_FLEET_CLAUDE_BIN",
    "AGENT_FLEET_CODEX_BIN",
    "AGENT_FLEET_CONFIG",
    "AGENT_FLEET_FORMAT",
    "AGENT_FLEET_QUOTA_BIN",
    "AGENT_FLEET_QUOTA_FIXTURE_DIR",
    "AGENT_FLEET_SHARE_DIR",
    "AGENT_FLEET_STATE_DIR",
    "AGENT_FLEET_TEST_QUOTA_FIXTURE_DIR",
)
REQUIRED_AGENT_FLEET_ENVIRONMENT_PREFIX_SCRUB = (
    "AGENT_FLEET_QUOTA_FIXTURE_",
    "AGENT_FLEET_TEST_QUOTA_FIXTURE_",
)

EXPECTED_TOPOLOGY: dict[str, tuple[str, tuple[str, ...], str]] = {
    "claude-1": (
        "claude",
        ("claude-crew", "claude-manual"),
        "worker",
    ),
    "claude-2": (
        "claude",
        ("claude-crew", "claude-manual"),
        "worker",
    ),
    "claude-3": (
        "claude",
        ("claude-manual",),
        "desktop_shared",
    ),
    "codex-1": ("codex", ("codex-crew", "codex-manual"), "worker"),
    "codex-2": ("codex", ("codex-crew", "codex-manual"), "worker"),
    "codex-3": ("codex", ("codex-crew", "codex-manual"), "worker"),
    "codex-4": ("codex", ("codex-crew", "codex-manual"), "worker"),
    "codex-5": ("codex", ("codex-manual",), "desktop_shared"),
}
WORKER_PROFILES = tuple(
    profile_id
    for profile_id, (_, _, policy) in EXPECTED_TOPOLOGY.items()
    if policy == "worker"
)
RESERVE_PROFILES = tuple(
    profile_id
    for profile_id, (_, _, policy) in EXPECTED_TOPOLOGY.items()
    if policy != "worker"
)

REGISTRY_TOP_KEYS = {"version", "settings", "providers", "profiles"}
SETTINGS_KEYS = {
    "state_dir",
    "share_dir",
    "quota_binary",
    "quota_node_binary",
    "quota_binary_sha256",
    "quota_node_sha256",
    "quota_release_tree_sha256",
    "quota_stale_seconds",
    "quota_verification_grace_seconds",
    "lease_grace_seconds",
    "active_lease_penalty",
    "lock_stale_seconds",
}
PROVIDER_KEYS = {
    "binary",
    "base_home",
    "hooks_source",
    "desktop_identity_file",
    "shared_entries",
    "trusted_projects",
}
PROFILE_KEYS = {
    "provider",
    "home",
    "pools",
    "enabled",
    "weight",
    "max_concurrent",
    "reserve_percent",
    "safety_policy",
}


class PreparationError(RuntimeError):
    """An exact-input, topology, release, or rehearsal refusal."""


@dataclass(frozen=True)
class ReleaseSpec:
    name: str
    current_link: Path
    old_release: Path
    old_target: str
    new_release: Path
    new_target: str
    old_proof_paths: tuple[str, ...]
    new_proof_paths: tuple[str, ...]


@dataclass(frozen=True)
class AgentFleetSpec:
    release: ReleaseSpec
    pythonpath: Path
    executable: Path
    python_binary: Path
    expected_python_version: str
    launcher_module: Path
    launcher_source: Path
    wheel_metadata: Path
    wheel_record: Path
    build_provenance: Path
    build_manifest: Path
    source_commit: str
    expected_version: str
    expected_contract_version: int
    rollback_executable: Path
    rollback_pythonpath: Path
    rollback_python_version: str
    rollback_source_commit: str
    rollback_version: str
    rollback_contract_version: int
    operator_front_door: Path
    candidate_front_door: Path
    rollback_front_door: Path


@dataclass(frozen=True)
class QuotaSpec:
    release: ReleaseSpec
    # ``binary`` is the only operational Quota entrypoint.  It is a native,
    # hardened launcher; raw Node and JavaScript are sealed internal inputs.
    binary: Path
    node_binary: Path
    entrypoint: Path
    launcher_source: Path
    build_provenance: Path
    runtime_manifest: Path
    node_version: str
    package_json: Path
    package_lock: Path
    expected_package_name: str
    expected_version: str
    source_commit: str
    rollback_binary: Path
    rollback_node_binary: Path
    rollback_entrypoint: Path
    rollback_launcher_source: Path
    rollback_build_provenance: Path
    rollback_runtime_manifest: Path
    rollback_package_json: Path
    rollback_package_lock: Path
    rollback_node_version: str
    rollback_version: str
    rollback_source_commit: str
    legacy_registry_binary: Path
    release_tree_sha256: str


@dataclass(frozen=True)
class SealedAdoptionSpec:
    agent_fleet_initial_target: str
    agent_fleet_front_door_initial_target: str
    quota_initial_target: str
    routing_absent_paths: tuple[Path, ...]
    backend_path: Path
    backend_sha256: str
    state_quiet_paths: tuple[Path, ...]
    forbidden_process_tokens: tuple[str, ...]
    ps_binary: Path
    ps_binary_sha256: str


@dataclass(frozen=True)
class WorkerStateSpec:
    snapshot_parent: Path


@dataclass(frozen=True)
class PreparationSpec:
    source_path: Path
    transaction_id: str
    apply_opt_in: bool
    output_dir: Path
    baseline_registry: Path
    baseline_registry_sha256: str
    live_registry: Path
    trusted_project: Path
    agent_fleet: AgentFleetSpec
    quota: QuotaSpec
    sealed_adoption: SealedAdoptionSpec
    worker_state: WorkerStateSpec
    raw: dict[str, Any]


@dataclass(frozen=True)
class AgentFleetAPI:
    package: ModuleType
    config: ModuleType
    models: ModuleType
    provision: ModuleType | None
    identity: ModuleType | None


def _require_exact_keys(
    value: Mapping[str, Any], required: set[str], optional: set[str], label: str
) -> None:
    missing = required - set(value)
    unknown = set(value) - required - optional
    if missing:
        raise PreparationError(f"{label} is missing keys: {', '.join(sorted(missing))}")
    if unknown:
        raise PreparationError(f"{label} has unknown keys: {', '.join(sorted(unknown))}")


def _read_json(path: Path, label: str, max_bytes: int = MAX_SPEC_BYTES) -> Any:
    _require_regular(path, label)
    if path.stat().st_size > max_bytes:
        raise PreparationError(f"{label} exceeds {max_bytes} bytes: {path}")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise PreparationError(f"{label} is not valid UTF-8 JSON: {path}: {exc}") from exc


def _normalized_absolute(value: Any, label: str) -> Path:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise PreparationError(f"{label} must be a non-empty absolute path string")
    if "$" in value:
        raise PreparationError(f"{label} may not contain shell-variable syntax")
    if value.startswith("~/"):
        passwd_home = pwd.getpwuid(os.getuid()).pw_dir
        value = os.path.join(passwd_home, value[2:])
    if not os.path.isabs(value) or os.path.normpath(value) != value:
        raise PreparationError(f"{label} must be absolute and normalized: {value!r}")
    return Path(value)


def _normalized_relative(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise PreparationError(f"{label} must be a non-empty relative path string")
    if os.path.isabs(value) or os.path.normpath(value) != value:
        raise PreparationError(f"{label} must be normalized and relative: {value!r}")
    if "$" in value:
        raise PreparationError(f"{label} may not contain shell-variable syntax")
    parts = Path(value).parts
    if not parts or any(part in {"", ".", ".."} for part in parts):
        raise PreparationError(f"{label} may not contain empty, '.' or '..' components")
    return value


def _normalized_symlink_payload(value: Any, label: str) -> str:
    if isinstance(value, str) and os.path.isabs(value):
        return str(_normalized_absolute(value, label))
    if not isinstance(value, str) or not value or "\x00" in value or "$" in value:
        raise PreparationError(f"{label} must be a non-empty literal symlink payload")
    if os.path.normpath(value) != value or any(
        part in {"", "."} for part in Path(value).parts
    ):
        raise PreparationError(f"{label} must be a normalized relative symlink payload")
    return value


def _canonical(path: Path, label: str) -> None:
    if Path(os.path.realpath(path)) != path:
        raise PreparationError(f"{label} is symlinked or non-canonical: {path}")


def _require_directory(path: Path, label: str, *, private: bool = False) -> None:
    try:
        info = os.lstat(path)
    except FileNotFoundError as exc:
        raise PreparationError(f"{label} does not exist: {path}") from exc
    if not stat.S_ISDIR(info.st_mode):
        raise PreparationError(f"{label} must be a real directory: {path}")
    _canonical(path, label)
    if private and stat.S_IMODE(info.st_mode) & 0o077:
        raise PreparationError(f"{label} must be private (0700 or stricter): {path}")


def _require_regular(
    path: Path,
    label: str,
    *,
    mode: int | None = None,
    executable: bool = False,
    allow_root_hardlinks: bool = False,
) -> None:
    try:
        info = os.lstat(path)
    except FileNotFoundError as exc:
        raise PreparationError(f"{label} does not exist: {path}") from exc
    if not stat.S_ISREG(info.st_mode):
        raise PreparationError(f"{label} must be a regular non-symlink file: {path}")
    if info.st_nlink != 1 and not (allow_root_hardlinks and info.st_uid == 0):
        raise PreparationError(f"{label} must have exactly one hard link: {path}")
    _canonical(path, label)
    observed_mode = stat.S_IMODE(info.st_mode)
    if mode is not None and observed_mode != mode:
        raise PreparationError(
            f"{label} mode is {observed_mode:04o}; expected {mode:04o}: {path}"
        )
    if observed_mode & 0o022:
        raise PreparationError(f"{label} must not be group- or other-writable: {path}")
    if executable and not observed_mode & 0o100:
        raise PreparationError(f"{label} must be owner-executable: {path}")


def _is_relative_to(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def _require_within(path: Path, root: Path, label: str) -> str:
    if path == root or not _is_relative_to(path, root):
        raise PreparationError(f"{label} must be strictly inside {root}: {path}")
    _canonical(path, label)
    return str(path.relative_to(root))


def _sha256(path: Path, *, allow_root_hardlinks: bool = False) -> str:
    _require_regular(
        path, "SHA-256 input", allow_root_hardlinks=allow_root_hardlinks
    )
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _parse_release(value: Any, label: str, name: str) -> ReleaseSpec:
    if not isinstance(value, dict):
        raise PreparationError(f"{label} must be an object")
    _require_exact_keys(
        value,
        {
            "current_link",
            "old_release",
            "old_target",
            "new_release",
            "new_target",
            "old_proof_paths",
            "new_proof_paths",
        },
        set(),
        label,
    )
    old_proofs = value["old_proof_paths"]
    new_proofs = value["new_proof_paths"]
    if not isinstance(old_proofs, list) or not old_proofs:
        raise PreparationError(f"{label}.old_proof_paths must be a non-empty array")
    if not isinstance(new_proofs, list) or not new_proofs:
        raise PreparationError(f"{label}.new_proof_paths must be a non-empty array")
    old_normalized = tuple(
        _normalized_relative(item, f"{label}.old_proof_paths[{index}]")
        for index, item in enumerate(old_proofs)
    )
    new_normalized = tuple(
        _normalized_relative(item, f"{label}.new_proof_paths[{index}]")
        for index, item in enumerate(new_proofs)
    )
    if len(set(old_normalized)) != len(old_normalized):
        raise PreparationError(f"{label}.old_proof_paths contains duplicates")
    if len(set(new_normalized)) != len(new_normalized):
        raise PreparationError(f"{label}.new_proof_paths contains duplicates")
    return ReleaseSpec(
        name=name,
        current_link=_normalized_absolute(value["current_link"], f"{label}.current_link"),
        old_release=_normalized_absolute(value["old_release"], f"{label}.old_release"),
        old_target=_normalized_relative(value["old_target"], f"{label}.old_target"),
        new_release=_normalized_absolute(value["new_release"], f"{label}.new_release"),
        new_target=_normalized_relative(value["new_target"], f"{label}.new_target"),
        old_proof_paths=old_normalized,
        new_proof_paths=new_normalized,
    )


def load_spec(path_value: str | os.PathLike[str]) -> PreparationSpec:
    path = _normalized_absolute(os.fspath(path_value), "spec path")
    _canonical(path, "spec path")
    raw = _read_json(path, "preparation spec")
    if not isinstance(raw, dict):
        raise PreparationError("preparation spec root must be an object")
    _require_exact_keys(
        raw,
        {
            "schema_version",
            "transaction_id",
            "apply_opt_in",
            "output_dir",
            "baseline_registry",
            "baseline_registry_sha256",
            "live_registry",
            "trusted_project",
            "agent_fleet",
            "quota",
            "sealed_adoption",
            "worker_state",
        },
        set(),
        "preparation spec",
    )
    if raw["schema_version"] != SCHEMA_VERSION:
        raise PreparationError(f"unsupported preparation schema: {raw['schema_version']!r}")
    transaction_id = raw["transaction_id"]
    if not isinstance(transaction_id, str) or not SAFE_NAME.fullmatch(transaction_id):
        raise PreparationError("transaction_id must be a safe 1-64 character identifier")
    if raw["apply_opt_in"] is not True:
        raise PreparationError("apply_opt_in must be true for the emitted transaction manifest")

    agent_raw = raw["agent_fleet"]
    if not isinstance(agent_raw, dict):
        raise PreparationError("agent_fleet must be an object")
    _require_exact_keys(
        agent_raw,
        {
            "current_link",
            "old_release",
            "old_target",
            "new_release",
            "new_target",
            "old_proof_paths",
            "new_proof_paths",
            "pythonpath",
            "executable",
            "python_binary",
            "expected_python_version",
            "launcher_module",
            "launcher_source",
            "wheel_metadata",
            "wheel_record",
            "build_provenance",
            "build_manifest",
            "source_commit",
            "expected_version",
            "expected_contract_version",
            "rollback_executable",
            "rollback_pythonpath",
            "rollback_python_version",
            "rollback_source_commit",
            "rollback_version",
            "rollback_contract_version",
            "operator_front_door",
            "candidate_front_door",
            "rollback_front_door",
        },
        set(),
        "agent_fleet",
    )
    agent_release_keys = {
        key: value
        for key, value in agent_raw.items()
        if key
        in {
            "current_link",
            "old_release",
            "old_target",
            "new_release",
            "new_target",
            "old_proof_paths",
            "new_proof_paths",
        }
    }
    agent_version = agent_raw["expected_version"]
    if agent_version != "0.2.0":
        raise PreparationError("agent_fleet.expected_version must be exactly 0.2.0")
    if agent_raw["expected_contract_version"] != 2:
        raise PreparationError("agent_fleet.expected_contract_version must be exactly 2")
    if agent_raw["rollback_version"] != "0.1.5":
        raise PreparationError("agent_fleet.rollback_version must be exactly 0.1.5")
    if agent_raw["rollback_contract_version"] != 1:
        raise PreparationError("agent_fleet.rollback_contract_version must be exactly 1")
    if not isinstance(agent_raw["rollback_python_version"], str) or not re.fullmatch(
        r"3\.11\.[0-9]+", agent_raw["rollback_python_version"]
    ):
        raise PreparationError("agent_fleet.rollback_python_version must be exact Python 3.11")
    for key in ("source_commit", "rollback_source_commit"):
        if not isinstance(agent_raw[key], str) or not GIT_COMMIT.fullmatch(agent_raw[key]):
            raise PreparationError(f"agent_fleet.{key} must be an exact Git commit")
    python_version = agent_raw["expected_python_version"]
    if not isinstance(python_version, str) or not re.fullmatch(
        r"3\.11\.[0-9]+", python_version
    ):
        raise PreparationError("agent_fleet.expected_python_version must be exact Python 3.11")
    agent_fleet = AgentFleetSpec(
        release=_parse_release(agent_release_keys, "agent_fleet", "agent-fleet-current"),
        pythonpath=_normalized_absolute(agent_raw["pythonpath"], "agent_fleet.pythonpath"),
        executable=_normalized_absolute(agent_raw["executable"], "agent_fleet.executable"),
        python_binary=_normalized_absolute(
            agent_raw["python_binary"], "agent_fleet.python_binary"
        ),
        expected_python_version=python_version,
        launcher_module=_normalized_absolute(
            agent_raw["launcher_module"], "agent_fleet.launcher_module"
        ),
        launcher_source=_normalized_absolute(
            agent_raw["launcher_source"], "agent_fleet.launcher_source"
        ),
        wheel_metadata=_normalized_absolute(
            agent_raw["wheel_metadata"], "agent_fleet.wheel_metadata"
        ),
        wheel_record=_normalized_absolute(
            agent_raw["wheel_record"], "agent_fleet.wheel_record"
        ),
        build_provenance=_normalized_absolute(
            agent_raw["build_provenance"], "agent_fleet.build_provenance"
        ),
        build_manifest=_normalized_absolute(
            agent_raw["build_manifest"], "agent_fleet.build_manifest"
        ),
        source_commit=agent_raw["source_commit"],
        expected_version=agent_version,
        expected_contract_version=2,
        rollback_executable=_normalized_absolute(
            agent_raw["rollback_executable"], "agent_fleet.rollback_executable"
        ),
        rollback_pythonpath=_normalized_absolute(
            agent_raw["rollback_pythonpath"], "agent_fleet.rollback_pythonpath"
        ),
        rollback_python_version=agent_raw["rollback_python_version"],
        rollback_source_commit=agent_raw["rollback_source_commit"],
        rollback_version="0.1.5",
        rollback_contract_version=1,
        operator_front_door=_normalized_absolute(
            agent_raw["operator_front_door"],
            "agent_fleet.operator_front_door",
        ),
        candidate_front_door=_normalized_absolute(
            agent_raw["candidate_front_door"],
            "agent_fleet.candidate_front_door",
        ),
        rollback_front_door=_normalized_absolute(
            agent_raw["rollback_front_door"],
            "agent_fleet.rollback_front_door",
        ),
    )

    quota_raw = raw["quota"]
    if not isinstance(quota_raw, dict):
        raise PreparationError("quota must be an object")
    _require_exact_keys(
        quota_raw,
        {
            "current_link",
            "old_release",
            "old_target",
            "new_release",
            "new_target",
            "old_proof_paths",
            "new_proof_paths",
            "binary",
            "node_binary",
            "entrypoint",
            "launcher_source",
            "build_provenance",
            "runtime_manifest",
            "node_version",
            "package_json",
            "package_lock",
            "expected_package_name",
            "expected_version",
            "source_commit",
            "rollback_binary",
            "rollback_node_binary",
            "rollback_entrypoint",
            "rollback_launcher_source",
            "rollback_build_provenance",
            "rollback_runtime_manifest",
            "rollback_package_json",
            "rollback_package_lock",
            "rollback_node_version",
            "rollback_version",
            "rollback_source_commit",
            "legacy_registry_binary",
            "release_tree_sha256",
        },
        set(),
        "quota",
    )
    quota_release_keys = {
        key: value
        for key, value in quota_raw.items()
        if key
        in {
            "current_link",
            "old_release",
            "old_target",
            "new_release",
            "new_target",
            "old_proof_paths",
            "new_proof_paths",
        }
    }
    package_name = quota_raw["expected_package_name"]
    quota_version = quota_raw["expected_version"]
    node_version = quota_raw["node_version"]
    baseline_digest = raw["baseline_registry_sha256"]
    if package_name != "quota-axi":
        raise PreparationError("quota.expected_package_name must be exactly 'quota-axi'")
    if quota_version != QUOTA_CANDIDATE_VERSION:
        raise PreparationError(
            f"quota.expected_version must be exactly {QUOTA_CANDIDATE_VERSION}"
        )
    if not isinstance(node_version, str) or not VERSION.fullmatch(node_version):
        raise PreparationError("quota.node_version is invalid")
    if quota_raw["rollback_version"] != "0.1.5":
        raise PreparationError("quota.rollback_version must be exactly 0.1.5")
    if not isinstance(quota_raw["rollback_node_version"], str) or not VERSION.fullmatch(
        quota_raw["rollback_node_version"]
    ):
        raise PreparationError("quota.rollback_node_version is invalid")
    for key in ("source_commit", "rollback_source_commit"):
        if not isinstance(quota_raw[key], str) or not GIT_COMMIT.fullmatch(quota_raw[key]):
            raise PreparationError(f"quota.{key} must be an exact Git commit")
    if not isinstance(baseline_digest, str) or not SHA256.fullmatch(baseline_digest):
        raise PreparationError("baseline_registry_sha256 must be a lowercase SHA-256 digest")
    quota_tree_digest = quota_raw["release_tree_sha256"]
    if not isinstance(quota_tree_digest, str) or not SHA256.fullmatch(quota_tree_digest):
        raise PreparationError("quota.release_tree_sha256 must be a lowercase SHA-256 digest")
    quota = QuotaSpec(
        release=_parse_release(quota_release_keys, "quota", "quota-current"),
        binary=_normalized_absolute(quota_raw["binary"], "quota.binary"),
        node_binary=_normalized_absolute(quota_raw["node_binary"], "quota.node_binary"),
        entrypoint=_normalized_absolute(quota_raw["entrypoint"], "quota.entrypoint"),
        launcher_source=_normalized_absolute(
            quota_raw["launcher_source"], "quota.launcher_source"
        ),
        build_provenance=_normalized_absolute(
            quota_raw["build_provenance"], "quota.build_provenance"
        ),
        runtime_manifest=_normalized_absolute(
            quota_raw["runtime_manifest"], "quota.runtime_manifest"
        ),
        node_version=node_version,
        package_json=_normalized_absolute(quota_raw["package_json"], "quota.package_json"),
        package_lock=_normalized_absolute(quota_raw["package_lock"], "quota.package_lock"),
        expected_package_name=package_name,
        expected_version=quota_version,
        source_commit=quota_raw["source_commit"],
        rollback_binary=_normalized_absolute(
            quota_raw["rollback_binary"], "quota.rollback_binary"
        ),
        rollback_node_binary=_normalized_absolute(
            quota_raw["rollback_node_binary"], "quota.rollback_node_binary"
        ),
        rollback_entrypoint=_normalized_absolute(
            quota_raw["rollback_entrypoint"], "quota.rollback_entrypoint"
        ),
        rollback_launcher_source=_normalized_absolute(
            quota_raw["rollback_launcher_source"], "quota.rollback_launcher_source"
        ),
        rollback_build_provenance=_normalized_absolute(
            quota_raw["rollback_build_provenance"],
            "quota.rollback_build_provenance",
        ),
        rollback_runtime_manifest=_normalized_absolute(
            quota_raw["rollback_runtime_manifest"],
            "quota.rollback_runtime_manifest",
        ),
        rollback_package_json=_normalized_absolute(
            quota_raw["rollback_package_json"], "quota.rollback_package_json"
        ),
        rollback_package_lock=_normalized_absolute(
            quota_raw["rollback_package_lock"], "quota.rollback_package_lock"
        ),
        rollback_node_version=quota_raw["rollback_node_version"],
        rollback_version="0.1.5",
        rollback_source_commit=quota_raw["rollback_source_commit"],
        legacy_registry_binary=_normalized_absolute(
            quota_raw["legacy_registry_binary"], "quota.legacy_registry_binary"
        ),
        release_tree_sha256=quota_tree_digest,
    )
    adoption_raw = raw["sealed_adoption"]
    if not isinstance(adoption_raw, dict):
        raise PreparationError("sealed_adoption must be an object")
    _require_exact_keys(
        adoption_raw,
        {
            "agent_fleet_initial_target",
            "agent_fleet_front_door_initial_target",
            "quota_initial_target",
            "routing_absent_paths",
            "backend_path",
            "backend_sha256",
            "state_quiet_paths",
            "forbidden_process_tokens",
            "ps_binary",
            "ps_binary_sha256",
        },
        set(),
        "sealed_adoption",
    )
    routing_values = adoption_raw["routing_absent_paths"]
    state_values = adoption_raw["state_quiet_paths"]
    token_values = adoption_raw["forbidden_process_tokens"]
    if not isinstance(routing_values, list) or not routing_values:
        raise PreparationError("sealed_adoption.routing_absent_paths must be non-empty")
    if not isinstance(state_values, list) or not state_values:
        raise PreparationError("sealed_adoption.state_quiet_paths must be non-empty")
    if (
        not isinstance(token_values, list)
        or not token_values
        or not all(
            isinstance(token, str)
            and token.startswith("/")
            and len(token) > 1
            and "\x00" not in token
            and "$" not in token
            for token in token_values
        )
        or len(token_values) != len(set(token_values))
    ):
        raise PreparationError(
            "sealed_adoption.forbidden_process_tokens must be unique absolute tokens"
        )
    routing_paths = tuple(
        _normalized_absolute(value, f"sealed_adoption.routing_absent_paths[{index}]")
        for index, value in enumerate(routing_values)
    )
    state_paths = tuple(
        _normalized_absolute(value, f"sealed_adoption.state_quiet_paths[{index}]")
        for index, value in enumerate(state_values)
    )
    if len(set(routing_paths)) != len(routing_paths):
        raise PreparationError("sealed_adoption.routing_absent_paths contains duplicates")
    if len(set(state_paths)) != len(state_paths):
        raise PreparationError("sealed_adoption.state_quiet_paths contains duplicates")
    backend_digest = adoption_raw["backend_sha256"]
    ps_digest = adoption_raw["ps_binary_sha256"]
    if not isinstance(backend_digest, str) or not SHA256.fullmatch(backend_digest):
        raise PreparationError("sealed_adoption.backend_sha256 is invalid")
    if not isinstance(ps_digest, str) or not SHA256.fullmatch(ps_digest):
        raise PreparationError("sealed_adoption.ps_binary_sha256 is invalid")
    sealed_adoption = SealedAdoptionSpec(
        agent_fleet_initial_target=_normalized_relative(
            adoption_raw["agent_fleet_initial_target"],
            "sealed_adoption.agent_fleet_initial_target",
        ),
        agent_fleet_front_door_initial_target=_normalized_symlink_payload(
            adoption_raw["agent_fleet_front_door_initial_target"],
            "sealed_adoption.agent_fleet_front_door_initial_target",
        ),
        quota_initial_target=_normalized_relative(
            adoption_raw["quota_initial_target"],
            "sealed_adoption.quota_initial_target",
        ),
        routing_absent_paths=routing_paths,
        backend_path=_normalized_absolute(
            adoption_raw["backend_path"], "sealed_adoption.backend_path"
        ),
        backend_sha256=backend_digest,
        state_quiet_paths=state_paths,
        forbidden_process_tokens=tuple(token_values),
        ps_binary=_normalized_absolute(
            adoption_raw["ps_binary"], "sealed_adoption.ps_binary"
        ),
        ps_binary_sha256=ps_digest,
    )
    worker_state_raw = raw["worker_state"]
    if not isinstance(worker_state_raw, dict):
        raise PreparationError("worker_state must be an object")
    _require_exact_keys(
        worker_state_raw,
        {"snapshot_parent"},
        set(),
        "worker_state",
    )
    worker_state = WorkerStateSpec(
        snapshot_parent=_normalized_absolute(
            worker_state_raw["snapshot_parent"], "worker_state.snapshot_parent"
        )
    )
    return PreparationSpec(
        source_path=path,
        transaction_id=transaction_id,
        apply_opt_in=True,
        output_dir=_normalized_absolute(raw["output_dir"], "output_dir"),
        baseline_registry=_normalized_absolute(
            raw["baseline_registry"], "baseline_registry"
        ),
        baseline_registry_sha256=baseline_digest,
        live_registry=_normalized_absolute(raw["live_registry"], "live_registry"),
        trusted_project=_normalized_absolute(raw["trusted_project"], "trusted_project"),
        agent_fleet=agent_fleet,
        quota=quota,
        sealed_adoption=sealed_adoption,
        worker_state=worker_state,
        raw=raw,
    )


def _load_module(path: Path, name_prefix: str) -> ModuleType:
    alias = f"_{name_prefix}_{hashlib.sha256(str(path).encode()).hexdigest()[:16]}"
    package_dir = path / "agent_fleet"
    init = package_dir / "__init__.py"
    _require_directory(path, "Agent Fleet pythonpath")
    _require_directory(package_dir, "Agent Fleet package")
    _require_regular(init, "Agent Fleet package initializer")
    spec = importlib.util.spec_from_file_location(
        alias, init, submodule_search_locations=[str(package_dir)]
    )
    if spec is None or spec.loader is None:
        raise PreparationError(f"cannot load exact Agent Fleet package: {package_dir}")
    for key in tuple(sys.modules):
        if key == alias or key.startswith(f"{alias}."):
            del sys.modules[key]
    module = importlib.util.module_from_spec(spec)
    sys.modules[alias] = module
    old_dont_write = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec.loader.exec_module(module)
    except Exception as exc:
        raise PreparationError(f"cannot import exact Agent Fleet package: {exc}") from exc
    finally:
        sys.dont_write_bytecode = old_dont_write
    return module


def load_agent_fleet_api(
    pythonpath: Path,
    release_root: Path,
    expected_version: str,
    label: str,
    *,
    require_provision_api: bool = False,
) -> AgentFleetAPI:
    package = _load_module(pythonpath, f"bridge_{label.replace(' ', '_')}")
    alias = package.__name__
    old_dont_write = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        config = importlib.import_module(f"{alias}.config")
        models = importlib.import_module(f"{alias}.models")
        provision = (
            importlib.import_module(f"{alias}.provision")
            if require_provision_api
            else None
        )
        identity = (
            importlib.import_module(f"{alias}.identity")
            if require_provision_api
            else None
        )
    except Exception as exc:
        raise PreparationError(f"cannot import Agent Fleet config API: {exc}") from exc
    finally:
        sys.dont_write_bytecode = old_dont_write
    observed = getattr(package, "__version__", None)
    if observed != expected_version:
        raise PreparationError(
            f"{label} package version is {observed!r}; expected {expected_version!r}"
        )
    api_modules: list[tuple[ModuleType, str]] = [
        (package, "package"),
        (config, "config"),
        (models, "models"),
    ]
    if provision is not None:
        api_modules.append((provision, "provision"))
    if identity is not None:
        api_modules.append((identity, "identity"))
    for module, module_label in api_modules:
        module_file = Path(getattr(module, "__file__", ""))
        _require_regular(module_file, f"{label} {module_label} module")
        _require_within(module_file, release_root, f"{label} {module_label} module")
    for required in ("load_registry", "save_registry"):
        if not callable(getattr(config, required, None)):
            raise PreparationError(f"exact Agent Fleet config API lacks {required}()")
    if provision is not None:
        for required in (
            "closed_claude_state_payload",
            "provision_plan",
            "verify_provisioned_profile",
        ):
            if not callable(getattr(provision, required, None)):
                raise PreparationError(
                    f"exact Agent Fleet provision API lacks {required}()"
                )
    if identity is not None:
        for required in ("identity_bundle_path", "verify_identity_bundle"):
            if not callable(getattr(identity, required, None)):
                raise PreparationError(
                    f"exact Agent Fleet identity API lacks {required}()"
                )
    return AgentFleetAPI(
        package=package,
        config=config,
        models=models,
        provision=provision,
        identity=identity,
    )


def _load_driver(path: Path) -> ModuleType:
    _require_regular(path, "cutover transaction driver")
    alias = f"_bridge_cutover_driver_{hashlib.sha256(str(path).encode()).hexdigest()[:16]}"
    spec = importlib.util.spec_from_file_location(alias, path)
    if spec is None or spec.loader is None:
        raise PreparationError(f"cannot load transaction driver: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[alias] = module
    try:
        spec.loader.exec_module(module)
    except Exception as exc:
        raise PreparationError(f"cannot import transaction driver: {exc}") from exc
    for required in (
        "compute_release_proof",
        "compute_release_tree_sha256",
        "load_manifest",
        "plan",
        "execute",
        "mark_post_install_irreversible_boundary",
        "BoundaryController",
        "InjectedFailure",
        "CutoverError",
    ):
        if not hasattr(module, required):
            raise PreparationError(f"transaction driver lacks {required}")
    return module


def _load_adoption_driver() -> ModuleType:
    path = Path(__file__).with_name("bridge_sealed_adoption.py")
    _require_regular(path, "sealed-adoption driver")
    alias = f"_bridge_sealed_adoption_{hashlib.sha256(str(path).encode()).hexdigest()[:16]}"
    module_spec = importlib.util.spec_from_file_location(alias, path)
    if module_spec is None or module_spec.loader is None:
        raise PreparationError(f"cannot load sealed-adoption driver: {path}")
    module = importlib.util.module_from_spec(module_spec)
    sys.modules[alias] = module
    try:
        module_spec.loader.exec_module(module)
    except Exception as exc:
        raise PreparationError(f"cannot import sealed-adoption driver: {exc}") from exc
    for required in (
        "load_manifest",
        "plan",
        "apply",
        "recover",
        "BoundaryController",
        "InjectedFailure",
        "AdoptionError",
    ):
        if not hasattr(module, required):
            raise PreparationError(f"sealed-adoption driver lacks {required}")
    return module


def _load_worker_state_driver() -> ModuleType:
    path = Path(__file__).with_name("bridge_worker_state_transaction.py")
    _require_regular(path, "worker-state transaction driver")
    alias = f"_bridge_worker_state_{hashlib.sha256(str(path).encode()).hexdigest()[:16]}"
    module_spec = importlib.util.spec_from_file_location(alias, path)
    if module_spec is None or module_spec.loader is None:
        raise PreparationError(f"cannot load worker-state transaction driver: {path}")
    module = importlib.util.module_from_spec(module_spec)
    sys.modules[alias] = module
    try:
        module_spec.loader.exec_module(module)
    except Exception as exc:
        raise PreparationError(f"cannot import worker-state driver: {exc}") from exc
    for required in ("load_manifest", "plan", "WorkerStateError"):
        if not hasattr(module, required):
            raise PreparationError(f"worker-state driver lacks {required}")
    return module


def _parse_registry_toml(path: Path, label: str) -> dict[str, Any]:
    _require_regular(path, label, mode=0o600)
    if path.stat().st_size > MAX_REGISTRY_BYTES:
        raise PreparationError(f"{label} exceeds {MAX_REGISTRY_BYTES} bytes")
    try:
        raw = tomllib.loads(path.read_text(encoding="utf-8"))
    except (UnicodeDecodeError, tomllib.TOMLDecodeError) as exc:
        raise PreparationError(f"{label} is not valid UTF-8 TOML: {exc}") from exc
    if set(raw) != REGISTRY_TOP_KEYS:
        raise PreparationError(
            f"{label} top-level keys are not the exact registry contract: {sorted(raw)}"
        )
    settings = raw.get("settings")
    providers = raw.get("providers")
    profiles = raw.get("profiles")
    if not isinstance(settings, dict) or not set(settings).issubset(SETTINGS_KEYS):
        raise PreparationError(f"{label} has unknown settings fields")
    for key in ("state_dir", "share_dir", "quota_binary", "quota_node_binary"):
        if key in settings:
            _normalized_absolute(settings[key], f"{label}.settings.{key}")
    if not isinstance(providers, dict) or set(providers) != {"claude", "codex"}:
        raise PreparationError(f"{label} must contain exactly claude and codex providers")
    for provider, value in providers.items():
        if not isinstance(value, dict) or not set(value).issubset(PROVIDER_KEYS):
            raise PreparationError(f"{label} provider {provider} has unknown fields")
        for key in ("binary", "base_home", "hooks_source", "desktop_identity_file"):
            if key in value and value[key] is not False:
                _normalized_absolute(value[key], f"{label}.providers.{provider}.{key}")
        projects = value.get("trusted_projects", [])
        if not isinstance(projects, list):
            raise PreparationError(f"{label} provider {provider} projects are invalid")
        for index, project in enumerate(projects):
            _normalized_absolute(
                project,
                f"{label}.providers.{provider}.trusted_projects[{index}]",
            )
    if not isinstance(profiles, dict) or set(profiles) != set(EXPECTED_TOPOLOGY):
        raise PreparationError(f"{label} must contain exactly the eight expected profiles")
    for profile_id, value in profiles.items():
        if not isinstance(value, dict) or not set(value).issubset(PROFILE_KEYS):
            raise PreparationError(f"{label} profile {profile_id} has unknown fields")
        _normalized_absolute(value.get("home"), f"{label}.profiles.{profile_id}.home")
    return raw


def _normalized_registry_raw(raw: Mapping[str, Any], label: str) -> dict[str, Any]:
    """Lexically normalize registry paths without resolving or touching homes."""

    normalized = copy.deepcopy(dict(raw))
    settings = normalized["settings"]
    for key in ("state_dir", "share_dir", "quota_binary", "quota_node_binary"):
        if key in settings:
            settings[key] = str(
                _normalized_absolute(settings[key], f"{label}.settings.{key}")
            )
    for provider_name, provider in normalized["providers"].items():
        for key in ("binary", "base_home", "hooks_source", "desktop_identity_file"):
            if key in provider and provider[key] is not False:
                provider[key] = str(
                    _normalized_absolute(
                        provider[key], f"{label}.providers.{provider_name}.{key}"
                    )
                )
        provider["trusted_projects"] = [
            str(
                _normalized_absolute(
                    project,
                    f"{label}.providers.{provider_name}.trusted_projects[{index}]",
                )
            )
            for index, project in enumerate(provider.get("trusted_projects", []))
        ]
    for profile_id, profile in normalized["profiles"].items():
        profile["home"] = str(
            _normalized_absolute(
                profile["home"], f"{label}.profiles.{profile_id}.home"
            )
        )
    return normalized


def _toml_value(value: Any, label: str) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int) and not isinstance(value, bool):
        return str(value)
    if isinstance(value, (str, Path)):
        return json.dumps(str(value))
    if isinstance(value, (list, tuple)):
        return "[" + ", ".join(
            _toml_value(item, f"{label}[{index}]")
            for index, item in enumerate(value)
        ) + "]"
    raise PreparationError(f"{label} has an unsupported TOML value: {type(value)!r}")


def _write_registry_toml(path: Path, raw: Mapping[str, Any]) -> None:
    settings_order = (
        "state_dir",
        "share_dir",
        "quota_binary",
        "quota_binary_sha256",
        "quota_node_binary",
        "quota_node_sha256",
        "quota_release_tree_sha256",
        "quota_stale_seconds",
        "quota_verification_grace_seconds",
        "lease_grace_seconds",
        "active_lease_penalty",
        "lock_stale_seconds",
    )
    provider_order = (
        "binary",
        "base_home",
        "hooks_source",
        "desktop_identity_file",
        "shared_entries",
        "trusted_projects",
    )
    profile_order = (
        "provider",
        "home",
        "pools",
        "enabled",
        "weight",
        "max_concurrent",
        "reserve_percent",
        "safety_policy",
    )
    lines = [f"version = {_toml_value(raw['version'], 'version')}", "", "[settings]"]
    settings = raw["settings"]
    if set(settings) - set(settings_order):
        raise PreparationError("registry settings cannot be serialized exactly")
    lines.extend(
        f"{key} = {_toml_value(settings[key], f'settings.{key}')}"
        for key in settings_order
        if key in settings
    )
    for provider_name in ("claude", "codex"):
        provider = raw["providers"][provider_name]
        if set(provider) - set(provider_order):
            raise PreparationError(f"provider {provider_name} cannot be serialized exactly")
        lines.extend(("", f"[providers.{provider_name}]"))
        lines.extend(
            f"{key} = {_toml_value(provider[key], f'providers.{provider_name}.{key}')}"
            for key in provider_order
            if key in provider
        )
    for profile_id in sorted(raw["profiles"]):
        profile = raw["profiles"][profile_id]
        if set(profile) - set(profile_order):
            raise PreparationError(f"profile {profile_id} cannot be serialized exactly")
        lines.extend(("", f"[profiles.{json.dumps(profile_id)}]"))
        lines.extend(
            f"{key} = {_toml_value(profile[key], f'profiles.{profile_id}.{key}')}"
            for key in profile_order
            if key in profile
        )
    _write_bytes(path, ("\n".join(lines) + "\n").encode("utf-8"), 0o600)


def _construct_sealed_baseline_raw(
    baseline_raw: Mapping[str, Any], spec: PreparationSpec
) -> dict[str, Any]:
    sealed = _normalized_registry_raw(baseline_raw, "sealed rollback registry")
    sealed["settings"]["quota_binary"] = str(_sealed_quota_binary(spec))
    for provider in sealed["providers"].values():
        provider.pop("hooks_source", None)
    return sealed


def _construct_candidate_raw(
    sealed_raw: Mapping[str, Any], spec: PreparationSpec
) -> dict[str, Any]:
    candidate = copy.deepcopy(dict(sealed_raw))
    settings = candidate["settings"]
    settings.update(
        {
            "quota_binary": str(spec.quota.binary),
            "quota_node_binary": str(spec.quota.node_binary),
            "quota_binary_sha256": _sha256(spec.quota.binary),
            "quota_node_sha256": _sha256(spec.quota.node_binary),
            "quota_release_tree_sha256": spec.quota.release_tree_sha256,
        }
    )
    for provider_name, provider in candidate["providers"].items():
        provider.pop("hooks_source", None)
        provider["shared_entries"] = [
            entry for entry in provider["shared_entries"] if entry != "plugins"
        ]
        provider["trusted_projects"] = [str(spec.trusted_project)]
        if provider_name == "claude" and provider.get("desktop_identity_file") is False:
            provider["desktop_identity_file"] = False
    for profile_id, (_, pools, policy) in EXPECTED_TOPOLOGY.items():
        profile = candidate["profiles"][profile_id]
        profile["pools"] = list(pools)
        profile["enabled"] = False
        profile["safety_policy"] = policy
    return candidate


def _semantic_validate_candidate_raw(
    sealed: Mapping[str, Any],
    candidate: Mapping[str, Any],
    spec: PreparationSpec,
) -> None:
    expected = _construct_candidate_raw(sealed, spec)
    if set(candidate) != set(expected):
        raise PreparationError("candidate registry top-level fields are not exact")
    for key, value in candidate["settings"].items():
        if key not in expected["settings"] or value != expected["settings"][key]:
            raise PreparationError(f"unallowlisted settings field changed: {key}")
    if set(candidate["settings"]) != set(expected["settings"]):
        raise PreparationError("candidate settings fields are not exact")
    for provider_name in ("claude", "codex"):
        before = sealed["providers"][provider_name]
        after = candidate["providers"][provider_name]
        expected_provider = expected["providers"][provider_name]
        if after.get("hooks_source") is not None:
            raise PreparationError(
                f"provider {provider_name} must not inherit mutable hooks"
            )
        if after.get("trusted_projects") != [str(spec.trusted_project)]:
            raise PreparationError(
                f"provider {provider_name} must trust exactly the Relvino project"
            )
        if "plugins" in after.get("shared_entries", []):
            raise PreparationError(
                f"provider {provider_name} plugin sharing was not removed exactly"
            )
        if after != expected_provider:
            changed = sorted(
                key
                for key in set(after) | set(expected_provider)
                if after.get(key) != expected_provider.get(key)
            )
            raise PreparationError(
                f"unallowlisted provider field changed: {provider_name}."
                + ",".join(changed)
            )
        if before.get("shared_entries") == after.get("shared_entries") and "plugins" in before.get(
            "shared_entries", []
        ):
            raise PreparationError(
                f"provider {provider_name} plugin sharing was not removed exactly"
            )
    if set(candidate["profiles"]) != set(EXPECTED_TOPOLOGY):
        raise PreparationError("candidate profiles are not the exact topology")
    for profile_id, (_, pools, policy) in EXPECTED_TOPOLOGY.items():
        after = candidate["profiles"][profile_id]
        expected_profile = expected["profiles"][profile_id]
        if after.get("enabled") is not False:
            raise PreparationError(f"profile {profile_id} is not disabled")
        if after.get("pools") != list(pools):
            raise PreparationError(f"profile {profile_id} pools are not exact")
        if after.get("safety_policy") != policy:
            raise PreparationError(f"profile {profile_id} policy is not exact")
        if after != expected_profile:
            raise PreparationError(
                f"unallowlisted profile field changed: {profile_id}"
            )


def _dataclass_from_mapping(
    target: type[Any],
    values: Mapping[str, Any],
    overrides: Mapping[str, Any],
    label: str,
) -> Any:
    if not dataclasses.is_dataclass(target):
        raise PreparationError(f"{label} target is not a dataclass")
    fields = {field.name: field for field in dataclasses.fields(target)}
    unknown = set(values) - set(fields)
    if unknown:
        raise PreparationError(
            f"{label} has fields absent from candidate schema: {', '.join(sorted(unknown))}"
        )
    unknown_overrides = set(overrides) - set(fields)
    if unknown_overrides:
        raise PreparationError(
            f"{label} candidate schema lacks: {', '.join(sorted(unknown_overrides))}"
        )
    arguments: dict[str, Any] = {}
    for name, field in fields.items():
        if name in overrides:
            arguments[name] = overrides[name]
        elif name in values:
            arguments[name] = values[name]
        elif field.default is not dataclasses.MISSING:
            arguments[name] = field.default
        elif field.default_factory is not dataclasses.MISSING:  # type: ignore[comparison-overlap]
            arguments[name] = field.default_factory()
        else:
            raise PreparationError(f"{label} is missing required field: {name}")
    try:
        return target(**arguments)
    except Exception as exc:
        raise PreparationError(f"cannot construct lexical {label}: {exc}") from exc


def _lexical_candidate_registry(
    api: AgentFleetAPI,
    raw: Mapping[str, Any],
    config_path: Path,
) -> Any:
    """Construct the v2 model without resolving, statting, or opening any home.

    config_path must name the live registry: the sealed provision API composes
    managed hook commands from it, and the recorded plans must byte-match what
    post-cutover provisioning produces against that exact live path.
    """

    settings_raw = raw["settings"]
    settings_values = dict(settings_raw)
    for key in ("state_dir", "share_dir", "quota_binary", "quota_node_binary"):
        settings_values[key] = _normalized_absolute(
            settings_values[key], f"candidate settings.{key}"
        )
    settings = _dataclass_from_mapping(
        api.models.Settings, settings_values, {}, "candidate settings"
    )
    providers: dict[str, Any] = {}
    for provider_name in ("claude", "codex"):
        provider_raw = raw["providers"][provider_name]
        provider_values = dict(provider_raw)
        provider_values["binary"] = _normalized_absolute(
            provider_values["binary"], f"candidate provider {provider_name}.binary"
        )
        for key in ("base_home", "hooks_source", "desktop_identity_file"):
            value = provider_values.get(key)
            provider_values[key] = (
                None
                if value is None or value is False
                else _normalized_absolute(
                    value, f"candidate provider {provider_name}.{key}"
                )
            )
        provider_values["shared_entries"] = tuple(provider_values["shared_entries"])
        provider_values["trusted_projects"] = tuple(
            _normalized_absolute(
                value, f"candidate provider {provider_name}.trusted_projects"
            )
            for value in provider_values["trusted_projects"]
        )
        providers[provider_name] = _dataclass_from_mapping(
            api.models.ProviderConfig,
            provider_values,
            {"name": provider_name},
            f"candidate provider {provider_name}",
        )
    profiles: dict[str, Any] = {}
    for profile_id in sorted(raw["profiles"]):
        profile_values = dict(raw["profiles"][profile_id])
        profile_values["home"] = _normalized_absolute(
            profile_values["home"], f"candidate profile {profile_id}.home"
        )
        profile_values["pools"] = tuple(profile_values["pools"])
        profiles[profile_id] = _dataclass_from_mapping(
            api.models.Profile,
            profile_values,
            {"id": profile_id},
            f"candidate profile {profile_id}",
        )
    return _dataclass_from_mapping(
        api.models.Registry,
        {"version": raw["version"]},
        {
            "settings": settings,
            "providers": providers,
            "profiles": profiles,
            "config_path": config_path,
        },
        "candidate registry",
    )


def _validate_legacy_registry_shape(
    raw: Mapping[str, Any], spec: PreparationSpec
) -> None:
    if raw.get("version") != 1:
        raise PreparationError("legacy baseline registry version must be exactly 1")
    settings = raw["settings"]
    expected_legacy_settings = SETTINGS_KEYS - {
        "quota_node_binary",
        "quota_binary_sha256",
        "quota_node_sha256",
        "quota_release_tree_sha256",
    }
    if set(settings) != expected_legacy_settings:
        raise PreparationError("legacy baseline settings fields are not exact")
    forbidden_new = {
        "quota_node_binary",
        "quota_binary_sha256",
        "quota_node_sha256",
    }
    present_new = forbidden_new & set(settings)
    if present_new:
        raise PreparationError(
            "legacy baseline unexpectedly contains new Quota identity fields: "
            + ", ".join(sorted(present_new))
        )
    if _normalized_absolute(
        settings.get("quota_binary"), "legacy baseline quota_binary"
    ) != spec.quota.legacy_registry_binary:
        raise PreparationError(
            "legacy baseline quota_binary is not the exact allowlisted old-release path"
        )
    providers = raw["providers"]
    for provider_name in ("claude", "codex"):
        required_provider = {
            "binary",
            "base_home",
            "hooks_source",
            "shared_entries",
            "trusted_projects",
        }
        optional_provider = {"desktop_identity_file"}
        if not required_provider.issubset(providers[provider_name]) or not set(
            providers[provider_name]
        ).issubset(required_provider | optional_provider):
            raise PreparationError(
                f"legacy baseline provider {provider_name} fields are not exact"
            )
        projects = providers[provider_name].get("trusted_projects", [])
        normalized_projects = [
            _normalized_absolute(project, f"legacy {provider_name} project")
            for project in projects
        ]
        if normalized_projects not in ([], [spec.trusted_project]):
            raise PreparationError(
                f"legacy baseline provider {provider_name} has unallowlisted projects"
            )
        shared = providers[provider_name].get("shared_entries", [])
        if (
            not isinstance(shared, list)
            or not all(isinstance(item, str) for item in shared)
            or len(shared) != len(set(shared))
        ):
            raise PreparationError(
                f"legacy baseline provider {provider_name} shared_entries are invalid"
            )
        allowed_shared = (
            {"CLAUDE.md", "skills", "plugins"}
            if provider_name == "claude"
            else {"AGENTS.md", "rules", "skills", "plugins"}
        )
        for index, item in enumerate(shared):
            _normalized_relative(
                item,
                f"legacy baseline provider {provider_name}.shared_entries[{index}]",
            )
        if not set(shared).issubset(allowed_shared):
            raise PreparationError(
                f"legacy baseline provider {provider_name} shared_entries are not allowlisted"
            )
        if any(Path(item).parts[:1] == ("plugins",) and item != "plugins" for item in shared):
            raise PreparationError(
                f"legacy baseline provider {provider_name} has an unexpected plugin subpath"
            )
    for profile_id, (provider, pools, policy) in EXPECTED_TOPOLOGY.items():
        profile = raw["profiles"][profile_id]
        if set(profile) != PROFILE_KEYS:
            raise PreparationError(
                f"legacy baseline profile fields are not exact for {profile_id}"
            )
        if profile.get("provider") != provider:
            raise PreparationError(f"legacy baseline provider mismatch for {profile_id}")
        if profile.get("enabled", False) is not False:
            raise PreparationError(f"legacy baseline profile is enabled: {profile_id}")
        if profile.get("pools") != list(pools):
            raise PreparationError(f"legacy baseline pools mismatch for {profile_id}")
        if profile.get("safety_policy") != policy:
            raise PreparationError(
                f"legacy baseline safety_policy mismatch for {profile_id}"
            )
    worker_homes = {
        profile_id: _normalized_absolute(
            raw["profiles"][profile_id]["home"],
            f"legacy baseline profile {profile_id}.home",
        )
        for profile_id in WORKER_PROFILES
    }
    identity_state = _normalized_absolute(
        settings["state_dir"], "legacy baseline identity state directory"
    )
    snapshot_parent = spec.worker_state.snapshot_parent
    for reserve_id in RESERVE_PROFILES:
        reserve_home = _normalized_absolute(
            raw["profiles"][reserve_id]["home"],
            f"legacy baseline profile {reserve_id}.home",
        )
        protected = {
            **worker_homes,
            "identity-state": identity_state,
            "worker-snapshot-parent": snapshot_parent,
        }
        for protected_id, protected_path in protected.items():
            if (
                reserve_home == protected_path
                or _is_relative_to(reserve_home, protected_path)
                or _is_relative_to(protected_path, reserve_home)
            ):
                raise PreparationError(
                    f"reserve profile {reserve_id} home overlaps {protected_id}"
                )


def _validate_release_spec(
    release: ReleaseSpec,
    expected_current_targets: Sequence[str] | None = None,
) -> None:
    _require_directory(release.current_link.parent, f"{release.name} link parent")
    _require_directory(release.old_release, f"{release.name} old release")
    _require_directory(release.new_release, f"{release.name} new release")
    _require_release_single_links(release.old_release, f"{release.name} old release")
    _require_release_single_links(release.new_release, f"{release.name} new release")
    if release.old_release == release.new_release:
        raise PreparationError(f"{release.name} old and new releases must differ")
    try:
        link_info = os.lstat(release.current_link)
    except FileNotFoundError as exc:
        raise PreparationError(f"{release.name} current link is missing") from exc
    if not stat.S_ISLNK(link_info.st_mode):
        raise PreparationError(f"{release.name} current path must be a symlink")
    observed = os.readlink(release.current_link)
    accepted_targets = tuple(expected_current_targets or (release.old_target,))
    if observed not in accepted_targets:
        raise PreparationError(
            f"{release.name} raw current target is {observed!r}; "
            f"expected one of {accepted_targets!r}"
        )
    old_resolved = Path(os.path.normpath(release.current_link.parent / release.old_target))
    new_resolved = Path(os.path.normpath(release.current_link.parent / release.new_target))
    if old_resolved != release.old_release:
        raise PreparationError(f"{release.name} old target does not resolve to old_release")
    if new_resolved != release.new_release:
        raise PreparationError(f"{release.name} new target does not resolve to new_release")
    for proof in release.old_proof_paths:
        _require_regular(release.old_release / proof, f"{release.name} old proof {proof}")
    for proof in release.new_proof_paths:
        _require_regular(release.new_release / proof, f"{release.name} new proof {proof}")


def _initial_release_path(release: ReleaseSpec, target: str) -> Path:
    return Path(os.path.normpath(release.current_link.parent / target))


def _require_release_single_links(root: Path, label: str) -> None:
    for directory, names, files in os.walk(root, followlinks=False):
        base = Path(directory)
        for name in (*names, *files):
            path = base / name
            info = os.lstat(path)
            if stat.S_ISREG(info.st_mode) and info.st_nlink != 1:
                raise PreparationError(
                    f"{label} contains a regular file with multiple hard links: {path}"
                )


def _expected_agent_fleet_module() -> bytes:
    return (
        "from pathlib import Path\n"
        "import runpy\n"
        "import sys\n"
        "ROOT = Path(__file__).resolve().parent\n"
        'sys.path.insert(0, str(ROOT / "site-packages"))\n'
        'runpy.run_module("agent_fleet", run_name="__main__", alter_sys=True)\n'
    ).encode("utf-8")


def _require_native_macho(path: Path, label: str) -> None:
    magic = path.read_bytes()[:4]
    macho_magics = {
        b"\xcf\xfa\xed\xfe",
        b"\xfe\xed\xfa\xcf",
        b"\xca\xfe\xba\xbe",
        b"\xbe\xba\xfe\xca",
        b"\xca\xfe\xba\xbf",
        b"\xbf\xba\xfe\xca",
    }
    if magic not in macho_magics:
        raise PreparationError(f"{label} must be a native Mach-O binary")


def _validate_installed_wheel_record(
    pythonpath: Path,
    version: str,
    *,
    require_provision: bool,
    label: str,
) -> None:
    dist_info = pythonpath / f"agent_fleet-{version}.dist-info"
    metadata_path = dist_info / "METADATA"
    record_path = dist_info / "RECORD"
    _require_regular(metadata_path, f"{label} wheel METADATA")
    _require_regular(record_path, f"{label} wheel RECORD")
    metadata_lines = metadata_path.read_text(encoding="utf-8").splitlines()
    metadata: dict[str, list[str]] = {}
    for line in metadata_lines:
        if not line or line[0].isspace() or ":" not in line:
            continue
        key, value = line.split(":", 1)
        metadata.setdefault(key, []).append(value.strip())
    if metadata.get("Name") != ["agent-fleet"] or metadata.get("Version") != [version]:
        raise PreparationError(f"{label} wheel METADATA identity is not exact")
    try:
        rows = list(csv.reader(record_path.read_text(encoding="utf-8").splitlines()))
    except UnicodeDecodeError as exc:
        raise PreparationError(f"{label} wheel RECORD is not UTF-8") from exc
    values: dict[str, tuple[str, str]] = {}
    for row in rows:
        if len(row) != 3:
            raise PreparationError(f"{label} wheel RECORD row is not exact")
        relative, digest_value, size_value = row
        _normalized_relative(relative, f"{label} wheel RECORD path")
        if relative in values:
            raise PreparationError(f"{label} wheel RECORD contains duplicate paths")
        values[relative] = (digest_value, size_value)
    required = {
        "agent_fleet/__init__.py",
        "agent_fleet/__main__.py",
        "agent_fleet/config.py",
        "agent_fleet/models.py",
        f"agent_fleet-{version}.dist-info/METADATA",
        f"agent_fleet-{version}.dist-info/RECORD",
    }
    if require_provision:
        required.update(
            {
                "agent_fleet/enrollment.py",
                "agent_fleet/identity.py",
                "agent_fleet/provision.py",
                "agent_fleet/recovery.py",
            }
        )
    if not required.issubset(values):
        raise PreparationError(f"{label} wheel RECORD omits required runtime files")
    self_path = f"agent_fleet-{version}.dist-info/RECORD"
    for relative in sorted(required - {self_path}):
        artifact = pythonpath / relative
        _require_regular(artifact, f"{label} wheel artifact {relative}")
        digest = base64.urlsafe_b64encode(
            bytes.fromhex(_sha256(artifact))
        ).decode("ascii").rstrip("=")
        if values[relative] != (
            f"sha256={digest}",
            str(os.lstat(artifact).st_size),
        ):
            raise PreparationError(f"{label} wheel RECORD does not bind {relative}")
    if values[self_path] != ("", ""):
        raise PreparationError(f"{label} wheel RECORD self-row must be unhashed")


def _validate_agent_fleet_runtime(spec: AgentFleetSpec) -> None:
    root = spec.release.new_release
    if spec.operator_front_door.name != "agent-fleet":
        raise PreparationError("Agent Fleet operator front-door basename must be agent-fleet")
    if spec.candidate_front_door != root / "operator/agent-fleet":
        raise PreparationError(
            "Agent Fleet candidate front door must be <release>/operator/agent-fleet"
        )
    if spec.rollback_front_door != spec.release.old_release / "operator/agent-fleet":
        raise PreparationError(
            "Agent Fleet rollback front door must be <release>/operator/agent-fleet"
        )
    for front, label in (
        (spec.candidate_front_door, "Agent Fleet candidate front door"),
        (spec.rollback_front_door, "Agent Fleet rollback front door"),
    ):
        _require_regular(front, label, mode=0o555, executable=True)
        _require_native_macho(front, label)
        _verify_hardened_signature(front, label)
    if spec.executable != root / "bin" / "agent-fleet":
        raise PreparationError("Agent Fleet executable must be <release>/bin/agent-fleet")
    if spec.python_binary != root / "bin" / "python3.11":
        raise PreparationError("Agent Fleet Python must be <release>/bin/python3.11")
    if spec.launcher_module != root / "launcher.py":
        raise PreparationError("Agent Fleet launcher module must be <release>/launcher.py")
    if spec.launcher_source != root / "build" / "agent-fleet-launcher.c":
        raise PreparationError(
            "Agent Fleet launcher source must be <release>/build/agent-fleet-launcher.c"
        )
    if spec.build_provenance != root / "build" / "provenance.json":
        raise PreparationError(
            "Agent Fleet build provenance must be <release>/build/provenance.json"
        )
    if spec.pythonpath != root / "site-packages":
        raise PreparationError("Agent Fleet pythonpath must be <release>/site-packages")
    expected_dist_info = spec.pythonpath / "agent_fleet-0.2.0.dist-info"
    if spec.wheel_metadata != expected_dist_info / "METADATA":
        raise PreparationError(
            "Agent Fleet wheel metadata must be "
            "<release>/site-packages/agent_fleet-0.2.0.dist-info/METADATA"
        )
    if spec.wheel_record != expected_dist_info / "RECORD":
        raise PreparationError(
            "Agent Fleet wheel RECORD must be "
            "<release>/site-packages/agent_fleet-0.2.0.dist-info/RECORD"
        )
    _require_directory(spec.pythonpath, "Agent Fleet pythonpath")
    _require_within(spec.pythonpath, root, "Agent Fleet pythonpath")
    _require_regular(spec.executable, "Agent Fleet executable", executable=True)
    _require_regular(spec.python_binary, "Agent Fleet Python runtime", executable=True)
    _require_native_macho(spec.python_binary, "Agent Fleet Python runtime")
    _require_regular(spec.launcher_module, "Agent Fleet isolated launcher module")
    _require_regular(spec.launcher_source, "Agent Fleet native launcher source")
    _require_regular(spec.wheel_metadata, "Agent Fleet wheel METADATA")
    _require_regular(spec.wheel_record, "Agent Fleet wheel RECORD")
    _require_regular(spec.build_provenance, "Agent Fleet in-tree build provenance")
    _require_regular(spec.build_manifest, "Agent Fleet launcher build manifest")
    _require_regular(
        spec.rollback_executable,
        "Agent Fleet rollback executable",
        executable=True,
    )
    _require_native_macho(spec.rollback_executable, "Agent Fleet rollback executable")
    _require_directory(spec.rollback_pythonpath, "Agent Fleet rollback pythonpath")
    _require_within(
        spec.rollback_pythonpath,
        spec.release.old_release,
        "Agent Fleet rollback pythonpath",
    )
    rollback_relative = _require_within(
        spec.rollback_executable,
        spec.release.old_release,
        "Agent Fleet rollback executable",
    )
    rollback_package_relative = _require_within(
        spec.rollback_pythonpath / "agent_fleet" / "__init__.py",
        spec.release.old_release,
        "Agent Fleet rollback package initializer",
    )
    rollback_config_relative = _require_within(
        spec.rollback_pythonpath / "agent_fleet" / "config.py",
        spec.release.old_release,
        "Agent Fleet rollback config module",
    )
    rollback_python_binary = spec.release.old_release / "bin" / "python3.11"
    _require_regular(
        rollback_python_binary,
        "Agent Fleet rollback Python runtime",
        executable=True,
    )
    _require_native_macho(
        rollback_python_binary,
        "Agent Fleet rollback Python runtime",
    )
    rollback_python_relative = _require_within(
        rollback_python_binary,
        spec.release.old_release,
        "Agent Fleet rollback Python runtime",
    )
    rollback_required = {
        rollback_relative,
        rollback_python_relative,
        rollback_package_relative,
        rollback_config_relative,
    }
    if not rollback_required.issubset(spec.release.old_proof_paths):
        raise PreparationError(
            "Agent Fleet old_proof_paths omits rollback runtime identity files"
        )
    for path, label in (
        (spec.pythonpath, "Agent Fleet pythonpath"),
        (spec.executable, "Agent Fleet executable"),
        (spec.python_binary, "Agent Fleet Python runtime"),
        (spec.launcher_module, "Agent Fleet isolated launcher module"),
        (spec.launcher_source, "Agent Fleet native launcher source"),
        (spec.wheel_metadata, "Agent Fleet wheel METADATA"),
        (spec.wheel_record, "Agent Fleet wheel RECORD"),
        (spec.build_provenance, "Agent Fleet in-tree build provenance"),
    ):
        if "current" in path.parts:
            raise PreparationError(f"{label} may not use a moving 'current' path: {path}")
    executable_relative = _require_within(spec.executable, root, "Agent Fleet executable")
    python_relative = _require_within(spec.python_binary, root, "Agent Fleet Python runtime")
    launcher_relative = _require_within(
        spec.launcher_module, root, "Agent Fleet isolated launcher module"
    )
    source_relative = _require_within(
        spec.launcher_source, root, "Agent Fleet native launcher source"
    )
    provenance_relative = _require_within(
        spec.build_provenance, root, "Agent Fleet in-tree build provenance"
    )
    metadata_relative = _require_within(
        spec.wheel_metadata, root, "Agent Fleet wheel METADATA"
    )
    record_relative = _require_within(
        spec.wheel_record, root, "Agent Fleet wheel RECORD"
    )
    package_relative = _require_within(
        spec.pythonpath / "agent_fleet" / "__init__.py",
        root,
        "Agent Fleet package initializer",
    )
    config_relative = _require_within(
        spec.pythonpath / "agent_fleet" / "config.py",
        root,
        "Agent Fleet package config module",
    )
    provision_relative = _require_within(
        spec.pythonpath / "agent_fleet" / "provision.py",
        root,
        "Agent Fleet package provision module",
    )
    identity_relative = _require_within(
        spec.pythonpath / "agent_fleet" / "identity.py",
        root,
        "Agent Fleet package identity module",
    )
    enrollment_relative = _require_within(
        spec.pythonpath / "agent_fleet" / "enrollment.py",
        root,
        "Agent Fleet package enrollment module",
    )
    recovery_relative = _require_within(
        spec.pythonpath / "agent_fleet" / "recovery.py",
        root,
        "Agent Fleet package credential recovery module",
    )
    required_proofs = {
        executable_relative,
        python_relative,
        launcher_relative,
        source_relative,
        provenance_relative,
        metadata_relative,
        record_relative,
        package_relative,
        config_relative,
        enrollment_relative,
        provision_relative,
        identity_relative,
        recovery_relative,
    }
    missing = required_proofs - set(spec.release.new_proof_paths)
    if missing:
        raise PreparationError(
            "Agent Fleet new_proof_paths omits runtime identity files: "
            + ", ".join(sorted(missing))
        )
    if spec.launcher_module.read_bytes() != _expected_agent_fleet_module():
        raise PreparationError("Agent Fleet launcher module is not the exact isolated bootstrap")
    try:
        metadata_lines = spec.wheel_metadata.read_text(encoding="utf-8").splitlines()
        record_lines = spec.wheel_record.read_text(encoding="utf-8").splitlines()
    except UnicodeDecodeError as exc:
        raise PreparationError("Agent Fleet wheel identity files must be UTF-8") from exc
    metadata: dict[str, list[str]] = {}
    for line in metadata_lines:
        if not line or line[0].isspace() or ":" not in line:
            continue
        key, value = line.split(":", 1)
        metadata.setdefault(key, []).append(value.strip())
    if metadata.get("Name") != ["agent-fleet"]:
        raise PreparationError("Agent Fleet wheel METADATA Name must be exactly agent-fleet")
    if metadata.get("Version") != [spec.expected_version]:
        raise PreparationError(
            "Agent Fleet wheel METADATA Version must match the candidate version"
        )
    record_values: dict[str, tuple[str, str]] = {}
    for row in csv.reader(record_lines):
        if len(row) != 3:
            raise PreparationError("Agent Fleet wheel RECORD row is not exact")
        raw_path, digest_value, size_value = row
        path_parts = Path(raw_path).parts
        if (
            not raw_path
            or os.path.isabs(raw_path)
            or os.path.normpath(raw_path) != raw_path
            or any(part in {"", ".", ".."} for part in path_parts)
        ):
            raise PreparationError("Agent Fleet wheel RECORD contains an unsafe path")
        if raw_path in record_values:
            raise PreparationError("Agent Fleet wheel RECORD contains duplicate paths")
        record_values[raw_path] = (digest_value, size_value)
    required_record_paths = {
        "agent_fleet/__init__.py",
        "agent_fleet/__main__.py",
        "agent_fleet/config.py",
        "agent_fleet/enrollment.py",
        "agent_fleet/models.py",
        "agent_fleet/provision.py",
        "agent_fleet/identity.py",
        "agent_fleet/recovery.py",
        "agent_fleet-0.2.0.dist-info/METADATA",
        "agent_fleet-0.2.0.dist-info/RECORD",
    }
    if not required_record_paths.issubset(record_values):
        raise PreparationError("Agent Fleet wheel RECORD omits required runtime files")
    for relative in sorted(required_record_paths - {"agent_fleet-0.2.0.dist-info/RECORD"}):
        artifact = spec.pythonpath / relative
        _require_regular(artifact, f"Agent Fleet RECORD artifact {relative}")
        encoded = base64.urlsafe_b64encode(
            bytes.fromhex(_sha256(artifact))
        ).decode("ascii").rstrip("=")
        expected_digest = f"sha256={encoded}"
        digest_value, size_value = record_values[relative]
        if digest_value != expected_digest or size_value != str(artifact.stat().st_size):
            raise PreparationError(
                f"Agent Fleet wheel RECORD does not hash-bind {relative}"
            )
    if record_values["agent_fleet-0.2.0.dist-info/RECORD"] != ("", ""):
        raise PreparationError("Agent Fleet wheel RECORD self-row must be unhashed")
    _validate_installed_wheel_record(
        spec.rollback_pythonpath,
        spec.rollback_version,
        require_provision=False,
        label="Agent Fleet rollback",
    )
    _require_native_macho(spec.executable, "Agent Fleet executable")
    # The contained Python runtimes are sealed internal inputs, never operator
    # entrypoints.  Their exact versions are bound by the already-validated
    # proof manifest; runtime probes go only through the hardened launchers.
    _probe_agent_fleet_version(
        spec.rollback_executable,
        spec.rollback_version,
        spec.rollback_contract_version,
        "Agent Fleet rollback",
    )
    _probe_agent_fleet_version(
        spec.executable,
        spec.expected_version,
        spec.expected_contract_version,
        "Agent Fleet candidate",
    )


def _probe_agent_fleet_version(
    executable: Path,
    expected_version: str,
    expected_contract: int,
    label: str,
) -> None:
    with tempfile.TemporaryDirectory(prefix="bridge-agent-fleet-version-") as home:
        sentinel = Path(home) / "hostile-env-sourced"
        poison = Path(home) / "hostile-env.sh"
        poison.write_text(f"touch {json.dumps(str(sentinel))}\n", encoding="utf-8")
        poison.chmod(0o600)
        env = {
            "HOME": home,
            "PATH": "/usr/bin:/bin",
            "LANG": "C",
            "LC_ALL": "C",
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONPATH": str(Path(home) / "hostile-pythonpath"),
            "PYTHONHOME": str(Path(home) / "hostile-pythonhome"),
            "ENV": str(poison),
            "BASH_ENV": str(poison),
            "AGENT_FLEET_BIN": str(Path(home) / "fake-agent-fleet"),
            "AGENT_FLEET_CLAUDE_BIN": str(Path(home) / "fake-claude"),
            "AGENT_FLEET_CODEX_BIN": str(Path(home) / "fake-codex"),
            "AGENT_FLEET_CONFIG": str(Path(home) / "redirected-registry.toml"),
            "AGENT_FLEET_STATE_DIR": str(Path(home) / "redirected-state"),
            "AGENT_FLEET_SHARE_DIR": str(Path(home) / "redirected-share"),
            "AGENT_FLEET_FORMAT": "hostile-format",
            "AGENT_FLEET_QUOTA_BIN": str(Path(home) / "fake-quota-axi"),
            "AGENT_FLEET_QUOTA_FIXTURE_DIR": str(Path(home) / "fake-quota"),
            "AGENT_FLEET_QUOTA_FIXTURE_RESULT": "fake-result",
            "AGENT_FLEET_TEST_QUOTA_FIXTURE_DIR": str(
                Path(home) / "fake-test-quota"
            ),
            "AGENT_FLEET_TEST_QUOTA_FIXTURE_RESULT": "fake-test-result",
        }
        try:
            completed = subprocess.run(
                [str(executable), "--format", "json", "version"],
                check=False,
                capture_output=True,
                text=True,
                env=env,
                timeout=15,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise PreparationError(f"{label} version probe failed: {exc}") from exc
        if sentinel.exists():
            raise PreparationError(f"{label} sourced hostile shell environment")
    if completed.returncode != 0:
        raise PreparationError(
            f"{label} version probe exited {completed.returncode}: {completed.stderr.strip()}"
        )
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise PreparationError(f"{label} version probe did not return JSON") from exc
    expected = {"cli_version": expected_version, "contract_version": expected_contract}
    if payload != expected:
        raise PreparationError(f"{label} version contract mismatch: {payload!r}")


def _sealed_quota_binary(spec: PreparationSpec) -> Path:
    return spec.quota.rollback_binary


def _verify_hardened_signature(path: Path, label: str) -> str:
    try:
        verified = subprocess.run(
            ["/usr/bin/codesign", "--verify", "--strict", "--verbose=4", str(path)],
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
        )
        described = subprocess.run(
            ["/usr/bin/codesign", "-d", "--verbose=4", str(path)],
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise PreparationError(f"{label} signature probe failed: {exc}") from exc
    if verified.returncode != 0:
        raise PreparationError(f"{label} does not have a valid strict code signature")
    description = described.stdout + described.stderr
    if described.returncode != 0 or "runtime" not in description:
        raise PreparationError(f"{label} is not signed with hardened runtime")
    return hashlib.sha256(description.encode("utf-8")).hexdigest()


def _validate_quota_role(
    *,
    root: Path,
    binary: Path,
    node: Path,
    entrypoint: Path,
    launcher_source: Path,
    provenance: Path,
    runtime_manifest: Path,
    package_json: Path,
    package_lock: Path,
    version: str,
    node_version: str,
    proof_paths: Sequence[str],
    label: str,
) -> None:
    expected_paths = {
        "binary": root / "bin" / "quota-axi",
        "node": root / "runtime" / "node",
        "entrypoint": root / "node_modules/quota-axi/dist/bin/quota-axi.js",
        "launcher source": root / "build" / "quota-axi-launcher.c",
        "provenance": root / "build" / "provenance.json",
        "runtime manifest": root / "build" / "runtime-closure.json",
        "package.json": root / "node_modules/quota-axi/package.json",
        "package-lock.json": root / "package-lock.json",
        "Quota build proof": root / "build" / "quota-build-proof.json",
    }
    observed_paths = {
        "binary": binary,
        "node": node,
        "entrypoint": entrypoint,
        "launcher source": launcher_source,
        "provenance": provenance,
        "runtime manifest": runtime_manifest,
        "package.json": package_json,
        "package-lock.json": package_lock,
        "Quota build proof": root / "build" / "quota-build-proof.json",
    }
    for name, expected in expected_paths.items():
        observed = observed_paths[name]
        if observed != expected:
            raise PreparationError(f"{label} {name} path is not the exact sealed path")
        if "current" in observed.parts:
            raise PreparationError(f"{label} {name} may not use a moving current path")
        _require_within(observed, root, f"{label} {name}")

    _require_regular(binary, f"{label} hardened launcher", executable=True)
    _require_native_macho(binary, f"{label} hardened launcher")
    _verify_hardened_signature(binary, f"{label} hardened launcher")
    _require_regular(node, f"{label} contained Node runtime", executable=True)
    _require_native_macho(node, f"{label} contained Node runtime")
    _require_regular(entrypoint, f"{label} internal JavaScript entrypoint")
    if stat.S_IMODE(entrypoint.stat().st_mode) & 0o111:
        raise PreparationError(
            f"{label} raw JavaScript entrypoint must be non-operational (not executable)"
        )
    _require_regular(launcher_source, f"{label} launcher source")
    _require_regular(provenance, f"{label} build provenance")
    _require_regular(runtime_manifest, f"{label} runtime closure manifest")
    _require_regular(package_json, f"{label} package.json")
    _require_regular(package_lock, f"{label} package-lock.json")
    _require_regular(
        root / "build" / "quota-build-proof.json",
        f"{label} Quota deterministic build proof",
    )

    required_proofs = {
        str(path.relative_to(root))
        for path in (
            binary,
            node,
            entrypoint,
            launcher_source,
            provenance,
            runtime_manifest,
            package_json,
            package_lock,
            root / "build" / "quota-build-proof.json",
        )
    }
    missing = required_proofs - set(proof_paths)
    if missing:
        raise PreparationError(
            f"{label} proof paths omit sealed runtime identity files: "
            + ", ".join(sorted(missing))
        )

    # Raw Node is a sealed internal input and is deliberately never invoked by
    # this preparer.  Its exact version is bound by the schema-v2 proof record;
    # empirical execution goes only through the hardened quota-axi launcher.
    package = _read_json(package_json, f"{label} package.json")
    lock = _read_json(package_lock, f"{label} package-lock.json")
    if not isinstance(package, dict) or package.get("name") != "quota-axi":
        raise PreparationError(f"{label} package name mismatch")
    if package.get("version") != version:
        raise PreparationError(f"{label} package version mismatch")
    package_bin = package.get("bin")
    if isinstance(package_bin, str):
        entry_value = package_bin
    elif isinstance(package_bin, dict) and set(package_bin) == {"quota-axi"}:
        entry_value = package_bin["quota-axi"]
    else:
        raise PreparationError(f"{label} package bin contract is not exact")
    if not isinstance(entry_value, str):
        raise PreparationError(f"{label} package bin entry must be a path string")
    if Path(os.path.normpath(package_json.parent / entry_value)) != entrypoint:
        raise PreparationError(f"{label} package bin does not bind the internal JavaScript")
    packages = lock.get("packages") if isinstance(lock, dict) else None
    relative_package = str(package_json.parent.relative_to(root))
    if not isinstance(packages, dict) or not isinstance(packages.get(relative_package), dict):
        raise PreparationError(f"{label} lock does not bind the installed package path")
    if packages[relative_package].get("version") != version:
        raise PreparationError(f"{label} lock package version mismatch")
    root_lock = packages.get("")
    dependencies = root_lock.get("dependencies") if isinstance(root_lock, dict) else None
    if not isinstance(dependencies, dict) or dependencies.get("quota-axi") != version:
        raise PreparationError(f"{label} lock root dependency is not an exact version pin")


def _validate_quota_runtime(spec: PreparationSpec) -> None:
    quota = spec.quota
    adoption = spec.sealed_adoption
    root = quota.release.new_release
    legacy = quota.legacy_registry_binary
    initial_release = _initial_release_path(
        quota.release, adoption.quota_initial_target
    )
    if legacy == initial_release or not _is_relative_to(legacy, initial_release):
        raise PreparationError("legacy registry Quota binary must be inside initial release")
    if "current" in legacy.parts:
        raise PreparationError("legacy registry Quota binary may not use a moving current path")
    _validate_quota_role(
        root=quota.release.old_release,
        binary=quota.rollback_binary,
        node=quota.rollback_node_binary,
        entrypoint=quota.rollback_entrypoint,
        launcher_source=quota.rollback_launcher_source,
        provenance=quota.rollback_build_provenance,
        runtime_manifest=quota.rollback_runtime_manifest,
        package_json=quota.rollback_package_json,
        package_lock=quota.rollback_package_lock,
        version=quota.rollback_version,
        node_version=quota.rollback_node_version,
        proof_paths=quota.release.old_proof_paths,
        label="Quota rollback",
    )
    _validate_quota_role(
        root=root,
        binary=quota.binary,
        node=quota.node_binary,
        entrypoint=quota.entrypoint,
        launcher_source=quota.launcher_source,
        provenance=quota.build_provenance,
        runtime_manifest=quota.runtime_manifest,
        package_json=quota.package_json,
        package_lock=quota.package_lock,
        version=quota.expected_version,
        node_version=quota.node_version,
        proof_paths=quota.release.new_proof_paths,
        label="Quota candidate",
    )


def _validate_adoption_inputs(spec: PreparationSpec) -> None:
    adoption = spec.sealed_adoption
    _require_directory(
        spec.worker_state.snapshot_parent,
        "worker-state snapshot parent",
        private=True,
    )
    if adoption.agent_fleet_initial_target in {
        spec.agent_fleet.release.old_target,
        spec.agent_fleet.release.new_target,
    }:
        raise PreparationError("Agent Fleet initial target must differ from sealed/new")
    if adoption.quota_initial_target in {
        spec.quota.release.old_target,
        spec.quota.release.new_target,
    }:
        raise PreparationError("Quota initial target must differ from sealed/new")
    for target, release, label in (
        (
            adoption.agent_fleet_initial_target,
            spec.agent_fleet.release,
            "Agent Fleet initial target",
        ),
        (adoption.quota_initial_target, spec.quota.release, "Quota initial target"),
    ):
        resolved = _initial_release_path(release, target)
        if resolved == release.current_link.parent or not _is_relative_to(
            resolved, release.current_link.parent
        ):
            raise PreparationError(f"{label} must resolve strictly below its product root")
    _require_directory(
        spec.agent_fleet.operator_front_door.parent,
        "Agent Fleet operator front-door parent",
    )
    try:
        front_info = os.lstat(spec.agent_fleet.operator_front_door)
    except FileNotFoundError as exc:
        raise PreparationError("Agent Fleet operator front door is missing") from exc
    if stat.S_ISLNK(front_info.st_mode):
        if (
            os.readlink(spec.agent_fleet.operator_front_door)
            != adoption.agent_fleet_front_door_initial_target
        ):
            raise PreparationError(
                "Agent Fleet operator front door must be the exact authorized legacy symlink"
            )
    elif stat.S_ISREG(front_info.st_mode):
        _require_regular(
            spec.agent_fleet.operator_front_door,
            "installed Agent Fleet operator front door",
            mode=0o555,
            executable=True,
        )
        if _sha256(spec.agent_fleet.operator_front_door) not in {
            _sha256(spec.agent_fleet.rollback_front_door),
            _sha256(spec.agent_fleet.candidate_front_door),
        }:
            raise PreparationError(
                "installed Agent Fleet operator front door has an unknown sealed payload"
            )
    else:
        raise PreparationError(
            "Agent Fleet operator front door must be a symlink or sealed regular file"
        )
    resolved_front_target = Path(
        os.path.normpath(
            spec.agent_fleet.operator_front_door.parent
            / adoption.agent_fleet_front_door_initial_target
        )
    )
    if resolved_front_target != spec.agent_fleet.release.current_link / "bin/agent-fleet":
        raise PreparationError(
            "Agent Fleet legacy front-door symlink must resolve to current/bin/agent-fleet"
        )
    _require_regular(adoption.backend_path, "adoption backend selector")
    if _sha256(adoption.backend_path) != adoption.backend_sha256:
        raise PreparationError("adoption backend selector SHA-256 mismatch")
    try:
        backend = adoption.backend_path.read_text(encoding="utf-8").strip()
    except UnicodeDecodeError as exc:
        raise PreparationError("adoption backend selector is not UTF-8") from exc
    if backend != "tmux":
        raise PreparationError("adoption backend selector must be tmux")
    _require_regular(adoption.ps_binary, "adoption ps binary", executable=True)
    if _sha256(adoption.ps_binary) != adoption.ps_binary_sha256:
        raise PreparationError("adoption ps binary SHA-256 mismatch")
    for path in adoption.routing_absent_paths:
        _require_directory(path.parent, "adoption routing path parent")
        if os.path.lexists(path):
            raise PreparationError(f"adoption routing path must be absent: {path}")
    for path in adoption.state_quiet_paths:
        _require_directory(path.parent, "adoption quiet state parent")
        if not os.path.lexists(path):
            continue
        _require_directory(path, "adoption quiet state path")
        with os.scandir(path) as entries:
            if next(entries, None) is not None:
                raise PreparationError(f"adoption quiet state path is not empty: {path}")


def _validate_input_state(
    spec: PreparationSpec,
    *,
    allow_existing_output: bool = False,
) -> tuple[AgentFleetAPI, AgentFleetAPI]:
    _require_regular(spec.baseline_registry, "baseline registry", mode=0o600)
    if _sha256(spec.baseline_registry) != spec.baseline_registry_sha256:
        raise PreparationError("baseline registry SHA-256 generation is stale")
    _require_regular(spec.live_registry, "live registry", mode=0o600)
    if spec.baseline_registry.read_bytes() != spec.live_registry.read_bytes():
        raise PreparationError("live registry bytes do not equal the explicit baseline")
    baseline_raw = _parse_registry_toml(spec.baseline_registry, "baseline registry")
    _validate_legacy_registry_shape(baseline_raw, spec)
    _require_directory(spec.trusted_project, "trusted Relvino project")
    if (
        not allow_existing_output
        and (spec.output_dir.exists() or os.path.lexists(spec.output_dir))
    ):
        raise PreparationError(f"output_dir must not already exist: {spec.output_dir}")
    _require_directory(spec.output_dir.parent, "output parent")
    _validate_adoption_inputs(spec)
    _validate_release_spec(
        spec.agent_fleet.release,
        (spec.sealed_adoption.agent_fleet_initial_target,),
    )
    _validate_release_spec(
        spec.quota.release,
        (spec.sealed_adoption.quota_initial_target,),
    )
    _validate_agent_fleet_runtime(spec.agent_fleet)
    _validate_quota_runtime(spec)
    rollback_api = load_agent_fleet_api(
        spec.agent_fleet.rollback_pythonpath,
        spec.agent_fleet.release.old_release,
        spec.agent_fleet.rollback_version,
        "Agent Fleet rollback",
    )
    candidate_api = load_agent_fleet_api(
        spec.agent_fleet.pythonpath,
        spec.agent_fleet.release.new_release,
        spec.agent_fleet.expected_version,
        "Agent Fleet candidate",
        require_provision_api=True,
    )
    return rollback_api, candidate_api


def _field_map(value: Any) -> dict[str, Any]:
    if not dataclasses.is_dataclass(value):
        raise PreparationError(f"Agent Fleet API returned a non-dataclass: {type(value)!r}")
    return {field.name: getattr(value, field.name) for field in dataclasses.fields(value)}


def _semantic_validate(baseline: Any, candidate: Any, spec: PreparationSpec) -> None:
    if set(getattr(baseline, "profiles", {})) != set(EXPECTED_TOPOLOGY):
        raise PreparationError("baseline object does not have the exact eight profiles")
    if set(getattr(candidate, "profiles", {})) != set(EXPECTED_TOPOLOGY):
        raise PreparationError("candidate object does not have the exact eight profiles")
    if set(getattr(baseline, "providers", {})) != {"claude", "codex"}:
        raise PreparationError("baseline object does not have exact providers")
    if set(getattr(candidate, "providers", {})) != {"claude", "codex"}:
        raise PreparationError("candidate object does not have exact providers")
    before_registry = _field_map(baseline)
    after_registry = _field_map(candidate)
    if set(before_registry) != set(after_registry):
        raise PreparationError("registry dataclass fields changed")
    for key in before_registry:
        if (
            key not in {"settings", "providers", "profiles"}
            and after_registry[key] != before_registry[key]
        ):
            raise PreparationError(f"unallowlisted registry field changed: {key}")

    before_settings = _field_map(baseline.settings)
    after_settings = _field_map(candidate.settings)
    quota_fields = {
        "quota_binary",
        "quota_node_binary",
        "quota_binary_sha256",
        "quota_node_sha256",
        "quota_release_tree_sha256",
    }
    missing_old = set(before_settings) - set(after_settings)
    unexpected_new = set(after_settings) - set(before_settings) - quota_fields
    if missing_old or unexpected_new:
        raise PreparationError(
            "settings dataclass fields changed outside the Quota identity migration"
        )
    expected_quota = {
        "quota_binary": spec.quota.binary,
        "quota_node_binary": spec.quota.node_binary,
        "quota_binary_sha256": _sha256(spec.quota.binary),
        "quota_node_sha256": _sha256(spec.quota.node_binary),
        "quota_release_tree_sha256": spec.quota.release_tree_sha256,
    }
    for key, value in expected_quota.items():
        if after_settings.get(key) != value:
            raise PreparationError(f"candidate {key} is not the exact immutable identity")
    for key in before_settings:
        if key in quota_fields:
            continue
        elif after_settings[key] != before_settings[key]:
            raise PreparationError(f"unallowlisted settings field changed: {key}")

    for provider_name in ("claude", "codex"):
        before = _field_map(baseline.providers[provider_name])
        after = _field_map(candidate.providers[provider_name])
        if set(before) != set(after):
            raise PreparationError(f"provider {provider_name} dataclass fields changed")
        for key in before:
            if key == "trusted_projects":
                if after[key] != (spec.trusted_project,):
                    raise PreparationError(
                        f"provider {provider_name} must trust exactly the Relvino project"
                    )
            elif key == "hooks_source":
                if after[key] is not None:
                    raise PreparationError(
                        f"provider {provider_name} must not inherit mutable hooks"
                    )
            elif key == "shared_entries":
                expected_shared = tuple(
                    entry for entry in before[key] if entry != "plugins"
                )
                if after[key] != expected_shared or "plugins" in after[key]:
                    raise PreparationError(
                        f"provider {provider_name} plugin sharing was not removed exactly"
                    )
            elif after[key] != before[key]:
                raise PreparationError(
                    f"unallowlisted provider field changed: {provider_name}.{key}"
                )

    for profile_id, (provider, pools, policy) in EXPECTED_TOPOLOGY.items():
        before = _field_map(baseline.profiles[profile_id])
        after = _field_map(candidate.profiles[profile_id])
        if set(before) != set(after):
            raise PreparationError(f"profile {profile_id} dataclass fields changed")
        for key in before:
            if key == "enabled":
                if after[key] is not False:
                    raise PreparationError(f"profile {profile_id} is not disabled")
            elif key == "pools":
                if after[key] != pools:
                    raise PreparationError(f"profile {profile_id} pools are not exact")
            elif key == "safety_policy":
                if after[key] != policy:
                    raise PreparationError(f"profile {profile_id} policy is not exact")
            elif after[key] != before[key]:
                raise PreparationError(f"unallowlisted profile field changed: {profile_id}.{key}")
        if after.get("provider") != provider:
            raise PreparationError(f"profile {profile_id} provider is not {provider}")


def _migrate_dataclass(
    target: type[Any],
    source: Any,
    overrides: Mapping[str, Any],
    label: str,
) -> Any:
    source_values = _field_map(source)
    target_fields = {field.name: field for field in dataclasses.fields(target)}
    removed = set(source_values) - set(target_fields)
    if removed:
        raise PreparationError(
            f"{label} target dropped baseline fields: {', '.join(sorted(removed))}"
        )
    unknown_overrides = set(overrides) - set(target_fields)
    if unknown_overrides:
        raise PreparationError(
            f"{label} target lacks required fields: {', '.join(sorted(unknown_overrides))}"
        )
    values: dict[str, Any] = {}
    for name, field in target_fields.items():
        if name in overrides:
            values[name] = overrides[name]
        elif name in source_values:
            values[name] = source_values[name]
        elif field.default is not dataclasses.MISSING:
            values[name] = field.default
        elif field.default_factory is not dataclasses.MISSING:  # type: ignore[comparison-overlap]
            values[name] = field.default_factory()
        else:
            raise PreparationError(
                f"{label} target added required field without migration: {name}"
            )
    try:
        return target(**values)
    except Exception as exc:
        raise PreparationError(f"cannot construct migrated {label}: {exc}") from exc


def _construct_sealed_baseline(baseline: Any, spec: PreparationSpec) -> Any:
    sealed_binary = _sealed_quota_binary(spec)
    before_settings = _field_map(baseline.settings)
    settings_overrides: dict[str, Any] = {"quota_binary": sealed_binary}
    for key in ("state_dir", "share_dir", "quota_node_binary"):
        if key in before_settings:
            settings_overrides[key] = _normalized_absolute(
                str(before_settings[key]), f"sealed rollback settings.{key}"
            )
    settings = _migrate_dataclass(
        type(baseline.settings),
        baseline.settings,
        settings_overrides,
        "sealed rollback settings",
    )
    providers = {}
    for name, provider in baseline.providers.items():
        provider_values = _field_map(provider)
        overrides: dict[str, Any] = {"hooks_source": None}
        for key in ("binary", "base_home", "desktop_identity_file"):
            value = provider_values.get(key)
            if value is not None:
                overrides[key] = _normalized_absolute(
                    str(value), f"sealed rollback provider {name}.{key}"
                )
        overrides["trusted_projects"] = tuple(
            _normalized_absolute(
                str(project), f"sealed rollback provider {name}.trusted_projects"
            )
            for project in provider_values.get("trusted_projects", ())
        )
        providers[name] = _migrate_dataclass(
            type(provider),
            provider,
            overrides,
            f"sealed rollback provider {name}",
        )
    profiles = {
        profile_id: _migrate_dataclass(
            type(profile),
            profile,
            {
                "home": _normalized_absolute(
                    str(profile.home), f"sealed rollback profile {profile_id}.home"
                )
            },
            f"sealed rollback profile {profile_id}",
        )
        for profile_id, profile in baseline.profiles.items()
    }
    sealed = _migrate_dataclass(
        type(baseline),
        baseline,
        {"settings": settings, "providers": providers, "profiles": profiles},
        "sealed rollback registry",
    )
    before_registry = _field_map(baseline)
    after_registry = _field_map(sealed)
    if set(before_registry) != set(after_registry):
        raise PreparationError("sealed rollback registry fields changed")
    for key in before_registry:
        if key not in {"settings", "providers", "profiles"} and after_registry[key] != before_registry[key]:
            raise PreparationError(f"sealed rollback changed registry field: {key}")
    for name, before_provider in baseline.providers.items():
        before = _field_map(before_provider)
        after = _field_map(sealed.providers[name])
        if set(before) != set(after):
            raise PreparationError(f"sealed rollback provider fields changed: {name}")
        for key in before:
            if key == "hooks_source":
                if after[key] is not None:
                    raise PreparationError(
                        f"sealed rollback provider {name} inherited mutable hooks"
                    )
            elif key in {"binary", "base_home", "desktop_identity_file"}:
                value = before[key]
                expected = (
                    None
                    if value is None
                    else _normalized_absolute(
                        str(value), f"sealed rollback provider {name}.{key}"
                    )
                )
                if after[key] != expected:
                    raise PreparationError(
                        f"sealed rollback provider path was not normalized: {name}.{key}"
                    )
            elif key == "trusted_projects":
                expected = tuple(
                    _normalized_absolute(
                        str(project), f"sealed rollback provider {name}.trusted_projects"
                    )
                    for project in before[key]
                )
                if after[key] != expected:
                    raise PreparationError(
                        f"sealed rollback provider projects were not normalized: {name}"
                    )
            elif after[key] != before[key]:
                raise PreparationError(
                    f"sealed rollback changed provider field: {name}.{key}"
                )
    after_settings = _field_map(sealed.settings)
    if set(before_settings) != set(after_settings):
        raise PreparationError("sealed rollback settings fields changed")
    for key in before_settings:
        if key == "quota_binary":
            if after_settings[key] != sealed_binary:
                raise PreparationError("sealed rollback Quota path is not exact")
        elif key in {"state_dir", "share_dir", "quota_node_binary"}:
            expected = _normalized_absolute(
                str(before_settings[key]), f"sealed rollback settings.{key}"
            )
            if after_settings[key] != expected:
                raise PreparationError(f"sealed rollback did not normalize settings.{key}")
        elif after_settings[key] != before_settings[key]:
            raise PreparationError(f"sealed rollback changed settings field: {key}")
    for profile_id, before_profile in baseline.profiles.items():
        before = _field_map(before_profile)
        after = _field_map(sealed.profiles[profile_id])
        if set(before) != set(after):
            raise PreparationError(f"sealed rollback profile fields changed: {profile_id}")
        for key in before:
            expected = (
                _normalized_absolute(
                    str(before[key]), f"sealed rollback profile {profile_id}.home"
                )
                if key == "home"
                else before[key]
            )
            if after[key] != expected:
                raise PreparationError(
                    f"sealed rollback changed profile field: {profile_id}.{key}"
                )
    return sealed


def _construct_candidate(api: AgentFleetAPI, baseline: Any, spec: PreparationSpec) -> Any:
    settings = _migrate_dataclass(
        api.models.Settings,
        baseline.settings,
        {
            "quota_binary": spec.quota.binary,
            "quota_node_binary": spec.quota.node_binary,
            "quota_binary_sha256": _sha256(spec.quota.binary),
            "quota_node_sha256": _sha256(spec.quota.node_binary),
            "quota_release_tree_sha256": spec.quota.release_tree_sha256,
        },
        "settings",
    )
    providers = {
        name: _migrate_dataclass(
            api.models.ProviderConfig,
            provider,
            {
                "hooks_source": None,
                "shared_entries": tuple(
                    entry for entry in provider.shared_entries if entry != "plugins"
                ),
                "trusted_projects": (spec.trusted_project,),
            },
            f"provider {name}",
        )
        for name, provider in baseline.providers.items()
    }
    profiles = {}
    for profile_id, (_, pools, policy) in EXPECTED_TOPOLOGY.items():
        profiles[profile_id] = _migrate_dataclass(
            api.models.Profile,
            baseline.profiles[profile_id],
            {"pools": pools, "enabled": False, "safety_policy": policy},
            f"profile {profile_id}",
        )
    candidate = _migrate_dataclass(
        api.models.Registry,
        baseline,
        {"settings": settings, "providers": providers, "profiles": profiles},
        "registry",
    )
    _semantic_validate(baseline, candidate, spec)
    return candidate


def _write_bytes(path: Path, value: bytes, mode: int = 0o600) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags, mode)
    try:
        os.fchmod(fd, mode)
        offset = 0
        while offset < len(value):
            offset += os.write(fd, value[offset:])
        os.fsync(fd)
    finally:
        os.close(fd)


def _write_json(path: Path, value: Any, mode: int = 0o600) -> None:
    payload = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")
    _write_bytes(path, payload, mode)


def _atomic_replace_bytes(path: Path, value: bytes, mode: int = 0o600) -> None:
    """Durably replace an existing regular file with new bytes.

    ``_write_bytes`` opens with ``O_EXCL`` and therefore only ever creates a new
    file.  Refreshing an already-published bundle artifact must overwrite in
    place, so this writes the payload to a private sibling temporary file and
    atomically renames it over the target, then fsyncs the directory.  The
    rename is atomic, so a reader either sees the whole old file or the whole new
    file, never a partial write.
    """

    directory = path.parent
    descriptor, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=directory)
    temp_path = Path(temp_name)
    try:
        os.fchmod(descriptor, mode)
        offset = 0
        while offset < len(value):
            offset += os.write(descriptor, value[offset:])
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    try:
        os.replace(temp_path, path)
    except BaseException:
        if os.path.lexists(temp_path):
            os.unlink(temp_path)
        raise
    parent_fd = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(parent_fd)
    finally:
        os.close(parent_fd)


def _atomic_replace_json(path: Path, value: Any, mode: int = 0o600) -> None:
    payload = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")
    _atomic_replace_bytes(path, payload, mode)


def _native_dependencies(path: Path) -> list[str]:
    try:
        completed = subprocess.run(
            ["/usr/bin/otool", "-L", str(path)],
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise PreparationError(f"cannot inspect native launcher dependencies: {exc}") from exc
    if completed.returncode != 0:
        raise PreparationError(
            f"otool failed for native launcher: {completed.stderr.strip()}"
        )
    dependencies: list[str] = []
    for line in completed.stdout.splitlines()[1:]:
        stripped = line.strip()
        if not stripped:
            continue
        dependencies.append(stripped)
    if not dependencies:
        raise PreparationError("native launcher has no inspectable dependencies")
    return dependencies


def _relative_record_path(root: Path, value: Any, label: str) -> Path:
    return root / _normalized_relative(value, label)


def _record_proof(path: Path, root: Path) -> dict[str, Any]:
    _require_regular(path, "sealed runtime identity file")
    info = os.lstat(path)
    return {
        "path": str(path.relative_to(root)),
        "sha256": _sha256(path),
        "mode": f"{stat.S_IMODE(info.st_mode):04o}",
        "nlink": 1,
    }


def _validate_manifest_proofs(
    record: Mapping[str, Any],
    root: Path,
    expected_paths: Sequence[str],
    driver: ModuleType,
    label: str,
) -> None:
    values = record.get("proofs")
    if not isinstance(values, list) or not values:
        raise PreparationError(f"{label}.proofs must be a non-empty array")
    expected_set = set(expected_paths)
    observed_set: set[str] = set()
    for index, value in enumerate(values):
        proof_label = f"{label}.proofs[{index}]"
        if not isinstance(value, dict):
            raise PreparationError(f"{proof_label} must be an object")
        _require_exact_keys(value, {"path", "sha256", "mode", "nlink"}, set(), proof_label)
        relative = _normalized_relative(value["path"], f"{proof_label}.path")
        if relative in observed_set:
            raise PreparationError(f"{label}.proofs contains duplicate path: {relative}")
        observed_set.add(relative)
        computed = driver.compute_release_proof(root, relative, proof_label)
        exact = {
            "path": computed["relative_path"],
            "sha256": computed["sha256"],
            "mode": computed["mode"],
            "nlink": 1,
        }
        if value != exact:
            raise PreparationError(f"{proof_label} does not match the sealed file")
    if observed_set != expected_set:
        raise PreparationError(f"{label}.proofs do not exactly match transaction proofs")


def _validate_common_runtime_record(
    record: Mapping[str, Any],
    *,
    manifest_root: Path,
    release: ReleaseSpec,
    candidate: bool,
    version: str,
    source_commit: str,
    driver: ModuleType,
    label: str,
) -> Path:
    role = "candidate" if candidate else "rollback"
    expected_root = release.new_release if candidate else release.old_release
    expected_proofs = release.new_proof_paths if candidate else release.old_proof_paths
    if record.get("role") != role:
        raise PreparationError(f"{label}.role must be {role}")
    root = _relative_record_path(manifest_root, record.get("release_path"), f"{label}.release_path")
    if Path(os.path.realpath(root)) != root or root != expected_root:
        raise PreparationError(f"{label}.release_path is not the exact canonical release")
    tree = driver.compute_release_tree_sha256(root, label)
    exact = {
        "version": version,
        "source_commit": source_commit,
        "tree_sha256": tree,
        "rebuild_tree_sha256": tree,
        "relocated_tree_sha256": tree,
    }
    for key, expected in exact.items():
        if record.get(key) != expected:
            raise PreparationError(f"{label}.{key} does not match the sealed runtime")
    _validate_manifest_proofs(record, root, expected_proofs, driver, label)
    return root


def _validate_signature_record(
    record: Any,
    binary: Path,
    label: str,
) -> None:
    if not isinstance(record, dict):
        raise PreparationError(f"{label} signature must be an object")
    _require_exact_keys(
        record,
        {"valid", "hardened_runtime", "verify_strict", "details_sha256"},
        set(),
        f"{label} signature",
    )
    if record["valid"] is not True or record["hardened_runtime"] is not True:
        raise PreparationError(f"{label} signature is not valid hardened runtime")
    if record["verify_strict"] is not True:
        raise PreparationError(f"{label} signature was not verified strictly")
    details_sha256 = _verify_hardened_signature(binary, label)
    if record["details_sha256"] != details_sha256:
        raise PreparationError(f"{label} signature detail digest mismatch")


def _validate_provenance_record(
    record: Any,
    root: Path,
    source_commit: str,
    kind: str,
    version: str,
    artifacts: Mapping[str, Path],
    label: str,
) -> None:
    if not isinstance(record, dict):
        raise PreparationError(f"{label}.provenance must be an object")
    _require_exact_keys(record, {"path", "sha256"}, set(), f"{label}.provenance")
    path = _relative_record_path(root, record["path"], f"{label}.provenance.path")
    if path != root / "build" / "provenance.json":
        raise PreparationError(f"{label}.provenance path is not exact")
    _require_regular(path, f"{label} provenance")
    if record["sha256"] != _sha256(path):
        raise PreparationError(f"{label}.provenance SHA-256 mismatch")
    payload = _read_json(path, f"{label} provenance")
    if not isinstance(payload, dict):
        raise PreparationError(f"{label}.provenance payload must be an object")
    required_payload = {
        "schema_version",
        "role",
        "version",
        "source_commit",
        "source_tree_sha256",
        "artifacts",
    }
    if kind == "agent_fleet":
        required_payload.update(
            {
                "python_runtime_source_tree_sha256",
                "python_runtime_transformations",
            }
        )
    _require_exact_keys(
        payload, required_payload, set(), f"{label}.provenance payload"
    )
    if (
        payload["schema_version"] != 2
        or payload["role"] != kind
        or payload["version"] != version
        or payload["source_commit"] != source_commit
        or not isinstance(payload["source_tree_sha256"], str)
        or not SHA256.fullmatch(payload["source_tree_sha256"])
    ):
        raise PreparationError(f"{label}.provenance identity is not exact")
    if kind == "agent_fleet":
        if (
            not isinstance(payload["python_runtime_source_tree_sha256"], str)
            or not SHA256.fullmatch(payload["python_runtime_source_tree_sha256"])
            or not isinstance(payload["python_runtime_transformations"], list)
        ):
            raise PreparationError(
                f"{label}.provenance Python-runtime transformation proof is invalid"
            )
    artifact_records = payload["artifacts"]
    if not isinstance(artifact_records, dict) or set(artifact_records) != set(artifacts):
        raise PreparationError(f"{label}.provenance artifact set is not exact")
    for artifact_name, expected_path in artifacts.items():
        artifact = artifact_records[artifact_name]
        if not isinstance(artifact, dict):
            raise PreparationError(
                f"{label}.provenance artifact {artifact_name} must be an object"
            )
        _require_exact_keys(
            artifact,
            {"path", "sha256"},
            set(),
            f"{label}.provenance artifact {artifact_name}",
        )
        observed_path = _relative_record_path(
            root,
            artifact["path"],
            f"{label}.provenance artifact {artifact_name}.path",
        )
        if observed_path != expected_path or artifact["sha256"] != _sha256(expected_path):
            raise PreparationError(
                f"{label}.provenance artifact {artifact_name} is not exact"
            )


def _require_true_probe(record: Mapping[str, Any], key: str, label: str) -> None:
    if record.get(key) is not True:
        raise PreparationError(f"{label}.{key} was not proven")


def _validate_agent_runtime_record(
    record: Mapping[str, Any],
    *,
    manifest_root: Path,
    release: ReleaseSpec,
    candidate: bool,
    executable: Path,
    python_binary: Path,
    python_version: str,
    expected_python_sha256: str,
    version: str,
    contract: int,
    source_commit: str,
    driver: ModuleType,
    label: str,
) -> None:
    required = {
        "role", "release_path", "version", "contract_version", "source_commit",
        "tree_sha256", "rebuild_tree_sha256", "relocated_tree_sha256", "proofs",
        "launcher", "python", "wheel", "provenance", "invocation", "probes",
    }
    _require_exact_keys(record, required, set(), label)
    root = _validate_common_runtime_record(
        record,
        manifest_root=manifest_root,
        release=release,
        candidate=candidate,
        version=version,
        source_commit=source_commit,
        driver=driver,
        label=label,
    )
    if record["contract_version"] != contract:
        raise PreparationError(f"{label}.contract_version mismatch")

    launcher = record["launcher"]
    if not isinstance(launcher, dict):
        raise PreparationError(f"{label}.launcher must be an object")
    _require_exact_keys(
        launcher,
        {
            "path", "sha256", "mode", "nlink", "binary_format", "source_path",
            "source_sha256", "dependencies", "signature", "canonical_physical_only",
            "env_scrub",
        },
        set(),
        f"{label}.launcher",
    )
    binary = _relative_record_path(root, launcher["path"], f"{label}.launcher.path")
    if binary != executable or "current" in binary.parts:
        raise PreparationError(f"{label}.launcher is not the canonical physical executable")
    source = _relative_record_path(root, launcher["source_path"], f"{label}.launcher.source_path")
    if source != root / "build" / "agent-fleet-launcher.c":
        raise PreparationError(f"{label}.launcher source path is not exact")
    expected_launcher = _record_proof(binary, root)
    for key in ("path", "sha256", "mode", "nlink"):
        if launcher[key] != expected_launcher[key]:
            raise PreparationError(f"{label}.launcher {key} mismatch")
    if launcher["source_sha256"] != _sha256(source):
        raise PreparationError(f"{label}.launcher source SHA-256 mismatch")
    if not isinstance(launcher["binary_format"], str) or not launcher["binary_format"].startswith("Mach-O"):
        raise PreparationError(f"{label}.launcher binary format is not Mach-O")
    if launcher["dependencies"] != _native_dependencies(binary):
        raise PreparationError(f"{label}.launcher dependencies mismatch")
    if launcher["canonical_physical_only"] is not True:
        raise PreparationError(f"{label}.launcher does not enforce canonical physical invocation")
    scrub = launcher["env_scrub"]
    if not isinstance(scrub, dict) or scrub != {
        "exact": [
            *REQUIRED_INJECTION_ENVIRONMENT_EXACT_SCRUB,
            *REQUIRED_AGENT_FLEET_ENVIRONMENT_SCRUB,
        ],
        "prefixes": [
            *REQUIRED_INJECTION_ENVIRONMENT_PREFIX_SCRUB,
            *REQUIRED_AGENT_FLEET_ENVIRONMENT_PREFIX_SCRUB,
        ],
    }:
        raise PreparationError(f"{label}.launcher environment scrub contract mismatch")
    _validate_signature_record(launcher["signature"], binary, f"{label} launcher")

    python = record["python"]
    if not isinstance(python, dict):
        raise PreparationError(f"{label}.python must be an object")
    _require_exact_keys(python, {"path", "sha256", "version"}, set(), f"{label}.python")
    python_path = _relative_record_path(root, python["path"], f"{label}.python.path")
    if (
        python_path != python_binary
        or python["sha256"] != _sha256(python_path)
        or python["sha256"] != expected_python_sha256
    ):
        raise PreparationError(f"{label}.python identity mismatch")
    if python["version"] != python_version:
        raise PreparationError(f"{label}.python version mismatch")

    wheel = record["wheel"]
    if not isinstance(wheel, dict):
        raise PreparationError(f"{label}.wheel must be an object")
    _require_exact_keys(wheel, {"path", "sha256"}, set(), f"{label}.wheel")
    wheel_path = _relative_record_path(root, wheel["path"], f"{label}.wheel.path")
    _require_regular(wheel_path, f"{label} source wheel")
    if wheel["sha256"] != _sha256(wheel_path):
        raise PreparationError(f"{label}.wheel SHA-256 mismatch")
    _validate_provenance_record(
        record["provenance"],
        root,
        source_commit,
        "agent_fleet",
        version,
        {
            "launcher": executable,
            "python": python_binary,
            "bootstrap": root / "launcher.py",
            "wheel": wheel_path,
        },
        label,
    )

    invocation = record["invocation"]
    if not isinstance(invocation, dict):
        raise PreparationError(f"{label}.invocation must be an object")
    _require_exact_keys(
        invocation,
        {"managed_relative_path", "config_relative_path", "hooks_relative_path", "operator_front_door"},
        set(),
        f"{label}.invocation",
    )
    for key in ("managed_relative_path", "config_relative_path", "hooks_relative_path"):
        if invocation[key] != launcher["path"]:
            raise PreparationError(f"{label}.invocation.{key} is not pinned to the launcher")
    front = invocation["operator_front_door"]
    if not isinstance(front, dict):
        raise PreparationError(f"{label} operator front door must be an object")
    _require_exact_keys(
        front,
        {
            "kind",
            "install_scope",
            "installed_name",
            "source_path",
            "source_sha256",
            "target_binding",
            "symlink_allowed",
        },
        set(),
        f"{label} operator front door",
    )
    front_source = _relative_record_path(root, front["source_path"], f"{label}.front_door.source_path")
    if front_source != root / "operator/agent-fleet":
        raise PreparationError(
            f"{label} operator front-door source path is not operator/agent-fleet"
        )
    _require_regular(
        front_source,
        f"{label} operator front-door source",
        mode=0o555,
        executable=True,
    )
    _require_native_macho(front_source, f"{label} operator front-door source")
    _verify_hardened_signature(front_source, f"{label} operator front-door source")
    if front["source_sha256"] != _sha256(front_source):
        raise PreparationError(f"{label} operator front-door source hash mismatch")
    if (
        front["kind"] != "native_regular_file"
        or front["install_scope"] != "user_local_bin"
        or front["installed_name"] != "agent-fleet"
    ):
        raise PreparationError(f"{label} operator front-door topology is not exact")
    if front["target_binding"] != launcher["sha256"]:
        raise PreparationError(f"{label} operator front door is not bound at compile time")
    if front["symlink_allowed"] is not False:
        raise PreparationError(f"{label} operator front door permits a symlink")

    probes = record["probes"]
    if not isinstance(probes, dict):
        raise PreparationError(f"{label}.probes must be an object")
    _require_exact_keys(
        probes,
        {"version", "contract", "hostile_environment", "relocated", "installed_topology"},
        set(),
        f"{label}.probes",
    )
    if probes["version"] != version or probes["contract"] != contract:
        raise PreparationError(f"{label}.probes version contract mismatch")
    for key in ("hostile_environment", "relocated", "installed_topology"):
        _require_true_probe(probes, key, f"{label}.probes")


def _compile_hostile_dylib(directory: Path, sentinel: Path) -> Path:
    source = directory / "hostile.c"
    dylib = directory / "hostile.dylib"
    source.write_text(
        "#include <fcntl.h>\n#include <stdlib.h>\n#include <unistd.h>\n"
        "__attribute__((constructor)) static void injected(void) {\n"
        "const char *p=getenv(\"BRIDGE_DYLD_SENTINEL\"); if(p){int f=open(p,O_WRONLY|O_CREAT|O_TRUNC,0600);"
        "if(f>=0){(void)write(f,\"dyld\",4);(void)close(f);}}}\n",
        encoding="utf-8",
    )
    try:
        completed = subprocess.run(
            ["/usr/bin/cc", "-dynamiclib", str(source), "-o", str(dylib)],
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise PreparationError(f"cannot compile hostile injection probe: {exc}") from exc
    if completed.returncode != 0:
        raise PreparationError(f"cannot compile hostile injection probe: {completed.stderr}")
    return dylib


def _probe_quota_launcher(binary: Path, expected_output: str, root: Path, label: str) -> None:
    before = _load_driver(Path(__file__).with_name("bridge_cutover_transaction.py")).compute_release_tree_sha256(root)
    with tempfile.TemporaryDirectory(prefix="bridge-quota-hostile-") as temporary:
        directory = Path(temporary)
        sentinel = directory / "sentinel"
        preload = directory / "preload.cjs"
        preload.write_text(
            f"require('fs').writeFileSync({json.dumps(str(sentinel))}, 'node');\n",
            encoding="utf-8",
        )
        dylib = _compile_hostile_dylib(directory, sentinel)
        hostile_bin = directory / "bin"
        hostile_bin.mkdir()
        fake_node = hostile_bin / "node"
        fake_node.write_text(f"#!/bin/sh\ntouch {json.dumps(str(sentinel))}\nexit 97\n", encoding="utf-8")
        fake_node.chmod(0o755)
        env = {
            "HOME": str(directory),
            "PATH": str(hostile_bin),
            "LANG": "C",
            "LC_ALL": "C",
            "BRIDGE_DYLD_SENTINEL": str(sentinel),
            "DYLD_INSERT_LIBRARIES": str(dylib),
            "NODE_OPTIONS": f"--require={preload}",
            "PYTHONPATH": str(directory / "python"),
            "BASH_ENV": str(directory / "shell-env"),
            "MALLOC_CHECK_": "3",
            "ELECTRON_RUN_AS_NODE": "1",
            "GCONV_PATH": str(directory),
            "LOCPATH": str(directory),
            "NLSPATH": str(directory),
            "SSLKEYLOGFILE": str(sentinel),
            "PERL5OPT": "-Mstrict",
        }
        try:
            completed = subprocess.run(
                [str(binary), "--version"],
                check=False,
                capture_output=True,
                text=True,
                env=env,
                timeout=30,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise PreparationError(f"{label} hostile-environment probe failed: {exc}") from exc
        if completed.returncode != 0 or completed.stdout.strip() != expected_output:
            raise PreparationError(f"{label} hostile-environment version probe failed")
        if sentinel.exists():
            raise PreparationError(f"{label} executed hostile environment injection")
    after = _load_driver(Path(__file__).with_name("bridge_cutover_transaction.py")).compute_release_tree_sha256(root)
    if after != before:
        raise PreparationError(f"{label} modified its sealed release tree")


def _validate_runtime_closure_manifest(
    root: Path,
    manifest_path: Path,
    record: Any,
    entrypoint: Path,
    label: str,
) -> str:
    if not isinstance(record, dict):
        raise PreparationError(f"{label}.runtime_manifest must be an object")
    _require_exact_keys(
        record,
        {
            "path",
            "sha256",
            "format",
            "entries_count",
            "closure_tree_sha256",
        },
        set(),
        f"{label}.runtime_manifest",
    )
    observed_path = _relative_record_path(
        root, record["path"], f"{label}.runtime_manifest.path"
    )
    if observed_path != manifest_path:
        raise PreparationError(f"{label}.runtime_manifest path is not exact")
    _require_regular(observed_path, f"{label} runtime closure manifest")
    manifest_sha256 = _sha256(observed_path)
    if (
        record["sha256"] != manifest_sha256
        or record["format"] != "bridge-runtime-closure-v1"
    ):
        raise PreparationError(f"{label}.runtime_manifest identity is not exact")
    payload = _read_json(observed_path, f"{label} runtime closure manifest")
    if not isinstance(payload, dict):
        raise PreparationError(f"{label} runtime closure manifest must be an object")
    _require_exact_keys(
        payload,
        {"schema_version", "format", "entries"},
        set(),
        f"{label} runtime closure manifest",
    )
    if (
        payload["schema_version"] != 1
        or payload["format"] != "bridge-runtime-closure-v1"
    ):
        raise PreparationError(f"{label} runtime closure schema is not exact")
    canonical_payload = (
        json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    ).encode("utf-8")
    if observed_path.read_bytes() != canonical_payload:
        raise PreparationError(f"{label} runtime closure manifest is not canonical JSON")
    entries = payload["entries"]
    if not isinstance(entries, list) or not entries:
        raise PreparationError(f"{label} runtime closure entries must be non-empty")
    paths: list[str] = []
    normalized_entries: list[dict[str, str]] = []
    for index, entry in enumerate(entries):
        entry_label = f"{label} runtime closure entries[{index}]"
        if not isinstance(entry, dict):
            raise PreparationError(f"{entry_label} must be an object")
        _require_exact_keys(entry, {"path", "mode", "sha256"}, set(), entry_label)
        relative = _normalized_relative(entry["path"], f"{entry_label}.path")
        target = root / relative
        _require_regular(target, entry_label)
        observed_mode = f"{stat.S_IMODE(os.lstat(target).st_mode):04o}"
        if entry["mode"] != observed_mode:
            raise PreparationError(f"{entry_label}.mode does not match the sealed file")
        if entry["sha256"] != _sha256(target):
            raise PreparationError(f"{entry_label}.sha256 does not match the sealed file")
        paths.append(relative)
        normalized_entries.append(dict(entry))
    expected_order = sorted(paths, key=lambda value: value.encode("utf-8"))
    if paths != expected_order or len(paths) != len(set(paths)):
        raise PreparationError(
            f"{label} runtime closure entries must be unique and UTF-8-byte sorted"
        )
    entrypoint_relative = str(entrypoint.relative_to(root))
    if entrypoint_relative not in paths:
        raise PreparationError(f"{label} runtime closure omits the entrypoint")
    closure_bytes = json.dumps(
        normalized_entries,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")
    closure_sha256 = hashlib.sha256(
        b"bridge-runtime-closure-v1\0" + closure_bytes
    ).hexdigest()
    if (
        record["entries_count"] != len(entries)
        or record["closure_tree_sha256"] != closure_sha256
    ):
        raise PreparationError(f"{label} runtime closure summary is not exact")
    return manifest_sha256


def _validate_quota_runtime_record(
    record: Mapping[str, Any],
    *,
    manifest_root: Path,
    release: ReleaseSpec,
    candidate: bool,
    binary: Path,
    node_binary: Path,
    entrypoint: Path,
    launcher_source: Path,
    provenance: Path,
    runtime_manifest: Path,
    package_lock: Path,
    version: str,
    node_version: str,
    expected_node_sha256: str,
    source_commit: str,
    driver: ModuleType,
    label: str,
) -> None:
    required = {
        "role", "release_path", "version", "source_commit", "tree_sha256",
        "rebuild_tree_sha256", "relocated_tree_sha256", "proofs", "launcher",
        "node", "entrypoint", "package_lock", "runtime_manifest", "provenance",
        "invocation", "probes",
    }
    _require_exact_keys(record, required, set(), label)
    root = _validate_common_runtime_record(
        record,
        manifest_root=manifest_root,
        release=release,
        candidate=candidate,
        version=version,
        source_commit=source_commit,
        driver=driver,
        label=label,
    )
    launcher = record["launcher"]
    if not isinstance(launcher, dict):
        raise PreparationError(f"{label}.launcher must be an object")
    _require_exact_keys(
        launcher,
        {
            "path", "sha256", "mode", "nlink", "binary_format", "source_path",
            "source_sha256", "dependencies", "signature", "fixed_path", "env_scrub",
            "runtime_manifest_sha256",
        },
        set(),
        f"{label}.launcher",
    )
    launcher_path = _relative_record_path(root, launcher["path"], f"{label}.launcher.path")
    source_path = _relative_record_path(root, launcher["source_path"], f"{label}.launcher.source_path")
    if launcher_path != binary or source_path != launcher_source:
        raise PreparationError(f"{label}.launcher paths do not match the sealed role")
    expected_launcher = _record_proof(launcher_path, root)
    for key in ("path", "sha256", "mode", "nlink"):
        if launcher[key] != expected_launcher[key]:
            raise PreparationError(f"{label}.launcher {key} mismatch")
    if launcher["source_sha256"] != _sha256(source_path):
        raise PreparationError(f"{label}.launcher source SHA-256 mismatch")
    if not isinstance(launcher["binary_format"], str) or not launcher["binary_format"].startswith("Mach-O"):
        raise PreparationError(f"{label}.launcher is not Mach-O")
    if launcher["dependencies"] != _native_dependencies(launcher_path):
        raise PreparationError(f"{label}.launcher dependencies mismatch")
    if launcher["fixed_path"] != "/usr/bin:/bin":
        raise PreparationError(f"{label}.launcher safe PATH is not exact")
    scrub = launcher["env_scrub"]
    if not isinstance(scrub, dict) or scrub != {
        "exact": list(REQUIRED_INJECTION_ENVIRONMENT_EXACT_SCRUB),
        "prefixes": list(REQUIRED_INJECTION_ENVIRONMENT_PREFIX_SCRUB),
    }:
        raise PreparationError(f"{label}.launcher environment scrub contract mismatch")
    _validate_signature_record(launcher["signature"], launcher_path, f"{label} launcher")

    runtime_manifest_sha256 = _validate_runtime_closure_manifest(
        root,
        runtime_manifest,
        record["runtime_manifest"],
        entrypoint,
        label,
    )
    if launcher["runtime_manifest_sha256"] != runtime_manifest_sha256:
        raise PreparationError(
            f"{label}.launcher is not bound to the exact runtime closure manifest"
        )

    node = record["node"]
    if not isinstance(node, dict):
        raise PreparationError(f"{label}.node must be an object")
    _require_exact_keys(
        node,
        {"path", "sha256", "mode", "nlink", "version", "signature_state", "operational"},
        set(),
        f"{label}.node",
    )
    node_path = _relative_record_path(root, node["path"], f"{label}.node.path")
    expected_node = _record_proof(node_path, root)
    if (
        node_path != node_binary
        or any(
            node[key] != expected_node[key]
            for key in ("path", "sha256", "mode", "nlink")
        )
        or node["sha256"] != expected_node_sha256
    ):
        raise PreparationError(f"{label}.node identity mismatch")
    if node["version"] != node_version or not isinstance(node["signature_state"], str):
        raise PreparationError(f"{label}.node version/signature-state mismatch")
    if node["operational"] is not False:
        raise PreparationError(f"{label}.node is incorrectly marked operational")

    js = record["entrypoint"]
    if not isinstance(js, dict):
        raise PreparationError(f"{label}.entrypoint must be an object")
    _require_exact_keys(js, {"path", "sha256", "mode", "nlink", "operational"}, set(), f"{label}.entrypoint")
    js_path = _relative_record_path(root, js["path"], f"{label}.entrypoint.path")
    expected_js = _record_proof(js_path, root)
    if js_path != entrypoint or any(js[key] != expected_js[key] for key in ("path", "sha256", "mode", "nlink")):
        raise PreparationError(f"{label}.entrypoint identity mismatch")
    if js["operational"] is not False:
        raise PreparationError(f"{label}.entrypoint is incorrectly marked operational")

    lock = record["package_lock"]
    if not isinstance(lock, dict):
        raise PreparationError(f"{label}.package_lock must be an object")
    _require_exact_keys(lock, {"path", "sha256"}, set(), f"{label}.package_lock")
    lock_path = _relative_record_path(root, lock["path"], f"{label}.package_lock.path")
    if lock_path != package_lock or lock["sha256"] != _sha256(lock_path):
        raise PreparationError(f"{label}.package_lock identity mismatch")
    _validate_provenance_record(
        record["provenance"],
        root,
        source_commit,
        "quota_axi",
        version,
        {
            "launcher": binary,
            "node": node_binary,
            "entrypoint": entrypoint,
            "package_lock": package_lock,
            "runtime_manifest": runtime_manifest,
            "quota_build_proof": root / "build" / "quota-build-proof.json",
        },
        label,
    )
    if _relative_record_path(root, record["provenance"]["path"], f"{label}.provenance.path") != provenance:
        raise PreparationError(f"{label}.provenance path mismatch")

    invocation = record["invocation"]
    if not isinstance(invocation, dict):
        raise PreparationError(f"{label}.invocation must be an object")
    expected_invocation = {
        "operational_relative_path": launcher["path"],
        "raw_node_forbidden": True,
        "raw_entrypoint_forbidden": True,
    }
    if invocation != expected_invocation:
        raise PreparationError(f"{label}.invocation does not forbid raw runtimes")
    probes = record["probes"]
    if not isinstance(probes, dict):
        raise PreparationError(f"{label}.probes must be an object")
    _require_exact_keys(probes, {"version", "help", "hostile_environment", "relocated", "canonical_path"}, set(), f"{label}.probes")
    if not isinstance(probes["version"], str) or version not in probes["version"]:
        raise PreparationError(f"{label}.probes.version mismatch")
    for key in ("help", "hostile_environment", "relocated", "canonical_path"):
        _require_true_probe(probes, key, f"{label}.probes")
    _probe_quota_launcher(launcher_path, probes["version"], root, label)


def _validate_closed_xattrs(roots: Sequence[Path]) -> None:
    allowed = {"com.apple.provenance"}
    for root in roots:
        paths = [root]
        for directory, directory_names, file_names in os.walk(
            root, topdown=True, followlinks=False
        ):
            directory_names.sort()
            file_names.sort()
            base = Path(directory)
            paths.extend(base / name for name in directory_names)
            paths.extend(base / name for name in file_names)
        for path in paths:
            if hasattr(os, "listxattr"):
                try:
                    observed = set(os.listxattr(path, follow_symlinks=False))
                except OSError as exc:
                    raise PreparationError(
                        f"cannot inspect sealed xattrs for {path}: {exc}"
                    ) from exc
            else:
                xattr_binary = Path("/usr/bin/xattr")
                _require_regular(
                    xattr_binary, "system xattr inspector", executable=True
                )
                try:
                    completed = subprocess.run(
                        [str(xattr_binary), "-s", str(path)],
                        check=False,
                        capture_output=True,
                        text=True,
                        env={"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
                        timeout=5,
                    )
                except (OSError, subprocess.TimeoutExpired) as exc:
                    raise PreparationError(
                        f"cannot inspect sealed xattrs for {path}: {exc}"
                    ) from exc
                if completed.returncode != 0:
                    raise PreparationError(
                        f"cannot inspect sealed xattrs for {path}: "
                        f"{completed.stderr.strip()}"
                    )
                observed = set(completed.stdout.splitlines())
            unexpected = observed - allowed
            if unexpected:
                raise PreparationError(
                    f"sealed release has forbidden xattrs at {path}: "
                    + ", ".join(sorted(unexpected))
                )


def _runtime_internal_symlink(root: Path, path: Path) -> tuple[str, Path]:
    target = os.readlink(path)
    if not target or "\x00" in target or "$" in target or os.path.isabs(target):
        raise PreparationError(
            f"pinned Python runtime has unsafe symlink: {path} -> {target!r}"
        )
    lexical = Path(os.path.normpath(path.parent / target))
    if not _is_relative_to(lexical, root):
        raise PreparationError(f"pinned Python runtime symlink escapes: {path}")
    resolved = Path(os.path.realpath(lexical))
    if not _is_relative_to(resolved, root):
        raise PreparationError(f"pinned Python runtime symlink resolves outside: {path}")
    _require_regular(resolved, "pinned Python runtime symlink target")
    return target, resolved


def _runtime_source_tree_sha256(root: Path) -> str:
    digest = hashlib.sha256(b"bridge-runtime-source-v1\0")
    observed = [root / "bin/python3.11", root / "lib"]
    for start in tuple(observed):
        if not start.exists() or start.is_symlink():
            raise PreparationError(f"pinned Python runtime root is invalid: {start}")
        if start.is_dir():
            observed.extend(start.rglob("*"))
    for path in sorted(
        set(observed),
        key=lambda item: item.relative_to(root).as_posix().encode("utf-8"),
    ):
        relative = path.relative_to(root).as_posix()
        info = os.lstat(path)
        if stat.S_ISLNK(info.st_mode):
            target, resolved = _runtime_internal_symlink(root, path)
            kind = b"symlink"
            value = hashlib.sha256(target.encode("utf-8")).digest()
            value += bytes.fromhex(_sha256(resolved))
        elif stat.S_ISDIR(info.st_mode):
            kind, value = b"directory", b""
        elif stat.S_ISREG(info.st_mode) and info.st_nlink == 1:
            kind, value = b"file", bytes.fromhex(_sha256(path))
        else:
            raise PreparationError(
                f"pinned Python runtime contains unsupported path: {path}"
            )
        digest.update(relative.encode("utf-8") + b"\0" + kind + b"\0" + value)
    return digest.hexdigest()


def _runtime_transformations(root: Path) -> list[dict[str, str]]:
    records: list[dict[str, str]] = []
    for path in sorted(
        (root / "lib").rglob("*"),
        key=lambda item: item.relative_to(root).as_posix().encode("utf-8"),
    ):
        if not path.is_symlink():
            continue
        target, resolved = _runtime_internal_symlink(root, path)
        records.append(
            {
                "path": path.relative_to(root).as_posix(),
                "target": target,
                "resolved_path": resolved.relative_to(root).as_posix(),
                "resolved_sha256": _sha256(resolved),
                "transformation": "materialize-internal-regular-file",
            }
        )
    return records


def _validate_materialized_python_runtime(source_root: Path, sealed_root: Path) -> None:
    """Bind the sealed regular-file closure to the retained lexical runtime tree."""

    expected: dict[str, tuple[str, str | None]] = {}
    starts = (source_root / "bin/python3.11", source_root / "lib")
    observed: list[Path] = list(starts)
    for start in starts:
        if start.is_dir():
            observed.extend(start.rglob("*"))
    for path in sorted(
        set(observed),
        key=lambda item: item.relative_to(source_root).as_posix().encode("utf-8"),
    ):
        relative = path.relative_to(source_root).as_posix()
        info = os.lstat(path)
        if stat.S_ISDIR(info.st_mode):
            expected[relative] = ("directory", None)
        elif stat.S_ISLNK(info.st_mode):
            _, resolved = _runtime_internal_symlink(source_root, path)
            expected[relative] = ("file", _sha256(resolved))
        elif stat.S_ISREG(info.st_mode) and info.st_nlink == 1:
            expected[relative] = ("file", _sha256(path))
        else:
            raise PreparationError(
                f"retained Python runtime contains unsupported path: {path}"
            )

    actual: dict[str, tuple[str, str | None]] = {}
    sealed_starts = (sealed_root / "bin/python3.11", sealed_root / "lib")
    sealed_paths: list[Path] = list(sealed_starts)
    for start in sealed_starts:
        if start.is_dir():
            sealed_paths.extend(start.rglob("*"))
    for path in sorted(
        set(sealed_paths),
        key=lambda item: item.relative_to(sealed_root).as_posix().encode("utf-8"),
    ):
        relative = path.relative_to(sealed_root).as_posix()
        info = os.lstat(path)
        if stat.S_ISDIR(info.st_mode):
            actual[relative] = ("directory", None)
        elif stat.S_ISREG(info.st_mode) and not stat.S_ISLNK(info.st_mode):
            actual[relative] = ("file", _sha256(path))
        else:
            raise PreparationError(
                f"sealed Python runtime is not fully materialized: {path}"
            )
    if actual != expected:
        raise PreparationError(
            f"sealed Python runtime closure differs from retained runtime: {sealed_root}"
        )


def _build_input_file(
    record: Any, label: str, *, allow_root_hardlinks: bool = False
) -> Path:
    if not isinstance(record, dict):
        raise PreparationError(f"{label} must be an object")
    _require_exact_keys(record, {"path", "sha256"}, set(), label)
    path = _normalized_absolute(record["path"], f"{label}.path")
    _require_regular(path, label, allow_root_hardlinks=allow_root_hardlinks)
    if not isinstance(record["sha256"], str) or not SHA256.fullmatch(
        record["sha256"]
    ):
        raise PreparationError(f"{label}.sha256 is invalid")
    if _sha256(path, allow_root_hardlinks=allow_root_hardlinks) != record["sha256"]:
        raise PreparationError(f"{label} digest changed")
    return path


def _validate_build_inputs(
    value: Any,
    proof_path: Path,
) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        raise PreparationError("sealed runtime build_inputs must be an object")
    _require_exact_keys(
        value,
        {
            "schema_version",
            "manifest_path",
            "manifest",
            "manifest_sha256",
            "manifest_canonical_sha256",
            "builder",
            "bootstrap",
            "transaction_driver",
            "tools",
            "python_runtime",
            "node_runtime",
            "agent_fleet",
            "quota_axi",
        },
        set(),
        "sealed runtime build_inputs",
    )
    if value["schema_version"] != 1 or not isinstance(value["manifest"], dict):
        raise PreparationError("sealed runtime build_inputs schema is invalid")
    manifest_path = _normalized_absolute(
        value["manifest_path"], "build_inputs.manifest_path"
    )
    _require_regular(manifest_path, "retained sealed-runtime builder manifest")
    raw_manifest = _read_json(manifest_path, "retained sealed-runtime builder manifest")
    if raw_manifest != value["manifest"]:
        raise PreparationError("retained builder manifest does not match build_inputs")
    if (
        value["manifest_sha256"] != _sha256(manifest_path)
        or not isinstance(value["manifest_sha256"], str)
        or not SHA256.fullmatch(value["manifest_sha256"])
    ):
        raise PreparationError("retained builder manifest digest is invalid")
    canonical = (
        json.dumps(raw_manifest, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    ).encode("utf-8")
    if value["manifest_canonical_sha256"] != hashlib.sha256(canonical).hexdigest():
        raise PreparationError("retained builder manifest canonical digest is invalid")
    if raw_manifest.get("proof_manifest") != str(proof_path):
        raise PreparationError("retained builder manifest targets a different proof")

    _build_input_file(value["builder"], "retained sealed-runtime builder")
    _build_input_file(value["bootstrap"], "retained Agent Fleet bootstrap")
    driver = _build_input_file(
        value["transaction_driver"], "retained transaction driver"
    )
    if raw_manifest.get("transaction_driver") != value["transaction_driver"]:
        raise PreparationError("retained transaction-driver binding differs from manifest")
    if not isinstance(value["tools"], dict) or value["tools"] != raw_manifest.get("tools"):
        raise PreparationError("retained tool bindings differ from builder manifest")
    for name, record in value["tools"].items():
        path = _build_input_file(
            record,
            f"retained build tool {name}",
            allow_root_hardlinks=True,
        )
        if name in {"clang", "codesign", "file", "git", "otool", "xattr"}:
            expected = Path(f"/usr/bin/{name}")
            if path != expected or os.lstat(path).st_uid != 0:
                raise PreparationError(f"retained build tool {name} is not immutable")
    if driver != _normalized_absolute(
        raw_manifest["transaction_driver"]["path"], "manifest transaction driver"
    ):
        raise PreparationError("retained transaction-driver path mismatch")

    python = value["python_runtime"]
    if not isinstance(python, dict):
        raise PreparationError("build_inputs.python_runtime must be an object")
    _require_exact_keys(
        python,
        {
            "root",
            "version",
            "binary_sha256",
            "source_tree_sha256",
            "transformations",
        },
        set(),
        "build_inputs.python_runtime",
    )
    raw_python = raw_manifest.get("python_runtime")
    if not isinstance(raw_python, dict):
        raise PreparationError("retained manifest Python runtime is invalid")
    root = _normalized_absolute(python["root"], "build_inputs.python_runtime.root")
    _require_directory(root, "retained Python runtime")
    if (
        python["version"] != raw_python.get("version")
        or python["binary_sha256"] != raw_python.get("binary_sha256")
        or python["source_tree_sha256"] != raw_python.get("tree_sha256")
        or _sha256(root / "bin/python3.11") != python["binary_sha256"]
        or _runtime_source_tree_sha256(root) != python["source_tree_sha256"]
        or _runtime_transformations(root) != python["transformations"]
    ):
        raise PreparationError("retained Python runtime proof changed")

    node = value["node_runtime"]
    if not isinstance(node, dict):
        raise PreparationError("build_inputs.node_runtime must be an object")
    _require_exact_keys(node, {"path", "version", "sha256"}, set(), "node runtime")
    node_path = _build_input_file(
        {"path": node["path"], "sha256": node["sha256"]},
        "retained Node runtime",
    )
    raw_node = raw_manifest.get("node_runtime")
    if not isinstance(raw_node, dict) or raw_node != {
        "binary": str(node_path),
        "version": node["version"],
        "sha256": node["sha256"],
    }:
        raise PreparationError("retained Node runtime differs from builder manifest")

    for family, artifact_fields in (
        ("agent_fleet", (("wheel", "wheel_sha256"),)),
        (
            "quota_axi",
            (
                ("package_tarball", "package_sha256"),
                ("package_lock", "package_lock_sha256"),
                ("build_proof", "build_proof_sha256"),
            ),
        ),
    ):
        records = value[family]
        raw_records = raw_manifest.get(family)
        if not isinstance(records, dict) or set(records) != {"candidate", "rollback"}:
            raise PreparationError(f"build_inputs.{family} roles are not exact")
        if not isinstance(raw_records, dict):
            raise PreparationError(f"retained manifest {family} roles are invalid")
        for role_name, record in records.items():
            raw_role = raw_records.get(role_name)
            if not isinstance(record, dict) or not isinstance(raw_role, dict):
                raise PreparationError(f"build_inputs.{family}.{role_name} is invalid")
            expected_record_keys = {
                "source_repo",
                "source_commit",
                "source_tree_sha256",
                *(
                    {"source_subdirectory", "wheel", "wheel_sha256"}
                    if family == "agent_fleet"
                    else {
                        "package_tarball",
                        "package_sha256",
                        "package_lock",
                        "package_lock_sha256",
                        "build_proof",
                        "build_proof_sha256",
                        "dependencies",
                    }
                ),
            }
            _require_exact_keys(
                record,
                expected_record_keys,
                set(),
                f"build_inputs.{family}.{role_name}",
            )
            for field in ("source_repo", "source_commit", "source_tree_sha256"):
                if record.get(field) != raw_role.get(field):
                    raise PreparationError(
                        f"build_inputs.{family}.{role_name}.{field} differs from manifest"
                    )
            if family == "agent_fleet":
                source_subdirectory = record.get("source_subdirectory")
                if (
                    source_subdirectory != raw_role.get("source_subdirectory")
                    or not isinstance(source_subdirectory, str)
                    or not source_subdirectory
                ):
                    raise PreparationError(
                        f"build_inputs.{family}.{role_name}.source_subdirectory is invalid"
                    )
                if source_subdirectory != ".":
                    _normalized_relative(
                        source_subdirectory,
                        f"build_inputs.{family}.{role_name}.source_subdirectory",
                    )
            if (
                not isinstance(record["source_commit"], str)
                or not GIT_COMMIT.fullmatch(record["source_commit"])
                or not isinstance(record["source_tree_sha256"], str)
                or not SHA256.fullmatch(record["source_tree_sha256"])
            ):
                raise PreparationError(
                    f"build_inputs.{family}.{role_name} source identity is invalid"
                )
            source_repo = _normalized_absolute(
                record.get("source_repo"),
                f"build_inputs.{family}.{role_name}.source_repo",
            )
            _require_directory(
                source_repo, f"retained {family} {role_name} source repository"
            )
            for path_field, sha_field in artifact_fields:
                path = _build_input_file(
                    {"path": record.get(path_field), "sha256": record.get(sha_field)},
                    f"retained {family} {role_name} {path_field}",
                )
                if (
                    raw_role.get(path_field) != str(path)
                    or raw_role.get(sha_field) != record.get(sha_field)
                ):
                    raise PreparationError(
                        f"retained {family} {role_name} {path_field} differs from manifest"
                    )
            if family == "quota_axi":
                if record.get("dependencies") != raw_role.get("dependencies"):
                    raise PreparationError(
                        f"retained Quota {role_name} dependency closure differs"
                    )
                for dependency in record.get("dependencies", []):
                    if not isinstance(dependency, dict):
                        raise PreparationError("retained Quota dependency is invalid")
                    _require_exact_keys(
                        dependency,
                        {
                            "name",
                            "version",
                            "install_path",
                            "tarball",
                            "sha256",
                            "integrity",
                        },
                        set(),
                        "retained Quota dependency",
                    )
                    _build_input_file(
                        {
                            "path": dependency.get("tarball"),
                            "sha256": dependency.get("sha256"),
                        },
                        f"retained Quota {role_name} dependency",
                    )
    return value


def _validate_sealed_runtime_manifest(
    spec: PreparationSpec,
    driver: ModuleType,
    manifest_path: Path | None = None,
) -> dict[str, Any]:
    path = manifest_path or spec.agent_fleet.build_manifest
    raw = _read_json(path, "sealed runtime proof manifest")
    if not isinstance(raw, dict):
        raise PreparationError("sealed runtime proof manifest must be an object")
    top_keys = {
        "schema_version", "agent_fleet_candidate", "agent_fleet_rollback",
        "quota_axi_candidate", "quota_axi_rollback", "xattr_policy", "nondeterminism",
        "build_inputs", "runtime_versions",
    }
    _require_exact_keys(raw, top_keys, set(), "sealed runtime proof manifest")
    if raw["schema_version"] != 2:
        raise PreparationError("sealed runtime proof manifest schema must be 2")
    build_inputs = _validate_build_inputs(
        raw["build_inputs"], spec.agent_fleet.build_manifest
    )
    # Role release paths are relative to the sealed-runtime root that owns the
    # source manifest.  A bundle carries a byte-for-byte proof copy elsewhere,
    # but relocation of that proof document must not retarget any runtime.
    manifest_root = spec.agent_fleet.build_manifest.parent
    af = spec.agent_fleet
    quota = spec.quota
    _validate_agent_runtime_record(
        raw["agent_fleet_candidate"], manifest_root=manifest_root, release=af.release,
        candidate=True, executable=af.executable, python_binary=af.python_binary,
        python_version=af.expected_python_version,
        expected_python_sha256=build_inputs["python_runtime"]["binary_sha256"],
        version=af.expected_version,
        contract=af.expected_contract_version, source_commit=af.source_commit,
        driver=driver, label="agent_fleet_candidate",
    )
    _validate_agent_runtime_record(
        raw["agent_fleet_rollback"], manifest_root=manifest_root, release=af.release,
        candidate=False, executable=af.rollback_executable,
        python_binary=af.release.old_release / "bin/python3.11",
        python_version=af.rollback_python_version,
        expected_python_sha256=build_inputs["python_runtime"]["binary_sha256"],
        version=af.rollback_version, contract=af.rollback_contract_version,
        source_commit=af.rollback_source_commit, driver=driver,
        label="agent_fleet_rollback",
    )
    _validate_quota_runtime_record(
        raw["quota_axi_candidate"], manifest_root=manifest_root, release=quota.release,
        candidate=True, binary=quota.binary, node_binary=quota.node_binary,
        entrypoint=quota.entrypoint, launcher_source=quota.launcher_source,
        provenance=quota.build_provenance,
        runtime_manifest=quota.runtime_manifest,
        package_lock=quota.package_lock,
        version=quota.expected_version, node_version=quota.node_version,
        expected_node_sha256=build_inputs["node_runtime"]["sha256"],
        source_commit=quota.source_commit, driver=driver, label="quota_axi_candidate",
    )
    _validate_quota_runtime_record(
        raw["quota_axi_rollback"], manifest_root=manifest_root, release=quota.release,
        candidate=False, binary=quota.rollback_binary,
        node_binary=quota.rollback_node_binary, entrypoint=quota.rollback_entrypoint,
        launcher_source=quota.rollback_launcher_source,
        provenance=quota.rollback_build_provenance,
        runtime_manifest=quota.rollback_runtime_manifest,
        package_lock=quota.rollback_package_lock, version=quota.rollback_version,
        node_version=quota.rollback_node_version,
        expected_node_sha256=build_inputs["node_runtime"]["sha256"],
        source_commit=quota.rollback_source_commit, driver=driver,
        label="quota_axi_rollback",
    )
    python_inputs = build_inputs["python_runtime"]
    for root, label in (
        (af.release.new_release, "agent_fleet_candidate"),
        (af.release.old_release, "agent_fleet_rollback"),
    ):
        provenance = _read_json(root / "build/provenance.json", f"{label} provenance")
        if (
            provenance.get("python_runtime_source_tree_sha256")
            != python_inputs["source_tree_sha256"]
            or provenance.get("python_runtime_transformations")
            != python_inputs["transformations"]
        ):
            raise PreparationError(
                f"{label} provenance does not bind the retained Python transformation proof"
            )
        _validate_materialized_python_runtime(Path(python_inputs["root"]), root)
    xattrs = raw["xattr_policy"]
    if not isinstance(xattrs, dict):
        raise PreparationError("xattr_policy must be an object")
    _require_exact_keys(
        xattrs,
        {"allowed_system_xattrs", "stripped_source_xattrs", "enforcement"},
        set(),
        "xattr_policy",
    )
    if xattrs["allowed_system_xattrs"] != ["com.apple.provenance"]:
        raise PreparationError("xattr_policy allowed system xattrs are not exact")
    if xattrs["stripped_source_xattrs"] is not True or xattrs["enforcement"] != "closed_tree":
        raise PreparationError("xattr_policy was not enforced")
    _validate_closed_xattrs(
        (
            af.release.new_release,
            af.release.old_release,
            quota.release.new_release,
            quota.release.old_release,
        )
    )
    nondeterminism = raw["nondeterminism"]
    if not isinstance(nondeterminism, dict):
        raise PreparationError("nondeterminism must be an object")
    _require_exact_keys(
        nondeterminism,
        {"builds", "tree_hashes_match", "relocated_hashes_match", "known_exclusions"},
        set(),
        "nondeterminism",
    )
    if (
        not isinstance(nondeterminism["builds"], int)
        or nondeterminism["builds"] < 2
        or nondeterminism["tree_hashes_match"] is not True
        or nondeterminism["relocated_hashes_match"] is not True
        or nondeterminism["known_exclusions"] != []
    ):
        raise PreparationError("sealed runtime builds are not deterministic and relocation-stable")
    runtime_versions = raw["runtime_versions"]
    if not isinstance(runtime_versions, dict):
        raise PreparationError("runtime_versions must be an object")
    _require_exact_keys(
        runtime_versions,
        {"schema_version", "closed_environment", "observed"},
        set(),
        "runtime_versions",
    )
    expected_versions = {
        "agent_fleet_candidate": f"Python {af.expected_python_version}",
        "agent_fleet_rollback": f"Python {af.rollback_python_version}",
        "quota_axi_candidate": f"v{quota.node_version}",
        "quota_axi_rollback": f"v{quota.rollback_node_version}",
    }
    if (
        runtime_versions["schema_version"] != 1
        or runtime_versions["closed_environment"] is not True
        or runtime_versions["observed"] != expected_versions
    ):
        raise PreparationError("closed-environment runtime version proof is not exact")
    return raw


def _validate_quota_release_tree(spec: QuotaSpec, driver: ModuleType) -> None:
    observed = driver.compute_release_tree_sha256(
        spec.release.new_release,
        "sealed Quota release tree",
    )
    if observed != spec.release_tree_sha256:
        raise PreparationError(
            f"sealed Quota release tree SHA-256 is {observed}; "
            f"expected {spec.release_tree_sha256}"
        )


def _release_operation(driver: ModuleType, release: ReleaseSpec) -> dict[str, Any]:
    return {
        "kind": "symlink",
        "name": release.name,
        "path": str(release.current_link),
        "old_target": release.old_target,
        "new_target": release.new_target,
        "old_proofs": [
            driver.compute_release_proof(release.old_release, relative)
            for relative in release.old_proof_paths
        ],
        "new_proofs": [
            driver.compute_release_proof(release.new_release, relative)
            for relative in release.new_proof_paths
        ],
        "old_tree_sha256": driver.compute_release_tree_sha256(release.old_release),
        "new_tree_sha256": driver.compute_release_tree_sha256(release.new_release),
    }


def _allowed_roots(spec: PreparationSpec) -> list[str]:
    candidates = [
        spec.agent_fleet.release.current_link.parent,
        spec.agent_fleet.operator_front_door.parent,
        spec.quota.release.current_link.parent,
        spec.live_registry.parent,
        spec.output_dir,
        spec.sealed_adoption.backend_path.parent,
        *(path.parent for path in spec.sealed_adoption.routing_absent_paths),
        *(path.parent for path in spec.sealed_adoption.state_quiet_paths),
    ]
    unique = list(dict.fromkeys(candidates))
    roots = [
        candidate
        for candidate in unique
        if not any(
            candidate != other and _is_relative_to(candidate, other)
            for other in unique
        )
    ]
    for left in roots:
        for right in roots:
            if left != right and (_is_relative_to(left, right) or _is_relative_to(right, left)):
                raise PreparationError(
                    f"derived transaction allowed roots overlap: {left}, {right}"
                )
    return [str(root) for root in roots]


def _quiet_point_dict(spec: PreparationSpec) -> dict[str, Any]:
    adoption = spec.sealed_adoption
    return {
        "profile_ids": sorted(EXPECTED_TOPOLOGY),
        "worker_profile_ids": sorted(WORKER_PROFILES),
        "never_enroll_profile_ids": sorted(RESERVE_PROFILES),
        "routing_absent_paths": [str(path) for path in adoption.routing_absent_paths],
        "backend_path": str(adoption.backend_path),
        "backend_sha256": adoption.backend_sha256,
        "state_quiet_paths": [str(path) for path in adoption.state_quiet_paths],
        "forbidden_process_tokens": list(adoption.forbidden_process_tokens),
        "ps_binary": str(adoption.ps_binary),
        "ps_binary_sha256": adoption.ps_binary_sha256,
    }


def _manifest_dict(
    spec: PreparationSpec,
    driver: ModuleType,
    old_source: Path,
    new_source: Path,
    lock_path: Path,
    journal_path: Path,
    *,
    old_sha256: str | None = None,
    new_sha256: str | None = None,
) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "transaction_id": spec.transaction_id,
        "apply_opt_in": spec.apply_opt_in,
        "allowed_roots": _allowed_roots(spec),
        "lock_path": str(lock_path),
        "journal_path": str(journal_path),
        "quiet_point": _quiet_point_dict(spec),
        "operations": [
            _release_operation(driver, spec.quota.release),
            _release_operation(driver, spec.agent_fleet.release),
            {
                "kind": "regular-file",
                "name": "agent-fleet-front-door",
                "path": str(spec.agent_fleet.operator_front_door),
                "old_source": str(spec.agent_fleet.rollback_front_door),
                "new_source": str(spec.agent_fleet.candidate_front_door),
                "old_sha256": _sha256(spec.agent_fleet.rollback_front_door),
                "new_sha256": _sha256(spec.agent_fleet.candidate_front_door),
                "mode": "0555",
            },
            {
                "kind": "registry",
                "name": "accounts-registry",
                "path": str(spec.live_registry),
                "old_source": str(old_source),
                "new_source": str(new_source),
                "old_sha256": old_sha256 or _sha256(old_source),
                "new_sha256": new_sha256 or _sha256(new_source),
                "mode": "0600",
            },
        ],
    }


def _adoption_link_operation(
    driver: ModuleType,
    release: ReleaseSpec,
    initial_target: str,
) -> dict[str, Any]:
    return {
        "name": release.name,
        "path": str(release.current_link),
        "initial_target": initial_target,
        "sealed_target": release.old_target,
        "sealed_release": str(release.old_release),
        "sealed_proofs": [
            driver.compute_release_proof(release.old_release, relative)
            for relative in release.old_proof_paths
        ],
        "sealed_tree_sha256": driver.compute_release_tree_sha256(release.old_release),
    }


def _adoption_manifest_dict(
    spec: PreparationSpec,
    driver: ModuleType,
    initial_source: Path,
    sealed_source: Path,
    lock_path: Path,
    journal_path: Path,
    *,
    initial_sha256: str | None = None,
    sealed_sha256: str | None = None,
) -> dict[str, Any]:
    transaction_id = f"{spec.transaction_id}-adopt"
    if len(transaction_id) > 64:
        raise PreparationError("transaction_id is too long for sealed-adoption suffix")
    return {
        "schema_version": 1,
        "transaction_id": transaction_id,
        "apply_opt_in": spec.apply_opt_in,
        "allowed_roots": _allowed_roots(spec),
        "lock_path": str(lock_path),
        "journal_path": str(journal_path),
        "quiet_point": _quiet_point_dict(spec),
        "link_operations": [
            _adoption_link_operation(
                driver,
                spec.quota.release,
                spec.sealed_adoption.quota_initial_target,
            ),
            _adoption_link_operation(
                driver,
                spec.agent_fleet.release,
                spec.sealed_adoption.agent_fleet_initial_target,
            ),
        ],
        "front_door_operation": {
            "name": "agent-fleet-front-door",
            "path": str(spec.agent_fleet.operator_front_door),
            "initial_target": (
                spec.sealed_adoption.agent_fleet_front_door_initial_target
            ),
            "sealed_source": str(spec.agent_fleet.rollback_front_door),
            "sealed_sha256": _sha256(spec.agent_fleet.rollback_front_door),
            "mode": "0555",
        },
        "registry_operation": {
            "name": "accounts-registry",
            "path": str(spec.live_registry),
            "initial_source": str(initial_source),
            "sealed_source": str(sealed_source),
            "initial_sha256": initial_sha256 or _sha256(initial_source),
            "sealed_sha256": sealed_sha256 or _sha256(sealed_source),
            "mode": "0600",
        },
    }


def _topology_summary() -> dict[str, dict[str, Any]]:
    return {
        profile_id: {
            "provider": provider,
            "pools": list(pools),
            "safety_policy": policy,
            "enabled": False,
            "never_enroll": policy != "worker",
            "fleet_managed": policy == "worker",
        }
        for profile_id, (provider, pools, policy) in EXPECTED_TOPOLOGY.items()
    }


def _canonical_json_bytes(value: Any) -> bytes:
    try:
        return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")
    except (TypeError, ValueError) as exc:
        raise PreparationError(f"value is not canonical JSON: {exc}") from exc


def _invoke_pure_provision_api(function: Any, *arguments: Any) -> Any:
    """Call a sealed planning API while refusing process or shell execution."""

    if not callable(function):
        raise PreparationError("sealed Agent Fleet provision API is not callable")

    def refused(*_args: Any, **_kwargs: Any) -> Any:
        raise PreparationError(
            "sealed Agent Fleet planning API attempted process or shell execution"
        )

    patched: list[tuple[Any, str, Any]] = []
    for owner, names in (
        (
            subprocess,
            ("Popen", "run", "call", "check_call", "check_output", "getoutput", "getstatusoutput"),
        ),
        (os, ("system", "popen", "spawnl", "spawnle", "spawnlp", "spawnlpe", "spawnv", "spawnve", "spawnvp", "spawnvpe")),
    ):
        for name in names:
            if hasattr(owner, name):
                patched.append((owner, name, getattr(owner, name)))
                setattr(owner, name, refused)
    try:
        return function(*arguments)
    except PreparationError:
        raise
    except Exception as exc:
        raise PreparationError(f"sealed Agent Fleet planning API failed: {exc}") from exc
    finally:
        for owner, name, original in reversed(patched):
            setattr(owner, name, original)


def _validate_provision_plan_entry(
    value: Any,
    label: str,
) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise PreparationError(f"{label} must be an object")
    entry_type = value.get("type")
    required_by_type = {
        "file": {"relative_path", "type", "mode", "sha256"},
        "dir": {"relative_path", "type", "mode"},
        "symlink": {"relative_path", "type", "target"},
    }
    required = required_by_type.get(entry_type)
    if required is None:
        raise PreparationError(f"{label}.type is not file, dir, or symlink")
    _require_exact_keys(value, required, set(), label)
    relative = value["relative_path"]
    if relative != ".":
        _normalized_relative(relative, f"{label}.relative_path")
    if entry_type in {"file", "dir"}:
        expected_mode = "0600" if entry_type == "file" else "0700"
        if value["mode"] != expected_mode:
            raise PreparationError(
                f"{label}.mode is {value['mode']!r}; expected {expected_mode!r}"
            )
    if entry_type == "file" and (
        not isinstance(value["sha256"], str) or not SHA256.fullmatch(value["sha256"])
    ):
        raise PreparationError(f"{label}.sha256 is not a lowercase SHA-256")
    if entry_type == "symlink":
        _normalized_absolute(value["target"], f"{label}.target")
    return dict(value)


def _validate_provision_plan(
    registry: Any,
    profile_id: str,
    raw_plan: Any,
    closed_claude_sha256: str,
) -> dict[str, Any]:
    label = f"provision plan {profile_id}"
    if not isinstance(raw_plan, dict):
        raise PreparationError(f"{label} must be an object")
    _require_exact_keys(
        raw_plan,
        {"schema", "profile", "provider", "home", "safety_policy", "entries"},
        set(),
        label,
    )
    if raw_plan["schema"] != 1:
        raise PreparationError(f"{label}.schema must be 1")
    if raw_plan["profile"] != profile_id:
        raise PreparationError(f"{label}.profile is not exact")
    profile = registry.profiles.get(profile_id)
    if profile is None:
        raise PreparationError(f"{label} refers to an absent profile")
    expected_provider = EXPECTED_TOPOLOGY[profile_id][0]
    if raw_plan["provider"] != expected_provider or profile.provider != expected_provider:
        raise PreparationError(f"{label}.provider is not exact")
    if raw_plan["safety_policy"] != "worker" or profile.safety_policy != "worker":
        raise PreparationError(f"{label} is not a worker-only plan")
    expected_home = _normalized_absolute(str(profile.home), f"{label} expected home")
    observed_home = _normalized_absolute(raw_plan["home"], f"{label}.home")
    if observed_home != expected_home:
        raise PreparationError(f"{label}.home is not the exact worker home")
    raw_entries = raw_plan["entries"]
    if not isinstance(raw_entries, list) or not raw_entries:
        raise PreparationError(f"{label}.entries must be a non-empty array")
    entries = [
        _validate_provision_plan_entry(item, f"{label}.entries[{index}]")
        for index, item in enumerate(raw_entries)
    ]
    paths = [entry["relative_path"] for entry in entries]
    if paths != sorted(paths) or len(paths) != len(set(paths)):
        raise PreparationError(f"{label}.entries must be uniquely path-sorted")
    if any(path == "plugins" or path.startswith("plugins/") for path in paths):
        raise PreparationError(f"{label} contains forbidden legacy plugins state")

    common_files = {
        ".agent-fleet-hooks.json",
        ".agent-fleet-profile.json",
        ".agent-fleet-provider-binary.json",
    }
    provider_files = (
        {".claude.json", "settings.json"}
        if expected_provider == "claude"
        else {"config.toml", "hooks.json"}
    )
    provider = registry.providers[expected_provider]
    allowed_shared = (
        {"CLAUDE.md", "skills"}
        if expected_provider == "claude"
        else {"AGENTS.md", "rules", "skills"}
    )
    configured_shared = tuple(provider.shared_entries)
    if len(configured_shared) != len(set(configured_shared)) or any(
        entry not in allowed_shared for entry in configured_shared
    ):
        raise PreparationError(f"{label} provider shared entries are not exact")
    expected_paths = {
        ".",
        "hooks",
        *common_files,
        *provider_files,
        *configured_shared,
    }
    if set(paths) != expected_paths:
        missing = sorted(expected_paths - set(paths))
        unexpected = sorted(set(paths) - expected_paths)
        raise PreparationError(
            f"{label}.entries are not the exact managed set; "
            f"missing={missing}, unexpected={unexpected}"
        )
    by_path = {entry["relative_path"]: entry for entry in entries}
    if by_path["."] != {"relative_path": ".", "type": "dir", "mode": "0700"}:
        raise PreparationError(f"{label} has an invalid profile-home root entry")
    if by_path["hooks"] != {
        "relative_path": "hooks",
        "type": "dir",
        "mode": "0700",
    }:
        raise PreparationError(f"{label} has an invalid empty hooks directory entry")
    for path in common_files | provider_files:
        if by_path[path]["type"] != "file":
            raise PreparationError(f"{label} managed file is not a file: {path}")
    if expected_provider == "claude" and by_path[".claude.json"]["sha256"] != closed_claude_sha256:
        raise PreparationError(
            f"{label} .claude.json is not bound to the canonical closed trust state"
        )
    base_home = getattr(provider, "base_home", None)
    if configured_shared and base_home is None:
        raise PreparationError(f"{label} has shared entries without a provider base home")
    for shared in configured_shared:
        entry = by_path[shared]
        expected_target = _normalized_absolute(
            str(Path(base_home) / shared), f"{label} expected target {shared}"
        )
        if entry != {
            "relative_path": shared,
            "type": "symlink",
            "target": str(expected_target),
        }:
            raise PreparationError(f"{label} has an invalid workflow link: {shared}")
    canonical = dict(raw_plan)
    canonical["entries"] = entries
    return canonical


def _sealed_provision_contract(
    api: AgentFleetAPI,
    registry: Any,
) -> dict[str, Any]:
    if api.provision is None:
        raise PreparationError("candidate Agent Fleet provision API was not loaded")
    if api.identity is None:
        raise PreparationError("candidate Agent Fleet identity API was not loaded")
    observed_closed = _invoke_pure_provision_api(
        api.provision.closed_claude_state_payload,
        registry,
    )
    expected_roots = sorted(
        str(_normalized_absolute(str(path), "Claude trusted project"))
        for path in registry.providers["claude"].trusted_projects
    )
    expected_closed = {
        "hasCompletedOnboarding": True,
        "projects": {
            root: {
                "hasCompletedProjectOnboarding": True,
                "hasTrustDialogAccepted": True,
            }
            for root in expected_roots
        },
    }
    if observed_closed != expected_closed or list(observed_closed.get("projects", {})) != expected_roots:
        raise PreparationError("Claude closed-state payload is not the exact canonical state")
    closed_sha256 = hashlib.sha256(_canonical_json_bytes(observed_closed)).hexdigest()
    plans: dict[str, dict[str, Any]] = {}
    for profile_id in WORKER_PROFILES:
        raw_plan = _invoke_pure_provision_api(
            api.provision.provision_plan,
            registry,
            profile_id,
        )
        plan = _validate_provision_plan(
            registry,
            profile_id,
            raw_plan,
            closed_sha256,
        )
        plans[profile_id] = {
            "plan": plan,
            "plan_sha256": hashlib.sha256(_canonical_json_bytes(plan)).hexdigest(),
        }
    if tuple(plans) != WORKER_PROFILES:
        raise PreparationError("sealed provision plans do not cover exactly six workers")
    state_dir = _normalized_absolute(
        str(registry.settings.state_dir), "candidate identity state directory"
    )
    identity_paths: dict[str, str] = {}
    identity_workers: dict[str, list[str]] = {}
    for provider in ("claude", "codex"):
        observed_path = _invoke_pure_provision_api(
            api.identity.identity_bundle_path,
            registry,
            provider,
        )
        expected_path = state_dir / "identity-bindings" / f"{provider}-bundle.json"
        normalized_path = _normalized_absolute(
            str(observed_path), f"{provider} identity bundle path"
        )
        if normalized_path != expected_path:
            raise PreparationError(f"{provider} identity bundle path is not exact")
        identity_paths[provider] = str(normalized_path)
        identity_workers[provider] = [
            profile_id
            for profile_id in WORKER_PROFILES
            if EXPECTED_TOPOLOGY[profile_id][0] == provider
        ]
    return {
        "schema_version": 1,
        "closed_claude_state": {
            "payload": observed_closed,
            "sha256": closed_sha256,
        },
        "plans": plans,
        "identity_bundles": {
            "schema_version": 1,
            "atomic_provider_bundles": True,
            "paths": identity_paths,
            "worker_profiles": identity_workers,
            "snapshot_compare_live_external": False,
            "readiness_compare_live_external": True,
        },
    }


def _activation_plan(provision_contract: Mapping[str, Any]) -> dict[str, Any]:
    """Return a command-free activation contract for reviewed human gates."""

    return {
        "schema_version": 2,
        "automatic_enrollment": False,
        "commands": [],
        "verify_existing_auth": {
            "mode": "browser-free-read-only-no-op-when-fresh-distinct",
            "profiles": list(WORKER_PROFILES),
            "explicit_config_required": True,
            "provider_login_allowed": False,
            "browser_allowed": False,
            "credential_mutation_allowed": False,
            "identity_replacement_allowed": False,
        },
        "batch_identity_adoption": {
            "mode": "browser-free-existing-credential-adoption",
            "profiles": list(WORKER_PROFILES),
            "atomic_provider_bundles": True,
            "fresh_exact_proofs_required": True,
            "provider_login_allowed": False,
            "credential_mutation_allowed": False,
            "browser_allowed": False,
        },
        "manual_profile_login": {
            "enabled": True,
            "mode": "operator-invoked-transactional-maintenance",
            "profiles": list(WORKER_PROFILES),
            "commands": [],
            "generated_commands": False,
            "automatic_execution": False,
            "automatic_browser_open": False,
            "automatic_profile_enable": False,
            "profile_remains_disabled": True,
            "all_same_provider_workers_disabled": True,
            "zero_same_provider_worker_leases": True,
            "provider_maintenance_lock_held_end_to_end": True,
            "exact_registry_compare_and_swap_required": True,
            "sealed_provider_binary_required": True,
            "whole_provider_worker_set_reverification_required": True,
            "credential_mutation_allowed": True,
            "credential_mutation_scope": "one-worker-transactional-staged-home",
            "reserve_access_forbidden": True,
            "base_default_and_desktop_identity_access_forbidden": True,
            "provider_logout_forbidden": True,
            "browser": {
                "automatic_open_allowed": False,
                "private_context_required": True,
                "desktop_session_mutation_forbidden": True,
                "codex_device_flow_is_default": True,
                "claude_requires_explicit_browser_flag": True,
            },
            "keychain": {
                "automatic_prompt": False,
                "claude_macos_requires_explicit_operator_flag": True,
                "unscoped_or_desktop_service_access_forbidden": True,
            },
            "provider_side_revocation": {
                "possible_after_login_starts": True,
                "locally_reversible": False,
                "reported_on_every_post_login_failure": True,
            },
            "initialize_login": {
                "command_shape": (
                    "agent-fleet profile initialize-login <worker> [--browser] "
                    "[--allow-keychain-prompt]"
                ),
                "provider_identity_bundle_required_state": "absent",
                "first_provider_bundle_creation_only": True,
                "durable_provider_scoped_provisional_batch": True,
                "provisional_batch_binds_exact_worker_topology_and_binary": True,
                "records_only_explicitly_initialized_targets": True,
                "recorded_target_fields": [
                    "remote_fingerprint",
                    "stable_source_contract",
                    "stable_source_stat",
                    "transaction_generation",
                ],
                "freshly_reprove_recorded_peers_each_invocation": True,
                "distinctness_uses_same_attempt_peers_and_external_anchors": True,
                "incomplete_peer_set_commits_target_provisionally": True,
                "complete_valid_distinct_set_adopts_bundle_atomically": True,
                "successful_bundle_adoption_removes_provisional_batch": True,
            },
            "recover_login": {
                "command_shape": (
                    "agent-fleet profile recover-login <worker> [--browser] "
                    "[--allow-keychain-prompt]"
                ),
                "provider_identity_bundle_required_state": "present-complete",
                "existing_pinned_identity_required": True,
                "staged_identity_must_equal_existing_pin": True,
                "identity_replacement_allowed": False,
                "local_credential_replacement_is_transactional": True,
                "rebuilds_bundle_after_full_provider_reverification": True,
            },
        },
        "provision": {
            "profiles": list(WORKER_PROFILES),
            "plan_schema": 1,
            "sealed_contract": dict(provision_contract),
            "passes": 2,
            "all_same_provider_profiles_disabled": True,
            "zero_same_provider_leases": True,
            "quiet_lock_required": True,
            "generation_lock_required": True,
            "inherited_provider_hooks_forbidden": True,
            "forward_only_plugin_cleanup": {
                "remove_exact_managed_symlink_only": True,
                "refuse_unexpected_plugin_tree": True,
            },
        },
        "external_reserves": {
            "profiles": list(RESERVE_PROFILES),
            "never_enroll": True,
            "never_provision": True,
            "home_snapshots_must_remain_unchanged": True,
            "auth_not_required": True,
        },
    }


def _worker_state_transaction_paths(
    spec: PreparationSpec,
) -> tuple[str, Path, Path, Path]:
    transaction_id = f"{spec.transaction_id}-workers"
    if len(transaction_id) > 64:
        raise PreparationError("transaction_id is too long for worker-state suffix")
    parent = spec.worker_state.snapshot_parent
    return (
        transaction_id,
        parent / f"{transaction_id}.lock",
        parent / f"{transaction_id}.journal.json",
        parent / f"{transaction_id}.snapshot",
    )


def _worker_state_manifest_dict(
    spec: PreparationSpec,
    *,
    bundle_path: Path,
    bundle_sha256: str,
    cutover_manifest_path: Path,
    candidate_registry_path: Path,
    candidate_registry_sha256: str,
    candidate: Any,
    provision_contract: Mapping[str, Any],
) -> dict[str, Any]:
    plans = provision_contract["plans"]
    identity_paths = provision_contract["identity_bundles"]["paths"]
    parent = spec.worker_state.snapshot_parent
    homes = [Path(candidate.profiles[profile_id].home) for profile_id in WORKER_PROFILES]
    protected = [spec.output_dir, *homes, *(Path(path) for path in identity_paths.values())]
    if any(
        parent == path
        or _is_relative_to(parent, path)
        or _is_relative_to(path, parent)
        for path in protected
    ):
        raise PreparationError(
            "worker-state snapshot parent must not overlap bundle, workers, or identity state"
        )
    transaction_id, lock_path, journal_path, snapshot_path = (
        _worker_state_transaction_paths(spec)
    )
    return {
        "schema_version": 1,
        "transaction_id": transaction_id,
        "apply_opt_in": True,
        "snapshot_parent": str(parent),
        "lock_path": str(lock_path),
        "journal_path": str(journal_path),
        "snapshot_path": str(snapshot_path),
        "cutover_manifest_path": str(cutover_manifest_path),
        "bundle_path": str(bundle_path),
        "bundle_sha256": bundle_sha256,
        "candidate_registry_path": str(candidate_registry_path),
        "candidate_registry_sha256": candidate_registry_sha256,
        "candidate_release": str(spec.agent_fleet.release.new_release),
        "candidate_pythonpath": str(spec.agent_fleet.pythonpath),
        "candidate_version": spec.agent_fleet.expected_version,
        "workers": [
            {
                "profile": profile_id,
                "provider": EXPECTED_TOPOLOGY[profile_id][0],
                "home": str(candidate.profiles[profile_id].home),
                "plan_sha256": plans[profile_id]["plan_sha256"],
            }
            for profile_id in sorted(WORKER_PROFILES)
        ],
        "identity_bundles": dict(identity_paths),
        "sealed_plans": dict(plans),
    }


def _rename_directory_no_replace(source: Path, destination: Path) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    source_bytes = os.fsencode(source)
    destination_bytes = os.fsencode(destination)
    if sys.platform == "darwin":
        function = libc.renamex_np
        function.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        function.restype = ctypes.c_int
        result = function(source_bytes, destination_bytes, 0x00000004)
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
        result = function(-100, source_bytes, -100, destination_bytes, 1)
    else:
        raise PreparationError(
            "this platform has no supported atomic no-replace rename primitive"
        )
    if result != 0:
        error = ctypes.get_errno()
        if error in {errno_module.EEXIST, errno_module.ENOTEMPTY}:
            raise PreparationError(
                f"output_dir appeared during preparation; refusing overwrite: {destination}"
            )
        raise PreparationError(
            f"atomic no-replace preparation publication failed: {source} -> "
            f"{destination}: {os.strerror(error)}"
        )


def _preparation_staging_marker(
    staging: Path,
    spec: PreparationSpec,
    spec_path: Path,
    driver_path: Path,
) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "transaction_id": spec.transaction_id,
        "output_dir": str(spec.output_dir),
        "spec_path": str(spec_path),
        "spec_sha256": _sha256(spec_path),
        "driver_path": str(driver_path),
        "driver_sha256": _sha256(driver_path),
    }


def _preparation_control_paths(staging: Path) -> tuple[Path, Path]:
    return (
        staging.with_name(staging.name + ".journal.json"),
        staging.with_name(staging.name + ".lock"),
    )


def _open_preparation_lock(path: Path) -> int:
    descriptor = os.open(
        path,
        os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
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
            raise PreparationError(f"preparation lock is not attributable: {path}")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise PreparationError("this exact preparation is already running") from exc
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def _preparation_journal_value(
    staging: Path,
    output_dir: Path,
    expected_marker: Mapping[str, Any],
    phase: str,
    tree_sha256: str | None,
) -> dict[str, Any]:
    if phase not in {"building", "ready", "complete"}:
        raise PreparationError(f"invalid preparation journal phase: {phase}")
    if phase == "building" and tree_sha256 is not None:
        raise PreparationError("building preparation journal cannot have a tree digest")
    if phase != "building" and (
        not isinstance(tree_sha256, str) or not SHA256.fullmatch(tree_sha256)
    ):
        raise PreparationError("ready preparation journal requires a tree digest")
    return {
        "schema_version": 1,
        "phase": phase,
        "staging_path": str(staging),
        "output_dir": str(output_dir),
        "marker": dict(expected_marker),
        "tree_sha256": tree_sha256,
    }


def _write_preparation_journal(
    path: Path,
    value: Mapping[str, Any],
    previous_sha256: str | None,
) -> str:
    payload = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")
    digest = hashlib.sha256(payload).hexdigest()
    temporary = path.with_name(f".{path.name}.bridge-write-{digest[:32]}")
    if os.path.lexists(temporary):
        info = os.lstat(temporary)
        staged = temporary.read_bytes() if stat.S_ISREG(info.st_mode) else b""
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid()
            or info.st_nlink != 1
            or stat.S_IMODE(info.st_mode) != 0o600
            or len(staged) > len(payload)
            or not payload.startswith(staged)
        ):
            raise PreparationError(
                f"preparation journal staging is not attributable: {temporary}"
            )
        temporary.unlink()
    if previous_sha256 is None:
        if os.path.lexists(path):
            raise PreparationError(f"preparation journal appeared unexpectedly: {path}")
    elif not os.path.lexists(path) or _sha256(path) != previous_sha256:
        raise PreparationError(f"preparation journal changed concurrently: {path}")
    _write_bytes(temporary, payload, 0o600)
    if previous_sha256 is None:
        _rename_directory_no_replace(temporary, path)
    else:
        if _sha256(path) != previous_sha256:
            raise PreparationError(
                f"preparation journal changed before replacement: {path}"
            )
        os.replace(temporary, path)
    parent_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(parent_fd)
    finally:
        os.close(parent_fd)
    return digest


def _load_preparation_journal(
    path: Path,
    staging: Path,
    output_dir: Path,
    expected_marker: Mapping[str, Any],
) -> tuple[dict[str, Any], str] | None:
    if not os.path.lexists(path):
        return None
    _require_regular(path, "preparation journal", mode=0o600)
    value = _read_json(path, "preparation journal")
    if not isinstance(value, dict):
        raise PreparationError("preparation journal must be an object")
    _require_exact_keys(
        value,
        {"schema_version", "phase", "staging_path", "output_dir", "marker", "tree_sha256"},
        set(),
        "preparation journal",
    )
    expected = _preparation_journal_value(
        staging,
        output_dir,
        expected_marker,
        value["phase"],
        value["tree_sha256"],
    )
    if value != expected:
        raise PreparationError("preparation journal belongs to another operation")
    return value, _sha256(path)


def _remove_preparation_staging(
    staging: Path,
    expected_marker: Mapping[str, Any],
    *,
    allow_incomplete_marker: bool = False,
) -> None:
    if not os.path.lexists(staging):
        return
    info = os.lstat(staging)
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.getuid()
        or stat.S_IMODE(info.st_mode) != 0o700
    ):
        raise PreparationError(
            f"preparation staging path is not attributable: {staging}"
        )
    marker_path = staging / ".bridge-preparation-staging.json"
    if not os.path.lexists(marker_path) and allow_incomplete_marker:
        if any(staging.iterdir()):
            raise PreparationError(
                f"unmarked preparation staging is not empty: {staging}"
            )
    else:
        marker_payload = (
            json.dumps(expected_marker, indent=2, sort_keys=True) + "\n"
        ).encode("utf-8")
        try:
            observed = _read_json(marker_path, "preparation staging ownership marker")
        except PreparationError:
            if not allow_incomplete_marker:
                raise
            info = os.lstat(marker_path)
            partial = marker_path.read_bytes() if stat.S_ISREG(info.st_mode) else b""
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_uid != os.getuid()
                or info.st_nlink != 1
                or stat.S_IMODE(info.st_mode) != 0o600
                or any(child != marker_path for child in staging.iterdir())
                or len(partial) > len(marker_payload)
                or not marker_payload.startswith(partial)
            ):
                raise PreparationError(
                    f"preparation staging marker is not attributable: {staging}"
                )
        else:
            if observed != expected_marker:
                raise PreparationError(
                    f"preparation staging marker belongs to another operation: {staging}"
                )
    shutil.rmtree(staging)
    parent_fd = os.open(
        staging.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    )
    try:
        os.fsync(parent_fd)
    finally:
        os.close(parent_fd)


def _prepare_locked(spec_path: Path, driver_path: Path) -> dict[str, Any]:
    spec = load_spec(spec_path)
    driver = _load_driver(driver_path)
    try:
        _validate_sealed_runtime_manifest(spec, driver)
        _validate_quota_release_tree(spec.quota, driver)
    except driver.CutoverError as exc:
        raise PreparationError(f"sealed runtime proof validation failed: {exc}") from exc
    staging = spec.output_dir.parent / (
        f".{spec.output_dir.name}.prepare-"
        f"{hashlib.sha256(spec.transaction_id.encode('utf-8')).hexdigest()[:32]}"
    )
    expected_staging_marker = _preparation_staging_marker(
        staging, spec, spec_path, driver_path
    )
    journal_path, _ = _preparation_control_paths(staging)
    loaded_journal = _load_preparation_journal(
        journal_path, staging, spec.output_dir, expected_staging_marker
    )
    rollback_api, candidate_api = _validate_input_state(
        spec, allow_existing_output=loaded_journal is not None
    )
    if loaded_journal is None:
        if os.path.lexists(staging):
            raise PreparationError(
                "preparation staging exists without an ownership journal and "
                f"belongs to another operation: {staging}"
            )
        journal = _preparation_journal_value(
            staging, spec.output_dir, expected_staging_marker, "building", None
        )
        journal_sha256 = _write_preparation_journal(journal_path, journal, None)
    else:
        journal, journal_sha256 = loaded_journal
        tree_sha256 = journal["tree_sha256"]
        if journal["phase"] in {"ready", "complete"}:
            if os.path.lexists(spec.output_dir):
                observed = driver.compute_release_tree_sha256(
                    spec.output_dir, "completed preparation bundle"
                )
                if observed != tree_sha256:
                    raise PreparationError(
                        "completed preparation output differs from its journal"
                    )
                if journal["phase"] != "complete":
                    journal = _preparation_journal_value(
                        staging,
                        spec.output_dir,
                        expected_staging_marker,
                        "complete",
                        tree_sha256,
                    )
                    journal_sha256 = _write_preparation_journal(
                        journal_path, journal, journal_sha256
                    )
                return validate_bundle(spec.output_dir / "bundle.json", driver_path)
            if journal["phase"] == "complete":
                raise PreparationError(
                    "completed preparation journal has no output directory"
                )
            if os.path.lexists(staging):
                observed = driver.compute_release_tree_sha256(
                    staging, "ready preparation staging"
                )
                if observed != tree_sha256:
                    raise PreparationError(
                        "ready preparation staging differs from its journal"
                    )
                _rename_directory_no_replace(staging, spec.output_dir)
                journal = _preparation_journal_value(
                    staging,
                    spec.output_dir,
                    expected_staging_marker,
                    "complete",
                    tree_sha256,
                )
                _write_preparation_journal(journal_path, journal, journal_sha256)
                return validate_bundle(spec.output_dir / "bundle.json", driver_path)
        if os.path.lexists(spec.output_dir):
            raise PreparationError(
                "preparation output exists before a complete tree was journaled"
            )
        _remove_preparation_staging(
            staging, expected_staging_marker, allow_incomplete_marker=True
        )
        journal = _preparation_journal_value(
            staging, spec.output_dir, expected_staging_marker, "building", None
        )
        journal_sha256 = _write_preparation_journal(
            journal_path, journal, journal_sha256
        )
    staging.mkdir(mode=0o700)
    _write_json(
        staging / ".bridge-preparation-staging.json",
        expected_staging_marker,
        0o600,
    )
    private = staging / "transaction"
    private.mkdir(mode=0o700)
    initial_staged = staging / "registry.initial.toml"
    old_staged = staging / "registry.old.toml"
    new_staged = staging / "registry.new.toml"
    build_proof_staged = staging / "sealed-runtime-proof-manifest.json"
    _write_bytes(initial_staged, spec.baseline_registry.read_bytes(), 0o600)
    _write_bytes(build_proof_staged, spec.agent_fleet.build_manifest.read_bytes(), 0o600)

    baseline_raw = _parse_registry_toml(initial_staged, "staged baseline registry")
    sealed_raw = _construct_sealed_baseline_raw(baseline_raw, spec)
    _write_registry_toml(old_staged, sealed_raw)
    sealed_reloaded_raw = _normalized_registry_raw(
        _parse_registry_toml(old_staged, "sealed rollback registry"),
        "sealed rollback registry",
    )
    if sealed_reloaded_raw != sealed_raw:
        raise PreparationError("sealed rollback registry did not round-trip exactly")
    candidate_raw = _construct_candidate_raw(sealed_raw, spec)
    _write_registry_toml(new_staged, candidate_raw)
    candidate_reloaded_raw = _normalized_registry_raw(
        _parse_registry_toml(new_staged, "candidate registry"),
        "candidate registry",
    )
    _semantic_validate_candidate_raw(sealed_raw, candidate_reloaded_raw, spec)
    if candidate_reloaded_raw != candidate_raw:
        raise PreparationError("candidate registry did not round-trip exactly")
    reloaded = _lexical_candidate_registry(
        candidate_api, candidate_reloaded_raw, spec.live_registry
    )
    sealed_provision_contract = _sealed_provision_contract(candidate_api, reloaded)

    final_initial = spec.output_dir / initial_staged.name
    final_old = spec.output_dir / old_staged.name
    final_new = spec.output_dir / new_staged.name
    final_private = spec.output_dir / private.name
    final_lock = final_private / "cutover.lock"
    final_journal = final_private / "cutover.journal.json"
    final_adoption_lock = final_private / "sealed-adoption.lock"
    final_adoption_journal = final_private / "sealed-adoption.journal.json"
    final_manifest = spec.output_dir / "cutover.manifest.json"
    final_adoption_manifest = spec.output_dir / "sealed-adoption.manifest.json"
    final_worker_state_manifest = spec.output_dir / "worker-state.manifest.json"
    _write_bytes(private / final_lock.name, b"", 0o600)
    _write_bytes(private / final_adoption_lock.name, b"", 0o600)
    manifest = _manifest_dict(
        spec,
        driver,
        final_old,
        final_new,
        final_lock,
        final_journal,
        old_sha256=_sha256(old_staged),
        new_sha256=_sha256(new_staged),
    )
    _write_json(staging / final_manifest.name, manifest, 0o600)
    adoption_manifest = _adoption_manifest_dict(
        spec,
        driver,
        final_initial,
        final_old,
        final_adoption_lock,
        final_adoption_journal,
        initial_sha256=_sha256(initial_staged),
        sealed_sha256=_sha256(old_staged),
    )
    _write_json(
        staging / final_adoption_manifest.name,
        adoption_manifest,
        0o600,
    )

    bundle = {
        "schema_version": BUNDLE_SCHEMA_VERSION,
        "spec": spec.raw,
        "agent_fleet_version": spec.agent_fleet.expected_version,
        "agent_fleet_contract_version": spec.agent_fleet.expected_contract_version,
        "agent_fleet_rollback_version": spec.agent_fleet.rollback_version,
        "agent_fleet_rollback_contract_version": (
            spec.agent_fleet.rollback_contract_version
        ),
        "quota_version": spec.quota.expected_version,
        "node_version": spec.quota.node_version,
        "quota_binary_sha256": _sha256(spec.quota.binary),
        "quota_node_sha256": _sha256(spec.quota.node_binary),
        "quota_release_tree_sha256": spec.quota.release_tree_sha256,
        "trusted_project": str(spec.trusted_project),
        "launcher_build_proof": {
            "source_path": str(spec.agent_fleet.build_manifest),
            "source_sha256": _sha256(spec.agent_fleet.build_manifest),
            "bundled_path": str(spec.output_dir / build_proof_staged.name),
            "bundled_sha256": _sha256(build_proof_staged),
        },
        "registry_initial": {
            "path": str(final_initial),
            "sha256": _sha256(initial_staged),
            "mode": "0600",
        },
        "registry_old": {
            "path": str(final_old),
            "sha256": _sha256(old_staged),
            "mode": "0600",
        },
        "registry_new": {
            "path": str(final_new),
            "sha256": _sha256(new_staged),
            "mode": "0600",
        },
        "manifest_path": str(final_manifest),
        "manifest_sha256": hashlib.sha256(
            (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")
        ).hexdigest(),
        "adoption_manifest_path": str(final_adoption_manifest),
        "adoption_manifest_sha256": hashlib.sha256(
            (json.dumps(adoption_manifest, indent=2, sort_keys=True) + "\n").encode(
                "utf-8"
            )
        ).hexdigest(),
        "worker_state_manifest_path": str(final_worker_state_manifest),
        "topology": _topology_summary(),
        "activation_plan": _activation_plan(sealed_provision_contract),
    }
    _write_json(staging / "bundle.json", bundle, 0o600)
    worker_state_manifest = _worker_state_manifest_dict(
        spec,
        bundle_path=spec.output_dir / "bundle.json",
        bundle_sha256=_sha256(staging / "bundle.json"),
        cutover_manifest_path=final_manifest,
        candidate_registry_path=final_new,
        candidate_registry_sha256=_sha256(new_staged),
        candidate=reloaded,
        provision_contract=sealed_provision_contract,
    )
    _write_json(
        staging / final_worker_state_manifest.name,
        worker_state_manifest,
        0o600,
    )
    tree_sha256 = driver.compute_release_tree_sha256(
        staging, "completed preparation staging"
    )
    journal = _preparation_journal_value(
        staging,
        spec.output_dir,
        expected_staging_marker,
        "ready",
        tree_sha256,
    )
    journal_sha256 = _write_preparation_journal(
        journal_path, journal, journal_sha256
    )
    _rename_directory_no_replace(staging, spec.output_dir)
    parent_fd = os.open(spec.output_dir.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(parent_fd)
    finally:
        os.close(parent_fd)
    journal = _preparation_journal_value(
        staging,
        spec.output_dir,
        expected_staging_marker,
        "complete",
        tree_sha256,
    )
    _write_preparation_journal(journal_path, journal, journal_sha256)
    return validate_bundle(spec.output_dir / "bundle.json", driver_path)


def prepare(spec_path: Path, driver_path: Path) -> dict[str, Any]:
    spec = load_spec(spec_path)
    staging = spec.output_dir.parent / (
        f".{spec.output_dir.name}.prepare-"
        f"{hashlib.sha256(spec.transaction_id.encode('utf-8')).hexdigest()[:32]}"
    )
    _, lock_path = _preparation_control_paths(staging)
    descriptor = _open_preparation_lock(lock_path)
    try:
        return _prepare_locked(spec_path, driver_path)
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def _spec_from_bundle(bundle_path: Path, bundle: dict[str, Any]) -> PreparationSpec:
    raw_spec = bundle.get("spec")
    if not isinstance(raw_spec, dict):
        raise PreparationError("bundle.spec must be an object")
    real_temp_root = Path(os.path.realpath(tempfile.gettempdir()))
    with tempfile.TemporaryDirectory(
        prefix="bridge-bundle-spec-", dir=real_temp_root
    ) as temporary:
        path = Path(temporary) / "spec.json"
        path.write_text(json.dumps(raw_spec), encoding="utf-8")
        path.chmod(0o600)
        spec = load_spec(path)
    if spec.output_dir != bundle_path.parent:
        raise PreparationError("bundle output_dir does not equal the bundle directory")
    return spec


@dataclass(frozen=True)
class _BundleState:
    """Reconstructed, journal-bound runtime state of a validated bundle.

    Carries exactly the pieces both the strict validator and the in-place
    refresh need after every shared integrity check has passed but before the
    two identity-bound gates (recorded activation plan, worker-state manifest)
    are enforced.  ``expected_provision_contract`` is recomputed against the
    CURRENT provider-binary identity, so it is what the refresh writes and what
    the validator compares against.
    """

    bundle_path: Path
    bundle: dict[str, Any]
    spec: PreparationSpec
    candidate: Any
    loaded: Any
    loaded_adoption: Any
    cutover_phase: str
    manifest_path: Path
    initial_path: Path
    old_path: Path
    new_path: Path
    expected_provision_contract: dict[str, Any]


def _reconstruct_bundle_state(bundle_path: Path, driver_path: Path) -> _BundleState:
    """Validate a bundle and reconstruct its journal-bound runtime state.

    Owns every bundle-integrity check shared by ``validate_bundle`` and the
    in-place refresh: metadata exactness, the sealed runtime and quota proofs,
    the three registries, the cutover and sealed-adoption manifests, the
    journal-bound cutover phase, the topology summary, and the freshly recomputed
    sealed provision contract (which reads the current provider-binary identity).
    It stops just before the two identity-bound exactness gates so the validator
    can enforce them strictly and the refresh can regenerate them.  It never
    mutates state.
    """

    bundle_path = _normalized_absolute(str(bundle_path), "bundle path")
    _canonical(bundle_path, "bundle path")
    bundle = _read_json(bundle_path, "cutover bundle")
    if not isinstance(bundle, dict):
        raise PreparationError("bundle root must be an object")
    _require_exact_keys(
        bundle,
        {
            "schema_version",
            "spec",
            "agent_fleet_version",
            "agent_fleet_contract_version",
            "agent_fleet_rollback_version",
            "agent_fleet_rollback_contract_version",
            "quota_version",
            "node_version",
            "quota_binary_sha256",
            "quota_node_sha256",
            "quota_release_tree_sha256",
            "trusted_project",
            "launcher_build_proof",
            "registry_initial",
            "registry_old",
            "registry_new",
            "manifest_path",
            "manifest_sha256",
            "adoption_manifest_path",
            "adoption_manifest_sha256",
            "worker_state_manifest_path",
            "topology",
            "activation_plan",
        },
        set(),
        "bundle",
    )
    if bundle["schema_version"] != BUNDLE_SCHEMA_VERSION:
        raise PreparationError("unsupported bundle schema")
    spec = _spec_from_bundle(bundle_path, bundle)
    exact_metadata = {
        "agent_fleet_version": spec.agent_fleet.expected_version,
        "agent_fleet_contract_version": spec.agent_fleet.expected_contract_version,
        "agent_fleet_rollback_version": spec.agent_fleet.rollback_version,
        "agent_fleet_rollback_contract_version": spec.agent_fleet.rollback_contract_version,
        "quota_version": spec.quota.expected_version,
        "node_version": spec.quota.node_version,
        "quota_binary_sha256": _sha256(spec.quota.binary),
        "quota_node_sha256": _sha256(spec.quota.node_binary),
        "quota_release_tree_sha256": spec.quota.release_tree_sha256,
        "trusted_project": str(spec.trusted_project),
    }
    for key, expected in exact_metadata.items():
        if bundle[key] != expected:
            raise PreparationError(f"bundle metadata mismatch: {key}")
    driver = _load_driver(driver_path)
    build_proof = bundle["launcher_build_proof"]
    if not isinstance(build_proof, dict):
        raise PreparationError("launcher_build_proof must be an object")
    _require_exact_keys(
        build_proof,
        {"source_path", "source_sha256", "bundled_path", "bundled_sha256"},
        set(),
        "launcher_build_proof",
    )
    bundled_build_proof = _normalized_absolute(
        build_proof["bundled_path"], "launcher_build_proof.bundled_path"
    )
    if bundled_build_proof != bundle_path.parent / "sealed-runtime-proof-manifest.json":
        raise PreparationError("bundled launcher proof path is not exact")
    _require_regular(bundled_build_proof, "bundled launcher build proof", mode=0o600)
    if build_proof["source_path"] != str(spec.agent_fleet.build_manifest):
        raise PreparationError("launcher build proof source path mismatch")
    if build_proof["source_sha256"] != _sha256(spec.agent_fleet.build_manifest):
        raise PreparationError("launcher build proof source SHA-256 mismatch")
    if build_proof["bundled_sha256"] != _sha256(bundled_build_proof):
        raise PreparationError("bundled launcher build proof SHA-256 mismatch")
    if spec.agent_fleet.build_manifest.read_bytes() != bundled_build_proof.read_bytes():
        raise PreparationError("bundled launcher build proof differs from its source")
    try:
        _validate_sealed_runtime_manifest(spec, driver, bundled_build_proof)
        _validate_quota_release_tree(spec.quota, driver)
    except driver.CutoverError as exc:
        raise PreparationError(f"sealed runtime proof validation failed: {exc}") from exc
    rollback_api, candidate_api = _validate_input_state_for_existing_bundle(spec)
    if not isinstance(bundle["registry_initial"], dict):
        raise PreparationError("registry_initial must be an object")
    if not isinstance(bundle["registry_old"], dict):
        raise PreparationError("registry_old must be an object")
    if not isinstance(bundle["registry_new"], dict):
        raise PreparationError("registry_new must be an object")
    initial_path = _normalized_absolute(
        bundle["registry_initial"].get("path"), "registry_initial.path"
    )
    old_path = _normalized_absolute(bundle["registry_old"].get("path"), "registry_old.path")
    new_path = _normalized_absolute(bundle["registry_new"].get("path"), "registry_new.path")
    for label, value, path in (
        ("registry_initial", bundle["registry_initial"], initial_path),
        ("registry_old", bundle["registry_old"], old_path),
        ("registry_new", bundle["registry_new"], new_path),
    ):
        _require_exact_keys(value, {"path", "sha256", "mode"}, set(), label)
        _require_regular(path, label, mode=0o600)
        if value["mode"] != "0600" or value["sha256"] != _sha256(path):
            raise PreparationError(f"{label} digest or mode mismatch")
    if any(
        path.parent != bundle_path.parent for path in (initial_path, old_path, new_path)
    ):
        raise PreparationError("registry sources must be direct bundle children")
    if initial_path.read_bytes() != spec.baseline_registry.read_bytes():
        raise PreparationError("bundled initial registry is not the exact baseline bytes")
    _parse_registry_toml(initial_path, "bundled initial registry")
    _parse_registry_toml(old_path, "bundled old registry")
    _parse_registry_toml(new_path, "bundled candidate registry")
    baseline_raw = _parse_registry_toml(initial_path, "bundled initial registry")
    sealed_raw = _normalized_registry_raw(
        _parse_registry_toml(old_path, "bundled sealed rollback registry"),
        "bundled sealed rollback registry",
    )
    if sealed_raw != _construct_sealed_baseline_raw(baseline_raw, spec):
        raise PreparationError("bundled sealed rollback registry is not exact")
    candidate_raw = _normalized_registry_raw(
        _parse_registry_toml(new_path, "bundled candidate registry"),
        "bundled candidate registry",
    )
    _semantic_validate_candidate_raw(sealed_raw, candidate_raw, spec)
    if candidate_raw != _construct_candidate_raw(sealed_raw, spec):
        raise PreparationError("bundled candidate registry is not exact")
    candidate = _lexical_candidate_registry(
        candidate_api, candidate_raw, spec.live_registry
    )

    manifest_path = _normalized_absolute(bundle["manifest_path"], "manifest_path")
    if manifest_path != bundle_path.parent / "cutover.manifest.json":
        raise PreparationError("manifest_path is not the exact bundle manifest")
    _require_regular(manifest_path, "cutover manifest", mode=0o600)
    manifest_raw = _read_json(manifest_path, "cutover manifest")
    expected_manifest = _manifest_dict(
        spec,
        driver,
        old_path,
        new_path,
        bundle_path.parent / "transaction" / "cutover.lock",
        bundle_path.parent / "transaction" / "cutover.journal.json",
    )
    if manifest_raw != expected_manifest:
        raise PreparationError("cutover manifest is not the exact reconstructed manifest")
    if bundle["manifest_sha256"] != _sha256(manifest_path):
        raise PreparationError("manifest SHA-256 mismatch")
    loaded = driver.load_manifest(manifest_path)
    adoption_path = _normalized_absolute(
        bundle["adoption_manifest_path"], "adoption_manifest_path"
    )
    if adoption_path != bundle_path.parent / "sealed-adoption.manifest.json":
        raise PreparationError("adoption_manifest_path is not exact")
    _require_regular(adoption_path, "sealed-adoption manifest", mode=0o600)
    expected_adoption = _adoption_manifest_dict(
        spec,
        driver,
        initial_path,
        old_path,
        bundle_path.parent / "transaction" / "sealed-adoption.lock",
        bundle_path.parent / "transaction" / "sealed-adoption.journal.json",
    )
    adoption_raw = _read_json(adoption_path, "sealed-adoption manifest")
    if adoption_raw != expected_adoption:
        raise PreparationError(
            "sealed-adoption manifest is not the exact reconstructed manifest"
        )
    if bundle["adoption_manifest_sha256"] != _sha256(adoption_path):
        raise PreparationError("sealed-adoption manifest SHA-256 mismatch")
    adoption_driver = _load_adoption_driver()
    try:
        loaded_adoption = adoption_driver.load_manifest(adoption_path)
    except adoption_driver.AdoptionError as exc:
        raise PreparationError(f"sealed-adoption state is invalid: {exc}") from exc
    try:
        adoption_plan = adoption_driver.plan(loaded_adoption)
    except adoption_driver.AdoptionError as exc:
        cutover_phase = _superseded_adoption_phase(
            driver, loaded, adoption_driver, loaded_adoption, exc
        )
    else:
        adoption_prefix = adoption_plan.get("sealed_prefix")
        adoption_sealed = adoption_plan.get("sealed") is True
        if adoption_prefix == 0 and not adoption_sealed:
            cutover_phase = "sealed-adoption-pending"
        elif adoption_prefix == 4 and adoption_sealed:
            planned = driver.plan(loaded)
            if _plan_prefix(planned) != 0 or planned.get(
                "post_install_irreversible_boundary"
            ):
                raise PreparationError(
                    "main cutover is not at the exact sealed rollback baseline"
                )
            cutover_phase = "runtime-switch-ready"
        elif adoption_plan.get("recovery_required"):
            cutover_phase = "sealed-adoption-recovery-required"
        else:
            raise PreparationError(
                "sealed-adoption state/journal combination is invalid"
            )
    expected_topology = _topology_summary()
    if bundle["topology"] != expected_topology:
        raise PreparationError("bundle topology summary is not exact")
    expected_provision_contract = _sealed_provision_contract(candidate_api, candidate)
    return _BundleState(
        bundle_path=bundle_path,
        bundle=bundle,
        spec=spec,
        candidate=candidate,
        loaded=loaded,
        loaded_adoption=loaded_adoption,
        cutover_phase=cutover_phase,
        manifest_path=manifest_path,
        initial_path=initial_path,
        old_path=old_path,
        new_path=new_path,
        expected_provision_contract=expected_provision_contract,
    )


def validate_bundle(bundle_path: Path, driver_path: Path) -> dict[str, Any]:
    """Validate a bundle strictly, enforcing the two identity-bound gates.

    The recorded activation plan and worker-state manifest must equal the exact
    reconstruction from the current provider-binary identity.  These are the
    journal-independent, identity-bound proofs the in-place refresh regenerates;
    this function never loosens them.
    """

    state = _reconstruct_bundle_state(bundle_path, driver_path)
    bundle = state.bundle
    bundle_path = state.bundle_path
    spec = state.spec
    candidate = state.candidate
    cutover_phase = state.cutover_phase
    loaded = state.loaded
    loaded_adoption = state.loaded_adoption
    manifest_path = state.manifest_path
    initial_path = state.initial_path
    old_path = state.old_path
    new_path = state.new_path
    expected_provision_contract = state.expected_provision_contract
    if bundle["activation_plan"] != _activation_plan(expected_provision_contract):
        raise PreparationError(
            "bundle activation plan is not exact or generated-command-free"
        )
    worker_state_path = _normalized_absolute(
        bundle["worker_state_manifest_path"], "worker_state_manifest_path"
    )
    if worker_state_path != bundle_path.parent / "worker-state.manifest.json":
        raise PreparationError("worker_state_manifest_path is not exact")
    _require_regular(worker_state_path, "worker-state manifest", mode=0o600)
    expected_worker_state = _worker_state_manifest_dict(
        spec,
        bundle_path=bundle_path,
        bundle_sha256=_sha256(bundle_path),
        cutover_manifest_path=manifest_path,
        candidate_registry_path=new_path,
        candidate_registry_sha256=_sha256(new_path),
        candidate=candidate,
        provision_contract=expected_provision_contract,
    )
    if _read_json(worker_state_path, "worker-state manifest") != expected_worker_state:
        raise PreparationError("worker-state manifest is not the exact reconstructed gate")
    worker_state_driver = _load_worker_state_driver()
    try:
        worker_state_loaded = worker_state_driver.load_manifest(worker_state_path)
        worker_state_plan = worker_state_driver.plan(worker_state_loaded)
    except worker_state_driver.WorkerStateError as exc:
        raise PreparationError(f"worker-state manifest is invalid: {exc}") from exc
    if worker_state_plan.get("phase") not in {
        "not-started",
        "snapshotted",
        "provision_verified",
        "complete",
        "rolling_back",
        "rolled_back",
        "cleaned",
    }:
        raise PreparationError("worker-state transaction phase is invalid")
    return {
        "valid": True,
        "bundle": str(bundle_path),
        "transaction_id": spec.transaction_id,
        "manifest_fingerprint": loaded.fingerprint,
        "adoption_manifest_fingerprint": loaded_adoption.fingerprint,
        "cutover_phase": cutover_phase,
        "runtime_switch_ready": cutover_phase == "runtime-switch-ready",
        # Worker snapshot/provision/identity verification is a separate,
        # post-install gate.  A sealed runtime switch alone is never enough to
        # claim end-to-end Bridge cutover readiness.
        "cutover_ready": False,
        "worker_state_phase": worker_state_plan["phase"],
        "worker_state_ready": worker_state_plan["worker_state_ready"],
        "initial_registry_sha256": _sha256(initial_path),
        "old_registry_sha256": _sha256(old_path),
        "new_registry_sha256": _sha256(new_path),
        "profiles": len(EXPECTED_TOPOLOGY),
        "fleet_managed_workers": len(WORKER_PROFILES),
        "external_reserves": len(RESERVE_PROFILES),
        "enabled": 0,
        "projects_per_provider": 1,
        "agent_fleet_version": spec.agent_fleet.expected_version,
        "agent_fleet_contract_version": spec.agent_fleet.expected_contract_version,
        "rollback_version": spec.agent_fleet.rollback_version,
        "rollback_contract_version": spec.agent_fleet.rollback_contract_version,
        "quota_binary": str(spec.quota.binary),
        "quota_node_binary": str(spec.quota.node_binary),
    }


def refresh_bundle(bundle_path: Path, driver_path: Path) -> dict[str, Any]:
    """Refresh identity artifacts per docs/bridge-cutover-sealed-runtimes.md."""

    state = _reconstruct_bundle_state(bundle_path, driver_path)
    if state.cutover_phase != "runtime-switched":
        raise PreparationError(
            "in-place refresh applies only to an applied runtime-switched bundle; "
            f"observed cutover phase {state.cutover_phase!r}"
        )
    bundle_path = state.bundle_path
    spec = state.spec
    # Serialize against a concurrent prepare or refresh of the same transaction.
    staging = spec.output_dir.parent / (
        f".{spec.output_dir.name}.prepare-"
        f"{hashlib.sha256(spec.transaction_id.encode('utf-8')).hexdigest()[:32]}"
    )
    _, lock_path = _preparation_control_paths(staging)
    descriptor = _open_preparation_lock(lock_path)
    try:
        worker_state_path = bundle_path.parent / "worker-state.manifest.json"
        (
            worker_state_id,
            worker_state_lock,
            worker_state_journal,
            worker_state_snapshot,
        ) = _worker_state_transaction_paths(spec)
        worker_state_staging = spec.worker_state.snapshot_parent / (
            f".{worker_state_id}.snapshot-staging"
        )
        worker_state_flags = (
            os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
        )
        worker_state_descriptor = os.open(
            worker_state_lock, worker_state_flags, 0o600
        )
        try:
            os.fchmod(worker_state_descriptor, 0o600)
            fcntl.flock(worker_state_descriptor, fcntl.LOCK_EX)
            try:
                if any(
                    os.path.lexists(path)
                    for path in (
                        worker_state_journal,
                        worker_state_snapshot,
                        worker_state_staging,
                    )
                ):
                    raise PreparationError(
                        "in-place refresh must run before the worker-state 6a "
                        "snapshot, while no worker-state transaction is bound to "
                        "the manifest; worker-state transaction state currently "
                        "exists, so refreshing would change the manifest fingerprint "
                        "and strand any bound transaction and its rollback"
                    )
                refreshed_bundle = dict(state.bundle)
                refreshed_bundle["activation_plan"] = _activation_plan(
                    state.expected_provision_contract
                )
                bundle_payload = (
                    json.dumps(refreshed_bundle, indent=2, sort_keys=True) + "\n"
                ).encode("utf-8")
                worker_state_manifest = _worker_state_manifest_dict(
                    spec,
                    bundle_path=bundle_path,
                    bundle_sha256=hashlib.sha256(bundle_payload).hexdigest(),
                    cutover_manifest_path=state.manifest_path,
                    candidate_registry_path=state.new_path,
                    candidate_registry_sha256=_sha256(state.new_path),
                    candidate=state.candidate,
                    provision_contract=state.expected_provision_contract,
                )
                # Write the bundle first so the worker-state manifest's bundle_sha256
                # pins the refreshed bundle bytes; both replacements are atomic.
                _atomic_replace_bytes(bundle_path, bundle_payload, 0o600)
                _atomic_replace_json(worker_state_path, worker_state_manifest, 0o600)
            finally:
                fcntl.flock(worker_state_descriptor, fcntl.LOCK_UN)
        finally:
            os.close(worker_state_descriptor)
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)
    result = validate_bundle(bundle_path, driver_path)
    if not result.get("valid") or result.get("cutover_phase") != "runtime-switched":
        raise PreparationError(
            "in-place refresh did not converge on a strict runtime-switched bundle"
        )
    result["refreshed"] = True
    return result


def _validate_input_state_for_existing_bundle(
    spec: PreparationSpec,
) -> tuple[AgentFleetAPI, AgentFleetAPI]:
    _require_regular(spec.baseline_registry, "baseline registry", mode=0o600)
    if _sha256(spec.baseline_registry) != spec.baseline_registry_sha256:
        raise PreparationError("baseline registry SHA-256 generation is stale")
    _require_regular(spec.live_registry, "live registry", mode=0o600)
    baseline_raw = _parse_registry_toml(spec.baseline_registry, "baseline registry")
    _validate_legacy_registry_shape(baseline_raw, spec)
    _require_directory(spec.trusted_project, "trusted Relvino project")
    _require_directory(spec.output_dir, "bundle output", private=True)
    _validate_adoption_inputs(spec)
    _validate_release_spec(
        spec.agent_fleet.release,
        (
            spec.sealed_adoption.agent_fleet_initial_target,
            spec.agent_fleet.release.old_target,
            spec.agent_fleet.release.new_target,
        ),
    )
    _validate_release_spec(
        spec.quota.release,
        (
            spec.sealed_adoption.quota_initial_target,
            spec.quota.release.old_target,
            spec.quota.release.new_target,
        ),
    )
    _validate_agent_fleet_runtime(spec.agent_fleet)
    _validate_quota_runtime(spec)
    rollback_api = load_agent_fleet_api(
        spec.agent_fleet.rollback_pythonpath,
        spec.agent_fleet.release.old_release,
        spec.agent_fleet.rollback_version,
        "Agent Fleet rollback",
    )
    candidate_api = load_agent_fleet_api(
        spec.agent_fleet.pythonpath,
        spec.agent_fleet.release.new_release,
        spec.agent_fleet.expected_version,
        "Agent Fleet candidate",
        require_provision_api=True,
    )
    return rollback_api, candidate_api


def _copy_release(source: Path, destination: Path) -> None:
    if destination.exists():
        return
    shutil.copytree(source, destination, symlinks=True, copy_function=shutil.copy2)


def _fixture_release_operation(
    driver: ModuleType,
    source_operation: dict[str, Any],
    source_release: ReleaseSpec,
    fixture_root: Path,
    initial_target: str | None = None,
) -> tuple[dict[str, Any], Path]:
    product = fixture_root / source_release.name.removesuffix("-current")
    product.mkdir(mode=0o700, exist_ok=True)
    old_target = source_release.old_target
    new_target = source_release.new_target
    old_release = Path(os.path.normpath(product / old_target))
    new_release = Path(os.path.normpath(product / new_target))
    old_release.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    new_release.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    _copy_release(source_release.old_release, old_release)
    _copy_release(source_release.new_release, new_release)
    copied_old_tree = driver.compute_release_tree_sha256(old_release)
    copied_new_tree = driver.compute_release_tree_sha256(new_release)
    if copied_old_tree != source_operation["old_tree_sha256"]:
        raise PreparationError("copied rollback release tree digest changed")
    if copied_new_tree != source_operation["new_tree_sha256"]:
        raise PreparationError("copied candidate release tree digest changed")
    current = product / "current"
    if not os.path.lexists(current):
        os.symlink(initial_target or old_target, current)
    operation = {
        **source_operation,
        "path": str(current),
        "old_tree_sha256": copied_old_tree,
        "new_tree_sha256": copied_new_tree,
        "old_proofs": [
            driver.compute_release_proof(old_release, proof["relative_path"])
            for proof in source_operation["old_proofs"]
        ],
        "new_proofs": [
            driver.compute_release_proof(new_release, proof["relative_path"])
            for proof in source_operation["new_proofs"]
        ],
    }
    return operation, current


def _assert_prefix(driver: ModuleType, manifest_path: Path, expected: int) -> None:
    manifest = driver.load_manifest(manifest_path)
    result = driver.plan(manifest)
    observed = _plan_prefix(result)
    if observed != expected:
        raise PreparationError(
            f"rehearsal prefix is {observed}; expected {expected}"
        )


def _post_cutover_pins(driver: ModuleType, loaded: Any) -> dict[str, dict[str, str]]:
    pins: dict[str, dict[str, str]] = {}
    for operation in loaded.operations:
        if isinstance(operation, driver.SymlinkOperation):
            pins[str(operation.path)] = {
                "kind": "link",
                "target": operation.new_target,
            }
        else:
            pins[str(operation.path)] = {
                "kind": "file",
                "sha256": operation.new_sha256,
            }
    return pins


def _superseded_adoption_phase(
    driver: ModuleType,
    loaded: Any,
    adoption_driver: ModuleType,
    loaded_adoption: Any,
    refusal: Exception,
) -> str:
    """Resolve the one accepted post-cutover phase after a strict adoption refusal.

    The sealed-adoption plan intentionally accepts live state only at its exact
    initial or sealed identities, so it refuses once the normal cutover has
    legitimately advanced the machine.  That refusal stands unless the main
    cutover is provably complete - every operation applied and the post-install
    irreversible boundary marked - and the sealed adoption passes the pinned
    post-cutover assessment against the exact cutover-new identities.
    """

    invalid = f"sealed-adoption state is invalid: {refusal}"
    try:
        planned = driver.plan(loaded)
        fully_applied = _plan_prefix(planned) == len(planned["states"])
    except (driver.CutoverError, PreparationError) as exc:
        raise PreparationError(f"{invalid} (post-cutover probe: {exc})") from refusal
    if not fully_applied or not planned.get("post_install_irreversible_boundary"):
        raise PreparationError(
            f"{invalid} (post-cutover probe: main cutover is not fully applied "
            "past the marked post-install irreversible boundary)"
        ) from refusal
    try:
        adoption_driver.post_cutover_plan(
            loaded_adoption, _post_cutover_pins(driver, loaded)
        )
    except adoption_driver.AdoptionError as exc:
        raise PreparationError(
            f"sealed-adoption state is invalid post-cutover: {exc}"
        ) from exc
    return "runtime-switched"


def _plan_prefix(result: Mapping[str, Any]) -> int:
    states = result.get("states")
    if not isinstance(states, list) or not states:
        raise PreparationError("transaction plan has no exact operation states")
    values: list[str] = []
    for item in states:
        if not isinstance(item, dict) or item.get("state") not in {"old", "new"}:
            raise PreparationError("transaction plan contains an invalid operation state")
        values.append(item["state"])
    prefix = next((index for index, value in enumerate(values) if value == "old"), len(values))
    if values != ["new"] * prefix + ["old"] * (len(values) - prefix):
        raise PreparationError("transaction plan is not an exact new-prefix/old-suffix")
    return prefix


def rehearse_bundle(bundle_path: Path, driver_path: Path, scratch_root: Path) -> dict[str, Any]:
    validation = validate_bundle(bundle_path, driver_path)
    bundle = _read_json(bundle_path, "cutover bundle")
    spec = _spec_from_bundle(bundle_path, bundle)
    driver = _load_driver(driver_path)
    adoption_driver = _load_adoption_driver()
    _require_directory(scratch_root, "rehearsal scratch root", private=True)

    with tempfile.TemporaryDirectory(prefix="bridge-cutover-rehearsal-", dir=scratch_root) as temp:
        root = Path(temp)
        root.chmod(0o700)
        source_manifest = _read_json(Path(bundle["manifest_path"]), "source manifest")
        fixture_operations: list[dict[str, Any]] = []
        links: list[Path] = []
        release_specs = (spec.quota.release, spec.agent_fleet.release)
        initial_targets = (
            spec.sealed_adoption.quota_initial_target,
            spec.sealed_adoption.agent_fleet_initial_target,
        )
        for source_operation, release_spec, initial_target in zip(
            source_manifest["operations"][:2], release_specs, initial_targets
        ):
            operation, link = _fixture_release_operation(
                driver,
                source_operation,
                release_spec,
                root,
                initial_target,
            )
            fixture_operations.append(operation)
            links.append(link)

        source_front = source_manifest["operations"][2]
        if (
            not isinstance(source_front, dict)
            or source_front.get("kind") != "regular-file"
            or source_front.get("name") != "agent-fleet-front-door"
        ):
            raise PreparationError(
                "source transaction manifest has no exact Agent Fleet front-door operation"
            )
        front_parent = root / "operator-bin"
        front_parent.mkdir(mode=0o700)
        front_path = front_parent / "agent-fleet"
        front_initial_target = "../agent-fleet/current/bin/agent-fleet"
        os.symlink(front_initial_target, front_path)
        agent_old_release = Path(
            os.path.normpath(links[1].parent / fixture_operations[1]["old_target"])
        )
        agent_new_release = Path(
            os.path.normpath(links[1].parent / fixture_operations[1]["new_target"])
        )
        front_old_source = agent_old_release / "operator/agent-fleet"
        front_new_source = agent_new_release / "operator/agent-fleet"
        fixture_operations.append(
            {
                "kind": "regular-file",
                "name": "agent-fleet-front-door",
                "path": str(front_path),
                "old_source": str(front_old_source),
                "new_source": str(front_new_source),
                "old_sha256": _sha256(front_old_source),
                "new_sha256": _sha256(front_new_source),
                "mode": "0555",
            }
        )

        state = root / "state"
        state.mkdir(mode=0o700)
        private = root / "transaction"
        private.mkdir(mode=0o700)
        initial_source = state / "registry.initial.toml"
        old_source = state / "registry.old.toml"
        new_source = state / "registry.new.toml"
        live_registry = state / "accounts.toml"
        shutil.copy2(Path(bundle["registry_initial"]["path"]), initial_source)
        shutil.copy2(Path(bundle["registry_old"]["path"]), old_source)
        shutil.copy2(Path(bundle["registry_new"]["path"]), new_source)
        shutil.copy2(initial_source, live_registry)
        for path in (initial_source, old_source, new_source, live_registry):
            path.chmod(0o600)
        quiet_root = root / "quiet"
        quiet_root.mkdir(mode=0o700)
        backend = quiet_root / "backend"
        backend.write_text("tmux\n", encoding="utf-8")
        backend.chmod(0o600)
        routing = quiet_root / "account-routing-mode"
        quiet_paths = tuple(
            quiet_root / name for name in ("leases", "sessions", "locks")
        )
        for path in quiet_paths:
            path.mkdir(mode=0o700)
        ps_binary = quiet_root / "fake-ps"
        ps_binary.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        ps_binary.chmod(0o755)
        quiet_point = {
            "profile_ids": sorted(EXPECTED_TOPOLOGY),
            "worker_profile_ids": sorted(WORKER_PROFILES),
            "never_enroll_profile_ids": sorted(RESERVE_PROFILES),
            "routing_absent_paths": [str(routing)],
            "backend_path": str(backend),
            "backend_sha256": _sha256(backend),
            "state_quiet_paths": [str(path) for path in quiet_paths],
            "forbidden_process_tokens": [
                str(root / "bin" / "agent-fleet"),
                str(root / "agent-fleet" / "releases") + "/",
                str(root / "quota" / "releases") + "/",
            ],
            "ps_binary": str(ps_binary),
            "ps_binary_sha256": _sha256(ps_binary),
        }
        lock = private / "cutover.lock"
        lock.write_bytes(b"")
        lock.chmod(0o600)
        adoption_lock = private / "sealed-adoption.lock"
        adoption_lock.write_bytes(b"")
        adoption_lock.chmod(0o600)
        manifest_path = root / "fixture.manifest.json"
        adoption_manifest_path = root / "fixture.adoption.manifest.json"
        fixture_operations.append(
            {
                "kind": "registry",
                "name": "accounts-registry",
                "path": str(live_registry),
                "old_source": str(old_source),
                "new_source": str(new_source),
                "old_sha256": _sha256(old_source),
                "new_sha256": _sha256(new_source),
                "mode": "0600",
            }
        )
        fixture_manifest = {
            "schema_version": 1,
            "transaction_id": f"{spec.transaction_id}-rehearsal",
            "apply_opt_in": True,
            "allowed_roots": [str(root)],
            "lock_path": str(lock),
            "journal_path": str(private / "cutover.journal.json"),
            "quiet_point": quiet_point,
            "operations": fixture_operations,
        }
        _write_json(manifest_path, fixture_manifest, 0o600)
        source_adoption = _read_json(
            Path(bundle["adoption_manifest_path"]), "source adoption manifest"
        )
        adoption_links: list[dict[str, Any]] = []
        for source_link, main_operation, link in zip(
            source_adoption["link_operations"], fixture_operations[:2], links
        ):
            sealed_release = Path(
                os.path.normpath(link.parent / main_operation["old_target"])
            )
            adoption_links.append(
                {
                    **source_link,
                    "path": str(link),
                    "sealed_release": str(sealed_release),
                    "sealed_proofs": main_operation["old_proofs"],
                    "sealed_tree_sha256": main_operation["old_tree_sha256"],
                }
            )
        adoption_fixture = {
            "schema_version": 1,
            "transaction_id": f"{spec.transaction_id}-adopt-rehearsal",
            "apply_opt_in": True,
            "allowed_roots": [str(root)],
            "lock_path": str(adoption_lock),
            "journal_path": str(private / "sealed-adoption.journal.json"),
            "quiet_point": quiet_point,
            "link_operations": adoption_links,
            "front_door_operation": {
                "name": "agent-fleet-front-door",
                "path": str(front_path),
                "initial_target": front_initial_target,
                "sealed_source": str(front_old_source),
                "sealed_sha256": _sha256(front_old_source),
                "mode": "0555",
            },
            "registry_operation": {
                "name": "accounts-registry",
                "path": str(live_registry),
                "initial_source": str(initial_source),
                "sealed_source": str(old_source),
                "initial_sha256": _sha256(initial_source),
                "sealed_sha256": _sha256(old_source),
                "mode": "0600",
            },
        }
        _write_json(adoption_manifest_path, adoption_fixture, 0o600)
        adoption_manifest = adoption_driver.load_manifest(adoption_manifest_path)
        adoption_initial = adoption_driver.plan(adoption_manifest)
        if adoption_initial.get("sealed_prefix") != 0:
            raise PreparationError("integrated rehearsal did not begin pre-adoption")
        adoption_recorder = adoption_driver.BoundaryController()
        adoption_driver.apply(adoption_manifest, adoption_recorder)
        adoption_boundaries = tuple(dict.fromkeys(adoption_recorder.seen))
        adoption_final = adoption_driver.plan(
            adoption_driver.load_manifest(adoption_manifest_path)
        )
        if not adoption_final.get("sealed") or adoption_final.get("sealed_prefix") != 4:
            raise PreparationError("integrated rehearsal did not seal both rollback runtimes")
        try:
            adoption_driver.recover(
                adoption_driver.load_manifest(adoption_manifest_path)
            )
        except adoption_driver.AdoptionError:
            adoption_recovery_refused_after_seal = True
        else:
            raise PreparationError("sealed adoption remained reversible")
        manifest = driver.load_manifest(manifest_path)
        initial = driver.plan(manifest)
        if _plan_prefix(initial) != 0:
            raise PreparationError("rehearsal did not begin fully old")

        forward_recorder = driver.BoundaryController()
        driver.execute(manifest, "forward", forward_recorder)
        forward_boundaries = tuple(dict.fromkeys(forward_recorder.seen))
        driver.execute(driver.load_manifest(manifest_path), "rollback")
        for boundary in forward_boundaries:
            try:
                driver.execute(
                    driver.load_manifest(manifest_path),
                    "forward",
                    driver.BoundaryController(boundary),
                )
            except driver.InjectedFailure:
                pass
            else:
                raise PreparationError(f"forward boundary did not inject: {boundary}")
            driver.execute(driver.load_manifest(manifest_path), "forward")
            _assert_prefix(driver, manifest_path, len(fixture_operations))
            driver.execute(driver.load_manifest(manifest_path), "rollback")
            _assert_prefix(driver, manifest_path, 0)

        driver.execute(driver.load_manifest(manifest_path), "forward")
        rollback_recorder = driver.BoundaryController()
        driver.execute(driver.load_manifest(manifest_path), "rollback", rollback_recorder)
        rollback_boundaries = tuple(dict.fromkeys(rollback_recorder.seen))
        for boundary in rollback_boundaries:
            driver.execute(driver.load_manifest(manifest_path), "forward")
            try:
                driver.execute(
                    driver.load_manifest(manifest_path),
                    "rollback",
                    driver.BoundaryController(boundary),
                )
            except driver.InjectedFailure:
                pass
            else:
                raise PreparationError(f"rollback boundary did not inject: {boundary}")
            driver.execute(driver.load_manifest(manifest_path), "rollback")
            _assert_prefix(driver, manifest_path, 0)

        driver.execute(driver.load_manifest(manifest_path), "forward")
        driver.mark_post_install_irreversible_boundary(
            driver.load_manifest(manifest_path)
        )
        try:
            driver.execute(driver.load_manifest(manifest_path), "rollback")
        except driver.CutoverError:
            rollback_refused_after_irreversible_boundary = True
        else:
            raise PreparationError(
                "rollback was not refused after the post-install irreversible boundary"
            )
        _assert_prefix(driver, manifest_path, len(fixture_operations))
        if live_registry.read_bytes() != new_source.read_bytes():
            raise PreparationError("rehearsal did not finish with exact candidate registry")
        for link, release_spec in zip(links, release_specs):
            if os.readlink(link) != release_spec.new_target:
                raise PreparationError(f"rehearsal link did not finish new: {link}")
        if (
            front_path.is_symlink()
            or front_path.read_bytes() != front_new_source.read_bytes()
            or stat.S_IMODE(os.lstat(front_path).st_mode) != 0o555
            or os.lstat(front_path).st_nlink != 1
        ):
            raise PreparationError(
                "rehearsal front door did not finish as the exact candidate regular file"
            )

        return {
            **validation,
            "rehearsed": True,
            "adoption_forward_boundaries": len(adoption_boundaries),
            "adoption_recovery_refused_after_seal": (
                adoption_recovery_refused_after_seal
            ),
            "forward_boundaries": len(forward_boundaries),
            "rollback_boundaries": len(rollback_boundaries),
            "operations": len(fixture_operations),
            "rollback_refused_after_irreversible_boundary": (
                rollback_refused_after_irreversible_boundary
            ),
            "fixture_removed_on_return": True,
        }


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--driver",
        required=True,
        help="absolute path to scripts/bridge_cutover_transaction.py",
    )
    commands = parser.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare", help="construct a new exact bundle")
    prepare_parser.add_argument("spec", help="absolute path to the preparation JSON spec")
    validate_parser = commands.add_parser("validate", help="validate an existing bundle")
    validate_parser.add_argument("bundle", help="absolute path to bundle.json")
    refresh_parser = commands.add_parser(
        "refresh",
        help=(
            "refresh an applied runtime-switched bundle's activation plan and "
            "worker-state manifest to the current provider-binary identity"
        ),
    )
    refresh_parser.add_argument("bundle", help="absolute path to bundle.json")
    rehearse_parser = commands.add_parser(
        "rehearse", help="run exhaustive disposable transaction recovery rehearsal"
    )
    rehearse_parser.add_argument("bundle", help="absolute path to bundle.json")
    rehearse_parser.add_argument(
        "--scratch-root",
        required=True,
        help="absolute path to an existing private directory used only for disposable fixtures",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        driver = _normalized_absolute(args.driver, "driver path")
        if args.command == "prepare":
            result = prepare(_normalized_absolute(args.spec, "spec path"), driver)
        elif args.command == "validate":
            result = validate_bundle(_normalized_absolute(args.bundle, "bundle path"), driver)
        elif args.command == "refresh":
            result = refresh_bundle(_normalized_absolute(args.bundle, "bundle path"), driver)
        else:
            scratch = _normalized_absolute(args.scratch_root, "scratch root")
            result = rehearse_bundle(
                _normalized_absolute(args.bundle, "bundle path"), driver, scratch
            )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    except (PreparationError, OSError, ValueError) as exc:
        print(f"refused: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
