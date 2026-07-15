#!/usr/bin/env bash
# fm-afk-launch.sh - the single owner of the away-mode daemon TERMINAL lifecycle:
# launch it in a NON-VISIBLE tracked terminal per backend, record its exact id,
# tear it down by that exact id, and reconcile a leaked one after a crash.
#
# Why this exists (docs/herdr-backend.md "Away-mode daemon terminal launch"):
# bin/fm-afk-start.sh execs the supervise daemon in the FOREGROUND of whatever
# terminal it is already in. Harnesses with a native in-pane tracked-background
# tool (claude, grok) run it there directly and it is fine. A harness with NO
# native background mechanism (pi) has to manufacture a terminal, and doing that
# by SPLITTING the captain's active pane visibly shrinks it - the regression this
# script fixes. Instead this creates a non-visible tracked terminal (a herdr tab/
# workspace with --no-focus, or a detached tmux session) that never touches the
# captain's active tab, and NEVER uses shell `&` (which herdr/codex can reap).
#
# Correct supervisor targeting: the daemon finds the captain pane to inject into
# from its OWN inherited env (discover_supervisor_target). Running it in a
# separate terminal would make it discover its OWN pane, so this captures the
# captain pane FIRST (from the pane this script runs in) and passes it in as
# FM_SUPERVISOR_TARGET/FM_SUPERVISOR_BACKEND explicitly.
#
# Usage:
#   fm-afk-launch.sh start     Capture the captain pane, then (unless the daemon
#                              is already running) launch the daemon in a fresh
#                              non-visible terminal for the detected backend and
#                              record it. Idempotent: an already-running daemon
#                              just refreshes state/.afk; a recorded-but-dead
#                              terminal is reconciled (closed by id) first.
#   fm-afk-launch.sh start-native
#                              Prepare lifecycle state for a harness-native
#                              background job and record that no terminal exists.
#   fm-afk-launch.sh stop      Correct-ordered exit: SIGTERM the daemon so its
#                              cleanup flushes WHILE state/.afk is still present,
#                              wait for it, close the recorded terminal by exact
#                              id, then clear state/.afk last.
#   fm-afk-launch.sh reconcile Close a recorded-but-dead daemon terminal by exact
#                              id and drop the record (recovery after a crash).
#
# Supported backends: herdr, tmux. Others (zellij, orca, cmux) have no verified
# non-visible-launch primitive here yet and refuse loudly.
#
# Test seam: FM_AFK_LAUNCH_ENTRY overrides the command run in the created
# terminal (default bin/fm-afk-start.sh), so a topology test can run a harmless
# placeholder instead of a real daemon. FM_SUPERVISOR_TARGET/FM_SUPERVISOR_BACKEND
# override the captured captain pane/backend (an isolated lab pane in tests).
set -u

FM_AFK_LAUNCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_AFK_LAUNCH_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_AFK_LAUNCH_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_AFK_LAUNCH_RECORD="$FM_AFK_LAUNCH_STATE/.afk-daemon-terminal"
FM_AFK_LAUNCH_LOCK="$FM_AFK_LAUNCH_STATE/.afk-launch.lock"
FM_AFK_LAUNCH_WS_LABEL="firstmate-afk-daemon"

# shellcheck source=bin/fm-backend.sh
. "$FM_AFK_LAUNCH_DIR/fm-backend.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$FM_AFK_LAUNCH_DIR/fm-supervisor-target-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$FM_AFK_LAUNCH_DIR/fm-gate-refuse-lib.sh"
# fm-afk-start.sh provides the daemon-lock liveness helpers and
# fm_afk_clear_stale_artifacts; it is sourceable (BASH_SOURCE guard) and its
# main does not run on source. It sets `set -eu`, so turn errexit back off for
# this script's best-effort flow immediately after.
# shellcheck source=bin/fm-afk-start.sh
. "$FM_AFK_LAUNCH_DIR/fm-afk-start.sh"
set +e

fm_afk_launch_log() { printf 'fm-afk-launch: %s\n' "$*" >&2; }

fm_afk_launch_state_prepare() {
  mkdir -p "$FM_AFK_LAUNCH_STATE" || return 1
  [ -d "$FM_AFK_LAUNCH_STATE" ] && [ ! -L "$FM_AFK_LAUNCH_STATE" ]
}

FM_AFK_LAUNCH_LOCK_TOKEN=

fm_afk_launch_path_identity() {
  if [ "$(uname)" = Darwin ]; then
    stat -f '%d:%i:%B' "$1" 2>/dev/null
  else
    stat -c '%d:%i:%W' "$1" 2>/dev/null
  fi
}

fm_afk_launch_file_size() {
  if [ "$(uname)" = Darwin ]; then
    stat -f '%z' "$1" 2>/dev/null
  else
    stat -c '%s' "$1" 2>/dev/null
  fi
}

fm_afk_launch_copy_bounded() {  # <source> <destination>
  local source=$1 destination=$2 expected actual pending cap=1048576
  [ -f "$source" ] && [ ! -L "$source" ] || return 1
  expected=$(fm_afk_launch_file_size "$source") || return 1
  case "$expected" in ''|*[!0-9]*) return 1 ;; esac
  [ "$expected" -le "$cap" ] || return 1
  pending=$(mktemp "$destination.pending.XXXXXX") || return 1
  if ! head -c "$((cap + 1))" "$source" > "$pending" 2>/dev/null; then
    rm -f "$pending"
    return 1
  fi
  actual=$(LC_ALL=C wc -c < "$pending" | tr -d '[:space:]') || {
    rm -f "$pending"
    return 1
  }
  if [ "$actual" != "$expected" ] || [ ! -f "$source" ] || [ -L "$source" ] \
    || [ -L "$destination" ] || { [ -e "$destination" ] && [ ! -f "$destination" ]; }; then
    rm -f "$pending"
    return 1
  fi
  mv "$pending" "$destination" || { rm -f "$pending"; return 1; }
}

fm_afk_launch_read_control() {
  local file=$1 snapshot bytes cap=4096
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  snapshot=$({
    head -c "$((cap + 1))" "$file" 2>/dev/null || exit 1
    printf '\034'
  }) || return 1
  case "$snapshot" in *$'\034') ;; *) return 1 ;; esac
  snapshot=${snapshot%$'\034'}
  bytes=$(printf '%s' "$snapshot" | LC_ALL=C wc -c | tr -d '[:space:]') || return 1
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$bytes" -le "$cap" ] || return 1
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  printf '%s' "$snapshot"
}

