#!/usr/bin/env bash
# Build one provider-neutral continuation packet for a managed task.
# Usage: fm-account-continuation.sh <task-id> <new-attempt-id>
#
# The packet is task-owned state under data/<id>/ and is the only prompt used
# for a fresh cross-profile continuation.
# It requires a dead recorded endpoint, an inspectable original worktree/home,
# a non-empty original brief or charter, and a verified repository snapshot.
# It carries available task-owned status, reports, decisions, steering,
# checkpoint, account-lineage, PR, and no-mistakes state without reading or
# copying provider homes, credentials, or transcripts.
# The continuation precedence is live external state, verified repository
# state, checkpoint/handoff intent, then recalled provider context.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
PACKET_TMP=
STATUS_SNAPSHOT_TMP=
LOG_SNAPSHOT_TMP=
META_SNAPSHOT_TMP=
NO_MISTAKES_STATUS_TMP=
MAX_PACKET_BYTES=65536
MAX_SNAPSHOT_BYTES=8192
NO_MISTAKES_STATUS_TIMEOUT=${FM_ACCOUNT_CONTINUATION_STATUS_TIMEOUT:-5}
cleanup_packet_tmp() {
  [ -z "$PACKET_TMP" ] || rm -f "$PACKET_TMP"
  [ -z "$STATUS_SNAPSHOT_TMP" ] || rm -f "$STATUS_SNAPSHOT_TMP"
  [ -z "$LOG_SNAPSHOT_TMP" ] || rm -f "$LOG_SNAPSHOT_TMP"
  [ -z "$META_SNAPSHOT_TMP" ] || rm -f "$META_SNAPSHOT_TMP"
  [ -z "$NO_MISTAKES_STATUS_TMP" ] || rm -f "$NO_MISTAKES_STATUS_TMP"
}
trap cleanup_packet_tmp EXIT
# shellcheck source=bin/fm-account-routing-lib.sh
. "$SCRIPT_DIR/fm-account-routing-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

ID=${1:-}
ATTEMPT=${2:-}
[ -n "$ID" ] && [ -n "$ATTEMPT" ] || { echo "usage: fm-account-continuation.sh <task-id> <new-attempt-id>" >&2; exit 2; }
case "$NO_MISTAKES_STATUS_TIMEOUT" in
  ''|*[!0-9]*|0) echo "error: FM_ACCOUNT_CONTINUATION_STATUS_TIMEOUT must be a positive integer" >&2; exit 2 ;;
esac
fm_account_valid_id "$ID" || { echo "error: invalid task id '$ID'" >&2; exit 1; }
fm_account_valid_id "$ATTEMPT" || { echo "error: invalid account attempt '$ATTEMPT'" >&2; exit 1; }

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || { echo "error: no safe managed metadata for continuation at $META" >&2; exit 1; }
PROFILE=$(fm_meta_get "$META" account_profile)
POOL=$(fm_meta_get "$META" account_pool)
HARNESS=$(fm_meta_get "$META" harness)
ACCOUNT_TASK=$(fm_meta_get "$META" account_task)
[ -n "$ACCOUNT_TASK" ] || ACCOUNT_TASK=$ID
[ -n "$PROFILE" ] && [ -n "$POOL" ] || { echo "error: task $ID is not a managed account task" >&2; exit 1; }
case "$HARNESS" in claude|codex) ;; *) echo "error: provider-neutral continuation supports only claude and codex" >&2; exit 1 ;; esac

KIND=$(fm_meta_get "$META" kind)
[ -n "$KIND" ] || KIND=ship
BACKEND=$(fm_backend_of_meta "$META")
TARGET=$(fm_backend_target_of_meta "$META")
SECONDMATE_HOME=$(fm_meta_get "$META" home)
[ -n "$SECONDMATE_HOME" ] || SECONDMATE_HOME=$(fm_meta_get "$META" worktree)
PROBE_HOME=$(fm_backend_endpoint_home "$BACKEND" "$KIND" "$FM_HOME" "$SECONDMATE_HOME")
if [ "$PROBE_HOME" = "$FM_HOME" ]; then
  ENDPOINT_STATE=$(fm_backend_target_state "$BACKEND" "$TARGET" "fm-$ID" 2>/dev/null)
else
  ENDPOINT_STATE=$(unset FM_ROOT_OVERRIDE; FM_HOME="$PROBE_HOME" FM_ROOT="$PROBE_HOME" fm_backend_target_state "$BACKEND" "$TARGET" "fm-$ID" 2>/dev/null)
