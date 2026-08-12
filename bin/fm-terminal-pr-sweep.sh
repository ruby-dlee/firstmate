#!/usr/bin/env bash
# Sweep terminal ship lanes in this Firstmate home and every registered direct
# secondmate home.
#
# An already merged PR is sent straight through ordinary fm-teardown.sh without
# --force.
# An open PR is eligible only when the live gh-axi adapter reports every check
# passing and GitHub reports it mergeable.
# For yolo=on, fm-pr-merge.sh remains the sole merge path and therefore owns the
# exact-head Crosscheck, draft, and atomic merge-or-enqueue gates.
# For yolo=off, the sweep reports the merge-ready PR for the captain and does not
# invoke any merge command.
# A gate refusal containing AUTHOR IDENTITY UNKNOWABLE is reported as
# unmergeable-as-authored with re-authoring takeover as the required action;
# the sweep never adds an admission or routes around Crosscheck.
# Red, pending, draft, closed, unmergeable, and unreviewed PRs are never merged.
#
# The periodic path deduplicates unchanged reports while continuing to retry
# guarded merge and teardown operations, so one durable wake does not become a
# watcher loop.
# --dry-run performs only live read-only PR inspection and prints conditional
# merge and reap actions without locks, markers, merges, or teardowns.
#
# Usage: fm-terminal-pr-sweep.sh [--dry-run]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
DRY_RUN=0
ACTIVE_SWEEP_LOCK=

case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=1 ;;
  *) echo "usage: fm-terminal-pr-sweep.sh [--dry-run]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "usage: fm-terminal-pr-sweep.sh [--dry-run]" >&2; exit 2; }

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
# shellcheck source=bin/fm-account-routing-lib.sh
. "$SCRIPT_DIR/fm-account-routing-lib.sh"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

release_sweep_lock() {
  [ -z "$ACTIVE_SWEEP_LOCK" ] \
    || fm_account_lifecycle_lock_release "$ACTIVE_SWEEP_LOCK" >/dev/null 2>&1 \
    || true
  ACTIVE_SWEEP_LOCK=
}
trap release_sweep_lock EXIT

sweep_tool() {  # <override-variable> <default-path>
  local variable=$1 fallback=$2 value
  eval "value=\${$variable:-}"
  if [ -n "$value" ]; then
    [ "${FM_TERMINAL_PR_SWEEP_TEST_HOOKS:-}" = firstmate-terminal-pr-sweep-tests-v1 ] || {
      echo "error: $variable requires the explicit terminal PR sweep test hook" >&2
      return 1
    }
    [ -x "$value" ] || return 1
    printf '%s\n' "$value"
    return 0
  fi
  [ -x "$fallback" ] || return 1
  printf '%s\n' "$fallback"
}

GITHUB_PR=$(sweep_tool FM_TERMINAL_PR_SWEEP_GITHUB_PR_BIN "$SCRIPT_DIR/fm-github-pr.py") || {
  echo "error: GitHub PR readiness adapter is unavailable" >&2
  exit 1
}
PR_MERGE=$(sweep_tool FM_TERMINAL_PR_SWEEP_PR_MERGE_BIN "$SCRIPT_DIR/fm-pr-merge.sh") || {
  echo "error: PR merge gate is unavailable" >&2
  exit 1
}
TEARDOWN=$(sweep_tool FM_TERMINAL_PR_SWEEP_TEARDOWN_BIN "$SCRIPT_DIR/fm-teardown.sh") || {
  echo "error: ordinary teardown is unavailable" >&2
  exit 1
}

meta_value() {  # <meta> <key>
  sed -n "s/^$2=//p" "$1" | tail -1
}

