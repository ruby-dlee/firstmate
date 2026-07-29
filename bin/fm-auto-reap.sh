#!/usr/bin/env bash
# Automatically reclaim terminal crewmates from the supervision loop.
#
# This script decides only whether a task has an unambiguous terminal trigger.
# It never decides whether work is landed.
# Every endpoint, cleanliness, landing, report, and worktree-release proof is
# delegated to ordinary fm-teardown.sh without --force.
# A teardown refusal preserves the task metadata and worktree and is surfaced.
#
# After teardown succeeds, an exactly attributed active no-mistakes run is
# aborted by run id so its monitor and pipeline agent are collected too.
# The shared no-mistakes daemon is never stopped or restarted.
#
# Usage:
#   fm-auto-reap.sh task <id> <pr-merged|scout-done|failed|local-merged>
#   fm-auto-reap.sh scan
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
AUTO_REAP_COMMAND_TIMEOUT=${FM_AUTO_REAP_COMMAND_TIMEOUT:-20}
AUTO_REAP_RETRY_SECS=${FM_AUTO_REAP_RETRY_SECS:-3600}

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
# shellcheck source=bin/fm-account-routing-lib.sh
. "$SCRIPT_DIR/fm-account-routing-lib.sh"
# shellcheck source=bin/fm-process-tree-lib.sh
. "$SCRIPT_DIR/fm-process-tree-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

case "$AUTO_REAP_COMMAND_TIMEOUT:$AUTO_REAP_RETRY_SECS" in
  *[!0-9:]*|0:*|*:0)
    echo "error: auto-reap timeouts must be positive integers" >&2
    exit 2
    ;;
esac
[ -d "$STATE" ] && [ ! -L "$STATE" ] || {
  echo "error: auto-reap state must be a real directory: $STATE" >&2
  exit 1
}
AUTO_REAP_ID=
AUTO_REAP_TRIGGER=
META=
KIND=
MODE=
WORKTREE=
PR_URL=
X_REQUEST=
NM_RUN_ID=
NM_AGENT_PID=
NM_AGENT_START=
RUN_CAPTURE_STATUS=0
FM_AUTO_REAP_CAPTURE_VALUE=

