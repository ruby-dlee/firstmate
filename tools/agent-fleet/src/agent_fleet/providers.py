from __future__ import annotations

import os
import shlex
import shutil
import subprocess
from collections.abc import Iterable
from hashlib import sha256

from .models import Profile, Registry


def identity_fingerprint(provider: str, identifier: str) -> str:
    return sha256(f"{provider}:{identifier}".encode()).hexdigest()


def provider_environment(profile: Profile, task: str | None = None) -> dict[str, str]:
    env = dict(os.environ)
    for name in tuple(env):
        if name.startswith(("ANTHROPIC_", "CLAUDE_", "OPENAI_", "CODEX_")):
            env.pop(name, None)
    env["AGENT_FLEET_PROFILE"] = profile.id
    env["AGENT_FLEET_PROVIDER"] = profile.provider
    if task:
        env["AGENT_FLEET_TASK_ID"] = task
    else:
        env.pop("AGENT_FLEET_TASK_ID", None)
    if profile.provider == "claude":
        env["CLAUDE_CONFIG_DIR"] = str(profile.home)
        env["DISABLE_LOGIN_COMMAND"] = "1"
        env["DISABLE_LOGOUT_COMMAND"] = "1"
    elif profile.provider == "codex":
        env["CODEX_HOME"] = str(profile.home)
        env["CODEX_SQLITE_HOME"] = str(profile.home)
    return env


def provider_argv(registry: Registry, profile: Profile, command: Iterable[str] = ()) -> list[str]:
    binary = registry.require_provider(profile.provider).binary
    suffix = list(command)
    return [str(binary), *suffix]


def login_argv(
    registry: Registry,
    profile: Profile,
    *,
    browser_login: bool = False,
    access_token: bool = False,
) -> list[str]:
    if profile.provider == "claude":
        suffix = ["auth", "login"]
    elif access_token:
        suffix = ["login", "--with-access-token"]
    else:
        suffix = ["login"] if browser_login else ["login", "--device-auth"]
    return provider_argv(registry, profile, suffix)


def auth_probe(registry: Registry, profile: Profile) -> dict[str, str | None]:
    binary = registry.require_provider(profile.provider).binary
    if not binary.exists():
        return {
            "status": "binary-missing",
            "identity_fingerprint": None,
            "identity_source": None,
        }
    suffix = ["auth", "status", "--json"] if profile.provider == "claude" else ["login", "status"]
    try:
        result = subprocess.run(
            [str(binary), *suffix],
            env=provider_environment(profile),
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return {
            "status": "unknown",
            "identity_fingerprint": None,
            "identity_source": None,
        }
    status = "authenticated" if result.returncode == 0 else "unauthenticated"
    return {
        "status": status,
        "identity_fingerprint": None,
        "identity_source": None,
    }


def auth_status(registry: Registry, profile: Profile) -> str:
    return str(auth_probe(registry, profile)["status"])


def session_hook_command() -> str:
    configured = os.environ.get("AGENT_FLEET_BIN")
    executable = configured or shutil.which("agent-fleet") or "agent-fleet"
    return f"{shlex.quote(executable)} --format json hook session-start"


def resume_argv(
    registry: Registry,
    profile: Profile,
    session_id: str,
    extra: list[str],
) -> list[str]:
    if profile.provider == "claude":
        return provider_argv(registry, profile, ["--resume", session_id, *extra])
    return provider_argv(registry, profile, ["resume", session_id, *extra])
