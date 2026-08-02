#!/usr/bin/env bash
# Tests for bin/fm-adversarial-pr-review.sh: the exact-head independent
# adversarial review lane that replaces Bugbot as the fifth merge property.
#
# Matrix:
#   (a) CLEAN verdict records auditable report + meta and verifies on same head
#   (b) verify refuses when the PR head moves after the verdict
#   (c) BLOCKING verdict records the finding and refuses
#   (d) review refuses when reviewer isolation cannot be proven
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

REVIEW="$ROOT/bin/fm-adversarial-pr-review.sh"
fm_test_tmproot_into TMP_ROOT fm-adversarial-review-tests

make_case() {
  local name=$1 case_dir head
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/data" "$case_dir/fakebin" \
    "$case_dir/accounts/codex/reviewer" "$case_dir/accounts/claude/author"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  printf 'base\n' > "$case_dir/_seed/service.txt"
  git -C "$case_dir/_seed" add service.txt
  git -C "$case_dir/_seed" commit -qm "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"

  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  printf 'base\npr change\n' > "$case_dir/wt/service.txt"
  git -C "$case_dir/wt" add service.txt
  git -C "$case_dir/wt" commit -qm "task change"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' "$head" > "$case_dir/pr-head"

  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *" title,body "*|*"--json title,body"*) printf 'Review lane test\n\nClaims to be safe.\n' ; exit 0 ;;
      *" baseRefName,baseRefOid "*|*"--json baseRefName,baseRefOid"*) printf 'main\t%s\n' "$FM_TEST_PR_BASE_HEAD" ; exit 0 ;;
      *) cat "$FM_TEST_PR_HEAD_FILE" ; exit 0 ;;
    esac
    ;;
esac
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi"

  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "harness=claude" \
    "model=claude-opus-5" \
    "generation_id=spawn:task-x1:test" \
    "account_home=$case_dir/accounts/claude/author"

  printf '%s\n' "$case_dir"
}

write_runner() {
  local case_dir=$1 verdict=$2
  cat > "$case_dir/reviewer.sh" <<SH
#!/usr/bin/env bash
prompt=\$1
out=\$2
grep -q 'Review exactly head SHA' "\$prompt" || exit 64
cat > "\$out" <<'EOF'
$verdict
EOF
SH
  chmod +x "$case_dir/reviewer.sh"
}

run_review() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_ADVERSARIAL_REVIEW_TEST_LAB=firstmate-adversarial-review-test-lab-v1 \
  FM_ADVERSARIAL_REVIEW_HARNESS=codex \
  FM_ADVERSARIAL_REVIEW_ACCOUNT_HOME="$case_dir/accounts/codex/reviewer" \
  FM_ADVERSARIAL_REVIEW_MODEL=gpt-test \
  FM_ADVERSARIAL_REVIEW_RUNNER="$case_dir/reviewer.sh" \
  FM_ADVERSARIAL_REVIEW_NOW=2026-08-02T00:00:00Z \
  FM_TEST_PR_HEAD_FILE="$case_dir/pr-head" \
  FM_TEST_PR_BASE_HEAD="$(git -C "$case_dir/project" rev-parse origin/main)" \
  PATH="$case_dir/fakebin:$PATH" \
    "$REVIEW" "$@"
}

