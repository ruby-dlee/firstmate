from __future__ import annotations

import json
import os
import shlex
import stat
import subprocess
import sys
from collections.abc import Iterable
from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path
from typing import Literal

from .models import Profile, Registry
from .paths import current_user_home
from .util import read_owned_private_json


def identity_fingerprint(provider: str, identifier: str) -> str:
    return sha256(f"{provider}:{identifier}".encode()).hexdigest()


CredentialFileState = Literal["present", "absent", "indeterminate"]

INJECTION_ENV_PREFIXES = (
    "BASH_",
    "DYLD_",
    "ELECTRON_",
    "LD_",
    "MALLOC_",
    "NODE_",
    "NPM_CONFIG_",
    "PERL5",
    "PYTHON",
    "RUBY",
    "npm_config_",
)
INJECTION_ENV_EXACT = frozenset(
    {
        "BASHOPTS",
        "BROWSER",
        "CHROME_PATH",
        "DBUS_SESSION_BUS_ADDRESS",
        "DISPLAY",
        "ALL_PROXY",
        "CURL_CA_BUNDLE",
        "ENV",
        "GCONV_PATH",
        "GIT_ASKPASS",
        "GIT_TERMINAL_PROMPT",
        "GH_BROWSER",
        "GCM_GUI_PROMPT",
        "GCM_INTERACTIVE",
        "GCM_MODAL_PROMPT",
        "INIT_CWD",
        "LOCPATH",
        "NLSPATH",
        "PERL5OPT",
        "PERLLIB",
        "REQUESTS_CA_BUNDLE",
        "RUBYLIB",
        "RUBYOPT",
        "SHELLOPTS",
        "SSH_ASKPASS",
        "SSH_ASKPASS_REQUIRE",
        "SSLKEYLOGFILE",
        "SSL_CERT_DIR",
        "SSL_CERT_FILE",
        "SUDO_ASKPASS",
        "WAYLAND_DISPLAY",
        "XAUTHORITY",
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "all_proxy",
        "http_proxy",
        "https_proxy",
    }
)

CONTROL_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"


def scrub_injection_environment(environment: dict[str, str]) -> dict[str, str]:
    cleaned = dict(environment)
    for name in tuple(cleaned):
        if name in INJECTION_ENV_EXACT or name.startswith(INJECTION_ENV_PREFIXES):
            cleaned.pop(name, None)
    return cleaned


def validated_worker_path(value: str | None = None) -> str:
    """Build a functional worker PATH from safe, physically resolved directories.

    Provider control probes never use this path. Workers need the operator's
    toolchain, so their separate contract accepts current-user or root-owned
    directories that are not world-writable and drops missing/relative entries.
    """

    source = os.environ.get("PATH", "") if value is None else value
    directories: list[str] = []
    seen: set[str] = set()
    for raw in [*source.split(os.pathsep), *CONTROL_PATH.split(os.pathsep)]:
        path = Path(raw)
        if not raw or not path.is_absolute():
            continue
        try:
            resolved = path.resolve(strict=True)
            metadata = resolved.stat()
        except OSError:
            continue
        if (
            not stat.S_ISDIR(metadata.st_mode)
            or metadata.st_uid not in {0, os.getuid()}
            or stat.S_IMODE(metadata.st_mode) & stat.S_IWOTH
        ):
            continue
        physical = str(resolved)
        if physical not in seen:
            seen.add(physical)
            directories.append(physical)
    if not directories:
        raise ValueError("worker PATH has no safe functional directories")
    return os.pathsep.join(directories)


def credential_file_path(profile: Profile) -> Path:
    return profile.home / (".credentials.json" if profile.provider == "claude" else "auth.json")


