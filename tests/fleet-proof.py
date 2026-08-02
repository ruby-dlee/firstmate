#!/usr/bin/env python3
"""Run sealed tests under a Herdr lab while protecting stable fleet identities.

The full default-session inventory is recorded before and after the run. Only
explicitly protected identities are continuous abort conditions: ordinary task
panes may complete and be reaped while a long suite runs, so their disappearance
is reported for lifecycle reconciliation instead of being confused with a test
kill.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import shlex
import stat
import subprocess
import sys
import time
from typing import Any


Identity = dict[str, Any]


def process_table() -> dict[int, Identity]:
    output = subprocess.check_output(
        ["ps", "-axo", "pid=,ppid=,lstart=,command="], text=True
    )
    table: dict[int, Identity] = {}
    for line in output.splitlines():
        fields = line.strip().split(None, 7)
        if len(fields) != 8:
            continue
        command = fields[7]
        pid = int(fields[0])
        table[pid] = {
            "pid": pid,
            "ppid": int(fields[1]),
            "start": " ".join(fields[2:7]),
            "command_sha256": hashlib.sha256(command.encode()).hexdigest(),
            "command": command,
        }
    return table


def same_identity(before: Identity, after: Identity) -> bool:
    return all(after.get(key) == before.get(key) for key in ("pid", "start", "command_sha256"))


def snapshot(server_pid: int, table: dict[int, Identity] | None = None) -> Identity:
    table = table or process_table()
    server = table.get(server_pid)
    if server is None:
        raise RuntimeError(f"default Herdr server PID is not live: {server_pid}")
    panes = sorted(
        (identity for identity in table.values() if identity["ppid"] == server_pid),
        key=lambda identity: identity["pid"],
    )
    return {"server": server, "panes": panes}


def identity_map(inventory: Identity) -> dict[int, Identity]:
    return {int(identity["pid"]): identity for identity in inventory["panes"]}


def process_identity_diff(before: list[Identity], after: list[Identity]) -> Identity:
    before_map = {int(identity["pid"]): identity for identity in before}
    after_map = {int(identity["pid"]): identity for identity in after}
    missing = [before_map[pid] for pid in sorted(before_map.keys() - after_map.keys())]
    added = [after_map[pid] for pid in sorted(after_map.keys() - before_map.keys())]
    changed = [
        {"before": before_map[pid], "after": after_map[pid]}
        for pid in sorted(before_map.keys() & after_map.keys())
        if not same_identity(before_map[pid], after_map[pid])
    ]
    return {"missing": missing, "added": added, "changed": changed}


def inventory_diff(before: Identity, after: Identity) -> Identity:
    before_panes = identity_map(before)
    after_panes = identity_map(after)
    missing = [before_panes[pid] for pid in sorted(before_panes.keys() - after_panes.keys())]
    added = [after_panes[pid] for pid in sorted(after_panes.keys() - before_panes.keys())]
    changed = [
        {"before": before_panes[pid], "after": after_panes[pid]}
        for pid in sorted(before_panes.keys() & after_panes.keys())
        if not same_identity(before_panes[pid], after_panes[pid])
    ]
    server_changed = not same_identity(before["server"], after["server"])
    return {
        "server_changed": server_changed,
        "missing": missing,
        "added": added,
        "changed": changed,
        "lifecycle_reconciliation_required": bool(missing or changed),
    }


def default_layout_snapshot(path: Path) -> Identity:
    """Read the default session's persisted logical pane identities, not helper PIDs."""
    metadata = path.lstat()
    if path.is_symlink() or not path.is_file() or metadata.st_size > 2 * 1024 * 1024:
        raise RuntimeError(f"default Herdr session state is unsafe or oversized: {path}")
    last_error: Exception | None = None
    for _ in range(5):
        try:
            payload = json.loads(path.read_bytes())
            panes: list[Identity] = []
            workspaces = payload.get("workspaces")
            if not isinstance(workspaces, list):
                raise RuntimeError("default Herdr session state has no workspace list")
            for workspace in workspaces:
                workspace_id = str(workspace["id"])
                public_numbers = workspace.get("public_pane_numbers", {})
                if not isinstance(public_numbers, dict):
                    raise RuntimeError("default Herdr workspace has no public pane map")
                for tab in workspace.get("tabs", []):
                    pane_records = tab.get("panes", {})
                    if not isinstance(pane_records, dict):
                        raise RuntimeError("default Herdr tab has no pane map")
                    for internal_id, pane in pane_records.items():
                        public_number = public_numbers.get(str(internal_id))
                        if not isinstance(public_number, int):
                            raise RuntimeError(
                                f"default Herdr pane {internal_id} has no public number"
                            )
                        panes.append(
                            {
                                "pane_id": f"{workspace_id}:p{public_number}",
                                "workspace_id": workspace_id,
                                "workspace_label": workspace.get("custom_name"),
                                "label": pane.get("label"),
                                "agent_name": pane.get("agent_name"),
                                "cwd": pane.get("cwd"),
                            }
                        )
            panes.sort(key=lambda pane: str(pane["pane_id"]))
            return {"path": str(path), "version": payload.get("version"), "panes": panes}
        except (json.JSONDecodeError, KeyError, OSError, RuntimeError, TypeError) as error:
            last_error = error
            time.sleep(0.05)
    raise RuntimeError(f"could not read stable default Herdr pane inventory: {last_error}")