test_clean_verdict_records_and_verifies() {
  local case_dir head out
  case_dir=$(make_case clean)
  head=$(cat "$case_dir/pr-head")
  write_runner "$case_dir" $'VERDICT: CLEAN\nFINDINGS:\n- none'

  out=$(run_review "$case_dir" run task-x1 https://github.com/example/repo/pull/9 --head "$head")

  assert_contains "$out" "adversarial review clean" "clean: run did not report a clean verdict"
  assert_grep "adversarial_review_head=$head" "$case_dir/state/task-x1.meta" \
    "clean: meta did not record review head"
  assert_grep 'adversarial_review_verdict=CLEAN' "$case_dir/state/task-x1.meta" \
    "clean: meta did not record CLEAN verdict"
  assert_grep 'verdict: CLEAN' "$case_dir/data/task-x1/adversarial-review.md" \
    "clean: report did not record CLEAN verdict"
  assert_grep 'isolation_proof: different_account_home' \
    "$case_dir/data/task-x1/adversarial-review.md" \
    "clean: report did not prove reviewer isolation"

  run_review "$case_dir" verify task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/verify.stdout" 2> "$case_dir/verify.stderr" \
    || fail "clean: verify should accept the exact same head"
  grep -qxF "$head" "$case_dir/verify.stdout" \
    || fail "clean: verify did not return the exact validated head"
  pass "adversarial review records a clean exact-head verdict and verifies it"
}

test_verify_refuses_stale_head() {
  local case_dir head stale rc
  case_dir=$(make_case stale)
  head=$(cat "$case_dir/pr-head")
  write_runner "$case_dir" $'VERDICT: CLEAN\nFINDINGS:\n- none'
  run_review "$case_dir" run task-x1 https://github.com/example/repo/pull/9 --head "$head" \
    > "$case_dir/run.stdout" 2> "$case_dir/run.stderr" \
    || fail "stale: initial clean review failed"
  stale=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  printf '%s\n' "$stale" > "$case_dir/pr-head"

  set +e
  run_review "$case_dir" verify task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/verify.stdout" 2> "$case_dir/verify.stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale: verify should refuse moved PR head"
  assert_grep 'adversarial review is stale' "$case_dir/verify.stderr" \
    "stale: refusal did not explain head invalidation"
  pass "adversarial review verify invalidates a verdict when the PR head moves"
}

test_blocking_verdict_refuses_with_report() {
  local case_dir head rc
  case_dir=$(make_case blocking)
  head=$(cat "$case_dir/pr-head")
  write_runner "$case_dir" $'VERDICT: BLOCKING\nFINDINGS:\n- service.txt:2: [business/domain logic] change breaks the documented invariant.'

  set +e
  run_review "$case_dir" run task-x1 https://github.com/example/repo/pull/9 --head "$head" \
    > "$case_dir/run.stdout" 2> "$case_dir/run.stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "blocking: run should refuse a blocking verdict"
  assert_grep 'adversarial_review_verdict=BLOCKING' "$case_dir/state/task-x1.meta" \
    "blocking: meta did not record BLOCKING verdict"
  assert_grep 'service.txt:2:' "$case_dir/data/task-x1/adversarial-review.md" \
    "blocking: report did not preserve file:line finding"
  pass "adversarial review records and refuses blocking findings"
}

test_isolation_failure_refuses_no_verdict() {
  local case_dir head rc
  case_dir=$(make_case isolation)
  head=$(cat "$case_dir/pr-head")
  write_runner "$case_dir" $'VERDICT: CLEAN\nFINDINGS:\n- none'
  sed 's/^harness=.*/harness=codex/; s#^account_home=.*#account_home='"$case_dir"'/accounts/codex/reviewer#' \
    "$case_dir/state/task-x1.meta" > "$case_dir/state/task-x1.meta.next"
  mv "$case_dir/state/task-x1.meta.next" "$case_dir/state/task-x1.meta"

  set +e
  run_review "$case_dir" run task-x1 https://github.com/example/repo/pull/9 --head "$head" \
    > "$case_dir/run.stdout" 2> "$case_dir/run.stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "isolation: run should refuse unproven self-review"
  assert_grep 'cannot prove reviewer is isolated from author' "$case_dir/run.stderr" \
    "isolation: refusal did not name the isolation proof failure"
  assert_no_grep 'adversarial_review_verdict=CLEAN' "$case_dir/state/task-x1.meta" \
    "isolation: unproven self-review was recorded as clean"
  pass "adversarial review refuses when account isolation cannot be proven"
}

test_clean_verdict_records_and_verifies
test_verify_refuses_stale_head
test_blocking_verdict_refuses_with_report
test_isolation_failure_refuses_no_verdict
