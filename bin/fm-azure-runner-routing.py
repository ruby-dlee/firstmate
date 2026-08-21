#!/usr/bin/env python3
"""Per-run Azure command-class routing for daemon-spawned no-mistakes steps.

WHY THIS EXISTS
---------------
`FM_AZURE_RUNNER_REMOTE_CLASSES` cannot select a class for one no-mistakes run.
The step that reads it is not a child of the operator's shell: it is a child of
the machine-global no-mistakes daemon, whose launchd job pins its environment to
`{HOME, PATH}`. Reading the live environment of a real run's step processes on
2026-08-21 showed the step's own shells carrying ZERO `FM_*` variables, so the
documented `export ... && no-mistakes axi run` recipe selects nothing. The only
environment that reaches such a step is a machine-global `launchctl setenv` plus
a daemon restart, which is an ambient global that outlives the intent AND a
restart of the daemon every other pipeline depends on.

This routing file replaces that with an ordinary per-run act: one file, keyed by
the run it applies to, that expires and carries a dispatch budget.

WHAT IT MUST CARRY, AND WHY EACH FIELD IS EXPLICIT
--------------------------------------------------
`fm_home` is declared, never inferred. `bin/fm-azure-runner.py` requires
`os.environ["FM_HOME"]` and it is where the runner's SPEND LEDGER lives, so a
guessed value does not merely fail: it silently writes cost accounting into a
second ledger and the real one under-reports.

`subscription` is likewise declared. Today the dispatch falls back to the
operator environment's `FM_AZURE_SUBSCRIPTION_ID`, which does not exist inside
the daemon. Requiring it here is not a workaround for that absence: it turns the
billable-compute confirmation from an ambient inheritance into an explicit
written act, which is what a confirmation should have been.

THE LOOKUP PATH IS NEVER DERIVED FROM REPOSITORY CONTENT
---------------------------------------------------------
The routing directory is anchored on `$HOME` alone. It is never derived from the
repository, the checkout, the worktree, or the working directory, so a branch may
carry `.fm-azure/runner-routing/*.json` freely and nothing here will read it.
That invariant is the whole answer to "what stops a checkout carrying one", and
it is asserted by `tests/fm-azure-runner.test.sh` rather than left as a property
of today's code, because it is exactly what a later refactor breaks by accident.

FAIL-CLOSED ASYMMETRY
---------------------
ABSENT is safe and means local execution, exactly today's default; it is the
normal case, and it is what keeps the machine-global empty forever.
PRESENT-BUT-BROKEN is never safe. Unreadable, torn, malformed, wrong schema,
missing field, expired, budget-exhausted, wrong run, or an unusable `fm_home`
all REFUSE BY NAME and the command runs NOWHERE. A present file means the
operator intended remote; running local instead would be a silent fallback, and
a silent local fallback is indistinguishable from a real cell run.

Usage:
  fm-azure-runner-routing.py resolve --run-id <ulid> --class <command-class>

Exit codes:
  0  remote selected; KEY=VALUE bindings on stdout
  1  refusal; exact reason on stderr; the caller must execute NOWHERE
  2  usage error
  3  no routing file for this run; the caller executes LOCALLY
  4  a routing file exists but does not select this class; execute LOCALLY
"""

import argparse
import datetime as dt
import errno
import fcntl
import importlib.util
import json
import os
import re
import stat
import sys
from pathlib import Path

SCHEMA = "fm.azure-runner-routing/v1"
RUN_ID = re.compile(r"^[0-9A-HJKMNP-TV-Z]{26}$")
COMMAND_CLASS = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$")
SUBSCRIPTION = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)
REQUIRED = ("schema", "run_id", "classes", "fm_home", "subscription", "expires_at", "max_dispatches")

EXIT_SELECTED = 0
EXIT_REFUSED = 1
EXIT_USAGE = 2
EXIT_ABSENT = 3
EXIT_NOT_SELECTED = 4


def refuse(message):
    """Every refusal names what is wrong. The caller then runs NOWHERE."""
    print("azure-runner routing: " + message, file=sys.stderr)
    raise SystemExit(EXIT_REFUSED)


def routing_root():
    """The routing directory, anchored on $HOME and nothing else.

    Returns None when no routing file can exist at all, which is an ABSENCE
    (execute locally), not a corruption.
    """
    override = os.environ.get("FM_AZURE_RUNNER_ROUTING_ROOT")
    if override:
        return Path(override)
    home = os.environ.get("HOME")
    if not home:
        return None
    return Path(home) / ".fm-azure" / "runner-routing"


