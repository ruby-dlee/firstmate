#!/usr/bin/env bash
# Behavior tests for bin/fm-crosscheck.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

CROSSCHECK="$ROOT/bin/fm-crosscheck.sh"
fm_test_tmproot_into TMP_ROOT fm-crosscheck-tests

write_runner() {
  local case_dir=$1
  cat > "$case_dir/runner.sh" <<'SH'
#!/usr/bin/env bash
prompt=$1
out=$2
printf '%s\n' "$prompt" >> "$FM_TEST_PROMPT_LOG"
cp "$FM_TEST_REVIEWER_JSON" "$out"
SH
  chmod +x "$case_dir/runner.sh"
}

make_repo_case() {
  local name=$1 case_dir repo bare wt base head
  case_dir="$TMP_ROOT/$name"
  repo="$case_dir/repo"
  bare="$case_dir/origin.git"
  wt="$case_dir/wt"
  mkdir -p "$case_dir/state" "$case_dir/data" "$case_dir/fakebin" "$repo"
  git -C "$repo" init -q -b main
  printf 'ok\n' > "$repo/app.txt"
  git -C "$repo" add app.txt
  git -C "$repo" commit -qm base
  base=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -qb feature
  printf 'bug\n' > "$repo/app.txt"
  git -C "$repo" commit -am feature -q
  head=$(git -C "$repo" rev-parse HEAD)
  git clone --quiet --bare "$repo" "$bare"
  git -C "$bare" update-ref refs/pull/7/head "$head"
  git clone --quiet "$bare" "$wt"
  git -C "$wt" checkout --quiet feature
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$wt" \
    "project=$repo" \
    "kind=ship" \
    "mode=no-mistakes" \
    "harness=codex" \
    "model=gpt-5" \
    "account_home=$case_dir/author"
  write_runner "$case_dir"
  cat > "$case_dir/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" --json headRefOid "*) printf '%s\n' '$head'; exit 0 ;;
  *" --json baseRefName,baseRefOid "*) printf 'main\t%s\n' '$base'; exit 0 ;;
  *" --json title,body "*) printf 'Test PR\n\nBody\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  printf '%s\n' "$case_dir"
}

run_crosscheck_case() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CROSSCHECK_TEST_LAB=firstmate-crosscheck-test-lab-v1 \
  FM_CROSSCHECK_REVIEWER_HARNESS=codex \
  FM_CROSSCHECK_REVIEWER_ACCOUNT_HOME="$case_dir/reviewer" \
  FM_CROSSCHECK_REVIEWER_MODEL=gpt-5-review \
  FM_CROSSCHECK_RUNNER="$case_dir/runner.sh" \
  FM_TEST_PROMPT_LOG="$case_dir/prompt.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$CROSSCHECK" "$@"
}

write_json() {
  local path=$1 content=$2
  printf '%s\n' "$content" > "$path"
}

test_reproduced_finding_blocks_and_persists() {
  local case_dir rc
  case_dir=$(make_repo_case reproduced-blocks)
  write_json "$case_dir/reviewer.json" '{
    "review": {"head_sha": "__HEAD__", "summary": "found bug", "citations": [{"path": "app.txt", "line": 1}]},
    "finding_updates": [],
    "new_findings": [{
      "title": "app writes bug",
      "category": "test-harness validity defects",
      "severity": "blocking",
      "description": "app.txt contains bug",
      "reproduction": {"command": "grep -n bug app.txt", "output": "1:bug"},
      "citations": [{"path": "app.txt", "line": 1}]
    }],
    "suspicions": []
  }'
  sed "s/__HEAD__/$(git -C "$case_dir/wt" rev-parse HEAD)/" "$case_dir/reviewer.json" > "$case_dir/reviewer-ready.json"
  FM_TEST_REVIEWER_JSON="$case_dir/reviewer-ready.json"
  export FM_TEST_REVIEWER_JSON

  set +e
  run_crosscheck_case "$case_dir" run task-x1 https://github.com/example/repo/pull/7 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "reproduced-blocks: crosscheck should block on reproduced finding"
  assert_grep '"lifecycle": "open"' "$case_dir/data/task-x1/crosscheck-ledger.json" \
    "reproduced-blocks: finding was not stored as open"
  assert_grep 'crosscheck_state=blocked' "$case_dir/state/task-x1.meta" \
    "reproduced-blocks: meta did not record blocked crosscheck state"
  pass "crosscheck stores reproduced findings as durable merge blockers"
}

