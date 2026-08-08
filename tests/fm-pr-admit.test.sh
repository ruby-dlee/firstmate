#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ADMIT="$ROOT/bin/fm-pr-admit.sh"
fm_test_tmproot_into TMP_ROOT fm-pr-admit
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
WT="$TMP_ROOT/worktree"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$STATE" "$FAKEBIN"
fm_git_init_commit "$WT"
BASE=$(git -C "$WT" rev-parse HEAD)
printf 'admitted\n' > "$WT/admitted.txt"
git -C "$WT" add admitted.txt
git -C "$WT" commit -qm admitted
HEAD_SHA=$(git -C "$WT" rev-parse HEAD)
fm_write_meta "$STATE/lane.meta" "worktree=$WT" "kind=ship"

cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'api /repos/ruby-dlee/firstmate/pulls/7')
    count=$(cat "$FM_TEST_PR_COUNT" 2>/dev/null || echo 0)
    count=$((count + 1))
    printf '%s\n' "$count" > "$FM_TEST_PR_COUNT"
    pr_head=$FM_TEST_HEAD
    if [ "$FM_TEST_PR_MODE" = move ] && [ "$count" -gt 1 ]; then
      pr_head=$FM_TEST_BASE
    fi
    cat <<EOF
state: open
draft: false
auto_merge: null
changed_files: 1
user:
  login: author
head:
  sha: $pr_head
base:
  sha: $FM_TEST_BASE
  ref: main
EOF
    ;;
  'api /repos/ruby-dlee/firstmate/pulls/7/files?per_page=100&page=1')
    if [ "$FM_TEST_FILE_MODE" = mismatch ]; then
      printf 'files[1]{filename}:\n  other.txt\n'
    else
      printf 'files[1]{filename}:\n  admitted.txt\n'
    fi
    ;;
  'api /repos/ruby-dlee/firstmate/commits/'"$FM_TEST_HEAD"'/check-runs?per_page=100&page=1')
    printf 'total_count: 1\ncheck_runs[1]{id}:\n  11\n'
    ;;
  'api /repos/ruby-dlee/firstmate/check-runs/11')
    count=$(cat "$FM_TEST_CHECK_COUNT" 2>/dev/null || echo 0)
    count=$((count + 1))
    printf '%s\n' "$count" > "$FM_TEST_CHECK_COUNT"
    check_name=ci
    check_app=17
    [ "$FM_TEST_CHECK_MODE" != unrelated ] || check_name=lint
    [ "$FM_TEST_CHECK_MODE" != status-context ] || check_name=lint
    [ "$FM_TEST_CHECK_MODE" != wrong-app ] || check_app=18
    if [ "$FM_TEST_CHECK_MODE" = race ] && [ "$count" -gt 1 ]; then
      check_name=ci-rerun
    fi
    if [ "$FM_TEST_CHECK_MODE" = pending ]; then
      check_status=in_progress
      check_conclusion=null
    else
      check_status=completed
      check_conclusion=success
    fi
    printf 'id: 11\nname: %s\napp:\n  id: %s\nstatus: %s\nconclusion: %s\n' \
      "$check_name" "$check_app" "$check_status" "$check_conclusion"
    ;;
  'api /repos/ruby-dlee/firstmate/commits/'"$FM_TEST_HEAD"'/status?per_page=100&page=1')
    if [ "$FM_TEST_CHECK_MODE" = status-context ]; then
      printf 'total_count: 1\nstate: success\nstatuses[1]:\n  - id: 21\n    context: ci\n    state: success\n'
    else
      printf 'total_count: 0\nstate: success\nstatuses[0]: []\n'
    fi
    ;;
  'api /repos/ruby-dlee/firstmate/pulls/7/reviews?per_page=100&page=1')
    count=$(cat "$FM_TEST_REVIEW_COUNT" 2>/dev/null || echo 0)
    count=$((count + 1))
    printf '%s\n' "$count" > "$FM_TEST_REVIEW_COUNT"
    case "$FM_TEST_REVIEW_MODE" in
      missing)
        printf 'reviews: []\n'
        ;;
      changes)
        cat <<EOF
reviews[3]:
  - id: 1
    user:
      login: reviewer-one
    state: APPROVED
    commit_id: $FM_TEST_HEAD
  - id: 2
    user:
      login: reviewer-two
    state: APPROVED
    commit_id: $FM_TEST_HEAD
  - id: 3
    user:
      login: reviewer-three
    state: CHANGES_REQUESTED
    commit_id: $FM_TEST_HEAD
EOF
        ;;
      dismissed)
        cat <<EOF
reviews[3]:
  - id: 1
    user:
      login: reviewer-one
    state: APPROVED
    commit_id: $FM_TEST_HEAD
  - id: 3
    user:
      login: reviewer-one
    state: DISMISSED
    commit_id: $FM_TEST_HEAD
  - id: 2
    user:
      login: reviewer-two
    state: APPROVED
    commit_id: $FM_TEST_HEAD
