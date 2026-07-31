#!/usr/bin/env bash
# External kill shim used when a test deliberately bypasses shell functions
# with `command kill`. BASH_ENV has already loaded test-env-guard.sh here.
set -u

fm_test_isolation_guard_kill_args "$@"
"$FM_TEST_GUARD_REAL_KILL" "$@"
