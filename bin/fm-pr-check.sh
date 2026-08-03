#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> and GitHub's exact pr_head=<sha> to
# state/<id>.meta.
# This command deliberately never creates or replaces state/<id>.check.sh.
# A merge poll armed future execution and overwrote task-owned custom checks;
# merge admission is now synchronous in fm-pr-merge.sh.
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
if [[ "$URL" =~ ^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]+)/pull/([0-9]+)/?$ ]] \
  && [[ "${BASH_REMATCH[1]}" != *- ]]; then
  PR_OWNER=${BASH_REMATCH[1]}
  PR_REPO=${BASH_REMATCH[2]}
  PR_NUMBER=${BASH_REMATCH[3]}
else
  echo "error: PR URL must match https://github.com/<owner>/<repo>/pull/<number> (got: $URL)" >&2
  exit 1
fi
META_LOCK=$(fm_account_meta_lock_acquire "$STATE" "$ID") || exit 1
if [ ! -f "$META" ] || [ -L "$META" ]; then
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
REMOTE_PR=$(gh-axi api "/repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER") || {
  echo "error: could not read PR $URL through gh-axi" >&2
  exit 1
}
PR_HEAD=$(printf '%s\n' "$REMOTE_PR" | awk '
  /^head:$/ { in_head = 1; next }
  /^base:$/ { in_head = 0 }
  in_head && $1 == "sha:" { gsub(/"/, "", $2); print $2; exit }
')
case "$PR_HEAD" in
  ????????????????????????????????????????)
    case "$PR_HEAD" in *[!0-9a-fA-F]*) echo "error: GitHub returned a non-hex PR head for $URL" >&2; exit 1 ;; esac
    ;;
  *) echo "error: GitHub returned no exact 40-character PR head for $URL" >&2; exit 1 ;;
esac
META_LOCK=$(fm_account_meta_lock_acquire "$STATE" "$ID") || exit 1
release_meta_lock() {
  fm_account_meta_lock_release "$META_LOCK" >/dev/null 2>&1 || true
}
trap release_meta_lock EXIT
if [ -f "$META" ] && [ ! -L "$META" ]; then
  CURRENT_WT=$(fm_account_meta_value "$META" worktree)
  CURRENT_GENERATION=$(fm_account_meta_value "$META" generation_id)
  if [ "$CURRENT_GENERATION" != "$LOOKUP_GENERATION" ] || [ "$CURRENT_WT" != "$LOOKUP_WT" ]; then
    echo "error: task generation changed while resolving PR state for $ID" >&2
    exit 1
  fi
  META_TMP=$(mktemp "$STATE/.$ID.meta.pr.XXXXXX") || exit 1
  if ! awk -F= '$1 != "pr" && $1 != "pr_head" { print }' "$META" > "$META_TMP" \
    || ! printf 'pr=%s\npr_head=%s\n' "$URL" "$PR_HEAD" >> "$META_TMP" \
    || ! fm_account_safe_file_destination "$META" \
    || ! mv "$META_TMP" "$META"; then
    rm -f "$META_TMP"
    echo "error: could not atomically record exact PR state for $ID" >&2
    exit 1
  fi
else
  echo "error: task metadata disappeared while resolving PR state for $ID" >&2
  exit 1
fi
fm_account_meta_lock_release "$META_LOCK"
trap - EXIT
echo "recorded: $URL head=$PR_HEAD (no merge was armed; custom task check preserved)"
