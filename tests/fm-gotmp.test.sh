#!/usr/bin/env bash
# Behavior tests for per-task GOTMPDIR support (fm-gotmp).
#
# fm-spawn gives each task a temp root /tmp/fm-<id>/ with Go's build temp nested at
# gotmp/, exports GOTMPDIR into the crewmate pane, and records tasktmp= in the task's
# meta. fm-teardown reads tasktmp= and removes the whole root on cleanup.
#
# These tests exercise behavior directly: fm-teardown is run as a subprocess against a
# fake FM_HOME/FM_ROOT (built so the real script resolves into it), with stub helper scripts.
# Nothing is sourced. The fm-spawn side is verified both structurally (the source has
# the contract lines) and behaviorally (the mkdir + meta-write pattern it uses).
set -u

# This suite does not source tests/lib.sh, so exempt its teardown subprocess from
# the gate-lifecycle refusal (bin/fm-gate-refuse-lib.sh) the way lib.sh does for
# the rest of the suite: the no-mistakes gate runs this suite from a gate worktree,
# which the guard would otherwise refuse.
export FM_GATE_REFUSE_BYPASS=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

TMP_ROOT=

cleanup() {
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-gotmp-tests.XXXXXX")
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

make_fixture_project() {
  local project=$1 worktree=$2 id=$3
  mkdir -p "$project" "$(dirname "$worktree")"
  git -C "$project" init -q
  printf 'fixture\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm initial
  git -C "$project" worktree add --quiet -b "fm/$id" "$worktree"
}

# Build a fake FM_HOME/FM_ROOT so the real fm-teardown.sh (symlinked in) resolves
# state and helper scripts inside it. Stub the helper scripts fm-teardown calls so no
# live tmux/treehouse/fleet state is touched. The leased worktree and Treehouse state
# are real local fixtures because teardown validates both before allowing cleanup.
make_fake_root() {
  local id=$1 tasktmp=$2 fixture=${3:-$1}
  local fake="$TMP_ROOT/$fixture" project="$TMP_ROOT/$fixture/project"
  local worktree="$TMP_ROOT/$fixture/treehouse-pool/1/worktree"
  mkdir -p "$fake/bin/backends" "$fake/state" "$fake/data/$id" "$fake/fakebin" "$fake/user"
  make_fixture_project "$project" "$worktree" "$id"
  printf 'fixture scout report\n' > "$fake/data/$id/report.md"
  cat > "$fake/treehouse-pool/treehouse-state.json" <<EOF
{"worktrees":[{"name":"1","path":"$worktree","leased":true,"lease_holder":"firstmate-$id"}]}
EOF
  # Symlink the REAL teardown so the test exercises actual code, not a copy.
  ln -s "$TEARDOWN" "$fake/bin/fm-teardown.sh"
  # fm-backend.sh + its tmux adapter: symlink the REAL files (teardown sources
  # fm-backend.sh unconditionally, and dispatches the kill call through the
  # tmux adapter; both are unchanged by this suite's fixture, just newly
  # required siblings since the P1 backend extraction).
  ln -s "$ROOT/bin/fm-backend.sh" "$fake/bin/fm-backend.sh"
  ln -s "$ROOT/bin/backends/tmux.sh" "$fake/bin/backends/tmux.sh"
  ln -s "$ROOT/bin/fm-tmux-lib.sh" "$fake/bin/fm-tmux-lib.sh"
  ln -s "$ROOT/bin/fm-composer-lib.sh" "$fake/bin/fm-composer-lib.sh"
  # fm-lock-lib.sh: teardown sources it for the shared lock-staleness proof.
  ln -s "$ROOT/bin/fm-lock-lib.sh" "$fake/bin/fm-lock-lib.sh"
  ln -s "$ROOT/bin/fm-checkout-lock-lib.sh" "$fake/bin/fm-checkout-lock-lib.sh"
  ln -s "$ROOT/bin/fm-process-tree-lib.sh" "$fake/bin/fm-process-tree-lib.sh"
  ln -s "$ROOT/bin/fm-wake-lib.sh" "$fake/bin/fm-wake-lib.sh"
  # fm-gate-refuse-lib.sh: teardown sources it before any fleet mutation.
  ln -s "$ROOT/bin/fm-gate-refuse-lib.sh" "$fake/bin/fm-gate-refuse-lib.sh"
  ln -s "$ROOT/bin/fm-account-routing-lib.sh" "$fake/bin/fm-account-routing-lib.sh"
  # fm-guard.sh: stub (teardown calls it with `|| true`).
  cat > "$fake/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-guard.sh"
  # fm-fleet-sync.sh: stub (called for non-scout/non-local-only teardowns).
  cat > "$fake/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake/bin/fm-fleet-sync.sh"
  # fm-tasks-axi-lib.sh: stub (teardown sources it). Report no backend so
  # backlog_refresh_reminder takes the plain-message path; no tasks-axi here.
  cat > "$fake/bin/fm-tasks-axi-lib.sh" <<'SH'
fm_tasks_axi_backend_available() { return 1; }
SH
  cat > "$fake/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) exit 0 ;;
  *) exit 1 ;;
esac
SH
  cat > "$fake/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  return)
    target=$(pwd -P) || exit 1
    project=${FM_TREEHOUSE_RETURN_PROJECT:?}
    cd "$project" || exit 1
    git worktree remove --force "$target"
    ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fake/fakebin/tmux" "$fake/fakebin/treehouse"
  {
    echo "window=fakeses:fm-$id"
    echo "worktree=$worktree"
    echo "project=$project"
    echo "harness=claude"
    echo "kind=scout"
    echo "mode=no-mistakes"
    echo "yolo=off"
    [ -z "$tasktmp" ] || echo "tasktmp=$tasktmp"
  } > "$fake/state/$id.meta"
  printf '%s' "$fake"
}

