#!/usr/bin/env python3
import hashlib
import errno
import fcntl
import os
import selectors
import signal
import stat
import sys
import termios
import time
import tty


def fail(message):
    print(f"error: continuation prompt launch failed: {message}", file=sys.stderr)
    raise SystemExit(1)


cleanup_only = len(sys.argv) == 5 and sys.argv[1] == "--cleanup"
if (cleanup_only and len(sys.argv) != 5) or (not cleanup_only and len(sys.argv) != 6):
    fail("expected a prompt file, parent identity, file identity, content identity, and launch command")

prompt_path = os.path.abspath(sys.argv[2] if cleanup_only else sys.argv[1])
parent_path, name = os.path.split(prompt_path)
if not name or name in (".", ".."):
    fail("invalid prompt path")

expected_parent = sys.argv[3] if cleanup_only else sys.argv[2]
expected_file = sys.argv[4] if cleanup_only else sys.argv[3]
expected_content = None if cleanup_only else sys.argv[4]
parent = os.open(parent_path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
descriptor = None
snapshot = None
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
    if not cleanup_only:
        digest = hashlib.sha256()
        chunks = []
        offset = 0
        while offset < opened.st_size:
            chunk = os.pread(descriptor, min(65536, opened.st_size - offset), offset)
            if not chunk:
                fail("prompt source ended while verifying content")
            digest.update(chunk)
            chunks.append(chunk)
            offset += len(chunk)
        snapshot = b"".join(chunks)
    finished = os.fstat(descriptor)
    if (finished.st_dev, finished.st_ino, finished.st_size, finished.st_mtime_ns, finished.st_ctime_ns) != (
        opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns
    ) or (not cleanup_only and digest.hexdigest() != expected_content):
        fail("prompt source content changed")
    ready = os.environ.get("FM_PROMPT_EXEC_TEST_READY")
    proceed = os.environ.get("FM_PROMPT_EXEC_TEST_PROCEED")
    if not cleanup_only and ready and proceed:
        marker = os.open(ready, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        os.close(marker)
        deadline = time.monotonic() + 5
        while not os.path.exists(proceed):
            if time.monotonic() >= deadline:
                fail("prompt launch test gate timed out")
            time.sleep(0.01)
    os.unlink(name, dir_fd=parent)
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

command = os.fsencode(sys.argv[5])
if snapshot is None:
    fail("prompt snapshot is unavailable")

child, terminal = os.forkpty()
if child == 0:
    tty.setraw(0, termios.TCSANOW)
    os.execve(b"/bin/bash", [b"bash", b"-c", command, b"fm-continuation"], os.environb.copy())


def copy_window_size():
    try:
        size = fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8)
        fcntl.ioctl(terminal, termios.TIOCSWINSZ, size)
    except OSError:
        pass


def forward_signal(signum, _frame):
    try:
        os.kill(child, signum)
    except ProcessLookupError:
        pass


copy_window_size()
signal.signal(signal.SIGWINCH, lambda signum, frame: copy_window_size())
for forwarded in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM, signal.SIGQUIT):
    signal.signal(forwarded, forward_signal)

os.set_blocking(terminal, False)
selector = selectors.DefaultSelector()
pending = memoryview(snapshot + b"\r")
selector.register(terminal, selectors.EVENT_READ | selectors.EVENT_WRITE)
stdin_registered = False
child_status = None
try:
    while True:
        if child_status is None:
            waited, status = os.waitpid(child, os.WNOHANG)
            if waited == child:
                child_status = status
        if child_status is not None and terminal not in selector.get_map():
            break
        for key, events in selector.select(timeout=0.1):
            if key.fd == terminal:
                if events & selectors.EVENT_WRITE and pending:
                    try:
                        written = os.write(terminal, pending)
                        pending = pending[written:]
                    except BlockingIOError:
                        pass
                    if not pending:
                        selector.modify(terminal, selectors.EVENT_READ)
                        try:
                            os.set_blocking(0, False)
                            selector.register(0, selectors.EVENT_READ)
                            stdin_registered = True
                        except OSError:
                            pass
                if events & selectors.EVENT_READ:
                    try:
                        output = os.read(terminal, 65536)
                    except OSError as error:
                        if error.errno == errno.EIO:
                            output = b""
                        else:
                            raise
                    if output:
                        view = memoryview(output)
                        while view:
                            try:
                                written = os.write(1, view)
                                view = view[written:]
                            except BlockingIOError:
                                continue
                    else:
                        selector.unregister(terminal)
            elif key.fd == 0:
                try:
                    incoming = os.read(0, 65536)
                except BlockingIOError:
                    continue
                if incoming:
                    view = memoryview(incoming)
                    while view:
                        try:
                            written = os.write(terminal, view)
                            view = view[written:]
                        except BlockingIOError:
                            continue
                else:
                    selector.unregister(0)
                    stdin_registered = False
finally:
    if stdin_registered:
        try:
            selector.unregister(0)
        except Exception:
            pass
    selector.close()
    os.close(terminal)
    if child_status is None:
        _, child_status = os.waitpid(child, 0)

if os.WIFEXITED(child_status):
    raise SystemExit(os.WEXITSTATUS(child_status))
if os.WIFSIGNALED(child_status):
    raise SystemExit(128 + os.WTERMSIG(child_status))
raise SystemExit(1)
