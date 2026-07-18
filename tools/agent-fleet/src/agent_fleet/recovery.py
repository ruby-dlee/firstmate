from __future__ import annotations

import json
import os
import pwd
import shutil
import signal
import socket
import stat
import subprocess
import sys
import unicodedata
import uuid
from collections.abc import Callable
from contextlib import suppress
from dataclasses import dataclass, replace
from hashlib import sha256
from pathlib import Path
from typing import Any, Protocol

from . import __version__
from .audit import append_audit
from .config import load_registry
from .enrollment import recover_pending_codex_transactions
from .identity import (
    adopt_provider_identity_bundle,
    identity_bundle_path,
    identity_conflict,
    read_identity_binding,
    refresh_provider_identity_anchors,
)
from .leases import active_leases
from .locks import provider_enrollment_lock, state_lock
from .models import Profile, Registry
from .paths import ensure_private_dir, open_private_dir
from .providers import CONTROL_PATH, login_argv
from .provision import PROVIDER_BINARY_MARKER_FILE, profile_is_provisioned, verified_provider_binary
from .quota import (
    has_remote_identity_proof,
    inspect_credential_source_contract,
    probe_quota,
    store_quota,
)
from .sessions import get_session, session_path
from .util import (
    atomic_write_bytes,
    atomic_write_json,
    process_identity_state,
    process_start_token,
    read_private_bytes,
    read_private_json,
)

RECOVERY_SCHEMA = 1
INITIALIZATION_CONTRACT_VERSION = 1
RECOVERY_MARKER = ".agent-fleet-recovery-stage.json"
CODEX_AUTH = "auth.json"
CLAUDE_AUTH = ".credentials.json"


class KeychainControl(Protocol):
    def exists(self, service: str, account: str) -> bool: ...

    def copy(self, source: str, destination: str, account: str) -> None: ...

    def delete(self, service: str, account: str, *, missing_ok: bool = False) -> None: ...


