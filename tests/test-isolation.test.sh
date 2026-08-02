#!/usr/bin/env bash
# Contract tests for the sealed behavior-test harness and its hard path guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/tests/test-env-guard.sh"
RUNNER="$ROOT/tests/run-test.sh"
SUITE="$ROOT/tests/run.sh"
DETACHED_RUNNER="$ROOT/tests/run-detached.py"
FLEET_PROOF="$ROOT/tests/fleet-proof.py"

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

test_bash_env_mutations_match_strict_allowlist() {
  "$ROOT/tests/audit-bash-env.sh" || fail "BASH_ENV mutation audit failed"
  pass "test isolation: BASH_ENV mutations match the strict centralized allowlist"
}

test_bash_env_audit_rejects_unapproved_mutations() {
  local audit_dir allowlist mutation out status
  audit_dir="$TMPDIR/bash-env-audit-spoof"
  allowlist="$audit_dir/allowlist"
  mkdir -p "$audit_dir"
  : > "$allowlist"
  for mutation in \
    '  BASH'_ENV='/hostile command' \
    'export BASH'_ENV \
    'declare -x BASH'_ENV \
    'typeset -x BASH'_ENV \
    'readonly BASH'_ENV \
    'unset BASH'_ENV \
    'env -u BASH'_ENV' command' \
    'env -uBASH'_ENV' command' \
    'env --unset=BASH'_ENV' command'; do
    # shellcheck disable=SC1003  # The trailing backslash is deliberate fixture text.
    printf '%s\n' 'PATH=/usr/bin:/bin \' "$mutation" > "$audit_dir/spoof.test.sh"
    status=0
    out=$("$ROOT/tests/audit-bash-env.sh" "$audit_dir" "$allowlist" 2>&1) || status=$?
    [ "$status" -eq 97 ] || fail "BASH_ENV mutation audit returned $status for: $mutation"
    assert_contains "$out" 'unaudited BASH_ENV mutation' "BASH_ENV mutation bypassed the audit: $mutation"
  done
  pass "test isolation: assignment, declaration, and unset mutations require exact allowlisting"
}

assert_guard_rejects() {  # <label> <expected-path> <environment assignment...>
  local label=$1 expected=$2 out status=0 expected_log="$TMPDIR/expected-guard-$RANDOM.log"
  shift 2
  out=$(env FM_TEST_ISOLATION_LOG="$expected_log" "$@" bash -c ':' 2>&1) || status=$?
  [ "$status" -eq 97 ] || fail "$label: guard returned $status instead of 97: $out"
  assert_contains "$out" 'test isolation violation:' "$label: hard-failure prefix missing"
  assert_contains "$out" "$expected" "$label: diagnostic omitted the offending path"
  rm -f "$expected_log"
}

test_guard_rejects_external_operational_paths() {
  assert_guard_rejects "external home" "$ROOT" FM_HOME="$ROOT"
  assert_guard_rejects "external state" "$ROOT/state" FM_STATE_OVERRIDE="$ROOT/state"
  assert_guard_rejects "external pool" "$ROOT/.treehouse" FM_TREEHOUSE_ROOT="$ROOT/.treehouse"
  assert_guard_rejects "external tmux socket" "$ROOT/tmux" TMUX_TMPDIR="$ROOT/tmux"
  pass "test isolation: home, state, pool, and tmux paths outside the sandbox hard-fail loudly"
}

test_guard_allows_malformed_private_operational_fixtures() {
  local config_fixture lock_fixture out
  lock_fixture="$TMPDIR/checkout-refresh-lock-file"
  : > "$lock_fixture"
  out=$(FM_CHECKOUT_REFRESH_LOCK_ROOT="$lock_fixture" bash -c \
    'printf "%s" "$FM_CHECKOUT_REFRESH_LOCK_ROOT"') \
    || fail "guard preempted a malformed but contained lock-root fixture"
  [ "$out" = "$lock_fixture" ] \
    || fail "contained lock-root fixture changed across guard validation: $out"

  config_fixture="$TMPDIR/config-file"
  : > "$config_fixture"
  out=$(FM_CONFIG_OVERRIDE="$config_fixture" bash -c \
    'printf "%s" "$FM_CONFIG_OVERRIDE"') \
    || fail "guard preempted a malformed but contained config fixture"
  [ "$out" = "$config_fixture" ] \
    || fail "contained config fixture changed across guard validation: $out"
  pass "test isolation: contained malformed fixtures reach the product's own fail-closed checks"
}

test_guard_rejects_symlink_escape() {
  local link out status=0 expected_log="$TMPDIR/expected-symlink-guard.log"
  link="$TMPDIR/escaped-home"
  ln -s "$ROOT" "$link"
  out=$(FM_TEST_ISOLATION_LOG="$expected_log" FM_HOME="$link" bash -c ':' 2>&1) || status=$?
  [ "$status" -eq 97 ] || fail "symlink escape: guard returned $status instead of 97: $out"
  assert_contains "$out" "$link" "symlink escape: diagnostic omitted the offending path"
  assert_contains "$out" "$ROOT" "symlink escape: diagnostic omitted the physical destination"
  rm -f "$expected_log"
  pass "test isolation: a sandbox path that resolves outward hard-fails"
}

