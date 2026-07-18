from __future__ import annotations

import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .executables import CONTROL_PATH, validated_safe_directory, validated_safe_executable
from .paths import current_user_home


@dataclass(frozen=True)
class _ExecutablePin:
    path: Path
    device: int
    inode: int
    size: int
    mtime_ns: int
    ctime_ns: int


_PINNED_TOON_COMMAND: tuple[_ExecutablePin, ...] | None = None


def _pin_executable(path: Path) -> _ExecutablePin:
    metadata = path.stat()
    return _ExecutablePin(
        path=path,
        device=metadata.st_dev,
        inode=metadata.st_ino,
        size=metadata.st_size,
        mtime_ns=metadata.st_mtime_ns,
        ctime_ns=metadata.st_ctime_ns,
    )


def _toon_candidates() -> tuple[Path, ...]:
    override = os.environ.get("AGENT_FLEET_TOON_BIN")
    if override:
        candidate = Path(override)
        if not candidate.is_absolute():
            raise ValueError("AGENT_FLEET_TOON_BIN must be an absolute path")
        return (candidate,)
    home = current_user_home()
    candidates = [
        home / ".local" / "bin" / "toon",
        *sorted(
            (home / ".nvm" / "versions" / "node").glob("*/bin/toon"),
            reverse=True,
        ),
        Path("/usr/local/bin/toon"),
        Path("/opt/homebrew/bin/toon"),
        Path("/usr/bin/toon"),
    ]
    return tuple(dict.fromkeys(candidates))


def _toon_node_candidates(alias: Path) -> tuple[Path, ...]:
    home = current_user_home()
    candidates = [
        alias.parent / "node",
        home / ".local" / "bin" / "node",
        Path("/usr/local/bin/node"),
        Path("/opt/homebrew/bin/node"),
        Path("/usr/bin/node"),
    ]
    return tuple(dict.fromkeys(candidates))


def _resolve_toon_command() -> tuple[Path, ...]:
    errors: list[str] = []
    for alias in _toon_candidates():
        try:
            validated_safe_directory(alias.parent, label="TOON launcher directory")
            target = validated_safe_executable(alias, label="TOON encoder")
        except ValueError as exc:
            errors.append(str(exc))
            continue
        try:
            with target.open("rb") as handle:
                first_line = handle.readline(256).decode("utf-8", errors="ignore")
        except OSError as exc:
            errors.append(f"TOON encoder is unreadable: {target}: {exc}")
            continue
        if target.suffix in {".js", ".mjs", ".cjs"} or (
            first_line.startswith("#!") and "node" in first_line
        ):
            for node_alias in _toon_node_candidates(alias):
                try:
                    node = validated_safe_executable(node_alias, label="TOON Node runtime")
                except ValueError:
                    continue
                return (node, target)
            errors.append(f"TOON encoder has no safely pinned Node runtime: {alias}")
            continue
        return (target,)
    detail = f" ({errors[0]})" if errors else ""
    raise ValueError(
        "TOON output requested but no safely pinned encoder is installed; "
        f"use --format json{detail}"
    )


def _toon_command() -> tuple[Path, ...]:
    global _PINNED_TOON_COMMAND
    if _PINNED_TOON_COMMAND is None:
        _PINNED_TOON_COMMAND = tuple(_pin_executable(path) for path in _resolve_toon_command())
    verified: list[Path] = []
    for pin in _PINNED_TOON_COMMAND:
        path = validated_safe_executable(pin.path, label="pinned TOON command")
        if _pin_executable(path) != pin:
            raise ValueError("pinned TOON command changed after preflight")
        verified.append(path)
    return tuple(verified)


def _run_toon(payload: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(path) for path in _toon_command()],
        input=payload,
        text=True,
        capture_output=True,
        check=False,
        env={"HOME": str(current_user_home()), "PATH": CONTROL_PATH},
    )


def preflight(output_format: str) -> None:
    if output_format != "toon":
        return
    result = _run_toon("{}")
    if result.returncode != 0:
        raise ValueError(f"TOON encoder preflight failed: {result.stderr.strip()}")


def emit(payload: Any, output_format: str) -> None:
    if output_format == "json":
        json.dump(payload, sys.stdout, sort_keys=True, separators=(",", ":"))
        sys.stdout.write("\n")
        return
    if output_format == "toon":
        encoded = json.dumps(payload, separators=(",", ":"))
        result = _run_toon(encoded)
        if result.returncode != 0:
            raise ValueError(f"TOON encoder failed: {result.stderr.strip()}")
        sys.stdout.write(result.stdout)
        return
    _emit_human(payload)


def _emit_human(payload: Any, prefix: str = "") -> None:
    if isinstance(payload, dict):
        for key, value in payload.items():
            if isinstance(value, (dict, list)):
                print(f"{prefix}{key}:")
                _emit_human(value, prefix + "  ")
            else:
                print(f"{prefix}{key}: {value}")
    elif isinstance(payload, list):
        for item in payload:
            if isinstance(item, (dict, list)):
                print(f"{prefix}-")
                _emit_human(item, prefix + "  ")
            else:
                print(f"{prefix}- {item}")
    else:
        print(f"{prefix}{payload}")
