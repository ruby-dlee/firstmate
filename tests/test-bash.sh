#!/bin/sh
if [ "${FM_TEST_SEALED:-}" != firstmate-test-v1 ] || [ -z "${FM_TEST_GUARD_ENV:-}" ] || [ -z "${FM_TEST_REAL_BASH:-}" ]; then
  printf '%s\n' 'test isolation violation: sealed Bash launcher is not configured' >&2
  exit 97
fi
unset ENV
export BASH_ENV=$FM_TEST_GUARD_ENV
exec "$FM_TEST_REAL_BASH" "$@"