def default_layout_diff(before: Identity, after: Identity) -> Identity:
    before_map = {str(pane["pane_id"]): pane for pane in before["panes"]}
    after_map = {str(pane["pane_id"]): pane for pane in after["panes"]}
    missing = [before_map[key] for key in sorted(before_map.keys() - after_map.keys())]
    added = [after_map[key] for key in sorted(after_map.keys() - before_map.keys())]
    changed = [
        {"before": before_map[key], "after": after_map[key]}
        for key in sorted(before_map.keys() & after_map.keys())
        if before_map[key] != after_map[key]
    ]
    return {
        "missing": missing,
        "added": added,
        "changed": changed,
        "unchanged": not any((missing, added, changed)),
        "lifecycle_reconciliation_required": bool(missing or changed),
    }


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def path_identity(path: Path) -> Identity:
    metadata = path.lstat()
    result: Identity = {
        "path": str(path),
        "mode": f"{stat.S_IMODE(metadata.st_mode):04o}",
    }
    if stat.S_ISLNK(metadata.st_mode):
        result.update({"type": "symlink", "target": os.readlink(path)})
    elif stat.S_ISDIR(metadata.st_mode):
        result["type"] = "directory"
    elif stat.S_ISREG(metadata.st_mode):
        result.update(
            {"type": "file", "size": metadata.st_size, "sha256": sha256_file(path)}
        )
    else:
        result.update({"type": "other", "device": metadata.st_rdev})
    return result


def treehouse_pool_snapshot(root: Path) -> Identity:
    entries: list[Identity] = []
    for first in sorted(root.iterdir(), key=lambda item: item.name):
        entries.append(path_identity(first))
        if first.is_dir() and not first.is_symlink():
            for second in sorted(first.iterdir(), key=lambda item: item.name):
                entries.append(path_identity(second))
    return {"root": path_identity(root), "entries": entries, "depth": 2}


def path_tree_snapshot(path: Path) -> Identity:
    if not path.exists() and not path.is_symlink():
        return {"path": str(path), "type": "absent"}
    entry = path_identity(path)
    target = path.resolve(strict=True) if path.is_symlink() else path
    members: list[Identity] = []
    if target.is_dir():
        for member in sorted(target.rglob("*"), key=lambda item: str(item)):
            members.append(path_identity(member))
    elif target != path:
        members.append(path_identity(target))
    return {"entry": entry, "resolved_target": str(target), "members": members}


def path_present(snapshot: Identity) -> bool:
    entry = snapshot.get("entry", snapshot)
    return entry.get("type") != "absent"