run_teardown() {
  local fake=$1 id=$2
  HOME="$fake/user" PATH="$fake/fakebin:$PATH" FM_HOME="$fake" \
    FM_TREEHOUSE_ROOT="$fake/treehouse-pool" FM_CHECKOUT_REFRESH_STATE_BASE="$fake/checkout-refresh" \
    bash "$fake/bin/fm-teardown.sh" "$id"
}

# --- fm-spawn side ---

test_spawn_contract_and_mkdir_pattern() {
  # Structural: fm-spawn must create the gotmp dir, record tasktmp in meta, and export
  # GOTMPDIR into the pane. Assert the contract lines are present in the source.
  # shellcheck disable=SC2016  # single quotes are deliberate: these are literal source strings
  grep -F 'mkdir -p "$TASK_TMP/gotmp"' "$SPAWN" >/dev/null \
    || fail "fm-spawn missing: mkdir of gotmp under TASK_TMP"
  # shellcheck disable=SC2016  # single quotes are deliberate: literal source string
  grep -F 'echo "tasktmp=$TASK_TMP"' "$SPAWN" >/dev/null \
    || fail "fm-spawn missing: tasktmp= line in meta write"
  grep -F 'export GOTMPDIR=' "$SPAWN" >/dev/null \
    || fail "fm-spawn missing: GOTMPDIR export into pane"
  # Behavioral: the mkdir + meta-write pattern spawn uses must produce a gotmp dir and
  # a meta line whose value the teardown grep (tasktmp=, cut -d= -f2-) reads back whole.
  local id=spawn-sim-z1
  local sim_root="$TMP_ROOT/$id-root"
  local task_tmp="$sim_root/tmp/fm-$id"
  mkdir -p "$sim_root/state"
  # Replicate spawn's exact mkdir + meta-write lines.
  TASK_TMP="$task_tmp"
  mkdir -p "$TASK_TMP/gotmp"
  {
    echo "tasktmp=$TASK_TMP"
  } > "$sim_root/state/$id.meta"
  [ -d "$task_tmp/gotmp" ] || fail "simulated spawn did not create gotmp dir"
  # Teardown reads tasktmp= with `grep '^tasktmp=' | cut -d= -f2-`; round-trip it.
  local read_back
  read_back=$(grep '^tasktmp=' "$sim_root/state/$id.meta" | cut -d= -f2-)
  [ "$read_back" = "$task_tmp" ] \
    || fail "tasktmp value not round-tripped by teardown's grep|cut (got '$read_back')"
  pass "fm-spawn creates gotmp dir and records tasktmp in meta"
}

