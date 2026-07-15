#!/usr/bin/env bash
# Reconcile Agent Fleet's real SessionStart mapping into Firstmate task meta.
# Usage: fm-account-session-sync.sh <task-id> [--wait <seconds>] [--require] [--updated-at] [--after-updated-at <timestamp>]
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
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
# shellcheck source=bin/fm-account-routing-lib.sh
. "$SCRIPT_DIR/fm-account-routing-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

WAIT=0
QUERY_TIMEOUT=${FM_ACCOUNT_SESSION_QUERY_TIMEOUT:-5}
REQUIRE=0
ALL=0
PRINT_UPDATED_AT=0
AFTER_UPDATED_AT=
ID=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --all) ALL=1; shift ;;
    --require) REQUIRE=1; shift ;;
    --updated-at) PRINT_UPDATED_AT=1; shift ;;
    --after-updated-at)
      [ "$#" -gt 1 ] || { echo "error: --after-updated-at requires a timestamp" >&2; exit 2; }
      AFTER_UPDATED_AT=$2
      shift 2
      ;;
    --after-updated-at=*) AFTER_UPDATED_AT=${1#--after-updated-at=}; shift ;;
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
case "$QUERY_TIMEOUT" in ''|*[!0-9]*|0) echo "error: FM_ACCOUNT_SESSION_QUERY_TIMEOUT must be a positive integer" >&2; exit 2 ;; esac
session_timestamp_advances() {  # <candidate> <baseline>
  LC_ALL=C awk -v candidate="$1" -v baseline="$2" '
    function valid(value) {
      return value ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]([.][0-9]+)?Z$/
    }
    function whole(value) {
      sub(/[.][0-9]+Z$/, "Z", value)
      return value
    }
    function fraction(value, result) {
      if (value !~ /[.][0-9]+Z$/) return "0"
      result = value
      sub(/^.*[.]/, "", result)
      sub(/Z$/, "", result)
      return result
    }
    BEGIN {
      if (!valid(candidate) || !valid(baseline)) exit 2
      if (whole(candidate) > whole(baseline)) exit 0
      if (whole(candidate) < whole(baseline)) exit 1
      candidate_fraction = fraction(candidate)
      baseline_fraction = fraction(baseline)
      while (length(candidate_fraction) < length(baseline_fraction)) candidate_fraction = candidate_fraction "0"
      while (length(baseline_fraction) < length(candidate_fraction)) baseline_fraction = baseline_fraction "0"
      exit !("x" candidate_fraction > "x" baseline_fraction)
    }
  '
}
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
case "$AFTER_UPDATED_AT" in *$'\n'*|*=*) echo "error: unsafe --after-updated-at value" >&2; exit 2 ;; esac
META="$STATE/$ID.meta"
LIFECYCLE_LOCK=
LIFECYCLE_LOCK_OWNED=0
META_LOCK=
META_TMP=
META_ROLLBACK_TMP=
if [ -n "${FM_ACCOUNT_LIFECYCLE_LOCK_HELD:-}" ]; then
  expected_lifecycle_lock="$STATE/.account-lifecycle-$ID.lock"
  if [ "$FM_ACCOUNT_LIFECYCLE_LOCK_HELD" != "$expected_lifecycle_lock" ] \
    || ! fm_account_lifecycle_lock_held "$FM_ACCOUNT_LIFECYCLE_LOCK_HELD"; then
    echo "error: invalid inherited account lifecycle lock for $ID" >&2
    exit 1
  fi
  LIFECYCLE_LOCK=$FM_ACCOUNT_LIFECYCLE_LOCK_HELD
else
  LIFECYCLE_LOCK=$(fm_account_lifecycle_lock_acquire "$STATE" "$ID") || exit 1
  LIFECYCLE_LOCK_OWNED=1
fi
release_locks() {
  [ -z "$META_TMP" ] || rm -f "$META_TMP"
  [ -z "$META_ROLLBACK_TMP" ] || rm -f "$META_ROLLBACK_TMP"
  [ -z "$META_LOCK" ] || fm_account_meta_lock_release "$META_LOCK" >/dev/null 2>&1 || true
  [ "$LIFECYCLE_LOCK_OWNED" != 1 ] || fm_account_lifecycle_lock_release "$LIFECYCLE_LOCK" >/dev/null 2>&1 || true
}
trap release_locks EXIT
META_LOCK=$(fm_account_meta_lock_acquire "$STATE" "$ID") || exit 1
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
PROFILE=$(fm_meta_get "$META" account_profile)
[ -n "$PROFILE" ] || { fm_account_meta_lock_release "$META_LOCK" || exit 1; exit 0; }
POOL=$(fm_meta_get "$META" account_pool)
HARNESS=$(fm_meta_get "$META" harness)
ACCOUNT_TASK=$(fm_meta_get "$META" account_task)
ATTEMPT=$(fm_meta_get "$META" account_attempt)
[ -n "$ACCOUNT_TASK" ] || ACCOUNT_TASK=$ID
[ -n "$ATTEMPT" ] || ATTEMPT=legacy
EXISTING=$(fm_meta_get "$META" provider_session_id)
fm_account_meta_lock_release "$META_LOCK" || exit 1
binary=$(fm_account_fleet_bin) || exit 1
fm_account_validate_contract "$binary" || exit 1