EOF
        ;;
      *)
        reviewer_two=reviewer-two
        review_head=$FM_TEST_HEAD
        [ "$FM_TEST_REVIEW_MODE" != author ] || reviewer_two=author
        [ "$FM_TEST_REVIEW_MODE" != stale ] || review_head=$FM_TEST_BASE
        [ "$FM_TEST_REVIEW_MODE" != malformed ] || reviewer_two=bad/reviewer
        if [ "$FM_TEST_REVIEW_MODE" = race ] && [ "$count" -gt 1 ]; then reviewer_two=reviewer-four; fi
        cat <<EOF
reviews[2]:
  - id: 1
    user:
      login: reviewer-one
    state: APPROVED
    commit_id: $review_head
  - id: 2
    user:
      login: $reviewer_two
    state: APPROVED
    commit_id: $review_head
EOF
        ;;
    esac
    ;;
  'api /repos/ruby-dlee/firstmate/branches/main/protection/required_status_checks')
    if [ "$FM_TEST_CHECK_MODE" = status-context ]; then
      printf 'strict: true\ncontexts[1]:\n  - ci\nchecks[0]: []\n'
    else
      printf 'strict: true\ncontexts[1]:\n  - ci\nchecks[1]:\n  - context: ci\n    app_id: 17\n'
    fi
    ;;
  'api /repos/ruby-dlee/firstmate/branches/main/protection/required_pull_request_reviews')
    if [ "$FM_TEST_POLICY_MODE" = weak ]; then
      printf 'required_approving_review_count: 1\ndismiss_stale_reviews: false\nrequire_code_owner_reviews: false\nrequire_last_push_approval: false\n'
    else
      printf 'required_approving_review_count: 2\ndismiss_stale_reviews: true\nrequire_code_owner_reviews: true\nrequire_last_push_approval: true\n'
    fi
    ;;
  'api /repos/ruby-dlee/firstmate/branches/main/protection/enforce_admins')
    printf 'enabled: true\n'
    ;;
  *) printf 'unexpected gh-axi call: %s\n' "$*" >&2; exit 97 ;;
esac
SH
chmod +x "$FAKEBIN/gh-axi"

run_admit() {
  local review_mode=${1:-valid} check_mode=${2:-success} file_mode=${3:-valid}
  local policy_mode=${4:-strict} pr_mode=${5:-stable}
  rm -f "$TMP_ROOT/pr.count" "$TMP_ROOT/check.count" "$TMP_ROOT/review.count"
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
    FM_TEST_HEAD="$HEAD_SHA" FM_TEST_BASE="$BASE" FM_TEST_PR_COUNT="$TMP_ROOT/pr.count" \
    FM_TEST_CHECK_COUNT="$TMP_ROOT/check.count" FM_TEST_REVIEW_COUNT="$TMP_ROOT/review.count" \
    FM_TEST_REVIEW_MODE=$review_mode FM_TEST_CHECK_MODE=$check_mode \
    FM_TEST_FILE_MODE=$file_mode FM_TEST_POLICY_MODE=$policy_mode \
    FM_TEST_PR_MODE=$pr_mode \
    "$ADMIT" lane https://github.com/ruby-dlee/firstmate/pull/7
}

out=$(run_admit) || fail "nested review identities were not admitted"
assert_contains "$out" "reviewers=2" "admission did not count two nested non-author identities"
out=$(run_admit valid status-context) || fail "protected status context was not admitted"
assert_contains "$out" "passed=2" "admission did not bind the protected exact-head status context"

expect_refusal() {  # <name> <stderr-pattern> [review] [check] [files] [policy] [pr]
  local name=$1 pattern=$2 rc
  shift 2
  set +e
  run_admit "$@" >"$TMP_ROOT/$name.out" 2>"$TMP_ROOT/$name.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "$name admission refusal"
  assert_grep "$pattern" "$TMP_ROOT/$name.err" "$name admission refusal was unclear"
}

expect_refusal author 'approvals=1' author
expect_refusal missing-review 'UNREVIEWED' missing
expect_refusal stale-review 'UNREVIEWED' stale
expect_refusal change-request 'blocked=1' changes
expect_refusal dismissed-review 'approvals=1' dismissed
expect_refusal malformed-review 'review identity is malformed' malformed
expect_refusal pending-checks 'checks are not green and settled' valid pending
expect_refusal unrelated-check 'protected exact-head check is missing' valid unrelated
expect_refusal wrong-check-app 'required app' valid wrong-app
expect_refusal check-evidence-race 'evidence changed during admission' valid race
expect_refusal review-evidence-race 'evidence changed during admission' race
expect_refusal containment-mismatch 'GitHub PR files differ' valid success mismatch
expect_refusal weak-policy 'base branch does not enforce' valid success valid weak
expect_refusal moving-head 'PR head/base/state changed during admission' valid success valid strict move

printf 'dirty\n' > "$WT/untracked.txt"
expect_refusal dirty-residual 'tracked, staged, or untracked residual'
rm -f "$WT/untracked.txt"

pass "PR admission enforces nested exact-head review and containment properties"
