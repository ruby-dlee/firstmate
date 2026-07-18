from __future__ import annotations

import hashlib
import json
import os
import stat
import tomllib
from dataclasses import replace
from pathlib import Path
from typing import Any

from . import __version__
from .models import SHARED_WORKFLOW_ENTRIES, Profile, ProviderConfig, Registry
from .paths import ensure_private_dir
from .projects import (
    TrustedProject,
    assert_project_controls_absent,
    project_control_file,
    registered_trusted_projects,
    resolve_trusted_project,
)
from .providers import (
    agent_fleet_entrypoint_path,
    credential_storage_ready,
    session_hook_command,
)
from .util import atomic_write_bytes, atomic_write_json, read_private_bytes, read_private_json

HOOK_MARKERS = (" hook session-start", " hook turn-end")
HOOK_MARKER_FILE = ".agent-fleet-hooks.json"
PROVIDER_BINARY_MARKER_FILE = ".agent-fleet-provider-binary.json"

def _read_json_object(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"refusing to modify invalid JSON: {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError(f"refusing to modify non-object JSON: {path}")
    return value


def _read_owned_json_object(path: Path) -> dict[str, Any]:
    try:
        value = read_private_json(path, label="managed JSON")
    except FileNotFoundError:
        return {}
    if not isinstance(value, dict):
        raise ValueError(f"refusing to modify non-object JSON: {path}")
    return value


def _assert_safe_file_ancestry(path: Path, description: str) -> None:
    current = path.absolute().parent
    while True:
        metadata = current.lstat()
        if not stat.S_ISDIR(metadata.st_mode):
            raise ValueError(f"{description} has symlinked or non-directory ancestry: {path}")
        mode = stat.S_IMODE(metadata.st_mode)
        if mode & 0o022 and not (mode & stat.S_ISVTX and metadata.st_uid == 0):
            raise ValueError(f"{description} has group/world-writable ancestry: {path}")
        if current == current.parent:
            return
        current = current.parent


def _opened_regular_identity(
    path: Path,
    description: str,
    *,
    require_owner: bool,
    require_executable: bool,
    allow_symlink: bool,
) -> dict[str, Any]:
    configured = path.absolute()
    _assert_safe_file_ancestry(configured, description)
    try:
        configured_metadata = configured.lstat()
    except OSError as exc:
        raise ValueError(f"{description} is not an existing safe file: {path}") from exc
    if not allow_symlink and not stat.S_ISREG(configured_metadata.st_mode):
        raise ValueError(f"{description} must be a current-user regular file: {path}")
    try:
        resolved = configured.resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise ValueError(f"{description} is not an existing safe file: {path}") from exc
    _assert_safe_file_ancestry(resolved, description)
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(resolved, flags)
    except OSError as exc:
        raise ValueError(f"{description} is not an openable regular file: {path}") from exc
    try:
        opened = os.fstat(descriptor)
        current = resolved.lstat()
        identity = (opened.st_dev, opened.st_ino)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 1
            or identity != (current.st_dev, current.st_ino)
        ):
            raise ValueError(f"{description} must resolve to one stable regular file: {path}")
        if require_owner and opened.st_uid != os.getuid():
            raise ValueError(f"{description} must be a current-user regular file: {path}")
        if stat.S_IMODE(opened.st_mode) & 0o022:
            raise ValueError(f"{description} must not be group/world writable: {path}")
        if require_executable and not os.access(resolved, os.X_OK):
            raise ValueError(f"{description} must be executable: {path}")
        digest = hashlib.sha256()
        while chunk := os.read(descriptor, 1024 * 1024):
            digest.update(chunk)
        after_open = os.fstat(descriptor)
        after_path = resolved.lstat()
        if (
            (after_open.st_dev, after_open.st_ino) != identity
            or (after_path.st_dev, after_path.st_ino) != identity
            or after_open.st_size != opened.st_size
            or after_open.st_mtime_ns != opened.st_mtime_ns
            or after_open.st_ctime_ns != opened.st_ctime_ns
            or configured.resolve(strict=True) != resolved
        ):
            raise ValueError(f"{description} changed while it was being verified: {path}")
    finally:
        os.close(descriptor)
    return {
        "configured_path": str(path),
        "resolved_path": str(resolved),
        "device": opened.st_dev,
        "inode": opened.st_ino,
        "uid": opened.st_uid,
        "size": opened.st_size,
        "mode": stat.S_IMODE(opened.st_mode),
        "nlink": opened.st_nlink,
        "modified_ns": opened.st_mtime_ns,
        "sha256": digest.hexdigest(),
    }


