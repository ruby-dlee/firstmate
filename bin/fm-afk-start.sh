#!/usr/bin/env bash
# Enter away mode and run the sub-supervisor daemon in a harness-tracked
# foreground process when one is not already alive.
#
# Usage: fm-afk-start.sh
#   Sets state/.afk unless FM_AFK_STATE_PREPARED=1, checks
#   state/.supervise-daemon.lock, and:
#     - prints "afk: daemon already running pid=<pid>" then exits 0 when that
#       lock is held by a live daemon (a REFRESH: no stale-artifact clear);
#     - otherwise clears any prior away session's stale escalation artifacts
#       (fm_afk_clear_stale_artifacts) for a direct, non-prepared start, then
#       execs bin/fm-supervise-daemon.sh in the foreground. A prepared start was
#       already cleared transactionally by bin/fm-afk-launch.sh.
#
# This file is sourceable: its BASH_SOURCE guard keeps main from running, while
# exposing the daemon-lock helpers and fm_afk_clear_stale_artifacts. Sourcing it
# enables nounset and errexit; callers that need different shell options must
# restore them explicitly.
#
# This is the COMMON daemon entry for every backend. HOW it becomes a tracked
# background process differs by harness/backend and is owned elsewhere:
#   - Harnesses with a native in-pane tracked-background tool (e.g. claude, grok)
#     run this directly via that tool, so the daemon inherits the captain pane's
#     env and auto-discovers it.
#   - Harnesses with NO native background mechanism (e.g. pi) run this THROUGH
#     bin/fm-afk-launch.sh, which creates a non-visible tracked terminal per
#     backend (herdr tab/workspace, tmux detached session) and passes the
#     captain pane in as FM_SUPERVISOR_TARGET so injection targets it, not the
#     daemon's own new pane.
# Do not wrap this in `nohup ... &`: Codex/herdr can reap fire-and-forget shell
# children after the tool call returns, while a tracked background terminal stays
# attached and has a real lifecycle.
set -eu

FM_AFK_START_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_AFK_START_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_AFK_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_AFK_LOCK="$FM_AFK_STATE/.supervise-daemon.lock"
FM_AFK_DAEMON="$FM_AFK_START_DIR/fm-supervise-daemon.sh"
FM_AFK_NATIVE_PROCESS="$FM_AFK_STATE/.afk-native-process"
FM_AFK_NATIVE_HANDOFF_LOCK="$FM_AFK_STATE/.afk-native-handoff.lock"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$FM_AFK_START_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent

# shellcheck source=bin/fm-wake-lib.sh
. "$FM_AFK_START_DIR/fm-wake-lib.sh"

