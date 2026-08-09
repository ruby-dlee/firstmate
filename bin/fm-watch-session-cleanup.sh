#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-wake-lib.sh"

[ "$#" -eq 3 ] || exit 2
root=$1
session=$2
owner_dir=$3
watch_path="$SCRIPT_DIR/fm-watch.sh"
lockdir="$STATE/.watch.lock"
observer=${BASHPID:-$$}
arm_owner=
arm_owner_identity=
observer_identity=

case "$root" in ''|*[!0-9]*) exit 2 ;; esac
[ "$session" = "$root" ] || exit 2
case "$owner_dir" in "$STATE"/.watch.lock.owner.arm.*) ;; *) exit 2 ;; esac
[ -d "$owner_dir" ] && [ ! -L "$owner_dir" ] || exit 2
[ "$(fm_pid_session "$observer" 2>/dev/null || true)" = "$session" ] || exit 1
arm_owner=$(cat "$owner_dir/arm-owner-pid" 2>/dev/null || true)
arm_owner_identity=$(cat "$owner_dir/arm-owner-identity" 2>/dev/null || true)
case "$arm_owner" in ''|*[!0-9]*) exit 1 ;; esac
[ -n "$arm_owner_identity" ] || exit 1
fm_watcher_prestart_owner_read "$owner_dir" || exit 1
[ "$FM_WATCHER_PRESTART_OWNER_PID" = "$observer" ] || exit 1
observer_identity=$FM_WATCHER_PRESTART_OWNER_IDENTITY
fm_pid_identity_live "$observer" "$observer_identity" || exit 1

while fm_pid_identity_live "$arm_owner" "$arm_owner_identity"; do
  if fm_session_stop_claim_completed_dir "$owner_dir" "$session" "$observer"; then
    exec 8<&-
    exit 0
  fi
  sleep 0.05
done

status=0
if [ "$(cat "$owner_dir/pid" 2>/dev/null || true)" = "$session" ] \
  && [ "$(cat "$owner_dir/process-session" 2>/dev/null || true)" = "$session" ] \
  && [ "$(cat "$owner_dir/fm-home" 2>/dev/null || true)" = "$FM_HOME" ] \
  && [ "$(cat "$owner_dir/watcher-path" 2>/dev/null || true)" = "$watch_path" ] \
  && { [ ! -e "$lockdir" ] && [ ! -L "$lockdir" ] \
    || fm_lock_points_to_owner "$lockdir" "$owner_dir"; } \
  && fm_session_stop_claim_dir "$owner_dir" "$session"; then
  if [ "${FM_WATCH_OWNER_TEST_HOOKS:-}" = firstmate-watcher-owner-tests-v1 ] \
    && [ -n "${FM_WATCH_OWNER_TEST_CLAIM_READY:-}" ] \
    && [ -n "${FM_WATCH_OWNER_TEST_CLAIM_PROCEED:-}" ]; then
    : > "$FM_WATCH_OWNER_TEST_CLAIM_READY"
    while [ ! -e "$FM_WATCH_OWNER_TEST_CLAIM_PROCEED" ]; do sleep 0.01; done
  fi
  fm_session_stop_owned_except "$session" "$observer" 30 || status=$?
  [ "$status" -ne 0 ] || fm_session_stop_claim_complete_dir \
    "$owner_dir" "$session" "$observer" || status=$?
else
  status=1
fi
if [ "$status" -eq 0 ] \
  && { [ -e "$lockdir" ] || [ -L "$lockdir" ]; } \
  && fm_lock_points_to_owner "$lockdir" "$owner_dir"; then
  rm -f "$lockdir/process-session" 2>/dev/null || status=1
  [ "$status" -ne 0 ] || fm_lock_remove_path "$lockdir" || status=1
fi
if [ "$status" -eq 0 ]; then
  exec 8<&-
  rm -f "$owner_dir/ready" "$owner_dir/failed" "$owner_dir/control" \
    "$owner_dir/eof" "$owner_dir/lost" "$owner_dir/session-root" \
    "$owner_dir/session-root.pending" "$owner_dir/handoff-request" \
    "$owner_dir/handoff-request.pending" "$owner_dir/handoff-taken" \
    "$owner_dir/handoff-taken.pending" "$owner_dir/prestart-owner" \
    "$owner_dir/prestart-owner.pending" "$owner_dir/prestart-owner-ack" \
    "$owner_dir/prestart-owner-ack.pending" 2>/dev/null || true
  rm -f "$owner_dir/pid" "$owner_dir/pid-identity" "$owner_dir/process-session" \
    "$owner_dir/fm-home" "$owner_dir/watcher-path" "$owner_dir/session-stop" \
    "$owner_dir/session-stop.pending" "$owner_dir/session-stop-complete" \
    "$owner_dir/.session-stop-transaction" \
    "$owner_dir/arm-owner-pid" "$owner_dir/arm-owner-identity" 2>/dev/null || true
  rmdir "$owner_dir" 2>/dev/null || true
fi
exit "$status"
