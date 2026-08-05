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
  "$1" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' \
    >/dev/null 2>&1
}

interpreter=""
for candidate in "${FM_CROSSCHECK_PYTHON:-}" python3.14 python3.13 python3.12 python3.11 python3; do
  [ -n "$candidate" ] || continue
  command -v "$candidate" >/dev/null 2>&1 || continue
  if fm_python_is_supported "$candidate"; then
    interpreter=$candidate
    break
  fi
done

if [ -z "$interpreter" ]; then
  printf 'CROSSCHECK UNREVIEWED: no Python %s or newer interpreter is available; %s\n' \
    "$FM_CROSSCHECK_MIN_PYTHON" \
    'install one or set FM_CROSSCHECK_PYTHON to its path' >&2
  exit 1
fi

exec "$interpreter" "$SCRIPT_DIR/fm-crosscheck.py" "$@"
