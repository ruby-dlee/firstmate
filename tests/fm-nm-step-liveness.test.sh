#!/usr/bin/env bash
# Behavior tests for bin/fm-nm-step-liveness.sh - the "is this no-mistakes step
# actually doing work?" probe.
#
# The 2026-08-02 incident (docs/postmortems/nm-quiet-test-step.md) was a false
# DEAD reading: a configured-command step reports no agent pid, no round, and no
# streamed log for its whole run, so `axi status` renders a healthy step as
# quiet, and the hand check used to confirm death - a process search by NAME -
# found nothing because the test command's argv carries neither the run id nor
# the worktree path. Two healthy runs were aborted on that reading.
#
# These cases pin the probe over REAL processes in a REAL directory, because the
# whole point is that it observes the operating system rather than a status
# report:
#   (a) no process in the worktree            -> dead
#   (b) a live process in the worktree        -> alive (presence-only, --sample 0)
#   (c) argv-invisible process: the exact regression for the false negative -
#       the process is undiscoverable by name and discoverable by cwd
#   (d) a CPU-burning process                 -> alive, with measured progress
#   (e) a sleeping process                    -> stalled, explicitly NOT dead
#   (f) worktree resolution through the no-mistakes home layout
#   (g) unresolvable worktree                 -> unknown (never dead)
#   (h) usage error                           -> exit 2
#   (i) the named unit of work and its age, which separate slow from hung and
#       which bin/fm-crew-state.sh carries onto every heartbeat read
#   (j) deterministic process-gap and sampled-transition regressions
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROBE="$ROOT/bin/fm-nm-step-liveness.sh"
fm_test_tmproot_into TMP_ROOT fm-nm-step-liveness

RUN_ID=01TESTRUNTESTRUNTESTRUN00
WT="$TMP_ROOT/worktree"
mkdir -p "$WT"

# Track every process this suite starts so a failing assertion never leaks one.
# Descendants are killed too, not just the tracked pid: a leaked grandchild
# inherits this suite's stdout and holds the pipe open until it exits on its
# own, which makes a passing suite look like a hung one to whatever is reading
# it - including the gate's serial test loop.
STARTED_PIDS=""
kill_tree() {  # <pid>
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do
    kill_tree "$child"
  done
  kill -9 "$1" 2>/dev/null || true
}
kill_started() {
  local pid
  for pid in $STARTED_PIDS; do
    kill_tree "$pid"
    wait "$pid" 2>/dev/null || true
  done
  STARTED_PIDS=""
}
trap kill_started EXIT

verdict_of() {  # <probe output> -> the verdict word
  printf '%s\n' "$1" | sed -n 's/^liveness:[[:space:]]*\([a-z]*\).*/\1/p'
}

wait_for_barrier() {  # <barrier-dir> <probe-pid>
  local dir=$1 pid=$2 _
  for _ in {1..200}; do
    [ -s "$dir/ready" ] && return 0
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.05
  done
  return 1
}

# --- (a) no process in the worktree -> dead ---------------------------------

out=$("$PROBE" "$RUN_ID" --worktree "$WT" --sample 0)
[ "$(verdict_of "$out")" = dead ] || fail "empty worktree must read dead, got: $out"
assert_contains "$out" "procs: 0" "dead verdict reports zero processes"
pass "no process with its cwd in the worktree reads dead"

# --- (b) a live process in the worktree -> alive ----------------------------

( cd "$WT" && exec sleep 120 ) &
SLEEPER=$!
STARTED_PIDS="$STARTED_PIDS $SLEEPER"
# The probe reads the kernel's view of the process table, so poll briefly rather
# than assuming the fork is observable the instant the shell returns.
out=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  out=$("$PROBE" "$RUN_ID" --worktree "$WT" --sample 0)
  [ "$(verdict_of "$out")" = alive ] && break
  sleep 0.3
done
[ "$(verdict_of "$out")" = alive ] || fail "live process in worktree must read alive, got: $out"
pass "a live process with its cwd in the worktree reads alive"

