#!/usr/bin/env bash
# Safe, home-scoped (re-)arm of the firstmate watcher, with honest verification.
#
# The watcher (bin/fm-watch.sh) blocks until it has an actionable wake to
# surface, then prints one reason line and exits. While state/.afk exists the
# daemon owns triage and the watcher exits on every wake for the daemon to
# classify. Reliability depends on arming through a mechanism that SURVIVES the
# call and NOTIFIES on exit, so firstmate must run this script as the harness's
# own tracked background task (e.g. run_in_background). Run it as its own
# standalone background task, never bundled onto the tail of another command.
# NEVER fire it and forget with a shell `&` inside another call: that backgrounded
# child is reaped when the call returns, leaving NO watcher running and a false
# "already running" off the dying process. That exact mistake silently took
# supervision down for ~30 minutes.
# On a harness with a PreToolUse-equivalent hook, bin/fm-arm-pretool-check.sh
# applies the command-position policy before the command runs; see
# docs/arm-pretool-check.md for the blessed tree and deny reason codes. It is a
# pre-execution seatbelt, not a substitute for the verification here.
#
# This script forks the watcher as a tracked child, then VERIFIES the outcome
# before it settles in. It confirms a watcher process is genuinely alive AND the
# liveness beacon (state/.last-watcher-beat) is within the tighter
# FM_WATCH_PROGRESS_GRACE cadence bound. The broader FM_GUARD_GRACE remains the
# normal wake-and-rearm handoff allowance when no live lock exists. It prints
# exactly one unambiguous status line:
#   watcher: started pid=<N> (beacon fresh)              - it launched one and confirmed it
#   watcher: attached pid=<N> (beacon <age>s as of <hh:mm:ss>)
#                                                        - arm mode found a live+fresh watcher
#                                                          holding the lock; this arm attaches and
#                                                          waits until that cycle ends
#   watcher: healthy pid=<N> (beacon <age>s)             - restart mode found a live+fresh
#                                                          watcher it did not own
#   watcher: FAILED - no live watcher with a fresh beacon  - could not confirm one
#   watcher: FAILED - attached cycle ended ...           - an attach ended (below)
#   watcher: FAILED - attach interrupted ...             - this arm was signalled away (below)
# It NEVER reports started/attached/healthy off a stale beacon or a dead/reused pid: a
# stale-beacon or dead-pid holder either self-heals (the fresh child steals the
# dead lock per the singleton self-eviction/steal path and is confirmed) or this
# returns a FAILED line. On started it monitors the exact recorded process tree,
# waits the child, and propagates the wake reason. Sustained full-core use or a
# stale progress beacon becomes a durable failure and the owned tree is reaped.
# On restart-only healthy it exits zero after the duplicate child stands down.
# On FAILED it exits non-zero so the failure is loud. A live cycle already
# present means re-arm attaches - do not start a second watcher.
#
# `attached` is a claim about the INSTANT it is printed, and this script's output
# outlives that instant: the caller reads the whole buffer after the task
# completes. So an attach is ALWAYS closed by a terminal line, non-zero, stating
# the truth at exit with a beacon age recomputed then rather than the frozen
# attach-time one:
#   watcher: FAILED - attached cycle ended (<which proof failed>), no live watcher
#     with a fresh beacon (was pid=<N>, beacon <age>s as of <hh:mm:ss>)
#   watcher: FAILED - attach interrupted ...   (this arm signalled away; says
#     whether the holder is still live, because "the watcher is up but nothing is
#     delivering its wakes" and "nothing is up" need different repairs)
# Without that closure the arm exited zero and SILENT, leaving `attached pid=<N>`
# as the caller's final word for a watcher that no longer existed and an age
# understated by however long the attach ran - a fleet nobody was watching, read
# as healthy. That fired constantly rather than rarely, because fm-watch.sh exits
# normally as soon as it surfaces a wake: in a busy home an attach lasts only
# until the next wake, so nearly every plain arm ended this way. No watcher crash
# is involved, and --restart was unaffected because it never attaches.
# The end of an attach is never "supervision is live": the holder is gone and any
# wake it surfaced is already durable in state/.wake-queue, so the honest report
# is the loud FAILED vocabulary the caller already repairs on (drain queued wakes,
# then re-arm) - and draining is what delivers that wake. Reporting FAILED here
# can at worst cost one redundant watcher if a successor appeared in the same
# instant; staying silent costs the whole fleet, so the ambiguity resolves toward
# supervision.
#
# --restart: stop ONLY this FM_HOME's watcher (the pid recorded in THIS home's
# state/.watch.lock) and its launch-time process session, then own a fresh cycle,
# or report restart-only healthy if a replacement peer wins the race.
# TERM-resistant owned processes are KILLed after a bound. No process is selected
# by command text, so another home's watcher cannot be touched. NEVER `pkill -f
# bin/fm-watch.sh`: that pattern matches every firstmate home's watcher
# (secondmate homes run the same script) and would kill siblings. Restart never
# takes the attach path.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-watcher-config-lib.sh
. "$SCRIPT_DIR/fm-watcher-config-lib.sh"
fm_watcher_config_load "$CONFIG" || exit 1
fm_watcher_config_positive_integer FM_CREW_STATE_READ_TIMEOUT 30

