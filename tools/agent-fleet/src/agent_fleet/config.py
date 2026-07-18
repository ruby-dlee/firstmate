from __future__ import annotations

import json
import os
import tomllib
from dataclasses import replace
from pathlib import Path
from typing import Any

from .models import (
    PROFILE_SAFETY_POLICIES,
    SUPPORTED_PROVIDERS,
    Profile,
    ProviderConfig,
    Registry,
    Settings,
)
from .paths import default_config_path, default_share_dir, default_state_dir, expand_path
from .util import validate_id


def _integer(value: Any, name: str, *, minimum: int, maximum: int | None = None) -> int:
    if not isinstance(value, int) or isinstance(value, bool):
        raise ValueError(f"{name} must be an integer")
    if value < minimum or (maximum is not None and value > maximum):
        suffix = f"..{maximum}" if maximum is not None else " or greater"
        raise ValueError(f"{name} must be {minimum}{suffix}")
    return value


def _profile_from_toml(profile_id: str, raw: dict[str, Any], share_dir: Path) -> Profile:
    validate_id(profile_id, "profile id")
    provider = str(raw.get("provider", ""))
    if provider not in SUPPORTED_PROVIDERS:
        raise ValueError(f"profile {profile_id}: unsupported provider: {provider}")
    home_raw = raw.get("home")
    if not isinstance(home_raw, str) or not home_raw:
        home = share_dir / "accounts" / provider / profile_id
    else:
        home = expand_path(home_raw)
    pools_raw = raw.get("pools", [])
    if not isinstance(pools_raw, list) or not pools_raw:
        raise ValueError(f"profile {profile_id}: pools must be a non-empty array")
    pools = tuple(validate_id(str(pool), "pool id") for pool in pools_raw)
    enabled = raw.get("enabled", False)
    if not isinstance(enabled, bool):
        raise ValueError(f"profile {profile_id}: enabled must be boolean")
    safety_policy = raw.get("safety_policy", "worker")
    if safety_policy not in PROFILE_SAFETY_POLICIES:
        choices = ", ".join(PROFILE_SAFETY_POLICIES)
        raise ValueError(f"profile {profile_id}: safety_policy must be one of {choices}")
    if safety_policy != "worker":
        pools = tuple(pool for pool in pools if pool != f"{provider}-crew")
        if not pools:
            pools = (f"{provider}-manual",)
        if enabled:
            raise ValueError(f"profile {profile_id}: {safety_policy} profiles cannot be enabled")
    return Profile(
        id=profile_id,
        provider=provider,
        home=home,
        pools=pools,
        enabled=enabled,
        weight=_integer(raw.get("weight", 1), f"profile {profile_id}: weight", minimum=1),
        max_concurrent=_integer(
            raw.get("max_concurrent", 2),
            f"profile {profile_id}: max_concurrent",
            minimum=1,
        ),
        reserve_percent=_integer(
            raw.get("reserve_percent", 15),
            f"profile {profile_id}: reserve_percent",
            minimum=0,
            maximum=100,
        ),
        safety_policy=str(safety_policy),
    )


