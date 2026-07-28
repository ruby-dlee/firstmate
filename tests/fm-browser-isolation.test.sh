#!/usr/bin/env bash
# Behavior tests for task-scoped browser launch, teardown reaping, and legacy
# process discrimination. All process mutations are confined to fake programs
# and profiles under this suite's private temp root.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BROWSER="$ROOT/bin/fm-browser-isolation.sh"
WRAPPER="$ROOT/bin/chrome-devtools-axi"
SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
TMP_ROOT=
TEARDOWN_TASK_TMP=
TEARDOWN_BROWSER_PID=
TEARDOWN_BRIDGE_PID=

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

cleanup() {
  for cleanup_pid in \
    "${UNRELATED_PID:-}" \
    "${LEGACY_BRIDGE_PID:-}" \
    "${LEGACY_BROWSER_PID:-}" \
    "${HEADED_BROWSER_PID:-}" \
    "${TEARDOWN_BROWSER_PID:-}" \
    "${TEARDOWN_BRIDGE_PID:-}"
  do
    [ -n "$cleanup_pid" ] || continue
    if kill -0 "$cleanup_pid" 2>/dev/null; then
      kill "$cleanup_pid" 2>/dev/null || true
    fi
    wait "$cleanup_pid" 2>/dev/null || true
  done
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
  if [ -n "${TEARDOWN_TASK_TMP:-}" ]; then
    rm -rf "$TEARDOWN_TASK_TMP"
  fi
}
trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-browser-isolation-tests.XXXXXX")
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
mkdir -p "$TMP_ROOT/tmp" "$TMP_ROOT/home" "$TMP_ROOT/state" "$TMP_ROOT/fakes"

FAKE_BROWSER="$TMP_ROOT/fakes/Google Chrome for Testing"
FAKE_AXI="$TMP_ROOT/fakes/real-chrome-devtools-axi"
FAKE_BRIDGE="$TMP_ROOT/fakes/chrome-devtools-axi-bridge.js"
FAKE_HEADED="$TMP_ROOT/fakes/captain-browser-helper.js"
AXI_RECORD="$TMP_ROOT/axi-record"
export FM_FAKE_AXI_RECORD="$AXI_RECORD"
export FM_FAKE_BRIDGE_SCRIPT="$FAKE_BRIDGE"

cat > "$FAKE_BROWSER" <<'JS'
#!/usr/bin/env node
const fs = require("fs");
const http = require("http");
const path = require("path");
const { spawn } = require("child_process");

const profileArg = process.argv.find((arg) => arg.startsWith("--user-data-dir="));
const requiredArgs = ["--use-mock-keychain", "--password-store=basic"];
if (
  !profileArg ||
  !process.argv.some((arg) => arg.startsWith("--headless")) ||
  requiredArgs.some((arg) => !process.argv.includes(arg))
) process.exit(2);
const profile = profileArg.slice("--user-data-dir=".length);
fs.mkdirSync(profile, { recursive: true });
const helper = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], {
  stdio: "ignore",
});
fs.writeFileSync(path.join(profile, "helper.pid"), `${helper.pid}\n`);
const server = http.createServer((request, response) => {
  response.setHeader("content-type", "application/json");
  response.end(JSON.stringify({
    Browser: "Fake Chrome for Testing",
    webSocketDebuggerUrl: `ws://127.0.0.1:${server.address().port}/devtools/browser/fake`,
  }));
});
server.listen(0, "127.0.0.1", () => {
  fs.writeFileSync(path.join(profile, "DevToolsActivePort"), `${server.address().port}\n/devtools/browser/fake\n`);
});
process.on("SIGTERM", () => server.close(() => process.exit(0)));
setInterval(() => {}, 1000);
JS

cat > "$FAKE_BRIDGE" <<'JS'
#!/usr/bin/env node
setInterval(() => {}, 1000);
JS

cp "$FAKE_BRIDGE" "$FAKE_HEADED"

cat > "$FAKE_AXI" <<'JS'
#!/usr/bin/env node
const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");