def watch_lock_logical_owner(snapshot: Identity) -> Identity:
    """Return stable owner fields while excluding expected lock-instance identity."""
    members = {
        Path(str(member["path"])).name: {
            key: value for key, value in member.items() if key != "path"
        }
        for member in snapshot.get("members", [])
    }
    return {
        name: members.get(name)
        for name in ("fm-home", "watcher-path")
    }


def watch_lock_owner_hashes(snapshot: Identity) -> Identity:
    members = {
        Path(str(member["path"])).name: member.get("sha256")
        for member in snapshot.get("members", [])
    }
    return {name: members.get(name) for name in ("fm-home", "watcher-path")}


def expected_line_hash(value: Path) -> str:
    canonical = str(value.resolve())
    return hashlib.sha256(f"{canonical}\n".encode()).hexdigest()


def watcher_command_matches(identity: Identity, watcher_path: Path) -> bool:
    try:
        words = shlex.split(str(identity["command"]))
    except ValueError:
        return False
    return str(watcher_path.resolve()) in words


def lifecycle_log_checkpoint(path: Path) -> Identity:
    identity = path_identity(path)
    if identity.get("type") != "file":
        raise RuntimeError(f"supervisor lifecycle log is not a regular file: {path}")
    metadata = path.stat()
    return {
        "identity": identity,
        "device": metadata.st_dev,
        "inode": metadata.st_ino,
        "offset": metadata.st_size,
    }


def lifecycle_log_delta(before: Identity, path: Path) -> Identity:
    metadata = path.stat()
    append_only = (
        metadata.st_dev == before["device"]
        and metadata.st_ino == before["inode"]
        and metadata.st_size >= before["offset"]
    )
    if not append_only:
        return {
            "path": str(path),
            "append_only": False,
            "before": before,
            "after": path_identity(path),
            "lines": [],
        }
    appended_size = metadata.st_size - int(before["offset"])
    if appended_size > 1024 * 1024:
        return {
            "path": str(path),
            "append_only": True,
            "bounded": False,
            "appended_size": appended_size,
            "lines": [],
        }
    with path.open("rb") as stream:
        stream.seek(int(before["offset"]))
        appended = stream.read()
    return {
        "path": str(path),
        "append_only": True,
        "bounded": True,
        "appended_size": len(appended),
        "sha256": hashlib.sha256(appended).hexdigest(),
        "lines": appended.decode("utf-8", errors="replace").splitlines(),
    }


def lifecycle_processes(table: dict[int, Identity]) -> Identity:
    targets = {
        "fm-supervise-daemon.sh": "supervisor",
        "fm-watch.sh": "watcher",
        "fm-afk-launch.sh": "afk-launcher",
        "fm-afk-daemon": "afk-daemon",
    }
    matched: list[Identity] = []
    for identity in table.values():
        try:
            words = shlex.split(str(identity["command"]))
        except ValueError:
            continue
        role = next(
            (
                role
                for name, role in targets.items()
                if any(Path(word).name == name for word in words[1:3])
            ),
            None,
        )
        if role is not None:
            matched.append({**identity, "role": role})
    matched.sort(key=lambda identity: int(identity["pid"]))
    by_pid = {int(identity["pid"]): identity for identity in matched}
    stable: list[Identity] = []
    for identity in matched:
        parent = by_pid.get(int(identity["ppid"]))
        role = identity["role"]
        if role == "watcher" and parent is not None and parent["role"] == "watcher":
            continue
        stable.append(identity)
    return {"all": matched, "stable": stable}


def lifecycle_in_expected_home(
    identity: Identity, expected_watcher_path: Path | None
) -> bool:
    if expected_watcher_path is None:
        return True
    expected_dir = expected_watcher_path.resolve().parent
    allowed = {
        str(expected_watcher_path.resolve()),
        str(expected_dir / "fm-supervise-daemon.sh"),
        str(expected_dir / "fm-afk-launch.sh"),
        str(expected_dir / "fm-afk-daemon"),
    }
    try:
        words = shlex.split(str(identity["command"]))
    except ValueError:
        return False
    return any(word in allowed for word in words)


