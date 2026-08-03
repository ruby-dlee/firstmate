#!/usr/bin/env bash
# Codex harness-owned runtime profile verification tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VERIFY="$ROOT/bin/fm-runtime-profile.sh"
fm_test_tmproot_into TMP_ROOT fm-runtime-profile

make_case() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/codex/sessions/2026/08/02" "$dir/wt"
  fm_write_meta "$dir/home/state/lane.meta" \
    "harness=codex" "model=gpt-5.6-sol" "effort=xhigh" \
    "worktree=$dir/wt" "runtime_home=$dir/codex" \
    "runtime_started_at_ns=1785700000000000000" "provider_session_id=session-new"
  printf '%s\n' "$dir"
}

write_context() {
  local file=$1 timestamp=$2 worktree=$3 model=$4 effort=$5
  printf '{"timestamp":"%s","type":"turn_context","payload":{"cwd":"%s","model":"%s","reasoning_effort":"%s"}}\n' \
    "$timestamp" "$worktree" "$model" "$effort" >> "$file"
}

write_session() {
  local file=$1 session=$2
  printf '{"timestamp":"2026-08-02T19:59:59Z","type":"session_meta","payload":{"id":"%s"}}\n' \
    "$session" >> "$file"
}

write_settings() {
  local file=$1 timestamp=$2 worktree=$3 model=$4 effort=$5
  printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"cwd":"%s","model":"%s","reasoning_effort":"%s"}}}\n' \
    "$timestamp" "$worktree" "$model" "$effort" >> "$file"
}

test_matching_runtime_passes() {
  local dir file out
  dir=$(make_case matching); file="$dir/codex/sessions/2026/08/02/rollout-match.jsonl"
  write_session "$file" session-new
  write_context "$file" 2026-08-02T20:00:00Z "$dir/wt" gpt-5.6-sol xhigh
  out=$(FM_HOME="$dir/home" "$VERIFY" lane) || fail "matching runtime was refused"
  assert_contains "$out" 'verified: Codex runtime model=gpt-5.6-sol effort=xhigh' "matching receipt omitted the runtime axes"
  pass "runtime profile verifies Codex's own exact model and effort record"
}

test_later_substitution_fails() {
  local dir file rc
  dir=$(make_case substituted); file="$dir/codex/sessions/2026/08/02/rollout-substituted.jsonl"
  write_session "$file" session-new
  write_context "$file" 2026-08-02T20:00:00Z "$dir/wt" gpt-5.6-sol xhigh
  write_settings "$file" 2026-08-02T20:05:00Z "$dir/wt" gpt-5.6-luna medium
  FM_HOME="$dir/home" "$VERIFY" lane >"$dir/out" 2>"$dir/err"; rc=$?
  expect_code 1 "$rc" "later runtime substitution must fail"
  assert_grep 'model=gpt-5.6-luna effort=medium' "$dir/err" "mismatch did not report the observed runtime"
  pass "runtime profile detects a post-launch Codex substitution"
}

test_previous_generation_is_not_runtime_proof() {
  local dir old_file new_file rc
  dir=$(make_case prior-generation)
  old_file="$dir/codex/sessions/2026/08/02/rollout-old.jsonl"
  new_file="$dir/codex/sessions/2026/08/02/rollout-new.jsonl"
  write_session "$old_file" session-old
  write_context "$old_file" 2026-08-02T20:00:00Z "$dir/wt" gpt-5.6-sol xhigh
  write_session "$new_file" session-new
  write_context "$new_file" 2026-08-02T19:00:00Z "$dir/wt" gpt-5.6-sol xhigh
  FM_HOME="$dir/home" "$VERIFY" lane >"$dir/out" 2>"$dir/err"; rc=$?
  expect_code 2 "$rc" "an older generation must not verify the current runtime"
  assert_grep 'session session-new' "$dir/err" "stale-generation refusal omitted the session binding"
  pass "runtime profile rejects matching records from another generation"
}

test_missing_runtime_is_unknown() {
  local dir rc
  dir=$(make_case missing)
  FM_HOME="$dir/home" "$VERIFY" lane >"$dir/out" 2>"$dir/err"; rc=$?
  expect_code 2 "$rc" "missing runtime record must be unknown"
  assert_grep 'unknown:' "$dir/err" "missing runtime was not fail-closed"
  pass "runtime profile never turns an unreadable harness record into success"
}

test_matching_runtime_passes
test_later_substitution_fails
test_previous_generation_is_not_runtime_proof
test_missing_runtime_is_unknown