fi
case "$ENDPOINT_STATE" in
  absent) ;;
  present) echo "error: managed continuation endpoint is still alive for $ID" >&2; exit 1 ;;
  *) echo "error: managed continuation endpoint state is unknown for $ID" >&2; exit 1 ;;
esac

WORKTREE=$(fm_meta_get "$META" worktree)
PROJECT=$(fm_meta_get "$META" project)
[ -n "$WORKTREE" ] && [ -d "$WORKTREE" ] || { echo "error: recorded continuation worktree/home is unavailable for $ID" >&2; exit 1; }
WORKTREE_REAL=$(cd "$WORKTREE" && pwd -P)
TOP=$(git -C "$WORKTREE_REAL" rev-parse --show-toplevel 2>/dev/null) || { echo "error: continuation worktree is not inspectable for $ID" >&2; exit 1; }
TOP_REAL=$(cd "$TOP" && pwd -P)
[ "$TOP_REAL" = "$WORKTREE_REAL" ] || { echo "error: continuation path is not the recorded worktree root for $ID" >&2; exit 1; }
HEAD=$(git -C "$WORKTREE_REAL" rev-parse HEAD 2>/dev/null) || { echo "error: cannot verify continuation HEAD for $ID" >&2; exit 1; }
BRANCH=$(git -C "$WORKTREE_REAL" branch --show-current 2>/dev/null)
[ -n "$BRANCH" ] || BRANCH=detached

