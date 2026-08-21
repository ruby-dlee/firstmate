#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-cloud-state-lib.sh
. "$ROOT/bin/fm-cloud-state-lib.sh"

run_cloud_credential_is_removed() {
  # The provider account credential a cloud spawn copies into the control home
  # must not outlive the task. docs/azure-workers.md states it never enters the
  # control home at all, and before this owner existed every completed cloud
  # crewmate left a plaintext auth.json there indefinitely.
  local tmp state id
  fm_test_tmproot_into tmp fm-cloud-state
  state="$tmp/state"
  id=cloud-task-1
  mkdir -p "$state/$id.cloud-account" "$state/$id.cloud-payload"
  printf '{"refresh":"secret"}\n' > "$state/$id.cloud-account/auth.json"
  printf '{}\n' > "$state/$id.cloud-account/settings.json"
  printf 'bundle\n' > "$state/$id.cloud-payload/repo.bundle"
  printf 'brief\n' > "$state/$id.cloud-payload/brief.md"
  printf 'entry\n' > "$state/$id.cloud-entrypoint"
  printf 'env\n' > "$state/$id.cloud-env"
  : > "$state/$id.cloud-execute-dispatched"
  printf 'request\n' > "$state/$id.worker-request.out"
  printf '{}\n' > "$state/$id.worker-result.json"
  printf 'log\n' > "$state/$id.worker-execute.log"
  printf '{}\n' > "$state/$id.worker-reconcile.json"

  fm_cloud_state_remove "$state" "$id"

  assert_absent "$state/$id.cloud-account/auth.json" \
    "the provider account credential outlived the task in the control home"
  assert_absent "$state/$id.cloud-account" "the account staging directory survived"
  assert_absent "$state/$id.cloud-payload" "the payload staging directory survived"
  assert_absent "$state/$id.cloud-entrypoint" "the persisted entrypoint survived"
  assert_absent "$state/$id.cloud-env" "the persisted environment survived"
  assert_absent "$state/$id.cloud-execute-dispatched" "the dispatch marker survived"
  assert_absent "$state/$id.worker-result.json" "the worker result survived"
  assert_absent "$state/$id.worker-execute.log" "the execute log survived"
  pass "teardown removes the cloud account credential and its transport state"
}

run_teardown_actually_calls_the_owner() {
  # Driving the library proves the function works and NOT that anything calls
  # it. The first version of this check counted a literal string, so it stayed
  # green when a call was neutered to a no-op, and it hardcoded the terminal
  # count so it could never notice a THIRD success path that had no call at
  # all. It now enumerates every successful terminal in the script and
  # requires a real call statement before each one.
  local script
  script="$ROOT/bin/fm-teardown.sh"
  assert_grep 'fm-cloud-state-lib.sh' "$script" "teardown no longer sources the cloud state owner"
  python3 - "$script" <<'TERMINALS' || fail "a successful teardown terminal does not remove the cloud credential"
import re
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
call = re.compile(r"^\s*fm_cloud_state_remove\s+\"\$STATE\"\s+\"\$ID\"\s*$")

terminals = [i for i, line in enumerate(lines) if re.match(r"^\s*exit 0\s*$", line)]
terminals.append(len(lines) - 1)
assert len(terminals) >= 3, ("expected at least three successful terminals", terminals)

uncovered = []
for index in terminals:
    window_start = 0
    for other in terminals:
        if other < index:
            window_start = max(window_start, other)
    if not any(call.match(lines[i]) for i in range(window_start, index + 1)):
        uncovered.append(index + 1)

assert not uncovered, (
    "these successful teardown terminals never remove the cloud credential (1-indexed lines)",
    uncovered,
)
TERMINALS
  pass "every successful teardown terminal removes the cloud credential"
}

