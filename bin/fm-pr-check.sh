#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> and GitHub's pr_head=<sha> to
# state/<id>.meta when available, then arms the watcher's merge poll by writing
# state/<id>.check.sh, which prints one line iff the PR is merged (the watcher's
# check contract: output = wake firstmate, silence = keep sleeping).
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
# shellcheck source=bin/fm-account-routing-lib.sh
. "$SCRIPT_DIR/fm-account-routing-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
URL=$2

META="$STATE/$ID.meta"
LOOKUP_WT=
LOOKUP_GENERATION=
PR_HEAD=
META_LOCK=$(fm_account_meta_lock_acquire "$STATE" "$ID") || exit 1
if [ ! -f "$META" ]; then
  fm_account_meta_lock_release "$META_LOCK"
  echo "error: no task metadata for $ID" >&2
  exit 1
fi
LOOKUP_WT=$(fm_account_meta_value "$META" worktree)
LOOKUP_GENERATION=$(fm_account_meta_value "$META" generation_id)
if [ -z "$LOOKUP_GENERATION" ]; then
  LEGACY_ATTEMPT=$(fm_account_attempt_id "$FM_HOME" "$ID") || {
    fm_account_meta_lock_release "$META_LOCK"
    exit 1
  }
  LOOKUP_GENERATION="legacy:$LEGACY_ATTEMPT"
  META_TMP=$(mktemp "$STATE/.$ID.meta.generation.XXXXXX") || {
    fm_account_meta_lock_release "$META_LOCK"
    exit 1
  }
  if ! awk '{ print }' "$META" > "$META_TMP" \
    || ! printf 'generation_id=%s\n' "$LOOKUP_GENERATION" >> "$META_TMP" \
    || ! fm_account_safe_file_destination "$META" \
    || ! mv "$META_TMP" "$META"; then
    rm -f "$META_TMP"
    fm_account_meta_lock_release "$META_LOCK"
    echo "error: could not backfill legacy task generation for $ID" >&2
    exit 1
  fi
fi
fm_account_meta_lock_release "$META_LOCK"
if [ -n "$LOOKUP_WT" ] && [ -d "$LOOKUP_WT" ]; then
  if command -v gh >/dev/null 2>&1; then
    if REMOTE_HEAD=$(cd "$LOOKUP_WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null); then
      PR_HEAD=$REMOTE_HEAD
    fi
  fi
fi
META_LOCK=$(fm_account_meta_lock_acquire "$STATE" "$ID") || exit 1
release_meta_lock() {
  fm_account_meta_lock_release "$META_LOCK" >/dev/null 2>&1 || true
}
trap release_meta_lock EXIT
if [ -f "$META" ]; then
  CURRENT_WT=$(fm_account_meta_value "$META" worktree)
  CURRENT_GENERATION=$(fm_account_meta_value "$META" generation_id)
  if [ "$CURRENT_GENERATION" != "$LOOKUP_GENERATION" ] || [ "$CURRENT_WT" != "$LOOKUP_WT" ]; then
    echo "error: task generation changed while resolving PR state for $ID" >&2
    exit 1
  fi
  if ! grep -qxF "pr=$URL" "$META"; then
    echo "pr=$URL" >> "$META"
  fi
  if [ -n "$PR_HEAD" ] && [ "$CURRENT_WT" = "$LOOKUP_WT" ] && ! grep -qxF "pr_head=$PR_HEAD" "$META"; then
    echo "pr_head=$PR_HEAD" >> "$META"
  fi
else
  echo "error: task metadata disappeared while resolving PR state for $ID" >&2
  exit 1
fi
CHECK_TMP=$(mktemp "$STATE/.$ID.check.XXXXXX") || exit 1
cat > "$CHECK_TMP" <<EOF
state=\$(gh pr view "$URL" --json state -q .state 2>/dev/null)
[ "\$state" = "MERGED" ] && echo "merged"
EOF
chmod +x "$CHECK_TMP"
mv "$CHECK_TMP" "$STATE/$ID.check.sh"
fm_account_meta_lock_release "$META_LOCK"
trap - EXIT
echo "armed: state/$ID.check.sh polls $URL"