def scoped_stable_lifecycle(
    inventory: Identity, expected_watcher_path: Path | None
) -> list[Identity]:
    return [
        identity
        for identity in inventory["lifecycle_processes"]["stable"]
        if lifecycle_in_expected_home(identity, expected_watcher_path)
    ]


def host_snapshot(
    treehouse_root: Path, watch_lock: Path, afk_flag: Path
) -> Identity:
    table = process_table()
    return {
        "treehouse_pool": treehouse_pool_snapshot(treehouse_root),
        "watch_lock": path_tree_snapshot(watch_lock),
        "afk_flag": path_tree_snapshot(afk_flag),
        "lifecycle_processes": lifecycle_processes(table),
    }


def lifecycle_reconciliation(
    before: Identity,
    after: Identity,
    log_delta: Identity | None,
    expected_watch_owner: Identity | None = None,
    expected_watcher_path: Path | None = None,
) -> Identity:
    before_stable = scoped_stable_lifecycle(before, expected_watcher_path)
    after_stable = scoped_stable_lifecycle(after, expected_watcher_path)
    stable_diff = process_identity_diff(before_stable, after_stable)
    strict_changed = any(stable_diff.values())
    watch_lock_changed = before["watch_lock"] != after["watch_lock"]
    afk_marker_changed = before["afk_flag"] != after["afk_flag"]
    afk_mode_changed = path_present(before["afk_flag"]) != path_present(after["afk_flag"])
    if not any((strict_changed, watch_lock_changed, afk_marker_changed)):
        return {"required": False, "accepted": True, "reasons": []}

    reasons: list[str] = []
    log_usable = bool(
        log_delta is not None
        and log_delta.get("append_only")
        and log_delta.get("bounded")
    )
    lines = [str(line) for line in (log_delta or {}).get("lines", [])]
    joined = "\n".join(lines)

    before_by_role: dict[str, list[Identity]] = {}
    after_by_role: dict[str, list[Identity]] = {}
    for identity in before_stable:
        before_by_role.setdefault(str(identity["role"]), []).append(identity)
    for identity in after_stable:
        after_by_role.setdefault(str(identity["role"]), []).append(identity)

    accepted = True
    supervisor_rotated = before_by_role.get("supervisor") != after_by_role.get("supervisor")
    watcher_rotated = before_by_role.get("watcher") != after_by_role.get("watcher")
    known_roles = {"supervisor", "watcher"}
    unexpected_roles = (
        set(before_by_role) | set(after_by_role)
    ) - known_roles
    for role in sorted(unexpected_roles):
        if before_by_role.get(role) != after_by_role.get(role):
            accepted = False
            reasons.append(f"unreconciled stable lifecycle role changed: {role}")

    if supervisor_rotated:
        old = before_by_role.get("supervisor", [])
        new = after_by_role.get("supervisor", [])
        clean_cycle = (
            len(old) == 1
            and len(new) == 1
            and old[0]["command_sha256"] == new[0]["command_sha256"]
            and log_usable
            and "reap-wake delivery ready: native tracked background task will complete" in joined
            and "daemon shutting down" in joined
            and re.search(rf"daemon starting \(pid {int(new[0]['pid'])}\)", joined)
            is not None
        )
        if clean_cycle:
            reasons.append(
                "supervisor PID rotation matched a logged reap-wake completion and clean restart"
            )
        else:
            accepted = False
            reasons.append("supervisor PID rotation lacked a logged clean reap-wake cycle")

    owner_same = (
        watch_lock_logical_owner(before["watch_lock"])
        == watch_lock_logical_owner(after["watch_lock"])
    )
    if watcher_rotated or watch_lock_changed:
        old = before_by_role.get("watcher", [])
        new = after_by_role.get("watcher", [])
        expected_owner_cycle = (
            expected_watch_owner is not None
            and expected_watcher_path is not None
            and all(
                not path_present(snapshot)
                or watch_lock_owner_hashes(snapshot) == expected_watch_owner
                for snapshot in (before["watch_lock"], after["watch_lock"])
            )
            and all(
                watcher_command_matches(identity, expected_watcher_path)
                for identity in [*old, *new]
            )
            and len(old) <= 1
            and len(new) <= 1
        )
        watcher_cycle = (
            len(old) == 1
            and len(new) == 1
            and old[0]["command_sha256"] == new[0]["command_sha256"]
            and owner_same
            and log_usable
            and any("wake: " in line for line in lines)
        )
        if expected_owner_cycle:
            reasons.append(
                "watcher lifecycle stayed inside the declared operator home/path set while transitioning between idle and active"
            )
        elif watcher_cycle:
            reasons.append(
                "watcher PID/lock rotation retained the exact logical owner during logged away-mode wakes"
            )
        else:
            accepted = False
            reasons.append("watcher PID/lock rotation lacked stable ownership or a logged wake")

    if afk_mode_changed:
        accepted = False
        reasons.append("away-mode presence changed")
    elif afk_marker_changed:
        if supervisor_rotated and accepted:
            reasons.append(
                "away-mode marker timestamp refreshed while away mode remained present"
            )
        else:
            accepted = False
            reasons.append("away-mode marker changed without a reconciled supervisor restart")

    return {"required": True, "accepted": accepted, "reasons": reasons}


