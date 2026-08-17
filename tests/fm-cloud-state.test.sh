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
  mkdir -p "$state/$id.cloud-account" "$state/$id.cloud-payload" "$state/$id.cloud-outcome"
  printf '{"refresh":"secret"}\n' > "$state/$id.cloud-account/auth.json"
  printf '{}\n' > "$state/$id.cloud-account/settings.json"
  printf 'bundle\n' > "$state/$id.cloud-payload/repo.bundle"
  printf 'brief\n' > "$state/$id.cloud-payload/brief.md"
  printf 'entry\n' > "$state/$id.cloud-entrypoint"
  printf 'env\n' > "$state/$id.cloud-env"
  printf 'wt\n' > "$state/$id.cloud-worktree"
  : > "$state/$id.cloud-execute-dispatched"
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
  assert_absent "$state/$id.cloud-worktree" "the leased worktree pointer survived"
  assert_absent "$state/$id.cloud-execute-dispatched" "the dispatch marker survived"
  assert_absent "$state/$id.worker-result.json" "the worker result survived"
  assert_absent "$state/$id.worker-execute.log" "the execute log survived"
  assert_absent "$state/$id.cloud-outcome" "an empty outcome directory survived"
  pass "teardown removes the cloud account credential and its transport state"
}

run_unlanded_outcome_is_kept() {
  # An outcome bundle still present at teardown is work that never landed.
  # Removing it would destroy the last copy of the crewmate's commits.
  local tmp state id out
  fm_test_tmproot_into tmp fm-cloud-state-outcome
  state="$tmp/state"
  id=cloud-task-2
  mkdir -p "$state/$id.cloud-account" "$state/$id.cloud-outcome"
  printf '{"refresh":"secret"}\n' > "$state/$id.cloud-account/auth.json"
  printf 'unlanded commits\n' > "$state/$id.cloud-outcome/outcome.bundle"

  out=$(fm_cloud_state_remove "$state" "$id" 2>&1)

  assert_present "$state/$id.cloud-outcome/outcome.bundle" \
    "teardown destroyed the last copy of an unlanded outcome bundle"
  assert_contains "$out" "kept an unlanded outcome bundle" \
    "teardown removed nothing but never told the operator the bundle is there"
  assert_absent "$state/$id.cloud-account/auth.json" \
    "keeping the bundle also kept the credential"
  pass "an unlanded outcome bundle is kept and named while the credential still goes"
}

run_teardown_actually_calls_the_owner() {
  # The two cases above drive the library, which proves the function works and
  # NOT that anything calls it: deleting both call sites leaves them green.
  # The teardown suite is case-based and drives the whole script, so this pins
  # the call sites directly instead. Both terminal paths must clean up, or a
  # torn-down cloud task keeps its credential.
  local script calls
  script="$ROOT/bin/fm-teardown.sh"
  assert_grep 'fm-cloud-state-lib.sh' "$script" "teardown no longer sources the cloud state owner"
  calls=$(grep -c 'fm_cloud_state_remove "\$STATE" "\$ID"' "$script" || true)
  test "$calls" -ge 2 \
    || fail "teardown calls the cloud state owner on $calls of its 2 terminal paths"
  pass "both teardown exit paths call the cloud state owner"
}

run_cloud_credential_is_removed
run_unlanded_outcome_is_kept
run_teardown_actually_calls_the_owner

echo "# fm-cloud-state.test.sh: all assertions passed"