run_cloud_state_survives_set_e() {
  # Teardown runs under `set -e` and removes the task metadata AFTER this. A
  # bare failing rm aborted it there, leaving a half-torn-down task and the
  # credential still present. The harness only sets `set -u`, so this drives
  # the function under production shell options explicitly.
  local tmp state id out status
  fm_test_tmproot_into tmp fm-cloud-state-set-e
  state="$tmp/state"
  id=cloud-task-3
  mkdir -p "$state/$id.cloud-account"
  printf '{"refresh":"secret"}\n' > "$state/$id.cloud-account/auth.json"
  chmod 0500 "$state/$id.cloud-account"
  out=$(set -e; . "$ROOT/bin/fm-cloud-state-lib.sh"; fm_cloud_state_remove "$state" "$id" 2>&1; echo REACHED)
  status=$?
  chmod 0700 "$state/$id.cloud-account"
  expect_code 0 "$status" "an unremovable credential aborted the caller under set -e"
  assert_contains "$out" "REACHED" "the caller never reached its remaining cleanup"
  assert_contains "$out" "could not remove its staged provider credential" \
    "a credential that could not be removed was not reported"
  pass "a failed credential removal never aborts a caller running under set -e"
}

run_cloud_credential_survives_a_symlinked_directory() {
  # rm -rf on a symlinked cloud-account unlinks the symlink and spares the
  # target, so the by-name removal is what actually guarantees the credential
  # goes. Without it this case leaves the file behind.
  local tmp state id real
  fm_test_tmproot_into tmp fm-cloud-state-symlink
  state="$tmp/state"
  id=cloud-task-4
  real="$tmp/elsewhere"
  mkdir -p "$state" "$real"
  printf '{"refresh":"secret"}\n' > "$real/auth.json"
  ln -s "$real" "$state/$id.cloud-account"

  fm_cloud_state_remove "$state" "$id"

  assert_absent "$real/auth.json" \
    "a symlinked account directory left the credential on disk"
  pass "a symlinked account directory still loses its credential"
}

seed_compartment_child_staging() {  # <compartment home> <task id>
  # The exact shape bin/fm-spawn.sh leaves behind for a compartment child: the
  # whole per-task cloud state in the COMPARTMENT's own state directory.
  local home=$1 id=$2
  mkdir -p "$home/state/$id.cloud-account" "$home/state/$id.cloud-payload"
  printf 'smc-1\n' > "$home/.fm-secondmate-home"
  printf '{"refresh":"secret"}\n' > "$home/state/$id.cloud-account/auth.json"
  printf '{}\n' > "$home/state/$id.cloud-account/settings.json"
  printf 'bundle\n' > "$home/state/$id.cloud-payload/repo.bundle"
  printf 'entry\n' > "$home/state/$id.cloud-entrypoint"
  printf 'request\n' > "$home/state/$id.worker-request.out"
  printf '{}\n' > "$home/state/$id.worker-result.json"
}

run_compartment_child_credential_is_removed_from_its_task_home() {
  # THE DEFECT. A compartment child's credential is staged in the SECONDMATE's
  # home, and withdraw and surrender necessarily run with FM_HOME on the
  # primary, so a remover pointed at the controller's own state directory
  # removed a path that never existed. Handed the TASK's home, it removes what
  # is actually there. Deliberately no path-equality assertion: what must go
  # red is the credential SURVIVING, never a string differing.
  local tmp home id
  fm_test_tmproot_into tmp fm-cloud-state-compartment
  home="$tmp/compartment"
  id=child-1
  seed_compartment_child_staging "$home" "$id"

  fm_cloud_state_remove "$home/state" "$id"

  assert_absent "$home/state/$id.cloud-account/auth.json" \
    "a compartment child's credential outlived its task in the compartment home"
  assert_absent "$home/state/$id.cloud-account" "the account staging directory survived"
  assert_absent "$home/state/$id.cloud-payload" "the payload staging directory survived"
  assert_absent "$home/state/$id.cloud-entrypoint" "the persisted entrypoint survived"
  assert_absent "$home/state/$id.worker-request.out" \
    "the request report, added to the file set by #280, outlived the task"
  assert_absent "$home/state/$id.worker-result.json" "the worker result survived"
  pass "a compartment child's credential is removed from the home it was staged in"
}