def _source_hash(source: Path | None) -> str | None:
    if source is None:
        return None
    if not source.exists() and not source.is_symlink():
        raise ValueError(f"configured hook source is missing: {source}")
    return str(
        _opened_regular_identity(
            source,
            "hook source",
            require_owner=True,
            require_executable=False,
            allow_symlink=False,
        )["sha256"]
    )


def _provider_binary_identity(provider: ProviderConfig) -> dict[str, Any]:
    identity = _opened_regular_identity(
        provider.binary,
        f"{provider.name} provider binary",
        require_owner=False,
        require_executable=True,
        allow_symlink=False,
    )
    if identity["uid"] not in {0, os.getuid()}:
        raise ValueError(f"{provider.name} provider binary must be owned by current user or root")
    return identity


def _agent_fleet_entrypoint_identity() -> dict[str, Any]:
    identity = _opened_regular_identity(
        agent_fleet_entrypoint_path(),
        "Agent Fleet SessionStart entrypoint",
        require_owner=False,
        require_executable=True,
        allow_symlink=False,
    )
    if identity["uid"] not in {0, os.getuid()}:
        raise ValueError(
            "Agent Fleet SessionStart entrypoint must be owned by current user or root"
        )
    return identity


def _verified_session_hook(registry: Registry) -> tuple[str, dict[str, Any]]:
    identity = _agent_fleet_entrypoint_identity()
    if registry.config_path is None:
        raise ValueError("loaded registry path is unavailable for managed hooks")
    command = session_hook_command(
        registry.config_path,
        Path(str(identity["resolved_path"])),
    )
    return command, identity


def verified_agent_fleet_hook_entrypoint() -> Path:
    """Return the freshly verified release-local hook entrypoint."""

    return Path(str(_agent_fleet_entrypoint_identity()["resolved_path"]))


def verified_configured_provider_binary(registry: Registry, provider_name: str) -> Path:
    """Verify a configured non-symlink binary before intentional bootstrap use."""

    identity = _provider_binary_identity(registry.require_provider(provider_name))
    return Path(str(identity["resolved_path"]))


def verified_provider_binary(registry: Registry, profile: Profile) -> Path:
    """Return the freshly marker-verified regular executable for one profile."""

    provider = registry.require_provider(profile.provider)
    marker = _read_owned_json_object(profile.home / PROVIDER_BINARY_MARKER_FILE)
    expected = _provider_binary_identity(provider)
    if marker != {
        "schema": 1,
        "profile": profile.id,
        "provider": profile.provider,
        "binary": expected,
    }:
        raise ValueError(f"managed provider binary changed since provisioning: {profile.id}")
    return Path(str(expected["resolved_path"]))


def provider_binary_ready(registry: Registry, profile: Profile) -> bool:
    try:
        verified_provider_binary(registry, profile)
    except (OSError, ValueError):
        return False
    return True


def _hook_payload_hash(payload: dict[str, Any]) -> str:
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def _agent_fleet_session_group(command: str) -> dict[str, Any]:
    return {
        "matcher": "startup|resume|clear|compact",
        "hooks": [
            {
                "type": "command",
                "command": command,
                "statusMessage": "Recording Agent Fleet session identity",
            }
        ],
    }


def _agent_fleet_turn_end_group(command: str) -> dict[str, Any]:
    return {
        "matcher": "",
        "hooks": [
            {
                "type": "command",
                "command": command,
                "statusMessage": "Recording FirstMate turn boundary",
            }
        ],
    }


def _declared_source_hooks(source: Path | None) -> dict[str, Any]:
    if source is not None:
        raise ValueError(
            "managed worker hooks must be release-owned; provider hooks_source must be absent"
        )
    return {}


