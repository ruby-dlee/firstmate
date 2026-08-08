#!/usr/bin/env bash
# Behavioral tests for synchronous exact-head native PR admission.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ADMIT="$ROOT/bin/fm-pr-admit.sh"
PR_URL=https://github.com/example/repo/pull/9
fm_test_tmproot_into TMP_ROOT fm-pr-admit
fm_git_identity fmtest fmtest@example.invalid

make_case() {  # <name>
  local dir="$TMP_ROOT/$1" base head
  mkdir -p "$dir/home/state" "$dir/wt" "$dir/fakebin"
  git -C "$dir/wt" init -q -b main
  printf 'base\n' > "$dir/wt/gate.txt"
  git -C "$dir/wt" add gate.txt
  git -C "$dir/wt" commit -qm base
  base=$(git -C "$dir/wt" rev-parse HEAD)
  git -C "$dir/wt" checkout -qb fm/task-x1
  printf 'head\n' > "$dir/wt/gate.txt"
  git -C "$dir/wt" commit -qam head
  head=$(git -C "$dir/wt" rev-parse HEAD)
  fm_write_meta "$dir/home/state/task-x1.meta" \
    "window=sess:fm-task-x1" "worktree=$dir/wt" "project=$dir/wt" \
    "kind=ship" "mode=no-mistakes" "generation_id=test:1"
  cat > "$dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "$*" in
  "api /repos/example/repo/pulls/9")
    count=$(cat "$FM_TEST_PULL_COUNT" 2>/dev/null || echo 0)
    count=$((count + 1))
    printf '%s\n' "$count" > "$FM_TEST_PULL_COUNT"
    head=$FM_TEST_HEAD
    if [ "${FM_TEST_MOVE_HEAD:-0}" = 1 ] && [ "$count" -ge 2 ]; then
      head=0000000000000000000000000000000000000000
    fi
    printf '%s\n' \
      'number: 9' \
      'state: open' \
      'user: author' \
      'draft: false' \
      'auto_merge: null' \
      'changed_files: 1' \
      'head:' \
      "  sha: $head" \
      'base:' \
      "  sha: $FM_TEST_BASE" \
      '  ref: main'
    ;;
  "api /repos/example/repo/pulls/9/files?per_page=100&page=1")
    if [ "${FM_TEST_FILE_MISMATCH:-0}" = 1 ]; then
      printf '[1]:\n  - filename: other.txt\n'
    else
      printf '[1]:\n  - filename: gate.txt\n'
    fi
    ;;
  "api /repos/example/repo/commits/$FM_TEST_HEAD/check-runs?per_page=100&page=1")
    printf 'total_count: 1\ncheck_runs[1]:\n  - id: 41\n'
    ;;
  "api /repos/example/repo/check-runs/41")
    if [ "${FM_TEST_PENDING:-0}" = 1 ]; then
      printf 'status: in_progress\nconclusion: null\n'
    else
      printf 'status: completed\nconclusion: success\n'
    fi
    ;;
  "api /repos/example/repo/commits/$FM_TEST_HEAD/status")
    printf 'state: pending\ntotal_count: 0\n'
    ;;
  "api /repos/example/repo/pulls/9/reviews?per_page=100&page=1")
    if [ "${FM_TEST_ONE_REVIEW:-0}" = 1 ]; then
      printf '[1]:\n  - user: reviewer-one\n    state: APPROVED\n    commit_id: %s\n' "$FM_TEST_HEAD"
    else
      printf '[2]:\n  - user: reviewer-one\n    state: APPROVED\n    commit_id: %s\n  - user: reviewer-two\n    state: APPROVED\n    commit_id: %s\n' \
        "$FM_TEST_HEAD" "$FM_TEST_HEAD"
    fi
    ;;
  "api /repos/example/repo/branches/main/protection/required_status_checks")
    printf 'strict: %s\ncontexts[1]:\n  - ci/required\n' "${FM_TEST_STRICT:-true}"
    ;;
  "api /repos/example/repo/branches/main/protection/required_pull_request_reviews")
    printf '%s\n' \
      'required_approving_review_count: 2' \
      'dismiss_stale_reviews: true' \
      'require_code_owner_reviews: true' \
      'require_last_push_approval: true'
    ;;
  "api /repos/example/repo/branches/main/protection/enforce_admins")
    printf 'enabled: true\n'
    ;;
  *)
    echo "unexpected gh-axi call: $*" >&2
    exit 97
    ;;
