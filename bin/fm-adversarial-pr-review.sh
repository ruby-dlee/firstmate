#!/usr/bin/env bash
# Run or verify Firstmate's independent adversarial PR review lane.
#
# This is the in-house replacement for Bugbot as the fifth merge property.
# It reviews a PR at one exact head SHA, writes an auditable report under
# data/<task-id>/adversarial-review.md, records the clean/blocking verdict in
# state/<task-id>.meta, and refuses merge verification unless the current PR
# head still equals the recorded CLEAN head.
#
# Usage:
#   fm-adversarial-pr-review.sh run <task-id> <pr-url> [--head <sha>]
#   fm-adversarial-pr-review.sh verify <task-id> <pr-url>
#
# Production reviewer selection uses direct account-directory homes so the
# report can prove account isolation without exposing secrets. Test-only runner
# and reviewer overrides require
# FM_ADVERSARIAL_REVIEW_TEST_LAB=firstmate-adversarial-review-test-lab-v1.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
TEST_LAB_TOKEN=firstmate-adversarial-review-test-lab-v1

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
# shellcheck source=bin/fm-account-routing-lib.sh
. "$SCRIPT_DIR/fm-account-routing-lib.sh"

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//' >&2
}

test_lab_enabled() {
  [ "${FM_ADVERSARIAL_REVIEW_TEST_LAB:-}" = "$TEST_LAB_TOKEN" ]
}

die() {
  echo "error: $*" >&2
  exit 1
}

safe_sha() {
  case "$1" in
    [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) return 0 ;;
    *) return 1 ;;
  esac
}

parse_pr_url() {
  local url=$1
  if [[ "$url" =~ ^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]+)/pull/([0-9]+)/?$ ]]; then
    PR_OWNER=${BASH_REMATCH[1]}
    PR_REPO=${BASH_REMATCH[2]}
    PR_NUMBER=${BASH_REMATCH[3]}
    [[ "$PR_OWNER" != *- ]] || return 1
    return 0
  fi
  return 1
}

meta_tail_value() { # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

require_meta() {
  META="$STATE/$ID.meta"
  [ -f "$META" ] || die "no task metadata for $ID at $META"
  WT=$(fm_account_meta_value "$META" worktree)
  PROJ=$(fm_account_meta_value "$META" project)
  AUTHOR_HARNESS=$(fm_account_meta_value "$META" harness)
  AUTHOR_MODEL=$(fm_account_meta_value "$META" model)
  AUTHOR_ACCOUNT_HOME=$(fm_account_meta_value "$META" account_home)
  AUTHOR_ACCOUNT_PROFILE=$(fm_account_meta_value "$META" account_profile)
  [ -n "$WT" ] || die "meta for $ID is missing worktree="
  [ -n "$PROJ" ] || die "meta for $ID is missing project="
  [ -d "$WT" ] || die "worktree for $ID is missing: $WT"
  [ -d "$PROJ" ] || die "project for $ID is missing: $PROJ"
}

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

current_pr_head() {
  if command -v gh-axi >/dev/null 2>&1; then
    gh-axi pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" --json headRefOid -q .headRefOid 2>/dev/null || true
  elif test_lab_enabled && command -v gh >/dev/null 2>&1; then
    gh pr view "$PR_URL" --json headRefOid -q .headRefOid 2>/dev/null || true
  fi
}

pr_claims() {
  if command -v gh-axi >/dev/null 2>&1; then
    gh-axi pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" --json title,body \
      -q '.title + "\n\n" + (.body // "")' 2>/dev/null || true
  elif test_lab_enabled && command -v gh >/dev/null 2>&1; then
    gh pr view "$PR_URL" --json title,body -q '.title + "\n\n" + (.body // "")' 2>/dev/null || true
  fi
}

fetch_review_refs() {
  DEFAULT=$(default_branch) || die "cannot determine default branch for $PROJ"
  git -C "$WT" remote get-url origin >/dev/null 2>&1 || die "adversarial review requires an origin remote"
  git -C "$WT" fetch origin "+refs/heads/$DEFAULT:refs/remotes/origin/$DEFAULT" --quiet
  if ! git -C "$WT" cat-file -e "$HEAD_SHA^{commit}" 2>/dev/null; then
    git -C "$WT" fetch --quiet origin "refs/pull/$PR_NUMBER/head" >/dev/null 2>&1 \
      || die "cannot fetch PR head for $PR_URL"
  fi
  git -C "$WT" cat-file -e "$HEAD_SHA^{commit}" 2>/dev/null \
    || die "PR head $HEAD_SHA is not present after fetch"
  BASE_REF="origin/$DEFAULT"
  git -C "$WT" rev-parse --verify --quiet "$BASE_REF^{commit}" >/dev/null \
    || die "base $BASE_REF does not exist in $WT"
  MERGE_BASE=$(git -C "$WT" merge-base "$BASE_REF" "$HEAD_SHA") \
    || die "cannot compute merge base for $BASE_REF and $HEAD_SHA"
  BASE_HEAD=$(git -C "$WT" rev-parse "$BASE_REF^{commit}")
}

choose_reviewer_harnesses() {
  case "$AUTHOR_HARNESS" in
    codex) printf '%s\n' claude codex ;;
    claude) printf '%s\n' codex claude ;;
    *) printf '%s\n' codex claude ;;
  esac
}