def _managed_hooks(
    source: Path | None,
    session_command: str,
    turn_end_command: str | None,
) -> dict[str, Any]:
    hooks = _declared_source_hooks(source)
    groups = hooks.setdefault("SessionStart", [])
    groups.append(_agent_fleet_session_group(session_command))
    if turn_end_command is not None:
        hooks.setdefault("Stop", []).append(_agent_fleet_turn_end_group(turn_end_command))
    return hooks


def _codex_hook_payload(source: Path | None, command: str) -> dict[str, Any]:
    return {"hooks": _managed_hooks(source, command, None)}


def _claude_hook_payload(
    existing: dict[str, Any],
    source: Path | None,
    session_command: str,
    turn_end_command: str,
) -> dict[str, Any]:
    return {"hooks": _managed_hooks(source, session_command, turn_end_command)}


def _hook_marker_payload(
    profile: Profile,
    provider: ProviderConfig,
    source_hash: str | None,
    session_command: str,
    turn_end_command: str | None,
    agent_fleet_binary: dict[str, Any],
    hooks: dict[str, Any],
) -> dict[str, Any]:
    return {
        "schema": 2,
        "agent_fleet_version": __version__,
        "agent_fleet_binary": agent_fleet_binary,
        "profile": profile.id,
        "provider": profile.provider,
        "source": str(provider.hooks_source) if provider.hooks_source is not None else None,
        "source_hash": source_hash,
        "session_command": session_command,
        "turn_end_command": turn_end_command,
        "hooks_hash": _hook_payload_hash(hooks),
    }


def _hook_marker_matches(
    marker: dict[str, Any],
    profile: Profile,
    provider: ProviderConfig,
    source_hash: str | None,
    session_command: str,
    turn_end_command: str | None,
    agent_fleet_binary: dict[str, Any],
) -> bool:
    return (
        set(marker)
        == {
            "schema",
            "agent_fleet_version",
            "agent_fleet_binary",
            "profile",
            "provider",
            "source",
            "source_hash",
            "session_command",
            "turn_end_command",
            "hooks_hash",
        }
        and marker.get("schema") == 2
        and marker.get("agent_fleet_version") == __version__
        and marker.get("agent_fleet_binary") == agent_fleet_binary
        and marker.get("profile") == profile.id
        and marker.get("provider") == profile.provider
        and marker.get("source")
        == (str(provider.hooks_source) if provider.hooks_source is not None else None)
        and marker.get("source_hash") == source_hash
        and marker.get("session_command") == session_command
        and marker.get("turn_end_command") == turn_end_command
    )


def _install_claude_hooks(
    registry: Registry, profile: Profile, provider: ProviderConfig
) -> None:
    session_command, agent_fleet_binary = _verified_session_hook(registry)
    turn_end_command = session_command.replace(" hook session-start", " hook turn-end")
    source_hash = _source_hash(provider.hooks_source)
    path = profile.home / "settings.json"
    existing = _read_owned_json_object(path)
    payload = _claude_hook_payload(
        existing,
        provider.hooks_source,
        session_command,
        turn_end_command,
    )
    if source_hash != _source_hash(provider.hooks_source):
        raise ValueError("Claude hook source changed during provisioning")
    atomic_write_json(path, payload)
    atomic_write_json(
        profile.home / HOOK_MARKER_FILE,
        _hook_marker_payload(
            profile,
            provider,
            source_hash,
            session_command,
            turn_end_command,
            agent_fleet_binary,
            payload["hooks"],
        ),
    )


def _install_codex_hooks(
    registry: Registry, profile: Profile, provider: ProviderConfig
) -> None:
    session_command, agent_fleet_binary = _verified_session_hook(registry)
    source_hash = _source_hash(provider.hooks_source)
    payload = _codex_hook_payload(provider.hooks_source, session_command)
    if source_hash != _source_hash(provider.hooks_source):
        raise ValueError("Codex hook source changed during provisioning")
    path = profile.home / "hooks.json"
    atomic_write_json(path, payload)
    atomic_write_json(
        profile.home / HOOK_MARKER_FILE,
        _hook_marker_payload(
            profile,
            provider,
            source_hash,
            session_command,
            None,
            agent_fleet_binary,
            payload["hooks"],
        ),
    )


