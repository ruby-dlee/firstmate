#!/usr/bin/env python3

import errno
import json
import os
import stat
import sys


def fail(message):
    raise RuntimeError(message)


def checked_root(descriptor):
    opened = os.fstat(descriptor)
    if not stat.S_ISDIR(opened.st_mode):
        fail("root descriptor is not a directory")
    return descriptor


def components(relative):
    if not relative or os.path.isabs(relative):
        fail("source is not a relative descendant")
    parts = relative.split(os.sep)
    if any(part in ("", ".", "..") for part in parts):
        fail("source has an unsafe relative path")
    return parts


def open_relative(root_descriptor, relative, flags):
    parts = components(relative)
    parent = os.dup(root_descriptor)
    try:
        for part in parts[:-1]:
            child = os.open(
                part,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=parent,
            )
            os.close(parent)
            parent = child
        before = os.stat(parts[-1], dir_fd=parent, follow_symlinks=False)
        if stat.S_ISLNK(before.st_mode):
            fail(f"source is a symlink: {relative}")
        descriptor = os.open(parts[-1], flags | os.O_NOFOLLOW, dir_fd=parent)
        opened = os.fstat(descriptor)
        if opened.st_dev != before.st_dev or opened.st_ino != before.st_ino:
            os.close(descriptor)
            fail("source identity changed while opening")
        return descriptor
    finally:
        os.close(parent)


def same_file(first, second):
    return (
        first.st_dev == second.st_dev
        and first.st_ino == second.st_ino
        and first.st_size == second.st_size
        and first.st_mtime_ns == second.st_mtime_ns
        and first.st_ctime_ns == second.st_ctime_ns
    )


def read_descriptor(descriptor, maximum, mode):
    opened = os.fstat(descriptor)
    if not stat.S_ISREG(opened.st_mode):
        fail("source is not a real regular file")
    if mode == "strict" and opened.st_size > maximum:
        return {"oversized": True, "size": opened.st_size, "content": b""}
    length = min(opened.st_size, maximum)
    offset = opened.st_size - length if mode == "tail" else 0
    chunks = []
    remaining = length
    while remaining:
        chunk = os.pread(descriptor, remaining, offset)
        if not chunk:
            fail("source ended before its recorded size")
        chunks.append(chunk)
        offset += len(chunk)
        remaining -= len(chunk)
    finished = os.fstat(descriptor)
    if not same_file(opened, finished):
        fail("source changed while reading")
    return {
        "oversized": opened.st_size > maximum,
        "size": opened.st_size,
        "content": b"".join(chunks),
    }


def read_relative(root_descriptor, relative, maximum, mode, optional=False):
    try:
        descriptor = open_relative(root_descriptor, relative, os.O_RDONLY)
    except FileNotFoundError:
        if optional:
            return None
        raise
    try:
        return read_descriptor(descriptor, maximum, mode)
    finally:
        os.close(descriptor)


def write_framed(items):
    header = []
    for name, item in items:
        if item is None:
            header.append({"name": name, "missing": True})
        else:
            header.append(
                {
                    "name": name,
                    "missing": False,
                    "oversized": item["oversized"],
                    "size": item["size"],
                    "bytes": len(item["content"]),
                }
            )
    output = sys.stdout.buffer
    output.write(json.dumps({"items": header}, separators=(",", ":")).encode("utf-8"))
    output.write(b"\n")
    for _, item in items:
        if item is not None:
            output.write(item["content"])


def open_verified_directory(parent_descriptor, name):
    before = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    if stat.S_ISLNK(before.st_mode) and name == "visuals":
        fail("visual evidence root must be a real directory")
    if not stat.S_ISDIR(before.st_mode):
        fail(f"visual evidence must contain only real directories at {name}")
    descriptor = os.open(
        name,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
        dir_fd=parent_descriptor,
    )
    opened = os.fstat(descriptor)
    if opened.st_dev != before.st_dev or opened.st_ino != before.st_ino:
        os.close(descriptor)
        fail(f"visual evidence changed while opening {name}")
    return descriptor


def ensure_destination_directory(parent_descriptor, name):
    try:
        os.mkdir(name, mode=0o700, dir_fd=parent_descriptor)
    except FileExistsError:
        pass
    return os.open(
        name,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
        dir_fd=parent_descriptor,
    )


