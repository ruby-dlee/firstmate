#!/usr/bin/env bash
# Queue-driven provider-neutral lifecycle for one-task elastic workers.
#
# This wrapper never decides that work is landed and never deletes ambiguous
# work. The exact lifecycle, Azure setup, release receipt, recovery, cost, and
# acceptance contracts live in docs/azure-workers.md.
#
# Required environment:
#   FM_HOME
#   FM_AZURE_SUBSCRIPTION_ID
#   FM_AZURE_DEPLOYMENT_GENERATION
#   FM_AZURE_OWNER_TAG
#   FM_AZURE_NAMING_PREFIX
#   FM_AZURE_STORAGE_NAME (Azure adapter)
#
# Optional policy:
#   FM_AZURE_WORKER_POLICY_PHASE=commissioning|steady
#   FM_AZURE_WORKER_STEADY_TARGET_USD=1000
#   FM_AZURE_WORKER_COMMISSIONING_CEILING_USD=1500
#   FM_AZURE_WORKER_HOUR_PLANNING_THRESHOLD=3500
#   FM_AZURE_WORKER_ADMISSION_HOURS=24
#   FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=300
#   FM_AZURE_WORKER_DAILY_BOUND_USD=100        (unset = 100; <=0 or non-numeric refuses)
#   FM_AZURE_WORKER_DAILY_BOUND_OVERRIDE=<utc-day>  (exact current day only)
#   FM_AZURE_WORKER_IDLE_RELEASE_SECONDS=14400 (600..604800)
#   FM_AZURE_WORKER_MAX=16
#   FM_AZURE_WORKER_WARM_IDLE=0
#   FM_WORKER_PROVIDER_COMMAND='python3 <provider-adapter>'
#
# Usage:
#   fm-worker-lifecycle.sh request <exact identity flags> --eligible
#   fm-worker-lifecycle.sh reconcile [--apply --confirm-subscription <uuid>]
#   fm-worker-lifecycle.sh capacity-reserve <exact specialized reservation flags>
#   fm-worker-lifecycle.sh capacity-reserve-shape <exact complete-shape constituents>
#   fm-worker-lifecycle.sh capacity-release <exact fence and cleanup receipt>
#   fm-worker-lifecycle.sh execute <exact assignment flags> -- <argv...>
#   fm-worker-lifecycle.sh authority-receipt <exact assignment flags> --output <json>
#   fm-worker-lifecycle.sh proof-template --task <id> --task-generation <id>
#   fm-worker-lifecycle.sh release --task <id> --task-generation <id> --proof-file <json>
#   fm-worker-lifecycle.sh withdraw --task <id> --task-generation <id> --confirm-withdraw --confirm-subscription <uuid>
#   fm-worker-lifecycle.sh abandon-claim --slot <n> --idempotency-key <sha256> --confirm-abandon --confirm-subscription <uuid>
#   fm-worker-lifecycle.sh surrender --task <id> --task-generation <id> --reason <text> --output <json> --confirm-surrender --confirm-subscription <uuid> [--confirm-discard-unlanded] [--confirm-orphan-children]
#   fm-worker-lifecycle.sh resume <exact recovery flags>
#   fm-worker-lifecycle.sh steer <exact assignment flags>
#   fm-worker-lifecycle.sh message-put <exact assignment flags> --file <json> | --attach <bundle>
#   fm-worker-lifecycle.sh message-collect <exact assignment flags> --output-dir <dir>
#   fm-worker-lifecycle.sh compartment-chain-tip <exact assignment flags> --sequence <n> --chain-digest <sha256>
#   fm-worker-lifecycle.sh status [--live] [--json]
#   fm-worker-lifecycle.sh acceptance-plan
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-cloud-state-lib.sh
. "$SCRIPT_DIR/fm-cloud-state-lib.sh"