test_silence_on_prior_finding_is_no_verdict() {
  local case_dir rc
  case_dir=$(make_repo_case silence-no-verdict)
  mkdir -p "$case_dir/data/task-x1"
  cat > "$case_dir/data/task-x1/crosscheck-ledger.json" <<JSON
{"version":1,"task":"task-x1","pr":"https://github.com/example/repo/pull/7","findings":[{"id":"cc-old","lifecycle":"open","title":"old bug","history":[]}],"suspicions":[],"runs":[]}
JSON
  write_json "$case_dir/reviewer.json" '{
    "review": {"head_sha": "__HEAD__", "summary": "looks ok", "citations": [{"path": "app.txt", "line": 1}]},
    "finding_updates": [],
    "new_findings": [],
    "suspicions": []
  }'
  sed "s/__HEAD__/$(git -C "$case_dir/wt" rev-parse HEAD)/" "$case_dir/reviewer.json" > "$case_dir/reviewer-ready.json"
  FM_TEST_REVIEWER_JSON="$case_dir/reviewer-ready.json"
  export FM_TEST_REVIEWER_JSON

  set +e
  run_crosscheck_case "$case_dir" run task-x1 https://github.com/example/repo/pull/7 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "silence-no-verdict: missing active finding update should fail closed"
  assert_grep 'silence never closes a finding' "$case_dir/stderr" \
    "silence-no-verdict: refusal did not name silence contract"
  assert_grep '"lifecycle":"open"' "$case_dir/data/task-x1/crosscheck-ledger.json" \
    "silence-no-verdict: prior open finding was changed despite no verdict"
  pass "crosscheck refuses citationful silence on active findings"
}

test_claimed_fixed_without_mutation_still_blocks() {
  local case_dir rc
  case_dir=$(make_repo_case claimed-fixed-blocks)
  mkdir -p "$case_dir/data/task-x1"
  cat > "$case_dir/data/task-x1/crosscheck-ledger.json" <<JSON
{"version":1,"task":"task-x1","pr":"https://github.com/example/repo/pull/7","findings":[{"id":"cc-old","lifecycle":"open","title":"old bug","history":[]}],"suspicions":[],"runs":[]}
JSON
  write_json "$case_dir/reviewer.json" '{
    "review": {"head_sha": "__HEAD__", "summary": "not reproduced", "citations": [{"path": "app.txt", "line": 1}]},
    "finding_updates": [{"id": "cc-old", "status": "claimed_fixed", "evidence": {"command": "grep -n old app.txt", "output": "no match", "citations": [{"path": "app.txt", "line": 1}]}}],
    "new_findings": [],
    "suspicions": []
  }'
  sed "s/__HEAD__/$(git -C "$case_dir/wt" rev-parse HEAD)/" "$case_dir/reviewer.json" > "$case_dir/reviewer-ready.json"
  FM_TEST_REVIEWER_JSON="$case_dir/reviewer-ready.json"
  export FM_TEST_REVIEWER_JSON

  set +e
  run_crosscheck_case "$case_dir" run task-x1 https://github.com/example/repo/pull/7 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "claimed-fixed-blocks: claimed-fixed finding should still block"
  assert_grep '"lifecycle": "claimed-fixed"' "$case_dir/data/task-x1/crosscheck-ledger.json" \
    "claimed-fixed-blocks: finding did not move to claimed-fixed"
  pass "crosscheck keeps claimed-fixed findings merge-blocking until mutation proof exists"
}