WATCH="$SCRIPT_DIR/fm-watch.sh"
WATCH_LOCK="$STATE/.watch.lock"
BEAT="$STATE/.last-watcher-beat"
# A normal wake-and-rearm handoff may briefly have no live lock, so guards retain
# the broad grace. A lock-holding watcher must make progress much more often: an
# age under 300s was technically "fresh" but let an already-wedged 155s-old
# watcher be reported as attachable.
PROGRESS_GRACE=${FM_WATCH_PROGRESS_GRACE:-60}
fm_watcher_config_positive_integer FM_WATCH_PROGRESS_GRACE 60
PROGRESS_GRACE=$FM_WATCH_PROGRESS_GRACE
# How long to wait for a freshly forked watcher to acquire the lock and beat.
CONFIRM_TIMEOUT=${FM_ARM_CONFIRM_TIMEOUT:-10}
# Poll interval while attached to an existing healthy watcher.
ATTACH_POLL=${FM_ARM_ATTACH_POLL:-0.5}
fm_watcher_config_positive_decimal FM_ARM_ATTACH_POLL 0.5 || exit 1
ATTACH_POLL=$FM_ARM_ATTACH_POLL
# Resource monitor for the exact recorded watcher tree. A watcher has no
# legitimate sustained full-core phase, so three five-second samples over this
# threshold are loud and end an owned cycle instead of burning silently.
CPU_LIMIT=${FM_WATCH_CPU_LIMIT:-80}
CPU_POLL=${FM_WATCH_CPU_POLL:-5}
CPU_SAMPLES=${FM_WATCH_CPU_SAMPLES:-3}
fm_watcher_config_positive_integer FM_WATCH_CPU_LIMIT 80
fm_watcher_config_positive_integer FM_WATCH_CPU_POLL 5
fm_watcher_config_positive_integer FM_WATCH_CPU_SAMPLES 3
CPU_LIMIT=$FM_WATCH_CPU_LIMIT
CPU_POLL=$FM_WATCH_CPU_POLL
CPU_SAMPLES=$FM_WATCH_CPU_SAMPLES

recorded_watcher_lock_metadata_matches() {
  local lock_home lock_path lock_pid lock_identity
  lock_home=$(cat "$WATCH_LOCK/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$WATCH_LOCK/watcher-path" 2>/dev/null || true)
  lock_pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  lock_identity=$(cat "$WATCH_LOCK/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$FM_HOME" ] || return 1
  [ "$lock_path" = "$WATCH" ] || return 1
  case "$lock_pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$lock_identity" ]
}

