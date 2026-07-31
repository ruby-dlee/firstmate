#!/usr/bin/env bash
# Contract tests for the sealed behavior-test harness and its hard path guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/tests/test-env-guard.sh"
RUNNER="$ROOT/tests/run-test.sh"

test_every_entry_sources_the_shared_harness() {
  local test_script missing=
  for test_script in "$ROOT"/tests/*.test.sh; do
    if ! grep -E '^[[:space:]]*(\.|source)[[:space:]].*lib\.sh' "$test_script" >/dev/null; then
      missing="$missing ${test_script#"$ROOT/"}"
    fi
  done
  [ -z "$missing" ] || fail "test entry points bypass tests/lib.sh:$missing"
  pass "test isolation: every behavior test enters through the shared sealed harness"
}

assert_guard_rejects() {  # <label> <expected-path> <environment assignment...>
  local label=$1 expected=$2 out status=0
  shift 2
  out=$(env "$@" bash -c ':' 2>&1) || status=$?
  [ "$status" -eq 97 ] || fail "$label: guard returned $status instead of 97: $out"
  assert_contains "$out" 'test isolation violation:' "$label: hard-failure prefix missing"
  assert_contains "$out" "$expected" "$label: diagnostic omitted the offending path"
}

test_guard_rejects_external_operational_paths() {
  assert_guard_rejects "external home" "$ROOT" FM_HOME="$ROOT"
  assert_guard_rejects "external state" "$ROOT/state" FM_STATE_OVERRIDE="$ROOT/state"
  assert_guard_rejects "external pool" "$ROOT/.treehouse" FM_TREEHOUSE_ROOT="$ROOT/.treehouse"
  pass "test isolation: home, state, and pool paths outside the sandbox hard-fail loudly"
}

test_guard_rejects_symlink_escape() {
  local link out status=0
  link="$TMPDIR/escaped-home"
  ln -s "$ROOT" "$link"
  out=$(FM_HOME="$link" bash -c ':' 2>&1) || status=$?
  [ "$status" -eq 97 ] || fail "symlink escape: guard returned $status instead of 97: $out"
  assert_contains "$out" "$link" "symlink escape: diagnostic omitted the offending path"
  assert_contains "$out" "$ROOT" "symlink escape: diagnostic omitted the physical destination"
  pass "test isolation: a sandbox path that resolves outward hard-fails"
}

test_guard_rejects_lock_symlink_escape() {
  local out status=0
  ln -s "$ROOT" "$FM_HOME/state/.watch.lock"
  out=$(bash -c ':' 2>&1) || status=$?
  rm -f "$FM_HOME/state/.watch.lock"
  [ "$status" -eq 97 ] || fail "watcher lock symlink escape returned $status instead of 97: $out"
  assert_contains "$out" 'state lock .watch.lock' "lock guard did not identify the unsafe lock"
  assert_contains "$out" "$ROOT" "lock guard did not name the resolved outside path"
  pass "test isolation: state locks cannot resolve outside the sandbox"
}

test_guard_accepts_regular_session_lock() {
  printf '%s\n' 999999 > "$FM_HOME/state/.lock"
  bash -c ':' || fail "guard rejected the legitimate file-based session lock"
  rm -f "$FM_HOME/state/.lock"
  pass "test isolation: regular session-lock files remain valid inside the sandbox"
}

test_guard_rejects_external_pid() {
  local out status=0
  out=$(bash -c 'kill -0 "$FM_TEST_OUTSIDE_PID"' 2>&1) || status=$?
  [ "$status" -eq 97 ] || fail "external PID guard returned $status instead of 97: $out"
  assert_contains "$out" "$FM_TEST_OUTSIDE_PID" "external PID diagnostic omitted the offending PID"
  assert_contains "$out" 'outside sandbox process tree' "external PID diagnostic omitted the boundary"
  pass "test isolation: daemon/watcher PIDs outside the test process tree hard-fail"
}

test_command_kill_rejects_external_pid() {
  local out status=0
  out=$(bash -c 'command kill -0 "$FM_TEST_OUTSIDE_PID"' 2>&1) || status=$?
  [ "$status" -eq 97 ] || fail "command-kill guard returned $status instead of 97: $out"
  assert_contains "$out" "$FM_TEST_OUTSIDE_PID" "command-kill diagnostic omitted the offending PID"
  pass "test isolation: command kill cannot bypass the external-PID guard"
}

test_hostile_bash_env_cannot_replace_guard() {
  local hostile marker out
  hostile="$TMPDIR/hostile-bash-env"
  marker="$TMPDIR/hostile-bash-env-ran"
  printf 'printf hostile > %q\n' "$marker" > "$hostile"
  out=$(BASH_ENV="$hostile" "$FM_TEST_BASH" -c 'printf "%s" "$BASH_ENV"')
  [ "$out" = "$GUARD" ] || fail "sealed launcher did not restore the guard: $out"
  [ ! -e "$marker" ] || fail "hostile BASH_ENV executed before the isolation guard"
  out=$(env -u BASH_ENV "$FM_TEST_BASH" -c 'printf "%s" "$BASH_ENV"')
  [ "$out" = "$GUARD" ] || fail "sealed launcher did not restore an unset guard: $out"
  "$FM_TEST_BASH" -c 'kill -0 "$FM_TEST_OUTSIDE_PID"' >/dev/null 2>&1 && fail "restored guard allowed an external PID"
  pass "test isolation: hostile BASH_ENV cannot replace the child-shell guard"
}

test_direct_execution_is_inert() {
  local out status=0
  # shellcheck disable=SC2016  # $1 is expanded by the child shell.
  out=$(env -u BASH_ENV -u FM_TEST_SEALED -u FM_TEST_SANDBOX_ROOT \
    "$FM_TEST_BASH" -c '. "$1"' _ "$ROOT/tests/lib.sh" 2>&1) || status=$?
  [ "$status" -eq 97 ] || fail "direct test guard returned $status instead of 97: $out"
  assert_contains "$out" 'sealed Bash launcher is not configured' \
    "direct test guard did not name the required entry point"
  pass "test isolation: direct test execution fails before loading fleet helpers"
}

test_runner_exports_a_complete_sandbox() {
  fm_test_isolation_guard_environment
  [ "$HOME" != "$ROOT" ] || fail "runner reused the repository as HOME"
  [ "$FM_HOME" != "$ROOT" ] || fail "runner reused the repository as FM_HOME"
  [ "$FM_TEST_INITIAL_STATE_OVERRIDE" = "$FM_HOME/state" ] \
    || fail "runner did not enter through an explicit private state override"
  [ "$FM_TREEHOUSE_ROOT" = "$HOME/.treehouse" ] \
    || fail "runner did not align Treehouse CLI and firstmate pool roots"
  assert_present "$RUNNER" "single-test sealed runner is missing"
  assert_present "$GUARD" "test environment guard is missing"
  pass "test isolation: runner exports a complete private HOME/FM_HOME/state/pool world"
}

test_pool_fixture_write_is_private() {
  local fixture="$HOME/.treehouse/scratch-project-isolation-proof/treehouse-state.json"
  mkdir -p "$(dirname "$fixture")"
  printf '%s\n' '{"worktrees": null}' > "$fixture"
  assert_grep '"worktrees": null' "$fixture" "scratch pool fixture was not written in the test home"
  case "$fixture" in
    "$FM_TEST_SANDBOX_ROOT"/*) ;;
    *) fail "scratch pool fixture escaped the sandbox: $fixture" ;;
  esac
  pass "test isolation: scratch-project pool fixtures stay under the sealed HOME"
}

test_every_entry_sources_the_shared_harness
test_guard_rejects_external_operational_paths
test_guard_rejects_symlink_escape
test_guard_rejects_lock_symlink_escape
test_guard_accepts_regular_session_lock
test_guard_rejects_external_pid
test_command_kill_rejects_external_pid
test_hostile_bash_env_cannot_replace_guard
test_direct_execution_is_inert
test_runner_exports_a_complete_sandbox
test_pool_fixture_write_is_private