test_verified_fixed_with_mutation_clears() {
  local case_dir rc
  case_dir=$(make_repo_case verified-fixed-clears)
  mkdir -p "$case_dir/data/task-x1"
  cat > "$case_dir/data/task-x1/crosscheck-ledger.json" <<JSON
{"version":1,"task":"task-x1","pr":"https://github.com/example/repo/pull/7","findings":[{"id":"cc-old","lifecycle":"open","title":"old bug","history":[]}],"suspicions":[],"runs":[]}
JSON
  write_json "$case_dir/reviewer.json" '{
    "review": {"head_sha": "__HEAD__", "summary": "fixed", "citations": [{"path": "app.txt", "line": 1}]},
    "finding_updates": [{"id": "cc-old", "status": "verified_fixed", "evidence": {"command": "grep -n old app.txt", "output": "no match", "citations": [{"path": "app.txt", "line": 1}]}, "mutation_proof": {"command": "tests/regression.sh", "output": "fails after reverting fix", "mutation": "reverted app.txt guard"}}],
    "new_findings": [],
    "suspicions": []
  }'
  sed "s/__HEAD__/$(git -C "$case_dir/wt" rev-parse HEAD)/" "$case_dir/reviewer.json" > "$case_dir/reviewer-ready.json"
  FM_TEST_REVIEWER_JSON="$case_dir/reviewer-ready.json"
  export FM_TEST_REVIEWER_JSON

  run_crosscheck_case "$case_dir" run task-x1 https://github.com/example/repo/pull/7 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "verified-fixed-clears: crosscheck should clear"

  assert_grep '"lifecycle": "verified-fixed"' "$case_dir/data/task-x1/crosscheck-ledger.json" \
    "verified-fixed-clears: finding was not verified-fixed"
  assert_grep 'crosscheck clear' "$case_dir/stdout" \
    "verified-fixed-clears: success output missing"
  pass "crosscheck clears only after mutation-proven fix evidence"
}

test_citationless_clean_result_is_no_verdict() {
  local case_dir rc
  case_dir=$(make_repo_case citationless-no-verdict)
  write_json "$case_dir/reviewer.json" '{
    "review": {"head_sha": "__HEAD__", "summary": "looks ok", "citations": []},
    "finding_updates": [],
    "new_findings": [],
    "suspicions": []
  }'
  sed "s/__HEAD__/$(git -C "$case_dir/wt" rev-parse HEAD)/" "$case_dir/reviewer.json" > "$case_dir/reviewer-ready.json"
  FM_TEST_REVIEWER_JSON="$case_dir/reviewer-ready.json"
  export FM_TEST_REVIEWER_JSON

  set +e
  run_crosscheck_case "$case_dir" run task-x1 https://github.com/example/repo/pull/7 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "citationless-no-verdict: citation-less result must fail"
  assert_grep 'citation-less' "$case_dir/stderr" \
    "citationless-no-verdict: refusal did not name missing citations"
  assert_absent "$case_dir/data/task-x1/crosscheck-ledger.json" \
    "citationless-no-verdict: malformed no-verdict result wrote a ledger"
  pass "crosscheck refuses citation-less clean output instead of passing"
}

test_reviewer_same_account_refuses() {
  local case_dir rc
  case_dir=$(make_repo_case same-account)
  write_json "$case_dir/reviewer.json" '{}'
  FM_TEST_REVIEWER_JSON="$case_dir/reviewer.json"
  export FM_TEST_REVIEWER_JSON

  set +e
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CROSSCHECK_TEST_LAB=firstmate-crosscheck-test-lab-v1 \
  FM_CROSSCHECK_REVIEWER_HARNESS=codex \
  FM_CROSSCHECK_REVIEWER_ACCOUNT_HOME="$case_dir/author" \
  FM_CROSSCHECK_REVIEWER_MODEL=gpt-5-review \
  FM_CROSSCHECK_RUNNER="$case_dir/runner.sh" \
  FM_TEST_PROMPT_LOG="$case_dir/prompt.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$CROSSCHECK" run task-x1 https://github.com/example/repo/pull/7 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "same-account: reviewer same as author should refuse"
  assert_grep 'author and reviewer account_home are identical' "$case_dir/stderr" \
    "same-account: refusal did not prove account isolation"
  pass "crosscheck refuses when reviewer account isolation cannot be proven"
}

test_reproduced_finding_blocks_and_persists
test_silence_on_prior_finding_is_no_verdict
test_claimed_fixed_without_mutation_still_blocks
test_verified_fixed_with_mutation_clears
test_citationless_clean_result_is_no_verdict
test_reviewer_same_account_refuses