auto_reap_tool() {  # <override-variable> <default-path-or-command>
  local variable=$1 fallback=$2 value
  eval "value=\${$variable:-}"
  if [ -n "$value" ]; then
    [ "${FM_AUTO_REAP_TEST_HOOKS:-}" = firstmate-auto-reap-tests-v2 ] || {
      echo "error: $variable requires the explicit auto-reap test hook" >&2
      return 1
    }
    [ -x "$value" ] && [ ! -L "$value" ] || return 1
    printf '%s\n' "$value"
    return 0
  fi
  case "$fallback" in
    /*) [ -x "$fallback" ] && [ ! -L "$fallback" ] || return 1; printf '%s\n' "$fallback" ;;
    *) command -v "$fallback" ;;
  esac
}

run_capture() {  # <output-variable> <command> [args...]
  local output_variable=$1
  shift
  FM_AUTO_REAP_CAPTURE_VALUE=
  if fm_run_bounded_capture --combine-stderr \
      FM_AUTO_REAP_CAPTURE_VALUE "$AUTO_REAP_COMMAND_TIMEOUT" "$@"; then
    RUN_CAPTURE_STATUS=0
  else
    RUN_CAPTURE_STATUS=$?
  fi
  fm_process_tree_cleanup_verified || {
    echo "error: bounded auto-reap command cleanup could not be verified" >&2
    return 1
  }
  printf -v "$output_variable" '%s' "$FM_AUTO_REAP_CAPTURE_VALUE"
  return 0
}

one_line() {
  tr '\n\t' '  ' | awk '{$1=$1; print}'
}

log_result() {
  local line=$1 log="$STATE/.auto-reap.log" size tmp
  [ ! -L "$log" ] && { [ ! -e "$log" ] || [ -f "$log" ]; } || return 0
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$line" >> "$log" 2>/dev/null || return 0
  size=$(wc -c < "$log" 2>/dev/null | tr -d '[:space:]')
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$size" -ge 262144 ]; then
    tmp=$(mktemp "$STATE/.auto-reap-log.XXXXXX") || return 0
    tail -n 2000 "$log" > "$tmp" 2>/dev/null && mv "$tmp" "$log" 2>/dev/null || true
    rm -f "$tmp" 2>/dev/null || true
  fi
}

refuse() {
  local message=$*
  printf 'auto-reap retained task=%s trigger=%s: %s\n' \
    "${AUTO_REAP_ID:-unknown}" "${AUTO_REAP_TRIGGER:-unknown}" "$message" >&2
  log_result "retained ${AUTO_REAP_ID:-unknown} (${AUTO_REAP_TRIGGER:-unknown}): $message"
  return 1
}

read_meta_field() {  # <key> <required:0|1>
  local key=$1 required=$2 values count
  values=$(sed -n "s/^${key}=//p" "$META" 2>/dev/null)
  count=$(printf '%s\n' "$values" | awk 'NF { n++ } END { print n + 0 }')
  if [ "$count" -eq 0 ] && [ "$required" -eq 0 ]; then
    META_FIELD=
    return 0
  fi
  [ "$count" -eq 1 ] || {
    refuse "metadata field $key is missing or ambiguous"
    return 1
  }
  META_FIELD=$values
}

load_task() {  # <id>
  local id=$1 state_root meta_parent
  fm_account_valid_id "$id" || {
    refuse "task id is invalid"
    return 1
  }
  META="$STATE/$id.meta"
  [ -f "$META" ] && [ ! -L "$META" ] && [ -r "$META" ] || {
    refuse "task metadata is not a real readable file"
    return 1
  }
  state_root=$(cd "$STATE" 2>/dev/null && pwd -P) || return 1
  meta_parent=$(cd "$(dirname "$META")" 2>/dev/null && pwd -P) || return 1
  [ "$state_root" = "$meta_parent" ] && [ "$(basename "$META")" = "$id.meta" ] || {
    refuse "task metadata identity is unsafe"
    return 1
  }
  read_meta_field kind 1 || return 1
  KIND=$META_FIELD
  case "$KIND" in ship|scout|secondmate) ;; *) refuse "task kind is unknown: $KIND"; return 1 ;; esac
  read_meta_field mode 1 || return 1
  MODE=$META_FIELD
  case "$KIND:$MODE" in
    ship:no-mistakes|ship:direct-PR|ship:local-only|\
    scout:no-mistakes|scout:direct-PR|scout:local-only|\
    secondmate:secondmate) ;;
    *) refuse "task kind/mode is unknown: $KIND/$MODE"; return 1 ;;
  esac
  read_meta_field worktree 1 || return 1
  WORKTREE=$META_FIELD
  read_meta_field pr 0 || return 1
  PR_URL=$META_FIELD
  read_meta_field x_request 0 || return 1
  X_REQUEST=$META_FIELD
}

status_last_line() {
  local status="$STATE/$AUTO_REAP_ID.status"
  [ -f "$status" ] && [ ! -L "$status" ] && [ -r "$status" ] || return 1
  grep -v '^[[:space:]]*$' "$status" 2>/dev/null | tail -1
}

require_status_verb() {  # <verb>
  local expected=$1 last verb
  last=$(status_last_line) || {
    refuse "terminal status is unreadable"
    return 1
  }
  verb=$(status_line_verb "$last")
  [ "$verb" = "$expected" ] || {
    refuse "last status verb is ${verb:-empty}, expected $expected"
    return 1
  }
}

require_current_state() {  # <state>
  local expected=$1 reader output actual
  reader=$(auto_reap_tool FM_AUTO_REAP_CREW_STATE_BIN "$SCRIPT_DIR/fm-crew-state.sh") || {
    refuse "current-state reader is unavailable"
    return 1
  }
  run_capture output "$reader" "$AUTO_REAP_ID" || return 1
  [ "$RUN_CAPTURE_STATUS" -eq 0 ] || {
    refuse "current task state could not be inspected"
    return 1
  }
  case "$output" in state:\ *" · source: "*) ;; *)
    refuse "current task state is ambiguous"
    return 1
    ;;
  esac
  actual=${output#state: }
  actual=${actual%% *}
  [ "$actual" = "$expected" ] || {
    refuse "current task state is $actual, expected $expected"
    return 1
  }
}

parse_pr_url() {  # <url>
  local url=$1 rest
  case "$url" in
    https://github.com/*/*/pull/[0-9]*) ;;
    *) return 1 ;;
  esac
  rest=${url#https://github.com/}
  PR_OWNER=${rest%%/*}
  rest=${rest#*/}
  PR_REPO=${rest%%/*}
  rest=${rest#*/pull/}
  PR_NUMBER=${rest%%[/?#]*}
  case "$PR_OWNER:$PR_REPO:$PR_NUMBER" in
    *[!A-Za-z0-9._:/-]*|::*|*::*|*:) return 1 ;;
  esac
  case "$PR_NUMBER" in ''|*[!0-9]*) return 1 ;; esac
}