def host_diff(
    before: Identity,
    after: Identity,
    log_delta: Identity | None = None,
    expected_watch_owner: Identity | None = None,
    expected_watcher_path: Path | None = None,
) -> Identity:
    all_lifecycle = process_identity_diff(
        before["lifecycle_processes"]["all"], after["lifecycle_processes"]["all"]
    )
    stable_lifecycle = process_identity_diff(
        before["lifecycle_processes"]["stable"],
        after["lifecycle_processes"]["stable"],
    )
    scoped_stable = process_identity_diff(
        scoped_stable_lifecycle(before, expected_watcher_path),
        scoped_stable_lifecycle(after, expected_watcher_path),
    )
    treehouse_changed = before["treehouse_pool"] != after["treehouse_pool"]
    watch_lock_changed = before["watch_lock"] != after["watch_lock"]
    afk_marker_changed = before["afk_flag"] != after["afk_flag"]
    afk_mode_changed = path_present(before["afk_flag"]) != path_present(after["afk_flag"])
    stable_changed = any(stable_lifecycle.values())
    reconciliation = lifecycle_reconciliation(
        before,
        after,
        log_delta,
        expected_watch_owner,
        expected_watcher_path,
    )
    strictly_unchanged = not any(
        (treehouse_changed, watch_lock_changed, afk_marker_changed, stable_changed)
    )
    safe_after_reconciliation = (
        not treehouse_changed
        and not afk_mode_changed
        and (strictly_unchanged or reconciliation["accepted"])
    )
    return {
        "treehouse_pool_changed": treehouse_changed,
        "watch_lock_changed": watch_lock_changed,
        "watch_lock_logical_owner_changed": (
            watch_lock_logical_owner(before["watch_lock"])
            != watch_lock_logical_owner(after["watch_lock"])
        ),
        "watch_lock_in_expected_owner_set": (
            None
            if expected_watch_owner is None
            else all(
                not path_present(snapshot)
                or watch_lock_owner_hashes(snapshot) == expected_watch_owner
                for snapshot in (before["watch_lock"], after["watch_lock"])
            )
        ),
        "afk_flag_changed": afk_marker_changed,
        "afk_mode_changed": afk_mode_changed,
        "all_lifecycle_processes": all_lifecycle,
        "stable_lifecycle_processes": stable_lifecycle,
        "scoped_stable_lifecycle_processes": scoped_stable,
        "lifecycle_reconciliation_required": reconciliation["required"],
        "lifecycle_reconciliation": reconciliation,
        "host_unchanged": strictly_unchanged,
        "host_unchanged_or_reconciled": safe_after_reconciliation,
    }


