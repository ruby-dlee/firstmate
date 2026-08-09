#!/usr/bin/env python3

import ctypes
import os
import platform
import sys


def linux_identity(pid):
    with open("/proc/sys/kernel/random/boot_id", encoding="ascii") as boot_file:
        boot_id = boot_file.read().strip()
    with open("/proc/{}/stat".format(pid), encoding="ascii") as stat_file:
        stat = stat_file.read()
    close = stat.rfind(")")
    fields = stat[close + 2 :].split()
    if close < 0 or len(fields) < 20:
        raise RuntimeError("invalid proc stat")
    return "linux:{}:{}".format(boot_id, fields[19])


class ProcBsdInfo(ctypes.Structure):
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("pbi_rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16),
        ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]


def darwin_identity(pid):
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    libproc.proc_pidinfo.argtypes = [
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_uint64,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    libproc.proc_pidinfo.restype = ctypes.c_int
    info = ProcBsdInfo()
    size = libproc.proc_pidinfo(
        pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)
    )
    if size != ctypes.sizeof(info) or info.pbi_pid != pid:
        raise RuntimeError("proc_pidinfo failed")
    return "darwin:{}:{}".format(info.pbi_start_tvsec, info.pbi_start_tvusec)


def main():
    if len(sys.argv) != 2 or not sys.argv[1].isdigit():
        return 2
    pid = int(sys.argv[1])
    if pid <= 0:
        return 2
    system = platform.system()
    try:
        if system == "Linux":
            identity = linux_identity(pid)
        elif system == "Darwin":
            identity = darwin_identity(pid)
        else:
            return 1
    except (OSError, RuntimeError, ValueError):
        return 1
    if not identity or os.getpid() <= 0:
        return 1
    print(identity)
    return 0


if __name__ == "__main__":
    sys.exit(main())