run_a_removal_never_reaches_a_same_id_task_in_another_home() {
  # Task ids are HOME-SCOPED, so the same id can be live in two homes at once:
  # a compartment child called X and, later, an ordinary local task called X in
  # the primary. A remover that resolved the home from the task id alone would
  # rm -rf the LIVE compartment child's credential, payload and results while
  # leaving the primary's own state behind - destroying one home's state and
  # reintroducing the leak in the other. Each remover therefore removes from
  # the directory it was handed, and from nowhere else.
  local tmp primary home id
  fm_test_tmproot_into tmp fm-cloud-state-same-id
  primary="$tmp/primary/state"
  home="$tmp/compartment"
  id=shared-id
  mkdir -p "$primary/$id.cloud-account"
  printf '{"refresh":"secret"}\n' > "$primary/$id.cloud-account/auth.json"
  printf 'entry\n' > "$primary/$id.cloud-entrypoint"
  seed_compartment_child_staging "$home" "$id"
  # An id-keyed redirect record, exactly as the rejected first design wrote it.
  # Nothing writes this file any more and nothing reads it; it is seeded here
  # on purpose so this case stays RED against any remover that resolves a home
  # from the task id instead of using the directory it was handed.
  printf '%s\n' "$home" > "$primary/$id.cloud-task-home"

  fm_cloud_state_remove "$primary" "$id"

  assert_absent "$primary/$id.cloud-account/auth.json" \
    "the primary's own credential was left behind"
  assert_absent "$primary/$id.cloud-entrypoint" "the primary's own entrypoint was left behind"
  assert_present "$home/state/$id.cloud-account/auth.json" \
    "removing the primary's task destroyed a live compartment child's credential"
  assert_present "$home/state/$id.cloud-payload/repo.bundle" \
    "removing the primary's task destroyed a live compartment child's payload"
  assert_present "$home/state/$id.worker-result.json" \
    "removing the primary's task destroyed a live compartment child's returned result"
  pass "a removal never reaches a same-id task living in another home"
}

run_the_generation_sweep_removes_the_task_end_set_plus_the_lease() {
  # The re-spawn sweep and the rollback share one lane. They must remove
  # everything the task-end remover does (or a new generation inherits it) plus
  # the leased-worktree pointer they own, and must never touch the outcome
  # directory, which can hold the only local copy of returned commits.
  local tmp state id
  fm_test_tmproot_into tmp fm-cloud-state-generation
  state="$tmp/state"
  id=gen-task
  mkdir -p "$state/$id.cloud-account" "$state/$id.cloud-payload" "$state/$id.cloud-outcome"
  printf '{"refresh":"secret"}\n' > "$state/$id.cloud-account/auth.json"
  printf 'bundle\n' > "$state/$id.cloud-payload/repo.bundle"
  printf 'entry\n' > "$state/$id.cloud-entrypoint"
  printf 'env\n' > "$state/$id.cloud-env"
  : > "$state/$id.cloud-execute-dispatched"
  printf 'path\n' > "$state/$id.cloud-worktree"
  printf '{}\n' > "$state/$id.worker-result.json"
  printf 'log\n' > "$state/$id.worker-execute.log"
  printf '{}\n' > "$state/$id.worker-reconcile.json"
  printf 'commits\n' > "$state/$id.cloud-outcome/outcome.bundle"

  fm_cloud_state_remove_generation "$state" "$id"

  assert_absent "$state/$id.cloud-account" "the sweep left the account staging directory"
  assert_absent "$state/$id.cloud-payload" "the sweep left the payload staging directory"
  assert_absent "$state/$id.cloud-entrypoint" "the sweep left the persisted entrypoint"
  assert_absent "$state/$id.cloud-env" "the sweep left the persisted environment"
  assert_absent "$state/$id.cloud-execute-dispatched" "the sweep left the dispatch marker"
  assert_absent "$state/$id.cloud-worktree" "the sweep left the leased worktree pointer"
  assert_absent "$state/$id.worker-request.out" "the sweep left the previous generation's request report"
  assert_absent "$state/$id.worker-result.json" "the sweep left the previous generation's result"
  assert_absent "$state/$id.worker-execute.log" "the sweep left the previous generation's log"
  assert_present "$state/$id.cloud-outcome/outcome.bundle" \
    "the sweep destroyed an unlanded outcome bundle"
  pass "the generation sweep removes the task-end set plus the lease and spares the outcome"
}