pr_is_merged() {
  local gh output state_count
  parse_pr_url "$PR_URL" || {
    refuse "recorded PR URL is missing or invalid"
    return 1
  }
  gh=$(auto_reap_tool FM_AUTO_REAP_GH_AXI_BIN gh-axi) || {
    refuse "gh-axi is unavailable"
    return 1
  }
  run_capture output "$gh" pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" || return 1
  [ "$RUN_CAPTURE_STATUS" -eq 0 ] || {
    refuse "GitHub could not verify the PR as merged"
    return 1
  }
  state_count=$(printf '%s\n' "$output" \
    | grep -Eci '^[[:space:]]*state:[[:space:]]*"?merged"?[[:space:]]*$')
  [ "$state_count" -eq 1 ] || {
    refuse "recorded PR is not provably merged"
    return 1
  }
}

strip_field() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  value=${value#\"}
  value=${value%\"}
  printf '%s' "$value"
}

axi_running_rows_for_branch() {  # <axi-home-output> <branch>
  local output=$1 branch=$2
  printf '%s\n' "$output" | awk -F',' -v wanted="$branch" '
    /^runs\[[0-9]+\]\{/ { in_runs = 1; next }
    in_runs && /^[^[:space:]]/ { in_runs = 0 }
    in_runs && /^[[:space:]]+/ {
      id = $1
      row_branch = $2
      status = $3
      gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", id)
      gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", row_branch)
      gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", status)
      if (row_branch == wanted && status == "running") print id
    }
  '
}

snapshot_agent_pid() {  # <axi-status-output> <run-id>
  local output=$1 run_id=$2 detail_id detail_branch row prefix pid current
  detail_id=$(printf '%s\n' "$output" \
    | sed -n '/^run:$/,/^[^[:space:]]/s/^[[:space:]]*id:[[:space:]]*//p' | head -1)
  detail_id=$(strip_field "$detail_id")
  detail_branch=$(printf '%s\n' "$output" \
    | sed -n '/^run:$/,/^[^[:space:]]/s/^[[:space:]]*branch:[[:space:]]*//p' | head -1)
  detail_branch=$(strip_field "$detail_branch")
  [ "$detail_id" = "$run_id" ] && [ "$detail_branch" = "fm/$AUTO_REAP_ID" ] || return 0
  row=$(printf '%s\n' "$output" \
    | sed -n '/^[[:space:]]*active_steps\[[0-9][0-9]*\].*:/,/^[^[:space:]]/p' \
    | grep -E '^[[:space:]]*[^,]+,[[:space:]]*(running|fixing),' | head -1)
  [ -n "$row" ] || return 0
  prefix=${row%,*}
  pid=${prefix##*,}
  pid=$(strip_field "$pid")
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  current=$(fm_account_process_start_time "$pid" 2>/dev/null) || return 0
  NM_AGENT_PID=$pid
  NM_AGENT_START=$current
}

snapshot_no_mistakes_run() {
  local nm home_output rows count runs_output row status branch detail_output
  NM_RUN_ID=
  NM_AGENT_PID=
  NM_AGENT_START=
  [ "$MODE" = no-mistakes ] || return 0
  [ -d "$WORKTREE" ] && [ ! -L "$WORKTREE" ] || {
    refuse "no-mistakes worktree is unavailable for exact run attribution"
    return 1
  }
  branch=$(git -C "$WORKTREE" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ "$branch" = "fm/$AUTO_REAP_ID" ] || {
    refuse "no-mistakes run attribution requires exact branch fm/$AUTO_REAP_ID"
    return 1
  }
  nm=$(auto_reap_tool FM_AUTO_REAP_NO_MISTAKES_BIN no-mistakes) || {
    refuse "no-mistakes is unavailable for process collection"
    return 1
  }
  run_capture home_output env -C "$WORKTREE" "$nm" axi || return 1
  [ "$RUN_CAPTURE_STATUS" -eq 0 ] || {
    refuse "no-mistakes run inventory is unreadable"
    return 1
  }
  rows=$(axi_running_rows_for_branch "$home_output" "$branch")
  count=$(printf '%s\n' "$rows" | awk 'NF { n++ } END { print n + 0 }')
  if [ "$count" -gt 1 ]; then
    refuse "multiple active no-mistakes runs match $branch"
    return 1
  fi
  if [ "$count" -eq 0 ]; then
    run_capture runs_output env -C "$WORKTREE" "$nm" runs --limit 200 || return 1
    [ "$RUN_CAPTURE_STATUS" -eq 0 ] || {
      refuse "no-mistakes fallback run inventory is unreadable"
      return 1
    }
    while IFS= read -r row; do
      row=$(printf '%s' "$row" | sed 's/^[[:space:]]*//')
      [ -n "$row" ] || continue
      status=${row%%[[:space:]]*}
      row=${row#"$status"}
      row=$(printf '%s' "$row" | sed 's/^[[:space:]]*//')
      [ "${row%%[[:space:]]*}" = "$branch" ] || continue
      if [ "$status" = running ]; then
        refuse "an active no-mistakes run matches $branch but its exact run id is unavailable"
        return 1
      fi
    done <<EOF
$runs_output
EOF
    return 0
  fi
  NM_RUN_ID=$(printf '%s\n' "$rows" | awk 'NF { print; exit }')
  case "$NM_RUN_ID" in ''|*[!A-Za-z0-9._-]*)
    refuse "matching no-mistakes run id is invalid"
    return 1
    ;;
  esac
  run_capture detail_output env -C "$WORKTREE" "$nm" axi status || return 1
  if [ "$RUN_CAPTURE_STATUS" -eq 0 ]; then
    snapshot_agent_pid "$detail_output" "$NM_RUN_ID"
  fi
}

no_mistakes_process_is_gone() {
  local current probe probe_status ps_bin
  [ -n "$NM_AGENT_PID" ] || return 0
  [ -n "$NM_AGENT_START" ] || return 1
  ps_bin=$(fm_account_ps_bin) || return 1
  [ -n "$FM_ACCOUNT_SYSTEM_SED_BIN" ] || return 1
  if probe=$(LC_ALL=C fm_account_system_exec "$ps_bin" -o lstart= -p "$NM_AGENT_PID" 2>&1); then
    probe_status=0
  else
    probe_status=$?
  fi
  current=$(printf '%s\n' "$probe" \
    | fm_account_system_exec "$FM_ACCOUNT_SYSTEM_SED_BIN" 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [ "$probe_status" -eq 0 ]; then
    [ -n "$current" ] && [ "$current" != "$NM_AGENT_START" ]
    return
  fi
  kill -0 "$NM_AGENT_PID" 2>/dev/null && return 1
  case "$current" in
    *"process id too large"*|*"No such process"*|*"no such process"*) return 0 ;;
  esac
  [ -z "$current" ]
}

collect_no_mistakes_run() {
  local nm output
  [ -n "$NM_RUN_ID" ] || return 0
  nm=$(auto_reap_tool FM_AUTO_REAP_NO_MISTAKES_BIN no-mistakes) || {
    echo "error: task resources were reclaimed, but no-mistakes process collection is unavailable" >&2
    return 1
  }
  run_capture output "$nm" axi abort --run "$NM_RUN_ID" || return 1
  [ "$RUN_CAPTURE_STATUS" -eq 0 ] || {
    echo "error: task resources were reclaimed, but no-mistakes run $NM_RUN_ID could not be collected" >&2
    [ -z "$output" ] || printf '%s\n' "$output" >&2
    return 1
  }
  no_mistakes_process_is_gone || {
    echo "error: task resources were reclaimed, but attributed agent pid $NM_AGENT_PID is still alive" >&2
    return 1
  }
  log_result "collected no-mistakes run $NM_RUN_ID for $AUTO_REAP_ID"
}

run_cleanup_marker() {
  printf '%s/.auto-reap-run-%s.pending' "$STATE" "$AUTO_REAP_ID"
}

prepare_run_cleanup_marker() {
  local marker tmp
  [ -n "$NM_RUN_ID" ] || return 0
  marker=$(run_cleanup_marker)
  if [ -L "$marker" ] || { [ -e "$marker" ] && [ ! -f "$marker" ]; }; then
    refuse "no-mistakes cleanup marker is unsafe"
    return 1
  fi
  tmp=$(mktemp "$STATE/.auto-reap-run-$AUTO_REAP_ID.XXXXXX") || {
    refuse "no-mistakes cleanup marker could not be staged"
    return 1
  }
  {
    printf 'run_id=%s\n' "$NM_RUN_ID"
    printf 'agent_pid=%s\n' "$NM_AGENT_PID"
    printf 'agent_start=%s\n' "$NM_AGENT_START"
  } > "$tmp" || {
    rm -f "$tmp"
    refuse "no-mistakes cleanup marker could not be written"
    return 1
  }
  mv "$tmp" "$marker" || {
    rm -f "$tmp"
    refuse "no-mistakes cleanup marker could not be installed"
    return 1
  }
}

clear_run_cleanup_marker() {
  local marker
  [ -n "$NM_RUN_ID" ] || return 0
  marker=$(run_cleanup_marker)
  if [ -L "$marker" ] || { [ -e "$marker" ] && [ ! -f "$marker" ]; }; then
    return 1
  fi
  rm -f "$marker"
}

validate_terminal_trigger() {
  [ "$KIND" != secondmate ] || {
    refuse "persistent secondmates are never automatically reclaimed"
    return 1
  }
  [ -z "$X_REQUEST" ] || {
    refuse "X-linked task still requires its final follow-up"
    return 1
  }
  case "$AUTO_REAP_TRIGGER:$KIND:$MODE" in
    pr-merged:ship:local-only)
      refuse "local-only tasks cannot use a PR-merged trigger"
      return 1
      ;;
    pr-merged:ship:*)
      require_status_verb "done" || return 1
      pr_is_merged || return 1
      ;;
    scout-done:scout:*)
      require_status_verb "done" || return 1
      require_current_state "done" || return 1
      [ -f "$DATA/$AUTO_REAP_ID/report.md" ] \
        && [ ! -L "$DATA/$AUTO_REAP_ID/report.md" ] \
        && [ -r "$DATA/$AUTO_REAP_ID/report.md" ] || {
        refuse "scout report is unavailable or unsafe"
        return 1
      }
      ;;
    failed:ship:*|failed:scout:*)
      require_status_verb failed || return 1
      require_current_state failed || return 1
      ;;
    local-merged:ship:local-only)
      require_status_verb "done" || return 1
      ;;
    *)
      refuse "terminal trigger does not match kind=$KIND mode=$MODE"
      return 1
      ;;
  esac
}