def claude_hooks_ready(registry: Registry, profile: Profile) -> bool:
    provider = registry.require_provider(profile.provider)
    try:
        expected_command, agent_fleet_binary = _verified_session_hook(registry)
        turn_end_command = expected_command.replace(" hook session-start", " hook turn-end")
        source_hash = _source_hash(provider.hooks_source)
        marker = _read_owned_json_object(profile.home / HOOK_MARKER_FILE)
        if not _hook_marker_matches(
            marker,
            profile,
            provider,
            source_hash,
            expected_command,
            turn_end_command,
            agent_fleet_binary,
        ):
            return False
        payload = _read_owned_json_object(profile.home / "settings.json")
        expected = _claude_hook_payload(
            payload,
            provider.hooks_source,
            expected_command,
            turn_end_command,
        )
    except (OSError, ValueError):
        return False
    expected_hooks = expected.get("hooks")
    actual_hooks = payload.get("hooks")
    expected_hash = _hook_payload_hash(expected_hooks)
    return (
        payload == expected
        and actual_hooks == expected_hooks
        and marker.get("hooks_hash") == expected_hash
        and _hook_payload_hash(actual_hooks) == expected_hash
    )


def codex_hooks_ready(registry: Registry, profile: Profile) -> bool:
    provider = registry.require_provider(profile.provider)
    try:
        expected_command, agent_fleet_binary = _verified_session_hook(registry)
        source_hash = _source_hash(provider.hooks_source)
        marker = _read_owned_json_object(profile.home / HOOK_MARKER_FILE)
        if not _hook_marker_matches(
            marker,
            profile,
            provider,
            source_hash,
            expected_command,
            None,
            agent_fleet_binary,
        ):
            return False
        payload = _read_owned_json_object(profile.home / "hooks.json")
        expected = _codex_hook_payload(provider.hooks_source, expected_command)
    except (OSError, ValueError):
        return False
    expected_hash = _hook_payload_hash(expected["hooks"])
    return (
        payload == expected
        and marker.get("hooks_hash") == expected_hash
        and _hook_payload_hash(payload["hooks"]) == expected_hash
    )


def closed_claude_state_payload(registry: Registry) -> dict[str, Any]:
    roots = sorted(
        {
            str(root)
            for project in registered_trusted_projects(registry, "claude")
            for root in {project.active_root, project.canonical_root}
        }
    )
    return {
        "hasCompletedOnboarding": True,
        "projects": {
            root: {
                "hasCompletedProjectOnboarding": True,
                "hasTrustDialogAccepted": True,
            }
            for root in roots
        },
    }


def _install_closed_claude_state(registry: Registry, profile: Profile) -> None:
    path = profile.home / ".claude.json"
    if path.exists() or path.is_symlink():
        _read_owned_json_object(path)
    atomic_write_json(path, closed_claude_state_payload(registry))


def claude_project_ready(
    registry: Registry, profile: Profile, project: TrustedProject
) -> bool:
    try:
        payload = _read_owned_json_object(profile.home / ".claude.json")
    except ValueError:
        return False
    expected = closed_claude_state_payload(registry)
    return payload == expected and all(
        str(root) in expected["projects"]
        for root in {project.active_root, project.canonical_root}
    )


def prepare_profile_launch(
    registry: Registry,
    profile: Profile,
    workspace: Path,
) -> TrustedProject:
    if not profile_is_provisioned(profile):
        raise ValueError(f"profile is not provisioned: {profile.id}")
    if not credential_storage_ready(profile):
        raise ValueError(f"managed credential storage is not ready for {profile.id}")
    if not _profile_plugins_absent(profile):
        raise ValueError(f"managed plugin path is forbidden for {profile.id}")
    if not provider_binary_ready(registry, profile):
        raise ValueError(f"managed provider binary changed since provisioning: {profile.id}")
    project = resolve_trusted_project(registry, profile.provider, workspace)
    assert_project_controls_absent(project, profile.provider)
    if profile.provider == "claude":
        if not claude_project_ready(registry, profile, project):
            raise ValueError(f"Claude project trust bootstrap failed for {profile.id}")
        hook_health = profile_hook_health(registry, profile)
        if not (
            hook_health["agent_fleet_session_hook"] and hook_health["release_owned_hooks"]
        ):
            raise ValueError(f"managed Claude hook set is not ready for {profile.id}")
    else:
        if not _codex_config_ready(profile.home):
            raise ValueError(f"managed Codex config is not ready for {profile.id}")
        if not codex_hooks_ready(registry, profile):
            raise ValueError(f"managed Codex hook set is not ready for {profile.id}")
    return project


