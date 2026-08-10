#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

fm_test_tmproot_into TMP_ROOT fm-blocker-discipline-gap
STATUS="$TMP_ROOT/lane.status"

test_blocker_proof_matrix() {
  local line open
  for line in \
    'blocked [key=bad]: database is unavailable' \
    'blocked [key=bad]: assumption=none; test=will run probe; result=pending' \
    'blocked [key=bad]: assumption=will investigate access; test=curl health endpoint; result=HTTP 403' \
    'blocked [key=bad]: assumption=unknown; test=curl health endpoint; result=not yet' \
    'blocked [key=bad]: assumption=credentials are rejected; test=curl health endpoint; result=would expect HTTP 403' \
    'blocked [key=bad]: assumption=credentials are rejected; test=pending; result=401 observed'; do
    : > "$STATUS"
    printf '%s\n' "$line" >> "$STATUS"
    [ -z "$(status_open_decisions "$STATUS")" ] \
      || fail "malformed or placeholder blocker entered the open set: $line"
  done

  : > "$STATUS"
  printf '%s\n' \
    'blocked [key=auth]: assumption=the token lacks repository scope; test=gh-axi repo view ruby-dlee/firstmate; result=command exited 1 with HTTP 403' \
    >> "$STATUS"
  open=$(status_open_decisions "$STATUS")
  assert_contains "$open" $'auth\tblocked\tassumption=the token lacks repository scope; test=gh-axi repo view ruby-dlee/firstmate; result=command exited 1 with HTTP 403' \
    "executed falsifiable blocker proof was rejected"
  printf '%s\n' 'resolved [key=auth]: refreshed the scoped token and the same probe succeeded' >> "$STATUS"
  [ -z "$(status_open_decisions "$STATUS")" ] \
    || fail "resolution did not retire the proved blocker"
  pass "blocker fold accepts only executed falsifiable proof and explicit resolution"
}

test_blocker_proof_matrix
