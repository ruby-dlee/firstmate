from __future__ import annotations

import json
import os
import pwd
import re
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
    build_provider_identity_bundle,
    identity_binding_conflict,
    identity_bundle_path,
    identity_conflict,
    install_provider_identity_bundle,
    read_identity_binding,
    refresh_provider_identity_anchors,
)
from .leases import active_leases
from .locks import provider_enrollment_lock, state_lock
from .models import Profile, Registry
from .paths import current_user_home, ensure_private_dir, open_private_dir
from .providers import CONTROL_PATH, login_argv
from .provision import PROVIDER_BINARY_MARKER_FILE, profile_is_provisioned, verified_provider_binary
from .quota import (
    has_remote_identity_proof,
    inspect_credential_source_contract,
    probe_quota,
    store_quota,
)
from .sessions import get_session, session_path
from .transaction_fence import pending_credential_recovery_journals
from .util import (
    atomic_write_bytes,
    atomic_write_json,
    process_identity_state,
    process_start_token,
    read_private_bytes,
    read_private_json,
    rename_private_noreplace,
    utc_now,
)

RECOVERY_SCHEMA = 1
INITIALIZATION_CONTRACT_VERSION = 1
MAX_PARTIAL_RETIREMENTS = 8
RECOVERY_MARKER = ".agent-fleet-recovery-stage.json"
CODEX_AUTH = "auth.json"
CLAUDE_AUTH = ".credentials.json"
CLAUDE_KEYCHAIN_SERVICE = re.compile(
    r"(?:Claude Code-credentials-[0-9a-f]{8}|Claude Code-agent-fleet-backup-[0-9a-f]{32})"
)


class _BundlePlanValidated(Exception):
    """Internal fence proving bundle validation reached the mutation boundary."""


class KeychainControl(Protocol):
    def exists(self, service: str, account: str) -> bool: ...

    def copy(self, source: str, destination: str, account: str) -> None: ...

    def delete(self, service: str, account: str, *, missing_ok: bool = False) -> None: ...


