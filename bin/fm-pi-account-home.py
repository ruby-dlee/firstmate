#!/usr/bin/env python3
"""Project one Pi profile into a single-profile account home.

Pi keeps every signed-in profile in ONE `auth.json`, keyed by provider slot:
`openai-codex`, `openai-codex-2`, and so on. Every Firstmate consumer of a Pi
credential instead reads an account home holding exactly one credential under
the fixed key `openai-codex` (`fm-crosscheck.py: inspect_pi_credential`,
`account_identity`, and the Azure Crosscheck credential archive all name that
key literally).

Handing the pooled file to a consumer therefore fails two ways at once. Only
the first slot is ever read, so profiles 2..N are unreachable no matter which
one the roster selected; and the Azure reviewer archive would carry every
signed-in account's tokens into a compartment that needs exactly one. This
command writes the single-profile homes those consumers already expect.

It validates credential SHAPE and reports expiry instants. It does not decide
whether a credential is still good enough to use: that is one question with one
owner, `bin/fm-credential-expiry.py`, which the callers run as their preflight.
Token material is never printed, and an account is identified only by digest.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import tempfile

CONSUMER_KEY = "openai-codex"
MAX_SOURCE_BYTES = 4 * 1024 * 1024
MAX_PROFILES = 256
REQUIRED_STRINGS = ("access", "refresh", "accountId")


class ProjectionError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise ProjectionError(message)


def read_pool(source: Path) -> dict[str, dict]:
    try:
        metadata = source.lstat()
    except OSError as exc:
        fail(f"Pi credential pool is unreadable at {source}: {exc.strerror}")
    if not stat.S_ISREG(metadata.st_mode) or source.is_symlink():
        fail(f"Pi credential pool must be a regular non-symlink file at {source}")
    if metadata.st_size > MAX_SOURCE_BYTES:
        fail(f"Pi credential pool exceeds its {MAX_SOURCE_BYTES}-byte bound at {source}")
    try:
        parsed = json.loads(source.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        fail(f"Pi credential pool is malformed at {source}: {type(exc).__name__}")
    if not isinstance(parsed, dict):
        fail(f"Pi credential pool is not a profile object at {source}")
    if len(parsed) > MAX_PROFILES:
        fail(f"Pi credential pool declares more than {MAX_PROFILES} profiles at {source}")
    return parsed


def entry_faults(entry: object) -> list[str]:
    """Every reason this entry would fail its consumer, not just the first."""

    if not isinstance(entry, dict):
        return ["is not a credential object"]
    faults = []
    if entry.get("type") != "oauth":
        faults.append("is not an oauth credential")
    for name in REQUIRED_STRINGS:
        value = entry.get(name)
        if not isinstance(value, str):
            faults.append(f"has no {name} string")
        elif not value.strip():
            # A blanked token is the shape a de-authenticated profile leaves
            # behind, and it reads as present to anything checking only for
            # the key. Consumers reject it; refuse to project it.
            faults.append(f"has a blank {name}")
    expires = entry.get("expires")
    if isinstance(expires, bool) or not isinstance(expires, (int, float)):
        faults.append("has no numeric expires")
    return faults


def expiry_text(entry: dict) -> str:
    expires = entry.get("expires")
    if isinstance(expires, bool) or not isinstance(expires, (int, float)):
        return "unknown"
    # Pi records the expiry in milliseconds.
    moment = datetime.datetime.fromtimestamp(
        expires / 1000.0, datetime.timezone.utc
    )
    return moment.isoformat().replace("+00:00", "Z")


def account_digest(entry: dict) -> str:
    account = entry.get("accountId")
    if not isinstance(account, str) or not account.strip():
        return "none"
    return hashlib.sha256(account.strip().encode("utf-8")).hexdigest()[:16]


def select(pool: dict[str, dict], requested: list[str], every: bool) -> list[str]:
    if every:
        return sorted(pool)
    missing = [name for name in requested if name not in pool]
    if missing:
        fail("Pi credential pool has no profile named: " + ", ".join(sorted(missing)))
    return list(dict.fromkeys(requested))


def write_home(destination: Path, entry: dict) -> Path:
    credential = destination / "auth.json"
    try:
        existing = credential.lstat()
    except FileNotFoundError:
        existing = None
    except OSError as exc:
        fail(f"account home is unreadable at {credential}: {exc.strerror}")
    if existing is not None and (
        not stat.S_ISREG(existing.st_mode) or credential.is_symlink()
    ):
        # Never follow a symlink into a write: the destination is chosen by an
        # operator argument and a planted link would redirect a credential.
        fail(f"refusing to replace a non-regular credential path at {credential}")

    destination.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(destination, 0o700)
    body = json.dumps({CONSUMER_KEY: entry}, sort_keys=True, indent=2) + "\n"

    # Written to a private temp file and renamed, so a reader never observes a
    # half-written credential and never sees one at default permissions.
    handle, staged = tempfile.mkstemp(dir=str(destination), prefix=".auth-", suffix=".tmp")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(body)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(staged, 0o600)
        os.replace(staged, credential)
    except BaseException:
        try:
            os.unlink(staged)
        except OSError:
            pass
        raise
    directory = os.open(str(destination), os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
    return credential


def command_report(args: argparse.Namespace) -> int:
    pool = read_pool(Path(args.source).expanduser().resolve())
    rows = []
    for name in sorted(pool):
        faults = entry_faults(pool[name])
        rows.append((name, "usable-shape" if not faults else "; ".join(faults),
                     expiry_text(pool[name]) if isinstance(pool[name], dict) else "unknown",
                     account_digest(pool[name]) if isinstance(pool[name], dict) else "none"))
    width = max([len(row[0]) for row in rows] + [len("profile")])
    stamp = max([len(row[2]) for row in rows] + [len("expires")])
    print(f"{'profile'.ljust(width)}  {'expires'.ljust(stamp)}  {'account':<16}  shape")
    for name, shape, expires, digest in rows:
        print(f"{name.ljust(width)}  {expires.ljust(stamp)}  {digest:<16}  {shape}")
    distinct = {row[3] for row in rows if row[3] != "none"}
    print(f"profiles={len(rows)} distinct-accounts={len(distinct)}")
    return 0


def command_project(args: argparse.Namespace) -> int:
    source = Path(args.source).expanduser().resolve()
    root = Path(args.destination_root).expanduser().resolve()
    pool = read_pool(source)
    names = select(pool, args.profile or [], args.all)
    if not names:
        fail("name at least one --profile, or pass --all")

    unusable = {name: entry_faults(pool[name]) for name in names}
    unusable = {name: faults for name, faults in unusable.items() if faults}
    if unusable:
        # All of them, so an operator fixes one round of logins rather than
        # discovering the next broken profile one failed projection at a time.
        for name in sorted(unusable):
            print(f"REFUSED {name}: {'; '.join(unusable[name])}", file=sys.stderr)
        fail(f"{len(unusable)} of {len(names)} selected profiles cannot be projected")

    for name in names:
        destination = root / name
        credential = write_home(destination, pool[name])
        print(
            f"projected {name} -> {credential} "
            f"account={account_digest(pool[name])} expires={expiry_text(pool[name])}"
        )
    print(f"projected={len(names)} root={root}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="fm-pi-account-home.py", description=__doc__.splitlines()[0]
    )
    commands = parser.add_subparsers(dest="command", required=True)

    default_source = "~/.pi/agent/auth.json"

    report = commands.add_parser("report", help="list pool profiles without projecting")
    report.add_argument("--source", default=default_source)
    report.set_defaults(handler=command_report)

    project = commands.add_parser("project", help="write single-profile account homes")
    project.add_argument("--source", default=default_source)
    project.add_argument("--destination-root", required=True)
    project.add_argument("--profile", action="append")
    project.add_argument("--all", action="store_true")
    project.set_defaults(handler=command_project)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.handler(args)
    except ProjectionError as exc:
        print(f"PI ACCOUNT HOME REFUSED: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