fm_afk_start_usage() {
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# fm_afk_clear_stale_artifacts: on a FRESH away-session entry (the daemon is not
# already running), drop the previous away session's leftover escalation-delivery
# artifacts so they cannot surface as stale escalations under the new session.
# These are session-scoped by timing: a fresh entry owns a new supervision
# session and the new daemon has not produced anything yet, so anything present
# here belongs to a PRIOR session. This never drops a genuinely-pending
# escalation - the delivery buffer is a transient cache, and any condition still
# true (a crew still blocked, a check still firing) is re-derived and re-escalated
# fresh by the daemon's heartbeat catch-all scan and the durable
# state/.wake-queue replay (see docs/herdr-backend.md "Away-mode stale-artifact
# lifecycle" and bin/fm-supervise-daemon.sh's escalate_add/inject_wedge_alarm).
# NOT called on a refresh (daemon already alive), so the current session's own
# buffered escalations are preserved.
fm_afk_clear_stale_artifacts() {  # <state-dir>
  local state=$1
  rm -f "$state/.subsuper-escalations" \
        "$state/.subsuper-escalations.since" \
        "$state/.subsuper-inject-wedged" 2>/dev/null
}

daemon_lock_owner() {
  local owner
  if [ -L "$FM_AFK_LOCK" ]; then
    owner=$(readlink "$FM_AFK_LOCK" 2>/dev/null) || return 1
    [ -n "$owner" ] || return 1
    case "$owner" in
      /*) printf '%s\n' "$owner" ;;
      *) printf '%s/%s\n' "$(dirname "$FM_AFK_LOCK")" "$owner" ;;
    esac
    return 0
  fi
  [ -d "$FM_AFK_LOCK" ] || return 1
  printf '%s\n' "$FM_AFK_LOCK"
}

daemon_pid_matches() {
  local pid=$1 owner=$2 identity current command
  identity=$(cat "$owner/pid-identity" 2>/dev/null || true)
  if [ -n "$identity" ]; then
    current=$(fm_pid_identity "$pid") || return 1
    [ "$current" = "$identity" ]
    return
  fi
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$FM_AFK_DAEMON"*|*"fm-supervise-daemon.sh"*) return 0 ;;
  esac
  return 1
}

daemon_lock_pid() {
  local owner
  owner=$(daemon_lock_owner) || return 1
  cat "$owner/pid" 2>/dev/null || true
}

daemon_lock_held_by_live_daemon() {
  local owner pid
  owner=$(daemon_lock_owner) || return 1
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  daemon_pid_matches "$pid" "$owner"
}

fm_afk_native_process_write() {
  local pending identity
  if fm_afk_native_process_live && [ "$FM_AFK_NATIVE_PID" != "$$" ]; then
    return 1
  fi
  if [ -e "$FM_AFK_NATIVE_PROCESS" ] || [ -L "$FM_AFK_NATIVE_PROCESS" ]; then
    [ ! -d "$FM_AFK_NATIVE_PROCESS" ] || return 1
    rm -f "$FM_AFK_NATIVE_PROCESS" || return 1
  fi
  identity=$(fm_afk_native_process_identity "$$") || return 1
  pending=$(mktemp "$FM_AFK_STATE/.afk-native-process.pending.XXXXXX") || return 1
  if ! printf '%s\n%s\n' "$$" "$identity" > "$pending"; then
    rm -f "$pending"
    return 1
  fi
  mv "$pending" "$FM_AFK_NATIVE_PROCESS" || { rm -f "$pending"; return 1; }
}

fm_afk_native_process_identity() {
  local pid=$1 out
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  out=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

fm_afk_native_process_live() {
  local pid identity current
  [ -f "$FM_AFK_NATIVE_PROCESS" ] && [ ! -L "$FM_AFK_NATIVE_PROCESS" ] || return 1
  pid=$(sed -n '1p' "$FM_AFK_NATIVE_PROCESS" 2>/dev/null || true)
  identity=$(sed -n '2p' "$FM_AFK_NATIVE_PROCESS" 2>/dev/null || true)
  [ -n "$identity" ] || return 1
  current=$(fm_afk_native_process_identity "$pid") || return 1
  [ "$current" = "$identity" ] || return 1
  FM_AFK_NATIVE_PID=$pid
}

fm_afk_start_main() {
  local prepared=0
  case "${1:-}" in
    '' ) ;;
    -h|--help) fm_afk_start_usage; return 0 ;;
    * ) echo "usage: $(basename "${BASH_SOURCE[1]:-fm-afk-start.sh}")" >&2; return 2 ;;
  esac

  mkdir -p "$FM_AFK_STATE"
  fm_lock_acquire_wait "$FM_AFK_NATIVE_HANDOFF_LOCK"
  if [ "${FM_AFK_STATE_PREPARED:-0}" = 1 ]; then
    prepared=1
    if [ ! -f "$FM_AFK_STATE/.afk" ]; then
      fm_lock_release "$FM_AFK_NATIVE_HANDOFF_LOCK"
      echo "afk: launcher-prepared state is missing" >&2
      return 1
    fi
  elif ! date '+%s' > "$FM_AFK_STATE/.afk"; then
    fm_lock_release "$FM_AFK_NATIVE_HANDOFF_LOCK"
    return 1
  fi

  local pid
  pid=$(daemon_lock_pid 2>/dev/null || true)
  if daemon_lock_held_by_live_daemon; then
    fm_lock_release "$FM_AFK_NATIVE_HANDOFF_LOCK"
    echo "afk: daemon already running pid=$pid"
    return 0
  fi

  if fm_pid_alive "$pid" && [ -n "$pid" ]; then
    fm_lock_remove_path "$FM_AFK_LOCK" 2>/dev/null || true
  fi

  # Fresh start: clear the previous away session's stale delivery artifacts
  # before the new daemon can surface them (fix for the leaked-artifact defect).
  if [ "$prepared" -eq 0 ] && ! fm_afk_clear_stale_artifacts "$FM_AFK_STATE"; then
    fm_lock_release "$FM_AFK_NATIVE_HANDOFF_LOCK"
    return 1
  fi

  if ! fm_afk_native_process_write; then
    fm_lock_release "$FM_AFK_NATIVE_HANDOFF_LOCK"
    echo "afk: could not register native process" >&2
    return 1
  fi
  fm_lock_release "$FM_AFK_NATIVE_HANDOFF_LOCK"

  echo "afk: starting supervise daemon in foreground; keep this command as a tracked background session"
  exec "$FM_AFK_DAEMON"
}

# Run only when executed, not when sourced (tests source fm_afk_clear_stale_artifacts
# and the lock helpers directly).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_afk_start_main "$@"
fi
