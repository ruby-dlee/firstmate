#!/usr/bin/env bash
# Synchronously preflight one task PR and refuse until atomic merge custody exists.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <method>]
# Supported methods: --squash (default), --merge, --rebase, --method=<value>.
# Scheduling flags are refused.
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

fm_pr_merge_locked() {
  local lifecycle generation head admission admitted_head admitted_base admitted_base_ref admitted_policy
  local pr_doc current_head current_base current_base_ref residual status=0
  lifecycle=$(fm_account_lifecycle_lock_acquire "$STATE" "$ID") || return 1
  generation=$(fm_account_meta_value "$META" generation_id)
  head=$(git -C "$WORKTREE" rev-parse --verify HEAD 2>/dev/null) || status=1
  [ -n "$generation" ] || status=1
  if [ "$status" -eq 0 ]; then fm_pr_merge_verify_custody "$generation" "$head" || status=1; fi
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
    [ "$admitted_policy" = snapshot-native-strict ] && [ -n "$admitted_base_ref" ] || {
      echo "error: admission receipt carried no server-policy snapshot identity" >&2
      status=1
    }
  fi
  if [ "$status" -eq 0 ]; then
    fm_pr_require_server_admission_rule "$OWNER" "$REPO" "$admitted_base_ref" || {
      echo "error: strict required checks or protected review policy changed during preflight" >&2
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
  if [ "$status" -eq 0 ]; then fm_pr_require_atomic_merge_boundary "$METHOD" || status=1; fi
  if ! fm_account_lifecycle_lock_release "$lifecycle" >/dev/null 2>&1; then
    echo "error: exact-head preflight lock cleanup needs recovery" >&2
    status=1
  fi
  return "$status"
}

LOCK_ROOT=$(fm_checkout_lock_root "$STATE")
fm_checkout_lock_run "$WORKTREE" "$LOCK_ROOT" fm_pr_merge_locked