def credential_file_state(profile: Profile) -> tuple[CredentialFileState, str | None]:
    """Classify only the provider's file-backed credential source.

    Claude may still have a profile-scoped Keychain credential when its file
    is absent. Callers must use Quota AXI's source attempts to classify that
    additional source; an unsafe or malformed file is always indeterminate.
    """

    path = credential_file_path(profile)
    try:
        payload = read_owned_private_json(path, label=f"{profile.provider} credential file")
    except FileNotFoundError:
        return "absent", None
    except ValueError as exc:
        return "indeterminate", str(exc)
    if not isinstance(payload, dict):
        return "indeterminate", "credential_payload_invalid"
    if profile.provider == "codex":
        tokens = payload.get("tokens")
        token = (
            tokens.get("access_token") or tokens.get("accessToken")
            if isinstance(tokens, dict)
            else None
        )
    else:
        oauth = payload.get("claudeAiOauth")
        token = (
            oauth.get("accessToken") or oauth.get("access_token")
            if isinstance(oauth, dict)
            else None
        )
    if not isinstance(token, str) or not token:
        return "indeterminate", "credential_payload_invalid"
    return "present", None


def credential_storage_ready(profile: Profile) -> bool:
    state, _ = credential_file_state(profile)
    if state == "indeterminate":
        return False
    return state == "present" or profile.provider == "claude"


def provider_environment(
    profile: Profile,
    task: str | None = None,
    workspace: Path | None = None,
    pool: str | None = None,
    turn_end: Path | None = None,
    *,
    default_provider_home: bool = False,
    operation: Literal["control", "worker"] = "control",
) -> dict[str, str]:
    env = scrub_injection_environment(dict(os.environ))
    for name in tuple(env):
        if name.startswith(("AGENT_FLEET_", "QUOTA_AXI_", "XDG_")):
            env.pop(name, None)
    env["HOME"] = str(current_user_home())
    for name in tuple(env):
        if name.startswith(("ANTHROPIC_", "CLAUDE_", "OPENAI_", "CODEX_")):
            env.pop(name, None)
    if operation == "control":
        env["PATH"] = CONTROL_PATH
    elif operation == "worker":
        env["PATH"] = validated_worker_path()
    else:
        raise ValueError(f"unsupported provider environment operation: {operation}")
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
    if pool:
        env["AGENT_FLEET_POOL"] = pool
    else:
        env.pop("AGENT_FLEET_POOL", None)
    if turn_end is not None:
        env["AGENT_FLEET_TURN_END"] = str(turn_end)
    else:
        env.pop("AGENT_FLEET_TURN_END", None)
    if profile.provider == "claude":
        if not default_provider_home:
            env["CLAUDE_CONFIG_DIR"] = str(profile.home)
        env["CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION"] = "false"
        env["DISABLE_LOGIN_COMMAND"] = "1"
        env["DISABLE_LOGOUT_COMMAND"] = "1"
    elif profile.provider == "codex":
        env["CODEX_HOME"] = str(profile.home)
        env["CODEX_SQLITE_HOME"] = str(profile.home)
    return env


def verified_provider_argv(binary: Path, command: Iterable[str] = ()) -> list[str]:
    if not binary.is_absolute():
        raise ValueError("verified provider binary path must be absolute")
    return [str(binary), *command]


WorkerOperation = Literal["exec", "resume"]
CLAUDE_EFFORTS = frozenset({"low", "medium", "high", "xhigh", "max"})
CODEX_EFFORTS = frozenset({"low", "medium", "high", "xhigh"})


@dataclass(frozen=True)
class WorkerArguments:
    """A validated FirstMate provider launch, separated from raw caller argv."""

    provider: str
    operation: WorkerOperation
    model: str | None = None
    effort: str | None = None
    notify_path: Path | None = None
    prompt: str | None = None


def _require_model(value: str) -> str:
    if (
        not value
        or value.startswith("-")
        or len(value) > 256
        or any(ord(character) < 32 or ord(character) == 127 for character in value)
    ):
        raise ValueError("managed worker --model requires a printable non-option value")
    return value


def _parse_codex_effort(value: str) -> str:
    prefix = 'model_reasoning_effort="'
    if not value.startswith(prefix) or not value.endswith('"'):
        raise ValueError("managed Codex effort must use FirstMate's exact config form")
    effort = value[len(prefix) : -1]
    if effort not in CODEX_EFFORTS:
        raise ValueError("managed Codex effort must be low, medium, high, or xhigh")
    return effort


def _firstmate_shell_quote(value: str) -> str:
    return "'" + value.replace("'", "'\\''") + "'"