def load_registry(path: Path | None = None) -> Registry:
    config_path = path or default_config_path()
    try:
        raw = tomllib.loads(config_path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ValueError(f"registry not found: {config_path}; run `agent-fleet init`") from exc
    except tomllib.TOMLDecodeError as exc:
        raise ValueError(f"invalid registry TOML at {config_path}: {exc}") from exc

    version = _integer(raw.get("version", 0), "version", minimum=1)
    if version != 1:
        raise ValueError(f"unsupported registry version: {version}")
    settings_raw = raw.get("settings", {})
    if not isinstance(settings_raw, dict):
        raise ValueError("settings must be a TOML table")
    state_dir = expand_path(settings_raw.get("state_dir", default_state_dir()))
    share_dir = expand_path(settings_raw.get("share_dir", default_share_dir()))
    quota_binary = expand_path(
        settings_raw.get(
            "quota_binary",
            "~/.local/libexec/agent-fleet/quota-axi/current/bin/quota-axi",
        )
    )
    settings = Settings(
        state_dir=state_dir,
        share_dir=share_dir,
        quota_binary=quota_binary,
        quota_stale_seconds=_integer(
            settings_raw.get("quota_stale_seconds", 300),
            "quota_stale_seconds",
            minimum=0,
        ),
        quota_verification_grace_seconds=_integer(
            settings_raw.get("quota_verification_grace_seconds", 86400),
            "quota_verification_grace_seconds",
            minimum=0,
        ),
        lease_grace_seconds=_integer(
            settings_raw.get("lease_grace_seconds", 30),
            "lease_grace_seconds",
            minimum=0,
        ),
        active_lease_penalty=_integer(
            settings_raw.get("active_lease_penalty", 8),
            "active_lease_penalty",
            minimum=0,
        ),
        lock_stale_seconds=_integer(
            settings_raw.get("lock_stale_seconds", 30),
            "lock_stale_seconds",
            minimum=1,
        ),
    )

    providers_raw = raw.get("providers", {})
    if not isinstance(providers_raw, dict):
        raise ValueError("providers must be a TOML table")
    providers: dict[str, ProviderConfig] = {}
    for provider in SUPPORTED_PROVIDERS:
        item = providers_raw.get(provider, {})
        if not isinstance(item, dict):
            raise ValueError(f"providers.{provider} must be a TOML table")
        binary_raw = item.get("binary")
        if not isinstance(binary_raw, str) or not binary_raw:
            raise ValueError(f"providers.{provider}.binary is required")
        base_home_raw = item.get("base_home")
        hooks_source_raw = item.get("hooks_source")
        desktop_identity_file_raw = item.get(
            "desktop_identity_file",
            "~/Library/Application Support/Claude/config.json" if provider == "claude" else None,
        )
        shared_raw = item.get("shared_entries", [])
        if base_home_raw is not None and not isinstance(base_home_raw, str):
            raise ValueError(f"providers.{provider}.base_home must be a path string")
        if hooks_source_raw is not None and not isinstance(hooks_source_raw, str):
            raise ValueError(f"providers.{provider}.hooks_source must be a path string")
        if desktop_identity_file_raw is not None and not isinstance(
            desktop_identity_file_raw, (str, bool)
        ):
            raise ValueError(
                f"providers.{provider}.desktop_identity_file must be a path string or false"
            )
        if desktop_identity_file_raw is True:
            raise ValueError(
                f"providers.{provider}.desktop_identity_file=true is ambiguous; "
                "provide a path or false"
            )
        if desktop_identity_file_raw == "":
            raise ValueError(
                f"providers.{provider}.desktop_identity_file cannot be empty; use false to opt out"
            )
        if not isinstance(shared_raw, list) or not all(
            isinstance(entry, str) and "/" not in entry and entry not in {"", ".", ".."}
            for entry in shared_raw
        ):
            raise ValueError(f"providers.{provider}.shared_entries must contain simple file names")
        providers[provider] = ProviderConfig(
            provider,
            expand_path(binary_raw),
            expand_path(base_home_raw) if base_home_raw else None,
            expand_path(hooks_source_raw) if hooks_source_raw else None,
            tuple(shared_raw),
            (
                expand_path(desktop_identity_file_raw)
                if isinstance(desktop_identity_file_raw, str) and desktop_identity_file_raw
                else None
            ),
        )

    profiles_raw = raw.get("profiles", {})
    if not isinstance(profiles_raw, dict):
        raise ValueError("profiles must be a TOML table")
    profiles = {
        profile_id: _profile_from_toml(profile_id, item, share_dir)
        for profile_id, item in profiles_raw.items()
        if isinstance(item, dict)
    }
    if len(profiles) != len(profiles_raw):
        raise ValueError("each profiles entry must be a TOML table")
    registry = Registry(version, settings, providers, profiles)
    _validate_profile_invariants(registry)
    return registry


def initial_registry(claude_count: int, codex_count: int) -> Registry:
    if claude_count < 0 or codex_count < 0 or claude_count + codex_count == 0:
        raise ValueError("at least one profile is required")
    state_dir = default_state_dir()
    share_dir = default_share_dir()
    providers = {
        "claude": ProviderConfig(
            "claude",
            expand_path(os.environ.get("AGENT_FLEET_CLAUDE_BIN", "~/.local/bin/claude")),
            expand_path("~/.claude"),
            expand_path("~/.claude/settings.json"),
            ("CLAUDE.md", "skills", "plugins"),
            expand_path("~/Library/Application Support/Claude/config.json"),
        ),
        "codex": ProviderConfig(
            "codex",
            expand_path(
                os.environ.get(
                    "AGENT_FLEET_CODEX_BIN",
                    "~/.local/libexec/agent-fleet/runtime/codex",
                )
            ),
            expand_path("~/.codex"),
            expand_path("~/.codex/hooks.json"),
            ("AGENTS.md", "skills", "plugins", "rules"),
        ),
    }
    profiles: dict[str, Profile] = {}
    for provider, count in (("claude", claude_count), ("codex", codex_count)):
        for index in range(1, count + 1):
            profile_id = f"{provider}-{index}"
            safety_policy = "worker"
            pools = [f"{provider}-crew", f"{provider}-manual"]
            if provider == "claude":
                pools.append("claude-captain")
            profiles[profile_id] = Profile(
                id=profile_id,
                provider=provider,
                home=share_dir / "accounts" / provider / str(index),
                pools=tuple(pools),
                enabled=False,
                max_concurrent=2 if provider == "claude" else 3,
                safety_policy=safety_policy,
            )
    quota_binary = expand_path(
        os.environ.get(
            "AGENT_FLEET_QUOTA_BIN",
            "~/.local/libexec/agent-fleet/quota-axi/current/bin/quota-axi",
        )
    )
    registry = Registry(1, Settings(state_dir, share_dir, quota_binary), providers, profiles)
    _validate_profile_invariants(registry)
    return registry


def with_profile(registry: Registry, profile: Profile) -> Registry:
    profiles = dict(registry.profiles)
    profiles[profile.id] = profile
    updated = replace(registry, profiles=profiles)
    _validate_profile_invariants(updated)
    return updated


def without_profile(registry: Registry, profile_id: str) -> Registry:
    registry.require_profile(profile_id)
    profiles = dict(registry.profiles)
    del profiles[profile_id]
    return replace(registry, profiles=profiles)


def _paths_overlap(first: Path, second: Path) -> bool:
    return first == second or first in second.parents or second in first.parents


def _validate_profile_invariants(registry: Registry) -> None:
    profiles = list(registry.profiles.values())
    for profile in profiles:
        if profile.safety_policy not in PROFILE_SAFETY_POLICIES:
            raise ValueError(
                f"profile {profile.id}: unsupported safety policy {profile.safety_policy}"
            )
        if profile.safety_policy != "worker":
            if profile.enabled:
                raise ValueError(
                    f"profile {profile.id}: {profile.safety_policy} profiles cannot be enabled"
                )
            if f"{profile.provider}-crew" in profile.pools:
                raise ValueError(
                    f"profile {profile.id}: {profile.safety_policy} profiles "
                    "cannot join a worker crew pool"
                )
        home = profile.home.resolve()
        state_dir = registry.settings.state_dir.resolve()
        share_dir = registry.settings.share_dir.resolve()
        if _paths_overlap(home, state_dir):
            raise ValueError(f"profile {profile.id}: home overlaps Agent Fleet state directory")
        if home == share_dir or home in share_dir.parents:
            raise ValueError(f"profile {profile.id}: home is too broad for Agent Fleet share data")
        provider = registry.require_provider(profile.provider)
        if provider.base_home is not None and _paths_overlap(
            home,
            provider.base_home.resolve(),
        ):
            raise ValueError(f"profile {profile.id}: home overlaps the provider base/Desktop home")
        if provider.desktop_identity_file is not None and home in (
            provider.desktop_identity_file.resolve().parents
        ):
            raise ValueError(
                f"profile {profile.id}: home contains the provider Desktop identity file"
            )
    for index, profile in enumerate(profiles):
        for other in profiles[index + 1 :]:
            if _paths_overlap(profile.home.resolve(), other.home.resolve()):
                raise ValueError(f"profile homes must not overlap: {profile.id}, {other.id}")


def set_profile_enabled(registry: Registry, profile_id: str, enabled: bool) -> Registry:
    profile = registry.require_profile(profile_id)
    if enabled and profile.safety_policy != "worker":
        raise ValueError(
            f"{profile.safety_policy} profile {profile.id} cannot be enabled for routing"
        )
    return with_profile(registry, replace(profile, enabled=enabled))


def set_profile_safety_policy(
    registry: Registry,
    profile_id: str,
    safety_policy: str,
) -> Registry:
    if safety_policy not in PROFILE_SAFETY_POLICIES:
        choices = ", ".join(PROFILE_SAFETY_POLICIES)
        raise ValueError(f"safety policy must be one of {choices}")
    profile = registry.require_profile(profile_id)
    pools = profile.pools
    if safety_policy != "worker":
        pools = tuple(pool for pool in pools if pool != f"{profile.provider}-crew")
        if not pools:
            pools = (f"{profile.provider}-manual",)
    return with_profile(
        registry,
        replace(
            profile,
            enabled=False if safety_policy != "worker" else profile.enabled,
            pools=pools,
            safety_policy=safety_policy,
        ),
    )


def _toml_string(value: str | Path) -> str:
    return json.dumps(str(value), ensure_ascii=False)


def save_registry(registry: Registry, path: Path | None = None) -> Path:
    _validate_profile_invariants(registry)
    config_path = path or default_config_path()
    config_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    config_path.parent.chmod(0o700)
    lines = [
        "# Agent Fleet registry. Contains labels and policy only; never credentials.",
        f"version = {registry.version}",
        "",
        "[settings]",
        f"state_dir = {_toml_string(registry.settings.state_dir)}",
        f"share_dir = {_toml_string(registry.settings.share_dir)}",
        f"quota_binary = {_toml_string(registry.settings.quota_binary)}",
        f"quota_stale_seconds = {registry.settings.quota_stale_seconds}",
        f"quota_verification_grace_seconds = {registry.settings.quota_verification_grace_seconds}",
        f"lease_grace_seconds = {registry.settings.lease_grace_seconds}",
        f"active_lease_penalty = {registry.settings.active_lease_penalty}",
        f"lock_stale_seconds = {registry.settings.lock_stale_seconds}",
    ]
    for provider in SUPPORTED_PROVIDERS:
        provider_config = registry.require_provider(provider)
        lines.extend(
            [
                "",
                f"[providers.{provider}]",
                f"binary = {_toml_string(provider_config.binary)}",
                *(
                    [f"base_home = {_toml_string(provider_config.base_home)}"]
                    if provider_config.base_home
                    else []
                ),
                *(
                    [f"hooks_source = {_toml_string(provider_config.hooks_source)}"]
                    if provider_config.hooks_source
                    else []
                ),
                *(
                    [
                        "desktop_identity_file = "
                        f"{_toml_string(provider_config.desktop_identity_file)}"
                    ]
                    if provider_config.desktop_identity_file
                    else (["desktop_identity_file = false"] if provider == "claude" else [])
                ),
                "shared_entries = ["
                + ", ".join(_toml_string(entry) for entry in provider_config.shared_entries)
                + "]",
            ]
        )
    for profile_id in sorted(registry.profiles):
        profile = registry.profiles[profile_id]
        pools = ", ".join(_toml_string(pool) for pool in profile.pools)
        lines.extend(
            [
                "",
                f"[profiles.{_toml_string(profile_id)}]",
                f"provider = {_toml_string(profile.provider)}",
                f"home = {_toml_string(profile.home)}",
                f"pools = [{pools}]",
                f"enabled = {'true' if profile.enabled else 'false'}",
                f"weight = {profile.weight}",
                f"max_concurrent = {profile.max_concurrent}",
                f"reserve_percent = {profile.reserve_percent}",
                f"safety_policy = {_toml_string(profile.safety_policy)}",
            ]
        )
    temp = config_path.with_name(f".{config_path.name}.{os.getpid()}.tmp")
    temp.write_text("\n".join(lines) + "\n", encoding="utf-8")
    temp.chmod(0o600)
    os.replace(temp, config_path)
    config_path.chmod(0o600)
    return config_path