run_teardown() {
  local teardown output rc summary marker_prepared=0
  teardown=$(auto_reap_tool FM_AUTO_REAP_TEARDOWN_BIN "$SCRIPT_DIR/fm-teardown.sh") || {
    refuse "ordinary teardown is unavailable"
    return 1
  }
  if [ -n "$NM_RUN_ID" ]; then
    prepare_run_cleanup_marker || return 1
    marker_prepared=1
  fi
  if output=$("$teardown" "$AUTO_REAP_ID" 2>&1); then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    [ "$marker_prepared" -eq 0 ] || clear_run_cleanup_marker || true
    summary=$(printf '%s\n' "$output" | tail -n 8 | one_line)
    refuse "ordinary teardown refused (exit $rc)${summary:+: $summary}"
    return 1
  fi
  if ! collect_no_mistakes_run; then
    printf 'auto-reap collected task=%s trigger=%s; process cleanup incomplete for run=%s\n' \
      "$AUTO_REAP_ID" "$AUTO_REAP_TRIGGER" "${NM_RUN_ID:-unknown}"
    return 1
  fi
  clear_run_cleanup_marker || {
    echo "error: task resources and processes were collected, but the durable cleanup marker could not be cleared" >&2
    return 1
  }
  summary=$(printf '%s\n' "$output" | tail -1 | one_line)
  log_result "collected $AUTO_REAP_ID ($AUTO_REAP_TRIGGER), no-mistakes run ${NM_RUN_ID:-none}"
  printf 'auto-reap collected task=%s trigger=%s no-mistakes-run=%s%s\n' \
    "$AUTO_REAP_ID" "$AUTO_REAP_TRIGGER" "${NM_RUN_ID:-none}" \
    "${summary:+; $summary}"
}

