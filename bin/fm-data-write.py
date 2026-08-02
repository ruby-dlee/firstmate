#!/usr/bin/env python3
"""Run a command while holding Firstmate data-writer locks."""

from __future__ import annotations

import argparse
import fcntl
import os
import stat
import subprocess
import sys
from pathlib import Path


def parse_args() -> tuple[list[Path], list[str]]:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", action="append", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        parser.error("a command is required after --")
    return [Path(value) for value in args.data], command


def safe_data_directory(path: Path) -> Path:
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise ValueError(f"unsafe data directory: {path}")
    return path.resolve()


def main() -> int:
    data_paths, command = parse_args()
    try:
        directories = sorted({safe_data_directory(path) for path in data_paths})
    except (OSError, ValueError) as exc:
        print(f"error: cannot establish data-writer lock: {exc}", file=sys.stderr)
        return 75

    descriptors: list[int] = []
    try:
        for directory in directories:
            flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_CLOEXEC", 0)
            flags |= getattr(os, "O_NOFOLLOW", 0)
            descriptor = os.open(directory / ".firstmate-data-write.lock", flags, 0o600)
            if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                raise OSError(f"unsafe data-writer lock in {directory}")
            descriptors.append(descriptor)
            fcntl.flock(descriptor, fcntl.LOCK_EX)
        return subprocess.run(command, check=False).returncode
    except OSError as exc:
        print(f"error: data-writer lock or command failed: {exc}", file=sys.stderr)
        return 75
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


if __name__ == "__main__":
    raise SystemExit(main())