# The state directory a receipted task's cloud state was staged in.
#
# A compartment child lives in the SECONDMATE's home, while these commands
# necessarily run with FM_HOME on the primary: the controller document has
# exactly one home. Guessing from the task id would be worse than the leak,
# because ids are home-scoped and the same id can be live in two homes at once,
# so the answer comes from the CONTROLLER, which authorized that exact path for
# that exact task generation under its own lock and echoes it back on the
# FM-TASK-HOME line beside the receipt. Absent (every ordinary task), the
# controller's own state directory is the answer, exactly as before.
#
# awk with a rest-of-line reconstruction, not `print $3`: a home path may
# contain spaces, and a truncated path is a removal aimed somewhere else.
fm_worker_receipt_state_dir() {  # <command output> <receipt task> <controller state>
  local output=$1 receipt=$2 fallback=$3 line parent task_home canonical
  line=$(printf '%s\n' "$output" | awk -v task="$receipt" \
    '$1 == "FM-TASK-HOME" && $2 == task { print; exit }')
  [ -n "$line" ] || { printf '%s\n' "$fallback"; return 0; }
  parent=$(printf '%s\n' "$line" | awk '{ print $3 }')
  # Rest of line, not `print $4`: a home path may contain spaces, and a
  # truncated path is a removal aimed somewhere else.
  task_home=$(printf '%s\n' "$line" | sed -e 's/^[^ ]* [^ ]* [^ ]* //')
  [ -n "$parent" ] || { printf '%s\n' "$fallback"; return 0; }
  case "$task_home" in
    /*/../*|*/..|*/../*|'') printf '%s\n' "$fallback"; return 0 ;;
    /*) : ;;
    *) printf '%s\n' "$fallback"; return 0 ;;
  esac
  # The reader enforces exactly what the stager enforced, no more and no less.
  # bin/fm-spawn.sh resolved FM_SPAWN_TASK_HOME with `cd -P && pwd -P` and then
  # required the home's own marker to name the parent compartment, and the
  # controller stores that resolved path; a value that is not its own physical
  # path therefore did not come from an authorization. This is what makes a
  # symlinked home, a symlinked path component, and a home whose marker names a
  # different secondmate fall back instead of redirecting a removal.
  canonical=$(cd -P "$task_home" 2>/dev/null && pwd -P) || canonical=
  [ -n "$canonical" ] && [ "$canonical" = "$task_home" ] \
    || { printf '%s\n' "$fallback"; return 0; }
  [ -f "$task_home/.fm-secondmate-home" ] && [ ! -L "$task_home/.fm-secondmate-home" ] \
    || { printf '%s\n' "$fallback"; return 0; }
  [ "$(cat "$task_home/.fm-secondmate-home" 2>/dev/null || true)" = "$parent" ] \
    || { printf '%s\n' "$fallback"; return 0; }
  printf '%s\n' "$task_home/state"
}

case "${1:-}" in
  request|release|resume|steer|execute|authority-receipt|capacity-reserve|capacity-reserve-shape|capacity-release|abandon-claim|message-put|message-collect|compartment-chain-tip)
    fm_refuse_if_gate_agent
    exec python3 "$SCRIPT_DIR/fm-worker-lifecycle.py" "$@"
    ;;
  withdraw)
    fm_refuse_if_gate_agent
    # A withdrawn request leaves no durable owner for the convergence artifacts
    # bin/fm-spawn.sh staged for it, including the COPIED PROVIDER CREDENTIAL at
    # $STATE/<id>.cloud-account/auth.json. fm-spawn's own rollback removes them
    # for exactly this reason, and teardown never runs for a task that never got
    # a worker, so the removal is owned here.
    #
    # Cleanup is keyed off the command's own FM-WITHDREW receipt, never off its
    # exit code and never off the argv. `--help` also exits 0 without
    # withdrawing anything, so an exit-code gate let `withdraw --task <id>
    # --help` destroy a LIVE task's credential, payload and returned result;
    # and an argv scan misses the --task=<value> form, silently leaving the
    # credential behind on a real withdrawal. The receipt names the exact entry
    # that was actually deleted, so cleanup cannot outrun the deletion.
    withdraw_output=$(python3 "$SCRIPT_DIR/fm-worker-lifecycle.py" "$@")
    printf '%s\n' "$withdraw_output"
    withdraw_receipt=$(printf '%s\n' "$withdraw_output" | awk '$1 == "FM-WITHDREW" { print $2; exit }')
    if [ -n "$withdraw_receipt" ]; then
      # Not `|| true`: fm_cloud_state_remove reports a stuck credential and
      # returns 0 so teardown can continue, but here it is the last step, so a
      # credential left on disk has to be visible to whatever ran this.
      state_root="${FM_STATE_OVERRIDE:-${FM_HOME:?FM_HOME is required}/state}"
      # Where the credential actually is, which is not the controller's home
      # for a compartment child.
      staged_root=$(fm_worker_receipt_state_dir "$withdraw_output" "$withdraw_receipt" "$state_root")
      fm_cloud_state_remove "$staged_root" "$withdraw_receipt"
      if [ -e "$staged_root/$withdraw_receipt.cloud-account/auth.json" ]; then
        echo "ELASTIC WORKER REFUSED: withdrew $withdraw_receipt but its staged provider credential remains" >&2
        exit 4
      fi
    fi
    exit 0
    ;;
  surrender)
    fm_refuse_if_gate_agent
    # A surrendered task's local cloud state has the same no-owner problem as a
    # withdrawn one: its endpoint, metadata and teardown are already gone (that
    # is what made surrender necessary), so nothing else will ever remove the
    # staged provider credential at $STATE/<id>.cloud-account/auth.json. The
    # cloud-side copies go later, through reconcile's fenced reset; the local
    # staging is owned here, keyed off the FM-SURRENDERED receipt for exactly
    # the reasons the withdraw lane documents above.
    surrender_output=$(python3 "$SCRIPT_DIR/fm-worker-lifecycle.py" "$@")
    printf '%s\n' "$surrender_output"
    surrender_receipt=$(printf '%s\n' "$surrender_output" | awk '$1 == "FM-SURRENDERED" { print $2; exit }')
    if [ -n "$surrender_receipt" ]; then
      state_root="${FM_STATE_OVERRIDE:-${FM_HOME:?FM_HOME is required}/state}"
      # Same source as the withdraw lane above, for the same reason: the
      # surrendered task's credential lives in ITS task home, which is the
      # secondmate's for a compartment child.
      staged_root=$(fm_worker_receipt_state_dir "$surrender_output" "$surrender_receipt" "$state_root")
      fm_cloud_state_remove "$staged_root" "$surrender_receipt"
      if [ -e "$staged_root/$surrender_receipt.cloud-account/auth.json" ]; then
        echo "ELASTIC WORKER REFUSED: surrendered $surrender_receipt but its staged provider credential remains" >&2
        exit 4
      fi
    fi
    exit 0
    ;;
  reconcile)
    for argument in "$@"; do
      if [ "$argument" = --apply ]; then
        fm_refuse_if_gate_agent
        break
      fi
    done
    exec python3 "$SCRIPT_DIR/fm-worker-lifecycle.py" "$@"
    ;;
  proof-template|status|acceptance-plan)
    exec python3 "$SCRIPT_DIR/fm-worker-lifecycle.py" "$@"
    ;;
  help|-h|--help|"")
    exec python3 "$SCRIPT_DIR/fm-worker-lifecycle.py" --help
    ;;
  *)
    printf 'ELASTIC WORKER REFUSED: unknown command: %s\n' "$1" >&2
    exec python3 "$SCRIPT_DIR/fm-worker-lifecycle.py" --help
    ;;
esac
