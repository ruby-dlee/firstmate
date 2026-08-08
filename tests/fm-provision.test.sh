#!/usr/bin/env bash
# Behavior tests for worktree provisioning: fm-provision.sh's readiness contract
# and fm-spawn.sh's use of it.
#
# The manifests here are synthetic on purpose. The contract under test is the
# engine's - reuse only on a proven-healthy environment, runtime checks before
# any build, containment, bounded steps, and the warn/block failure policy - and
# none of that should need a real toolchain to exercise.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROVISION="$ROOT/bin/fm-provision.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
fm_test_tmproot_into TMP_ROOT fm-provision

# --- fixtures ---------------------------------------------------------------

# make_case <name>: create a project directory and a worktree with a lock file
# and an "install marker" component, and echo "<case>|<project>|<worktree>".
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/project" "$case_dir/wt/component"
  printf 'lock-v1\n' > "$case_dir/wt/component/lock.txt"
  printf '%s\n' "$case_dir|$case_dir/project|$case_dir/wt"
}

read_case() {
  IFS='|' read -r CASE_DIR PROJ_DIR WT_DIR <<EOF
$1
EOF
}

# write_manifest <file> [<key> <json-value>]...: a one-component manifest whose
# install writes the artifact its probe checks and also appends to a counter
# OUTSIDE the reset path, so a test can tell how many times the component was
# actually built even though each build wipes the artifact directory.
write_manifest() {
  local file=$1
  shift
  cat > "$file" <<'JSON'
{
  "kinds": ["ship"],
  "components": [
    {
      "name": "component",
      "dir": "component",
      "fingerprint": {
        "path": "built/.fm-provision-fingerprint",
        "files": ["lock.txt"],
        "versions": [ { "name": "toolchain", "argv": ["sh", "-c", "echo tool-v1"] } ]
      },
      "reset": ["built"],
      "install": [ { "name": "build", "argv": ["sh", "-c", "mkdir -p built && echo built > built/log && echo built >> ../build-count"] } ],
      "probes": [ { "name": "artifact present", "argv": ["sh", "-c", "test -s built/log"] } ]
    }
  ]
}
JSON
  local key value tmp
  while [ "$#" -gt 1 ]; do
    key=$1
    value=$2
    shift 2
    tmp="$file.tmp"
    jq --argjson v "$value" ".$key = \$v" "$file" > "$tmp" && mv "$tmp" "$file"
  done
}

build_count() {
  local wt=$1
  [ -f "$wt/build-count" ] || { printf '0\n'; return 0; }
  awk 'END { print NR }' "$wt/build-count"
}

provision() {
  local proj=$1 wt=$2 manifest=$3
  shift 3
  "$PROVISION" "$proj" "$wt" --manifest "$manifest" --quiet "$@" 2>/dev/null
}

verdict_field() {
  printf '%s' "$1" | jq -r "$2"
}

# --- engine behavior --------------------------------------------------------

test_absent_manifest_is_a_no_op() {
  local rec out status state
  rec=$(make_case absent-manifest)
  read_case "$rec"
  state="$CASE_DIR/state"
  mkdir -p "$state"
  out=$(FM_STATE_OVERRIDE="$state" provision "$PROJ_DIR" "$WT_DIR" \
    "$CASE_DIR/nothing-here.json" --task absent-a1)
  status=$?
  expect_code 0 "$status" "an absent manifest must not fail a spawn"
  [ "$(verdict_field "$out" .status)" = skipped ] || fail "absent manifest should be skipped, got: $out"
  assert_absent "$state/absent-a1.provision" "an absent manifest must not create a verdict record"
  assert_absent "$state/absent-a1.provision.log" "an absent manifest must not create a log"
  pass "a project with no manifest provisions nothing and exits clean"
}

test_fresh_worktree_is_built_and_probed() {
  local rec out
  rec=$(make_case fresh-build)
  read_case "$rec"
  write_manifest "$CASE_DIR/m.json"
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m.json")
  expect_code 0 "$?" "a fresh worktree should provision cleanly: $out"
  [ "$(verdict_field "$out" '.components[0].result')" = installed ] \
    || fail "fresh worktree should report installed, got: $out"
  [ "$(build_count "$WT_DIR")" = 1 ] || fail "install should have run exactly once"
  assert_present "$WT_DIR/component/built/.fm-provision-fingerprint" \
    "a successful build should record its fingerprint"
  pass "a fresh worktree is built and its probes are run"
}

test_unchanged_healthy_environment_is_reused() {
  local rec out
  rec=$(make_case reuse)
  read_case "$rec"
  write_manifest "$CASE_DIR/m.json"
  provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m.json" >/dev/null
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m.json")
  expect_code 0 "$?" "a second run over an unchanged environment should succeed"
  [ "$(verdict_field "$out" '.components[0].result')" = reused ] \
    || fail "unchanged healthy environment should be reused, got: $out"
  [ "$(build_count "$WT_DIR")" = 1 ] || fail "reuse must not rebuild"
  pass "an unchanged, healthy environment is reused instead of rebuilt"
}

test_existing_directory_is_never_assumed_healthy() {
  local rec out
  rec=$(make_case not-trusted)
  read_case "$rec"
  write_manifest "$CASE_DIR/m.json"
  provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m.json" >/dev/null
  # The directory still exists and the fingerprint still matches; only the thing
  # the probe checks is gone. This is the case that made borrowed evidence
  # necessary: a present-looking environment that cannot actually run anything.
  rm -f "$WT_DIR/component/built/log"
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m.json")
  expect_code 0 "$?" "a failed reuse should self-heal, not fail"
  [ "$(verdict_field "$out" '.components[0].result')" = rebuilt ] \
    || fail "a fingerprint hit whose probes fail must rebuild, got: $out"
  [ "$(build_count "$WT_DIR")" = 2 ] || fail "the rebuild should have run the install again"
  pass "a matching fingerprint over a broken environment rebuilds instead of trusting the directory"
}

test_changed_input_rebuilds() {
  local rec out
  rec=$(make_case changed-input)
  read_case "$rec"
  write_manifest "$CASE_DIR/m.json"
  provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m.json" >/dev/null
  printf 'lock-v2\n' > "$WT_DIR/component/lock.txt"
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m.json")
  [ "$(verdict_field "$out" '.components[0].result')" = installed ] \
    || fail "a changed fingerprint input should rebuild, got: $out"
  [ "$(verdict_field "$out" '.components[0].detail')" = "built because the fingerprint changed" ] \
    || fail "the rebuild reason should name the changed fingerprint, got: $out"
  pass "a changed declared input rebuilds the environment"
}

test_unavailable_fingerprint_never_reuses() {
  local rec out first second
  rec=$(make_case fingerprint-unavailable)
  read_case "$rec"
  write_manifest "$CASE_DIR/m.json"
  # A version command that fails makes the fingerprint unavailable rather than
  # empty-but-equal, so reuse must never be inferred from it.
  jq '.components[0].fingerprint.versions = [{"name":"broken","argv":["sh","-c","exit 3"]}]' \
    "$CASE_DIR/m.json" > "$CASE_DIR/m2.json"
  first=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m2.json")
  second=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m2.json")
  [ "$(verdict_field "$first" '.components[0].result')" = installed ] || fail "first run should build: $first"
  [ "$(verdict_field "$second" '.components[0].result')" = installed ] \
    || fail "an unavailable fingerprint must never be reused, got: $second"
  [ "$(verdict_field "$second" '.components[0].detail')" = "built because the fingerprint inputs were unavailable" ] \
    || fail "the reason should name the unavailable inputs, got: $second"
  [ "$(build_count "$WT_DIR")" = 2 ] || fail "both runs should have built"
  assert_absent "$WT_DIR/component/built/.fm-provision-fingerprint" \
    "an unavailable fingerprint must not be recorded"
  pass "a fingerprint that could not be computed forces a rebuild every time"
}