single_meta_value() {  # <meta> <key>
  local meta=$1 key=$2 count
  count=$(grep -c "^${key}=" "$meta" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  sed -n "s/^${key}=//p" "$meta"
}

status_last_verb() {  # <state> <task>
  local state=$1 task=$2 line verb
  line=$(grep -v '^[[:space:]]*$' "$state/$task.status" 2>/dev/null | tail -1)
  verb=${line%%:*}
  verb=${verb%%\[key=*}
  printf '%s' "$verb" | tr -d '[:space:]'
}

valid_pr_url() {  # <url>
  [[ "$1" =~ ^https://github\.com/[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]+/pull/[0-9]+/?$ ]]
}

scoped_command() {  # <home> <state> <data> <command> [args...]
  local home=$1 state=$2 data=$3
  shift 3
  FM_HOME="$home" \
  FM_STATE_OVERRIDE="$state" \
  FM_DATA_OVERRIDE="$data" \
  FM_CONFIG_OVERRIDE="$home/config" \
  FM_PROJECTS_OVERRIDE="$home/projects" \
    "$@"
}

observation_marker() {  # <state> <task>
  printf '%s/.terminal-pr-sweep-observed-%s' "$1" "$2"
}

clear_observation() {  # <state> <task>
  local marker
  [ "$DRY_RUN" -eq 0 ] || return 0
  marker=$(observation_marker "$1" "$2")
  if [ -L "$marker" ] || { [ -e "$marker" ] && [ ! -f "$marker" ]; }; then
    echo "error: unsafe terminal PR sweep marker for $2 at $marker" >&2
    return 1
  fi
  rm -f "$marker"
}

emit_once() {  # <state> <task> <signature> <line>
  local state=$1 task=$2 signature=$3 line=$4 marker current tmp
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\n' "$line"
    return 0
  fi
  marker=$(observation_marker "$state" "$task")
  if [ -L "$marker" ] || { [ -e "$marker" ] && [ ! -f "$marker" ]; }; then
    echo "error: unsafe terminal PR sweep marker for $task at $marker" >&2
    return 1
  fi
  current=$(cat "$marker" 2>/dev/null || true)
  [ "$current" != "$signature" ] || return 0
  printf '%s\n' "$line"
  tmp=$(mktemp "$state/.terminal-pr-sweep-observed-$task.XXXXXX") || return 1
  if ! printf '%s\n' "$signature" > "$tmp" || ! mv "$tmp" "$marker"; then
    rm -f "$tmp"
    return 1
  fi
}

diagnostic_line() {  # <captured-output>
  printf '%s' "$1" | tr '\r\n' '  ' | cut -c1-400
}

retire_merged_check() {  # <state> <task>
  local check="$1/$2.check.sh"
  [ "$DRY_RUN" -eq 0 ] || return 0
  if [ -L "$check" ] || { [ -e "$check" ] && [ ! -f "$check" ]; }; then
    echo "error: unsafe merged-PR check for $2 at $check" >&2
    return 1
  fi
  rm -f "$check"
}

readiness_for() {  # <url>
  local output state head extra
  output=$("$GITHUB_PR" merge-readiness "$1" 2>&1) || {
    READINESS_ERROR=$(diagnostic_line "$output")
    return 1
  }
  state=${output%% *}
  head=${output#* }
  extra=${head#* }
  [ "$head" = "$extra" ] || return 1
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || return 1
  case "$state" in
    READY|MERGED|RED|PENDING|DRAFT|CLOSED|BLOCKED|UNKNOWN) ;;
    *) return 1 ;;
  esac
  PR_READINESS=$state
  PR_HEAD=$head
}

reap_confirmed() {  # <label> <home> <state> <data> <task> <url> <head> <merged-here:0|1>
  local label=$1 home=$2 state=$3 data=$4 task=$5 url=$6 head=$7 merged_here=$8 output detail status
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'would-reap: %s %s %s (ordinary teardown after confirmed merge)\n' \
      "$label" "$task" "$url"
    return 0
  fi
  retire_merged_check "$state" "$task" || {
    emit_once "$state" "$task" "check-retire-refused|$url|$head" \
      "retained: $label $task $url (confirmed-merge check could not be retired safely)"
    return 0
  }
  [ "$merged_here" -ne 1 ] \
    || printf 'merged: %s %s %s\n' "$label" "$task" "$url"
  if output=$(scoped_command "$home" "$state" "$data" "$TEARDOWN" "$task" 2>&1); then
    printf 'reaped: %s %s %s\n' "$label" "$task" "$url"
    clear_observation "$state" "$task" || true
    return 0
  else
    status=$?
  fi
  detail=$(diagnostic_line "$output")
  if [ "$status" -eq 75 ]; then
    emit_once "$state" "$task" "teardown-retry|$url|$head" \
      "retry: $label $task $url (ordinary teardown is temporarily blocked: ${detail:-no diagnostic})"
    return 0
  fi
  emit_once "$state" "$task" "teardown-refused|$url|$head" \
    "retained: $label $task $url (ordinary teardown refused: ${detail:-no diagnostic})"
}

process_candidate() {  # <label> <home> <state> <data> <meta>
  local label=$1 home=$2 state=$3 data=$4 meta=$5 task kind mode yolo url
  local merge_output post_detail
  task=${meta##*/}
  task=${task%.meta}
  fm_account_valid_id "$task" || return 0
  [ "$(status_last_verb "$state" "$task")" = "done" ] || return 0
  kind=$(meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  [ "$kind" = ship ] || return 0
  mode=$(meta_value "$meta" mode)
  [ "$mode" != local-only ] || return 0
  [ -z "$(meta_value "$meta" x_request)" ] || return 0
  if ! url=$(single_meta_value "$meta" pr) || ! valid_pr_url "$url"; then
    return 0
  fi
  yolo=$(meta_value "$meta" yolo)
  [ -n "$yolo" ] || yolo=off
  case "$yolo" in
    on|off) ;;
    *)
      emit_once "$state" "$task" "invalid-yolo|$url|$yolo" \
        "retained: $label $task $url (invalid yolo metadata; no merge attempted)"
      return 0
      ;;
  esac

  READINESS_ERROR=
  if ! readiness_for "$url"; then
    emit_once "$state" "$task" "unreviewed|$url" \
      "retained: $label $task $url (live PR readiness is unreviewed: ${READINESS_ERROR:-invalid adapter response})"
    return 0
  fi

  case "$PR_READINESS" in
    MERGED)
      reap_confirmed "$label" "$home" "$state" "$data" "$task" "$url" "$PR_HEAD" 0
      ;;
    READY)
      if [ "$yolo" = off ]; then
        emit_once "$state" "$task" "captain|$url|$PR_HEAD" \
          "captain: $label $task $url (merge-ready; yolo=off)"
        return 0
      fi
      if [ "$DRY_RUN" -eq 1 ]; then
        printf 'would-merge: %s %s %s (through fm-pr-merge.sh)\n' \
          "$label" "$task" "$url"
        reap_confirmed "$label" "$home" "$state" "$data" "$task" "$url" "$PR_HEAD" 1
        return 0
      fi
      if ! merge_output=$(scoped_command "$home" "$state" "$data" "$PR_MERGE" "$task" "$url" 2>&1); then
        post_detail=$(diagnostic_line "$merge_output")
        if [[ "$merge_output" == *"AUTHOR IDENTITY UNKNOWABLE"* ]]; then
          emit_once "$state" "$task" "unmergeable-as-authored|$url|$PR_HEAD" \
            "unmergeable-as-authored: $label $task $url (Crosscheck cannot prove the author identity; re-authoring takeover is required under a newly launch-bound author lane, with a replacement commit published to the existing PR branch)"
          return 0
        fi
        emit_once "$state" "$task" "merge-refused|$url|$PR_HEAD" \
          "blocked: $label $task $url (fm-pr-merge.sh refused: ${post_detail:-no diagnostic})"
        return 0
      fi
      READINESS_ERROR=
      if ! readiness_for "$url"; then
        emit_once "$state" "$task" "merge-unconfirmed|$url|$PR_HEAD" \
          "retained: $label $task $url (merge gate returned, but merged state is unconfirmed: ${READINESS_ERROR:-invalid adapter response})"
        return 0
      fi
      if [ "$PR_READINESS" = MERGED ]; then
        reap_confirmed "$label" "$home" "$state" "$data" "$task" "$url" "$PR_HEAD" 1
      else
        emit_once "$state" "$task" "enqueued|$url|$PR_HEAD|$PR_READINESS" \
          "enqueued: $label $task $url (not reaped until GitHub confirms merged)"
      fi
      ;;
    RED)
      emit_once "$state" "$task" "red|$url|$PR_HEAD" \
        "retained: $label $task $url (red PR checks; never merged)"
      ;;
    PENDING)
      emit_once "$state" "$task" "pending|$url|$PR_HEAD" \
        "retained: $label $task $url (PR checks are pending)"
      ;;
    DRAFT)
      emit_once "$state" "$task" "draft|$url|$PR_HEAD" \
        "retained: $label $task $url (draft PR)"
      ;;
    CLOSED)
      emit_once "$state" "$task" "closed|$url|$PR_HEAD" \
        "retained: $label $task $url (PR closed without merge)"
      ;;
    BLOCKED)
      emit_once "$state" "$task" "github-blocked|$url|$PR_HEAD" \
        "retained: $label $task $url (GitHub reports the PR unmergeable)"
      ;;
    UNKNOWN)
      emit_once "$state" "$task" "unknown|$url|$PR_HEAD" \
        "retained: $label $task $url (GitHub mergeability is not yet known)"
      ;;
  esac
}