model_for_harness() {
  case "$1" in
    codex) printf '%s\n' "${FM_ADVERSARIAL_REVIEW_CODEX_MODEL:-gpt-5}" ;;
    claude) "$SCRIPT_DIR/fm-harness.sh" claude-crew-model ;;
    *) return 1 ;;
  esac
}

select_reviewer() {
  local candidate selected model
  if test_lab_enabled && [ -n "${FM_ADVERSARIAL_REVIEW_HARNESS:-}" ]; then
    REVIEWER_HARNESS=$FM_ADVERSARIAL_REVIEW_HARNESS
    REVIEWER_ACCOUNT_HOME=${FM_ADVERSARIAL_REVIEW_ACCOUNT_HOME:-}
    REVIEWER_MODEL=${FM_ADVERSARIAL_REVIEW_MODEL:-}
    [ -n "$REVIEWER_ACCOUNT_HOME" ] || die "test-lab reviewer override requires FM_ADVERSARIAL_REVIEW_ACCOUNT_HOME"
    [ -n "$REVIEWER_MODEL" ] || REVIEWER_MODEL=$(model_for_harness "$REVIEWER_HARNESS")
  else
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      command -v "$candidate" >/dev/null 2>&1 || continue
      selected=$("$SCRIPT_DIR/fm-account-directory.sh" select "$candidate" 2>"$RUN_DIR/$candidate-account.err") || {
        cat "$RUN_DIR/$candidate-account.err" >&2
        continue
      }
      model=$(model_for_harness "$candidate") || continue
      REVIEWER_HARNESS=$candidate
      REVIEWER_ACCOUNT_HOME=$selected
      REVIEWER_MODEL=$model
      break
    done <<EOF
$(choose_reviewer_harnesses)
EOF
  fi
  [ -n "${REVIEWER_HARNESS:-}" ] || die "no independent reviewer account was available"
  [ -n "$REVIEWER_ACCOUNT_HOME" ] || die "reviewer account selection did not return an account home"

  ISOLATION_PROOF=
  if [ -n "$AUTHOR_HARNESS" ] && [ "$AUTHOR_HARNESS" != "$REVIEWER_HARNESS" ]; then
    ISOLATION_PROOF="different_harness author=$AUTHOR_HARNESS reviewer=$REVIEWER_HARNESS"
  elif [ -n "$AUTHOR_ACCOUNT_HOME" ] && [ "$AUTHOR_ACCOUNT_HOME" != "$REVIEWER_ACCOUNT_HOME" ]; then
    ISOLATION_PROOF="different_account_home author=$AUTHOR_ACCOUNT_HOME reviewer=$REVIEWER_ACCOUNT_HOME"
  elif [ -n "$AUTHOR_ACCOUNT_PROFILE" ]; then
    ISOLATION_PROOF="legacy_author_profile author_profile=$AUTHOR_ACCOUNT_PROFILE reviewer_home=$REVIEWER_ACCOUNT_HOME"
  else
    die "cannot prove reviewer is isolated from author; author_harness=${AUTHOR_HARNESS:-unknown} author_account_home=${AUTHOR_ACCOUNT_HOME:-absent}"
  fi
}

