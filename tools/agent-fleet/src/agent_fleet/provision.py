from __future__ import annotations

import copy
import hashlib
import json
import os
import stat
import tomllib
from pathlib import Path
from typing import Any

from . import __version__
from .models import SHARED_WORKFLOW_ENTRIES, Profile, ProviderConfig, Registry
from .paths import ensure_private_dir
from .projects import TrustedProject, resolve_trusted_project
from .providers import session_hook_command
from .util import atomic_write_json

HOOK_MARKER = " hook session-start"
CODEX_HOOK_MARKER_FILE = ".agent-fleet-hooks.json"


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
    if not path.exists() and not path.is_symlink():
        return {}
    try:
        current = path.lstat()
    except FileNotFoundError:
        return {}
    if not stat.S_ISREG(current.st_mode) or current.st_uid != os.getuid():
        raise ValueError(f"managed JSON must be a current-user regular file: {path}")
    if stat.S_IMODE(current.st_mode) & 0o077:
        raise ValueError(f"managed JSON must not grant group/world access: {path}")
    return _read_json_object(path)


def _merge_source_hooks(payload: dict[str, Any], source: Path | None) -> None:
    if source is None or not source.exists():
        return
    source_payload = _read_json_object(source)
    source_hooks = source_payload.get("hooks", {})
    if not isinstance(source_hooks, dict):
        raise ValueError(f"hooks must be an object: {source}")
    destination = payload.setdefault("hooks", {})
    if not isinstance(destination, dict):
        raise ValueError("destination hooks must be an object")
    for event, groups in source_hooks.items():
        if not isinstance(groups, list):
            raise ValueError(f"hooks.{event} must be an array: {source}")
        target_groups = destination.setdefault(event, [])
        if not isinstance(target_groups, list):
            raise ValueError(f"destination hooks.{event} must be an array")
        existing = {json.dumps(group, sort_keys=True) for group in target_groups}
        for group in groups:
            encoded = json.dumps(group, sort_keys=True)
            if encoded not in existing:
                target_groups.append(group)
                existing.add(encoded)


def _install_session_hook(path: Path, source: Path | None) -> None:
    payload = _read_json_object(path)
    _merge_source_hooks(payload, source)
    hooks = payload.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError(f"hooks must be an object: {path}")
    groups = hooks.setdefault("SessionStart", [])
    if not isinstance(groups, list):
        raise ValueError(f"hooks.SessionStart must be an array: {path}")
    for group in groups:
        if not isinstance(group, dict):
            continue
        for hook in group.get("hooks", []):
            if isinstance(hook, dict) and HOOK_MARKER in str(hook.get("command", "")):
                atomic_write_json(path, payload)
                return
    groups.append(
        {
            "matcher": "startup|resume|clear|compact",
            "hooks": [
                {
                    "type": "command",
                    "command": session_hook_command(),
                    "statusMessage": "Recording Agent Fleet session identity",
                }
            ],
        }
    )
    atomic_write_json(path, payload)


def _source_hash(source: Path | None) -> str | None:
    if source is None:
        return None
    if not source.exists() and not source.is_symlink():
        return None
    current = source.lstat()
    if not stat.S_ISREG(current.st_mode) or current.st_uid != os.getuid():
        raise ValueError(f"hook source must be a current-user regular file: {source}")
    return hashlib.sha256(source.read_bytes()).hexdigest()


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


def _codex_hook_payload(source: Path | None, command: str) -> dict[str, Any]:
    source_payload = _read_json_object(source) if source is not None and source.exists() else {}
    source_hooks = source_payload.get("hooks", {})
    if not isinstance(source_hooks, dict):
        raise ValueError(f"hooks must be an object: {source}")
    hooks = copy.deepcopy(source_hooks)
    for event, groups in list(hooks.items()):
        if not isinstance(groups, list):
            raise ValueError(f"hooks.{event} must be an array: {source}")
        canonical_groups: list[Any] = []
        for group in groups:
            if not isinstance(group, dict):
                raise ValueError(f"hooks.{event} entries must be objects: {source}")
            entries = group.get("hooks", [])
            if not isinstance(entries, list):
                raise ValueError(f"hooks.{event} hook entries must be an array: {source}")
            canonical_entries = [
                entry
                for entry in entries
                if not (isinstance(entry, dict) and HOOK_MARKER in str(entry.get("command", "")))
            ]
            if canonical_entries:
                group["hooks"] = canonical_entries
                canonical_groups.append(group)
        hooks[event] = canonical_groups
    groups = hooks.setdefault("SessionStart", [])
    groups.append(_agent_fleet_session_group(command))
    return {"hooks": hooks}