def _parse_codex_notify(value: str) -> Path:
    key, separator, encoded = value.partition("=")
    if key != "notify" or not separator:
        raise ValueError("managed Codex notify must use FirstMate's exact config form")
    try:
        command = json.loads(encoded)
    except json.JSONDecodeError as exc:
        raise ValueError("managed Codex notify must be valid JSON") from exc
    if (
        not isinstance(command, list)
        or len(command) != 3
        or command[:2] != ["bash", "-c"]
        or not isinstance(command[2], str)
    ):
        raise ValueError("managed Codex notify must be FirstMate's turn-end command")
    try:
        words = shlex.split(command[2])
    except ValueError as exc:
        raise ValueError("managed Codex notify command is not valid shell syntax") from exc
    if len(words) != 2 or words[0] != "touch":
        raise ValueError("managed Codex notify must only touch the turn-end marker")
    path = Path(words[1])
    if (
        not path.is_absolute()
        or path.name in {"", ".", ".."}
        or not path.name.endswith(".turn-ended")
        or command[2] != f"touch {_firstmate_shell_quote(str(path))}"
    ):
        raise ValueError("managed Codex notify must name one canonical turn-end marker")
    return path


def _parse_prompt(arguments: list[str], operation: WorkerOperation) -> str | None:
    if operation == "resume":
        if arguments:
            raise ValueError("managed worker resume accepts no caller prompt or session")
        return None
    if len(arguments) != 1 or not arguments[0]:
        raise ValueError("managed worker exec requires exactly one non-empty prompt")
    return arguments[0]


def parse_worker_arguments(
    profile: Profile,
    arguments: list[str],
    *,
    operation: WorkerOperation,
) -> WorkerArguments:
    """Parse only the exact provider argv forms emitted by FirstMate."""

    if operation not in {"exec", "resume"}:
        raise ValueError(f"unsupported managed worker operation: {operation}")
    remaining = list(arguments)
    model: str | None = None
    effort: str | None = None
    notify_path: Path | None = None

    if profile.provider == "claude":
        if not remaining or remaining.pop(0) != "--dangerously-skip-permissions":
            raise ValueError("managed Claude launch requires FirstMate's autonomy flag")
        if remaining[:1] == ["--model"]:
            if len(remaining) < 2:
                raise ValueError("managed Claude --model requires a value")
            model = _require_model(remaining[1])
            del remaining[:2]
        if remaining[:1] == ["--effort"]:
            if len(remaining) < 2 or remaining[1] not in CLAUDE_EFFORTS:
                raise ValueError("managed Claude effort must be low, medium, high, xhigh, or max")
            effort = remaining[1]
            del remaining[:2]
    elif profile.provider == "codex":
        if remaining[:1] == ["--model"]:
            if len(remaining) < 2:
                raise ValueError("managed Codex --model requires a value")
            model = _require_model(remaining[1])
            del remaining[:2]
        if remaining[:1] == ["-c"]:
            if len(remaining) < 2:
                raise ValueError("managed Codex effort requires a value")
            effort = _parse_codex_effort(remaining[1])
            del remaining[:2]
        if not remaining or remaining.pop(0) != "--dangerously-bypass-approvals-and-sandbox":
            raise ValueError("managed Codex launch requires FirstMate's autonomy flag")
        if remaining[:1] == ["-c"]:
            if len(remaining) < 2:
                raise ValueError("managed Codex notify requires a value")
            notify_path = _parse_codex_notify(remaining[1])
            del remaining[:2]
    else:
        raise ValueError(f"unsupported managed worker provider: {profile.provider}")

    return WorkerArguments(
        provider=profile.provider,
        operation=operation,
        model=model,
        effort=effort,
        notify_path=notify_path,
        prompt=_parse_prompt(remaining, operation),
    )


def validate_worker_arguments(
    profile: Profile,
    arguments: list[str],
    *,
    operation: WorkerOperation = "exec",
) -> WorkerArguments:
    """Compatibility wrapper returning the structured positive-grammar result."""

    return parse_worker_arguments(profile, arguments, operation=operation)


