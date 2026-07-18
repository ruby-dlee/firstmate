from __future__ import annotations

import base64
import json
import os
import shutil
import stat
import tempfile
import uuid
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any

from .models import Profile, Registry
from .paths import ensure_private_dir
from .provision import provision_profile
from .quota import QuotaCacheSnapshot, restore_quota_cache
from .util import atomic_write_json

CODEX_AUTH_FILE = "auth.json"


@dataclass(frozen=True)
class CodexAuthTransaction:
    target_auth: Path
    backup_auth: Path | None
    installed_stat: tuple[int, int, int, int]
    journal_path: Path


def _regular_file_stat(path: Path, label: str) -> os.stat_result:
    try:
        current = path.lstat()
    except FileNotFoundError as exc:
        raise ValueError(f"{label} is missing: {path}") from exc
    if not stat.S_ISREG(current.st_mode):
        raise ValueError(f"{label} must be a regular file: {path}")
    if current.st_uid != os.getuid():
        raise ValueError(f"{label} must be owned by the current user: {path}")
    return current


def _private_directory(path: Path, label: str) -> None:
    try:
        current = path.lstat()
    except FileNotFoundError as exc:
        raise ValueError(f"{label} is missing: {path}") from exc
    if not stat.S_ISDIR(current.st_mode):
        raise ValueError(f"{label} must be a regular directory: {path}")
    if current.st_uid != os.getuid():
        raise ValueError(f"{label} must be owned by the current user: {path}")
    if stat.S_IMODE(current.st_mode) & 0o077:
        raise ValueError(f"{label} must not grant group/world access: {path}")


def _stat_identity(current: os.stat_result) -> tuple[int, int, int, int]:
    return (current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns)


def _encoded_stat(current: tuple[int, int, int, int] | None) -> list[int] | None:
    return list(current) if current is not None else None


def _decoded_stat(value: Any, label: str) -> tuple[int, int, int, int] | None:
    if value is None:
        return None
    if (
        not isinstance(value, list)
        or len(value) != 4
        or not all(isinstance(item, int) and not isinstance(item, bool) for item in value)
    ):
        raise ValueError(f"invalid {label} in Codex auth transaction journal")
    return tuple(value)  # type: ignore[return-value]


def _journal_path(registry: Registry, target: Profile) -> Path:
    return registry.settings.state_dir / "transactions" / f"codex-auth-{target.id}.json"


def _snapshot_payload(snapshot: QuotaCacheSnapshot) -> dict[str, Any]:
    return {
        "existed": snapshot.existed,
        "payload": base64.b64encode(snapshot.payload).decode("ascii"),
        "mode": snapshot.mode,
    }


def _snapshot_from_payload(value: Any) -> QuotaCacheSnapshot:
    if not isinstance(value, dict) or not isinstance(value.get("existed"), bool):
        raise ValueError("invalid quota snapshot in Codex auth transaction journal")
    encoded = value.get("payload", "")
    mode = value.get("mode", 0o600)
    if not isinstance(encoded, str) or not isinstance(mode, int) or isinstance(mode, bool):
        raise ValueError("invalid quota snapshot in Codex auth transaction journal")
    if mode < 0 or mode > 0o777 or mode & 0o077:
        raise ValueError("unsafe quota snapshot mode in Codex auth transaction journal")
    try:
        payload = base64.b64decode(encoded, validate=True)
    except ValueError as exc:
        raise ValueError("invalid quota snapshot in Codex auth transaction journal") from exc
    return QuotaCacheSnapshot(bool(value["existed"]), payload, mode)