def _install_codex_hooks(profile: Profile, provider: ProviderConfig) -> None:
    command = session_hook_command()
    source_hash = _source_hash(provider.hooks_source)
    payload = _codex_hook_payload(provider.hooks_source, command)
    if source_hash != _source_hash(provider.hooks_source):
        raise ValueError("Codex hook source changed during provisioning")
    path = profile.home / "hooks.json"
    atomic_write_json(path, payload)
    atomic_write_json(
        profile.home / CODEX_HOOK_MARKER_FILE,
        {
            "schema": 1,
            "agent_fleet_version": __version__,
            "profile": profile.id,
            "provider": profile.provider,
            "source": str(provider.hooks_source) if provider.hooks_source is not None else None,
            "source_hash": source_hash,
            "session_command": command,
            "hooks_hash": _hook_payload_hash(payload),
        },
    )


def codex_hooks_ready(registry: Registry, profile: Profile) -> bool:
    provider = registry.require_provider(profile.provider)
    try:
        marker = _read_owned_json_object(profile.home / CODEX_HOOK_MARKER_FILE)
        if (
            set(marker)
            != {
                "schema",
                "agent_fleet_version",
                "profile",
                "provider",
                "source",
                "source_hash",
                "session_command",
                "hooks_hash",
            }
            or marker.get("schema") != 1
            or marker.get("agent_fleet_version") != __version__
            or marker.get("profile") != profile.id
            or marker.get("provider") != "codex"
            or marker.get("source")
            != (str(provider.hooks_source) if provider.hooks_source is not None else None)
            or marker.get("source_hash") != _source_hash(provider.hooks_source)
            or not isinstance(marker.get("session_command"), str)
        ):
            return False
        payload = _read_owned_json_object(profile.home / "hooks.json")
        expected = _codex_hook_payload(provider.hooks_source, marker["session_command"])
    except (OSError, ValueError):
        return False
    expected_hash = _hook_payload_hash(expected)
    return (
        payload == expected
        and marker.get("hooks_hash") == expected_hash
        and _hook_payload_hash(payload) == expected_hash
    )


def _merge_claude_project_trust(profile: Profile, project: TrustedProject) -> None:
    path = profile.home / ".claude.json"
    payload = _read_owned_json_object(path)
    projects = payload.setdefault("projects", {})
    if not isinstance(projects, dict):
        raise ValueError(f"Claude projects state must be an object: {path}")
    changed = payload.get("hasCompletedOnboarding") is not True
    payload["hasCompletedOnboarding"] = True
    for root in {project.active_root, project.canonical_root}:
        key = str(root)
        existing = projects.setdefault(key, {})
        if not isinstance(existing, dict):
            raise ValueError(f"Claude project state must be an object: {key}")
        if existing.get("hasTrustDialogAccepted") is not True:
            changed = True
            existing["hasTrustDialogAccepted"] = True
    if changed:
        atomic_write_json(path, payload)


def claude_project_ready(profile: Profile, project: TrustedProject) -> bool:
    try:
        payload = _read_owned_json_object(profile.home / ".claude.json")
    except ValueError:
        return False
    projects = payload.get("projects")
    return (
        payload.get("hasCompletedOnboarding") is True
        and isinstance(projects, dict)
        and all(
            isinstance(projects.get(str(root)), dict)
            and projects[str(root)].get("hasTrustDialogAccepted") is True
            for root in {project.active_root, project.canonical_root}
        )
    )


def prepare_profile_launch(
    registry: Registry,
    profile: Profile,
    workspace: Path,
) -> TrustedProject:
    if not profile_is_provisioned(profile):
        raise ValueError(f"profile is not provisioned: {profile.id}")
    project = resolve_trusted_project(registry, profile.provider, workspace)
    if profile.provider == "claude":
        _merge_claude_project_trust(profile, project)
        if not claude_project_ready(profile, project):
            raise ValueError(f"Claude project trust bootstrap failed for {profile.id}")
        hook_health = profile_hook_health(registry, profile)
        if not (
            hook_health["agent_fleet_session_hook"] and hook_health["inherited_workflow_hooks"]
        ):
            raise ValueError(f"managed Claude hook set is not ready for {profile.id}")
    else:
        project_hook = project.active_root / ".codex" / "hooks.json"
        if project_hook.exists() or project_hook.is_symlink():
            raise ValueError(f"managed Codex launch refuses project hooks: {project_hook}")
        if not _codex_config_ready(profile.home):
            raise ValueError(f"managed Codex config is not ready for {profile.id}")
        if not codex_hooks_ready(registry, profile):
            raise ValueError(f"managed Codex hook set is not ready for {profile.id}")
    return project


