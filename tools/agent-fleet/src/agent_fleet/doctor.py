from __future__ import annotations

import json
import os
import shutil
import stat
from pathlib import Path
from typing import Any

from .models import Registry
from .projects import registered_trusted_projects
from .providers import auth_status
from .provision import (
    profile_hook_health,
    profile_is_provisioned,
    profile_selection_ready,
    profile_shared_assets_healthy,
)
from .quota import has_remote_identity_proof, read_quota


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
    project: Path | None = None,
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
        projects_ready = bool(config.trusted_projects)
        if projects_ready:
            try:
                registered_trusted_projects(registry, provider)
            except ValueError:
                projects_ready = False
        add(
            f"trusted-projects:{provider}",
            projects_ready,
            ",".join(str(path) for path in config.trusted_projects) or "none",
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
        quota = read_quota(registry, profile.id)
        remote_verified = (
            provisioned
            and status == "authenticated"
            and quota.get("fresh") is True
            and has_remote_identity_proof(quota)
        )
        add(
            f"profile:{profile.id}:remote-identity-proof",
            remote_verified,
            "fresh" if remote_verified else str(quota.get("reason") or quota.get("status")),
            required=profile.enabled and profile.safety_policy == "worker",
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
        claude_events = _workspace_hook_events(workspace / ".claude" / "settings.json")
        required = {"PreToolUse", "Stop"}
        add(
            "workspace:claude:supervision-hooks",
            required.issubset(claude_events),
            f"{workspace}: events={','.join(sorted(claude_events)) or 'none'}",
        )
        codex_events = _workspace_hook_events(workspace / ".codex" / "hooks.json")
        add(
            "workspace:codex:supervision-hooks",
            required.issubset(codex_events),
            f"{workspace}: events={','.join(sorted(codex_events)) or 'none'}",
        )
    if project is not None:
        for profile in sorted(registry.profiles.values(), key=lambda item: item.id):
            ready = profile_is_provisioned(profile) and profile_selection_ready(
                registry, profile, project
            )
            add(
                f"project:{profile.id}:provider-bootstrap",
                ready,
                "ready" if ready else "project, onboarding, or hook readiness failed",
                required=profile.enabled and profile.safety_policy == "worker",
            )
    required_failures = [check for check in checks if check["required"] and not check["ok"]]
    return {
        "healthy": not required_failures,
        "profiles": len(registry.profiles),
        "enabled_profiles": sum(profile.enabled for profile in registry.profiles.values()),
        "workspace": str(workspace) if workspace else None,
        "project": str(project) if project else None,
        "checks": checks,
    }
