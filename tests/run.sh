#!/bin/sh
# Single sealed entry point for firstmate's behavior-test suite.
set -u
unset BASH_ENV

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
runner="$TEST_DIR/run-test.sh"
detached_runner="$TEST_DIR/run-detached.py"
result=0
lab_active=0
lab_owned=0
output_owned=0
suite_nested=${FM_TEST_SUITE_ACTIVE:-0}
reuse_lab=${FM_TEST_REUSE_HERDR_LAB:-0}
adoption_timeout=${FM_TEST_HERDR_ADOPTION_TIMEOUT_SECONDS:-30}
case "$reuse_lab" in
  0|1) ;;
  *)
    printf 'test isolation violation: FM_TEST_REUSE_HERDR_LAB must be 0 or 1: %s\n' \
      "$reuse_lab" >&2
    exit 97
    ;;
esac
case "$adoption_timeout" in
  *[!0-9]*|'')
    printf 'test isolation violation: FM_TEST_HERDR_ADOPTION_TIMEOUT_SECONDS must be an integer from 1 to 600: %s\n' \
      "$adoption_timeout" >&2
    exit 97
    ;;
esac
if [ "$adoption_timeout" -lt 1 ] || [ "$adoption_timeout" -gt 600 ]; then
  printf 'test isolation violation: FM_TEST_HERDR_ADOPTION_TIMEOUT_SECONDS must be an integer from 1 to 600: %s\n' \
    "$adoption_timeout" >&2
  exit 97
fi
export FM_TEST_SUITE_ACTIVE=1
FM_TEST_ORIGINAL_PATH=${FM_TEST_ORIGINAL_PATH:-$PATH}
FM_TEST_HERDR_CLIENT_HOME=${FM_TEST_HERDR_CLIENT_HOME:-$HOME}
FM_TEST_HERDR_LAB_STATE_DIR=${FM_TEST_HERDR_LAB_STATE_DIR:-${FM_HERDR_LAB_STATE_DIR:-${TMPDIR:-/tmp}/fm-herdr-lab-$(id -u)}}
FM_TEST_HERDR_CLIENT_BIN=$TEST_DIR/herdr-client-bin
export FM_TEST_ORIGINAL_PATH FM_TEST_HERDR_CLIENT_HOME FM_TEST_HERDR_LAB_STATE_DIR \
  FM_TEST_HERDR_CLIENT_BIN

fm_test_lab_call() {
  FM_HERDR_LAB_STATE_DIR="$FM_TEST_HERDR_LAB_STATE_DIR" \
    PATH="$FM_TEST_HERDR_CLIENT_BIN:$FM_TEST_ORIGINAL_PATH" \
    "$FM_TEST_HERDR_LAB_HELPER" "$@"
}

fm_test_lab_wait_running() {
  adoption_attempt=0
  adoption_attempt_limit=$((adoption_timeout * 5))
  while [ "$adoption_attempt" -lt "$adoption_attempt_limit" ]; do
    if fm_test_lab_call run "$FM_TEST_HERDR_LAB_SESSION" status --json \
      | jq -e --arg session "$FM_TEST_HERDR_LAB_SESSION" \
          '.server.running == true and .server.session == $session' >/dev/null 2>&1; then
      return 0
    fi
    adoption_attempt=$((adoption_attempt + 1))
    sleep 0.2
  done
  return 1
}

fm_test_lab_reset() (
  # A reused lab amortizes the expensive server provision, but its workspaces
  # are test state just like files under TMPDIR.  Close every workspace in the
  # owned session between entries so a passing or failing test cannot shape the
  # next one's expectations.  The helper pins every operation to the lab and
  # re-proves the live default-session tripwire before each close.
  reset_listing=$(fm_test_lab_call run "$FM_TEST_HERDR_LAB_SESSION" workspace list) \
    || return 1
  printf '%s' "$reset_listing" \
    | jq -e '(.result.workspaces | type) == "array"' >/dev/null 2>&1 \
    || return 1
  reset_ids=$(printf '%s' "$reset_listing" \
    | jq -r '.result.workspaces[]?.workspace_id // empty') \
    || return 1
  for reset_id in $reset_ids; do
    case "$reset_id" in
      w?*)
        case "${reset_id#w}" in
          *[!0-9A-Za-z]*|'') return 1 ;;
        esac
        ;;
      *) return 1 ;;
    esac
    fm_test_lab_call run "$FM_TEST_HERDR_LAB_SESSION" workspace close "$reset_id" \
      >/dev/null || return 1
  done
  reset_listing=$(fm_test_lab_call run "$FM_TEST_HERDR_LAB_SESSION" workspace list) \
    || return 1
  printf '%s' "$reset_listing" \
    | jq -e '(.result.workspaces | type) == "array" and (.result.workspaces | length) == 0' \
        >/dev/null 2>&1
)

fm_test_lab_cleanup() {
  cleanup_status=$?
  if [ "$lab_active" -eq 1 ] && [ "$lab_owned" -eq 1 ]; then
    fm_test_lab_call teardown "$FM_TEST_HERDR_LAB_SESSION" \
      || cleanup_status=1
    lab_active=0
  fi
  if [ "$output_owned" -eq 1 ]; then
    rm -rf "$FM_TEST_OUTPUT_DIR"
  fi
  trap - EXIT
  exit "$cleanup_status"
}
trap fm_test_lab_cleanup EXIT