class SecurityKeychain:
    """Exact-account macOS Keychain operations without secret-bearing argv or buffers."""

    binary = Path("/usr/bin/security")

    def _prefix(self, operation: str, service: str, account: str) -> list[str]:
        if not service.startswith("Claude Code-") or not account:
            raise ValueError("refusing an unscoped Claude Keychain operation")
        return [str(self.binary), operation, "-s", service, "-a", account]

    def exists(self, service: str, account: str) -> bool:
        result = subprocess.run(
            self._prefix("find-generic-password", service, account),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if result.returncode not in {0, 44}:
            raise ValueError("scoped Claude Keychain lookup failed")
        return result.returncode == 0

    def copy(self, source: str, destination: str, account: str) -> None:
        # `security -w` writes the secret only to the pipe. The destination
        # command receives it through stdin because -w is its final option.
        reader = subprocess.Popen(
            [*self._prefix("find-generic-password", source, account), "-w"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        assert reader.stdout is not None
        try:
            writer = subprocess.Popen(
                [
                    *self._prefix("add-generic-password", destination, account),
                    "-U",
                    "-w",
                ],
                stdin=reader.stdout,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            reader.stdout.close()
            writer_status = writer.wait()
            reader_status = reader.wait()
        finally:
            reader.stdout.close()
            if reader.poll() is None:
                reader.kill()
                reader.wait()
        if reader_status != 0 or writer_status != 0:
            raise ValueError("scoped Claude Keychain copy failed")

    def delete(self, service: str, account: str, *, missing_ok: bool = False) -> None:
        result = subprocess.run(
            self._prefix("delete-generic-password", service, account),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if result.returncode != 0 and not (missing_ok and result.returncode == 44):
            raise ValueError("scoped Claude Keychain deletion failed")


@dataclass(frozen=True)
class RecoveryHooks:
    """Narrow seams used by tests; production defaults remain the sealed controls."""

    login: Callable[[list[str], dict[str, str], Path, Callable[[int, str], None]], int]
    inspect_source: Callable[[Registry, Profile, bool], dict[str, Any]]
    prove: Callable[[Registry, Profile, bool], tuple[dict[str, Any], dict[str, Any]]]
    refresh_anchors: Callable[[Registry, str, bool], None]
    adopt_bundle: Callable[
        [Registry, str, dict[str, tuple[dict[str, Any], dict[str, Any]]], bool],
        dict[str, Any],
    ]
    keychain: KeychainControl


def _system_login(
    argv: list[str],
    environment: dict[str, str],
    cwd: Path,
    record_child: Callable[[int, str], None],
) -> int:
    """Fork a gated child so its durable PID record precedes provider exec."""

    read_fd, write_fd = os.pipe()
    pid = os.fork()
    if pid == 0:  # pragma: no cover - integration-only child
        try:
            os.close(write_fd)
            os.umask(0o077)
            if os.read(read_fd, 1) != b"1":
                os._exit(126)
            os.close(read_fd)
            os.chdir(cwd)
            os.execve(argv[0], argv, environment)
        except BaseException:
            os._exit(126)
    os.close(read_fd)
    try:
        start = process_start_token(pid)
        if start is None:
            os.kill(pid, signal.SIGTERM)
            os.waitpid(pid, 0)
            raise ValueError("could not establish provider login process identity")
        record_child(pid, start)
        os.write(write_fd, b"1")
    except BaseException:
        with suppress(ProcessLookupError):
            os.kill(pid, signal.SIGTERM)
        os.waitpid(pid, 0)
        raise
    finally:
        os.close(write_fd)
    _, status = os.waitpid(pid, 0)
    return os.waitstatus_to_exitcode(status)


def _inspect_source(registry: Registry, profile: Profile, prompt: bool) -> dict[str, Any]:
    return inspect_credential_source_contract(
        registry,
        profile,
        allow_keychain_prompt=prompt,
        allow_absent=True,
    )


def _prove(
    registry: Registry,
    profile: Profile,
    prompt: bool,
) -> tuple[dict[str, Any], dict[str, Any]]:
    before = inspect_credential_source_contract(
        registry,
        profile,
        allow_keychain_prompt=prompt,
    )
    proof = probe_quota(registry, profile, allow_keychain_prompt=prompt)
    after = inspect_credential_source_contract(
        registry,
        profile,
        allow_keychain_prompt=prompt,
    )
    if before != after:
        raise ValueError(f"credential source changed while proving {profile.id}")
    if not has_remote_identity_proof(proof):
        raise ValueError(f"fresh remote identity proof unavailable for {profile.id}")
    return proof, after


def _refresh(registry: Registry, provider: str, prompt: bool) -> None:
    refresh_provider_identity_anchors(
        registry,
        provider,
        allow_keychain_prompt=prompt,
    )


def _adopt(
    registry: Registry,
    provider: str,
    proofs: dict[str, tuple[dict[str, Any], dict[str, Any]]],
    prompt: bool,
) -> dict[str, Any]:
    return adopt_provider_identity_bundle(
        registry,
        provider,
        proofs,
        allow_keychain_prompt=prompt,
    )


def default_recovery_hooks() -> RecoveryHooks:
    return RecoveryHooks(
        login=_system_login,
        inspect_source=_inspect_source,
        prove=_prove,
        refresh_anchors=_refresh,
        adopt_bundle=_adopt,
        keychain=SecurityKeychain(),
    )


def _workers(registry: Registry, provider: str) -> tuple[Profile, ...]:
    # Filter safety policy before returning any object to recovery code. Reserve
    # homes and credential sources are never derived, inspected, or cleaned.
    return tuple(
        sorted(
            (
                profile
                for profile in registry.profiles.values()
                if profile.safety_policy == "worker" and profile.provider == provider
            ),
            key=lambda item: item.id,
        )
    )


def _provider_has_active_lease(registry: Registry, provider: str) -> bool:
    worker_ids = {profile.id for profile in _workers(registry, provider)}
    return any(lease.get("profile") in worker_ids for lease in active_leases(registry))


def _provider_has_session_mapping(registry: Registry, provider: str) -> bool:
    directory = registry.settings.state_dir / "sessions"
    if not directory.exists():
        return False
    _private_directory(directory, "provider session mapping directory")
    found = False
    for path in sorted(directory.glob("*.json")):
        raw = read_private_json(path, label="provider session mapping")
        if not isinstance(raw, dict) or not isinstance(raw.get("task"), str):
            raise ValueError(f"corrupt provider session mapping: {path}")
        task = str(raw["task"])
        if session_path(registry, task) != path:
            raise ValueError(f"provider session filename does not match its task: {path}")
        mapping = get_session(registry, task)
        profile = registry.require_profile(str(mapping["profile"]))
        if profile.provider == provider and profile.safety_policy == "worker":
            found = True
    return found


def _assert_drained(registry: Registry, provider: str) -> None:
    enabled = [profile.id for profile in _workers(registry, provider) if profile.enabled]
    if enabled:
        raise ValueError(
            f"disable every {provider} worker before credential recovery: " + ", ".join(enabled)
        )
    if _provider_has_active_lease(registry, provider):
        raise ValueError(f"drain every {provider} worker lease before credential recovery")
    if _provider_has_session_mapping(registry, provider):
        raise ValueError(
            f"remove every continuable {provider} worker session mapping before credential recovery"
        )


def _recheck(
    expected: Registry,
    config_path: Path,
    profile_id: str,
    boundary: str,
) -> tuple[Registry, Profile]:
    with state_lock(expected.settings.state_dir, expected.settings.lock_stale_seconds):
        observed = load_registry(config_path)
        if observed != expected:
            raise ValueError(f"registry changed before recovery {boundary}; operation stopped")
        provider = expected.require_profile(profile_id).provider
        target = next(
            (profile for profile in _workers(observed, provider) if profile.id == profile_id),
            None,
        )
        if target is None:
            raise ValueError("recovery target is not a managed worker")
        _assert_drained(observed, target.provider)
    if not profile_is_provisioned(target):
        raise ValueError(f"provision worker {target.id} before credential recovery")
    verified_provider_binary(observed, target)
    return observed, target


def _stat_payload(metadata: os.stat_result) -> dict[str, int]:
    return {
        "dev": metadata.st_dev,
        "ino": metadata.st_ino,
        "uid": metadata.st_uid,
        "mode": stat.S_IMODE(metadata.st_mode),
        "nlink": metadata.st_nlink,
        "size": metadata.st_size,
        "mtime_ns": metadata.st_mtime_ns,
        "ctime_ns": metadata.st_ctime_ns,
    }


def _private_file(path: Path, label: str) -> os.stat_result:
    metadata = path.lstat()
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or stat.S_IMODE(metadata.st_mode) != 0o600
        or metadata.st_nlink != 1
    ):
        raise ValueError(f"{label} must be a current-user 0600 single-link file: {path}")
    return metadata


def _private_directory(path: Path, label: str) -> os.stat_result:
    metadata = path.lstat()
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or stat.S_IMODE(metadata.st_mode) != 0o700
    ):
        raise ValueError(f"{label} must be a current-user 0700 directory: {path}")
    return metadata


def _same_stat(path: Path, encoded: object, *, ctime: bool = True) -> bool:
    if not isinstance(encoded, dict):
        return False
    try:
        observed = _stat_payload(path.lstat())
    except FileNotFoundError:
        return False
    fields = set(observed) if ctime else set(observed) - {"ctime_ns"}
    return all(encoded.get(field) == observed[field] for field in fields)


def _same_directory_identity(path: Path, encoded: object) -> bool:
    if not isinstance(encoded, dict):
        return False
    try:
        observed = _stat_payload(_private_directory(path, "credential recovery stage"))
    except (FileNotFoundError, ValueError):
        return False
    return all(
        encoded.get(field) == observed[field]
        for field in ("dev", "ino", "uid", "mode")
    )


def _journal_root(registry: Registry) -> Path:
    return registry.settings.state_dir / "transactions" / "credential-recovery"


def _journal_path_for_worker(registry: Registry, profile: Profile) -> Path:
    if profile.safety_policy != "worker":
        raise ValueError("reserve profiles have no credential-recovery transaction path")
    return _journal_root(registry) / f"{profile.provider}-{profile.id}.json"


def _stage_root(registry: Registry, provider: str) -> Path:
    return registry.settings.state_dir / "staging" / "credential-recovery" / provider


def _write_journal(path: Path, journal: dict[str, Any], phase: str) -> None:
    journal["phase"] = phase
    atomic_write_json(path, journal)


def _read_journal(registry: Registry, profile: Profile) -> tuple[Path, dict[str, Any]] | None:
    path = _journal_path_for_worker(registry, profile)
    try:
        value = read_private_json(path, label="credential recovery journal")
    except FileNotFoundError:
        return None
    if (
        not isinstance(value, dict)
        or value.get("schema") != RECOVERY_SCHEMA
        or value.get("kind") != "credential-recovery"
        or value.get("profile") != profile.id
        or value.get("provider") != profile.provider
        or value.get("workflow") not in {"recover", "initialize"}
        or value.get("journal") != str(path)
    ):
        raise ValueError(f"invalid credential recovery journal: {path}")
    return path, value


def _transaction_paths(
    registry: Registry,
    profile: Profile,
    nonce: str,
) -> dict[str, str]:
    stage = _stage_root(registry, profile.provider) / f".{profile.id}.login-{nonce}"
    return {
        "stage": str(stage),
        "codex_backup": str(stage / ".stable-auth.backup"),
        "claude_file_backup": str(stage / ".stable-claude-auth.backup"),
        "bundle_backup": str(stage / ".identity-bundle.backup"),
        "provisional_backup": str(stage / ".provisional-batch.backup"),
        "provisional_guard_backup": str(stage / ".provisional-guard.backup"),
        "install_temp": str(profile.home / f".agent-fleet-recovery-{nonce}.new"),
        "rollback_temp": str(profile.home / f".agent-fleet-recovery-{nonce}.rollback"),
    }


def _validate_paths(
    registry: Registry,
    profile: Profile,
    journal: dict[str, Any],
) -> dict[str, Path]:
    nonce = journal.get("nonce")
    if not isinstance(nonce, str) or len(nonce) != 32:
        raise ValueError("credential recovery journal has invalid ownership nonce")
    expected = _transaction_paths(registry, profile, nonce)
    raw = journal.get("paths")
    if raw != expected:
        raise ValueError("credential recovery journal paths do not match the worker")
    return {name: Path(value) for name, value in expected.items()}


def _copy_private_file(source: Path, destination: Path) -> os.stat_result:
    source_before = _private_file(source, "credential transaction source")
    source_fd = os.open(source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    destination_fd = -1
    try:
        if _stat_payload(os.fstat(source_fd)) != _stat_payload(source_before):
            raise ValueError("credential transaction source changed while opening")
        destination_fd = os.open(
            destination,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        os.fchmod(destination_fd, 0o600)
        while chunk := os.read(source_fd, 1024 * 1024):
            view = memoryview(chunk)
            while view:
                view = view[os.write(destination_fd, view) :]
        os.fsync(destination_fd)
        installed = os.fstat(destination_fd)
    finally:
        os.close(source_fd)
        if destination_fd >= 0:
            os.close(destination_fd)
    return installed


def _fsync(path: Path) -> None:
    descriptor = open_private_dir(path)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _stage_marker_payload(profile: Profile, nonce: str) -> dict[str, Any]:
    return {
        "schema": 1,
        "kind": "credential-recovery-stage",
        "profile": profile.id,
        "provider": profile.provider,
        "nonce": nonce,
    }


def _prepare_stage(
    registry: Registry,
    profile: Profile,
    journal_path: Path,
    journal: dict[str, Any],
) -> Profile:
    paths = _validate_paths(registry, profile, journal)
    stage = paths["stage"]
    ensure_private_dir(stage.parent)
    stage.mkdir(mode=0o700)
    stage.chmod(0o700)
    marker = stage / RECOVERY_MARKER
    atomic_write_json(marker, _stage_marker_payload(profile, str(journal["nonce"])))
    # These two non-secret markers let the sealed Quota runtime inspect and
    # prove the staged credential. Worker hooks, shared workflow links, project
    # trust, plugins, and provider history are deliberately absent.
    atomic_write_bytes(
        stage / ".agent-fleet-profile.json",
        (json.dumps({
            "schema": 2,
            "agent_fleet_version": __version__,
            "profile": profile.id,
            "provider": profile.provider,
        }, indent=2, sort_keys=True) + "\n").encode(),
    )
    stable_binary_marker = profile.home / PROVIDER_BINARY_MARKER_FILE
    atomic_write_bytes(
        stage / PROVIDER_BINARY_MARKER_FILE,
        read_private_bytes(stable_binary_marker, label="managed provider binary marker"),
    )
    if profile.provider == "codex":
        atomic_write_bytes(
            stage / "config.toml",
            b'cli_auth_credentials_store = "file"\n\n[features]\nhooks = false\n',
        )
    ensure_private_dir(stage / ".cache")
    journal["stage_stat"] = _stat_payload(_private_directory(stage, "recovery stage"))
    journal["marker_stat"] = _stat_payload(_private_file(marker, "recovery stage marker"))
    _record_stage_manifest(stage, journal)
    _write_journal(journal_path, journal, "stage-ready")
    return replace(profile, home=stage, enabled=False)


def _validate_stage(profile: Profile, stage: Path, journal: dict[str, Any]) -> None:
    if not _same_directory_identity(stage, journal.get("stage_stat")):
        raise ValueError("credential recovery stage path was replaced")
    marker = stage / RECOVERY_MARKER
    if not _same_stat(marker, journal.get("marker_stat"), ctime=False):
        raise ValueError("credential recovery stage marker was replaced")
    if read_private_json(marker, label="credential recovery stage marker") != (
        _stage_marker_payload(profile, str(journal["nonce"]))
    ):
        raise ValueError("credential recovery stage marker is invalid")
    for root, directories, files in os.walk(stage, followlinks=False):
        root_path = Path(root)
        for name in [*directories, *files]:
            path = root_path / name
            metadata = path.lstat()
            if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) & 0o077:
                raise ValueError(f"unsafe entry in credential recovery stage: {path}")
            if stat.S_ISDIR(metadata.st_mode):
                continue
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
                raise ValueError(f"non-regular entry in credential recovery stage: {path}")
    mutable_phases = {
        "login-running",
        "login-finished",
        "stage-proof-running",
        "credential-backup-running",
        "bundle-backup-running",
        "provisional-backup-running",
    }
    expected_manifest = journal.get("stage_manifest")
    if (
        journal.get("phase") not in mutable_phases
        and expected_manifest is not None
        and expected_manifest != _stage_manifest(stage)
    ):
        raise ValueError("credential recovery stage has unrecorded or changed entries")


def _stage_manifest(stage: Path) -> list[dict[str, Any]]:
    manifest: list[dict[str, Any]] = []
    for root, directories, files in os.walk(stage, followlinks=False):
        root_path = Path(root)
        for name in sorted([*directories, *files]):
            path = root_path / name
            metadata = path.lstat()
            relative_digest = sha256(os.fsencode(str(path.relative_to(stage)))).hexdigest()
            if stat.S_ISDIR(metadata.st_mode):
                kind = "directory"
            elif stat.S_ISREG(metadata.st_mode):
                kind = "file"
            else:
                raise ValueError(f"unsafe stage manifest entry: {path}")
            manifest.append(
                {
                    "path_sha256": relative_digest,
                    "kind": kind,
                    **_stat_payload(metadata),
                }
            )
    return sorted(manifest, key=lambda item: str(item["path_sha256"]))


def _record_stage_manifest(stage: Path, journal: dict[str, Any]) -> None:
    journal["stage_manifest"] = _stage_manifest(stage)


def _remove_stage(profile: Profile, stage: Path, journal: dict[str, Any]) -> None:
    _validate_stage(profile, stage, journal)
    quarantine = stage.with_name(f".{stage.name}.cleanup-{journal['nonce']}")
    if quarantine.exists() or quarantine.is_symlink():
        raise ValueError("credential recovery cleanup quarantine already exists")
    identity = (stage.lstat().st_dev, stage.lstat().st_ino)
    os.replace(stage, quarantine)
    moved = quarantine.lstat()
    if (moved.st_dev, moved.st_ino) != identity:
        raise ValueError("credential recovery stage changed during quarantine")
    _validate_stage(profile, quarantine, journal)
    shutil.rmtree(quarantine)
    _fsync(quarantine.parent)


def _claude_service(home: Path) -> str:
    normalized = unicodedata.normalize("NFC", str(home))
    return f"Claude Code-credentials-{sha256(normalized.encode()).hexdigest()[:8]}"


def _keychain_account() -> str:
    try:
        account = pwd.getpwuid(os.getuid()).pw_name
    except (KeyError, OSError) as exc:
        raise ValueError("cannot resolve the current macOS username") from exc
    if not account or any(ord(character) < 32 for character in account):
        raise ValueError("current macOS username is unsafe")
    return account


def _login_environment(profile: Profile) -> dict[str, str]:
    account = _keychain_account()
    environment = {
        "HOME": str(profile.home),
        "PATH": CONTROL_PATH,
        "LANG": "en_US.UTF-8",
        "TERM": "xterm-256color",
        # Claude derives its Keychain account from USER before consulting the
        # OS account. Never let a hostile inherited value redirect storage.
        "USER": account,
        "LOGNAME": account,
        "AGENT_FLEET_PROFILE": profile.id,
        "AGENT_FLEET_PROVIDER": profile.provider,
        "XDG_CACHE_HOME": str(profile.home / ".cache"),
        "XDG_CONFIG_HOME": str(profile.home / ".config"),
        "XDG_DATA_HOME": str(profile.home / ".data"),
        "XDG_STATE_HOME": str(profile.home / ".state"),
    }
    if profile.provider == "claude":
        environment.update(
            {
                "CLAUDE_CONFIG_DIR": str(profile.home),
                "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION": "false",
                "DISABLE_LOGOUT_COMMAND": "1",
            }
        )
    else:
        environment.update(
            {
                "CODEX_HOME": str(profile.home),
                "CODEX_SQLITE_HOME": str(profile.home),
            }
        )
    return environment


def _preflight_stable_credential(profile: Profile) -> None:
    credential = profile.home / (CLAUDE_AUTH if profile.provider == "claude" else CODEX_AUTH)
    if credential.exists() or credential.is_symlink():
        _private_file(credential, f"stable {profile.provider} credential")


def _snapshot_bundle(registry: Registry, paths: dict[str, Path], journal: dict[str, Any]) -> None:
    bundle = identity_bundle_path(registry, str(journal["provider"]))
    journal["bundle_existed"] = bundle.exists()
    if bundle.exists() or bundle.is_symlink():
        _private_file(bundle, "provider identity bundle")
        _copy_private_file(bundle, paths["bundle_backup"])
        journal["bundle_original_stat"] = _stat_payload(bundle.lstat())


def _provisional_path(registry: Registry, provider: str) -> Path:
    return registry.settings.state_dir / "identity-bindings" / f"{provider}-provisional.json"


def _provisional_guard_path(registry: Registry, provider: str) -> Path:
    workers = _workers(registry, provider)
    if not workers:
        raise ValueError("provider initialization requires at least one managed worker")
    return workers[0].home / f".agent-fleet-{provider}-initialization.json"


def _provider_initialization_contract(registry: Registry, provider: str) -> dict[str, Any]:
    config_path = registry.config_path
    if config_path is None or not config_path.is_absolute():
        raise ValueError("provider initialization requires an absolute loaded registry path")
    config_payload = read_private_bytes(config_path, label="Agent Fleet registry")
    configured = registry.require_provider(provider)
    workers: list[dict[str, Any]] = []
    for worker in _workers(registry, provider):
        marker = worker.home / PROVIDER_BINARY_MARKER_FILE
        marker_payload = read_private_bytes(marker, label="managed provider binary marker")
        workers.append(
            {
                "id": worker.id,
                "provider": worker.provider,
                "home": str(worker.home),
                "pools": list(worker.pools),
                "weight": worker.weight,
                "max_concurrent": worker.max_concurrent,
                "reserve_percent": worker.reserve_percent,
                "safety_policy": worker.safety_policy,
                "provider_binary_marker_sha256": sha256(marker_payload).hexdigest(),
            }
        )
    payload = {
        "initialization_contract_version": INITIALIZATION_CONTRACT_VERSION,
        "agent_fleet_version": __version__,
        "registry_schema_version": registry.version,
        "registry_config_path": str(config_path),
        "registry_config_sha256": sha256(config_payload).hexdigest(),
        "state_dir": str(registry.settings.state_dir),
        "share_dir": str(registry.settings.share_dir),
        "quota_binary": str(registry.settings.quota_binary),
        "quota_node_binary": str(registry.settings.quota_node_binary),
        "provider": provider,
        "provider_binary": str(configured.binary),
        "base_home": str(configured.base_home) if configured.base_home is not None else None,
        "desktop_identity_file": (
            str(configured.desktop_identity_file)
            if configured.desktop_identity_file is not None
            else None
        ),
        "hooks_source": str(configured.hooks_source) if configured.hooks_source else None,
        "shared_entries": list(configured.shared_entries),
        "trusted_projects": [str(path) for path in configured.trusted_projects],
        "quota_binary_sha256": registry.settings.quota_binary_sha256,
        "quota_node_sha256": registry.settings.quota_node_sha256,
        "quota_release_tree_sha256": registry.settings.quota_release_tree_sha256,
        "quota_stale_seconds": registry.settings.quota_stale_seconds,
        "quota_verification_grace_seconds": (
            registry.settings.quota_verification_grace_seconds
        ),
        "lease_grace_seconds": registry.settings.lease_grace_seconds,
        "active_lease_penalty": registry.settings.active_lease_penalty,
        "lock_stale_seconds": registry.settings.lock_stale_seconds,
        "workers": workers,
    }
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    return {
        "expected_workers": [worker["id"] for worker in workers],
        "contract_sha256": sha256(encoded).hexdigest(),
    }


def _read_provisional_batch(
    registry: Registry,
    provider: str,
) -> dict[str, Any] | None:
    path = _provisional_path(registry, provider)
    guard_path = _provisional_guard_path(registry, provider)
    try:
        payload = read_private_json(path, label="provider provisional identity batch")
    except FileNotFoundError:
        if guard_path.exists() or guard_path.is_symlink():
            _private_file(guard_path, "provider initialization locator")
            raise ValueError(
                "provider initialization locator exists without its configured provisional batch; "
                "state root or registry path drifted"
            ) from None
        return None
    try:
        guard = read_private_json(guard_path, label="provider initialization locator")
    except FileNotFoundError as exc:
        raise ValueError("provider provisional identity batch has no durable locator") from exc
    expected = _provider_initialization_contract(registry, provider)
    if (
        not isinstance(payload, dict)
        or set(payload) != {
            "schema",
            "kind",
            "provider",
            "generation",
            "expected_workers",
            "contract_sha256",
            "workers",
        }
        or payload.get("schema") != 1
        or payload.get("kind") != "provider-initialization"
        or payload.get("provider") != provider
        or payload.get("expected_workers") != expected["expected_workers"]
        or payload.get("contract_sha256") != expected["contract_sha256"]
        or not isinstance(payload.get("generation"), str)
        or len(str(payload["generation"])) != 32
        or not isinstance(payload.get("workers"), dict)
        or not set(payload["workers"]).issubset(set(expected["expected_workers"]))
    ):
        raise ValueError("provider provisional identity batch is invalid or drifted")
    for profile_id, record in payload["workers"].items():
        if (
            not isinstance(record, dict)
            or set(record) != {
                "profile",
                "provider",
                "stable_home",
                "identity_fingerprint",
                "source_contract",
                "source_stat",
                "transaction_generation",
            }
            or record.get("profile") != profile_id
            or record.get("provider") != provider
            or record.get("stable_home")
            != str(registry.require_profile(profile_id).home)
            or not isinstance(record.get("identity_fingerprint"), str)
            or len(str(record["identity_fingerprint"])) != 64
            or not isinstance(record.get("source_contract"), dict)
            or not isinstance(record.get("source_stat"), dict)
            or not isinstance(record.get("transaction_generation"), str)
            or len(str(record["transaction_generation"])) != 32
        ):
            raise ValueError("provider provisional identity record is invalid or drifted")
    expected_guard = {
        "schema": 1,
        "kind": "provider-initialization-locator",
        "provider": provider,
        "generation": payload["generation"],
        "contract_sha256": payload["contract_sha256"],
        "provisional_path": str(path),
        "state_dir": str(registry.settings.state_dir),
        "share_dir": str(registry.settings.share_dir),
        "registry_config_path": str(registry.config_path),
        "agent_fleet_version": __version__,
    }
    if guard != expected_guard:
        raise ValueError("provider initialization locator is invalid or drifted")
    return payload


def _provisional_guard_payload(
    registry: Registry,
    provider: str,
    batch: dict[str, Any],
) -> dict[str, Any]:
    return {
        "schema": 1,
        "kind": "provider-initialization-locator",
        "provider": provider,
        "generation": batch["generation"],
        "contract_sha256": batch["contract_sha256"],
        "provisional_path": str(_provisional_path(registry, provider)),
        "state_dir": str(registry.settings.state_dir),
        "share_dir": str(registry.settings.share_dir),
        "registry_config_path": str(registry.config_path),
        "agent_fleet_version": __version__,
    }


def _new_provisional_batch(registry: Registry, provider: str) -> dict[str, Any]:
    contract = _provider_initialization_contract(registry, provider)
    return {
        "schema": 1,
        "kind": "provider-initialization",
        "provider": provider,
        "generation": uuid.uuid4().hex,
        **contract,
        "workers": {},
    }


def _source_stat(
    hooks: RecoveryHooks,
    profile: Profile,
    source: dict[str, Any],
) -> dict[str, Any]:
    kind = source.get("kind")
    if kind in {"auth-json", "oauth-file"}:
        expected = profile.home / (CODEX_AUTH if profile.provider == "codex" else CLAUDE_AUTH)
        if source.get("path") != str(expected):
            raise ValueError("stable credential source path is outside the worker home")
        return {"kind": "file", **_stat_payload(_private_file(expected, "stable credential"))}
    if kind == "keychain" and profile.provider == "claude":
        account = _keychain_account()
        service = _claude_service(profile.home)
        if (
            source.get("service") != service
            or source.get("config_home") != str(profile.home)
            or not hooks.keychain.exists(service, account)
        ):
            raise ValueError("stable scoped Claude Keychain source changed")
        return {
            "kind": "keychain",
            "service": service,
            "account": account,
            "present": True,
        }
    raise ValueError("stable credential source is not eligible for provisional identity")


def _provisional_record(
    hooks: RecoveryHooks,
    profile: Profile,
    proof: dict[str, Any],
    source: dict[str, Any],
    transaction_generation: str,
) -> dict[str, Any]:
    return {
        "profile": profile.id,
        "provider": profile.provider,
        "stable_home": str(profile.home),
        "identity_fingerprint": _identity_fingerprint(proof, profile),
        "source_contract": source,
        "source_stat": _source_stat(hooks, profile, source),
        "transaction_generation": transaction_generation,
    }


def _snapshot_provisional(
    registry: Registry,
    provider: str,
    paths: dict[str, Path],
    journal: dict[str, Any],
) -> None:
    path = _provisional_path(registry, provider)
    guard = _provisional_guard_path(registry, provider)
    existed = path.exists() or path.is_symlink()
    guard_existed = guard.exists() or guard.is_symlink()
    if existed != guard_existed:
        raise ValueError("provider provisional identity batch and locator disagree")
    journal["provisional_existed"] = existed
    journal["provisional_guard_existed"] = guard_existed
    if existed:
        _private_file(path, "provider provisional identity batch")
        _copy_private_file(path, paths["provisional_backup"])
        _private_file(guard, "provider initialization locator")
        _copy_private_file(guard, paths["provisional_guard_backup"])


def _restore_provisional(
    registry: Registry,
    provider: str,
    paths: dict[str, Path],
    journal: dict[str, Any],
) -> None:
    path = _provisional_path(registry, provider)
    guard = _provisional_guard_path(registry, provider)
    if journal.get("provisional_existed") is True:
        backup = paths["provisional_backup"]
        _private_file(backup, "provider provisional identity backup")
        temporary = path.with_name(f".{path.name}.rollback-{journal['nonce']}")
        if temporary.exists() or temporary.is_symlink():
            raise ValueError("provisional identity rollback temporary already exists")
        _copy_private_file(backup, temporary)
        os.replace(temporary, path)
        _fsync(path.parent)
    elif journal.get("provisional_existed") is False and (path.exists() or path.is_symlink()):
        _private_file(path, "transaction-created provisional identity batch")
        path.unlink()
        _fsync(path.parent)
    if journal.get("provisional_guard_existed") is True:
        backup = paths["provisional_guard_backup"]
        _private_file(backup, "provider initialization locator backup")
        temporary = guard.with_name(f".{guard.name}.rollback-{journal['nonce']}")
        if temporary.exists() or temporary.is_symlink():
            raise ValueError("initialization locator rollback temporary already exists")
        _copy_private_file(backup, temporary)
        os.replace(temporary, guard)
        _fsync(guard.parent)
    elif journal.get("provisional_guard_existed") is False and (
        guard.exists() or guard.is_symlink()
    ):
        _private_file(guard, "transaction-created provider initialization locator")
        guard.unlink()
        _fsync(guard.parent)


def _restore_bundle(registry: Registry, paths: dict[str, Path], journal: dict[str, Any]) -> None:
    bundle = identity_bundle_path(registry, str(journal["provider"]))
    if journal.get("bundle_existed") is True:
        backup = paths["bundle_backup"]
        _private_file(backup, "provider identity bundle backup")
        temporary = bundle.with_name(f".{bundle.name}.rollback-{journal['nonce']}")
        if temporary.exists() or temporary.is_symlink():
            raise ValueError("identity bundle rollback temporary already exists")
        _copy_private_file(backup, temporary)
        os.replace(temporary, bundle)
        _fsync(bundle.parent)
    elif journal.get("bundle_existed") is False and (bundle.exists() or bundle.is_symlink()):
        _private_file(bundle, "transaction-created provider identity bundle")
        bundle.unlink()
        _fsync(bundle.parent)


def _identity_fingerprint(proof: dict[str, Any], profile: Profile) -> str:
    fingerprint = proof.get("identity_fingerprint")
    if not isinstance(fingerprint, str) or len(fingerprint) != 64:
        raise ValueError(f"fresh remote identity unavailable for {profile.id}")
    return fingerprint


def _assert_staged_identity(
    registry: Registry,
    target: Profile,
    proof: dict[str, Any],
) -> None:
    fingerprint = _identity_fingerprint(proof, target)
    target_binding = read_identity_binding(registry, target)
    if target_binding.get("status") == "unavailable":
        raise ValueError(
            "credential recovery requires an existing pinned worker identity; "
            "initial enrollment is a separate reviewed workflow"
        )
    expected = target_binding.get("remote_fingerprint")
    if expected != fingerprint:
        raise ValueError("staged login does not match the worker's pinned remote identity")
    for worker in _workers(registry, target.provider):
        if worker.id == target.id:
            continue
        binding = read_identity_binding(registry, worker)
        other = binding.get("remote_fingerprint")
        if not isinstance(other, str) or len(other) != 64:
            raise ValueError(f"identity binding unavailable for peer worker {worker.id}")
        if other == fingerprint:
            raise ValueError(f"staged login duplicates managed worker {worker.id}")
    conflict = identity_conflict(
        registry,
        target,
        proof,
        require_complete_worker_set=False,
    )
    if conflict is not None:
        raise ValueError(f"staged login conflicts with {conflict}")


def _require_existing_worker_bindings(registry: Registry, provider: str) -> None:
    for worker in _workers(registry, provider):
        binding = read_identity_binding(registry, worker)
        fingerprint = binding.get("remote_fingerprint")
        if binding.get("status") == "unavailable" or not (
            isinstance(fingerprint, str) and len(fingerprint) == 64
        ):
            raise ValueError(
                f"credential recovery requires an existing pinned identity for {worker.id}"
            )


def _bundle_present(registry: Registry, provider: str) -> bool:
    path = identity_bundle_path(registry, provider)
    if not (path.exists() or path.is_symlink()):
        return False
    _private_file(path, "provider identity bundle")
    return True


def _assert_workflow_state(
    registry: Registry,
    provider: str,
    workflow: str,
    *,
    initialization_complete: bool = False,
) -> dict[str, Any] | None:
    bundle = _bundle_present(registry, provider)
    provisional = _read_provisional_batch(registry, provider)
    if workflow == "recover":
        if not bundle:
            raise ValueError(
                "credential recovery requires an existing pinned identity bundle; "
                "use the separate initialize-login workflow"
            )
        if provisional is not None:
            raise ValueError("provider has both a bundle and a provisional identity batch")
        _require_existing_worker_bindings(registry, provider)
        return None
    if workflow != "initialize":
        raise ValueError("unsupported profile login transaction workflow")
    if initialization_complete:
        if not bundle or provisional is not None:
            raise ValueError("completed provider initialization state is inconsistent")
        return None
    if bundle:
        raise ValueError(
            "provider identity bundle already exists; use recover-login for bound workers"
        )
    return provisional


def _normalize_source_contract(
    hooks: RecoveryHooks,
    profile: Profile,
    source: dict[str, Any],
) -> dict[str, Any]:
    if source.get("kind") != "keychain":
        return source
    if profile.provider != "claude":
        raise ValueError("non-Claude worker reported a Keychain credential source")
    service = _claude_service(profile.home)
    account = _keychain_account()
    reported_account = source.get("account")
    if (
        source.get("service") != service
        or source.get("config_home") != str(profile.home)
        or reported_account != account
        or not hooks.keychain.exists(service, account)
    ):
        raise ValueError("Claude credential source is not scoped to the exact home and account")
    return {**source, "account": account}


def _initialization_peer_proofs(
    registry: Registry,
    target: Profile,
    batch: dict[str, Any],
    hooks: RecoveryHooks,
    allow_keychain_prompt: bool,
) -> dict[str, tuple[dict[str, Any], dict[str, Any]]]:
    results: dict[str, tuple[dict[str, Any], dict[str, Any]]] = {}
    records = batch["workers"]
    for worker in _workers(registry, target.provider):
        if worker.id == target.id:
            continue
        record = records.get(worker.id)
        try:
            proof, raw_source = hooks.prove(registry, worker, allow_keychain_prompt)
            source = _normalize_source_contract(hooks, worker, raw_source)
        except (OSError, TimeoutError, ValueError):
            if record is not None:
                raise ValueError(
                    f"recorded provisional worker is not freshly verifiable: {worker.id}"
                ) from None
            continue
        if record is not None:
            observed = _provisional_record(
                hooks,
                worker,
                proof,
                source,
                str(record["transaction_generation"]),
            )
            if observed != record:
                raise ValueError(
                    f"recorded provisional worker changed since initialization: {worker.id}"
                )
        results[worker.id] = proof, source
    return results


def _assert_initial_staged_identity(
    registry: Registry,
    target: Profile,
    proof: dict[str, Any],
    peers: dict[str, tuple[dict[str, Any], dict[str, Any]]],
) -> None:
    fingerprint = _identity_fingerprint(proof, target)
    for profile_id, (peer_proof, _source) in peers.items():
        if _identity_fingerprint(peer_proof, registry.require_profile(profile_id)) == fingerprint:
            raise ValueError(f"staged login duplicates freshly proved worker {profile_id}")
    external_only = replace(registry, profiles={target.id: target})
    conflict = identity_conflict(
        external_only,
        target,
        proof,
        require_complete_worker_set=False,
    )
    if conflict is not None:
        raise ValueError(f"staged login conflicts with {conflict}")


def _install_codex(
    target: Profile,
    stage: Profile,
    paths: dict[str, Path],
    journal_path: Path,
    journal: dict[str, Any],
) -> None:
    _validate_stage(target, stage.home, journal)
    staged_auth = stage.home / CODEX_AUTH
    _private_file(staged_auth, "staged Codex auth")
    stable = target.home / CODEX_AUTH
    original = None
    if stable.exists() or stable.is_symlink():
        original = _private_file(stable, "stable Codex auth")
        journal["original_credential_stat"] = _stat_payload(original)
    else:
        journal["original_credential_stat"] = None
    journal["credential_kind"] = "codex-file"
    _write_journal(journal_path, journal, "credential-backup-running")
    if original is not None:
        _copy_private_file(stable, paths["codex_backup"])
    _record_stage_manifest(stage.home, journal)
    _write_journal(journal_path, journal, "credential-backup-ready")
    temporary = paths["install_temp"]
    _copy_private_file(staged_auth, temporary)
    journal["prepared_credential_stat"] = _stat_payload(
        _private_file(temporary, "prepared Codex auth")
    )
    _write_journal(journal_path, journal, "credential-prepared")
    current = _stat_payload(_private_file(stable, "stable Codex auth")) if original else None
    if current != journal["original_credential_stat"]:
        raise ValueError("stable Codex auth changed during recovery")
    os.replace(temporary, stable)
    _fsync(target.home)
    journal["installed_credential_stat"] = _stat_payload(
        _private_file(stable, "installed Codex auth")
    )
    _write_journal(journal_path, journal, "credential-installed")


def _install_claude(
    hooks: RecoveryHooks,
    registry: Registry,
    target: Profile,
    stage: Profile,
    source: dict[str, Any],
    paths: dict[str, Path],
    journal_path: Path,
    journal: dict[str, Any],
) -> None:
    _validate_stage(target, stage.home, journal)
    if sys.platform == "darwin" and source.get("kind") != "keychain":
        raise ValueError("macOS Claude recovery requires the staged scoped Keychain source")
    if source.get("kind") == "oauth-file":
        # Non-macOS Claude keeps the same durable file transaction semantics.
        staged = stage.home / CLAUDE_AUTH
        stable = target.home / CLAUDE_AUTH
        original = _private_file(stable, "stable Claude auth") if stable.exists() else None
        journal["credential_kind"] = "claude-file"
        journal["original_credential_stat"] = _stat_payload(original) if original else None
        _write_journal(journal_path, journal, "credential-backup-running")
        if original:
            _copy_private_file(stable, paths["claude_file_backup"])
        _record_stage_manifest(stage.home, journal)
        _write_journal(journal_path, journal, "credential-backup-ready")
        temporary = paths["install_temp"]
        _copy_private_file(staged, temporary)
        journal["prepared_credential_stat"] = _stat_payload(temporary.lstat())
        _write_journal(journal_path, journal, "credential-prepared")
        os.replace(temporary, stable)
        _fsync(target.home)
        journal["installed_credential_stat"] = _stat_payload(stable.lstat())
        _write_journal(journal_path, journal, "credential-installed")
        return
    if source.get("kind") != "keychain":
        raise ValueError("staged Claude login has no single scoped credential source")
    account = _keychain_account()
    staged_service = _claude_service(stage.home)
    stable_service = _claude_service(target.home)
    if (
        source.get("service") != staged_service
        or source.get("config_home") != str(stage.home)
        or source.get("account") != account
    ):
        raise ValueError("staged Claude Keychain credential is scoped to another home")
    backup_service = f"Claude Code-agent-fleet-backup-{journal['nonce']}"
    stable_source = _normalize_source_contract(
        hooks,
        target,
        hooks.inspect_source(registry, target, True),
    )
    if stable_source.get("kind") not in {"absent", "keychain", "oauth-file"}:
        raise ValueError("stable Claude worker has ambiguous credential sources")
    stable_keychain = stable_source.get("kind") == "keychain"
    stable_file = target.home / CLAUDE_AUTH
    stable_file_stat = None
    if stable_source.get("kind") == "oauth-file":
        stable_file_stat = _private_file(stable_file, "stable Claude auth file")
    journal.update(
        {
            "credential_kind": "claude-keychain",
            "keychain_account": account,
            "staged_service": staged_service,
            "stable_service": stable_service,
            "backup_service": backup_service,
            "stable_keychain_existed": stable_keychain,
            "original_credential_stat": (
                _stat_payload(stable_file_stat) if stable_file_stat else None
            ),
        }
    )
    _write_journal(journal_path, journal, "credential-backup-running")
    if stable_file_stat is not None:
        _copy_private_file(stable_file, paths["claude_file_backup"])
    if stable_keychain:
        if not hooks.keychain.exists(stable_service, account):
            raise ValueError("stable scoped Claude Keychain item disappeared")
        hooks.keychain.copy(stable_service, backup_service, account)
    _record_stage_manifest(stage.home, journal)
    _write_journal(journal_path, journal, "credential-backup-ready")
    if stable_file_stat is not None:
        if _stat_payload(_private_file(stable_file, "stable Claude auth file")) != (
            journal["original_credential_stat"]
        ):
            raise ValueError("stable Claude auth file changed during recovery")
        stable_file.unlink()
        _fsync(target.home)
    _write_journal(journal_path, journal, "credential-prepared")
    hooks.keychain.copy(staged_service, stable_service, account)
    if not hooks.keychain.exists(stable_service, account):
        raise ValueError("promoted scoped Claude Keychain item is unavailable")
    _write_journal(journal_path, journal, "credential-installed")


def _rollback_file_credential(
    target: Profile,
    stable_name: str,
    backup: Path,
    paths: dict[str, Path],
    journal: dict[str, Any],
) -> None:
    stable = target.home / stable_name
    original = journal.get("original_credential_stat")
    installed = journal.get("installed_credential_stat") or journal.get(
        "prepared_credential_stat"
    )
    current_original = _same_stat(stable, original) if original is not None else not stable.exists()
    current_installed = _same_stat(stable, installed, ctime=False) if installed else False
    if current_original:
        return
    if not current_installed:
        raise ValueError("stable credential changed outside the recovery transaction")
    if original is None:
        stable.unlink()
    else:
        _private_file(backup, "credential recovery backup")
        rollback = paths["rollback_temp"]
        if rollback.exists() or rollback.is_symlink():
            _private_file(rollback, "credential rollback temporary")
            rollback.unlink()
        _copy_private_file(backup, rollback)
        os.replace(rollback, stable)
    _fsync(target.home)


def _rollback_local_credential(
    hooks: RecoveryHooks,
    target: Profile,
    paths: dict[str, Path],
    journal: dict[str, Any],
) -> None:
    kind = journal.get("credential_kind")
    if kind == "codex-file":
        _rollback_file_credential(target, CODEX_AUTH, paths["codex_backup"], paths, journal)
    elif kind == "claude-file":
        _rollback_file_credential(
            target,
            CLAUDE_AUTH,
            paths["claude_file_backup"],
            paths,
            journal,
        )
    elif kind == "claude-keychain":
        account = str(journal.get("keychain_account", ""))
        stable_service = str(journal.get("stable_service", ""))
        backup_service = str(journal.get("backup_service", ""))
        phase = journal.get("phase")
        backup_ready = phase not in {
            "credential-backup-running",
        }
        if journal.get("stable_keychain_existed") is True:
            if backup_ready:
                if not hooks.keychain.exists(backup_service, account):
                    raise ValueError("Claude Keychain rollback generation is unavailable")
                hooks.keychain.copy(backup_service, stable_service, account)
            elif not hooks.keychain.exists(stable_service, account):
                raise ValueError("original scoped Claude Keychain item changed during backup")
        elif backup_ready:
            hooks.keychain.delete(stable_service, account, missing_ok=True)
        elif hooks.keychain.exists(stable_service, account):
            raise ValueError("stable scoped Claude Keychain item appeared during backup")
        original = journal.get("original_credential_stat")
        stable_file = target.home / CLAUDE_AUTH
        if original is not None and not _same_stat(stable_file, original):
            if stable_file.exists() or stable_file.is_symlink():
                raise ValueError("stable Claude auth file changed outside recovery")
            rollback = paths["rollback_temp"]
            _copy_private_file(paths["claude_file_backup"], rollback)
            os.replace(rollback, stable_file)
            _fsync(target.home)
        elif original is None and (stable_file.exists() or stable_file.is_symlink()):
            raise ValueError("unexpected stable Claude auth file appeared during recovery")


def _clean_exact_temporaries(paths: dict[str, Path]) -> None:
    for name in ("install_temp", "rollback_temp"):
        path = paths[name]
        if path.exists() or path.is_symlink():
            _private_file(path, "credential recovery temporary")
            path.unlink()
            _fsync(path.parent)


def _cleanup_keychain(hooks: RecoveryHooks, journal: dict[str, Any]) -> None:
    if journal.get("provider") != "claude":
        return
    account = str(journal.get("keychain_account", ""))
    for field in ("staged_service", "backup_service"):
        service = journal.get(field)
        if isinstance(service, str):
            hooks.keychain.delete(service, account, missing_ok=True)


def recover_pending_profile_recoveries(
    registry: Registry,
    provider: str,
    *,
    hooks: RecoveryHooks | None = None,
    allow_current_owner: bool = False,
) -> list[dict[str, Any]]:
    """Recover only worker transactions while the caller owns the provider lock."""

    controls = hooks or default_recovery_hooks()
    recovered: list[dict[str, Any]] = []
    # This worker-only filter happens before journal-path derivation (R2/R5).
    for target in _workers(registry, provider):
        pending = _read_journal(registry, target)
        if pending is None:
            continue
        journal_path, journal = pending
        paths = _validate_paths(registry, target, journal)
        owner_host = journal.get("owner_host")
        owner_pid = journal.get("owner_pid")
        owner_start = journal.get("owner_start")
        if owner_host != socket.gethostname():
            raise ValueError("credential recovery journal belongs to another host")
        if not isinstance(owner_pid, int) or not isinstance(owner_start, str):
            raise ValueError("credential recovery journal has invalid process ownership")
        owner_state = process_identity_state(owner_pid, owner_start)
        current_owner = owner_pid == os.getpid() and owner_start == process_start_token(os.getpid())
        if owner_state != "dead" and not (allow_current_owner and current_owner):
            raise ValueError("credential recovery transaction still has a live/unknown owner")
        child_pid = journal.get("login_pid")
        child_start = journal.get("login_start")
        if (
            isinstance(child_pid, int)
            and isinstance(child_start, str)
            and process_identity_state(child_pid, child_start) != "dead"
        ):
            raise ValueError("provider login process is still live or indeterminate")
        phase = journal.get("phase")
        committed = phase == "committed"
        if not committed:
            _rollback_local_credential(controls, target, paths, journal)
            if journal.get("bundle_snapshot_ready") is True:
                _restore_bundle(registry, paths, journal)
            if journal.get("provisional_snapshot_ready") is True:
                _restore_provisional(registry, target.provider, paths, journal)
        _clean_exact_temporaries(paths)
        _cleanup_keychain(controls, journal)
        stage = paths["stage"]
        if stage.exists() or stage.is_symlink():
            _remove_stage(target, stage, journal)
        journal_path.unlink()
        _fsync(journal_path.parent)
        recovered.append(
            {
                "profile": target.id,
                "committed": committed,
                "provider_side_revocation_possible": bool(journal.get("login_started")),
            }
        )
    return recovered


def _profile_login_transaction(
    registry: Registry,
    profile_id: str,
    config_path: Path,
    *,
    workflow: str,
    browser_login: bool = False,
    allow_keychain_prompt: bool = False,
    hooks: RecoveryHooks | None = None,
    boundary_hook: Callable[[str], None] | None = None,
) -> dict[str, Any]:
    """Run one explicitly selected disabled-worker login transaction."""

    controls = hooks or default_recovery_hooks()
    journal_path: Path | None = None
    failure_stage = "preflight"
    initial = registry.require_profile(profile_id)
    if initial.safety_policy != "worker":
        raise ValueError(
            f"profile {profile_id} is {initial.safety_policy} capacity and has no recovery path "
            "or initialization login path"
        )
    if initial.provider == "claude" and not browser_login:
        raise ValueError(
            "Claude profile login can open a browser and requires the explicit --browser flag; "
            "use a private browser context without changing Desktop login state"
        )
    if initial.provider == "claude" and sys.platform == "darwin" and not allow_keychain_prompt:
        raise ValueError(
            "macOS Claude profile login requires explicit --allow-keychain-prompt for exact scoped "
            "backup, promotion, and verification"
        )
    try:
        lock = provider_enrollment_lock(
            registry.settings.state_dir,
            initial.provider,
            registry.settings.lock_stale_seconds,
            timeout=0.1,
        )
        lock.acquire()
        try:
            current, target = _recheck(registry, config_path, profile_id, "start")
            recover_pending_codex_transactions(current, target.provider)
            prior = recover_pending_profile_recoveries(current, target.provider, hooks=controls)
            current, target = _recheck(current, config_path, profile_id, "intent")
            observed_batch = _assert_workflow_state(current, target.provider, workflow)
            persisted_batch = observed_batch
            working_batch = (
                observed_batch
                if observed_batch is not None
                else _new_provisional_batch(current, target.provider)
                if workflow == "initialize"
                else None
            )
            if (
                workflow == "initialize"
                and working_batch is not None
                and target.id in working_batch["workers"]
            ):
                pending = sorted(
                    set(working_batch["expected_workers"])
                    - set(working_batch["workers"])
                )
                raise ValueError(
                    f"worker {target.id} is already recorded in the provisional identity batch; "
                    "initialize a pending worker instead: " + ", ".join(pending)
                )

            def checked(
                expected: Registry,
                boundary: str,
                *,
                initialization_complete: bool = False,
            ) -> tuple[Registry, Profile]:
                nonlocal persisted_batch
                checked_registry, checked_target = _recheck(
                    expected,
                    config_path,
                    profile_id,
                    boundary,
                )
                current_batch = _assert_workflow_state(
                    checked_registry,
                    checked_target.provider,
                    workflow,
                    initialization_complete=initialization_complete,
                )
                if (
                    workflow == "initialize"
                    and not initialization_complete
                    and current_batch != persisted_batch
                ):
                    raise ValueError(
                        "provider provisional identity batch changed during initialization"
                    )
                return checked_registry, checked_target

            if workflow == "initialize":
                assert working_batch is not None
                # Reprove every durable peer before invoking another provider
                # login. Tamper, drift, or ejection must not consume/revoke a
                # second worker credential before the batch fails closed.
                _initialization_peer_proofs(
                    current,
                    target,
                    working_batch,
                    controls,
                    allow_keychain_prompt,
                )
            _preflight_stable_credential(target)
            controls.inspect_source(current, target, allow_keychain_prompt)
            journal_path = _journal_path_for_worker(current, target)
            ensure_private_dir(journal_path.parent)
            if journal_path.exists() or journal_path.is_symlink():
                raise ValueError("unfinished credential recovery requires recovery first")
            nonce = uuid.uuid4().hex
            owner_start = process_start_token(os.getpid())
            if owner_start is None:
                raise ValueError("cannot establish credential recovery process identity")
            journal: dict[str, Any] = {
                "schema": RECOVERY_SCHEMA,
                "kind": "credential-recovery",
                "profile": target.id,
                "provider": target.provider,
                "workflow": workflow,
                "stable_home": str(target.home),
                "config": str(config_path),
                "nonce": nonce,
                "owner_pid": os.getpid(),
                "owner_start": owner_start,
                "owner_host": socket.gethostname(),
                "journal": str(journal_path),
                "paths": _transaction_paths(current, target, nonce),
                "login_started": False,
            }
            if target.provider == "claude":
                stage_home = Path(journal["paths"]["stage"])
                journal.update(
                    {
                        "keychain_account": _keychain_account(),
                        "staged_service": _claude_service(stage_home),
                        "stable_service": _claude_service(target.home),
                        "backup_service": f"Claude Code-agent-fleet-backup-{nonce}",
                    }
                )
            # Durable ownership and artifact paths precede stage creation and
            # therefore every possible credential-bearing provider write.
            _write_journal(journal_path, journal, "intent")
            stage = _prepare_stage(current, target, journal_path, journal)
            if boundary_hook:
                boundary_hook("stage-ready")
            current, target = checked(current, "login")
            failure_stage = "provider_login"
            stage = replace(target, home=stage.home, enabled=False)
            binary = verified_provider_binary(current, target)
            argv = login_argv(
                current,
                stage,
                binary=binary,
                browser_login=browser_login,
            )

            def child_started(pid: int, start: str) -> None:
                journal.update(
                    {
                        "login_started": True,
                        "login_pid": pid,
                        "login_start": start,
                    }
                )
                _write_journal(journal_path, journal, "login-running")

            status = controls.login(argv, _login_environment(stage), stage.home, child_started)
            journal.pop("login_pid", None)
            journal.pop("login_start", None)
            _write_journal(journal_path, journal, "login-finished")
            if status != 0:
                raise ValueError("provider login did not complete successfully")
            _validate_stage(target, stage.home, journal)
            _record_stage_manifest(stage.home, journal)
            _write_journal(journal_path, journal, "login-complete")
            if boundary_hook:
                boundary_hook("login-complete")
            current, target = checked(current, "staged verification")
            failure_stage = "staged_identity_verification"
            stage = replace(target, home=stage.home, enabled=False)
            controls.refresh_anchors(current, target.provider, allow_keychain_prompt)
            peer_proofs: dict[str, tuple[dict[str, Any], dict[str, Any]]] = {}
            if workflow == "initialize":
                assert working_batch is not None
                peer_proofs = _initialization_peer_proofs(
                    current,
                    target,
                    working_batch,
                    controls,
                    allow_keychain_prompt,
                )
            _write_journal(journal_path, journal, "stage-proof-running")
            staged_proof, raw_staged_source = controls.prove(
                current,
                stage,
                allow_keychain_prompt,
            )
            staged_source = _normalize_source_contract(
                controls,
                stage,
                raw_staged_source,
            )
            if workflow == "recover":
                _assert_staged_identity(current, target, staged_proof)
            else:
                _assert_initial_staged_identity(
                    current,
                    target,
                    staged_proof,
                    peer_proofs,
                )
            journal["staged_identity_fingerprint"] = _identity_fingerprint(
                staged_proof,
                target,
            )
            journal["staged_source_kind"] = staged_source.get("kind")
            _record_stage_manifest(stage.home, journal)
            _write_journal(journal_path, journal, "stage-verified")
            if boundary_hook:
                boundary_hook("stage-verified")
            current, target = checked(current, "promotion")
            failure_stage = "local_credential_promotion"
            paths = _validate_paths(current, target, journal)
            if target.provider == "codex":
                _install_codex(target, stage, paths, journal_path, journal)
            else:
                _install_claude(
                    controls,
                    current,
                    target,
                    stage,
                    staged_source,
                    paths,
                    journal_path,
                    journal,
                )
            if boundary_hook:
                boundary_hook("credential-installed")
            current, target = checked(current, "final verification")
            failure_stage = "provider_worker_set_verification"
            proofs: dict[str, tuple[dict[str, Any], dict[str, Any]]] = {}
            blockers: dict[str, str] = {}
            controls.refresh_anchors(current, target.provider, allow_keychain_prompt)
            for worker in _workers(current, target.provider):
                try:
                    proof, raw_source = controls.prove(
                        current,
                        worker,
                        allow_keychain_prompt,
                    )
                    source = _normalize_source_contract(controls, worker, raw_source)
                    proofs[worker.id] = proof, source
                except (OSError, TimeoutError, ValueError) as exc:
                    blockers[worker.id] = type(exc).__name__
            if target.id in blockers:
                raise ValueError("promoted worker failed fresh stable credential verification")
            if (
                _identity_fingerprint(proofs[target.id][0], target)
                != journal["staged_identity_fingerprint"]
            ):
                raise ValueError("promoted worker identity differs from the staged login")
            fingerprints: dict[str, str] = {}
            for worker in _workers(current, target.provider):
                if worker.id not in proofs:
                    continue
                fingerprint = _identity_fingerprint(proofs[worker.id][0], worker)
                if fingerprint in fingerprints:
                    raise ValueError(
                        f"fresh worker proof set contains a duplicate: "
                        f"{fingerprints[fingerprint]}, {worker.id}"
                    )
                fingerprints[fingerprint] = worker.id
            updated_batch: dict[str, Any] | None = None
            pending_initialization: list[str] = []
            if workflow == "initialize":
                assert working_batch is not None
                for recorded_id, record in working_batch["workers"].items():
                    if recorded_id == target.id:
                        continue
                    if recorded_id not in proofs:
                        raise ValueError(
                            f"recorded provisional worker lost fresh proof: {recorded_id}"
                        )
                    worker = current.require_profile(recorded_id)
                    observed_record = _provisional_record(
                        controls,
                        worker,
                        proofs[recorded_id][0],
                        proofs[recorded_id][1],
                        str(record["transaction_generation"]),
                    )
                    if observed_record != record:
                        raise ValueError(
                            f"recorded provisional worker changed before commit: {recorded_id}"
                        )
                updated_batch = json.loads(json.dumps(working_batch))
                updated_batch["workers"][target.id] = _provisional_record(
                    controls,
                    target,
                    proofs[target.id][0],
                    proofs[target.id][1],
                    nonce,
                )
                pending_initialization = sorted(
                    set(updated_batch["expected_workers"]) - set(updated_batch["workers"])
                )
                ready = (
                    not blockers
                    and not pending_initialization
                    and len(proofs) == len(_workers(current, target.provider))
                )
            else:
                ready = not blockers and len(proofs) == len(
                    _workers(current, target.provider)
                )
            if boundary_hook:
                boundary_hook("final-verified")
            current, target = checked(current, "commit")
            failure_stage = "identity_binding_commit"
            if workflow == "initialize":
                assert updated_batch is not None
                _validate_stage(target, stage.home, journal)
                _write_journal(journal_path, journal, "provisional-backup-running")
                _snapshot_provisional(
                    current,
                    target.provider,
                    paths,
                    journal,
                )
                journal["provisional_snapshot_ready"] = True
                _record_stage_manifest(stage.home, journal)
                _write_journal(journal_path, journal, "provisional-backup-ready")
                atomic_write_json(
                    _provisional_path(current, target.provider),
                    updated_batch,
                )
                atomic_write_json(
                    _provisional_guard_path(current, target.provider),
                    _provisional_guard_payload(current, target.provider, updated_batch),
                )
                persisted_batch = updated_batch
                _write_journal(journal_path, journal, "provisional-installed")
            if ready:
                _validate_stage(target, stage.home, journal)
                _write_journal(journal_path, journal, "bundle-backup-running")
                _snapshot_bundle(current, paths, journal)
                journal["bundle_snapshot_ready"] = True
                _record_stage_manifest(stage.home, journal)
                _write_journal(journal_path, journal, "bundle-backup-ready")
                controls.adopt_bundle(
                    current,
                    target.provider,
                    proofs,
                    allow_keychain_prompt,
                )
                _write_journal(journal_path, journal, "binding-installed")
                if workflow == "initialize":
                    provisional_path = _provisional_path(current, target.provider)
                    provisional_guard = _provisional_guard_path(current, target.provider)
                    _private_file(
                        provisional_path,
                        "completed provider provisional identity batch",
                    )
                    _private_file(
                        provisional_guard,
                        "completed provider initialization locator",
                    )
                    provisional_path.unlink()
                    _fsync(provisional_path.parent)
                    provisional_guard.unlink()
                    _fsync(provisional_guard.parent)
                    persisted_batch = None
                    _write_journal(journal_path, journal, "provisional-removed")
            _write_journal(journal_path, journal, "committed")
            failure_stage = "quota_cache_commit"
            for worker in _workers(current, target.provider):
                if worker.id in proofs:
                    store_quota(current, worker, proofs[worker.id][0])
            if boundary_hook:
                boundary_hook("committed")
            current, target = checked(
                current,
                "cleanup",
                initialization_complete=workflow == "initialize" and ready,
            )
            failure_stage = "transaction_cleanup"
            _clean_exact_temporaries(paths)
            _cleanup_keychain(controls, journal)
            _remove_stage(target, paths["stage"], journal)
            journal_path.unlink()
            _fsync(journal_path.parent)
            append_audit(
                current,
                (
                    "profile-credential-initialized"
                    if workflow == "initialize"
                    else "profile-credential-recovered"
                ),
                {
                    "profile": target.id,
                    "provider": target.provider,
                    "provider_ready": ready,
                    "blocked_profiles": sorted(blockers),
                    "pending_initialization": pending_initialization,
                    "enabled": False,
                },
            )
            return {
                "profile": target.id,
                "provider": target.provider,
                "credential_recovered": workflow == "recover",
                "credential_initialized": workflow == "initialize",
                "workflow": f"{workflow}-login",
                "provider_ready": ready,
                "blocked_profiles": sorted(blockers),
                "pending_initialization": pending_initialization,
                "provisional_workers": (
                    sorted(updated_batch["workers"])
                    if workflow == "initialize" and not ready and updated_batch is not None
                    else []
                ),
                "enabled": False,
                "provider_login_invoked": True,
                "browser_mode": browser_login,
                "recovered_prior_transactions": prior,
                "provider_side_revocation_possible": True,
                "provider_side_revocation_locally_reversible": False,
                "next_step": (
                    "run the existing explicit profile enable gate for each worker"
                    if ready
                    else (
                        "initialize every pending provider worker before any enable"
                        if workflow == "initialize"
                        else "recover or verify every blocked provider worker before any enable"
                    )
                ),
            }
        except BaseException as failure:
            # Ordinary errors are not crashes: restore local credential state
            # and remove exact transaction artifacts before maintenance unlocks.
            # SIGKILL cannot execute this branch; its durable journal is handled
            # by recover_pending_profile_recoveries on the next invocation.
            if journal_path is None or not journal_path.exists():
                raise
            pending = _read_journal(registry, initial)
            revocation_possible = bool(pending and pending[1].get("login_started"))
            rollback_complete = True
            try:
                recover_pending_profile_recoveries(
                    registry,
                    initial.provider,
                    hooks=controls,
                    allow_current_owner=True,
                )
            except BaseException:
                rollback_complete = False
            append_audit(
                registry,
                "profile-credential-login-failed",
                {
                    "profile": initial.id,
                    "provider": initial.provider,
                    "workflow": workflow,
                    "failure_stage": failure_stage,
                    "failure_class": type(failure).__name__,
                    "provider_side_revocation_possible": revocation_possible,
                    "provider_side_revocation_locally_reversible": False,
                    "local_rollback_complete": rollback_complete,
                    "enabled": False,
                },
            )
            status = "complete" if rollback_complete else "incomplete_fail_closed"
            workflow_label = (
                "credential initialization failed"
                if workflow == "initialize"
                else "credential recovery failed"
            )
            raise ValueError(
                f"{workflow_label}; "
                f"failure_stage={failure_stage}; local_rollback={status}; "
                f"provider_side_revocation_possible={str(revocation_possible).lower()}; "
                "provider-side token changes are locally non-reversible; keep every provider "
                "worker disabled and recover/verify the worker set before enable"
            ) from None
        finally:
            lock.release()
    except TimeoutError as exc:
        raise ValueError(
            f"another {initial.provider} maintenance or Fleet selection is in progress"
        ) from exc


def recover_profile_login(
    registry: Registry,
    profile_id: str,
    config_path: Path,
    *,
    browser_login: bool = False,
    allow_keychain_prompt: bool = False,
    hooks: RecoveryHooks | None = None,
    boundary_hook: Callable[[str], None] | None = None,
) -> dict[str, Any]:
    return _profile_login_transaction(
        registry,
        profile_id,
        config_path,
        workflow="recover",
        browser_login=browser_login,
        allow_keychain_prompt=allow_keychain_prompt,
        hooks=hooks,
        boundary_hook=boundary_hook,
    )


def initialize_profile_login(
    registry: Registry,
    profile_id: str,
    config_path: Path,
    *,
    browser_login: bool = False,
    allow_keychain_prompt: bool = False,
    hooks: RecoveryHooks | None = None,
    boundary_hook: Callable[[str], None] | None = None,
) -> dict[str, Any]:
    return _profile_login_transaction(
        registry,
        profile_id,
        config_path,
        workflow="initialize",
        browser_login=browser_login,
        allow_keychain_prompt=allow_keychain_prompt,
        hooks=hooks,
        boundary_hook=boundary_hook,
    )
