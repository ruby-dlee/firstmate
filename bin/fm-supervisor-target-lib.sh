#!/usr/bin/env bash
# fm-supervisor-target-lib.sh - the single owner of primary session endpoint discovery.
#
# The session lock records a verified terminal route when the harness process is
# a descendant of that endpoint. Home-bound visible delivery can then use the
# recorded route without guessing which active terminal belongs to this home.

# Default supervisor pane target/backend when nothing is configured or detected.
# "firstmate:0" is a tmux session:window name, so the bare fallback assumes tmux
# when no runtime endpoint is detected.
FM_SUPERVISOR_TARGET_DEFAULT="firstmate:0"
FM_SUPERVISOR_BACKEND_DEFAULT="tmux"

# discover_supervisor_target: resolve the pane running firstmate. Priority:
#   1. FM_SUPERVISOR_TARGET env (explicit override) - may be a tmux target or a
#      herdr "<session>:<pane-id>" target (paired with discover_supervisor_backend
#      to know which).
#   2. $TMUX_PANE - tmux sets this in every pane's environment; inherited by a
#      process launched from firstmate's own pane.
#   3. $HERDR_ENV=1 + $HERDR_PANE_ID - herdr sets both on every process it
#      manages a pane for; compose the "<session>:<pane-id>" target from
#      $HERDR_SESSION (defaulting to "default", mirroring bin/backends/herdr.sh's
#      fm_backend_herdr_session) and $HERDR_PANE_ID. Checked after $TMUX_PANE so a
#      tmux pane nested inside herdr still resolves to tmux, matching
#      fm_backend_detect's innermost-first rule.
#   4. FM_SUPERVISOR_TARGET_DEFAULT - legacy tmux fallback (may not resolve if the
#      session is named differently). Returns 1 so the caller treats it as unverified.
discover_supervisor_target() {
  if [ -n "${FM_SUPERVISOR_TARGET:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_TARGET"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf '%s' "$TMUX_PANE"
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf '%s:%s' "${HERDR_SESSION:-default}" "$HERDR_PANE_ID"
    return 0
  fi
  printf '%s' "$FM_SUPERVISOR_TARGET_DEFAULT"
  return 1
}

# discover_supervisor_backend: resolve the supervisor pane's BACKEND, independent
# of the target string so an explicit FM_SUPERVISOR_TARGET override still knows
# which primitives (tmux vs herdr) to dispatch through. Priority mirrors
# discover_supervisor_target and bin/fm-backend.sh's fm_backend_detect:
#   1. FM_SUPERVISOR_BACKEND env (explicit override).
#   2. $TMUX_PANE set - tmux.
#   3. $HERDR_ENV=1 (with $HERDR_PANE_ID present) - herdr.
#   4. FM_SUPERVISOR_BACKEND_DEFAULT (tmux) - matches the target fallback. Returns 1.
discover_supervisor_backend() {
  if [ -n "${FM_SUPERVISOR_BACKEND:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_BACKEND"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf 'tmux'
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf 'herdr'
    return 0
  fi
  printf '%s' "$FM_SUPERVISOR_BACKEND_DEFAULT"
  return 1
}
