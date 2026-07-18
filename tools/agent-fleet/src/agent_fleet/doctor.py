from __future__ import annotations

import json
import os
import shutil
import stat
from pathlib import Path
from typing import Any

from .models import Registry
from .providers import auth_status
from .provision import (
    profile_hook_health,
    profile_is_provisioned,
    profile_shared_assets_healthy,
)


def _mode(path: Path) -> str | None:
    try:
        return oct(stat.S_IMODE(path.stat().st_mode))
    except FileNotFoundError:
        return None


def _workspace_hook_events(path: Path) -> set[str]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return set()
    hooks = payload.get("hooks", {}) if isinstance(payload, dict) else {}
    return set(hooks) if isinstance(hooks, dict) else set()


def run_doctor(
    registry: Registry,
    config_path: Path,
    *,
    workspace: Path | None = None,
) -> dict[str, Any]:
    checks: list[dict[str, Any]] = []

    def add(name: str, ok: bool, detail: str, *, required: bool = True) -> None:
        checks.append({"name": name, "ok": ok, "required": required, "detail": detail})

    add(
        "registry-permissions",
        _mode(config_path) == "0o600",
        f"{config_path} mode={_mode(config_path)} expected=0o600",
    )
    add("toon", shutil.which("toon") is not None, "TOON encoder on PATH")
    add(
        "quota-axi",
        registry.settings.quota_binary.is_file()
        and os.access(registry.settings.quota_binary, os.X_OK),
        f"pinned quota reader: {registry.settings.quota_binary}",
    )
    for provider, config in registry.providers.items():
        binary_ok = config.binary.is_file() and os.access(config.binary, os.X_OK)
        add(
            f"binary:{provider}",
            binary_ok,
            f"{config.binary}",
        )
    for profile in sorted(registry.profiles.values(), key=lambda item: item.id):
        provisioned = profile_is_provisioned(profile)
        add(
            f"profile:{profile.id}:provisioned",
            provisioned or not profile.enabled,
            "provisioned" if provisioned else "not provisioned (allowed while disabled)",
        )
        status = auth_status(registry, profile) if provisioned else "not-provisioned"
        add(
            f"profile:{profile.id}:auth",
            status == "authenticated" or not profile.enabled,
            status,
        )
        if provisioned:
            home_mode = _mode(profile.home)
            add(
                f"profile:{profile.id}:home-permissions",
                home_mode == "0o700",
                f"mode={home_mode} expected=0o700",
            )
            hook_health = profile_hook_health(registry, profile)
            for name, healthy in hook_health.items():
                add(
                    f"profile:{profile.id}:{name.replace('_', '-')}",
                    healthy,
                    "present" if healthy else "missing",
                )
            shared_healthy = profile_shared_assets_healthy(registry, profile)
            add(
                f"profile:{profile.id}:shared-workflow-assets",
                shared_healthy,
                "healthy" if shared_healthy else "missing or redirected link",
            )
    if workspace is not None:
        workspace = workspace.resolve()
        claude_events = _workspace_hook_events(workspace / ".claude" / "settings.json")
        codex_events = _workspace_hook_events(workspace / ".codex" / "hooks.json")
        for provider, events in (("claude", claude_events), ("codex", codex_events)):
            required = {"PreToolUse", "Stop"}
            add(
                f"workspace:{provider}:supervision-hooks",
                required.issubset(events),
                f"{workspace}: events={','.join(sorted(events)) or 'none'}",
            )
    required_failures = [check for check in checks if check["required"] and not check["ok"]]
    return {
        "healthy": not required_failures,
        "profiles": len(registry.profiles),
        "enabled_profiles": sum(profile.enabled for profile in registry.profiles.values()),
        "workspace": str(workspace) if workspace else None,
        "checks": checks,
    }