fm_afk_launch_lock_owned() {
  local pid expected actual
  [ -d "$FM_AFK_LAUNCH_LOCK" ] && [ ! -L "$FM_AFK_LAUNCH_LOCK" ] || return 1
  pid=$(fm_afk_launch_read_control "$FM_AFK_LAUNCH_LOCK/pid") || return 1
  expected=$(fm_afk_launch_read_control "$FM_AFK_LAUNCH_LOCK/pid-identity") || return 1
  actual=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ -n "$expected" ] && [ "$actual" = "$expected" ]
}

fm_afk_launch_lock_identity() {
  [ -d "$FM_AFK_LAUNCH_LOCK" ] && [ ! -L "$FM_AFK_LAUNCH_LOCK" ] || return 1
  fm_afk_launch_path_identity "$FM_AFK_LAUNCH_LOCK"
}

fm_afk_launch_atomic_rename() {
  if command -v node >/dev/null 2>&1; then
    node -e 'try { require("node:fs").renameSync(process.argv[1], process.argv[2]); } catch { process.exit(1); }' "$1" "$2"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'exit(rename($ARGV[0], $ARGV[1]) ? 0 : 1)' "$1" "$2"
  else
    return 1
  fi
}

fm_afk_launch_reclaim_owned() {
  local reclaim=$1 pid expected actual
  [ -d "$reclaim" ] && [ ! -L "$reclaim" ] || return 1
  pid=$(fm_afk_launch_read_control "$reclaim/pid") || return 1
  expected=$(fm_afk_launch_read_control "$reclaim/pid-identity") || return 1
  actual=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ -n "$expected" ] && [ "$actual" = "$expected" ]
}

fm_afk_launch_lock_acquire() {
  local i incomplete=0 identity quarantine stale_identity claimed_identity last_identity=
  local candidate claim_candidate reclaim reclaim_identity token reclaim_token ownerless_grace
  ownerless_grace=${FM_AFK_LAUNCH_RECLAIM_GRACE_SECONDS:-1}
  case "$ownerless_grace" in ''|*[!0-9]*) return 1 ;; esac
  fm_afk_launch_state_prepare || return 1
  for i in $(seq 1 200); do
    if [ -L "$FM_AFK_LAUNCH_LOCK" ] \
      || { [ -e "$FM_AFK_LAUNCH_LOCK" ] && [ ! -d "$FM_AFK_LAUNCH_LOCK" ]; }; then
      fm_afk_launch_log "refusing unsafe launcher lock: $FM_AFK_LAUNCH_LOCK"
      return 1
    fi
    if [ ! -e "$FM_AFK_LAUNCH_LOCK" ]; then
      candidate=$(mktemp -d "$FM_AFK_LAUNCH_LOCK.candidate.XXXXXX" 2>/dev/null) || { sleep 0.05; continue; }
      token=${candidate##*.candidate.}
      identity=$(fm_pid_identity "$$" 2>/dev/null) || {
        rm -rf "$candidate"
        return 1
      }
      if [ -z "$identity" ] \
        || ! printf '%s' "$$" > "$candidate/pid" \
        || ! printf '%s' "$identity" > "$candidate/pid-identity" \
        || ! printf '%s' "$token" > "$candidate/token"; then
        rm -rf "$candidate"
        return 1
      fi
      if [ ! -e "$FM_AFK_LAUNCH_LOCK" ] && fm_afk_launch_atomic_rename "$candidate" "$FM_AFK_LAUNCH_LOCK"; then
        if [ "$(fm_afk_launch_read_control "$FM_AFK_LAUNCH_LOCK/token" 2>/dev/null || true)" = "$token" ]; then
          FM_AFK_LAUNCH_LOCK_TOKEN=$token
          return 0
        fi
        return 1
      fi
      rm -rf "$candidate" 2>/dev/null || true
    fi
    stale_identity=$(fm_afk_launch_lock_identity) || {
      sleep 0.05
      continue
    }
    if [ "$stale_identity" != "$last_identity" ]; then
      incomplete=0
      last_identity=$stale_identity
    fi
    if [ ! -s "$FM_AFK_LAUNCH_LOCK/pid" ] || [ ! -s "$FM_AFK_LAUNCH_LOCK/pid-identity" ]; then
      incomplete=$((incomplete + 1))
      if [ "$incomplete" -lt $((ownerless_grace * 20)) ]; then
        sleep 0.05
        continue
      fi
    else
      incomplete=0
    fi
    if ! fm_afk_launch_lock_owned; then
      reclaim="$FM_AFK_LAUNCH_LOCK/.reclaim"
      if [ -L "$reclaim" ] || { [ -e "$reclaim" ] && [ ! -d "$reclaim" ]; }; then
        fm_afk_launch_log "refusing unsafe launcher reclaim directory: $reclaim"
        return 1
      fi
      if [ -d "$reclaim" ]; then
        if fm_afk_launch_reclaim_owned "$reclaim" \
          || [ "$(fm_path_age "$reclaim" 2>/dev/null || echo 0)" -lt "$ownerless_grace" ]; then
          sleep 0.05
          continue
        fi
        reclaim_identity=$(fm_afk_launch_path_identity "$reclaim") || { sleep 0.05; continue; }
        if fm_afk_launch_atomic_rename "$reclaim" "$FM_AFK_LAUNCH_LOCK/.reclaim.stale.${reclaim_identity//:/_}.$$.$RANDOM"; then
          rm -rf "$FM_AFK_LAUNCH_LOCK"/.reclaim.stale."${reclaim_identity//:/_}".$$.* 2>/dev/null || true
        fi
        sleep 0.05
        continue
      fi
      reclaim_token="$$.$RANDOM.$i"
      claim_candidate="$FM_AFK_LAUNCH_LOCK/.reclaim-candidate.$reclaim_token"
      [ -d "$FM_AFK_LAUNCH_LOCK" ] && [ ! -L "$FM_AFK_LAUNCH_LOCK" ] || return 1
      mkdir "$claim_candidate" 2>/dev/null || { sleep 0.05; continue; }
      identity=$(fm_pid_identity "$$" 2>/dev/null) || {
        rm -rf "$claim_candidate"
        return 1
      }
      if [ -z "$identity" ] \
        || ! printf '%s' "$$" > "$claim_candidate/pid" \
        || ! printf '%s' "$identity" > "$claim_candidate/pid-identity" \
        || ! printf '%s' "$reclaim_token" > "$claim_candidate/token" \
        || ! fm_afk_launch_atomic_rename "$claim_candidate" "$reclaim"; then
        rm -rf "$claim_candidate" 2>/dev/null || true
        sleep 0.05
        continue
      fi
      claimed_identity=$(fm_afk_launch_lock_identity) || claimed_identity=
      if [ -z "$claimed_identity" ] || [ "$claimed_identity" != "$stale_identity" ]; then
        [ "$(fm_afk_launch_read_control "$reclaim/token" 2>/dev/null || true)" != "$reclaim_token" ] || rm -rf "$reclaim" 2>/dev/null || true
        sleep 0.05
        continue
      fi
      if fm_afk_launch_lock_owned; then
        [ "$(fm_afk_launch_read_control "$reclaim/token" 2>/dev/null || true)" != "$reclaim_token" ] || rm -rf "$reclaim" 2>/dev/null || true
        sleep 0.05
        continue
      fi
      quarantine="$FM_AFK_LAUNCH_LOCK.stale.$reclaim_token"
      if ! fm_afk_launch_atomic_rename "$FM_AFK_LAUNCH_LOCK" "$quarantine"; then
        [ "$(fm_afk_launch_read_control "$reclaim/token" 2>/dev/null || true)" != "$reclaim_token" ] || rm -rf "$reclaim" 2>/dev/null || true
        sleep 0.05
        continue
      fi
      [ -d "$quarantine" ] && [ ! -L "$quarantine" ] || return 1
      if [ "$(fm_afk_launch_read_control "$quarantine/.reclaim/token" 2>/dev/null || true)" != "$reclaim_token" ]; then
        fm_afk_launch_log "launcher lock changed while reclaiming it"
        return 1
      fi
      rm -rf "$quarantine" 2>/dev/null || return 1
      incomplete=0
      continue
    fi
    sleep 0.05
  done
  fm_afk_launch_log "timed out waiting for launcher lock"
  return 1
}

