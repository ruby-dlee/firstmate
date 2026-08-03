#!/usr/bin/env python3
import os
import stat
import sys


def identity(metadata):
    return metadata.st_dev, metadata.st_ino


def mountinfo_paths():
    paths = set()
    mountinfo = "/proc/self/mountinfo"
    if not os.path.exists(mountinfo):
        if sys.platform.startswith("linux"):
            raise OSError("Linux mount authority is unavailable")
        return paths
    with open(mountinfo, encoding="utf-8") as stream:
        for line in stream:
            fields = line.rstrip("\n").split()
            if len(fields) < 5:
                raise OSError("malformed mount table")
            value = fields[4]
            for encoded, decoded in (
                ("\\040", " "),
                ("\\011", "\t"),
                ("\\012", "\n"),
                ("\\134", "\\"),
            ):
                value = value.replace(encoded, decoded)
            paths.add(os.path.realpath(value))
    return paths


def hooks_enabled():
    return (
        os.environ.get("FM_ACCOUNT_ROUTING_TEST_LAB")
        == "firstmate-account-routing-test-lab-v1"
        and os.environ.get("FM_ACCOUNT_TEST_HOOKS")
        == "firstmate-account-tests-v1"
    )


target = os.path.normpath(os.path.abspath(sys.argv[1]))
if not sys.argv[1] or target == os.path.sep:
    raise SystemExit(1)

parent = os.path.dirname(target)
name = os.path.basename(target)
flags = os.O_RDONLY | os.O_DIRECTORY
if not hasattr(os, "O_NOFOLLOW"):
    raise SystemExit(1)
flags |= os.O_NOFOLLOW


def reject_boundary(path, metadata, device, mounted_paths):
    if metadata.st_dev != device:
        raise OSError(f"filesystem boundary at {path}")
    canonical = os.path.realpath(path)
    if canonical in mounted_paths or os.path.ismount(canonical):
        raise OSError(f"mount boundary at {canonical}")


def validate_tree(directory_fd, device, path, mounted_paths):
    reject_boundary(path, os.fstat(directory_fd), device, mounted_paths)
    for entry in sorted(os.listdir(directory_fd)):
        metadata = os.stat(entry, dir_fd=directory_fd, follow_symlinks=False)
        entry_path = os.path.join(path, entry)
        if stat.S_ISLNK(metadata.st_mode):
            continue
        if stat.S_ISDIR(metadata.st_mode):
            child_fd = os.open(entry, flags, dir_fd=directory_fd)
            try:
                opened = os.fstat(child_fd)
                if identity(opened) != identity(metadata):
                    raise OSError(f"directory identity changed at {entry}")
                validate_tree(child_fd, device, entry_path, mounted_paths)
            finally:
                os.close(child_fd)
            continue
        reject_boundary(entry_path, metadata, device, mounted_paths)


def remove_tree(directory_fd, device, path, mounted_paths):
    reject_boundary(path, os.fstat(directory_fd), device, mounted_paths)
    entries = sorted(os.listdir(directory_fd))
    disappearing = os.environ.get("FM_SAFE_TASK_TMP_DISAPPEAR_ENTRY")
    if (
        hooks_enabled()
        and disappearing in entries
    ):
        os.unlink(disappearing, dir_fd=directory_fd)
        del os.environ["FM_SAFE_TASK_TMP_DISAPPEAR_ENTRY"]
    for entry in entries:
        metadata = os.stat(entry, dir_fd=directory_fd, follow_symlinks=False)
        entry_path = os.path.join(path, entry)
        if stat.S_ISLNK(metadata.st_mode):
            current_metadata = os.stat(
                entry, dir_fd=directory_fd, follow_symlinks=False
            )
            if identity(current_metadata) != identity(metadata):
                raise OSError(f"symlink identity changed at {entry}")
            os.unlink(entry, dir_fd=directory_fd)
        elif stat.S_ISDIR(metadata.st_mode):
            child_fd = os.open(entry, flags, dir_fd=directory_fd)
            try:
                opened = os.fstat(child_fd)
                if identity(opened) != identity(metadata):
                    raise OSError(f"directory identity changed at {entry}")
                reject_boundary(entry_path, opened, device, mounted_paths)
                remove_tree(child_fd, device, entry_path, mounted_paths)
                current_metadata = os.stat(
                    entry, dir_fd=directory_fd, follow_symlinks=False
                )
                if identity(current_metadata) != identity(opened):
                    raise OSError(f"directory identity changed at {entry}")
                os.rmdir(entry, dir_fd=directory_fd)
            finally:
                os.close(child_fd)
        else:
            reject_boundary(entry_path, metadata, device, mounted_paths)
            current_metadata = os.stat(
                entry, dir_fd=directory_fd, follow_symlinks=False
            )
            if identity(current_metadata) != identity(metadata):
                raise OSError(f"entry identity changed at {entry}")
            os.unlink(entry, dir_fd=directory_fd)


