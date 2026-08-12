#!/usr/bin/env python3
"""Bounded health census and explicit reaper for legacy process-tree anchors.

`report` is read-only and is safe for session-start diagnostics.
`reap --apply` is deliberately opt-in: it sends SIGKILL only to an exact
Firstmate legacy anchor that is parented by init, leads its own process group,
and is the sole member of that group. The census, candidate count, signal count,
and wall time are all bounded. See docs/process-tree-supervisors.md.
"""

from __future__ import annotations

import argparse
import ctypes
from dataclasses import dataclass
import errno
import os
from pathlib import Path
import signal
import stat
import sys
import time
from typing import Dict, Iterable, List, Mapping, Optional, Tuple


DEFAULT_CENSUS_SECONDS = 3.0
DEFAULT_MAX_ARGUMENT_BYTES = 16 * 1024 * 1024
DEFAULT_MAX_ITEMS = 16_384
DEFAULT_REAP_LIMIT = 16
MAX_REAP_LIMIT = 32
MAX_PROCESS_ARGUMENT_BYTES = 1024 * 1024
SUPERVISOR_MARKERS = (
    b"-MPOSIX=:sys_wait_h",
    b"-MErrno=EINTR",
    b"sub record_cleanup",
    b"bounded command process-group anchor",
)


class CensusError(RuntimeError):
    """The host process inventory could not be read within its bounds."""


@dataclass(frozen=True)
class ProcessInfo:
    process_id: int
    parent_id: int
    group_id: int
    user_id: int
    identity: Tuple[int, int]
    command: str


@dataclass(frozen=True)
class Census:
    leaked_supervisors: Tuple[ProcessInfo, ...]
    reaper_candidates: Tuple[ProcessInfo, ...]
    parentless_argument_bytes: int
    complete: bool
    gap: str = ""


class _DarwinBsdInfo(ctypes.Structure):
    _fields_ = [
        ("flags", ctypes.c_uint32),
        ("status", ctypes.c_uint32),
        ("xstatus", ctypes.c_uint32),
        ("pid", ctypes.c_uint32),
        ("ppid", ctypes.c_uint32),
        ("uid", ctypes.c_uint32),
        ("gid", ctypes.c_uint32),
        ("ruid", ctypes.c_uint32),
        ("rgid", ctypes.c_uint32),
        ("svuid", ctypes.c_uint32),
        ("svgid", ctypes.c_uint32),
        ("reserved", ctypes.c_uint32),
        ("command", ctypes.c_char * 16),
        ("name", ctypes.c_char * 32),
        ("nfiles", ctypes.c_uint32),
        ("pgid", ctypes.c_uint32),
        ("job_control", ctypes.c_uint32),
        ("terminal_device", ctypes.c_uint32),
        ("terminal_pgid", ctypes.c_uint32),
        ("nice", ctypes.c_int32),
        ("started_seconds", ctypes.c_uint64),
        ("started_microseconds", ctypes.c_uint64),
    ]


class _DarwinUniqueIdentifierInfo(ctypes.Structure):
    _fields_ = [
        ("uuid", ctypes.c_uint8 * 16),
        ("unique_id", ctypes.c_uint64),
        ("parent_unique_id", ctypes.c_uint64),
        ("id_version", ctypes.c_int32),
        ("original_parent_id_version", ctypes.c_int32),
        ("reserved2", ctypes.c_uint64),
        ("reserved3", ctypes.c_uint64),
    ]


class _DarwinAuditToken(ctypes.Structure):
    _fields_ = [("values", ctypes.c_uint32 * 8)]


def _require_time(deadline: float) -> None:
    if time.monotonic() >= deadline:
        raise CensusError("process-tree health census timed out")


def _decode_command(value: bytes) -> str:
    return value.split(b"\0", 1)[0].decode("utf-8", "replace")


