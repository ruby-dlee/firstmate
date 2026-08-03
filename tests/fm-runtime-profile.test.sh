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
  local dir file out rc
  dir=$(make_case substituted); file="$dir/codex/sessions/2026/08/02/rollout-substituted.jsonl"
  write_session "$file" session-new
  write_context "$file" 2026-08-02T20:00:00Z "$dir/wt" gpt-5.6-sol xhigh
  write_settings "$file" 2026-08-02T20:05:00Z "$dir/wt" gpt-5.6-luna medium
  FM_HOME="$dir/home" "$VERIFY" lane >"$dir/out" 2>"$dir/err"; rc=$?
  expect_code 1 "$rc" "later runtime substitution must fail"
  assert_grep 'model=gpt-5.6-luna effort=medium' "$dir/err" "mismatch did not report the observed runtime"
  write_settings "$file" 2026-08-02T20:06:00Z "$dir/wt" gpt-5.6-sol xhigh
  out=$(FM_HOME="$dir/home" "$VERIFY" lane) || fail "restored exact runtime remained mismatched"
  assert_contains "$out" 'verified: Codex runtime model=gpt-5.6-sol effort=xhigh' \
    "restored runtime did not retire the violation"
  pass "runtime profile rejects and then retires a real post-launch substitution"
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

test_missing_session_binding_is_unverified() {
  local dir file meta_tmp rc
  dir=$(make_case missing-session-binding)
  file="$dir/codex/sessions/2026/08/02/rollout-sibling.jsonl"
  write_session "$file" session-sibling
  write_context "$file" 2026-08-02T20:00:00Z "$dir/wt" gpt-5.6-sol xhigh
  meta_tmp=$(mktemp "$dir/home/state/.lane.meta.XXXXXX")
  grep -v '^provider_session_id=' "$dir/home/state/lane.meta" > "$meta_tmp"
  mv "$meta_tmp" "$dir/home/state/lane.meta"
  FM_HOME="$dir/home" "$VERIFY" lane >"$dir/out" 2>"$dir/err"; rc=$?
  expect_code 2 "$rc" "an unbound Codex generation must remain unverified"
  assert_grep 'Codex runtime profile UNVERIFIED because provider session identity is unavailable' "$dir/err" \
    "missing session identity fell back to a neighboring rollout"
  assert_no_grep 'verified:' "$dir/out" "unbound generation emitted a positive runtime verdict"
  pass "runtime profile refuses every unbound Codex generation instead of guessing a session"
}

test_mismatched_session_skips_large_tail_within_total_budget() {
  local dir file good rc out
  dir=$(make_case bounded-mismatch)
  file="$dir/codex/sessions/2026/08/02/rollout-other.jsonl"
  write_session "$file" session-other
  dd if=/dev/zero bs=1048576 count=2 >> "$file" 2>/dev/null
  FM_CODEX_PROFILE_TOTAL_BYTES=131072 FM_HOME="$dir/home" "$VERIFY" lane >"$dir/out" 2>"$dir/err"; rc=$?
  expect_code 2 "$rc" "mismatched session should be rejected from its cheap head"
  assert_no_grep 'byte budget exceeded' "$dir/err" "mismatched session consumed its large tail budget"
  rm -f "$file"
  file="$dir/codex/sessions/2026/08/02/rollout-current-large.jsonl"
  write_session "$file" session-new
  dd if=/dev/zero bs=1048576 count=2 >> "$file" 2>/dev/null
  FM_CODEX_PROFILE_TOTAL_BYTES=131072 FM_HOME="$dir/home" "$VERIFY" lane >"$dir/out" 2>"$dir/err"; rc=$?
  expect_code 2 "$rc" "matching session must still respect the total scan budget"
  assert_grep 'byte budget exceeded' "$dir/err" "total runtime scan budget did not fail closed"
  rm -f "$file"
  good="$dir/codex/sessions/2026/08/02/rollout-good.jsonl"
  write_session "$good" session-new
  write_context "$good" 2026-08-02T20:00:00Z "$dir/wt" gpt-5.6-sol xhigh
  out=$(FM_CODEX_PROFILE_TOTAL_BYTES=131072 FM_HOME="$dir/home" "$VERIFY" lane) \
    || fail "matching bounded runtime was not accepted after mismatch retirement"
  assert_contains "$out" 'verified: Codex runtime' "bounded runtime repair omitted verification"
  pass "runtime scanning rejects mismatched sessions before bounded tail reads"
}

test_matching_runtime_passes
test_later_substitution_fails
test_previous_generation_is_not_runtime_proof
test_missing_runtime_is_unknown
test_missing_session_binding_is_unverified
test_mismatched_session_skips_large_tail_within_total_budget
