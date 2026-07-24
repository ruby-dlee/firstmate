#!/usr/bin/env bash
# Firstmate-owned chrome-devtools-axi isolation and lifecycle control.
#
# Usage:
#   fm-browser.sh check
#   fm-browser.sh prepare <task-id> <generation-id> <task-tmp> <task-meta>
#   fm-browser.sh run <task-id> <chrome-devtools-axi args...>
#   fm-browser.sh reap <task-id> <task-meta>
#   fm-browser.sh sweep
#
# `prepare` creates a task-local PATH wrapper at
# /tmp/fm-<task-id>/browser-bin/chrome-devtools-axi and a generation-bound
# owner marker beside chrome-devtools-axi's named-session state.
# The wrapper is the browser boundary:
#   - it always selects the separate Google Chrome Canary application;
#   - it always selects the task's unique `fm-<task-id>` bridge session;
#   - it strips auto-connect, browser-URL, profile, port, headed, and extra
#     Chrome-argument overrides that could reconnect to the captain's Chrome;
#   - it refuses action commands before invoking chrome-devtools-axi when the
#     dedicated Canary executable is absent.
# Help/version and `stop` remain available without Canary.
#
# `reap` first proves that the owner marker, task metadata, generation, bridge
# PID, process start time, UID, process-group identity, and bridge command all
# agree.
# It then terminates the bridge's detached process group, which includes the
# chrome-devtools-mcp transport and its headless browser children.
# A failed proof is a refusal, never a best-guess kill.
#
# `sweep` scans only named sessions carrying Firstmate's owner-marker format.
# A marker whose exact task metadata and generation still exist is live and is
# never touched.
# A marker with no matching live generation is orphaned and is reaped through
# the same process-identity proof as explicit teardown.
# Unmarked/default/user sessions are outside Firstmate's ownership and skipped.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORMAT=firstmate-browser-owner-v1
CHANNEL=canary
SESSION_PREFIX=fm-
TEST_LAB_TOKEN=firstmate-browser-test-lab-v1

if [ "${FM_BROWSER_TEST_LAB:-}" = "$TEST_LAB_TOKEN" ]; then
  BROWSER_STATE_ROOT=${FM_BROWSER_STATE_ROOT:-}
  CANARY_EXECUTABLE=${FM_BROWSER_CANARY_EXECUTABLE:-}
else
  BROWSER_STATE_ROOT="$HOME/.chrome-devtools-axi"
  case "$(uname -s 2>/dev/null || true)" in
    Darwin) CANARY_EXECUTABLE="/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary" ;;
    Linux) CANARY_EXECUTABLE=$(command -v google-chrome-canary 2>/dev/null || true) ;;
    *) CANARY_EXECUTABLE= ;;
  esac
fi

valid_task_id() {
  printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,60}$'
}

safe_regular_file() {
  [ -f "$1" ] && [ ! -L "$1" ]
}

single_value() { # <file> <key>
  local file=$1 key=$2 values count
  safe_regular_file "$file" || return 1
  values=$(sed -n "s/^${key}=//p" "$file") || return 1
  count=$(printf '%s\n' "$values" | awk 'NF { count++ } END { print count + 0 }')
  [ "$count" -eq 1 ] || return 1
  printf '%s\n' "$values" | awk 'NF { print; exit }'
}

session_for_task() {
  valid_task_id "$1" || return 1
  printf '%s%s\n' "$SESSION_PREFIX" "$1"
}

session_dir_for_task() {
  local session
  session=$(session_for_task "$1") || return 1
  [ -n "$BROWSER_STATE_ROOT" ] || return 1
  printf '%s/sessions/%s\n' "${BROWSER_STATE_ROOT%/}" "$session"
}

canary_available() {
  [ -n "$CANARY_EXECUTABLE" ] && [ -x "$CANARY_EXECUTABLE" ]
}

canary_missing_message() {
  local expected=${CANARY_EXECUTABLE:-Google Chrome Canary}
  echo "error: Firstmate browser automation is disabled because its dedicated Google Chrome Canary executable is unavailable: $expected" >&2
  echo "error: stable Google Chrome is intentionally blocked so automation cannot hijack or pollute the captain's browser; install Canary, then start a new crew session" >&2
}

resolve_axi() {
  local path_part candidate
  while IFS= read -r path_part; do
    [ -n "$path_part" ] || path_part=.
    candidate="${path_part%/}/chrome-devtools-axi"
    [ -x "$candidate" ] && [ ! -d "$candidate" ] || continue
    case "$candidate" in
      /tmp/fm-*/browser-bin/chrome-devtools-axi) continue ;;
    esac
    (
      cd "$(dirname "$candidate")" 2>/dev/null || exit 1
      printf '%s/%s\n' "$(pwd -P)" "$(basename "$candidate")"
    )
    return $?
  done <<EOF