run_the_receipt_reader_enforces_the_stagers_own_rules() {
  # The one place a remover is TOLD a home rather than handed one: the
  # FM-TASK-HOME line withdraw and surrender echo beside their receipt. The
  # spawn resolved FM_SPAWN_TASK_HOME with `cd -P && pwd -P` and required the
  # home's marker to name the parent compartment, so the reader must hold the
  # value to the same rules. Anything else falls back to the controller's own
  # state directory, which leaves a credential behind rather than deleting
  # somewhere it does not own.
  local tmp home real fallback answer
  fm_test_tmproot_into tmp fm-cloud-state-receipt
  home="$tmp/compartment"
  fallback="$tmp/primary/state"
  mkdir -p "$home/state" "$fallback"
  printf 'smc-1\n' > "$home/.fm-secondmate-home"
  # shellcheck source=bin/fm-worker-lifecycle.sh
  receipt_dir() {  # <line>
    ( set +u
      fm_worker_receipt_state_dir() { :; }
      eval "$(sed -n '/^fm_worker_receipt_state_dir() {/,/^}/p' "$ROOT/bin/fm-worker-lifecycle.sh")"
      fm_worker_receipt_state_dir "$1" child-1 "$fallback" )
  }

  answer=$(receipt_dir "FM-TASK-HOME child-1 smc-1 $home")
  [ "$answer" = "$home/state" ] || fail "an authorized home was not followed: $answer"

  # 1. A symlinked DIRECTORY pointing at a seeded home.
  real="$tmp/link-to-home"
  ln -s "$home" "$real"
  answer=$(receipt_dir "FM-TASK-HOME child-1 smc-1 $real")
  [ "$answer" = "$fallback" ] || fail "a symlinked home directory was followed: $answer"

  # 2. A seeded home reached through a symlinked PATH COMPONENT.
  mkdir -p "$tmp/real-parent/inner/state"
  printf 'smc-1\n' > "$tmp/real-parent/inner/.fm-secondmate-home"
  ln -s "$tmp/real-parent" "$tmp/link-parent"
  answer=$(receipt_dir "FM-TASK-HOME child-1 smc-1 $tmp/link-parent/inner")
  [ "$answer" = "$fallback" ] || fail "a symlinked path component was followed: $answer"

  # 3. A real, marked home whose marker names a DIFFERENT secondmate.
  mkdir -p "$tmp/other/state"
  printf 'smc-other\n' > "$tmp/other/.fm-secondmate-home"
  answer=$(receipt_dir "FM-TASK-HOME child-1 smc-1 $tmp/other")
  [ "$answer" = "$fallback" ] || fail "a home marked for another secondmate was followed: $answer"

  # And the shapes that were already refused stay refused.
  answer=$(receipt_dir "FM-TASK-HOME child-1 smc-1 compartment")
  [ "$answer" = "$fallback" ] || fail "a relative home was followed: $answer"
  answer=$(receipt_dir "FM-TASK-HOME child-1 smc-1 $home/../compartment")
  [ "$answer" = "$fallback" ] || fail "a traversal home was followed: $answer"
  answer=$(receipt_dir "FM-TASK-HOME child-1 smc-1 $tmp/absent")
  [ "$answer" = "$fallback" ] || fail "a missing home was followed: $answer"
  answer=$(receipt_dir "FM-WITHDREW child-1 gen-1")
  [ "$answer" = "$fallback" ] || fail "a receipt with no task home was not the fallback: $answer"
  answer=$(receipt_dir "FM-TASK-HOME other-task smc-1 $home")
  [ "$answer" = "$fallback" ] || fail "a line naming another task was followed: $answer"
  pass "the receipt reader follows only a canonical home its marker names the parent of"
}