clear_stale_recorded_watcher_lock() {
  local lock_session
  recorded_watcher_lock_metadata_matches || return 1
  lock_session=$(cat "$WATCH_LOCK/process-session" 2>/dev/null || true)
  if [ -n "$lock_session" ]; then
    fm_session_wait_quiescent_except "$lock_session" "" 2 || return 1
  fi
  fm_lock_remove_path "$WATCH_LOCK" || return 1
  [ ! -e "$WATCH_LOCK" ] && [ ! -L "$WATCH_LOCK" ]
}

stop_recorded_watcher() {  # <root-pid> <root-identity>
  local root=$1 identity=$2 session current_identity anchor anchor_identity
  session=$(cat "$WATCH_LOCK/process-session" 2>/dev/null || true)
  if [ -n "$session" ]; then
    fm_watcher_lock_session_record_matches "$STATE" "$WATCH" "$FM_HOME" "$session" || return 1
    fm_watcher_lock_session_anchor_read "$STATE" || true
    anchor=$FM_WATCHER_SESSION_ANCHOR_PID
    anchor_identity=$FM_WATCHER_SESSION_ANCHOR_IDENTITY
    if fm_session_anchor_matches "$session" "$anchor" "$anchor_identity"; then
      fm_session_stop_owned_with_anchor "$session" "$anchor" "$anchor_identity" 30
      return
    fi
    current_identity=$(fm_pid_identity "$root" 2>/dev/null || true)
    [ "$current_identity" = "$identity" ] || return 1
    [ "$(fm_pid_session "$root" 2>/dev/null || true)" = "$session" ] || return 1
    fm_pid_session_stop "$root" "$session" 30 "$identity"
    return
  fi
  current_identity=$(fm_pid_identity "$root") || return 1
  [ "$current_identity" = "$identity" ] || return 1
  fm_pid_tree_stop "$root" 30 "$identity"
}

# A watcher is "healthy" iff the lock names a live process that is genuinely THIS
# home's watcher (the identity match guards against a recycled/reused pid) AND the
# liveness beacon is within PROGRESS_GRACE. Sets HEALTHY_PID on success. This is the
# single honesty gate: a dead pid, a reused pid, or a stale beacon all fail it, so
# this script can never report a watcher that is not really there.
HEALTHY_PID=
healthy_watcher() {
  HEALTHY_PID=
  fm_watcher_healthy "$STATE" "$WATCH" "$PROGRESS_GRACE" "$FM_HOME" || return 1
  HEALTHY_PID=$FM_WATCHER_HEALTHY_PID
}

# A beacon age is only true at the instant it is measured, and the `attached`
# line is the one reading that routinely gets read much later - it is printed
# once and then stands unchanged for the whole attach. Stamping the reading with
# the clock time it was taken is what makes it unmistakable: `beacon 11s as of
# 14:32:07` read at 14:32:36 states its own staleness, where a bare `beacon 11s`
# silently understated a true 40s by exactly the 29s since it was printed. The
# computation itself is exact at call time (verified against stat across the
# grace boundary), so the honest fix is to date the reading, not to change the
# arithmetic. Re-printing the line on a timer instead would only produce a stream
# of readings that each go stale the same way.
report_attached() {
  local age
  age=$(fm_path_age "$BEAT")
  echo "watcher: attached pid=$HEALTHY_PID (beacon ${age}s as of $(date +%H:%M:%S))"
}

report_healthy() {
  local age
  age=$(fm_path_age "$BEAT")
  echo "watcher: healthy pid=$HEALTHY_PID (beacon ${age}s)"
}

watcher_tree_hot() {  # <root-pid>
  local root=$1
  fm_watcher_tree_usage "$root" || return 1
  awk -v actual="$FM_WATCHER_TREE_CPU" -v limit="$CPU_LIMIT" 'BEGIN { exit !(actual >= limit) }'
}

resource_reason() {  # <root-pid>
  local root=$1
  printf 'stale: watcher pid %s process tree is consuming %s%% CPU across %s processes (limit %s%% for %s consecutive %ss-cadence samples; exact recorded pid and parentage, never command matching)' \
    "$root" "$FM_WATCHER_TREE_CPU" "$FM_WATCHER_TREE_COUNT" "$CPU_LIMIT" "$CPU_SAMPLES" "$CPU_POLL"
}

