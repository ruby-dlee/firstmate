#!/usr/bin/env bash
# Behavioral coverage for the blocker-assumption carrier gate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

fm_test_tmproot_into TMP_ROOT fm-blocker-discipline-gap
STATUS="$TMP_ROOT/lane.status"

test_unproved_blocker_cannot_enter_open_set() {
  local open
  printf 'blocked [key=premise]: database is unavailable\n' >> "$STATUS"
  status_is_captain_relevant "$(last_status_line "$STATUS")" \
    || fail "malformed blocker did not remain visible for repair"
  open=$(status_open_decisions "$STATUS")
  [ -z "$open" ] || fail "unproved blocker entered the durable open-decision set: $open"
  pass "blocker carrier rejects a missing assumption, test, and result without hiding the bad event"
}

test_placeholder_proof_is_rejected() {
  local open
  : > "$STATUS"
  printf '%s\n' \
    'blocked [key=premise]: assumption=database is unavailable; test=not run; result=unknown' \
    >> "$STATUS"
  open=$(status_open_decisions "$STATUS")
  [ -z "$open" ] || fail "placeholder blocker proof entered the durable open set: $open"
  pass "blocker carrier rejects placeholder probes and observations"
}

test_proved_blocker_opens_and_resolves() {
  local open
  : > "$STATUS"
  printf '%s\n' \
    'blocked [key=premise]: assumption=scheduler is in launch-only mode; test=query the live scheduler mode; result=live mode is launch-only' \
    >> "$STATUS"
  open=$(status_open_decisions "$STATUS")
  assert_contains "$open" \
    $'premise\tblocked\tassumption=scheduler is in launch-only mode; test=query the live scheduler mode; result=live mode is launch-only' \
    "proved blocker did not enter the durable open set"
  printf 'resolved [key=premise]: scheduler mode changed\n' >> "$STATUS"
  [ -z "$(status_open_decisions "$STATUS")" ] \
    || fail "explicit resolution did not retire the proved blocker"
  pass "blocker carrier opens only the structured premise and mechanical observation"
}

test_unproved_blocker_cannot_enter_open_set
test_placeholder_proof_is_rejected
test_proved_blocker_opens_and_resolves
