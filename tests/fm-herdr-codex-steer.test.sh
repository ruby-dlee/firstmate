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

test_every_unbound_text_adapter_refuses