fm_afk_launch_lock_release() {
  local pid token
  [ -d "$FM_AFK_LAUNCH_LOCK" ] && [ ! -L "$FM_AFK_LAUNCH_LOCK" ] || return 0
  pid=$(fm_afk_launch_read_control "$FM_AFK_LAUNCH_LOCK/pid" 2>/dev/null || true)
  token=$(fm_afk_launch_read_control "$FM_AFK_LAUNCH_LOCK/token" 2>/dev/null || true)
  [ "$pid" = "$$" ] && [ -n "$FM_AFK_LAUNCH_LOCK_TOKEN" ] && [ "$token" = "$FM_AFK_LAUNCH_LOCK_TOKEN" ] || return 0
  rm -rf "$FM_AFK_LAUNCH_LOCK"
  FM_AFK_LAUNCH_LOCK_TOKEN=
}

fm_afk_launch_usage() {
  sed -n '2,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# The command run inside the created terminal. Real launch runs the shared
# daemon entry; a test overrides it with a harmless placeholder.
fm_afk_launch_entry_cmd() {
  printf '%s' "${FM_AFK_LAUNCH_ENTRY:-$FM_ROOT/bin/fm-afk-start.sh}"
}

fm_afk_launch_record_write() {  # <backend> <target> <extra>
  local pending
  fm_afk_launch_state_prepare || return 1
  pending=$(mktemp "$FM_AFK_LAUNCH_STATE/.afk-daemon-terminal.pending.XXXXXX") || return 1
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" > "$pending" || { rm -f "$pending"; return 1; }
  if [ -L "$FM_AFK_LAUNCH_RECORD" ] || { [ -e "$FM_AFK_LAUNCH_RECORD" ] && [ ! -f "$FM_AFK_LAUNCH_RECORD" ]; }; then
    fm_afk_launch_log "refusing unsafe daemon-terminal record destination: $FM_AFK_LAUNCH_RECORD"
    rm -f "$pending"
    return 1
  fi
  mv "$pending" "$FM_AFK_LAUNCH_RECORD" || { rm -f "$pending"; return 1; }
}

fm_afk_launch_flag_write() {
  local destination="$FM_AFK_LAUNCH_STATE/.afk" pending
  fm_afk_launch_state_prepare || return 1
  pending=$(mktemp "$FM_AFK_LAUNCH_STATE/.afk.pending.XXXXXX") || return 1
  date '+%s' > "$pending" || { rm -f "$pending"; return 1; }
  if [ -L "$destination" ] || { [ -e "$destination" ] && [ ! -f "$destination" ]; }; then
    fm_afk_launch_log "refusing unsafe away-mode flag destination: $destination"
    rm -f "$pending"
    return 1
  fi
  mv "$pending" "$destination" || { rm -f "$pending"; return 1; }
}

fm_afk_launch_herdr_identity_pack() {  # <workspace-id> <label>
  local workspace=$1 label=$2
  case "$workspace$label" in *$'\t'*|*$'\n'*|*'|'*) return 1 ;; esac
  [ -n "$workspace" ] && [ -n "$label" ] || return 1
  printf '%s|%s\n' "$workspace" "$label"
}

fm_afk_launch_herdr_identity_parse() {  # <packed-identity>
  local packed=$1
  case "$packed" in *'|'*) ;; *) return 1 ;; esac
  FM_AFK_HERDR_WORKSPACE=${packed%%|*}
  FM_AFK_HERDR_LABEL=${packed#*|}
  [ -n "$FM_AFK_HERDR_WORKSPACE" ] && [ -n "$FM_AFK_HERDR_LABEL" ] \
    && [ "$FM_AFK_HERDR_LABEL" != "$packed" ]
}