test_state_dependent_fingerprint_is_refused_not_recorded() {
  local rec out
  rec=$(make_case fingerprint-unstable)
  read_case "$rec"
  write_manifest "$CASE_DIR/m.json"
  # This version command answers differently once the component is built, exactly
  # like `uv python find` resolving a project .venv. Recording the pre-build
  # value would guarantee a rebuild on every future lease, silently.
  jq '.components[0].fingerprint.versions = [{"name":"state dependent","argv":["sh","-c","test -d built && echo after || echo before"]}]' \
    "$CASE_DIR/m.json" > "$CASE_DIR/m2.json"
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m2.json")
  expect_code 0 "$?" "an unstable fingerprint should still provision successfully"
  assert_contains "$(verdict_field "$out" '.components[0].detail')" "fingerprint not recorded" \
    "the verdict should say the fingerprint was refused: $out"
  assert_absent "$WT_DIR/component/built/.fm-provision-fingerprint" \
    "a fingerprint that changes across the build must not be recorded"
  pass "a version command that depends on what it fingerprints is reported, not silently recorded"
}

test_empty_to_nonempty_fingerprint_is_refused_not_recorded() {
  local rec out
  rec=$(make_case fingerprint-empty-then-present)
  read_case "$rec"
  write_manifest "$CASE_DIR/m.json"
  jq '.components[0].fingerprint.versions = [{"name":"state appears","argv":["sh","-c","test -d built && echo after"]}]' \
    "$CASE_DIR/m.json" > "$CASE_DIR/m2.json"
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m2.json")
  expect_code 0 "$?" "an empty-to-non-empty fingerprint transition should still provision"
  assert_contains "$(verdict_field "$out" '.components[0].detail')" "fingerprint not recorded" \
    "the verdict should expose an empty-to-non-empty fingerprint transition: $out"
  assert_absent "$WT_DIR/component/built/.fm-provision-fingerprint" \
    "a fingerprint unavailable before the build must not be recorded afterward"
  pass "a fingerprint that appears only after installation is refused"
}

test_runtime_check_mismatch_fails_before_building() {
  local rec out status
  rec=$(make_case runtime-mismatch)
  read_case "$rec"
  write_manifest "$CASE_DIR/m.json"
  jq '.components[0].runtime_checks = [{"name":"pinned runtime","argv":["sh","-c","echo 23.8.0"],"expect":"20.20.2"}]' \
    "$CASE_DIR/m.json" > "$CASE_DIR/m2.json"
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m2.json")
  status=$?
  expect_code 3 "$status" "a warn-policy failure should exit 3"
  assert_contains "$(verdict_field "$out" .reason)" "reported '23.8.0', expected '20.20.2'" \
    "the failure should name both runtimes"
  [ "$(build_count "$WT_DIR")" = 0 ] \
    || fail "nothing may be built once the runtime check failed"
  pass "a runtime mismatch fails before anything is built under the wrong runtime"
}

test_runtime_check_with_no_output_fails() {
  local rec out
  rec=$(make_case runtime-silent)
  read_case "$rec"
  write_manifest "$CASE_DIR/m.json"
  jq '.components[0].runtime_checks = [{"name":"silent","argv":["true"],"expect":"20.20.2"}]' \
    "$CASE_DIR/m.json" > "$CASE_DIR/m2.json"
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m2.json")
  expect_code 3 "$?" "a silent runtime check must not pass"
  assert_contains "$(verdict_field "$out" .reason)" "printed nothing" \
    "the failure should say the check produced no value"
  pass "a runtime check that prints nothing never satisfies an expected value"
}

test_probe_expect_is_enforced() {
  local rec out
  rec=$(make_case probe-expect-mismatch)
  read_case "$rec"
  write_manifest "$CASE_DIR/m.json"
  jq '.components[0].probes = [{"name":"interpreter","argv":["sh","-c","echo 3.12"],"expect":"3.11"}]' \
    "$CASE_DIR/m.json" > "$CASE_DIR/m2.json"
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m2.json")
  expect_code 3 "$?" "a probe whose output differs from expect must fail"
  assert_contains "$(verdict_field "$out" .reason)" "reported '3.12', expected '3.11'" \
    "the probe failure should name its actual and expected output"

  rec=$(make_case probe-expect-silent)
  read_case "$rec"
  write_manifest "$CASE_DIR/m.json"
  jq '.components[0].probes = [{"name":"interpreter","argv":["true"],"expect":"3.11"}]' \
    "$CASE_DIR/m.json" > "$CASE_DIR/m2.json"
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m2.json")
  expect_code 3 "$?" "a silent probe with expect must fail"
  assert_contains "$(verdict_field "$out" .reason)" "printed nothing, expected '3.11'" \
    "the silent probe failure should name the missing expected output"
  pass "probe expectations use the same exact-output boundary as runtime checks"
}

test_step_timeout_is_reported_and_bounded() {
  local rec out started elapsed
  rec=$(make_case timeout)
  read_case "$rec"
  write_manifest "$CASE_DIR/m.json"
  jq '.components[0].probes = [{"name":"hang","argv":["sh","-c","sleep 120 & sleep 120"],"timeout_seconds":2}]' \
    "$CASE_DIR/m.json" > "$CASE_DIR/m2.json"
  started=$(date +%s)
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m2.json")
  expect_code 3 "$?" "a timed-out step should fail the run"
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 30 ] || fail "the bound did not hold; the run took ${elapsed}s"
  assert_contains "$(verdict_field "$out" .reason)" "timed out after 2s" \
    "the failure should name the timeout"
  pass "a hanging step is killed at its bound and reported as a timeout"
}

test_bounded_step_supervises_background_descendants() {
  local rec out pid attempt=0
  rec=$(make_case background-descendant)
  read_case "$rec"
  write_manifest "$CASE_DIR/m.json"
  jq '.components[0].probes = [{"name":"background hang","argv":["sh","-c","sh -c '\''trap \"\" TERM; sleep 120'\'' & echo $! > ../background-pid"],"timeout_seconds":2}]' \
    "$CASE_DIR/m.json" > "$CASE_DIR/m2.json"
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m2.json")
  expect_code 3 "$?" "a background descendant must keep the bounded step open"
  assert_contains "$(verdict_field "$out" .reason)" "timed out after 2s" \
    "the background descendant should exhaust the step bound"
  pid=$(cat "$WT_DIR/background-pid")
  while kill -0 "$pid" 2>/dev/null && [ "$attempt" -lt 20 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    fail "the bounded step left background descendant $pid running"
  fi
  pass "bounded steps supervise and kill their complete process group"
}