# --- fm-teardown side (real subprocess) ---

test_teardown_removes_tasktmp_dir() {
  local id=td-rm-z2
  local task_tmp="/tmp/fm-$id"
  local out
  mkdir -p "$task_tmp/gotmp"
  printf 'leftover\n' > "$task_tmp/gotmp/build-artifact"
  local fake
  fake=$(make_fake_root "$id" "$task_tmp")
  # Sanity: dir + contents exist before teardown.
  [ -d "$task_tmp/gotmp" ] || fail "precondition: gotmp missing before teardown"
  # Run the REAL teardown against the fake root.
  out=$(run_teardown "$fake" "$id" 2>&1) \
    || fail "teardown exited non-zero with a valid tasktmp"$'\n'"$out"
  [ ! -e "$task_tmp" ] \
    || fail "teardown did not remove the tasktmp dir ($task_tmp still exists)"$'\n'"$out"
  pass "fm-teardown removes the dir pointed to by tasktmp= in meta"
}

test_teardown_skips_gracefully_without_tasktmp() {
  # Backward compat: a meta from a pre-fix task has no tasktmp= line. Teardown must
  # not error and must not remove anything.
  local id=td-absent-z3
  local fake
  fake=$(make_fake_root "$id" '')
  run_teardown "$fake" "$id" >/dev/null 2>&1 \
    || fail "teardown exited non-zero when tasktmp= was absent"
  pass "fm-teardown skips gracefully when tasktmp= is absent (backward compat)"
}

test_second_teardown_with_already_removed_tasktmp_succeeds() {
  # Two teardown generations for the same task id share the deterministic tasktmp.
  # The first removes it; the second must treat the already-absent exact path as success.
  local id=td-repeat-z4
  local task_tmp="/tmp/fm-$id"
  local first second out
  mkdir -p "$task_tmp/gotmp"
  first=$(make_fake_root "$id" "$task_tmp" "$id-first")
  out=$(run_teardown "$first" "$id" 2>&1) \
    || fail "first teardown exited non-zero with a valid tasktmp"$'\n'"$out"
  [ ! -e "$task_tmp" ] || fail "first teardown did not remove $task_tmp"
  second=$(make_fake_root "$id" "$task_tmp" "$id-second")
  out=$(run_teardown "$second" "$id" 2>&1) \
    || fail "second teardown exited non-zero with an already-absent exact tasktmp"$'\n'"$out"
  [ ! -e "$task_tmp" ] || fail "teardown created/left the tasktmp dir unexpectedly"
  pass "a second teardown for the same task succeeds after its exact tasktmp is already gone"
}

test_teardown_refuses_wrong_tasktmp_path() {
  local id=td-wrong-z5
  local wrong="$TMP_ROOT/wrong-tasktmp-$id" fake out
  mkdir -p "$wrong"
  printf 'retain\n' > "$wrong/sentinel"
  fake=$(make_fake_root "$id" "$wrong")
  if out=$(run_teardown "$fake" "$id" 2>&1); then
    fail "teardown accepted a tasktmp path other than the exact /tmp/fm-<id> path"
  fi
  case "$out" in
    *"REFUSED: unsafe task temp path in metadata for $id: $wrong"*) ;;
    *) fail "wrong tasktmp refusal did not name the unsafe metadata path"$'\n'"$out" ;;
  esac
  [ -f "$wrong/sentinel" ] || fail "wrong tasktmp path was modified despite refusal"
  pass "fm-teardown still refuses and preserves a wrong tasktmp path"
}

test_spawn_contract_and_mkdir_pattern
test_teardown_removes_tasktmp_dir
test_teardown_skips_gracefully_without_tasktmp
test_second_teardown_with_already_removed_tasktmp_succeeds
test_teardown_refuses_wrong_tasktmp_path