const command = process.argv[2] || "";
if (command === "stop") process.exit(0);
fs.appendFileSync(
  process.env.FM_FAKE_AXI_RECORD,
  [
    `home=${process.env.HOME}`,
    `session=${process.env.CHROME_DEVTOOLS_AXI_SESSION}`,
    `port=${process.env.CHROME_DEVTOOLS_AXI_PORT}`,
    `browser_url=${process.env.CHROME_DEVTOOLS_AXI_BROWSER_URL}`,
    `auto_connect=${process.env.CHROME_DEVTOOLS_AXI_AUTO_CONNECT || ""}`,
    `user_data_dir=${process.env.CHROME_DEVTOOLS_AXI_USER_DATA_DIR || ""}`,
    `channel=${process.env.CHROME_DEVTOOLS_AXI_CHANNEL || ""}`,
    `chrome_args=${process.env.CHROME_DEVTOOLS_AXI_CHROME_ARGS || ""}`,
  ].join("\n") + "\n",
);
if (command === "open") {
  const bridge = spawn(process.execPath, [process.env.FM_FAKE_BRIDGE_SCRIPT], {
    detached: true,
    stdio: "ignore",
  });
  bridge.unref();
  const pidFile = path.join(
    process.env.HOME,
    ".chrome-devtools-axi",
    "sessions",
    process.env.CHROME_DEVTOOLS_AXI_SESSION,
    "bridge.pid",
  );
  fs.mkdirSync(path.dirname(pidFile), { recursive: true });
  fs.writeFileSync(pidFile, `${JSON.stringify({ pid: bridge.pid, port: Number(process.env.CHROME_DEVTOOLS_AXI_PORT) })}\n`);
}
JS

chmod +x "$FAKE_BROWSER" "$FAKE_AXI" "$FAKE_BRIDGE" "$FAKE_HEADED"

browser_root() {
  FM_BROWSER_TMP_ROOT="$TMP_ROOT/tmp" "$BROWSER" root "$1" "$2"
}

test_process_discrimination() {
  local fixture="$TMP_ROOT/processes.txt" out
  cat > "$fixture" <<'ROWS'
101 1 101 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
102 101 101 /Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper --type=renderer
103 1 103 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless=new --user-data-dir=/Users/captain/Library/Application Support/Google/Chrome
104 1 104 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --user-data-dir=/tmp/puppeteer_dev_chrome_profile-headed
105 1 105 codex task text says chrome-devtools-axi-bridge process cleanup
106 1 106 node /opt/axi/chrome-devtools-axi-bridge.js
107 106 106 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless=new --user-data-dir=/tmp/puppeteer_dev_chrome_profile-leaked
108 1 108 /cache/Google Chrome for Testing --headless=new --user-data-dir=/tmp/fm-browser-0123456789abcdef-task-z1/profile
109 1 109 python worker.py --headless=new --user-data-dir=/tmp/puppeteer_dev_chrome_profile-not-a-browser
ROWS
  out=$("$BROWSER" classify "$fixture")
  [ "$(printf '%s\n' "$out" | awk -F '\t' '$2 == "unrelated" { count += 1 } END { print count + 0 }')" -eq 6 ] \
    || fail "captain-like and partial-marker processes were not all preserved"
  [ "$(printf '%s\n' "$out" | awk -F '\t' '$2 == "legacy-bridge" { print $1 }')" = 106 ] \
    || fail "exact AXI bridge was not classified"
  [ "$(printf '%s\n' "$out" | awk -F '\t' '$2 == "legacy-browser" { print $1 }')" = 107 ] \
    || fail "headless temp-profile Chrome was not classified"
  [ "$(printf '%s\n' "$out" | awk -F '\t' '$2 == "protected-task-browser" { print $1 }')" = 108 ] \
    || fail "new task-owned browser was not protected from the legacy sweep"
  pass "classifier requires exact automation markers and preserves captain-like Chrome"
}

