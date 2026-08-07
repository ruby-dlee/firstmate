#!/usr/bin/env bash
# Run or verify the independent exact-head crosscheck ledger for a task PR.
#
# Usage:
#   fm-crosscheck.sh run <task-id> <full GitHub PR URL>
#   fm-crosscheck.sh verify <task-id> <full GitHub PR URL>
#   fm-crosscheck.sh merge <task-id> <full GitHub PR URL> <reviewed SHA> <method>
#
# `run` is intentionally independent of no-mistakes so both reviews can be in
# flight together once a PR exists. `verify` is the merge-gate operation: it
# re-reads live GitHub state, requires the latest attempt for that exact head
# and claims document to be clear, and prints only the reviewed SHA.
# `merge` repeats that verification and is the sole entrypoint to the private
# exact-SHA GitHub merge primitive.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent

# Pick an interpreter that satisfies this gate's bounded-parsing contract.
# `python3` is 3.9 on stock macOS, where CPython applies no integer-literal
# bound, so a hostile artifact parses unbounded. Refuse rather than review with
# weaker bounds than the gate documents.
FM_CROSSCHECK_MIN_PYTHON="3.11"
fm_python_is_supported() {
  "$1" -c 'import sys
minimum = tuple(int(part) for part in sys.argv[1].split("."))
raise SystemExit(0 if sys.version_info >= minimum else 1)' \
    "$FM_CROSSCHECK_MIN_PYTHON" >/dev/null 2>&1
}

# An explicit pin is honoured or refused, never quietly replaced: substituting a
# different interpreter for the one an operator named is the same silent
# degradation this gate exists to make impossible.
interpreter=""
pinned="${FM_CROSSCHECK_PYTHON:-}"
if [ -n "$pinned" ]; then
  if ! command -v "$pinned" >/dev/null 2>&1; then
    printf 'CROSSCHECK UNREVIEWED: FM_CROSSCHECK_PYTHON=%s names no runnable command; %s\n' \
      "$pinned" \
      "point it at a Python $FM_CROSSCHECK_MIN_PYTHON or newer interpreter, or unset it to select one" >&2
    exit 1
  fi
  if ! fm_python_is_supported "$pinned"; then
    printf 'CROSSCHECK UNREVIEWED: FM_CROSSCHECK_PYTHON=%s did not report Python %s or newer; %s\n' \
      "$pinned" "$FM_CROSSCHECK_MIN_PYTHON" \
      'the gate refuses rather than silently reviewing under an interpreter nobody pinned' >&2
    exit 1
  fi
  interpreter=$pinned
else
  for candidate in python3.14 python3.13 python3.12 python3.11 python3; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    if fm_python_is_supported "$candidate"; then
      interpreter=$candidate
      break
    fi
  done
fi

if [ -z "$interpreter" ]; then
  printf 'CROSSCHECK UNREVIEWED: no Python %s or newer interpreter is available; %s\n' \
    "$FM_CROSSCHECK_MIN_PYTHON" \
    'install one or set FM_CROSSCHECK_PYTHON to its path' >&2
  exit 1
fi

exec "$interpreter" "$SCRIPT_DIR/fm-crosscheck.py" "$@"
