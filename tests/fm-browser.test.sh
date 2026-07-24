#!/usr/bin/env bash
# Behavior tests for Firstmate's chrome-devtools-axi isolation and reaping.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BROWSER="$ROOT/bin/fm-browser.sh"
TMP_ROOT=$(fm_test_tmproot fm-browser-tests)
CASE="$TMP_ROOT/case"
FAKEBIN="$CASE/fakebin"
STATE_ROOT="$CASE/browser-state"
TASK_TMP_ROOT="$CASE/task-tmp"
META_ROOT="$CASE/task-state"
CANARY="$CASE/Google Chrome Canary"
AXI_LOG="$CASE/axi.log"
REAL_NODE=$(command -v node)
mkdir -p "$FAKEBIN" "$STATE_ROOT" "$TASK_TMP_ROOT" "$META_ROOT"

cleanup() {
  local pid_file pid
  for pid_file in "$STATE_ROOT"/sessions/fm-*/bridge.pid; do
    [ -f "$pid_file" ] || continue
    pid=$(sed -nE 's/^\{"pid":([0-9]+),"port":[0-9]+\}$/\1/p' "$pid_file")
    [ -n "$pid" ] || continue
    kill -KILL "-$pid" 2>/dev/null || true
  done
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

cat > "$CASE/chrome-devtools-axi-bridge.js" <<'JS'
const fs = require("fs");
const { spawn } = require("child_process");
const headless = spawn(process.execPath, [process.env.FM_FAKE_HEADLESS_SCRIPT], {
  stdio: "ignore",
});
fs.writeFileSync(process.env.FM_FAKE_HEADLESS_PID, String(headless.pid));
setInterval(() => {}, 1000);
JS

cat > "$CASE/fake-headless-chrome.js" <<'JS'
setInterval(() => {}, 1000);
JS

cat > "$CASE/launch-bridge.js" <<'JS'
const fs = require("fs");
const { spawn } = require("child_process");
const sessionDir = process.argv[2];
const bridge = spawn(
  process.execPath,
  [process.env.FM_FAKE_BRIDGE_SCRIPT],
  {
    detached: true,
    stdio: "ignore",
    env: {
      ...process.env,
      FM_FAKE_HEADLESS_PID: `${sessionDir}/headless.pid`,
    },
  },
);
bridge.unref();
fs.writeFileSync(
  `${sessionDir}/bridge.pid`,
  JSON.stringify({ pid: bridge.pid, port: 9555 }),
);
process.stdout.write(String(bridge.pid));
JS

cat > "$FAKEBIN/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s|channel=%s|session=%s|auto=%s|url=%s|profile=%s|port=%s|headed=%s|args=%s\n' \
  "${1:-}" "${CHROME_DEVTOOLS_AXI_CHANNEL-unset}" "${CHROME_DEVTOOLS_AXI_SESSION-unset}" \
  "${CHROME_DEVTOOLS_AXI_AUTO_CONNECT-unset}" "${CHROME_DEVTOOLS_AXI_BROWSER_URL-unset}" \
  "${CHROME_DEVTOOLS_AXI_USER_DATA_DIR-unset}" "${CHROME_DEVTOOLS_AXI_PORT-unset}" \
  "${CHROME_DEVTOOLS_AXI_HEADED-unset}" "${CHROME_DEVTOOLS_AXI_CHROME_ARGS-unset}" \
  >> "$FM_FAKE_AXI_LOG"
session_dir="$FM_BROWSER_STATE_ROOT/sessions/$CHROME_DEVTOOLS_AXI_SESSION"
case "${1:-}" in
  open|start)
    if [ ! -f "$session_dir/bridge.pid" ]; then
      "$FM_FAKE_NODE" "$FM_FAKE_LAUNCHER" "$session_dir" >/dev/null
    fi
    ;;
  stop)
    if [ -f "$session_dir/bridge.pid" ]; then
      pid=$(sed -nE 's/^\{"pid":([0-9]+),"port":[0-9]+\}$/\1/p' "$session_dir/bridge.pid")
      [ -z "$pid" ] || kill -TERM "-$pid" 2>/dev/null || true
      rm -f "$session_dir/bridge.pid"
    fi
    ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/chrome-devtools-axi"