process_home() {  # <label> <home> <state> <data>
  local label=$1 home=$2 state=$3 data=$4 meta lock
  [ -d "$state" ] && [ ! -L "$state" ] || {
    echo "terminal-pr-sweep: skipped $label: unsafe state directory $state" >&2
    return 0
  }
  [ -d "$data" ] && [ ! -L "$data" ] || {
    echo "terminal-pr-sweep: skipped $label: unsafe data directory $data" >&2
    return 0
  }
  if [ "$DRY_RUN" -eq 0 ]; then
    lock=$(fm_account_lock_acquire "$state" terminal-pr-sweep terminal-pr-sweep \
      "terminal PR sweep" 0 2>/dev/null || true)
    [ -n "$lock" ] || return 0
    ACTIVE_SWEEP_LOCK=$lock
  fi
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    process_candidate "$label" "$home" "$state" "$data" "$meta"
  done
  release_sweep_lock
}

FM_HOME_REAL=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || {
  echo "error: active Firstmate home is unavailable: $FM_HOME" >&2
  exit 1
}
process_home primary "$FM_HOME_REAL" "$STATE" "$DATA"

REGISTRY="$DATA/secondmates.md"
if [ -e "$REGISTRY" ] || [ -L "$REGISTRY" ]; then
  [ -f "$REGISTRY" ] && [ ! -L "$REGISTRY" ] || {
    echo "error: unsafe secondmate registry: $REGISTRY" >&2
    exit 1
  }
  SEEN_HOMES="
