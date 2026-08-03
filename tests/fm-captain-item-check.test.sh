#!/usr/bin/env bash
# Behavior tests for the captain-facing risk and decision item gate.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-captain-item-check.sh"
FIXTURES="$ROOT/tests/fixtures/captain-item-check"
TMP_ROOT=$(fm_test_tmproot captain-item-check)

run_check() {
  local mode=$1 file=$2 rc
  : > "$TMP_ROOT/output"
  set +e
  "$CHECK" "$mode" "$file" > "$TMP_ROOT/output" 2>&1
  rc=$?
  set -e
  printf '%s\n' "$rc"
}

assert_required_failures() {
  local item=$1 rc element
  rc=$(run_check risk "$FIXTURES/negative/$item.txt")
  [ "$rc" -eq 1 ] || fail "$item returned $rc instead of rejecting the draft"
  for element in system-purpose business-impact tradeoff.fix-cost tradeoff.leave-cost decision; do
    grep -F "missing: $element" "$TMP_ROOT/output" >/dev/null \
      || fail "$item did not report missing $element"
  done
  pass "$item: FAIL; missing system-purpose, business-impact, tradeoff.fix-cost, tradeoff.leave-cost, decision"
}

assert_positive_clear() {
  local item=$1 rc
  rc=$(run_check risk "$FIXTURES/positive/$item.md")
  if [ "$rc" -ne 0 ]; then
    cat "$TMP_ROOT/output" >&2
    fail "$item positive control returned $rc instead of clearing"
  fi
  grep -F 'captain-item-check: CLEAR' "$TMP_ROOT/output" >/dev/null \
    || fail "$item positive control did not print CLEAR"
  pass "$item rewrite: CLEAR"
}

test_negative_controls() {
  local item
  for item in risk-billing risk-privacy risk-delete risk-cron; do
    assert_required_failures "$item"
  done
}

test_positive_controls() {
  local item
  for item in risk-billing risk-privacy risk-delete risk-cron; do
    assert_positive_clear "$item"
  done
}

test_decision_mode() {
  local rc
  rc=$(run_check decision "$FIXTURES/positive/risk-billing.md")
  [ "$rc" -eq 0 ] || fail "decision mode rejected a complete item"
  grep -F 'mode=decision' "$TMP_ROOT/output" >/dev/null \
    || fail "decision mode was not reported"
  pass "decision mode accepts a complete item"
}

test_opaque_mechanism_fails() {
  local rc
  cp "$FIXTURES/positive/risk-billing.md" "$TMP_ROOT/opaque.md"
  printf '\nThe ClickHouse pointer guard passed 97 tests on main at worker.py:97.\n' >> "$TMP_ROOT/opaque.md"
  rc=$(run_check risk "$TMP_ROOT/opaque.md")
  [ "$rc" -eq 1 ] || fail "opaque engineering language did not fail"
  grep -F "opaque: internal term 'ClickHouse'" "$TMP_ROOT/output" >/dev/null \
    || fail "opaque engineering language did not identify ClickHouse"
  grep -F "opaque: engineering reference" "$TMP_ROOT/output" >/dev/null \
    || fail "opaque engineering evidence did not get a specific failure"
  pass "opaque mechanism and engineering evidence fail specifically"
}

test_usage_and_file_errors() {
  local rc
  rc=$(run_check invalid "$FIXTURES/positive/risk-billing.md")
  [ "$rc" -eq 2 ] || fail "invalid mode returned $rc instead of 2"
  rc=$(run_check risk "$TMP_ROOT/missing.md")
  [ "$rc" -eq 2 ] || fail "missing file returned $rc instead of 2"
  grep -F 'unreadable item file' "$TMP_ROOT/output" >/dev/null \
    || fail "missing file did not report the exact error"
  pass "invalid usage and unreadable files return 2"
}

test_wiring() {
  # shellcheck disable=SC2016  # These are literal tracked Markdown fragments.
  grep -F 'require `bin/fm-captain-item-check.sh` to clear' "$ROOT/AGENTS.md" >/dev/null \
    || fail "AGENTS.md does not require the check before surfacing an item"
  # shellcheck disable=SC2016  # These are literal tracked Markdown fragments.
  grep -F 'run `bin/fm-captain-item-check.sh` as documented for every item' \
    "$ROOT/.agents/skills/lavish-decisions/SKILL.md" >/dev/null \
    || fail "lavish-decisions does not invoke the check before creation"
  pass "always-loaded and Lavish workflows invoke the check"
}

test_negative_controls
test_positive_controls
test_decision_mode
test_opaque_mechanism_fails
test_usage_and_file_errors
test_wiring
