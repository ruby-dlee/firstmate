#!/usr/bin/env bash
# Synchronously admit and merge one task PR without arming future execution.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <method>]
# Supported methods: --squash (default), --merge, --rebase, --method=<value>.
# Scheduling flags are refused.
# The final GitHub merge request carries the admitted head SHA, so a force-push
# between admission and execution fails atomically instead of landing new code.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
# shellcheck source=bin/fm-pr-evidence-lib.sh
. "$SCRIPT_DIR/fm-pr-evidence-lib.sh"
# shellcheck source=bin/fm-account-routing-lib.sh
. "$SCRIPT_DIR/fm-account-routing-lib.sh"
# shellcheck source=bin/fm-checkout-lock-lib.sh
. "$SCRIPT_DIR/fm-checkout-lock-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

ID=${1:?usage: fm-pr-merge.sh <task-id> <pr-url> [-- <method>]}
URL=${2:?usage: fm-pr-merge.sh <task-id> <pr-url> [-- <method>]}
shift 2
[ "${1:-}" = -- ] && shift

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || { echo "error: no safe meta for task $ID at $META" >&2; exit 1; }
WORKTREE=$(fm_account_meta_value "$META" worktree)
[ -d "$WORKTREE" ] && [ ! -L "$WORKTREE" ] || { echo "error: no safe worktree for task $ID" >&2; exit 1; }

if [[ "$URL" =~ ^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]+)/pull/([0-9]+)/?$ ]] \
  && [[ "${BASH_REMATCH[1]}" != *- ]]; then
  OWNER=${BASH_REMATCH[1]}
  REPO=${BASH_REMATCH[2]}
  NUMBER=${BASH_REMATCH[3]}
else
  echo "error: PR URL must match https://github.com/<owner>/<repo>/pull/<number> (got: $URL)" >&2
  exit 1
fi

METHOD=squash
while [ "$#" -gt 0 ]; do
  case "$1" in
    --squash) METHOD=squash ;;
    --merge) METHOD=merge ;;
    --rebase) METHOD=rebase ;;
    --method)
      shift
      METHOD=${1:?error: --method requires merge, squash, or rebase}
      ;;
    --method=*) METHOD=${1#--method=} ;;
    --auto|--queue|--admin|--delete-branch)
      echo "error: merge scheduling and side-effect flags are forbidden ($1); fm-pr-merge is one-shot only" >&2
      exit 1
      ;;
    --repo|--repo=*|-R|-R?*)
      echo "error: merge args must not override the repository parsed from the PR URL ($1)" >&2
      exit 1
      ;;
    *) echo "error: unsupported merge argument '$1'" >&2; exit 1 ;;
  esac
  shift
done
case "$METHOD" in merge|squash|rebase) ;; *) echo "error: invalid merge method '$METHOD'" >&2; exit 1 ;; esac

fm_pr_merge_section_scalar() {  # <document> <section> <key>
  printf '%s\n' "$1" | awk -v section="$2" -v key="$3" '
    $0 == section ":" { inside = 1; next }
    inside && /^[^ ]/ { inside = 0 }
    inside && $1 == key ":" { gsub(/"/, "", $2); print $2; exit }
  '
}

fm_pr_merge_verify_custody() {  # <generation> <head>
  local generation=$1 head=$2 current
  [ -f "$META" ] && [ ! -L "$META" ] || return 1
  [ "$(fm_account_meta_value "$META" generation_id)" = "$generation" ] || return 1
  [ "$(fm_account_meta_value "$META" worktree)" = "$WORKTREE" ] || return 1
  current=$(git -C "$WORKTREE" rev-parse --verify HEAD 2>/dev/null) || return 1
  [ "$current" = "$head" ]
}

fm_pr_merge_quiesce() {
  local backend target scoped tab state i=0
  backend=$(fm_backend_of_meta "$META")
  target=$(fm_backend_target_of_meta "$META")
  scoped=$(fm_account_meta_value "$META" tmux_session_target)
  tab=$(fm_account_meta_value "$META" zellij_tab_id)
  [ -n "$target" ] || { echo "error: task endpoint identity is unavailable for merge quiescence" >&2; return 1; }
  state=$(fm_backend_target_state "$backend" "$target" "fm-$ID" "$scoped" 2>/dev/null)
  case "$state" in
    absent) return 0 ;;
    present) ;;
    *) echo "error: task endpoint state is unknown; merge custody cannot be proved" >&2; return 1 ;;
  esac
  fm_backend_kill "$backend" "$target" "$tab" "fm-$ID" "$scoped" >/dev/null 2>&1 || {
    echo "error: task endpoint could not be quiesced before merge" >&2
    return 1
  }
  while [ "$i" -lt 20 ]; do
    state=$(fm_backend_target_state "$backend" "$target" "fm-$ID" "$scoped" 2>/dev/null)
    [ "$state" != absent ] || return 0
    [ "$state" != unknown ] || break
    sleep 0.1
    i=$((i + 1))
  done
  echo "error: task endpoint did not become provably absent before merge" >&2
  return 1
}

