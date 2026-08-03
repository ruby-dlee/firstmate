#!/usr/bin/env bash
# Behavioral evidence for the blocker-discipline carrier gap.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

fm_test_tmproot_into TMP_ROOT fm-blocker-discipline-gap
STATUS="$TMP_ROOT/lane.status"

test_unproved_blocker_remains_reachable_and_is_then_retired() {
  local open
  printf 'blocked [key=premise]: database is unavailable\n' >> "$STATUS"
  status_is_captain_relevant "$(last_status_line "$STATUS")" \
    || fail "production classifier did not expose the reachable blocker carrier"
  open=$(status_open_decisions "$STATUS")
  assert_contains "$open" $'premise\tblocked\tdatabase is unavailable' \
    "production decision fold did not accept the unproved blocker"
  printf 'resolved [key=premise]: premise withdrawn because no test was recorded\n' >> "$STATUS"
  [ -z "$(status_open_decisions "$STATUS")" ] \
    || fail "explicit resolution did not retire the reachable unproved blocker"
  pass "blocker mutation proves the mandatory structured-proof guard is still absent"
}

test_unproved_blocker_remains_reachable_and_is_then_retired