$(printf '%s' "$PATH" | tr ':' '\n')
EOF
  return 1
}

owner_marker_valid() { # <owner-file> [expected-task]
  local owner=$1 expected_task=${2:-} format task session generation meta axi
  safe_regular_file "$owner" || return 1
  format=$(single_value "$owner" format) || return 1
  task=$(single_value "$owner" task) || return 1
  session=$(single_value "$owner" session) || return 1
  generation=$(single_value "$owner" generation_id) || return 1
  meta=$(single_value "$owner" meta) || return 1
  axi=$(single_value "$owner" axi) || return 1
  [ "$format" = "$FORMAT" ] || return 1
  valid_task_id "$task" || return 1
  [ -z "$expected_task" ] || [ "$task" = "$expected_task" ] || return 1
  [ "$session" = "$SESSION_PREFIX$task" ] || return 1
  [ -n "$generation" ] && [ -n "$meta" ] && [ -n "$axi" ]
}

owner_is_live() { # <owner-file>
  local owner=$1 task session generation meta
  owner_marker_valid "$owner" || return 1
  task=$(single_value "$owner" task) || return 1
  session=$(single_value "$owner" session) || return 1
  generation=$(single_value "$owner" generation_id) || return 1
  meta=$(single_value "$owner" meta) || return 1
  safe_regular_file "$meta" || return 1
  [ "$(single_value "$meta" browser_session 2>/dev/null || true)" = "$session" ] || return 1
  [ "$(single_value "$meta" browser_channel 2>/dev/null || true)" = "$CHANNEL" ] || return 1
  [ "$(single_value "$meta" generation_id 2>/dev/null || true)" = "$generation" ] || return 1
  [ "$(basename "$meta")" = "$task.meta" ]
}

bridge_pid_and_port() { # <session-dir>
  local pid_file=$1/bridge.pid line parsed
  safe_regular_file "$pid_file" || return 1
  line=$(cat "$pid_file") || return 1
  case "$line" in *$'\n'*) return 1 ;; esac
  parsed=$(printf '%s\n' "$line" | sed -nE 's/^\{"pid":([0-9]+),"port":([0-9]+)\}$/\1 \2/p')
  [ -n "$parsed" ] || return 1
  printf '%s\n' "$parsed"
}

