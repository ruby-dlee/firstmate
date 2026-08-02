#!/usr/bin/env bash
# Merge a task's PR, always recording pr= and any available pr_head= into
# state/<id>.meta first via bin/fm-pr-check.sh, so bin/fm-teardown.sh's
# landed-check has a PR reference to verify a squash merge against.
#
# Why this exists: the normal trigger for running fm-pr-check.sh is the crewmate's
# `done: PR <url> checks green` line, which no-mistakes only emits once its CI
# step turns green. Repos that intentionally run no CI on PRs (CI only on
# pushes to the default branch) never emit that line, so a merge performed by
# hand-running `gh-axi pr merge` - the common shape of a yolo-authorized merge -
# can skip the recording step entirely. Teardown then has nothing to look up for
# a squash-merge-then-delete-branch flow and false-refuses provably landed work.
# This script makes recording part of the merge itself, so it cannot be skipped
# by omission. Use it for every PR merge (captain-requested or yolo-authorized),
# in place of calling `gh-axi pr merge` directly.
#
# gh-axi pr merge expects a PR number and --repo <owner>/<repo>; it does not
# parse a full https://github.com/<owner>/<repo>/pull/<n> URL. This script
# parses the URL and invokes gh-axi in the form it accepts.
#
# Merge method: when the caller passes none of --squash, --merge, --rebase, or
# --method after the optional -- separator, no method is added. This lets a
# GitHub merge queue select its configured strategy. An explicit caller method
# is forwarded unchanged.
# Merge success means GitHub independently reports the PR state as merged after
# the merge command returns.
# Merge queue acceptance, auto-merge enablement, or any other still-open state
# exits non-zero and reports the observed state instead of success.
# Draft status is checked only after fm-pr-check.sh records the PR and available
# head, then drafts are refused with an actionable error before merge is called.
# Extra args must not include --repo or -R because the repo is parsed from the
# PR URL.
#
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent

ID=${1:?usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]}
URL=${2:?usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]}
shift 2
[ "${1:-}" = "--" ] && shift

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META; refusing to merge without recording pr=" >&2; exit 1; }

merge_method_label() {
  local arg previous=
  for arg in "$@"; do
    if [ "$previous" = method ]; then
      printf '%s\n' "$arg"
      return 0
    fi
    case "$arg" in
      --squash) printf '%s\n' squash; return 0 ;;
      --merge) printf '%s\n' merge; return 0 ;;
      --rebase) printf '%s\n' rebase; return 0 ;;
      --method=*) printf '%s\n' "${arg#--method=}"; return 0 ;;
      --method) previous=method ;;
      *) previous= ;;
    esac
  done
  printf '%s\n' default
}

parse_pr_url() {
  local url=$1
  if [[ "$url" =~ ^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]+)/pull/([0-9]+)/?$ ]]; then
    PR_OWNER="${BASH_REMATCH[1]}"
    PR_REPO="${BASH_REMATCH[2]}"
    PR_NUMBER="${BASH_REMATCH[3]}"
    if [[ "$PR_OWNER" != *- ]]; then
      return 0
    fi
  fi
  echo "error: PR URL must match https://github.com/<owner>/<repo>/pull/<number> (got: $url)" >&2
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge args must not override --repo parsed from PR URL (got: $arg)" >&2
        return 1
        ;;
    esac
  done
  return 0
}

toon_scalar() {
  local field=$1 input=$2 value
  value=$(printf '%s\n' "$input" | sed -n "s/^[[:space:]]*$field:[[:space:]]*//p" | head -1)
  value=${value#\"}
  value=${value%\"}
  printf '%s\n' "$value"
}

refuse_draft_pr() {
  local view draft
  if ! view=$(gh-axi pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" 2>&1); then
    echo "error: could not inspect $PR_OWNER/$PR_REPO#$PR_NUMBER for draft status; refusing to merge" >&2
    printf '%s\n' "$view" >&2
    return 1
  fi
  draft=$(toon_scalar draft "$view")
  case "$draft" in
    yes|YES|true|TRUE)
      echo "error: refusing to merge $PR_OWNER/$PR_REPO#$PR_NUMBER because it is a draft; run gh-axi pr ready $PR_NUMBER --repo $PR_OWNER/$PR_REPO once it is ready for review" >&2
      return 1
      ;;
    no|NO|false|FALSE) return 0 ;;
    *)
      echo "error: gh-axi pr view did not report draft status for $PR_OWNER/$PR_REPO#$PR_NUMBER; refusing to merge" >&2
      return 1
      ;;
  esac
}

