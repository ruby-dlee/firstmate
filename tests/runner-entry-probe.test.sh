#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
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
expected_guard_log="$TMPDIR/runner-entry-expected-guard.log"
out=$(FM_TEST_ISOLATION_LOG="$expected_guard_log" \
  bash -c 'kill -0 "$FM_TEST_OUTSIDE_PID"' 2>&1) || status=$?
[ "$status" -eq 97 ] || fail "runner entry probe reached its outside PID: $out"
rm -f "$expected_guard_log"
if [ "${FM_TEST_PROBE_SWALLOWED_GUARD:-}" = 1 ]; then
  bash -c 'kill -0 "$FM_TEST_OUTSIDE_PID"' >/dev/null 2>&1 || true
fi
if [ "${FM_TEST_PROBE_NESTED_CLEANUP:-}" = 1 ]; then
  bash -c '. "$1"' _ "$ROOT/tests/lib.sh" \
    || fail "nested helper shell did not exit cleanly"
fi
if [ "${FM_TEST_PROBE_ORPHAN:-}" = 1 ]; then
  bash -c 'sleep 300 &'
fi
pass runner-entry-probe-ok
if [ -n "${FM_TEST_RUNNER_PROBE_EXIT:-}" ]; then
  case "$FM_TEST_RUNNER_PROBE_EXIT" in
    *[!0-9]*|'') fail "runner entry probe received an invalid forced exit" ;;
  esac
  exit "$FM_TEST_RUNNER_PROBE_EXIT"
fi