def check_provenance(path, root):
    """The file and every directory up to the routing root must be ours.

    A routing file authorizes billable compute, so it is held to the same
    standard as credential material: no symlink anywhere on the path, owned by
    the invoking user, and never group- or world-writable.
    """
    checked = []
    current = path
    root = root.resolve() if root.exists() else root
    while True:
        checked.append(current)
        if current.parent == current:
            break
        if current.resolve(strict=False) == root:
            break
        current = current.parent
        if len(checked) > 64:
            refuse("routing path is implausibly deep: {}".format(path))
    for item in checked:
        try:
            info = item.lstat()
        except OSError as exc:
            refuse("routing path component {} is unreadable: {}".format(item, exc.strerror))
        if stat.S_ISLNK(info.st_mode):
            refuse("routing path component {} is a symlink".format(item))
        if info.st_uid != os.geteuid():
            refuse(
                "routing path component {} is owned by uid {}, not the invoking uid {}".format(
                    item, info.st_uid, os.geteuid()
                )
            )
        if info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            refuse("routing path component {} is group- or world-writable".format(item))


def known_resource_classes():
    """The runner's own class table, imported rather than mirrored.

    A hardcoded copy would drift; importing means a class this file accepts is
    exactly a class the runner can run. An unimportable runner REFUSES, because
    a routing file is present and its selection cannot be validated.
    """
    module_path = Path(__file__).resolve().parent / "fm-azure-runner.py"
    try:
        spec = importlib.util.spec_from_file_location("fm_azure_runner", module_path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        classes = set(module.RESOURCE_CLASSES)
    except Exception as exc:  # noqa: BLE001 - any import failure must fail closed
        refuse("the runner's resource-class table is unreadable ({}): {}".format(module_path, exc))
    if not classes:
        refuse("the runner declares no resource classes")
    return classes


def parse_utc(value, label):
    try:
        stamp = dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except (AttributeError, TypeError, ValueError):
        refuse("{} is not an exact UTC timestamp: {!r}".format(label, value))
    if stamp.tzinfo is None:
        refuse("{} carries no timezone: {!r}".format(label, value))
    return stamp


def load_document(path):
    """Read and structurally validate. Any failure past existence is a refusal."""
    try:
        raw = path.read_bytes()
    except OSError as exc:
        refuse("routing file {} is unreadable: {}".format(path, exc.strerror))
    if not raw.strip():
        refuse("routing file {} is empty, which is what a torn write looks like".format(path))
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        refuse(
            "routing file {} is not valid JSON ({}); a partially written file is refused "
            "rather than half-applied".format(path, exc)
        )
    if not isinstance(value, dict):
        refuse("routing file {} is not a JSON object".format(path))
    missing = [name for name in REQUIRED if name not in value]
    if missing:
        refuse("routing file {} is missing required field(s): {}".format(path, ", ".join(missing)))
    if value.get("schema") != SCHEMA:
        refuse(
            "routing file {} declares schema {!r}, not {!r}".format(path, value.get("schema"), SCHEMA)
        )
    return value


def validate(value, path, run_id, command_class):
    if value.get("run_id") != run_id:
        refuse(
            "routing file {} is bound to run {!r}, not the run being executed ({!r})".format(
                path, value.get("run_id"), run_id
            )
        )
    classes = value.get("classes")
    if not isinstance(classes, dict) or not classes:
        refuse("routing file {} declares no class selections".format(path))
    for name, resource in classes.items():
        if not isinstance(name, str) or not COMMAND_CLASS.match(name):
            refuse("routing file {} declares an invalid command class {!r}".format(path, name))
        if not isinstance(resource, str):
            refuse("routing file {} maps class {!r} to a non-string resource class".format(path, name))
    if not SUBSCRIPTION.match(str(value.get("subscription", ""))):
        refuse("routing file {} declares no exact subscription id".format(path))
    max_dispatches = value.get("max_dispatches")
    if not isinstance(max_dispatches, int) or isinstance(max_dispatches, bool) or max_dispatches < 1:
        refuse("routing file {} declares a max_dispatches that is not a positive whole number".format(path))
    dispatched = value.get("dispatched", 0)
    if not isinstance(dispatched, int) or isinstance(dispatched, bool) or dispatched < 0:
        refuse("routing file {} declares a dispatched count that is not a whole number".format(path))
    expires = parse_utc(value.get("expires_at"), "expires_at")
    now = dt.datetime.now(dt.timezone.utc)
    if expires <= now:
        refuse(
            "routing file {} expired at {}; a selection that outlives its window is refused "
            "rather than reused".format(path, value.get("expires_at"))
        )
    if dispatched >= max_dispatches:
        refuse(
            "routing file {} has spent its dispatch budget ({} of {})".format(
                path, dispatched, max_dispatches
            )
        )
    # Only now, once the file is known good, does an unselected class mean local.
    if command_class not in classes:
        return None
    resource_class = classes[command_class]
    if resource_class not in known_resource_classes():
        refuse(
            "routing file {} selects class {!r} onto unknown resource class {!r}".format(
                path, command_class, resource_class
            )
        )
    fm_home = value.get("fm_home")
    if not isinstance(fm_home, str) or not fm_home.startswith("/"):
        refuse("routing file {} declares no absolute fm_home".format(path))
    home_path = Path(fm_home)
    if home_path.is_symlink():
        refuse("routing file {} declares an fm_home that is a symlink".format(path))
    if not home_path.is_dir():
        refuse(
            "routing file {} declares fm_home {!r}, which is not an existing directory; it is "
            "never defaulted because it selects which spend ledger the run writes to".format(
                path, fm_home
            )
        )
    user_home = os.environ.get("HOME")
    if user_home:
        try:
            home_path.resolve().relative_to(Path(user_home).resolve())
        except ValueError:
            refuse(
                "routing file {} declares fm_home {!r} outside {}".format(path, fm_home, user_home)
            )
    return resource_class


def consume(path, value):
    """Spend one dispatch from the budget, durably, under an exclusive lock."""
    updated = dict(value)
    updated["dispatched"] = int(value.get("dispatched", 0)) + 1
    temporary = path.with_name(path.name + ".tmp-{}".format(os.getpid()))
    try:
        handle = os.open(path, os.O_RDWR)
    except OSError as exc:
        refuse("routing file {} could not be locked: {}".format(path, exc.strerror))
    try:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX)
        except OSError as exc:
            refuse("routing file {} could not be locked: {}".format(path, exc.strerror))
        try:
            temporary.write_text(json.dumps(updated, sort_keys=True, indent=2) + "\n", encoding="utf-8")
            os.chmod(temporary, 0o600)
            os.replace(temporary, path)
        except OSError as exc:
            refuse("routing file {} could not record its spent dispatch: {}".format(path, exc.strerror))
    finally:
        os.close(handle)
        try:
            temporary.unlink()
        except OSError as exc:
            if exc.errno != errno.ENOENT:
                raise
    return updated