fm_afk_launch_herdr_identity_state() {  # <target> <packed-identity>
  local target=$1 packed=$2 session pane workspaces panes out code
  fm_afk_launch_herdr_identity_parse "$packed" || { printf 'unknown'; return 0; }
  session=${target%%:*}
  pane=${target#*:}
  [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || { printf 'unknown'; return 0; }
  workspaces=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || { printf 'unknown'; return 0; }
  if ! printf '%s\n' "$workspaces" | jq -e '(.result.workspaces | type) == "array"' >/dev/null 2>&1; then
    printf 'unknown'
    return 0
  fi
  if printf '%s\n' "$workspaces" | jq -e --arg id "$FM_AFK_HERDR_WORKSPACE" --arg want_label "$FM_AFK_HERDR_LABEL" \
    'any(.result.workspaces[]?; (.workspace_id | tostring) == $id and .label == $want_label)' >/dev/null 2>&1; then
    panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$FM_AFK_HERDR_WORKSPACE" 2>/dev/null) \
      || { printf 'unknown'; return 0; }
    if ! printf '%s\n' "$panes" | jq -e '(.result.panes | type) == "array"' >/dev/null 2>&1; then
      printf 'unknown'
      return 0
    fi
    if printf '%s\n' "$panes" | jq -e --arg pane "$pane" \
      'any(.result.panes[]?; (.pane_id | tostring) == $pane)' >/dev/null 2>&1; then
      printf 'match'
      return 0
    fi
  elif printf '%s\n' "$workspaces" | jq -e --arg id "$FM_AFK_HERDR_WORKSPACE" \
    'any(.result.workspaces[]?; (.workspace_id | tostring) == $id)' >/dev/null 2>&1; then
    printf 'mismatch'
    return 0
  fi
  if out=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>&1); then
    printf 'mismatch'
    return 0
  fi
  code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null) || { printf 'unknown'; return 0; }
  if [ "$code" = pane_not_found ]; then printf 'absent'; else printf 'unknown'; fi
}

# Read the recorded terminal into FM_AFK_REC_BACKEND/FM_AFK_REC_TARGET and
# FM_AFK_REC_EXTRA. Returns 1 when no record exists.
fm_afk_launch_record_read() {
  local record hash expected_prefix
  FM_AFK_REC_BACKEND=""; FM_AFK_REC_TARGET=""; FM_AFK_REC_EXTRA=""
  if [ -L "$FM_AFK_LAUNCH_RECORD" ] \
    || { [ -e "$FM_AFK_LAUNCH_RECORD" ] && [ ! -f "$FM_AFK_LAUNCH_RECORD" ]; }; then
    fm_afk_launch_log "daemon terminal record is not a real regular file; refusing to act on it"
    return 2
  fi
  [ -f "$FM_AFK_LAUNCH_RECORD" ] || return 1
  record=$(fm_afk_launch_read_control "$FM_AFK_LAUNCH_RECORD") || record=""
  if [ -z "$record" ] || [ -L "$FM_AFK_LAUNCH_RECORD" ] || [ ! -f "$FM_AFK_LAUNCH_RECORD" ]; then
    fm_afk_launch_log "daemon terminal record changed while reading; refusing to act on it"
    return 2
  fi
  IFS=$'\t' read -r FM_AFK_REC_BACKEND FM_AFK_REC_TARGET FM_AFK_REC_EXTRA <<< "$record" || true
  if ! printf '%s\n' "$record" | awk -F '\t' 'NF != 3 { bad=1 } END { exit !(NR == 1 && !bad) }' \
    || [ -z "$FM_AFK_REC_BACKEND" ] || [ -z "$FM_AFK_REC_TARGET" ]; then
    fm_afk_launch_log "daemon terminal record is malformed; refusing to act on it"
    return 2
  fi
  case "$FM_AFK_REC_BACKEND" in
    herdr) fm_afk_launch_herdr_identity_parse "$FM_AFK_REC_EXTRA" ;;
    herdr-plan) [ -n "$FM_AFK_REC_EXTRA" ] ;;
    tmux)
      hash=$(printf '%s' "$FM_HOME" | cksum | cut -d' ' -f1)
      expected_prefix="fm-afk-daemon-$hash-"
      if ! printf '%s\n' "$FM_AFK_REC_TARGET" | grep -Eq "^${expected_prefix}[0-9]+-[0-9]+-[0-9]+$"; then
        fm_afk_launch_log "recorded tmux target '$FM_AFK_REC_TARGET' does not belong to this Firstmate home; refusing to act on it"
        return 2
      fi
      ;;
    none) [ "$FM_AFK_REC_TARGET" = - ] && [ "$FM_AFK_REC_EXTRA" = native ] ;;
    *) return 2 ;;
  esac || { fm_afk_launch_log "daemon terminal record is malformed; refusing to act on it"; return 2; }
}

fm_afk_launch_record_validate_if_present() {
  local result
  fm_afk_launch_record_read
  result=$?
  [ "$result" -ne 2 ]
}

# Close a recorded terminal by EXACT id (never a broad sweep). The
# recorded workspace id (herdr) needs no separate close: closing the pane takes
# its single-tab dedicated workspace with it.
fm_afk_launch_close_terminal() {  # <backend> <target> [extra]
  local backend=$1 target=$2 extra=${3:-}
  case "$backend" in
    herdr)
      fm_backend_source herdr || return 1
      local session=${target%%:*} pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      [ "$(fm_afk_launch_herdr_identity_state "$target" "$extra")" = match ] || return 1
      fm_backend_herdr_cli "$session" pane close "$pane" >/dev/null 2>&1
      ;;
    tmux)
      # target is the dedicated daemon session name - kill exactly it.
      tmux kill-session -t "=$target" 2>/dev/null
      ;;
    none)
      return 0
      ;;
    *)
      fm_afk_launch_log "cannot close unknown recorded backend '$backend'"
      return 1
      ;;
  esac
}

fm_afk_launch_terminal_absent() {  # <backend> <target> [extra]
  local backend=$1 target=$2 extra=${3:-} session pane out result
  case "$backend" in
    herdr)
      session=${target%%:*}
      pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      [ "$(fm_afk_launch_herdr_identity_state "$target" "$extra")" = absent ]
      ;;
    tmux)
      out=$(tmux has-session -t "=$target" 2>&1)
      result=$?
      [ "$result" -eq 1 ] || return 1
      printf '%s' "$out" | grep -Eqi "can't find session|no server running on|failed to connect to server|error connecting to .*\((No such file or directory|Connection refused)\)"
      ;;
    none)
      return 0
      ;;
    *) return 1 ;;
  esac
}

