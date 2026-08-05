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
  local rec out status
  rec=$(make_case absent-manifest)
  read_case "$rec"
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/nothing-here.json")
  status=$?
  expect_code 0 "$status" "an absent manifest must not fail a spawn"
  [ "$(verdict_field "$out" .status)" = skipped ] || fail "absent manifest should be skipped, got: $out"
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
  local rec out
  rec=$(make_case kind-gate)
  read_case "$rec"
  write_manifest "$CASE_DIR/m.json"
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m.json" --kind scout)
  expect_code 0 "$?" "an excluded kind should skip, not fail"
  [ "$(verdict_field "$out" .status)" = skipped ] || fail "scout should be skipped by default: $out"
  [ "$(build_count "$WT_DIR")" = 0 ] || fail "a skipped kind must not build"
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
  assert_contains "$(verdict_field "$out" .reason)" "escapes the component directory" \
    "the failure should name the refused reset path"
  pass "component and reset paths that escape their base are refused"
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

test_malformed_manifest_warns_rather_than_bricking_spawns() {
  local rec out
  rec=$(make_case malformed)
  read_case "$rec"
  printf '{ not json\n' > "$CASE_DIR/m.json"
  out=$(provision "$PROJ_DIR" "$WT_DIR" "$CASE_DIR/m.json")
  expect_code 3 "$?" "a malformed local manifest must not block every spawn"
  assert_contains "$(verdict_field "$out" .reason)" "not valid JSON" \
    "the failure should name the parse problem"
  pass "a malformed manifest fails loudly under the warn default"
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
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$proj/component"
  printf 'lock-v1\n' > "$proj/component/lock.txt"
  git -C "$proj" add component/lock.txt
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
    "$SPAWN" "$@" 2>&1
}

# install_spawn_manifest <home> <case-dir> [<jq-filter>]: write the project
# manifest fm-spawn will resolve, optionally transformed.
install_spawn_manifest() {
  local home=$1 case_dir=$2 filter=${3:-.} target="$2/manifest.json"
  write_manifest "$target" path_prepend "[\"$case_dir/pinned-bin\"]"
  jq "$filter" "$target" > "$home/config/provision/project.json"
}

exported_path() {
  awk -F '\t' '$2 ~ /^export PATH=/ { print $2 }' "$1" | head -n 1
}

test_spawn_pins_the_proven_runtime_into_the_crew_path() {
  local rec id out path_line
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
  pass "a ready provisioning run pins its proven runtime ahead of the crewmate PATH"
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

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$SEND_LOG" "$id" "$PROJ_DIR" --no-provision)
  expect_code 0 "$?" "--no-provision should spawn without provisioning: $out"
  assert_not_contains "$out" "WORKTREE PROVISIONING FAILED" "--no-provision should not run the manifest at all"
  assert_absent "$HOME_DIR/state/$id.provision" "--no-provision should leave no verdict"
  pass "--no-provision skips provisioning entirely"
}

test_absent_manifest_is_a_no_op
test_fresh_worktree_is_built_and_probed
test_unchanged_healthy_environment_is_reused
test_existing_directory_is_never_assumed_healthy
test_changed_input_rebuilds
test_unavailable_fingerprint_never_reuses
test_state_dependent_fingerprint_is_refused_not_recorded
test_runtime_check_mismatch_fails_before_building
test_runtime_check_with_no_output_fails
test_step_timeout_is_reported_and_bounded
test_block_policy_uses_a_distinct_exit_code
test_kind_gate_and_force
test_paths_are_contained
test_env_may_not_hijack_path
test_malformed_manifest_warns_rather_than_bricking_spawns
test_path_prepend_is_published_only_when_ready
test_task_record_and_log_are_written
test_manifest_path_resolution
test_spawn_pins_the_proven_runtime_into_the_crew_path
test_spawn_continues_loudly_when_provisioning_warns
test_spawn_aborts_when_the_project_declares_block
test_spawn_no_provision_opt_out

echo "# all fm-provision tests passed"