test_task_launch_and_reap() {
  local id=browser-owned-z2 tasktmp="$TMP_ROOT/tmp/fm-browser-owned-z2"
  local browser_pid bridge_pid helper_pid root
  mkdir -p "$tasktmp/gotmp"
  FM_BROWSER_TMP_ROOT="$TMP_ROOT/tmp" \
    "$BROWSER" prepare "$id" "$tasktmp" "$TMP_ROOT/home" "$FAKE_AXI" "$FAKE_BROWSER" ""
  root=$(browser_root "$id" "$TMP_ROOT/home")
  FM_BROWSER_TMP_ROOT="$TMP_ROOT/tmp" \
    FM_BROWSER_TASK_ID="$id" \
    FM_BROWSER_ROOT="$root" FM_BROWSER_OWNER_HOME="$TMP_ROOT/home" \
    "$WRAPPER" open https://example.test/

  grep -F "home=$root/home" "$AXI_RECORD" >/dev/null \
    || fail "AXI HOME was not isolated under the task browser root"
  grep -F "session=fm-$id" "$AXI_RECORD" >/dev/null \
    || fail "AXI session was not keyed to the task"
  grep -E '^browser_url=http://127\.0\.0\.1:[0-9]+$' "$AXI_RECORD" >/dev/null \
    || fail "AXI did not attach to the separate automation browser"
  grep -Fx 'auto_connect=' "$AXI_RECORD" >/dev/null \
    || fail "AUTO_CONNECT leaked into task AXI"
  grep -Fx 'user_data_dir=' "$AXI_RECORD" >/dev/null \
    || fail "AXI direct profile launch leaked around the wrapper"
  grep -Fx 'channel=' "$AXI_RECORD" >/dev/null \
    || fail "stable Chrome channel leaked into task AXI"
  grep -Fx 'chrome_args=--use-mock-keychain --password-store=basic' "$AXI_RECORD" >/dev/null \
    || fail "AXI fallback launch did not inherit credential-store isolation"

  browser_pid=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).pid)' "$root/browser.json")
  helper_pid=$(cat "$root/profile/helper.pid")
  bridge_pid=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).pid)' "$root/home/.chrome-devtools-axi/sessions/fm-$id/bridge.pid")
  TEARDOWN_BROWSER_PID=$browser_pid
  TEARDOWN_BRIDGE_PID=$bridge_pid
  kill -0 "$browser_pid" 2>/dev/null || fail "fake automation browser did not remain live"
  kill -0 "$bridge_pid" 2>/dev/null || fail "fake AXI bridge did not remain live"
  sleep 300 &
  UNRELATED_PID=$!

  FM_BROWSER_TMP_ROOT="$TMP_ROOT/tmp" "$BROWSER" reap "$id" "$tasktmp" "$TMP_ROOT/home"
  kill -0 "$browser_pid" 2>/dev/null && fail "task browser survived reap"
  kill -0 "$helper_pid" 2>/dev/null && fail "unmarked browser helper survived reap"
  kill -0 "$bridge_pid" 2>/dev/null && fail "task bridge survived reap"
  kill -0 "$UNRELATED_PID" 2>/dev/null || fail "unrelated process was killed by task reap"
  [ ! -e "$root" ] || fail "task browser profile root survived reap"
  TEARDOWN_BROWSER_PID=
  TEARDOWN_BRIDGE_PID=
  pass "task reap removes the exact bridge, browser, and profile without collateral"
}

test_failed_browser_cannot_respawn() {
  local id=browser-failure-z4 tasktmp="$TMP_ROOT/tmp/fm-browser-failure-z4"
  local browser_pid second_output root
  mkdir -p "$tasktmp/gotmp"
  FM_BROWSER_TMP_ROOT="$TMP_ROOT/tmp" \
    "$BROWSER" prepare "$id" "$tasktmp" "$TMP_ROOT/home" "$FAKE_AXI" "$FAKE_BROWSER" ""
  root=$(browser_root "$id" "$TMP_ROOT/home")
  FM_BROWSER_TMP_ROOT="$TMP_ROOT/tmp" \
    FM_BROWSER_TASK_ID="$id" \
    FM_BROWSER_ROOT="$root" FM_BROWSER_OWNER_HOME="$TMP_ROOT/home" \
    "$WRAPPER" open https://example.test/
  browser_pid=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).pid)' "$root/browser.json")
  kill "$browser_pid"
  wait "$browser_pid" 2>/dev/null || true
  if second_output=$(
    FM_BROWSER_TMP_ROOT="$TMP_ROOT/tmp" \
      FM_BROWSER_TASK_ID="$id" \
      FM_BROWSER_ROOT="$root" FM_BROWSER_OWNER_HOME="$TMP_ROOT/home" \
      "$WRAPPER" screenshot 2>&1
  ); then
    fail "wrapper respawned a browser after its owned browser died"
  fi
  printf '%s\n' "$second_output" | grep -F 'refusing to respawn it implicitly' >/dev/null \
    || fail "unexpected browser death did not trip the respawn latch"
  [ -f "$root/browser.failed" ] \
    || fail "browser failure latch was not recorded"
  [ ! -f "$root/browser.json" ] \
    || fail "stale browser state survived failed-browser cleanup"
  FM_BROWSER_TMP_ROOT="$TMP_ROOT/tmp" "$BROWSER" reap "$id" "$tasktmp" "$TMP_ROOT/home"
  pass "unexpected browser death is cleaned and cannot trigger an implicit respawn"
}