fm_afk_launch_herdr_plan_absent() {  # <session> <label>
  local session=$1 label=$2 workspaces
  workspaces=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 1
  printf '%s' "$workspaces" | jq -e --arg want "$label" \
    '(.result.workspaces | type) == "array" and all(.result.workspaces[]?; .label != $want)' >/dev/null 2>&1
}

fm_afk_launch_plan_grace_elapsed() {
  local mtime now
  [ -f "$FM_AFK_LAUNCH_RECORD" ] && [ ! -L "$FM_AFK_LAUNCH_RECORD" ] || return 1
  mtime=$(fm_path_mtime "$FM_AFK_LAUNCH_RECORD") || return 1
  now=$(date '+%s') || return 1
  case "$mtime:$now" in *[!0-9:]*) return 1 ;; esac
  [ $((now - mtime)) -ge 60 ]
}

fm_afk_launch_close_recorded() {
  local close_result=0 recovered wsid pane packed
  if [ "$FM_AFK_REC_BACKEND" = herdr-plan ]; then
    recovered=$(fm_afk_launch_herdr_recover_created "$FM_AFK_REC_TARGET" "$FM_AFK_REC_EXTRA") || {
      if fm_afk_launch_plan_grace_elapsed \
        && fm_afk_launch_herdr_plan_absent "$FM_AFK_REC_TARGET" "$FM_AFK_REC_EXTRA"; then
        rm -f "$FM_AFK_LAUNCH_RECORD" || return 1
        fm_afk_launch_log "planned herdr daemon workspace was never created; cleared its expired intent"
        return 0
      fi
      fm_afk_launch_log "planned herdr daemon workspace is not yet recoverable; preserving its unique label"
      return 1
    }
    IFS=$'\t' read -r wsid pane <<< "$recovered"
    packed=$(fm_afk_launch_herdr_identity_pack "$wsid" "$FM_AFK_REC_EXTRA") || return 1
    fm_afk_launch_record_write herdr "$FM_AFK_REC_TARGET:$pane" "$packed" || return 1
    FM_AFK_REC_BACKEND=herdr
    FM_AFK_REC_TARGET="$FM_AFK_REC_TARGET:$pane"
    FM_AFK_REC_EXTRA=$packed
  fi
  fm_afk_launch_close_terminal "$FM_AFK_REC_BACKEND" "$FM_AFK_REC_TARGET" "$FM_AFK_REC_EXTRA" || close_result=$?
  if fm_afk_launch_terminal_absent "$FM_AFK_REC_BACKEND" "$FM_AFK_REC_TARGET" "$FM_AFK_REC_EXTRA"; then
    rm -f "$FM_AFK_LAUNCH_RECORD" || return 1
    [ "$close_result" -eq 0 ] || fm_afk_launch_log "terminal close command failed, but exact absence was confirmed"
    return 0
  fi
  fm_afk_launch_log "recorded terminal teardown is unconfirmed; preserving exact id"
  return 1
}

fm_afk_launch_terminal_alive() {  # <backend> <target> [extra]
  local backend=$1 target=$2 extra=${3:-} session pane
  case "$backend" in
    herdr)
      session=${target%%:*}
      pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      [ "$(fm_afk_launch_herdr_identity_state "$target" "$extra")" = match ]
      ;;
    tmux)
      tmux has-session -t "=$target" 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

fm_afk_launch_wait_ready() {  # <backend> <target> [extra]
  local backend=$1 target=$2 extra=${3:-} i
  if [ -n "${FM_AFK_LAUNCH_ENTRY:-}" ]; then
    fm_afk_launch_terminal_alive "$backend" "$target" "$extra"
    return
  fi
  for i in $(seq 1 100); do
    daemon_lock_held_by_live_daemon && return 0
    fm_afk_launch_terminal_alive "$backend" "$target" "$extra" || return 1
    sleep 0.05
  done
  return 1
}

fm_afk_launch_commit_terminal() {  # <backend> <target> <extra> [already-recorded]
  local backend=$1 target=$2 extra=$3 already_recorded=${4:-0}
  if [ "$already_recorded" -ne 1 ] && ! fm_afk_launch_record_write "$backend" "$target" "$extra"; then
    fm_afk_launch_log "failed to persist daemon terminal record; closing $backend:$target"
    fm_afk_launch_close_terminal "$backend" "$target" "$extra"
    return 1
  fi
  if ! fm_afk_launch_wait_ready "$backend" "$target" "$extra"; then
    fm_afk_launch_log "daemon did not become ready; closing $backend:$target"
    FM_AFK_REC_BACKEND=$backend
    FM_AFK_REC_TARGET=$target
    FM_AFK_REC_EXTRA=$extra
    fm_afk_launch_close_recorded
    return 1
  fi
}

fm_afk_launch_herdr_recover_created() {  # <session> <label>
  local session=$1 label=$2 workspaces ws_count wsid panes pane_count pane i
  for i in $(seq 1 20); do
    workspaces=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || { sleep 0.05; continue; }
    ws_count=$(printf '%s' "$workspaces" | jq --arg want "$label" \
      '[.result.workspaces[]? | select(.label == $want)] | length' 2>/dev/null) || { sleep 0.05; continue; }
    if [ "$ws_count" = 0 ]; then
      sleep 0.05
      continue
    fi
    [ "$ws_count" = 1 ] || return 1
    wsid=$(printf '%s' "$workspaces" | jq -r --arg want "$label" \
      '.result.workspaces[]? | select(.label == $want) | .workspace_id' 2>/dev/null) || return 1
    [ -n "$wsid" ] || return 1
    panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$wsid" 2>/dev/null) || { sleep 0.05; continue; }
    pane_count=$(printf '%s' "$panes" | jq '[.result.panes[]?] | length' 2>/dev/null) || { sleep 0.05; continue; }
    if [ "$pane_count" = 0 ]; then
      sleep 0.05
      continue
    fi
    [ "$pane_count" = 1 ] || return 1
    pane=$(printf '%s' "$panes" | jq -r '.result.panes[0].pane_id // empty' 2>/dev/null) || return 1
    [ -n "$pane" ] || return 1
    printf '%s\t%s' "$wsid" "$pane"
    return 0
  done
  return 1
}

