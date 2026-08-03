#!/usr/bin/env python3
"""Shared fail-closed bounds for subprocesses and structured artifacts.

The module is importable by Python helpers and also exposes a small CLI for
empirical checks. One absolute deadline covers process execution, output
draining, final wait, and process-group cleanup.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import math
import os
from pathlib import Path
import selectors
import signal
import stat
import subprocess
import sys
import time
from typing import Any, NoReturn, Sequence


DEFAULT_CLEANUP_GRACE_SECONDS = 0.25
DEFAULT_JSON_MAX_DEPTH = 64
DEFAULT_JSON_MAX_ITEMS = 4096


class BoundedIOError(RuntimeError):
    """An operation exceeded or could not prove its declared bounds."""


class BoundedTimeout(BoundedIOError):
    """A subprocess exhausted its one absolute deadline."""


class BoundedOutputExceeded(BoundedIOError):
    """A subprocess exceeded its aggregate stdout and stderr byte ceiling."""


def fail(message: str) -> NoReturn:
    raise BoundedIOError(message)


def positive_number(value: float | int, label: str) -> float:
    numeric = float(value)
    if not math.isfinite(numeric) or numeric <= 0:
        fail(f"{label} must be a positive finite number")
    return numeric


def positive_integer(value: int, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        fail(f"{label} must be a positive integer")
    return value


@dataclass(frozen=True)
class CommandResult:
    arguments: tuple[str, ...]
    returncode: int
    stdout: bytes
    stderr: bytes


class DeadlineBudget:
    """One wall-clock budget shared by a bounded batch and its commands."""

    def __init__(self, maximum_seconds: float, maximum_items: int) -> None:
        self.maximum_seconds = positive_number(maximum_seconds, "maximum seconds")
        self.maximum_items = positive_integer(maximum_items, "maximum items")
        self.deadline = time.monotonic() + self.maximum_seconds
        self.items = 0

    def consume_item(self, label: str) -> None:
        self.items += 1
        if self.items > self.maximum_items:
            fail(f"{label} exceeds the {self.maximum_items}-item limit")
        self.require_time(label)

    def consume_items(self, values: Sequence[Any], label: str) -> None:
        if len(values) > self.maximum_items - self.items:
            fail(f"{label} exceeds the {self.maximum_items}-item limit")
        self.items += len(values)
        self.require_time(label)

    def require_time(self, label: str) -> None:
        if time.monotonic() >= self.deadline:
            fail(f"{label} exceeded the {self.maximum_seconds:g}-second deadline")

    def timeout(self, requested_seconds: float, label: str) -> float:
        requested = positive_number(requested_seconds, f"{label} timeout")
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            fail(f"{label} exceeded the {self.maximum_seconds:g}-second deadline")
        return min(requested, remaining)


def _process_group_exists(process_group: int) -> bool:
    try:
        os.killpg(process_group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _wait_for_group_exit(process_group: int, deadline: float) -> bool:
    while time.monotonic() < deadline:
        if not _process_group_exists(process_group):
            return True
        time.sleep(min(0.01, max(0, deadline - time.monotonic())))
    return not _process_group_exists(process_group)


def _wait_for_process(process: subprocess.Popen[bytes], deadline: float) -> bool:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        return process.poll() is not None
    try:
        process.wait(timeout=remaining)
        return True
    except subprocess.TimeoutExpired:
        return False


def _terminate_group(
    process: subprocess.Popen[bytes],
    deadline: float,
    cleanup_grace_seconds: float,
) -> None:
    process_group = process.pid
    grace = positive_number(cleanup_grace_seconds, "cleanup grace seconds")
    if _process_group_exists(process_group):
        try:
            os.killpg(process_group, signal.SIGTERM)
        except ProcessLookupError:
            pass
        term_deadline = min(deadline, time.monotonic() + grace)
        _wait_for_group_exit(process_group, term_deadline)
    if _process_group_exists(process_group):
        try:
            os.killpg(process_group, signal.SIGKILL)
        except ProcessLookupError:
            pass
    _wait_for_process(process, deadline)
    if _process_group_exists(process_group):
        _wait_for_group_exit(process_group, deadline)
    if process.poll() is None or _process_group_exists(process_group):
        fail(f"process-group cleanup could not be verified for group {process_group}")


def run_bounded(
    arguments: Sequence[str],
    *,
    timeout_seconds: float,
    maximum_output_bytes: int,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    input_bytes: bytes | None = None,
    cleanup_grace_seconds: float = DEFAULT_CLEANUP_GRACE_SECONDS,
) -> CommandResult:
    """Run one command with aggregate output, time, and process-tree bounds."""

    if not arguments or any(not isinstance(item, str) or not item for item in arguments):
        fail("bounded command arguments must be nonempty strings")
    timeout = positive_number(timeout_seconds, "timeout seconds")
    output_limit = positive_integer(maximum_output_bytes, "maximum output bytes")
    cleanup_grace = min(
        positive_number(cleanup_grace_seconds, "cleanup grace seconds"),
        timeout / 10,
    )
    deadline = time.monotonic() + timeout
    command_deadline = deadline - cleanup_grace
    try:
        process = subprocess.Popen(
            list(arguments),
            cwd=cwd,
            env=env,
            stdin=subprocess.PIPE if input_bytes is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
    except FileNotFoundError as exc:
        fail(f"bounded command is unavailable: {arguments[0]}")
    except OSError as exc:
        fail(f"bounded command could not start: {exc}")

    selector = selectors.DefaultSelector()
    streams = {"stdout": process.stdout, "stderr": process.stderr}
    output = {"stdout": bytearray(), "stderr": bytearray()}
    captured = 0
    input_offset = 0
    try:
        for label, stream in streams.items():
            if stream is None:
                fail(f"bounded command {label} pipe is unavailable")
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, label)
        if process.stdin is not None:
            if input_bytes:
                os.set_blocking(process.stdin.fileno(), False)
                selector.register(process.stdin, selectors.EVENT_WRITE, "stdin")
            else:
                process.stdin.close()

        while selector.get_map() or process.poll() is None:
            remaining = command_deadline - time.monotonic()
            if remaining <= 0:
                raise BoundedTimeout(
                    f"bounded command timed out after {timeout:g} seconds"
                )
            if not selector.get_map():
                time.sleep(min(0.01, remaining))
                continue
            for key, _ in selector.select(timeout=min(0.1, remaining)):
                stream = key.fileobj
                if key.data == "stdin":
                    try:
                        written = os.write(stream.fileno(), input_bytes[input_offset:])
                    except BlockingIOError:
                        continue
                    except BrokenPipeError:
                        written = 0
                    input_offset += written
                    if written == 0 or input_offset == len(input_bytes):
                        selector.unregister(stream)
                        stream.close()
                    continue
                try:
                    chunk = os.read(stream.fileno(), min(65_536, output_limit + 1))
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(stream)
                    stream.close()
                    continue
                captured += len(chunk)
                if captured > output_limit:
                    raise BoundedOutputExceeded(
                        "bounded command exceeded the "
                        f"{output_limit}-byte aggregate output limit"
                    )
                output[key.data].extend(chunk)

        if not _wait_for_process(process, command_deadline):
            raise BoundedTimeout(
                f"bounded command timed out after {timeout:g} seconds"
            )
        _terminate_group(process, deadline, cleanup_grace)
        return CommandResult(
            tuple(arguments),
            int(process.returncode),
            bytes(output["stdout"]),
            bytes(output["stderr"]),
        )
    except BaseException:
        _terminate_group(process, deadline, cleanup_grace)
        raise
    finally:
        selector.close()
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream is not None and not stream.closed:
                stream.close()


def _json_budget(
    value: Any,
    *,
    maximum_depth: int,
    maximum_items: int,
    maximum_string_bytes: int,
) -> None:
    maximum_depth = positive_integer(maximum_depth, "maximum JSON depth")
    maximum_items = positive_integer(maximum_items, "maximum JSON items")
    maximum_string_bytes = positive_integer(
        maximum_string_bytes, "maximum JSON string bytes"
    )
    stack: list[tuple[Any, int]] = [(value, 1)]
    items = 0
    string_bytes = 0
    while stack:
        current, depth = stack.pop()
        if depth > maximum_depth:
            fail(f"JSON exceeds the {maximum_depth}-level depth limit")
        items += 1
        if items > maximum_items:
            fail(f"JSON exceeds the {maximum_items}-item limit")
        if isinstance(current, str):
            string_bytes += len(current.encode("utf-8"))
            if string_bytes > maximum_string_bytes:
                fail(
                    "JSON exceeds the "
                    f"{maximum_string_bytes}-byte decoded string limit"
                )
        elif isinstance(current, dict):
            for key, child in current.items():
                if not isinstance(key, str):
                    fail("JSON object contains a non-string key")
                string_bytes += len(key.encode("utf-8"))
                if string_bytes > maximum_string_bytes:
                    fail(
                        "JSON exceeds the "
                        f"{maximum_string_bytes}-byte decoded string limit"
                    )
                stack.append((child, depth + 1))
        elif isinstance(current, list):
            stack.extend((child, depth + 1) for child in current)


def read_bounded_json(
    path: Path,
    *,
    maximum_bytes: int,
    maximum_depth: int = DEFAULT_JSON_MAX_DEPTH,
    maximum_items: int = DEFAULT_JSON_MAX_ITEMS,
    maximum_string_bytes: int | None = None,
) -> Any:
    """Read one stable regular JSON file without following a symlink."""

    byte_limit = positive_integer(maximum_bytes, "maximum artifact bytes")
    string_limit = byte_limit if maximum_string_bytes is None else maximum_string_bytes
    try:
        before = path.stat(follow_symlinks=False)
    except OSError as exc:
        fail(f"bounded JSON artifact is unavailable at {path}: {exc}")
    if not stat.S_ISREG(before.st_mode):
        fail(f"bounded JSON artifact is not a regular file: {path}")
    if before.st_size <= 0:
        fail(f"bounded JSON artifact is empty: {path}")
    if before.st_size > byte_limit:
        fail(f"bounded JSON artifact exceeds {byte_limit} bytes: {path}")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            fail(f"bounded JSON artifact identity changed while opening: {path}")
        chunks: list[bytes] = []
        remaining = byte_limit + 1
        while remaining > 0:
            chunk = os.read(descriptor, min(65_536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    raw = b"".join(chunks)
    if len(raw) > byte_limit:
        fail(f"bounded JSON artifact exceeds {byte_limit} bytes: {path}")
    if (
        opened.st_size != after.st_size
        or opened.st_mtime_ns != after.st_mtime_ns
        or opened.st_ctime_ns != after.st_ctime_ns
    ):
        fail(f"bounded JSON artifact changed while reading: {path}")
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"bounded JSON artifact is malformed at {path}: {exc}")
    _json_budget(
        value,
        maximum_depth=maximum_depth,
        maximum_items=maximum_items,
        maximum_string_bytes=string_limit,
    )
    return value


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    run = subparsers.add_parser("run")
    run.add_argument("--timeout", type=float, required=True)
    run.add_argument("--max-output-bytes", type=int, required=True)
    run.add_argument("arguments", nargs=argparse.REMAINDER)
    artifact = subparsers.add_parser("json")
    artifact.add_argument("--max-bytes", type=int, required=True)
    artifact.add_argument("--max-depth", type=int, default=DEFAULT_JSON_MAX_DEPTH)
    artifact.add_argument("--max-items", type=int, default=DEFAULT_JSON_MAX_ITEMS)
    artifact.add_argument("--max-string-bytes", type=int)
    artifact.add_argument("path", type=Path)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.command == "run":
            arguments = args.arguments
            if arguments and arguments[0] == "--":
                arguments = arguments[1:]
            result = run_bounded(
                arguments,
                timeout_seconds=args.timeout,
                maximum_output_bytes=args.max_output_bytes,
            )
            sys.stdout.buffer.write(result.stdout)
            sys.stderr.buffer.write(result.stderr)
            return result.returncode
        value = read_bounded_json(
            args.path,
            maximum_bytes=args.max_bytes,
            maximum_depth=args.max_depth,
            maximum_items=args.max_items,
            maximum_string_bytes=args.max_string_bytes,
        )
        print(json.dumps(value, sort_keys=True, separators=(",", ":")))
        return 0
    except BoundedTimeout as exc:
        print(f"UNREVIEWED: {exc}", file=sys.stderr)
        return 124
    except BoundedIOError as exc:
        print(f"UNREVIEWED: {exc}", file=sys.stderr)
        return 125


if __name__ == "__main__":
    raise SystemExit(main())