fm_test_lab_rotate() {
  fm_test_lab_call teardown "$FM_TEST_HERDR_LAB_SESSION" \
    || return 1
  lab_active=0
  fm_test_lab_call provision "$FM_TEST_HERDR_LAB_SESSION" \
    || return 1
  lab_active=1
}

if [ -n "${FM_TEST_HERDR_LAB_SESSION:-}" ]; then
  FM_TEST_HERDR_LAB_HELPER=${FM_TEST_HERDR_LAB_HELPER:-${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}}
  case "$FM_TEST_HERDR_LAB_SESSION" in
    fm-lab-?*) ;;
    *)
      printf 'test isolation violation: refusing non-lab Herdr session: %s\n' \
        "$FM_TEST_HERDR_LAB_SESSION" >&2
      exit 97
      ;;
  esac
  FM_TEST_REAL_HERDR=$(PATH="$FM_TEST_ORIGINAL_PATH" command -v herdr) \
    || { printf 'test isolation violation: an adopted Herdr lab requires herdr\n' >&2; exit 69; }
  export FM_TEST_REAL_HERDR
  command -v jq >/dev/null 2>&1 \
    || { printf 'test isolation violation: an adopted Herdr lab requires jq\n' >&2; exit 69; }
  fm_test_lab_wait_running \
    || { printf 'test isolation violation: adopted Herdr lab did not report running within %s seconds: %s\n' \
          "$adoption_timeout" "$FM_TEST_HERDR_LAB_SESSION" >&2; exit 97; }
  lab_active=1
elif command -v herdr >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  FM_TEST_HERDR_LAB_HELPER=$ROOT/bin/fm-herdr-lab.sh
  FM_TEST_REAL_HERDR=$(command -v herdr)
  export FM_TEST_REAL_HERDR
  FM_TEST_HERDR_LAB_SESSION=$(fm_test_lab_call name firstmate-tests)
  export HERDR_LAB_HELPER="$FM_TEST_HERDR_LAB_HELPER"
  fm_test_lab_call provision "$FM_TEST_HERDR_LAB_SESSION" \
    || { printf 'test isolation violation: could not provision Herdr lab: %s\n' \
          "$FM_TEST_HERDR_LAB_SESSION" >&2; exit 97; }
  lab_active=1
  lab_owned=1
fi
if [ "$lab_active" -eq 1 ]; then
  export FM_TEST_HERDR_LAB_HELPER FM_TEST_HERDR_LAB_SESSION FM_TEST_REAL_HERDR
  if [ "$reuse_lab" -eq 1 ] && [ "$suite_nested" -eq 0 ]; then
    fm_test_lab_reset || {
      printf 'test isolation violation: reused Herdr lab did not reset to an empty workspace set before the suite: %s\n' \
        "$FM_TEST_HERDR_LAB_SESSION" >&2
      exit 97
    }
  fi
fi

if [ "$#" -eq 0 ]; then
  set -- "$TEST_DIR"/*.test.sh
fi
test_count=$#
test_index=0

command -v python3 >/dev/null 2>&1 \
  || { printf 'test isolation violation: detached test execution requires python3\n' >&2; exit 69; }
[ -x "$detached_runner" ] \
  || { printf 'test isolation violation: detached test runner is unavailable: %s\n' \
        "$detached_runner" >&2; exit 69; }
if [ -z "${FM_TEST_OUTPUT_DIR:-}" ]; then
  FM_TEST_OUTPUT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/firstmate-test-output.XXXXXX")
  output_owned=1
else
  mkdir -p "$FM_TEST_OUTPUT_DIR"
  FM_TEST_OUTPUT_DIR="$(cd "$FM_TEST_OUTPUT_DIR" && pwd -P)"
fi
export FM_TEST_OUTPUT_DIR

for test_script in "$@"; do
  test_index=$((test_index + 1))
  case "$test_script" in /*) ;; *) test_script="$ROOT/$test_script" ;; esac
  test_name=${test_script#"$ROOT/"}
  printf '== %s ==\n' "$test_name"
  artifact="$FM_TEST_OUTPUT_DIR/$(basename "$test_script" .test.sh).log"
  test_status=0
  "$detached_runner" "$artifact" -- "$runner" "$test_script" || test_status=$?
  if [ "$test_status" -ne 0 ]; then
    printf 'not ok - %s exited %s\n' "$test_name" "$test_status" >&2
    result=1
  fi
  if [ "$lab_active" -eq 1 ] && [ "$suite_nested" -eq 0 ]; then
    if [ "$reuse_lab" -eq 1 ]; then
      fm_test_lab_wait_running || fm_test_lab_call provision "$FM_TEST_HERDR_LAB_SESSION" \
        || {
          printf 'test isolation violation: reused Herdr lab could not be restored after %s: %s\n' \
            "$test_name" "$FM_TEST_HERDR_LAB_SESSION" >&2
          result=1
          break
        }
      fm_test_lab_wait_running && fm_test_lab_reset || {
        printf 'test isolation violation: reused Herdr lab retained test state after %s: %s\n' \
          "$test_name" "$FM_TEST_HERDR_LAB_SESSION" >&2
        result=1
        break
      }
    elif [ "$test_index" -lt "$test_count" ]; then
      fm_test_lab_rotate || {
        printf 'test isolation violation: Herdr lab rotation or default-session tripwire failed after %s\n' \
          "$test_name" >&2
        result=1
        break
      }
    fi
  fi
done

exit "$result"