export FM_BROWSER_TEST_LAB=firstmate-browser-test-lab-v1
export FM_BROWSER_STATE_ROOT="$STATE_ROOT"
export FM_BROWSER_CANARY_EXECUTABLE="$CANARY"
export FM_FAKE_AXI_LOG="$AXI_LOG"
export FM_FAKE_NODE="$REAL_NODE"
export FM_FAKE_LAUNCHER="$CASE/launch-bridge.js"
export FM_FAKE_BRIDGE_SCRIPT="$CASE/chrome-devtools-axi-bridge.js"
export FM_FAKE_HEADLESS_SCRIPT="$CASE/fake-headless-chrome.js"
export PATH="$FAKEBIN:$PATH"

write_meta() {
  local task=$1 generation=$2 meta
  meta="$META_ROOT/$task.meta"
  {
    echo "generation_id=$generation"
    echo "browser_session=fm-$task"
    echo "browser_channel=canary"
  } > "$meta"
  printf '%s\n' "$meta"
}

prepare_task() {
  local task=$1 generation=$2 meta=$3 task_tmp
  task_tmp="$TASK_TMP_ROOT/$task"
  mkdir -p "$task_tmp"
  "$BROWSER" prepare "$task" "$generation" "$task_tmp" "$meta"
}

session_pid() {
  sed -nE 's/^\{"pid":([0-9]+),"port":[0-9]+\}$/\1/p' "$STATE_ROOT/sessions/fm-$1/bridge.pid"
}

wait_gone() {
  local pid=$1
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.05
  done
  return 1
}

test_missing_canary_fails_before_bridge_start() {
  local task=missing generation=gen-missing meta wrapper_dir status
  meta=$(write_meta "$task" "$generation")
  wrapper_dir=$(prepare_task "$task" "$generation" "$meta")
  : > "$AXI_LOG"
  "$wrapper_dir/chrome-devtools-axi" open about:blank >/dev/null 2>&1
  status=$?
  [ "$status" -eq 78 ] || fail "missing Canary should return 78, got $status"
  [ ! -s "$AXI_LOG" ] || fail "missing Canary invoked the underlying browser tool"
  [ ! -f "$STATE_ROOT/sessions/fm-$task/bridge.pid" ] \
    || fail "missing Canary started a bridge"
  "$wrapper_dir/chrome-devtools-axi" --help >/dev/null
  grep -Eq '^--help\|channel=canary\|session=fm-missing\|' "$AXI_LOG" \
    || fail "help should remain available through the pinned wrapper"
  pass "browser wrapper: missing Canary fails loudly before bridge creation"
}

test_prepare_refuses_unowned_existing_session() {
  local task=unowned generation=gen-unowned meta task_tmp session_dir status
  meta=$(write_meta "$task" "$generation")
  task_tmp="$TASK_TMP_ROOT/$task"
  session_dir="$STATE_ROOT/sessions/fm-$task"
  mkdir -p "$task_tmp" "$session_dir"
  : > "$session_dir/captain-owned-sentinel"
  "$BROWSER" prepare "$task" "$generation" "$task_tmp" "$meta" >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "prepare claimed an existing session without a Firstmate owner marker"
  [ -f "$session_dir/captain-owned-sentinel" ] \
    || fail "prepare modified an unowned existing session"
  [ ! -e "$session_dir/firstmate-owner" ] \
    || fail "prepare wrote a Firstmate marker into an unowned existing session"
  pass "browser ownership: existing unmarked session is never claimed or modified"
}

