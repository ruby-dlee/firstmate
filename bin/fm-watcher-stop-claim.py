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


def process_identity_live(helper, pid):
    result = subprocess.run(
        [helper, "--live", str(pid)],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        universal_newlines=True,
    )
    if result.returncode != 0:
        return None
    identity = result.stdout.rstrip("\n")
    return identity or None


def session_basis(lockdir, session, helper):
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
        if process_identity(helper, int(root)) != root_identity:
            raise RuntimeError("reused session leader")
    extra_names = ("session-root", "arm-owner-pid", "arm-owner-identity")
    extras = {
        name: read_regular(os.path.join(lockdir, name))
        for name in extra_names
    }
    if extras["session-root"]:
        expected_root = "pid={}\nidentity={}\n".format(root, root_identity)
        if extras["session-root"] != expected_root:
            raise RuntimeError("invalid session root proof")
    if bool(extras["arm-owner-pid"]) != bool(extras["arm-owner-identity"]):
        raise RuntimeError("incomplete arm owner proof")
    if extras["arm-owner-pid"] and not extras["arm-owner-pid"].strip().isdigit():
        raise RuntimeError("invalid arm owner proof")
    return tuple((name, values[name]) for name in RECORD_NAMES) + tuple(
        (name, extras[name]) for name in extra_names
    )


