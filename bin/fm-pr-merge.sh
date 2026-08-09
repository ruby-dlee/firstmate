#!/usr/bin/env bash
# Preflight a task's PR only when one unchanged head passes synchronous
# five-part admission and a clear independent crosscheck ledger covers that
# exact head and PR claims, while always recording pr= and the exact live
# pr_head=.
#
# Why this exists: the normal trigger for running fm-pr-check.sh is the crewmate's
# `done: PR <url> checks green` line, which no-mistakes only emits once its CI
# step turns green. Repos that intentionally run no CI on PRs (CI only on
# pushes to the default branch) never emit that line, so a merge performed by
# hand-running `gh-axi pr merge` - the common shape of a yolo-authorized merge -
# can skip the recording step entirely. Teardown then has nothing to look up for
# a squash-merge-then-delete-branch flow and false-refuses provably landed work.
# This script makes recording and crosscheck verification part of the sole
# admitted merge-attempt preflight, so neither can be skipped by omission.
# Use it for every PR merge attempt; it currently never executes one.
#
# The script rejects every armed/scheduled mode, synchronously requires a green
# settled check set, exact-head approvals, content containment, a zero-byte
# worktree residual, and an independent adversarial verdict, then refuses before
# the merge API because GitHub may enqueue even an immediate request and no
# server transaction binds every later check plus local writer custody.
#
# Merge method defaults to squash. Only --squash, --merge, --rebase, and
# --method are accepted; they describe the refused future atomic operation.
#
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <method>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
# shellcheck source=bin/fm-pr-evidence-lib.sh
. "$SCRIPT_DIR/fm-pr-evidence-lib.sh"

ID=${1:?usage: fm-pr-merge.sh <task-id> <pr-url> [-- <atomic merge options>]}
URL=${2:?usage: fm-pr-merge.sh <task-id> <pr-url> [-- <atomic merge options>]}
shift 2
[ "${1:-}" = "--" ] && shift

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META; refusing to merge without recording pr=" >&2; exit 1; }

parse_pr_url() {
  local url=$1
  if [[ "$url" =~ ^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]+)/pull/([0-9]+)/?$ ]]; then
    if [[ "${BASH_REMATCH[1]}" != *- ]]; then
      return 0
    fi
  fi
  echo "error: PR URL must match https://github.com/<owner>/<repo>/pull/<number> (got: $url)" >&2
  return 1
}

parse_pr_url "$URL" || exit 1

MERGE_METHOD=squash
while [ "$#" -gt 0 ]; do
  case "$1" in
    --squash) MERGE_METHOD=squash ;;
    --merge) MERGE_METHOD=merge ;;
    --rebase) MERGE_METHOD=rebase ;;
    --method)
      [ "$#" -ge 2 ] || { echo "error: --method requires a value" >&2; exit 1; }
      MERGE_METHOD=$2
      shift
      ;;
    --method=*) MERGE_METHOD=${1#--method=} ;;
    --repo|--repo=*|-R|-R?*)
      echo "error: extra merge args must not override the repository parsed from the PR URL (got: $1)" >&2
      exit 1
      ;;
    --auto|--queue|--admin|--delete-branch)
      echo "error: $1 is incompatible with an immediate atomic expected-head merge" >&2
      exit 1
      ;;
    *)
      echo "error: unsupported atomic merge argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

case "$MERGE_METHOD" in
  merge|squash|rebase) ;;
  *) echo "error: merge method must be merge, squash, or rebase" >&2; exit 1 ;;
esac

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || { echo "error: fm-pr-check did not record pr=$URL in $META; refusing to merge" >&2; exit 1; }

REVIEWED_HEAD=$("$SCRIPT_DIR/fm-crosscheck.sh" verify "$ID" "$URL") || exit 1
[[ "$REVIEWED_HEAD" =~ ^[0-9a-f]{40}$ ]] || {
  echo "error: crosscheck did not return one exact reviewed SHA" >&2
  exit 1
}
grep -qxF "pr_head=$REVIEWED_HEAD" "$META" || {
  echo "error: fm-pr-check did not record the reviewed live head in $META" >&2
  exit 1
}

ADMISSION=$("$SCRIPT_DIR/fm-pr-admit.sh" "$ID" "$URL") || exit 1
case "$ADMISSION" in
  "admitted: head=$REVIEWED_HEAD "*) ;;
  admitted:\ head=*)
    echo "error: exact-head admission moved away from independently reviewed head $REVIEWED_HEAD" >&2
    exit 1
    ;;
  *)
    echo "error: exact-head admission returned no deterministic receipt" >&2
    exit 1
    ;;
esac
# GitHub can turn even an immediate REST merge into a merge-queue entry, and no
# server transaction binds arbitrary later checks plus local writer custody to
# that request. Refuse before the API call rather than leaving future execution
# armed. This boundary is intentionally unconditional until that authority exists.
fm_pr_require_atomic_merge_boundary "$MERGE_METHOD"
exit 1
