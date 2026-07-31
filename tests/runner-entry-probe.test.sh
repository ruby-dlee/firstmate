#!/usr/bin/env bash
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ "$BASH_ENV" = "$FM_TEST_GUARD_ENV" ] || fail "runner entry probe did not inherit the mandatory guard"
effective_state=${FM_STATE_OVERRIDE:-$FM_HOME/state}
[ "$FM_TEST_INITIAL_STATE_OVERRIDE" = "$FM_HOME/state" ] \
  || fail "runner entry probe lost its explicit initial state proof"
case "$HOME:$FM_HOME:$effective_state:$FM_TREEHOUSE_ROOT" in
  "$FM_TEST_SANDBOX_ROOT"/*:"$FM_TEST_SANDBOX_ROOT"/*:"$FM_TEST_SANDBOX_ROOT"/*:"$FM_TEST_SANDBOX_ROOT"/*) ;;
  *) fail "runner entry probe inherited an operational path outside its sandbox" ;;
esac
status=0
out=$(bash -c 'kill -0 "$FM_TEST_OUTSIDE_PID"' 2>&1) || status=$?
[ "$status" -eq 97 ] || fail "runner entry probe reached its outside PID: $out"
pass runner-entry-probe-ok