test_wrapper_pins_channel_and_strips_unsafe_overrides() {
  local task=pinned generation=gen-pinned meta wrapper_dir pid
  : > "$CANARY"
  chmod +x "$CANARY"
  meta=$(write_meta "$task" "$generation")
  wrapper_dir=$(prepare_task "$task" "$generation" "$meta")
  : > "$AXI_LOG"
  CHROME_DEVTOOLS_AXI_CHANNEL=stable \
    CHROME_DEVTOOLS_AXI_SESSION=default \
    CHROME_DEVTOOLS_AXI_AUTO_CONNECT=1 \
    CHROME_DEVTOOLS_AXI_BROWSER_URL=http://127.0.0.1:9222 \
    CHROME_DEVTOOLS_AXI_USER_DATA_DIR="$CASE/captain-profile" \
    CHROME_DEVTOOLS_AXI_PORT=9224 \
    CHROME_DEVTOOLS_AXI_HEADED=1 \
    CHROME_DEVTOOLS_AXI_CHROME_ARGS=--user-data-dir=/captain \
    "$wrapper_dir/chrome-devtools-axi" open about:blank >/dev/null
  grep -Eq '^open\|channel=canary\|session=fm-pinned\|auto=unset\|url=unset\|profile=unset\|port=unset\|headed=unset\|args=unset$' \
    "$AXI_LOG" || fail "wrapper did not pin Canary or strip captain-Chrome attachment overrides"
  pid=$(session_pid "$task")
  kill -0 "$pid" 2>/dev/null || fail "pinned wrapper did not launch the fake bridge"
  "$BROWSER" reap "$task" "$meta"
  wait_gone "$pid" || fail "explicit reap left the bridge alive"
  [ ! -e "$STATE_ROOT/sessions/fm-$task" ] || fail "explicit reap left browser session state"
  pass "browser wrapper: caller overrides cannot escape Canary or task-session isolation"
}

test_sweep_preserves_live_owner_and_reaps_orphan() {
  local task=sweep generation=gen-sweep meta wrapper_dir bridge_pid headless_pid out before after
  meta=$(write_meta "$task" "$generation")
  wrapper_dir=$(prepare_task "$task" "$generation" "$meta")
  "$wrapper_dir/chrome-devtools-axi" start >/dev/null
  bridge_pid=$(session_pid "$task")
  headless_pid=$(cat "$STATE_ROOT/sessions/fm-$task/headless.pid")
  before=$(ps -p "$bridge_pid,$headless_pid" -o pid=,ppid=,pgid=,command= 2>/dev/null)
  out=$("$BROWSER" sweep)
  [ -z "$out" ] || fail "live owner sweep should be silent, got: $out"
  kill -0 "$bridge_pid" 2>/dev/null || fail "sweep killed a live crew's bridge"
  kill -0 "$headless_pid" 2>/dev/null || fail "sweep killed a live crew's browser child"
  rm -f "$meta"
  out=$("$BROWSER" sweep)
  assert_contains "$out" "BROWSER_SWEEP: orphaned session fm-$task: reaped" \
    "sweep did not report orphan cleanup"
  wait_gone "$bridge_pid" || fail "orphan sweep left the bridge alive"
  wait_gone "$headless_pid" || fail "orphan sweep left the browser child alive"
  after=$(ps -p "$bridge_pid,$headless_pid" -o pid=,ppid=,pgid=,command= 2>/dev/null || true)
  [ -z "$after" ] || fail "orphan sweep process listing still contains owned processes: $after"
  printf 'browser process evidence before reap:\n%s\nbrowser process evidence after reap: <none>\n' "$before"
  pass "browser sweep: live generation preserved; orphan bridge and child reaped"
}

test_stop_then_open_relaunches_live_session() {
  local task=relaunch generation=gen-relaunch meta wrapper_dir first_pid second_pid
  meta=$(write_meta "$task" "$generation")
  wrapper_dir=$(prepare_task "$task" "$generation" "$meta")
  "$wrapper_dir/chrome-devtools-axi" open about:blank >/dev/null
  first_pid=$(session_pid "$task")
  "$wrapper_dir/chrome-devtools-axi" stop >/dev/null
  wait_gone "$first_pid" || fail "stop left the first bridge alive"
  "$wrapper_dir/chrome-devtools-axi" open about:blank >/dev/null
  second_pid=$(session_pid "$task")
  [ "$second_pid" != "$first_pid" ] || fail "open after stop did not launch a fresh bridge"
  kill -0 "$second_pid" 2>/dev/null || fail "fresh bridge is not alive after relaunch"
  "$BROWSER" reap "$task" "$meta"
  wait_gone "$second_pid" || fail "final reap left relaunched bridge alive"
  pass "browser wrapper: stop does not wedge a live crew; next open relaunches"
}

test_missing_canary_fails_before_bridge_start
test_prepare_refuses_unowned_existing_session
test_wrapper_pins_channel_and_strips_unsafe_overrides
test_sweep_preserves_live_owner_and_reaps_orphan
test_stop_then_open_relaunches_live_session