esac
SH
  chmod +x "$dir/fakebin/gh-axi"
  printf '%s|%s|%s\n' "$dir" "$base" "$head"
}

run_admit() {  # <dir> <base> <head>
  local dir=$1 base=$2 head=$3
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_TEST_GH_LOG="$dir/gh.log" \
    FM_TEST_PULL_COUNT="$dir/pull.count" FM_TEST_BASE="$base" FM_TEST_HEAD="$head" \
    "$ADMIT" task-x1 "$PR_URL"
}

case_parts() {  # <name>
  local record
  record=$(make_case "$1")
  IFS='|' read -r CASE_DIR CASE_BASE CASE_HEAD <<EOF
$record
EOF
  : > "$CASE_DIR/gh.log"
}

test_exact_head_admits_all_native_properties() {
  local out rc
  case_parts exact
  out=$(run_admit "$CASE_DIR" "$CASE_BASE" "$CASE_HEAD" 2> "$CASE_DIR/err"); rc=$?
  expect_code 0 "$rc" "exact-head admission"
  assert_contains "$out" "admitted: head=$CASE_HEAD base=$CASE_BASE" "receipt omitted exact identities"
  assert_contains "$out" 'total=1 passed=1 failed=0 skipped=0 pending=0' \
    "receipt omitted the settled check accounting"
  assert_contains "$out" 'reviewers=2 residual_bytes=0' \
    "receipt omitted exact-head review and containment evidence"
  assert_no_grep 'api PUT' "$CASE_DIR/gh.log" "admission unexpectedly reached a merge API"
  pass "exact-head admission requires all native properties without merge authority"
}

test_unsettled_checks_refuse() {
  local rc
  case_parts pending
  set +e
  FM_TEST_PENDING=1 run_admit "$CASE_DIR" "$CASE_BASE" "$CASE_HEAD" \
    > "$CASE_DIR/out" 2> "$CASE_DIR/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "pending checks"
  assert_grep 'not green and settled' "$CASE_DIR/err" "pending set did not fail its deterministic predicate"
  pass "pending exact-head checks are never read as green"
}

test_missing_review_verdict_is_unreviewed() {
  local rc
  case_parts unreviewed
  set +e
  FM_TEST_ONE_REVIEW=1 run_admit "$CASE_DIR" "$CASE_BASE" "$CASE_HEAD" \
    > "$CASE_DIR/out" 2> "$CASE_DIR/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "missing review verdict"
  assert_grep 'exact head is UNREVIEWED' "$CASE_DIR/err" \
    "a stopped or absent reviewer was mistaken for no findings"
  pass "missing exact-head reviewer verdict remains UNREVIEWED"
}

test_content_and_residual_mismatches_refuse() {
  local rc
  case_parts content
  set +e
  FM_TEST_FILE_MISMATCH=1 run_admit "$CASE_DIR" "$CASE_BASE" "$CASE_HEAD" \
    > "$CASE_DIR/out" 2> "$CASE_DIR/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "PR file mismatch"
  assert_grep 'GitHub PR files differ' "$CASE_DIR/err" "file mismatch was not identified"

  case_parts residual
  printf 'not in the PR\n' > "$CASE_DIR/wt/untracked.txt"
  set +e
  run_admit "$CASE_DIR" "$CASE_BASE" "$CASE_HEAD" > "$CASE_DIR/out" 2> "$CASE_DIR/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "worktree residual"
  assert_grep 'tracked, staged, or untracked residual' "$CASE_DIR/err" \
    "zero-byte residual predicate was not enforced"
  pass "content containment rejects both PR-file mismatch and worktree residual"
}

test_head_movement_invalidates_every_property() {
  local rc
  case_parts movement
  set +e
  FM_TEST_MOVE_HEAD=1 run_admit "$CASE_DIR" "$CASE_BASE" "$CASE_HEAD" \
    > "$CASE_DIR/out" 2> "$CASE_DIR/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "head movement"
  assert_grep 'PR head/base/state changed during admission' "$CASE_DIR/err" \
    "head movement did not invalidate the sampled properties"
  pass "every native admission property dies when the head moves"
}

test_exact_head_admits_all_native_properties
test_unsettled_checks_refuse
test_missing_review_verdict_is_unreviewed
test_content_and_residual_mismatches_refuse
test_head_movement_invalidates_every_property
