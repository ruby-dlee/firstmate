#!/usr/bin/env python3

import errno
import base64
import ctypes
import hashlib
import json
import os
import selectors
import stat
import subprocess
import sys
import time


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
        if flags & os.O_DIRECTORY:
            if not stat.S_ISDIR(before.st_mode):
                fail(f"source is not a real directory: {relative}")
        elif not stat.S_ISREG(before.st_mode):
            fail(f"source is not a real regular file: {relative}")
        descriptor = os.open(parts[-1], flags | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
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


class FingerprintBudget:
    def __init__(self, maximum_files, maximum_bytes, maximum_seconds=None):
        self.maximum_files = maximum_files
        self.maximum_bytes = maximum_bytes
        self.deadline = time.monotonic() + maximum_seconds if maximum_seconds is not None else None
        self.files = 0
        self.bytes = 0

    def check_time(self):
        if self.deadline is not None and time.monotonic() > self.deadline:
            fail("repository fingerprint exceeds its time limit")

    def consume(self, size=0):
        self.check_time()
        self.files += 1
        if self.files > self.maximum_files:
            fail("repository fingerprint exceeds its file-count limit")
        self.consume_bytes(size)

    def consume_bytes(self, size):
        self.check_time()
        self.bytes += size
        if self.bytes > self.maximum_bytes:
            fail("repository fingerprint exceeds its byte limit")


def fingerprint_descriptor(descriptor, relative, records, budget):
    opened = os.fstat(descriptor)
    if stat.S_ISREG(opened.st_mode):
        budget.consume(opened.st_size)
        digest = hashlib.sha256()
        offset = 0
        while offset < opened.st_size:
            chunk = os.pread(descriptor, min(64 * 1024, opened.st_size - offset), offset)
            if not chunk:
                fail(f"repository file ended while fingerprinting: {relative}")
            budget.check_time()
            digest.update(chunk)
            offset += len(chunk)
        if not same_file(opened, os.fstat(descriptor)):
            fail(f"repository file changed while fingerprinting: {relative}")
        records.append((relative, "file", opened.st_mode, digest.hexdigest()))
        return
    if not stat.S_ISDIR(opened.st_mode):
        budget.consume(0)
        records.append((relative, "special", opened.st_mode, "special"))
        return
    budget.consume(0)
    records.append((relative, "directory", opened.st_mode, "directory"))
    for name in sorted(os.listdir(descriptor)):
        child_relative = f"{relative}/{name}" if relative else name
        before = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        if stat.S_ISLNK(before.st_mode):
            target = os.readlink(name, dir_fd=descriptor).encode("utf-8", "surrogateescape")
            after = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            if not same_file(before, after):
                fail(f"repository symlink changed while fingerprinting: {child_relative}")
            budget.consume(len(target))
            records.append((child_relative, "symlink", before.st_mode, hashlib.sha256(target).hexdigest()))
            continue
        flags = os.O_RDONLY | (os.O_DIRECTORY if stat.S_ISDIR(before.st_mode) else 0)
        child = os.open(name, flags | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=descriptor)
        try:
            actual = os.fstat(child)
            if actual.st_dev != before.st_dev or actual.st_ino != before.st_ino:
                fail(f"repository path changed while fingerprinting: {child_relative}")
            fingerprint_descriptor(child, child_relative, records, budget)
        finally:
            os.close(child)


def command_fingerprint_paths_fd(arguments):
    if len(arguments) not in (1, 3):
        fail("usage: fm-contained-read.py fingerprint-paths-fd <paths-file> [max-files max-bytes]")
    root = checked_root(3)
    paths = open(arguments[0], "rb").read().split(b"\0")
    maximum_files = int(arguments[1]) if len(arguments) == 3 else 100000
    maximum_bytes = int(arguments[2]) if len(arguments) == 3 else 1073741824
    if maximum_files <= 0 or maximum_bytes <= 0:
        fail("repository fingerprint limits must be positive")
    budget = FingerprintBudget(maximum_files, maximum_bytes)
    records = []
    for raw in paths:
        if not raw:
            continue
        relative = raw.decode("utf-8", "surrogateescape")
        try:
            parts = components(relative)
            parent = os.dup(root)
            try:
                for part in parts[:-1]:
                    child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
                    os.close(parent)
                    parent = child
                before = os.stat(parts[-1], dir_fd=parent, follow_symlinks=False)
                if stat.S_ISLNK(before.st_mode):
                    target = os.readlink(parts[-1], dir_fd=parent).encode("utf-8", "surrogateescape")
                    after = os.stat(parts[-1], dir_fd=parent, follow_symlinks=False)
                    if not same_file(before, after):
                        fail(f"repository symlink changed while fingerprinting: {relative}")
                    budget.consume(len(target))
                    records.append((relative, "symlink", before.st_mode, hashlib.sha256(target).hexdigest()))
                else:
                    flags = os.O_RDONLY | (os.O_DIRECTORY if stat.S_ISDIR(before.st_mode) else 0)
                    item = os.open(parts[-1], flags | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
                    try:
                        actual = os.fstat(item)
                        if actual.st_dev != before.st_dev or actual.st_ino != before.st_ino:
                            fail(f"repository path changed while fingerprinting: {relative}")
                        fingerprint_descriptor(item, relative, records, budget)
                    finally:
                        os.close(item)
            finally:
                os.close(parent)
        except FileNotFoundError:
            records.append((relative, "missing", 0, "missing"))
    output = sys.stdout.buffer
    for relative, kind, mode, digest in records:
        output.write(relative.encode("utf-8", "surrogateescape"))
        output.write(f"\0{kind}:{mode:o}:{digest}\0".encode("ascii"))


def bounded_command_output(command, budget):
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    selector = selectors.DefaultSelector()
    output = []
    try:
        os.set_blocking(process.stdout.fileno(), False)
        selector.register(process.stdout, selectors.EVENT_READ)
        while True:
            budget.check_time()
            for key, _ in selector.select(timeout=0.1):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if chunk:
                    budget.consume_bytes(len(chunk))
                    output.append(chunk)
                else:
                    selector.unregister(key.fileobj)
            if process.poll() is not None and not selector.get_map():
                break
        if process.returncode != 0:
            raise subprocess.CalledProcessError(process.returncode, command)
        return b"".join(output)
    except BaseException:
        if process.poll() is None:
            process.kill()
        process.wait()
        raise
    finally:
        selector.close()
        process.stdout.close()


def command_fingerprint_submodules_fd(arguments):
    if len(arguments) != 4:
        fail("usage: fm-contained-read.py fingerprint-submodules-fd <paths-file> <max-files> <max-bytes> <max-seconds>")
    root = checked_root(3)
    maximum_files = int(arguments[1])
    maximum_bytes = int(arguments[2])
    maximum_seconds = int(arguments[3])
    if maximum_files <= 0 or maximum_bytes <= 0 or maximum_seconds <= 0:
        fail("repository fingerprint limits must be positive")
    budget = FingerprintBudget(maximum_files, maximum_bytes, maximum_seconds)
    paths = [item for item in open(arguments[0], "rb").read().split(b"\0") if item]
    output = sys.stdout.buffer
    for raw in paths:
        relative = raw.decode("utf-8", "surrogateescape")
        descriptor = open_relative(root, relative, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fchdir(descriptor)
            command_output = []
            try:
                for command in (
                    ["git", "rev-parse", "HEAD"],
                    ["git", "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=no"],
                    ["git", "diff", "--no-ext-diff", "--binary", "--submodule=diff", "HEAD", "--"],
                ):
                    budget.consume()
                    command_output.append(bounded_command_output(command, budget))
                budget.consume()
                untracked = bounded_command_output(
                    ["git", "ls-files", "--others", "--exclude-standard", "-z"],
                    budget,
                ).split(b"\0")
            except subprocess.CalledProcessError:
                output.write(b"submodule\0" + raw + b"\0unavailable\0")
                continue
        finally:
            os.fchdir(root)
            os.close(descriptor)
        records = []
        prefix = f"{relative}/"
        for item in untracked:
            if not item:
                continue
            item_relative = prefix + item.decode("utf-8", "surrogateescape")
            item_descriptor = open_relative(root, item_relative, os.O_RDONLY)
            try:
                fingerprint_descriptor(item_descriptor, item_relative, records, budget)
            finally:
                os.close(item_descriptor)
        output.write(b"submodule\0" + raw + b"\0")
        for value in command_output:
            output.write(value + b"\0")
        for item_relative, kind, mode, digest in records:
            output.write(item_relative.encode("utf-8", "surrogateescape"))
            output.write(f"\0{kind}:{mode:o}:{digest}\0".encode("ascii"))


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
    source = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=source_parent)
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


def snapshot_artifact(source_parent, destination_parent, source_name, destination_name, view_limit, mode, copy_limit=None, optional=False):
    try:
        source = open_relative(source_parent, source_name, os.O_RDONLY)
    except FileNotFoundError:
        if optional:
            return None
        raise
    destination = None
    try:
        opened = os.fstat(source)
        item = read_descriptor(source, view_limit, mode)
        if copy_limit is not None and opened.st_size > copy_limit:
            return item
        destination = os.open(
            destination_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=destination_parent,
        )
        os.lseek(source, 0, os.SEEK_SET)
        copied = 0
        while copied < opened.st_size:
            chunk = os.read(source, min(64 * 1024, opened.st_size - copied))
            if not chunk:
                fail(f"source ended before its recorded size: {source_name}")
            view = memoryview(chunk)
            while view:
                written = os.write(destination, view)
                view = view[written:]
            copied += len(chunk)
        if os.read(source, 1):
            fail(f"source changed size while copying: {source_name}")
        if not same_file(opened, os.fstat(source)):
            fail(f"source changed while copying: {source_name}")
        return item
    finally:
        if destination is not None:
            os.close(destination)
        os.close(source)


def write_artifact(destination, name, content):
    descriptor = os.open(
        name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
        dir_fd=destination,
    )
    try:
        view = memoryview(content)
        while view:
            written = os.write(descriptor, view)
            view = view[written:]
    finally:
        os.close(descriptor)


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
        brief = snapshot_artifact(task, destination, "brief.md", "brief.md", int(brief_raw), "head", optional=True)
        source = snapshot_artifact(task, destination, source_name, "report.md", int(source_raw), "strict", copy_limit=int(source_raw), optional=True)
        visuals = copy_visuals(task, destination, int(visual_raw), int(entry_raw), int(depth_raw))
        write_artifact(destination, ".visuals.json", json.dumps(visuals, separators=(",", ":")).encode("utf-8"))
        write_framed([("brief", brief), ("source", source)])
    finally:
        os.close(task)


def command_snapshot_file_fd(arguments):
    if len(arguments) != 4:
        fail("usage: fm-contained-read.py snapshot-file-fd <relative> <view-limit> <head|tail> <destination-name>")
    relative, maximum_raw, mode, destination_name = arguments
    maximum = int(maximum_raw)
    if maximum < 0 or mode not in ("head", "tail") or len(components(destination_name)) != 1:
        fail("invalid contained snapshot arguments")
    root = checked_root(3)
    destination = checked_root(4)
    parent_name = os.path.dirname(relative)
    source_parent = open_relative(root, parent_name, os.O_RDONLY | os.O_DIRECTORY) if parent_name else os.dup(root)
    try:
        item = snapshot_artifact(source_parent, destination, os.path.basename(relative), destination_name, maximum, mode, optional=True)
    finally:
        os.close(source_parent)
    write_framed([("source", item)])


def command_snapshot_files_fd(arguments):
    if len(arguments) < 2:
        fail("usage: fm-contained-read.py snapshot-files-fd <maximum-bytes> <source>...")
    maximum = int(arguments[0])
    if maximum < 0:
        fail("invalid contained snapshot limit")
    root = checked_root(3)
    destination = checked_root(4)
    for index, relative in enumerate(arguments[1:]):
        if len(components(relative)) != 1:
            fail("snapshot sources must be single safe components")
        item = read_relative(root, relative, maximum, "strict", optional=True)
        if item is None:
            continue
        if item["oversized"]:
            fail(f"source exceeds {maximum} bytes: {relative}")
        name = f"{index}.snapshot"
        descriptor = os.open(
            name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=destination,
        )
        try:
            content = item["content"]
            written = 0
            while written < len(content):
                written += os.write(descriptor, content[written:])
        finally:
            os.close(descriptor)


def remove_directory_contents(descriptor):
    for entry in os.scandir(descriptor):
        before = os.stat(entry.name, dir_fd=descriptor, follow_symlinks=False)
        if stat.S_ISDIR(before.st_mode):
            child = os.open(
                entry.name,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=descriptor,
            )
            try:
                opened = os.fstat(child)
                if opened.st_dev != before.st_dev or opened.st_ino != before.st_ino:
                    fail(f"directory changed while removing {entry.name}")
                remove_directory_contents(child)
                current = os.stat(entry.name, dir_fd=descriptor, follow_symlinks=False)
                if current.st_dev != opened.st_dev or current.st_ino != opened.st_ino:
                    fail(f"directory changed while removing {entry.name}")
                os.rmdir(entry.name, dir_fd=descriptor)
            finally:
                os.close(child)
        else:
            os.unlink(entry.name, dir_fd=descriptor)


def command_replace_file_fd(arguments):
    if len(arguments) != 2:
        fail("usage: fm-contained-read.py replace-file-fd <source-name> <destination-name>")
    source_name, destination_name = arguments
    if len(components(source_name)) != 1 or len(components(destination_name)) != 1:
        fail("replacement names must be single safe components")
    source_root = checked_root(3)
    destination_root = checked_root(4)
    source = os.stat(source_name, dir_fd=source_root, follow_symlinks=False)
    if not stat.S_ISREG(source.st_mode):
        fail("replacement source is not a real regular file")
    try:
        destination = os.stat(destination_name, dir_fd=destination_root, follow_symlinks=False)
        if not stat.S_ISREG(destination.st_mode):
            fail("replacement destination is not a real regular file")
    except FileNotFoundError:
        pass
    os.rename(
        source_name,
        destination_name,
        src_dir_fd=source_root,
        dst_dir_fd=destination_root,
    )


def command_remove_owned_directory_fd(arguments):
    if len(arguments) != 3:
        fail("usage: fm-contained-read.py remove-owned-directory-fd <directory-name> <control-name> <token>")
    directory_name, control_name, token = arguments
    if len(components(directory_name)) != 1 or len(components(control_name)) != 1:
        fail("owned directory names must be single safe components")
    root = checked_root(3)
    before = os.stat(directory_name, dir_fd=root, follow_symlinks=False)
    if not stat.S_ISDIR(before.st_mode):
        fail("owned path is not a real directory")
    directory = os.open(
        directory_name,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
        dir_fd=root,
    )
    try:
        opened = os.fstat(directory)
        if opened.st_dev != before.st_dev or opened.st_ino != before.st_ino:
            fail("owned directory changed while opening")
        control = read_relative(directory, control_name, 4096, "strict")
        if control["oversized"]:
            fail("owned directory control file is too large")
        raw = control["content"].decode("utf-8").strip()
        try:
            owner_token = json.loads(raw).get("token", "")
        except json.JSONDecodeError:
            owner_token = raw.splitlines()[-1] if raw else ""
        if owner_token != token:
            fail("owned directory token changed")
        current = os.stat(directory_name, dir_fd=root, follow_symlinks=False)
        if current.st_dev != opened.st_dev or current.st_ino != opened.st_ino:
            fail("owned directory changed before removal")
        quarantine = f".{directory_name}.released.{os.getpid()}.{token}"
        os.rename(directory_name, quarantine, src_dir_fd=root, dst_dir_fd=root)
        quarantined = os.stat(quarantine, dir_fd=root, follow_symlinks=False)
        if quarantined.st_dev != opened.st_dev or quarantined.st_ino != opened.st_ino:
            fail("owned directory changed during removal")
        remove_directory_contents(directory)
        os.rmdir(quarantine, dir_fd=root)
    finally:
        os.close(directory)


def exchange_names(root, first, second):
    libc = ctypes.CDLL(None, use_errno=True)
    first_raw = os.fsencode(first)
    second_raw = os.fsencode(second)
    if sys.platform == "darwin":
        rename_exchange = libc.renameatx_np
        rename_exchange.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        rename_exchange.restype = ctypes.c_int
        result = rename_exchange(root, first_raw, root, second_raw, 0x00000002)
    else:
        machine = os.uname().machine
        syscall_number = 316 if machine in ("x86_64", "amd64") else 276
        result = libc.syscall(syscall_number, root, first_raw, root, second_raw, 0x00000002)
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def rename_noreplace(source_root, destination_root, source, destination):
    libc = ctypes.CDLL(None, use_errno=True)
    source_raw = os.fsencode(source)
    destination_raw = os.fsencode(destination)
    if sys.platform == "darwin":
        rename_exclusive = libc.renameatx_np
        rename_exclusive.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        rename_exclusive.restype = ctypes.c_int
        result = rename_exclusive(source_root, source_raw, destination_root, destination_raw, 0x00000004)
    else:
        machine = os.uname().machine
        syscall_number = 316 if machine in ("x86_64", "amd64") else 276
        result = libc.syscall(syscall_number, source_root, source_raw, destination_root, destination_raw, 0x00000001)
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def command_exchange_files_fd(arguments):
    if len(arguments) != 4:
        fail("usage: fm-contained-read.py exchange-files-fd <source> <destination> <source-id> <destination-id>")
    source_name, destination_name, source_id, destination_id = arguments
    if len(components(source_name)) != 1 or len(components(destination_name)) != 1:
        fail("exchange names must be single safe components")
    root = checked_root(3)
    source = os.stat(source_name, dir_fd=root, follow_symlinks=False)
    destination = os.stat(destination_name, dir_fd=root, follow_symlinks=False)
    if not stat.S_ISREG(source.st_mode) or not stat.S_ISREG(destination.st_mode):
        fail("exchange operands must be real regular files")
    if f"{source.st_dev}:{source.st_ino}" != source_id or f"{destination.st_dev}:{destination.st_ino}" != destination_id:
        fail("exchange generation changed before publication")
    exchange_names(root, source_name, destination_name)
    moved_source = os.stat(destination_name, dir_fd=root, follow_symlinks=False)
    moved_destination = os.stat(source_name, dir_fd=root, follow_symlinks=False)
    if f"{moved_source.st_dev}:{moved_source.st_ino}" == source_id \
            and f"{moved_destination.st_dev}:{moved_destination.st_ino}" == destination_id:
        return
    exchange_names(root, source_name, destination_name)
    fail("exchange generation changed during publication")


def command_copy_file_fd(arguments):
    if len(arguments) not in (2, 3) or (len(arguments) == 3 and arguments[2] != "emit-base64"):
        fail("usage: fm-contained-read.py copy-file-fd <source> <destination> [emit-base64]")
    source_name, destination_name = arguments[:2]
    emit_base64 = len(arguments) == 3
    if len(components(source_name)) != 1 or len(components(destination_name)) != 1:
        fail("copy names must be single safe components")
    root = checked_root(3)
    source = open_relative(root, source_name, os.O_RDONLY)
    destination = None
    copied = []
    try:
        before = os.fstat(source)
        destination = os.open(
            destination_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=root,
        )
        offset = 0
        while offset < before.st_size:
            chunk = os.pread(source, min(1024 * 1024, before.st_size - offset), offset)
            if not chunk:
                fail("source ended before its recorded size")
            written = 0
            while written < len(chunk):
                written += os.write(destination, chunk[written:])
            if emit_base64:
                copied.append(chunk)
            offset += len(chunk)
        os.fsync(destination)
        after = os.fstat(source)
        if not same_file(before, after):
            fail("source changed while copying")
        if emit_base64:
            sys.stdout.buffer.write(base64.b64encode(b"".join(copied)))
    except Exception:
        if destination is not None:
            os.close(destination)
            destination = None
        try:
            os.unlink(destination_name, dir_fd=root)
        except FileNotFoundError:
            pass
        raise
    finally:
        if destination is not None:
            os.close(destination)
        os.close(source)


def command_rename_noreplace_owned_fd(arguments):
    if len(arguments) != 3:
        fail("usage: fm-contained-read.py rename-noreplace-owned-fd <source> <destination> <source-id>")
    source_name, destination_name, source_id = arguments
    if len(components(source_name)) != 1 or len(components(destination_name)) != 1:
        fail("rename names must be single safe components")
    source_root = checked_root(3)
    destination_root = checked_root(4)
    source = os.stat(source_name, dir_fd=source_root, follow_symlinks=False)
    if not stat.S_ISDIR(source.st_mode) or f"{source.st_dev}:{source.st_ino}" != source_id:
        fail("owned directory generation changed before rename")
    ready = os.environ.get("FM_CONTAINED_RENAME_TEST_READY")
    proceed = os.environ.get("FM_CONTAINED_RENAME_TEST_PROCEED")
    if ready and proceed:
        with open(ready, "x", encoding="utf-8") as marker:
            marker.write(f"{destination_name}\n")
        deadline = time.monotonic() + 5
        while not os.path.exists(proceed):
            if time.monotonic() >= deadline:
                fail("owned rename test gate timed out")
            time.sleep(0.01)
    rename_noreplace(source_root, destination_root, source_name, destination_name)
    moved = os.stat(destination_name, dir_fd=destination_root, follow_symlinks=False)
    if moved.st_dev != source.st_dev or moved.st_ino != source.st_ino:
        try:
            rename_noreplace(destination_root, source_root, destination_name, source_name)
            restored = os.stat(source_name, dir_fd=source_root, follow_symlinks=False)
            if restored.st_dev != moved.st_dev or restored.st_ino != moved.st_ino:
                fail("unowned directory generation could not be restored after rename")
        except OSError as error:
            fail(f"unowned directory generation remains quarantined after rename: {error}")
        fail("owned directory generation changed during rename and the moved replacement was restored")


def command_rename_noreplace_owned_entry_fd(arguments):
    if len(arguments) != 3:
        fail("usage: fm-contained-read.py rename-noreplace-owned-entry-fd <source> <destination> <source-id>")
    source_name, destination_name, source_id = arguments
    if len(components(source_name)) != 1 or len(components(destination_name)) != 1:
        fail("rename names must be single safe components")
    source_root = checked_root(3)
    destination_root = checked_root(4)
    source = os.stat(source_name, dir_fd=source_root, follow_symlinks=False)
    if stat.S_ISLNK(source.st_mode) or not (stat.S_ISDIR(source.st_mode) or stat.S_ISREG(source.st_mode)) \
            or f"{source.st_dev}:{source.st_ino}" != source_id:
        fail("owned entry generation changed before rename")
    rename_noreplace(source_root, destination_root, source_name, destination_name)
    moved = os.stat(destination_name, dir_fd=destination_root, follow_symlinks=False)
    if moved.st_dev != source.st_dev or moved.st_ino != source.st_ino:
        try:
            rename_noreplace(destination_root, source_root, destination_name, source_name)
        except OSError as error:
            fail(f"unowned entry generation remains quarantined after rename: {error}")
        fail("owned entry generation changed during rename and the moved replacement was restored")


def command_prune_tombstones_fd(arguments):
    if len(arguments) != 1:
        fail("usage: fm-contained-read.py prune-tombstones-fd <batch>")
    batch = int(arguments[0])
    if batch <= 0:
        fail("tombstone prune batch must be positive")
    root = checked_root(3)
    pruned = 0
    pending = False
    for tombstone_name in sorted(os.listdir(root)):
        if not tombstone_name.startswith("tombstone-"):
            fail(f"invalid retention tombstone: {tombstone_name}")
        tombstone = open_relative(root, tombstone_name, os.O_RDONLY | os.O_DIRECTORY)
        try:
            children = sorted(os.listdir(tombstone))
            for child in children:
                if pruned >= batch:
                    pending = True
                    break
                child_stat = os.stat(child, dir_fd=tombstone, follow_symlinks=False)
                legacy_expired = child.startswith(".") and child.endswith(".expired")
                if not stat.S_ISDIR(child_stat.st_mode) or (child.startswith(".") and not legacy_expired):
                    fail(f"invalid report entry in retention tombstone: {child}")
                child_fd = open_relative(tombstone, child, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    remove_directory_contents(child_fd)
                finally:
                    os.close(child_fd)
                os.rmdir(child, dir_fd=tombstone)
                pruned += 1
            if not os.listdir(tombstone):
                os.rmdir(tombstone_name, dir_fd=root)
            else:
                pending = True
        finally:
            os.close(tombstone)
        if pruned >= batch:
            pending = pending or bool(os.listdir(root))
            break
    print(json.dumps({"pruned": pruned, "pending": pending}, separators=(",", ":")))


def copy_directory_contents(source, destination):
    before = os.fstat(source)
    names = sorted(os.listdir(source))
    for name in names:
        observed = os.stat(name, dir_fd=source, follow_symlinks=False)
        if stat.S_ISDIR(observed.st_mode):
            child_source = open_relative(source, name, os.O_RDONLY | os.O_DIRECTORY)
            os.mkdir(name, 0o700, dir_fd=destination)
            child_destination = open_relative(destination, name, os.O_RDONLY | os.O_DIRECTORY)
            try:
                copy_directory_contents(child_source, child_destination)
            finally:
                os.close(child_destination)
                os.close(child_source)
        elif stat.S_ISREG(observed.st_mode):
            child_source = open_relative(source, name, os.O_RDONLY)
            child_destination = os.open(
                name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
                0o600,
                dir_fd=destination,
            )
            try:
                opened = os.fstat(child_source)
                offset = 0
                while offset < opened.st_size:
                    chunk = os.pread(child_source, min(1024 * 1024, opened.st_size - offset), offset)
                    if not chunk:
                        fail(f"source ended while copying {name}")
                    written = 0
                    while written < len(chunk):
                        written += os.write(child_destination, chunk[written:])
                    offset += len(chunk)
                os.fsync(child_destination)
                if not same_file(opened, os.fstat(child_source)):
                    fail(f"source changed while copying {name}")
            finally:
                os.close(child_destination)
                os.close(child_source)
        else:
            fail(f"source is not a real file or directory: {name}")
    after = os.fstat(source)
    if before.st_dev != after.st_dev or before.st_ino != after.st_ino or names != sorted(os.listdir(source)):
        fail("source directory changed while copying")


def command_copy_directory_fd(arguments):
    if len(arguments) != 3:
        fail("usage: fm-contained-read.py copy-directory-fd <source> <destination-parent|-> <destination>")
    source_name, parent_name, destination_name = arguments
    if len(components(source_name)) != 1 or len(components(destination_name)) != 1:
        fail("copy directory names must be single safe components")
    if parent_name != "-" and len(components(parent_name)) != 1:
        fail("copy directory parent must be one safe component")
    source_root = checked_root(3)
    destination_root = checked_root(4)
    source = open_relative(source_root, source_name, os.O_RDONLY | os.O_DIRECTORY)
    parent = os.dup(destination_root)
    staged_name = f".{destination_name}.legacy-restore"
    try:
        if parent_name != "-":
            try:
                os.mkdir(parent_name, 0o700, dir_fd=destination_root)
            except FileExistsError:
                pass
            os.close(parent)
            parent = open_relative(destination_root, parent_name, os.O_RDONLY | os.O_DIRECTORY)
        try:
            staged = open_relative(parent, staged_name, os.O_RDONLY | os.O_DIRECTORY)
        except FileNotFoundError:
            staged = None
        if staged is not None:
            try:
                remove_directory_contents(staged)
            finally:
                os.close(staged)
            os.rmdir(staged_name, dir_fd=parent)
        os.mkdir(staged_name, 0o700, dir_fd=parent)
        destination = open_relative(parent, staged_name, os.O_RDONLY | os.O_DIRECTORY)
        try:
            copy_directory_contents(source, destination)
            os.fsync(destination)
        finally:
            os.close(destination)
        rename_noreplace(parent, parent, staged_name, destination_name)
        os.fsync(parent)
    except Exception:
        try:
            staged = open_relative(parent, staged_name, os.O_RDONLY | os.O_DIRECTORY)
        except (FileNotFoundError, NotADirectoryError):
            staged = None
        if staged is not None:
            try:
                remove_directory_contents(staged)
            finally:
                os.close(staged)
            os.rmdir(staged_name, dir_fd=parent)
        raise
    finally:
        os.close(parent)
        os.close(source)


def command_exchange_directories_fd(arguments):
    if len(arguments) != 4:
        fail("usage: fm-contained-read.py exchange-directories-fd <first> <second> <first-id> <second-id>")
    first_name, second_name, first_id, second_id = arguments
    if len(components(first_name)) != 1 or len(components(second_name)) != 1:
        fail("exchange directory names must be single safe components")
    root = checked_root(3)
    first = os.stat(first_name, dir_fd=root, follow_symlinks=False)
    second = os.stat(second_name, dir_fd=root, follow_symlinks=False)
    if not stat.S_ISDIR(first.st_mode) or not stat.S_ISDIR(second.st_mode):
        fail("exchange operands must be real directories")
    if f"{first.st_dev}:{first.st_ino}" != first_id or f"{second.st_dev}:{second.st_ino}" != second_id:
        fail("exchange directory generation changed before publication")
    exchange_names(root, first_name, second_name)
    moved_first = os.stat(second_name, dir_fd=root, follow_symlinks=False)
    moved_second = os.stat(first_name, dir_fd=root, follow_symlinks=False)
    if f"{moved_first.st_dev}:{moved_first.st_ino}" != first_id \
            or f"{moved_second.st_dev}:{moved_second.st_ino}" != second_id:
        exchange_names(root, first_name, second_name)
        fail("exchange directory generation changed during publication")


def command_remove_owned_file_fd(arguments):
    if len(arguments) != 3:
        fail("usage: fm-contained-read.py remove-owned-file-fd <name> <identity> <quarantine>")
    name, identity, quarantine = arguments
    if len(components(name)) != 1 or len(components(quarantine)) != 1:
        fail("owned file names must be single safe components")
    root = checked_root(3)
    before = os.stat(name, dir_fd=root, follow_symlinks=False)
    if not stat.S_ISREG(before.st_mode) or f"{before.st_dev}:{before.st_ino}" != identity:
        fail("owned file generation changed before removal")
    try:
        os.stat(quarantine, dir_fd=root, follow_symlinks=False)
        fail("owned file quarantine already exists")
    except FileNotFoundError:
        pass
    ready = os.environ.get("FM_CONTAINED_REMOVE_TEST_READY")
    proceed = os.environ.get("FM_CONTAINED_REMOVE_TEST_PROCEED")
    if ready and proceed:
        with open(ready, "x", encoding="utf-8") as marker:
            marker.write("ready\n")
        deadline = time.monotonic() + 5
        while not os.path.exists(proceed):
            if time.monotonic() >= deadline:
                fail("owned file removal test gate timed out")
            time.sleep(0.01)
    os.rename(name, quarantine, src_dir_fd=root, dst_dir_fd=root)
    moved = os.stat(quarantine, dir_fd=root, follow_symlinks=False)
    if f"{moved.st_dev}:{moved.st_ino}" != identity:
        try:
            os.link(
                quarantine,
                name,
                src_dir_fd=root,
                dst_dir_fd=root,
                follow_symlinks=False,
            )
            os.unlink(quarantine, dir_fd=root)
        except OSError:
            pass
        fail("owned file generation changed during removal")
    os.unlink(quarantine, dir_fd=root)


def main():
    if len(sys.argv) < 2:
        fail("contained read command is required")
    if sys.argv[1] == "read-fd":
        command_read_fd(sys.argv[2:])
    elif sys.argv[1] == "snapshot-task-fd":
        command_snapshot_task_fd(sys.argv[2:])
    elif sys.argv[1] == "snapshot-files-fd":
        command_snapshot_files_fd(sys.argv[2:])
    elif sys.argv[1] == "snapshot-file-fd":
        command_snapshot_file_fd(sys.argv[2:])
    elif sys.argv[1] == "replace-file-fd":
        command_replace_file_fd(sys.argv[2:])
    elif sys.argv[1] == "remove-owned-directory-fd":
        command_remove_owned_directory_fd(sys.argv[2:])
    elif sys.argv[1] == "fingerprint-paths-fd":
        command_fingerprint_paths_fd(sys.argv[2:])
    elif sys.argv[1] == "fingerprint-submodules-fd":
        command_fingerprint_submodules_fd(sys.argv[2:])
    elif sys.argv[1] == "exchange-files-fd":
        command_exchange_files_fd(sys.argv[2:])
    elif sys.argv[1] == "copy-file-fd":
        command_copy_file_fd(sys.argv[2:])
    elif sys.argv[1] == "rename-noreplace-owned-fd":
        command_rename_noreplace_owned_fd(sys.argv[2:])
    elif sys.argv[1] == "rename-noreplace-owned-entry-fd":
        command_rename_noreplace_owned_entry_fd(sys.argv[2:])
    elif sys.argv[1] == "prune-tombstones-fd":
        command_prune_tombstones_fd(sys.argv[2:])
    elif sys.argv[1] == "copy-directory-fd":
        command_copy_directory_fd(sys.argv[2:])
    elif sys.argv[1] == "exchange-directories-fd":
        command_exchange_directories_fd(sys.argv[2:])
    elif sys.argv[1] == "remove-owned-file-fd":
        command_remove_owned_file_fd(sys.argv[2:])
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
