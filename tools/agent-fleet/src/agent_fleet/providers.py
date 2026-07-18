from __future__ import annotations

import json
import os
import shlex
import shutil
import subprocess
from collections.abc import Iterable
from hashlib import sha256
from pathlib import Path

from .models import Profile, Registry


def identity_fingerprint(provider: str, identifier: str) -> str:
    return sha256(f"{provider}:{identifier}".encode()).hexdigest()


def provider_environment(
    profile: Profile,
    task: str | None = None,
    workspace: Path | None = None,
) -> dict[str, str]:
    env = dict(os.environ)
    for name in tuple(env):
        if name.startswith(("ANTHROPIC_", "CLAUDE_", "OPENAI_", "CODEX_")):
            env.pop(name, None)
    env.pop("AGENT_FLEET_QUOTA_FIXTURE_DIR", None)
    env.pop("AGENT_FLEET_TEST_QUOTA_FIXTURE_DIR", None)
    env["AGENT_FLEET_PROFILE"] = profile.id
    env["AGENT_FLEET_PROVIDER"] = profile.provider
    if task:
        env["AGENT_FLEET_TASK_ID"] = task
    else:
        env.pop("AGENT_FLEET_TASK_ID", None)
    if workspace is not None:
        env["AGENT_FLEET_WORKSPACE"] = str(workspace)
    else:
        env.pop("AGENT_FLEET_WORKSPACE", None)
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


def _matches_long_option(argument: str, names: set[str]) -> bool:
    return argument in names or any(argument.startswith(f"{name}=") for name in names)


def _validate_codex_config(value: str) -> None:
    key, separator, _ = value.partition("=")
    if not separator or key.strip() not in {"model_reasoning_effort", "notify"}:
        raise ValueError(
            "worker exec allows only model_reasoning_effort and notify Codex config overrides"
        )


def validate_worker_arguments(profile: Profile, arguments: list[str]) -> None:
    blocked_commands = {
        "login",
        "logout",
        "resume",
        "fork",
        "auth",
        "--resume",
        "--continue",
    }
    if any(
        argument in blocked_commands
        or argument == "-r"
        or argument.startswith("--resume=")
        or argument.startswith("--continue=")
        for argument in arguments
    ):
        raise ValueError("worker exec refuses provider auth and resume commands")
    if any(
        argument in {"-C", "--cd", "--cwd", "--directory", "--add-dir"}
        or argument.startswith(("-C", "--cd=", "--cwd=", "--directory=", "--add-dir="))
        for argument in arguments
    ):
        raise ValueError("worker exec refuses provider working-directory overrides")
    if profile.provider != "codex":
        forbidden = {
            "--settings",
            "--setting-sources",
            "--bare",
            "--safe-mode",
            "--no-session-persistence",
            "--session-id",
            "--fork-session",
            "--worktree",
            "--tmux",
            "--background",
            "--from-pr",
            "--cloud",
            "--remote",
            "--teleport",
            "--setup-token",
            "--agents",
        }
        if any(
            argument == "-c"
            or (argument.startswith("-c") and len(argument) > 2)
            or argument == "-r"
            or (argument.startswith("-r") and len(argument) > 2)
            or _matches_long_option(argument, forbidden)
            for argument in arguments
        ):
            raise ValueError("worker exec refuses unmanaged Claude launch and session controls")
        return
    if any(argument in {"plugin", "features", "mcp"} for argument in arguments):
        raise ValueError("worker exec refuses Codex plugin and configuration administration")
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if (
            argument == "-p"
            or (argument.startswith("-p") and len(argument) > 2)
            or _matches_long_option(
                argument,
                {
                    "--profile",
                    "--remote",
                    "--oss",
                    "--local-provider",
                    "--provider",
                    "--credential-store",
                    "--hooks",
                    "--plugins",
                    "--projects",
                    "--trust",
                },
            )
        ):
            raise ValueError("worker exec refuses alternate Codex config and runtime profiles")
        if argument == "--dangerously-bypass-hook-trust":
            raise ValueError("worker exec owns the Codex hook-trust override")
        if argument == "--enable" or argument.startswith("--enable="):
            raise ValueError("managed Codex launches keep plugins disabled")
        if argument in {"--no-hooks", "--skip-hooks", "--disable-hooks"}:
            raise ValueError("managed Codex launches require hooks")
        if argument == "--disable":
            if index + 1 >= len(arguments):
                raise ValueError("Codex --disable requires a feature name")
            if arguments[index + 1] == "hooks":
                raise ValueError("managed Codex launches require hooks")
            index += 2
            continue
        if argument.startswith("--disable=") and argument.split("=", 1)[1] == "hooks":
            raise ValueError("managed Codex launches require hooks")
        if argument in {"-c", "--config"}:
            if index + 1 >= len(arguments):
                raise ValueError("Codex config override requires a value")
            _validate_codex_config(arguments[index + 1])
            index += 2
            continue
        if argument.startswith("-c") and len(argument) > 2:
            _validate_codex_config(argument[2:])
        elif argument.startswith("--config="):
            _validate_codex_config(argument.split("=", 1)[1])
        index += 1


def codex_launch_prefix(active_root: Path) -> list[str]:
    trust_override = f'projects.{json.dumps(str(active_root))}.trust_level="trusted"'
    return [
        "--disable",
        "plugins",
        "--disable",
        "plugin_sharing",
        "-c",
        trust_override,
        "--dangerously-bypass-hook-trust",
    ]


def managed_argv(
    registry: Registry,
    profile: Profile,
    active_root: Path,
    extra: list[str],
) -> list[str]:
    prefix = codex_launch_prefix(active_root) if profile.provider == "codex" else []
    return provider_argv(registry, profile, [*prefix, *extra])


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
            cwd=profile.home,
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
    executable = shutil.which("agent-fleet") or "agent-fleet"
    return f"{shlex.quote(executable)} --format json hook session-start"


def resume_argv(
    registry: Registry,
    profile: Profile,
    session_id: str,
    extra: list[str],
    *,
    active_root: Path,
) -> list[str]:
    if profile.provider == "claude":
        return provider_argv(registry, profile, ["--resume", session_id, *extra])
    return provider_argv(
        registry,
        profile,
        ["resume", *codex_launch_prefix(active_root), session_id, *extra],
    )
