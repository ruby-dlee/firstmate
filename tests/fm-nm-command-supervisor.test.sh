#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SUPERVISOR="$ROOT/bin/fm-nm-command-supervisor.sh"
PROBE="$ROOT/bin/fm-nm-step-liveness.sh"
fm_test_tmproot_into TMP_ROOT fm-nm-command-supervisor
STATE_DIR="$TMP_ROOT/state"
WORKTREE="$TMP_ROOT/01RUN"
mkdir -p "$STATE_DIR" "$WORKTREE"

isolated_run() {
  perl -e 'setpgrp(0, 0); exec @ARGV' "$@"
}

wait_for_file() {
  local file=$1 attempt=0
  while [ "$attempt" -lt 50 ]; do
    [ -s "$file" ] && return 0
    sleep 0.1
    attempt=$((attempt + 1))
  done
  fail "timed out waiting for $file"
}

wait_for_process_exit() {
  local pid=$1 attempt=0
  while [ "$attempt" -lt 50 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    attempt=$((attempt + 1))
  done
  return 1
}

test_gate_commands_use_the_supervisor() {
  assert_grep "  lint: 'exec bin/fm-nm-command-supervisor.sh lint bin/fm-gate-lint.sh'" \
    "$ROOT/.no-mistakes.yaml" "configured lint command must exec the supervisor"
  assert_grep "  test: 'exec bin/fm-nm-command-supervisor.sh test bin/fm-gate-test.sh'" \
    "$ROOT/.no-mistakes.yaml" "configured test command must exec the supervisor"
  assert_grep 'for test_script in tests/*.test.sh; do' "$ROOT/bin/fm-gate-test.sh" \
    "gate test must retain the complete behavior suite"
  assert_grep 'uv run --directory tools/agent-fleet --locked pytest' "$ROOT/bin/fm-gate-test.sh" \
    "gate test must retain Agent Fleet pytest"
  assert_grep 'uv run --directory tools/agent-fleet --locked python -m compileall -q src' "$ROOT/bin/fm-gate-test.sh" \
    "gate test must retain Agent Fleet compileall"
  pass "configured lint and test commands exec the supervisor without shortening coverage"
}

test_failure_propagates_and_cleans_state() {
  local out rc=0
  out=$(cd "$WORKTREE" && FM_NM_COMMAND_STATE_DIR="$STATE_DIR" \
    isolated_run "$SUPERVISOR" test sh -c 'echo command-failed; exit 7') || rc=$?
  [ "$rc" = 7 ] || fail "supervisor returned $rc instead of child exit 7"
  assert_contains "$out" "command-failed" "supervisor preserves command output"
  [ ! -e "$STATE_DIR/01RUN.test.state" ] || fail "normal failure left command identity state"
  pass "supervisor propagates command failure and removes identity state"
}

test_killed_child_returns_failure_and_reaps_group() {
  local state="$STATE_DIR/01RUN.test.state" pid_file="$TMP_ROOT/killed-child.pid"
  local supervisor_pid child_pid rc=0
  (
    cd "$WORKTREE" || exit 1
    exec perl -e 'setpgrp(0, 0); exec @ARGV' env FM_NM_COMMAND_STATE_DIR="$STATE_DIR" \
      "$SUPERVISOR" test sh -c 'echo $$ > "$1"; echo command-started; while :; do sleep 1; done' sh "$pid_file"
  ) > "$TMP_ROOT/killed-child.out" 2>&1 &
  supervisor_pid=$!
  wait_for_file "$state"
  wait_for_file "$pid_file"
  child_pid=$(cat "$pid_file")
  kill -KILL "$child_pid"
  wait "$supervisor_pid" || rc=$?
  [ "$rc" -ne 0 ] || fail "killed command returned success"
  [ ! -e "$state" ] || fail "killed command left identity state"
  assert_grep 'command-started' "$TMP_ROOT/killed-child.out" "supervisor flushes killed command output"
  pass "a killed child returns a failed command and reaps its process group"
}

test_live_identity_is_provable() {
  local state="$STATE_DIR/01RUN.test.state" out supervisor_pid
  (
    cd "$WORKTREE" || exit 1
    exec perl -e 'setpgrp(0, 0); exec @ARGV' env FM_NM_COMMAND_STATE_DIR="$STATE_DIR" \
      "$SUPERVISOR" test sleep 30
  ) &
  supervisor_pid=$!
  wait_for_file "$state"
  out=$(FM_NM_COMMAND_STATE_DIR="$STATE_DIR" "$PROBE" 01RUN --step test --worktree "$WORKTREE" --sample 0)
  assert_contains "$out" "liveness: alive" "tracked supervisor identity must prove liveness"
  assert_contains "$out" "supervised pid $supervisor_pid" "probe reports the exact command pid"
  kill -TERM "$supervisor_pid" 2>/dev/null || true
  wait "$supervisor_pid" 2>/dev/null || true
  [ ! -e "$state" ] || fail "terminated supervisor left command identity state"
  pass "probe verifies the supervised command pid and process group"
}

test_missing_supervisor_reaps_group_and_reads_dead() {
  local state="$STATE_DIR/01RUN.test.state" pid_file="$TMP_ROOT/worker.pid"
  local supervisor_pid worker_pid out
  (
    cd "$WORKTREE" || exit 1
    exec perl -e 'setpgrp(0, 0); exec @ARGV' env FM_NM_COMMAND_STATE_DIR="$STATE_DIR" \
      "$SUPERVISOR" test sh -c 'echo $$ > "$1"; while :; do echo working; sleep 1; done' sh "$pid_file"
  ) &
  supervisor_pid=$!
  wait_for_file "$state"
  wait_for_file "$pid_file"
  worker_pid=$(cat "$pid_file")
  kill -KILL "$supervisor_pid"
  wait "$supervisor_pid" 2>/dev/null || true
  wait_for_process_exit "$worker_pid" || fail "watchdog left worker $worker_pid alive after supervisor death"
  out=$(FM_NM_COMMAND_STATE_DIR="$STATE_DIR" "$PROBE" 01RUN --step test --worktree "$WORKTREE" --sample 0)
  assert_contains "$out" "liveness: dead" "stale exact identity must report a missing command"
  assert_contains "$out" "after two checks" "missing command requires a stable absence recheck"
  pass "missing supervisor closes the command and yields a stable dead verdict"
}

test_gate_commands_use_the_supervisor
test_failure_propagates_and_cleans_state
test_killed_child_returns_failure_and_reaps_group
test_live_identity_is_provable
test_missing_supervisor_reaps_group_and_reads_dead

echo "all fm-nm-command-supervisor tests passed"
