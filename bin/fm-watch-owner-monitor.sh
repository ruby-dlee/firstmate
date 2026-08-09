#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

[ "$#" -eq 5 ] || exit 2
watcher_pid=$1
owner_fifo=$2
owner_ready=$3
owner_failed=$4
owner_dir=$5
watch_path="$SCRIPT_DIR/fm-watch.sh"
watch_lock="$STATE/.watch.lock"
monitor_pid=$$
owner_eof="$owner_dir/eof"
owner_lost="$owner_dir/lost"
session_record="$owner_dir/session-root"
session_record_pending="$owner_dir/session-root.pending"
anchor_pending="$watch_lock/session-anchor.pending"
anchor_record="$watch_lock/session-anchor"
owner_root_poll=5
owner_link_lost=false

case "$watcher_pid" in ''|*[!0-9]*) exit 2 ;; esac
case "$owner_dir" in "$STATE"/.watch-arm-owner.*) ;; *) exit 2 ;; esac
[ -d "$owner_dir" ] && [ ! -L "$owner_dir" ] || exit 2
[ "$owner_fifo" = "$owner_dir/control" ] && [ -p "$owner_fifo" ] || exit 2
[ "$owner_ready" = "$owner_dir/ready" ] || exit 2
[ "$owner_failed" = "$owner_dir/failed" ] || exit 2
[ "$(fm_pid_session "$monitor_pid" 2>/dev/null || true)" = "$watcher_pid" ] || exit 1
fm_watcher_lock_session_record_matches "$STATE" "$watch_path" "$FM_HOME" "$watcher_pid" || exit 1
watcher_identity=$(cat "$watch_lock/pid-identity" 2>/dev/null || true)
[ -n "$watcher_identity" ] || exit 1
monitor_identity=$(fm_pid_identity "$monitor_pid") || exit 1

owner_link_current() {
  local timeout=$1 read_status=0 started=$SECONDS elapsed
  IFS= read -r -t "$timeout" _ <&8 || read_status=$?
  [ "$read_status" -ne 0 ] || return 0
  elapsed=$((SECONDS - started))
  [ "$elapsed" -ge "$timeout" ] || return 1
  [ "$PPID" = "$watcher_pid" ] || return 1
  fm_pid_identity_live "$watcher_pid" "$watcher_identity"
}

monitor_exit_cleanup() {
  rm -f "$anchor_pending" "$owner_eof" "$owner_lost" 2>/dev/null || true
}

trap monitor_exit_cleanup EXIT
trap 'exit 143' HUP TERM INT

if [ "${FM_WATCH_OWNER_TEST_HOOKS:-}" = firstmate-watcher-owner-tests-v1 ] \
  && [ -n "${FM_WATCH_OWNER_TEST_EXIT_READY:-}" ] \
  && [ -n "${FM_WATCH_OWNER_TEST_EXIT_PROCEED:-}" ]; then
  : > "$FM_WATCH_OWNER_TEST_EXIT_READY"
  while [ ! -e "$FM_WATCH_OWNER_TEST_EXIT_PROCEED" ]; do
    owner_link_current 1 || exit 1
  done
  exit 1
fi

[ ! -e "$anchor_pending" ] && [ ! -L "$anchor_pending" ] || exit 1
[ ! -e "$anchor_record" ] && [ ! -L "$anchor_record" ] || exit 1
printf 'pid=%s\nidentity=%s\n' "$monitor_pid" "$monitor_identity" > "$anchor_pending" || exit 1
if [ "${FM_WATCH_OWNER_TEST_HOOKS:-}" = firstmate-watcher-owner-tests-v1 ] \
  && [ -n "${FM_WATCH_OWNER_TEST_PUBLISH_READY:-}" ] \
  && [ -n "${FM_WATCH_OWNER_TEST_PUBLISH_PROCEED:-}" ]; then
  : > "$FM_WATCH_OWNER_TEST_PUBLISH_READY"
  while [ ! -e "$FM_WATCH_OWNER_TEST_PUBLISH_PROCEED" ]; do
    if ! owner_link_current 1; then
      owner_link_lost=true
      break
    fi
  done
fi
mv -f "$anchor_pending" "$anchor_record" || exit 1
fm_watcher_lock_session_anchor_matches "$STATE" "$watcher_pid" || exit 1
[ "$FM_WATCHER_SESSION_ANCHOR_PID" = "$monitor_pid" ] || exit 1
printf '%s\n' "$watcher_pid" > "$owner_ready" || exit 1

if ! "$owner_link_lost"; then
  while owner_link_current "$owner_root_poll"; do :; done
fi
: > "$owner_eof" 2>/dev/null || true
: > "$owner_lost" 2>/dev/null || true
: > "$owner_failed" 2>/dev/null || true
status=0
fm_session_stop_owned_except "$watcher_pid" "$monitor_pid" 30 || status=$?
if [ "$status" -eq 0 ] \
  && fm_watcher_lock_owner_record_matches \
    "$STATE" "$watch_path" "$FM_HOME" "$watcher_pid" "$watcher_identity" \
  && fm_watcher_lock_session_anchor_matches "$STATE" "$watcher_pid" \
  && [ "$FM_WATCHER_SESSION_ANCHOR_PID" = "$monitor_pid" ]; then
  rm -f "$watch_lock/process-session" 2>/dev/null || status=1
  [ "$status" -ne 0 ] || fm_lock_remove_path "$watch_lock" || status=1
fi
exec 8<&-
rm -f "$owner_ready" "$owner_failed" "$owner_fifo" "$owner_eof" "$owner_lost" 2>/dev/null || true
rm -f "$session_record" "$session_record_pending" 2>/dev/null || true
rmdir "$owner_dir" 2>/dev/null || true
exit "$status"
