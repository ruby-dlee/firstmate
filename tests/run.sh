#!/usr/bin/env bash
# Single sealed entry point for firstmate's behavior-test suite.
set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
runner="$TEST_DIR/run-test.sh"
result=0

if [ "$#" -eq 0 ]; then
  set -- "$TEST_DIR"/*.test.sh
fi

for test_script in "$@"; do
  case "$test_script" in /*) ;; *) test_script="$ROOT/$test_script" ;; esac
  printf '== %s ==\n' "${test_script#"$ROOT/"}"
  "$runner" "$test_script" || result=1
done

exit "$result"
