#!/usr/bin/env bash
# Text steering must refuse every pane adapter without a session-bound submit.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

fm_test_tmproot_into TMP_ROOT fm-herdr-codex-steer
LOG="$TMP_ROOT/herdr.log"

test_every_unbound_text_adapter_refuses() {
  local backend rc
  unset FM_BACKEND_HERDR_TEST_LAB
  : > "$LOG"
  for backend in tmux herdr zellij orca cmux; do
    fm_backend_send_steering "$backend" fixture:target 'shell hazard' >"$TMP_ROOT/$backend.out" 2>"$TMP_ROOT/$backend.err"; rc=$?
    expect_code 1 "$rc" "$backend text steering must refuse without atomic session binding"
    assert_grep "no atomic agent-session-bound text steering operation" "$TMP_ROOT/$backend.err" \
      "$backend refusal omitted the exact missing primitive"
  done
  [ ! -s "$LOG" ] || fail "refused adapter steering invoked a pane or native agent command"
  pass "all pane-backed text adapters refuse unbound steering"
}

test_exact_lab_token_admits_only_atomic_herdr_line() {
  local out rc
  fm_backend_source herdr || fail "could not source the Herdr backend"
  fm_backend_herdr_send_text_line() {
    printf '%s\t%s\n' "$1" "$2" >> "$LOG"
  }
  : > "$LOG"
  FM_BACKEND_HERDR_TEST_LAB=wrong-token \
    fm_backend_send_steering herdr fixture:target 'lab message' >"$TMP_ROOT/wrong.out" 2>"$TMP_ROOT/wrong.err"; rc=$?
  expect_code 1 "$rc" "a noncanonical Herdr lab token must refuse"
  [ ! -s "$LOG" ] || fail "a noncanonical lab token reached the atomic adapter"
  out=$(FM_BACKEND_HERDR_TEST_LAB=firstmate-herdr-test-lab-v1 \
    FM_BACKEND_HERDR_ATOMIC_STEERING_TEST_LAB=firstmate-herdr-atomic-steering-test-lab-v1 \
    fm_backend_send_steering herdr fixture:target 'lab message') || fail "the exact lab token did not reach the atomic adapter"
  [ "$out" = confirmed ] || fail "the exact lab adapter returned '$out', expected confirmed"
  assert_contains "$(cat "$LOG")" $'fixture:target\tlab message' "the lab route did not use the atomic Herdr text-line operation"
  pass "exact Herdr test-lab token admits only the atomic text-line adapter"
}

test_every_unbound_text_adapter_refuses
test_exact_lab_token_admits_only_atomic_herdr_line