continuation_safe_file() {
  local file=$1 root=$2 parent root_real resolved
  [ -s "$file" ] && [ -f "$file" ] && [ ! -L "$file" ] || return 1
  parent=$(cd "$(dirname "$file")" && pwd -P) || return 1
  root_real=$(cd "$root" && pwd -P) || return 1
  resolved="$parent/$(basename "$file")"
  case "$resolved" in "$root_real"/*) printf '%s\n' "$resolved" ;; *) return 1 ;; esac
}

TASK_DIR=$(fm_account_task_dir "$DATA" "$ID" create) \
  || { echo "error: continuation task directory is unsafe for $ID" >&2; exit 1; }

if [ "$KIND" = secondmate ] && [ -e "$WORKTREE_REAL/data/charter.md" ]; then
  BRIEF=$(continuation_safe_file "$WORKTREE_REAL/data/charter.md" "$WORKTREE_REAL") || BRIEF=
else
  BRIEF=$(continuation_safe_file "$TASK_DIR/brief.md" "$TASK_DIR") || BRIEF=
fi
[ -n "$BRIEF" ] || { echo "error: no safe non-empty original brief or charter for continuation of $ID" >&2; exit 1; }

PACKET="$TASK_DIR/continuation-$ATTEMPT.md"
PACKET_TMP=$(mktemp "$TASK_DIR/.continuation-$ATTEMPT.XXXXXX") \
  || { echo "error: cannot safely stage continuation packet for $ID" >&2; exit 1; }

packet_bytes() {
  local bytes
  bytes=$(wc -c < "$PACKET_TMP" | tr -d '[:space:]')
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$bytes"
}

packet_size_error() {
  echo "error: continuation packet for $ID is $1 bytes; maximum is $MAX_PACKET_BYTES" >&2
  return 1
}

packet_check_budget() {
  local bytes
  bytes=$(packet_bytes) || { echo "error: cannot measure continuation packet for $ID" >&2; return 1; }
  [ "$bytes" -le "$MAX_PACKET_BYTES" ] || packet_size_error "$bytes"
}

snapshot_bytes() {
  local file=$1 bytes
  bytes=$(wc -c < "$file" | tr -d '[:space:]')
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$bytes"
}

capture_command_snapshot() {
  local file=$1 failure_mode=$2 command_rc head_rc bytes
  local pipeline_status
  shift 2
  set +e
  "$@" 2>&1 | head -c "$((MAX_SNAPSHOT_BYTES + 1))" > "$file"
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  command_rc=${pipeline_status[0]:-1}
  head_rc=${pipeline_status[1]:-1}
  [ "$head_rc" -eq 0 ] || return "$head_rc"
  bytes=$(snapshot_bytes "$file") || return 1
  if [ "$command_rc" -eq 0 ] \
    || { [ "$command_rc" -eq 141 ] && [ "$bytes" -gt "$MAX_SNAPSHOT_BYTES" ]; }; then
    return 0
  fi
  [ "$failure_mode" = unavailable ] || return "$command_rc"
  printf 'unavailable\n' > "$file"
}

capture_file_snapshot() {
  local file=$1 source=$2
  head -c "$((MAX_SNAPSHOT_BYTES + 1))" "$source" > "$file"
}

append_snapshot_section() {
  local heading=$1 file=$2 current source_bytes data_bytes framing_bytes projected truncated
  current=$(packet_bytes) || { echo "error: cannot measure continuation packet for $ID" >&2; return 1; }
  source_bytes=$(snapshot_bytes "$file") || { echo "error: cannot measure continuation snapshot $file" >&2; return 1; }
  data_bytes=$source_bytes
  truncated=0
  if [ "$data_bytes" -gt "$MAX_SNAPSHOT_BYTES" ]; then
    data_bytes=$MAX_SNAPSHOT_BYTES
    truncated=1
  fi
  framing_bytes=$({
    printf '\n## %s\n\n```text\n' "$heading"
    if [ "$truncated" -eq 1 ]; then
      printf '\n[Snapshot truncated at %s bytes.]\n```\n' "$MAX_SNAPSHOT_BYTES"
    else
      printf '\n```\n'
    fi
  } | wc -c | tr -d '[:space:]')
  case "$framing_bytes" in ''|*[!0-9]*) echo "error: cannot measure continuation snapshot framing" >&2; return 1 ;; esac
  projected=$((current + data_bytes + framing_bytes))
  [ "$projected" -le "$MAX_PACKET_BYTES" ] || packet_size_error "$projected"
  {
    printf '\n## %s\n\n```text\n' "$heading"
    [ "$data_bytes" -eq 0 ] || head -c "$data_bytes" "$file"
    if [ "$truncated" -eq 1 ]; then
      printf '\n[Snapshot truncated at %s bytes.]\n```\n' "$MAX_SNAPSHOT_BYTES"
    else
      printf '\n```\n'
    fi
  } >> "$PACKET_TMP"
  packet_check_budget
}

append_file_section() {  # <heading> <file>
  local heading=$1 file=$2 current file_bytes framing_bytes projected copy_start copy_end copied copy_rc
  [ -f "$file" ] || return 0
  [ ! -L "$file" ] || { echo "error: refusing symlinked continuation source $file" >&2; return 1; }
  current=$(packet_bytes) || { echo "error: cannot measure continuation packet for $ID" >&2; return 1; }
  file_bytes=$(wc -c < "$file" | tr -d '[:space:]')
  framing_bytes=$(printf '\n## %s\n\n\n' "$heading" | wc -c | tr -d '[:space:]')
  case "$file_bytes$framing_bytes" in *[!0-9]*) echo "error: cannot measure continuation source $file" >&2; return 1 ;; esac
  projected=$((current + file_bytes + framing_bytes))
  [ "$projected" -le "$MAX_PACKET_BYTES" ] || packet_size_error "$projected"
  printf '\n## %s\n\n' "$heading" >> "$PACKET_TMP" || return 1
  copy_start=$(packet_bytes) || { echo "error: cannot measure continuation packet for $ID" >&2; return 1; }
  set +e
  head -c "$((file_bytes + 1))" "$file" >> "$PACKET_TMP"
  copy_rc=$?
  set -e
  [ "$copy_rc" -eq 0 ] || { echo "error: cannot copy continuation source $file" >&2; return 1; }
  copy_end=$(packet_bytes) || { echo "error: cannot measure continuation packet for $ID" >&2; return 1; }
  copied=$((copy_end - copy_start))
  [ "$copied" -eq "$file_bytes" ] || packet_size_error "$((current + framing_bytes + copied))"
  printf '\n' >> "$PACKET_TMP" || return 1
  packet_check_budget
}

{
  printf '# Provider-neutral continuation for %s\n\n' "$ID"
  printf 'This is a fresh provider session for the same Firstmate task, not a replay from the beginning.\n'
  printf 'Re-verify live external state before acting, then trust current repository state, then explicit checkpoint and handoff intent, and use recalled provider context only as a final aid.\n'
  printf 'Do not repeat completed side effects unless current external and repository evidence proves they did not land.\n'
  printf 'Continue in the recorded worktree and preserve its branch, commits, uncommitted changes, task identity, and delivery state.\n\n'
  printf '## Verified continuation anchor\n\n'
  printf -- "- Task: \`%s\`\n" "$ID"
  printf -- "- New attempt: \`%s\`\n" "$ATTEMPT"
  printf -- "- Previous Agent Fleet task: \`%s\`\n" "$ACCOUNT_TASK"
  printf -- "- Previous provider/profile/pool: \`%s\` / \`%s\` / \`%s\`\n" "$HARNESS" "$PROFILE" "$POOL"
  printf -- "- Recorded endpoint: dead (\`%s\`, \`%s\`)\n" "$BACKEND" "${TARGET:-none}"
  printf -- "- Worktree: \`%s\`\n" "$WORKTREE_REAL"
  printf -- "- Project: \`%s\`\n" "$PROJECT"
  printf -- "- Branch: \`%s\`\n" "$BRANCH"
  printf -- "- HEAD: \`%s\`\n" "$HEAD"
} >> "$PACKET_TMP"
packet_check_budget

STATUS_SNAPSHOT_TMP=$(mktemp "$TASK_DIR/.continuation-status.XXXXXX") || STATUS_SNAPSHOT_TMP=
LOG_SNAPSHOT_TMP=$(mktemp "$TASK_DIR/.continuation-log.XXXXXX") || LOG_SNAPSHOT_TMP=
META_SNAPSHOT_TMP=$(mktemp "$TASK_DIR/.continuation-meta.XXXXXX") || META_SNAPSHOT_TMP=
NO_MISTAKES_STATUS_TMP=$(mktemp "$TASK_DIR/.continuation-no-mistakes.XXXXXX") || NO_MISTAKES_STATUS_TMP=
if [ -z "$STATUS_SNAPSHOT_TMP" ] || [ -z "$LOG_SNAPSHOT_TMP" ] \
  || [ -z "$META_SNAPSHOT_TMP" ] || [ -z "$NO_MISTAKES_STATUS_TMP" ]; then
  echo "error: cannot safely stage continuation snapshots for $ID" >&2
  exit 1
fi

capture_command_snapshot "$STATUS_SNAPSHOT_TMP" fatal git -C "$WORKTREE_REAL" status --short --branch \
  || { echo "error: cannot snapshot continuation repository status for $ID" >&2; exit 1; }
append_snapshot_section "Verified repository status" "$STATUS_SNAPSHOT_TMP"

capture_command_snapshot "$LOG_SNAPSHOT_TMP" fatal git -C "$WORKTREE_REAL" log --oneline --decorate -20 \
  || { echo "error: cannot snapshot continuation repository history for $ID" >&2; exit 1; }
append_snapshot_section "Recent repository history" "$LOG_SNAPSHOT_TMP"

capture_file_snapshot "$META_SNAPSHOT_TMP" "$META" \
  || { echo "error: cannot snapshot continuation metadata for $ID" >&2; exit 1; }
append_snapshot_section "Recorded task metadata" "$META_SNAPSHOT_TMP"

if NO_MISTAKES_BIN=$(command -v no-mistakes 2>/dev/null); then
  run_no_mistakes_status() {
    cd "$WORKTREE_REAL" && fm_account_run_bounded "$NO_MISTAKES_STATUS_TIMEOUT" "$NO_MISTAKES_BIN" axi status
  }
  capture_command_snapshot "$NO_MISTAKES_STATUS_TMP" unavailable run_no_mistakes_status \
    || { echo "error: cannot bound continuation no-mistakes snapshot for $ID" >&2; exit 1; }
  [ -s "$NO_MISTAKES_STATUS_TMP" ] || printf 'unavailable\n' > "$NO_MISTAKES_STATUS_TMP"
else
  printf 'unavailable\n' > "$NO_MISTAKES_STATUS_TMP"
fi
append_snapshot_section "No-mistakes state" "$NO_MISTAKES_STATUS_TMP"

append_file_section "Original brief or charter" "$BRIEF"
append_file_section "Wake-event and progress status" "$STATE/$ID.status"
append_file_section "Task report" "$TASK_DIR/report.md"
append_file_section "Completion report" "$TASK_DIR/completion.md"
append_file_section "Decisions" "$TASK_DIR/decisions.md"
append_file_section "Steering trail" "$TASK_DIR/steering.md"
append_file_section "Pending steering audit" "$TASK_DIR/steering-pending.md"
append_file_section "Completed side effects" "$TASK_DIR/side-effects.md"
append_file_section "Do not rerun" "$TASK_DIR/do-not-rerun.md"
append_file_section "Next action" "$TASK_DIR/next-action.md"
append_file_section "Checkpoint" "$TASK_DIR/checkpoint.md"
append_file_section "Handoff" "$TASK_DIR/handoff.md"
append_file_section "Recalled context" "$TASK_DIR/recalled.md"
append_file_section "Provider transcript summary" "$TASK_DIR/transcript-summary.md"
append_file_section "Account attempt lineage" "$TASK_DIR/account-attempts.md"

packet_check_budget
if [ -L "$PACKET" ] || { [ -e "$PACKET" ] && [ ! -f "$PACKET" ]; }; then
  echo "error: unsafe continuation packet destination for $ID" >&2
  exit 1
fi
mv "$PACKET_TMP" "$PACKET" || exit 1
PACKET_TMP=
printf '%s\n' "$PACKET"
