#!/usr/bin/env bash
# Ownership of the per-task cloud state a cloud-placed spawn leaves in the
# control home.
#
# A cloud crewmate cannot read the operator's provider account directly, so
# bin/fm-spawn.sh copies the account credential into
# <task home>/state/<id>.cloud-account/ for the worker lifecycle to stage.
# Nothing owned its removal, so every completed cloud task left a plaintext
# auth.json in the control home indefinitely, contradicting the invariant in
# docs/azure-workers.md that provider-account credentials never enter it.
# This library is that owner; teardown, withdraw and surrender call it.
#
# WHICH home. Since the compartment-child task-home split, the home the task
# lives in is NOT always the home that owns the elastic-worker controller
# document: a secondmate compartment's child stages its credential in the
# COMPARTMENT's home while every lifecycle command for it runs with FM_HOME on
# the primary. Removers that re-derived the primary's state directory
# therefore missed the credential entirely and it outlived the task with
# nothing left that would ever remove it. So the resolution lives HERE, in the
# same owner as the removal, and fm_cloud_state_remove performs it itself:
# a caller cannot resolve a different directory than the remover, because
# callers do not resolve at all.
#
# Named residue: a compartment child torn down from ITS OWN home (FM_HOME on
# the secondmate) never sees the controller home, so its record stays behind
# there. That leftover is a PATH, never a credential; it is task-id scoped, it
# refuses to redirect anything once the directory it names stops being a
# seeded secondmate home, and the next spawn of that id rewrites or removes it.

# The stager's own durable record of the home it staged a task's cloud state
# in. Written by bin/fm-spawn.sh under the CONTROLLER's state directory (the
# one place every remover already looks) and only when the task home differs
# from it; the ordinary crewmate lane writes no such file and its removal is
# byte-identical to what it was before the split existed.
fm_cloud_state_task_home_record() {  # <state_dir> <task_id>
  local state=${1:?cloud state directory is required} id=${2:?task id is required}
  printf '%s\n' "$state/$id.cloud-task-home"
}

# The directory that holds one task's staged cloud state. THE one resolution:
# the record when the stager left one and it still names a seeded secondmate
# home, otherwise the state directory the caller already had.
fm_cloud_state_dir() {  # <state_dir> <task_id>
  local state=${1:?cloud state directory is required} id=${2:?task id is required}
  # home is initialized, not merely declared: an unreadable record leaves read
  # without an assignment, and callers run under `set -u`.
  local record home=
  record=$(fm_cloud_state_task_home_record "$state" "$id")
  # A regular file only, and only an absolute path with no traversal: this
  # value redirects a removal, so it is held to the same shape rules the spawn
  # held FM_SPAWN_TASK_HOME to. Anything else falls back to the caller's own
  # directory rather than following a path into somewhere it does not own.
  if [ -f "$record" ] && [ ! -L "$record" ]; then
    # `|| :`, never `|| home=`: a final line with no trailing newline makes
    # read return non-zero AFTER assigning, and clearing it there would
    # silently discard a perfectly good record and fall back to the wrong home.
    IFS= read -r home < "$record" || :
    case "$home" in
      /*/../*|*/..|*/../*|'') : ;;
      /*)
        # The same marker the stager required before it staged anything. A
        # remover that walked into a directory that is not a seeded secondmate
        # home would be worse than the leak it is fixing.
        if [ -f "$home/.fm-secondmate-home" ] && [ ! -L "$home/.fm-secondmate-home" ]; then
          printf '%s\n' "$home/state"
          return 0
        fi
        ;;
    esac
  fi
  printf '%s\n' "$state"
}

# Remove one task's cloud state. Args: state_dir task_id
fm_cloud_state_remove() {
  local state=${1:?cloud state directory is required} id=${2:?task id is required}
  local record resolved
  record=$(fm_cloud_state_task_home_record "$state" "$id")
  # Resolve BEFORE removing anything: the record is part of the state being
  # removed, so reading it afterwards would answer with the fallback.
  resolved=$(fm_cloud_state_dir "$state" "$id")
  # The credential by name FIRST: rm -rf on the directory would follow neither
  # a symlinked cloud-account nor leave the file if the directory removal
  # fails, so naming it is what actually guarantees it goes.
  rm -f "$resolved/$id.cloud-account/auth.json" "$resolved/$id.cloud-account/settings.json" || true
  rm -rf "$resolved/$id.cloud-account" "$resolved/$id.cloud-payload" || true
  rm -f "$resolved/$id.cloud-entrypoint" "$resolved/$id.cloud-env" \
    "$resolved/$id.cloud-execute-dispatched" \
    "$resolved/$id.worker-result.json" "$resolved/$id.worker-execute.log" \
    "$resolved/$id.worker-reconcile.json" || true
  # Last, and only after the state it points at is gone: a record that
  # outlived its removal would aim the NEXT resolution at a home this task no
  # longer lives in.
  rm -f "$record" || true
  # Callers run under `set -e` and finish removing task metadata AFTER this.
  # Aborting there would leave a half-torn-down task AND the credential, so a
  # failure is reported loudly and teardown continues.
  if [ -e "$resolved/$id.cloud-account/auth.json" ]; then
    echo "error: $id could not remove its staged provider credential at $resolved/$id.cloud-account/auth.json" >&2
    return 0
  fi
  return 0
}