queue_watcher_failure() {  # <reason>
  local reason=$1
  fm_wake_append stale watcher-health "$reason" >/dev/null 2>&1 || true
}

# Terminal line for an attach that has ended: the holder failed the same honesty
# gate that let it be reported in the first place (pid gone, identity mismatch, or
# a beacon that went stale), so no live cycle exists at exit. The age is measured
# HERE, not carried over from the attach-time line, which is exactly the reading
# that was understated by the attach duration.
report_attach_ended() {
  local ended_pid=$1 age cause
  age=$(fm_path_age "$BEAT")
  # Name which proof failed. Diagnosing this by hand (ps the pid, stat the
  # beacon) is exactly the work the silent exit used to push onto the operator.
  if ! fm_pid_alive "$ended_pid"; then
    cause="holder exited"
  elif ! fm_watcher_lock_matches_pid "$STATE" "$WATCH" "$ended_pid" "$FM_HOME"; then
    cause="lock no longer names that watcher"
  else
    cause="beacon went stale"
  fi
  echo "watcher: FAILED - attached cycle ended ($cause), no live watcher with a fresh beacon (was pid=$ended_pid, beacon ${age}s as of $(date +%H:%M:%S))"
}

# Same closure for the other way an attach stops: this arm is signalled (harness
# restart, session teardown) while the holder may still be fine. Wake delivery
# still stops, so the post-condition the caller reads for is false either way -
# but say which, because "the watcher is still up, the notify path is not" and
# "nothing is up" need different repairs.
# shellcheck disable=SC2329 # Invoked from attach_and_wait's HUP/TERM/INT traps.
report_attach_interrupted() {
  local ended_pid=$1 age
  age=$(fm_path_age "$BEAT")
  if healthy_watcher; then
    echo "watcher: FAILED - attach interrupted; watcher pid=$HEALTHY_PID is still live (beacon ${age}s) but this arm stopped waiting on it, so no wake reaches the harness until re-armed"
  else
    echo "watcher: FAILED - attach interrupted, no live watcher with a fresh beacon (was pid=$ended_pid, beacon ${age}s)"
  fi
}

# Stay alive until the attached identity-matched healthy holder is gone.
# If a different healthy watcher appears mid-attach (rare steal), re-attach.
# Does not reprint the starter arm's wake reason line: any wake the holder
# surfaced is already durable in state/.wake-queue, and the caller's repair for
# the terminal line below is to drain that queue and then re-arm.
attach_and_wait() {
  local attached_pid=$1 hot_samples=0 next_cpu=0 now reason
  # Being signalled is the other way this arm stops waiting, and it must not be
  # silent either: the harness restarting or tearing down the task would
  # otherwise leave the buffered `attached` line as the final word. No child to
  # clean up here - the confirm path cleared its traps and reaped its child
  # before calling in, and the pre-fork path never forked one.
  trap 'report_attach_interrupted "$attached_pid"; exit 129' HUP
  trap 'report_attach_interrupted "$attached_pid"; exit 143' TERM INT
  while :; do
    if healthy_watcher; then
      if [ "$HEALTHY_PID" != "$attached_pid" ]; then
        attached_pid=$HEALTHY_PID
        hot_samples=0
        report_attached
      fi
      now=$(date +%s)
      if [ "$now" -ge "$next_cpu" ]; then
        next_cpu=$((now + CPU_POLL))
        if watcher_tree_hot "$attached_pid"; then
          hot_samples=$((hot_samples + 1))
          if [ "$hot_samples" -ge "$CPU_SAMPLES" ]; then
            reason=$(resource_reason "$attached_pid")
            queue_watcher_failure "$reason"
            echo "watcher: FAILED - $reason; run bin/fm-watch-arm.sh --restart for home-scoped recovery"
            exit 1
          fi
        else
          hot_samples=0
        fi
      fi
      sleep "$ATTACH_POLL"
      continue
    fi
    # Attached cycle ended (pid gone, identity mismatch, or beacon no longer
    # fresh). Never exit silently here: the buffered `attached` line would stand
    # as the caller's final word and read as live supervision.
    report_attach_ended "$attached_pid"
    exit 1
  done
}

