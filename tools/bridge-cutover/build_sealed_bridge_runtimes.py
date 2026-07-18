#!/usr/bin/env python3
"""Build four deterministic schema-v2 Bridge runtime roles from a pinned manifest.

The builder reads no live installation, account registry, credential directory, or
ambient package cache.
Every source artifact and build tool is supplied by a strict JSON manifest and
hash-pinned before use.
The command builds twice, verifies a relocated copy, runs hostile-environment and
tamper probes, and atomically publishes a proof manifest only after all gates pass.
"""

from __future__ import annotations

import argparse
import base64
import ctypes
import csv
import errno as errno_module
import hashlib
import io
import json
import os
import re
import secrets
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from types import ModuleType
from typing import Any, Iterable, Mapping, Sequence


SCHEMA_VERSION = 2
MAX_MANIFEST_BYTES = 1_000_000
SHA256 = re.compile(r"^[0-9a-f]{64}$")
GIT_COMMIT = re.compile(r"^[0-9a-f]{40}$")
VERSION = re.compile(r"^[0-9]+(?:\.[0-9]+){1,3}(?:[-+][A-Za-z0-9._-]+)?$")
SAFE_RELATIVE_COMPONENT = re.compile(r"^[A-Za-z0-9@._+\-]+$")

GENERIC_ENV_EXACT = (
    "ENV",
    "GCONV_PATH",
    "LOCPATH",
    "NLSPATH",
    "PERL5OPT",
    "RUBYOPT",
    "SSLKEYLOGFILE",
)
GENERIC_ENV_PREFIXES = (
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
AGENT_ENV_EXACT = (
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
AGENT_ENV_PREFIXES = (
    "AGENT_FLEET_QUOTA_FIXTURE_",
    "AGENT_FLEET_TEST_QUOTA_FIXTURE_",
)
ALLOWED_SYSTEM_XATTRS = ("com.apple.provenance",)
CLANG_FLAGS = (
    "-std=c11",
    "-Os",
    "-Wall",
    "-Wextra",
    "-Werror",
    "-Wno-deprecated-declarations",
    "-Wno-unused-function",
    "-Wno-unused-const-variable",
    "-fno-ident",
    "-Wl,-dead_strip",
)
CODESIGN_FLAGS = (
    "--force",
    "--sign",
    "-",
    "--options",
    "runtime",
    "--timestamp=none",
)
PINNED_TOOL_ENV_OVERRIDES = frozenset(
    {
        "CFFIXED_USER_HOME",
        "GIT_CONFIG_GLOBAL",
        "GIT_CONFIG_NOSYSTEM",
        "HOME",
        "LANG",
        "LC_ALL",
        "PATH",
        "SOURCE_DATE_EPOCH",
        "TMPDIR",
        "ZERO_AR_DATE",
    }
)
ROLE_REQUIREMENTS = {
    "agent_fleet": {
        "candidate": ("0.2.0", 2),
        "rollback": ("0.1.5", 1),
    },
    "quota_axi": {
        "candidate": ("0.1.7", None),
        "rollback": ("0.1.5", None),
    },
}


class BuildError(RuntimeError):
    """A fail-closed input, build, integrity, or probe refusal."""


@dataclass(frozen=True)
class ToolPin:
    path: Path
    sha256: str


@dataclass(frozen=True)
class PythonRuntime:
    root: Path
    version: str
    binary_sha256: str
    tree_sha256: str


@dataclass(frozen=True)
class NodeRuntime:
    binary: Path
    version: str
    sha256: str


@dataclass(frozen=True)
class AgentRole:
    role: str
    release_path: str
    version: str
    contract_version: int
    source_repo: Path
    source_commit: str
    source_tree_sha256: str
    wheel: Path
    wheel_sha256: str


@dataclass(frozen=True)
class Dependency:
    name: str
    version: str
    install_path: str
    tarball: Path
    sha256: str


@dataclass(frozen=True)
class QuotaRole:
    role: str
    release_path: str
    version: str
    source_repo: Path
    source_commit: str
    source_tree_sha256: str
    package_tarball: Path
    package_sha256: str
    package_lock: Path
    package_lock_sha256: str
    dependencies: tuple[Dependency, ...]


@dataclass(frozen=True)
class BuildManifest:
    path: Path
    manifest_sha256: str
    output_root: Path
    proof_manifest: Path
    operator_front_door: Path
    transaction_driver: ToolPin
    tools: Mapping[str, ToolPin]
    python_runtime: PythonRuntime
    node_runtime: NodeRuntime
    agent_roles: Mapping[str, AgentRole]
    quota_roles: Mapping[str, QuotaRole]


def _sha256_fd(fd: int) -> str:
    os.lseek(fd, 0, os.SEEK_SET)
    digest = hashlib.sha256()
    while True:
        block = os.read(fd, 1024 * 1024)
        if not block:
            break
        digest.update(block)
    return digest.hexdigest()


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


def _open_verified_file(
    path: Path,
    label: str,
    expected_sha256: str | None = None,
    *,
    executable: bool = False,
    allow_root_owner: bool = False,
) -> tuple[int, os.stat_result, str]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        raise BuildError(f"cannot safely open {label}: {path}: {exc}") from exc
    try:
        before = os.fstat(fd)
        allowed_uids = {os.getuid(), 0} if allow_root_owner else {os.getuid()}
        mode = stat.S_IMODE(before.st_mode)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_uid not in allowed_uids
            or mode & 0o022
        ):
            raise BuildError(
                f"{label} must be an owned, single-link, safe regular file: {path}"
            )
        if executable and not mode & 0o100:
            raise BuildError(f"{label} is not owner-executable: {path}")
        if before.st_uid == 0 and allow_root_owner:
            _require_safe_ancestry(path.parent, label, system_only=True)
        else:
            _require_safe_ancestry(path.parent, label)
        digest = _sha256_fd(fd)
        after = os.fstat(fd)
        current = os.lstat(path)
        if _file_identity(after) != _file_identity(before) or _file_identity(
            current
        ) != _file_identity(before):
            raise BuildError(f"{label} changed while it was verified: {path}")
        if expected_sha256 is not None and digest != expected_sha256:
            raise BuildError(f"{label} SHA-256 does not match its manifest pin: {path}")
        os.lseek(fd, 0, os.SEEK_SET)
        return fd, before, digest
    except BaseException:
        os.close(fd)
        raise


def _revalidate_open_file(
    fd: int,
    before: os.stat_result,
    path: Path,
    label: str,
    expected_sha256: str,
) -> None:
    digest = _sha256_fd(fd)
    after = os.fstat(fd)
    current = os.lstat(path)
    if (
        digest != expected_sha256
        or _file_identity(after) != _file_identity(before)
        or _file_identity(current) != _file_identity(before)
    ):
        raise BuildError(f"{label} changed while it was consumed: {path}")


def _sha256(path: Path) -> str:
    fd, _, digest = _open_verified_file(path, "file")
    os.close(fd)
    return digest


def _read_verified_bytes(
    path: Path,
    label: str,
    expected_sha256: str | None = None,
) -> bytes:
    fd, before, digest = _open_verified_file(path, label, expected_sha256)
    try:
        payload = bytearray()
        while True:
            block = os.read(fd, 1024 * 1024)
            if not block:
                break
            payload.extend(block)
        _revalidate_open_file(fd, before, path, label, digest)
        return bytes(payload)
    finally:
        os.close(fd)


def _run(
    argv: Sequence[str],
    *,
    cwd: Path | None = None,
    env: Mapping[str, str] | None = None,
    timeout: int = 60,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    effective_env = {
        "HOME": "/var/empty",
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin",
        "TMPDIR": "/tmp",
    }
    if env is not None:
        effective_env.update(env)
    try:
        completed = subprocess.run(
            list(argv),
            cwd=cwd,
            env=effective_env,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise BuildError(f"command failed to run: {list(argv)!r}: {exc}") from exc
    if check and completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise BuildError(
            f"command exited {completed.returncode}: {list(argv)!r}: {detail}"
        )
    return completed


def _run_pinned(
    pin: ToolPin,
    arguments: Sequence[str],
    *,
    cwd: Path | None = None,
    env: Mapping[str, str] | None = None,
    timeout: int = 60,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    """Run one hash-pinned tool and reject named-object drift around execution."""
    unexpected_environment = set(env or {}) - PINNED_TOOL_ENV_OVERRIDES
    if unexpected_environment:
        raise BuildError(
            "pinned build tool environment has forbidden overrides: "
            f"{sorted(unexpected_environment)!r}"
        )
    if env is not None and env.get("PATH", "/usr/bin:/bin") != "/usr/bin:/bin":
        raise BuildError("pinned build tool PATH override must remain /usr/bin:/bin")
    tool_fd, before, digest = _open_verified_file(
        pin.path,
        "pinned build tool",
        pin.sha256,
        executable=True,
        allow_root_owner=True,
    )
    os.close(tool_fd)
    try:
        return _run(
            [str(pin.path), *arguments],
            cwd=cwd,
            env=env,
            timeout=timeout,
            check=check,
        )
    finally:
        after_fd, after, after_digest = _open_verified_file(
            pin.path,
            "pinned build tool",
            pin.sha256,
            executable=True,
            allow_root_owner=True,
        )
        os.close(after_fd)
        if _file_identity(after) != _file_identity(before) or after_digest != digest:
            raise BuildError(
                f"pinned build tool identity changed during execution: {pin.path}"
            )


def _require_regular(
    path: Path,
    label: str,
    expected_sha256: str | None = None,
    *,
    executable: bool = False,
    allow_root_owner: bool = False,
) -> None:
    fd, _, _ = _open_verified_file(
        path,
        label,
        expected_sha256,
        executable=executable,
        allow_root_owner=allow_root_owner,
    )
    os.close(fd)


def _require_safe_ancestry(
    path: Path,
    label: str,
    *,
    system_only: bool = False,
) -> None:
    current = path
    saw_private_user_directory = False
    while True:
        try:
            info = os.lstat(current)
        except FileNotFoundError as exc:
            raise BuildError(f"{label} ancestry is missing: {current}") from exc
        if not stat.S_ISDIR(info.st_mode):
            raise BuildError(f"{label} ancestry is not a real directory: {current}")
        mode = stat.S_IMODE(info.st_mode)
        if info.st_uid == os.getuid() and not system_only:
            if mode & 0o022:
                raise BuildError(
                    f"{label} has group/world-writable user ancestry: {current}"
                )
            saw_private_user_directory = True
        elif info.st_uid == 0:
            if mode & 0o022:
                sticky = bool(mode & stat.S_ISVTX)
                if system_only or not sticky or not saw_private_user_directory:
                    raise BuildError(
                        f"{label} has unsafe root-owned ancestry: {current}"
                    )
        else:
            raise BuildError(
                f"{label} ancestry is not owned by current uid or root: {current}"
            )
        if current == current.parent:
            break
        current = current.parent


def _exact_object(
    value: Any,
    keys: set[str],
    label: str,
) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        observed = sorted(value) if isinstance(value, dict) else type(value).__name__
        raise BuildError(
            f"{label} fields are not exact: expected {sorted(keys)!r}, observed {observed!r}"
        )
    return value


def _strict_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise BuildError(f"JSON contains a duplicate object key: {key!r}")
        result[key] = value
    return result


def _read_strict_json(path: Path, label: str) -> dict[str, Any]:
    payload = _read_verified_bytes(path, label)
    return _parse_strict_json_payload(payload, label)


def _parse_strict_json_payload(payload: bytes, label: str) -> dict[str, Any]:
    if len(payload) > MAX_MANIFEST_BYTES:
        raise BuildError(f"{label} exceeds {MAX_MANIFEST_BYTES} bytes")
    try:
        value = json.loads(payload, object_pairs_hook=_strict_pairs)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BuildError(f"{label} is not strict JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise BuildError(f"{label} must contain a JSON object")
    return value


def _sha_value(value: Any, label: str) -> str:
    if not isinstance(value, str) or not SHA256.fullmatch(value):
        raise BuildError(f"{label} must be a lowercase SHA-256 digest")
    return value


def _version(value: Any, label: str) -> str:
    if not isinstance(value, str) or not VERSION.fullmatch(value):
        raise BuildError(f"{label} must be a normalized semantic version")
    return value


def _commit(value: Any, label: str) -> str:
    if not isinstance(value, str) or not GIT_COMMIT.fullmatch(value):
        raise BuildError(f"{label} must be a full lowercase git commit")
    return value


def _relative(value: Any, label: str) -> str:
    if (
        not isinstance(value, str)
        or not value
        or "\x00" in value
        or "\\" in value
    ):
        raise BuildError(f"{label} must be a nonempty POSIX relative path")
    try:
        value.encode("ascii")
    except UnicodeEncodeError as exc:
        raise BuildError(f"{label} must be ASCII for native launcher binding") from exc
    pure = PurePosixPath(value)
    if (
        pure.is_absolute()
        or pure.as_posix() != value
        or any(
            part in {"", ".", ".."} or not SAFE_RELATIVE_COMPONENT.fullmatch(part)
            for part in pure.parts
        )
    ):
        raise BuildError(f"{label} is not a normalized safe relative path: {value!r}")
    return value


def _absolute(value: Any, label: str, *, must_exist: bool = True) -> Path:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise BuildError(f"{label} must be an absolute path string")
    path = Path(value)
    if not path.is_absolute() or Path(os.path.normpath(value)) != path:
        raise BuildError(f"{label} must be an absolute normalized path: {value!r}")
    if must_exist and not path.exists():
        raise BuildError(f"{label} does not exist: {path}")
    anchor = path if path.exists() else path.parent
    if Path(os.path.realpath(anchor)) != anchor:
        raise BuildError(f"{label} has a symlinked or noncanonical path: {path}")
    return path


def _parse_tool(value: Any, label: str, *, system_tool: bool) -> ToolPin:
    raw = _exact_object(value, {"path", "sha256"}, label)
    pin = ToolPin(
        path=_absolute(raw["path"], f"{label}.path"),
        sha256=_sha_value(raw["sha256"], f"{label}.sha256"),
    )
    _require_regular(
        pin.path,
        label,
        pin.sha256,
        executable=True,
        allow_root_owner=system_tool,
    )
    return pin


def _parse_agent_role(value: Any, expected_role: str, label: str) -> AgentRole:
    raw = _exact_object(
        value,
        {
            "role",
            "release_path",
            "version",
            "contract_version",
            "source_repo",
            "source_commit",
            "source_tree_sha256",
            "wheel",
            "wheel_sha256",
        },
        label,
    )
    version = _version(raw["version"], f"{label}.version")
    required_version, required_contract = ROLE_REQUIREMENTS["agent_fleet"][expected_role]
    if raw["role"] != expected_role or version != required_version:
        raise BuildError(f"{label} must be the exact {expected_role} {required_version} role")
    contract = raw["contract_version"]
    if isinstance(contract, bool) or contract != required_contract:
        raise BuildError(f"{label}.contract_version must be {required_contract}")
    source_repo = _absolute(raw["source_repo"], f"{label}.source_repo")
    if not source_repo.is_dir():
        raise BuildError(f"{label}.source_repo must be a directory")
    _require_safe_ancestry(source_repo, f"{label}.source_repo")
    wheel = _absolute(raw["wheel"], f"{label}.wheel")
    role = AgentRole(
        role=expected_role,
        release_path=_relative(raw["release_path"], f"{label}.release_path"),
        version=version,
        contract_version=contract,
        source_repo=source_repo,
        source_commit=_commit(raw["source_commit"], f"{label}.source_commit"),
        source_tree_sha256=_sha_value(
            raw["source_tree_sha256"], f"{label}.source_tree_sha256"
        ),
        wheel=wheel,
        wheel_sha256=_sha_value(raw["wheel_sha256"], f"{label}.wheel_sha256"),
    )
    _require_regular(role.wheel, f"{label} wheel", role.wheel_sha256)
    return role


def _parse_dependency(value: Any, label: str) -> Dependency:
    raw = _exact_object(
        value,
        {"name", "version", "install_path", "tarball", "sha256"},
        label,
    )
    name = raw["name"]
    if not isinstance(name, str) or not name or len(name) > 214:
        raise BuildError(f"{label}.name is invalid")
    install_path = _relative(raw["install_path"], f"{label}.install_path")
    if not install_path.startswith("node_modules/"):
        raise BuildError(f"{label}.install_path must be below node_modules")
    tarball = _absolute(raw["tarball"], f"{label}.tarball")
    dependency = Dependency(
        name=name,
        version=_version(raw["version"], f"{label}.version"),
        install_path=install_path,
        tarball=tarball,
        sha256=_sha_value(raw["sha256"], f"{label}.sha256"),
    )
    _require_regular(tarball, f"{label} tarball", dependency.sha256)
    return dependency


def _parse_quota_role(value: Any, expected_role: str, label: str) -> QuotaRole:
    raw = _exact_object(
        value,
        {
            "role",
            "release_path",
            "version",
            "source_repo",
            "source_commit",
            "source_tree_sha256",
            "package_tarball",
            "package_sha256",
            "package_lock",
            "package_lock_sha256",
            "dependencies",
        },
        label,
    )
    version = _version(raw["version"], f"{label}.version")
    required_version, _ = ROLE_REQUIREMENTS["quota_axi"][expected_role]
    if raw["role"] != expected_role or version != required_version:
        raise BuildError(f"{label} must be the exact {expected_role} {required_version} role")
    if not isinstance(raw["dependencies"], list):
        raise BuildError(f"{label}.dependencies must be an array")
    dependencies = tuple(
        _parse_dependency(item, f"{label}.dependencies[{index}]")
        for index, item in enumerate(raw["dependencies"])
    )
    paths = [dependency.install_path for dependency in dependencies]
    if paths != sorted(paths, key=lambda item: item.encode("utf-8")) or len(paths) != len(set(paths)):
        raise BuildError(f"{label}.dependencies must be unique and path-sorted")
    source_repo = _absolute(raw["source_repo"], f"{label}.source_repo")
    if not source_repo.is_dir():
        raise BuildError(f"{label}.source_repo must be a directory")
    _require_safe_ancestry(source_repo, f"{label}.source_repo")
    package_tarball = _absolute(raw["package_tarball"], f"{label}.package_tarball")
    package_lock = _absolute(raw["package_lock"], f"{label}.package_lock")
    role = QuotaRole(
        role=expected_role,
        release_path=_relative(raw["release_path"], f"{label}.release_path"),
        version=version,
        source_repo=source_repo,
        source_commit=_commit(raw["source_commit"], f"{label}.source_commit"),
        source_tree_sha256=_sha_value(
            raw["source_tree_sha256"], f"{label}.source_tree_sha256"
        ),
        package_tarball=package_tarball,
        package_sha256=_sha_value(raw["package_sha256"], f"{label}.package_sha256"),
        package_lock=package_lock,
        package_lock_sha256=_sha_value(
            raw["package_lock_sha256"], f"{label}.package_lock_sha256"
        ),
        dependencies=dependencies,
    )
    _require_regular(package_tarball, f"{label} package tarball", role.package_sha256)
    _require_regular(package_lock, f"{label} package lock", role.package_lock_sha256)
    return role


def load_manifest(path: Path, *, allow_existing_outputs: bool = False) -> BuildManifest:
    """Load, strictly type-check, and hash-pin a builder input manifest."""
    path = _absolute(str(path), "builder manifest")
    manifest_payload = _read_verified_bytes(path, "builder manifest")
    raw = _exact_object(
        _parse_strict_json_payload(manifest_payload, "builder manifest"),
        {
            "schema_version",
            "output_root",
            "proof_manifest",
            "operator_front_door",
            "transaction_driver",
            "tools",
            "python_runtime",
            "node_runtime",
            "agent_fleet",
            "quota_axi",
        },
        "builder manifest",
    )
    if raw["schema_version"] != SCHEMA_VERSION:
        raise BuildError(f"builder manifest schema must be {SCHEMA_VERSION}")
    output_root = _absolute(raw["output_root"], "output_root")
    if not output_root.is_dir():
        raise BuildError("output_root must be an existing canonical directory")
    output_info = os.lstat(output_root)
    if output_info.st_uid != os.getuid() or stat.S_IMODE(output_info.st_mode) & 0o022:
        raise BuildError("output_root must be owned and not group/world writable")
    _require_safe_ancestry(output_root, "output_root")
    proof_manifest = _absolute(
        raw["proof_manifest"], "proof_manifest", must_exist=False
    )
    if proof_manifest.parent != output_root or proof_manifest.name in {"", ".", ".."}:
        raise BuildError("proof_manifest must be an absent direct child of output_root")
    if proof_manifest.exists() and not allow_existing_outputs:
        raise BuildError(f"proof_manifest already exists; refusing overwrite: {proof_manifest}")
    operator_front_door = _absolute(
        raw["operator_front_door"], "operator_front_door", must_exist=False
    )
    if operator_front_door.name != "agent-fleet":
        raise BuildError("operator_front_door basename must be agent-fleet")
    front_parent = operator_front_door.parent
    if not front_parent.is_dir() or Path(os.path.realpath(front_parent)) != front_parent:
        raise BuildError("operator_front_door parent must be an existing canonical directory")
    front_parent_info = os.lstat(front_parent)
    if front_parent_info.st_uid != os.getuid() or stat.S_IMODE(front_parent_info.st_mode) & 0o022:
        raise BuildError("operator_front_door parent must be owned and not group/world writable")
    _require_safe_ancestry(front_parent, "operator_front_door parent")
    tools_raw = _exact_object(
        raw["tools"],
        {"clang", "codesign", "file", "git", "otool", "xattr"},
        "tools",
    )
    tools = {
        name: _parse_tool(value, f"tools.{name}", system_tool=True)
        for name, value in tools_raw.items()
    }
    transaction_driver = _parse_tool(
        raw["transaction_driver"], "transaction_driver", system_tool=False
    )

    python_raw = _exact_object(
        raw["python_runtime"],
        {"root", "version", "binary_sha256", "tree_sha256"},
        "python_runtime",
    )
    python_root = _absolute(python_raw["root"], "python_runtime.root")
    if not python_root.is_dir():
        raise BuildError("python_runtime.root must be a directory")
    _require_safe_ancestry(python_root, "python_runtime.root")
    python_runtime = PythonRuntime(
        root=python_root,
        version=_version(python_raw["version"], "python_runtime.version"),
        binary_sha256=_sha_value(
            python_raw["binary_sha256"], "python_runtime.binary_sha256"
        ),
        tree_sha256=_sha_value(python_raw["tree_sha256"], "python_runtime.tree_sha256"),
    )
    _require_regular(
        python_root / "bin/python3.11",
        "pinned Python binary",
        python_runtime.binary_sha256,
        executable=True,
    )
    if not (python_root / "lib").is_dir():
        raise BuildError("python_runtime.root has no lib directory")

    node_raw = _exact_object(
        raw["node_runtime"],
        {"binary", "version", "sha256"},
        "node_runtime",
    )
    node_binary = _absolute(node_raw["binary"], "node_runtime.binary")
    node_runtime = NodeRuntime(
        binary=node_binary,
        version=_version(node_raw["version"], "node_runtime.version"),
        sha256=_sha_value(node_raw["sha256"], "node_runtime.sha256"),
    )
    _require_regular(node_binary, "pinned Node binary", node_runtime.sha256, executable=True)

    agents_raw = _exact_object(
        raw["agent_fleet"], {"candidate", "rollback"}, "agent_fleet"
    )
    quotas_raw = _exact_object(raw["quota_axi"], {"candidate", "rollback"}, "quota_axi")
    agent_roles = {
        role: _parse_agent_role(agents_raw[role], role, f"agent_fleet.{role}")
        for role in ("candidate", "rollback")
    }
    quota_roles = {
        role: _parse_quota_role(quotas_raw[role], role, f"quota_axi.{role}")
        for role in ("candidate", "rollback")
    }
    release_paths = [item.release_path for item in (*agent_roles.values(), *quota_roles.values())]
    if len(release_paths) != len(set(release_paths)):
        raise BuildError("all four release_path values must be distinct")
    for relative in release_paths:
        final = output_root / relative
        if (final.exists() or final.is_symlink()) and not allow_existing_outputs:
            raise BuildError(f"final release already exists; refusing overwrite: {final}")
        parent = final.parent
        if not parent.is_dir() or Path(os.path.realpath(parent)) != parent:
            raise BuildError(f"final release parent must already be canonical: {parent}")
        info = os.lstat(parent)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o022:
            raise BuildError(f"final release parent is not safely owned: {parent}")
        _require_safe_ancestry(parent, "final release parent")
    return BuildManifest(
        path=path,
        manifest_sha256=hashlib.sha256(manifest_payload).hexdigest(),
        output_root=output_root,
        proof_manifest=proof_manifest,
        operator_front_door=operator_front_door,
        transaction_driver=transaction_driver,
        tools=tools,
        python_runtime=python_runtime,
        node_runtime=node_runtime,
        agent_roles=agent_roles,
        quota_roles=quota_roles,
    )


def _load_transaction_driver(pin: ToolPin) -> ModuleType:
    fd, before, digest = _open_verified_file(
        pin.path,
        "transaction driver",
        pin.sha256,
        executable=True,
    )
    try:
        payload = bytearray()
        while True:
            block = os.read(fd, 1024 * 1024)
            if not block:
                break
            payload.extend(block)
        _revalidate_open_file(fd, before, pin.path, "transaction driver", digest)
        name = "sealed_runtime_transaction_driver"
        module = ModuleType(name)
        module.__file__ = str(pin.path)
        module.__package__ = ""
        sys.modules[name] = module
        code = compile(bytes(payload), str(pin.path), "exec", dont_inherit=True)
        exec(code, module.__dict__)
        _revalidate_open_file(fd, before, pin.path, "transaction driver", digest)
    except Exception as exc:
        if isinstance(exc, BuildError):
            raise
        raise BuildError(f"cannot load the pinned transaction driver: {exc}") from exc
    finally:
        os.close(fd)
    for name in ("compute_release_tree_sha256", "compute_release_proof"):
        if not callable(getattr(module, name, None)):
            raise BuildError(f"transaction driver lacks {name}")
    return module


def _tree_sha256(driver: ModuleType, root: Path, label: str) -> str:
    try:
        value = str(driver.compute_release_tree_sha256(root, label))
    except Exception as exc:
        raise BuildError(f"{label} is not a closed release tree: {exc}") from exc
    if not SHA256.fullmatch(value):
        raise BuildError(f"{label} tree digest is malformed")
    return value


def _git(manifest: BuildManifest, source: Path, *arguments: str) -> str:
    _require_safe_ancestry(source, "git source repository")
    result = _run_pinned(
        manifest.tools["git"],
        ["--no-replace-objects", "-C", str(source), *arguments],
        env={"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"},
    ).stdout.strip()
    _require_safe_ancestry(source, "git source repository")
    return result


def _git_archive(manifest: BuildManifest, source: Path, commit: str) -> dict[str, tuple[str, bytes]]:
    resolved = _git(manifest, source, "rev-parse", f"{commit}^{{commit}}")
    if resolved != commit:
        raise BuildError(f"source commit is unavailable or ambiguous: {source} {commit}")
    git = manifest.tools["git"]
    _require_safe_ancestry(source, "git source repository")
    git_fd, git_before, git_digest = _open_verified_file(
        git.path,
        "pinned build tool",
        git.sha256,
        executable=True,
        allow_root_owner=True,
    )
    os.close(git_fd)
    try:
        completed = subprocess.run(
            [
                str(git.path),
                "--no-replace-objects",
                "-C",
                str(source),
                "archive",
                "--format=tar",
                commit,
            ],
            check=False,
            capture_output=True,
            env={
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_CONFIG_NOSYSTEM": "1",
                "HOME": "/var/empty",
                "LANG": "C",
                "LC_ALL": "C",
                "PATH": "/usr/bin:/bin",
                "TMPDIR": "/tmp",
            },
            timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise BuildError(f"cannot archive exact source commit {commit}: {exc}") from exc
    finally:
        after_fd, git_after, after_digest = _open_verified_file(
            git.path,
            "pinned build tool",
            git.sha256,
            executable=True,
            allow_root_owner=True,
        )
        os.close(after_fd)
        if (
            _file_identity(git_after) != _file_identity(git_before)
            or after_digest != git_digest
        ):
            raise BuildError(f"pinned build tool identity changed during archive: {git.path}")
        _require_safe_ancestry(source, "git source repository")
    if completed.returncode != 0:
        raise BuildError(
            f"cannot archive exact source commit {commit}: "
            + completed.stderr.decode(errors="replace").strip()
        )
    members: dict[str, tuple[str, bytes]] = {}
    with tarfile.open(fileobj=io.BytesIO(completed.stdout), mode="r:") as archive:
        for member in archive.getmembers():
            if member.isdir():
                continue
            relative = _relative(member.name, "git archive member")
            if relative in members:
                raise BuildError(f"git archive repeats {relative}")
            if member.isfile():
                extracted = archive.extractfile(member)
                if extracted is None:
                    raise BuildError(f"cannot read git archive member {relative}")
                members[relative] = ("file", extracted.read())
            elif member.issym():
                target = member.linkname.encode("utf-8")
                members[relative] = ("symlink", target)
            else:
                raise BuildError(f"git archive has unsupported member {relative}")
    return members


def _archive_tree_sha256(members: Mapping[str, tuple[str, bytes]]) -> str:
    digest = hashlib.sha256(b"bridge-git-archive-v1\0")
    for relative in sorted(members, key=lambda item: item.encode("utf-8")):
        kind, payload = members[relative]
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(kind.encode("ascii"))
        digest.update(b"\0")
        digest.update(hashlib.sha256(payload).digest())
    return digest.hexdigest()


def _validate_source_commit(
    manifest: BuildManifest,
    source: Path,
    commit: str,
    expected_tree: str,
    label: str,
) -> dict[str, tuple[str, bytes]]:
    members = _git_archive(manifest, source, commit)
    observed = _archive_tree_sha256(members)
    if observed != expected_tree:
        raise BuildError(
            f"{label} canonical source-tree SHA-256 is {observed}; expected {expected_tree}"
        )
    return members


def _wheel_members(role: AgentRole, source: Mapping[str, tuple[str, bytes]]) -> dict[str, bytes]:
    members: dict[str, bytes] = {}
    fd, before, digest = _open_verified_file(
        role.wheel,
        f"{role.role} Agent Fleet wheel",
        role.wheel_sha256,
    )
    try:
        with os.fdopen(os.dup(fd), "rb") as raw:
            with zipfile.ZipFile(raw) as archive:
                bad = archive.testzip()
                if bad is not None:
                    raise BuildError(
                        f"{role.role} Agent Fleet wheel has a bad member: {bad}"
                    )
                for info in archive.infolist():
                    if info.is_dir():
                        continue
                    relative = _relative(info.filename, "wheel member")
                    file_type = (info.external_attr >> 16) & 0o170000
                    if file_type == stat.S_IFLNK or relative in members:
                        raise BuildError(f"wheel member is linked or repeated: {relative}")
                    members[relative] = archive.read(info)
        _revalidate_open_file(
            fd,
            before,
            role.wheel,
            f"{role.role} Agent Fleet wheel",
            digest,
        )
    finally:
        os.close(fd)
    dist = f"agent_fleet-{role.version}.dist-info"
    metadata_path = f"{dist}/METADATA"
    record_path = f"{dist}/RECORD"
    required = {
        "agent_fleet/__init__.py",
        "agent_fleet/__main__.py",
        "agent_fleet/config.py",
        "agent_fleet/models.py",
        metadata_path,
        record_path,
    }
    if role.role == "candidate":
        required.update(
            {
                "agent_fleet/enrollment.py",
                "agent_fleet/identity.py",
                "agent_fleet/provision.py",
                "agent_fleet/recovery.py",
            }
        )
    if not required.issubset(members):
        raise BuildError(
            f"{role.role} Agent Fleet wheel omits required members: {sorted(required - set(members))!r}"
        )
    metadata = members[metadata_path].decode("utf-8")
    if f"\nVersion: {role.version}\n" not in f"\n{metadata}" or "\nName: agent-fleet\n" not in f"\n{metadata}":
        raise BuildError(f"{role.role} Agent Fleet wheel metadata identity is wrong")
    try:
        rows = list(csv.reader(io.StringIO(members[record_path].decode("utf-8"))))
    except UnicodeDecodeError as exc:
        raise BuildError("Agent Fleet wheel RECORD is not UTF-8") from exc
    if len(rows) != len(members):
        raise BuildError("Agent Fleet wheel RECORD membership is incomplete")
    seen: set[str] = set()
    for row in rows:
        if len(row) != 3:
            raise BuildError("Agent Fleet wheel RECORD row is malformed")
        relative, encoded_hash, encoded_size = row
        _relative(relative, "wheel RECORD path")
        if relative in seen or relative not in members:
            raise BuildError("Agent Fleet wheel RECORD repeats or invents a member")
        seen.add(relative)
        payload = members[relative]
        if relative == record_path:
            if encoded_hash or encoded_size:
                raise BuildError("Agent Fleet wheel RECORD self-row must be empty")
            continue
        if not encoded_hash.startswith("sha256=") or encoded_size != str(len(payload)):
            raise BuildError(f"Agent Fleet wheel RECORD metadata is wrong: {relative}")
        try:
            expected = base64.urlsafe_b64decode(
                encoded_hash.removeprefix("sha256=") + "=="
            )
        except ValueError as exc:
            raise BuildError(f"Agent Fleet wheel RECORD hash is invalid: {relative}") from exc
        if expected != hashlib.sha256(payload).digest():
            raise BuildError(f"Agent Fleet wheel RECORD hash failed: {relative}")
    source_package = {
        path.removeprefix("src/"): payload
        for path, (kind, payload) in source.items()
        if kind == "file" and path.startswith("src/agent_fleet/")
    }
    installed_package = {
        path: payload
        for path, payload in members.items()
        if path.startswith("agent_fleet/")
    }
    if installed_package != source_package:
        raise BuildError(
            f"{role.role} Agent Fleet wheel package does not match its exact source commit"
        )
    allowed_generated = {
        metadata_path,
        record_path,
        f"{dist}/WHEEL",
        f"{dist}/entry_points.txt",
        f"{dist}/licenses/LICENSE",
    }
    extras = set(members) - set(installed_package) - allowed_generated
    if extras:
        raise BuildError(
            f"{role.role} Agent Fleet wheel contains non-source or non-minimal generated members: "
            f"{sorted(extras)!r}"
        )
    return members


def _safe_package_members(
    path: Path,
    label: str,
    expected_sha256: str | None = None,
) -> dict[str, bytes]:
    members: dict[str, bytes] = {}
    fd, before, digest = _open_verified_file(path, label, expected_sha256)
    try:
        with os.fdopen(os.dup(fd), "rb") as raw:
            try:
                archive = tarfile.open(fileobj=raw, mode="r:*")
            except (OSError, tarfile.TarError) as exc:
                raise BuildError(
                    f"{label} is not a readable package archive: {exc}"
                ) from exc
            with archive:
                for member in archive.getmembers():
                    pure = PurePosixPath(member.name)
                    if not pure.parts or pure.parts[0] != "package":
                        raise BuildError(
                            f"{label} member is outside package/: {member.name!r}"
                        )
                    if len(pure.parts) == 1:
                        if member.isdir():
                            continue
                        raise BuildError(f"{label} has a non-directory package root")
                    relative = _relative(
                        PurePosixPath(*pure.parts[1:]).as_posix(), f"{label} member"
                    )
                    if member.isdir():
                        continue
                    if not member.isfile() or relative in members:
                        raise BuildError(
                            f"{label} member is linked, special, or repeated: {relative}"
                        )
                    extracted = archive.extractfile(member)
                    if extracted is None:
                        raise BuildError(f"cannot extract {label} member: {relative}")
                    members[relative] = extracted.read()
        _revalidate_open_file(fd, before, path, label, digest)
    finally:
        os.close(fd)
    if not members:
        raise BuildError(f"{label} has no files")
    return members


def _package_identity(
    members: Mapping[str, bytes],
    name: str,
    version: str,
    label: str,
) -> dict[str, Any]:
    try:
        package = json.loads(members["package.json"])
    except (KeyError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BuildError(f"{label} has no valid package.json") from exc
    if not isinstance(package, dict) or package.get("name") != name or package.get("version") != version:
        raise BuildError(f"{label} package identity must be {name}@{version}")
    scripts = package.get("scripts", {})
    dangerous = {"preinstall", "install", "postinstall", "prepare"}
    if not isinstance(scripts, dict) or dangerous & set(scripts):
        raise BuildError(f"{label} contains an install-time script")
    return package


def _validate_quota_inputs(
    role: QuotaRole,
    source: Mapping[str, tuple[str, bytes]],
) -> tuple[dict[str, bytes], dict[str, dict[str, bytes]], bytes]:
    package_members = _safe_package_members(
        role.package_tarball,
        f"{role.role} Quota AXI package",
        role.package_sha256,
    )
    package = _package_identity(
        package_members, "quota-axi", role.version, f"{role.role} Quota AXI package"
    )
    bin_value = package.get("bin")
    if isinstance(bin_value, str):
        entry = bin_value
    elif isinstance(bin_value, dict) and set(bin_value) == {"quota-axi"}:
        entry = bin_value["quota-axi"]
    else:
        raise BuildError(f"{role.role} Quota AXI bin contract is not exact")
    if not isinstance(entry, str) or entry.removeprefix("./") != "dist/bin/quota-axi.js":
        raise BuildError(f"{role.role} Quota AXI entrypoint is not exact")
    if "dist/bin/quota-axi.js" not in package_members:
        raise BuildError(f"{role.role} Quota AXI package omits its entrypoint")
    source_package = source.get("package.json")
    if source_package is None or source_package[0] != "file":
        raise BuildError(f"{role.role} Quota AXI source commit omits package.json")
    try:
        source_identity = json.loads(source_package[1])
    except json.JSONDecodeError as exc:
        raise BuildError("Quota AXI source package.json is invalid") from exc
    if source_identity.get("name") != "quota-axi" or source_identity.get("version") != role.version:
        raise BuildError(f"{role.role} Quota AXI source identity does not match its package")
    for relative, payload in package_members.items():
        source_member = source.get(relative)
        if source_member != ("file", payload):
            raise BuildError(
                f"{role.role} Quota AXI package member is absent or differs from exact source: {relative}"
            )

    dependency_members: dict[str, dict[str, bytes]] = {}
    for dependency in role.dependencies:
        members = _safe_package_members(
            dependency.tarball,
            f"{role.role} dependency {dependency.name}",
            dependency.sha256,
        )
        _package_identity(
            members,
            dependency.name,
            dependency.version,
            f"{role.role} dependency {dependency.name}",
        )
        dependency_members[dependency.install_path] = members

    lock_bytes = _read_verified_bytes(
        role.package_lock,
        f"{role.role} Quota AXI package lock",
        role.package_lock_sha256,
    )
    try:
        lock = json.loads(lock_bytes, object_pairs_hook=_strict_pairs)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BuildError(f"{role.role} Quota AXI package lock is invalid") from exc
    if not isinstance(lock, dict) or lock.get("lockfileVersion") != 3:
        raise BuildError(f"{role.role} Quota AXI package lock must use lockfileVersion 3")
    packages = lock.get("packages")
    if not isinstance(packages, dict):
        raise BuildError(f"{role.role} Quota AXI package lock has no packages map")
    expected_paths = {"node_modules/quota-axi", *(item.install_path for item in role.dependencies)}
    if set(packages) - {""} != expected_paths:
        raise BuildError(f"{role.role} Quota AXI lock package closure is not exact")
    if packages["node_modules/quota-axi"].get("version") != role.version:
        raise BuildError(f"{role.role} Quota AXI lock does not pin quota-axi")
    root = packages.get("")
    root_dependencies = root.get("dependencies") if isinstance(root, dict) else None
    if not isinstance(root_dependencies, dict) or root_dependencies.get("quota-axi") != role.version:
        raise BuildError(f"{role.role} Quota AXI lock root dependency is not exact")
    for dependency in role.dependencies:
        record = packages.get(dependency.install_path)
        if not isinstance(record, dict) or record.get("version") != dependency.version:
            raise BuildError(
                f"{role.role} Quota AXI lock does not pin {dependency.install_path}"
            )
    return package_members, dependency_members, lock_bytes


def _content_tree_sha256(root: Path, relatives: Sequence[str], label: str) -> str:
    digest = hashlib.sha256(b"bridge-runtime-source-v1\0")
    observed: list[Path] = []
    for relative in relatives:
        path = root / relative
        if not path.exists() or path.is_symlink():
            raise BuildError(f"{label} path is missing or symlinked: {path}")
        observed.append(path)
        if path.is_dir():
            observed.extend(path.rglob("*"))
    unique = sorted(
        set(observed), key=lambda item: item.relative_to(root).as_posix().encode("utf-8")
    )
    for path in unique:
        relative = path.relative_to(root).as_posix()
        info = os.lstat(path)
        if stat.S_ISLNK(info.st_mode):
            raise BuildError(f"{label} contains a symlink: {path}")
        if stat.S_ISDIR(info.st_mode):
            kind = b"directory"
            value = b""
        elif stat.S_ISREG(info.st_mode) and info.st_nlink == 1:
            kind = b"file"
            value = bytes.fromhex(_sha256(path))
        else:
            raise BuildError(f"{label} contains an unsupported path: {path}")
        digest.update(relative.encode("utf-8") + b"\0" + kind + b"\0" + value)
    return digest.hexdigest()


def _copy_regular(source: Path, destination: Path) -> None:
    source_fd, source_info, source_digest = _open_verified_file(
        source, "copy source"
    )
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        with destination.open("xb") as writer:
            while True:
                block = os.read(source_fd, 1024 * 1024)
                if not block:
                    break
                writer.write(block)
            _revalidate_open_file(
                source_fd, source_info, source, "copy source", source_digest
            )
            os.fchmod(writer.fileno(), 0o600)
            writer.flush()
            os.fsync(writer.fileno())
    except FileExistsError as exc:
        raise BuildError(f"copy destination already exists: {destination}") from exc
    finally:
        os.close(source_fd)


def _fsync_directory(path: Path) -> None:
    flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        raise BuildError(f"cannot open directory for durability sync: {path}: {exc}") from exc
    try:
        os.fsync(fd)
    except OSError as exc:
        raise BuildError(f"cannot durability-sync directory: {path}: {exc}") from exc
    finally:
        os.close(fd)


def _fsync_sealed_tree(root: Path) -> None:
    """Durably sync every regular payload and directory in a closed tree."""
    directories: list[Path] = []
    files: list[Path] = []
    for directory, names, filenames in os.walk(
        root, topdown=True, followlinks=False
    ):
        names.sort()
        filenames.sort()
        base = Path(directory)
        directories.append(base)
        files.extend(base / name for name in filenames)
    for path in files:
        fd, before, digest = _open_verified_file(path, "sealed publication payload")
        try:
            os.fsync(fd)
            _revalidate_open_file(
                fd,
                before,
                path,
                "sealed publication payload",
                digest,
            )
        except OSError as exc:
            raise BuildError(f"cannot durability-sync sealed payload: {path}: {exc}") from exc
        finally:
            os.close(fd)
    for directory in reversed(directories):
        _fsync_directory(directory)


def _copy_tree(source: Path, destination: Path) -> None:
    if destination.exists():
        raise BuildError(f"copy destination already exists: {destination}")
    destination.mkdir(parents=True)
    for directory, names, files in os.walk(source, topdown=True, followlinks=False):
        names.sort()
        files.sort()
        base = Path(directory)
        relative = base.relative_to(source)
        target_base = destination / relative
        for name in names:
            item = base / name
            info = os.lstat(item)
            if not stat.S_ISDIR(info.st_mode):
                raise BuildError(f"copy source tree contains a symlink or special path: {item}")
            (target_base / name).mkdir()
        for name in files:
            item = base / name
            _copy_regular(item, target_base / name)


def _extract_members(members: Mapping[str, bytes], destination: Path) -> None:
    destination.mkdir(parents=True)
    for relative in sorted(members, key=lambda item: item.encode("utf-8")):
        target = destination.joinpath(*PurePosixPath(relative).parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            raise BuildError(f"package extraction would overwrite {target}")
        with target.open("xb") as handle:
            handle.write(members[relative])
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(target, 0o600)


def _write_bytes(path: Path, payload: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        with path.open("xb") as handle:
            handle.write(payload)
            os.fchmod(handle.fileno(), mode)
            handle.flush()
            os.fsync(handle.fileno())
    except FileExistsError as exc:
        raise BuildError(f"refusing to overwrite build artifact: {path}") from exc
    _fsync_directory(path.parent)


def _write_json(path: Path, value: Any, mode: int = 0o600) -> None:
    _write_bytes(
        path,
        (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode(
            "utf-8"
        ),
        mode,
    )


def _unseal(root: Path) -> None:
    if not root.exists() or root.is_symlink():
        return
    for directory, names, files in os.walk(root, topdown=True, followlinks=False):
        base = Path(directory)
        try:
            os.chmod(base, 0o700)
        except OSError:
            pass
        for name in [*names, *files]:
            path = base / name
            try:
                if not path.is_symlink():
                    os.chmod(path, 0o700 if path.is_dir() else 0o600)
            except OSError:
                pass


def _remove_tree(root: Path) -> None:
    if root.exists() and not root.is_symlink():
        _unseal(root)
        shutil.rmtree(root)


def _normalize_modes(root: Path, executables: Iterable[str], xattr: ToolPin) -> None:
    executable_set = set(executables)
    _unseal(root)
    cleared = _run_pinned(
        xattr,
        ["-c", "-r", "-s", str(root)],
        check=False,
    )
    if cleared.returncode != 0:
        raise BuildError(
            f"cannot strip source xattrs: {cleared.stderr.strip() or cleared.stdout.strip()}"
        )
    observed: set[str] = set()
    for directory, names, files in os.walk(root, topdown=False, followlinks=False):
        names.sort()
        files.sort()
        base = Path(directory)
        for name in files:
            path = base / name
            if path.is_symlink():
                raise BuildError(f"sealed tree contains a symlink: {path}")
            relative = path.relative_to(root).as_posix()
            mode = 0o555 if relative in executable_set else 0o444
            os.chmod(path, mode)
            if mode == 0o555:
                observed.add(relative)
        for name in names:
            path = base / name
            if path.is_symlink():
                raise BuildError(f"sealed tree contains a symlink: {path}")
            os.chmod(path, 0o555)
        os.chmod(base, 0o555)
    if observed != executable_set:
        raise BuildError(
            f"executable closure mismatch: missing={sorted(executable_set - observed)!r}, "
            f"extra={sorted(observed - executable_set)!r}"
        )


def _assert_closed_tree(root: Path, xattr: ToolPin) -> None:
    if Path(os.path.realpath(root)) != root:
        raise BuildError(f"sealed root is not canonical: {root}")
    paths = [root]
    for directory, names, files in os.walk(root, topdown=True, followlinks=False):
        base = Path(directory)
        paths.extend(base / name for name in [*names, *files])
    for path in paths:
        info = os.lstat(path)
        if (
            info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) & 0o222
            or stat.S_ISLNK(info.st_mode)
            or (stat.S_ISREG(info.st_mode) and info.st_nlink != 1)
        ):
            raise BuildError(f"sealed release has unsafe identity or mode: {path}")
        if hasattr(os, "listxattr"):
            try:
                xattrs = set(os.listxattr(path, follow_symlinks=False))
            except OSError as exc:
                raise BuildError(f"cannot inspect sealed xattrs: {path}: {exc}") from exc
        else:
            inspected = _run_pinned(
                xattr,
                ["-s", str(path)],
                check=False,
            )
            if inspected.returncode != 0:
                raise BuildError(
                    f"cannot inspect sealed xattrs: {path}: {inspected.stderr.strip()}"
                )
            xattrs = set(inspected.stdout.splitlines())
        unexpected = xattrs - set(ALLOWED_SYSTEM_XATTRS)
        if unexpected:
            raise BuildError(f"sealed release has forbidden xattrs: {path}: {sorted(unexpected)}")


def _runtime_entries(root: Path, relatives: Iterable[str]) -> list[dict[str, str]]:
    entries: list[dict[str, str]] = []
    paths: set[Path] = set()
    for relative in relatives:
        path = root / relative
        if not path.exists() or path.is_symlink():
            raise BuildError(f"protected closure path is missing or symlinked: {path}")
        if path.is_dir():
            paths.update(item for item in path.rglob("*") if item.is_file())
        else:
            paths.add(path)
    for path in sorted(paths, key=lambda item: item.relative_to(root).as_posix().encode("utf-8")):
        info = os.lstat(path)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise BuildError(f"protected closure member is not a single-link regular file: {path}")
        entries.append(
            {
                "path": path.relative_to(root).as_posix(),
                "mode": f"{stat.S_IMODE(info.st_mode):04o}",
                "sha256": _sha256(path),
            }
        )
    if not entries:
        raise BuildError("protected runtime closure is empty")
    return entries


def _closure_digest(entries: Sequence[Mapping[str, str]]) -> str:
    payload = json.dumps(
        list(entries), sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    return hashlib.sha256(b"bridge-runtime-closure-v1\0" + payload).hexdigest()


def _directory_inventory(root: Path, walk_roots: Sequence[str]) -> list[str]:
    directories: set[str] = set()
    for relative in walk_roots:
        path = root / relative
        if not path.is_dir() or path.is_symlink():
            raise BuildError(f"closure walk root is not a physical directory: {path}")
        directories.add(relative)
        for item in path.rglob("*"):
            if item.is_symlink():
                raise BuildError(f"closure walk root contains a symlink: {item}")
            if item.is_dir():
                directories.add(item.relative_to(root).as_posix())
    return sorted(directories, key=lambda item: item.encode("utf-8"))


def _c_quote(value: str) -> str:
    try:
        value.encode("ascii")
    except UnicodeEncodeError as exc:
        raise BuildError("native launcher binding contains a non-ASCII path") from exc
    return json.dumps(value)


def _c_array(values: Sequence[str]) -> str:
    if not values:
        return "    NULL,"
    return "\n".join(f"    {_c_quote(value)}," for value in values)


def _c_entry_array(entries: Sequence[Mapping[str, str]]) -> str:
    return "\n".join(
        "    {"
        + _c_quote(entry["path"])
        + ", "
        + str(int(entry["mode"], 8))
        + ", "
        + _c_quote(entry["sha256"])
        + "},"
        for entry in entries
    )


C_SUPPORT = r'''
#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <fts.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <mach-o/dyld.h>

extern char **environ;

struct file_entry { const char *path; mode_t mode; const char *sha256; };

static void fail(const char *message) {
    int saved = errno;
    if (saved != 0) {
        (void)fprintf(stderr, "%s: %s: %s\n", PROGRAM_NAME, message, strerror(saved));
    } else {
        (void)fprintf(stderr, "%s: %s\n", PROGRAM_NAME, message);
    }
    exit(126);
}

static char *join_path(const char *root, const char *relative) {
    size_t left = strlen(root), right = strlen(relative);
    if (left > SIZE_MAX - right - 2U) { errno = EOVERFLOW; fail("path too long"); }
    char *result = malloc(left + right + 2U);
    if (result == NULL) fail("cannot allocate path");
    (void)memcpy(result, root, left);
    result[left] = '/';
    (void)memcpy(result + left + 1U, relative, right + 1U);
    return result;
}

static char *physical_self(void) {
    uint32_t size = 0;
    if (_NSGetExecutablePath(NULL, &size) != -1 || size == 0) {
        errno = EINVAL; fail("cannot size executable path");
    }
    char *reported = malloc((size_t)size);
    if (reported == NULL) fail("cannot allocate executable path");
    if (_NSGetExecutablePath(reported, &size) != 0) {
        free(reported); errno = EINVAL; fail("cannot read executable path");
    }
    char *resolved = realpath(reported, NULL);
    if (resolved == NULL) { free(reported); fail("cannot resolve executable path"); }
    if (strcmp(reported, resolved) != 0) {
        free(reported); free(resolved); errno = 0;
        fail("launcher must use its canonical physical path");
    }
    free(reported);
    return resolved;
}

static void require_self_identity(const char *path) {
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) fail("cannot open physical executable");
    struct stat opened, named;
    if (fstat(fd, &opened) != 0 || lstat(path, &named) != 0) {
        (void)close(fd); fail("cannot stat physical executable");
    }
    if (!S_ISREG(opened.st_mode) || opened.st_uid != getuid() ||
        opened.st_nlink != 1 || (opened.st_mode & 07777) != 0555 ||
        opened.st_dev != named.st_dev || opened.st_ino != named.st_ino ||
        opened.st_uid != named.st_uid || opened.st_nlink != named.st_nlink ||
        opened.st_mode != named.st_mode) {
        (void)close(fd); errno = 0; fail("physical executable metadata drifted");
    }
    if (close(fd) != 0) fail("cannot close physical executable");
}

static int hex_value(unsigned char value) {
    if (value >= '0' && value <= '9') return (int)(value - '0');
    if (value >= 'a' && value <= 'f') return (int)(value - 'a') + 10;
    return -1;
}

static void require_file(const char *path, mode_t mode, const char *expected) {
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) fail("cannot open protected runtime file");
    struct stat info;
    if (fstat(fd, &info) != 0) { (void)close(fd); fail("cannot stat protected runtime file"); }
    if (!S_ISREG(info.st_mode) || info.st_uid != getuid() || info.st_nlink != 1 ||
        (info.st_mode & 07777) != mode || info.st_size < 0 ||
        (uint64_t)info.st_size > (uint64_t)UINT_MAX) {
        (void)close(fd); errno = 0; fail("protected runtime file metadata drifted");
    }
    const void *mapped = NULL;
    if (info.st_size > 0) {
        mapped = mmap(NULL, (size_t)info.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
        if (mapped == MAP_FAILED) { (void)close(fd); fail("cannot map protected runtime file"); }
    }
    unsigned char observed[CC_SHA256_DIGEST_LENGTH];
    static const unsigned char empty = 0;
    (void)CC_SHA256(info.st_size > 0 ? mapped : &empty, (CC_LONG)info.st_size, observed);
    if (info.st_size > 0 && munmap((void *)mapped, (size_t)info.st_size) != 0) {
        (void)close(fd); fail("cannot unmap protected runtime file");
    }
    if (close(fd) != 0) fail("cannot close protected runtime file");
    for (size_t index = 0; index < CC_SHA256_DIGEST_LENGTH; ++index) {
        int high = hex_value((unsigned char)expected[index * 2U]);
        int low = hex_value((unsigned char)expected[index * 2U + 1U]);
        if (high < 0 || low < 0 || observed[index] != (unsigned char)((high << 4) | low)) {
            errno = 0; fail("protected runtime file content drifted");
        }
    }
    if (expected[CC_SHA256_DIGEST_LENGTH * 2U] != '\0') {
        errno = 0; fail("compiled runtime digest is malformed");
    }
}

static int string_member(const char *value, const char *const *values, size_t count) {
    for (size_t index = 0; index < count; ++index) {
        if (strcmp(value, values[index]) == 0) return 1;
    }
    return 0;
}

static int file_member(const char *value) {
    for (size_t index = 0; index < FILE_COUNT; ++index) {
        if (strcmp(value, FILES[index].path) == 0) return 1;
    }
    return 0;
}

static void verify_walk(const char *root, const char *relative) {
    char *start = join_path(root, relative);
    char *paths[] = { start, NULL };
    FTS *tree = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
    if (tree == NULL) { free(start); fail("cannot open protected runtime tree"); }
    size_t root_length = strlen(root);
    FTSENT *item;
    errno = 0;
    while ((item = fts_read(tree)) != NULL) {
        if (item->fts_info == FTS_DP) continue;
        if (strncmp(item->fts_path, root, root_length) != 0 ||
            item->fts_path[root_length] != '/') {
            (void)fts_close(tree); free(start); errno = 0; fail("runtime walk escaped root");
        }
        const char *member = item->fts_path + root_length + 1U;
        if (item->fts_info == FTS_D) {
            if (!string_member(member, DIRECTORIES, DIRECTORY_COUNT) ||
                item->fts_statp->st_uid != getuid() ||
                (item->fts_statp->st_mode & 07777) != 0555) {
                (void)fts_close(tree); free(start); errno = 0;
                fail("protected runtime directory drifted");
            }
        } else if (item->fts_info == FTS_F) {
            if (!file_member(member)) {
                (void)fts_close(tree); free(start); errno = 0;
                fail("protected runtime tree contains an undeclared file");
            }
        } else {
            (void)fts_close(tree); free(start); errno = 0;
            fail("protected runtime tree contains a link or special path");
        }
    }
    if (errno != 0) { (void)fts_close(tree); free(start); fail("protected runtime walk failed"); }
    if (fts_close(tree) != 0) { free(start); fail("cannot close protected runtime walk"); }
    free(start);
}

static int has_prefix(const char *entry, const char *prefix) {
    size_t prefix_length = strlen(prefix);
    return strncmp(entry, prefix, prefix_length) == 0;
}

static int injection_variable(const char *entry) {
    const char *equals = strchr(entry, '=');
    if (equals == NULL) return 0;
    size_t length = (size_t)(equals - entry);
    for (size_t index = 0; index < EXACT_COUNT; ++index) {
        if (length == strlen(EXACT_ENV[index]) && strncmp(entry, EXACT_ENV[index], length) == 0) return 1;
    }
    for (size_t index = 0; index < PREFIX_COUNT; ++index) {
        if (length >= strlen(PREFIX_ENV[index]) && has_prefix(entry, PREFIX_ENV[index])) return 1;
    }
    return 0;
}

static void scrub_environment(void) {
    for (;;) {
        const char *candidate = NULL;
        for (char **entry = environ; entry != NULL && *entry != NULL; ++entry) {
            if (injection_variable(*entry)) { candidate = *entry; break; }
        }
        if (candidate == NULL) return;
        const char *equals = strchr(candidate, '=');
        size_t length = (size_t)(equals - candidate);
        char *name = malloc(length + 1U);
        if (name == NULL) fail("cannot allocate environment name");
        (void)memcpy(name, candidate, length);
        name[length] = '\0';
        if (unsetenv(name) != 0) { free(name); fail("cannot scrub environment"); }
        free(name);
    }
}
'''


def _launcher_prelude(
    *,
    program: str,
    entries: Sequence[Mapping[str, str]],
    directories: Sequence[str],
    walk_roots: Sequence[str],
    exact_env: Sequence[str],
    prefix_env: Sequence[str],
) -> str:
    tables = (
        "static const struct file_entry FILES[] = {\n"
        + _c_entry_array(entries)
        + "\n};\n"
        + "#define FILE_COUNT (sizeof(FILES) / sizeof(FILES[0]))\n"
        + "static const char *const DIRECTORIES[] = {\n"
        + _c_array(directories)
        + "\n};\n"
        + f"#define DIRECTORY_COUNT {len(directories)}U\n"
        + "static const char *const WALK_ROOTS[] = {\n"
        + _c_array(walk_roots)
        + "\n};\n"
        + f"#define WALK_ROOT_COUNT {len(walk_roots)}U\n"
        + "static const char *const EXACT_ENV[] = {\n"
        + _c_array(exact_env)
        + "\n};\n"
        + f"#define EXACT_COUNT {len(exact_env)}U\n"
        + "static const char *const PREFIX_ENV[] = {\n"
        + _c_array(prefix_env)
        + "\n};\n"
        + f"#define PREFIX_COUNT {len(prefix_env)}U\n"
    )
    marker = "\nstatic void fail(const char *message) {"
    if marker not in C_SUPPORT:
        raise BuildError("internal native launcher template marker is missing")
    support = C_SUPPORT.replace(marker, "\n" + tables + marker, 1)
    return f"#define PROGRAM_NAME {_c_quote(program)}\n" + support


def generate_agent_launcher_source(
    entries: Sequence[Mapping[str, str]],
    directories: Sequence[str],
    walk_roots: Sequence[str],
    runtime_manifest_sha256: str,
) -> str:
    """Generate the relocation-safe Agent Fleet closure-verifying launcher."""
    prelude = _launcher_prelude(
        program="agent-fleet launcher",
        entries=entries,
        directories=directories,
        walk_roots=walk_roots,
        exact_env=(*GENERIC_ENV_EXACT, *AGENT_ENV_EXACT),
        prefix_env=(*GENERIC_ENV_PREFIXES, *AGENT_ENV_PREFIXES),
    )
    return prelude + f'''
static const char *const SELF_SUFFIX = "/bin/agent-fleet";
static const char *const MANIFEST_PATH = "build/runtime-closure.json";
static const char *const MANIFEST_SHA256 = "{runtime_manifest_sha256}";

int main(int argc, char **argv) {{
    char *self = physical_self();
    require_self_identity(self);
    size_t self_length = strlen(self), suffix_length = strlen(SELF_SUFFIX);
    if (self_length <= suffix_length || strcmp(self + self_length - suffix_length, SELF_SUFFIX) != 0) {{
        free(self); errno = 0; fail("physical launcher path is not canonical");
    }}
    self[self_length - suffix_length] = '\\0';
    char *manifest = join_path(self, MANIFEST_PATH);
    require_file(manifest, 0444, MANIFEST_SHA256);
    for (size_t index = 0; index < WALK_ROOT_COUNT; ++index) verify_walk(self, WALK_ROOTS[index]);
    for (size_t index = 0; index < FILE_COUNT; ++index) {{
        char *path = join_path(self, FILES[index].path);
        require_file(path, FILES[index].mode, FILES[index].sha256);
        free(path);
    }}
    char *python = join_path(self, "bin/python3.11");
    char *bootstrap = join_path(self, "launcher.py");
    scrub_environment();
    if ((size_t)argc > SIZE_MAX / sizeof(char *) - 6U) {{ errno = EOVERFLOW; fail("argument vector is too large"); }}
    char **forwarded = calloc((size_t)argc + 6U, sizeof(char *));
    if (forwarded == NULL) fail("cannot allocate argument vector");
    forwarded[0] = python;
    forwarded[1] = "-I";
    forwarded[2] = "-S";
    forwarded[3] = "-B";
    forwarded[4] = bootstrap;
    for (int index = 1; index < argc; ++index) forwarded[index + 4] = argv[index];
    forwarded[argc + 4] = NULL;
    (void)execv(python, forwarded);
    fail("cannot exec sealed Python runtime");
}}
'''


def generate_quota_launcher_source(
    entries: Sequence[Mapping[str, str]],
    directories: Sequence[str],
    walk_roots: Sequence[str],
    runtime_manifest_sha256: str,
) -> str:
    """Generate the relocation-safe Quota AXI closure-verifying front door."""
    prelude = _launcher_prelude(
        program="quota-axi launcher",
        entries=entries,
        directories=directories,
        walk_roots=walk_roots,
        exact_env=GENERIC_ENV_EXACT,
        prefix_env=GENERIC_ENV_PREFIXES,
    )
    return prelude + f'''
static const char *const SELF_SUFFIX = "/bin/quota-axi";
static const char *const MANIFEST_PATH = "build/runtime-closure.json";
static const char *const MANIFEST_SHA256 = "{runtime_manifest_sha256}";

int main(int argc, char **argv) {{
    char *self = physical_self();
    require_self_identity(self);
    size_t self_length = strlen(self), suffix_length = strlen(SELF_SUFFIX);
    if (self_length <= suffix_length || strcmp(self + self_length - suffix_length, SELF_SUFFIX) != 0) {{
        free(self); errno = 0; fail("physical launcher path is not canonical");
    }}
    self[self_length - suffix_length] = '\\0';
    char *manifest = join_path(self, MANIFEST_PATH);
    require_file(manifest, 0444, MANIFEST_SHA256);
    for (size_t index = 0; index < WALK_ROOT_COUNT; ++index) verify_walk(self, WALK_ROOTS[index]);
    for (size_t index = 0; index < FILE_COUNT; ++index) {{
        char *path = join_path(self, FILES[index].path);
        require_file(path, FILES[index].mode, FILES[index].sha256);
        free(path);
    }}
    char *node = join_path(self, "runtime/node");
    char *entrypoint = join_path(self, "node_modules/quota-axi/dist/bin/quota-axi.js");
    scrub_environment();
    if (setenv("PATH", "/usr/bin:/bin", 1) != 0) fail("cannot set safe PATH");
    if ((size_t)argc > SIZE_MAX / sizeof(char *) - 3U) {{ errno = EOVERFLOW; fail("argument vector is too large"); }}
    char **forwarded = calloc((size_t)argc + 3U, sizeof(char *));
    if (forwarded == NULL) fail("cannot allocate argument vector");
    forwarded[0] = node;
    forwarded[1] = entrypoint;
    for (int index = 1; index < argc; ++index) forwarded[index + 1] = argv[index];
    forwarded[argc + 1] = NULL;
    (void)execv(node, forwarded);
    fail("cannot exec sealed Node runtime");
}}
'''


def generate_agent_front_door_source(target: Path, target_sha256: str) -> str:
    """Generate a native regular installer payload bound to one physical launcher."""
    empty_entries = [{"path": "unused", "mode": "0444", "sha256": "0" * 64}]
    prelude = _launcher_prelude(
        program="agent-fleet front door",
        entries=empty_entries,
        directories=(),
        walk_roots=(),
        exact_env=(*GENERIC_ENV_EXACT, *AGENT_ENV_EXACT),
        prefix_env=(*GENERIC_ENV_PREFIXES, *AGENT_ENV_PREFIXES),
    )
    return prelude + f'''
static const char *const TARGET = {_c_quote(str(target))};
static const char *const TARGET_SHA256 = "{target_sha256}";

int main(int argc, char **argv) {{
    char *self = physical_self();
    require_self_identity(self);
    free(self);
    require_file(TARGET, 0555, TARGET_SHA256);
    scrub_environment();
    if ((size_t)argc > SIZE_MAX / sizeof(char *) - 1U) {{ errno = EOVERFLOW; fail("argument vector is too large"); }}
    char **forwarded = calloc((size_t)argc + 1U, sizeof(char *));
    if (forwarded == NULL) fail("cannot allocate argument vector");
    forwarded[0] = (char *)TARGET;
    for (int index = 1; index < argc; ++index) forwarded[index] = argv[index];
    forwarded[argc] = NULL;
    (void)execv(TARGET, forwarded);
    fail("cannot exec bound Agent Fleet launcher");
}}
'''


def _compile_signed(manifest: BuildManifest, source: Path, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    build_home = source.parent / ".compiler-home"
    build_temp = source.parent / ".compiler-tmp"
    build_home.mkdir(mode=0o700)
    build_temp.mkdir(mode=0o700)
    env = {
        "CFFIXED_USER_HOME": str(build_home),
        "HOME": str(build_home),
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin",
        "SOURCE_DATE_EPOCH": "1580601600",
        "TMPDIR": str(build_temp),
        "ZERO_AR_DATE": "1",
    }
    try:
        _run_pinned(
            manifest.tools["clang"],
            [*CLANG_FLAGS, "-o", str(output), str(source)],
            env=env,
            timeout=120,
        )
        _run_pinned(
            manifest.tools["codesign"],
            [*CODESIGN_FLAGS, str(output)],
            env=env,
            timeout=30,
        )
        _signature_details(manifest, output)
    finally:
        _remove_tree(build_home)
        _remove_tree(build_temp)
    os.chmod(output, 0o700)


def _signature_details(manifest: BuildManifest, path: Path) -> str:
    verified = _run_pinned(
        manifest.tools["codesign"],
        ["--verify", "--strict", "--verbose=4", str(path)],
        check=False,
    )
    described = _run_pinned(
        manifest.tools["codesign"],
        ["-d", "--verbose=4", str(path)],
        check=False,
    )
    description = described.stdout + described.stderr
    if verified.returncode != 0 or described.returncode != 0 or "runtime" not in description:
        raise BuildError(f"native launcher is not strict hardened-runtime signed: {path}")
    return hashlib.sha256(description.encode("utf-8")).hexdigest()


def _native_dependencies(manifest: BuildManifest, path: Path) -> list[str]:
    lines = _run_pinned(
        manifest.tools["otool"], ["-L", str(path)]
    ).stdout.splitlines()
    dependencies = [line.strip() for line in lines[1:] if line.strip()]
    if not dependencies:
        raise BuildError(f"native binary has no inspectable dependencies: {path}")
    return dependencies


def _binary_format(manifest: BuildManifest, path: Path) -> str:
    value = _run_pinned(manifest.tools["file"], ["-b", str(path)]).stdout.strip()
    if not value.startswith("Mach-O"):
        raise BuildError(f"native launcher is not Mach-O: {path}: {value}")
    return value


def _signature_state(manifest: BuildManifest, path: Path) -> str:
    result = _run_pinned(
        manifest.tools["codesign"],
        ["--verify", "--strict", str(path)],
        check=False,
    )
    return "strict-valid" if result.returncode == 0 else "unverified-contained-runtime"


def _set_preclosure_modes(root: Path, executables: set[str]) -> None:
    for directory, names, files in os.walk(root, topdown=True, followlinks=False):
        base = Path(directory)
        for name in names:
            path = base / name
            if path.is_symlink():
                raise BuildError(f"runtime source contains a symlink: {path}")
        for name in files:
            path = base / name
            if path.is_symlink():
                raise BuildError(f"runtime source contains a symlink: {path}")
            relative = path.relative_to(root).as_posix()
            os.chmod(path, 0o555 if relative in executables else 0o444)


def _artifact(path: Path, root: Path) -> dict[str, str]:
    return {"path": path.relative_to(root).as_posix(), "sha256": _sha256(path)}


def _build_agent_release(
    manifest: BuildManifest,
    role: AgentRole,
    root: Path,
    wheel_members: Mapping[str, bytes],
    publication_id: str,
) -> None:
    root.mkdir(parents=True)
    (root / "bin").mkdir()
    _copy_regular(manifest.python_runtime.root / "bin/python3.11", root / "bin/python3.11")
    _copy_tree(manifest.python_runtime.root / "lib", root / "lib")
    _extract_members(wheel_members, root / "site-packages")
    build = root / "build"
    build.mkdir()
    _copy_regular(role.wheel, build / "source.whl")
    bootstrap_source = Path(__file__).with_name("sealed_agent_fleet_bootstrap.py")
    _require_regular(bootstrap_source, "Agent Fleet bootstrap source")
    _copy_regular(bootstrap_source, root / "launcher.py")

    executables = {"bin/python3.11"}
    _set_preclosure_modes(root, executables)
    protected = (
        "bin/python3.11",
        "launcher.py",
        "lib",
        "site-packages",
        "build/source.whl",
    )
    entries = _runtime_entries(root, protected)
    closure = {
        "schema_version": 1,
        "format": "bridge-runtime-closure-v1",
        "entries": entries,
    }
    closure_path = build / "runtime-closure.json"
    _write_json(closure_path, closure, 0o444)
    walk_roots = ("lib", "site-packages")
    directories = _directory_inventory(root, walk_roots)
    launcher_source = build / "agent-fleet-launcher.c"
    _write_bytes(
        launcher_source,
        generate_agent_launcher_source(
            entries, directories, walk_roots, _sha256(closure_path)
        ).encode("utf-8"),
    )
    launcher = root / "bin/agent-fleet"
    _compile_signed(manifest, launcher_source, launcher)

    final_launcher = manifest.output_root / role.release_path / "bin/agent-fleet"
    front_source = build / "agent-fleet-front-door.c"
    _write_bytes(
        front_source,
        generate_agent_front_door_source(final_launcher, _sha256(launcher)).encode("utf-8"),
    )
    front = root / "operator/agent-fleet"
    _compile_signed(manifest, front_source, front)

    provenance = {
        "schema_version": 2,
        "role": "agent_fleet",
        "version": role.version,
        "source_commit": role.source_commit,
        "source_tree_sha256": role.source_tree_sha256,
        "artifacts": {
            "launcher": _artifact(launcher, root),
            "python": _artifact(root / "bin/python3.11", root),
            "bootstrap": _artifact(root / "launcher.py", root),
            "wheel": _artifact(build / "source.whl", root),
        },
    }
    _write_json(build / "provenance.json", provenance)
    _write_json(
        build / "bridge-publication.json",
        {"schema_version": 1, "publication_id": publication_id},
        0o444,
    )
    executables.update({"bin/agent-fleet", "operator/agent-fleet"})
    _normalize_modes(root, executables, manifest.tools["xattr"])
    _assert_closed_tree(root, manifest.tools["xattr"])


def _build_quota_release(
    manifest: BuildManifest,
    role: QuotaRole,
    root: Path,
    package_members: Mapping[str, bytes],
    dependency_members: Mapping[str, Mapping[str, bytes]],
    lock_bytes: bytes,
    publication_id: str,
) -> None:
    root.mkdir(parents=True)
    _copy_regular(manifest.node_runtime.binary, root / "runtime/node")
    _extract_members(package_members, root / "node_modules/quota-axi")
    for install_path, members in dependency_members.items():
        _extract_members(members, root / install_path)
    _write_bytes(root / "package-lock.json", lock_bytes)
    build = root / "build"
    build.mkdir()
    executables = {"runtime/node"}
    _set_preclosure_modes(root, executables)
    protected = ("runtime", "node_modules", "package-lock.json")
    entries = _runtime_entries(root, protected)
    closure = {
        "schema_version": 1,
        "format": "bridge-runtime-closure-v1",
        "entries": entries,
    }
    closure_path = build / "runtime-closure.json"
    _write_json(closure_path, closure, 0o444)
    walk_roots = ("runtime", "node_modules")
    directories = _directory_inventory(root, walk_roots)
    launcher_source = build / "quota-axi-launcher.c"
    _write_bytes(
        launcher_source,
        generate_quota_launcher_source(
            entries, directories, walk_roots, _sha256(closure_path)
        ).encode("utf-8"),
    )
    launcher = root / "bin/quota-axi"
    _compile_signed(manifest, launcher_source, launcher)
    provenance = {
        "schema_version": 2,
        "role": "quota_axi",
        "version": role.version,
        "source_commit": role.source_commit,
        "source_tree_sha256": role.source_tree_sha256,
        "artifacts": {
            "launcher": _artifact(launcher, root),
            "node": _artifact(root / "runtime/node", root),
            "entrypoint": _artifact(
                root / "node_modules/quota-axi/dist/bin/quota-axi.js", root
            ),
            "package_lock": _artifact(root / "package-lock.json", root),
            "runtime_manifest": _artifact(closure_path, root),
        },
    }
    _write_json(build / "provenance.json", provenance)
    _write_json(
        build / "bridge-publication.json",
        {"schema_version": 1, "publication_id": publication_id},
        0o444,
    )
    executables.add("bin/quota-axi")
    _normalize_modes(root, executables, manifest.tools["xattr"])
    _assert_closed_tree(root, manifest.tools["xattr"])


def _build_once(
    manifest: BuildManifest,
    base: Path,
    agent_inputs: Mapping[str, Mapping[str, bytes]],
    quota_inputs: Mapping[
        str, tuple[Mapping[str, bytes], Mapping[str, Mapping[str, bytes]], bytes]
    ],
    driver: ModuleType,
    publication_id: str,
) -> dict[str, Any]:
    roots: dict[str, Path] = {}
    trees: dict[str, str] = {}
    for role_name in ("candidate", "rollback"):
        key = f"agent_fleet_{role_name}"
        role = manifest.agent_roles[role_name]
        root = base / role.release_path
        _build_agent_release(
            manifest, role, root, agent_inputs[role_name], publication_id
        )
        roots[key] = root
        trees[key] = _tree_sha256(driver, root, key)
    for role_name in ("candidate", "rollback"):
        key = f"quota_axi_{role_name}"
        role = manifest.quota_roles[role_name]
        root = base / role.release_path
        package, dependencies, lock = quota_inputs[role_name]
        _build_quota_release(
            manifest,
            role,
            root,
            package,
            dependencies,
            lock,
            publication_id,
        )
        roots[key] = root
        trees[key] = _tree_sha256(driver, root, key)
    return {"roots": roots, "trees": trees}


def _hostile_environment(manifest: BuildManifest, temporary: Path) -> tuple[dict[str, str], Path]:
    home = temporary / "home"
    hostile = temporary / "hostile"
    home.mkdir(mode=0o700)
    hostile.mkdir(mode=0o700)
    sentinel = hostile / "executed-sentinel"
    shell = hostile / "shell-env"
    shell.write_text(f"touch {_c_quote(str(sentinel))}\nexit 97\n", encoding="utf-8")
    preload = hostile / "preload.cjs"
    preload.write_text(
        f"require('fs').writeFileSync({json.dumps(str(sentinel))}, 'node');\n",
        encoding="utf-8",
    )
    python = hostile / "sitecustomize.py"
    python.write_text(
        f"from pathlib import Path\nPath({str(sentinel)!r}).write_text('python')\n",
        encoding="utf-8",
    )
    dylib_source = hostile / "injected.c"
    dylib = hostile / "injected.dylib"
    dylib_source.write_text(
        "#include <fcntl.h>\n#include <stdlib.h>\n#include <unistd.h>\n"
        "__attribute__((constructor)) static void injected(void) {"
        "const char *p=getenv(\"BRIDGE_DYLD_SENTINEL\");"
        "if(p){int f=open(p,O_WRONLY|O_CREAT|O_TRUNC,0600);"
        "if(f>=0){(void)write(f,\"dyld\",4);(void)close(f);}}}\n",
        encoding="utf-8",
    )
    _run_pinned(
        manifest.tools["clang"],
        [
            "-std=c11",
            "-Os",
            "-dynamiclib",
            "-o",
            str(dylib),
            str(dylib_source),
        ],
        env={
            "HOME": str(home),
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin",
            "TMPDIR": str(hostile),
        },
    )
    env = {
        "AGENT_FLEET_BIN": str(hostile / "fake-agent-fleet"),
        "AGENT_FLEET_CLAUDE_BIN": str(hostile / "fake-claude"),
        "AGENT_FLEET_CODEX_BIN": str(hostile / "fake-codex"),
        "AGENT_FLEET_CONFIG": str(hostile / "registry.toml"),
        "AGENT_FLEET_FORMAT": "hostile-format",
        "AGENT_FLEET_QUOTA_BIN": str(hostile / "fake-quota"),
        "AGENT_FLEET_QUOTA_FIXTURE_DIR": str(hostile),
        "AGENT_FLEET_QUOTA_FIXTURE_RESULT": "hostile",
        "AGENT_FLEET_SHARE_DIR": str(hostile),
        "AGENT_FLEET_STATE_DIR": str(hostile),
        "AGENT_FLEET_TEST_QUOTA_FIXTURE_DIR": str(hostile),
        "AGENT_FLEET_TEST_QUOTA_FIXTURE_RESULT": "hostile",
        "BASH_ENV": str(shell),
        "BRIDGE_DYLD_SENTINEL": str(sentinel),
        "DYLD_FORCE_FLAT_NAMESPACE": "1",
        "DYLD_INSERT_LIBRARIES": str(dylib),
        "ELECTRON_RUN_AS_NODE": "1",
        "ENV": str(shell),
        "GCONV_PATH": str(hostile),
        "HOME": str(home),
        "LANG": "C",
        "LC_ALL": "C",
        "LOCPATH": str(hostile),
        "MALLOC_CHECK_": "3",
        "NLSPATH": str(hostile),
        "NODE_OPTIONS": f"--require={preload}",
        "NODE_PATH": str(hostile),
        "PATH": str(hostile),
        "PERL5OPT": "-Mstrict",
        "PYTHONHOME": str(hostile),
        "PYTHONPATH": str(hostile),
        "RUBYOPT": "-r./hostile",
        "SSLKEYLOGFILE": str(sentinel),
    }
    return env, sentinel


def _probe_invocation_shapes(
    executable: Path,
    env: Mapping[str, str],
    arguments: Sequence[str],
) -> None:
    temporary = Path(os.path.realpath(tempfile.mkdtemp(prefix="bridge-launcher-alias-")))
    try:
        alias = temporary / executable.name
        os.symlink(executable, alias)
        aliased = _run([str(alias), *arguments], env=env, check=False, timeout=30)
        if aliased.returncode == 0:
            raise BuildError(f"native launcher accepted a symlink alias: {executable}")
        try:
            spoofed = subprocess.run(
                ["spoofed-argv-zero", *arguments],
                executable=str(executable),
                env=dict(env),
                check=False,
                capture_output=True,
                text=True,
                timeout=30,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise BuildError(f"cannot run hostile argv[0] probe: {exc}") from exc
        if spoofed.returncode != 0:
            detail = spoofed.stderr.strip() or spoofed.stdout.strip()
            raise BuildError(
                f"native launcher trusted hostile argv[0] instead of physical self: "
                f"{executable}: {detail}"
            )
        path_env = dict(env)
        path_env["PATH"] = f"{executable.parent}:/usr/bin:/bin"
        by_path = _run(
            [executable.name, *arguments], env=path_env, check=False, timeout=30
        )
        if by_path.returncode != 0:
            detail = by_path.stderr.strip() or by_path.stdout.strip()
            raise BuildError(
                f"native launcher failed ordinary PATH invocation: {executable}: {detail}"
            )
    finally:
        _remove_tree(temporary)


def _probe_agent(root: Path, role: AgentRole, driver: ModuleType) -> dict[str, Any]:
    before = _tree_sha256(driver, root, f"Agent Fleet {role.role} pre-probe")
    temporary = Path(os.path.realpath(tempfile.mkdtemp(prefix="bridge-agent-probe-")))
    try:
        env, sentinel = _hostile_environment(_ACTIVE_MANIFEST, temporary)
        executable = root / "bin/agent-fleet"
        completed = _run(
            [str(executable), "--format", "json", "version"],
            env=env,
            timeout=120,
        )
        try:
            payload = json.loads(completed.stdout)
        except json.JSONDecodeError as exc:
            raise BuildError("Agent Fleet version probe did not return JSON") from exc
        expected = {
            "cli_version": role.version,
            "contract_version": role.contract_version,
        }
        if payload != expected:
            raise BuildError(
                f"Agent Fleet {role.role} version contract is {payload!r}; expected {expected!r}"
            )
        help_result = _run([str(executable), "--help"], env=env, timeout=120)
        if "usage:" not in help_result.stdout.lower():
            raise BuildError(f"Agent Fleet {role.role} help probe did not reach its parser")
        if sentinel.exists():
            raise BuildError(f"Agent Fleet {role.role} executed hostile environment injection")
        _probe_invocation_shapes(
            executable, env, ("--format", "json", "version")
        )
        after = _tree_sha256(driver, root, f"Agent Fleet {role.role} post-probe")
        if before != after:
            raise BuildError(f"Agent Fleet {role.role} probe mutated its release")
        return {
            "version": role.version,
            "contract": role.contract_version,
            "hostile_environment": True,
            "relocated": True,
            "installed_topology": True,
        }
    finally:
        _remove_tree(temporary)


def _probe_quota(root: Path, role: QuotaRole, driver: ModuleType) -> dict[str, Any]:
    before = _tree_sha256(driver, root, f"Quota AXI {role.role} pre-probe")
    temporary = Path(os.path.realpath(tempfile.mkdtemp(prefix="bridge-quota-probe-")))
    try:
        env, sentinel = _hostile_environment(_ACTIVE_MANIFEST, temporary)
        executable = root / "bin/quota-axi"
        version = _run([str(executable), "--version"], env=env, timeout=120).stdout.strip()
        if role.version not in version:
            raise BuildError(f"Quota AXI {role.role} version probe returned {version!r}")
        help_result = _run([str(executable), "--help"], env=env, timeout=120)
        if "usage:" not in help_result.stdout.lower():
            raise BuildError(f"Quota AXI {role.role} help probe did not reach its parser")
        if sentinel.exists():
            raise BuildError(f"Quota AXI {role.role} executed hostile environment injection")
        _probe_invocation_shapes(executable, env, ("--version",))
        after = _tree_sha256(driver, root, f"Quota AXI {role.role} post-probe")
        if before != after:
            raise BuildError(f"Quota AXI {role.role} probe mutated its release")
        return {
            "version": version,
            "help": True,
            "hostile_environment": True,
            "relocated": True,
            "canonical_path": True,
        }
    finally:
        _remove_tree(temporary)


_ACTIVE_MANIFEST: BuildManifest


def _copy_sealed(manifest: BuildManifest, source: Path, destination: Path) -> None:
    executables = {
        path.relative_to(source).as_posix()
        for path in source.rglob("*")
        if path.is_file() and stat.S_IMODE(os.lstat(path).st_mode) == 0o555
    }
    _copy_tree(source, destination)
    _normalize_modes(destination, executables, manifest.tools["xattr"])
    _assert_closed_tree(destination, manifest.tools["xattr"])
    _fsync_sealed_tree(destination)


def _relocation_and_tamper_probe(
    manifest: BuildManifest,
    source: Path,
    driver: ModuleType,
    role: AgentRole | QuotaRole,
    kind: str,
) -> str:
    temporary = Path(os.path.realpath(tempfile.mkdtemp(prefix="bridge-runtime-relocation-")))
    try:
        relocated = temporary / "relocated" / source.name
        relocated.parent.mkdir()
        _copy_sealed(manifest, source, relocated)
        digest = _tree_sha256(driver, relocated, f"{kind} {role.role} relocated")
        if kind == "agent_fleet":
            _probe_agent(relocated, role, driver)  # type: ignore[arg-type]
            target = relocated / "site-packages/agent_fleet/__init__.py"
        else:
            _probe_quota(relocated, role, driver)  # type: ignore[arg-type]
            target = relocated / "node_modules/quota-axi/dist/bin/quota-axi.js"
        os.chmod(target, 0o644)
        with target.open("ab") as handle:
            handle.write(b"\n")
        os.chmod(target, 0o444)
        executable = relocated / "bin" / ("agent-fleet" if kind == "agent_fleet" else "quota-axi")
        env = {"HOME": str(temporary), "PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"}
        command = (
            [str(executable), "--format", "json", "version"]
            if kind == "agent_fleet"
            else [str(executable), "--version"]
        )
        tampered = _run(command, env=env, check=False, timeout=120)
        if tampered.returncode == 0:
            raise BuildError(f"{kind} {role.role} launcher accepted closure tampering")
        return digest
    finally:
        _remove_tree(temporary)


def _rename_no_replace(source: Path, destination: Path) -> None:
    """Atomically rename a directory while refusing a racing destination."""
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
        raise BuildError("this platform has no supported atomic no-replace rename primitive")
    if result != 0:
        error = ctypes.get_errno()
        if error in {errno_module.EEXIST, errno_module.ENOTEMPTY}:
            raise BuildError(
                f"final release appeared during atomic publication; refusing overwrite: {destination}"
            )
        raise BuildError(
            f"atomic no-replace publication failed: {source} -> {destination}: "
            f"{os.strerror(error)}"
        )


def _write_json_no_replace(path: Path, value: Any, mode: int) -> None:
    if path.exists() or path.is_symlink():
        raise BuildError(f"refusing to overwrite build artifact: {path}")
    staging = Path(
        os.path.realpath(
            tempfile.mkdtemp(prefix=f".{path.name}.bridge-write-", dir=path.parent)
        )
    )
    os.chmod(staging, 0o700)
    temporary = staging / "payload"
    try:
        _write_json(temporary, value, mode)
        _rename_no_replace(temporary, path)
        _fsync_directory(path.parent)
    finally:
        _remove_tree(staging)


def _publish_release(manifest: BuildManifest, source: Path, final: Path) -> tuple[int, int]:
    if final.exists() or final.is_symlink():
        raise BuildError(f"final release appeared during build; refusing overwrite: {final}")
    staging = Path(
        os.path.realpath(
            tempfile.mkdtemp(prefix=f".{final.name}.bridge-sealed-", dir=final.parent)
        )
    )
    os.chmod(staging, 0o700)
    candidate = staging / "release"
    try:
        _copy_sealed(manifest, source, candidate)
        os.chmod(candidate, 0o700)
        _rename_no_replace(candidate, final)
        os.chmod(final, 0o555)
        _fsync_directory(final)
        _fsync_directory(final.parent)
        info = os.lstat(final)
        return info.st_dev, info.st_ino
    finally:
        _remove_tree(staging)


def _remove_tree_if_identity(path: Path, identity: tuple[int, int]) -> None:
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return
    if (info.st_dev, info.st_ino) != identity or not stat.S_ISDIR(info.st_mode):
        raise BuildError(f"refusing cleanup after published release identity changed: {path}")
    _remove_tree(path)
    _fsync_directory(path.parent)


def _unlink_file_if_identity(path: Path, identity: tuple[int, int, str]) -> None:
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_nlink != 1
        or (info.st_dev, info.st_ino, _sha256(path)) != identity
    ):
        raise BuildError(f"refusing cleanup after published file identity changed: {path}")
    os.chmod(path, 0o600)
    path.unlink()
    _fsync_directory(path.parent)


def _publication_journal_path(manifest: BuildManifest) -> Path:
    return manifest.proof_manifest.with_name(
        manifest.proof_manifest.stem + "-build-journal.json"
    )


def _front_door_plan_path(manifest: BuildManifest) -> Path:
    return manifest.proof_manifest.with_name(
        manifest.proof_manifest.stem + "-front-door.json"
    )


def _publication_records(
    manifest: BuildManifest, trees: Mapping[str, str]
) -> list[dict[str, str]]:
    records: list[dict[str, str]] = []
    for key in (
        "agent_fleet_candidate",
        "agent_fleet_rollback",
        "quota_axi_candidate",
        "quota_axi_rollback",
    ):
        family, role_name = key.rsplit("_", 1)
        role = (
            manifest.agent_roles[role_name]
            if family == "agent_fleet"
            else manifest.quota_roles[role_name]
        )
        records.append(
            {
                "key": key,
                "path": str(manifest.output_root / role.release_path),
                "relative_path": role.release_path,
                "tree_sha256": trees[key],
            }
        )
    return records


def _publication_marker(root: Path, publication_id: str) -> None:
    marker = root / "build/bridge-publication.json"
    value = _exact_object(
        _read_strict_json(marker, "release publication marker"),
        {"schema_version", "publication_id"},
        "release publication marker",
    )
    if value != {"schema_version": 1, "publication_id": publication_id}:
        raise BuildError(f"release publication marker does not match its journal: {root}")
    if stat.S_IMODE(os.lstat(marker).st_mode) != 0o444:
        raise BuildError(f"release publication marker mode drifted: {marker}")


def _validate_publication_journal(
    manifest: BuildManifest, raw: Mapping[str, Any]
) -> tuple[str, tuple[Mapping[str, str], ...]]:
    journal = _exact_object(
        raw,
        {
            "schema_version",
            "manifest_sha256",
            "publication_id",
            "live_references_changed",
            "releases",
        },
        "publication journal",
    )
    if journal["schema_version"] != 1 or journal["live_references_changed"] is not False:
        raise BuildError("publication journal is not a fail-closed schema-v1 build journal")
    if journal["manifest_sha256"] != manifest.manifest_sha256:
        raise BuildError("publication journal belongs to a different builder manifest")
    publication_id = journal["publication_id"]
    if not isinstance(publication_id, str) or not SHA256.fullmatch(publication_id):
        raise BuildError("publication journal has an invalid publication_id")
    releases = journal["releases"]
    if not isinstance(releases, list) or len(releases) != 4:
        raise BuildError("publication journal must bind exactly four releases")
    expected_paths = {
        str(manifest.output_root / role.release_path): role.release_path
        for role in (*manifest.agent_roles.values(), *manifest.quota_roles.values())
    }
    observed_paths: set[str] = set()
    records: list[Mapping[str, str]] = []
    for index, value in enumerate(releases):
        record = _exact_object(
            value,
            {"key", "path", "relative_path", "tree_sha256"},
            f"publication journal release[{index}]",
        )
        if (
            not isinstance(record["key"], str)
            or record["path"] not in expected_paths
            or record["relative_path"] != expected_paths.get(record["path"])
            or not isinstance(record["tree_sha256"], str)
            or not SHA256.fullmatch(record["tree_sha256"])
            or record["path"] in observed_paths
        ):
            raise BuildError("publication journal release binding is invalid")
        observed_paths.add(record["path"])
        records.append(record)
    if observed_paths != set(expected_paths):
        raise BuildError("publication journal does not bind the exact four release paths")
    return publication_id, tuple(records)


def _proof_matches_publication(
    manifest: BuildManifest,
    driver: ModuleType,
    records: Sequence[Mapping[str, str]],
) -> bool:
    if not manifest.proof_manifest.exists():
        return False
    proof = _read_strict_json(manifest.proof_manifest, "published proof manifest")
    if proof.get("schema_version") != 2:
        raise BuildError("published proof manifest does not use schema version 2")
    if stat.S_IMODE(os.lstat(manifest.proof_manifest).st_mode) != 0o444:
        raise BuildError("published proof manifest mode drifted")
    for record in records:
        role = proof.get(record["key"])
        if (
            not isinstance(role, dict)
            or role.get("release_path") != record["relative_path"]
            or role.get("tree_sha256") != record["tree_sha256"]
        ):
            raise BuildError("published proof manifest does not match its build journal")
        root = Path(record["path"])
        if _tree_sha256(driver, root, f"completed {record['key']}") != record["tree_sha256"]:
            raise BuildError("completed release tree does not match its proof")
    return True


def _recover_interrupted_publication(
    manifest: BuildManifest, driver: ModuleType
) -> bool:
    journal_path = _publication_journal_path(manifest)
    if not journal_path.exists():
        return False
    _require_regular(journal_path, "publication journal")
    if stat.S_IMODE(os.lstat(journal_path).st_mode) != 0o600:
        raise BuildError("publication journal mode must be 0600")
    journal_info = os.lstat(journal_path)
    journal_identity = (
        journal_info.st_dev,
        journal_info.st_ino,
        _sha256(journal_path),
    )
    publication_id, records = _validate_publication_journal(
        manifest, _read_strict_json(journal_path, "publication journal")
    )
    plan_path = _front_door_plan_path(manifest)
    completed = _proof_matches_publication(manifest, driver, records)
    if completed:
        expected_plan = _front_door_plan(
            manifest,
            manifest.output_root / manifest.agent_roles["candidate"].release_path,
            manifest.output_root / manifest.agent_roles["rollback"].release_path,
        )
        if _read_strict_json(plan_path, "front-door plan") != expected_plan:
            raise BuildError("completed front-door plan does not match its releases")
        _unlink_file_if_identity(journal_path, journal_identity)
        return True
    if plan_path.exists():
        expected_plan = _front_door_plan(
            manifest,
            manifest.output_root / manifest.agent_roles["candidate"].release_path,
            manifest.output_root / manifest.agent_roles["rollback"].release_path,
        )
        if _read_strict_json(plan_path, "interrupted front-door plan") != expected_plan:
            raise BuildError("interrupted front-door plan cannot be safely attributed")
        plan_info = os.lstat(plan_path)
        _unlink_file_if_identity(
            plan_path,
            (plan_info.st_dev, plan_info.st_ino, _sha256(plan_path)),
        )
    for record in records:
        root = Path(record["path"])
        if not root.exists() and not root.is_symlink():
            continue
        info = os.lstat(root)
        if (
            not stat.S_ISDIR(info.st_mode)
            or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) not in {0o555, 0o700}
        ):
            raise BuildError(f"interrupted release cannot be safely attributed: {root}")
        _publication_marker(root, publication_id)
        original_mode = stat.S_IMODE(info.st_mode)
        if original_mode == 0o700:
            os.chmod(root, 0o555)
        observed = _tree_sha256(driver, root, f"interrupted {record['key']}")
        if observed != record["tree_sha256"]:
            if original_mode == 0o700:
                os.chmod(root, 0o700)
            raise BuildError(f"interrupted release tree drifted; refusing cleanup: {root}")
        _remove_tree(root)
        _fsync_directory(root.parent)
    _unlink_file_if_identity(journal_path, journal_identity)
    return False


def _proof(driver: ModuleType, root: Path, relative: str) -> dict[str, Any]:
    try:
        value = driver.compute_release_proof(root, relative, "sealed runtime proof")
    except Exception as exc:
        raise BuildError(f"cannot compute proof for {root / relative}: {exc}") from exc
    return {
        "path": value["relative_path"],
        "sha256": value["sha256"],
        "mode": value["mode"],
        "nlink": 1,
    }


def _agent_proof_paths(root: Path, role: AgentRole) -> list[str]:
    dist = f"site-packages/agent_fleet-{role.version}.dist-info"
    paths = {
        "bin/agent-fleet",
        "bin/python3.11",
        "launcher.py",
        "operator/agent-fleet",
        "build/agent-fleet-front-door.c",
        "build/agent-fleet-launcher.c",
        "build/provenance.json",
        "build/runtime-closure.json",
        "build/source.whl",
        f"{dist}/METADATA",
        f"{dist}/RECORD",
        "site-packages/agent_fleet/__init__.py",
        "site-packages/agent_fleet/__main__.py",
        "site-packages/agent_fleet/config.py",
        "site-packages/agent_fleet/models.py",
    }
    if role.role == "candidate":
        paths.update(
            f"site-packages/agent_fleet/{name}"
            for name in ("enrollment.py", "identity.py", "provision.py", "recovery.py")
        )
    return sorted(paths, key=lambda item: item.encode("utf-8"))


def _quota_proof_paths() -> list[str]:
    return sorted(
        {
            "bin/quota-axi",
            "runtime/node",
            "node_modules/quota-axi/dist/bin/quota-axi.js",
            "node_modules/quota-axi/package.json",
            "package-lock.json",
            "build/quota-axi-launcher.c",
            "build/provenance.json",
            "build/runtime-closure.json",
        },
        key=lambda item: item.encode("utf-8"),
    )


def _file_record(path: Path, root: Path) -> dict[str, Any]:
    info = os.lstat(path)
    return {
        "path": path.relative_to(root).as_posix(),
        "sha256": _sha256(path),
        "mode": f"{stat.S_IMODE(info.st_mode):04o}",
        "nlink": info.st_nlink,
    }


def _signature_record(manifest: BuildManifest, path: Path) -> dict[str, Any]:
    return {
        "valid": True,
        "hardened_runtime": True,
        "verify_strict": True,
        "details_sha256": _signature_details(manifest, path),
    }


def _agent_record(
    manifest: BuildManifest,
    driver: ModuleType,
    role: AgentRole,
    root: Path,
    tree: str,
    probes: Mapping[str, Any],
) -> dict[str, Any]:
    launcher_path = root / "bin/agent-fleet"
    launcher = _file_record(launcher_path, root)
    launcher.update(
        {
            "binary_format": _binary_format(manifest, launcher_path),
            "source_path": "build/agent-fleet-launcher.c",
            "source_sha256": _sha256(root / "build/agent-fleet-launcher.c"),
            "dependencies": _native_dependencies(manifest, launcher_path),
            "signature": _signature_record(manifest, launcher_path),
            "canonical_physical_only": True,
            "env_scrub": {
                "exact": [*GENERIC_ENV_EXACT, *AGENT_ENV_EXACT],
                "prefixes": [*GENERIC_ENV_PREFIXES, *AGENT_ENV_PREFIXES],
            },
        }
    )
    proof_paths = _agent_proof_paths(root, role)
    front = root / "operator/agent-fleet"
    return {
        "role": role.role,
        "release_path": root.relative_to(manifest.output_root).as_posix(),
        "version": role.version,
        "contract_version": role.contract_version,
        "source_commit": role.source_commit,
        "tree_sha256": tree,
        "rebuild_tree_sha256": tree,
        "relocated_tree_sha256": tree,
        "proofs": [_proof(driver, root, relative) for relative in proof_paths],
        "launcher": launcher,
        "python": {
            "path": "bin/python3.11",
            "sha256": _sha256(root / "bin/python3.11"),
            "version": manifest.python_runtime.version,
        },
        "wheel": {
            "path": "build/source.whl",
            "sha256": _sha256(root / "build/source.whl"),
        },
        "provenance": {
            "path": "build/provenance.json",
            "sha256": _sha256(root / "build/provenance.json"),
        },
        "invocation": {
            "managed_relative_path": "bin/agent-fleet",
            "config_relative_path": "bin/agent-fleet",
            "hooks_relative_path": "bin/agent-fleet",
            "operator_front_door": {
                "kind": "native_regular_file",
                "install_scope": "user_local_bin",
                "installed_name": "agent-fleet",
                "source_path": "operator/agent-fleet",
                "source_sha256": _sha256(front),
                "target_binding": launcher["sha256"],
                "symlink_allowed": False,
            },
        },
        "probes": dict(probes),
    }


def _quota_record(
    manifest: BuildManifest,
    driver: ModuleType,
    role: QuotaRole,
    root: Path,
    tree: str,
    probes: Mapping[str, Any],
) -> dict[str, Any]:
    launcher_path = root / "bin/quota-axi"
    launcher = _file_record(launcher_path, root)
    runtime_manifest = root / "build/runtime-closure.json"
    launcher.update(
        {
            "binary_format": _binary_format(manifest, launcher_path),
            "source_path": "build/quota-axi-launcher.c",
            "source_sha256": _sha256(root / "build/quota-axi-launcher.c"),
            "dependencies": _native_dependencies(manifest, launcher_path),
            "signature": _signature_record(manifest, launcher_path),
            "fixed_path": "/usr/bin:/bin",
            "env_scrub": {
                "exact": list(GENERIC_ENV_EXACT),
                "prefixes": list(GENERIC_ENV_PREFIXES),
            },
            "runtime_manifest_sha256": _sha256(runtime_manifest),
        }
    )
    closure = _read_strict_json(runtime_manifest, f"{role.role} runtime closure")
    entries = closure.get("entries")
    if not isinstance(entries, list):
        raise BuildError("runtime closure entries disappeared after build")
    node = _file_record(root / "runtime/node", root)
    node.update(
        {
            "version": manifest.node_runtime.version,
            "signature_state": _signature_state(manifest, root / "runtime/node"),
            "operational": False,
        }
    )
    entrypoint = _file_record(
        root / "node_modules/quota-axi/dist/bin/quota-axi.js", root
    )
    entrypoint["operational"] = False
    return {
        "role": role.role,
        "release_path": root.relative_to(manifest.output_root).as_posix(),
        "version": role.version,
        "source_commit": role.source_commit,
        "tree_sha256": tree,
        "rebuild_tree_sha256": tree,
        "relocated_tree_sha256": tree,
        "proofs": [
            _proof(driver, root, relative) for relative in _quota_proof_paths()
        ],
        "launcher": launcher,
        "node": node,
        "entrypoint": entrypoint,
        "package_lock": {
            "path": "package-lock.json",
            "sha256": _sha256(root / "package-lock.json"),
        },
        "runtime_manifest": {
            "path": "build/runtime-closure.json",
            "sha256": _sha256(runtime_manifest),
            "format": "bridge-runtime-closure-v1",
            "entries_count": len(entries),
            "closure_tree_sha256": _closure_digest(entries),
        },
        "provenance": {
            "path": "build/provenance.json",
            "sha256": _sha256(root / "build/provenance.json"),
        },
        "invocation": {
            "operational_relative_path": "bin/quota-axi",
            "raw_node_forbidden": True,
            "raw_entrypoint_forbidden": True,
        },
        "probes": dict(probes),
    }


def _front_door_plan(
    manifest: BuildManifest,
    candidate: Path,
    rollback: Path,
) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "installed_path": str(manifest.operator_front_door),
        "required_type": "single_link_regular_file",
        "required_mode": "0555",
        "symlink_allowed": False,
        "candidate": {
            "source_path": str(candidate / "operator/agent-fleet"),
            "source_sha256": _sha256(candidate / "operator/agent-fleet"),
            "target_sha256": _sha256(candidate / "bin/agent-fleet"),
        },
        "rollback": {
            "source_path": str(rollback / "operator/agent-fleet"),
            "source_sha256": _sha256(rollback / "operator/agent-fleet"),
            "target_sha256": _sha256(rollback / "bin/agent-fleet"),
        },
    }


def _probe_front_door(manifest: BuildManifest, source: Path, expected: AgentRole) -> None:
    temporary = Path(os.path.realpath(tempfile.mkdtemp(prefix="bridge-front-door-probe-")))
    try:
        installed = temporary / ".local/bin/agent-fleet"
        _copy_regular(source, installed)
        os.chmod(installed, 0o555)
        completed = _run(
            [str(installed), "--format", "json", "version"],
            env={
                "HOME": str(temporary),
                "PATH": "/usr/bin:/bin",
                "LANG": "C",
                "LC_ALL": "C",
            },
            timeout=120,
        )
        payload = json.loads(completed.stdout)
        if payload != {
            "cli_version": expected.version,
            "contract_version": expected.contract_version,
        }:
            raise BuildError("native operator front door reached the wrong Agent Fleet role")
        info = os.lstat(installed)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise BuildError("native operator front-door probe was not a regular single-link file")
        _probe_invocation_shapes(
            installed,
            {
                "HOME": str(temporary),
                "PATH": "/usr/bin:/bin",
                "LANG": "C",
                "LC_ALL": "C",
            },
            ("--format", "json", "version"),
        )
    finally:
        _remove_tree(temporary)


def build(manifest_path: Path) -> Path:
    """Build, verify, and publish four previously absent immutable releases."""
    global _ACTIVE_MANIFEST
    manifest = load_manifest(manifest_path, allow_existing_outputs=True)
    _ACTIVE_MANIFEST = manifest
    _require_regular(
        manifest.path,
        "builder manifest",
        manifest.manifest_sha256,
    )
    driver = _load_transaction_driver(manifest.transaction_driver)
    if _recover_interrupted_publication(manifest, driver):
        return manifest.proof_manifest
    for role in (*manifest.agent_roles.values(), *manifest.quota_roles.values()):
        final = manifest.output_root / role.release_path
        if final.exists() or final.is_symlink():
            raise BuildError(
                f"final release exists without an attributable build journal: {final}"
            )
    if manifest.proof_manifest.exists() or manifest.proof_manifest.is_symlink():
        raise BuildError(
            f"proof manifest exists without a completing build journal: {manifest.proof_manifest}"
        )
    python_tree = _content_tree_sha256(
        manifest.python_runtime.root,
        ("bin/python3.11", "lib"),
        "pinned Python runtime",
    )
    if python_tree != manifest.python_runtime.tree_sha256:
        raise BuildError(
            f"pinned Python runtime tree is {python_tree}; expected {manifest.python_runtime.tree_sha256}"
        )

    agent_inputs: dict[str, Mapping[str, bytes]] = {}
    quota_inputs: dict[
        str, tuple[Mapping[str, bytes], Mapping[str, Mapping[str, bytes]], bytes]
    ] = {}
    for role_name, role in manifest.agent_roles.items():
        source = _validate_source_commit(
            manifest,
            role.source_repo,
            role.source_commit,
            role.source_tree_sha256,
            f"Agent Fleet {role_name}",
        )
        agent_inputs[role_name] = _wheel_members(role, source)
    for role_name, role in manifest.quota_roles.items():
        source = _validate_source_commit(
            manifest,
            role.source_repo,
            role.source_commit,
            role.source_tree_sha256,
            f"Quota AXI {role_name}",
        )
        quota_inputs[role_name] = _validate_quota_inputs(role, source)

    publication_id = secrets.token_hex(32)
    first_base = Path(os.path.realpath(tempfile.mkdtemp(prefix="bridge-runtime-build-a-")))
    second_base = Path(os.path.realpath(tempfile.mkdtemp(prefix="bridge-runtime-build-b-")))
    published: list[tuple[Path, tuple[int, int]]] = []
    plan_path = _front_door_plan_path(manifest)
    journal_path = _publication_journal_path(manifest)
    try:
        if journal_path.exists() or journal_path.is_symlink():
            raise BuildError(
                f"publication journal appeared after recovery: {journal_path}"
            )
        if plan_path.exists() or plan_path.is_symlink():
            raise BuildError(f"front-door plan already exists; refusing overwrite: {plan_path}")
        first = _build_once(
            manifest,
            first_base,
            agent_inputs,
            quota_inputs,
            driver,
            publication_id,
        )
        second = _build_once(
            manifest,
            second_base,
            agent_inputs,
            quota_inputs,
            driver,
            publication_id,
        )
        if first["trees"] != second["trees"]:
            raise BuildError(
                f"deterministic rebuild tree digests differ: {first['trees']!r} != {second['trees']!r}"
            )
        probes: dict[str, Mapping[str, Any]] = {}
        for role_name, role in manifest.agent_roles.items():
            key = f"agent_fleet_{role_name}"
            root = first["roots"][key]
            probes[key] = _probe_agent(root, role, driver)
            relocated = _relocation_and_tamper_probe(
                manifest, root, driver, role, "agent_fleet"
            )
            if relocated != first["trees"][key]:
                raise BuildError(f"{key} relocated tree digest differs")
        for role_name, role in manifest.quota_roles.items():
            key = f"quota_axi_{role_name}"
            root = first["roots"][key]
            probes[key] = _probe_quota(root, role, driver)
            relocated = _relocation_and_tamper_probe(
                manifest, root, driver, role, "quota_axi"
            )
            if relocated != first["trees"][key]:
                raise BuildError(f"{key} relocated tree digest differs")

        _require_regular(
            manifest.path,
            "builder manifest",
            manifest.manifest_sha256,
        )
        journal = {
            "schema_version": 1,
            "manifest_sha256": manifest.manifest_sha256,
            "publication_id": publication_id,
            "live_references_changed": False,
            "releases": _publication_records(manifest, first["trees"]),
        }
        _write_json_no_replace(journal_path, journal, 0o600)
        journal_info = os.lstat(journal_path)
        journal_identity = (
            journal_info.st_dev,
            journal_info.st_ino,
            _sha256(journal_path),
        )

        for key, source in first["roots"].items():
            if key.startswith("agent_fleet_"):
                role = manifest.agent_roles[key.removeprefix("agent_fleet_")]
            else:
                role = manifest.quota_roles[key.removeprefix("quota_axi_")]
            final = manifest.output_root / role.release_path
            identity = _publish_release(manifest, source, final)
            published.append((final, identity))
            if _tree_sha256(driver, final, f"published {key}") != first["trees"][key]:
                raise BuildError(f"published {key} tree digest differs")

        agent_candidate = manifest.output_root / manifest.agent_roles["candidate"].release_path
        agent_rollback = manifest.output_root / manifest.agent_roles["rollback"].release_path
        _probe_front_door(
            manifest,
            agent_candidate / "operator/agent-fleet",
            manifest.agent_roles["candidate"],
        )
        _probe_front_door(
            manifest,
            agent_rollback / "operator/agent-fleet",
            manifest.agent_roles["rollback"],
        )

        proof: dict[str, Any] = {
            "schema_version": 2,
            "agent_fleet_candidate": _agent_record(
                manifest,
                driver,
                manifest.agent_roles["candidate"],
                agent_candidate,
                first["trees"]["agent_fleet_candidate"],
                probes["agent_fleet_candidate"],
            ),
            "agent_fleet_rollback": _agent_record(
                manifest,
                driver,
                manifest.agent_roles["rollback"],
                agent_rollback,
                first["trees"]["agent_fleet_rollback"],
                probes["agent_fleet_rollback"],
            ),
            "quota_axi_candidate": _quota_record(
                manifest,
                driver,
                manifest.quota_roles["candidate"],
                manifest.output_root / manifest.quota_roles["candidate"].release_path,
                first["trees"]["quota_axi_candidate"],
                probes["quota_axi_candidate"],
            ),
            "quota_axi_rollback": _quota_record(
                manifest,
                driver,
                manifest.quota_roles["rollback"],
                manifest.output_root / manifest.quota_roles["rollback"].release_path,
                first["trees"]["quota_axi_rollback"],
                probes["quota_axi_rollback"],
            ),
            "xattr_policy": {
                "allowed_system_xattrs": list(ALLOWED_SYSTEM_XATTRS),
                "stripped_source_xattrs": True,
                "enforcement": "closed_tree",
            },
            "nondeterminism": {
                "builds": 2,
                "tree_hashes_match": True,
                "relocated_hashes_match": True,
                "known_exclusions": [],
            },
        }
        plan = _front_door_plan(manifest, agent_candidate, agent_rollback)
        _write_json_no_replace(plan_path, plan, 0o444)
        plan_info = os.lstat(plan_path)
        plan_identity = (plan_info.st_dev, plan_info.st_ino, _sha256(plan_path))
        _write_json_no_replace(manifest.proof_manifest, proof, 0o444)
        _unlink_file_if_identity(journal_path, journal_identity)
        return manifest.proof_manifest
    except Exception:
        for path, identity in reversed(published):
            _remove_tree_if_identity(path, identity)
        if plan_path.exists():
            if "plan_identity" not in locals():
                raise BuildError(f"front-door plan appeared without owned identity: {plan_path}")
            _unlink_file_if_identity(plan_path, plan_identity)
        if manifest.proof_manifest.exists():
            proof_info = os.lstat(manifest.proof_manifest)
            proof_identity = (
                proof_info.st_dev,
                proof_info.st_ino,
                _sha256(manifest.proof_manifest),
            )
            _unlink_file_if_identity(manifest.proof_manifest, proof_identity)
        raise
    finally:
        _remove_tree(first_base)
        _remove_tree(second_base)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--manifest",
        required=True,
        type=Path,
        help="strict schema-v2 input manifest",
    )
    arguments = parser.parse_args(argv)
    try:
        proof = build(arguments.manifest)
    except BuildError as exc:
        parser.error(str(exc))
    print(proof)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