test_real_teardown_path_reaps_owned_browser() {
  local id="browser-td-z5-$$" tasktmp="/tmp/fm-browser-td-z5-$$"
  local home="$TMP_ROOT/teardown-home" pool="$TMP_ROOT/teardown-pool"
  local project="$TMP_ROOT/teardown-project" origin="$TMP_ROOT/teardown-origin.git"
  local worktree="$pool/1/worktree" seed="$TMP_ROOT/teardown-seed"
  local fakebin="$TMP_ROOT/teardown-fakebin"
  local browser_pid bridge_pid output root
  TEARDOWN_TASK_TMP=$tasktmp
  mkdir -p "$tasktmp/gotmp" "$home/state" "$home/data" "$home/config" "$pool/1" "$fakebin"
  git init -q --bare "$origin"
  git -C "$origin" symbolic-ref HEAD refs/heads/main
  git clone -q "$origin" "$seed" 2>/dev/null
  git -C "$seed" -c user.name=BrowserIsolationTest \
    -c user.email=browser-isolation@example.invalid \
    commit -q --allow-empty -m init
  git -C "$seed" push -q origin main
  git clone -q "$origin" "$project"
  git -C "$project" worktree add -q -b "fm/$id" "$worktree" main
  node - "$pool/treehouse-state.json" "$worktree" "firstmate-$id" <<'JS'
const fs = require("fs");
const [state, worktree, holder] = process.argv.slice(2);
fs.writeFileSync(state, JSON.stringify({
  worktrees: [{ name: "1", path: worktree, leased: true, lease_holder: holder }],
}));
JS
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
state="$(dirname "$0")/.tmux-live"
case "${1:-}" in
  display-message)
    [ -f "$state" ] || exit 1
    case " $* " in
      *' #{pane_current_command} '*) printf '%s\n' bash ;;
    esac
    exit 0
    ;;
  list-windows)
    [ ! -f "$state" ] || printf 'fm-%s\n' "$FM_FAKE_TASK_ID"
    exit 0
    ;;
  kill-window) rm -f "$state"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux"
  : > "$fakebin/.tmux-live"
  cat > "$home/state/$id.meta" <<META
window=firstmate:fm-$id
tmux_session_target=firstmate:fm-$id
worktree=$worktree
project=$project
harness=claude
kind=ship
mode=local-only
yolo=off
tasktmp=$tasktmp
META
  "$BROWSER" prepare "$id" "$tasktmp" "$home" "$FAKE_AXI" "$FAKE_BROWSER" ""
  root=$("$BROWSER" root "$id" "$home")
  FM_BROWSER_TASK_ID="$id" FM_BROWSER_ROOT="$root" FM_BROWSER_OWNER_HOME="$home" \
    "$WRAPPER" open https://example.test/
  browser_pid=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).pid)' "$root/browser.json")
  bridge_pid=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).pid)' "$root/home/.chrome-devtools-axi/sessions/fm-$id/bridge.pid")
  TEARDOWN_BROWSER_PID=$browser_pid
  TEARDOWN_BRIDGE_PID=$bridge_pid

  output=$(
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_CONFIG_OVERRIDE="$home/config" FM_CHECKOUT_REFRESH_LOCK_ROOT="$TMP_ROOT/checkout-locks" \
      FM_FAKE_TASK_ID="$id" PATH="$fakebin:$PATH" \
      env -u NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS=1 "$TEARDOWN" "$id" 2>&1
  ) || fail "fm-teardown rejected an otherwise-finished browser-owning task: $output"
  kill -0 "$browser_pid" 2>/dev/null && fail "browser survived the real fm-teardown path"
  kill -0 "$bridge_pid" 2>/dev/null && fail "bridge survived the real fm-teardown path"
  [ ! -e "$tasktmp" ] || fail "task temp root survived the real fm-teardown path"
  [ ! -e "$home/state/$id.meta" ] || fail "task metadata survived successful teardown"
  TEARDOWN_TASK_TMP=
  TEARDOWN_BROWSER_PID=
  TEARDOWN_BRIDGE_PID=
  pass "real fm-teardown path reaps the bridge, browser process tree, and task profile"
}

