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
# These cases pin exact supervised identity separately from unowned worktree
# process presence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROBE="$ROOT/bin/fm-nm-step-liveness.sh"
fm_test_tmproot_into TMP_ROOT fm-nm-step-liveness

RUN_ID=01TESTRUNTESTRUNTESTRUN00
WT="$TMP_ROOT/worktree"
STATE_DIR="$TMP_ROOT/command-state"
mkdir -p "$WT" "$STATE_DIR"
export FM_NM_COMMAND_STATE_DIR="$STATE_DIR"

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

# --- no command identity never proves either liveness direction --------------

out=$("$PROBE" "$RUN_ID" --worktree "$WT" --sample 0)
[ "$(verdict_of "$out")" = unknown ] || fail "unowned empty worktree must read unknown, got: $out"
assert_contains "$out" "two checks" "absence is rechecked before it is reported"
pass "worktree absence without command identity reads unknown"

# --- unowned worktree presence remains unknown ------------------------------

( cd "$WT" && exec sleep 120 ) &
SLEEPER=$!
STARTED_PIDS="$STARTED_PIDS $SLEEPER"
# The probe reads the kernel's view of the process table, so poll briefly rather
# than assuming the fork is observable the instant the shell returns.
out=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  out=$("$PROBE" "$RUN_ID" --worktree "$WT" --sample 0)
  case "$out" in *"procs: "[1-9]*) break ;; esac
  sleep 0.3
done
[ "$(verdict_of "$out")" = unknown ] || fail "unowned worktree process must read unknown, got: $out"
assert_contains "$out" "no supervised command identity" "presence is not treated as command identity"
pass "an unrelated worktree process cannot prove command liveness"

# --- (c) the false-negative regression: invisible to a name search ----------
#
# This is the failure that cost two healthy runs. `sleep 120` names neither the
# run nor the worktree, exactly like the real `sh -c command -v tmux ...` test
# command and its `bash tests/<name>.test.sh` children.
by_name=$(pgrep -f "$WT" 2>/dev/null || true)
[ -z "$by_name" ] || fail "fixture is wrong: the process must be invisible to an argv search"
[ "$(verdict_of "$out")" = unknown ] || fail "cwd presence without identity must stay unknown"
pass "argv-invisible cwd presence remains observation rather than liveness proof"

# A stale exact identity is dead even when an unrelated process holds the cwd.
touch "$STATE_DIR/$RUN_ID.test.identity.99999999"
cat > "$STATE_DIR/$RUN_ID.test.state" <<EOF
version=2
run_id=$RUN_ID
step=test
worktree=$(cd "$WT" && pwd -P)
pid=99999999
pgid=99999999
start=Mon Jan 1 00:00:00 2000
identity_file=$STATE_DIR/$RUN_ID.test.identity.99999999
EOF
out=$("$PROBE" "$RUN_ID" --step test --worktree "$WT" --sample 0)
[ "$(verdict_of "$out")" = dead ] || fail "missing exact identity must read dead despite cwd process, got: $out"
assert_contains "$out" "after two checks" "dead identity requires a stable absence recheck"
pass "an unrelated cwd process cannot mask a missing supervised command"
rm -f "$STATE_DIR/$RUN_ID.test.state" "$STATE_DIR/$RUN_ID.test.identity.99999999"

out=$("$PROBE" "$RUN_ID" --worktree "$WT" --sample 1)
[ "$(verdict_of "$out")" = unknown ] || fail "sleeping unowned process must remain unknown, got: $out"
pass "an idle unowned process is not mislabeled alive or dead"

# --- unowned CPU activity remains unknown -----------------------------------

( cd "$WT" && exec bash -c 'while :; do :; done' ) &
BURNER=$!
STARTED_PIDS="$STARTED_PIDS $BURNER"
out=$("$PROBE" "$RUN_ID" --worktree "$WT" --sample 1)
[ "$(verdict_of "$out")" = unknown ] || fail "busy unowned process must remain unknown, got: $out"
pass "CPU activity without command identity is not liveness proof"

kill_started

# --- (f) worktree resolution through the no-mistakes home layout ------------

NM_HOME="$TMP_ROOT/nm-home"
mkdir -p "$NM_HOME/worktrees/repoid123/$RUN_ID"
out=$(FM_NM_HOME="$NM_HOME" "$PROBE" "$RUN_ID" --sample 0)
[ "$(verdict_of "$out")" = unknown ] || fail "layout resolution must find the worktree, got: $out"
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