# --- (c) the false-negative regression: invisible to a name search ----------
#
# This is the failure that cost two healthy runs. `sleep 120` names neither the
# run nor the worktree, exactly like the real `sh -c command -v tmux ...` test
# command and its `bash tests/<name>.test.sh` children.
by_name=$(pgrep -f "$WT" 2>/dev/null || true)
[ -z "$by_name" ] || fail "fixture is wrong: the process must be invisible to an argv search"
[ "$(verdict_of "$out")" = alive ] || fail "cwd search must find what an argv search cannot"
pass "a process invisible to an argv search is still found by working directory"

# --- (e) a sleeping process reads stalled, never dead -----------------------
#
# Ordered before the CPU case so the sleeper is still the only process here.
out=$("$PROBE" "$RUN_ID" --worktree "$WT" --sample 1)
[ "$(verdict_of "$out")" = stalled ] || fail "an idle process must read stalled, got: $out"
assert_not_contains "$out" "liveness: dead" "a sleeping process is never reported dead"
assert_contains "$out" "blocked on I/O" "stalled explains that it may be legitimately waiting"
pass "a process making no progress reads stalled, explicitly distinct from dead"

# --- (d) a CPU-burning process reports measured progress --------------------

( cd "$WT" && exec bash -c 'while :; do :; done' ) &
BURNER=$!
STARTED_PIDS="$STARTED_PIDS $BURNER"
out=$("$PROBE" "$RUN_ID" --worktree "$WT" --sample 1)
[ "$(verdict_of "$out")" = alive ] || fail "a CPU-burning process must read alive, got: $out"
assert_contains "$out" "cpu +" "the alive verdict reports the measured CPU delta"
pass "a process consuming CPU reads alive with measured progress"

kill_started

# --- (i) the reported unit of work ------------------------------------------
#
# "alive" alone still leaves hours of runtime unexplained, which is what made a
# healthy multi-hour step indistinguishable from a hang. The probe names the
# step's current unit of work and its age, and bin/fm-crew-state.sh carries that
# onto every heartbeat read, so the field is load-bearing rather than cosmetic.
#
# The shape mirrors the real one: a root shell the daemon owns, running one
# child at a time - the suite's `for t in tests/*.test.sh` loop.
( cd "$WT" && exec bash -c 'sleep 120 & wait' ) &
PARENT=$!
STARTED_PIDS="$STARTED_PIDS $PARENT"
out=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  out=$("$PROBE" "$RUN_ID" --worktree "$WT" --sample 0)
  case "$out" in *"doing: "*) break ;; esac
  sleep 0.3
done
assert_contains "$out" "doing: sleep 120" "the probe names the child the step is currently running"
# The age is what separates "slow" from "sitting on the same script for hours".
printf '%s\n' "$out" | grep -qE 'doing: sleep 120 \([0-9]+:[0-9]{2}' \
  || fail "the reported unit of work must carry its age, got: $out"
pass "the probe names the current unit of work and how long it has been running"

kill_started

# --- (f) worktree resolution through the no-mistakes home layout ------------

NM_HOME="$TMP_ROOT/nm-home"
mkdir -p "$NM_HOME/worktrees/repoid123/$RUN_ID"
out=$(FM_NM_HOME="$NM_HOME" "$PROBE" "$RUN_ID" --sample 0)
[ "$(verdict_of "$out")" = dead ] || fail "layout resolution must find the worktree, got: $out"
assert_contains "$out" "$RUN_ID" "the resolved worktree path names the run"
pass "the run's worktree resolves through the no-mistakes home layout"

# --- (g) an unresolvable worktree is unknown, never dead --------------------

out=$(FM_NM_HOME="$NM_HOME" "$PROBE" 01NOSUCHRUN0000000000000 --sample 0)
[ "$(verdict_of "$out")" = unknown ] || fail "an unresolvable run must read unknown, got: $out"
pass "an unresolvable run reads unknown rather than dead"