test_reset_is_bounded_by_the_total_budget() {
  local rec out started elapsed fakebin
  rec=$(make_case reset-timeout)
  read_case "$rec"
  write_manifest "$CASE_DIR/m.json" timeout_seconds 4
  fakebin="$CASE_DIR/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/rm" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -rf ]; then
  : > "${FM_FAKE_RESET_CALLED:?}"
  sleep 120
fi
exec /bin/rm "$@"
SH
  chmod +x "$fakebin/rm"
  started=$(date +%s)
  out=$(FM_FAKE_RESET_CALLED="$CASE_DIR/reset-called" PATH="$fakebin:$PATH" \
    provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m.json")
  expect_code 3 "$?" "a reset that exceeds the whole-run budget must fail"
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 15 ] || fail "the reset bound did not hold; the run took ${elapsed}s"
  assert_present "$CASE_DIR/reset-called" "the fake reset should have started"
  assert_contains "$(verdict_field "$out" .reason)" "reset 'built' timed out" \
    "the failure should identify the bounded reset"
  pass "reset deletion cannot outlive the whole-run provisioning budget"
}

test_block_policy_uses_a_distinct_exit_code() {
  local rec out
  rec=$(make_case block-policy)
  read_case "$rec"
  write_manifest "$CASE_DIR/m.json" on_failure '"block"'
  jq '.components[0].probes = [{"name":"always fails","argv":["false"]}]' \
    "$CASE_DIR/m.json" > "$CASE_DIR/m2.json"
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m2.json")
  expect_code 4 "$?" "on_failure=block should exit 4 so the caller can abort"
  [ "$(verdict_field "$out" .policy)" = block ] || fail "the verdict should carry the policy: $out"
  pass "a block-policy failure is a distinct exit code from a warn-policy failure"
}

test_kind_gate_and_force() {
  local rec out state
  rec=$(make_case kind-gate)
  read_case "$rec"
  state="$CASE_DIR/state"
  mkdir -p "$state"
  write_manifest "$CASE_DIR/m.json"
  out=$(FM_STATE_OVERRIDE="$state" provision "$PROJ_DIR" "$WT_DIR" \
    "$CASE_DIR/m.json" --kind scout --task excluded-a1)
  expect_code 0 "$?" "an excluded kind should skip, not fail"
  [ "$(verdict_field "$out" .status)" = skipped ] || fail "scout should be skipped by default: $out"
  [ "$(build_count "$WT_DIR")" = 0 ] || fail "a skipped kind must not build"
  assert_absent "$state/excluded-a1.provision" "an excluded kind must not create a verdict record"
  assert_absent "$state/excluded-a1.provision.log" "an excluded kind must not create a log"
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m.json" --kind scout --force)
  expect_code 0 "$?" "--force should provision an otherwise-excluded kind"
  [ "$(verdict_field "$out" .status)" = ready ] || fail "--force should provision the scout: $out"
  pass "provisioning is limited to the manifest's kinds and --force overrides it"
}

test_paths_are_contained() {
  local rec out
  rec=$(make_case containment)
  read_case "$rec"
  write_manifest "$CASE_DIR/m.json"
  jq '.components[0].dir = "../outside"' "$CASE_DIR/m.json" > "$CASE_DIR/escape-dir.json"
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/escape-dir.json")
  expect_code 3 "$?" "a component directory outside the worktree should fail"
  assert_contains "$(verdict_field "$out" .reason)" "escapes the worktree" \
    "the failure should name the containment refusal"
  jq '.components[0].reset = ["../../escape"]' "$CASE_DIR/m.json" > "$CASE_DIR/escape-reset.json"
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/escape-reset.json")
  expect_code 3 "$?" "a reset path outside the component should fail"
  assert_contains "$(verdict_field "$out" .reason)" "strict descendant" \
    "the failure should name the refused reset path"
  pass "component and reset paths that escape their base are refused"
}

assert_reset_target_refused() {
  local name=$1 target=$2 rec out
  rec=$(make_case "reset-$name")
  read_case "$rec"
  write_manifest "$CASE_DIR/m.json"
  jq --arg target "$target" '.components[0].reset = [$target]' \
    "$CASE_DIR/m.json" > "$CASE_DIR/m2.json"
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m2.json")
  expect_code 3 "$?" "reset target '$target' must be refused"
  assert_contains "$(verdict_field "$out" .reason)" "strict descendant" \
    "reset target '$target' should fail the structural descendant check"
  assert_present "$WT_DIR/component" "refusing reset '$target' must preserve the component directory"
}

test_reset_targets_are_structurally_strict_descendants() {
  assert_reset_target_refused dot .
  assert_reset_target_refused normalized-root sub/..
  assert_reset_target_refused empty ''
  assert_reset_target_refused absolute "$TMP_ROOT/outside-reset"
  pass "reset targets can never resolve to the component root"
}

test_fingerprint_paths_are_structurally_strict_descendants() {
  local rec out
  rec=$(make_case fingerprint-root-path)
  read_case "$rec"
  write_manifest "$CASE_DIR/m.json"
  jq '.components[0].fingerprint.path = "."' "$CASE_DIR/m.json" > "$CASE_DIR/m2.json"
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m2.json")
  expect_code 3 "$?" "a component-root fingerprint path must be refused"
  assert_contains "$(verdict_field "$out" .reason)" "fingerprint path must be a strict descendant" \
    "the fingerprint path should fail the structural descendant check"

  rec=$(make_case fingerprint-root-input)
  read_case "$rec"
  write_manifest "$CASE_DIR/m.json"
  jq '.components[0].fingerprint.files = ["."]' "$CASE_DIR/m.json" > "$CASE_DIR/m2.json"
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m2.json")
  expect_code 3 "$?" "a component-root fingerprint input must be refused"
  assert_contains "$(verdict_field "$out" .reason)" "fingerprint file must be a strict descendant" \
    "the fingerprint input should fail the structural descendant check"
  pass "fingerprint paths cannot name their component root"
}

test_component_directory_may_be_the_worktree_root() {
  local rec out
  rec=$(make_case worktree-root-component)
  read_case "$rec"
  write_manifest "$CASE_DIR/m.json"
  jq 'del(.components[0].dir)
    | .components[0].fingerprint.path = "component/built/.fm-provision-fingerprint"
    | .components[0].fingerprint.files = ["component/lock.txt"]
    | .components[0].reset = ["component/built"]
    | .components[0].install = [{"name":"build","argv":["sh","-c","mkdir -p component/built && echo built > component/built/log"]}]
    | .components[0].probes = [{"name":"artifact present","argv":["sh","-c","test -s component/built/log"]}]' \
    "$CASE_DIR/m.json" > "$CASE_DIR/m2.json"
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m2.json")
  expect_code 0 "$?" "a component may legitimately use the worktree root: $out"
  [ "$(verdict_field "$out" .status)" = ready ] || fail "the root component should be ready: $out"
  pass "component roots retain the deliberate worktree-root asymmetry"
}

