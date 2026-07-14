#!/usr/bin/env bash
# Deterministic Agent Fleet integration tests for spawn, recovery, and rollback.
# A fake Agent Fleet and fake tmux capture every command; no profile home,
# credential, real endpoint, global config, or live worker is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-account-routing-tests)

assert_not_grep() {
  local pattern=$1 file=$2 label=$3
  grep -Eq "$pattern" "$file" 2>/dev/null && fail "$label"
  return 0
}

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_TMUX_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_id}"*) [ -f "${FM_FAKE_ENDPOINT_FILE:-/nonexistent}" ]; exit $? ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|set-window-option) exit 0 ;;
  kill-window) rm -f "${FM_FAKE_ENDPOINT_FILE:-/nonexistent}"; exit 0 ;;
  new-window)
    case "$*" in *"${FM_FAKE_TMUX_FAIL_LABEL:-__never__}"*) exit 41 ;; esac
    touch "${FM_FAKE_ENDPOINT_FILE:-/nonexistent}"
    printf '%%77\n'
    exit 0
    ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for arg in "$@"; do
        if [ "$prev" = -l ]; then printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"; fi
        prev=$arg
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  cat > "$fakebin/agent-fleet" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_AF_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_AF_LOG"
task=
pool=
profile=${FM_FAKE_AF_PROFILE:-claude-2}
provider=${FM_FAKE_AF_PROVIDER:-claude}
prev=
for arg in "$@"; do
  case "$prev" in
    --task) task=$arg ;;
    --pool) pool=$arg ;;
    --profile) profile=$arg ;;
    --provider) provider=$arg ;;
  esac
  prev=$arg
done
case "$*" in
  *" choose "*|*" lease choose "*|*" lease acquire "*|*" lease recover "*)
    [ "${FM_FAKE_AF_SELECT_FAIL:-0}" != 1 ] || exit 42
    [ -n "$pool" ] || pool=${FM_FAKE_AF_POOL:-claude-crew}
    printf '{"schema":1,"task":"%s","pool":"%s","profile":"%s","provider":"%s","decision_reason":"fake","quota_fresh":true,"headroom_percent":5,"active_lease_count":0,"degraded":false}\n' "$task" "$pool" "$profile" "$provider"
    ;;
  *" session status "*)
    [ "${FM_FAKE_AF_SESSION_MISSING:-0}" != 1 ] || exit 1
    [ -n "$pool" ] || pool=${FM_FAKE_AF_POOL:-claude-crew}
    printf '{"schema":1,"task":"%s","profile":"%s","provider":"%s","pool":"%s","session_id":"sess-%s","updated_at":"2026-07-13T00:00:00Z"}\n' "$task" "$profile" "$provider" "$pool" "$task"
    ;;
  *" lease release "*|*" session remove "*) printf '{"ok":true}\n' ;;
  *) echo "unexpected fake agent-fleet command: $*" >&2; exit 64 ;;
esac
SH
  chmod +x "$fakebin/agent-fleet"
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
  AF_LOG="$CASE_DIR/agent-fleet.log"
  TMUX_LOG="$CASE_DIR/tmux.log"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  : > "$AF_LOG"
  : > "$TMUX_LOG"
  : > "$LAUNCH_LOG"
}

run_spawn() {
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="${FM_TEST_PANE_PATH:-$WT_DIR}" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_FAKE_AF_LOG="$AF_LOG" \
    FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_AGENT_FLEET_BIN="$FAKEBIN_DIR/agent-fleet" FM_ACCOUNT_SESSION_WAIT_SECONDS=0 \
    TMUX="fake,1,0" PATH="$FAKEBIN_DIR:$PATH" "$SPAWN" "$@" 2>&1
}