def resolve(args):
    if not RUN_ID.match(args.run_id):
        print("azure-runner routing: run id is malformed", file=sys.stderr)
        return EXIT_USAGE
    if not COMMAND_CLASS.match(args.command_class):
        print("azure-runner routing: command class is malformed", file=sys.stderr)
        return EXIT_USAGE
    root = routing_root()
    if root is None:
        return EXIT_ABSENT
    path = root / (args.run_id + ".json")
    try:
        path.lstat()
    except OSError as exc:
        if exc.errno == errno.ENOENT:
            return EXIT_ABSENT
        refuse("routing file {} is unreadable: {}".format(path, exc.strerror))
    check_provenance(path, root)
    value = load_document(path)
    resource_class = validate(value, path, args.run_id, args.command_class)
    if resource_class is None:
        return EXIT_NOT_SELECTED
    updated = consume(path, value)
    remaining = int(updated["max_dispatches"]) - int(updated["dispatched"])
    print("resource_class={}".format(resource_class))
    print("fm_home={}".format(value["fm_home"]))
    print("subscription={}".format(value["subscription"]))
    print("dispatches_remaining={}".format(remaining))
    return EXIT_SELECTED


def main():
    parser = argparse.ArgumentParser(add_help=True)
    commands = parser.add_subparsers(dest="command", required=True)
    resolve_parser = commands.add_parser("resolve")
    resolve_parser.add_argument("--run-id", required=True)
    resolve_parser.add_argument("--class", dest="command_class", required=True)
    args = parser.parse_args()
    if args.command == "resolve":
        return resolve(args)
    return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main())
