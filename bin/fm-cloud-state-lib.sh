#!/usr/bin/env bash
# Ownership of the per-task cloud state a cloud-placed spawn leaves in the
# control home.
#
# A cloud crewmate cannot read the operator's provider account directly, so
# bin/fm-spawn.sh copies the account credential into
# $FM_HOME/state/<id>.cloud-account/ for the worker lifecycle to stage. Nothing
# owned its removal, so every completed cloud task left a plaintext auth.json
# in the control home indefinitely, contradicting the invariant in
# docs/azure-workers.md that provider-account credentials never enter it.
# This library is that owner; teardown calls it.

# Remove one task's cloud state. Args: state_dir task_id
fm_cloud_state_remove() {
  local state=$1 id=$2 bundle
  [ -n "$state" ] && [ -n "$id" ] || return 0
  # The credential first and by name, so a later failure cannot leave it.
  rm -f "$state/$id.cloud-account/auth.json" "$state/$id.cloud-account/settings.json"
  rm -rf "$state/$id.cloud-account" "$state/$id.cloud-payload"
  rm -f "$state/$id.cloud-entrypoint" "$state/$id.cloud-env" \
    "$state/$id.cloud-execute-dispatched" "$state/$id.cloud-worktree" \
    "$state/$id.worker-result.json" "$state/$id.worker-execute.log" \
    "$state/$id.worker-reconcile.json"
  # An outcome bundle still present at teardown is work that never landed.
  # Deleting it would destroy the last copy of a crewmate's commits, so it is
  # kept and named instead.
  bundle=$state/$id.cloud-outcome/outcome.bundle
  if [ -s "$bundle" ]; then
    echo "notice: $id kept an unlanded outcome bundle at $bundle" >&2
    return 0
  fi
  rm -rf "$state/$id.cloud-outcome"
}
