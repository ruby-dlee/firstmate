#!/usr/bin/env python3
"""Run one test behind a reparented worker and preserve combined output."""

from __future__ import annotations

import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def usage() -> int:
    print("usage: tests/run-detached.py <artifact> -- <command> [args...]", file=sys.stderr)
    return 64


def process_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def group_live_members(process_group: int) -> list[str]:
    try:
        output = subprocess.check_output(
            ["/bin/ps", "-axo", "pid=,ppid=,pgid=,state=,command="],
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except (OSError, subprocess.SubprocessError):
        # A failed ownership inspection must not be mistaken for clean exit.
        return ["<process-group inspection failed>"]
    members: list[str] = []
    for line in output.splitlines():
        fields = line.strip().split(None, 4)
        if len(fields) < 4 or not fields[2].isdigit():
            continue
        if int(fields[2]) == process_group and not fields[3].startswith("Z"):
            members.append(line.strip())
    return members


def group_alive(process_group: int) -> bool:
    return bool(group_live_members(process_group))


def stop_group(process_group: int) -> None:
    if not group_alive(process_group):
        return
    os.killpg(process_group, signal.SIGTERM)
    for _ in range(20):
        if not group_alive(process_group):
            return
        time.sleep(0.05)
    if group_alive(process_group):
        os.killpg(process_group, signal.SIGKILL)


def write_atomic(path: Path, value: str) -> None:
    candidate = path.with_name(f"{path.name}.tmp-{os.getpid()}")
    candidate.write_text(value, encoding="utf-8")
    candidate.replace(path)


def worker(artifact: Path, status_path: Path, command_pid_path: Path, command: list[str]) -> None:
    with artifact.open("wb") as output:
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=output,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        write_atomic(command_pid_path, f"{process.pid}\n")
        return_code = process.wait()
        remaining_members = group_live_members(process.pid)
        descendants_remained = bool(remaining_members)
        if descendants_remained:
            stop_group(process.pid)
            output.write(
                b"test isolation violation: detached test left processes in its owned process group\n"
            )
            for member in remaining_members:
                output.write(f"offending process: {member}\n".encode())
        if return_code < 0:
            output.write(
                f"test isolation violation: detached test runner terminated by signal {-return_code}\n".encode()
            )
        output.flush()

    if return_code < 0:
        status = min(128 + (-return_code), 255)
    elif descendants_remained and return_code == 0:
        status = 97
    else:
        status = return_code
    write_atomic(status_path, f"{status}\n")


def spawn_reparented_worker(
    artifact: Path, status_path: Path, command_pid_path: Path, command: list[str]
) -> int:
    read_fd, write_fd = os.pipe()
    broker_pid = os.fork()
    if broker_pid == 0:
        os.close(read_fd)
        worker_pid = os.fork()
        if worker_pid == 0:
            os.close(write_fd)
            try:
                worker(artifact, status_path, command_pid_path, command)
            finally:
                os._exit(0)
        os.write(write_fd, f"{worker_pid}\n".encode())
        os.close(write_fd)
        os._exit(0)

    os.close(write_fd)
    worker_text = b""
    while not worker_text.endswith(b"\n"):
        chunk = os.read(read_fd, 64)
        if not chunk:
            break
        worker_text += chunk
    os.close(read_fd)
    os.waitpid(broker_pid, 0)
    if not worker_text.strip().isdigit():
        raise RuntimeError("detached worker did not report its PID")
    return int(worker_text.strip())


def main() -> int:
    if len(sys.argv) < 4 or sys.argv[2] != "--":
        return usage()
    artifact = Path(sys.argv[1])
    command = sys.argv[3:]
    artifact.parent.mkdir(parents=True, exist_ok=True)
    status_path = artifact.with_name(f".{artifact.name}.status")
    command_pid_path = artifact.with_name(f".{artifact.name}.pid")
    status_path.unlink(missing_ok=True)
    command_pid_path.unlink(missing_ok=True)

    worker_pid = spawn_reparented_worker(artifact, status_path, command_pid_path, command)
    caller_fatal = False
    while not status_path.exists():
        if not process_alive(worker_pid):
            time.sleep(0.1)
            if status_path.exists():
                break
            caller_fatal = True
            break
        time.sleep(0.05)

    if caller_fatal:
        if command_pid_path.exists():
            command_pid = int(command_pid_path.read_text(encoding="utf-8").strip())
            stop_group(command_pid)
        with artifact.open("ab") as output:
            output.write(
                b"test isolation violation: detached test caller terminated before reporting status\n"
            )
        status = 97
    else:
        status = int(status_path.read_text(encoding="utf-8").strip())

    with artifact.open("rb") as output:
        sys.stdout.buffer.write(output.read())
        sys.stdout.buffer.flush()
    status_path.unlink(missing_ok=True)
    command_pid_path.unlink(missing_ok=True)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