process_value() { # <pid> <ps-field>
  local value
  value=$(LC_ALL=C ps -p "$1" -o "$2=" 2>/dev/null) || return 1
  value=$(printf '%s\n' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

bridge_process_signature() { # <pid>
  local command
  command=$(process_value "$1" command) || return 1
  printf '%s\n' "$command" | grep -Eq '^(node|.*/node) [^ ]*/chrome-devtools-axi-bridge\.(js|ts)$'
}

record_bridge_identity() { # <session-dir>
  local session_dir=$1 pair pid port start pgid uid tmp identity
  pair=$(bridge_pid_and_port "$session_dir") || return 0
  read -r pid port <<EOF
$pair
EOF
  bridge_process_signature "$pid" || return 0
  start=$(process_value "$pid" lstart) || return 0
  pgid=$(process_value "$pid" pgid) || return 0
  uid=$(process_value "$pid" uid) || return 0
  [ "$pgid" = "$pid" ] || return 0
  [ "$uid" = "$(id -u)" ] || return 0
  identity="$session_dir/firstmate-bridge"
  tmp=$(mktemp "$session_dir/.firstmate-bridge.XXXXXX") || return 1
  {
    echo "pid=$pid"
    echo "port=$port"
    echo "start=$start"
    echo "pgid=$pgid"
    echo "uid=$uid"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$identity"
}

bridge_identity_matches() { # <session-dir> <pid> <port>
  local session_dir=$1 pid=$2 port=$3 identity recorded_pid recorded_port recorded_start recorded_pgid recorded_uid
  local start pgid uid
  identity="$session_dir/firstmate-bridge"
  safe_regular_file "$identity" || return 1
  recorded_pid=$(single_value "$identity" pid) || return 1
  recorded_port=$(single_value "$identity" port) || return 1
  recorded_start=$(single_value "$identity" start) || return 1
  recorded_pgid=$(single_value "$identity" pgid) || return 1
  recorded_uid=$(single_value "$identity" uid) || return 1
  [ "$recorded_pid" = "$pid" ] && [ "$recorded_port" = "$port" ] || return 1
  start=$(process_value "$pid" lstart) || return 1
  pgid=$(process_value "$pid" pgid) || return 1
  uid=$(process_value "$pid" uid) || return 1
  [ "$recorded_start" = "$start" ] || return 1
  [ "$recorded_pgid" = "$pid" ] && [ "$pgid" = "$pid" ] || return 1
  [ "$recorded_uid" = "$(id -u)" ] && [ "$uid" = "$recorded_uid" ]
}

process_group_alive() { # <pgid>
  kill -0 "-$1" 2>/dev/null
}

terminate_owned_session() { # <session-dir> <expected-task>
  local session_dir=$1 task=$2 owner pair pid port
  owner="$session_dir/firstmate-owner"
  owner_marker_valid "$owner" "$task" || {
    echo "error: refusing browser reap for $task: missing or invalid Firstmate owner marker at $owner" >&2
    return 1
  }
  if ! pair=$(bridge_pid_and_port "$session_dir"); then
    [ ! -e "$session_dir/bridge.pid" ] || {
      echo "error: refusing browser reap for $task: invalid bridge PID file" >&2
      return 1
    }
    rm -rf -- "$session_dir"
    return 0
  fi
  read -r pid port <<EOF
$pair
EOF
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -rf -- "$session_dir"
    return 0
  fi
  bridge_process_signature "$pid" || {
    echo "error: refusing browser reap for $task: PID $pid is not an exact chrome-devtools-axi bridge command" >&2
    return 1
  }
  bridge_identity_matches "$session_dir" "$pid" "$port" || {
    echo "error: refusing browser reap for $task: PID $pid does not match its recorded start/UID/process-group identity" >&2
    return 1
  }
  kill -TERM "-$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    process_group_alive "$pid" || break
    sleep 0.1
  done
  if process_group_alive "$pid"; then
    kill -KILL "-$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      process_group_alive "$pid" || break
      sleep 0.1
    done
  fi
  if process_group_alive "$pid"; then
    echo "error: browser process group $pid for $task survived TERM/KILL; retaining ownership state" >&2
    return 1
  fi
  rm -rf -- "$session_dir"
}

prepare() {
  local task=$1 generation=$2 task_tmp=$3 meta=$4 session session_dir owner axi owner_tmp wrapper_dir wrapper
  valid_task_id "$task" || { echo "error: invalid browser task id '$task'" >&2; return 1; }
  [ -n "$generation" ] || { echo "error: empty browser generation for $task" >&2; return 1; }
  if [ "${FM_BROWSER_TEST_LAB:-}" != "$TEST_LAB_TOKEN" ] && [ "$task_tmp" != "/tmp/fm-$task" ]; then
    echo "error: unsafe browser task temp path for $task: $task_tmp" >&2
    return 1
  fi
  safe_regular_file "$meta" || { echo "error: browser owner metadata is unavailable for $task: $meta" >&2; return 1; }
  [ "$(single_value "$meta" generation_id 2>/dev/null || true)" = "$generation" ] || {
    echo "error: browser owner generation does not match task metadata for $task" >&2
    return 1
  }
  session=$(session_for_task "$task") || return 1
  [ "$(single_value "$meta" browser_session 2>/dev/null || true)" = "$session" ] || {
    echo "error: browser session metadata does not match $session" >&2
    return 1
  }
  [ "$(single_value "$meta" browser_channel 2>/dev/null || true)" = "$CHANNEL" ] || {
    echo "error: browser channel metadata is not pinned to $CHANNEL" >&2
    return 1
  }
  axi=$(resolve_axi) || {
    echo "error: chrome-devtools-axi is unavailable outside Firstmate's task wrapper" >&2
    return 1
  }
  session_dir=$(session_dir_for_task "$task") || return 1
  owner="$session_dir/firstmate-owner"
  if [ -e "$session_dir" ] && [ ! -e "$owner" ] && [ ! -L "$owner" ]; then
    echo "error: browser session $session already exists without a Firstmate owner marker; refusing to claim it" >&2
    return 1
  fi
  if [ -e "$owner" ] || [ -L "$owner" ]; then
    if owner_is_live "$owner"; then
      [ "$(single_value "$owner" generation_id)" = "$generation" ] || {
        echo "error: browser session $session belongs to another live task generation" >&2
        return 1
      }
    else
      terminate_owned_session "$session_dir" "$task" || return 1
    fi
  fi
  mkdir -p "$session_dir" "$task_tmp/browser-bin" || return 1
  [ -d "$session_dir" ] && [ ! -L "$session_dir" ] || {
    echo "error: unsafe browser session directory for $task: $session_dir" >&2
    return 1
  }
  owner_tmp=$(mktemp "$session_dir/.firstmate-owner.XXXXXX") || return 1
  {
    echo "format=$FORMAT"
    echo "task=$task"
    echo "session=$session"
    echo "generation_id=$generation"
    echo "meta=$meta"
    echo "axi=$axi"
  } > "$owner_tmp" || { rm -f "$owner_tmp"; return 1; }
  mv "$owner_tmp" "$owner"
  wrapper_dir="$task_tmp/browser-bin"
  wrapper="$wrapper_dir/chrome-devtools-axi"
  {
    echo '#!/usr/bin/env bash'
    printf 'exec %q run %q "$@"\n' "$SCRIPT_DIR/fm-browser.sh" "$task"
  } > "$wrapper" || return 1
  chmod +x "$wrapper" || return 1
  printf '%s\n' "$wrapper_dir"
}

run_axi() {
  local task=$1
  shift
  local session_dir owner session axi first=${1:-} second=${2:-} rc
  session_dir=$(session_dir_for_task "$task") || return 1
  owner="$session_dir/firstmate-owner"
  owner_marker_valid "$owner" "$task" || {
    echo "error: Firstmate browser wrapper for $task has no valid owner marker; start a fresh crew session" >&2
    return 1
  }
  owner_is_live "$owner" || {
    echo "error: Firstmate browser wrapper for $task does not match a live task generation; refusing browser access" >&2
    return 1
  }
  session=$(single_value "$owner" session) || return 1
  axi=$(single_value "$owner" axi) || return 1
  [ -x "$axi" ] || { echo "error: recorded chrome-devtools-axi executable is unavailable: $axi" >&2; return 1; }
  case "$first:$second" in
    -h:*|--help:*|-v:*|-V:*|--version:*|*:--help|stop:*) ;;
    *)
      canary_available || { canary_missing_message; return 78; }
      ;;
  esac
  (
    unset CHROME_DEVTOOLS_AXI_AUTO_CONNECT CHROME_DEVTOOLS_AXI_BROWSER_URL
    unset CHROME_DEVTOOLS_AXI_WS_HEADERS CHROME_DEVTOOLS_AXI_USER_DATA_DIR
    unset CHROME_DEVTOOLS_AXI_PORT CHROME_DEVTOOLS_AXI_HEADED
    unset CHROME_DEVTOOLS_AXI_CHROME_ARGS
    export CHROME_DEVTOOLS_AXI_CHANNEL="$CHANNEL"
    export CHROME_DEVTOOLS_AXI_SESSION="$session"
    "$axi" "$@"
  )
  rc=$?
  record_bridge_identity "$session_dir" || {
    echo "error: failed to record browser bridge identity for $task" >&2
    return 1
  }
  return "$rc"
}

reap() {
  local task=$1 meta=$2 session_dir owner
  session_dir=$(session_dir_for_task "$task") || return 1
  [ -e "$session_dir" ] || return 0
  owner="$session_dir/firstmate-owner"
  owner_marker_valid "$owner" "$task" || {
    echo "error: refusing browser reap for $task: session is not provably Firstmate-owned" >&2
    return 1
  }
  [ "$(single_value "$owner" meta 2>/dev/null || true)" = "$meta" ] || {
    echo "error: refusing browser reap for $task: owner marker points at different metadata" >&2
    return 1
  }
  safe_regular_file "$meta" || {
    echo "error: refusing explicit browser reap for $task: task metadata is unavailable" >&2
    return 1
  }
  [ "$(single_value "$meta" generation_id 2>/dev/null || true)" = "$(single_value "$owner" generation_id)" ] || {
    echo "error: refusing browser reap for $task: task generation changed" >&2
    return 1
  }
  terminate_owned_session "$session_dir" "$task"
}

sweep() {
  local sessions_dir session_dir owner task
  [ -n "$BROWSER_STATE_ROOT" ] || return 0
  sessions_dir="${BROWSER_STATE_ROOT%/}/sessions"
  [ -d "$sessions_dir" ] || return 0
  for session_dir in "$sessions_dir"/"$SESSION_PREFIX"*; do
    [ -d "$session_dir" ] && [ ! -L "$session_dir" ] || continue
    owner="$session_dir/firstmate-owner"
    owner_marker_valid "$owner" || continue
    task=$(single_value "$owner" task) || continue
    [ "$(basename "$session_dir")" = "$SESSION_PREFIX$task" ] || continue
    owner_is_live "$owner" && continue
    if terminate_owned_session "$session_dir" "$task"; then
      echo "BROWSER_SWEEP: orphaned session $SESSION_PREFIX$task: reaped"
    else
      echo "BROWSER_SWEEP: orphaned session $SESSION_PREFIX$task: refused unsafe reap"
    fi
  done
}

usage() {
  sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  check)
    canary_available || { canary_missing_message; exit 1; }
    printf '%s\n' "$CANARY_EXECUTABLE"
    ;;
  prepare)
    [ "$#" -eq 5 ] || { usage >&2; exit 2; }
    prepare "$2" "$3" "$4" "$5"
    ;;
  run)
    [ "$#" -ge 3 ] || { usage >&2; exit 2; }
    task=$2
    shift 2
    run_axi "$task" "$@"
    ;;
  reap)
    [ "$#" -eq 3 ] || { usage >&2; exit 2; }
    reap "$2" "$3"
    ;;
  sweep)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    sweep
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
