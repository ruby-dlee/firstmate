#!/usr/bin/env bash
# Manual macOS integration proof for credential-store isolation, screenshot
# reuse, teardown, and optional stable-Chrome routing.
#
# This test launches only the separate automation browser selected by
# FM_BROWSER_AUTOMATION_EXECUTABLE. It never attaches to or stops stable Chrome.
# Set FM_BROWSER_ROUTING_TEST=1 to exercise the explicit `open -na` routing
# assertion, which creates one real stable-Chrome window for review.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BROWSER_LIFECYCLE="$ROOT/bin/fm-browser-isolation.sh"
WRAPPER="$ROOT/bin/chrome-devtools-axi"
TASK_ID="credential-smoke-$$"
TASK_TMP="/tmp/fm-$TASK_ID"
MONITOR_PID=
PROFILE=
BRIDGE_PID=

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

owned_process_count() {
  local marker=$1
  FM_BROWSER_OWNED_MARKER="$marker" node <<'JS'
const { execFileSync } = require("child_process");
const marker = process.env.FM_BROWSER_OWNED_MARKER;
const commands = execFileSync("ps", ["-axo", "command="], { encoding: "utf8" })
  .split(/\r?\n/);
console.log(commands.filter((command) => command.includes(marker)).length);
JS
}

stable_window_count() {
  # shellcheck disable=SC2016 # Swift source is intentionally a shell literal.
  swift -e '
    import CoreGraphics
    let rows = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID
    ) as? [[String: Any]] ?? []
    print(rows.filter {
      ($0[kCGWindowOwnerName as String] as? String) == "Google Chrome"
    }.count)
  '
}

cleanup() {
  local cleanup_rc=0 remaining=0
  touch "$TASK_TMP/monitor.stop" 2>/dev/null || true
  if [ -n "$MONITOR_PID" ]; then
    wait "$MONITOR_PID" 2>/dev/null || cleanup_rc=1
  fi
  if [ -f "$TASK_TMP/browser/owner.json" ]; then
    "$BROWSER_LIFECYCLE" reap "$TASK_ID" "$TASK_TMP" >/dev/null 2>&1 || cleanup_rc=1
  fi
  if [ -n "$PROFILE" ]; then
    remaining=$(owned_process_count "$PROFILE")
    [ "$remaining" -eq 0 ] || cleanup_rc=1
  fi
  rm -rf "$TASK_TMP"
  if [ "$cleanup_rc" -ne 0 ]; then
    printf 'not ok - integration cleanup could not prove zero owned processes\n' >&2
  fi
  return "$cleanup_rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

[ "$(uname)" = Darwin ] || fail "macOS smoke test requires Darwin"
REAL_AXI=$(command -v chrome-devtools-axi 2>/dev/null) \
  || fail "chrome-devtools-axi is unavailable"
MCP_PATH=${CHROME_DEVTOOLS_AXI_MCP_PATH:-}
if [ -z "$MCP_PATH" ]; then
  NPM_PREFIX=$(npm prefix -g 2>/dev/null || true)
  if [ -n "$NPM_PREFIX" ]; then
    MCP_PATH="$NPM_PREFIX/lib/node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js"
  fi
fi
if [ ! -f "$MCP_PATH" ]; then
  MCP_PATH=$(
    find "$HOME/.npm/_npx" \
      -type f -path '*/node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js' \
      2>/dev/null |
      sort |
      tail -n 1
  )
fi
[ -f "$MCP_PATH" ] || fail "chrome-devtools-mcp is unavailable"

AUTOMATION_BROWSER=${FM_BROWSER_AUTOMATION_EXECUTABLE:-}
if [ -z "$AUTOMATION_BROWSER" ]; then
  AUTOMATION_BROWSER=$(
    find "$HOME/.cache/puppeteer/chrome" "$HOME/Library/Caches/puppeteer/chrome" \
      -type f -path '*/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing' \
      -perm -111 2>/dev/null |
      sort |
      tail -n 1
  )
fi
[ -x "$AUTOMATION_BROWSER" ] || fail "separate Chrome for Testing is unavailable"

STABLE_PID=$(
  ps -axo pid=,command= |
    awk -v executable="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" '
      {
        pid = $1
        sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0)
        if ($0 == executable) {
          print pid
          exit
        }
      }
    '
)
[ -n "$STABLE_PID" ] || fail "captain stable Chrome process was not found"
STABLE_IDENTITY=$(ps -p "$STABLE_PID" -o pid=,lstart=,pgid=)