watch_output_has_wake() {
  local out=$1
  grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null
}

print_watch_output() {
  local out=$1
  [ -s "$out" ] && cat "$out"
}

mode=arm
case "${1:-}" in
  ''|arm|--arm) mode=arm ;;
  --restart) mode=restart ;;
  *) echo "usage: $(basename "$0") [--restart]" >&2; exit 2 ;;
esac

if [ "$mode" = restart ]; then
  # Home-scoped stop: only the watcher pid recorded in THIS home's lock and its
  # recorded ownership boundary. TERM-resistant wedges are escalated to KILL
  # after a bound, which is the supported alternative to manual pid surgery.
  lock_pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  lock_identity=$(cat "$WATCH_LOCK/pid-identity" 2>/dev/null || true)
  if [ -e "$WATCH_LOCK" ] || [ -L "$WATCH_LOCK" ]; then
    recorded_watcher_lock_metadata_matches || {
      echo "watcher: FAILED - recorded watcher lock ownership metadata is invalid" >&2
      exit 1
    }
    lock_session=$(cat "$WATCH_LOCK/process-session" 2>/dev/null || true)
    current_identity=$(fm_pid_identity "$lock_pid" 2>/dev/null || true)
    if [ -n "$lock_session" ] || [ "$current_identity" = "$lock_identity" ]; then
      if ! stop_recorded_watcher "$lock_pid" "$lock_identity"; then
        echo "watcher: FAILED - recorded watcher ownership boundary could not be stopped for restart" >&2
        exit 1
      fi
    fi
    clear_stale_recorded_watcher_lock || {
      echo "watcher: FAILED - recorded watcher ownership boundary remains live after restart cleanup" >&2
      exit 1
    }
  fi
fi

# Refuse an already-sick live holder immediately. The broad 300-second handoff
# allowance is not an attach standard: a 155-second-old beacon was accepted here,
# then aged to 300 while the same TERM-resistant pid remained wedged.
if [ "$mode" = arm ]; then
  recorded_pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  if fm_watcher_lock_matches_pid "$STATE" "$WATCH" "$recorded_pid" "$FM_HOME" \
    && [ -e "$BEAT" ]; then
    recorded_age=$(fm_path_age "$BEAT")
    if ! fm_watcher_progress_current "$STATE" "$recorded_pid" "$PROGRESS_GRACE"; then
      echo "watcher: FAILED - live watcher pid=$recorded_pid missed progress cadence (beacon ${recorded_age}s, limit ${PROGRESS_GRACE}s); run bin/fm-watch-arm.sh --restart"
      exit 1
    fi
  fi
fi

# If a genuinely live+fresh watcher already holds the lock, do not start a second
# one - attach to that cycle and wait until it ends so the harness notify fires
# then, not as an immediate empty wake. (--restart skips this: it just stopped
# this home's watcher and wants a fresh one.)
if [ "$mode" = arm ] && healthy_watcher; then
  report_attached
  attach_and_wait "$HEALTHY_PID"
fi

# Start a watcher as a tracked child and confirm it before settling in. The child
# stays our child for its whole life: we wait on it, so killing this arm (the
# harness-tracked task) tears the watcher down too, and the watcher's eventual
# wake exit propagates out so the harness re-notifies firstmate.
child=
child_identity=
child_session_identity=
child_session_record=
child_out=
child_session_verified=false
owner_link_dir=
owner_link_fifo=
owner_link_ready=
owner_link_failed=
owner_link_connected=false
owner_link_reader_connected=false

owner_link_disconnect() {
  if "$owner_link_connected"; then
    exec 9>&-
    owner_link_connected=false
  fi
}