out=$("$PROBE" "$RUN_ID" --worktree "$TMP_ROOT/does-not-exist" --sample 0)
[ "$(verdict_of "$out")" = unknown ] || fail "a missing worktree must read unknown, got: $out"
pass "a missing worktree reads unknown rather than dead"

# --- (h) usage ---------------------------------------------------------------

status=0
"$PROBE" >/dev/null 2>&1 || status=$?
[ "$status" = 2 ] || fail "a missing run id must exit 2, got $status"
pass "a missing run id is a usage error"

# --- (j) REGRESSION: the 2026-08-02 test-start deadlock cannot recur ---------
#
# The deadlock was not that a step died. It was that a step recorded `running`
# was INDISTINGUISHABLE from a slow one, so a healthy multi-hour step and a
# genuinely dead one produced the same reading and three healthy runs were
# aborted on it. These cases pin both directions of that distinction over real
# processes, because a regression in EITHER direction recreates the outage:
# read a live step as dead and work gets destroyed; read a dead step as alive
# and the run wedges forever with nothing reporting it.

# (j1) The exact incident signature: a step whose log is quiet, whose agent_pid
# is empty and whose round reads `starting` - i.e. nothing in `axi status` says
# it is alive - is still reported ALIVE while its processes are working.
( cd "$WT" && exec bash -c 'while :; do :; done' ) &
LIVE=$!
STARTED_PIDS="$STARTED_PIDS $LIVE"
out=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  out=$("$PROBE" "$RUN_ID" --worktree "$WT" --sample 0)
  [ "$(verdict_of "$out")" = alive ] && break
  sleep 0.3
done
[ "$(verdict_of "$out")" = alive ] \
  || fail "REGRESSION: a working step with no axi-status liveness signal must read alive, got: $out"
pass "regression: a quiet step with no pid and no round still reads alive while working"

# (j2) A momentary gap between units of work must NOT read dead. The scan barrier
# proves the first scan was empty before the successor is allowed to appear, so
# this cannot pass merely because a load-delayed first scan found the successor.
kill -9 "$LIVE" 2>/dev/null || true
wait "$LIVE" 2>/dev/null || true
GAP_BARRIER="$TMP_ROOT/gap-barrier"
mkdir -p "$GAP_BARRIER"
GAP_OUT="$TMP_ROOT/gap.out"
FM_NM_TEST_BARRIER_DIR="$GAP_BARRIER" \
  FM_NM_TEST_BARRIER_PHASE=after-empty-scan \
  FM_NM_ABSENCE_CONFIRM_DELAY=0 \
  "$PROBE" "$RUN_ID" --worktree "$WT" --sample 0 > "$GAP_OUT" &
GAP_PROBE=$!
STARTED_PIDS="$STARTED_PIDS $GAP_PROBE"
wait_for_barrier "$GAP_BARRIER" "$GAP_PROBE" \
  || fail "the gap probe never proved its first scan was empty"
[ "$(cat "$GAP_BARRIER/ready")" = after-empty-scan ] \
  || fail "the gap probe reached the wrong barrier phase"
( cd "$WT" && exec bash -c 'while :; do :; done' ) &
SUCCESSOR=$!
STARTED_PIDS="$STARTED_PIDS $SUCCESSOR"
out=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  out=$("$PROBE" "$RUN_ID" --worktree "$WT" --sample 0)
  [ "$(verdict_of "$out")" = alive ] && break
done
[ "$(verdict_of "$out")" = alive ] || fail "the successor was not observable before the confirming rescan"
printf 'after-empty-scan\n' > "$GAP_BARRIER/release"
wait "$GAP_PROBE" || fail "the gap probe failed after its barrier was released"
out=$(cat "$GAP_OUT")
[ "$(verdict_of "$out")" = alive ] \
  || fail "REGRESSION: a gap with a confirmed successor must be reported alive, got: $out"
pass "regression: a momentary gap between units of work is not reported as death"

