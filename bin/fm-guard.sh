#!/usr/bin/env bash
# Watcher liveness and worktree-tangle guard, called by supervision scripts, by
# fm-wake-drain.sh after it empties queued wakes, and by fm-session-start.sh in
# read-only advisory mode when another session holds the fleet lock.
# First, always warn if the firstmate primary checkout (FM_ROOT) is on a named
# non-default branch, because that means firstmate-on-itself work landed in the
# primary instead of an isolated worktree.
# Then, if any task is in flight (a state/<id>.meta exists) and the watcher's
# liveness beacon (state/.last-watcher-beat, touched between bounded phases) is
# missing or older than FM_GUARD_GRACE seconds, prints a loud, clearly delimited
# banner so the agent cannot skim past it in the tool output of whatever it was
# doing - the one channel every harness has. A live lock gets the tighter
# FM_WATCH_PROGRESS_GRACE check, because normal wake-and-rearm handoff grace must
# not make an already-wedged holder look healthy. Normal wake handling (watcher
# briefly down between a wake and the next supervision resume) stays inside the
# broad grace window and stays silent. Always exits 0: the guard warns, it never
# blocks.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-watcher-config-lib.sh
. "$SCRIPT_DIR/fm-watcher-config-lib.sh"
fm_watcher_config_load "$CONFIG" || exit 1
GRACE=${FM_GUARD_GRACE:-300}
PROGRESS_GRACE=${FM_WATCH_PROGRESS_GRACE:-60}
CPU_LIMIT=${FM_WATCH_CPU_LIMIT:-80}
fm_watcher_config_positive_integer FM_WATCH_PROGRESS_GRACE 60
fm_watcher_config_positive_integer FM_WATCH_CPU_LIMIT 80
PROGRESS_GRACE=$FM_WATCH_PROGRESS_GRACE
CPU_LIMIT=$FM_WATCH_CPU_LIMIT
queue_pending=false
READ_ONLY=${FM_GUARD_READ_ONLY:-0}
case "$READ_ONLY" in 1|true|TRUE|yes|YES) READ_ONLY=1 ;; *) READ_ONLY=0 ;; esac
CONTINUE_LINE=${FM_GUARD_CONTINUE_LINE:-This is a supervision warning only; the guarded operation WILL still run.}

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tangle-lib.sh
. "$SCRIPT_DIR/fm-tangle-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"

# Worktree-tangle alarm, checked FIRST and independent of in-flight tasks: the
# firstmate PRIMARY checkout (FM_ROOT) must stay on its default branch. If a
# crewmate's branch/commits landed here instead of in its own isolated worktree,
# the primary is stranded on a feature branch - surface it loudly on the very next
# fleet action, the same way the watcher-down banner does. Scoped to the primary
# only: detached HEAD (linked worktrees, secondmate homes) never trips this.
tangle_branch=$(fm_primary_tangle_branch "$FM_ROOT" || true)
if [ -n "$tangle_branch" ]; then
  tangle_default=$(fm_default_branch "$FM_ROOT" 2>/dev/null || echo main)
  trule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '●%s\n' "$trule"
    printf '●  WORKTREE TANGLE - PRIMARY CHECKOUT IS ON A FEATURE BRANCH\n'
    printf "●  %s is on '%s', not its default branch '%s'.\n" "$FM_ROOT" "$tangle_branch" "$tangle_default"
    printf '●  A crewmate likely branched/committed in the primary instead of its own worktree.\n'
    printf "●  The work is SAFE on the '%s' ref.\n" "$tangle_branch"
    if [ "$READ_ONLY" -eq 1 ]; then
      printf '●  This read-only session must leave restore work to the session holding the fleet lock.\n'
    else
      printf "●  Restore the primary to '%s':\n" "$tangle_default"
      printf '●      git -C %s checkout %s\n' "$FM_ROOT" "$tangle_default"
      printf "●  then re-validate '%s' in a proper isolated worktree.\n" "$tangle_branch"
    fi
    printf '●%s\n' "$trule"
  } >&2
fi

# Compute in-flight count and watcher-beacon freshness via the shared
# grace-based predicate (bin/fm-supervision-lib.sh). Only act with tasks in
# flight; count them so the banner can say how much is riding on an absent
# watcher.
fm_supervision_status "$STATE" "$GRACE"
in_flight=$FM_SUP_IN_FLIGHT
watcher_fresh=$FM_SUP_WATCHER_FRESH
beacon_desc=$FM_SUP_BEACON_DESC
[ "$in_flight" -eq 0 ] && exit 0

[ -s "$FM_WAKE_QUEUE" ] && queue_pending=true