fm_pr_merge_locked() {
  local lifecycle generation head admission admitted_head admitted_base admitted_base_ref admitted_policy
  local pr_doc current_head current_base current_base_ref residual merge_doc merged message status=0
  lifecycle=$(fm_account_lifecycle_lock_acquire "$STATE" "$ID") || return 1
  generation=$(fm_account_meta_value "$META" generation_id)
  head=$(git -C "$WORKTREE" rev-parse --verify HEAD 2>/dev/null) || status=1
  [ -n "$generation" ] || status=1
  if [ "$status" -eq 0 ]; then fm_pr_merge_verify_custody "$generation" "$head" || status=1; fi
  if [ "$status" -eq 0 ]; then fm_pr_merge_quiesce || status=1; fi
  if [ "$status" -eq 0 ]; then fm_pr_merge_verify_custody "$generation" "$head" || status=1; fi
  if [ "$status" -eq 0 ]; then "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL" >/dev/null || status=1; fi
  if [ "$status" -eq 0 ]; then
    admission=$("$SCRIPT_DIR/fm-pr-admit.sh" "$ID" "$URL") || status=1
  fi
  if [ "$status" -eq 0 ]; then
    case "$admission" in
      admitted:\ head=*) admitted_head=${admission#admitted: head=}; admitted_head=${admitted_head%% *} ;;
      *) echo "error: admission returned no exact-head receipt" >&2; status=1 ;;
    esac
  fi
  if [ "$status" -eq 0 ]; then
    admitted_base=${admission#* base=}; admitted_base=${admitted_base%% *}
    admitted_base_ref=${admission#* base_ref=}; admitted_base_ref=${admitted_base_ref%% *}
    admitted_policy=${admission#* policy=}; admitted_policy=${admitted_policy%% *}
    case "$admitted_head:$admitted_base" in
      ????????????????????????????????????????:????????????????????????????????????????) ;;
      *) echo "error: admission receipt carried an invalid head or base" >&2; status=1 ;;
    esac
    [ "$admitted_policy" = native-strict ] && [ -n "$admitted_base_ref" ] || {
      echo "error: admission receipt carried no server-native policy identity" >&2
      status=1
    }
  fi
  if [ "$status" -eq 0 ]; then
    fm_pr_require_server_admission_rule "$OWNER" "$REPO" "$admitted_base_ref" || {
      echo "error: strict required checks and protected review evidence are not enforced at the server merge boundary" >&2
      status=1
    }
  fi
  if [ "$status" -eq 0 ]; then
    pr_doc=$(gh-axi api "/repos/$OWNER/$REPO/pulls/$NUMBER") || status=1
  fi
  if [ "$status" -eq 0 ]; then
    current_head=$(fm_pr_merge_section_scalar "$pr_doc" head sha)
    current_base=$(fm_pr_merge_section_scalar "$pr_doc" base sha)
    current_base_ref=$(fm_pr_merge_section_scalar "$pr_doc" base ref)
    [ "$current_head" = "$admitted_head" ] && [ "$current_base" = "$admitted_base" ] \
      && [ "$current_base_ref" = "$admitted_base_ref" ] || {
      echo "error: PR head or base changed after admission" >&2
      status=1
    }
  fi
  if [ "$status" -eq 0 ]; then fm_pr_merge_verify_custody "$generation" "$admitted_head" || status=1; fi
  if [ "$status" -eq 0 ]; then
    residual=$(git -C "$WORKTREE" status --porcelain=v1 --untracked-files=all) || status=1
    [ -z "$residual" ] || {
      echo "error: tracked, staged, or untracked residual appeared at the final merge boundary" >&2
      status=1
    }
  fi
  if [ "$status" -eq 0 ]; then
    merge_doc=$(gh-axi api PUT "/repos/$OWNER/$REPO/pulls/$NUMBER/merge" \
      --field "sha=$admitted_head" --field "merge_method=$METHOD") || status=1
  fi
  if [ "$status" -eq 0 ]; then
    merged=$(printf '%s\n' "$merge_doc" | sed -n 's/^merged: *//p' | head -1)
    if [ "$merged" != true ]; then
      message=$(printf '%s\n' "$merge_doc" | sed -n 's/^message: *//p' | head -1)
      echo "error: GitHub did not merge admitted head $admitted_head (${message:-no merge verdict})" >&2
      status=1
    fi
  fi
  if ! fm_account_lifecycle_lock_release "$lifecycle" >/dev/null 2>&1; then
    if [ "$status" -eq 0 ]; then
      echo "warning: exact-head merge succeeded but task lifecycle lock cleanup needs recovery" >&2
    else
      status=1
    fi
  fi
  [ "$status" -eq 0 ] || return "$status"
  printf 'merged: %s exact_head=%s method=%s\n' "$URL" "$admitted_head" "$METHOD"
}

LOCK_ROOT=$(fm_checkout_lock_root "$STATE")
fm_checkout_lock_run "$WORKTREE" "$LOCK_ROOT" fm_pr_merge_locked