test_symlinked_paths_are_refused_before_access() {
  local rec out outside before after
  rec=$(make_case symlink-reset)
  read_case "$rec"
  write_manifest "$CASE_DIR/m.json"
  outside="$CASE_DIR/outside"
  mkdir -p "$outside/env"
  printf 'keep\n' > "$outside/env/sentinel"
  ln -s "$outside" "$WT_DIR/component/cache"
  jq '.components[0].reset = ["cache/env"]' "$CASE_DIR/m.json" > "$CASE_DIR/m2.json"
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m2.json")
  expect_code 3 "$?" "a reset path through a symlink must fail"
  assert_present "$outside/env/sentinel" "a refused reset must not delete outside the component"
  assert_contains "$(verdict_field "$out" .reason)" "reset path must be a strict descendant" \
    "the reset failure should report containment refusal"

  rec=$(make_case symlink-fingerprint)
  read_case "$rec"
  write_manifest "$CASE_DIR/m.json"
  provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m.json" >/dev/null
  outside="$CASE_DIR/outside"
  mkdir -p "$outside"
  cp "$WT_DIR/component/built/.fm-provision-fingerprint" "$outside/fingerprint"
  /bin/rm -f "$WT_DIR/component/built/.fm-provision-fingerprint"
  ln -s "$outside" "$WT_DIR/component/cache"
  before=$(shasum -a 256 "$outside/fingerprint" | awk '{print $1}')
  jq '.components[0].fingerprint.path = "cache/fingerprint"' \
    "$CASE_DIR/m.json" > "$CASE_DIR/m2.json"
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m2.json")
  expect_code 3 "$?" "a fingerprint path through a symlink must fail"
  assert_contains "$(verdict_field "$out" .reason)" "fingerprint path must be a strict descendant" \
    "the fingerprint failure should report containment refusal"
  after=$(shasum -a 256 "$outside/fingerprint" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "a fingerprint write escaped through an in-tree symlink"
  pass "symlinked reset and fingerprint paths cannot escape the worktree"
}

test_env_may_not_hijack_path() {
  local rec out
  rec=$(make_case env-path)
  read_case "$rec"
  write_manifest "$CASE_DIR/m.json"
  jq '.components[0].env = {"PATH":"/nowhere"}' "$CASE_DIR/m.json" > "$CASE_DIR/m2.json"
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m2.json")
  expect_code 3 "$?" "an env PATH override should be refused"
  assert_contains "$(verdict_field "$out" .reason)" "env must not set PATH" \
    "the refusal should point at path_prepend"
  pass "a manifest cannot smuggle a runtime past the runtime checks through env PATH"
}

test_unreadable_policy_fails_closed() {
  local rec out
  rec=$(make_case malformed)
  read_case "$rec"
  printf '{ not json\n' > "$CASE_DIR/m.json"
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m.json")
  expect_code 4 "$?" "a manifest whose policy cannot be read must fail closed"
  assert_contains "$(verdict_field "$out" .reason)" "not valid JSON" \
    "the failure should name the parse problem"
  [ "$(verdict_field "$out" .policy)" = block ] \
    || fail "an unreadable policy should be reported as block: $out"

  write_manifest "$CASE_DIR/bad-policy.json" on_failure '"maybe"'
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/bad-policy.json")
  expect_code 4 "$?" "an unrecognized on_failure must fail closed, not take the warn default"
  assert_contains "$(verdict_field "$out" .reason)" "on_failure must be" \
    "the failure should name the rejected policy value"

  write_manifest "$CASE_DIR/absent-policy.json"
  jq 'del(.on_failure)' "$CASE_DIR/absent-policy.json" > "$CASE_DIR/absent2.json"
  jq '.components[0].probes = [{"name":"always fails","argv":["false"]}]' \
    "$CASE_DIR/absent2.json" > "$CASE_DIR/absent3.json"
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/absent3.json")
  expect_code 3 "$?" "an ABSENT on_failure is not ambiguous and keeps the warn default"
  pass "an unreadable or unrecognized policy fails closed while an absent one still warns"
}

test_path_prepend_is_published_only_when_ready() {
  local rec out
  rec=$(make_case path-prepend)
  read_case "$rec"
  mkdir -p "$CASE_DIR/pinned-bin"
  write_manifest "$CASE_DIR/m.json" path_prepend "[\"$CASE_DIR/pinned-bin\"]"
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m.json")
  [ "$(verdict_field "$out" .path_prepend)" = "$CASE_DIR/pinned-bin" ] \
    || fail "a ready verdict should publish the pinned runtime: $out"
  jq '.components[0].probes = [{"name":"always fails","argv":["false"]}]' \
    "$CASE_DIR/m.json" > "$CASE_DIR/m2.json"
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m2.json")
  [ "$(verdict_field "$out" .path_prepend)" = "" ] \
    || fail "a failed verdict must not publish a runtime pin: $out"
  pass "the pinned runtime is published only by a verdict that proved it"
}

# jq's `length` answers for values that cannot be iterated: a string "abc" is 3,
# the number 7 is 7. Trusting that length let a manifest declare components the
# run then iterated into nothing, and the run still called itself ready.
test_a_non_array_components_field_fails_closed() {
  local rec out status malformed
  rec=$(make_case components-not-an-array)
  read_case "$rec"
  for malformed in '"abc"' '7'; do
    printf '{"kinds":["ship"],"components":%s}\n' "$malformed" > "$CASE_DIR/m.json"
    out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m.json")
    status=$?
    expect_code 3 "$status" "a non-array components ($malformed) must fail, not report ready: $out"
    [ "$(verdict_field "$out" .status)" = failed ] \
      || fail "a non-array components ($malformed) must not be ready, got: $out"
    assert_contains "$(verdict_field "$out" .reason)" "components must be an array" \
      "the failure should name the malformed field: $out"
  done
  printf '{"kinds":["ship"],"on_failure":"block","components":"abc"}\n' > "$CASE_DIR/m.json"
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m.json")
  expect_code 4 "$?" "a block project must abort on a non-array components: $out"
  pass "a components field that is not an array fails closed instead of reporting ready"
}

# The same class one level down: any manifest list that is not an array used to
# iterate into nothing, so a component could report "installed" having run no
# install steps at all.
test_a_non_array_step_list_fails_closed() {
  local rec out
  rec=$(make_case steps-not-an-array)
  read_case "$rec"
  write_manifest "$CASE_DIR/m.json"
  jq '.components[0].install = "make"' "$CASE_DIR/m.json" > "$CASE_DIR/m2.json"
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m2.json")
  expect_code 3 "$?" "a non-array install list must fail rather than install nothing: $out"
  assert_contains "$(verdict_field "$out" .reason)" "install must be an array" \
    "the failure should name the malformed list: $out"
  [ "$(build_count "$WT_DIR")" = 0 ] || fail "nothing should have been built"
  pass "a step list that is not an array fails closed instead of provisioning nothing"
}

# Every step is driven from a list this script is reading, so a step that reads
# stdin must not be able to consume the rest of that list. Each step here counts
# itself, and the count is what proves the whole list ran.
test_a_step_cannot_consume_the_list_that_drives_it() {
  local rec out installs probes
  rec=$(make_case stdin-draining-step)
  read_case "$rec"
  cat > "$CASE_DIR/m.json" <<JSON
{
  "kinds": ["ship"],
  "components": [
    {
      "name": "component",
      "dir": "component",
      "runtime_checks": [
        { "name": "drains stdin", "argv": ["sh", "-c", "cat > /dev/null"] },
        { "name": "still runs", "argv": ["sh", "-c", "echo ok"], "expect": "ok" }
      ],
      "install": [
        { "name": "drains stdin", "argv": ["sh", "-c", "cat > /dev/null; echo i >> ../install-count"] },
        { "name": "builds", "argv": ["sh", "-c", "mkdir -p built && echo built > built/log && echo i >> ../install-count"] }
      ],
      "probes": [
        { "name": "drains stdin", "argv": ["sh", "-c", "cat > /dev/null; echo p >> ../probe-count"] },
        { "name": "artifact present", "argv": ["sh", "-c", "test -s built/log && echo p >> ../probe-count"] }
      ]
    }
  ]
}
JSON
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m.json")
  expect_code 0 "$?" "a step that reads stdin should not disturb the run: $out"
  installs=$(awk 'END { print NR }' "$WT_DIR/install-count" 2>/dev/null || printf '0\n')
  probes=$(awk 'END { print NR }' "$WT_DIR/probe-count" 2>/dev/null || printf '0\n')
  [ "$installs" = 2 ] || fail "both install steps must run, got $installs"
  [ "$probes" = 2 ] || fail "both probes must run, got $probes"
  assert_present "$WT_DIR/component/built/log" \
    "a ready verdict must not be reachable with the build step skipped"
  pass "a step that reads stdin cannot skip the remaining steps of its own list"
}

test_task_record_and_log_are_written() {
  local rec state out
  rec=$(make_case task-record)
  read_case "$rec"
  state="$CASE_DIR/state"
  mkdir -p "$state"
  write_manifest "$CASE_DIR/m.json"
  out=$(FM_STATE_OVERRIDE="$state" provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m.json" --task demo-a1)
  expect_code 0 "$?" "provisioning with a task id should succeed: $out"
  assert_present "$state/demo-a1.provision" "the verdict should be durable"
  assert_present "$state/demo-a1.provision.log" "the step log should be durable"
  assert_grep 'install :: build' "$state/demo-a1.provision.log" "the log should record each step"
  pass "a task-scoped run leaves a durable verdict and step log behind"
}

test_manifest_path_resolution() {
  local out
  out=$(FM_CONFIG_OVERRIDE="$TMP_ROOT/cfg" "$PROVISION" --manifest-path /some/where/relvino)
  [ "$out" = "$TMP_ROOT/cfg/provision/relvino.json" ] \
    || fail "manifest path should be config/provision/<project>.json, got: $out"
  pass "a project's manifest resolves from config/provision/<project>.json"
}

# --- fm-spawn integration ---------------------------------------------------
#
# The fakes mirror the shape used by the other fm-spawn suites: a fake tmux that
# records what would be typed into the pane, and a fake treehouse that leases a
# real isolated git worktree.

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  # A real harness binary on firstmate's own PATH. Nothing executes it; a spawn
  # that publishes a runtime pin resolves the harness to an absolute path before
  # that pin exists, and refuses to launch a harness it cannot resolve.
  fm_fake_exit0 "$fakebin" claude
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    if [ -s "${FM_FAKE_TREEHOUSE_CURRENT:-}" ]; then
      cat "$FM_FAKE_TREEHOUSE_CURRENT"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_SEND_LOG:-}" ]; then
      shift
      literal=0
      for a in "$@"; do
        [ "$a" != "-l" ] || literal=1
      done
      prev=
      for a in "$@"; do
        case "$a" in
          -t) prev=-t; continue ;;
          -l) continue ;;
          Enter) continue ;;
        esac
        if [ "$prev" = "-t" ]; then prev=; continue; fi
        printf '%s\t%s\n' "$literal" "$a" >> "$FM_FAKE_SEND_LOG"
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  get)
    shift
    holder=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --lease-holder) shift; holder=${1:-} ;;
        --lease-holder=*) holder=${1#--lease-holder=} ;;
      esac
      shift
    done
    [ -n "$holder" ] || exit 2
    pool=${FM_FAKE_TREEHOUSE_POOL:?}
    target="$pool/$holder/project"
    mkdir -p "$(dirname "$target")"
    git -C "$PWD" worktree add --quiet --detach "$target" HEAD || exit 1
    target=$(cd "$target" && pwd -P) || exit 1
    python3 - "$pool/treehouse-state.json" "$target" "$holder" <<'PY'
import json
import os
import sys

state_path, target, holder = sys.argv[1:]
os.makedirs(os.path.dirname(state_path), exist_ok=True)
try:
    with open(state_path, encoding="utf-8") as stream:
        state = json.load(stream)
except FileNotFoundError:
    state = {"worktrees": []}
state["worktrees"] = [
    entry for entry in state.get("worktrees", []) if entry.get("path") != target
]
state["worktrees"].append(
    {"name": holder, "path": target, "leased": True, "lease_holder": holder}
)
with open(state_path, "w", encoding="utf-8") as stream:
    json.dump(state, stream)
PY
    printf '%s\n' "$target" > "${FM_FAKE_TREEHOUSE_CURRENT:?}"
    printf '%s\n' "$target"
    ;;
  return) exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# make_spawn_case <name> <task-id>: build a home, a project repo with a
