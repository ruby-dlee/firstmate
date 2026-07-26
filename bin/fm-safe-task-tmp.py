#!/usr/bin/env python3
import os
import stat
import sys


def identity(metadata):
    return metadata.st_dev, metadata.st_ino


target = os.path.normpath(os.path.abspath(sys.argv[1]))
if not sys.argv[1] or target == os.path.sep:
    raise SystemExit(1)

parent = os.path.dirname(target)
name = os.path.basename(target)
flags = os.O_RDONLY | os.O_DIRECTORY
if not hasattr(os, "O_NOFOLLOW"):
    raise SystemExit(1)
flags |= os.O_NOFOLLOW


def remove_tree(directory_fd, device):
    entries = sorted(os.listdir(directory_fd))
    disappearing = os.environ.get("FM_SAFE_TASK_TMP_DISAPPEAR_ENTRY")
    if (
        os.environ.get("FM_ACCOUNT_ROUTING_TEST_LAB")
        == "firstmate-account-routing-test-lab-v1"
        and disappearing in entries
    ):
        os.unlink(disappearing, dir_fd=directory_fd)
        del os.environ["FM_SAFE_TASK_TMP_DISAPPEAR_ENTRY"]
    for entry in entries:
        metadata = os.stat(entry, dir_fd=directory_fd, follow_symlinks=False)
        if metadata.st_dev != device:
            raise OSError(f"filesystem boundary at {entry}")
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
                remove_tree(child_fd, device)
                current_metadata = os.stat(
                    entry, dir_fd=directory_fd, follow_symlinks=False
                )
                if identity(current_metadata) != identity(opened):
                    raise OSError(f"directory identity changed at {entry}")
                os.rmdir(entry, dir_fd=directory_fd)
            finally:
                os.close(child_fd)
        else:
            current_metadata = os.stat(
                entry, dir_fd=directory_fd, follow_symlinks=False
            )
            if identity(current_metadata) != identity(metadata):
                raise OSError(f"entry identity changed at {entry}")
            os.unlink(entry, dir_fd=directory_fd)


try:
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
        if (
            os.environ.get("FM_ACCOUNT_ROUTING_TEST_LAB")
            == "firstmate-account-routing-test-lab-v1"
            and os.environ.get("FM_SAFE_TASK_TMP_SWAP_ANCESTOR")
        ):
            os.rename(
                os.environ["FM_SAFE_TASK_TMP_SWAP_ANCESTOR"],
                os.environ["FM_SAFE_TASK_TMP_SWAP_MOVED"],
            )
            os.symlink(
                os.environ["FM_SAFE_TASK_TMP_SWAP_OUTSIDE"],
                os.environ["FM_SAFE_TASK_TMP_SWAP_ANCESTOR"],
                target_is_directory=True,
            )
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
            remove_tree(root_fd, opened.st_dev)
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
