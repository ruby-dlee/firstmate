#!/usr/bin/env bash
# Exact-head PR admission and one-shot merge tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE="$ROOT/bin/fm-pr-merge.sh"
fm_test_tmproot_into TMP_ROOT fm-pr-merge

make_case() {
  local dir="$TMP_ROOT/$1" base head
  mkdir -p "$dir/state" "$dir/fakebin" "$dir/wt"
  git -C "$dir/wt" init -q -b main
  printf 'base\n' > "$dir/wt/gate.txt"
  git -C "$dir/wt" add gate.txt
  git -C "$dir/wt" commit -qm base
  base=$(git -C "$dir/wt" rev-parse HEAD)
  git -C "$dir/wt" checkout -qb fm/gate
  printf 'head\n' > "$dir/wt/gate.txt"
  git -C "$dir/wt" commit -qam head
  head=$(git -C "$dir/wt" rev-parse HEAD)
  fm_write_meta "$dir/state/task-x1.meta" \
    "backend=tmux" "window=fm-task-x1" "tmux_window_id=@1" \
    "tmux_session_target=fmtest:fm-task-x1" "worktree=$dir/wt" "project=$dir/wt" \
    "kind=ship" "mode=no-mistakes" "generation_id=test:1"
  printf 'present\n' > "$dir/endpoint.state"
  printf '#!/usr/bin/env bash\necho custom\n' > "$dir/state/task-x1.check.sh"
  chmod +x "$dir/state/task-x1.check.sh"
  printf '%s|%s|%s\n' "$dir" "$base" "$head"
}

add_gh_axi() {
  local dir=$1
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
state=$(cat "$FM_TEST_ENDPOINT_STATE" 2>/dev/null || printf 'absent')
case "$1" in
  display-message)
    [ "$state" = present ] || exit 1
    case "${*: -1}" in
      *session_name*) printf 'fmtest\tfm-task-x1\n' ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  kill-window) printf 'absent\n' > "$FM_TEST_ENDPOINT_STATE" ;;
  list-windows)
    if [ "$state" = present ]; then
      printf 'fm-task-x1\n'
    else
      printf "can't find session: fmtest\n" >&2
      exit 1
    fi
    ;;
  *) echo "unexpected tmux call: $*" >&2; exit 1 ;;
esac
SH
  cat > "$dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "$*" in
  "api /repos/example/repo/pulls/9")
    pull_count=$(cat "$FM_TEST_PULL_COUNT" 2>/dev/null || echo 0)
    pull_count=$((pull_count + 1))
    printf '%s\n' "$pull_count" > "$FM_TEST_PULL_COUNT"
    response_head=$FM_TEST_HEAD
    if [ "${FM_TEST_MOVE_DURING_ADMISSION:-0}" = 1 ] && [ "$pull_count" -ge 3 ]; then
      response_head=0000000000000000000000000000000000000000
    fi
    cat <<EOF
number: 9
state: open
user: author
draft: false
auto_merge: null
changed_files: 1
head:
  sha: $response_head
base:
  sha: $FM_TEST_BASE
  ref: main
