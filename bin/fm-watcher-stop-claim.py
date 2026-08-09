#!/usr/bin/env python3

import fcntl
import os
import secrets
import stat
import subprocess
import sys


RECORD_NAMES = (
    "pid",
    "pid-identity",
    "process-session",
    "fm-home",
    "watcher-path",
    "session-anchor",
    "session-anchor-pid",
    "session-anchor-identity",
)


def read_regular(path, required=False):
    try:
        metadata = os.lstat(path)
    except FileNotFoundError:
        if required:
            raise RuntimeError("missing record")
        return ""
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise RuntimeError("unsafe record")
    with open(path, encoding="utf-8") as record:
        return record.read()


def process_identity(helper, pid):
    result = subprocess.run(
        [helper, str(pid)],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        universal_newlines=True,
    )
    if result.returncode != 0:
        return None
    identity = result.stdout.rstrip("\n")
    return identity or None


def basis(lockdir, session, helper):
    values = {}
    for name in RECORD_NAMES:
        values[name] = read_regular(
            os.path.join(lockdir, name),
            required=name in ("pid", "pid-identity", "process-session", "fm-home", "watcher-path"),
        )
    root = values["pid"].strip()
    root_identity = values["pid-identity"].rstrip("\n")
    recorded_session = values["process-session"].strip()
    if not root.isdigit() or root != session or recorded_session != session or not root_identity:
        raise RuntimeError("invalid session proof")
    current = process_identity(helper, int(root))
    if current is not None:
        if current != root_identity or os.getsid(int(root)) != int(session):
            raise RuntimeError("reused session leader")
    return tuple((name, values[name]) for name in RECORD_NAMES)


def parse_claim(contents):
    fields = {}
    for line in contents.splitlines():
        if "=" not in line:
            raise RuntimeError("malformed claim")
        name, value = line.split("=", 1)
        if name in fields:
            raise RuntimeError("duplicate claim field")
        fields[name] = value
    expected = {
        "version",
        "session-id",
        "basis-id",
        "stopper-pid",
        "stopper-identity",
        "claim-id",
    }
    if set(fields) != expected or fields["version"] != "1":
        raise RuntimeError("malformed claim")
    if not fields["session-id"].isdigit() or not fields["stopper-pid"].isdigit():
        raise RuntimeError("malformed claim")
    if not fields["basis-id"] or not fields["stopper-identity"] or not fields["claim-id"]:
        raise RuntimeError("malformed claim")
    return fields


def basis_id(snapshot):
    import hashlib

    digest = hashlib.sha256()
    for name, value in snapshot:
        digest.update(name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(value.encode("utf-8"))
        digest.update(b"\0")
    return digest.hexdigest()


def claim_live(fields, session, current_basis_id, helper):
    if fields["session-id"] != session or fields["basis-id"] != current_basis_id:
        return False
    pid = int(fields["stopper-pid"])
    return process_identity(helper, pid) == fields["stopper-identity"]


def locked_file(lockdir):
    path = os.path.join(lockdir, ".session-stop-transaction")
    flags = os.O_RDWR | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o600)
    metadata = os.fstat(descriptor)
    if not stat.S_ISREG(metadata.st_mode):
        os.close(descriptor)
        raise RuntimeError("unsafe transaction lock")
    fcntl.flock(descriptor, fcntl.LOCK_EX)
    return descriptor