def protected_violation(
    baseline: Identity, protected_pids: set[int], table: dict[int, Identity] | None = None
) -> Identity | None:
    table = table or process_table()
    expected = {int(baseline["server"]["pid"]): baseline["server"]}
    expected.update(identity_map(baseline))
    missing: list[Identity] = []
    changed: list[Identity] = []
    for pid in sorted(protected_pids | {int(baseline["server"]["pid"])}):
        before = expected.get(pid)
        if before is None:
            missing.append({"pid": pid, "reason": "not present in baseline"})
            continue
        after = table.get(pid)
        if after is None:
            missing.append(before)
        elif not same_identity(before, after):
            changed.append({"before": before, "after": after})
    if missing or changed:
        return {"missing": missing, "changed": changed}
    return None


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def write_bounded_tail(source: Path, destination: Path, limit: int = 1024 * 1024) -> None:
    with source.open("rb") as stream:
        stream.seek(0, os.SEEK_END)
        size = stream.tell()
        stream.seek(max(0, size - limit))
        destination.write_bytes(stream.read(limit))


def capture_lab_diagnostics(
    proof: Path, helper: Path, session: str, environment: dict[str, str]
) -> None:
    """Preserve actual lab state before guarded teardown removes its session dir."""
    try:
        listed = subprocess.run(
            [str(helper), "run", session, "session", "list", "--json"],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as error:
        (proof / "lab-diagnostics-error").write_text(
            f"session list failed: {error}\n", encoding="utf-8"
        )
        return
    (proof / "lab-session-list.json").write_bytes(listed.stdout)
    (proof / "lab-session-list.err").write_bytes(listed.stderr)
    (proof / "lab-session-list-status").write_text(
        f"{listed.returncode}\n", encoding="utf-8"
    )
    try:
        payload = json.loads(listed.stdout)
        records = [
            record
            for record in payload.get("sessions", [])
            if isinstance(record, dict) and record.get("name") == session
        ]
        if len(records) != 1:
            raise RuntimeError(
                f"expected one inventory record for {session}, found {len(records)}"
            )
        session_dir = Path(str(records[0]["session_dir"]))
        expected = Path.home() / ".config" / "herdr" / "sessions" / session
        if session_dir.resolve(strict=True) != expected.resolve(strict=True):
            raise RuntimeError(
                f"session directory escaped the expected path: {session_dir}"
            )
        for name in ("session.json", "herdr-server.log"):
            source = session_dir / name
            if source.is_file() and not source.is_symlink():
                write_bounded_tail(source, proof / f"lab-{name}")
    except (KeyError, OSError, RuntimeError, TypeError, ValueError) as error:
        (proof / "lab-diagnostics-error").write_text(
            f"session artifact capture failed: {error}\n", encoding="utf-8"
        )


def wait_lab_running(
    proof: Path,
    helper: Path,
    session: str,
    environment: dict[str, str],
    timeout_seconds: int = 30,
) -> bool:
    """Adopt only the running session state, never a proxy's exit-zero claim."""
    deadline = time.monotonic() + timeout_seconds
    attempt = 0
    with (proof / "adoption.log").open("wb") as output:
        while time.monotonic() < deadline:
            attempt += 1
            try:
                observed = subprocess.run(
                    [str(helper), "run", session, "status", "--json"],
                    env=environment,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=5,
                    check=False,
                )
                output.write(f"attempt={attempt} status={observed.returncode}\n".encode())
                output.write(observed.stdout)
                output.write(observed.stderr)
                output.write(b"\n")
                if observed.returncode == 0:
                    payload = json.loads(observed.stdout)
                    server = payload.get("server", {})
                    if server.get("running") is True and server.get("session") == session:
                        return True
            except (json.JSONDecodeError, OSError, subprocess.SubprocessError) as error:
                output.write(f"probe error: {error}\n".encode())
            time.sleep(0.2)
    return False


def stop_group(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--proof-dir", required=True, type=Path)
    parser.add_argument("--lab-helper", required=True, type=Path)
    parser.add_argument("--server-pid", required=True, type=int)
    parser.add_argument("--default-session-state", type=Path)
    parser.add_argument("--protect", action="append", default=[], type=int)
    parser.add_argument("--label", default="firstmate-suite")
    parser.add_argument("--treehouse-root", type=Path)
    parser.add_argument("--watch-lock", type=Path)
    parser.add_argument("--afk-flag", type=Path)
    parser.add_argument("--supervise-log", type=Path)
    parser.add_argument("--watch-home", type=Path)
    parser.add_argument("--watcher-path", type=Path)
    parser.add_argument("--reuse-lab", action="store_true")
    parser.add_argument("tests", nargs="+")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = Path(__file__).resolve().parent.parent
    proof = args.proof_dir.resolve()
    proof.mkdir(parents=True, exist_ok=True)
    baseline = snapshot(args.server_pid)
    write_json(proof / "default-before.json", baseline)
    layout_before = None
    if args.default_session_state is not None:
        layout_before = default_layout_snapshot(args.default_session_state)
        write_json(proof / "default-layout-before.json", layout_before)
    host_paths = (args.treehouse_root, args.watch_lock, args.afk_flag)
    if any(host_paths) and not all(host_paths):
        raise RuntimeError(
            "--treehouse-root, --watch-lock, and --afk-flag must be provided together"
        )
    watch_owner_paths = (args.watch_home, args.watcher_path)
    if any(watch_owner_paths) and not all(watch_owner_paths):
        raise RuntimeError("--watch-home and --watcher-path must be provided together")
    if all(watch_owner_paths) and not all(host_paths):
        raise RuntimeError("declared watcher ownership requires the real host snapshot arguments")
    expected_watch_owner = (
        {
            "fm-home": expected_line_hash(args.watch_home),
            "watcher-path": expected_line_hash(args.watcher_path),
        }
        if all(watch_owner_paths)
        else None
    )
    host_before = (
        host_snapshot(args.treehouse_root, args.watch_lock, args.afk_flag)
        if all(host_paths)
        else None
    )
    if host_before is not None:
        write_json(proof / "host-before.json", host_before)
    log_before = None
    if args.supervise_log is not None:
        if host_before is None:
            raise RuntimeError("--supervise-log requires the real host snapshot arguments")
        log_before = lifecycle_log_checkpoint(args.supervise_log)
        write_json(proof / "lifecycle-log-before.json", log_before)
    protected = set(args.protect)
    initial_violation = protected_violation(baseline, protected)
    if initial_violation:
        write_json(proof / "tripwire-violation.json", initial_violation)
        return 98

    session = subprocess.check_output(
        [str(args.lab_helper), "name", args.label], text=True
    ).strip()
    (proof / "lab-session").write_text(session + "\n", encoding="utf-8")
    environment = os.environ.copy()
    environment.update(
        {
            "FM_TEST_HERDR_LAB_SESSION": session,
            "HERDR_LAB_HELPER": str(args.lab_helper),
            "FM_TEST_OUTPUT_DIR": str(proof / "test-artifacts"),
        }
    )
    if args.reuse_lab:
        environment["FM_TEST_REUSE_HERDR_LAB"] = "1"
    with (proof / "provision.log").open("wb") as output:
        provision_status = subprocess.call(
            [str(args.lab_helper), "provision", session],
            stdout=output,
            stderr=subprocess.STDOUT,
        )
    (proof / "provision-status").write_text(
        f"{provision_status}\n", encoding="utf-8"
    )
    adoption_timeout = int(os.environ.get("FM_TEST_HERDR_ADOPTION_TIMEOUT_SECONDS", "30"))
    if not 1 <= adoption_timeout <= 600:
        raise RuntimeError(
            "FM_TEST_HERDR_ADOPTION_TIMEOUT_SECONDS must be an integer from 1 to 600"
        )
    adoption_ok = provision_status == 0 and wait_lab_running(
        proof,
        args.lab_helper,
        session,
        os.environ.copy(),
        timeout_seconds=adoption_timeout,
    )
    (proof / "adoption-status").write_text(
        f"{0 if adoption_ok else 1}\n", encoding="utf-8"
    )
    if provision_status != 0 or not adoption_ok:
        capture_lab_diagnostics(proof, args.lab_helper, session, os.environ.copy())
        with (proof / "teardown.log").open("wb") as output:
            teardown_status = subprocess.call(
                [str(args.lab_helper), "teardown", session],
                stdout=output,
                stderr=subprocess.STDOUT,
            )
        (proof / "teardown-status").write_text(
            f"{teardown_status}\n", encoding="utf-8"
        )
        after = snapshot(args.server_pid)
        write_json(proof / "default-after.json", after)
        write_json(proof / "default-diff.json", inventory_diff(baseline, after))
        if layout_before is not None:
            layout_after = default_layout_snapshot(args.default_session_state)
            write_json(proof / "default-layout-after.json", layout_after)
            write_json(
                proof / "default-layout-diff.json",
                default_layout_diff(layout_before, layout_after),
            )
        if host_before is not None:
            host_after = host_snapshot(args.treehouse_root, args.watch_lock, args.afk_flag)
            write_json(proof / "host-after.json", host_after)
            log_after = (
                lifecycle_log_delta(log_before, args.supervise_log)
                if log_before is not None
                else None
            )
            if log_after is not None:
                write_json(proof / "lifecycle-log-delta.json", log_after)
            write_json(
                proof / "host-diff.json",
                host_diff(
                    host_before,
                    host_after,
                    log_after,
                    expected_watch_owner,
                    args.watcher_path,
                ),
            )
        status = provision_status if provision_status != 0 else 97
        final_violation = protected_violation(baseline, protected)
        if final_violation:
            write_json(proof / "tripwire-violation.json", final_violation)
            status = 98
        (proof / "driver-status").write_text(f"{status}\n", encoding="utf-8")
        return status

    status = 1
    process: subprocess.Popen[bytes] | None = None
    teardown_status = 0
    try:
        with (proof / "suite.log").open("wb") as output:
            process = subprocess.Popen(
                [str(root / "tests/run.sh"), *args.tests],
                stdout=output,
                stderr=subprocess.STDOUT,
                env=environment,
                start_new_session=True,
            )
            while process.poll() is None:
                violation = protected_violation(baseline, protected)
                if violation:
                    write_json(proof / "tripwire-violation.json", violation)
                    stop_group(process)
                    status = 98
                    break
                time.sleep(0.1)
            if status != 98:
                status = process.wait()
    finally:
        if process is not None:
            stop_group(process)
        capture_lab_diagnostics(proof, args.lab_helper, session, os.environ.copy())
        with (proof / "teardown.log").open("wb") as output:
            teardown_status = subprocess.call(
                [str(args.lab_helper), "teardown", session],
                stdout=output,
                stderr=subprocess.STDOUT,
            )
        (proof / "teardown-status").write_text(
            f"{teardown_status}\n", encoding="utf-8"
        )
        after = snapshot(args.server_pid)
        write_json(proof / "default-after.json", after)
        write_json(proof / "default-diff.json", inventory_diff(baseline, after))
        if layout_before is not None:
            layout_after = default_layout_snapshot(args.default_session_state)
            write_json(proof / "default-layout-after.json", layout_after)
            write_json(
                proof / "default-layout-diff.json",
                default_layout_diff(layout_before, layout_after),
            )
        if host_before is not None:
            host_after = host_snapshot(args.treehouse_root, args.watch_lock, args.afk_flag)
            write_json(proof / "host-after.json", host_after)
            log_after = (
                lifecycle_log_delta(log_before, args.supervise_log)
                if log_before is not None
                else None
            )
            if log_after is not None:
                write_json(proof / "lifecycle-log-delta.json", log_after)
            host_result = host_diff(
                host_before,
                host_after,
                log_after,
                expected_watch_owner,
                args.watcher_path,
            )
            write_json(proof / "host-diff.json", host_result)
            if status == 0 and not host_result["host_unchanged_or_reconciled"]:
                status = 99
        final_violation = protected_violation(baseline, protected)
        if final_violation:
            write_json(proof / "tripwire-violation.json", final_violation)
            status = 98
        elif teardown_status != 0 and status == 0:
            status = teardown_status
        (proof / "driver-status").write_text(f"{status}\n", encoding="utf-8")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