def publish_regular(path, contents):
    pending = "{}.pending.{}".format(path, secrets.token_hex(12))
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(pending, flags, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as record:
            record.write(contents)
            record.flush()
            os.fsync(record.fileno())
        os.link(pending, path)
    finally:
        if os.path.exists(pending):
            os.unlink(pending)


def legacy_basis(lockdir, group, helper):
    names = ("pid", "pid-identity", "fm-home", "watcher-path")
    values = {
        name: read_regular(os.path.join(lockdir, name), required=True)
        for name in names
    }
    root = values["pid"].strip()
    root_identity = values["pid-identity"].rstrip("\n")
    if not root.isdigit() or root != group or not root_identity:
        raise RuntimeError("invalid legacy proof")
    current = process_identity(helper, int(root))
    if current is not None and current != root_identity:
        raise RuntimeError("reused legacy root")
    group_path = os.path.join(lockdir, "process-group")
    group_record = read_regular(group_path)
    if not group_record:
        if process_identity_live(helper, int(root)) != root_identity:
            raise RuntimeError("missing live legacy root")
        if os.getpgid(int(root)) != int(group):
            raise RuntimeError("invalid legacy process group")
        publish_regular(group_path, "{}\n".format(group))
        group_record = read_regular(group_path, required=True)
    if group_record.strip() != group:
        raise RuntimeError("invalid legacy process group")
    current = process_identity(helper, int(root))
    if current is not None:
        if current != root_identity or os.getpgid(int(root)) != int(group):
            raise RuntimeError("changed legacy process group")
        if process_identity(helper, int(root)) != root_identity:
            raise RuntimeError("reused legacy root")
    values["process-group"] = group_record
    return tuple((name, values[name]) for name in names + ("process-group",))


def basis(lockdir, boundary, helper, kind):
    if kind == "session":
        return session_basis(lockdir, boundary, helper)
    if kind == "legacy":
        return legacy_basis(lockdir, boundary, helper)
    raise RuntimeError("invalid claim kind")


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
    if set(fields) == expected:
        fields["kind"] = "session"
    elif set(fields) != expected | {"kind"}:
        raise RuntimeError("malformed claim")
    if fields["version"] != "1" or fields["kind"] not in ("session", "legacy"):
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


def claim_owner_live(fields, helper):
    pid = int(fields["stopper-pid"])
    return process_identity_live(helper, pid) == fields["stopper-identity"]


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


def acquire(lockdir, boundary, helper, stopper, stopper_identity, kind):
    descriptor = locked_file(lockdir)
    try:
        claim_path = os.path.join(lockdir, "session-stop")
        complete_path = os.path.join(lockdir, "session-stop-complete")
        try:
            contents = read_regular(claim_path, required=True)
            fields = parse_claim(contents)
        except FileNotFoundError:
            fields = None
        except RuntimeError:
            fields = None
        if fields is not None and claim_owner_live(fields, helper):
            if (
                fields["session-id"] == boundary
                and fields["kind"] == kind
                and str(stopper) == fields["stopper-pid"]
                and stopper_identity == fields["stopper-identity"]
            ):
                print(fields["claim-id"])
                return 0
            return 3
        snapshot = basis(lockdir, boundary, helper, kind)
        current_basis_id = basis_id(snapshot)
        if os.path.lexists(claim_path):
            if basis(lockdir, boundary, helper, kind) != snapshot:
                return 1
            quarantine = "{}.reclaimed.{}".format(claim_path, secrets.token_hex(12))
            os.rename(claim_path, quarantine)
            os.unlink(quarantine)
        if os.path.lexists(complete_path):
            if basis(lockdir, boundary, helper, kind) != snapshot:
                return 1
            read_regular(complete_path, required=True)
            os.unlink(complete_path)
        pending_names = [
            name
            for name in os.listdir(lockdir)
            if name == "session-stop.pending"
            or name.startswith("session-stop.pending.")
            or name.startswith("session-stop-complete.pending.")
        ]
        for pending_name in pending_names:
            if basis(lockdir, boundary, helper, kind) != snapshot:
                return 1
            pending_path = os.path.join(lockdir, pending_name)
            pending_metadata = os.lstat(pending_path)
            if stat.S_ISLNK(pending_metadata.st_mode) or not stat.S_ISREG(
                pending_metadata.st_mode
            ):
                return 1
            os.unlink(pending_path)
        if basis(lockdir, boundary, helper, kind) != snapshot:
            return 1
        if process_identity_live(helper, stopper) != stopper_identity:
            return 1
        claim_id = secrets.token_hex(24)
        contents = (
            "version=1\n"
            "kind={}\n"
            "session-id={}\n"
            "basis-id={}\n"
            "stopper-pid={}\n"
            "stopper-identity={}\n"
            "claim-id={}\n"
        ).format(kind, boundary, current_basis_id, stopper, stopper_identity, claim_id)
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
        if basis(lockdir, boundary, helper, kind) != snapshot:
            os.unlink(claim_path)
            return 1
        print(claim_id)
        return 0
    finally:
        os.close(descriptor)


def matches(lockdir, boundary, helper, kind):
    descriptor = locked_file(lockdir)
    try:
        fields = parse_claim(read_regular(os.path.join(lockdir, "session-stop"), required=True))
        return 0 if (
            fields["session-id"] == boundary
            and fields["kind"] == kind
            and claim_owner_live(fields, helper)
        ) else 1
    finally:
        os.close(descriptor)


def clear(lockdir, boundary, helper, stopper, stopper_identity, claim_id, kind):
    descriptor = locked_file(lockdir)
    try:
        claim_path = os.path.join(lockdir, "session-stop")
        fields = parse_claim(read_regular(claim_path, required=True))
        if (
            fields["session-id"] != boundary
            or fields["kind"] != kind
            or fields["claim-id"] != claim_id
            or fields["stopper-pid"] != str(stopper)
            or fields["stopper-identity"] != stopper_identity
            or process_identity_live(helper, stopper) != stopper_identity
        ):
            return 1
        complete_path = os.path.join(lockdir, "session-stop-complete")
        if os.path.lexists(complete_path):
            if read_regular(complete_path, required=True) != read_regular(claim_path, required=True):
                return 1
            os.unlink(complete_path)
        os.unlink(claim_path)
        return 0
    finally:
        os.close(descriptor)


def complete(lockdir, boundary, helper, stopper, stopper_identity, claim_id, kind):
    descriptor = locked_file(lockdir)
    try:
        claim_path = os.path.join(lockdir, "session-stop")
        claim_contents = read_regular(claim_path, required=True)
        fields = parse_claim(claim_contents)
        snapshot = basis(lockdir, boundary, helper, kind)
        if (
            fields["session-id"] != boundary
            or fields["kind"] != kind
            or fields["claim-id"] != claim_id
            or fields["stopper-pid"] != str(stopper)
            or fields["stopper-identity"] != stopper_identity
            or fields["basis-id"] != basis_id(snapshot)
            or process_identity_live(helper, stopper) != stopper_identity
        ):
            return 1
        complete_path = os.path.join(lockdir, "session-stop-complete")
        if os.path.lexists(complete_path):
            return 0 if read_regular(complete_path, required=True) == claim_contents else 1
        publish_regular(complete_path, claim_contents)
        if (
            read_regular(claim_path, required=True) != claim_contents
            or read_regular(complete_path, required=True) != claim_contents
            or basis(lockdir, boundary, helper, kind) != snapshot
        ):
            os.unlink(complete_path)
            return 1
        return 0
    finally:
        os.close(descriptor)


def completed(lockdir, boundary, helper, kind):
    descriptor = locked_file(lockdir)
    try:
        claim_contents = read_regular(os.path.join(lockdir, "session-stop"), required=True)
        fields = parse_claim(claim_contents)
        snapshot = basis(lockdir, boundary, helper, kind)
        return 0 if (
            fields["session-id"] == boundary
            and fields["kind"] == kind
            and fields["basis-id"] == basis_id(snapshot)
            and read_regular(
                os.path.join(lockdir, "session-stop-complete"), required=True
            ) == claim_contents
        ) else 1
    finally:
        os.close(descriptor)


def publish_lock(lockdir, boundary, helper, publish_path):
    descriptor = locked_file(lockdir)
    published = False
    try:
        claim_path = os.path.join(lockdir, "session-stop")
        if os.path.lexists(claim_path):
            fields = parse_claim(read_regular(claim_path, required=True))
            return 3 if claim_owner_live(fields, helper) else 1
        if os.path.lexists(os.path.join(lockdir, "session-stop-complete")):
            return 1
        if any(
            name == "session-stop.pending"
            or name.startswith("session-stop.pending.")
            or name.startswith("session-stop-complete.pending.")
            for name in os.listdir(lockdir)
        ):
            return 1
        snapshot = basis(lockdir, boundary, helper, "session")
        lockdir = os.path.abspath(lockdir)
        publish_path = os.path.abspath(publish_path)
        if (
            os.path.dirname(publish_path) != os.path.dirname(lockdir)
            or os.path.basename(publish_path) != ".watch.lock"
            or os.path.lexists(publish_path)
        ):
            return 1
        os.symlink(lockdir, publish_path)
        published = True
        if basis(lockdir, boundary, helper, "session") != snapshot:
            os.unlink(publish_path)
            published = False
            return 1
        if not os.path.islink(publish_path) or os.readlink(publish_path) != lockdir:
            os.unlink(publish_path)
            published = False
            return 1
        return 0
    except Exception:
        if published:
            try:
                if os.path.islink(publish_path) and os.readlink(publish_path) == lockdir:
                    os.unlink(publish_path)
            except OSError:
                pass
        raise
    finally:
        os.close(descriptor)


def main():
    if len(sys.argv) not in (5, 6, 7, 8):
        return 2
    action, lockdir, boundary, helper = sys.argv[1:5]
    kind = "legacy" if action.endswith("-legacy") else "session"
    if kind == "legacy":
        action = action[: -len("-legacy")]
    if not boundary.isdigit() or not os.path.isdir(lockdir) or os.path.islink(lockdir):
        return 2
    try:
        if action == "acquire":
            if len(sys.argv) != 7 or not sys.argv[5].isdigit():
                return 2
            return acquire(lockdir, boundary, helper, int(sys.argv[5]), sys.argv[6], kind)
        if action == "matches":
            if len(sys.argv) != 5:
                return 2
            return matches(lockdir, boundary, helper, kind)
        if action == "clear":
            if len(sys.argv) != 8 or not sys.argv[5].isdigit():
                return 2
            return clear(
                lockdir,
                boundary,
                helper,
                int(sys.argv[5]),
                sys.argv[6],
                sys.argv[7],
                kind,
            )
        if action == "complete":
            if len(sys.argv) != 8 or not sys.argv[5].isdigit() or kind != "session":
                return 2
            return complete(
                lockdir,
                boundary,
                helper,
                int(sys.argv[5]),
                sys.argv[6],
                sys.argv[7],
                kind,
            )
        if action == "completed":
            if len(sys.argv) != 5 or kind != "session":
                return 2
            return completed(lockdir, boundary, helper, kind)
        if action == "publish":
            if len(sys.argv) != 6 or kind != "session":
                return 2
            return publish_lock(lockdir, boundary, helper, sys.argv[5])
        return 2
    except (OSError, RuntimeError, ValueError):
        return 1


if __name__ == "__main__":
    sys.exit(main())