reap_task() {  # <id> <trigger>
  AUTO_REAP_ID=$1
  AUTO_REAP_TRIGGER=$2
  load_task "$AUTO_REAP_ID" || return 1
  validate_terminal_trigger || return 1
  snapshot_no_mistakes_run || return 1
  run_teardown
}

if [ "$(uname)" = Darwin ]; then
  stat_signature() { stat -f '%z:%m' "$1" 2>/dev/null; }
  stat_mtime() { stat -f '%m' "$1" 2>/dev/null; }
else
  stat_signature() { stat -c '%s:%Y' "$1" 2>/dev/null; }
  stat_mtime() { stat -c '%Y' "$1" 2>/dev/null; }
fi

scan_signature() {  # <id> <trigger>
  local id=$1 trigger=$2 meta status
  local head dirty remotes
  meta="$STATE/$id.meta"
  status="$STATE/$id.status"
  head=$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || printf unknown)
  dirty=$(git -C "$WORKTREE" status --porcelain=v1 --untracked-files=all 2>/dev/null | cksum || printf unknown)
  remotes=$(git -C "$WORKTREE" for-each-ref --format='%(objectname)' refs/remotes 2>/dev/null | cksum || printf unknown)
  printf '%s|%s|%s|%s|%s|%s|%s' \
    "$id" "$trigger" "$(stat_signature "$meta" || printf unknown)" \
    "$(stat_signature "$status" || printf unknown)" "$head" "$dirty" "$remotes"
}