test_guard_rejects_lock_symlink_escape() {
  local out status=0 expected_log="$TMPDIR/expected-lock-guard.log"
  ln -s "$ROOT" "$FM_HOME/state/.watch.lock"
  out=$(FM_TEST_ISOLATION_LOG="$expected_log" bash -c ':' 2>&1) || status=$?
  rm -f "$FM_HOME/state/.watch.lock"
  [ "$status" -eq 97 ] || fail "watcher lock symlink escape returned $status instead of 97: $out"
  assert_contains "$out" 'state lock .watch.lock' "lock guard did not identify the unsafe lock"
  assert_contains "$out" "$ROOT" "lock guard did not name the resolved outside path"
  rm -f "$expected_log"
  pass "test isolation: state locks cannot resolve outside the sandbox"
}

test_guard_accepts_regular_session_lock() {
  printf '%s\n' 999999 > "$FM_HOME/state/.lock"
  bash -c ':' || fail "guard rejected the legitimate file-based session lock"
  rm -f "$FM_HOME/state/.lock"
  pass "test isolation: regular session-lock files remain valid inside the sandbox"
}

test_guard_rejects_external_pid() {
  local out status=0 expected_log="$TMPDIR/expected-pid-guard.log"
  out=$(FM_TEST_ISOLATION_LOG="$expected_log" \
    bash -c 'kill -0 "$FM_TEST_OUTSIDE_PID"' 2>&1) || status=$?
  [ "$status" -eq 97 ] || fail "external PID guard returned $status instead of 97: $out"
  assert_contains "$out" "$FM_TEST_OUTSIDE_PID" "external PID diagnostic omitted the offending PID"
  assert_contains "$out" 'outside sandbox process tree' "external PID diagnostic omitted the boundary"
  rm -f "$expected_log"
  pass "test isolation: daemon/watcher PIDs outside the test process tree hard-fail"
}

test_command_kill_rejects_external_pid() {
  local out status=0 expected_log="$TMPDIR/expected-command-kill-guard.log"
  out=$(FM_TEST_ISOLATION_LOG="$expected_log" \
    bash -c 'command kill -0 "$FM_TEST_OUTSIDE_PID"' 2>&1) || status=$?
  [ "$status" -eq 97 ] || fail "command-kill guard returned $status instead of 97: $out"
  assert_contains "$out" "$FM_TEST_OUTSIDE_PID" "command-kill diagnostic omitted the offending PID"
  rm -f "$expected_log"
  pass "test isolation: command kill cannot bypass the external-PID guard"
}

test_guard_allows_reparented_owned_session_member() {
  local pid_file="$TMPDIR/reparented-owned-pid" pid i=0 parent group session
  bash -c 'set -m; trap "" HUP; sleep 300 >/dev/null 2>&1 & printf "%s\n" "$!" > "$1"' \
    _ "$pid_file"
  pid=$(cat "$pid_file")
  while [ "$i" -lt 40 ]; do
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    [ "$parent" != "$$" ] && break
    sleep 0.05
    i=$((i + 1))
  done
  group=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  session=$("$FM_TEST_GUARD_PYTHON" -c \
    'import os, sys; print(os.getsid(int(sys.argv[1])))' "$pid")
  [ "$group" != "$FM_TEST_PROCESS_ROOT_PID" ] \
    || fail "job-control fixture did not enter a nested process group: pid=$pid pgid=$group"
  [ "$session" = "$FM_TEST_PROCESS_ROOT_PID" ] \
    || fail "reparented fixture escaped the sealed process session: pid=$pid sid=$session"
  kill "$pid" || fail "guard rejected a reparented member of the sealed process session"
  pass "test isolation: reparented job groups remain owned only inside the sealed process session"
}

test_job_helpers_never_signal_a_reused_numeric_pid() {
  local pid status=0
  sleep 30 &
  pid=$!
  fm_test_job_is_running "$pid" \
    || fail "fresh background fixture was absent from Bash's child-job table"
  fm_test_reap_job "$pid"
  fm_test_job_is_running "$pid" \
    && fail "reaped background fixture remained in Bash's running-job table"
  fm_test_signal_job "$FM_TEST_OUTSIDE_PID" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] \
    || fail "job signal helper accepted a live process that is not this shell's child job"
  pass "test isolation: fixture cleanup signals Bash jobspecs, never reusable numeric PIDs"
}