EOF
    ;;
  "api /repos/example/repo/pulls/9/files?per_page=100&page=1")
    if [ "${FM_TEST_FILE_MISMATCH:-0}" = 1 ]; then
      printf '[1]:\n  - sha: abc\n    filename: other.txt\n    status: modified\n'
    else
      printf '[1]:\n  - sha: abc\n    filename: gate.txt\n    status: modified\n'
    fi
    ;;
  "api /repos/example/repo/commits/$FM_TEST_HEAD/check-runs?per_page=100&page=1")
    if [ "${FM_TEST_TRUNCATED_CHECKS:-0}" = 1 ]; then
      printf 'total_count: 2\ncheck_runs[1]:\n  - id: 41\n    name: behavior\n'
    else
      printf 'total_count: 1\ncheck_runs[1]:\n  - id: 41\n    name: behavior\n'
    fi
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
    if [ "${FM_TEST_MULTIPAGE_REVIEWS:-0}" = 1 ]; then
      printf '[100]:\n'
      i=1
      while [ "$i" -le 100 ]; do
        printf '  - id: %s\n    user: reviewer-%s\n    state: APPROVED\n    commit_id: %s\n    body: clean\n' \
          "$i" "$i" "$FM_TEST_HEAD"
        i=$((i + 1))
      done
    elif [ "${FM_TEST_ONE_REVIEW:-0}" = 1 ]; then
      printf '[1]:\n  - id: 1\n    user: reviewer-one\n    state: APPROVED\n    commit_id: %s\n    body: clean\n' "$FM_TEST_HEAD"
    elif [ "${FM_TEST_STALE_REVIEW:-0}" = 1 ]; then
      printf '[2]:\n  - id: 1\n    user: reviewer-one\n    state: APPROVED\n    commit_id: %s\n    body: clean\n  - id: 2\n    user: reviewer-two\n    state: APPROVED\n    commit_id: 0000000000000000000000000000000000000000\n    body: stale\n' "$FM_TEST_HEAD"
    else
      printf '[2]:\n  - id: 1\n    user: reviewer-one\n    state: APPROVED\n    commit_id: %s\n    body: clean\n  - id: 2\n    user: reviewer-two\n    state: APPROVED\n    commit_id: %s\n    body: clean\n' "$FM_TEST_HEAD" "$FM_TEST_HEAD"
    fi
    ;;
  "api /repos/example/repo/pulls/9/reviews?per_page=100&page=2")
    [ "${FM_TEST_MULTIPAGE_REVIEWS:-0}" = 1 ] || exit 1
    printf '[1]:\n  - id: 101\n    user: reviewer-final\n    state: APPROVED\n    commit_id: %s\n    body: clean\n' "$FM_TEST_HEAD"
    ;;
  "api /repos/example/repo/branches/main/protection/required_status_checks")
    policy_count=$(cat "$FM_TEST_POLICY_COUNT" 2>/dev/null || echo 0)
    policy_count=$((policy_count + 1))
    printf '%s\n' "$policy_count" > "$FM_TEST_POLICY_COUNT"
    if [ "${FM_TEST_DIRTY_AFTER_ADMISSION:-0}" = 1 ] && [ "$policy_count" -ge 2 ]; then
      printf 'late residual\n' > "$FM_TEST_WORKTREE/late-residual.txt"
    fi
    if [ "${FM_TEST_MISSING_EVIDENCE_RULE:-0}" = 1 ]; then
      printf 'strict: true\ncontexts[0]:\n'
    else
      printf 'strict: %s\ncontexts[1]:\n  - ci/required\n' "${FM_TEST_STRICT:-true}"
    fi
    ;;
  "api /repos/example/repo/branches/main/protection/required_pull_request_reviews")
    printf 'required_approving_review_count: 2\ndismiss_stale_reviews: true\nrequire_code_owner_reviews: true\nrequire_last_push_approval: true\n'
    ;;
  "api /repos/example/repo/branches/main/protection/enforce_admins")
    printf 'enabled: true\n'
    ;;
  "api PUT /repos/example/repo/pulls/9/merge --field sha=$FM_TEST_HEAD --field merge_method="*)
    if [ "${FM_TEST_REVOKED_REVIEW:-0}" = 1 ]; then
      echo 'error: required code-owner review was dismissed' >&2
      exit 1
    fi
    if [ "${FM_TEST_MERGE_FAIL:-0}" = 1 ]; then
      echo 'error: head moved' >&2
      exit 1
    fi
    printf 'merged: true\nmessage: merged\n'
    ;;
  *) echo "unexpected gh-axi call: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$dir/fakebin/gh-axi" "$dir/fakebin/tmux"
}

run_merge() {
  local dir=$1 base=$2 head=$3; shift 3
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/state" \
    FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_PULL_COUNT="$dir/pull.count" \
    FM_TEST_POLICY_COUNT="$dir/policy.count" FM_TEST_ENDPOINT_STATE="$dir/endpoint.state" \
    FM_TEST_WORKTREE="$dir/wt" \
    FM_TEST_BASE="$base" FM_TEST_HEAD="$head" \
    PATH="$dir/fakebin:$PATH" "$MERGE" task-x1 https://github.com/example/repo/pull/9 "$@"
}