def acquire(lockdir, session, helper, stopper, stopper_identity):
    descriptor = locked_file(lockdir)
    try:
        snapshot = basis(lockdir, session, helper)
        current_basis_id = basis_id(snapshot)
        claim_path = os.path.join(lockdir, "session-stop")
        try:
            contents = read_regular(claim_path, required=True)
            fields = parse_claim(contents)
        except FileNotFoundError:
            fields = None
        except RuntimeError:
            fields = None
        if fields is not None and claim_live(fields, session, current_basis_id, helper):
            if str(stopper) == fields["stopper-pid"] and stopper_identity == fields["stopper-identity"]:
                print(fields["claim-id"])
                return 0
            return 3
        if os.path.lexists(claim_path):
            if basis(lockdir, session, helper) != snapshot:
                return 1
            quarantine = "{}.reclaimed.{}".format(claim_path, secrets.token_hex(12))
            os.rename(claim_path, quarantine)
            os.unlink(quarantine)
        old_pending = os.path.join(lockdir, "session-stop.pending")
        if os.path.lexists(old_pending):
            if basis(lockdir, session, helper) != snapshot:
                return 1
            pending_metadata = os.lstat(old_pending)
            if stat.S_ISLNK(pending_metadata.st_mode) or not stat.S_ISREG(pending_metadata.st_mode):
                return 1
            os.unlink(old_pending)
        if basis(lockdir, session, helper) != snapshot:
            return 1
        if process_identity(helper, stopper) != stopper_identity:
            return 1
        claim_id = secrets.token_hex(24)
        contents = (
            "version=1\n"
            "session-id={}\n"
            "basis-id={}\n"
            "stopper-pid={}\n"
            "stopper-identity={}\n"
            "claim-id={}\n"
        ).format(session, current_basis_id, stopper, stopper_identity, claim_id)
        pending = "{}.pending.{}".format(claim_path, claim_id)
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        pending_descriptor = os.open(pending, flags, 0o600)
        try:
            with os.fdopen(pending_descriptor, "w", encoding="utf-8") as record:
                record.write(contents)
                record.flush()
                os.fsync(record.fileno())
            os.link(pending, claim_path)
        finally:
            if os.path.exists(pending):
                os.unlink(pending)
        if basis(lockdir, session, helper) != snapshot:
            os.unlink(claim_path)
            return 1
        print(claim_id)
        return 0
    finally:
        os.close(descriptor)


def matches(lockdir, session, helper):
    descriptor = locked_file(lockdir)
    try:
        current_basis_id = basis_id(basis(lockdir, session, helper))
        fields = parse_claim(read_regular(os.path.join(lockdir, "session-stop"), required=True))
        return 0 if claim_live(fields, session, current_basis_id, helper) else 1
    finally:
        os.close(descriptor)


def clear(lockdir, session, helper, stopper, stopper_identity, claim_id):
    descriptor = locked_file(lockdir)
    try:
        current_basis_id = basis_id(basis(lockdir, session, helper))
        claim_path = os.path.join(lockdir, "session-stop")
        fields = parse_claim(read_regular(claim_path, required=True))
        if (
            fields["session-id"] != session
            or fields["basis-id"] != current_basis_id
            or fields["claim-id"] != claim_id
            or fields["stopper-pid"] != str(stopper)
            or fields["stopper-identity"] != stopper_identity
        ):
            return 1
        os.unlink(claim_path)
        return 0
    finally:
        os.close(descriptor)


def main():
    if len(sys.argv) not in (5, 7, 8):
        return 2
    action, lockdir, session, helper = sys.argv[1:5]
    if not session.isdigit() or not os.path.isdir(lockdir) or os.path.islink(lockdir):
        return 2
    try:
        if action == "acquire":
            if len(sys.argv) != 7 or not sys.argv[5].isdigit():
                return 2
            return acquire(lockdir, session, helper, int(sys.argv[5]), sys.argv[6])
        if action == "matches":
            if len(sys.argv) != 5:
                return 2
            return matches(lockdir, session, helper)
        if action == "clear":
            if len(sys.argv) != 8 or not sys.argv[5].isdigit():
                return 2
            return clear(
                lockdir,
                session,
                helper,
                int(sys.argv[5]),
                sys.argv[6],
                sys.argv[7],
            )
        return 2
    except (OSError, RuntimeError, ValueError):
        return 1


if __name__ == "__main__":
    sys.exit(main())