class SecurityKeychain:
    """Exact-account macOS Keychain operations without secret-bearing argv or buffers."""

    binary = Path("/usr/bin/security")

    def _verified_binary(self) -> Path:
        try:
            metadata = self.binary.lstat()
        except OSError as exc:
            raise ValueError("macOS Keychain control is unavailable") from exc
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != 0
            or stat.S_IMODE(metadata.st_mode) & 0o022
            or not os.access(self.binary, os.X_OK)
        ):
            raise ValueError("macOS Keychain control is unsafe")
        return self.binary

    def _execution_context(
        self, account: str
    ) -> tuple[Path, str, Path, dict[str, str]]:
        binary = self._verified_binary()
        home = current_user_home()
        environment = {
            "HOME": str(home),
            "USER": account,
            "LOGNAME": account,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "C",
            "LANG": "C",
            "NO_COLOR": "1",
            "TERM": "dumb",
        }
        return binary, account, home, environment

    @staticmethod
    def _validate_scope(service: str, account: str, expected_account: str) -> None:
        if (
            CLAUDE_KEYCHAIN_SERVICE.fullmatch(service) is None
            or not account
            or account != expected_account
        ):
            raise ValueError("refusing an unscoped Claude Keychain operation")

    @staticmethod
    def _prefix(
        binary: Path,
        operation: str,
        service: str,
        account: str,
        expected_account: str,
    ) -> list[str]:
        SecurityKeychain._validate_scope(service, account, expected_account)
        return [str(binary), operation, "-s", service, "-a", account]

    def exists(self, service: str, account: str) -> bool:
        expected_account = _keychain_account()
        self._validate_scope(service, account, expected_account)
        binary, expected_account, home, environment = self._execution_context(
            expected_account
        )
        result = subprocess.run(
            self._prefix(
                binary,
                "find-generic-password",
                service,
                account,
                expected_account,
            ),
            env=environment,
            cwd=home,
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
        expected_account = _keychain_account()
        self._validate_scope(source, account, expected_account)
        self._validate_scope(destination, account, expected_account)
        binary, expected_account, home, environment = self._execution_context(
            expected_account
        )
        reader = subprocess.Popen(
            [
                *self._prefix(
                    binary,
                    "find-generic-password",
                    source,
                    account,
                    expected_account,
                ),
                "-w",
            ],
            env=environment,
            cwd=home,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        assert reader.stdout is not None
        try:
            writer = subprocess.Popen(
                [
                    *self._prefix(
                        binary,
                        "add-generic-password",
                        destination,
                        account,
                        expected_account,
                    ),
                    "-U",
                    "-w",
                ],
                env=environment,
                cwd=home,
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
        expected_account = _keychain_account()
        self._validate_scope(service, account, expected_account)
        binary, expected_account, home, environment = self._execution_context(
            expected_account
        )
        result = subprocess.run(
            self._prefix(
                binary,
                "delete-generic-password",
                service,
                account,
                expected_account,
            ),
            env=environment,
            cwd=home,
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

    login: Callable[[list[str], dict[str, str], Path, Callable[[int, str, int], None]], int]
    inspect_source: Callable[[Registry, Profile, bool], dict[str, Any]]
    prove: Callable[[Registry, Profile, bool], tuple[dict[str, Any], dict[str, Any]]]
    refresh_anchors: Callable[[Registry, str, bool], None]
    install_bundle: Callable[
        [
            Registry,
            str,
            dict[str, Any],
            Callable[[], None] | None,
        ],
        dict[str, Any],
    ]
    keychain: KeychainControl


def _system_login(
    argv: list[str],
    environment: dict[str, str],
    cwd: Path,
    record_child: Callable[[int, str, int], None],
) -> int:
    """Fork a gated child so its durable PID record precedes provider exec."""

    read_fd, write_fd = os.pipe()
    pid = os.fork()
    if pid == 0:  # pragma: no cover - integration-only child
        try:
            os.close(write_fd)
            os.setsid()
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
        record_child(pid, start, pid)
        os.write(write_fd, b"1")
    except BaseException:
        with suppress(ProcessLookupError):
            os.kill(pid, signal.SIGTERM)
        os.waitpid(pid, 0)
        raise
    finally:
        os.close(write_fd)
    _, status = os.waitpid(pid, 0)
    if _process_group_state(pid) != "dead":
        raise ValueError("provider login descendants remain live or indeterminate")
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


def _install_bundle(
    registry: Registry,
    provider: str,
    payload: dict[str, Any],
    before_install: Callable[[], None] | None = None,
) -> dict[str, Any]:
    return install_provider_identity_bundle(
        registry,
        provider,
        payload,
        before_install=before_install,
    )


def default_recovery_hooks() -> RecoveryHooks:
    return RecoveryHooks(
        login=_system_login,
        inspect_source=_inspect_source,
        prove=_prove,
        refresh_anchors=_refresh,
        install_bundle=_install_bundle,
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


def _inode_payload(metadata: os.stat_result) -> dict[str, int]:
    return {
        "dev": metadata.st_dev,
        "ino": metadata.st_ino,
        "uid": metadata.st_uid,
        "mode": stat.S_IMODE(metadata.st_mode),
        "nlink": metadata.st_nlink,
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


def _stat_matches_generation(
    observed: dict[str, int],
    encoded: object,
    *,
    ctime: bool,
) -> bool:
    if not isinstance(encoded, dict):
        return False
    fields = set(observed) if ctime else set(observed) - {"ctime_ns"}
    return all(encoded.get(field) == observed[field] for field in fields)


def _stat_matches_inode(observed: dict[str, int], encoded: object) -> bool:
    if not isinstance(encoded, dict):
        return False
    fields = {"dev", "ino", "uid", "mode", "nlink"}
    return all(encoded.get(field) == observed[field] for field in fields)


def _valid_inode_payload(encoded: object) -> bool:
    fields = {"dev", "ino", "uid", "mode", "nlink"}
    return (
        isinstance(encoded, dict)
        and set(encoded) == fields
        and all(isinstance(encoded[field], int) for field in fields)
    )


def _file_generation(path: Path, label: str) -> dict[str, Any]:
    before = _private_file(path, label)
    payload = read_private_bytes(path, label=label)
    after = _private_file(path, label)
    if _stat_payload(before) != _stat_payload(after):
        raise ValueError(f"{label} changed while its generation was read")
    return {
        "stat": _stat_payload(after),
        "sha256": sha256(payload).hexdigest(),
    }


def _same_file_generation(path: Path, encoded: object) -> bool:
    if not isinstance(encoded, dict):
        return False
    expected_stat = encoded.get("stat")
    expected_digest = encoded.get("sha256")
    if not isinstance(expected_digest, str) or len(expected_digest) != 64:
        return False
    try:
        observed = _file_generation(path, "credential transaction generation")
    except (FileNotFoundError, ValueError):
        return False
    if observed["sha256"] != expected_digest or not isinstance(expected_stat, dict):
        return False
    fields = set(observed["stat"]) - {"ctime_ns"}
    return all(expected_stat.get(field) == observed["stat"][field] for field in fields)


def _json_payload_sha256(payload: dict[str, Any]) -> str:
    encoded = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode()
    return sha256(encoded).hexdigest()


def _same_directory_identity(path: Path, encoded: object) -> bool:
    if not isinstance(encoded, dict):
        return False
    try:
        observed = _stat_payload(_private_directory(path, "credential recovery stage"))
    except (FileNotFoundError, ValueError):
        return False
    return all(encoded.get(field) == observed[field] for field in ("dev", "ino", "uid", "mode"))


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


def _write_recovery_journal(
    path: Path,
    journal: dict[str, Any],
    recovery_phase: str,
) -> None:
    """Durably advance cleanup without destroying the forward transaction phase."""

    journal["recovery_phase"] = recovery_phase
    atomic_write_json(path, journal)


class _JournaledKeychain:
    """Run macOS Keychain operations behind a durably tracked gated helper."""

    def __init__(
        self,
        delegate: SecurityKeychain,
        journal_path: Path,
        journal: dict[str, Any],
    ) -> None:
        self.delegate = delegate
        self.journal_path = journal_path
        self.journal = journal

    def _run(
        self,
        operation: str,
        source: str,
        account: str,
        *,
        destination: str | None = None,
        missing_ok: bool = False,
    ) -> bool:
        gate_read, gate_write = os.pipe()
        result_read, result_write = os.pipe()
        pid = os.fork()
        if pid == 0:  # pragma: no cover - exercised through kill/restart tests
            try:
                os.close(gate_write)
                os.close(result_read)
                os.setsid()
                if os.read(gate_read, 1) != b"1":
                    os._exit(126)
                os.close(gate_read)
                if operation == "exists":
                    observed = self.delegate.exists(source, account)
                    os.write(result_write, b"1" if observed else b"0")
                elif operation == "copy" and destination is not None:
                    self.delegate.copy(source, destination, account)
                    os.write(result_write, b"1")
                elif operation == "delete":
                    self.delegate.delete(source, account, missing_ok=missing_ok)
                    os.write(result_write, b"1")
                else:
                    os._exit(64)
                os.close(result_write)
                os._exit(0)
            except BaseException:
                os._exit(70)

        os.close(gate_read)
        os.close(result_write)
        gate_open = True
        try:
            start = process_start_token(pid)
            if start is None:
                raise ValueError("could not establish Keychain helper process identity")
            sequence = int(self.journal.get("keychain_operation_sequence", 0)) + 1
            self.journal["keychain_operation_sequence"] = sequence
            self.journal["keychain_operation"] = {
                "pid": pid,
                "start": start,
                "pgid": pid,
                "operation": operation,
                "sequence": sequence,
            }
            _write_recovery_journal(
                self.journal_path,
                self.journal,
                "keychain-operation-gated",
            )
            os.write(gate_write, b"1")
            os.close(gate_write)
            gate_open = False
            result = bytearray()
            while chunk := os.read(result_read, 64):
                result.extend(chunk)
            _, status = os.waitpid(pid, 0)
            self.journal.pop("keychain_operation", None)
            _write_recovery_journal(
                self.journal_path,
                self.journal,
                "keychain-operation-finished",
            )
            if os.waitstatus_to_exitcode(status) != 0:
                raise ValueError("scoped Claude Keychain helper failed")
            return bytes(result) == b"1"
        except BaseException:
            if gate_open:
                os.close(gate_write)
                gate_open = False
                with suppress(ChildProcessError):
                    os.waitpid(pid, 0)
            raise
        finally:
            if gate_open:
                os.close(gate_write)
            os.close(result_read)

    def exists(self, service: str, account: str) -> bool:
        return self._run("exists", service, account)

    def copy(self, source: str, destination: str, account: str) -> None:
        if not self._run("copy", source, account, destination=destination):
            raise ValueError("scoped Claude Keychain copy returned no completion proof")

    def delete(self, service: str, account: str, *, missing_ok: bool = False) -> None:
        if not self._run("delete", service, account, missing_ok=missing_ok):
            raise ValueError("scoped Claude Keychain deletion returned no completion proof")


def _transactional_keychain(
    control: KeychainControl,
    journal_path: Path,
    journal: dict[str, Any],
) -> KeychainControl:
    if isinstance(control, _JournaledKeychain):
        control = control.delegate
    if isinstance(control, SecurityKeychain):
        return _JournaledKeychain(control, journal_path, journal)
    return control


def _process_group_state(pgid: int) -> str:
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return "dead"
    except PermissionError:
        return "indeterminate"
    return "live"


def _ensure_keychain_operation_quiescent(
    journal_path: Path,
    journal: dict[str, Any],
) -> None:
    operation = journal.get("keychain_operation")
    if operation is None:
        return
    if not isinstance(operation, dict):
        raise ValueError("credential recovery journal has invalid Keychain operation state")
    pid = operation.get("pid")
    start = operation.get("start")
    pgid = operation.get("pgid")
    if not isinstance(pid, int) or not isinstance(start, str) or pgid != pid:
        raise ValueError("credential recovery journal has invalid Keychain helper identity")
    helper_state = process_identity_state(pid, start)
    group_state = _process_group_state(pid)
    if helper_state != "dead" or group_state != "dead":
        raise ValueError("scoped Claude Keychain operation is still live or indeterminate")
    journal.pop("keychain_operation", None)
    _write_recovery_journal(
        journal_path,
        journal,
        "keychain-operation-quiesced",
    )


def _ensure_login_operation_quiescent(
    journal_path: Path,
    journal: dict[str, Any],
) -> None:
    pid = journal.get("login_pid")
    start = journal.get("login_start")
    pgid = journal.get("login_pgid")
    present = (pid is not None, start is not None, pgid is not None)
    if present == (False, False, False):
        return
    if (
        present != (True, True, True)
        or not isinstance(pid, int)
        or not isinstance(start, str)
        or pgid != pid
    ):
        raise ValueError("credential recovery journal has invalid provider login ownership")
    if process_identity_state(pid, start) != "dead" or _process_group_state(pgid) != "dead":
        raise ValueError("provider login process group is still live or indeterminate")
    journal.pop("login_pid", None)
    journal.pop("login_start", None)
    journal.pop("login_pgid", None)
    _write_recovery_journal(journal_path, journal, "provider-login-quiesced")


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
    retirement = (
        registry.settings.state_dir
        / "retired"
        / "credential-recovery"
        / f"{profile.provider}-{profile.id}-{nonce}"
    )
    paths = {
        "stage": str(stage),
        "quarantine": str(stage.with_name(f".{stage.name}.cleanup-{nonce}")),
        "retirement": str(retirement),
        "codex_backup": str(stage / ".stable-auth.backup"),
        "claude_file_backup": str(stage / ".stable-claude-auth.backup"),
        "bundle_backup": str(stage / ".identity-bundle.backup"),
        "provisional_backup": str(stage / ".provisional-batch.backup"),
        "provisional_guard_backup": str(stage / ".provisional-guard.backup"),
        "install_temp": str(profile.home / f".agent-fleet-recovery-{nonce}.new"),
        "rollback_temp": str(profile.home / f".agent-fleet-recovery-{nonce}.rollback"),
        "credential_quarantine": str(profile.home / f".agent-fleet-recovery-{nonce}.quarantine"),
        "credential_original_quarantine": str(
            profile.home / f".agent-fleet-recovery-{nonce}.original"
        ),
        "bundle_restore_temp": str(
            identity_bundle_path(registry, profile.provider).with_name(
                f".{identity_bundle_path(registry, profile.provider).name}.rollback-{nonce}"
            )
        ),
        "provisional_restore_temp": str(
            _provisional_path(registry, profile.provider).with_name(
                f".{_provisional_path(registry, profile.provider).name}.rollback-{nonce}"
            )
        ),
        "provisional_guard_restore_temp": str(
            _provisional_guard_path(registry, profile.provider).with_name(
                f".{_provisional_guard_path(registry, profile.provider).name}.rollback-{nonce}"
            )
        ),
        "bundle_install_temp": str(
            identity_bundle_path(registry, profile.provider).with_name(
                f".{identity_bundle_path(registry, profile.provider).name}.install-{nonce}"
            )
        ),
        "provisional_install_temp": str(
            _provisional_path(registry, profile.provider).with_name(
                f".{_provisional_path(registry, profile.provider).name}.install-{nonce}"
            )
        ),
        "provisional_guard_install_temp": str(
            _provisional_guard_path(registry, profile.provider).with_name(
                f".{_provisional_guard_path(registry, profile.provider).name}.install-{nonce}"
            )
        ),
        "bundle_original_quarantine": str(
            identity_bundle_path(registry, profile.provider).with_name(
                f".{identity_bundle_path(registry, profile.provider).name}.original-{nonce}"
            )
        ),
        "provisional_original_quarantine": str(
            _provisional_path(registry, profile.provider).with_name(
                f".{_provisional_path(registry, profile.provider).name}.original-{nonce}"
            )
        ),
        "provisional_guard_original_quarantine": str(
            _provisional_guard_path(registry, profile.provider).with_name(
                f".{_provisional_guard_path(registry, profile.provider).name}.original-{nonce}"
            )
        ),
        "bundle_restore_quarantine": str(
            identity_bundle_path(registry, profile.provider).with_name(
                f".{identity_bundle_path(registry, profile.provider).name}.forward-{nonce}"
            )
        ),
        "provisional_restore_quarantine": str(
            _provisional_path(registry, profile.provider).with_name(
                f".{_provisional_path(registry, profile.provider).name}.forward-{nonce}"
            )
        ),
        "provisional_guard_restore_quarantine": str(
            _provisional_guard_path(registry, profile.provider).with_name(
                f".{_provisional_guard_path(registry, profile.provider).name}.forward-{nonce}"
            )
        ),
    }
    for name in (
        "codex_backup",
        "claude_file_backup",
        "bundle_backup",
        "provisional_backup",
        "provisional_guard_backup",
        "install_temp",
        "rollback_temp",
        "bundle_install_temp",
        "provisional_install_temp",
        "provisional_guard_install_temp",
        "bundle_original_quarantine",
        "provisional_original_quarantine",
        "provisional_guard_original_quarantine",
        "credential_quarantine",
        "credential_original_quarantine",
        "bundle_restore_temp",
        "provisional_restore_temp",
        "provisional_guard_restore_temp",
        "bundle_restore_quarantine",
        "provisional_restore_quarantine",
        "provisional_guard_restore_quarantine",
    ):
        paths[f"{name}_cleanup"] = str(retirement / f"{name}.retired")
    return paths


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


def _copy_private_file(
    source: Path,
    destination: Path,
    *,
    destination_created: Callable[[os.stat_result], None] | None = None,
    expected_source_generation: object | None = None,
) -> os.stat_result:
    source_before = _private_file(source, "credential transaction source")
    source_fd = os.open(source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    destination_fd = -1
    try:
        opened_source = _stat_payload(os.fstat(source_fd))
        if opened_source != _stat_payload(source_before):
            raise ValueError("credential transaction source changed while opening")
        if expected_source_generation is not None and not (
            isinstance(expected_source_generation, dict)
            and set(expected_source_generation) == {"stat", "sha256"}
            and isinstance(expected_source_generation.get("sha256"), str)
            and len(expected_source_generation["sha256"]) == 64
            and _stat_matches_generation(
                opened_source,
                expected_source_generation.get("stat"),
                ctime=True,
            )
        ):
            raise ValueError("credential transaction source changed from its bound generation")
        destination_fd = os.open(
            destination,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        os.fchmod(destination_fd, 0o600)
        if destination_created is not None:
            destination_created(os.fstat(destination_fd))
        source_digest = sha256()
        while chunk := os.read(source_fd, 1024 * 1024):
            source_digest.update(chunk)
            view = memoryview(chunk)
            while view:
                view = view[os.write(destination_fd, view) :]
        if _stat_payload(os.fstat(source_fd)) != opened_source:
            raise ValueError("credential transaction source changed while copying")
        if expected_source_generation is not None and (
            source_digest.hexdigest() != expected_source_generation.get("sha256")
        ):
            raise ValueError("credential transaction source content changed while copying")
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


def _generation_matches(
    observed: dict[str, Any],
    expected: object,
    *,
    ctime: bool,
) -> bool:
    """Match either a full content generation or an owned in-progress inode."""

    if not isinstance(expected, dict):
        return False
    if set(expected) == {"stat", "sha256"}:
        expected_stat = expected.get("stat")
        expected_digest = expected.get("sha256")
        return (
            isinstance(expected_digest, str)
            and observed.get("sha256") == expected_digest
            and isinstance(observed.get("stat"), dict)
            and _stat_matches_generation(
                observed["stat"],
                expected_stat,
                ctime=ctime,
            )
        )
    return isinstance(observed.get("stat"), dict) and _stat_matches_inode(
        observed["stat"],
        expected,
    )


def _read_fd_generation(descriptor: int) -> dict[str, Any]:
    before = os.fstat(descriptor)
    os.lseek(descriptor, 0, os.SEEK_SET)
    digest = sha256()
    while chunk := os.read(descriptor, 1024 * 1024):
        digest.update(chunk)
    after = os.fstat(descriptor)
    if _stat_payload(before) != _stat_payload(after):
        raise ValueError("credential transaction file changed while hashing")
    return {"stat": _stat_payload(after), "sha256": digest.hexdigest()}


def _retire_prequarantined_generation(
    path: Path,
    expected: dict[str, Any],
    *,
    label: str,
) -> dict[str, Any]:
    """Scrub an owned tombstone through its fd and retain a zero-byte marker.

    Darwin has no unlink-by-descriptor primitive. Retaining the deterministic,
    journal-owned zero-byte marker avoids a final validate-then-unlink pathname
    race in which a same-UID replacement could otherwise be destroyed. The
    transaction path set bounds these retired markers to one per artifact.
    """

    parent_fd = open_private_dir(path.parent)
    descriptor = -1
    try:
        descriptor = os.open(
            path.name,
            os.O_RDWR | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=parent_fd,
        )
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != os.getuid()
            or stat.S_IMODE(opened.st_mode) != 0o600
            or opened.st_nlink != 1
        ):
            raise ValueError(f"{label} is not a private transaction tombstone")
        observed = _read_fd_generation(descriptor)
        already_retired = (
            observed["sha256"] == sha256(b"").hexdigest()
            and observed["stat"]["size"] == 0
            and isinstance(expected, dict)
            and isinstance(expected.get("stat"), dict)
            and _stat_matches_inode(observed["stat"], expected["stat"])
        )
        if not already_retired and not _generation_matches(observed, expected, ctime=True):
            raise ValueError(f"{label} changed before attributed retirement")
        current = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
        if _stat_payload(current) != observed["stat"]:
            raise ValueError(f"{label} changed immediately before attributed retirement")
        if not already_retired:
            os.ftruncate(descriptor, 0)
            os.fsync(descriptor)
        retired = _read_fd_generation(descriptor)
        if (
            retired["sha256"] != sha256(b"").hexdigest()
            or retired["stat"]["size"] != 0
            or any(
                retired["stat"][field] != _inode_payload(opened)[field]
                for field in ("dev", "ino", "uid", "mode")
            )
            or retired["stat"]["nlink"] not in {0, 1}
        ):
            raise RuntimeError(f"{label} retirement identity was not stable")
        current = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
        if _stat_payload(current) != retired["stat"]:
            raise ValueError(f"{label} path changed while its owned inode was retired")
        os.fsync(parent_fd)
        return retired
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(parent_fd)


def _cleanup_owned_generation(
    path: Path,
    cleanup: Path,
    expected: object,
    *,
    key: str,
    label: str,
    journal_path: Path,
    journal: dict[str, Any],
) -> None:
    """Remove only an attributed generation through a deterministic tombstone."""

    moved_key = f"{key}_cleanup_generation"
    retired_key = f"{key}_retired_generation"
    absent_key = f"{key}_retired_absent"
    complete_key = f"{key}_cleanup_complete"
    if journal.get(complete_key) is True:
        if path.exists() or path.is_symlink():
            raise ValueError(f"{label} reappeared after attributed cleanup")
        if journal.get(absent_key) is True:
            if cleanup.exists() or cleanup.is_symlink():
                raise ValueError(f"{label} cleanup marker appeared after absent retirement")
            return
        retired = _file_generation(cleanup, f"retired {label}")
        if not _generation_matches(retired, journal.get(retired_key), ctime=True):
            raise ValueError(f"retired {label} changed after attributed cleanup")
        return
    ensure_private_dir(cleanup.parent)
    path_exists = path.exists() or path.is_symlink()
    cleanup_exists = cleanup.exists() or cleanup.is_symlink()
    if path_exists and cleanup_exists:
        raise ValueError(f"{label} exists at both source and cleanup paths")
    if cleanup_exists:
        moved = _file_generation(cleanup, f"quarantined {label}")
        durable = journal.get(moved_key)
        durable_retired = journal.get(retired_key)
        if durable_retired is not None:
            if not _generation_matches(moved, durable_retired, ctime=True):
                raise ValueError(f"retired {label} changed after retirement")
        elif durable is not None:
            if not _generation_matches(moved, durable, ctime=True):
                raise ValueError(f"quarantined {label} changed after cleanup move")
        elif not _generation_matches(moved, expected, ctime=False):
            raise ValueError(f"quarantined {label} has no transaction attribution")
        else:
            journal[moved_key] = moved
            _write_recovery_journal(journal_path, journal, f"{key}-cleanup-moved")
    elif path_exists:
        observed = _file_generation(path, label)
        if not _generation_matches(observed, expected, ctime=True):
            raise ValueError(f"{label} changed before attributed cleanup")
        _write_recovery_journal(journal_path, journal, f"{key}-cleanup-move-authorized")
        try:
            _rename_noreplace(path, cleanup)
        except FileExistsError as exc:
            raise ValueError(f"{label} cleanup tombstone already exists") from exc
        moved = _file_generation(cleanup, f"quarantined {label}")
        if not _generation_matches(moved, observed, ctime=False):
            _restore_misattributed_move(
                cleanup,
                path,
                moved["stat"],
                label=f"misattributed {label} cleanup",
            )
            raise ValueError(f"{label} changed during attributed cleanup move")
        journal[moved_key] = moved
        _write_recovery_journal(journal_path, journal, f"{key}-cleanup-moved")
    else:
        journal[absent_key] = True
        journal[complete_key] = True
        _write_recovery_journal(journal_path, journal, f"{key}-cleanup-complete")
        return
    moved = journal.get(moved_key)
    if not isinstance(moved, dict):
        raise ValueError(f"{label} cleanup generation is not durable")
    _write_recovery_journal(journal_path, journal, f"{key}-cleanup-retire-authorized")
    retired = _retire_prequarantined_generation(
        cleanup,
        moved,
        label=f"quarantined {label}",
    )
    journal[retired_key] = retired
    _write_recovery_journal(journal_path, journal, f"{key}-cleanup-retired")
    observed_retired = _file_generation(cleanup, f"retired {label}")
    if not _generation_matches(observed_retired, retired, ctime=True):
        raise ValueError(f"retired {label} changed before cleanup completion")
    journal[complete_key] = True
    _write_recovery_journal(journal_path, journal, f"{key}-cleanup-complete")
    observed_retired = _file_generation(cleanup, f"retired {label}")
    if not _generation_matches(observed_retired, retired, ctime=True):
        raise ValueError(f"retired {label} changed after cleanup completion")


def _retire_partial_generation(
    destination: Path,
    cleanup: Path,
    identity: dict[str, int],
    *,
    key: str,
    identity_key: str,
    label: str,
    journal_path: Path,
    journal: dict[str, Any],
) -> None:
    """Retire one interrupted O_EXCL generation into a bounded attempt slot."""

    count_key = f"{key}_partial_retirement_count"
    count = journal.get(count_key, 0)
    if (
        not isinstance(count, int)
        or isinstance(count, bool)
        or not 0 <= count < MAX_PARTIAL_RETIREMENTS
    ):
        raise ValueError(f"{label} exceeded its bounded partial-retirement allowance")
    partial_key = f"{key}-partial-{count}"
    partial_cleanup = cleanup.with_name(f"{cleanup.name}.{key}.partial-{count}")
    _cleanup_owned_generation(
        destination,
        partial_cleanup,
        identity,
        key=partial_key,
        label=f"partial {label}",
        journal_path=journal_path,
        journal=journal,
    )
    journal[count_key] = count + 1
    journal.pop(identity_key, None)
    _write_recovery_journal(journal_path, journal, f"{key}-copy-reset")


def _prepare_owned_copy(
    source: Path,
    destination: Path,
    cleanup: Path,
    *,
    key: str,
    label: str,
    journal_path: Path,
    journal: dict[str, Any],
    expected_source_generation: object | None = None,
) -> dict[str, Any]:
    """Create a restart-attributed O_EXCL copy and bind its final digest."""

    identity_key = f"{key}_copy_identity"
    prepared_key = f"{key}_prepared_generation"
    prepared = journal.get(prepared_key)
    identity = journal.get(identity_key)
    if prepared is not None:
        observed = _file_generation(destination, f"prepared {label}")
        if not _generation_matches(observed, prepared, ctime=True):
            raise ValueError(f"prepared {label} changed")
        if expected_source_generation is not None and not (
            isinstance(expected_source_generation, dict)
            and observed.get("sha256") == expected_source_generation.get("sha256")
        ):
            raise ValueError(f"prepared {label} does not match its bound source content")
        return observed
    if identity is not None and not _valid_inode_payload(identity):
        raise ValueError(f"{label} copy ownership is invalid")
    if identity is not None:
        _retire_partial_generation(
            destination,
            cleanup,
            identity,
            key=key,
            identity_key=identity_key,
            label=label,
            journal_path=journal_path,
            journal=journal,
        )
        identity = None
    elif destination.exists() or destination.is_symlink():
        raise ValueError(f"partial {label} has no durable transaction ownership")
    _write_recovery_journal(journal_path, journal, f"{key}-copy-running")

    def record_identity(metadata: os.stat_result) -> None:
        journal[identity_key] = _inode_payload(metadata)
        _write_recovery_journal(journal_path, journal, f"{key}-copy-owned")

    copied = _copy_private_file(
        source,
        destination,
        destination_created=record_identity,
        expected_source_generation=expected_source_generation,
    )
    observed = _file_generation(destination, f"prepared {label}")
    if not _stat_matches_inode(
        observed["stat"], journal.get(identity_key)
    ) or not _stat_matches_inode(_stat_payload(copied), journal.get(identity_key)):
        raise ValueError(f"prepared {label} changed before final attribution")
    if expected_source_generation is not None and not (
        isinstance(expected_source_generation, dict)
        and observed.get("sha256") == expected_source_generation.get("sha256")
    ):
        raise ValueError(f"prepared {label} does not match its bound source content")
    journal[prepared_key] = observed
    journal.pop(identity_key, None)
    _write_recovery_journal(journal_path, journal, f"{key}-prepared")
    return observed


def _prepare_owned_payload(
    destination: Path,
    cleanup: Path,
    payload: bytes,
    *,
    key: str,
    label: str,
    journal_path: Path,
    journal: dict[str, Any],
) -> dict[str, Any]:
    """Create a journal-owned exact-path payload without atomic-write temp aliases."""

    identity_key = f"{key}_copy_identity"
    prepared_key = f"{key}_prepared_generation"
    prepared = journal.get(prepared_key)
    identity = journal.get(identity_key)
    if prepared is not None:
        observed = _file_generation(destination, f"prepared {label}")
        if not _generation_matches(observed, prepared, ctime=True):
            raise ValueError(f"prepared {label} changed")
        return observed
    if identity is not None and not _valid_inode_payload(identity):
        raise ValueError(f"{label} payload ownership is invalid")
    if identity is not None:
        _retire_partial_generation(
            destination,
            cleanup,
            identity,
            key=key,
            identity_key=identity_key,
            label=label,
            journal_path=journal_path,
            journal=journal,
        )
        identity = None
    elif destination.exists() or destination.is_symlink():
        raise ValueError(f"partial {label} has no durable transaction ownership")
    _write_recovery_journal(journal_path, journal, f"{key}-copy-running")
    parent_fd = open_private_dir(destination.parent)
    descriptor = -1
    try:
        descriptor = os.open(
            destination.name,
            os.O_RDWR | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=parent_fd,
        )
        os.fchmod(descriptor, 0o600)
        journal[identity_key] = _inode_payload(os.fstat(descriptor))
        _write_recovery_journal(journal_path, journal, f"{key}-copy-owned")
        view = memoryview(payload)
        while view:
            view = view[os.write(descriptor, view) :]
        os.fsync(descriptor)
        observed = _read_fd_generation(descriptor)
        current = os.stat(destination.name, dir_fd=parent_fd, follow_symlinks=False)
        if not _stat_matches_inode(observed["stat"], journal.get(identity_key)) or (
            _stat_payload(current) != observed["stat"]
        ):
            raise ValueError(f"prepared {label} changed before final attribution")
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(parent_fd)
    journal[prepared_key] = observed
    journal.pop(identity_key, None)
    _write_recovery_journal(journal_path, journal, f"{key}-prepared")
    return observed


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
    if stage.exists() or stage.is_symlink():
        raise ValueError("credential recovery stage already exists before construction")
    _write_journal(journal_path, journal, "stage-create-authorized")
    stage.mkdir(mode=0o700)
    stage.chmod(0o700)
    journal["stage_stat"] = _stat_payload(_private_directory(stage, "recovery stage"))
    _write_journal(journal_path, journal, "stage-created")
    marker = stage / RECOVERY_MARKER
    atomic_write_json(marker, _stage_marker_payload(profile, str(journal["nonce"])))
    journal["marker_stat"] = _stat_payload(_private_file(marker, "recovery stage marker"))
    _write_journal(journal_path, journal, "stage-marker-ready")
    # These two non-secret markers let the sealed Quota runtime inspect and
    # prove the staged credential. Worker hooks, shared workflow links, project
    # trust, plugins, and provider history are deliberately absent.
    atomic_write_bytes(
        stage / ".agent-fleet-profile.json",
        (
            json.dumps(
                {
                    "schema": 2,
                    "agent_fleet_version": __version__,
                    "profile": profile.id,
                    "provider": profile.provider,
                },
                indent=2,
                sort_keys=True,
            )
            + "\n"
        ).encode(),
    )
    _write_journal(journal_path, journal, "stage-profile-ready")
    stable_binary_marker = profile.home / PROVIDER_BINARY_MARKER_FILE
    atomic_write_bytes(
        stage / PROVIDER_BINARY_MARKER_FILE,
        read_private_bytes(stable_binary_marker, label="managed provider binary marker"),
    )
    _write_journal(journal_path, journal, "stage-binary-ready")
    if profile.provider == "codex":
        atomic_write_bytes(
            stage / "config.toml",
            b'cli_auth_credentials_store = "file"\n\n[features]\nhooks = false\n',
        )
    _write_journal(journal_path, journal, "stage-config-ready")
    ensure_private_dir(stage / ".cache")
    _write_journal(journal_path, journal, "stage-cache-ready")
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


def _validate_partial_stage_tree(stage: Path, expected: object | None) -> os.stat_result:
    metadata = _private_directory(stage, "credential recovery cleanup tree")
    if expected is not None and not all(
        isinstance(expected, dict) and expected.get(field) == _stat_payload(metadata)[field]
        for field in ("dev", "ino", "uid", "mode")
    ):
        raise ValueError("credential recovery cleanup tree identity changed")
    for root, directories, files in os.walk(stage, followlinks=False):
        root_path = Path(root)
        for name in [*directories, *files]:
            path = root_path / name
            item = path.lstat()
            if item.st_uid != os.getuid() or stat.S_IMODE(item.st_mode) & 0o077:
                raise ValueError(f"unsafe entry in partial credential recovery stage: {path}")
            if stat.S_ISDIR(item.st_mode):
                continue
            if not stat.S_ISREG(item.st_mode) or item.st_nlink != 1:
                raise ValueError(f"unsafe partial credential recovery stage entry: {path}")
    return metadata


def _remove_stage(
    profile: Profile,
    paths: dict[str, Path],
    journal_path: Path,
    journal: dict[str, Any],
) -> None:
    """Quarantine and remove a full or partially constructed stage idempotently."""

    if journal.get("stage_cleanup_complete") is True:
        return
    stage = paths["stage"]
    quarantine = paths["quarantine"]
    stage_exists = stage.exists() or stage.is_symlink()
    quarantine_exists = quarantine.exists() or quarantine.is_symlink()
    if stage_exists and quarantine_exists:
        raise ValueError("credential recovery stage and quarantine both exist")
    if not stage_exists and not quarantine_exists:
        if stage.parent.exists() or stage.parent.is_symlink():
            _fsync(stage.parent)
        journal["stage_cleanup_complete"] = True
        _write_recovery_journal(journal_path, journal, "stage-removed")
        return

    expected = journal.get("stage_cleanup_stat") or journal.get("stage_stat")
    if stage_exists:
        if expected is None:
            # The only unbound crash window is immediately after mkdir and
            # before the stage-created journal. No writer was yet authorized.
            metadata = _validate_partial_stage_tree(stage, None)
            if any(stage.iterdir()):
                raise ValueError("unbound credential recovery stage is not empty")
            expected = _stat_payload(metadata)
            journal["stage_cleanup_stat"] = expected
            _write_recovery_journal(journal_path, journal, "stage-cleanup-bound")
        else:
            _validate_partial_stage_tree(stage, expected)
        if journal.get("stage_manifest") is not None:
            _validate_stage(profile, stage, journal)
        journal["stage_cleanup_stat"] = expected
        _write_recovery_journal(journal_path, journal, "stage-quarantine-authorized")
        try:
            _rename_noreplace(stage, quarantine)
        except FileExistsError as exc:
            raise ValueError("credential recovery stage quarantine appeared") from exc
        _fsync(quarantine.parent)
        moved = _validate_partial_stage_tree(quarantine, expected)
        journal["quarantine_stat"] = _stat_payload(moved)
        _write_recovery_journal(journal_path, journal, "stage-quarantined")
        quarantine_exists = True

    if quarantine_exists:
        _fsync(quarantine.parent)
        expected = journal.get("stage_cleanup_stat") or journal.get("stage_stat")
        removal_started = journal.get("stage_removal_started") is True
        moved = _validate_partial_stage_tree(quarantine, expected)
        if journal.get("quarantine_stat") is None:
            journal["quarantine_stat"] = _stat_payload(moved)
            _write_recovery_journal(journal_path, journal, "stage-quarantined")
        if journal.get("stage_manifest") is not None and not removal_started:
            _validate_stage(profile, quarantine, journal)
        journal["stage_removal_started"] = True
        _write_recovery_journal(
            journal_path,
            journal,
            "stage-quarantine-remove-authorized",
        )
        shutil.rmtree(quarantine)
        _fsync(quarantine.parent)
    journal["stage_cleanup_complete"] = True
    _write_recovery_journal(journal_path, journal, "stage-removed")


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


def _validated_keychain_scope(
    target: Profile,
    paths: dict[str, Path],
    journal: dict[str, Any],
) -> dict[str, str]:
    if target.provider != "claude":
        raise ValueError("Keychain scope requires a Claude worker")
    nonce = journal.get("nonce")
    if not isinstance(nonce, str) or re.fullmatch(r"[0-9a-f]{32}", nonce) is None:
        raise ValueError("credential recovery journal has invalid Keychain nonce")
    scope = {
        "account": _keychain_account(),
        "staged": _claude_service(paths["stage"]),
        "stable": _claude_service(target.home),
        "backup": f"Claude Code-agent-fleet-backup-{nonce}",
    }
    expected_fields = {
        "keychain_account": scope["account"],
        "staged_service": scope["staged"],
        "stable_service": scope["stable"],
        "backup_service": scope["backup"],
    }
    if any(journal.get(field) != value for field, value in expected_fields.items()):
        raise ValueError("credential recovery journal Keychain scope is not derived exactly")
    if len({scope["staged"], scope["stable"], scope["backup"]}) != 3:
        raise ValueError("credential recovery Keychain services are not distinct")
    return scope


def _scoped_keychain_exists(
    hooks: RecoveryHooks,
    target: Profile,
    paths: dict[str, Path],
    journal: dict[str, Any],
    role: str,
) -> bool:
    scope = _validated_keychain_scope(target, paths, journal)
    return hooks.keychain.exists(scope[role], scope["account"])


def _scoped_keychain_copy(
    hooks: RecoveryHooks,
    target: Profile,
    paths: dict[str, Path],
    journal: dict[str, Any],
    source_role: str,
    destination_role: str,
) -> None:
    scope = _validated_keychain_scope(target, paths, journal)
    hooks.keychain.copy(
        scope[source_role],
        scope[destination_role],
        scope["account"],
    )


def _scoped_keychain_delete(
    hooks: RecoveryHooks,
    target: Profile,
    paths: dict[str, Path],
    journal: dict[str, Any],
    role: str,
    *,
    missing_ok: bool,
) -> None:
    scope = _validated_keychain_scope(target, paths, journal)
    hooks.keychain.delete(scope[role], scope["account"], missing_ok=missing_ok)


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


def _snapshot_bundle(
    registry: Registry,
    paths: dict[str, Path],
    journal_path: Path,
    journal: dict[str, Any],
) -> None:
    bundle = identity_bundle_path(registry, str(journal["provider"]))
    journal["bundle_existed"] = bundle.exists()
    if bundle.exists() or bundle.is_symlink():
        journal["bundle_original_generation"] = _file_generation(
            bundle,
            "provider identity bundle",
        )
        _prepare_owned_copy(
            bundle,
            paths["bundle_backup"],
            paths["bundle_backup_cleanup"],
            key="bundle-backup",
            label="provider identity bundle backup",
            journal_path=journal_path,
            journal=journal,
        )


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
        "quota_verification_grace_seconds": (registry.settings.quota_verification_grace_seconds),
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
        or set(payload)
        != {
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
            or set(record)
            != {
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
            or record.get("stable_home") != str(registry.require_profile(profile_id).home)
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
    journal_path: Path,
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
        journal["provisional_original_generation"] = _file_generation(
            path,
            "provider provisional identity batch",
        )
        _prepare_owned_copy(
            path,
            paths["provisional_backup"],
            paths["provisional_backup_cleanup"],
            key="provisional-backup",
            label="provider provisional identity batch backup",
            journal_path=journal_path,
            journal=journal,
        )
        journal["provisional_guard_original_generation"] = _file_generation(
            guard,
            "provider initialization locator",
        )
        _prepare_owned_copy(
            guard,
            paths["provisional_guard_backup"],
            paths["provisional_guard_backup_cleanup"],
            key="provisional-guard-backup",
            label="provider initialization locator backup",
            journal_path=journal_path,
            journal=journal,
        )


def _snapshot_state(
    target: Path,
    *,
    existed: bool,
    key: str,
    label: str,
    journal: dict[str, Any],
) -> tuple[str, dict[str, Any] | None]:
    if not (target.exists() or target.is_symlink()):
        if not existed:
            return "original-absent", None
        if journal.get(f"{key}_forward_absent") is True:
            return "forward-absent", None
        return "unknown-absent", None
    observed = _file_generation(target, label)
    for state, field in (
        ("original", f"{key}_original_generation"),
        ("forward", f"{key}_forward_generation"),
        ("prepared-restore", f"{key}_restore_prepared_generation"),
        ("restored", f"{key}_restored_generation"),
    ):
        if _same_file_generation(target, journal.get(field)):
            return state, observed
    planned_digest = journal.get(f"{key}_forward_sha256")
    if isinstance(planned_digest, str) and observed["sha256"] == planned_digest:
        return "forward-planned", observed
    return "unknown", observed


def _require_snapshot_original(
    target: Path,
    *,
    existed: bool,
    key: str,
    label: str,
    journal: dict[str, Any],
) -> None:
    state, _generation = _snapshot_state(
        target,
        existed=existed,
        key=key,
        label=label,
        journal=journal,
    )
    expected = "original" if existed else "original-absent"
    if state != expected:
        raise ValueError(f"{label} changed before transaction installation")


def _install_metadata_payload(
    *,
    target: Path,
    temporary: Path,
    temporary_cleanup: Path,
    original_quarantine: Path,
    payload: dict[str, Any],
    existed: bool,
    key: str,
    label: str,
    journal_path: Path,
    journal: dict[str, Any],
) -> dict[str, Any]:
    """Publish transaction metadata without replacing a concurrent generation."""

    encoded = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode()
    prepared = _prepare_owned_payload(
        temporary,
        temporary_cleanup,
        encoded,
        key=f"{key}-install",
        label=f"{label} install generation",
        journal_path=journal_path,
        journal=journal,
    )
    original = journal.get(f"{key}_original_generation")
    if existed:
        if not isinstance(original, dict):
            raise ValueError(f"{label} original generation is unavailable")
        _quarantine_owned_generation(
            target,
            original_quarantine,
            original,
            key=f"{key}-original",
            label=f"original {label}",
            journal_path=journal_path,
            journal=journal,
        )
    elif target.exists() or target.is_symlink():
        raise ValueError(f"{label} appeared before transaction installation")
    installed = _publish_owned_generation(
        temporary,
        target,
        prepared,
        key=f"{key}-forward",
        label=label,
        journal_path=journal_path,
        journal=journal,
    )
    journal[f"{key}_forward_generation"] = installed
    return installed


def _restore_snapshot_file(
    *,
    target: Path,
    backup: Path,
    temporary: Path,
    temporary_cleanup: Path,
    quarantine: Path,
    original_quarantine: Path,
    existed: bool,
    key: str,
    label: str,
    journal_path: Path,
    journal: dict[str, Any],
) -> None:
    """Restore one snapshot through attributed quarantine and no-replace publication."""

    complete_key = f"{key}_restore_complete"
    restored_key = f"{key}_restored_generation"
    if journal.get(complete_key) is True:
        if existed:
            if not _same_file_generation(target, journal.get(restored_key)):
                raise ValueError(f"{label} changed after rollback completed")
        elif target.exists() or target.is_symlink():
            raise ValueError(f"{label} appeared after rollback completed")
        return

    installed = journal.get(f"{key}-restore_installed_generation")
    if installed is not None and (target.exists() or target.is_symlink()):
        observed_installed = _file_generation(target, f"restored {label}")
        if _generation_matches(observed_installed, installed, ctime=True):
            journal[restored_key] = observed_installed
            journal[complete_key] = True
            _write_recovery_journal(journal_path, journal, f"{key}-restore-complete")
            return
    prepared_after_move = journal.get(f"{key}-restore_prepared_generation")
    if prepared_after_move is not None and (target.exists() or target.is_symlink()):
        observed_prepared = _file_generation(target, f"restored {label}")
        if _generation_matches(observed_prepared, prepared_after_move, ctime=False):
            if temporary.exists() or temporary.is_symlink():
                raise ValueError(f"restored {label} exists at two paths")
            journal[f"{key}-restore_installed_generation"] = observed_prepared
            journal[restored_key] = observed_prepared
            journal[complete_key] = True
            _write_recovery_journal(journal_path, journal, f"{key}-restore-complete")
            return

    state, observed = _snapshot_state(
        target,
        existed=existed,
        key=key,
        label=label,
        journal=journal,
    )
    if state in {"original", "restored"}:
        journal[restored_key] = _file_generation(target, f"restored {label}")
        journal[complete_key] = True
        _write_recovery_journal(journal_path, journal, f"{key}-restore-complete")
        return
    forward_key = f"{key}-forward-rollback"
    quarantine_exists = quarantine.exists() or quarantine.is_symlink()
    if quarantine_exists:
        moved = _file_generation(quarantine, f"quarantined {label}")
        expected_moved = journal.get(f"{forward_key}_quarantine_generation") or journal.get(
            f"{forward_key}_observed_generation"
        )
        if not _generation_matches(
            moved,
            expected_moved,
            ctime=journal.get(f"{forward_key}_quarantine_generation") is not None,
        ):
            raise ValueError(f"quarantined {label} has no transaction attribution")
        if journal.get(f"{forward_key}_quarantine_generation") is None:
            journal[f"{forward_key}_quarantine_generation"] = moved
            _write_recovery_journal(journal_path, journal, f"{forward_key}-quarantined")
        if target.exists() or target.is_symlink():
            raise ValueError(f"{label} appeared while its forward generation is quarantined")
    elif state in {"forward", "forward-planned", "prepared-restore"}:
        if observed is None:
            raise ValueError(f"{label} forward generation is unavailable")
        _quarantine_owned_generation(
            target,
            quarantine,
            observed,
            key=forward_key,
            label=label,
            journal_path=journal_path,
            journal=journal,
        )
    elif state == "unknown-absent" and (
        original_quarantine.exists() or original_quarantine.is_symlink()
    ):
        pass
    elif state not in {"original-absent", "forward-absent"}:
        raise ValueError(f"{label} has an unknown generation during rollback")
    if not existed:
        journal[complete_key] = True
        _write_recovery_journal(journal_path, journal, f"{key}-restore-complete")
        return

    original_generation = journal.get(f"{key}_original_generation")
    if original_quarantine.exists() or original_quarantine.is_symlink():
        original_moved = _file_generation(
            original_quarantine,
            f"quarantined original {label}",
        )
        durable_original = journal.get(f"{key}-original_quarantine_generation")
        if durable_original is not None:
            if not _generation_matches(original_moved, durable_original, ctime=True):
                raise ValueError(f"quarantined original {label} changed")
        elif not _generation_matches(original_moved, original_generation, ctime=False):
            raise ValueError(f"quarantined original {label} has no attribution")
        restored_generation = _publish_owned_generation(
            original_quarantine,
            target,
            original_moved,
            key=f"{key}-restore",
            label=f"restored {label}",
            journal_path=journal_path,
            journal=journal,
        )
        journal[restored_key] = restored_generation
        journal[complete_key] = True
        _write_recovery_journal(journal_path, journal, f"{key}-restore-complete")
        return
    backup_generation = _file_generation(backup, f"{label} backup")
    backup_key = f"{key.replace('_', '-')}-backup"
    durable_backup_key = f"{backup_key}_prepared_generation"
    durable_backup = journal.get(durable_backup_key)
    if not isinstance(original_generation, dict) or (
        backup_generation["sha256"] != original_generation.get("sha256")
    ):
        raise ValueError(f"{label} backup is not the snapshotted generation")
    if durable_backup is None:
        journal[durable_backup_key] = backup_generation
        durable_backup = backup_generation
        _write_recovery_journal(journal_path, journal, f"{backup_key}-legacy-generation-bound")
    elif not _generation_matches(backup_generation, durable_backup, ctime=True):
        raise ValueError(f"{label} backup changed from its durable snapshot generation")
    prepared = _prepare_owned_copy(
        backup,
        temporary,
        temporary_cleanup,
        key=f"{key}-restore",
        label=f"{label} rollback generation",
        journal_path=journal_path,
        journal=journal,
        expected_source_generation=durable_backup,
    )
    journal[f"{key}_restore_prepared_generation"] = prepared
    restored_generation = _publish_owned_generation(
        temporary,
        target,
        prepared,
        key=f"{key}-restore",
        label=f"restored {label}",
        journal_path=journal_path,
        journal=journal,
    )
    journal[restored_key] = restored_generation
    journal[complete_key] = True
    _write_recovery_journal(journal_path, journal, f"{key}-restore-complete")


def _restore_provisional(
    registry: Registry,
    provider: str,
    paths: dict[str, Path],
    journal_path: Path,
    journal: dict[str, Any],
) -> None:
    path = _provisional_path(registry, provider)
    guard = _provisional_guard_path(registry, provider)
    provisional_existed = journal.get("provisional_existed")
    guard_existed = journal.get("provisional_guard_existed")
    if not isinstance(provisional_existed, bool) or not isinstance(guard_existed, bool):
        raise ValueError("provider provisional snapshot state is incomplete")
    _restore_snapshot_file(
        target=path,
        backup=paths["provisional_backup"],
        temporary=paths["provisional_restore_temp"],
        temporary_cleanup=paths["provisional_restore_temp_cleanup"],
        quarantine=paths["provisional_restore_quarantine"],
        original_quarantine=paths["provisional_original_quarantine"],
        existed=provisional_existed,
        key="provisional",
        label="provider provisional identity batch",
        journal_path=journal_path,
        journal=journal,
    )
    _restore_snapshot_file(
        target=guard,
        backup=paths["provisional_guard_backup"],
        temporary=paths["provisional_guard_restore_temp"],
        temporary_cleanup=paths["provisional_guard_restore_temp_cleanup"],
        quarantine=paths["provisional_guard_restore_quarantine"],
        original_quarantine=paths["provisional_guard_original_quarantine"],
        existed=guard_existed,
        key="provisional_guard",
        label="provider initialization locator",
        journal_path=journal_path,
        journal=journal,
    )


def _restore_bundle(
    registry: Registry,
    paths: dict[str, Path],
    journal_path: Path,
    journal: dict[str, Any],
) -> None:
    bundle = identity_bundle_path(registry, str(journal["provider"]))
    bundle_existed = journal.get("bundle_existed")
    if not isinstance(bundle_existed, bool):
        raise ValueError("provider identity bundle snapshot state is incomplete")
    _restore_snapshot_file(
        target=bundle,
        backup=paths["bundle_backup"],
        temporary=paths["bundle_restore_temp"],
        temporary_cleanup=paths["bundle_restore_temp_cleanup"],
        quarantine=paths["bundle_restore_quarantine"],
        original_quarantine=paths["bundle_original_quarantine"],
        existed=bundle_existed,
        key="bundle",
        label="provider identity bundle",
        journal_path=journal_path,
        journal=journal,
    )


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


def _quarantine_owned_generation(
    source: Path,
    quarantine: Path,
    expected: dict[str, Any],
    *,
    key: str,
    label: str,
    journal_path: Path,
    journal: dict[str, Any],
) -> dict[str, Any]:
    """Move an exact source generation aside without replacing either side."""

    observed_key = f"{key}_observed_generation"
    moved_key = f"{key}_quarantine_generation"
    source_exists = source.exists() or source.is_symlink()
    quarantine_exists = quarantine.exists() or quarantine.is_symlink()
    if source_exists and quarantine_exists:
        raise ValueError(f"{label} exists at both stable and quarantine paths")
    if quarantine_exists:
        moved = _file_generation(quarantine, f"quarantined {label}")
        durable = journal.get(moved_key)
        before_move = journal.get(observed_key) or expected
        if durable is not None:
            if not _generation_matches(moved, durable, ctime=True):
                raise ValueError(f"quarantined {label} changed after its move")
        elif not _generation_matches(moved, before_move, ctime=False):
            raise ValueError(f"quarantined {label} has no transaction attribution")
        else:
            journal[moved_key] = moved
            _write_recovery_journal(journal_path, journal, f"{key}-quarantined")
        return moved
    if not source_exists:
        raise ValueError(f"{label} disappeared before its quarantine move")
    observed = _file_generation(source, label)
    if not _generation_matches(observed, expected, ctime=True):
        raise ValueError(f"{label} changed before its quarantine move")
    journal[observed_key] = observed
    _write_recovery_journal(journal_path, journal, f"{key}-quarantine-authorized")
    try:
        _rename_noreplace(source, quarantine)
    except FileExistsError as exc:
        raise ValueError(f"{label} quarantine path already exists") from exc
    moved = _file_generation(quarantine, f"quarantined {label}")
    if not _generation_matches(moved, observed, ctime=False):
        _restore_misattributed_move(
            quarantine,
            source,
            moved["stat"],
            label=f"misattributed {label}",
        )
        raise ValueError(f"{label} changed during its quarantine move")
    journal[moved_key] = moved
    _write_recovery_journal(journal_path, journal, f"{key}-quarantined")
    if source.exists() or source.is_symlink():
        raise ValueError(f"{label} reappeared after its quarantine move")
    return moved


def _publish_owned_generation(
    source: Path,
    destination: Path,
    expected: dict[str, Any],
    *,
    key: str,
    label: str,
    journal_path: Path,
    journal: dict[str, Any],
) -> dict[str, Any]:
    """Publish one prepared generation with atomic no-replace semantics."""

    installed_key = f"{key}_installed_generation"
    source_exists = source.exists() or source.is_symlink()
    destination_exists = destination.exists() or destination.is_symlink()
    if source_exists and destination_exists:
        raise ValueError(f"{label} exists at both prepared and destination paths")
    if destination_exists:
        installed = _file_generation(destination, f"installed {label}")
        durable = journal.get(installed_key)
        if durable is not None:
            if not _generation_matches(installed, durable, ctime=True):
                raise ValueError(f"installed {label} changed after publication")
        elif not _generation_matches(installed, expected, ctime=False):
            raise ValueError(f"destination contains an unattributed {label}")
        else:
            journal[installed_key] = installed
            _write_recovery_journal(journal_path, journal, f"{key}-installed")
        return installed
    if not source_exists:
        raise ValueError(f"prepared {label} disappeared before publication")
    prepared = _file_generation(source, f"prepared {label}")
    if not _generation_matches(prepared, expected, ctime=True):
        raise ValueError(f"prepared {label} changed before publication")
    _write_recovery_journal(journal_path, journal, f"{key}-publish-authorized")
    try:
        _rename_noreplace(source, destination)
    except FileExistsError as exc:
        raise ValueError(f"destination appeared before {label} publication") from exc
    installed = _file_generation(destination, f"installed {label}")
    if not _generation_matches(installed, prepared, ctime=False):
        _restore_misattributed_move(
            destination,
            source,
            installed["stat"],
            label=f"misattributed published {label}",
        )
        raise ValueError(f"prepared {label} changed during publication")
    journal[installed_key] = installed
    _write_recovery_journal(journal_path, journal, f"{key}-installed")
    if source.exists() or source.is_symlink():
        raise ValueError(f"prepared {label} reappeared after publication")
    _fsync(destination.parent)
    return installed


def _install_file_credential(
    staged: Path,
    stable: Path,
    backup: Path,
    paths: dict[str, Path],
    journal_path: Path,
    journal: dict[str, Any],
    *,
    label: str,
    stage_home: Path,
    backup_name: str,
) -> None:
    """Install a file credential through attributed copies and no-replace moves."""

    original = (
        _file_generation(stable, f"stable {label}")
        if stable.exists() or stable.is_symlink()
        else None
    )
    journal["original_credential_generation"] = original
    journal["original_credential_stat"] = original["stat"] if original else None
    _write_journal(journal_path, journal, "credential-backup-running")
    if original is not None:
        _prepare_owned_copy(
            stable,
            backup,
            paths[f"{backup_name}_cleanup"],
            key=f"{backup_name}-snapshot",
            label=f"{label} backup",
            journal_path=journal_path,
            journal=journal,
        )
    _record_stage_manifest(stage_home, journal)
    _write_journal(journal_path, journal, "credential-backup-ready")
    prepared = _prepare_owned_copy(
        staged,
        paths["install_temp"],
        paths["install_temp_cleanup"],
        key="credential-install",
        label=f"{label} install generation",
        journal_path=journal_path,
        journal=journal,
    )
    journal["prepared_credential_generation"] = prepared
    journal["prepared_credential_stat"] = prepared["stat"]
    _write_journal(journal_path, journal, "credential-prepared")
    if original is not None:
        _quarantine_owned_generation(
            stable,
            paths["credential_original_quarantine"],
            original,
            key="credential-original",
            label=f"original stable {label}",
            journal_path=journal_path,
            journal=journal,
        )
    elif stable.exists() or stable.is_symlink():
        raise ValueError(f"stable {label} appeared during recovery")
    installed = _publish_owned_generation(
        paths["install_temp"],
        stable,
        prepared,
        key="credential-forward",
        label=label,
        journal_path=journal_path,
        journal=journal,
    )
    journal["installed_credential_generation"] = installed
    journal["installed_credential_stat"] = installed["stat"]
    _write_journal(journal_path, journal, "credential-installed")


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
    journal["credential_kind"] = "codex-file"
    _install_file_credential(
        staged_auth,
        stable,
        paths["codex_backup"],
        paths,
        journal_path,
        journal,
        label="Codex auth",
        stage_home=stage.home,
        backup_name="codex_backup",
    )


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
        journal["credential_kind"] = "claude-file"
        _install_file_credential(
            staged,
            stable,
            paths["claude_file_backup"],
            paths,
            journal_path,
            journal,
            label="Claude auth",
            stage_home=stage.home,
            backup_name="claude_file_backup",
        )
        return
    if source.get("kind") != "keychain":
        raise ValueError("staged Claude login has no single scoped credential source")
    scope = _validated_keychain_scope(target, paths, journal)
    account = scope["account"]
    staged_service = scope["staged"]
    stable_service = scope["stable"]
    if (
        source.get("service") != staged_service
        or source.get("config_home") != str(stage.home)
        or source.get("account") != account
    ):
        raise ValueError("staged Claude Keychain credential is scoped to another home")
    backup_service = scope["backup"]
    stable_source = _normalize_source_contract(
        hooks,
        target,
        hooks.inspect_source(registry, target, True),
    )
    if stable_source.get("kind") not in {"absent", "keychain", "oauth-file"}:
        raise ValueError("stable Claude worker has ambiguous credential sources")
    stable_keychain = stable_source.get("kind") == "keychain"
    stable_file = target.home / CLAUDE_AUTH
    stable_file_generation = None
    if stable_source.get("kind") == "oauth-file":
        stable_file_generation = _file_generation(
            stable_file,
            "stable Claude auth file",
        )
    journal.update(
        {
            "credential_kind": "claude-keychain",
            "keychain_account": account,
            "staged_service": staged_service,
            "stable_service": stable_service,
            "backup_service": backup_service,
            "stable_keychain_existed": stable_keychain,
            "original_credential_generation": stable_file_generation,
            "original_credential_stat": (
                stable_file_generation["stat"] if stable_file_generation else None
            ),
        }
    )
    _write_journal(journal_path, journal, "credential-backup-running")
    if stable_file_generation is not None:
        _prepare_owned_copy(
            stable_file,
            paths["claude_file_backup"],
            paths["claude_file_backup_cleanup"],
            key="claude_file_backup-snapshot",
            label="Claude auth backup",
            journal_path=journal_path,
            journal=journal,
        )
    if stable_keychain:
        if not _scoped_keychain_exists(hooks, target, paths, journal, "stable"):
            raise ValueError("stable scoped Claude Keychain item disappeared")
        _scoped_keychain_copy(hooks, target, paths, journal, "stable", "backup")
    _record_stage_manifest(stage.home, journal)
    _write_journal(journal_path, journal, "credential-backup-ready")
    if stable_file_generation is not None:
        _quarantine_owned_generation(
            stable_file,
            paths["credential_original_quarantine"],
            stable_file_generation,
            key="credential-original",
            label="original stable Claude auth file",
            journal_path=journal_path,
            journal=journal,
        )
    _write_journal(journal_path, journal, "credential-prepared")
    _scoped_keychain_copy(hooks, target, paths, journal, "staged", "stable")
    if not _scoped_keychain_exists(hooks, target, paths, journal, "stable"):
        raise ValueError("promoted scoped Claude Keychain item is unavailable")
    _write_journal(journal_path, journal, "credential-installed")


def _rename_noreplace(source: Path, destination: Path) -> None:
    """Atomically move one private path without replacing the destination."""

    rename_private_noreplace(source, destination)


def _restore_misattributed_move(
    source: Path,
    destination: Path,
    moved_generation: dict[str, int],
    *,
    label: str,
) -> None:
    """Return a moved foreign generation without overwriting a new destination."""

    try:
        _rename_noreplace(source, destination)
    except FileExistsError as exc:
        raise ValueError(f"{label} attribution failed and both generations were preserved") from exc
    restored = _stat_payload(_private_file(destination, label))
    if not _stat_matches_generation(restored, moved_generation, ctime=False):
        raise ValueError(f"{label} changed while its misattributed move was restored")


def _rollback_file_credential(
    target: Profile,
    stable_name: str,
    backup: Path,
    paths: dict[str, Path],
    journal_path: Path,
    journal: dict[str, Any],
    *,
    allow_absent_forward: bool = False,
) -> None:
    stable = target.home / stable_name
    rollback = paths["rollback_temp"]
    quarantine = paths["credential_quarantine"]
    original_quarantine = paths.get("credential_original_quarantine")

    original = journal.get("original_credential_generation")
    if original is None and isinstance(journal.get("original_credential_stat"), dict):
        backup_generation = _file_generation(backup, "credential recovery backup")
        original = {
            "stat": journal["original_credential_stat"],
            "sha256": backup_generation["sha256"],
        }
    installed = journal.get("installed_credential_generation") or journal.get(
        "credential-forward_installed_generation"
    )
    prepared_forward = journal.get("prepared_credential_generation") or journal.get(
        "credential-install_prepared_generation"
    )
    if (
        installed is None
        and isinstance(journal.get("installed_credential_stat"), dict)
        and (stable.exists() or stable.is_symlink())
    ):
        candidate = _file_generation(stable, "transaction-installed stable credential")
        if _stat_matches_generation(
            candidate["stat"],
            journal["installed_credential_stat"],
            ctime=True,
        ):
            installed = candidate
    if (
        installed is None
        and prepared_forward is not None
        and (stable.exists() or stable.is_symlink())
    ):
        candidate = _file_generation(stable, "transaction-published stable credential")
        if _generation_matches(candidate, prepared_forward, ctime=False):
            installed = candidate
            journal["installed_credential_generation"] = candidate
            _write_recovery_journal(
                journal_path,
                journal,
                "credential-forward-publication-recovered",
            )
    restored = journal.get("rollback-file_installed_generation")
    rollback_prepared = journal.get("rollback-file_prepared_generation")

    stable_exists = stable.exists() or stable.is_symlink()
    if original is not None and stable_exists:
        observed_stable = _file_generation(stable, "stable credential during rollback")
        if any(
            expected is not None and _generation_matches(observed_stable, expected, ctime=False)
            for expected in (original, restored, rollback_prepared)
        ):
            journal["rollback-file_installed_generation"] = observed_stable
            journal["rollback_file_installed_stat"] = observed_stable["stat"]
            _write_recovery_journal(journal_path, journal, "rollback-file-installed")
            return

    if quarantine.exists() or quarantine.is_symlink():
        expected_forward = (
            journal.get("credential-forward-rollback_quarantine_generation")
            or journal.get("credential-forward-rollback_observed_generation")
            or installed
        )
        forward_quarantine = _file_generation(
            quarantine,
            "quarantined transaction credential",
        )
        if not _generation_matches(
            forward_quarantine,
            expected_forward,
            ctime=journal.get("credential-forward-rollback_quarantine_generation") is not None,
        ):
            raise ValueError("credential quarantine contains an unattributed generation")
        if journal.get("credential-forward-rollback_quarantine_generation") is None:
            journal["credential-forward-rollback_quarantine_generation"] = forward_quarantine
            _write_recovery_journal(journal_path, journal, "rollback-file-quarantined")
        if stable_exists:
            raise ValueError("stable credential appeared while its prior generation is quarantined")
    elif stable_exists:
        if installed is None:
            raise ValueError("stable credential has no transaction-installed attribution")
        _quarantine_owned_generation(
            stable,
            quarantine,
            installed,
            key="credential-forward-rollback",
            label="transaction-installed stable credential",
            journal_path=journal_path,
            journal=journal,
        )
        stable_exists = False
    elif (
        original is not None
        and not allow_absent_forward
        and not (
            original_quarantine
            and (original_quarantine.exists() or original_quarantine.is_symlink())
        )
    ):
        raise ValueError("stable credential changed outside the recovery transaction")

    if original is None:
        journal["rollback_file_deleted"] = True
        _write_recovery_journal(journal_path, journal, "rollback-file-installed")
        return

    if original_quarantine and (original_quarantine.exists() or original_quarantine.is_symlink()):
        original_moved = _file_generation(
            original_quarantine,
            "quarantined original credential",
        )
        durable_original = journal.get("credential-original_quarantine_generation")
        if durable_original is not None:
            if not _generation_matches(original_moved, durable_original, ctime=True):
                raise ValueError("quarantined original credential changed")
        elif not _generation_matches(original_moved, original, ctime=False):
            raise ValueError("quarantined original credential has no attribution")
        published = _publish_owned_generation(
            original_quarantine,
            stable,
            original_moved,
            key="rollback-file",
            label="restored credential generation",
            journal_path=journal_path,
            journal=journal,
        )
    else:
        backup_key = (
            "codex_backup-snapshot" if stable_name == CODEX_AUTH else "claude_file_backup-snapshot"
        )
        durable_backup = journal.get(f"{backup_key}_prepared_generation")
        backup_generation = _file_generation(backup, "credential recovery backup")
        durable_backup_changed = durable_backup is not None and not _generation_matches(
            backup_generation,
            durable_backup,
            ctime=True,
        )
        if durable_backup_changed or not (
            isinstance(original, dict) and backup_generation.get("sha256") == original.get("sha256")
        ):
            raise ValueError("credential recovery backup changed before rollback")
        if durable_backup is None:
            durable_backup = backup_generation
            journal[f"{backup_key}_prepared_generation"] = durable_backup
            _write_recovery_journal(
                journal_path,
                journal,
                f"{backup_key}-legacy-generation-bound",
            )
        prepared = _prepare_owned_copy(
            backup,
            rollback,
            paths["rollback_temp_cleanup"],
            key="rollback-file",
            label="credential rollback generation",
            journal_path=journal_path,
            journal=journal,
            expected_source_generation=durable_backup,
        )
        published = _publish_owned_generation(
            rollback,
            stable,
            prepared,
            key="rollback-file",
            label="restored credential generation",
            journal_path=journal_path,
            journal=journal,
        )
    journal["rollback_file_installed_stat"] = published["stat"]
    _write_recovery_journal(journal_path, journal, "rollback-file-installed")


def _rollback_local_credential(
    hooks: RecoveryHooks,
    target: Profile,
    paths: dict[str, Path],
    journal_path: Path,
    journal: dict[str, Any],
) -> None:
    if journal.get("local_credential_rollback_complete") is True:
        return
    kind = journal.get("credential_kind")
    if kind == "codex-file":
        _rollback_file_credential(
            target,
            CODEX_AUTH,
            paths["codex_backup"],
            paths,
            journal_path,
            journal,
        )
    elif kind == "claude-file":
        _rollback_file_credential(
            target,
            CLAUDE_AUTH,
            paths["claude_file_backup"],
            paths,
            journal_path,
            journal,
        )
    elif kind == "claude-keychain":
        _validated_keychain_scope(target, paths, journal)
        phase = journal.get("phase")
        backup_ready = phase not in {
            "credential-backup-running",
        }
        if journal.get("keychain_rollback_complete") is not True:
            _write_recovery_journal(journal_path, journal, "rollback-keychain-running")
            if journal.get("stable_keychain_existed") is True:
                if backup_ready:
                    if not _scoped_keychain_exists(
                        hooks,
                        target,
                        paths,
                        journal,
                        "backup",
                    ):
                        raise ValueError("Claude Keychain rollback generation is unavailable")
                    _scoped_keychain_copy(
                        hooks,
                        target,
                        paths,
                        journal,
                        "backup",
                        "stable",
                    )
                    if not _scoped_keychain_exists(
                        hooks,
                        target,
                        paths,
                        journal,
                        "stable",
                    ):
                        raise ValueError("restored scoped Claude Keychain item is unavailable")
                elif not _scoped_keychain_exists(
                    hooks,
                    target,
                    paths,
                    journal,
                    "stable",
                ):
                    raise ValueError("original scoped Claude Keychain item changed during backup")
            elif backup_ready:
                _scoped_keychain_delete(
                    hooks,
                    target,
                    paths,
                    journal,
                    "stable",
                    missing_ok=True,
                )
            elif _scoped_keychain_exists(hooks, target, paths, journal, "stable"):
                raise ValueError("stable scoped Claude Keychain item appeared during backup")
            journal["keychain_rollback_complete"] = True
            _write_recovery_journal(journal_path, journal, "rollback-keychain-complete")
        original = journal.get("original_credential_stat")
        if original is not None:
            _rollback_file_credential(
                target,
                CLAUDE_AUTH,
                paths["claude_file_backup"],
                paths,
                journal_path,
                journal,
                allow_absent_forward=True,
            )
        elif (target.home / CLAUDE_AUTH).exists() or (target.home / CLAUDE_AUTH).is_symlink():
            raise ValueError("unexpected stable Claude auth file appeared during recovery")
    journal["local_credential_rollback_complete"] = True
    _write_recovery_journal(journal_path, journal, "rollback-credential-complete")


def _clean_exact_temporaries(
    paths: dict[str, Path],
    journal_path: Path,
    journal: dict[str, Any],
) -> None:
    cleanup_specs: tuple[tuple[str, str, object], ...] = (
        (
            "credential_quarantine",
            "credential-forward-rollback",
            journal.get("credential-forward-rollback_quarantine_generation"),
        ),
        (
            "credential_original_quarantine",
            "credential-original",
            journal.get("credential-original_quarantine_generation"),
        ),
        (
            "install_temp",
            "credential-install",
            journal.get("credential-install_prepared_generation")
            or journal.get("credential-install_copy_identity"),
        ),
        (
            "rollback_temp",
            "rollback-file",
            journal.get("rollback-file_prepared_generation")
            or journal.get("rollback-file_copy_identity"),
        ),
        (
            "bundle_install_temp",
            "bundle-install",
            journal.get("bundle-install_prepared_generation")
            or journal.get("bundle-install_copy_identity"),
        ),
        (
            "provisional_install_temp",
            "provisional-install",
            journal.get("provisional-install_prepared_generation")
            or journal.get("provisional-install_copy_identity"),
        ),
        (
            "provisional_guard_install_temp",
            "provisional-guard-install",
            journal.get("provisional_guard-install_prepared_generation")
            or journal.get("provisional_guard-install_copy_identity"),
        ),
        (
            "bundle_original_quarantine",
            "bundle-original",
            journal.get("bundle-original_quarantine_generation"),
        ),
        (
            "provisional_original_quarantine",
            "provisional-original",
            journal.get("provisional-original_quarantine_generation"),
        ),
        (
            "provisional_guard_original_quarantine",
            "provisional_guard-original",
            journal.get("provisional_guard-original_quarantine_generation"),
        ),
        (
            "bundle_restore_temp",
            "bundle-restore",
            journal.get("bundle-restore_prepared_generation")
            or journal.get("bundle-restore_copy_identity"),
        ),
        (
            "provisional_restore_temp",
            "provisional-restore",
            journal.get("provisional-restore_prepared_generation")
            or journal.get("provisional-restore_copy_identity"),
        ),
        (
            "provisional_guard_restore_temp",
            "provisional_guard-restore",
            journal.get("provisional_guard-restore_prepared_generation")
            or journal.get("provisional_guard-restore_copy_identity"),
        ),
        (
            "bundle_restore_quarantine",
            "bundle-forward-rollback",
            journal.get("bundle-forward-rollback_quarantine_generation"),
        ),
        (
            "provisional_restore_quarantine",
            "provisional-forward-rollback",
            journal.get("provisional-forward-rollback_quarantine_generation"),
        ),
        (
            "provisional_guard_restore_quarantine",
            "provisional_guard-forward-rollback",
            journal.get("provisional_guard-forward-rollback_quarantine_generation"),
        ),
    )
    for name, key, expected in cleanup_specs:
        path = paths[name]
        cleanup = paths[f"{name}_cleanup"]
        if (
            not any(candidate.exists() or candidate.is_symlink() for candidate in (path, cleanup))
            and journal.get(f"{key}_cleanup_complete") is not True
        ):
            continue
        if expected is None and journal.get(f"{key}_cleanup_generation") is None:
            raise ValueError(f"{name} has no durable cleanup ownership")
        _cleanup_owned_generation(
            path,
            cleanup,
            expected,
            key=key,
            label=name.replace("_", " "),
            journal_path=journal_path,
            journal=journal,
        )


def _clean_stage_backups(
    paths: dict[str, Path],
    journal_path: Path,
    journal: dict[str, Any],
) -> None:
    """Remove attributed secret-bearing backups before final stage collection."""

    specs = (
        ("codex_backup", "codex_backup-snapshot"),
        ("claude_file_backup", "claude_file_backup-snapshot"),
        ("bundle_backup", "bundle-backup"),
        ("provisional_backup", "provisional-backup"),
        ("provisional_guard_backup", "provisional-guard-backup"),
    )
    changed = False
    for name, key in specs:
        path = paths[name]
        cleanup = paths[f"{name}_cleanup"]
        if (
            not any(candidate.exists() or candidate.is_symlink() for candidate in (path, cleanup))
            and journal.get(f"{key}_cleanup_complete") is not True
        ):
            continue
        expected = journal.get(f"{key}_prepared_generation") or journal.get(f"{key}_copy_identity")
        if expected is None and journal.get(f"{key}_cleanup_generation") is None:
            raise ValueError(f"{name} has no durable backup cleanup ownership")
        _cleanup_owned_generation(
            path,
            cleanup,
            expected,
            key=key,
            label=name.replace("_", " "),
            journal_path=journal_path,
            journal=journal,
        )
        changed = True
    stage = paths["stage"]
    if changed and (stage.exists() or stage.is_symlink()):
        _validate_partial_stage_tree(stage, journal.get("stage_stat"))
        _record_stage_manifest(stage, journal)
        _write_recovery_journal(journal_path, journal, "stage-backups-cleaned")


def _cleanup_keychain(
    hooks: RecoveryHooks,
    target: Profile,
    paths: dict[str, Path],
    journal_path: Path,
    journal: dict[str, Any],
    *,
    committed: bool,
) -> None:
    if journal.get("provider") != "claude":
        return
    if journal.get("keychain_cleanup_complete") is True:
        return
    _validated_keychain_scope(target, paths, journal)
    staged_service = journal.get("staged_service")
    if journal.get("staged_keychain_cleanup_complete") is not True:
        if isinstance(staged_service, str):
            _write_recovery_journal(
                journal_path,
                journal,
                "keychain-staged-cleanup-authorized",
            )
            _scoped_keychain_delete(
                hooks,
                target,
                paths,
                journal,
                "staged",
                missing_ok=True,
            )
        journal["staged_keychain_cleanup_complete"] = True
        _write_recovery_journal(
            journal_path,
            journal,
            "keychain-staged-cleanup-complete",
        )

    backup_service = journal.get("backup_service")
    if journal.get("backup_keychain_cleanup_complete") is not True:
        if not committed and journal.get("local_credential_rollback_complete") is not True:
            raise ValueError("refusing to delete Claude rollback backup before durable rollback")
        if isinstance(backup_service, str):
            _write_recovery_journal(
                journal_path,
                journal,
                "keychain-backup-cleanup-authorized",
            )
            _scoped_keychain_delete(
                hooks,
                target,
                paths,
                journal,
                "backup",
                missing_ok=True,
            )
        journal["backup_keychain_cleanup_complete"] = True
        _write_recovery_journal(
            journal_path,
            journal,
            "keychain-backup-cleanup-complete",
        )
    journal["keychain_cleanup_complete"] = True
    _write_recovery_journal(journal_path, journal, "keychain-cleanup-complete")


def recover_pending_profile_recoveries(
    registry: Registry,
    provider: str,
    *,
    hooks: RecoveryHooks | None = None,
    allow_current_owner: bool = False,
    retain_committed_receipts: bool = False,
) -> list[dict[str, Any]]:
    """Recover only worker transactions while the caller owns the provider lock."""

    controls = hooks or default_recovery_hooks()
    recovered: list[dict[str, Any]] = []
    for discovered_path, discovered in pending_credential_recovery_journals(registry):
        if discovered.get("provider") != provider:
            continue
        profile_id = str(discovered.get("profile", ""))
        target = registry.profiles.get(profile_id)
        if target is None or target.provider != provider or target.safety_policy != "worker":
            raise ValueError(
                "pending credential recovery journal is hidden by profile topology drift"
            )
        pending = _read_journal(registry, target)
        if pending is None or pending[0] != discovered_path or pending[1] != discovered:
            raise ValueError("pending credential recovery journal changed during discovery")
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
        _ensure_login_operation_quiescent(journal_path, journal)
        _ensure_keychain_operation_quiescent(journal_path, journal)
        transaction_controls = replace(
            controls,
            keychain=_transactional_keychain(
                controls.keychain,
                journal_path,
                journal,
            ),
        )
        phase = journal.get("phase")
        committed = phase == "committed"
        if not committed:
            _rollback_local_credential(
                transaction_controls,
                target,
                paths,
                journal_path,
                journal,
            )
            if journal.get("bundle_snapshot_ready") is True:
                _restore_bundle(registry, paths, journal_path, journal)
            if journal.get("provisional_snapshot_ready") is True:
                _restore_provisional(
                    registry,
                    target.provider,
                    paths,
                    journal_path,
                    journal,
                )
        _clean_stage_backups(paths, journal_path, journal)
        _clean_exact_temporaries(paths, journal_path, journal)
        _cleanup_keychain(
            transaction_controls,
            target,
            paths,
            journal_path,
            journal,
            committed=committed,
        )
        _remove_stage(target, paths, journal_path, journal)
        journal["transaction_cleanup_complete"] = True
        _write_recovery_journal(
            journal_path,
            journal,
            "transaction-cleanup-complete",
        )
        retained = committed and retain_committed_receipts
        if not retained:
            journal_path.unlink()
            _fsync(journal_path.parent)
        record = {
            "profile": target.id,
            "committed": committed,
            "provider_side_revocation_possible": bool(journal.get("login_started")),
        }
        if retained:
            record.update(
                {
                    "workflow": journal.get("workflow"),
                    "receipt_retained": True,
                }
            )
        recovered.append(record)
    return recovered


def _verify_committed_receipt(
    registry: Registry,
    receipt: dict[str, Any],
    hooks: RecoveryHooks,
    allow_keychain_prompt: bool,
) -> dict[str, Any]:
    profile_id = str(receipt["profile"])
    workflow = str(receipt["workflow"])
    target = registry.require_profile(profile_id)
    if target.safety_policy != "worker":
        raise ValueError("committed credential receipt is hidden by profile policy drift")
    hooks.refresh_anchors(registry, target.provider, allow_keychain_prompt)
    proofs: dict[str, tuple[dict[str, Any], dict[str, Any]]] = {}
    blockers: dict[str, str] = {}
    fingerprints: dict[str, str] = {}
    for worker in _workers(registry, target.provider):
        try:
            proof, raw_source = hooks.prove(registry, worker, allow_keychain_prompt)
            source = _normalize_source_contract(hooks, worker, raw_source)
            fingerprint = _identity_fingerprint(proof, worker)
            if fingerprint in fingerprints:
                raise ValueError("duplicate_worker_identity")
            fingerprints[fingerprint] = worker.id
            proofs[worker.id] = proof, source
        except (OSError, TimeoutError, ValueError) as exc:
            blockers[worker.id] = type(exc).__name__

    pending_initialization: list[str] = []
    provisional_workers: list[str] = []
    bundle = _bundle_present(registry, target.provider)
    provisional = _read_provisional_batch(registry, target.provider)
    if bundle:
        if provisional is not None:
            raise ValueError("committed credential receipt has conflicting identity metadata")
        for worker_id, (proof, source) in proofs.items():
            worker = registry.require_profile(worker_id)
            conflict = identity_binding_conflict(registry, worker, proof, source)
            if conflict is not None:
                blockers[worker_id] = conflict
    elif workflow == "initialize" and provisional is not None:
        records = provisional["workers"]
        provisional_workers = sorted(records)
        pending_initialization = sorted(set(provisional["expected_workers"]) - set(records))
        if profile_id not in records:
            raise ValueError(
                "committed initialization receipt is absent from its provisional batch"
            )
        for worker_id, record in records.items():
            if worker_id not in proofs:
                blockers[worker_id] = "fresh_proof_unavailable"
                continue
            worker = registry.require_profile(worker_id)
            observed = _provisional_record(
                hooks,
                worker,
                proofs[worker_id][0],
                proofs[worker_id][1],
                str(record["transaction_generation"]),
            )
            if observed != record:
                blockers[worker_id] = "provisional_identity_drift"
    else:
        raise ValueError("committed credential receipt has no matching identity generation")

    for worker_id, (proof, _source) in proofs.items():
        if worker_id not in blockers:
            store_quota(registry, registry.require_profile(worker_id), proof)
    ready = bundle and not blockers and len(proofs) == len(_workers(registry, target.provider))
    return {
        "profile": profile_id,
        "provider": target.provider,
        "credential_recovered": workflow == "recover",
        "credential_initialized": workflow == "initialize",
        "workflow": f"{workflow}-login",
        "provider_ready": ready,
        "blocked_profiles": sorted(blockers),
        "pending_initialization": pending_initialization,
        "provisional_workers": provisional_workers,
        "enabled": False,
        "provider_login_invoked": False,
        "browser_mode": False,
        "replayed_committed_transaction": True,
        "provider_side_revocation_possible": bool(receipt.get("provider_side_revocation_possible")),
        "provider_side_revocation_locally_reversible": False,
        "next_step": (
            "run the existing explicit profile enable gate for each worker"
            if ready
            else "review this committed replay receipt before any new explicit login"
        ),
    }


def _consume_committed_receipt(
    registry: Registry,
    profile: Profile,
    journal_path: Path,
    journal: dict[str, Any],
) -> None:
    observed = _read_journal(registry, profile)
    if observed is None or observed[0] != journal_path or observed[1] != journal:
        raise ValueError("committed credential replay receipt changed during verification")
    if (
        journal.get("phase") != "committed"
        or journal.get("transaction_cleanup_complete") is not True
        or journal.get("keychain_operation") is not None
    ):
        raise ValueError("committed credential replay receipt is not terminal")
    journal_path.unlink()
    _fsync(journal_path.parent)


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
            prior = recover_pending_profile_recoveries(
                current,
                target.provider,
                hooks=controls,
                retain_committed_receipts=True,
            )
            committed_prior = [record for record in prior if record.get("committed") is True]
            if committed_prior:
                if len(committed_prior) != 1:
                    raise ValueError("multiple committed credential replay receipts require review")
                receipt = committed_prior[0]
                receipt_profile = current.require_profile(str(receipt["profile"]))
                pending_receipt = _read_journal(current, receipt_profile)
                if pending_receipt is None:
                    raise ValueError("committed credential replay receipt disappeared")
                receipt_path, receipt_journal = pending_receipt
                receipt_controls = replace(
                    controls,
                    keychain=_transactional_keychain(
                        controls.keychain,
                        receipt_path,
                        receipt_journal,
                    ),
                )
                result = _verify_committed_receipt(
                    current,
                    receipt,
                    receipt_controls,
                    allow_keychain_prompt,
                )
                result["recovered_prior_transactions"] = prior
                result["requested_profile"] = profile_id
                result["requested_workflow"] = f"{workflow}-login"
                _consume_committed_receipt(
                    current,
                    receipt_profile,
                    receipt_path,
                    receipt_journal,
                )
                return result
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
                    set(working_batch["expected_workers"]) - set(working_batch["workers"])
                )
                raise ValueError(
                    f"worker {target.id} is already recorded in the provisional identity batch; "
                    "initialize a pending worker instead: " + ", ".join(pending)
                )
            _preflight_stable_credential(target)
            controls.inspect_source(current, target, allow_keychain_prompt)

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
            controls = replace(
                controls,
                keychain=_transactional_keychain(
                    controls.keychain,
                    journal_path,
                    journal,
                ),
            )
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

            def child_started(pid: int, start: str, pgid: int) -> None:
                if pgid != pid:
                    raise ValueError("provider login must own a detached process group")
                journal.update(
                    {
                        "login_started": True,
                        "login_pid": pid,
                        "login_start": start,
                        "login_pgid": pgid,
                    }
                )
                _write_journal(journal_path, journal, "login-running")

            status = controls.login(argv, _login_environment(stage), stage.home, child_started)
            journal.pop("login_pid", None)
            journal.pop("login_start", None)
            journal.pop("login_pgid", None)
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
                ready = not blockers and len(proofs) == len(_workers(current, target.provider))
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
                    journal_path,
                    journal,
                )
                journal["provisional_snapshot_ready"] = True
                _record_stage_manifest(stage.home, journal)
                _write_journal(journal_path, journal, "provisional-backup-ready")
                provisional_path = _provisional_path(current, target.provider)
                provisional_guard = _provisional_guard_path(current, target.provider)
                guard_payload = _provisional_guard_payload(
                    current,
                    target.provider,
                    updated_batch,
                )
                journal["provisional_forward_sha256"] = _json_payload_sha256(updated_batch)
                journal["provisional_guard_forward_sha256"] = _json_payload_sha256(guard_payload)
                _write_journal(
                    journal_path,
                    journal,
                    "provisional-install-authorized",
                )
                _install_metadata_payload(
                    target=provisional_path,
                    temporary=paths["provisional_install_temp"],
                    temporary_cleanup=paths["provisional_install_temp_cleanup"],
                    original_quarantine=paths["provisional_original_quarantine"],
                    payload=updated_batch,
                    existed=bool(journal["provisional_existed"]),
                    key="provisional",
                    label="provider provisional identity batch",
                    journal_path=journal_path,
                    journal=journal,
                )
                _install_metadata_payload(
                    target=provisional_guard,
                    temporary=paths["provisional_guard_install_temp"],
                    temporary_cleanup=paths["provisional_guard_install_temp_cleanup"],
                    original_quarantine=paths["provisional_guard_original_quarantine"],
                    payload=guard_payload,
                    existed=bool(journal["provisional_guard_existed"]),
                    key="provisional_guard",
                    label="provider initialization locator",
                    journal_path=journal_path,
                    journal=journal,
                )
                persisted_batch = updated_batch
                _write_journal(journal_path, journal, "provisional-installed")
            if ready:
                _validate_stage(target, stage.home, journal)
                _write_journal(journal_path, journal, "bundle-backup-running")
                _snapshot_bundle(current, paths, journal_path, journal)
                journal["bundle_snapshot_ready"] = True
                _record_stage_manifest(stage.home, journal)
                _write_journal(journal_path, journal, "bundle-backup-ready")
                adopted_at = utc_now()
                planned_bundle = build_provider_identity_bundle(
                    current,
                    target.provider,
                    proofs,
                    allow_keychain_prompt=allow_keychain_prompt,
                    adopted_at=adopted_at,
                )
                journal["bundle_forward_sha256"] = _json_payload_sha256(planned_bundle)
                _write_journal(journal_path, journal, "bundle-install-authorized")
                bundle_path = identity_bundle_path(current, target.provider)

                def require_bundle_snapshot_original() -> None:
                    _require_snapshot_original(
                        bundle_path,
                        existed=bool(journal["bundle_existed"]),
                        key="bundle",
                        label="provider identity bundle",
                        journal=journal,
                    )
                    raise _BundlePlanValidated

                try:
                    controls.install_bundle(
                        current,
                        target.provider,
                        planned_bundle,
                        require_bundle_snapshot_original,
                    )
                except _BundlePlanValidated:
                    pass
                else:
                    raise ValueError(
                        "provider identity bundle validator bypassed its pre-install fence"
                    )
                _install_metadata_payload(
                    target=bundle_path,
                    temporary=paths["bundle_install_temp"],
                    temporary_cleanup=paths["bundle_install_temp_cleanup"],
                    original_quarantine=paths["bundle_original_quarantine"],
                    payload=planned_bundle,
                    existed=bool(journal["bundle_existed"]),
                    key="bundle",
                    label="provider identity bundle",
                    journal_path=journal_path,
                    journal=journal,
                )
                _write_journal(journal_path, journal, "binding-installed")
                if workflow == "initialize":
                    _private_file(
                        provisional_path,
                        "completed provider provisional identity batch",
                    )
                    _private_file(
                        provisional_guard,
                        "completed provider initialization locator",
                    )
                    journal["provisional_forward_absent"] = True
                    journal["provisional_guard_forward_absent"] = True
                    _write_journal(
                        journal_path,
                        journal,
                        "provisional-remove-authorized",
                    )
                    provisional_state, provisional_generation = _snapshot_state(
                        provisional_path,
                        existed=bool(journal["provisional_existed"]),
                        key="provisional",
                        label="provider provisional identity batch",
                        journal=journal,
                    )
                    if provisional_state != "forward":
                        raise ValueError(
                            "provider provisional identity batch changed before removal"
                        )
                    if provisional_generation is None:
                        raise ValueError(
                            "provider provisional identity batch generation is unavailable"
                        )
                    _quarantine_owned_generation(
                        provisional_path,
                        paths["provisional_restore_quarantine"],
                        provisional_generation,
                        key="provisional-forward-rollback",
                        label="provider provisional identity batch",
                        journal_path=journal_path,
                        journal=journal,
                    )
                    guard_state, guard_generation = _snapshot_state(
                        provisional_guard,
                        existed=bool(journal["provisional_guard_existed"]),
                        key="provisional_guard",
                        label="provider initialization locator",
                        journal=journal,
                    )
                    if guard_state != "forward":
                        raise ValueError("provider initialization locator changed before removal")
                    if guard_generation is None:
                        raise ValueError(
                            "provider initialization locator generation is unavailable"
                        )
                    _quarantine_owned_generation(
                        provisional_guard,
                        paths["provisional_guard_restore_quarantine"],
                        guard_generation,
                        key="provisional_guard-forward-rollback",
                        label="provider initialization locator",
                        journal_path=journal_path,
                        journal=journal,
                    )
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
            _clean_stage_backups(paths, journal_path, journal)
            _clean_exact_temporaries(paths, journal_path, journal)
            _cleanup_keychain(
                controls,
                target,
                paths,
                journal_path,
                journal,
                committed=True,
            )
            _remove_stage(target, paths, journal_path, journal)
            journal["transaction_cleanup_complete"] = True
            _write_recovery_journal(
                journal_path,
                journal,
                "transaction-cleanup-complete",
            )
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
                    retain_committed_receipts=True,
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
