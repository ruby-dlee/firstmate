#!/usr/bin/env bash
# tests/fm-afk-inject-e2e.test.sh - private-socket end-to-end test for the afk
# daemon's production refusal path for a pane-backed tmux supervisor.
#
# A captain-relevant status must remain buffered because tmux has no atomic
# agent-session-bound steering operation. No text or Enter may reach the pane.
# The submit-ACK retry mechanics remain covered by fm-daemon.test.sh's explicit
# function-level test adapter; this real-pane suite exercises production wiring.
#
# Isolation: all test tmux runs on a dedicated socket (tmux -L afk-e2e-<pid>).
# A tmux shim first on PATH redirects the daemon's bare `tmux` calls to the
# private socket. The daemon points at a throwaway state dir (FM_STATE_OVERRIDE)
# and the test pane (FM_SUPERVISOR_TARGET). Nothing touches the live fleet.
# FM_SUPERVISOR_BACKEND=tmux is passed explicitly (not left to auto-detection):
# this test's own process may itself be running inside herdr (HERDR_ENV=1 is
# inherited by every process herdr manages a pane for), which would otherwise
# leak into the spawned daemon subprocess and misdetect backend=herdr against
# what is actually a tmux pane on the private socket.
#
# Assert on submitted CONTENT (logged verbatim by the supervisor pane), not pane
# appearance - terminal line-wrapping looks like newlines but isn't.
set -u

# This isolated test drives the guarded daemon from the no-mistakes gate
# worktree, so opt into the same suite-only lifecycle exemption as tests/lib.sh.
export FM_GATE_REFUSE_BYPASS=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

# Skip gracefully if tmux is not installed.
command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
SOCKET="afk-e2e-$$"
TMUX_TEST_TMPDIR=$(mktemp -d /tmp/fm-afk-tmux.XXXXXX) || exit 1
export TMUX_TMPDIR="$TMUX_TEST_TMPDIR"
STATE_DIR=
TMUX_SHIM_DIR=
LOG_FILE=
DAEMON_PID=
SUPERVISOR_PANE=
LOOP_SCRIPT=

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

cleanup_all() {
  if [ -n "${DAEMON_PID:-}" ]; then
    afk_exit "${STATE_DIR:-}" 2>/dev/null || true
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  if [ -n "${SOCKET:-}" ] && [ -n "${REAL_TMUX:-}" ]; then
    "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  fi
  rm -rf "${TMUX_SHIM_DIR:-}" 2>/dev/null || true
  rm -rf "${STATE_DIR:-}" 2>/dev/null || true
  rm -rf "${TMUX_TEST_TMPDIR:-}" 2>/dev/null || true
}
trap cleanup_all EXIT

# --- setup ------------------------------------------------------------------

STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-e2e.XXXXXX")
mkdir -p "$STATE_DIR"
LOG_FILE="$STATE_DIR/submitted.log"
: > "$LOG_FILE"

# Source the daemon to get FM_INJECT_MARK, afk_enter, afk_exit.
# shellcheck source=bin/fm-supervise-daemon.sh
. "$DAEMON"

# Private tmux server with a supervisor session.
"$REAL_TMUX" -L "$SOCKET" new-session -d -s supervisor -x 200 -y 50
SUPERVISOR_PANE=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t supervisor '#{pane_id}')

# Supervisor pane loop: a small deterministic composer that logs each submitted
# line verbatim (hex + text + classification). It draws the in-progress input
# itself instead of relying on the terminal driver's canonical-mode echo, because
# tmux cursor placement for that echo varies across CI environments.
LOOP_SCRIPT="$STATE_DIR/supervisor-loop.sh"
cat > "$LOOP_SCRIPT" <<'LOOP'
#!/usr/bin/env bash
MARK=$'\x1f'
LOG="$1"
OLD_STTY=$(stty -g 2>/dev/null || true)
[ -z "$OLD_STTY" ] || stty -echo -icanon min 1 time 0 2>/dev/null || true
cleanup() {
  [ -z "$OLD_STTY" ] || stty "$OLD_STTY" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

_buf=
redraw() {
  printf '\r\033[K%s' "$_buf"
}
submit_line() {
  local _line=$_buf _c _hex
  if [ "${_line:0:1}" = "$MARK" ]; then
    _c="injection"
  else
    _c="user"
  fi
  _hex=$(printf '%s' "$_line" | od -An -tx1 | tr -d ' \n')
  printf '%s\t%s\t%s\n' "$_hex" "$_line" "$_c" >> "$LOG"
  _buf=
  printf '\r\033[K\n'
  redraw
}

redraw
while IFS= read -r -n 1 _ch; do
  if [ -z "$_ch" ]; then
    submit_line
    continue
  fi
  case "$_ch" in
    $'\r'|$'\n') submit_line ;;
    $'\177'|$'\b') _buf=${_buf%?}; redraw ;;
    *) _buf="${_buf}${_ch}"; redraw ;;
  esac
