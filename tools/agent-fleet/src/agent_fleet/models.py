from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

SUPPORTED_PROVIDERS = ("claude", "codex")
PROFILE_SAFETY_POLICIES = ("worker", "manual_only", "desktop_shared")


@dataclass(frozen=True)
class ProviderConfig:
    name: str
    binary: Path
    base_home: Path | None = None
    hooks_source: Path | None = None
    shared_entries: tuple[str, ...] = ()
    desktop_identity_file: Path | None = None


@dataclass(frozen=True)
class Profile:
    id: str
    provider: str
    home: Path
    pools: tuple[str, ...]
    enabled: bool = False
    weight: int = 1
    max_concurrent: int = 2
    reserve_percent: int = 15
    safety_policy: str = "worker"

    def public_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "provider": self.provider,
            "home": str(self.home),
            "pools": list(self.pools),
            "enabled": self.enabled,
            "weight": self.weight,
            "max_concurrent": self.max_concurrent,
            "reserve_percent": self.reserve_percent,
            "safety_policy": self.safety_policy,
        }


@dataclass(frozen=True)
class Settings:
    state_dir: Path
    share_dir: Path
    quota_binary: Path
    quota_stale_seconds: int = 300
    quota_verification_grace_seconds: int = 86400
    lease_grace_seconds: int = 30
    active_lease_penalty: int = 8
    lock_stale_seconds: int = 30


@dataclass(frozen=True)
class Registry:
    version: int
    settings: Settings
    providers: dict[str, ProviderConfig] = field(default_factory=dict)
    profiles: dict[str, Profile] = field(default_factory=dict)

    def require_profile(self, profile_id: str) -> Profile:
        try:
            return self.profiles[profile_id]
        except KeyError as exc:
            raise ValueError(f"unknown profile: {profile_id}") from exc

    def require_provider(self, provider: str) -> ProviderConfig:
        try:
            return self.providers[provider]
        except KeyError as exc:
            raise ValueError(f"provider binary is not configured: {provider}") from exc
