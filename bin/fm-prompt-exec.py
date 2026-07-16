#!/usr/bin/env python3
import os
import stat
import sys


def fail(message):
    print(f"error: continuation prompt launch failed: {message}", file=sys.stderr)
    raise SystemExit(1)


cleanup_only = len(sys.argv) == 5 and sys.argv[1] == "--cleanup"
if len(sys.argv) != 5:
    fail("expected a prompt file, parent identity, file identity, and launch command")

prompt_path = os.path.abspath(sys.argv[2] if cleanup_only else sys.argv[1])
parent_path, name = os.path.split(prompt_path)
if not name or name in (".", ".."):
    fail("invalid prompt path")

expected_parent = sys.argv[3] if cleanup_only else sys.argv[2]
expected_file = sys.argv[4] if cleanup_only else sys.argv[3]
parent = os.open(parent_path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
descriptor = None
try:
    parent_stat = os.fstat(parent)
    if f"{parent_stat.st_dev}:{parent_stat.st_ino}" != expected_parent:
        fail("prompt parent generation changed")
    before = os.stat(name, dir_fd=parent, follow_symlinks=False)
    if not stat.S_ISREG(before.st_mode) or f"{before.st_dev}:{before.st_ino}" != expected_file:
        fail("prompt source generation changed")
    descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    opened = os.fstat(descriptor)
    if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
        fail("prompt source changed while opening")
    os.unlink(name, dir_fd=parent)
    chunks = []
    offset = 0
    while offset < opened.st_size:
        chunk = os.pread(descriptor, min(1024 * 1024, opened.st_size - offset), offset)
        if not chunk:
            fail("prompt source ended before its recorded size")
        chunks.append(chunk)
        offset += len(chunk)
    finished = os.fstat(descriptor)
    if (finished.st_dev, finished.st_ino, finished.st_size, finished.st_mtime_ns) != (
        opened.st_dev,
        opened.st_ino,
        opened.st_size,
        opened.st_mtime_ns,
    ):
        fail("prompt source changed while reading")
finally:
    if descriptor is not None:
        os.close(descriptor)
    os.close(parent)

grandparent_path, parent_name = os.path.split(parent_path)
grandparent = os.open(grandparent_path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
try:
    current_parent = os.stat(parent_name, dir_fd=grandparent, follow_symlinks=False)
    if f"{current_parent.st_dev}:{current_parent.st_ino}" == expected_parent:
        try:
            os.rmdir(parent_name, dir_fd=grandparent)
        except OSError:
            pass
finally:
    os.close(grandparent)

if cleanup_only:
    raise SystemExit(0)

prompt = b"".join(chunks)
if b"\0" in prompt:
    fail("prompt contains a NUL byte that cannot be represented in an argument")

command = os.fsencode(sys.argv[4])
os.execve(b"/bin/bash", [b"bash", b"-c", command, b"fm-continuation", prompt], os.environb.copy())