test_exact_head_admitted_and_merged_once() {
  local rec dir base head out
  rec=$(make_case success); IFS='|' read -r dir base head <<EOF
$rec
EOF
  add_gh_axi "$dir"; : > "$dir/gh.log"
  out=$(run_merge "$dir" "$base" "$head") || fail "exact-head merge fixture refused: $out"
  assert_contains "$out" "exact_head=$head" "merge receipt omitted exact head"
  assert_grep "pr_head=$head" "$dir/state/task-x1.meta" "PR head was not recorded"
  [ "$("$dir/state/task-x1.check.sh")" = custom ] || fail "fm-pr-check overwrote the task-owned custom check"
  grep -qxF "api PUT /repos/example/repo/pulls/9/merge --field sha=$head --field merge_method=squash" "$dir/gh.log" \
    || fail "merge did not carry the admitted head atomically"
  pass "fm-pr-merge admits five exact-head properties and executes one guarded merge"
}

test_unsettled_checks_refuse() {
  local rec dir base head rc
  rec=$(make_case pending); IFS='|' read -r dir base head <<EOF
$rec
EOF
  add_gh_axi "$dir"; : > "$dir/gh.log"
  FM_TEST_PENDING=1 run_merge "$dir" "$base" "$head" >"$dir/out" 2>"$dir/err"; rc=$?
  expect_code 1 "$rc" "pending check set must refuse"
  assert_grep 'not green and settled' "$dir/err" "pending refusal omitted settled predicate"
  assert_no_grep 'api PUT /repos/example/repo/pulls/9/merge' "$dir/gh.log" "pending checks reached merge"
  pass "fm-pr-merge refuses a non-settled check set"
}

test_stopped_reviewer_is_unreviewed() {
  local rec dir base head rc
  rec=$(make_case unreviewed); IFS='|' read -r dir base head <<EOF
$rec
EOF
  add_gh_axi "$dir"; : > "$dir/gh.log"
  FM_TEST_ONE_REVIEW=1 run_merge "$dir" "$base" "$head" >"$dir/out" 2>"$dir/err"; rc=$?
  expect_code 1 "$rc" "missing second approval must refuse"
  assert_grep 'UNREVIEWED' "$dir/err" "review refusal did not use the fail-closed verdict"
  assert_no_grep 'api PUT /repos/example/repo/pulls/9/merge' "$dir/gh.log" "unreviewed head reached merge"
  pass "fm-pr-merge treats a missing reviewer verdict as UNREVIEWED"
}

test_stale_review_is_unreviewed() {
  local rec dir base head rc
  rec=$(make_case stale-review); IFS='|' read -r dir base head <<EOF
$rec
EOF
  add_gh_axi "$dir"; : > "$dir/gh.log"
  FM_TEST_STALE_REVIEW=1 run_merge "$dir" "$base" "$head" >"$dir/out" 2>"$dir/err"; rc=$?
  expect_code 1 "$rc" "a verdict on another head must not review the current head"
  assert_grep 'UNREVIEWED' "$dir/err" "stale review was not fail-closed"
  assert_no_grep 'api PUT /repos/example/repo/pulls/9/merge' "$dir/gh.log" "stale review reached merge"
  pass "fm-pr-merge rejects an approval from another head"
}

test_truncated_check_enumeration_refuses() {
  local rec dir base head rc
  rec=$(make_case truncated-checks); IFS='|' read -r dir base head <<EOF
$rec
EOF
  add_gh_axi "$dir"; : > "$dir/gh.log"
  FM_TEST_TRUNCATED_CHECKS=1 run_merge "$dir" "$base" "$head" >"$dir/out" 2>"$dir/err"; rc=$?
  expect_code 1 "$rc" "an incomplete check-run enumeration must refuse"
  assert_grep 'enumeration is incomplete or duplicated' "$dir/err" "truncated check set was not identified"
  assert_no_grep 'api PUT /repos/example/repo/pulls/9/merge' "$dir/gh.log" "truncated checks reached merge"
  pass "fm-pr-merge accounts for every exact-head check run"
}

test_content_file_set_mismatch_refuses() {
  local rec dir base head rc
  rec=$(make_case file-mismatch); IFS='|' read -r dir base head <<EOF
$rec
EOF
  add_gh_axi "$dir"; : > "$dir/gh.log"
  FM_TEST_FILE_MISMATCH=1 run_merge "$dir" "$base" "$head" >"$dir/out" 2>"$dir/err"; rc=$?
  expect_code 1 "$rc" "a remote/local PR file mismatch must refuse"
  assert_grep 'GitHub PR files differ' "$dir/err" "content mismatch refusal was unclear"
  assert_no_grep 'api PUT /repos/example/repo/pulls/9/merge' "$dir/gh.log" "mismatched content reached merge"
  pass "fm-pr-merge requires exact local and GitHub PR file containment"
}