test_same_id_isolated_across_homes() {
  local id=shared-browser-z6 tasktmp="$TMP_ROOT/tmp/fm-shared-browser-z6"
  local home_a="$TMP_ROOT/home-a" home_b="$TMP_ROOT/home-b"
  local root_a root_b browser_a browser_b bridge_a bridge_b
  mkdir -p "$tasktmp/gotmp" "$home_a" "$home_b"
  FM_BROWSER_TMP_ROOT="$TMP_ROOT/tmp" \
    "$BROWSER" prepare "$id" "$tasktmp" "$home_a" "$FAKE_AXI" "$FAKE_BROWSER" ""
  FM_BROWSER_TMP_ROOT="$TMP_ROOT/tmp" \
    "$BROWSER" prepare "$id" "$tasktmp" "$home_b" "$FAKE_AXI" "$FAKE_BROWSER" ""
  root_a=$(browser_root "$id" "$home_a")
  root_b=$(browser_root "$id" "$home_b")
  [ "$root_a" != "$root_b" ] || fail "sibling homes received the same browser root"
  FM_BROWSER_TMP_ROOT="$TMP_ROOT/tmp" FM_BROWSER_TASK_ID="$id" \
    FM_BROWSER_ROOT="$root_a" FM_BROWSER_OWNER_HOME="$home_a" \
    "$WRAPPER" open https://home-a.example.test/
  FM_BROWSER_TMP_ROOT="$TMP_ROOT/tmp" FM_BROWSER_TASK_ID="$id" \
    FM_BROWSER_ROOT="$root_b" FM_BROWSER_OWNER_HOME="$home_b" \
    "$WRAPPER" open https://home-b.example.test/
  browser_a=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).pid)' "$root_a/browser.json")
  browser_b=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).pid)' "$root_b/browser.json")
  bridge_a=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).pid)' "$root_a/home/.chrome-devtools-axi/sessions/fm-$id/bridge.pid")
  bridge_b=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).pid)' "$root_b/home/.chrome-devtools-axi/sessions/fm-$id/bridge.pid")
  FM_BROWSER_TMP_ROOT="$TMP_ROOT/tmp" "$BROWSER" reap "$id" "$tasktmp" "$home_a"
  kill -0 "$browser_a" 2>/dev/null && fail "reaped home browser survived"
  kill -0 "$bridge_a" 2>/dev/null && fail "reaped home bridge survived"
  kill -0 "$browser_b" 2>/dev/null || fail "sibling home browser was killed"
  kill -0 "$bridge_b" 2>/dev/null || fail "sibling home bridge was killed"
  [ -d "$root_b/profile" ] || fail "sibling home profile was removed"
  FM_BROWSER_TMP_ROOT="$TMP_ROOT/tmp" "$BROWSER" reap "$id" "$tasktmp" "$home_b"
  pass "same task id remains browser-isolated across sibling homes"
}

