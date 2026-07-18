from __future__ import annotations

import hashlib
import json
import os
import stat
import tomllib
import uuid
from contextlib import suppress
from dataclasses import replace
from pathlib import Path
from typing import Any

from .models import (
    PROFILE_SAFETY_POLICIES,
    SHARED_WORKFLOW_ENTRIES,
    SUPPORTED_PROVIDERS,
    Profile,
    ProviderConfig,
    Registry,
    Settings,
)
from .paths import (
    default_config_path,
    default_share_dir,
    default_state_dir,
    expand_lexical_path,
    expand_path,
)
from .transaction_fence import assert_no_pending_credential_recovery
from .util import read_private_bytes, validate_id

DEFAULT_QUOTA_RELEASE = "~/.local/libexec/agent-fleet/quota-axi/releases/0.1.6-da603d0d"
DEFAULT_QUOTA_BINARY = f"{DEFAULT_QUOTA_RELEASE}/bin/quota-axi"
DEFAULT_QUOTA_NODE_BINARY = f"{DEFAULT_QUOTA_RELEASE}/runtime/node"


def _opened_executable_identity(
    path: Path,
    label: str,
    *,
    resolve_configured_symlink: bool,
) -> tuple[Path, str]:
    configured = path.absolute()
    try:
        configured_metadata = configured.lstat()
    except OSError as exc:
        raise ValueError(f"{label} is not an existing executable: {path}") from exc
    if stat.S_ISLNK(configured_metadata.st_mode):
        if not resolve_configured_symlink:
            raise ValueError(f"{label} must be pinned to a non-symlink release file: {path}")
    elif not stat.S_ISREG(configured_metadata.st_mode):
        raise ValueError(f"{label} must be a regular file: {path}")
    try:
        resolved = configured.resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise ValueError(f"{label} is not an existing executable: {path}") from exc
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(resolved, flags)
    except OSError as exc:
        raise ValueError(f"{label} is not a safe regular file: {path}") from exc
    try:
        opened = os.fstat(descriptor)
        current = resolved.lstat()
        identity = (opened.st_dev, opened.st_ino)
        if not stat.S_ISREG(opened.st_mode) or identity != (current.st_dev, current.st_ino):
            raise ValueError(f"{label} changed while opening: {path}")
        if stat.S_IMODE(opened.st_mode) & 0o022 or not os.access(resolved, os.X_OK):
            raise ValueError(f"{label} must be executable and not group/world writable: {path}")
        digest = hashlib.sha256()
        while chunk := os.read(descriptor, 1024 * 1024):
            digest.update(chunk)
        after = os.fstat(descriptor)
        after_path = resolved.lstat()
        if (
            (after.st_dev, after.st_ino) != identity
            or (after_path.st_dev, after_path.st_ino) != identity
            or after.st_size != opened.st_size
            or after.st_mtime_ns != opened.st_mtime_ns
            or after.st_ctime_ns != opened.st_ctime_ns
        ):
            raise ValueError(f"{label} changed while hashing: {path}")
    finally:
        os.close(descriptor)
    return resolved, digest.hexdigest()