def _worker_launch_options(
    arguments: WorkerArguments,
    *,
    hook_entrypoint: Path | None = None,
    config_path: Path | None = None,
) -> list[str]:
    options: list[str] = []
    if arguments.provider == "claude":
        options.append("--dangerously-skip-permissions")
        if arguments.model is not None:
            options.extend(["--model", arguments.model])
        if arguments.effort is not None:
            options.extend(["--effort", arguments.effort])
        return options
    if arguments.model is not None:
        options.extend(["--model", arguments.model])
    if arguments.effort is not None:
        options.extend(["-c", f'model_reasoning_effort="{arguments.effort}"'])
    options.append("--dangerously-bypass-approvals-and-sandbox")
    if arguments.notify_path is not None:
        if (
            hook_entrypoint is None
            or not hook_entrypoint.is_absolute()
            or config_path is None
            or not config_path.is_absolute()
        ):
            raise ValueError(
                "managed Codex notify requires a verified Agent Fleet entrypoint and config"
            )
        notify = [
            str(hook_entrypoint),
            "--config",
            str(config_path),
            "--format",
            "json",
            "hook",
            "turn-end",
        ]
        options.extend(["-c", f"notify={json.dumps(notify, separators=(',', ':'))}"])
    return options


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
    arguments: WorkerArguments,
    *,
    binary: Path,
    hook_entrypoint: Path | None = None,
) -> list[str]:
    if (
        arguments.provider != profile.provider
        or arguments.operation != "exec"
        or arguments.prompt is None
    ):
        raise ValueError("managed exec arguments do not match the selected provider")
    prefix = codex_launch_prefix(active_root) if profile.provider == "codex" else []
    if registry.config_path is None or not registry.config_path.is_absolute():
        raise ValueError("managed exec requires an absolute loaded registry path")
    return verified_provider_argv(
        binary,
        [
            *prefix,
            *_worker_launch_options(
                arguments,
                hook_entrypoint=hook_entrypoint,
                config_path=registry.config_path,
            ),
            "--",
            arguments.prompt,
        ],
    )


def login_argv(
    registry: Registry,
    profile: Profile,
    *,
    binary: Path,
    browser_login: bool = False,
    access_token: bool = False,
) -> list[str]:
    if profile.provider == "claude":
        suffix = ["auth", "login"]
    elif access_token:
        suffix = ["login", "--with-access-token"]
    else:
        suffix = ["login"] if browser_login else ["login", "--device-auth"]
    return verified_provider_argv(binary, suffix)


def auth_probe(
    profile: Profile,
    *,
    binary: Path,
    default_provider_home: bool = False,
) -> dict[str, str | None]:
    suffix = ["auth", "status", "--json"] if profile.provider == "claude" else ["login", "status"]
    try:
        result = subprocess.run(
            [str(binary), *suffix],
            env=provider_environment(profile, default_provider_home=default_provider_home),
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


def auth_status(profile: Profile, *, binary: Path) -> str:
    return str(auth_probe(profile, binary=binary)["status"])


def agent_fleet_entrypoint_path() -> Path:
    """Return the release-local console entrypoint beside the running interpreter."""

    return (Path(sys.executable).absolute().parent / "agent-fleet").absolute()


def session_hook_command(config_path: Path, executable: Path | None = None) -> str:
    pinned = executable or agent_fleet_entrypoint_path()
    if not config_path.is_absolute():
        raise ValueError("SessionStart hook config path must be absolute")
    return (
        f"{shlex.quote(str(pinned))} --config {shlex.quote(str(config_path))} "
        "--format json hook session-start"
    )


def resume_argv(
    registry: Registry,
    profile: Profile,
    session_id: str,
    arguments: WorkerArguments,
    *,
    active_root: Path,
    binary: Path,
    hook_entrypoint: Path | None = None,
) -> list[str]:
    if (
        arguments.provider != profile.provider
        or arguments.operation != "resume"
        or arguments.prompt is not None
    ):
        raise ValueError("managed resume arguments do not match the selected provider")
    if registry.config_path is None or not registry.config_path.is_absolute():
        raise ValueError("managed resume requires an absolute loaded registry path")
    options = _worker_launch_options(
        arguments,
        hook_entrypoint=hook_entrypoint,
        config_path=registry.config_path,
    )
    if profile.provider == "claude":
        return verified_provider_argv(binary, ["--resume", session_id, *options])
    return verified_provider_argv(
        binary,
        ["resume", *codex_launch_prefix(active_root), session_id, *options],
    )