done
LOOP
chmod +x "$LOOP_SCRIPT"

# Start the loop in the supervisor pane.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" \
  "bash '$LOOP_SCRIPT' '$LOG_FILE'" Enter
sleep 1  # let the loop start and settle

# tmux shim: redirects bare `tmux` to the private socket. Optionally swallows
# the first Enter (file-based flag) for Scenario B.
TMUX_SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-shim.XXXXXX")
cat > "$TMUX_SHIM_DIR/tmux" <<SHIM
#!/usr/bin/env bash
if [ "\${1:-}" = "send-keys" ] && [ -f "$STATE_DIR/.swallow-enter" ]; then
  shift
  _args=()
  for _arg in "\$@"; do
    if [ "\$_arg" = "Enter" ] && [ -f "$STATE_DIR/.swallow-enter" ]; then
      rm -f "$STATE_DIR/.swallow-enter"
      continue
    fi
    _args+=("\$_arg")
  done
  exec "$REAL_TMUX" -L "$SOCKET" send-keys "\${_args[@]}"
fi
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SHIM
chmod +x "$TMUX_SHIM_DIR/tmux"

# Create a fake crewmate window (the watcher lists fm-* windows for stale
# detection). The pane is an inert shell - it just needs to exist.
"$REAL_TMUX" -L "$SOCKET" new-window -d -n fm-fake-c1 -t supervisor

start_daemon() {
  PATH="$TMUX_SHIM_DIR:$PATH" \
  FM_STATE_OVERRIDE="$STATE_DIR" \
  FM_SUPERVISOR_TARGET="$SUPERVISOR_PANE" \
  FM_SUPERVISOR_BACKEND=tmux \
  FM_ESCALATE_BATCH_SECS=0 \
  FM_HOUSEKEEPING_TICK=1 \
  FM_POLL=1 \
  FM_SIGNAL_GRACE=1 \
  FM_HEARTBEAT=999999 \
  FM_CHECK_INTERVAL=999999 \
  FM_INJECT_CONFIRM_SLEEP=0.3 \
  FM_INJECT_CONFIRM_RETRIES=5 \
  FM_STALE_ESCALATE_SECS=999999 \
  nohup "$DAEMON" >"$STATE_DIR/daemon.out" 2>"$STATE_DIR/daemon.err" &
  DAEMON_PID=$!
  # Wait for the daemon to start and acquire the lock.
  local i=0
  while [ "$i" -lt 30 ]; do
    [ -f "$STATE_DIR/.supervise-daemon.pid" ] && break
    sleep 0.2
    i=$((i + 1))
  done
  [ -f "$STATE_DIR/.supervise-daemon.pid" ] || {
    echo "daemon stderr:" >&2; cat "$STATE_DIR/daemon.err" >&2
    fail "daemon did not start (no pid file after 6s)"
  }
}

stop_daemon() {
  [ -n "${DAEMON_PID:-}" ] || return 0
  afk_exit "$STATE_DIR" 2>/dev/null || true
  kill "$DAEMON_PID" 2>/dev/null || true
  wait "$DAEMON_PID" 2>/dev/null || true
  DAEMON_PID=""
  sleep 1
}