def _valid_sha256(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def _tree_hash_field(digest: Any, value: bytes) -> None:
    digest.update(len(value).to_bytes(8, "big"))
    digest.update(value)


def _is_relative_to(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def _validate_release_entry(path: Path, metadata: os.stat_result, label: str) -> None:
    if metadata.st_uid != os.getuid():
        raise ValueError(f"{label} entry is not owned by the current user: {path}")
    if not stat.S_ISLNK(metadata.st_mode) and stat.S_IMODE(metadata.st_mode) & 0o022:
        raise ValueError(f"{label} entry is group/world writable: {path}")
    if stat.S_ISREG(metadata.st_mode) and metadata.st_nlink != 1:
        raise ValueError(f"{label} regular file has multiple hard links: {path}")


def _release_tree_sha256_once(root: Path, label: str) -> str:
    try:
        root_metadata = root.lstat()
    except OSError as exc:
        raise ValueError(f"{label} does not exist: {root}") from exc
    if not stat.S_ISDIR(root_metadata.st_mode):
        raise ValueError(f"{label} must be a real directory: {root}")
    _validate_release_entry(root, root_metadata, label)
    digest = hashlib.sha256()
    digest.update(b"bridge-release-tree-v1\x00")

    def record_header(kind: bytes, relative: bytes, mode: int) -> None:
        digest.update(kind)
        _tree_hash_field(digest, relative)
        digest.update(mode.to_bytes(4, "big"))

    record_header(b"D", b"", stat.S_IMODE(root_metadata.st_mode))

    def walk(directory: Path) -> None:
        try:
            entries = sorted(os.scandir(directory), key=lambda entry: os.fsencode(entry.name))
        except OSError as exc:
            raise ValueError(f"cannot scan {label}: {directory}") from exc
        for entry in entries:
            path = Path(entry.path)
            relative = os.fsencode(str(path.relative_to(root)))
            try:
                metadata = entry.stat(follow_symlinks=False)
            except OSError as exc:
                raise ValueError(f"cannot stat {label} entry: {path}") from exc
            _validate_release_entry(path, metadata, label)
            mode = stat.S_IMODE(metadata.st_mode)
            if stat.S_ISDIR(metadata.st_mode):
                record_header(b"D", relative, mode)
                walk(path)
                continue
            if stat.S_ISREG(metadata.st_mode):
                record_header(b"F", relative, mode)
                digest.update(metadata.st_size.to_bytes(8, "big"))
                flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
                try:
                    descriptor = os.open(path, flags)
                except OSError as exc:
                    raise ValueError(f"cannot safely open {label} entry: {path}") from exc
                try:
                    opened = os.fstat(descriptor)
                    if (
                        not stat.S_ISREG(opened.st_mode)
                        or opened.st_uid != os.getuid()
                        or opened.st_nlink != 1
                        or (opened.st_dev, opened.st_ino, opened.st_size)
                        != (metadata.st_dev, metadata.st_ino, metadata.st_size)
                        or stat.S_IMODE(opened.st_mode) != mode
                    ):
                        raise ValueError(f"{label} entry changed while opening: {path}")
                    while block := os.read(descriptor, 1024 * 1024):
                        digest.update(block)
                    after = os.fstat(descriptor)
                    current = path.lstat()
                    if (
                        (after.st_dev, after.st_ino) != (opened.st_dev, opened.st_ino)
                        or (current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino)
                        or after.st_size != opened.st_size
                        or after.st_mtime_ns != opened.st_mtime_ns
                        or after.st_mode != opened.st_mode
                    ):
                        raise ValueError(f"{label} entry changed while hashing: {path}")
                finally:
                    os.close(descriptor)
                continue
            if stat.S_ISLNK(metadata.st_mode):
                record_header(b"L", relative, mode)
                try:
                    payload = os.readlink(path)
                except OSError as exc:
                    raise ValueError(f"cannot read {label} symlink: {path}") from exc
                _tree_hash_field(digest, os.fsencode(payload))
                lexical = Path(
                    os.path.normpath(payload if os.path.isabs(payload) else path.parent / payload)
                )
                if not _is_relative_to(lexical, root):
                    raise ValueError(f"{label} symlink escapes the release tree: {path}")
                if not os.path.exists(path):
                    raise ValueError(f"{label} symlink is dangling or cyclic: {path}")
                resolved = Path(os.path.realpath(path))
                if not _is_relative_to(resolved, root):
                    raise ValueError(f"{label} symlink resolves outside the release tree: {path}")
                continue
            raise ValueError(f"{label} contains a special file: {path}")

    walk(root)
    after_root = root.lstat()
    if (
        after_root.st_dev != root_metadata.st_dev
        or after_root.st_ino != root_metadata.st_ino
        or after_root.st_mode != root_metadata.st_mode
    ):
        raise ValueError(f"{label} root changed while hashing: {root}")
    return digest.hexdigest()


def compute_release_tree_sha256(root: Path, label: str = "release tree") -> str:
    normalized = Path(os.path.normpath(str(root)))
    if not root.is_absolute() or normalized != root or Path(os.path.realpath(root)) != root:
        raise ValueError(f"{label} root must be an absolute canonical path: {root}")
    first = _release_tree_sha256_once(root, label)
    second = _release_tree_sha256_once(root, label)
    if first != second:
        raise ValueError(f"{label} changed between consecutive snapshots: {root}")
    return first


def quota_release_root(quota_binary: Path, node_binary: Path) -> Path:
    try:
        root = Path(os.path.commonpath((quota_binary, node_binary)))
    except ValueError as exc:
        raise ValueError("Quota JavaScript and Node runtime must share one release root") from exc
    expected_quota = root / "bin" / "quota-axi"
    expected_node = root / "runtime" / "node"
    if quota_binary != expected_quota or node_binary != expected_node:
        raise ValueError(
            "Quota wrapper and contained Node runtime must use the sealed release layout"
        )
    entrypoint = root / "node_modules" / "quota-axi" / "dist" / "bin" / "quota-axi.js"
    try:
        entrypoint_metadata = entrypoint.lstat()
    except OSError as exc:
        raise ValueError(
            "Quota sealed release is missing its internal JavaScript entrypoint"
        ) from exc
    if (
        not stat.S_ISREG(entrypoint_metadata.st_mode)
        or entrypoint_metadata.st_uid != os.getuid()
        or entrypoint_metadata.st_nlink != 1
        or stat.S_IMODE(entrypoint_metadata.st_mode) & 0o222
    ):
        raise ValueError("Quota internal JavaScript entrypoint has unsafe identity or mode")
    return root


def quota_release_tree_digest(quota_binary: Path, node_binary: Path) -> str:
    root = quota_release_root(quota_binary, node_binary)
    return compute_release_tree_sha256(root, "configured quota-axi release tree")


def _verified_pinned_executable(path: Path, expected_digest: str, label: str) -> Path:
    resolved, digest = _opened_executable_identity(
        path,
        label,
        resolve_configured_symlink=False,
    )
    if digest != expected_digest:
        raise ValueError(f"{label} changed since registry creation")
    return resolved


def verified_quota_binary(settings: Settings) -> Path:
    return _verified_pinned_executable(
        settings.quota_binary,
        settings.quota_binary_sha256,
        "configured quota-axi native wrapper",
    )


def verified_quota_node_binary(settings: Settings) -> Path:
    return _verified_pinned_executable(
        settings.quota_node_binary,
        settings.quota_node_sha256,
        "configured contained quota-axi Node runtime",
    )


def verified_quota_runtime(settings: Settings) -> tuple[Path, Path]:
    node_binary = verified_quota_node_binary(settings)
    quota_binary = verified_quota_binary(settings)
    observed = quota_release_tree_digest(quota_binary, node_binary)
    if observed != settings.quota_release_tree_sha256:
        raise ValueError("configured quota-axi release tree changed since registry creation")
    return node_binary, quota_binary


def quota_binary_digest(path: Path) -> str:
    _, digest = _opened_executable_identity(
        path,
        "quota-axi binary",
        resolve_configured_symlink=False,
    )
    return digest


def _initial_quota_node_candidate() -> Path:
    configured = os.environ.get("AGENT_FLEET_QUOTA_NODE_BIN")
    if configured:
        return expand_lexical_path(configured)
    return expand_lexical_path(DEFAULT_QUOTA_NODE_BINARY)


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
        raw = tomllib.loads(
            read_private_bytes(config_path, label="Agent Fleet registry").decode("utf-8")
        )
    except FileNotFoundError as exc:
        raise ValueError(f"registry not found: {config_path}; run `agent-fleet init`") from exc
    except (UnicodeDecodeError, tomllib.TOMLDecodeError) as exc:
        raise ValueError(f"invalid registry TOML at {config_path}: {exc}") from exc

    version = _integer(raw.get("version", 0), "version", minimum=1)
    if version != 1:
        raise ValueError(f"unsupported registry version: {version}")
    settings_raw = raw.get("settings", {})
    if not isinstance(settings_raw, dict):
        raise ValueError("settings must be a TOML table")
    state_dir = expand_path(settings_raw.get("state_dir", default_state_dir()))
    share_dir = expand_path(settings_raw.get("share_dir", default_share_dir()))
    quota_binary = expand_lexical_path(
        settings_raw.get(
            "quota_binary",
            DEFAULT_QUOTA_BINARY,
        )
    )
    quota_binary_sha256 = settings_raw.get("quota_binary_sha256")
    if quota_binary_sha256 is None:
        quota_binary, quota_binary_sha256 = _opened_executable_identity(
            quota_binary,
            "legacy configured quota-axi binary",
            resolve_configured_symlink=False,
        )
    elif not _valid_sha256(quota_binary_sha256):
        raise ValueError("settings.quota_binary_sha256 must be a lowercase SHA-256 digest")
    quota_node_raw = settings_raw.get("quota_node_binary")
    quota_node_sha256 = settings_raw.get("quota_node_sha256")
    if quota_node_raw is None:
        if quota_node_sha256 is not None:
            raise ValueError("settings.quota_node_binary is required with quota_node_sha256")
        quota_node_binary, quota_node_sha256 = _opened_executable_identity(
            _initial_quota_node_candidate(),
            "legacy quota-axi Node runtime",
            resolve_configured_symlink=True,
        )
    else:
        if not isinstance(quota_node_raw, str) or not quota_node_raw:
            raise ValueError("settings.quota_node_binary must be a non-empty path string")
        quota_node_binary = expand_lexical_path(quota_node_raw)
        if quota_node_sha256 is None:
            quota_node_binary, quota_node_sha256 = _opened_executable_identity(
                quota_node_binary,
                "legacy quota-axi Node runtime",
                resolve_configured_symlink=False,
            )
        elif not _valid_sha256(quota_node_sha256):
            raise ValueError("settings.quota_node_sha256 must be a lowercase SHA-256 digest")
    quota_release_tree_sha256 = settings_raw.get("quota_release_tree_sha256")
    if quota_release_tree_sha256 is None:
        quota_release_tree_sha256 = quota_release_tree_digest(quota_binary, quota_node_binary)
    elif not _valid_sha256(quota_release_tree_sha256):
        raise ValueError("settings.quota_release_tree_sha256 must be a lowercase SHA-256 digest")
    settings = Settings(
        state_dir=state_dir,
        share_dir=share_dir,
        quota_binary=quota_binary,
        quota_node_binary=quota_node_binary,
        quota_binary_sha256=quota_binary_sha256,
        quota_node_sha256=quota_node_sha256,
        quota_release_tree_sha256=quota_release_tree_sha256,
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
        trusted_projects_raw = item.get("trusted_projects", [])
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
        disallowed_shared = sorted(set(shared_raw) - SHARED_WORKFLOW_ENTRIES[provider])
        if disallowed_shared:
            raise ValueError(
                f"providers.{provider}.shared_entries contains non-workflow assets: "
                + ", ".join(disallowed_shared)
            )
        if not isinstance(trusted_projects_raw, list) or not all(
            isinstance(entry, str) and entry for entry in trusted_projects_raw
        ):
            raise ValueError(f"providers.{provider}.trusted_projects must contain path strings")
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
            tuple(expand_lexical_path(entry) for entry in trusted_projects_raw),
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
    registry = Registry(version, settings, providers, profiles, config_path=config_path)
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
            None,
            ("CLAUDE.md", "skills"),
            expand_path("~/Library/Application Support/Claude/config.json"),
            (),
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
            None,
            ("AGENTS.md", "skills", "rules"),
            None,
            (),
        ),
    }
    profiles: dict[str, Profile] = {}
    for provider, count in (("claude", claude_count), ("codex", codex_count)):
        for index in range(1, count + 1):
            profile_id = f"{provider}-{index}"
            safety_policy = "worker"
            pools = [f"{provider}-crew", f"{provider}-manual"]
            profiles[profile_id] = Profile(
                id=profile_id,
                provider=provider,
                home=share_dir / "accounts" / provider / str(index),
                pools=tuple(pools),
                enabled=False,
                max_concurrent=2 if provider == "claude" else 3,
                safety_policy=safety_policy,
            )
    quota_candidate = expand_lexical_path(
        os.environ.get(
            "AGENT_FLEET_QUOTA_BIN",
            DEFAULT_QUOTA_BINARY,
        )
    )
    quota_binary, quota_binary_sha256 = _opened_executable_identity(
        quota_candidate,
        "initial quota-axi binary",
        resolve_configured_symlink=True,
    )
    quota_node_binary, quota_node_sha256 = _opened_executable_identity(
        _initial_quota_node_candidate(),
        "initial quota-axi Node runtime",
        resolve_configured_symlink=True,
    )
    quota_release_tree_sha256 = quota_release_tree_digest(quota_binary, quota_node_binary)
    registry = Registry(
        1,
        Settings(
            state_dir,
            share_dir,
            quota_binary,
            quota_node_binary,
            quota_binary_sha256=quota_binary_sha256,
            quota_node_sha256=quota_node_sha256,
            quota_release_tree_sha256=quota_release_tree_sha256,
        ),
        providers,
        profiles,
        config_path=default_config_path(),
    )
    _validate_profile_invariants(registry)
    return registry


def with_profile(registry: Registry, profile: Profile) -> Registry:
    profiles = dict(registry.profiles)
    profiles[profile.id] = profile
    updated = replace(registry, profiles=profiles)
    _validate_profile_invariants(updated)
    return updated


def with_provider(registry: Registry, provider: ProviderConfig) -> Registry:
    providers = dict(registry.providers)
    providers[provider.name] = provider
    return replace(registry, providers=providers)


def without_profile(registry: Registry, profile_id: str) -> Registry:
    profile = registry.require_profile(profile_id)
    if profile.safety_policy != "worker":
        raise ValueError(
            f"{profile.safety_policy} profile {profile_id} cannot be removed by the live "
            "registry API; use an offline reviewed registry migration"
        )
    profiles = dict(registry.profiles)
    del profiles[profile_id]
    return replace(registry, profiles=profiles)


def _paths_overlap(first: Path, second: Path) -> bool:
    return first == second or first in second.parents or second in first.parents


def _validate_profile_invariants(registry: Registry) -> None:
    if not _valid_sha256(registry.settings.quota_binary_sha256):
        raise ValueError("settings.quota_binary_sha256 must be a lowercase SHA-256 digest")
    if not _valid_sha256(registry.settings.quota_node_sha256):
        raise ValueError("settings.quota_node_sha256 must be a lowercase SHA-256 digest")
    if not _valid_sha256(registry.settings.quota_release_tree_sha256):
        raise ValueError("settings.quota_release_tree_sha256 must be a lowercase SHA-256 digest")
    for provider_name, provider in registry.providers.items():
        disallowed = sorted(set(provider.shared_entries) - SHARED_WORKFLOW_ENTRIES[provider_name])
        if disallowed:
            raise ValueError(
                f"providers.{provider_name}.shared_entries contains non-workflow assets: "
                + ", ".join(disallowed)
            )
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
    assert_no_pending_credential_recovery(
        registry,
        {profile.provider},
        operation="profile enablement change",
    )
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
    assert_no_pending_credential_recovery(
        registry,
        {profile.provider},
        operation="profile safety-policy change",
    )
    if profile.safety_policy != "worker" and safety_policy != profile.safety_policy:
        raise ValueError(
            f"{profile.safety_policy} classification is terminal for {profile.id}; "
            "use an offline reviewed registry migration"
        )
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


def _assert_registry_parent_ancestry(parent: Path) -> None:
    current = parent.absolute()
    leaf = current
    while True:
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            current = current.parent
            continue
        if not stat.S_ISDIR(metadata.st_mode):
            raise ValueError(f"registry parent has symlinked or non-directory ancestry: {parent}")
        mode = stat.S_IMODE(metadata.st_mode)
        if current == leaf:
            if metadata.st_uid != os.getuid() or mode & 0o022:
                raise ValueError(
                    "registry parent must be current-user owned and not group/world writable: "
                    f"{parent}"
                )
        elif mode & 0o022 and not (mode & stat.S_ISVTX and metadata.st_uid == 0):
            raise ValueError(f"registry parent has unsafe writable ancestry: {current}")
        if current == current.parent:
            return
        current = current.parent


def _open_registry_parent(parent: Path) -> tuple[int, tuple[int, int]]:
    try:
        current = parent.lstat()
    except FileNotFoundError:
        try:
            parent.mkdir(parents=True, mode=0o700)
        except FileExistsError as exc:
            raise ValueError(f"registry parent changed during creation: {parent}") from exc
        parent.chmod(0o700)
        current = parent.lstat()
    if not stat.S_ISDIR(current.st_mode):
        raise ValueError(f"registry parent must be a real directory: {parent}")
    _assert_registry_parent_ancestry(parent)
    flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        parent_fd = os.open(parent, flags)
    except OSError as exc:
        raise ValueError(f"registry parent is not a safe directory: {parent}") from exc
    opened = os.fstat(parent_fd)
    identity = (opened.st_dev, opened.st_ino)
    if (
        not stat.S_ISDIR(opened.st_mode)
        or opened.st_uid != os.getuid()
        or stat.S_IMODE(opened.st_mode) & 0o022
        or identity != (current.st_dev, current.st_ino)
    ):
        os.close(parent_fd)
        raise ValueError(f"registry parent changed while opening: {parent}")
    return parent_fd, identity


def _registry_parent_matches(parent: Path, identity: tuple[int, int]) -> bool:
    try:
        current = parent.lstat()
    except FileNotFoundError:
        return False
    return stat.S_ISDIR(current.st_mode) and (current.st_dev, current.st_ino) == identity


def save_registry(registry: Registry, path: Path | None = None) -> Path:
    _validate_profile_invariants(registry)
    config_path = path or default_config_path()
    lines = [
        "# Agent Fleet registry. Contains labels and policy only; never credentials.",
        f"version = {registry.version}",
        "",
        "[settings]",
        f"state_dir = {_toml_string(registry.settings.state_dir)}",
        f"share_dir = {_toml_string(registry.settings.share_dir)}",
        f"quota_binary = {_toml_string(registry.settings.quota_binary)}",
        f"quota_binary_sha256 = {_toml_string(registry.settings.quota_binary_sha256)}",
        f"quota_node_binary = {_toml_string(registry.settings.quota_node_binary)}",
        f"quota_node_sha256 = {_toml_string(registry.settings.quota_node_sha256)}",
        f"quota_release_tree_sha256 = {_toml_string(registry.settings.quota_release_tree_sha256)}",
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
                "trusted_projects = ["
                + ", ".join(_toml_string(entry) for entry in provider_config.trusted_projects)
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
    parent_fd, parent_identity = _open_registry_parent(config_path.parent)
    temp_name = f".{config_path.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp"
    temp_fd: int | None = None
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        temp_fd = os.open(temp_name, flags, 0o600, dir_fd=parent_fd)
        os.fchmod(temp_fd, 0o600)
        with os.fdopen(temp_fd, "w", encoding="utf-8") as handle:
            temp_fd = None
            handle.write("\n".join(lines) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        if not _registry_parent_matches(config_path.parent, parent_identity):
            raise ValueError(f"registry parent changed during save: {config_path.parent}")
        os.replace(
            temp_name,
            config_path.name,
            src_dir_fd=parent_fd,
            dst_dir_fd=parent_fd,
        )
        os.fsync(parent_fd)
        if not _registry_parent_matches(config_path.parent, parent_identity):
            raise ValueError(f"registry parent changed during save: {config_path.parent}")
    except BaseException:
        if temp_fd is not None:
            os.close(temp_fd)
        with suppress(FileNotFoundError):
            os.unlink(temp_name, dir_fd=parent_fd)
        raise
    finally:
        os.close(parent_fd)
    return config_path