# component the manifest can provision, and echo the record read_spawn_case
# parses.
make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin sendlog
  case_dir="$TMP_ROOT/spawn-$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  sendlog="$case_dir/send.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config/provision" \
    "$case_dir/treehouse-root" "$case_dir/pinned-bin"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '# Backlog\n\n## In flight\n' > "$home/data/backlog.md"
  printf -- '- [ ] %s - provisioning test (repo: project)\n' "$id" >> "$home/data/backlog.md"
  printf '\n## Queued\n\n## Done\n' >> "$home/data/backlog.md"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  chmod 0644 "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$proj/component"
  printf 'lock-v1\n' > "$proj/component/lock.txt"
  # A real manifest builds gitignored trees (.venv, node_modules), so the
  # fixture's built artifacts are gitignored too. What provisioning leaves
  # UNIGNORED is residue, and residue has its own test below.
  printf 'built/\nbuild-count\n' > "$proj/.gitignore"
  git -C "$proj" add component/lock.txt .gitignore
  git -C "$proj" -c user.name=t -c user.email=t@example.invalid commit -qm component
  git -C "$wt" checkout --quiet --detach HEAD
  git -C "$proj" branch --quiet -D "wt-$name"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$sendlog"
}

read_spawn_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR SEND_LOG <<EOF
$1
EOF
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 sendlog=$4 case_dir
  shift 4
  case_dir=${home%/home}
  : > "$sendlog"
  FM_ROOT_OVERRIDE="${FM_TEST_ROOT_OVERRIDE:-}" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CHECKOUT_REFRESH_STATE_BASE="$case_dir/checkout-state" \
    FM_TREEHOUSE_ROOT="$case_dir/treehouse-root" \
    FM_FAKE_TREEHOUSE_POOL="$case_dir/treehouse-root/profile" \
    FM_FAKE_TREEHOUSE_CURRENT="$case_dir/acquired-worktree" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_SEND_LOG="$sendlog" PATH="$fakebin:$PATH" \
    "${SPAWN_CMD:-$SPAWN}" "$@" 2>&1
}