# (j3) A process set present at the first scan but gone by the second is an
# ambiguous step transition, not evidence that work remains alive.
SAMPLE_BARRIER="$TMP_ROOT/sample-barrier"
mkdir -p "$SAMPLE_BARRIER"
SAMPLE_OUT="$TMP_ROOT/sample.out"
FM_NM_TEST_BARRIER_DIR="$SAMPLE_BARRIER" \
  FM_NM_TEST_BARRIER_PHASE=before-progress-sample \
  "$PROBE" "$RUN_ID" --worktree "$WT" --sample 1 > "$SAMPLE_OUT" &
SAMPLE_PROBE=$!
STARTED_PIDS="$STARTED_PIDS $SAMPLE_PROBE"
wait_for_barrier "$SAMPLE_BARRIER" "$SAMPLE_PROBE" \
  || fail "the sample probe never observed the initial process set"
[ "$(cat "$SAMPLE_BARRIER/ready")" = before-progress-sample ] \
  || fail "the sample probe reached the wrong barrier phase"
kill_tree "$SUCCESSOR"
wait "$SUCCESSOR" 2>/dev/null || true
printf 'before-progress-sample\n' > "$SAMPLE_BARRIER/release"
wait "$SAMPLE_PROBE" || fail "the sample probe failed after its barrier was released"
out=$(cat "$SAMPLE_OUT")
[ "$(verdict_of "$out")" = unknown ] \
  || fail "a process set that vanished during the sample must read unknown, got: $out"
assert_contains "$out" "processes present at the first scan were gone by the second" \
  "the transition verdict explains what changed between scans"
assert_contains "$out" "transition could not be established" \
  "the transition verdict states that the outcome is ambiguous"
pass "regression: a process set that vanished during sampling reads unknown"

kill_started

for delay in '' -1 invalid 1s; do
  out=$(FM_NM_ABSENCE_CONFIRM_DELAY="$delay" "$PROBE" "$RUN_ID" --worktree "$WT" --sample 0)
  [ "$(verdict_of "$out")" = unknown ] \
    || fail "an invalid absence-confirmation delay must read unknown, got: $out"
  assert_contains "$out" "invalid absence-confirmation delay" \
    "an invalid absence-confirmation delay explains why it was rejected"
done

out=$(FM_NM_ABSENCE_CONFIRM_DELAY=0 "$PROBE" "$RUN_ID" --worktree "$WT" --sample 0)
[ "$(verdict_of "$out")" = unknown ] \
  || fail "zero delay without the empty-scan test barrier must read unknown, got: $out"
assert_contains "$out" "zero requires the explicit empty-scan test barrier" \
  "zero delay names its test-only requirement"

WAIT_FAIL_BIN="$TMP_ROOT/wait-fail-bin"
mkdir -p "$WAIT_FAIL_BIN"
cat > "$WAIT_FAIL_BIN/sleep" <<'SH'
#!/usr/bin/env bash
exit 7
SH
chmod +x "$WAIT_FAIL_BIN/sleep"
out=$(PATH="$WAIT_FAIL_BIN:$PATH" FM_NM_ABSENCE_CONFIRM_DELAY=1 \
  "$PROBE" "$RUN_ID" --worktree "$WT" --sample 0)
[ "$(verdict_of "$out")" = unknown ] \
  || fail "a failed absence-confirmation wait must read unknown, got: $out"
assert_contains "$out" "absence-confirmation wait failed: sleep exited 7" \
  "a failed wait explains why absence was not confirmed"

# (j4) A genuinely absent step still reads dead after the confirming rescan, so
# the fix for (j2) did not buy safety by making `dead` unreachable.
out=$(FM_NM_ABSENCE_CONFIRM_DELAY=1 "$PROBE" "$RUN_ID" --worktree "$WT" --sample 0)
[ "$(verdict_of "$out")" = dead ] \
  || fail "REGRESSION: a genuinely empty worktree must still read dead, got: $out"
assert_contains "$out" "confirmed by a second scan" "the dead verdict states that absence was confirmed"
pass "regression: confirmed absence still reads dead, so the distinction stays usable"
