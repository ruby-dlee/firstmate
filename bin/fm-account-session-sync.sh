#!/usr/bin/env bash
# Reconcile Agent Fleet's real SessionStart mapping into Firstmate task meta.
# Usage: fm-account-session-sync.sh <task-id> [--wait <seconds>] [--require]
#        fm-account-session-sync.sh --all
#
# Only managed tasks (meta with account_profile=) are touched.
# The command consumes `agent-fleet --format json session status --task` and
# validates attempt/task/profile/provider/pool stickiness before atomically
# recording the real provider_session_id= in meta.
# An early SessionStart race is normal: without --require, no mapping returns
# quietly non-zero so spawn or the watcher can retry later.
# --require turns the missing mapping into a fail-closed recovery blocker.
# --all scans only managed metas that still lack provider_session_id.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-account-routing-lib.sh
. "$SCRIPT_DIR/fm-account-routing-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

WAIT=0
REQUIRE=0
ALL=0
ID=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --all) ALL=1; shift ;;
    --require) REQUIRE=1; shift ;;
    --wait)
      [ "$#" -gt 1 ] || { echo "error: --wait requires seconds" >&2; exit 2; }
      WAIT=$2
      shift 2
      ;;
    --wait=*) WAIT=${1#--wait=}; shift ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "error: unknown option $1" >&2; exit 2 ;;
    *) [ -z "$ID" ] || { echo "error: expected one task id" >&2; exit 2; }; ID=$1; shift ;;
  esac
done
case "$WAIT" in ''|*[!0-9]*) echo "error: --wait must be a non-negative integer" >&2; exit 2 ;; esac
if [ "$ALL" = 1 ]; then
  [ -z "$ID" ] || { echo "error: --all does not accept a task id" >&2; exit 2; }
  rc=0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    [ -n "$(fm_meta_get "$meta" account_profile)" ] || continue
    [ -z "$(fm_meta_get "$meta" provider_session_id)" ] || continue
    task=$(basename "$meta" .meta)
    "$0" "$task" >/dev/null 2>&1 || rc=1
  done
  exit "$rc"
fi
[ -n "$ID" ] || { echo "usage: fm-account-session-sync.sh <task-id> [--wait <seconds>] [--require]" >&2; exit 2; }
META="$STATE/$ID.meta"
META_LOCK=$(fm_account_meta_lock_acquire "$STATE" "$ID") || exit 1
release_meta_lock() {
  fm_account_meta_lock_release "$META_LOCK" >/dev/null 2>&1 || true
}
trap release_meta_lock EXIT
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
PROFILE=$(fm_meta_get "$META" account_profile)
[ -n "$PROFILE" ] || exit 0
POOL=$(fm_meta_get "$META" account_pool)
HARNESS=$(fm_meta_get "$META" harness)
ACCOUNT_TASK=$(fm_meta_get "$META" account_task)
ATTEMPT=$(fm_meta_get "$META" account_attempt)
[ -n "$ACCOUNT_TASK" ] || ACCOUNT_TASK=$ID
[ -n "$ATTEMPT" ] || ATTEMPT=legacy
EXISTING=$(fm_meta_get "$META" provider_session_id)
binary=$(fm_account_fleet_bin) || exit 1

deadline=$(( $(date +%s) + WAIT ))
while :; do
  if json=$("$binary" --format json session status --task "$ACCOUNT_TASK" 2>/dev/null); then
    break
  fi
  [ "$(date +%s)" -lt "$deadline" ] || {
    if [ "$REQUIRE" = 1 ]; then
      echo "error: no Agent Fleet provider-session mapping for managed task $ID attempt $ATTEMPT; refusing recovery" >&2
    fi
    exit 1
  }
  sleep 1
done

mapped_task=$(fm_account_json_field "$json" '.task | select(type == "string")' session) || exit 1
mapped_profile=$(fm_account_json_field "$json" '.profile | select(type == "string")' session) || exit 1
mapped_provider=$(fm_account_json_field "$json" '.provider | select(type == "string")' session) || exit 1
mapped_pool=$(fm_account_json_field "$json" '.pool | select(type == "string")' session) || exit 1
session_id=$(fm_account_json_field "$json" '.session_id | select(type == "string" and length > 0)' session) || exit 1
[ "$mapped_task" = "$ACCOUNT_TASK" ] || { echo "error: Agent Fleet session task mismatch for $ID attempt $ATTEMPT" >&2; exit 1; }
[ "$mapped_profile" = "$PROFILE" ] || { echo "error: Agent Fleet session profile mismatch for $ID" >&2; exit 1; }
[ "$mapped_pool" = "$POOL" ] || { echo "error: Agent Fleet session pool mismatch for $ID" >&2; exit 1; }
[ "$mapped_provider" = "$HARNESS" ] || { echo "error: Agent Fleet session provider mismatch for $ID" >&2; exit 1; }
case "$session_id" in ''|*$'\n'*|*=*) echo "error: unsafe provider session id for $ID" >&2; exit 1 ;; esac
if [ -n "$EXISTING" ] && [ "$EXISTING" != "$session_id" ]; then
  echo "error: provider session id changed for managed task $ID; refusing to overwrite recovery truth" >&2
  exit 1
fi
if [ -z "$EXISTING" ]; then
  META_TMP="$STATE/.$ID.meta.sync.$$"
  awk '!/^provider_session_id=/' "$META" > "$META_TMP" || { rm -f "$META_TMP"; exit 1; }
  printf 'provider_session_id=%s\n' "$session_id" >> "$META_TMP"
  mv "$META_TMP" "$META"
  fm_account_lineage_append "$DATA" "$ID" session-bound "$ATTEMPT" "$ACCOUNT_TASK" "$HARNESS" "$POOL" "$PROFILE" "$session_id" "$(fm_meta_get "$META" account_predecessor_task)" || exit 1
fi
printf '%s\n' "$session_id"