deadline=$(( $(date +%s) + WAIT ))
while :; do
  if json=$(fm_account_run_bounded "$QUERY_TIMEOUT" "$binary" --format json session status --task "$ACCOUNT_TASK" 2>/dev/null); then
    mapped_task=$(fm_account_json_field "$json" '.task | select(type == "string")' session) || exit 1
    mapped_profile=$(fm_account_json_field "$json" '.profile | select(type == "string")' session) || exit 1
    mapped_provider=$(fm_account_json_field "$json" '.provider | select(type == "string")' session) || exit 1
    mapped_pool=$(fm_account_json_field "$json" '.pool | select(type == "string")' session) || exit 1
    session_id=$(fm_account_json_field "$json" '.session_id | select(type == "string" and length > 0)' session) || exit 1
    updated_at=$(fm_account_json_field "$json" '.updated_at | select(type == "string" and length > 0)' session) || exit 1
    [ "$mapped_task" = "$ACCOUNT_TASK" ] || { echo "error: Agent Fleet session task mismatch for $ID attempt $ATTEMPT" >&2; exit 1; }
    [ "$mapped_profile" = "$PROFILE" ] || { echo "error: Agent Fleet session profile mismatch for $ID" >&2; exit 1; }
    [ "$mapped_pool" = "$POOL" ] || { echo "error: Agent Fleet session pool mismatch for $ID" >&2; exit 1; }
    [ "$mapped_provider" = "$HARNESS" ] || { echo "error: Agent Fleet session provider mismatch for $ID" >&2; exit 1; }
    case "$session_id" in ''|*$'\n'*|*=*) echo "error: unsafe provider session id for $ID" >&2; exit 1 ;; esac
    case "$updated_at" in ''|*$'\n'*|*=*) echo "error: unsafe provider session update timestamp for $ID" >&2; exit 1 ;; esac
    if [ -z "$AFTER_UPDATED_AT" ]; then
      break
    fi
    if session_timestamp_advances "$updated_at" "$AFTER_UPDATED_AT"; then
      break
    else
      timestamp_status=$?
      [ "$timestamp_status" -ne 2 ] || { echo "error: invalid Agent Fleet session update timestamp for $ID" >&2; exit 1; }
    fi
  fi
  [ "$(date +%s)" -lt "$deadline" ] || {
    if [ "$REQUIRE" = 1 ]; then
      if [ -n "$AFTER_UPDATED_AT" ]; then
        echo "error: no fresh Agent Fleet SessionStart update for managed task $ID attempt $ATTEMPT; refusing recovery" >&2
      else
        echo "error: no Agent Fleet provider-session mapping for managed task $ID attempt $ATTEMPT; refusing recovery" >&2
      fi
    fi
    exit 1
  }
  sleep 1
done
META_LOCK=$(fm_account_meta_lock_acquire "$STATE" "$ID") || exit 1
current_account_task=$(fm_meta_get "$META" account_task)
current_attempt=$(fm_meta_get "$META" account_attempt)
[ -n "$current_account_task" ] || current_account_task=$ID
[ -n "$current_attempt" ] || current_attempt=legacy
if [ ! -f "$META" ] \
  || [ "$current_account_task" != "$ACCOUNT_TASK" ] \
  || [ "$current_attempt" != "$ATTEMPT" ] \
  || [ "$(fm_meta_get "$META" account_profile)" != "$PROFILE" ] \
  || [ "$(fm_meta_get "$META" account_pool)" != "$POOL" ] \
  || [ "$(fm_meta_get "$META" harness)" != "$HARNESS" ]; then
  fm_account_meta_lock_release "$META_LOCK" >/dev/null 2>&1 || true
  echo "error: managed task generation changed before session synchronization for $ID" >&2
  exit 1
fi
EXISTING=$(fm_meta_get "$META" provider_session_id)
if [ -n "$EXISTING" ] && [ "$EXISTING" != "$session_id" ]; then
  fm_account_meta_lock_release "$META_LOCK" >/dev/null 2>&1 || true
  echo "error: provider session id changed for managed task $ID; refusing to overwrite recovery truth" >&2
  exit 1
fi
if [ -z "$EXISTING" ]; then
  META_TMP="$STATE/.$ID.meta.sync.$$"
  META_ROLLBACK_TMP="$STATE/.$ID.meta.sync-rollback.$$"
  awk '!/^provider_session_id=/' "$META" > "$META_ROLLBACK_TMP" || exit 1
  cp -p "$META_ROLLBACK_TMP" "$META_TMP" || exit 1
  printf 'provider_session_id=%s\n' "$session_id" >> "$META_TMP" || { rm -f "$META_TMP"; exit 1; }
  mv "$META_TMP" "$META" || { rm -f "$META_TMP"; exit 1; }
  META_TMP=
  if ! fm_account_lineage_append "$DATA" "$ID" session-bound "$ATTEMPT" "$ACCOUNT_TASK" "$HARNESS" "$POOL" "$PROFILE" "$session_id" "$(fm_meta_get "$META" account_predecessor_task)"; then
    if mv "$META_ROLLBACK_TMP" "$META"; then
      META_ROLLBACK_TMP=
    else
      echo "error: session lineage failed and prior metadata could not be restored for $ID" >&2
      exit 1
    fi
    echo "error: session lineage publication failed; restored unbound metadata for $ID" >&2
    exit 1
  fi
  rm -f "$META_ROLLBACK_TMP"
  META_ROLLBACK_TMP=
fi
fm_account_meta_lock_release "$META_LOCK" || exit 1
if [ "$PRINT_UPDATED_AT" = 1 ]; then
  printf '%s\n' "$updated_at"
else
  printf '%s\n' "$session_id"
fi
