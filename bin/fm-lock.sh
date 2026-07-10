#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID and start time found by walking the
# shell's ancestry, which lives as long as the firstmate session - unlike the
# transient subshell PID of any one tool call, which is dead moments after it is
# written.
# Usage: fm-lock.sh           acquire; exit 1 if another live session holds it
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE"

# Known harness command names; extend when a new adapter is verified.
HARNESS_RE='claude|codex|opencode|grok|^pi$'

process_start_time() {
  local pid=$1 out
  out=$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null) || return 1
  out=$(printf '%s\n' "$out" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

process_command_text() {
  local pid=$1 comm args
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null || true)
  printf '%s %s\n' "$(basename "$comm")" "$args"
}

command_is_app_server() {
  printf '%s' "$1" | grep -qE '(^|[[:space:]/])app-server([[:space:]]|$)'
}

lock_pid() {
  sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p;q;}' "$1" 2>/dev/null
}

lock_start_time() {
  sed -n '2{s/^[[:space:]]*//;s/[[:space:]]*$//;p;q;}' "$1" 2>/dev/null
}

write_lock() {
  local pid=$1 start tmp
  start=$(process_start_time "$pid") || return 1
  tmp="$LOCK.tmp.$$"
  {
    printf '%s\n' "$pid"
    printf '%s\n' "$start"
  } > "$tmp" || return 1
  mv -f "$tmp" "$LOCK"
}

harness_pid() {
  local pid=$$ comm args command
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    command="$(basename "$comm") $args"
    if ! command_is_app_server "$command" && printf '%s' "$(basename "$comm")" | grep -qE "$HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*)
        if ! command_is_app_server "$command" && printf '%s' "$args" | grep -qE "$HARNESS_RE"; then
          echo "$pid"; return 0
        fi
        ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

holder_alive() {
  local lock=$1 pid recorded_start current_start command
  pid=$(lock_pid "$lock")
  recorded_start=$(lock_start_time "$lock")
  [ -n "$recorded_start" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  current_start=$(process_start_time "$pid") || return 1
  [ "$current_start" = "$recorded_start" ] || return 1
  command=$(process_command_text "$pid") || return 1
  command_is_app_server "$command" && return 1
  printf '%s' "$command" | grep -qE "$HARNESS_RE"
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(lock_pid "$LOCK")
  if holder_alive "$LOCK"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
  exit 0
fi

me=$(harness_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
if [ -f "$LOCK" ]; then
  old=$(lock_pid "$LOCK")
  if [ "$old" != "$me" ] && holder_alive "$LOCK"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
write_lock "$me" || { echo "error: cannot record harness process identity" >&2; exit 1; }
echo "lock acquired: harness pid $me"
