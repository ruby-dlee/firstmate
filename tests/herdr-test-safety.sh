#!/usr/bin/env bash
# Compatibility source for real-Herdr tests.
# The production owner of the isolation, refuse-default, teardown, and
# fleet-state tripwire contract is bin/fm-herdr-lab.sh.
set -u

# Herdr backend tests drive the real fm-spawn/fm-teardown.
# Behavior entries already inherit this exemption from tests/lib.sh; retain it
# here as well so the safety compatibility helper remains self-contained (see
# bin/fm-gate-refuse-lib.sh for the gate-worktree rationale).
export FM_GATE_REFUSE_BYPASS=1

HERDR_TEST_SAFETY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-herdr-lab.sh
. "$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh"

herdr_refuse_if_default() { # <session>
  fm_herdr_lab_refuse_if_default "$1"
}

# Real-Herdr suites must never start or otherwise repair the captain's default
# session just to satisfy a test precondition. Treat a missing, unreadable, or
# stopped default as an unavailable external lab baseline and skip cleanly;
# the deterministic fm-herdr-lab unit suite owns refusal coverage.
herdr_test_lab_available() { # <session>
  if fm_herdr_lab_require_default_running "$1" "isolated test setup"; then
    return 0
  fi
  echo "skip: default Herdr session is not running; isolated lab tests will not start or mutate it"
  return 1
}

herdr_safe_stop_and_delete() { # <session>
  fm_herdr_lab_teardown "$1"
}