mkdir -p "$TASK_TMP/gotmp" "$TASK_TMP/shots"
"$BROWSER_LIFECYCLE" prepare \
  "$TASK_ID" "$TASK_TMP" "$ROOT" "$REAL_AXI" "$AUTOMATION_BROWSER" "$MCP_PATH"

# shellcheck disable=SC2016 # Swift source is intentionally a shell literal.
swift -e '
  import CoreGraphics
  import Foundation

  let taskRoot = CommandLine.arguments[1]
  let stopFile = taskRoot + "/monitor.stop"
  let readyFile = taskRoot + "/monitor.ready"
  let browserOwners: Set<String> = [
    "Chromium",
    "Google Chrome Canary",
    "Google Chrome for Testing"
  ]
  try? "ready\n".write(toFile: readyFile, atomically: true, encoding: .utf8)
  var samples = 0
  var maximumVisibleAutomationWindows = 0
  while samples < 10 || !FileManager.default.fileExists(atPath: stopFile) {
    let rows = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID
    ) as? [[String: Any]] ?? []
    let visible = rows.filter { row in
      let owner = row[kCGWindowOwnerName as String] as? String ?? ""
      let title = (row[kCGWindowName as String] as? String ?? "").lowercased()
      return browserOwners.contains(owner) || title.contains("keychain not found")
    }.count
    maximumVisibleAutomationWindows = max(maximumVisibleAutomationWindows, visible)
    samples += 1
    usleep(100_000)
  }
  print("dialog_monitor_samples=\(samples)")
  print("automation_visible_windows_seen=\(maximumVisibleAutomationWindows)")
  exit(maximumVisibleAutomationWindows == 0 ? 0 : 1)
' "$TASK_TMP" >"$TASK_TMP/monitor.out" 2>"$TASK_TMP/monitor.err" &
MONITOR_PID=$!

READY_ATTEMPTS=0
while [ ! -f "$TASK_TMP/monitor.ready" ]; do
  kill -0 "$MONITOR_PID" 2>/dev/null || fail "native-dialog monitor failed to start"
  READY_ATTEMPTS=$((READY_ATTEMPTS + 1))
  [ "$READY_ATTEMPTS" -lt 100 ] || fail "native-dialog monitor did not become ready"
  sleep 0.1
done

FM_BROWSER_TASK_ID="$TASK_ID" FM_BROWSER_ROOT="$TASK_TMP/browser" \
  "$WRAPPER" open https://example.com/

STATE_FILE="$TASK_TMP/browser/browser.json"
PROFILE=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).profile)' "$STATE_FILE")
BROWSER_PID=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).pid)' "$STATE_FILE")
BROWSER_PORT=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).port)' "$STATE_FILE")
BROWSER_COMMAND=$(ps -p "$BROWSER_PID" -o command=)
case "$BROWSER_COMMAND" in
  *--use-mock-keychain*) ;;
  *) fail "live automation browser lacks --use-mock-keychain" ;;
esac
case "$BROWSER_COMMAND" in
  *--password-store=basic*) ;;
  *) fail "live automation browser lacks --password-store=basic" ;;
esac