def _darwin_process_table(
    deadline: float, maximum_items: int
) -> Dict[int, ProcessInfo]:
    _require_time(deadline)
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    list_all = libproc.proc_listallpids
    list_all.argtypes = [ctypes.c_void_p, ctypes.c_int]
    list_all.restype = ctypes.c_int
    pid_info = libproc.proc_pidinfo
    pid_info.argtypes = [
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_uint64,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    pid_info.restype = ctypes.c_int
    capacity = list_all(None, 0)
    _require_time(deadline)
    if capacity < 0 or capacity > maximum_items:
        raise CensusError(
            f"process-tree health inventory exceeds {maximum_items} processes"
        )
    processes = (ctypes.c_int * (capacity + 256))()
    count = list_all(processes, ctypes.sizeof(processes))
    _require_time(deadline)
    if count < 0 or count > len(processes) or count > maximum_items:
        raise CensusError("process-tree health inventory changed beyond its bound")
    table: Dict[int, ProcessInfo] = {}
    for process_id in processes[:count]:
        _require_time(deadline)
        if process_id <= 0:
            continue
        info = _DarwinBsdInfo()
        copied = pid_info(process_id, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
        if copied != ctypes.sizeof(info) or info.pid != process_id:
            continue
        table[process_id] = ProcessInfo(
            process_id=int(info.pid),
            parent_id=int(info.ppid),
            group_id=int(info.pgid),
            user_id=int(info.uid),
            identity=(int(info.started_seconds), int(info.started_microseconds)),
            command=_decode_command(bytes(info.command)),
        )
    return table


def _darwin_current_process(
    process_id: int, deadline: float
) -> Optional[ProcessInfo]:
    _require_time(deadline)
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    pid_info = libproc.proc_pidinfo
    pid_info.argtypes = [
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_uint64,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    pid_info.restype = ctypes.c_int
    info = _DarwinBsdInfo()
    copied = pid_info(process_id, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
    if copied != ctypes.sizeof(info) or info.pid != process_id:
        return None
    return ProcessInfo(
        process_id=int(info.pid),
        parent_id=int(info.ppid),
        group_id=int(info.pgid),
        user_id=int(info.uid),
        identity=(int(info.started_seconds), int(info.started_microseconds)),
        command=_decode_command(bytes(info.command)),
    )


def _darwin_process_arguments(
    process: ProcessInfo, deadline: float
) -> Optional[Tuple[bytes, int]]:
    _require_time(deadline)
    libc = ctypes.CDLL(None, use_errno=True)
    sysctl = libc.sysctl
    sysctl.argtypes = [
        ctypes.POINTER(ctypes.c_int),
        ctypes.c_uint,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_size_t),
        ctypes.c_void_p,
        ctypes.c_size_t,
    ]
    sysctl.restype = ctypes.c_int
    query = (ctypes.c_int * 3)(1, 49, process.process_id)
    size = ctypes.c_size_t()
    if sysctl(query, 3, None, ctypes.byref(size), None, 0) != 0:
        return None
    _require_time(deadline)
    if size.value <= 0 or size.value > MAX_PROCESS_ARGUMENT_BYTES:
        raise CensusError(
            f"process {process.process_id} arguments exceed "
            f"{MAX_PROCESS_ARGUMENT_BYTES} bytes"
        )
    buffer = ctypes.create_string_buffer(size.value)
    if sysctl(query, 3, buffer, ctypes.byref(size), None, 0) != 0:
        return None
    _require_time(deadline)
    return buffer.raw[: size.value], int(size.value)


def _linux_process_info(process_id: int) -> Optional[ProcessInfo]:
    try:
        raw = Path(f"/proc/{process_id}/stat").read_text(encoding="ascii")
        metadata = os.stat(f"/proc/{process_id}")
    except (OSError, UnicodeError):
        return None
    closing = raw.rfind(")")
    if closing < 0:
        return None
    fields = raw[closing + 2 :].split()
    if len(fields) < 20:
        return None
    try:
        return ProcessInfo(
            process_id=process_id,
            parent_id=int(fields[1]),
            group_id=int(fields[2]),
            user_id=int(metadata.st_uid),
            identity=(process_id, int(fields[19])),
            command=raw[raw.find("(") + 1 : closing],
        )
    except ValueError:
        return None


def _linux_process_table(
    deadline: float, maximum_items: int
) -> Dict[int, ProcessInfo]:
    table: Dict[int, ProcessInfo] = {}
    try:
        entries = os.scandir("/proc")
    except OSError as error:
        raise CensusError(f"cannot open Linux process inventory: {error}") from error
    with entries:
        for entry in entries:
            _require_time(deadline)
            if not entry.name.isdigit():
                continue
            if len(table) >= maximum_items:
                raise CensusError(
                    f"process-tree health inventory exceeds {maximum_items} processes"
                )
            process = _linux_process_info(int(entry.name))
            if process is not None:
                table[process.process_id] = process
    return table


def _linux_process_arguments(
    process: ProcessInfo, deadline: float
) -> Optional[Tuple[bytes, int]]:
    _require_time(deadline)
    try:
        descriptor = os.open(
            f"/proc/{process.process_id}/cmdline",
            os.O_RDONLY | getattr(os, "O_CLOEXEC", 0),
        )
    except OSError:
        return None
    chunks: List[bytes] = []
    total = 0
    try:
        while True:
            _require_time(deadline)
            block = os.read(descriptor, min(65_536, MAX_PROCESS_ARGUMENT_BYTES + 1 - total))
            if not block:
                break
            chunks.append(block)
            total += len(block)
            if total > MAX_PROCESS_ARGUMENT_BYTES:
                raise CensusError(
                    f"process {process.process_id} arguments exceed "
                    f"{MAX_PROCESS_ARGUMENT_BYTES} bytes"
                )
    finally:
        os.close(descriptor)
    return b"".join(chunks), total


def _process_is_current(process: ProcessInfo, deadline: float) -> bool:
    _require_time(deadline)
    if sys.platform == "darwin":
        current = _darwin_current_process(process.process_id, deadline)
    else:
        current = _linux_process_info(process.process_id)
    return current is not None and current.identity == process.identity


def _is_firstmate_supervisor(process: ProcessInfo, arguments: bytes) -> bool:
    return process.command == "perl" and all(
        marker in arguments for marker in SUPERVISOR_MARKERS
    )


def _guard_path(arguments: bytes) -> Optional[str]:
    prefix = b"FM_PROCESS_TREE_GUARD_FILE="
    for field in arguments.split(b"\0"):
        if field.startswith(prefix) and len(field) > len(prefix):
            return os.fsdecode(field[len(prefix) :])
    return None


def _guard_retains_process(arguments: bytes, process_id: int) -> bool:
    path = _guard_path(arguments)
    if path is None:
        return False
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    no_follow = getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags | no_follow)
    except FileNotFoundError:
        return False
    except OSError:
        return True
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 64:
            return True
        value = os.read(descriptor, 65)
    except OSError:
        return True
    finally:
        os.close(descriptor)
    try:
        recorded = int(value.strip())
    except ValueError:
        return True
    return recorded == process_id


def _summarize(
    table: Mapping[int, ProcessInfo],
    arguments: Mapping[int, Tuple[bytes, int]],
    complete: bool,
    gap: str = "",
) -> Census:
    group_members: Dict[int, List[int]] = {}
    for process in table.values():
        group_members.setdefault(process.group_id, []).append(process.process_id)
    leaked: List[ProcessInfo] = []
    candidates: List[ProcessInfo] = []
    argument_bytes = 0
    for process_id in sorted(arguments):
        process = table.get(process_id)
        if process is None:
            continue
        raw, size = arguments[process_id]
        argument_bytes += size
        if not _is_firstmate_supervisor(process, raw):
            continue
        leaked.append(process)
        if (
            process.group_id == process.process_id
            and group_members.get(process.group_id) == [process.process_id]
            and not _guard_retains_process(raw, process.process_id)
        ):
            candidates.append(process)
    return Census(
        leaked_supervisors=tuple(leaked),
        reaper_candidates=tuple(candidates),
        parentless_argument_bytes=argument_bytes,
        complete=complete,
        gap=gap,
    )


def collect_census(
    maximum_seconds: float = DEFAULT_CENSUS_SECONDS,
    maximum_items: int = DEFAULT_MAX_ITEMS,
    maximum_argument_bytes: int = DEFAULT_MAX_ARGUMENT_BYTES,
) -> Census:
    deadline = time.monotonic() + maximum_seconds
    if sys.platform == "darwin":
        table = _darwin_process_table(deadline, maximum_items)
        argument_reader = _darwin_process_arguments
    elif sys.platform.startswith("linux"):
        table = _linux_process_table(deadline, maximum_items)
        argument_reader = _linux_process_arguments
    else:
        raise CensusError(f"unsupported process inventory platform: {sys.platform}")
    arguments: Dict[int, Tuple[bytes, int]] = {}
    total = 0
    complete = True
    gaps: List[str] = []
    for process in sorted(table.values(), key=lambda value: value.process_id):
        _require_time(deadline)
        if process.parent_id != 1 or process.user_id != os.getuid():
            continue
        observed = argument_reader(process, deadline)
        if observed is None:
            if _process_is_current(process, deadline):
                complete = False
                gaps.append(f"process-{process.process_id}-arguments-unreadable")
            continue
        raw, size = observed
        if total + size > maximum_argument_bytes:
            complete = False
            gaps.append(f"argument-byte-limit-{maximum_argument_bytes}")
            break
        arguments[process.process_id] = (raw, size)
        total += size
    return _summarize(table, arguments, complete, ",".join(gaps))


def _darwin_process_audit_token(process_id: int) -> Optional[_DarwinAuditToken]:
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    pid_info = libproc.proc_pidinfo
    pid_info.argtypes = [
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_uint64,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    pid_info.restype = ctypes.c_int
    info = _DarwinUniqueIdentifierInfo()
    copied = pid_info(process_id, 17, 0, ctypes.byref(info), ctypes.sizeof(info))
    if copied != ctypes.sizeof(info):
        return None
    token = _DarwinAuditToken()
    token.values[5] = process_id
    token.values[7] = info.id_version
    return token


def _darwin_signal_candidate(process: ProcessInfo) -> bool:
    token = _darwin_process_audit_token(process.process_id)
    if token is None:
        return False
    current = _darwin_current_process(process.process_id, time.monotonic() + 1.0)
    if current is None or current.identity != process.identity:
        return True
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    signal_process = libproc.proc_signal_with_audittoken
    signal_process.argtypes = [ctypes.POINTER(_DarwinAuditToken), ctypes.c_int]
    signal_process.restype = ctypes.c_int
    ctypes.set_errno(0)
    result = int(signal_process(ctypes.byref(token), signal.SIGKILL))
    return result == 0 or (result == -1 and ctypes.get_errno() == errno.ESRCH)


def reap_orphans(limit: int) -> Tuple[int, int, int]:
    if sys.platform != "darwin":
        raise CensusError("identity-bound legacy orphan reaping is supported only on macOS")
    initial = collect_census()
    if not initial.complete:
        raise CensusError(
            "legacy orphan reaping requires a complete census; "
            f"capability gap: {initial.gap or 'unknown'}"
        )
    selected = tuple(
        sorted(
            initial.reaper_candidates,
            key=lambda process: (process.identity, process.process_id),
        )[:limit]
    )
    if not selected:
        return 0, 0, 0
    fresh = collect_census()
    if not fresh.complete:
        raise CensusError(
            "legacy orphan reaping requires a complete revalidation census; "
            f"capability gap: {fresh.gap or 'unknown'}"
        )
    fresh_candidates = {
        (process.process_id, process.identity): process
        for process in fresh.reaper_candidates
    }
    signaled: List[ProcessInfo] = []
    retained = 0
    for process in selected:
        current = fresh_candidates.get((process.process_id, process.identity))
        if current is None:
            continue
        if _darwin_signal_candidate(current):
            signaled.append(current)
        else:
            retained += 1
    reaped = 0
    for process in signaled:
        process_deadline = time.monotonic() + 2.0
        while time.monotonic() < process_deadline:
            current = _darwin_current_process(
                process.process_id, min(process_deadline, time.monotonic() + 0.25)
            )
            if current is None or current.identity != process.identity:
                reaped += 1
                break
            time.sleep(0.02)
        else:
            retained += 1
    return len(selected), reaped, retained


def _format_report(census: Census) -> str:
    gap = census.gap or "none"
    return (
        f"leaked_supervisors={len(census.leaked_supervisors)} "
        f"parentless_argv_bytes={census.parentless_argument_bytes} "
        f"census_complete={1 if census.complete else 0} "
        f"reaper_candidates={len(census.reaper_candidates)} gap={gap}"
    )


def _positive_limit(value: str) -> int:
    try:
        limit = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("limit must be an integer") from error
    if limit < 1 or limit > MAX_REAP_LIMIT:
        raise argparse.ArgumentTypeError(f"limit must be between 1 and {MAX_REAP_LIMIT}")
    return limit


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_subparsers(dest="action", required=True)
    action.add_parser("report", help="print the bounded read-only health census")
    reap = action.add_parser(
        "reap", help="reap a captain-authorized bounded batch of proven legacy anchors"
    )
    reap.add_argument(
        "--apply",
        action="store_true",
        help="confirm the captain-authorized destructive action",
    )
    reap.add_argument(
        "--limit", type=_positive_limit, default=DEFAULT_REAP_LIMIT, metavar="1..32"
    )
    return parser


def main(arguments: Optional[Iterable[str]] = None) -> int:
    parsed = _build_parser().parse_args(arguments)
    try:
        if parsed.action == "report":
            print(_format_report(collect_census()))
            return 0
        if not parsed.apply:
            print(
                "error: legacy orphan reaping requires explicit captain authorization "
                "and the --apply flag",
                file=sys.stderr,
            )
            return 2
        selected, reaped, retained = reap_orphans(parsed.limit)
        print(f"selected={selected} reaped={reaped} retained={retained}")
        return 0 if retained == 0 else 1
    except (CensusError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
