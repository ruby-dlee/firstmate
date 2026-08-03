#!/usr/bin/env bash
# fm-gate-test.sh - run the complete configured gate test command.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 1

command -v tmux >/dev/null || { echo "tmux is required for e2e tests" >&2; exit 1; }
tmux -V
rc=0
for test_script in tests/*.test.sh; do
  echo "== $test_script =="
  bash "$test_script" || rc=1
done
uv run --directory tools/agent-fleet --locked pytest || rc=1
uv run --directory tools/agent-fleet --locked python -m compileall -q src || rc=1
exit "$rc"