# Reconcile a recorded-but-dead terminal: if a record exists and no live daemon
# owns it, close the leaked terminal by exact id and drop the record.
fm_afk_launch_reconcile() {
  local read_result
  if daemon_lock_held_by_live_daemon; then
    return 0
  fi
  fm_afk_launch_record_read
  read_result=$?
  if [ "$read_result" -eq 0 ]; then
    fm_afk_launch_log "reconciling leaked daemon terminal ${FM_AFK_REC_BACKEND}:${FM_AFK_REC_TARGET}"
    fm_afk_launch_close_recorded
  elif [ "$read_result" -eq 2 ]; then
    return 1
  fi
}

fm_afk_launch_restore_backup() {  # <backup> <had-afk>
  local backup=$1 had_afk=$2 artifact result=0
  rm -f "$FM_AFK_LAUNCH_STATE/.afk" \
    "$FM_AFK_LAUNCH_STATE/.subsuper-escalations" \
    "$FM_AFK_LAUNCH_STATE/.subsuper-escalations.since" \
    "$FM_AFK_LAUNCH_STATE/.subsuper-inject-wedged" || result=1
  if [ "$had_afk" -eq 1 ]; then
    fm_afk_launch_copy_bounded "$backup/.afk" "$FM_AFK_LAUNCH_STATE/.afk" || result=1
  fi
  for artifact in .subsuper-escalations .subsuper-escalations.since .subsuper-inject-wedged; do
    if [ -e "$backup/$artifact" ] || [ -L "$backup/$artifact" ]; then
      fm_afk_launch_copy_bounded "$backup/$artifact" "$FM_AFK_LAUNCH_STATE/$artifact" || result=1
    fi
  done
  if [ "$result" -eq 0 ]; then
    rm -rf "$backup" || return 1
  else
    fm_afk_launch_log "rollback restoration incomplete; backup retained at $backup"
  fi
  return "$result"
}

# Launch the daemon in a non-visible herdr terminal in the CAPTAIN's session
# (so the daemon can inject into the captain pane, which lives there). A
# dedicated background workspace (--no-focus) holds exactly one tab/pane; it
# never touches the captain's active tab. Prints the record line on success.
fm_afk_launch_create_herdr() {  # <captain-target> <captain-backend>
  local captain_target=$1 captain_backend=$2 session out wsid pane entry cmd label recovered create_result packed
  session=${captain_target%%:*}
  if [ -z "$session" ] || [ "$session" = "$captain_target" ]; then
    fm_afk_launch_log "cannot derive herdr session from captain target '$captain_target'"
    return 1
  fi
  fm_backend_source herdr || return 1
  fm_backend_herdr_server_ensure "$session" || { fm_afk_launch_log "herdr server not ready for session '$session'"; return 1; }
  label=${FM_AFK_LAUNCH_LABEL:-"$FM_AFK_LAUNCH_WS_LABEL-$$-${RANDOM:-0}-$(date '+%s')"}
  if ! fm_afk_launch_record_write herdr-plan "$session" "$label"; then
    fm_afk_launch_log "failed to persist planned herdr daemon workspace '$label'"
    return 1
  fi
  out=$(fm_backend_herdr_cli "$session" workspace create --cwd "$FM_HOME" --label "$label" --no-focus 2>/dev/null)
  create_result=$?
  wsid=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ "$create_result" -ne 0 ] && [ -n "$wsid" ] && [ -n "$pane" ]; then
    fm_afk_launch_log "herdr create failed after returning exact ids; closing $session:$pane"
    packed=$(fm_afk_launch_herdr_identity_pack "$wsid" "$label") || return 1
    if fm_afk_launch_record_write herdr "$session:$pane" "$packed"; then
      FM_AFK_REC_BACKEND=herdr
      FM_AFK_REC_TARGET="$session:$pane"
      FM_AFK_REC_EXTRA=$packed
      fm_afk_launch_close_recorded || true
    else
      fm_afk_launch_log "failed to persist exact id for failed herdr create"
    fi
    return 1
  fi
  if [ -z "$wsid" ] || [ -z "$pane" ]; then
    recovered=$(fm_afk_launch_herdr_recover_created "$session" "$label") || {
      fm_afk_launch_log "herdr create did not yield a recoverable exact workspace/pane id"
      return 1
    }
    IFS=$'\t' read -r wsid pane <<< "$recovered"
  fi
  packed=$(fm_afk_launch_herdr_identity_pack "$wsid" "$label") || return 1
  entry=$(fm_afk_launch_entry_cmd)
  cmd=$(printf 'exec env FM_HOME=%q FM_STATE_OVERRIDE=%q FM_AFK_STATE_PREPARED=1 FM_SUPERVISOR_TARGET=%q FM_SUPERVISOR_BACKEND=%q %q' \
    "$FM_HOME" "$FM_AFK_LAUNCH_STATE" "$captain_target" "$captain_backend" "$entry")
  if ! fm_afk_launch_record_write herdr "$session:$pane" "$packed"; then
    fm_afk_launch_log "failed to persist herdr daemon terminal record; closing $session:$pane"
    fm_afk_launch_close_terminal herdr "$session:$pane" "$packed"
    return 1
  fi
  if ! fm_backend_herdr_cli "$session" pane run "$pane" "$cmd" >/dev/null 2>&1; then
    fm_afk_launch_log "failed to run daemon in herdr pane $session:$pane; closing it"
    FM_AFK_REC_BACKEND=herdr
    FM_AFK_REC_TARGET="$session:$pane"
    FM_AFK_REC_EXTRA=$packed
    fm_afk_launch_close_recorded || true
    return 1
  fi
  fm_afk_launch_commit_terminal herdr "$session:$pane" "$packed" 1 || return 1
  fm_afk_launch_log "daemon launched in non-visible herdr workspace $wsid (pane $session:$pane), supervising $captain_target"
}