def _read_journal(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ValueError(f"Codex auth transaction journal is missing: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ValueError(f"Codex auth transaction journal is invalid: {path}") from exc
    if not isinstance(value, dict) or value.get("schema") != 1:
        raise ValueError(f"Codex auth transaction journal is invalid: {path}")
    return value


def _validate_journal_paths(
    registry: Registry,
    target: Profile,
    journal: dict[str, Any],
) -> tuple[Path, Path | None, Path]:
    if journal.get("profile") != target.id or journal.get("provider") != "codex":
        raise ValueError("Codex auth transaction journal targets another profile")
    target_auth = Path(str(journal.get("target_auth", "")))
    if target_auth != target.home / CODEX_AUTH_FILE:
        raise ValueError("Codex auth transaction journal target is outside the profile")
    backup_raw = journal.get("backup_auth")
    if backup_raw is not None and not isinstance(backup_raw, str):
        raise ValueError("Codex auth transaction backup path is invalid")
    backup = Path(backup_raw) if isinstance(backup_raw, str) else None
    if backup is not None and (
        backup.parent != target.home or not backup.name.startswith(f".{CODEX_AUTH_FILE}.backup-")
    ):
        raise ValueError("Codex auth transaction backup is outside the profile")
    temporary = Path(str(journal.get("temporary_auth", "")))
    if temporary.parent != target.home or not temporary.name.startswith(f".{CODEX_AUTH_FILE}.new-"):
        raise ValueError("Codex auth transaction temporary file is outside the profile")
    expected_journal = _journal_path(registry, target)
    if Path(str(journal.get("journal_path", ""))) != expected_journal:
        raise ValueError("Codex auth transaction journal path is inconsistent")
    return target_auth, backup, temporary


def _open_no_follow(path: Path) -> int:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    return os.open(path, flags)


def _copy_regular_file(source: Path, destination: Path) -> None:
    source_stat = _regular_file_stat(source, "Codex staged auth")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    source_fd = _open_no_follow(source)
    try:
        if _stat_identity(os.fstat(source_fd)) != _stat_identity(source_stat):
            raise ValueError("Codex staged auth changed while opening it")
        destination_fd = os.open(destination, flags, 0o600)
        try:
            while True:
                chunk = os.read(source_fd, 1024 * 1024)
                if not chunk:
                    break
                view = memoryview(chunk)
                while view:
                    written = os.write(destination_fd, view)
                    view = view[written:]
            os.fchmod(destination_fd, 0o600)
            os.fsync(destination_fd)
        finally:
            os.close(destination_fd)
    finally:
        os.close(source_fd)


def create_codex_login_stage(profile: Profile) -> Profile:
    ensure_private_dir(profile.home.parent)
    _private_directory(profile.home.parent, "managed Codex accounts directory")
    stage = Path(
        tempfile.mkdtemp(
            prefix=f".{profile.home.name}.login-",
            dir=profile.home.parent,
        )
    )
    stage.chmod(0o700)
    config = stage / "config.toml"
    config.write_text('cli_auth_credentials_store = "file"\n', encoding="utf-8")
    config.chmod(0o600)
    return replace(profile, home=stage, enabled=False)


def _remove_private_tree(path: Path) -> None:
    if path.is_symlink():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path)


def discard_codex_stage(stage: Profile, target: Profile) -> None:
    expected_prefix = f".{target.home.name}.login-"
    if stage.home.parent != target.home.parent or not stage.home.name.startswith(expected_prefix):
        raise ValueError(f"refusing to discard unrecognized Codex stage: {stage.home}")
    _remove_private_tree(stage.home)


def discard_codex_promotion(promotion: Profile, target: Profile) -> None:
    expected_prefix = f".{target.home.name}.promote-"
    if promotion.home.parent != target.home.parent or not promotion.home.name.startswith(
        expected_prefix
    ):
        raise ValueError(f"refusing to discard unrecognized Codex promotion: {promotion.home}")
    _remove_private_tree(promotion.home)


def prepare_codex_promotion(
    registry: Registry,
    target: Profile,
    stage: Profile,
) -> Profile:
    staged_auth = stage.home / CODEX_AUTH_FILE
    _private_directory(stage.home, "Codex staging home")
    _regular_file_stat(staged_auth, "Codex staged auth")
    if target.home.is_symlink():
        raise ValueError(f"managed Codex profile home cannot be a symlink: {target.home}")
    provision_profile(registry, target)
    _private_directory(target.home, "managed Codex profile home")
    promotion = Path(
        tempfile.mkdtemp(
            prefix=f".{target.home.name}.promote-",
            dir=target.home.parent,
        )
    )
    promotion.chmod(0o700)
    try:
        shutil.copytree(
            target.home,
            promotion,
            symlinks=True,
            copy_function=shutil.copy2,
            dirs_exist_ok=True,
            ignore=shutil.ignore_patterns(".agent-fleet-quota-cache"),
        )
        destination = promotion / CODEX_AUTH_FILE
        if destination.exists() or destination.is_symlink():
            if destination.is_symlink() or not destination.is_file():
                raise ValueError("managed Codex auth.json must be a regular file")
            destination.unlink()
        temporary = promotion / f".{CODEX_AUTH_FILE}.new-{uuid.uuid4().hex}"
        _copy_regular_file(staged_auth, temporary)
        os.replace(temporary, destination)
        destination.chmod(0o600)
        _fsync_directory(promotion)
        promotion_profile = replace(target, home=promotion, enabled=False)
        provision_profile(registry, promotion_profile)
        return promotion_profile
    except BaseException:
        _remove_private_tree(promotion)
        raise


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _validate_promotion(target: Profile, promotion: Profile) -> Path:
    expected_prefix = f".{target.home.name}.promote-"
    if promotion.home.parent != target.home.parent or not promotion.home.name.startswith(
        expected_prefix
    ):
        raise ValueError(f"refusing to activate unrecognized Codex promotion: {promotion.home}")
    _private_directory(target.home, "managed Codex profile home")
    _private_directory(promotion.home, "Codex promotion home")
    source = promotion.home / CODEX_AUTH_FILE
    _regular_file_stat(source, "Codex promotion auth")
    return source


def activate_codex_promotion(
    registry: Registry,
    target: Profile,
    promotion: Profile,
    quota_snapshot: QuotaCacheSnapshot,
) -> CodexAuthTransaction:
    source = _validate_promotion(target, promotion)
    target_auth = target.home / CODEX_AUTH_FILE
    original_stat: os.stat_result | None = None
    backup: Path | None = None
    if target_auth.exists() or target_auth.is_symlink():
        original_stat = _regular_file_stat(target_auth, "managed Codex auth")
        if stat.S_IMODE(original_stat.st_mode) & 0o077:
            raise ValueError("managed Codex auth must not grant group/world access")
        backup = target.home / f".{CODEX_AUTH_FILE}.backup-{uuid.uuid4().hex}"
        _copy_regular_file(target_auth, backup)
    temporary = target.home / f".{CODEX_AUTH_FILE}.new-{uuid.uuid4().hex}"
    journal_path = _journal_path(registry, target)
    if journal_path.exists() or journal_path.is_symlink():
        raise ValueError(f"unfinished Codex auth transaction requires recovery: {journal_path}")
    try:
        _copy_regular_file(source, temporary)
        if original_stat is not None:
            if _stat_identity(
                _regular_file_stat(target_auth, "managed Codex auth")
            ) != _stat_identity(original_stat):
                raise ValueError("managed Codex auth changed during promotion")
        elif target_auth.exists() or target_auth.is_symlink():
            raise ValueError("managed Codex auth appeared during promotion")
        installed_stat = _stat_identity(_regular_file_stat(temporary, "prepared Codex auth"))
        journal = {
            "schema": 1,
            "profile": target.id,
            "provider": "codex",
            "phase": "prepared",
            "target_auth": str(target_auth),
            "backup_auth": str(backup) if backup is not None else None,
            "temporary_auth": str(temporary),
            "original_stat": _encoded_stat(
                _stat_identity(original_stat) if original_stat is not None else None
            ),
            "installed_stat": _encoded_stat(installed_stat),
            "quota_snapshot": _snapshot_payload(quota_snapshot),
            "journal_path": str(journal_path),
        }
        # This durable intent record must reach disk before auth.json can change.
        # A process crash after the replace is therefore always recoverable.
        atomic_write_json(journal_path, journal)
        _fsync_directory(journal_path.parent)
        os.replace(temporary, target_auth)
        target_auth.chmod(0o600)
        installed = _regular_file_stat(target_auth, "promoted Codex auth")
        if _stat_identity(installed) != installed_stat:
            raise ValueError("promoted Codex auth identity changed during replace")
        _fsync_directory(target.home)
        return CodexAuthTransaction(
            target_auth=target_auth,
            backup_auth=backup,
            installed_stat=_stat_identity(installed),
            journal_path=journal_path,
        )
    except BaseException:
        temporary.unlink(missing_ok=True)
        if backup is not None and not journal_path.exists():
            backup.unlink(missing_ok=True)
        raise


def _validate_transaction(
    registry: Registry,
    target: Profile,
    transaction: CodexAuthTransaction,
) -> dict[str, Any]:
    expected = target.home / CODEX_AUTH_FILE
    if transaction.target_auth != expected:
        raise ValueError("Codex auth transaction does not belong to the target profile")
    if transaction.journal_path != _journal_path(registry, target):
        raise ValueError("Codex auth transaction journal does not belong to the target profile")
    journal = _read_journal(transaction.journal_path)
    target_auth, backup, _ = _validate_journal_paths(registry, target, journal)
    if target_auth != transaction.target_auth or backup != transaction.backup_auth:
        raise ValueError("Codex auth transaction disagrees with its durable journal")
    if _decoded_stat(journal.get("installed_stat"), "installed stat") != (
        transaction.installed_stat
    ):
        raise ValueError("Codex auth transaction stat disagrees with its durable journal")
    current = _regular_file_stat(expected, "promoted Codex auth")
    if _stat_identity(current) != transaction.installed_stat:
        raise ValueError("promoted Codex auth changed before transaction completion")
    return journal


def rollback_codex_promotion(
    registry: Registry,
    target: Profile,
    transaction: CodexAuthTransaction,
) -> None:
    _private_directory(target.home, "managed Codex profile home")
    _validate_transaction(registry, target, transaction)
    backup = transaction.backup_auth
    if backup is None:
        transaction.target_auth.unlink()
    else:
        expected_prefix = f".{CODEX_AUTH_FILE}.backup-"
        if backup.parent != target.home or not backup.name.startswith(expected_prefix):
            raise ValueError("Codex auth backup is outside the target profile")
        _regular_file_stat(backup, "Codex auth backup")
        os.replace(backup, transaction.target_auth)
        transaction.target_auth.chmod(0o600)
    _fsync_directory(target.home)
    journal = _read_journal(transaction.journal_path)
    restore_quota_cache(
        registry,
        target.id,
        _snapshot_from_payload(journal.get("quota_snapshot")),
    )
    transaction.journal_path.unlink()
    _fsync_directory(transaction.journal_path.parent)


def finalize_codex_promotion(
    registry: Registry,
    target: Profile,
    transaction: CodexAuthTransaction,
) -> None:
    _private_directory(target.home, "managed Codex profile home")
    journal = _validate_transaction(registry, target, transaction)
    journal["phase"] = "committed"
    atomic_write_json(transaction.journal_path, journal)
    _fsync_directory(transaction.journal_path.parent)
    backup = transaction.backup_auth
    if backup is not None:
        expected_prefix = f".{CODEX_AUTH_FILE}.backup-"
        if backup.parent != target.home or not backup.name.startswith(expected_prefix):
            raise ValueError("Codex auth backup is outside the target profile")
        _regular_file_stat(backup, "Codex auth backup")
        backup.unlink()
        _fsync_directory(target.home)
    transaction.journal_path.unlink()
    _fsync_directory(transaction.journal_path.parent)


def recover_pending_codex_transaction(registry: Registry, target: Profile) -> bool:
    """Recover one interrupted promotion while the caller owns the provider lock."""

    if target.provider != "codex":
        return False
    journal_path = _journal_path(registry, target)
    if not journal_path.exists():
        return False
    journal = _read_journal(journal_path)
    target_auth, backup, temporary = _validate_journal_paths(registry, target, journal)
    installed_stat = _decoded_stat(journal.get("installed_stat"), "installed stat")
    original_stat = _decoded_stat(journal.get("original_stat"), "original stat")
    if installed_stat is None:
        raise ValueError("Codex auth transaction has no installed stat")
    phase = journal.get("phase")
    if phase not in {"prepared", "committed"}:
        raise ValueError("Codex auth transaction has an invalid phase")
    _private_directory(target.home, "managed Codex profile home")

    current_stat: tuple[int, int, int, int] | None
    if target_auth.exists() or target_auth.is_symlink():
        current_stat = _stat_identity(_regular_file_stat(target_auth, "managed Codex auth"))
    else:
        current_stat = None

    if phase == "committed":
        if current_stat != installed_stat:
            raise ValueError("committed Codex auth changed before crash recovery")
    else:
        if current_stat == installed_stat:
            if backup is None:
                target_auth.unlink()
            else:
                _regular_file_stat(backup, "Codex auth backup")
                os.replace(backup, target_auth)
                target_auth.chmod(0o600)
            _fsync_directory(target.home)
        elif current_stat != original_stat:
            raise ValueError("Codex auth changed outside the interrupted transaction")
        # Restore normalized quota evidence before deleting any recovery artifact.
        restore_quota_cache(
            registry,
            target.id,
            _snapshot_from_payload(journal.get("quota_snapshot")),
        )

    # Cleanup happens only after rollback+quota restore or a durable commit.
    temporary.unlink(missing_ok=True)
    if backup is not None:
        backup.unlink(missing_ok=True)
    journal_path.unlink()
    _fsync_directory(target.home)
    _fsync_directory(journal_path.parent)
    return True


def recover_pending_codex_transactions(registry: Registry, provider: str) -> list[str]:
    if provider != "codex":
        return []
    recovered: list[str] = []
    for profile in registry.profiles.values():
        if profile.provider == provider and recover_pending_codex_transaction(registry, profile):
            recovered.append(profile.id)
    return recovered