def profile_selection_ready(
    registry: Registry,
    profile: Profile,
    workspace: Path,
) -> bool:
    if (
        not credential_storage_ready(profile)
        or not provider_binary_ready(registry, profile)
        or not _profile_plugins_absent(profile)
    ):
        return False
    try:
        project = resolve_trusted_project(registry, profile.provider, workspace)
    except ValueError:
        return False
    if project_control_file(project, profile.provider) is not None:
        return False
    if profile.provider == "claude":
        canonical = replace(
            project,
            active_root=project.canonical_root,
            active_identity=project.canonical_identity,
        )
        hook_health = profile_hook_health(registry, profile)
        return (
            claude_project_ready(registry, profile, canonical)
            and hook_health["agent_fleet_session_hook"]
            and hook_health["release_owned_hooks"]
        )
    return _codex_config_ready(profile.home) and codex_hooks_ready(registry, profile)


def profile_launch_ready(
    registry: Registry,
    profile: Profile,
    workspace: Path,
) -> bool:
    if (
        not credential_storage_ready(profile)
        or not provider_binary_ready(registry, profile)
        or not _profile_plugins_absent(profile)
    ):
        return False
    try:
        project = resolve_trusted_project(registry, profile.provider, workspace)
    except ValueError:
        return False
    if project_control_file(project, profile.provider) is not None:
        return False
    if profile.provider == "claude":
        hook_health = profile_hook_health(registry, profile)
        return (
            claude_project_ready(registry, profile, project)
            and hook_health["agent_fleet_session_hook"]
            and hook_health["release_owned_hooks"]
        )
    return _codex_config_ready(profile.home) and codex_hooks_ready(registry, profile)


CODEX_MANAGED_CONFIG = {"cli_auth_credentials_store": "file", "features": {"hooks": True}}
CODEX_MANAGED_CONFIG_TEXT = 'cli_auth_credentials_store = "file"\n\n[features]\nhooks = true\n'


def _read_closed_codex_config(path: Path) -> dict[str, Any]:
    raw = _read_owned_codex_config(path)
    if raw != CODEX_MANAGED_CONFIG:
        raise ValueError(f"managed Codex config contains unsupported launch controls: {path}")
    return raw


def _read_owned_codex_config(path: Path) -> dict[str, Any]:
    try:
        raw = tomllib.loads(read_private_bytes(path, label="managed Codex config").decode())
    except UnicodeDecodeError as exc:
        raise ValueError(f"invalid Codex config encoding: {path}") from exc
    except tomllib.TOMLDecodeError as exc:
        raise ValueError(f"invalid Codex config: {path}: {exc}") from exc
    return raw


def _assert_existing_profile_config_closed(profile: Profile) -> None:
    if profile.provider == "claude":
        path = profile.home / "settings.json"
        if path.exists() or path.is_symlink():
            _read_owned_json_object(path)
        return
    path = profile.home / "config.toml"
    if path.exists() or path.is_symlink():
        _read_owned_codex_config(path)


def _ensure_codex_config(home: Path) -> None:
    path = home / "config.toml"
    if path.exists() or path.is_symlink():
        _read_owned_codex_config(path)
    atomic_write_bytes(path, CODEX_MANAGED_CONFIG_TEXT.encode("utf-8"))


def _codex_config_ready(home: Path) -> bool:
    path = home / "config.toml"
    try:
        _read_closed_codex_config(path)
    except (OSError, ValueError):
        return False
    return True