test_runner_surfaces_swallowed_child_guard_failure() {
  local artifact="$TMPDIR/swallowed-child-guard.log" out status=0
  FM_TEST_PROBE_SWALLOWED_GUARD=1 \
    "$DETACHED_RUNNER" "$artifact" -- "$RUNNER" tests/runner-entry-probe.test.sh \
    >/dev/null 2>&1 || status=$?
  out=$(cat "$artifact")
  [ "$status" -eq 97 ] \
    || fail "swallowed child guard returned $status instead of 97: $out"
  assert_contains "$out" 'test isolation violation log' \
    "runner did not surface the child guard failure after stderr was redirected"
  assert_contains "$out" 'outside sandbox process tree' \
    "persistent guard log omitted the offending PID boundary"
  pass "test isolation: redirected child guard failures still fail the owning test loudly"
}

test_nested_helper_cleanup_cannot_kill_caller() {
  local artifact="$TMPDIR/nested-cleanup-caller.log" out status=0
  FM_TEST_PROBE_NESTED_CLEANUP=1 \
    "$DETACHED_RUNNER" "$artifact" -- "$RUNNER" tests/runner-entry-probe.test.sh \
    >/dev/null 2>&1 || status=$?
  out=$(cat "$artifact")
  [ "$status" -eq 0 ] \
    || fail "nested helper cleanup killed its caller (status $status): $out"
  assert_not_contains "$out" 'detached test runner terminated by signal' \
    "nested helper cleanup remained caller-fatal"
  pass "test isolation: nested helper cleanup cannot terminate its caller"
}

test_hostile_bash_env_cannot_replace_guard() {
  local hostile marker artifact out status=0 expected_log="$TMPDIR/expected-hostile-guard.log"
  hostile="$TMPDIR/hostile-bash-env"
  marker="$TMPDIR/hostile-bash-env-ran"
  printf 'printf hostile > %q\n' "$marker" > "$hostile"
  # shellcheck disable=SC2016  # BASH_ENV is expanded by the child shell.
  out=$(BASH_ENV="$hostile" "$FM_TEST_BASH" -c 'printf "%s" "$BASH_ENV"')
  [ "$out" = "$GUARD" ] || fail "sealed launcher did not restore the guard: $out"
  [ ! -e "$marker" ] || fail "hostile BASH_ENV executed before the isolation guard"
  # shellcheck disable=SC2016  # BASH_ENV is expanded by the child shell.
  out=$(env -u BASH_ENV "$FM_TEST_BASH" -c 'printf "%s" "$BASH_ENV"')
  [ "$out" = "$GUARD" ] || fail "sealed launcher did not restore an unset guard: $out"
  printf 'printf hostile > %q\n/bin/kill -0 %q\n' \
    "$marker" "$FM_TEST_OUTSIDE_PID" > "$hostile"
  artifact="$TMPDIR/hostile-runner-entry.log"
  out=$(BASH_ENV="$hostile" "$DETACHED_RUNNER" "$artifact" -- \
    "$RUNNER" tests/runner-entry-probe.test.sh 2>&1) || status=$?
  [ "$status" -eq 0 ] || fail "sealed runner rejected safe entry under hostile ambient BASH_ENV: $out"
  assert_contains "$out" 'runner-entry-probe-ok' "sealed runner did not execute its guarded probe"
  [ ! -e "$marker" ] || fail "sealed runner sourced hostile ambient BASH_ENV"
  status=0
  out=$(BASH_ENV="$hostile" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    "$SUITE" tests/runner-entry-probe.test.sh 2>&1) || status=$?
  [ "$status" -eq 0 ] || fail "public suite entry rejected safe execution under hostile ambient BASH_ENV: $out"
  assert_contains "$out" 'runner-entry-probe-ok' "public suite entry did not execute its guarded probe"
  [ ! -e "$marker" ] || fail "public suite entry sourced hostile ambient BASH_ENV"
  # shellcheck disable=SC2016  # FM_TEST_OUTSIDE_PID is expanded by the child shell.
  FM_TEST_ISOLATION_LOG="$expected_log" \
    "$FM_TEST_BASH" -c 'kill -0 "$FM_TEST_OUTSIDE_PID"' >/dev/null 2>&1 \
    && fail "restored guard allowed an external PID"
  rm -f "$expected_log"
  pass "test isolation: hostile BASH_ENV cannot replace the child-shell guard"
}