scan_marker_allows() {  # <id> <signature>
  local id=$1 signature=$2 marker recorded mtime age
  marker="$STATE/.auto-reap-refused-$id"
  [ ! -L "$marker" ] && { [ ! -e "$marker" ] || [ -f "$marker" ]; } || return 1
  [ -f "$marker" ] || return 0
  recorded=$(sed -n '1p' "$marker" 2>/dev/null || true)
  [ "$recorded" = "$signature" ] || return 0
  mtime=$(stat_mtime "$marker" || printf 0)
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  age=$(( $(date +%s) - mtime ))
  [ "$age" -ge "$AUTO_REAP_RETRY_SECS" ]
}

record_scan_refusal() {  # <id> <signature>
  local id=$1 signature=$2 marker tmp
  marker="$STATE/.auto-reap-refused-$id"
  [ ! -L "$marker" ] && { [ ! -e "$marker" ] || [ -f "$marker" ]; } || return 1
  tmp=$(mktemp "$STATE/.auto-reap-refused-$id.XXXXXX") || return 1
  printf '%s\n' "$signature" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$marker"
}

scan_task() {  # <id> <trigger>
  local id=$1 trigger=$2 signature output rc
  AUTO_REAP_ID=$id
  AUTO_REAP_TRIGGER=$trigger
  load_task "$id" || return 0
  signature=$(scan_signature "$id" "$trigger")
  scan_marker_allows "$id" "$signature" || return 0
  if output=$(reap_task "$id" "$trigger" 2>&1); then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    rm -f "$STATE/.auto-reap-refused-$id"
    printf '%s\n' "$output" | one_line
    return 0
  fi
  record_scan_refusal "$id" "$signature" || true
  printf '%s\n' "$output" | one_line
  return 0
}