run_no_second_enumeration_of_the_cloud_file_set() {
  # THE STRUCTURAL INVARIANT behind this change. The per-task cloud file set
  # used to be spelled out in three places - the library, the re-spawn sweep,
  # and the spawn rollback - and only two of them knew about any given name.
  # That is how a file can be created by one lane and removed by none. Every
  # name now lives in bin/fm-cloud-state-lib.sh and nowhere else; this fails if
  # a second speller reappears.
  python3 - "$ROOT" <<'ENUM' || fail "a per-task cloud file name is enumerated outside its owner"
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
owner = root / "bin" / "fm-cloud-state-lib.sh"
names = [
    ".cloud-account", ".cloud-payload", ".cloud-entrypoint", ".cloud-env",
    ".cloud-execute-dispatched", ".cloud-worktree",
    ".worker-request.out", ".worker-result.json", ".worker-execute.log",
    ".worker-reconcile.json",
]
removal = re.compile(r"\brm\s+-[A-Za-z]*[rf][A-Za-z]*\b")
offenders = []
for script in sorted((root / "bin").glob("*.sh")):
    if script == owner:
        continue
    for number, line in enumerate(script.read_text(encoding="utf-8").splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        for match in removal.finditer(line):
            # Only what the removal is actually AIMED at. Matching the whole
            # line flags an atomic write whose failure arm removes its own temp
            # file on a line that merely names the destination.
            arguments = line[match.end():]
            if any(name in arguments for name in names):
                offenders.append("{}:{}: {}".format(script.name, number, line.strip()))
                break
assert not offenders, ("these remove a per-task cloud file outside bin/fm-cloud-state-lib.sh", offenders)
ENUM
  pass "the per-task cloud file set is enumerated in exactly one place"
}

run_the_secondmate_child_reaping_loop_removes_cloud_state() {
  # Teardown's reaping loop is the one teardown that ends a cloud-placed child
  # of a SECONDMATE home when the parent goes first, and on base it removed the
  # child's metadata while never removing its cloud state at all. It is checked
  # structurally rather than by execution: the loop is followed by the removal
  # of the whole home, which would make any after-the-fact file assertion pass
  # whether or not the call exists.
  python3 - "$ROOT/bin/fm-teardown.sh" <<'REAP' || fail "the child reaping loop no longer removes cloud state"
import re
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
start = next(i for i, line in enumerate(lines)
             if line.startswith("cleanup_firstmate_home_children()"))
end = next(i for i in range(start + 1, len(lines)) if lines[i] == "}")
body = lines[start:end]
call = re.compile(r'^\s*fm_cloud_state_remove\s+"\$sub_state"\s+"\$child_id"\s*$')
assert any(call.match(line) for line in body), (
    "cleanup_firstmate_home_children does not remove each child's cloud state")
meta = next(i for i, line in enumerate(body) if "$sub_state/$child_id.meta" in line)
removal = next(i for i, line in enumerate(body) if call.match(line))
assert removal < meta, (
    "the cloud state removal must precede the metadata removal that ends the child")
REAP
  pass "teardown's secondmate child reaping loop removes each child's cloud state"
}

run_cloud_credential_is_removed
run_teardown_actually_calls_the_owner
run_cloud_state_survives_set_e
run_cloud_credential_survives_a_symlinked_directory
run_compartment_child_credential_is_removed_from_its_task_home
run_a_removal_never_reaches_a_same_id_task_in_another_home
run_the_generation_sweep_removes_the_task_end_set_plus_the_lease
run_the_receipt_reader_enforces_the_stagers_own_rules
run_no_second_enumeration_of_the_cloud_file_set
run_the_secondmate_child_reaping_loop_removes_cloud_state

echo "# fm-cloud-state.test.sh: all assertions passed"