# make_stub_provisioner_bin <case-dir> <name> <body>: mirror bin/ with symlinks
# and replace ONLY fm-provision.sh with a stub running <body>. The spawn under
# test stays the real one; what is substituted is the provisioner, so a test can
# present fm-spawn with an outcome the real provisioner would not currently
# produce. --manifest-path still reaches the real script, because resolving the
# manifest is exactly what fm-spawn must be able to do independently of the run.
make_stub_provisioner_bin() {
  local case_dir=$1 name=$2 body=$3 bin entry
  # Mirrored as <root>/bin so the spawn's own FM_ROOT still resolves siblings
  # such as bin/fm-harness.sh exactly as it does in the real tree.
  bin="$case_dir/$name-root/bin"
  mkdir -p "$bin"
  for entry in "$ROOT"/bin/*; do
    ln -s "$entry" "$bin/$(basename "$entry")"
  done
  rm -f "$bin/fm-provision.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -u\n'
    # shellcheck disable=SC2016 # Stub source text; it must not expand here.
    printf 'if [ "${1:-}" = "--manifest-path" ]; then\n'
    printf '  exec %s "$@"\n' "$ROOT/bin/fm-provision.sh"
    printf 'fi\n'
    printf '%s\n' "$body"
  } > "$bin/fm-provision.sh"
  chmod +x "$bin/fm-provision.sh"
  printf '%s\n' "$bin"
}

# A provisioner that dies the way an OOM kill, a signal, or an unanticipated exit
# does - with no verdict on stdout for fm-spawn to read.
make_dying_provisioner_bin() {
  make_stub_provisioner_bin "$1" dying \
"printf 'fm-provision: killed before any verdict\n' >&2
kill -KILL \$\$
sleep 5"
}

# A provisioner that emits a well-formed non-ready verdict and exits 3, the
# documented warn-policy failure, regardless of what the manifest says. This is
# what fm-spawn would see if the two scripts ever disagreed about the policy.
make_warn_exit_provisioner_bin() {
  make_stub_provisioner_bin "$1" warnexit \
"printf '%s\n' '{\"schema\":\"fm-provision.v1\",\"status\":\"failed\",\"reason\":\"probe failed\",\"policy\":\"warn\",\"path_prepend\":\"\",\"components\":[]}'
exit 3"
}

file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

# install_spawn_manifest <home> <case-dir> [<jq-filter>]: write the project
# manifest fm-spawn will resolve, optionally transformed.
install_spawn_manifest() {
  local home=$1 case_dir=$2 filter=${3:-.} target="$2/manifest.json"
  write_manifest "$target" path_prepend "[\"$case_dir/pinned-bin\"]"
  jq "$filter" "$target" > "$home/config/provision/project.json"
}

seed_spawn_provision_evidence() {
  local home=$1 id=$2
  printf '{"status":"ready"}\n' > "$home/state/$id.provision"
  printf 'stale log\n' > "$home/state/$id.provision.log"
  {
    printf '\n<!-- fm-provision:begin -->\n'
    printf '\n# Environment readiness\n\n'
    printf 'This stale section must be retired.\n'
    printf '\n<!-- fm-provision:end -->\n'
  } >> "$home/data/$id/brief.md"
}

exported_path() {
  awk -F '\t' '$2 ~ /^export PATH=/ { print $2 }' "$1" | head -n 1
}

sent_launch_line() {
  awk -F '\t' '$2 ~ /--dangerously-skip-permissions/ { print $2 }' "$1" | head -n 1
}

# A provisioner that is present but has lost its exec bit. Firstmate still has to
# be able to tell that this project opted in, and under block it must refuse.
make_unrunnable_provisioner_bin() {
  local bin
  bin=$(make_stub_provisioner_bin "$1" unrunnable "exit 0")
  chmod -x "$bin/fm-provision.sh"
  printf '%s\n' "$bin"
}

test_spawn_pins_the_proven_runtime_into_the_crew_path() {
  local rec id out path_line brief_mode
  id=provision-ready-p1
  rec=$(make_spawn_case ready "$id")
  read_spawn_case "$rec"
  install_spawn_manifest "$HOME_DIR" "$CASE_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$SEND_LOG" "$id" "$PROJ_DIR")
  expect_code 0 "$?" "a ready provisioning run should not disturb the spawn: $out"
  path_line=$(exported_path "$SEND_LOG")
  case "$path_line" in
    "export PATH='$CASE_DIR/pinned-bin:"*) ;;
    *) fail "the crewmate PATH should lead with the proven runtime, got: $path_line" ;;
  esac
  assert_grep 'Environment readiness' "$HOME_DIR/data/$id/brief.md" \
    "a provisioned crewmate should be told its environment is ready"
  assert_present "$HOME_DIR/state/$id.provision" "the spawn should leave a durable verdict"
  brief_mode=$(file_mode "$HOME_DIR/data/$id/brief.md")
  [ "$brief_mode" = 644 ] \
    || fail "the readiness note must not narrow the brief's mode, got $brief_mode"
  pass "a ready provisioning run pins its proven runtime ahead of the crewmate PATH"
}

# The pinned runtime leads the crewmate's PATH, and a pinned node prefix is
# exactly where a globally installed `claude` lives. The harness must therefore
# be launched by the path firstmate resolved for itself, not by a bare name the
# manifest's own directory could answer.
test_spawn_launches_the_harness_by_the_path_firstmate_resolved() {
  local rec id out launch
  id=provision-harness-pin-pd
  rec=$(make_spawn_case harness-pin "$id")
  read_spawn_case "$rec"
  install_spawn_manifest "$HOME_DIR" "$CASE_DIR"
  # A decoy the pinned directory would answer with, since it leads the exported
  # PATH the pane shell resolves against.
  printf '#!/bin/sh\nexit 0\n' > "$CASE_DIR/pinned-bin/claude"
  chmod +x "$CASE_DIR/pinned-bin/claude"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$SEND_LOG" "$id" "$PROJ_DIR")
  expect_code 0 "$?" "a ready provisioning run should still launch: $out"
  launch=$(sent_launch_line "$SEND_LOG")
  assert_contains "$launch" "$FAKEBIN_DIR/claude" \
    "the harness must be launched by the absolute path firstmate resolved: $launch"
  case "$launch" in
    *"$CASE_DIR/pinned-bin/claude"*)
      fail "the manifest's pinned directory must not name the harness binary: $launch" ;;
  esac
  pass "a published runtime pin cannot repoint the harness the spawn launches"
}

test_spawn_fails_closed_when_the_provisioner_cannot_be_run() {
  local rec id out bin
  id=provision-unrunnable-block-pe
  rec=$(make_spawn_case unrunnable-block "$id")
  read_spawn_case "$rec"
  install_spawn_manifest "$HOME_DIR" "$CASE_DIR" '.on_failure = "block"'
  bin=$(make_unrunnable_provisioner_bin "$CASE_DIR")

  out=$(SPAWN_CMD="$bin/fm-spawn.sh" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$SEND_LOG" "$id" "$PROJ_DIR")
  expect_code 1 "$?" "a provisioner that cannot run must not launch under block: $out"
  assert_contains "$out" "WORKTREE PROVISIONING FAILED" "the refusal should be unmissable"
  assert_contains "$out" "not executable" "the banner should name the unrunnable provisioner"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "a block project must not launch a crewmate into an unprovisioned worktree"
  assert_grep 'not executable' "$HOME_DIR/state/$id.provision" \
    "the refusal must leave a durable verdict like any other provisioning failure"
  pass "a provisioner that lost its exec bit is a provisioning failure, not a silent skip"
}

test_spawn_treats_provisioning_residue_as_a_failure() {
  local rec id out
  id=provision-residue-p6
  rec=$(make_spawn_case residue "$id")
  read_spawn_case "$rec"
  install_spawn_manifest "$HOME_DIR" "$CASE_DIR" \
    '.on_failure = "block"
     | .components[0].install += [{"name":"stray artifact","argv":["sh","-c","echo stray > ../stray.log"]}]'

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$SEND_LOG" "$id" "$PROJ_DIR")
  expect_code 1 "$?" "residue left in the lease must not reach an agent under block: $out"
  assert_contains "$out" "WORKTREE PROVISIONING FAILED" "residue should be reported as a provisioning failure"
  assert_contains "$out" "not a safe base for this task" "the banner should name the unclean lease"
  assert_absent "$HOME_DIR/state/$id.meta" "a worktree left dirty by provisioning must not be launched into"
  pass "provisioning residue is caught while the spawn can still refuse"
}

test_spawn_fails_closed_when_the_provisioner_dies_without_a_verdict() {
  local rec id out bin
  id=provision-death-block-p7
  rec=$(make_spawn_case death-block "$id")
  read_spawn_case "$rec"
  install_spawn_manifest "$HOME_DIR" "$CASE_DIR" '.on_failure = "block"'
  bin=$(make_dying_provisioner_bin "$CASE_DIR")

  out=$(SPAWN_CMD="$bin/fm-spawn.sh" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$SEND_LOG" "$id" "$PROJ_DIR")
  expect_code 1 "$?" "on_failure=block must abort when the provisioner dies without a verdict: $out"
  assert_contains "$out" "died without emitting a verdict" "the banner should say the provisioner emitted nothing"
  assert_contains "$out" "no agent is launched" "the banner should say why nothing was launched"
  assert_absent "$HOME_DIR/state/$id.meta" "a verdict-less provisioner death must not launch an agent under block"
  assert_grep 'died without emitting a verdict' "$HOME_DIR/state/$id.provision" \
    "the death must still leave a durable verdict artifact"
  pass "on_failure=block fails closed when the provisioner dies without a verdict"
}

test_spawn_warn_policy_survives_a_verdict_less_provisioner_death() {
  local rec id out path_line bin
  id=provision-death-warn-p8
  rec=$(make_spawn_case death-warn "$id")
  read_spawn_case "$rec"
  install_spawn_manifest "$HOME_DIR" "$CASE_DIR"
  bin=$(make_dying_provisioner_bin "$CASE_DIR")

  out=$(SPAWN_CMD="$bin/fm-spawn.sh" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$SEND_LOG" "$id" "$PROJ_DIR")
  expect_code 0 "$?" "the warn default must still launch after a verdict-less death: $out"
  assert_contains "$out" "died without emitting a verdict" "the death must be loud even under warn"
  assert_contains "$out" "continuing" "the banner should say the spawn continued"
  assert_present "$HOME_DIR/state/$id.meta" "a warn-policy death still launches the task"
  assert_grep 'died without emitting a verdict' "$HOME_DIR/state/$id.provision" \
    "the warn path must record the death durably too"
  assert_grep 'Provisioning this worktree FAILED' "$HOME_DIR/data/$id/brief.md" \
    "the crewmate must be told it cannot validate locally"
  path_line=$(exported_path "$SEND_LOG")
  case "$path_line" in
    *"$CASE_DIR/pinned-bin"*) fail "a dead provisioner must not pin a runtime: $path_line" ;;
  esac
  pass "the warn default continues loudly when the provisioner dies without a verdict"
}

test_spawn_unreadable_failure_policy_is_treated_as_block() {
  local rec id out bin
  id=provision-death-badpolicy-p9
  rec=$(make_spawn_case death-badpolicy "$id")
  read_spawn_case "$rec"
  install_spawn_manifest "$HOME_DIR" "$CASE_DIR" '.on_failure = "maybe"'
  bin=$(make_dying_provisioner_bin "$CASE_DIR")

  out=$(SPAWN_CMD="$bin/fm-spawn.sh" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$SEND_LOG" "$id" "$PROJ_DIR")
  expect_code 1 "$?" "an unrecognized on_failure must not fail open on a verdict-less death: $out"
  assert_absent "$HOME_DIR/state/$id.meta" "an ambiguous policy must not launch an agent into an unproven worktree"
  pass "an unreadable failure policy is resolved as block, not as the warn default"
}

test_spawn_aborts_on_a_verdict_from_an_unreadable_policy_manifest() {
  local rec id out
  id=provision-badpolicy-verdict-pa
  rec=$(make_spawn_case badpolicy-verdict "$id")
  read_spawn_case "$rec"
  install_spawn_manifest "$HOME_DIR" "$CASE_DIR" \
    '.on_failure = "maybe" | .components[0].probes = [{"name":"always fails","argv":["false"]}]'

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$SEND_LOG" "$id" "$PROJ_DIR")
  expect_code 1 "$?" "an unrecognized on_failure must abort even when a verdict was emitted: $out"
  assert_contains "$out" "WORKTREE PROVISIONING FAILED" "the refusal should be unmissable"
  assert_absent "$HOME_DIR/state/$id.meta" "an ambiguous policy must not launch an agent"
  pass "an unreadable policy aborts the spawn on the verdict-bearing path too"
}

test_spawn_honors_a_resolved_block_over_a_warn_exit_code() {
  local rec id out bin
  id=provision-policy-divergence-pb
  rec=$(make_spawn_case policy-divergence "$id")
  read_spawn_case "$rec"
  install_spawn_manifest "$HOME_DIR" "$CASE_DIR" '.on_failure = "block"'
  bin=$(make_warn_exit_provisioner_bin "$CASE_DIR")

  out=$(SPAWN_CMD="$bin/fm-spawn.sh" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$SEND_LOG" "$id" "$PROJ_DIR")
  expect_code 1 "$?" "a resolved block must not be discarded because the exit code said warn: $out"
  assert_absent "$HOME_DIR/state/$id.meta" "a block project must never launch on a non-ready verdict"
  assert_grep 'probe failed' "$HOME_DIR/state/$id.provision" \
    "the durable verdict should keep the provisioner's own reason"
  pass "a resolved block policy survives a provisioner that reported the warn exit code"
}

# A recovery respawn rewrites a section that is already there, which is the cycle
# that can accumulate whitespace: the retire strips the section but not the blank
# line that separated it, and the fresh note then adds its own separator again.
# Seeding the section reproduces that cycle inside one lease.
test_spawn_readiness_note_is_byte_idempotent() {
  local rec id out blanks markers
  id=provision-idempotent-pc
  rec=$(make_spawn_case idempotent "$id")
  read_spawn_case "$rec"
  install_spawn_manifest "$HOME_DIR" "$CASE_DIR"
  seed_spawn_provision_evidence "$HOME_DIR" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$SEND_LOG" "$id" "$PROJ_DIR")
  expect_code 0 "$?" "a provisioned respawn over an existing section should succeed: $out"
  assert_no_grep 'This stale section must be retired' "$HOME_DIR/data/$id/brief.md" \
    "the stale section must be replaced, not kept"
  markers=$(grep -c '^<!-- fm-provision:begin -->$' "$HOME_DIR/data/$id/brief.md")
  [ "$markers" = 1 ] || fail "the readiness section should appear exactly once, got $markers"
  blanks=$(awk '
    BEGIN { run = 0 }
    /^<!-- fm-provision:begin -->$/ { print run; found = 1; exit }
    /^$/ { run++; next }
    { run = 0 }
    END { if (!found) print "no-marker" }' "$HOME_DIR/data/$id/brief.md")
  [ "$blanks" = 1 ] \
    || fail "rewriting the section must not accumulate blank lines before it, got '$blanks'"
  pass "rewriting the readiness section over an existing one keeps the brief byte-stable"
}

test_spawn_continues_loudly_when_provisioning_warns() {
  local rec id out path_line
  id=provision-warn-p2
  rec=$(make_spawn_case warn "$id")
  read_spawn_case "$rec"
  install_spawn_manifest "$HOME_DIR" "$CASE_DIR" \
    '.components[0].probes = [{"name":"always fails","argv":["false"]}]'

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$SEND_LOG" "$id" "$PROJ_DIR")
  expect_code 0 "$?" "a warn-policy provisioning failure must not block the spawn: $out"
  assert_contains "$out" "WORKTREE PROVISIONING FAILED" "the failure should be unmissable in the spawn output"
  assert_contains "$out" "continuing" "the banner should say the spawn continued"
  assert_present "$HOME_DIR/state/$id.meta" "a warn-policy failure still launches the task"
  assert_grep 'Provisioning this worktree FAILED' "$HOME_DIR/data/$id/brief.md" \
    "the crewmate must be told it cannot validate locally"
  path_line=$(exported_path "$SEND_LOG")
  case "$path_line" in
    *"$CASE_DIR/pinned-bin"*) fail "a failed run must not pin a runtime it did not prove: $path_line" ;;
  esac
  pass "a warn-policy provisioning failure launches the crewmate but tells it and firstmate"
}

test_spawn_aborts_when_the_project_declares_block() {
  local rec id out
  id=provision-block-p3
  rec=$(make_spawn_case block "$id")
  read_spawn_case "$rec"
  install_spawn_manifest "$HOME_DIR" "$CASE_DIR" \
    '.on_failure = "block" | .components[0].probes = [{"name":"always fails","argv":["false"]}]'

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$SEND_LOG" "$id" "$PROJ_DIR")
  expect_code 1 "$?" "on_failure=block should abort the spawn"
  assert_contains "$out" "no agent is launched" "the banner should say why nothing was launched"
  assert_absent "$HOME_DIR/state/$id.meta" "a blocked spawn must not record a live task"
  pass "a block-policy project refuses to launch an agent into an unready worktree"
}

test_spawn_no_provision_opt_out() {
  local rec id out
  id=provision-off-p4
  rec=$(make_spawn_case off "$id")
  read_spawn_case "$rec"
  install_spawn_manifest "$HOME_DIR" "$CASE_DIR" \
    '.components[0].probes = [{"name":"always fails","argv":["false"]}]'
  seed_spawn_provision_evidence "$HOME_DIR" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$SEND_LOG" "$id" "$PROJ_DIR" --no-provision)
  expect_code 0 "$?" "--no-provision should spawn without provisioning: $out"
  assert_not_contains "$out" "WORKTREE PROVISIONING FAILED" "--no-provision should not run the manifest at all"
  assert_absent "$HOME_DIR/state/$id.provision" "--no-provision should leave no verdict"
  assert_absent "$HOME_DIR/state/$id.provision.log" "--no-provision should leave no log"
  assert_not_contains "$(cat "$HOME_DIR/data/$id/brief.md")" "Environment readiness" \
    "--no-provision should retire a prior readiness section"
  pass "--no-provision retires stale evidence and skips provisioning"
}

test_spawn_skipped_provisioning_is_a_true_no_op() {
  local rec id out path_line
  id=provision-skip-p5
  rec=$(make_spawn_case skip "$id")
  read_spawn_case "$rec"
  install_spawn_manifest "$HOME_DIR" "$CASE_DIR"
  seed_spawn_provision_evidence "$HOME_DIR" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$SEND_LOG" "$id" "$PROJ_DIR" --scout)
  expect_code 0 "$?" "an excluded-kind provisioning skip should not disturb the spawn: $out"
  assert_absent "$HOME_DIR/state/$id.provision" "a skipped spawn must not leave a verdict"
  assert_absent "$HOME_DIR/state/$id.provision.log" "a skipped spawn must not leave a log"
  assert_not_contains "$(cat "$HOME_DIR/data/$id/brief.md")" "Environment readiness" \
    "a skipped spawn must not claim the worktree was provisioned"
  path_line=$(exported_path "$SEND_LOG")
  case "$path_line" in
    *"$CASE_DIR/pinned-bin"*) fail "a skipped run must not publish a runtime pin: $path_line" ;;
  esac
  pass "a skipped provisioning verdict publishes no readiness evidence"
}

test_absent_manifest_is_a_no_op
test_fresh_worktree_is_built_and_probed
test_unchanged_healthy_environment_is_reused
test_existing_directory_is_never_assumed_healthy
test_changed_input_rebuilds
test_unavailable_fingerprint_never_reuses
test_state_dependent_fingerprint_is_refused_not_recorded
test_empty_to_nonempty_fingerprint_is_refused_not_recorded
test_runtime_check_mismatch_fails_before_building
test_runtime_check_with_no_output_fails
test_probe_expect_is_enforced
test_step_timeout_is_reported_and_bounded
test_bounded_step_supervises_background_descendants
test_reset_is_bounded_by_the_total_budget
test_block_policy_uses_a_distinct_exit_code
test_kind_gate_and_force
test_paths_are_contained
test_reset_targets_are_structurally_strict_descendants
test_fingerprint_paths_are_structurally_strict_descendants
test_component_directory_may_be_the_worktree_root
test_symlinked_paths_are_refused_before_access
test_env_may_not_hijack_path
test_unreadable_policy_fails_closed
test_path_prepend_is_published_only_when_ready
test_a_non_array_components_field_fails_closed
test_a_non_array_step_list_fails_closed
test_a_step_cannot_consume_the_list_that_drives_it
test_task_record_and_log_are_written
test_manifest_path_resolution
test_spawn_pins_the_proven_runtime_into_the_crew_path
test_spawn_launches_the_harness_by_the_path_firstmate_resolved
test_spawn_fails_closed_when_the_provisioner_cannot_be_run
test_spawn_continues_loudly_when_provisioning_warns
test_spawn_aborts_when_the_project_declares_block
test_spawn_no_provision_opt_out
test_spawn_skipped_provisioning_is_a_true_no_op
test_spawn_treats_provisioning_residue_as_a_failure
test_spawn_fails_closed_when_the_provisioner_dies_without_a_verdict
test_spawn_warn_policy_survives_a_verdict_less_provisioner_death
test_spawn_unreadable_failure_policy_is_treated_as_block
test_spawn_aborts_on_a_verdict_from_an_unreadable_policy_manifest
test_spawn_honors_a_resolved_block_over_a_warn_exit_code
test_spawn_readiness_note_is_byte_idempotent

echo "# all fm-provision tests passed"
