# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# Computes supervision status without collapsing a failed liveness proof into a
# healthy result. Beacon freshness is retained as one observation, while callers
# that supply the watcher path and home also receive the exact process-bound
# healthy|down|unknown verdict from bin/fm-wake-lib.sh.

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_supervision_status <state-dir> [grace-seconds] [watch-path] [home]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_WATCHER_STATE  healthy|down|unknown when a watch path was supplied;
#                         beacon-only otherwise for backward-compatible probes
#   FM_SUP_WATCHER_REASON actionable explanation for the process-bound verdict
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} watch_path=${3:-} home=${4:-${FM_HOME:-}}
  local meta beat m age
  FM_SUP_IN_FLIGHT=0
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_WATCHER_STATE=unknown
  FM_SUP_WATCHER_REASON="watcher process liveness was not requested"
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      FM_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    fi
  fi

  if [ -n "$watch_path" ]; then
    if ! type fm_watcher_health_state >/dev/null 2>&1; then
      FM_SUP_WATCHER_STATE=unknown
      FM_SUP_WATCHER_REASON="watcher process proof is unavailable"
    else
      if fm_watcher_health_state "$state" "$watch_path" "$grace" "$home"; then
        :
      else
        : # The global verdict preserves down (1) versus unknown (2).
      fi
      FM_SUP_WATCHER_STATE=$FM_WATCHER_HEALTH_STATE
      FM_SUP_WATCHER_REASON=$FM_WATCHER_HEALTH_REASON
    fi
  elif [ "$FM_SUP_WATCHER_FRESH" = true ]; then
    FM_SUP_WATCHER_STATE=healthy
    FM_SUP_WATCHER_REASON="beacon-only compatibility probe is fresh"
  else
    FM_SUP_WATCHER_STATE=down
    # shellcheck disable=SC2034 # Read by callers after fm_supervision_status returns.
    FM_SUP_WATCHER_REASON="beacon-only compatibility probe is absent or stale"
  fi

  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true
  return 0
}

# fm_supervision_unhealthy <state-dir> [grace-seconds] [watch-path] [home]
# Exit 0 (true) exactly in the dangerous state: in-flight work exists and watcher
# health is either down or indeterminate. Unknown is actionable, never healthy.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_IN_FLIGHT" -gt 0 ] && [ "$FM_SUP_WATCHER_STATE" != healthy ]
}