$FM_HOME_REAL
"
  while IFS= read -r registry_line; do
    case "$registry_line" in -\ *) ;; *) continue ;; esac
    secondmate_id=${registry_line#- }
    secondmate_id=${secondmate_id%% *}
    fm_account_valid_id "$secondmate_id" || continue
    secondmate_home=$(printf '%s\n' "$registry_line" \
      | sed -n 's/.*(home:[[:space:]]*\([^;)]*\);.*/\1/p' \
      | sed 's/[[:space:]]*$//')
    [ -n "$secondmate_home" ] || {
      echo "terminal-pr-sweep: skipped secondmate:$secondmate_id: registry home is missing" >&2
      continue
    }
    if ! validate_secondmate_home "$secondmate_id" "$secondmate_home"; then
      echo "terminal-pr-sweep: skipped secondmate:$secondmate_id: $VALIDATION_ERROR" >&2
      continue
    fi
    case "$SEEN_HOMES" in
      *$'\n'"$VALIDATED_HOME"$'\n'*) continue ;;
    esac
    SEEN_HOMES="$SEEN_HOMES$VALIDATED_HOME
"
    process_home "secondmate:$secondmate_id" "$VALIDATED_HOME" \
      "$VALIDATED_HOME/state" "$VALIDATED_HOME/data"
  done < "$REGISTRY"
fi
