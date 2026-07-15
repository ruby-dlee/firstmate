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
PACKET_TMP=
MAX_PACKET_BYTES=65536
cleanup_packet_tmp() {
  [ -z "$PACKET_TMP" ] || rm -f "$PACKET_TMP"
}
trap cleanup_packet_tmp EXIT
# shellcheck source=bin/fm-account-routing-lib.sh
. "$SCRIPT_DIR/fm-account-routing-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

ID=${1:-}
ATTEMPT=${2:-}
[ -n "$ID" ] && [ -n "$ATTEMPT" ] || { echo "usage: fm-account-continuation.sh <task-id> <new-attempt-id>" >&2; exit 2; }
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
PACKET_TMP="$TASK_DIR/.continuation-$ATTEMPT.md.$$"
[ ! -e "$PACKET_TMP" ] && [ ! -L "$PACKET_TMP" ] \
  || { echo "error: unsafe continuation packet staging path for $ID" >&2; exit 1; }
( set -o noclobber; : > "$PACKET_TMP" ) 2>/dev/null \
  || { echo "error: cannot safely stage continuation packet for $ID" >&2; exit 1; }

STATUS_SNAPSHOT=$(git -C "$WORKTREE_REAL" status --short --branch 2>&1) || { echo "error: cannot snapshot continuation repository status for $ID" >&2; exit 1; }
LOG_SNAPSHOT=$(git -C "$WORKTREE_REAL" log --oneline --decorate -20 2>&1) || { echo "error: cannot snapshot continuation repository history for $ID" >&2; exit 1; }
NO_MISTAKES_STATUS=unavailable
if command -v no-mistakes >/dev/null 2>&1; then
  NO_MISTAKES_STATUS=$(cd "$WORKTREE_REAL" && no-mistakes axi status 2>&1 || true)
  [ -n "$NO_MISTAKES_STATUS" ] || NO_MISTAKES_STATUS=unavailable
fi

append_file_section() {  # <heading> <file>
  local heading=$1 file=$2
  [ -f "$file" ] || return 0
  [ ! -L "$file" ] || { echo "error: refusing symlinked continuation source $file" >&2; return 1; }
  {
    printf '\n## %s\n\n' "$heading"
    cat "$file"
    printf '\n'
  } >> "$PACKET_TMP"
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
  printf "\n## Verified repository status\n\n\`\`\`text\n%s\n\`\`\`\n" "$STATUS_SNAPSHOT"
  printf "\n## Recent repository history\n\n\`\`\`text\n%s\n\`\`\`\n" "$LOG_SNAPSHOT"
  printf '\n## Recorded task metadata\n\n```text\n'
  cat "$META"
  printf '```\n'
  printf "\n## No-mistakes state\n\n\`\`\`text\n%s\n\`\`\`\n" "$NO_MISTAKES_STATUS"
} >> "$PACKET_TMP"

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

PACKET_BYTES=$(wc -c < "$PACKET_TMP" | tr -d '[:space:]')
case "$PACKET_BYTES" in ''|*[!0-9]*) echo "error: cannot measure continuation packet for $ID" >&2; exit 1 ;; esac
if [ "$PACKET_BYTES" -gt "$MAX_PACKET_BYTES" ]; then
  echo "error: continuation packet for $ID is $PACKET_BYTES bytes; maximum is $MAX_PACKET_BYTES" >&2
  exit 1
fi
mv "$PACKET_TMP" "$PACKET" || exit 1
PACKET_TMP=
printf '%s\n' "$PACKET"
