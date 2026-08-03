#!/usr/bin/env bash
# Herdr steering must not invoke native agent send for Codex.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"

fm_test_tmproot_into TMP_ROOT fm-herdr-codex-steer
LOG="$TMP_ROOT/herdr.log"

fm_backend_herdr_target_ready() {
  FM_BACKEND_HERDR_SESSION=default
  FM_BACKEND_HERDR_PANE=w1:p2
}
fm_backend_herdr_control_jq() { jq "$@"; }
fm_backend_herdr_cli() {
  local session=$1; shift
  printf '%s %s\n' "$session" "$*" >> "$LOG"
  case "$*" in
    'agent get w1:p2') printf '{"result":{"agent":{"agent":"%s"}}}\n' "$FM_TEST_AGENT" ;;
  esac
}

test_codex_uses_literal_pane_delivery() {
  : > "$LOG"
  FM_TEST_AGENT=codex fm_backend_herdr_send_literal default:w1:p2 'keep profile'
  assert_grep 'pane send-text w1:p2 keep profile' "$LOG" "Codex steer did not use literal pane input"
  assert_no_grep 'agent send' "$LOG" "Codex steer invoked the thread-settings-resetting native route"
  pass "Herdr Codex steering bypasses native agent send"
}

test_other_agents_retain_native_delivery() {
  : > "$LOG"
  FM_TEST_AGENT=claude fm_backend_herdr_send_literal default:w1:p2 'native steer'
  assert_grep 'agent send w1:p2 native steer' "$LOG" "non-Codex agent lost native delivery"
  assert_no_grep 'pane send-text' "$LOG" "non-Codex agent was routed through the Codex exception"
  pass "Herdr keeps native delivery for non-Codex agents"
}

test_agentless_pane_refuses() {
  : > "$LOG"
  if FM_TEST_AGENT='' fm_backend_herdr_send_literal default:w1:p2 'shell hazard'; then
    fail "agent-less Herdr pane accepted steering"
  fi
  assert_no_grep 'send-text\|agent send' "$LOG" "agent-less pane received instruction text"
  pass "Herdr refuses to steer an agent-less shell pane"
}

test_codex_uses_literal_pane_delivery
test_other_agents_retain_native_delivery
test_agentless_pane_refuses