def copy_regular(source_parent, destination_parent, name, remaining):
    before = os.stat(name, dir_fd=source_parent, follow_symlinks=False)
    if not stat.S_ISREG(before.st_mode):
        return 0
    source = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=source_parent)
    destination = None
    try:
        opened = os.fstat(source)
        if not stat.S_ISREG(opened.st_mode) or opened.st_dev != before.st_dev or opened.st_ino != before.st_ino:
            fail(f"visual evidence changed while opening {name}")
        if opened.st_size > remaining:
            fail("visual evidence exceeds the 20 MiB report limit")
        destination = os.open(
            name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=destination_parent,
        )
        copied = 0
        while copied < opened.st_size:
            chunk = os.read(source, min(64 * 1024, opened.st_size - copied))
            if not chunk:
                fail(f"visual evidence changed size while copying {name}")
            view = memoryview(chunk)
            while view:
                written = os.write(destination, view)
                view = view[written:]
            copied += len(chunk)
        if os.read(source, 1):
            fail(f"visual evidence changed size while copying {name}")
        if not same_file(opened, os.fstat(source)):
            fail(f"visual evidence changed while copying {name}")
        return copied
    finally:
        if destination is not None:
            os.close(destination)
        os.close(source)


def copy_visuals(task_descriptor, destination_descriptor, maximum, entry_limit, depth_limit):
    try:
        source = open_verified_directory(task_descriptor, "visuals")
    except FileNotFoundError:
        return []
    destination = ensure_destination_directory(destination_descriptor, "visuals")
    copied_paths = []
    total = 0
    entries = 1

    def visit(source_directory, destination_directory, relative, depth):
        nonlocal entries, total
        if depth > depth_limit:
            fail(f"visual evidence exceeds the {depth_limit}-level depth limit")
        for name in sorted(os.listdir(source_directory)):
            entries += 1
            if entries > entry_limit:
                fail(f"visual evidence exceeds the {entry_limit}-entry limit")
            item = os.stat(name, dir_fd=source_directory, follow_symlinks=False)
            display = "/".join((*relative, name))
            if stat.S_ISLNK(item.st_mode):
                fail(f"visual evidence must not contain symlinks at {display}")
            if stat.S_ISDIR(item.st_mode):
                source_child = open_verified_directory(source_directory, name)
                destination_child = ensure_destination_directory(destination_directory, name)
                try:
                    visit(source_child, destination_child, (*relative, name), depth + 1)
                finally:
                    os.close(destination_child)
                    os.close(source_child)
            elif stat.S_ISREG(item.st_mode):
                total += copy_regular(source_directory, destination_directory, name, maximum - total)
                copied_paths.append(f"visuals/{display}")

    try:
        visit(source, destination, (), 0)
    finally:
        os.close(destination)
        os.close(source)
    return sorted(copied_paths)


def command_read_fd(arguments):
    if len(arguments) != 3:
        fail("usage: fm-contained-read.py read-fd <relative> <maximum-bytes> <strict|head|tail>")
    relative, maximum_raw, mode = arguments
    maximum = int(maximum_raw)
    if maximum < 0 or mode not in ("strict", "head", "tail"):
        fail("invalid contained read arguments")
    root = checked_root(3)
    write_framed([("source", read_relative(root, relative, maximum, mode, optional=True))])


def command_snapshot_task_fd(arguments):
    if len(arguments) != 6:
        fail("usage: fm-contained-read.py snapshot-task-fd <task-id> <source-name> <brief-limit> <source-limit> <visual-limit> <entry-limit>:<depth-limit>")
    task_id, source_name, brief_raw, source_raw, visual_raw, inventory_raw = arguments
    task_parts = components(task_id)
    source_parts = components(source_name)
    if len(task_parts) != 1 or len(source_parts) != 1:
        fail("task and report source names must be single safe components")
    entry_raw, depth_raw = inventory_raw.split(":", 1)
    root = checked_root(3)
    destination = checked_root(4)
    task = open_relative(root, task_id, os.O_RDONLY | os.O_DIRECTORY)
    try:
        if not stat.S_ISDIR(os.fstat(task).st_mode):
            fail("task data source is not a real directory")
        brief = read_relative(task, "brief.md", int(brief_raw), "head", optional=True)
        source = read_relative(task, source_name, int(source_raw), "strict", optional=True)
        visuals = copy_visuals(task, destination, int(visual_raw), int(entry_raw), int(depth_raw))
        write_framed([("brief", brief), ("source", source), ("visuals", {"oversized": False, "size": 0, "content": json.dumps(visuals, separators=(",", ":")).encode("utf-8")})])
    finally:
        os.close(task)


def main():
    if len(sys.argv) < 2:
        fail("contained read command is required")
    if sys.argv[1] == "read-fd":
        command_read_fd(sys.argv[2:])
    elif sys.argv[1] == "snapshot-task-fd":
        command_snapshot_task_fd(sys.argv[2:])
    else:
        fail(f"unknown contained read command: {sys.argv[1]}")


try:
    main()
except (OSError, RuntimeError, ValueError) as error:
    if isinstance(error, OSError) and error.errno == errno.ELOOP:
        message = "source traversal encountered a symlink"
    else:
        message = str(error)
    print(f"error: contained read failed: {message}", file=sys.stderr)
    sys.exit(1)