pending_merge_status() {
  local output=$1 status kind
  status=$(toon_scalar status "$output")
  kind=$(printf '%s\n' "$output" | sed -n 's/^\([[:alpha:]_-]*\):[[:space:]]*$/\1/p' | head -1)
  case "$status" in
    enqueued|ENQUEUED) printf '%s\n' enqueued; return 0 ;;
    accepted|ACCEPTED) printf '%s\n' accepted; return 0 ;;
    queued|QUEUED) printf '%s\n' queued; return 0 ;;
  esac
  case "$kind" in
    enqueued|ENQUEUED) printf '%s\n' enqueued ;;
    accepted|ACCEPTED) printf '%s\n' accepted ;;
    queued|QUEUED) printf '%s\n' queued ;;
    *) printf '%s\n' enqueued ;;
  esac
}

verify_pr_merged() {
  local view state pending_status
  if ! view=$(gh-axi pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" 2>&1); then
    printf 'merge:\n  number: %s\n  status: unknown\n  observed_state: unavailable\n  method: %s\n' \
      "$PR_NUMBER" "$MERGE_METHOD_LABEL"
    echo "error: gh-axi pr merge returned success, but GitHub merge verification failed for $PR_OWNER/$PR_REPO#$PR_NUMBER" >&2
    printf '%s\n' "$view" >&2
    return 1
  fi
  state=$(toon_scalar state "$view")
  case "$state" in
    merged|MERGED)
      printf 'merged:\n  number: %s\n  status: ok\n  method: %s\n  observed_state: merged\n' \
        "$PR_NUMBER" "$MERGE_METHOD_LABEL"
      return 0
      ;;
    open|OPEN)
      pending_status=$(pending_merge_status "$MERGE_OUTPUT")
      printf 'merge:\n  number: %s\n  status: %s\n  observed_state: open\n  method: %s\n' \
        "$PR_NUMBER" "$pending_status" "$MERGE_METHOD_LABEL"
      echo "error: merge request was $pending_status, but GitHub still reports $PR_OWNER/$PR_REPO#$PR_NUMBER as open; it is not verified merged" >&2
      return 1
      ;;
    closed|CLOSED)
      printf 'merge:\n  number: %s\n  status: closed\n  observed_state: closed\n  method: %s\n' \
        "$PR_NUMBER" "$MERGE_METHOD_LABEL"
      echo "error: gh-axi pr merge returned success, but GitHub reports $PR_OWNER/$PR_REPO#$PR_NUMBER as closed without a confirmed merge" >&2
      return 1
      ;;
    "")
      printf 'merge:\n  number: %s\n  status: unknown\n  observed_state: unavailable\n  method: %s\n' \
        "$PR_NUMBER" "$MERGE_METHOD_LABEL"
      echo "error: gh-axi pr merge returned success, but gh-axi pr view did not report a PR state for $PR_OWNER/$PR_REPO#$PR_NUMBER" >&2
      return 1
      ;;
    *)
      printf 'merge:\n  number: %s\n  status: unconfirmed\n  observed_state: %s\n  method: %s\n' \
        "$PR_NUMBER" "$state" "$MERGE_METHOD_LABEL"
      echo "error: gh-axi pr merge returned success, but GitHub did not confirm $PR_OWNER/$PR_REPO#$PR_NUMBER as merged" >&2
      return 1
      ;;
  esac
}

parse_pr_url "$URL" || exit 1
reject_repo_overrides "$@" || exit 1

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || { echo "error: fm-pr-check did not record pr=$URL in $META; refusing to merge" >&2; exit 1; }
refuse_draft_pr || exit 1

MERGE_METHOD_LABEL=$(merge_method_label "$@")

if ! MERGE_OUTPUT=$(gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "$@" 2>&1); then
  printf '%s\n' "$MERGE_OUTPUT"
  exit 1
fi
verify_pr_merged
