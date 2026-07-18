from __future__ import annotations

import json
import os
import stat
import tomllib
from pathlib import Path
from typing import Any

from .models import Profile, ProviderConfig, Registry
from .paths import ensure_private_dir
from .providers import session_hook_command
from .util import atomic_write_json

HOOK_MARKER = " hook session-start"


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


def _ensure_codex_config(home: Path) -> None:
    path = home / "config.toml"
    if not path.exists():
        path.write_text(
            'cli_auth_credentials_store = "file"\n\n[features]\nhooks = true\n',
            encoding="utf-8",
        )
        path.chmod(0o600)
        return
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
    path.chmod(0o600)


def _share_workflow_entries(profile: Profile, provider: ProviderConfig) -> list[str]:
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
        _install_session_hook(profile.home / "hooks.json", provider.hooks_source)
    marker = profile.home / ".agent-fleet-profile.json"
    atomic_write_json(
        marker,
        {"schema": 1, "profile": profile.id, "provider": profile.provider},
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
    if not profile.home.is_dir() or not marker.is_file():
        return False
    try:
        raw = json.loads(marker.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False
    return raw.get("profile") == profile.id and raw.get("provider") == profile.provider


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
    return {
        "agent_fleet_session_hook": any(HOOK_MARKER in command for command in commands),
        "herdr_session_hook": any("herdr-agent-state" in command for command in commands),
        "inherited_workflow_hooks": source_ok,
    }


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