scan_terminal_tasks() {
  local meta id kind status last verb pr_count
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    [ -f "$meta" ] && [ ! -L "$meta" ] && [ -r "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    fm_account_valid_id "$id" || continue
    kind=$(sed -n 's/^kind=//p' "$meta")
    [ -n "$kind" ] || kind=ship
    [ "$kind" != secondmate ] || continue
    status="$STATE/$id.status"
    [ -f "$status" ] && [ ! -L "$status" ] && [ -r "$status" ] || continue
    last=$(grep -v '^[[:space:]]*$' "$status" 2>/dev/null | tail -1)
    verb=$(status_line_verb "$last")
    case "$verb:$kind" in
      done:ship)
        if grep -qx 'mode=local-only' "$meta"; then
          scan_task "$id" local-merged
        else
          pr_count=$(grep -Ec '^pr=https://github\.com/[^/]+/[^/]+/pull/[0-9]+([/?#].*)?$' "$meta")
          [ "$pr_count" -eq 1 ] || continue
          scan_task "$id" pr-merged
        fi
        ;;
      done:scout) scan_task "$id" scout-done ;;
      failed:ship|failed:scout) scan_task "$id" failed ;;
    esac
  done
}

read_cleanup_field() {  # <marker> <key> <required:0|1>
  local marker=$1 key=$2 required=$3 values count
  values=$(sed -n "s/^${key}=//p" "$marker" 2>/dev/null)
  count=$(printf '%s\n' "$values" | awk 'NF { n++ } END { print n + 0 }')
  if [ "$count" -eq 0 ] && [ "$required" -eq 0 ]; then
    CLEANUP_FIELD=
    return 0
  fi
  [ "$count" -eq 1 ] || return 1
  CLEANUP_FIELD=$values
}

scan_orphaned_runs() {
  local marker id output
  for marker in "$STATE"/.auto-reap-run-*.pending; do
    [ -e "$marker" ] || continue
    [ -f "$marker" ] && [ ! -L "$marker" ] && [ -r "$marker" ] || continue
    id=${marker##*/.auto-reap-run-}
    id=${id%.pending}
    fm_account_valid_id "$id" || continue
    [ ! -e "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ] || continue
    AUTO_REAP_ID=$id
    AUTO_REAP_TRIGGER=orphan-process
    read_cleanup_field "$marker" run_id 1 || {
      refuse "durable no-mistakes cleanup marker is ambiguous"
      continue
    }
    NM_RUN_ID=$CLEANUP_FIELD
    case "$NM_RUN_ID" in ''|*[!A-Za-z0-9._-]*)
      refuse "durable no-mistakes run id is invalid"
      continue
      ;;
    esac
    read_cleanup_field "$marker" agent_pid 0 || {
      refuse "durable agent pid is ambiguous"
      continue
    }
    NM_AGENT_PID=$CLEANUP_FIELD
    read_cleanup_field "$marker" agent_start 0 || {
      refuse "durable agent identity is ambiguous"
      continue
    }
    NM_AGENT_START=$CLEANUP_FIELD
    if [ -z "$NM_AGENT_PID" ] && [ -z "$NM_AGENT_START" ]; then
      :
    elif [ -n "$NM_AGENT_START" ]; then
      case "$NM_AGENT_PID" in
        ''|*[!0-9]*)
          refuse "durable agent process identity is invalid"
          continue
          ;;
      esac
    else
        refuse "durable agent process identity is invalid"
        continue
    fi
    if output=$(collect_no_mistakes_run 2>&1); then
      rm -f "$marker"
      printf 'auto-reap collected orphan task=%s no-mistakes-run=%s%s\n' \
        "$id" "$NM_RUN_ID" "${output:+; $(printf '%s\n' "$output" | one_line)}"
    else
      printf '%s\n' "$output" | one_line
    fi
  done
}

case "${1:-}" in
  task)
    [ "$#" -eq 3 ] || {
      echo "usage: fm-auto-reap.sh task <id> <pr-merged|scout-done|failed|local-merged>" >&2
      exit 2
    }
    case "$3" in pr-merged|scout-done|failed|local-merged) ;; *)
      echo "error: unknown auto-reap trigger: $3" >&2
      exit 2
      ;;
    esac
    reap_task "$2" "$3"
    ;;
  scan)
    [ "$#" -eq 1 ] || { echo "usage: fm-auto-reap.sh scan" >&2; exit 2; }
    scan_orphaned_runs
    scan_terminal_tasks
    ;;
  *)
    echo "usage: fm-auto-reap.sh task <id> <trigger> | scan" >&2
    exit 2
    ;;
esac