def _share_workflow_entries(profile: Profile, provider: ProviderConfig) -> list[str]:
    disallowed = sorted(set(provider.shared_entries) - SHARED_WORKFLOW_ENTRIES[provider.name])
    if disallowed:
        raise ValueError(
            f"providers.{provider.name}.shared_entries contains non-workflow assets: "
            + ", ".join(disallowed)
        )
    if provider.base_home is None:
        return []
    shared: list[str] = []
    flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        home_fd = os.open(profile.home, flags)
    except OSError as exc:
        raise ValueError(f"managed profile home is not a safe directory: {profile.home}") from exc
    try:
        opened = os.fstat(home_fd)
        current = profile.home.lstat()
        if not stat.S_ISDIR(opened.st_mode) or (opened.st_dev, opened.st_ino) != (
            current.st_dev,
            current.st_ino,
        ):
            raise ValueError(f"managed profile home changed during provisioning: {profile.home}")
        for entry in provider.shared_entries:
            source = provider.base_home / entry
            if not source.exists():
                continue
            try:
                destination_stat = os.stat(entry, dir_fd=home_fd, follow_symlinks=False)
            except FileNotFoundError:
                os.symlink(
                    str(source),
                    entry,
                    target_is_directory=source.is_dir(),
                    dir_fd=home_fd,
                )
                destination_stat = os.stat(
                    entry,
                    dir_fd=home_fd,
                    follow_symlinks=False,
                )
            if not stat.S_ISLNK(destination_stat.st_mode):
                raise ValueError(
                    f"refusing to replace existing managed workflow path: {profile.home / entry}"
                )
            if os.readlink(entry, dir_fd=home_fd) != str(source):
                raise ValueError(f"managed shared link points elsewhere: {profile.home / entry}")
            shared.append(entry)
    finally:
        os.close(home_fd)
    return shared


def _remove_exact_legacy_plugin_link(profile: Profile, provider: ProviderConfig) -> None:
    destination = profile.home / "plugins"
    try:
        metadata = destination.lstat()
    except FileNotFoundError:
        return
    expected = provider.base_home / "plugins" if provider.base_home is not None else None
    if (
        expected is None
        or not stat.S_ISLNK(metadata.st_mode)
        or os.readlink(destination) != str(expected)
    ):
        raise ValueError(f"unexpected managed plugin path must be removed manually: {destination}")
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(profile.home, flags)
    try:
        opened = os.fstat(descriptor)
        current = profile.home.lstat()
        link = os.stat("plugins", dir_fd=descriptor, follow_symlinks=False)
        if (
            (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino)
            or (link.st_dev, link.st_ino) != (metadata.st_dev, metadata.st_ino)
            or not stat.S_ISLNK(link.st_mode)
            or os.readlink("plugins", dir_fd=descriptor) != str(expected)
        ):
            raise ValueError(f"managed plugin link changed during cleanup: {destination}")
        os.unlink("plugins", dir_fd=descriptor)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _profile_plugins_absent(profile: Profile) -> bool:
    try:
        profile.home.joinpath("plugins").lstat()
    except FileNotFoundError:
        return True
    return False


