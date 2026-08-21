#!/usr/bin/env python3
"""The ONE derivation of the FM_AZURE_* names a cloud placement must persist.

WHY THIS FILE EXISTS. `SPAWN_CLOUD_ENV_ALLOWLIST` in bin/fm-spawn.sh is the set
of variables written into `state/<id>.cloud-env`, which the compartment and
crewmate monitors source in a subshell for every lifecycle call they make. Those
monitors run in Herdr panes whose environment is CLOSED: they inherit nothing
from the operator's shell, so a name missing from that file is unreachable in
production no matter what the operator exported.

The names that file must carry are decided somewhere else entirely - in the code
that READS them on the far side of the pane boundary. Before this module the two
sides learned the set independently, and they drifted: the compartment-child
lane could never create its worker at all, because bin/fm-azure-pilot.sh refuses
`worker-create` without FM_AZURE_TENANT_ID (and six more names) that the
allowlist did not carry. Every hermetic test missed it, because the tests drive
a fixture provider that never shells out to the pilot.

So: this module derives the required set FROM THE READERS, mechanically. The
allowlist stays an explicit literal in bin/fm-spawn.sh (an operator can audit one
line without running anything), and tests/fm-spawn-cloud.test.sh asserts the
PERSISTED FILE against this derivation, so a name added to a reader without
being added to the allowlist goes red.

Regenerate the allowlist literal with:

    bin/fm-cloud-env-contract.py --allowlist

Usage:
  fm-cloud-env-contract.py              one required name per line
  fm-cloud-env-contract.py --allowlist  one space-joined line for bin/fm-spawn.sh
  fm-cloud-env-contract.py --explain    each name with the readers that need it
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# The readers on the far side of the closed pane. Every FM_AZURE_* name any of
# them takes from the environment is a name the persisted file has to be able to
# carry, because the compartment-child lane reaches all three from the monitor:
# fm-spawn.sh -> fm-worker-lifecycle.py -> fm-azure-worker-provider.py ->
# fm-azure-pilot.sh (worker-create). The pilot is the one that was missed: it is
# a SUBPROCESS of the provider, so a grep of the provider alone never saw it.
READERS = (
    "bin/fm-azure-pilot.sh",
    "bin/fm-azure-worker-provider.py",
    "bin/fm-worker-lifecycle.py",
)

# Names the provider SUPPLIES to the pilot itself, per placement, in
# run_pilot_create's env.update. Persisting an operator's copy of these would be
# inert at best and a stale override at worst, so they are subtracted - and they
# are read out of that call rather than listed here, so the subtraction cannot
# drift from it either.
SUPPLIER = "bin/fm-azure-worker-provider.py"

# Reviewed exclusions: a FM_AZURE_* name a reader takes from the environment that
# must still NEVER be written to disk, because its VALUE is a credential (or
# names a file holding one). The allowlist exists for exactly this reason - it is
# not a prefix glob - and this tuple is where that judgment is recorded, one
# entry per name with the reason inline.
#
# Empty today, deliberately: no name any of the READERS takes is secret-bearing.
# The shape to expect is the validation lane's FM_AZURE_VALIDATION_*_KEY_FILE
# pair, which names key material and is excluded here by construction because no
# reader above reads it.
SECRET_BEARING_EXCLUSIONS: tuple[str, ...] = ()

NAME = re.compile(r"FM_AZURE_[A-Z0-9_]+")


class ContractError(RuntimeError):
    pass


def read(relative: str) -> str:
    path = ROOT / relative
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ContractError("reader {} is unreadable: {}".format(relative, exc))


def reader_names() -> dict[str, set[str]]:
    """Every FM_AZURE_* name each reader takes, keyed by name."""
    by_name: dict[str, set[str]] = {}
    for relative in READERS:
        found = set(NAME.findall(read(relative)))
        if not found:
            # A reader that suddenly matches nothing means the derivation broke,
            # not that the lane stopped needing an environment. Fail loudly: a
            # silently empty contract would make the guarding test vacuous.
            raise ContractError(
                "reader {} yielded no FM_AZURE_ names; the derivation is broken".format(relative)
            )
        for name in found:
            by_name.setdefault(name, set()).add(relative)
    return by_name


def provider_supplied() -> set[str]:
    source = read(SUPPLIER)
    match = re.search(r"def run_pilot_create\(.*?env\.update\((\{.*?\})\)", source, re.S)
    if match is None:
        raise ContractError(
            "run_pilot_create's env.update could not be located in {}; "
            "the provider-supplied subtraction cannot be derived".format(SUPPLIER)
        )
    supplied = set(NAME.findall(match.group(1)))
    if not supplied:
        raise ContractError("run_pilot_create supplies no FM_AZURE_ names; the derivation is broken")
    return supplied


def required() -> dict[str, set[str]]:
    by_name = reader_names()
    for name in provider_supplied() | set(SECRET_BEARING_EXCLUSIONS):
        by_name.pop(name, None)
    if not by_name:
        raise ContractError("the derived cloud-env contract is empty; the derivation is broken")
    return by_name


def main(argv: list[str]) -> int:
    mode = argv[1] if len(argv) > 1 else ""
    if mode not in ("", "--allowlist", "--explain"):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    try:
        contract = required()
    except ContractError as exc:
        print("fm-cloud-env-contract: {}".format(exc), file=sys.stderr)
        return 1
    names = sorted(contract)
    if mode == "--allowlist":
        print(" ".join(names))
    elif mode == "--explain":
        for name in names:
            print("{}\t{}".format(name, ",".join(sorted(contract[name]))))
    else:
        for name in names:
            print(name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