try:
    mounted_paths = mountinfo_paths()
    parent_fd = os.open(os.path.sep, flags)
    try:
        try:
            for component in parent.split(os.path.sep):
                if not component:
                    continue
                next_fd = os.open(component, flags, dir_fd=parent_fd)
                os.close(parent_fd)
                parent_fd = next_fd
        except FileNotFoundError:
            raise SystemExit(0)
        swap_ancestor_value = os.environ.get("FM_SAFE_TASK_TMP_SWAP_ANCESTOR")
        if hooks_enabled() and swap_ancestor_value:
            swap_ancestor = os.path.normpath(os.path.abspath(swap_ancestor_value))
            swap_moved = os.path.normpath(
                os.path.abspath(os.environ["FM_SAFE_TASK_TMP_SWAP_MOVED"])
            )
            swap_outside = os.path.normpath(
                os.path.abspath(os.environ["FM_SAFE_TASK_TMP_SWAP_OUTSIDE"])
            )
            fixture_parent = os.path.dirname(swap_ancestor)
            if (
                swap_ancestor_value != swap_ancestor
                or os.path.commonpath((target, swap_ancestor)) != swap_ancestor
                or target == swap_ancestor
                or os.path.dirname(swap_moved) != fixture_parent
                or os.path.dirname(swap_outside) != fixture_parent
                or len({swap_ancestor, swap_moved, swap_outside}) != 3
            ):
                raise OSError("unsafe task temp swap fixture")
            os.rename(swap_ancestor, swap_moved)
            os.symlink(swap_outside, swap_ancestor, target_is_directory=True)
        try:
            metadata = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
                raise OSError("task temp root is not a real directory")
            root_fd = os.open(name, flags, dir_fd=parent_fd)
        except FileNotFoundError:
            raise SystemExit(0)
        try:
            opened = os.fstat(root_fd)
            if identity(opened) != identity(metadata):
                raise OSError("task temp root identity changed")
            parent_metadata = os.fstat(parent_fd)
            if opened.st_dev != parent_metadata.st_dev:
                raise OSError("task temp root filesystem boundary")
            reject_boundary(target, opened, opened.st_dev, mounted_paths)
            validate_tree(root_fd, opened.st_dev, target, mounted_paths)
            current_mounts = mountinfo_paths()
            if current_mounts != mounted_paths:
                raise OSError("mount table changed during task temp validation")
            remove_tree(root_fd, opened.st_dev, target, mounted_paths)
            current_metadata = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            if identity(current_metadata) != identity(opened):
                raise OSError("task temp root identity changed")
            os.rmdir(name, dir_fd=parent_fd)
        finally:
            os.close(root_fd)
    finally:
        os.close(parent_fd)
except OSError as error:
    print(f"REFUSED: unsafe task temp removal: {error}", file=sys.stderr)
    raise SystemExit(1)