# Launch the daemon in a detached tmux session (never a split-window in the
# captain's window). tmux pane ids are server-global, so the daemon reaches the
# captain pane by its %id from this separate session.
fm_afk_launch_create_tmux() {  # <captain-target> <captain-backend>
  local captain_target=$1 captain_backend=$2 session entry cmd hash nonce
  hash=$(printf '%s' "$FM_HOME" | cksum | cut -d' ' -f1)
  nonce="$$-${RANDOM:-0}-$(date '+%s')"
  session="fm-afk-daemon-$hash-$nonce"
  entry=$(fm_afk_launch_entry_cmd)
  cmd=$(printf 'exec env FM_HOME=%q FM_STATE_OVERRIDE=%q FM_AFK_STATE_PREPARED=1 FM_SUPERVISOR_TARGET=%q FM_SUPERVISOR_BACKEND=%q %q' \
    "$FM_HOME" "$FM_AFK_LAUNCH_STATE" "$captain_target" "$captain_backend" "$entry")
  if ! fm_afk_launch_record_write tmux "$session" ""; then
    fm_afk_launch_log "failed to persist planned tmux daemon session '$session'"
    return 1
  fi
  if ! tmux new-session -d -s "$session" "$cmd" 2>/dev/null; then
    fm_afk_launch_log "failed to create detached tmux daemon session '$session'"
    if fm_afk_launch_terminal_absent tmux "$session"; then
      if ! rm -f "$FM_AFK_LAUNCH_RECORD"; then
        fm_afk_launch_log "failed to remove absent planned tmux daemon record after creation failure"
      fi
    else
      fm_afk_launch_log "tmux creation outcome is unconfirmed; preserving exact session '$session' for reconciliation"
    fi
    return 1
  fi
  fm_afk_launch_commit_terminal tmux "$session" "" 1 || return 1
  fm_afk_launch_log "daemon launched in detached tmux session '$session', supervising $captain_target"
}

fm_afk_launch_start() {
  local captain_target captain_target_status captain_backend captain_backend_status backup artifact had_afk=0 result=0
  # Capture the captain pane FIRST, before creating anything.
  if captain_target=$(discover_supervisor_target); then captain_target_status=0; else captain_target_status=$?; fi
  if captain_backend=$(discover_supervisor_backend); then captain_backend_status=0; else captain_backend_status=$?; fi
  [ -n "$captain_target" ] || {
    fm_afk_launch_log "could not resolve the captain supervisor pane (set FM_SUPERVISOR_TARGET)"; return 1; }
  [ -n "$captain_backend" ] || {
    fm_afk_launch_log "could not resolve the captain supervisor backend (set FM_SUPERVISOR_BACKEND)"; return 1; }
  if [ "$captain_target_status" -ne 0 ] || [ "$captain_backend_status" -ne 0 ]; then
    fm_afk_launch_log "using legacy supervisor fallback $captain_backend:$captain_target"
  fi

  fm_afk_launch_state_prepare || return 1

  if daemon_lock_held_by_live_daemon; then
    fm_afk_launch_record_validate_if_present || return 1
    if ! fm_afk_launch_flag_write; then
      fm_afk_launch_log "failed to refresh away-mode flag"
      return 1
    fi
    fm_afk_launch_log "daemon already running; refreshed away-mode flag (no new terminal)"
    return 0
  fi

  backup=$(mktemp -d "$FM_AFK_LAUNCH_STATE/.afk-launch-backup.XXXXXX") || return 1
  if [ -e "$FM_AFK_LAUNCH_STATE/.afk" ] || [ -L "$FM_AFK_LAUNCH_STATE/.afk" ]; then
    had_afk=1
    fm_afk_launch_copy_bounded "$FM_AFK_LAUNCH_STATE/.afk" "$backup/.afk" || { rm -rf "$backup"; return 1; }
  fi
  for artifact in .subsuper-escalations .subsuper-escalations.since .subsuper-inject-wedged; do
    if [ -e "$FM_AFK_LAUNCH_STATE/$artifact" ] || [ -L "$FM_AFK_LAUNCH_STATE/$artifact" ]; then
      fm_afk_launch_copy_bounded "$FM_AFK_LAUNCH_STATE/$artifact" "$backup/$artifact" || { rm -rf "$backup"; return 1; }
    fi
  done
  if ! fm_afk_launch_reconcile; then
    result=1
  elif [ "$had_afk" -eq 0 ]; then
    if fm_afk_clear_stale_artifacts "$FM_AFK_LAUNCH_STATE"; then
      result=0
    else
      fm_afk_launch_log "failed to clear stale away-mode artifacts"
      result=1
    fi
  fi
  if [ "$result" -eq 0 ]; then
    if ! fm_afk_launch_flag_write; then
      fm_afk_launch_log "failed to write away-mode flag"
      result=1
    fi
  fi

  if [ "$result" -eq 0 ]; then
    case "$captain_backend" in
      herdr) fm_afk_launch_create_herdr "$captain_target" "$captain_backend"; result=$? ;;
      tmux)  fm_afk_launch_create_tmux "$captain_target" "$captain_backend"; result=$? ;;
      *)
        fm_afk_launch_log "no non-visible daemon-launch primitive for backend '$captain_backend' yet (supported: herdr, tmux)"
        result=1
        ;;
    esac
  fi
  if [ "$result" -ne 0 ]; then
    fm_afk_launch_restore_backup "$backup" "$had_afk" || result=1
  else
    rm -rf "$backup" || result=1
  fi
  return "$result"
}

fm_afk_launch_start_native_locked() {
  local backup artifact had_afk=0 result=0 record_result
  fm_afk_launch_state_prepare || return 1
  if fm_afk_native_process_live; then
    fm_afk_launch_record_read
    record_result=$?
    [ "$record_result" -ne 2 ] || return 1
    if [ "$record_result" -eq 1 ]; then
      fm_afk_launch_record_write none - native || return 1
    fi
    fm_afk_launch_flag_write || return 1
    fm_afk_launch_log "native daemon process already starting or active; refreshed away-mode flag"
    return 0
  fi
  if [ "$FM_AFK_NATIVE_PROCESS_UNSAFE" = 1 ]; then
    fm_afk_launch_log "native daemon process marker does not identify an away-mode daemon; refusing refresh"
    return 1
  fi
  if daemon_lock_held_by_live_daemon; then
    fm_afk_launch_record_validate_if_present || return 1
    fm_afk_launch_flag_write || return 1
    fm_afk_launch_log "daemon already running; refreshed away-mode flag"
    return 0
  fi
  backup=$(mktemp -d "$FM_AFK_LAUNCH_STATE/.afk-launch-backup.XXXXXX") || return 1
  if [ -e "$FM_AFK_LAUNCH_STATE/.afk" ] || [ -L "$FM_AFK_LAUNCH_STATE/.afk" ]; then
    had_afk=1
    fm_afk_launch_copy_bounded "$FM_AFK_LAUNCH_STATE/.afk" "$backup/.afk" || { rm -rf "$backup"; return 1; }
  fi
  for artifact in .subsuper-escalations .subsuper-escalations.since .subsuper-inject-wedged; do
    if [ -e "$FM_AFK_LAUNCH_STATE/$artifact" ] || [ -L "$FM_AFK_LAUNCH_STATE/$artifact" ]; then
      fm_afk_launch_copy_bounded "$FM_AFK_LAUNCH_STATE/$artifact" "$backup/$artifact" || { rm -rf "$backup"; return 1; }
    fi
  done
  fm_afk_launch_reconcile || result=1
  if [ "$result" -eq 0 ] && [ "$had_afk" -eq 0 ]; then
    if ! fm_afk_clear_stale_artifacts "$FM_AFK_LAUNCH_STATE"; then
      fm_afk_launch_log "failed to clear stale away-mode artifacts"
      result=1
    fi
  fi
  if [ "$result" -eq 0 ] && ! fm_afk_launch_flag_write; then
    result=1
  fi
  if [ "$result" -eq 0 ]; then
    fm_afk_launch_record_write none - native || result=1
  fi
  if [ "$result" -ne 0 ]; then
    fm_afk_launch_restore_backup "$backup" "$had_afk" || result=1
  else
    rm -rf "$backup" || result=1
  fi
  return "$result"
}