test_direct_execution_is_inert() {
  local out status=0 expected_log="$TMPDIR/expected-direct-guard.log"
  # shellcheck disable=SC2016  # $1 is expanded by the child shell.
  out=$(env -u BASH_ENV -u FM_TEST_SEALED -u FM_TEST_SANDBOX_ROOT \
    FM_TEST_ISOLATION_LOG="$expected_log" \
    "$FM_TEST_BASH" -c '. "$1"' _ "$ROOT/tests/lib.sh" 2>&1) || status=$?
  [ "$status" -eq 97 ] || fail "direct test guard returned $status instead of 97: $out"
  assert_contains "$out" 'sealed Bash launcher is not configured' \
    "direct test guard did not name the required entry point"
  rm -f "$expected_log"
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
  case "$TMUX_TMPDIR" in
    "$FM_TEST_SANDBOX_ROOT"/*) ;;
    *) fail "runner did not isolate the tmux socket root: $TMUX_TMPDIR" ;;
  esac
  assert_present "$RUNNER" "single-test sealed runner is missing"
  assert_present "$SUITE" "public sealed suite entry is missing"
  assert_present "$GUARD" "test environment guard is missing"
  if [ -n "${FM_TEST_HERDR_LAB_SESSION:-}" ]; then
    case "$FM_TEST_HERDR_LAB_SESSION" in
      fm-lab-?*) ;;
      *) fail "runner exported an unsafe Herdr session: $FM_TEST_HERDR_LAB_SESSION" ;;
    esac
    [ "$HERDR_SESSION" = "$FM_TEST_HERDR_LAB_SESSION" ] \
      || fail "runner did not pin Herdr to its owned lab"
    [ "$(command -v herdr)" = "$ROOT/tests/sealed-herdr-bin/herdr" ] \
      || fail "runner did not install the sealed Herdr launcher"
  fi
  pass "test isolation: runner exports a complete private HOME/FM_HOME/state/pool/tmux/Herdr world"
}

test_native_herdr_agent_rebases_its_guarded_process_tree() {
  local session=fm-lab-native-agent-fixture out child_pid child_root foreign
  out=$(FM_BACKEND_HERDR_TEST_LAB=firstmate-herdr-test-lab-v1 \
    FM_TEST_HERDR_LAB_SESSION="$session" HERDR_SESSION="$session" \
    HERDR_ENV=1 HERDR_PANE_ID=wF:p7 \
    bash -c 'printf "%s %s" "$$" "$FM_TEST_PROCESS_ROOT_PID"') \
    || fail "owned native Herdr agent could not enter its guarded process tree"
  read -r child_pid child_root <<EOF
$out
EOF
  [ "$child_pid" = "$child_root" ] \
    || fail "native Herdr agent retained the detached runner as its unreachable process root: $out"

  foreign=$(FM_BACKEND_HERDR_TEST_LAB=firstmate-herdr-test-lab-v1 \
    FM_TEST_HERDR_LAB_SESSION="$session" HERDR_SESSION=fm-lab-foreign \
    HERDR_ENV=1 HERDR_PANE_ID=wF:p7 \
    bash -c 'printf "%s %s" "$$" "$FM_TEST_PROCESS_ROOT_PID"') \
    || fail "foreign-session guard fixture did not run"
  read -r child_pid child_root <<EOF
$foreign
EOF
  [ "$child_pid" != "$child_root" ] \
    || fail "foreign Herdr session could claim an owned native-agent process root"
  [ "$child_root" = "$FM_TEST_PROCESS_ROOT_PID" ] \
    || fail "foreign Herdr session changed the sealed runner root: $foreign"
  pass "test isolation: only an authenticated owned-lab pane rebases native-agent child ownership"
}

test_herdr_guard_rejects_default_and_routes_owned_lab() {
  local out status=0 observed expected_log="$TMPDIR/expected-herdr-guard.log"
  [ -n "${FM_TEST_HERDR_LAB_SESSION:-}" ] || {
    pass "test isolation: Herdr guard is inert when Herdr is unavailable"
    return
  }
  out=$(FM_TEST_ISOLATION_LOG="$expected_log" \
    herdr status --json --session default 2>&1) || status=$?
  [ "$status" -eq 97 ] || fail "foreign Herdr session returned $status instead of 97: $out"
  assert_contains "$out" 'test isolation violation:' \
    "foreign Herdr session did not hard-fail loudly"
  assert_contains "$out" 'default' \
    "foreign Herdr diagnostic omitted the offending session"
  rm -f "$expected_log"

  observed=$(herdr status --json | jq -r '.client.session // empty') \
    || fail "sealed Herdr launcher could not reach its owned lab"
  [ "$observed" = "$FM_TEST_HERDR_LAB_SESSION" ] \
    || fail "sealed Herdr launcher reached $observed instead of $FM_TEST_HERDR_LAB_SESSION"
  pass "test isolation: real Herdr calls are helper-routed to the owned lab and default hard-fails"
}

test_detached_runner_survives_caller_fatal_test() {
  local artifact status=0 out
  artifact="$TMPDIR/caller-fatal.log"
  "$DETACHED_RUNNER" "$artifact" -- python3 -c \
    'import os, signal, time; print("caller-fatal-probe-started", flush=True); os.kill(os.getppid(), signal.SIGTERM); time.sleep(30)' \
    >/dev/null 2>&1 || status=$?
  [ "$status" -eq 97 ] \
    || fail "detached caller-fatal probe returned $status instead of 97"
  out=$(cat "$artifact")
  assert_contains "$out" 'caller-fatal-probe-started' \
    "detached runner lost output written before caller death"
  assert_contains "$out" 'detached test caller terminated before reporting status' \
    "detached runner did not diagnose caller-fatal termination"
  pass "test isolation: a caller-fatal test cannot terminate the suite driver and leaves an artifact"
}

test_shared_cleanup_reaps_owned_orphans() {
  local artifact status=0 out
  artifact="$TMPDIR/shared-cleanup-orphan.log"
  FM_TEST_PROBE_ORPHAN=1 "$DETACHED_RUNNER" "$artifact" -- \
    "$RUNNER" tests/runner-entry-probe.test.sh >/dev/null 2>&1 || status=$?
  out=$(cat "$artifact")
  [ "$status" -eq 0 ] \
    || fail "shared process cleanup left owned residue (status $status): $out"
  assert_not_contains "$out" 'detached test left processes in its owned process group' \
    "detached runner had to compensate for shared cleanup"
  pass "test isolation: shared cleanup reaps orphaned members of the sealed process group"
}

test_failed_lab_provision_is_torn_down() {
  local case_dir helper proof status=0
  case_dir="$TMPDIR/failed-lab-provision"
  helper="$case_dir/lab-helper"
  proof="$case_dir/proof"
  mkdir -p "$case_dir"
  cat > "$helper" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  name) printf '%s\n' fm-lab-failed-provision-fixture ;;
  provision) : > "$FM_TEST_FAKE_LAB_DIR/provisioned"; exit 1 ;;
  teardown) : > "$FM_TEST_FAKE_LAB_DIR/torn-down" ;;
  *) exit 64 ;;
esac
SH
  chmod +x "$helper"
  FM_TEST_FAKE_LAB_DIR="$case_dir" "$FLEET_PROOF" \
    --proof-dir "$proof" \
    --lab-helper "$helper" \
    --server-pid "$$" \
    tests/runner-entry-probe.test.sh >/dev/null 2>&1 || status=$?
  [ "$status" -eq 1 ] \
    || fail "failed-provision proof returned $status instead of its primary status"
  assert_present "$case_dir/provisioned" "fake lab did not exercise provision failure"
  assert_present "$case_dir/torn-down" "failed lab provision did not trigger teardown"
  [ "$(cat "$proof/teardown-status")" = 0 ] \
    || fail "failed-provision proof did not record successful cleanup"
  assert_present "$proof/default-after.json" \
    "failed-provision proof omitted its default-session after snapshot"
  pass "test isolation: partial lab provisioning always tears down and records fleet state"
}

test_exit_zero_lab_proxy_is_not_adopted() {
  local case_dir helper proof status=0
  case_dir="$TMPDIR/exit-zero-lab-proxy"
  helper="$case_dir/lab-helper"
  proof="$case_dir/proof"
  mkdir -p "$case_dir"
  cat > "$helper" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  name) printf '%s\n' fm-lab-exit-zero-proxy ;;
  provision) exit 0 ;;
  run)
    printf '{"server":{"running":false,"session":"%s"}}\n' "$2"
    ;;
  teardown) : > "$FM_TEST_FAKE_LAB_DIR/torn-down" ;;
  *) exit 64 ;;
esac
SH
  chmod +x "$helper"
  FM_TEST_FAKE_LAB_DIR="$case_dir" FM_TEST_HERDR_ADOPTION_TIMEOUT_SECONDS=1 \
    "$FLEET_PROOF" \
    --proof-dir "$proof" \
    --lab-helper "$helper" \
    --server-pid "$$" \
    tests/runner-entry-probe.test.sh >/dev/null 2>&1 || status=$?
  [ "$status" -eq 97 ] \
    || fail "exit-zero proxy proof returned $status instead of refusing adoption"
  [ "$(cat "$proof/provision-status")" = 0 ] \
    || fail "exit-zero proxy fixture did not reproduce a successful provision return"
  [ "$(cat "$proof/adoption-status")" = 1 ] \
    || fail "proof driver trusted provision exit zero without a running session"
  assert_present "$case_dir/torn-down" \
    "unadoptable exit-zero proxy did not trigger guarded teardown"
  assert_contains "$(cat "$proof/adoption.log")" '"running":false' \
    "adoption evidence omitted the observed stopped session state"
  pass "test isolation: provision exit zero is rejected until the owned session itself reports running"
}

test_reused_lab_resets_owned_workspaces_between_entries() {
  local case_dir helper fake_bin artifacts state out status=0
  case_dir="$TMPDIR/reused-lab-reset"
  helper="$case_dir/lab-helper"
  fake_bin="$case_dir/bin"
  artifacts="$case_dir/artifacts"
  state="$case_dir/workspace-present"
  mkdir -p "$fake_bin"
  : > "$state"
  cat > "$helper" <<'SH'
#!/bin/sh
set -u
state=${FM_TEST_FAKE_WORKSPACE_STATE:?}
case "$1 ${3:-} ${4:-}" in
  "run status --json")
    printf '{"server":{"running":true,"session":"%s"}}\n' "$2"
    ;;
  "run workspace list")
    if [ -e "$state" ]; then
      printf '{"result":{"workspaces":[{"workspace_id":"w9"}]}}\n'
    else
      printf '{"result":{"workspaces":[]}}\n'
    fi
    ;;
  "run workspace close")
    [ "${5:-}" = w9 ] || exit 65
    rm -f "$state"
    printf 'closed\n' >> "$FM_TEST_FAKE_CLOSE_LOG"
    ;;
  *) exit 64 ;;
esac
SH
  cat > "$fake_bin/herdr" <<'SH'
#!/bin/sh
exit 0
SH
  chmod +x "$helper" "$fake_bin/herdr"
  out=$(
    env -u FM_TEST_SUITE_ACTIVE \
      FM_TEST_HERDR_LAB_SESSION=fm-lab-reset-fixture \
      FM_TEST_HERDR_LAB_HELPER="$helper" \
      FM_TEST_REUSE_HERDR_LAB=1 \
      FM_TEST_FAKE_WORKSPACE_STATE="$state" \
      FM_TEST_FAKE_CLOSE_LOG="$case_dir/close.log" \
      FM_TEST_ORIGINAL_PATH="$fake_bin:$PATH" \
      FM_TEST_OUTPUT_DIR="$artifacts" \
        "$ROOT/tests/run.sh" "$ROOT/tests/runner-entry-probe.test.sh" 2>&1
  ) || status=$?
  [ "$status" -eq 0 ] \
    || fail "reused-lab reset fixture failed: status=$status output=$out"
  [ ! -e "$state" ] || fail "reused lab retained its pre-suite workspace"
  [ "$(wc -l < "$case_dir/close.log" | tr -d '[:space:]')" = 1 ] \
    || fail "reused lab did not close exactly the one owned fixture workspace"
  pass "test isolation: one provisioned lab is reused only after exact workspace reset"
}

test_fleet_tripwire_protects_identities_without_counting_task_panes() {
  local out
  out=$(python3 - "$FLEET_PROOF" <<'PY'
import importlib.util
import json
import sys
import tempfile

spec = importlib.util.spec_from_file_location("fleet_proof", sys.argv[1])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

def identity(pid, ppid, command):
    return {
        "pid": pid,
        "ppid": ppid,
        "start": f"start-{pid}",
        "command_sha256": f"sha-{command}",
        "command": command,
    }

before = {
    "server": identity(100, 1, "server"),
    "panes": [identity(200, 100, "firstmate"), identity(300, 100, "task")],
}
after_task_reap = {
    "server": before["server"],
    "panes": [before["panes"][0]],
}
table_after_task_reap = {
    100: before["server"],
    200: before["panes"][0],
}
task_diff = module.inventory_diff(before, after_task_reap)
assert task_diff["lifecycle_reconciliation_required"] is True
assert [entry["pid"] for entry in task_diff["missing"]] == [300]
assert module.protected_violation(before, {200}, table_after_task_reap) is None

protected_loss = {100: before["server"]}
violation = module.protected_violation(before, {200}, protected_loss)
assert [entry["pid"] for entry in violation["missing"]] == [200]

host_before = {
    "treehouse_pool": {"same": True},
    "watch_lock": {"same": True},
    "afk_flag": {"same": True},
    "lifecycle_processes": {
        "all": [identity(400, 1, "supervisor"), identity(401, 400, "transient")],
        "stable": [identity(400, 1, "supervisor")],
    },
}
host_after = {
    **host_before,
    "lifecycle_processes": {
        "all": [identity(400, 1, "supervisor"), identity(402, 400, "transient")],
        "stable": [identity(400, 1, "supervisor")],
    },
}
host_result = module.host_diff(host_before, host_after)
assert host_result["host_unchanged"] is True
assert host_result["all_lifecycle_processes"]["missing"][0]["pid"] == 401

def lifecycle(pid, ppid, command, role):
    return {**identity(pid, ppid, command), "role": role}

def watch_lock(owner, pid):
    return {
        "entry": {"path": f"/state/.watch.lock.{pid}", "type": "symlink"},
        "members": [
            {"path": f"/state/.watch.lock.{pid}/fm-home", "sha256": owner},
            {"path": f"/state/.watch.lock.{pid}/watcher-path", "sha256": "watcher"},
            {"path": f"/state/.watch.lock.{pid}/pid", "sha256": str(pid)},
        ],
    }

rotated_before = {
    "treehouse_pool": {"same": True},
    "watch_lock": watch_lock("home", 501),
    "afk_flag": {"entry": {"type": "file", "sha256": "old-timestamp"}},
    "lifecycle_processes": {
        "all": [
            lifecycle(500, 1, "supervisor", "supervisor"),
            lifecycle(501, 500, "watcher", "watcher"),
        ],
        "stable": [
            lifecycle(500, 1, "supervisor", "supervisor"),
            lifecycle(501, 500, "watcher", "watcher"),
        ],
    },
}
rotated_after = {
    **rotated_before,
    "watch_lock": watch_lock("home", 601),
    "afk_flag": {"entry": {"type": "file", "sha256": "new-timestamp"}},
    "lifecycle_processes": {
        "all": [
            lifecycle(600, 1, "supervisor", "supervisor"),
            lifecycle(601, 600, "watcher", "watcher"),
        ],
        "stable": [
            lifecycle(600, 1, "supervisor", "supervisor"),
            lifecycle(601, 600, "watcher", "watcher"),
        ],
    },
}
log_delta = {
    "append_only": True,
    "bounded": True,
    "lines": [
        "reap-wake delivery ready: native tracked background task will complete",
        "daemon shutting down",
        "daemon starting (pid 600); delivery=reap-wake",
        "wake: heartbeat",
    ],
}
reconciled = module.host_diff(rotated_before, rotated_after, log_delta)
assert reconciled["host_unchanged"] is False
assert reconciled["host_unchanged_or_reconciled"] is True
assert reconciled["afk_mode_changed"] is False
assert reconciled["watch_lock_logical_owner_changed"] is False
assert reconciled["lifecycle_reconciliation"]["accepted"] is True

unexplained = module.host_diff(rotated_before, rotated_after)
assert unexplained["host_unchanged_or_reconciled"] is False
assert unexplained["lifecycle_reconciliation"]["accepted"] is False

idle_before = {
    "treehouse_pool": {"same": True},
    "watch_lock": {"path": "/state/.watch.lock", "type": "absent"},
    "afk_flag": {"path": "/state/.afk", "type": "absent"},
    "lifecycle_processes": {"all": [], "stable": []},
}
active_after = {
    **idle_before,
    "watch_lock": watch_lock("home", 701),
    "lifecycle_processes": {
        "all": [lifecycle(701, 700, "bash /expected/fm-watch.sh", "watcher")],
        "stable": [lifecycle(701, 700, "bash /expected/fm-watch.sh", "watcher")],
    },
}
expected_owner_transition = module.host_diff(
    idle_before,
    active_after,
    expected_watch_owner={"fm-home": "home", "watcher-path": "watcher"},
    expected_watcher_path=module.Path("/expected/fm-watch.sh"),
)
assert expected_owner_transition["host_unchanged"] is False
assert expected_owner_transition["host_unchanged_or_reconciled"] is True
assert expected_owner_transition["watch_lock_in_expected_owner_set"] is True
assert expected_owner_transition["lifecycle_reconciliation"]["accepted"] is True

with tempfile.TemporaryDirectory() as directory:
    state_path = module.Path(directory) / "session.json"
    state_path.write_text(json.dumps({
        "version": 3,
        "workspaces": [{
            "id": "wF",
            "custom_name": "default",
            "public_pane_numbers": {"15": 1, "16": 2},
            "tabs": [{
                "panes": {
                    "15": {"cwd": "/fleet/firstmate"},
                    "16": {"cwd": "/fleet/task"},
                },
            }],
        }],
    }))
    layout_before = module.default_layout_snapshot(state_path)
    assert [pane["pane_id"] for pane in layout_before["panes"]] == ["wF:p1", "wF:p2"]
    assert all("command" not in pane for pane in layout_before["panes"])

    state_path.write_text(json.dumps({
        "version": 3,
        "workspaces": [{
            "id": "wF",
            "custom_name": "default",
            "public_pane_numbers": {"15": 1, "17": 3},
            "tabs": [{
                "panes": {
                    "15": {"cwd": "/fleet/firstmate"},
                    "17": {"cwd": "/fleet/new-task"},
                },
            }],
        }],
    }))
    layout_after = module.default_layout_snapshot(state_path)
    layout_diff = module.default_layout_diff(layout_before, layout_after)
    assert [pane["pane_id"] for pane in layout_diff["missing"]] == ["wF:p2"]
    assert [pane["pane_id"] for pane in layout_diff["added"]] == ["wF:p3"]
    assert layout_diff["lifecycle_reconciliation_required"] is True
print(json.dumps({
    "task_reap": task_diff,
    "protected_loss": violation,
    "host_transient": host_result,
    "host_reconciled": reconciled,
    "host_unexplained": unexplained,
    "expected_owner_transition": expected_owner_transition,
    "layout_diff": layout_diff,
}))
PY
  ) || fail "fleet identity tripwire fixture failed: $out"
  assert_contains "$out" '"lifecycle_reconciliation_required": true' \
    "fleet inventory did not retain ordinary task disappearance for reconciliation"
  assert_contains "$out" '"pid": 200' \
    "fleet tripwire did not identify the missing protected pane"
  assert_contains "$out" '"host_unchanged": true' \
    "transient watcher descendants caused a false host-state failure"
  assert_contains "$out" '"host_unchanged_or_reconciled": true' \
    "known reap-wake lifecycle rotation was not reconciled"
  assert_contains "$out" '"accepted": false' \
    "unexplained lifecycle rotation was silently accepted"
  assert_contains "$out" '"watch_lock_in_expected_owner_set": true' \
    "declared operator watcher transition was not reconciled as a stable expected set"
  pass "test isolation: stable identities abort while routine task reaps require reconciliation"
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

test_suite_names_a_nonzero_test_file() {
  local artifacts="$TMPDIR/nonzero-suite-artifacts"
  local out status=0
  out=$(
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    FM_TEST_OUTPUT_DIR="$artifacts" \
    FM_TEST_RUNNER_PROBE_EXIT=23 \
      "$ROOT/tests/run.sh" "$ROOT/tests/runner-entry-probe.test.sh" 2>&1
  ) || status=$?
  [ "$status" -eq 1 ] \
    || fail "suite did not aggregate a forced test failure: status=$status output=$out"
  assert_contains "$out" 'not ok - tests/runner-entry-probe.test.sh exited 23' \
    "suite hid the file and status for a nonzero test"
  pass "test isolation: suite names every nonzero test file and exit status"
}

test_suite_polls_adopted_lab_until_running() {
  local case_dir helper fake_bin attempts artifacts out status=0
  case_dir="$TMPDIR/adoption-poll"
  helper="$case_dir/lab-helper"
  fake_bin="$case_dir/bin"
  attempts="$case_dir/attempts"
  artifacts="$case_dir/artifacts"
  mkdir -p "$fake_bin"
  cat > "$helper" <<'SH'
#!/bin/sh
set -u
attempts=${FM_TEST_FAKE_ADOPTION_ATTEMPTS:?}
if [ "$1 ${3:-}" = "run status" ]; then
  count=0
  [ ! -f "$attempts" ] || count=$(cat "$attempts")
  count=$((count + 1))
  printf '%s\n' "$count" > "$attempts"
  if [ "$count" -lt 3 ]; then
    printf '{"server":{"running":false,"session":"%s"}}\n' "$2"
  else
    printf '{"server":{"running":true,"session":"%s"}}\n' "$2"
  fi
  exit 0
fi
exit 64
SH
  cat > "$fake_bin/herdr" <<'SH'
#!/bin/sh
exit 0
SH
  chmod +x "$helper" "$fake_bin/herdr"
  out=$(
    FM_TEST_HERDR_LAB_SESSION=fm-lab-adoption-fixture \
    FM_TEST_HERDR_LAB_HELPER="$helper" \
    FM_TEST_HERDR_ADOPTION_TIMEOUT_SECONDS=1 \
    FM_TEST_FAKE_ADOPTION_ATTEMPTS="$attempts" \
    FM_TEST_ORIGINAL_PATH="$fake_bin:$PATH" \
    FM_TEST_OUTPUT_DIR="$artifacts" \
      "$ROOT/tests/run.sh" "$ROOT/tests/runner-entry-probe.test.sh" 2>&1
  ) || status=$?
  [ "$status" -eq 0 ] \
    || fail "suite rejected a lab that became running inside the adoption deadline: $out"
  [ "$(cat "$attempts")" -eq 3 ] \
    || fail "suite did not poll the adopted lab to a proven running state"
  pass "test isolation: adopted labs are polled to real running state before tests start"
}

test_every_entry_sources_the_shared_harness
test_bash_env_mutations_match_strict_allowlist
test_bash_env_audit_rejects_unapproved_mutations
test_guard_rejects_external_operational_paths
test_guard_allows_malformed_private_operational_fixtures
test_guard_rejects_symlink_escape
test_guard_rejects_lock_symlink_escape
test_guard_accepts_regular_session_lock
test_guard_rejects_external_pid
test_command_kill_rejects_external_pid
test_guard_allows_reparented_owned_session_member
test_job_helpers_never_signal_a_reused_numeric_pid
test_runner_surfaces_swallowed_child_guard_failure
test_nested_helper_cleanup_cannot_kill_caller
test_hostile_bash_env_cannot_replace_guard
test_direct_execution_is_inert
test_runner_exports_a_complete_sandbox
test_native_herdr_agent_rebases_its_guarded_process_tree
test_herdr_guard_rejects_default_and_routes_owned_lab
test_detached_runner_survives_caller_fatal_test
test_shared_cleanup_reaps_owned_orphans
test_failed_lab_provision_is_torn_down
test_exit_zero_lab_proxy_is_not_adopted
test_reused_lab_resets_owned_workspaces_between_entries
test_fleet_tripwire_protects_identities_without_counting_task_panes
test_pool_fixture_write_is_private
test_suite_names_a_nonzero_test_file
test_suite_polls_adopted_lab_until_running