owner_link_reader_disconnect() {
  if "$owner_link_reader_connected"; then
    exec 8<&-
    owner_link_reader_connected=false
  fi
}

owner_link_remove() {
  [ -n "$owner_link_dir" ] || return 0
  rm -f "$owner_link_ready" "$owner_link_failed" "$owner_link_fifo" \
    "$owner_link_dir/session-root" "$owner_link_dir/session-root.pending" 2>/dev/null || true
  rmdir "$owner_link_dir" 2>/dev/null || true
  owner_link_dir=
  owner_link_fifo=
  owner_link_ready=
  owner_link_failed=
}

capture_child_session_handshake() {
  local snapshot lines record_pid record_identity
  "$child_session_verified" && return 0
  [ -f "$child_session_record" ] && [ ! -L "$child_session_record" ] || return 1
  snapshot=$(cat "$child_session_record" 2>/dev/null) || return 1
  lines=$(printf '%s\n' "$snapshot" | awk 'END { print NR }')
  [ "$lines" -eq 2 ] || return 1
  record_pid=$(printf '%s\n' "$snapshot" | sed -n '1s/^pid=//p')
  record_identity=$(printf '%s\n' "$snapshot" | sed -n '2s/^identity=//p')
  [ "$record_pid" = "$child" ] || return 1
  [ -n "$record_identity" ] || return 1
  [ "$(fm_pid_identity "$child" 2>/dev/null || true)" = "$record_identity" ] || return 1
  [ "$(fm_pid_session "$child" 2>/dev/null || true)" = "$child" ] || return 1
  child_session_identity=$record_identity
  child_session_verified=true
}

stop_owned_child() {
  local status=0 session_status=0
  [ -n "$child" ] || return 0
  owner_link_disconnect
  owner_link_reader_disconnect
  if "$child_session_verified" \
    && [ "$(cat "$WATCH_LOCK/pid-identity" 2>/dev/null || true)" = "$child_session_identity" ] \
    && fm_watcher_lock_session_record_matches "$STATE" "$WATCH" "$FM_HOME" "$child"; then
    stop_recorded_watcher "$child" "$child_session_identity" || status=$?
  elif "$child_session_verified"; then
    if [ -n "$child_session_identity" ] \
      && [ "$(fm_pid_identity "$child" 2>/dev/null || true)" = "$child_session_identity" ]; then
      fm_pid_session_stop "$child" "$child" 30 "$child_session_identity" || status=$?
    else
      status=1
    fi
  elif [ -n "$child_identity" ] && fm_pid_alive "$child"; then
    fm_pid_stop_identity "$child" "$child_identity" 30 || status=$?
  fi
  wait "$child" 2>/dev/null || true
  if "$child_session_verified"; then
    fm_session_has_live_processes "$child" || session_status=$?
    [ "$session_status" -eq 1 ] || status=1
  fi
  clear_stale_recorded_watcher_lock >/dev/null 2>&1 || true
  owner_link_remove
  return "$status"
}

cleanup_child() {
  stop_owned_child >/dev/null 2>&1 || true
  owner_link_disconnect
  owner_link_reader_disconnect
  owner_link_remove
  if [ -n "$child_out" ]; then
    rm -f "$child_out" 2>/dev/null || true
  fi
}