test_orphan_sweep() {
  local id=browser-orphan-z3 tasktmp="$TMP_ROOT/tmp/fm-browser-orphan-z3"
  local legacy_profile="$TMP_ROOT/tmp/puppeteer_dev_chrome_profile-stale"
  local headed_profile="$TMP_ROOT/tmp/puppeteer_dev_chrome_profile-headed" out root
  mkdir -p "$tasktmp/gotmp" "$legacy_profile" "$headed_profile"
  FM_BROWSER_TMP_ROOT="$TMP_ROOT/tmp" \
    "$BROWSER" prepare "$id" "$tasktmp" "$TMP_ROOT/home" "$FAKE_AXI" "$FAKE_BROWSER" ""
  root=$(browser_root "$id" "$TMP_ROOT/home")

  node "$FAKE_BRIDGE" &
  LEGACY_BRIDGE_PID=$!
  "$FAKE_BROWSER" \
    --headless=new \
    --use-mock-keychain \
    --password-store=basic \
    "--user-data-dir=$legacy_profile" &
  LEGACY_BROWSER_PID=$!
  node "$FAKE_HEADED" "--user-data-dir=$headed_profile" &
  HEADED_BROWSER_PID=$!
  sleep 0.2
  kill -0 "$LEGACY_BRIDGE_PID" 2>/dev/null || fail "fake legacy bridge did not start"
  kill -0 "$LEGACY_BROWSER_PID" 2>/dev/null || fail "fake legacy browser did not start"
  kill -0 "$HEADED_BROWSER_PID" 2>/dev/null || fail "fake headed browser did not start"
  sleep 300 &
  UNRELATED_PID=$!

  out=$(FM_BROWSER_TMP_ROOT="$TMP_ROOT/tmp" "$BROWSER" sweep "$TMP_ROOT/home" "$TMP_ROOT/state")
  kill -0 "$LEGACY_BRIDGE_PID" 2>/dev/null && fail "legacy AXI bridge survived orphan sweep"
  kill -0 "$LEGACY_BROWSER_PID" 2>/dev/null && fail "legacy headless temp-profile browser survived orphan sweep"
  wait "$LEGACY_BRIDGE_PID" 2>/dev/null || true
  wait "$LEGACY_BROWSER_PID" 2>/dev/null || true
  kill -0 "$UNRELATED_PID" 2>/dev/null || fail "unrelated process was killed by orphan sweep"
  kill -0 "$HEADED_BROWSER_PID" 2>/dev/null || fail "headed temp-profile browser was killed by orphan sweep"
  [ ! -e "$root" ] || fail "metadata-free task browser root survived sweep"
  [ ! -e "$legacy_profile" ] || fail "unused legacy temp profile survived sweep"
  [ -d "$headed_profile" ] || fail "active headed temp profile was removed by orphan sweep"
  printf '%s\n' "$out" | grep -E '^BROWSER_GC: reaped task_roots=1 bridges=1 browser_processes=2 profiles=1$' >/dev/null \
    || fail "sweep did not report measured cleanup: $out"
  pass "backstop kills only exact orphan markers and preserves unrelated processes"
}

test_spawn_and_teardown_wiring() {
  grep -F "\"\$SCRIPT_DIR/fm-browser-isolation.sh\" prepare" "$SPAWN" >/dev/null \
    || fail "spawn does not prepare browser isolation"
  grep -F "CREW_PATH=\"\$SCRIPT_DIR:\$(crew_tool_path)\"" "$SPAWN" >/dev/null \
    || fail "spawn does not put the task AXI wrapper first on PATH"
  grep -F "HERDR_AGENT_ENV+=(\"FM_BROWSER_TASK_ID=\$ID\")" "$SPAWN" >/dev/null \
    || fail "Herdr does not receive the task browser identity natively"
  grep -F "HERDR_AGENT_ENV+=(\"FM_BROWSER_OWNER_HOME=\$FM_HOME\")" "$SPAWN" >/dev/null \
    || fail "Herdr does not receive the home-qualified browser owner"
  grep -F "FM_BROWSER_ROOT=\$(shell_quote \"\$BROWSER_ROOT\")" "$SPAWN" >/dev/null \
    || fail "terminal backends do not export the task browser root"
  grep -F "reap_task_browser \"\$ID\" \"\$TASK_TMP\"" "$TEARDOWN" >/dev/null \
    || fail "teardown does not reap the task browser before temp-root deletion"
  grep -F 'cleanup_prepared_task_tmp' "$SPAWN" >/dev/null \
    || fail "spawn abort does not route prepared temp cleanup through browser reap"
  grep -F 'browser_gc_sweep' "$BOOTSTRAP" >/dev/null \
    || fail "bootstrap does not expose the crash-orphan backstop"
  grep -F "\"\$SCRIPT_DIR/fm-browser-isolation.sh\" sweep \"\$FM_HOME\" \"\$STATE\"" "$BOOTSTRAP" >/dev/null \
    || fail "bootstrap backstop does not invoke browser orphan cleanup"
  pass "spawn and teardown wire the browser lifecycle on every backend channel"
}

test_process_discrimination
test_task_launch_and_reap
test_failed_browser_cannot_respawn
test_real_teardown_path_reaps_owned_browser
test_same_id_isolated_across_homes
test_orphan_sweep
test_spawn_and_teardown_wiring