test_dirty_worktree_refuses_admission() {
  local rec dir base head rc
  rec=$(make_case dirty-worktree); IFS='|' read -r dir base head <<EOF
$rec
EOF
  add_gh_axi "$dir"; : > "$dir/gh.log"
  printf 'untracked\n' > "$dir/wt/untracked.txt"
  run_merge "$dir" "$base" "$head" >"$dir/out" 2>"$dir/err"; rc=$?
  expect_code 1 "$rc" "untracked worktree residual must refuse"
  assert_grep 'tracked, staged, or untracked residual' "$dir/err" "dirty worktree refusal was unclear"
  assert_no_grep 'api PUT /repos/example/repo/pulls/9/merge' "$dir/gh.log" "dirty worktree reached merge"
  pass "fm-pr-merge requires a mechanically clean admitted worktree"
}

test_missing_server_evidence_rule_refuses() {
  local rec dir base head rc
  rec=$(make_case missing-rule); IFS='|' read -r dir base head <<EOF
$rec
EOF
  add_gh_axi "$dir"; : > "$dir/gh.log"
  FM_TEST_MISSING_EVIDENCE_RULE=1 run_merge "$dir" "$base" "$head" >"$dir/out" 2>"$dir/err"; rc=$?
  expect_code 1 "$rc" "merge must refuse without a required admission context"
  assert_grep 'does not enforce strict required checks' "$dir/err" "missing server rule refusal was unclear"
  assert_no_grep 'api PUT /repos/example/repo/pulls/9/merge' "$dir/gh.log" "unprotected evidence reached merge"
  pass "fm-pr-merge requires complete server-native branch protection"
}

test_non_strict_base_policy_rejects_then_retires() {
  local rec dir base head out rc
  rec=$(make_case non-strict); IFS='|' read -r dir base head <<EOF
$rec
EOF
  add_gh_axi "$dir"; : > "$dir/gh.log"
  FM_TEST_STRICT=false run_merge "$dir" "$base" "$head" >"$dir/out" 2>"$dir/err"; rc=$?
  expect_code 1 "$rc" "non-strict required checks must refuse exact-base admission"
  assert_grep 'does not enforce strict required checks' "$dir/err" "non-strict refusal was unclear"
  assert_no_grep 'api PUT /repos/example/repo/pulls/9/merge' "$dir/gh.log" "non-strict base policy reached merge"
  : > "$dir/gh.log"; rm -f "$dir/policy.count" "$dir/pull.count"
  out=$(run_merge "$dir" "$base" "$head") || fail "strict policy did not retire the base-drift violation"
  assert_contains "$out" "exact_head=$head" "strict-policy repair did not merge exact head"
  pass "fm-pr-merge rejects and retires non-strict base admission policy"
}

test_revoked_same_head_review_is_server_rejected_then_retired() {
  local rec dir base head out rc
  rec=$(make_case revoked-review); IFS='|' read -r dir base head <<EOF
$rec
EOF
  add_gh_axi "$dir"; : > "$dir/gh.log"
  FM_TEST_REVOKED_REVIEW=1 run_merge "$dir" "$base" "$head" >"$dir/out" 2>"$dir/err"; rc=$?
  expect_code 1 "$rc" "dismissed same-head review must fail at the server merge boundary"
  assert_grep 'required code-owner review was dismissed' "$dir/err" "server review mutation refusal was hidden"
  assert_grep 'api PUT /repos/example/repo/pulls/9/merge' "$dir/gh.log" "review mutation never reached the native server guard"
  : > "$dir/gh.log"; rm -f "$dir/policy.count" "$dir/pull.count"
  out=$(run_merge "$dir" "$base" "$head") || fail "restored review state did not retire the violation"
  assert_contains "$out" "exact_head=$head" "restored review state did not merge exact head"
  pass "server-native review protection rejects and retires same-head mutation"
}

