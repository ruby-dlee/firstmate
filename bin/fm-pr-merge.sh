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
# Merge method: defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. An explicit
# caller method is never overridden.
# Merge success means GitHub independently reports the PR state as merged after
# the merge command returns.
# Merge queue acceptance, auto-merge enablement, or any other still-open state
# exits non-zero and reports the observed state instead of success.
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

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

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
  printf '%s\n' squash
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

verify_pr_merged() {
  local view state
  if ! view=$(gh-axi pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" 2>&1); then
    printf 'merge:\n  number: %s\n  status: unknown\n  observed_state: unavailable\n  method: %s\n' \
      "$PR_NUMBER" "$MERGE_METHOD_LABEL"
    echo "error: gh-axi pr merge returned success, but GitHub merge verification failed for $PR_OWNER/$PR_REPO#$PR_NUMBER" >&2
    printf '%s\n' "$view" >&2
    return 1
  fi
  state=$(printf '%s\n' "$view" | sed -n 's/^[[:space:]]*state:[[:space:]]*//p' | head -1)
  state=${state#\"}
  state=${state%\"}
  case "$state" in
    merged|MERGED)
      printf 'merged:\n  number: %s\n  status: ok\n  method: %s\n  observed_state: merged\n' \
        "$PR_NUMBER" "$MERGE_METHOD_LABEL"
      return 0
      ;;
    open|OPEN)
      printf 'merge:\n  number: %s\n  status: enqueued\n  observed_state: open\n  method: %s\n' \
        "$PR_NUMBER" "$MERGE_METHOD_LABEL"
      echo "error: gh-axi pr merge returned success, but GitHub still reports $PR_OWNER/$PR_REPO#$PR_NUMBER as open; treating it as enqueued/unconfirmed, not merged" >&2
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

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi
MERGE_METHOD_LABEL=$(merge_method_label ${merge_args[@]+"${merge_args[@]}"} "$@")

if ! MERGE_OUTPUT=$(gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" ${merge_args[@]+"${merge_args[@]}"} "$@" 2>&1); then
  printf '%s\n' "$MERGE_OUTPUT"
  exit 1
fi
verify_pr_merged