# Beacon freshness cannot detect a sibling burning a core while the recorded
# parent remains alive. Inspect only the lock-recorded pid and its descendants;
# never select by command text, which may merely quote the watcher in a brief.
watcher_pid=$(cat "$STATE/.watch.lock/pid" 2>/dev/null || true)
watcher_lock_live=false
watcher_progress_stale=false
if fm_watcher_lock_matches_pid "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$watcher_pid" "$FM_HOME"; then
  watcher_lock_live=true
  watcher_age=$(fm_path_age "$STATE/.last-watcher-beat")
  if fm_watcher_progress_current "$STATE" "$watcher_pid" "$PROGRESS_GRACE"; then
    watcher_fresh=true
  else
    watcher_progress_stale=true
  fi
fi
if "$watcher_lock_live" \
  && fm_watcher_tree_usage "$watcher_pid" \
  && awk -v actual="$FM_WATCHER_TREE_CPU" -v limit="$CPU_LIMIT" 'BEGIN { exit !(actual >= limit) }'; then
  resource_rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '●%s\n' "$resource_rule"
    printf '●  WATCHER RUNAWAY - SUPERVISION IS CONSUMING A CORE\n'
    printf '●  Recorded watcher pid %s and its exact descendant tree are using %s%% CPU across %s processes (limit %s%%).\n' \
      "$watcher_pid" "$FM_WATCHER_TREE_CPU" "$FM_WATCHER_TREE_COUNT" "$CPU_LIMIT"
    if [ "$READ_ONLY" -eq 1 ]; then
      printf '●  This read-only session should report the runaway, not repair it.\n'
    else
      printf '●  Recover this home with: bin/fm-watch-arm.sh --restart\n'
    fi
    printf '●  %s\n' "$CONTINUE_LINE"
    printf '●%s\n' "$resource_rule"
  } >&2
fi

# A live lock is not enough. A normal watcher refreshes between bounded phases;
# reaching this tighter limit means it stopped making progress even though the
# broad handoff grace has not expired.
if "$watcher_progress_stale"; then
  progress_rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '●%s\n' "$progress_rule"
    printf '●  WATCHER WEDGED - LIVE SUPERVISION MISSED ITS CADENCE\n'
    printf '●  Recorded watcher pid %s is still alive, but its beacon is %ss old (cadence limit %ss).\n' \
      "$watcher_pid" "$watcher_age" "$PROGRESS_GRACE"
    if [ "$READ_ONLY" -eq 1 ]; then
      printf '●  This read-only session should report the wedge, not repair it.\n'
    else
      printf '●  Recover this home with: bin/fm-watch-arm.sh --restart\n'
    fi
    printf '●  %s\n' "$CONTINUE_LINE"
    printf '●%s\n' "$progress_rule"
  } >&2
fi

# No fresh watcher with tasks in flight is the dangerous state: emit a prominent,
# bordered banner FIRST so it reads as an alarm, not a buried stderr line.
if [ "$watcher_fresh" = false ] && ! "$watcher_progress_stale"; then
  afk=0
  [ -e "$STATE/.afk" ] && afk=1
  queue_arg=0
  "$queue_pending" && queue_arg=1
  x_mode=0
  [ -f "$CONFIG/x-mode.env" ] && x_mode=1
  fix=$("$SCRIPT_DIR/fm-supervision-instructions.sh" \
    --read-only "$READ_ONLY" \
    --afk "$afk" \
    --x-mode "$x_mode" \
    --queue-pending "$queue_arg" \
    --repair-line 2>/dev/null || printf '%s\n' 'Resume supervision according to the session-start operating block.')
  rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '●%s\n' "$rule"
    printf '●  WATCHER DOWN - SUPERVISION IS OFF\n'
    printf '●  %s task(s) in flight, but no watcher has a fresh beacon (last beat: %s, grace %ss).\n' "$in_flight" "$beacon_desc" "$GRACE"
    if [ "$READ_ONLY" -eq 1 ]; then
      printf '●  This read-only session should report the lapse, not repair it.\n'
    else
      printf '●  Trust the emitted supervision protocol for this harness; do not use shell & for watcher repair.\n'
    fi
    printf '●  %s\n' "$CONTINUE_LINE"
    printf '●  %s\n' "$fix"
    printf '●%s\n' "$rule"
  } >&2
fi

# Queued wakes are an independent hazard; warn whenever they are pending, even if
# a watcher is alive. Kept after the banner so the no-watcher alarm reads first.
if "$queue_pending"; then
  if [ "$READ_ONLY" -eq 1 ]; then
    echo "WARNING: queued wakes pending - left untouched for the session holding the fleet lock." >&2
  else
    echo "WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else." >&2
  fi
fi
exit 0