test_late_worktree_residual_rejects_then_retires() {
  local rec dir base head out rc
  rec=$(make_case late-residual); IFS='|' read -r dir base head <<EOF
$rec
EOF
  add_gh_axi "$dir"; : > "$dir/gh.log"
  FM_TEST_DIRTY_AFTER_ADMISSION=1 run_merge "$dir" "$base" "$head" >"$dir/out" 2>"$dir/err"; rc=$?
  expect_code 1 "$rc" "late untracked residual must refuse at final merge custody"
  assert_grep 'residual appeared at the final merge boundary' "$dir/err" "late residual refusal was unclear"
  assert_no_grep 'api PUT /repos/example/repo/pulls/9/merge' "$dir/gh.log" "late worktree residual reached merge"
  rm -f "$dir/wt/late-residual.txt" "$dir/policy.count" "$dir/pull.count"
  : > "$dir/gh.log"
  out=$(run_merge "$dir" "$base" "$head") || fail "clean worktree did not retire late residual"
  assert_contains "$out" "exact_head=$head" "clean worktree repair did not merge exact head"
  pass "merge custody catches and retires a real late worktree residual"
}

test_review_pagination_combines_validated_pages() {
  local rec dir base head out
  rec=$(make_case paginated-reviews); IFS='|' read -r dir base head <<EOF
$rec
EOF
  add_gh_axi "$dir"; : > "$dir/gh.log"
  out=$(FM_TEST_MULTIPAGE_REVIEWS=1 run_merge "$dir" "$base" "$head") \
    || fail "multi-page review admission refused: $out"
  assert_grep 'reviews?per_page=100&page=2' "$dir/gh.log" "review pagination never fetched page two"
  pass "fm-pr-merge validates and combines explicit review pages"
}

test_head_movement_during_admission_refuses() {
  local rec dir base head rc
  rec=$(make_case admission-move); IFS='|' read -r dir base head <<EOF
$rec
EOF
  add_gh_axi "$dir"; : > "$dir/gh.log"
  FM_TEST_MOVE_DURING_ADMISSION=1 run_merge "$dir" "$base" "$head" >"$dir/out" 2>"$dir/err"; rc=$?
  expect_code 1 "$rc" "head movement during admission must invalidate every property"
  assert_grep 'head/base/state changed during admission' "$dir/err" "admission movement refusal was unclear"
  assert_no_grep 'api PUT /repos/example/repo/pulls/9/merge' "$dir/gh.log" "moved head reached merge"
  pass "fm-pr-merge invalidates all properties when the head moves during admission"
}

test_armed_merge_flags_refuse() {
  local rec dir base head rc
  rec=$(make_case armed); IFS='|' read -r dir base head <<EOF
$rec
EOF
  add_gh_axi "$dir"; : > "$dir/gh.log"
  run_merge "$dir" "$base" "$head" -- --auto >"$dir/out" 2>"$dir/err"; rc=$?
  expect_code 1 "$rc" "--auto must refuse"
  assert_grep 'one-shot only' "$dir/err" "armed merge refusal was unclear"
  [ ! -s "$dir/gh.log" ] || fail "armed merge flag reached GitHub"
  pass "fm-pr-merge cannot leave a merge armed"
}

test_atomic_head_movement_failure_propagates() {
  local rec dir base head rc
  rec=$(make_case moved); IFS='|' read -r dir base head <<EOF
$rec
EOF
  add_gh_axi "$dir"; : > "$dir/gh.log"
  FM_TEST_MERGE_FAIL=1 run_merge "$dir" "$base" "$head" >"$dir/out" 2>"$dir/err"; rc=$?
  expect_code 1 "$rc" "atomic head mismatch must propagate"
  assert_grep 'head moved' "$dir/err" "atomic merge failure was hidden"
  pass "fm-pr-merge propagates GitHub's atomic exact-head refusal"
}

test_exact_head_admitted_and_merged_once
test_unsettled_checks_refuse
test_stopped_reviewer_is_unreviewed
test_stale_review_is_unreviewed
test_truncated_check_enumeration_refuses
test_content_file_set_mismatch_refuses
test_dirty_worktree_refuses_admission
test_missing_server_evidence_rule_refuses
test_non_strict_base_policy_rejects_then_retires
test_revoked_same_head_review_is_server_rejected_then_retired
test_late_worktree_residual_rejects_then_retires
test_review_pagination_combines_validated_pages
test_head_movement_during_admission_refuses
test_armed_merge_flags_refuse
test_atomic_head_movement_failure_propagates