make_prompt() {
  local claims stat name_status diff
  claims=$(pr_claims)
  stat=$(git -C "$WT" diff --stat "$MERGE_BASE...$HEAD_SHA" --)
  name_status=$(git -C "$WT" diff --name-status "$MERGE_BASE...$HEAD_SHA" --)
  diff=$(git -C "$WT" diff --find-renames --find-copies --unified=80 "$MERGE_BASE...$HEAD_SHA" --)
  cat > "$PROMPT_FILE" <<EOF
You are Firstmate's independent adversarial PR reviewer.
Your job is to REFUTE the PR's own claims, not confirm them.

Hard constraints:
- Review exactly head SHA $HEAD_SHA against merge base $MERGE_BASE.
- Do not review the current branch tip unless it is that exact SHA.
- Do not edit files, commit, push, post comments, or run mutating commands.
- If you find a blocking issue, cite file:line in the head being reviewed.
- If a concern is speculative and not merge-blocking, omit it.
- Return only the output contract below.

Output contract:
VERDICT: BLOCKING
FINDINGS:
- path/to/file:123: [category] concise title - concrete failure mode and why it blocks merge.

or:
VERDICT: CLEAN
FINDINGS:
- none

Categories to target:
- business/domain logic defects
- concurrency, publication, and idempotency defects
- environment/config/deploy mismatches
- observability and false-assurance defects
- test-harness validity defects
- tooling/CI guard holes

Isolation proof supplied by Firstmate:
$ISOLATION_PROOF

PR URL:
$PR_URL

PR claims:
$claims

Review commands you may use:
- git diff --find-renames --find-copies $MERGE_BASE...$HEAD_SHA --
- git show $HEAD_SHA:path/to/file | nl -ba | sed -n 'START,ENDp'
- git grep -n PATTERN $HEAD_SHA -- path/

Diff stat:
$stat

Changed files:
$name_status

Full diff:
$diff
EOF
}

run_reviewer() {
  local timeout
  timeout=${FM_ADVERSARIAL_REVIEW_TIMEOUT_SECS:-1800}
  case "$timeout" in ''|*[!0-9]*|0) die "FM_ADVERSARIAL_REVIEW_TIMEOUT_SECS must be a positive integer" ;; esac
  if test_lab_enabled && [ -n "${FM_ADVERSARIAL_REVIEW_RUNNER:-}" ]; then
    "$FM_ADVERSARIAL_REVIEW_RUNNER" "$PROMPT_FILE" "$AGENT_OUT" "$REVIEWER_HARNESS" "$REVIEWER_ACCOUNT_HOME" "$REVIEWER_MODEL"
    return
  fi
  case "$REVIEWER_HARNESS" in
    codex)
      fm_account_run_bounded "$timeout" env \
        CODEX_HOME="$REVIEWER_ACCOUNT_HOME" \
        XDG_CACHE_HOME="$REVIEWER_ACCOUNT_HOME/.agent-fleet-quota-cache" \
        codex exec -C "$WT" --sandbox read-only --ask-for-approval never --ephemeral \
          --model "$REVIEWER_MODEL" --color never --output-last-message "$AGENT_OUT" \
          < "$PROMPT_FILE" > "$RUN_DIR/codex.stdout" 2> "$RUN_DIR/codex.stderr"
      ;;
    claude)
      fm_account_run_bounded "$timeout" env \
        CLAUDE_CONFIG_DIR="$REVIEWER_ACCOUNT_HOME" \
        CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
        claude -p --model "$REVIEWER_MODEL" --permission-mode dontAsk \
          --output-format text --no-session-persistence \
          < "$PROMPT_FILE" > "$AGENT_OUT" 2> "$RUN_DIR/claude.stderr"
      ;;
    *)
      die "unsupported adversarial reviewer harness: $REVIEWER_HARNESS"
      ;;
  esac
}

extract_verdict() {
  VERDICT=
  if grep -Eq '^VERDICT:[[:space:]]*BLOCKING[[:space:]]*$' "$AGENT_OUT"; then
    VERDICT=BLOCKING
  elif grep -Eq '^VERDICT:[[:space:]]*CLEAN[[:space:]]*$' "$AGENT_OUT"; then
    VERDICT=CLEAN
  fi
  [ -n "$VERDICT" ] || return 1
  if [ "$VERDICT" = BLOCKING ] && ! grep -Eq '(^|[[:space:]])[^[:space:]:][^:]*:[0-9]+:' "$AGENT_OUT"; then
    echo "error: blocking adversarial review omitted file:line findings" >&2
    return 1
  fi
}