def profile_launch_ready(
    registry: Registry,
    profile: Profile,
    workspace: Path,
) -> bool:
    try:
        project = resolve_trusted_project(registry, profile.provider, workspace)
    except ValueError:
        return False
    if profile.provider == "claude":
        hook_health = profile_hook_health(registry, profile)
        return (
            claude_project_ready(profile, project)
            and hook_health["agent_fleet_session_hook"]
            and hook_health["inherited_workflow_hooks"]
        )
    project_hook = project.active_root / ".codex" / "hooks.json"
    return (
        not (project_hook.exists() or project_hook.is_symlink())
        and _codex_config_ready(profile.home)
        and codex_hooks_ready(registry, profile)
    )


def _ensure_codex_config(home: Path) -> None:
    path = home / "config.toml"
    if not path.exists() and not path.is_symlink():
        path.write_text(
            'cli_auth_credentials_store = "file"\n\n[features]\nhooks = true\n',
            encoding="utf-8",
        )
        path.chmod(0o600)
        return
    current = path.lstat()
    if not stat.S_ISREG(current.st_mode) or current.st_uid != os.getuid():
        raise ValueError(f"managed Codex config must be a current-user regular file: {path}")
    try:
        raw = tomllib.loads(path.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as exc:
        raise ValueError(f"invalid Codex config: {path}: {exc}") from exc
    store = raw.get("cli_auth_credentials_store")
    if store != "file":
        raise ValueError(
            f'managed Codex profile requires cli_auth_credentials_store="file": {path}'
        )
    features = raw.get("features", {})
    if not isinstance(features, dict) or features.get("hooks") is not True:
        raise ValueError(f"managed Codex profile requires [features] hooks=true: {path}")
    projects = raw.get("projects", {})
    if not isinstance(projects, dict) or projects:
        raise ValueError(f"managed Codex profile cannot persist project trust: {path}")
    path.chmod(0o600)


def _codex_config_ready(home: Path) -> bool:
    path = home / "config.toml"
    try:
        current = path.lstat()
        if (
            not stat.S_ISREG(current.st_mode)
            or current.st_uid != os.getuid()
            or stat.S_IMODE(current.st_mode) & 0o077
        ):
            return False
        raw = tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError):
        return False
    features = raw.get("features", {})
    projects = raw.get("projects", {})
    return (
        raw.get("cli_auth_credentials_store") == "file"
        and isinstance(features, dict)
        and features.get("hooks") is True
        and isinstance(projects, dict)
        and not projects
    )


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


def provision_profile(registry: Registry, profile: Profile) -> dict[str, Any]:
    if profile.home.is_symlink():
        raise ValueError(f"managed profile home cannot be a symlink: {profile.home}")
    ensure_private_dir(profile.home)
    current = profile.home.lstat()
    if not stat.S_ISDIR(current.st_mode) or current.st_uid != os.getuid():
        raise ValueError(f"managed profile home must be a current-user directory: {profile.home}")
    provider = registry.require_provider(profile.provider)
    shared = _share_workflow_entries(profile, provider)
    if profile.provider == "claude":
        ensure_private_dir(profile.home / "hooks")
        _install_session_hook(profile.home / "settings.json", provider.hooks_source)
    elif profile.provider == "codex":
        ensure_private_dir(profile.home / "hooks")
        _ensure_codex_config(profile.home)
        _install_codex_hooks(profile, provider)
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
    }


def profile_is_provisioned(profile: Profile) -> bool:
    marker = profile.home / ".agent-fleet-profile.json"
    if not profile.home.is_dir():
        return False
    try:
        current = marker.lstat()
        if (
            not stat.S_ISREG(current.st_mode)
            or current.st_uid != os.getuid()
            or stat.S_IMODE(current.st_mode) != 0o600
        ):
            return False
        raw = json.loads(marker.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
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
            "inherited_workflow_hooks": False,
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

    source_ok = True
    source = registry.require_provider(profile.provider).hooks_source
    if source is not None and source.exists():
        try:
            source_payload = _read_json_object(source)
        except ValueError:
            source_ok = False
        else:
            source_hooks = source_payload.get("hooks", {})
            if not isinstance(source_hooks, dict) or not isinstance(hooks, dict):
                source_ok = False
            else:
                for event, groups in source_hooks.items():
                    destination_groups = hooks.get(event, [])
                    if not isinstance(groups, list) or not isinstance(destination_groups, list):
                        source_ok = False
                        break
                    destination = {
                        json.dumps(group, sort_keys=True) for group in destination_groups
                    }
                    if any(
                        json.dumps(group, sort_keys=True) not in destination for group in groups
                    ):
                        source_ok = False
                        break
    if profile.provider == "codex":
        source_ok = codex_hooks_ready(registry, profile)
    health = {
        "agent_fleet_session_hook": any(HOOK_MARKER in command for command in commands),
        "herdr_session_hook": any("herdr-agent-state" in command for command in commands),
        "inherited_workflow_hooks": source_ok,
    }
    if profile.provider == "codex":
        health["closed_profile_hooks"] = codex_hooks_ready(registry, profile)
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