fm_afk_launch_start_native() {
  local result
  fm_lock_acquire_wait "$FM_AFK_NATIVE_HANDOFF_LOCK"
  fm_afk_launch_start_native_locked
  result=$?
  fm_lock_release "$FM_AFK_NATIVE_HANDOFF_LOCK"
  return "$result"
}

fm_afk_launch_stop_locked() {
  local pid pid_identity current_identity native_identity=0 result=0 read_result
  fm_afk_launch_record_read
  read_result=$?
  if [ "$read_result" -eq 2 ]; then
    fm_afk_launch_log "malformed daemon terminal record; refusing to stop away mode"
    return 1
  fi
  # (1) SIGTERM the daemon so its cleanup trap flushes buffered escalations
  # WHILE state/.afk is still present (the exit-ordering fix: clearing .afk
  # first would make that flush a no-op via inject_msg's presence gate).
  pid=""
  pid_identity=""
  if daemon_lock_held_by_live_daemon; then
    pid=$(daemon_lock_pid 2>/dev/null) || return 1
    pid_identity=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  elif { [ "$read_result" -eq 1 ] || [ "$FM_AFK_REC_BACKEND" = none ]; } && fm_afk_native_process_live; then
    pid=$FM_AFK_NATIVE_PID
    pid_identity=$(fm_afk_native_process_identity "$pid") || return 1
    native_identity=1
  elif [ -e "$FM_AFK_NATIVE_PROCESS" ]; then
    if fm_afk_native_process_live; then
      fm_afk_launch_log "live native daemon process conflicts with the recorded terminal; preserving lifecycle state"
      return 1
    fi
    if [ "$FM_AFK_NATIVE_PROCESS_UNSAFE" = 1 ]; then
      fm_afk_launch_log "native daemon process marker does not identify an away-mode daemon; refusing to signal pid=$(sed -n '1p' "$FM_AFK_NATIVE_PROCESS" 2>/dev/null || true)"
      return 1
    fi
    rm -f "$FM_AFK_NATIVE_PROCESS" || return 1
  fi
  if [ -n "$pid" ]; then
    if ! kill -TERM "$pid" 2>/dev/null; then
      fm_afk_launch_log "failed to signal away-mode daemon pid=$pid"
      result=1
    fi
    for _ in $(seq 1 40); do
      fm_pid_alive "$pid" || break
      sleep 0.25
    done
  fi
  if [ -n "$pid" ] && fm_pid_alive "$pid"; then
    if [ "$native_identity" -eq 1 ]; then
      current_identity=$(fm_afk_native_process_identity "$pid" 2>/dev/null) || {
        fm_afk_launch_log "could not confirm away-mode daemon exit; preserving lifecycle state"
        return 1
      }
    else
      current_identity=$(fm_pid_identity "$pid" 2>/dev/null) || {
        fm_afk_launch_log "could not confirm away-mode daemon exit; preserving lifecycle state"
        return 1
      }
    fi
    if [ -z "$current_identity" ]; then
      fm_afk_launch_log "could not confirm away-mode daemon exit; preserving lifecycle state"
      return 1
    fi
    if [ "$current_identity" = "$pid_identity" ]; then
      fm_afk_launch_log "away-mode daemon did not exit after SIGTERM; preserving lifecycle state"
      return 1
    fi
  fi
  rm -f "$FM_AFK_NATIVE_PROCESS" || result=1
  # (2) Close the daemon's own terminal by exact id.
  if [ "$read_result" -eq 0 ]; then
    fm_afk_launch_close_recorded || result=1
  fi
  # (3) Clear the away-mode flag LAST.
  if ! rm -f "$FM_AFK_LAUNCH_STATE/.afk"; then
    fm_afk_launch_log "failed to clear away-mode flag"
    result=1
  fi
  if [ "$result" -eq 0 ]; then
    fm_afk_launch_log "away mode stopped; daemon terminal torn down and .afk cleared"
  else
    fm_afk_launch_log "away mode stopped; terminal teardown remains recorded for retry"
  fi
  return "$result"
}

fm_afk_launch_stop() {
  local result
  fm_lock_acquire_wait "$FM_AFK_NATIVE_HANDOFF_LOCK"
  fm_afk_launch_stop_locked
  result=$?
  fm_lock_release "$FM_AFK_NATIVE_HANDOFF_LOCK"
  return "$result"
}

fm_afk_launch_main() {
  local result
  fm_refuse_if_gate_agent
  fm_afk_launch_lock_acquire || return 1
  trap fm_afk_launch_lock_release EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  case "${1:-start}" in
    start) fm_afk_launch_start ;;
    start-native) fm_afk_launch_start_native ;;
    stop) fm_afk_launch_stop ;;
    reconcile) fm_afk_launch_reconcile ;;
    -h|--help|help) fm_afk_launch_usage ;;
    *) fm_afk_launch_usage >&2; return 2 ;;
  esac
  result=$?
  fm_afk_launch_lock_release || result=1
  trap - EXIT INT TERM
  return "$result"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_afk_launch_main "$@"
fi