write_report() {
  local generated
  generated=${FM_ADVERSARIAL_REVIEW_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  REVIEW_DIR=$(fm_account_task_dir "$DATA" "$ID" create) || die "cannot create data directory for $ID"
  REPORT="$REVIEW_DIR/adversarial-review.md"
  TMP_REPORT=$(mktemp "$REVIEW_DIR/.adversarial-review.XXXXXX") || die "cannot create temporary review report"
  cat > "$TMP_REPORT" <<EOF
# Adversarial PR Review

task: $ID
pr: $PR_URL
generated_at: $generated
base_ref: $BASE_REF
base_head_sha: $BASE_HEAD
merge_base_sha: $MERGE_BASE
head_sha: $HEAD_SHA
verdict: $VERDICT
author_harness: ${AUTHOR_HARNESS:-unknown}
author_model: ${AUTHOR_MODEL:-unknown}
author_account_home: ${AUTHOR_ACCOUNT_HOME:-unknown}
author_account_profile: ${AUTHOR_ACCOUNT_PROFILE:-unknown}
reviewer_harness: $REVIEWER_HARNESS
reviewer_model: $REVIEWER_MODEL
reviewer_account_home: $REVIEWER_ACCOUNT_HOME
isolation_proof: $ISOLATION_PROOF

## Reviewer Verdict

$(cat "$AGENT_OUT")
EOF
  mv "$TMP_REPORT" "$REPORT"
}

record_meta_verdict() {
  local lock
  lock=$(fm_account_meta_lock_acquire "$STATE" "$ID") || return 1
  trap 'fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true' EXIT
  [ -f "$META" ] || die "task metadata disappeared for $ID"
  {
    printf 'adversarial_review_head=%s\n' "$HEAD_SHA"
    printf 'adversarial_review_verdict=%s\n' "$VERDICT"
    printf 'adversarial_review_report=%s\n' "$REPORT"
    printf 'adversarial_review_reviewer_harness=%s\n' "$REVIEWER_HARNESS"
    printf 'adversarial_review_reviewer_account_home=%s\n' "$REVIEWER_ACCOUNT_HOME"
  } >> "$META"
  fm_account_meta_lock_release "$lock"
  trap - EXIT
}

run_mode() {
  local supplied_head=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --head)
        shift
        supplied_head=${1:-}
        [ -n "$supplied_head" ] || die "--head requires a SHA"
        ;;
      *) usage; exit 2 ;;
    esac
    shift
  done
  if [ -n "$supplied_head" ]; then
    safe_sha "$supplied_head" || die "invalid supplied head SHA: $supplied_head"
    HEAD_SHA=$supplied_head
  else
    HEAD_SHA=$(current_pr_head)
    safe_sha "$HEAD_SHA" || die "could not resolve current PR head for $PR_URL"
  fi
  RUN_DIR=$(mktemp -d "$STATE/.$ID.adversarial-review.XXXXXX") || die "cannot create review temp dir"
  PROMPT_FILE="$RUN_DIR/prompt.md"
  AGENT_OUT="$RUN_DIR/reviewer-output.md"
  fetch_review_refs
  choose_reviewer_harnesses >/dev/null
  select_reviewer
  make_prompt
  if ! run_reviewer; then
    VERDICT=NO_VERDICT
    AGENT_OUT="$RUN_DIR/no-verdict.md"
    printf 'VERDICT: NO_VERDICT\nFINDINGS:\n- reviewer unavailable or failed to complete.\n' > "$AGENT_OUT"
    write_report
    echo "adversarial review produced no verdict for $PR_URL at $HEAD_SHA" >&2
    exit 1
  fi
  if ! extract_verdict; then
    VERDICT=NO_VERDICT
    write_report
    echo "adversarial review output was not a valid verdict for $PR_URL at $HEAD_SHA" >&2
    exit 1
  fi
  write_report
  record_meta_verdict
  case "$VERDICT" in
    CLEAN)
      echo "adversarial review clean: $PR_URL head=$HEAD_SHA report=$REPORT"
      ;;
    BLOCKING)
      echo "adversarial review blocking: $PR_URL head=$HEAD_SHA report=$REPORT" >&2
      exit 1
      ;;
  esac
}

verify_mode() {
  local current recorded verdict report
  current=$(current_pr_head)
  safe_sha "$current" || die "could not resolve current PR head for $PR_URL"
  recorded=$(meta_tail_value adversarial_review_head)
  verdict=$(meta_tail_value adversarial_review_verdict)
  report=$(meta_tail_value adversarial_review_report)
  if [ "$verdict" != CLEAN ]; then
    die "adversarial review has no CLEAN verdict for $PR_URL (last verdict: ${verdict:-absent})"
  fi
  if [ "$recorded" != "$current" ]; then
    die "adversarial review is stale for $PR_URL: recorded head ${recorded:-absent}, current head $current"
  fi
  [ -n "$report" ] && [ -f "$report" ] || die "adversarial review report is missing for $PR_URL"
  if ! grep -q "^head_sha: $current$" "$report" || ! grep -q '^verdict: CLEAN$' "$report"; then
    die "adversarial review report does not prove CLEAN for current head $current"
  fi
  echo "adversarial review verified: $PR_URL head=$current report=$report"
}

MODE=${1:-}
ID=${2:-}
PR_URL=${3:-}
[ -n "$MODE" ] && [ -n "$ID" ] && [ -n "$PR_URL" ] || { usage; exit 2; }
shift 3
parse_pr_url "$PR_URL" || die "PR URL must match https://github.com/<owner>/<repo>/pull/<number>"
require_meta
case "$MODE" in
  run) run_mode "$@" ;;
  verify)
    [ "$#" -eq 0 ] || { usage; exit 2; }
    verify_mode
    ;;
  *) usage; exit 2 ;;
esac