def _canonical_json_bytes(payload: Any) -> bytes:
    return (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode()


def _planned_file(relative_path: str, payload: bytes) -> dict[str, Any]:
    return {
        "relative_path": relative_path,
        "type": "file",
        "mode": "0600",
        "sha256": hashlib.sha256(payload).hexdigest(),
    }


def provision_plan(registry: Registry, profile_id: str) -> dict[str, Any]:
    """Return the canonical, non-mutating managed filesystem plan for one worker."""

    profile = registry.require_profile(profile_id)
    if profile.safety_policy != "worker":
        raise ValueError("external reserve profiles must never be planned or inspected")
    provider = registry.require_provider(profile.provider)
    if provider.hooks_source is not None:
        raise ValueError("managed worker hooks must be release-owned")
    binary_identity = _provider_binary_identity(provider)
    session_command, agent_fleet_binary = _verified_session_hook(registry)
    turn_end_command = (
        session_command.replace(" hook session-start", " hook turn-end")
        if profile.provider == "claude"
        else None
    )
    hook_payload = (
        _claude_hook_payload({}, None, session_command, str(turn_end_command))
        if profile.provider == "claude"
        else _codex_hook_payload(None, session_command)
    )
    payloads: dict[str, bytes] = {
        HOOK_MARKER_FILE: _canonical_json_bytes(
            _hook_marker_payload(
                profile,
                provider,
                None,
                session_command,
                turn_end_command,
                agent_fleet_binary,
                hook_payload["hooks"],
            )
        ),
        PROVIDER_BINARY_MARKER_FILE: _canonical_json_bytes(
            {
                "schema": 1,
                "profile": profile.id,
                "provider": profile.provider,
                "binary": binary_identity,
            }
        ),
        ".agent-fleet-profile.json": _canonical_json_bytes(
            {
                "schema": 2,
                "agent_fleet_version": __version__,
                "profile": profile.id,
                "provider": profile.provider,
            }
        ),
    }
    if profile.provider == "claude":
        payloads["settings.json"] = _canonical_json_bytes(hook_payload)
        payloads[".claude.json"] = _canonical_json_bytes(
            closed_claude_state_payload(registry)
        )
    else:
        payloads["hooks.json"] = _canonical_json_bytes(hook_payload)
        payloads["config.toml"] = CODEX_MANAGED_CONFIG_TEXT.encode()
    entries: list[dict[str, Any]] = [
        {"relative_path": ".", "type": "dir", "mode": "0700"},
        {"relative_path": "hooks", "type": "dir", "mode": "0700"},
        *(_planned_file(path, payload) for path, payload in payloads.items()),
    ]
    if provider.base_home is not None:
        for entry in provider.shared_entries:
            source = provider.base_home / entry
            if source.exists():
                entries.append(
                    {
                        "relative_path": entry,
                        "type": "symlink",
                        "target": str(source),
                    }
                )
    entries.sort(key=lambda item: str(item["relative_path"]))
    return {
        "schema": 1,
        "profile": profile.id,
        "provider": profile.provider,
        "home": str(profile.home),
        "safety_policy": profile.safety_policy,
        "entries": entries,
    }


def verify_provisioned_profile(registry: Registry, profile_id: str) -> dict[str, Any]:
    """Verify only release-managed paths; never read credentials or reserve homes."""

    plan = provision_plan(registry, profile_id)
    profile = registry.require_profile(profile_id)
    actual_entries: list[dict[str, Any]] = []
    mismatches: list[dict[str, str]] = []
    for expected in plan["entries"]:
        relative = str(expected["relative_path"])
        path = profile.home if relative == "." else profile.home / relative
        try:
            metadata = path.lstat()
        except OSError:
            mismatches.append({"relative_path": relative, "reason": "missing"})
            continue
        if expected["type"] == "dir":
            actual = {
                "relative_path": relative,
                "type": "dir" if stat.S_ISDIR(metadata.st_mode) else "other",
                "mode": f"{stat.S_IMODE(metadata.st_mode):04o}",
            }
        elif expected["type"] == "symlink":
            actual = {
                "relative_path": relative,
                "type": "symlink" if stat.S_ISLNK(metadata.st_mode) else "other",
                "target": os.readlink(path) if stat.S_ISLNK(metadata.st_mode) else None,
            }
        else:
            try:
                payload = read_private_bytes(path, label="managed provisioned file")
            except (OSError, ValueError):
                actual = {"relative_path": relative, "type": "other"}
            else:
                actual = {
                    "relative_path": relative,
                    "type": "file",
                    "mode": f"{stat.S_IMODE(metadata.st_mode):04o}",
                    "sha256": hashlib.sha256(payload).hexdigest(),
                }
        actual_entries.append(actual)
        if actual != expected:
            mismatches.append({"relative_path": relative, "reason": "content_or_type"})
    if not _profile_plugins_absent(profile):
        mismatches.append({"relative_path": "plugins", "reason": "forbidden"})
    canonical_plan = json.dumps(plan, sort_keys=True, separators=(",", ":")).encode()
    return {
        "schema": 1,
        "profile": profile.id,
        "provider": profile.provider,
        "status": "verified" if not mismatches else "mismatch",
        "plan_sha256": hashlib.sha256(canonical_plan).hexdigest(),
        "actual_entries": actual_entries,
        "mismatches": mismatches,
    }


def provision_profile(registry: Registry, profile: Profile) -> dict[str, Any]:
    if profile.safety_policy != "worker":
        raise ValueError(
            f"profile {profile.id} is external {profile.safety_policy} capacity "
            "and must not be provisioned"
        )
    provider = registry.require_provider(profile.provider)
    binary_identity = _provider_binary_identity(provider)
    trusted_projects = registered_trusted_projects(registry, profile.provider)
    if not trusted_projects:
        raise ValueError(f"register at least one trusted project for {profile.provider}")
    _assert_existing_profile_config_closed(profile)
    if provider.hooks_source is not None:
        raise ValueError(
            "managed worker hooks must be release-owned; provider hooks_source must be absent"
        )
    if profile.home.is_symlink():
        raise ValueError(f"managed profile home cannot be a symlink: {profile.home}")
    ensure_private_dir(profile.home)
    current = profile.home.lstat()
    if not stat.S_ISDIR(current.st_mode) or current.st_uid != os.getuid():
        raise ValueError(f"managed profile home must be a current-user directory: {profile.home}")
    _remove_exact_legacy_plugin_link(profile, provider)
    shared = _share_workflow_entries(profile, provider)
    if profile.provider == "claude":
        ensure_private_dir(profile.home / "hooks")
        _install_claude_hooks(registry, profile, provider)
        _install_closed_claude_state(registry, profile)
    elif profile.provider == "codex":
        ensure_private_dir(profile.home / "hooks")
        _ensure_codex_config(profile.home)
        _install_codex_hooks(registry, profile, provider)
    atomic_write_json(
        profile.home / PROVIDER_BINARY_MARKER_FILE,
        {
            "schema": 1,
            "profile": profile.id,
            "provider": profile.provider,
            "binary": binary_identity,
        },
    )
    marker = profile.home / ".agent-fleet-profile.json"
    atomic_write_json(
        marker,
        {
            "schema": 2,
            "agent_fleet_version": __version__,
            "profile": profile.id,
            "provider": profile.provider,
        },
    )
    os.chmod(marker, 0o600)
    return {
        "profile": profile.id,
        "provider": profile.provider,
        "home": str(profile.home),
        "provisioned": True,
        "shared_entries": shared,
        "provider_binary": binary_identity,
    }


def profile_is_provisioned(profile: Profile) -> bool:
    marker = profile.home / ".agent-fleet-profile.json"
    if not profile.home.is_dir():
        return False
    try:
        raw = read_private_json(marker, label="profile marker")
    except (OSError, ValueError):
        return False
    return raw == {
        "schema": 2,
        "agent_fleet_version": __version__,
        "profile": profile.id,
        "provider": profile.provider,
    }


def profile_hook_health(registry: Registry, profile: Profile) -> dict[str, bool]:
    path = profile.home / ("settings.json" if profile.provider == "claude" else "hooks.json")
    try:
        payload = _read_json_object(path)
    except ValueError:
        return {
            "agent_fleet_session_hook": False,
            "herdr_session_hook": False,
            "release_owned_hooks": False,
        }
    hooks = payload.get("hooks", {})
    commands: list[str] = []
    if isinstance(hooks, dict):
        for groups in hooks.values():
            if not isinstance(groups, list):
                continue
            for group in groups:
                if not isinstance(group, dict):
                    continue
                entries = group.get("hooks", [])
                if not isinstance(entries, list):
                    continue
                commands.extend(
                    str(entry.get("command", "")) for entry in entries if isinstance(entry, dict)
                )

    closed_hooks = (
        claude_hooks_ready(registry, profile)
        if profile.provider == "claude"
        else codex_hooks_ready(registry, profile)
    )
    health = {
        "agent_fleet_session_hook": closed_hooks,
        "herdr_session_hook": any("herdr-agent-state" in command for command in commands),
        "release_owned_hooks": closed_hooks,
    }
    health["closed_profile_hooks"] = closed_hooks
    return health


def profile_shared_assets_healthy(registry: Registry, profile: Profile) -> bool:
    provider = registry.require_provider(profile.provider)
    if provider.base_home is None:
        return True
    for entry in provider.shared_entries:
        source = provider.base_home / entry
        if not source.exists():
            continue
        destination = profile.home / entry
        if not destination.is_symlink() or destination.resolve() != source.resolve():
            return False
    return True