monitor_started_child() {  # <confirmed-watcher-pid>
  local watched=$1 hot_samples=0 sample_in=0 age reason rc session_status=0 identity
  while fm_pid_alive "$watched" \
    && fm_watcher_lock_matches_pid "$STATE" "$WATCH" "$watched" "$FM_HOME"; do
    age=$(fm_path_age "$BEAT")
    if ! fm_watcher_progress_current "$STATE" "$watched" "$PROGRESS_GRACE"; then
      reason="stale: watcher pid $watched stopped making supervision progress; beacon age ${age}s reached cadence limit ${PROGRESS_GRACE}s"
      queue_watcher_failure "$reason"
      echo "watcher: FAILED - $reason; recovering the owned watcher tree"
      if ! stop_owned_child; then
        echo "watcher: FAILED - owned watcher process session could not be fully reaped"
      fi
      print_watch_output "$child_out"
      rm -f "$child_out" 2>/dev/null || true
      child=
      child_out=
      return 1
    fi
    if [ "$sample_in" -eq 0 ]; then
      sample_in=$CPU_POLL
      if watcher_tree_hot "$watched"; then
        hot_samples=$((hot_samples + 1))
        if [ "$hot_samples" -ge "$CPU_SAMPLES" ]; then
          reason=$(resource_reason "$watched")
          queue_watcher_failure "$reason"
          echo "watcher: FAILED - $reason; recovering the owned watcher tree"
          if ! stop_owned_child; then
            echo "watcher: FAILED - owned watcher process session could not be fully reaped"
          fi
          print_watch_output "$child_out"
          rm -f "$child_out" 2>/dev/null || true
          child=
          child_out=
          return 1
        fi
      else
        hot_samples=0
      fi
    fi
    sleep 1
    sample_in=$((sample_in - 1))
  done
  wait "$watched"
  rc=$?
  owner_link_disconnect
  if "$child_session_verified"; then
    fm_session_has_live_processes "$watched" || session_status=$?
  fi
  if "$child_session_verified" && [ "$session_status" -ne 1 ]; then
    reason="stale: watcher pid $watched exited before its owned process session was verified empty"
    queue_watcher_failure "$reason"
    echo "watcher: FAILED - $reason; recovering the owned watcher process session"
    session_status=0
    identity=$child_session_identity
    stop_recorded_watcher "$watched" "$identity" || session_status=$?
    if [ "$session_status" -ne 0 ]; then
      echo "watcher: FAILED - owned watcher process session could not be fully reaped"
    fi
    rc=1
  fi
  clear_stale_recorded_watcher_lock >/dev/null 2>&1 || true
  owner_link_remove
  print_watch_output "$child_out"
  rm -f "$child_out" 2>/dev/null || true
  child=
  child_out=
  return "$rc"
}
trap 'cleanup_child; exit 129' HUP
trap 'cleanup_child; exit 143' TERM INT

child_out=$(mktemp "$STATE/.watch-arm-output.XXXXXX") || {
  echo "watcher: FAILED - no live watcher with a fresh beacon"
  exit 1
}
owner_link_dir=$(mktemp -d "$STATE/.watch-arm-owner.XXXXXX") || {
  rm -f "$child_out"
  echo "watcher: FAILED - could not create arm ownership channel"
  exit 1
}
owner_link_fifo="$owner_link_dir/control"
owner_link_ready="$owner_link_dir/ready"
owner_link_failed="$owner_link_dir/failed"
child_session_record="$owner_link_dir/session-root"
mkfifo "$owner_link_fifo" || {
  cleanup_child
  echo "watcher: FAILED - could not create arm ownership channel"
  exit 1
}
exec 9<> "$owner_link_fifo" || {
  cleanup_child
  echo "watcher: FAILED - could not open arm ownership channel"
  exit 1
}
owner_link_connected=true
exec 8< "$owner_link_fifo" || {
  cleanup_child
  echo "watcher: FAILED - could not inherit arm ownership channel"
  exit 1
}
owner_link_reader_connected=true
(
  exec 9>&-
  FM_WATCHER_OWN_SESSION=1 \
    FM_WATCH_ARM_OWNER_DIR="$owner_link_dir" \
    FM_WATCH_ARM_OWNER_FIFO="$owner_link_fifo" \
    FM_WATCH_ARM_OWNER_READY="$owner_link_ready" \
    FM_WATCH_ARM_OWNER_FAILED="$owner_link_failed" \
    FM_WATCH_ARM_SESSION_RECORD="$child_session_record" \
    FM_WATCH_ARM_OWNER_FD=8 \
    exec perl -MPOSIX -e '
      my $cleanup = shift @ARGV;
      my $session = POSIX::setsid();
      exit 126 if !defined $session || $session != $$;
      my $root = $$;
      my $observer = fork();
      exit 125 if !defined $observer;
      if ($observer == 0) {
        $SIG{HUP} = "IGNORE";
        $SIG{INT} = "IGNORE";
        $SIG{TERM} = "IGNORE";
        open my $owner, "<&=8" or exit 125;
        while (getppid() == $root) {
          my $readable = "";
          vec($readable, fileno($owner), 1) = 1;
          my $ready = select($readable, undef, undef, 1);
          next if !defined $ready || $ready == 0;
          my $count = sysread($owner, my $byte, 1);
          last if !defined $count || $count == 0;
        }
        close $owner;
        exec $cleanup, $root, $session, $ENV{FM_WATCH_ARM_OWNER_DIR};
        exit 125;
      }
      exec @ARGV;
      exit 127;
    ' "$SCRIPT_DIR/fm-watch-session-cleanup.sh" "$WATCH"
) >"$child_out" 2>&1 &
child=$!
child_identity=$(fm_pid_identity "$child" 2>/dev/null || true)
owner_link_reader_disconnect
child_done=0

