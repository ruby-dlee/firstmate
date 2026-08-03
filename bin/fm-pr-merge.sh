#!/usr/bin/env bash
# Synchronously admit and merge one task PR without arming future execution.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <method>]
# Supported methods: --squash (default), --merge, --rebase, --method=<value>.
# Scheduling flags are refused.
# The final GitHub merge request carries the admitted head SHA, so a force-push
# between admission and execution fails atomically instead of landing new code.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
# shellcheck source=bin/fm-pr-evidence-lib.sh
. "$SCRIPT_DIR/fm-pr-evidence-lib.sh"

ID=${1:?usage: fm-pr-merge.sh <task-id> <pr-url> [-- <method>]}
URL=${2:?usage: fm-pr-merge.sh <task-id> <pr-url> [-- <method>]}
shift 2
[ "${1:-}" = -- ] && shift

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || { echo "error: no safe meta for task $ID at $META" >&2; exit 1; }

if [[ "$URL" =~ ^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]+)/pull/([0-9]+)/?$ ]] \
  && [[ "${BASH_REMATCH[1]}" != *- ]]; then
  OWNER=${BASH_REMATCH[1]}
  REPO=${BASH_REMATCH[2]}
  NUMBER=${BASH_REMATCH[3]}
else
  echo "error: PR URL must match https://github.com/<owner>/<repo>/pull/<number> (got: $URL)" >&2
  exit 1
fi

METHOD=squash
while [ "$#" -gt 0 ]; do
  case "$1" in
    --squash) METHOD=squash ;;
    --merge) METHOD=merge ;;
    --rebase) METHOD=rebase ;;
    --method)
      shift
      METHOD=${1:?error: --method requires merge, squash, or rebase}
      ;;
    --method=*) METHOD=${1#--method=} ;;
    --auto|--queue|--admin|--delete-branch)
      echo "error: merge scheduling and side-effect flags are forbidden ($1); fm-pr-merge is one-shot only" >&2
      exit 1
      ;;
    --repo|--repo=*|-R|-R?*)
      echo "error: merge args must not override the repository parsed from the PR URL ($1)" >&2
      exit 1
      ;;
    *) echo "error: unsupported merge argument '$1'" >&2; exit 1 ;;
  esac
  shift
done
case "$METHOD" in merge|squash|rebase) ;; *) echo "error: invalid merge method '$METHOD'" >&2; exit 1 ;; esac

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL" >/dev/null
ADMISSION=$("$SCRIPT_DIR/fm-pr-admit.sh" "$ID" "$URL") || exit 1
case "$ADMISSION" in
  admitted:\ head=*) ADMITTED_HEAD=${ADMISSION#admitted: head=}; ADMITTED_HEAD=${ADMITTED_HEAD%% *} ;;
  *) echo "error: admission returned no exact-head receipt" >&2; exit 1 ;;
esac
case "$ADMITTED_HEAD" in
  ????????????????????????????????????????) ;;
  *) echo "error: admission receipt carried an invalid head" >&2; exit 1 ;;
esac
ADMITTED_BASE_REF=${ADMISSION#* base_ref=}
ADMITTED_BASE_REF=${ADMITTED_BASE_REF%% *}
ADMITTED_EVIDENCE=${ADMISSION#* evidence=}
ADMITTED_EVIDENCE=${ADMITTED_EVIDENCE%% *}
[ -n "$ADMITTED_BASE_REF" ] && [ "$ADMITTED_EVIDENCE" = "$FM_PR_ADMISSION_CONTEXT" ] || {
  echo "error: admission receipt carried no server-enforced evidence identity" >&2
  exit 1
}
fm_pr_require_server_admission_rule "$OWNER" "$REPO" "$ADMITTED_BASE_REF" || {
  echo "error: exact-head admission evidence is not required at the server merge boundary" >&2
  exit 1
}

MERGE_DOC=$(gh-axi api PUT "/repos/$OWNER/$REPO/pulls/$NUMBER/merge" \
  --field "sha=$ADMITTED_HEAD" --field "merge_method=$METHOD") || exit 1
MERGED=$(printf '%s\n' "$MERGE_DOC" | sed -n 's/^merged: *//p' | head -1)
[ "$MERGED" = true ] || {
  MESSAGE=$(printf '%s\n' "$MERGE_DOC" | sed -n 's/^message: *//p' | head -1)
  echo "error: GitHub did not merge admitted head $ADMITTED_HEAD (${MESSAGE:-no merge verdict})" >&2
  exit 1
}
printf 'merged: %s exact_head=%s method=%s\n' "$URL" "$ADMITTED_HEAD" "$METHOD"