INDEX=1
while [ "$INDEX" -le 15 ]; do
  FM_BROWSER_TASK_ID="$TASK_ID" FM_BROWSER_ROOT="$TASK_TMP/browser" \
    "$WRAPPER" screenshot "$TASK_TMP/shots/shot-$INDEX.png" >/dev/null
  INDEX=$((INDEX + 1))
done
[ "$(find "$TASK_TMP/shots" -type f -name 'shot-*.png' | wc -l | tr -d ' ')" -eq 15 ] \
  || fail "browser-heavy flow did not produce 15 screenshots"

if [ "${FM_BROWSER_ROUTING_TEST:-0}" = 1 ]; then
  ROUTING_TOKEN="fm-routing-$TASK_ID"
  STABLE_WINDOWS_BEFORE=$(stable_window_count)
  open -na "Google Chrome" --args --new-window "https://example.com/?$ROUTING_TOKEN"
  sleep 3
  STABLE_WINDOWS_AFTER=$(stable_window_count)
  [ "$STABLE_WINDOWS_AFTER" -gt "$STABLE_WINDOWS_BEFORE" ] \
    || fail "stable Chrome did not gain the requested new window"
  if curl -fsS "http://127.0.0.1:$BROWSER_PORT/json/list" | grep -F "$ROUTING_TOKEN" >/dev/null; then
    fail "captain routing test URL landed in the automation browser"
  fi
  printf 'stable_windows_before=%s\n' "$STABLE_WINDOWS_BEFORE"
  printf 'stable_windows_after=%s\n' "$STABLE_WINDOWS_AFTER"
  printf 'routing_url_in_automation=0\n'
fi

OWNED_DURING_RUN=$(owned_process_count "$PROFILE")
BRIDGE_PID=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).pid)' \
  "$TASK_TMP/browser/home/.chrome-devtools-axi/sessions/fm-$TASK_ID/bridge.pid")
kill -0 "$BRIDGE_PID" 2>/dev/null || fail "AXI bridge was not live during the run"

touch "$TASK_TMP/monitor.stop"
wait "$MONITOR_PID" || fail "automation browser displayed a native dialog"
MONITOR_PID=
cat "$TASK_TMP/monitor.out"
grep -Fx 'automation_visible_windows_seen=0' "$TASK_TMP/monitor.out" >/dev/null \
  || fail "native-dialog monitor observed an automation window"
if grep -Ei 'keychain|password store' "$TASK_TMP/browser/browser.log" >/dev/null; then
  grep -Ei 'keychain|password store' "$TASK_TMP/browser/browser.log" >&2
  fail "automation browser logged a credential-store error"
fi

FM_BROWSER_TASK_ID="$TASK_ID" FM_BROWSER_ROOT="$TASK_TMP/browser" \
  "$WRAPPER" stop >/dev/null
OWNED_AFTER_STOP=$(owned_process_count "$PROFILE")
kill -0 "$BRIDGE_PID" 2>/dev/null && fail "AXI bridge survived wrapper stop"
[ "$OWNED_AFTER_STOP" -eq 0 ] || fail "automation browser survived wrapper stop"
"$BROWSER_LIFECYCLE" reap "$TASK_ID" "$TASK_TMP"
[ ! -e "$TASK_TMP/browser" ] || fail "task profile root survived reap"

STABLE_IDENTITY_AFTER=$(ps -p "$STABLE_PID" -o pid=,lstart=,pgid=)
[ "$STABLE_IDENTITY_AFTER" = "$STABLE_IDENTITY" ] \
  || fail "captain stable Chrome identity changed during the smoke test"

printf 'screenshots=15\n'
printf 'owned_processes_during_run=%s\n' "$OWNED_DURING_RUN"
printf 'owned_processes_after_stop=%s\n' "$OWNED_AFTER_STOP"
printf 'bridge_alive_after_stop=0\n'
printf 'profile_exists_after_reap=0\n'
printf 'stable_chrome_identity_preserved=1\n'
printf 'ok - macOS credential isolation and teardown smoke test passed\n'