# Verify the outcome: poll until this child is the confirmed healthy watcher, or
# until some other watcher legitimately holds the singleton (a startup race), or
# until the child gives up. Only then print the honest line.
deadline=$(( $(date +%s) + CONFIRM_TIMEOUT ))
while :; do
  capture_child_session_handshake >/dev/null 2>&1 || true
  if "$child_session_verified" \
    && [ "${FM_WATCH_OWNER_TEST_HOOKS:-}" = firstmate-watcher-owner-tests-v1 ] \
    && [ -n "${FM_WATCH_OWNER_TEST_REUSED_SESSION_PID:-}" ]; then
    original_child=$child
    stop_recorded_watcher "$original_child" "$child_session_identity" >/dev/null 2>&1 || true
    wait "$original_child" 2>/dev/null || true
    child=$FM_WATCH_OWNER_TEST_REUSED_SESSION_PID
    stop_owned_child >/dev/null 2>&1 || true
    exit 1
  fi
  if healthy_watcher; then
    if [ "$HEALTHY_PID" = "$child" ]; then
      if ! "$child_session_verified" \
        || ! fm_watcher_lock_session_matches_pid "$STATE" "$WATCH" "$FM_HOME" "$child"; then
        echo "watcher: FAILED - started watcher did not establish its owned process session"
        cleanup_child
        exit 1
      fi
      if [ "$(cat "$owner_link_ready" 2>/dev/null || true)" != "$child" ]; then
        [ "$(date +%s)" -ge "$deadline" ] && break
        sleep 0.05
        continue
      fi
      child_session_verified=true
      echo "watcher: started pid=$child (beacon fresh)"
      monitor_started_child "$child"
      rc=$?
      exit "$rc"
    fi
    # Another watcher won the singleton; our child stood down.
    if [ "$mode" = arm ]; then
      report_attached
      wait "$child" 2>/dev/null || true
      owner_link_disconnect
      owner_link_remove
      rm -f "$child_out" 2>/dev/null || true
      child=
      child_out=
      trap - HUP TERM INT
      attach_and_wait "$HEALTHY_PID"
    fi
    report_healthy
    wait "$child" 2>/dev/null || true
    owner_link_disconnect
    owner_link_remove
    rm -f "$child_out" 2>/dev/null || true
    exit 0
  fi
  if [ "$child_done" -eq 0 ] && ! fm_pid_alive "$child"; then
    wait "$child"
    rc=$?
    child_done=1
    if [ "$rc" -eq 0 ] && watch_output_has_wake "$child_out"; then
      owner_link_disconnect
      owner_link_remove
      print_watch_output "$child_out"
      rm -f "$child_out" 2>/dev/null || true
      exit 0
    fi
  fi
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 0.2
done

trap - HUP TERM INT
echo "watcher: FAILED - no live watcher with a fresh beacon"
print_watch_output "$child_out"
cleanup_child
wait "$child" 2>/dev/null || true
exit 1
