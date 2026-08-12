#!/usr/bin/env python3
"""Replay bounded Crosscheck evidence in one fresh networkless Azure runner."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time


MAX_COMMANDS = 32
MAX_CAPTURE = 200_000
MAX_SECONDS = 900


def split_commands(values: list[str]) -> list[list[str]]:
    commands: list[list[str]] = []
    current: list[str] = []
    for value in values:
        if value == "--next-command":
            if current:
                commands.append(current)
                current = []
            continue
        current.append(value)
    if current:
        commands.append(current)
    if not commands or len(commands) > MAX_COMMANDS:
        raise ValueError("replay command count is invalid")
    for command in commands:
        if not command or command[0] != "bash" or command[1:3] != ["--noprofile", "--norc"]:
            raise ValueError("replay admits only non-profile Bash evidence helpers")
        if len(command) != 4 or not command[3].startswith(".crosscheck/reproductions/"):
            raise ValueError("replay helper path is invalid")
    return commands


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", required=True, choices=("capture", "verify"))
    parser.add_argument("--evidence-json", required=True)
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    values = args.arguments[1:] if args.arguments[:1] == ["--"] else args.arguments
    commands = split_commands(values)
    try:
        artifacts = json.loads(base64.b64decode(args.evidence_json, validate=True))
    except (ValueError, json.JSONDecodeError) as exc:
        raise SystemExit("replay: evidence manifest is malformed") from exc
    if not isinstance(artifacts, dict) or len(artifacts) > MAX_COMMANDS:
        raise SystemExit("replay: evidence manifest item count is invalid")
    for relative, encoded in artifacts.items():
        if (
            not isinstance(relative, str)
            or not relative.startswith((".crosscheck/reproductions/", ".crosscheck/mutations/"))
            or ".." in Path(relative).parts
            or not isinstance(encoded, str)
        ):
            raise SystemExit("replay: evidence manifest path is invalid")
        try:
            content = base64.b64decode(encoded, validate=True)
        except ValueError as exc:
            raise SystemExit("replay: evidence body is malformed") from exc
        if not 1 <= len(content) <= MAX_CAPTURE or b"\x00" in content:
            raise SystemExit("replay: evidence body violates byte contract")
        destination = Path(relative)
        destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o700 if relative.startswith(".crosscheck/reproductions/") else 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(content)
    deadline = time.monotonic() + MAX_SECONDS
    results = []
    environment = {
        "HOME": str(Path.cwd() / ".crosscheck-home"),
        "PATH": "/usr/local/bin:/usr/bin:/bin",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
    }
    Path(environment["HOME"]).mkdir(mode=0o700, exist_ok=True)
    for command in commands:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise SystemExit("replay: aggregate deadline expired")
        completed = subprocess.run(
            command,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=remaining,
        )
        if len(completed.stdout) + len(completed.stderr) > MAX_CAPTURE:
            raise SystemExit("replay: output exceeded byte bound")
        record = {
            "argv": command,
            "exit": completed.returncode,
            "stdout_sha256": "sha256:" + hashlib.sha256(completed.stdout).hexdigest(),
            "stderr_sha256": "sha256:" + hashlib.sha256(completed.stderr).hexdigest(),
            "stdout": completed.stdout.decode("utf-8", errors="replace"),
            "stderr": completed.stderr.decode("utf-8", errors="replace"),
        }
        results.append(record)
        if completed.returncode != 0:
            print(json.dumps({"schema": "fm.azure-crosscheck-replay/v1", "mode": args.mode, "results": results}, sort_keys=True))
            return completed.returncode
    print(json.dumps({"schema": "fm.azure-crosscheck-replay/v1", "mode": args.mode, "results": results}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
