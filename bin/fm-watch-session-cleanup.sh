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

case "$root" in ''|*[!0-9]*) exit 2 ;; esac
[ "$session" = "$root" ] || exit 2
case "$owner_dir" in "$STATE"/.watch-arm-owner.*) ;; *) exit 2 ;; esac
[ -d "$owner_dir" ] && [ ! -L "$owner_dir" ] || exit 2
[ "$(fm_pid_session "$observer" 2>/dev/null || true)" = "$session" ] || exit 1

status=0
fm_session_stop_owned_except "$session" "$observer" 30 || status=$?
if [ "$status" -eq 0 ] \
  && [ "$(cat "$lockdir/pid" 2>/dev/null || true)" = "$session" ] \
  && [ "$(cat "$lockdir/process-session" 2>/dev/null || true)" = "$session" ] \
  && [ "$(cat "$lockdir/fm-home" 2>/dev/null || true)" = "$FM_HOME" ] \
  && [ "$(cat "$lockdir/watcher-path" 2>/dev/null || true)" = "$watch_path" ]; then
  rm -f "$lockdir/process-session" 2>/dev/null || status=1
  [ "$status" -ne 0 ] || fm_lock_remove_path "$lockdir" || status=1
fi
if [ "$status" -eq 0 ]; then
  exec 8<&-
  rm -f "$owner_dir/ready" "$owner_dir/failed" "$owner_dir/control" \
    "$owner_dir/eof" "$owner_dir/lost" "$owner_dir/session-root" \
    "$owner_dir/session-root.pending" 2>/dev/null || true
  rmdir "$owner_dir" 2>/dev/null || true
fi
exit "$status"