test_off_is_byte_compatible_and_never_calls_agent_fleet() {
  local id rec out status launch expected
  id=account-off-z1
  rec=$(make_case off claude "$id")
  read_case "$rec"
  out=$(run_spawn "$id" "$PROJ_DIR")
  status=$?
  [ "$status" -eq 0 ] || fail "default-off spawn should succeed (exit $status): $out"
  [ ! -s "$AF_LOG" ] || fail "routing off invoked Agent Fleet: $(cat "$AF_LOG")"
  launch=$(cat "$LAUNCH_LOG")
  expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$(cat '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "routing off changed the launch bytes"
  assert_not_grep '^account_' "$HOME_DIR/state/$id.meta" "routing off wrote account metadata"
  assert_not_grep '^provider_session_id=' "$HOME_DIR/state/$id.meta" "routing off wrote session metadata"
  assert_contains "$out" "spawned $id" "default-off spawn did not complete"
  pass "routing off makes no Agent Fleet call and preserves launch/meta bytes"
}

test_observe_is_dry_run_only() {
  local id rec out status launch
  id=account-observe-z2
  rec=$(make_case observe claude "$id")
  read_case "$rec"
  out=$(FM_ACCOUNT_ROUTING=observe run_spawn "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "observe spawn should preserve legacy launch"
  assert_grep 'choose --pool claude-crew --task account-observe-z2 --provider claude --dry-run' "$AF_LOG" "observe did not use dry-run choose"
  assert_not_grep 'lease choose\|lease acquire' "$AF_LOG" "observe created a lease"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" ' claude --dangerously-skip-permissions ' "observe changed the provider command"
  assert_not_contains "$launch" 'agent-fleet' "observe wrapped the provider launch"
  assert_not_grep '^account_' "$HOME_DIR/state/$id.meta" "observe wrote account metadata"
  assert_contains "$out" 'observe pool=claude-crew provider=claude profile=claude-2' "observe did not surface its non-secret shadow choice"
  pass "observe performs only a dry run and leaves launch/meta unchanged"
}

test_enforce_pool_wraps_backend_and_records_real_session() {
  local id rec out status launch meta
  id=account-enforce-z3
  rec=$(make_case enforce claude "$id")
  read_case "$rec"
  out=$(FM_FAKE_AF_POOL=claude-crew run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  expect_code 0 "$status" "explicit pool spawn should enforce routing"
  assert_grep 'lease choose --pool claude-crew --task account-enforce-z3 --provider claude' "$AF_LOG" "enforce did not atomically choose a lease"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "'$FAKEBIN_DIR/agent-fleet' --format json exec --profile 'claude-2' --task '$id' --pool 'claude-crew' -- --dangerously-skip-permissions" "enforce did not build the backend-neutral Agent Fleet wrapper"
  meta="$HOME_DIR/state/$id.meta"
  grep -q '^account_pool=' "$meta" || fail "meta missing account pool; contents: $(tr '\n' '|' < "$meta")"
  assert_grep 'account_pool=claude-crew' "$meta" "meta missing account pool"
  assert_grep 'account_profile=claude-2' "$meta" "meta missing selected profile"
  assert_grep "provider_session_id=sess-$id" "$meta" "meta missing real provider session id"
  assert_contains "$out" "spawned $id" "enforced spawn did not complete"
  pass "enforce leases before spawn, wraps any backend launch, and records the real session id"
}

test_explicit_profile_uses_explicit_pool() {
  local id rec status
  id=account-profile-z4
  rec=$(make_case profile claude "$id")
  read_case "$rec"
  FM_FAKE_AF_POOL=explicit run_spawn "$id" "$PROJ_DIR" --account-profile claude-3 >/dev/null
  status=$?
  expect_code 0 "$status" "explicit profile spawn should succeed"
  assert_grep 'lease acquire --profile claude-3 --task account-profile-z4 --pool explicit' "$AF_LOG" "explicit profile did not use explicit acquire"
  assert_grep 'account_pool=explicit' "$HOME_DIR/state/$id.meta" "explicit profile meta missing explicit pool"
  assert_grep 'account_profile=claude-3' "$HOME_DIR/state/$id.meta" "explicit profile meta mismatch"
  pass "an explicit profile is acquired and persisted without a silent default account"
}

test_enforce_failure_prevents_endpoint_creation() {
  local id rec out status
  id=account-select-fail-z5
  rec=$(make_case select-fail claude "$id")
  read_case "$rec"
  out=$(FM_FAKE_AF_SELECT_FAIL=1 run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "failed Agent Fleet selection should block spawn"
  assert_not_grep '^new-window ' "$TMUX_LOG" "endpoint was created after selection failure"
  assert_absent "$HOME_DIR/state/$id.meta" "selection failure wrote task meta"
  [ -n "$out" ] || true
  pass "enforce fails closed before endpoint creation when Agent Fleet cannot select"
}

test_pane_failure_rolls_back_reserved_lease() {
  local id rec out status
  id=account-pane-fail-z6
  rec=$(make_case pane-fail claude "$id")
  read_case "$rec"
  out=$(FM_FAKE_TMUX_FAIL_LABEL="fm-$id" run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "pane creation failure should fail spawn"
  assert_grep 'lease choose --pool claude-crew --task account-pane-fail-z6' "$AF_LOG" "pane-failure test never acquired a lease"
  assert_grep 'lease release --task account-pane-fail-z6 --force' "$AF_LOG" "pane failure did not roll back its reservation"
  assert_absent "$HOME_DIR/state/$id.meta" "pane failure left task meta"
  [ -n "$out" ] || true
  pass "a failure after atomic selection releases the unconsumed lease"
}

test_batch_partial_failure_releases_only_failed_item() {
  local id1 id2 rec out status
  id1=account-batch-ok-z7
  id2=account-batch-fail-z8
  rec=$(make_case batch claude "$id1" "$id2")
  read_case "$rec"
  out=$(FM_FAKE_TMUX_FAIL_LABEL="fm-$id2" run_spawn "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "partial batch failure should exit non-zero"
  assert_grep "lease choose --pool claude-crew --task $id1" "$AF_LOG" "batch first item was not leased"
  assert_grep "lease choose --pool claude-crew --task $id2" "$AF_LOG" "batch second item was not leased"
  assert_not_grep "lease release --task $id1" "$AF_LOG" "successful batch item's lease was rolled back"
  assert_grep "lease release --task $id2 --force" "$AF_LOG" "failed batch item's lease was not rolled back"
  assert_present "$HOME_DIR/state/$id1.meta" "successful batch item lost its meta"
  assert_absent "$HOME_DIR/state/$id2.meta" "failed batch item left meta"
  assert_contains "$out" "batch: FAILED to spawn $id2" "partial batch failure was not reported"
  pass "partial batch failure retains launched leases and releases every unconsumed reservation"
}

test_resume_uses_sticky_recovery_and_preserves_mapping_on_failure() {
  local id rec status launch before_session out
  id=account-resume-z9
  rec=$(make_case resume claude "$id")
  read_case "$rec"
  FM_FAKE_AF_POOL=claude-crew run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null
  status=$?
  expect_code 0 "$status" "initial managed spawn for resume should succeed"
  before_session=$(sed -n 's/^provider_session_id=//p' "$HOME_DIR/state/$id.meta" | tail -1)
  rm -f "$CASE_DIR/endpoint-live"
  : > "$AF_LOG"
  : > "$TMUX_LOG"
  : > "$LAUNCH_LOG"
  out=$(FM_FAKE_AF_POOL=claude-crew run_spawn "$id" --resume-account)
  status=$?
  [ "$status" -eq 0 ] || fail "managed resume should succeed (exit $status): $out"
  assert_grep "lease recover --task $id" "$AF_LOG" "resume used new-task selection instead of sticky recovery reservation"
  assert_not_grep 'lease choose\|lease acquire' "$AF_LOG" "resume ran the new-task quota path"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--format json resume --task '$id' -- --dangerously-skip-permissions" "resume did not use Agent Fleet's fail-closed task mapping"
  assert_not_contains "$launch" 'cat ' "resume started a fresh prompted conversation"
  [ "$(sed -n 's/^provider_session_id=//p' "$HOME_DIR/state/$id.meta" | tail -1)" = "$before_session" ] || fail "resume changed provider session identity"

  : > "$AF_LOG"
  : > "$TMUX_LOG"
  rm -f "$CASE_DIR/endpoint-live"
  out=$(FM_FAKE_AF_SESSION_MISSING=1 FM_FAKE_AF_POOL=claude-crew run_spawn "$id" --resume-account)
  status=$?
  [ "$status" -ne 0 ] || fail "resume without a session mapping should fail closed"
  assert_not_grep '^new-window ' "$TMUX_LOG" "missing session mapping still created an endpoint"
  assert_not_grep 'session remove' "$AF_LOG" "failed resume removed the durable session mapping"
  assert_contains "$out" 'no Agent Fleet provider-session mapping' "missing mapping blocker was not explicit"
  pass "resume uses below-reserve sticky recovery and never deletes mapping on a failed attempt"
}

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter\n' > "$home/data/charter.md"
}

test_secondmate_pool_is_nonactivating_and_noninherited() {
  local id rec sm out status
  id=account-secondmate-off-z10
  rec=$(make_case secondmate-off claude)
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  printf 'claude-captains\n' > "$HOME_DIR/config/secondmate-account-pool"

  out=$(FM_TEST_PANE_PATH="$sm" run_spawn "$id" "$sm" --secondmate)
  status=$?
  [ "$status" -eq 0 ] || fail "pool-only secondmate spawn should stay legacy/off (exit $status): $out"
  [ ! -s "$AF_LOG" ] || fail "secondmate pool activated Agent Fleet while routing was off: $(cat "$AF_LOG")"
  assert_not_grep '^account_' "$HOME_DIR/state/$id.meta" "off secondmate wrote account metadata"
  assert_absent "$sm/config/secondmate-account-pool" "secondmate account pool leaked into the child home"
  pass "the primary secondmate pool is non-inherited and does not activate routing by itself"
}

test_secondmate_pool_routes_when_mode_is_enforced_and_mode_inherits() {
  local id rec sm out status
  id=account-secondmate-enforce-z11
  rec=$(make_case secondmate-enforce claude)
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  printf 'enforce\n' > "$HOME_DIR/config/account-routing-mode"
  printf 'claude-captains\n' > "$HOME_DIR/config/secondmate-account-pool"

  out=$(FM_FAKE_AF_POOL=claude-captains FM_TEST_PANE_PATH="$sm" run_spawn "$id" "$sm" --secondmate)
  status=$?
  [ "$status" -eq 0 ] || fail "enforced secondmate spawn should succeed (exit $status): $out"
  assert_grep "lease choose --pool claude-captains --task $id --provider claude" "$AF_LOG" "secondmate did not use its primary-owned account pool"
  assert_grep 'account_pool=claude-captains' "$HOME_DIR/state/$id.meta" "secondmate meta lost its account pool"
  [ "$(cat "$sm/config/account-routing-mode" 2>/dev/null)" = enforce ] || fail "account routing mode did not inherit into the secondmate home"
  assert_absent "$sm/config/secondmate-account-pool" "primary-only secondmate pool leaked into the child home"
  pass "secondmate routing uses the primary pool while the mode, but not that pool, inherits"
}

test_off_is_byte_compatible_and_never_calls_agent_fleet
test_observe_is_dry_run_only
test_enforce_pool_wraps_backend_and_records_real_session
test_explicit_profile_uses_explicit_pool
test_enforce_failure_prevents_endpoint_creation
test_pane_failure_rolls_back_reserved_lease
test_batch_partial_failure_releases_only_failed_item
test_resume_uses_sticky_recovery_and_preserves_mapping_on_failure
test_secondmate_pool_is_nonactivating_and_noninherited
test_secondmate_pool_routes_when_mode_is_enforced_and_mode_inherits

echo "# all fm-account-routing tests passed"
