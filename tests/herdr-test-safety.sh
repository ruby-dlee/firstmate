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

# A suite-owned lab has already been provisioned through the guarded helper.
# Keep real E2E adapter calls on PATH so the sealed Herdr launcher can route
# them through that same helper instead of the production account-binary path.
if [ -n "${FM_TEST_HERDR_LAB_SESSION:-}" ]; then
  export FM_BACKEND_HERDR_TEST_LAB=firstmate-herdr-test-lab-v1
fi

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

herdr_test_session() { # <fallback-label>
  if [ -n "${FM_TEST_HERDR_LAB_SESSION:-}" ]; then
    printf '%s\n' "$FM_TEST_HERDR_LAB_SESSION"
  else
    fm_herdr_lab_name "$1"
  fi
}

herdr_test_prepare() { # <session>
  if [ -n "${FM_TEST_HERDR_LAB_SESSION:-}" ] \
    && [ "$1" = "$FM_TEST_HERDR_LAB_SESSION" ]; then
    return 0
  fi
  fm_herdr_lab_prepare "$1"
}

herdr_safe_stop_and_delete() { # <session>
  if [ -n "${FM_TEST_HERDR_LAB_SESSION:-}" ] \
    && [ "$1" = "$FM_TEST_HERDR_LAB_SESSION" ]; then
    return 0
  fi
  fm_herdr_lab_teardown "$1"
}

herdr_test_stop() { # <session>
  if [ -n "${FM_TEST_HERDR_LAB_SESSION:-}" ] \
    && [ "$1" = "$FM_TEST_HERDR_LAB_SESSION" ]; then
    FM_HERDR_LAB_STATE_DIR="$FM_TEST_HERDR_LAB_STATE_DIR" \
      PATH="$FM_TEST_HERDR_CLIENT_BIN:$FM_TEST_ORIGINAL_PATH" \
      "$FM_TEST_HERDR_LAB_HELPER" stop "$1"
    return
  fi
  fm_herdr_lab_stop "$1"
}

herdr_test_provision() { # <session>
  if [ -n "${FM_TEST_HERDR_LAB_SESSION:-}" ] \
    && [ "$1" = "$FM_TEST_HERDR_LAB_SESSION" ]; then
    # A provisioned server intentionally survives this helper invocation.
    # Launch the lifecycle helper in its own session so that server is owned by
    # the suite lab, not by this test's disposable process group. The public
    # runner already requires Python for its caller-fatal detached boundary.
    python3 - "$FM_TEST_HERDR_LAB_HELPER" "$1" \
      "$FM_TEST_HERDR_LAB_STATE_DIR" "$FM_TEST_HERDR_CLIENT_BIN:$FM_TEST_ORIGINAL_PATH" \
      "$FM_TEST_HERDR_CLIENT_HOME" "$FM_TEST_REAL_HERDR" <<'PY'
import os
import subprocess
import sys

helper, session, state_dir, path, client_home, real_herdr = sys.argv[1:]
# The long-lived lab server is suite infrastructure, not a child of this
# disposable test sandbox.  Give the lifecycle helper a closed environment:
# inheriting BASH_ENV would make every restored pane source a guard whose
# sandbox is deleted as soon as this one test exits, while inheriting FM_HOME
# or pool roots would let server-side shells retain per-test operational state.
environment = {
    "FM_HERDR_LAB_STATE_DIR": state_dir,
    "FM_TEST_HERDR_CLIENT_HOME": client_home,
    "FM_TEST_REAL_HERDR": real_herdr,
    "HERDR_SESSION": session,
    "HOME": client_home,
    "PATH": path,
}
for name in ("LANG", "LC_ALL", "LC_CTYPE", "TERM", "TMPDIR"):
    if name in os.environ:
        environment[name] = os.environ[name]
if "FM_HERDR_LAB_PROVISION_TIMEOUT_SECONDS" in os.environ:
    environment["FM_HERDR_LAB_PROVISION_TIMEOUT_SECONDS"] = os.environ[
        "FM_HERDR_LAB_PROVISION_TIMEOUT_SECONDS"
    ]
raise SystemExit(
    subprocess.call(
        [helper, "provision", session],
        env=environment,
        start_new_session=True,
    )
)
PY
    return
  fi
  fm_herdr_lab_provision "$1"
}