reset_state() {
  # Clear daemon and watcher state for a fresh scenario.
  rm -f "$STATE_DIR"/*.status \
         "$STATE_DIR"/.subsuper-* \
         "$STATE_DIR"/.wake-queue* \
         "$STATE_DIR"/.watch.lock* \
         "$STATE_DIR"/.last-* \
         "$STATE_DIR"/.hash-* \
         "$STATE_DIR"/.count-* \
         "$STATE_DIR"/.stale-* \
         "$STATE_DIR"/.seen-* \
         "$STATE_DIR"/.heartbeat-streak \
         "$STATE_DIR"/.swallow-enter \
         2>/dev/null || true
  : > "$LOG_FILE"
}

# --- pane_input_pending environment self-check ------------------------------
# Verify that pane_input_pending (which uses cursor_y + capture-pane) can detect
# typed text in this tmux environment. If it can't, the e2e cannot prove the
# operator-visible injection contracts it owns.

selfcheck_pane_input_pending() {
  local check_text="selfcheck-marker-12345"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" -l "$check_text"
  if wait_for_pane_input_pending; then
    # Detected - clean up the text and proceed.
    "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" Enter
    sleep 0.3
    return 0
  fi
  # Not detected - print diagnostics and fail.
  echo "pane_input_pending cannot detect typed text in this tmux environment" >&2
  local _cy _line
  _cy=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SUPERVISOR_PANE" '#{cursor_y}' 2>/dev/null)
  echo "  cursor_y=$_cy" >&2
  echo "  pane capture (first 10 lines):" >&2
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SUPERVISOR_PANE" 2>/dev/null | head -10 | sed 's/^/    /' >&2
  _line=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SUPERVISOR_PANE" 2>/dev/null | sed -n "$((_cy + 1))p")
  echo "  cursor line: '$_line'" >&2
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" Enter
  fail "pane_input_pending self-check failed"
}

wait_for_pane_input_pending() {
  local i=0
  while [ "$i" -lt 30 ]; do
    if PATH="$TMUX_SHIM_DIR:$PATH" pane_input_pending "$SUPERVISOR_PANE"; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

selfcheck_pane_input_pending

# --- Scenario A: human-partial-input ----------------------------------------

test_scenario_a() {
  reset_state
  afk_enter "$STATE_DIR"
  start_daemon

  # Type partial text into the supervisor pane with NO Enter. This simulates the
  # captain returning and starting to type before afk has been cleared.
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" -l "human draft text"
  wait_for_pane_input_pending \
    || fail "Scenario A: human draft text did not become detectable as pending input"

  # Write a captain-relevant status to trigger a real escalation through the
  # real watcher child.
  echo "done: PR https://example.test/pr/100" > "$STATE_DIR/fake-c1.status"

  # Wait for the watcher to detect the change and the daemon to attempt inject.
  sleep 6

  [ ! -s "$LOG_FILE" ] || fail "Scenario A: pending draft was submitted or merged"
  [ -s "$STATE_DIR/.subsuper-escalations" ] || fail "Scenario A: refusal lost the buffered escalation"
  PATH="$TMUX_SHIM_DIR:$PATH" pane_input_pending "$SUPERVISOR_PANE" \
    || fail "Scenario A: refusal changed the captain's pending draft"
  stop_daemon
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" Enter
  sleep 0.3
  pass "Scenario A: pending human input stays untouched and escalation stays buffered"
}

# --- Scenario B: swallowed-Enter --------------------------------------------

test_scenario_b() {
  reset_state
  afk_enter "$STATE_DIR"

  # Arm the swallow: the daemon's first Enter will be dropped by the shim.
  touch "$STATE_DIR/.swallow-enter"

  start_daemon

  # Write a captain-relevant status to trigger a real escalation.
  echo "done: PR https://example.test/pr/200" > "$STATE_DIR/fake-c1.status"

  # Production refuses before any pane input, so the shim's marker must remain.
  sleep 8
  [ -e "$STATE_DIR/.swallow-enter" ] || fail "Scenario B: production refusal sent Enter"
  [ ! -s "$LOG_FILE" ] || fail "Scenario B: production refusal submitted pane input"
  [ -s "$STATE_DIR/.subsuper-escalations" ] || fail "Scenario B: refusal lost the buffered escalation"
  stop_daemon
  pass "Scenario B: refusal never reaches the swallowed-Enter shim and preserves the buffer"
}

# --- Scenario C: idle-pane production refusal -------------------------------

test_scenario_c() {
  reset_state
  afk_enter "$STATE_DIR"
  start_daemon

  echo "done: PR https://example.test/pr/300" > "$STATE_DIR/fake-c1.status"
  sleep 8
  [ ! -s "$LOG_FILE" ] || fail "Scenario C: production refusal submitted pane input"
  if PATH="$TMUX_SHIM_DIR:$PATH" pane_input_pending "$SUPERVISOR_PANE"; then
    fail "Scenario C: production refusal left text pending in the idle pane"
  fi
  [ -s "$STATE_DIR/.subsuper-escalations" ] || fail "Scenario C: refusal lost the buffered escalation"
  grep -q 'no atomic agent-session-bound tmux steering route' "$STATE_DIR/.supervise-daemon.log" \
    || fail "Scenario C: production refusal was not recorded"
  stop_daemon
  pass "Scenario C: idle-pane refusal buffers escalation with zero submission"
}

test_scenario_a
test_scenario_b
test_scenario_c
