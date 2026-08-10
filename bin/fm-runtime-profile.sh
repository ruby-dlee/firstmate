#!/usr/bin/env bash
# Verify one task's runtime profile from the harness's own execution record.
# Usage: fm-runtime-profile.sh <task-id>
# Exit 0 = verified/not applicable, 1 = mismatch, 2 = unverifiable.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ID=${1:?usage: fm-runtime-profile.sh <task-id>}
META="$STATE/$ID.meta"

# shellcheck source=bin/fm-account-routing-lib.sh
. "$SCRIPT_DIR/fm-account-routing-lib.sh"

[ -f "$META" ] && [ ! -L "$META" ] || {
  echo "unknown: no safe task metadata for $ID" >&2
  exit 2
}
HARNESS=$(fm_account_meta_value "$META" harness)
if [ "$HARNESS" != codex ]; then
  echo "not-applicable: harness=$HARNESS"
  exit 0
fi
MODEL=$(fm_account_meta_value "$META" model)
EFFORT=$(fm_account_meta_value "$META" effort)
WORKTREE=$(fm_account_meta_value "$META" worktree)
CODEX_RUNTIME_HOME=$(fm_account_meta_value "$META" runtime_home)
RUNTIME_STARTED_AT_NS=$(fm_account_meta_value "$META" runtime_started_at_ns)
PROVIDER_SESSION=$(fm_account_meta_value "$META" provider_session_id)
[ -n "$PROVIDER_SESSION" ] || {
  echo "unknown: Codex runtime profile UNVERIFIED because provider session identity is unavailable for $ID" >&2
  exit 2
}

if [ "$MODEL" != gpt-5.6-sol ] || [ "$EFFORT" != xhigh ]; then
  echo "mismatch: recorded Codex profile model=${MODEL:-default} effort=${EFFORT:-default}; expected model=gpt-5.6-sol effort=xhigh" >&2
  exit 1
fi
[ -d "$WORKTREE" ] && [ ! -L "$WORKTREE" ] || {
  echo "unknown: Codex worktree is unavailable for $ID" >&2
  exit 2
}
[ -d "$CODEX_RUNTIME_HOME" ] && [ ! -L "$CODEX_RUNTIME_HOME" ] || {
  echo "unknown: Codex runtime home is unavailable for $ID" >&2
  exit 2
}
case "$RUNTIME_STARTED_AT_NS" in
  ''|*[!0-9]*)
    echo "unknown: Codex runtime start identity is unavailable for $ID" >&2
    exit 2
    ;;
esac

node "$SCRIPT_DIR/fm-codex-runtime-profile.mjs" \
  "$CODEX_RUNTIME_HOME" "$WORKTREE" gpt-5.6-sol xhigh \
  "$PROVIDER_SESSION" "$RUNTIME_STARTED_AT_NS"
