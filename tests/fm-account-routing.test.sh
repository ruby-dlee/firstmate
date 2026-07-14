#!/usr/bin/env bash
# Deterministic Agent Fleet integration tests for spawn, recovery, and rollback.
# A fake Agent Fleet and fake tmux capture every command; no profile home,
# credential, real endpoint, global config, or live worker is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
SEND="$ROOT/bin/fm-send.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
SESSION_SYNC="$ROOT/bin/fm-account-session-sync.sh"
CONTINUATION="$ROOT/bin/fm-account-continuation.sh"
TMP_ROOT=$(fm_test_tmproot fm-account-routing-tests)

assert_not_grep() {
  local pattern=$1 file=$2 label=$3
  grep -Eq "$pattern" "$file" 2>/dev/null && fail "$label"
  return 0
}

assert_regex() {
  local pattern=$1 file=$2 label=$3
  grep -Eq "$pattern" "$file" 2>/dev/null || fail "$label"
}

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_TMUX_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
[ -z "${FM_FAKE_LIFECYCLE_LOG:-}" ] || printf 'tmux %s\n' "$*" >> "$FM_FAKE_LIFECYCLE_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  display-message*"#{pane_id}"*)
    case "${FM_FAKE_TARGET_STATE:-auto}" in
      present) exit 0 ;;
      absent|unknown) exit 1 ;;
    esac
    [ -f "${FM_FAKE_ENDPOINT_FILE:-/nonexistent}" ]; exit $?
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-panes) [ "${FM_FAKE_TARGET_STATE:-auto}" != unknown ]; exit $? ;;
  list-windows|has-session|new-session|set-window-option) exit 0 ;;
  kill-window)
    [ "${FM_FAKE_TMUX_KILL_FAIL:-0}" != 1 ] || exit 71
    rm -f "${FM_FAKE_ENDPOINT_FILE:-/nonexistent}"
    exit 0
    ;;
  new-window)
    case "$*" in *"${FM_FAKE_TMUX_FAIL_LABEL:-__never__}"*) exit 41 ;; esac
    [ -z "${FM_FAKE_TMUX_NEW_WINDOW_MARKER:-}" ] || touch "$FM_FAKE_TMUX_NEW_WINDOW_MARKER"
    if [ -n "${FM_FAKE_TMUX_NEW_WINDOW_GATE:-}" ]; then
      while [ ! -f "$FM_FAKE_TMUX_NEW_WINDOW_GATE" ]; do sleep 0.05; done
    fi
    touch "${FM_FAKE_ENDPOINT_FILE:-/nonexistent}"
    printf '%%77\n'
    exit 0
    ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for arg in "$@"; do
        if [ "$prev" = -l ]; then
          printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"
          case "$arg" in
            *' resume --task '*) [ -z "${FM_FAKE_AF_RESUME_ARM:-}" ] || touch "$FM_FAKE_AF_RESUME_ARM" ;;
            *'account-native-launch'*)
              [ -z "${FM_FAKE_AF_RESUME_ARM:-}" ] || touch "$FM_FAKE_AF_RESUME_ARM"
              native_path=${arg#*\'}
              native_path=${native_path%%\'*}
              [ -z "${FM_FAKE_NATIVE_LAUNCH_LOG:-}" ] || cat "$native_path" >> "$FM_FAKE_NATIVE_LAUNCH_LOG"
              ;;
          esac
        fi
        prev=$arg
      done
    fi
    case "$*" in
      *' Enter')
        if [ -n "${FM_FAKE_AF_RESUME_ARM:-}" ] && [ -f "$FM_FAKE_AF_RESUME_ARM" ]; then
          rm -f "$FM_FAKE_AF_RESUME_ARM"
          [ -z "${FM_FAKE_AF_RESUME_READY:-}" ] || touch "$FM_FAKE_AF_RESUME_READY"
          (
            for _ in $(seq 1 200); do
              [ -n "${FM_FAKE_AF_RESUME_GO:-}" ] && [ -f "$FM_FAKE_AF_RESUME_GO" ] && break
              sleep 0.05
            done
            if [ -n "${FM_FAKE_AF_RESUME_GO:-}" ] && [ -f "$FM_FAKE_AF_RESUME_GO" ] \
              && [ "${FM_FAKE_AF_RESUME_NO_REFRESH:-0}" != 1 ] && [ -n "${FM_FAKE_AF_SESSION_REFRESHED:-}" ]; then
              touch "$FM_FAKE_AF_SESSION_REFRESHED"
            fi
          ) </dev/null >/dev/null 2>&1 &
        fi
        ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_TREEHOUSE_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TREEHOUSE_LOG"
[ -z "${FM_FAKE_LIFECYCLE_LOG:-}" ] || printf 'treehouse %s\n' "$*" >> "$FM_FAKE_LIFECYCLE_LOG"
[ -z "${FM_FAKE_TREEHOUSE_SLEEP:-}" ] || sleep "$FM_FAKE_TREEHOUSE_SLEEP"
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/orca" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_ORCA_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_ORCA_LOG"
case "$*" in
  'status --json') printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'; exit 0 ;;
esac
echo "unexpected fake orca command: $*" >&2
exit 64
SH
  chmod +x "$fakebin/orca"
  cat > "$fakebin/agent-fleet" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_AF_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_AF_LOG"
[ -z "${FM_FAKE_LIFECYCLE_LOG:-}" ] || printf 'agent-fleet %s\n' "$*" >> "$FM_FAKE_LIFECYCLE_LOG"
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
    if [ "${FM_FAKE_AF_BAD_SELECTION:-0}" = 1 ]; then printf '{bad json\n'; exit 0; fi
    [ -n "$pool" ] || pool=${FM_FAKE_AF_POOL:-claude-crew}
    case "$*" in
      *" lease recover "*)
        [ -z "${FM_FAKE_AF_RECOVER_TASK:-}" ] || task=$FM_FAKE_AF_RECOVER_TASK
        [ "${FM_FAKE_AF_STALE_REFRESH_ON_RECOVER:-0}" != 1 ] || touch "${FM_FAKE_AF_SESSION_REFRESHED:?}"
        ;;
    esac
    printf '{"schema":1,"task":"%s","pool":"%s","profile":"%s","provider":"%s","decision_reason":"fake","quota_fresh":true,"headroom_percent":5,"active_lease_count":0,"degraded":false}\n' "$task" "$pool" "$profile" "$provider"
    ;;
  *" session status "*)
    [ "${FM_FAKE_AF_SESSION_MISSING:-0}" != 1 ] || exit 1
    if [ -n "${FM_FAKE_AF_RESUME_GO:-}" ] && [ -f "$FM_FAKE_AF_RESUME_GO" ] \
      && [ "${FM_FAKE_AF_RESUME_NO_REFRESH:-0}" != 1 ] && [ -n "${FM_FAKE_AF_SESSION_REFRESHED:-}" ]; then
      touch "$FM_FAKE_AF_SESSION_REFRESHED"
    fi
    [ -z "${FM_FAKE_AF_SESSION_MARKER:-}" ] || touch "$FM_FAKE_AF_SESSION_MARKER"
    [ -z "${FM_FAKE_AF_SESSION_SLEEP:-}" ] || sleep "$FM_FAKE_AF_SESSION_SLEEP"
    [ -n "$pool" ] || pool=${FM_FAKE_AF_POOL:-claude-crew}
    updated_at=${FM_FAKE_AF_UPDATED_AT_BEFORE:-2026-07-13T00:00:00Z}
    if [ -n "${FM_FAKE_AF_SESSION_REFRESHED:-}" ] && [ -f "$FM_FAKE_AF_SESSION_REFRESHED" ]; then
      updated_at=${FM_FAKE_AF_UPDATED_AT_AFTER:-2026-07-13T00:00:01Z}
    fi
    printf '{"schema":1,"task":"%s","profile":"%s","provider":"%s","pool":"%s","session_id":"sess-%s","updated_at":"%s"}\n' "$task" "$profile" "$provider" "$pool" "$task" "$updated_at"
    ;;
  *" lease release "*)
    [ -z "${FM_FAKE_AF_RELEASE_MARKER:-}" ] || touch "$FM_FAKE_AF_RELEASE_MARKER"
    [ "${FM_FAKE_AF_RELEASE_FAIL:-0}" != 1 ] || exit 43
    if [ -n "${FM_FAKE_AF_RELEASE_FAIL_ONCE:-}" ] && [ ! -f "$FM_FAKE_AF_RELEASE_FAIL_ONCE" ]; then
      touch "$FM_FAKE_AF_RELEASE_FAIL_ONCE"
      exit 43
    fi
    printf '{"ok":true}\n'
    ;;
  *" session remove "*)
    [ "${FM_FAKE_AF_SESSION_REMOVE_FAIL:-0}" != 1 ] || exit 44
    if [ -n "${FM_FAKE_AF_SESSION_REMOVE_FAIL_ONCE:-}" ] && [ ! -f "$FM_FAKE_AF_SESSION_REMOVE_FAIL_ONCE" ]; then
      touch "$FM_FAKE_AF_SESSION_REMOVE_FAIL_ONCE"
      exit 44
    fi
    printf '{"ok":true}\n'
    ;;
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
  TREEHOUSE_LOG="$CASE_DIR/treehouse.log"
  LIFECYCLE_LOG="$CASE_DIR/lifecycle.log"
  ORCA_LOG="$CASE_DIR/orca.log"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  NATIVE_LAUNCH_LOG="$CASE_DIR/native-launch.log"
  : > "$AF_LOG"
  : > "$TMUX_LOG"
  : > "$TREEHOUSE_LOG"
  : > "$LIFECYCLE_LOG"
  : > "$ORCA_LOG"
  : > "$LAUNCH_LOG"
  : > "$NATIVE_LAUNCH_LOG"
}

run_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="${FM_TEST_PANE_PATH:-$WT_DIR}" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_FAKE_AF_LOG="$AF_LOG" \
    FM_FAKE_TREEHOUSE_LOG="$TREEHOUSE_LOG" FM_FAKE_LIFECYCLE_LOG="$LIFECYCLE_LOG" \
    FM_FAKE_ORCA_LOG="$ORCA_LOG" \
    FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_AF_RESUME_ARM="$CASE_DIR/resume-arm" FM_FAKE_AF_SESSION_REFRESHED="$CASE_DIR/session-refreshed" \
    FM_FAKE_AF_RESUME_READY="$HOME_DIR/state/.$id.account-native-ready" FM_FAKE_AF_RESUME_GO="$HOME_DIR/state/.$id.account-native-go" \
    FM_FAKE_NATIVE_LAUNCH_LOG="$NATIVE_LAUNCH_LOG" \
    FM_AGENT_FLEET_BIN="$FAKEBIN_DIR/agent-fleet" FM_ACCOUNT_SESSION_WAIT_SECONDS=0 \
    TMUX="fake,1,0" PATH="$FAKEBIN_DIR:$PATH" "$SPAWN" "$@" 2>&1
}

run_teardown() {
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_FAKE_AF_LOG="$AF_LOG" \
    FM_FAKE_TREEHOUSE_LOG="$TREEHOUSE_LOG" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_AGENT_FLEET_BIN="$FAKEBIN_DIR/agent-fleet" \
    TMUX="fake,1,0" PATH="$FAKEBIN_DIR:$PATH" "$TEARDOWN" "$@"
}

run_send() {
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" FM_SEND_RETRIES=1 FM_SEND_SLEEP=0 FM_SEND_SETTLE=0 \
    TMUX="fake,1,0" PATH="$FAKEBIN_DIR:$PATH" "$SEND" "$@"
}

meta_account_task() {
  sed -n 's/^account_task=//p' "$HOME_DIR/state/$1.meta" | tail -1
}

logged_account_task() {
  sed -n 's/.*--task \([^ ]*\).*/\1/p' "$AF_LOG" | head -1
}

clear_case_logs() {
  : > "$AF_LOG"
  : > "$TMUX_LOG"
  : > "$TREEHOUSE_LOG"
  : > "$LIFECYCLE_LOG"
  : > "$ORCA_LOG"
  : > "$LAUNCH_LOG"
  : > "$NATIVE_LAUNCH_LOG"
  rm -f "$CASE_DIR/resume-arm" "$CASE_DIR/session-refreshed"
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
  assert_regex 'choose --pool claude-crew --task fm-[0-9a-f]+-account-observe-z2-a[0-9a-f]+ --provider claude --dry-run' "$AF_LOG" "observe did not use a namespaced dry-run choice"
  assert_not_grep 'lease choose\|lease acquire' "$AF_LOG" "observe created a lease"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" ' claude --dangerously-skip-permissions ' "observe changed the provider command"
  assert_not_contains "$launch" 'agent-fleet' "observe wrapped the provider launch"
  assert_not_grep '^account_' "$HOME_DIR/state/$id.meta" "observe wrote account metadata"
  assert_contains "$out" 'observe pool=claude-crew provider=claude profile=claude-2' "observe did not surface its non-secret shadow choice"
  pass "observe performs only a dry run and leaves launch/meta unchanged"
}

test_enforce_pool_wraps_backend_and_records_real_session() {
  local id rec out status launch meta account_task
  id=account-enforce-z3
  rec=$(make_case enforce claude "$id")
  read_case "$rec"
  out=$(FM_FAKE_AF_POOL=claude-crew run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  expect_code 0 "$status" "explicit pool spawn should enforce routing"
  account_task=$(meta_account_task "$id")
  assert_grep "lease choose --pool claude-crew --task $account_task --provider claude" "$AF_LOG" "enforce did not atomically choose a namespaced lease"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "'$FAKEBIN_DIR/agent-fleet' --format json exec --profile 'claude-2' --task '$account_task' --pool 'claude-crew' -- --dangerously-skip-permissions" "enforce did not build the backend-neutral Agent Fleet wrapper"
  meta="$HOME_DIR/state/$id.meta"
  grep -q '^account_pool=' "$meta" || fail "meta missing account pool; contents: $(tr '\n' '|' < "$meta")"
  assert_grep 'account_pool=claude-crew' "$meta" "meta missing account pool"
  assert_grep 'account_profile=claude-2' "$meta" "meta missing selected profile"
  assert_grep "account_task=$account_task" "$meta" "meta missing namespaced Agent Fleet task"
  assert_grep "provider_session_id=sess-$account_task" "$meta" "meta missing real provider session id"
  assert_contains "$out" "spawned $id" "enforced spawn did not complete"
  pass "enforce leases before spawn, wraps any backend launch, and records the real session id"
}

test_explicit_profile_uses_explicit_pool() {
  local id rec out status account_task
  id=account-profile-z4
  rec=$(make_case profile claude "$id")
  read_case "$rec"
  out=$(FM_FAKE_AF_POOL=explicit FM_FAKE_AF_PROFILE=claude-3 run_spawn "$id" "$PROJ_DIR" --account-profile claude-3)
  status=$?
  [ "$status" -eq 0 ] || fail "explicit profile spawn should succeed: $out"
  account_task=$(meta_account_task "$id")
  assert_grep "lease acquire --profile claude-3 --task $account_task --pool explicit" "$AF_LOG" "explicit profile did not use explicit acquire"
  assert_grep 'account_pool=explicit' "$HOME_DIR/state/$id.meta" "explicit profile meta missing explicit pool"
  assert_grep 'account_profile=claude-3' "$HOME_DIR/state/$id.meta" "explicit profile meta mismatch"
  pass "an explicit profile is acquired and persisted without a silent default account"
}

test_enforce_failure_rolls_back_prepared_endpoint() {
  local id rec out status
  id=account-select-fail-z5
  rec=$(make_case select-fail claude "$id")
  read_case "$rec"
  out=$(FM_FAKE_AF_SELECT_FAIL=1 run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "failed Agent Fleet selection should block spawn"
  assert_regex '^new-window ' "$TMUX_LOG" "selection did not happen after endpoint preparation"
  assert_regex '^kill-window ' "$TMUX_LOG" "selection failure did not remove its prepared endpoint"
  assert_grep 'return --force' "$TREEHOUSE_LOG" "selection failure did not return its prepared worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "selection failure wrote task meta"
  [ -n "$out" ] || true
  pass "enforce reserves immediately before binding and rolls back prepared runtime state"
}

test_pane_failure_happens_before_account_reservation() {
  local id rec out status
  id=account-pane-fail-z6
  rec=$(make_case pane-fail claude "$id")
  read_case "$rec"
  out=$(FM_FAKE_TMUX_FAIL_LABEL="fm-$id" run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "pane creation failure should fail spawn"
  [ ! -s "$AF_LOG" ] || fail "pane failure touched Agent Fleet before endpoint preparation completed: $(cat "$AF_LOG")"
  assert_absent "$HOME_DIR/state/$id.meta" "pane failure left task meta"
  [ -n "$out" ] || true
  pass "endpoint preparation failures happen before any Agent Fleet reservation"
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
  assert_regex "lease choose --pool claude-crew --task .*-$id1-" "$AF_LOG" "batch first item was not leased"
  assert_not_grep "lease choose --pool claude-crew --task .*-$id2-" "$AF_LOG" "failed batch item reserved before endpoint preparation"
  assert_not_grep 'lease release' "$AF_LOG" "batch pane failure released another task's lease"
  assert_present "$HOME_DIR/state/$id1.meta" "successful batch item lost its meta"
  assert_absent "$HOME_DIR/state/$id2.meta" "failed batch item left meta"
  assert_contains "$out" "batch: FAILED to spawn $id2" "partial batch failure was not reported"
  pass "partial batch failure retains launched leases and releases every unconsumed reservation"
}

test_resume_uses_sticky_recovery_and_preserves_mapping_on_failure() {
  local id rec status launch before_session out account_task
  id=account-resume-z9
  rec=$(make_case resume claude "$id")
  read_case "$rec"
  FM_FAKE_AF_POOL=claude-crew run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null
  status=$?
  expect_code 0 "$status" "initial managed spawn for resume should succeed"
  before_session=$(sed -n 's/^provider_session_id=//p' "$HOME_DIR/state/$id.meta" | tail -1)
  account_task=$(meta_account_task "$id")
  rm -f "$CASE_DIR/endpoint-live"
  : > "$AF_LOG"
  : > "$TMUX_LOG"
  : > "$LAUNCH_LOG"
  : > "$NATIVE_LAUNCH_LOG"
  out=$(FM_FAKE_AF_POOL=claude-crew run_spawn "$id" --resume-account)
  status=$?
  [ "$status" -eq 0 ] || fail "managed resume should succeed (exit $status): $out"
  assert_grep "lease recover --task $account_task" "$AF_LOG" "resume used new-task selection instead of sticky recovery reservation"
  assert_not_grep 'lease choose\|lease acquire' "$AF_LOG" "resume ran the new-task quota path"
  launch=$(cat "$LAUNCH_LOG" "$NATIVE_LAUNCH_LOG")
  assert_contains "$launch" "--format json resume --task '$account_task' -- \"\$@\"" "resume did not use Agent Fleet's fail-closed task mapping"
  assert_contains "$launch" "account-native-launch' --dangerously-skip-permissions" "resume did not pass provider arguments through its launch gate"
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

test_recovered_reservations_are_owned_until_launch_commit() {
  local id rec out status account_task session lineage
  id=account-recover-owned-z9b
  rec=$(make_case recover-owned claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "recovered reservation precondition spawn failed"
  account_task=$(meta_account_task "$id")
  session=$(sed -n 's/^provider_session_id=//p' "$HOME_DIR/state/$id.meta" | tail -1)
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs

  out=$(FM_FAKE_AF_RECOVER_TASK=wrong-recovery-task run_spawn "$id" --resume-account)
  status=$?
  [ "$status" -ne 0 ] || fail "mismatched recovery response unexpectedly succeeded"
  assert_grep "lease release --task $account_task --force" "$AF_LOG" "mismatched recovery leaked its acquired reservation"
  assert_not_grep "session remove --task $account_task" "$AF_LOG" "mismatched recovery removed the durable session mapping"
  assert_grep "provider_session_id=$session" "$HOME_DIR/state/$id.meta" "mismatched recovery changed durable session metadata"

  clear_case_logs
  lineage="$HOME_DIR/data/$id/account-attempts.md"
  rm -f "$lineage"
  mkdir "$lineage"
  out=$(run_spawn "$id" --resume-account)
  status=$?
  [ "$status" -ne 0 ] || fail "post-recovery pre-bind failure unexpectedly succeeded"
  assert_grep "lease recover --task $account_task" "$AF_LOG" "post-recovery failure never acquired the sticky reservation"
  assert_grep "lease release --task $account_task --force" "$AF_LOG" "post-recovery failure leaked its owned reservation"
  assert_not_grep "session remove --task $account_task" "$AF_LOG" "post-recovery rollback removed the durable session mapping"
  assert_grep "provider_session_id=$session" "$HOME_DIR/state/$id.meta" "post-recovery rollback lost durable session metadata"
  [ -n "$out" ] || true
  pass "recovered reservations release on every validation and pre-bind failure"
}

test_native_resume_requires_fresh_sessionstart_evidence() {
  local id rec out status account_task session
  id=account-resume-fresh-z9c
  rec=$(make_case resume-fresh claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "fresh resume precondition spawn failed"
  account_task=$(meta_account_task "$id")
  session=$(sed -n 's/^provider_session_id=//p' "$HOME_DIR/state/$id.meta" | tail -1)
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs

  out=$(FM_FAKE_AF_RESUME_NO_REFRESH=1 run_spawn "$id" --resume-account)
  status=$?
  [ "$status" -ne 0 ] || fail "native resume accepted a stale SessionStart mapping"
  assert_contains "$out" "no fresh Agent Fleet SessionStart update" "stale native resume did not report its missing launch evidence"
  assert_grep "lease release --task $account_task --force" "$AF_LOG" "stale native resume leaked its recovered reservation"
  assert_not_grep "session remove --task $account_task" "$AF_LOG" "stale native resume removed its durable mapping"
  assert_regex '^kill-window ' "$TMUX_LOG" "stale native resume retained its failed endpoint"
  assert_grep "provider_session_id=$session" "$HOME_DIR/state/$id.meta" "stale native resume changed session truth"
  pass "native resume commits only after a fresh SessionStart update"
}

test_native_resume_rejects_prelaunch_sessionstart_evidence() {
  local id rec out status account_task session
  id=account-resume-launch-z9d
  rec=$(make_case resume-launch claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "launch-specific resume precondition spawn failed"
  account_task=$(meta_account_task "$id")
  session=$(sed -n 's/^provider_session_id=//p' "$HOME_DIR/state/$id.meta" | tail -1)
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs

  out=$(FM_FAKE_AF_STALE_REFRESH_ON_RECOVER=1 FM_FAKE_AF_RESUME_NO_REFRESH=1 run_spawn "$id" --resume-account)
  status=$?
  [ "$status" -ne 0 ] || fail "native resume accepted SessionStart evidence produced before its launch gate"
  assert_contains "$out" "no fresh Agent Fleet SessionStart update" "prelaunch SessionStart evidence was not rejected"
  assert_grep "lease release --task $account_task --force" "$AF_LOG" "prelaunch evidence failure leaked its recovered reservation"
  assert_grep "provider_session_id=$session" "$HOME_DIR/state/$id.meta" "prelaunch evidence failure changed durable session truth"
  pass "native resume requires SessionStart evidence after its own launch gate"
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
  assert_regex "lease choose --pool claude-captains --task .*-$id-.* --provider claude" "$AF_LOG" "secondmate did not use its primary-owned account pool"
  assert_grep 'account_pool=claude-captains' "$HOME_DIR/state/$id.meta" "secondmate meta lost its account pool"
  [ "$(cat "$sm/config/account-routing-mode" 2>/dev/null)" = enforce ] || fail "account routing mode did not inherit into the secondmate home"
  assert_absent "$sm/config/secondmate-account-pool" "primary-only secondmate pool leaked into the child home"
  pass "secondmate routing uses the primary pool while the mode, but not that pool, inherits"
}

test_managed_shared_namespace_secondmate_uses_primary_endpoint_scope() {
  local id rec sm zellij_log out status scope
  id=account-secondmate-zellij-z11a
  rec=$(make_case secondmate-zellij claude)
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  zellij_log="$CASE_DIR/zellij.log"
  make_seeded_secondmate_home "$sm" "$id"
  : > "$zellij_log"
  cat > "$FAKEBIN_DIR/zellij" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s|%s|%s\n' "${FM_HOME:-}" "${FM_ROOT:-}" "$*" >> "$FM_FAKE_ZELLIJ_LOG"
case "$*" in
  '--version') printf 'zellij 0.44.0\n'; exit 0 ;;
  'list-sessions --short --no-formatting') printf 'firstmate\n'; exit 0 ;;
  *' action new-tab '*)
    prev=
    for arg in "$@"; do
      [ "$prev" != --name ] || printf '%s\n' "$arg" > "$FM_FAKE_ZELLIJ_TITLE"
      prev=$arg
    done
    touch "$FM_FAKE_ZELLIJ_ENDPOINT"
    printf '7\n'
    exit 0
    ;;
  *' action list-panes --json'*)
    if [ -f "$FM_FAKE_ZELLIJ_ENDPOINT" ]; then
      printf '[{"id":9,"tab_id":7,"is_plugin":false,"pane_cwd":"%s"}]\n' "$FM_FAKE_ZELLIJ_CWD"
    else
      printf '[]\n'
    fi
    exit 0
    ;;
  *' action list-tabs --json'*)
    if [ -f "$FM_FAKE_ZELLIJ_ENDPOINT" ]; then
      printf '[{"tab_id":7,"name":"%s","active":true}]\n' "$(cat "$FM_FAKE_ZELLIJ_TITLE")"
    else
      printf '[]\n'
    fi
    exit 0
    ;;
  *' action close-tab-by-id 7'*) rm -f "$FM_FAKE_ZELLIJ_ENDPOINT"; exit 0 ;;
  *' action paste '*|*' action write-chars '*|*' action send-keys '*|*' action dump-screen '*) exit 0 ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN_DIR/zellij"

  out=$(FM_FAKE_AF_SESSION_MISSING=1 FM_FAKE_ZELLIJ_LOG="$zellij_log" \
    FM_FAKE_ZELLIJ_ENDPOINT="$CASE_DIR/zellij-endpoint" FM_FAKE_ZELLIJ_TITLE="$CASE_DIR/zellij-title" \
    FM_FAKE_ZELLIJ_CWD="$sm" FM_TEST_PANE_PATH="$sm" \
    run_spawn "$id" "$sm" --secondmate --backend zellij --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "unbound managed zellij secondmate unexpectedly succeeded"
  assert_absent "$CASE_DIR/zellij-endpoint" "zellij secondmate rollback left its live endpoint"
  assert_not_grep "^$sm\\|" "$zellij_log" "zellij secondmate switched endpoint label scope during rollback"
  assert_regex "^$HOME_DIR\\|" "$zellij_log" "zellij secondmate never used the primary endpoint label scope"
  assert_grep 'lease release ' "$AF_LOG" "zellij secondmate rollback did not release after confirmed endpoint removal"
  scope=$(FM_HOME="$HOME_DIR" FM_ROOT="$ROOT" bash -c '. "$1"; fm_backend_endpoint_home cmux secondmate "$2" "$3"' _ "$ROOT/bin/fm-backend.sh" "$HOME_DIR" "$sm")
  [ "$scope" = "$HOME_DIR" ] || fail "cmux secondmate endpoint scope drifted from its primary owner"
  scope=$(FM_HOME="$HOME_DIR" FM_ROOT="$ROOT" bash -c '. "$1"; fm_backend_endpoint_home herdr secondmate "$2" "$3"' _ "$ROOT/bin/fm-backend.sh" "$HOME_DIR" "$sm")
  [ "$scope" = "$sm" ] || fail "herdr secondmate endpoint scope lost its child workspace owner"
  pass "managed secondmates keep backend-specific endpoint ownership across cleanup"
}

test_unused_secondmate_pool_never_blocks_unmanaged_spawn() {
  local id rec sm out status
  id=account-secondmate-malformed-off-z11b
  rec=$(make_case secondmate-malformed-off claude)
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  printf 'claude-one\nclaude-two\n' > "$HOME_DIR/config/secondmate-account-pool"
  out=$(FM_TEST_PANE_PATH="$sm" run_spawn "$id" "$sm" --secondmate)
  status=$?
  [ "$status" -eq 0 ] || fail "malformed unused secondmate pool blocked default-off spawn: $out"
  [ ! -s "$AF_LOG" ] || fail "default-off malformed pool invoked Agent Fleet"

  id=account-secondmate-malformed-optout-z11c
  rec=$(make_case secondmate-malformed-optout claude)
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  printf 'enforce\n' > "$HOME_DIR/config/account-routing-mode"
  printf 'claude-one\nclaude-two\n' > "$HOME_DIR/config/secondmate-account-pool"
  out=$(FM_TEST_PANE_PATH="$sm" run_spawn "$id" "$sm" --secondmate --no-account-routing)
  status=$?
  [ "$status" -eq 0 ] || fail "malformed unused secondmate pool blocked explicit opt-out: $out"
  [ ! -s "$AF_LOG" ] || fail "opted-out malformed pool invoked Agent Fleet"
  pass "unused secondmate pool policy is not parsed by unmanaged spawns"
}

test_agent_fleet_task_keys_are_namespaced_by_home_and_attempt() {
  local id rec task_one task_two
  id=account-namespace-z12
  rec=$(make_case namespace-one claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "first namespaced spawn failed"
  task_one=$(meta_account_task "$id")
  rec=$(make_case namespace-two claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "second namespaced spawn failed"
  task_two=$(meta_account_task "$id")
  [ "$task_one" != "$task_two" ] || fail "two firstmate homes shared Agent Fleet task key $task_one"
  assert_contains "$task_one" "-$id-a" "first Agent Fleet task did not retain local task identity"
  assert_contains "$task_two" "-$id-a" "second Agent Fleet task did not retain local task identity"
  pass "Agent Fleet task keys namespace every home-local task and launch generation"
}

test_duplicate_spawn_preserves_original_endpoint_and_lease() {
  local id rec out status
  id=account-duplicate-z13
  rec=$(make_case duplicate claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "initial duplicate test spawn failed"
  clear_case_logs
  out=$(run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "duplicate managed spawn unexpectedly succeeded"
  [ ! -s "$AF_LOG" ] || fail "duplicate managed spawn touched the original lease: $(cat "$AF_LOG")"
  assert_not_grep '^kill-window ' "$TMUX_LOG" "duplicate managed spawn killed the original endpoint"
  assert_present "$CASE_DIR/endpoint-live" "duplicate managed spawn removed the original endpoint marker"
  assert_contains "$out" "managed metadata already exists" "duplicate managed spawn did not fail at ownership guard"
  pass "duplicate spawn cannot release or kill an existing managed task"
}

test_reservation_occurs_after_worktree_preparation() {
  local id rec treehouse_line lease_line
  id=account-order-z14
  rec=$(make_case order claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "reservation order spawn failed"
  treehouse_line=$(grep -n '^tmux send-keys .* treehouse get Enter$' "$LIFECYCLE_LOG" | head -1 | cut -d: -f1)
  lease_line=$(grep -n 'agent-fleet .* lease choose ' "$LIFECYCLE_LOG" | head -1 | cut -d: -f1)
  [ -n "$treehouse_line" ] && [ -n "$lease_line" ] && [ "$lease_line" -gt "$treehouse_line" ] \
    || fail "Agent Fleet reservation did not follow worktree preparation: $(tr '\n' '|' < "$LIFECYCLE_LOG")"
  pass "account capacity is reserved only when the prepared endpoint can bind"
}

test_raw_enforced_launch_is_rejected_before_mutation() {
  local id rec out status
  id=account-raw-z15
  rec=$(make_case raw claude "$id")
  read_case "$rec"
  out=$(run_spawn "$id" "$PROJ_DIR" --harness 'claude --dangerously-skip-permissions' --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "raw enforced launch unexpectedly succeeded"
  [ ! -s "$AF_LOG" ] || fail "raw enforced launch touched Agent Fleet"
  assert_not_grep '^new-window ' "$TMUX_LOG" "raw enforced launch created an endpoint"
  assert_contains "$out" "does not accept raw launch commands" "raw enforced launch blocker was unclear"
  pass "raw launch commands cannot bypass enforced account wrapping"
}

test_malformed_routing_mode_fails_closed() {
  local id rec out status
  id=account-mode-z16
  rec=$(make_case mode claude "$id")
  read_case "$rec"
  printf 'enforce\noff\n' > "$HOME_DIR/config/account-routing-mode"
  out=$(run_spawn "$id" "$PROJ_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "multi-value routing mode silently fell back to off"
  assert_not_grep '^new-window ' "$TMUX_LOG" "invalid routing mode created an endpoint"
  assert_contains "$out" "must contain exactly one value" "invalid routing mode error was suppressed"
  rm -f "$HOME_DIR/config/account-routing-mode"
  mkdir "$HOME_DIR/config/account-routing-mode"
  clear_case_logs
  out=$(run_spawn "$id" "$PROJ_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "unreadable routing mode silently fell back to off"
  assert_not_grep '^new-window ' "$TMUX_LOG" "unreadable routing mode created an endpoint"
  assert_contains "$out" "cannot read" "unreadable routing mode error was suppressed"
  pass "malformed or unreadable account-routing policy never collapses to default-off"
}

test_invalid_selection_response_releases_reservation() {
  local id rec out status task release_count
  id=account-invalid-select-z17
  rec=$(make_case invalid-select claude "$id")
  read_case "$rec"
  out=$(FM_FAKE_AF_BAD_SELECTION=1 run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "malformed lease response unexpectedly succeeded"
  task=$(logged_account_task)
  assert_grep "lease release --task $task --force" "$AF_LOG" "malformed lease response leaked its reservation"
  assert_absent "$HOME_DIR/state/$id.meta" "malformed lease response left managed metadata"
  [ -n "$out" ] || true
  : > "$AF_LOG"
  rm -f "$CASE_DIR/release-failed-once"
  out=$(FM_FAKE_AF_BAD_SELECTION=1 FM_FAKE_AF_RELEASE_FAIL_ONCE="$CASE_DIR/release-failed-once" run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "malformed lease response with a transient release failure unexpectedly succeeded"
  release_count=$(grep -c 'lease release .* --force' "$AF_LOG" || true)
  [ "$release_count" -eq 2 ] || fail "malformed lease rollback did not retry the owned reservation after release failure"
  pass "post-acquisition response validation always releases the reservation"
}

test_fresh_launch_requires_session_binding_and_fully_rolls_back() {
  local id rec out status task
  id=account-bind-z18
  rec=$(make_case bind claude "$id")
  read_case "$rec"
  out=$(FM_FAKE_AF_SESSION_MISSING=1 run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "managed launch without SessionStart mapping unexpectedly succeeded"
  task=$(logged_account_task)
  assert_grep "lease release --task $task --force" "$AF_LOG" "unbound launch did not release its lease"
  assert_grep "session remove --task $task" "$AF_LOG" "unbound launch did not remove its attempt mapping"
  assert_regex '^kill-window ' "$TMUX_LOG" "unbound launch did not kill its endpoint"
  assert_grep 'return --force' "$TREEHOUSE_LOG" "unbound launch did not return its worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "unbound launch left phantom recovery metadata"
  assert_contains "$out" "did not bind a fresh SessionStart mapping" "unbound launch did not report its binding failure"
  pass "fresh managed launches commit only after provider binding and otherwise unwind"
}

test_failed_cleanup_persists_retryable_metadata() {
  local id rec out status task
  id=account-rollback-retry-z18b
  rec=$(make_case rollback-retry claude "$id")
  read_case "$rec"
  out=$(FM_FAKE_AF_SESSION_MISSING=1 FM_FAKE_AF_RELEASE_FAIL=1 run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "failed launch with failed cleanup unexpectedly succeeded"
  task=$(logged_account_task)
  assert_grep 'account_rollback_cleanup=pending' "$HOME_DIR/state/$id.meta" "failed cleanup did not persist a retry marker"
  assert_grep "account_task=$task" "$HOME_DIR/state/$id.meta" "failed cleanup lost its Agent Fleet task identity"
  assert_not_grep 'return --force' "$TREEHOUSE_LOG" "failed cleanup recycled its retained worktree"

  clear_case_logs
  run_teardown "$id" --force >/dev/null || fail "teardown could not retry failed Agent Fleet cleanup"
  assert_grep "lease release --task $task --force" "$AF_LOG" "teardown did not retry the failed lease release"
  assert_grep "session remove --task $task" "$AF_LOG" "teardown did not retry the failed session cleanup"
  assert_grep 'return --force' "$TREEHOUSE_LOG" "teardown did not recycle the worktree after account cleanup"
  assert_absent "$HOME_DIR/state/$id.meta" "teardown left failed-attempt metadata after cleanup"
  pass "failed Agent Fleet cleanup leaves durable teardown-retry state"
}

test_unknown_spawn_endpoint_retains_lease_for_retry() {
  local id rec out status task
  id=account-unknown-rollback-z18c
  rec=$(make_case unknown-rollback claude "$id")
  read_case "$rec"
  out=$(FM_FAKE_AF_SESSION_MISSING=1 FM_FAKE_TARGET_STATE=unknown FM_FAKE_TMUX_KILL_FAIL=1 \
    run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "unknown failed endpoint unexpectedly committed"
  task=$(logged_account_task)
  assert_not_grep "lease release --task $task" "$AF_LOG" "unknown endpoint state released its lease"
  assert_grep 'account_rollback_cleanup=pending' "$HOME_DIR/state/$id.meta" "unknown endpoint state lost retry metadata"
  assert_contains "$out" "endpoint state is unknown" "unknown endpoint retention was not reported"
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs
  run_teardown "$id" --force >/dev/null || fail "unknown endpoint retry state could not be torn down after absence was confirmed"
  pass "spawn rollback retains leases while endpoint state is unknown"
}

test_rollback_retry_rechecks_live_endpoint_before_release() {
  local id rec out status task
  id=account-live-rollback-retry-z18d
  rec=$(make_case live-rollback-retry claude "$id")
  read_case "$rec"
  out=$(FM_FAKE_AF_SESSION_MISSING=1 FM_FAKE_AF_RELEASE_FAIL=1 \
    run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "rollback retry precondition unexpectedly succeeded"
  task=$(logged_account_task)
  touch "$CASE_DIR/endpoint-live"
  clear_case_logs
  out=$(FM_FAKE_TMUX_KILL_FAIL=1 run_spawn "$id" --continue-account --account-profile claude-3)
  status=$?
  [ "$status" -ne 0 ] || fail "rollback retry released a live endpoint"
  assert_not_grep "lease release --task $task" "$AF_LOG" "rollback retry released the lease before killing the endpoint"
  assert_grep 'account_rollback_cleanup=pending' "$HOME_DIR/state/$id.meta" "live rollback retry lost retry metadata"
  assert_contains "$out" "endpoint is still alive" "live rollback retry blocker was unclear"
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs
  run_teardown "$id" --force >/dev/null || fail "live rollback retry state could not be torn down after endpoint removal"
  pass "rollback cleanup retries prove the retained endpoint is dead"
}

test_failed_secondmate_rollback_preserves_home_for_relaunch() {
  local id rec sm out status
  id=account-secondmate-rollback-z18e
  rec=$(make_case secondmate-rollback claude)
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  out=$(FM_FAKE_AF_SESSION_MISSING=1 FM_FAKE_AF_RELEASE_FAIL=1 FM_TEST_PANE_PATH="$sm" \
    run_spawn "$id" "$sm" --secondmate --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "failed secondmate rollback precondition unexpectedly succeeded"
  assert_grep 'account_rollback_cleanup=pending' "$HOME_DIR/state/$id.meta" "failed secondmate attempt lost cleanup metadata"

  clear_case_logs
  out=$(run_spawn "$id" --continue-account --account-profile claude-3)
  status=$?
  [ "$status" -ne 0 ] || fail "cleanup-only secondmate retry claimed to relaunch"
  assert_absent "$HOME_DIR/state/$id.meta" "cleaned secondmate attempt still poisoned ordinary respawn"
  assert_present "$sm/.fm-secondmate-home" "secondmate cleanup retired the persistent home"
  assert_contains "$out" "retry the secondmate spawn without tearing down its home" "secondmate retry guidance was unclear"

  clear_case_logs
  out=$(FM_TEST_PANE_PATH="$sm" run_spawn "$id" "$sm" --secondmate --account-pool claude-crew)
  status=$?
  [ "$status" -eq 0 ] || fail "cleaned secondmate home could not relaunch: $out"
  assert_present "$sm/.fm-secondmate-home" "secondmate relaunch lost its home marker"
  pass "failed secondmate rollback clears task state without retiring its home"
}

test_observe_invalid_response_remains_advisory() {
  local id rec out status launch
  id=account-observe-invalid-z19
  rec=$(make_case observe-invalid claude "$id")
  read_case "$rec"
  out=$(FM_ACCOUNT_ROUTING=observe FM_FAKE_AF_BAD_SELECTION=1 run_spawn "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "invalid observe response should preserve legacy spawn"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" ' claude --dangerously-skip-permissions ' "invalid observe response changed launch"
  assert_not_grep 'lease release' "$AF_LOG" "observe response attempted lease cleanup"
  assert_contains "$out" "observe decision invalid" "observe validation failure was not surfaced"
  pass "observe mode remains non-blocking on malformed decisions"
}

test_explicit_secondmate_profile_ignores_configured_pool() {
  local id rec sm out status
  id=account-secondmate-profile-z20
  rec=$(make_case secondmate-profile claude)
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  printf 'claude-captains\n' > "$HOME_DIR/config/secondmate-account-pool"
  out=$(FM_FAKE_AF_POOL=explicit FM_FAKE_AF_PROFILE=claude-9 FM_TEST_PANE_PATH="$sm" run_spawn "$id" "$sm" --secondmate --account-profile claude-9)
  status=$?
  [ "$status" -eq 0 ] || fail "explicit secondmate profile failed: $out"
  assert_regex 'lease acquire --profile claude-9 --task .* --pool explicit' "$AF_LOG" "explicit secondmate profile inherited the configured pool"
  assert_regex '^account_pool=explicit$' "$HOME_DIR/state/$id.meta" "explicit secondmate profile meta retained the configured pool"
  pass "an explicit secondmate profile fully overrides pool policy"
}

test_enforced_orca_is_rejected_before_owned_resource_creation() {
  local id rec out status
  id=account-orca-z20b
  rec=$(make_case orca claude "$id")
  read_case "$rec"
  out=$(run_spawn "$id" "$PROJ_DIR" --backend orca --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "enforced Orca spawn unexpectedly succeeded"
  [ ! -s "$AF_LOG" ] || fail "enforced Orca spawn acquired an Agent Fleet lease"
  assert_not_grep '^worktree ' "$ORCA_LOG" "enforced Orca spawn created a worktree"
  assert_contains "$out" "does not support backend=orca" "enforced Orca blocker was unclear"
  pass "enforced account routing refuses Orca before creating owned resources"
}

test_cross_profile_continuation_for_harness() {
  local harness=$1 old_profile=$2 new_profile=$3 provider=$4 id rec old_task new_task packet out status launch
  id="account-continue-$harness-z21"
  rec=$(make_case "continue-$harness" "$harness" "$id")
  read_case "$rec"
  out=$(FM_FAKE_AF_PROVIDER="$provider" FM_FAKE_AF_PROFILE="$old_profile" FM_FAKE_AF_POOL="$harness-crew" run_spawn "$id" "$PROJ_DIR" --account-pool "$harness-crew")
  status=$?
  [ "$status" -eq 0 ] || fail "$harness initial managed spawn failed: $out"
  old_task=$(meta_account_task "$id")
  printf 'done: external side effect alpha; do not rerun\nnext: verify beta\n' > "$HOME_DIR/state/$id.status"
  printf '# Decisions\n\n- Keep the existing branch.\n' > "$HOME_DIR/data/$id/decisions.md"
  run_send "$id" "Preserve the verified next action for $harness." >/dev/null \
    || fail "$harness steering trail precondition failed"
  assert_grep "Preserve the verified next action for $harness." "$HOME_DIR/data/$id/steering.md" "$harness managed steering was not recorded"
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs
  out=$(FM_FAKE_AF_PROVIDER="$provider" FM_FAKE_AF_PROFILE="$new_profile" FM_FAKE_AF_POOL=explicit run_spawn "$id" --continue-account --account-profile "$new_profile")
  status=$?
  [ "$status" -eq 0 ] || fail "$harness cross-profile continuation failed: $out"
  new_task=$(meta_account_task "$id")
  [ "$new_task" != "$old_task" ] || fail "$harness continuation reused a stale launch generation"
  packet=$(sed -n 's/^continuation_packet=//p' "$HOME_DIR/state/$id.meta" | tail -1)
  assert_present "$packet" "$harness continuation packet was not persisted"
  assert_grep 'done: external side effect alpha; do not rerun' "$packet" "$harness continuation packet lost completed side-effect state"
  assert_grep 'Keep the existing branch' "$packet" "$harness continuation packet lost decisions"
  assert_grep "Preserve the verified next action for $harness." "$packet" "$harness continuation packet lost steering"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--profile '$new_profile' --task '$new_task'" "$harness continuation did not use the new profile/generation"
  assert_contains "$launch" "cat '$packet'" "$harness continuation did not seed the fresh provider from task-owned state"
  assert_grep "lease release --task $old_task --force" "$AF_LOG" "$harness continuation did not release its predecessor after binding"
  assert_grep "session remove --task $old_task" "$AF_LOG" "$harness continuation did not remove its predecessor mapping"
  assert_grep "agent_fleet_task=$new_task" "$HOME_DIR/data/$id/account-attempts.md" "$harness continuation lineage lost the new attempt"
  pass "$harness can continue safely under a different account profile"
}

test_cross_provider_continuation_uses_target_default_pool() {
  local source=$1 target=$2 id rec old_task out status
  id="account-continue-$source-to-$target-z21a"
  rec=$(make_case "continue-$source-to-$target" "$source" "$id")
  read_case "$rec"
  out=$(FM_FAKE_AF_PROVIDER="$source" FM_FAKE_AF_PROFILE="$source-2" FM_FAKE_AF_POOL="$source-crew" \
    run_spawn "$id" "$PROJ_DIR" --account-pool "$source-crew")
  status=$?
  [ "$status" -eq 0 ] || fail "$source initial managed spawn failed: $out"
  old_task=$(meta_account_task "$id")
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs

  out=$(FM_FAKE_AF_PROVIDER="$target" FM_FAKE_AF_PROFILE="$target-2" FM_FAKE_AF_POOL="$target-crew" \
    run_spawn "$id" --continue-account --harness "$target")
  status=$?
  [ "$status" -eq 0 ] || fail "$source-to-$target continuation failed: $out"
  assert_regex "lease choose --pool $target-crew --task .*-$id-.* --provider $target" "$AF_LOG" \
    "$source-to-$target continuation did not select the target provider's default pool"
  assert_not_grep "lease choose --pool $source-crew" "$AF_LOG" \
    "$source-to-$target continuation inherited the predecessor provider's pool"
  assert_grep "predecessor=$old_task" "$HOME_DIR/data/$id/account-attempts.md" \
    "$source-to-$target continuation lost predecessor lineage"
  pass "$source-to-$target continuation resolves the target provider pool"
}

test_continuation_refuses_unknown_endpoint_state() {
  local id rec old_task out status
  id=account-continuation-unknown-z21aa
  rec=$(make_case continuation-unknown claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "unknown continuation precondition spawn failed"
  old_task=$(meta_account_task "$id")
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs

  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_TARGET_STATE=unknown FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" direct-unknown 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "continuation packet builder accepted an unknown predecessor endpoint"
  assert_contains "$out" "endpoint state is unknown" "packet builder's unknown endpoint blocker was unclear"

  out=$(FM_FAKE_TARGET_STATE=unknown run_spawn "$id" --continue-account --account-profile claude-3)
  status=$?
  [ "$status" -ne 0 ] || fail "continuation accepted an unknown predecessor endpoint"
  assert_contains "$out" "endpoint state is unknown" "unknown continuation blocker was unclear"
  assert_not_grep 'lease choose\|lease acquire\|lease release' "$AF_LOG" "unknown continuation mutated Agent Fleet state"
  assert_grep "account_task=$old_task" "$HOME_DIR/state/$id.meta" "unknown continuation changed predecessor metadata"
  assert_not_grep '^new-window ' "$TMUX_LOG" "unknown continuation created a replacement endpoint"
  pass "continuation requires confirmed predecessor endpoint absence"
}

test_predecessor_cleanup_failure_preserves_replacement_for_retry() {
  local id rec old_task new_task fail_once out status
  id=account-predecessor-retry-z21b
  rec=$(make_case predecessor-retry claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "predecessor cleanup precondition spawn failed"
  old_task=$(meta_account_task "$id")
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs
  fail_once="$CASE_DIR/session-remove-failed"

  out=$(FM_FAKE_AF_PROFILE=claude-3 FM_FAKE_AF_POOL=explicit FM_FAKE_AF_SESSION_REMOVE_FAIL_ONCE="$fail_once" \
    run_spawn "$id" --continue-account --account-profile claude-3)
  status=$?
  [ "$status" -ne 0 ] || fail "predecessor session cleanup failure was hidden"
  new_task=$(meta_account_task "$id")
  [ "$new_task" != "$old_task" ] || fail "replacement attempt was not installed before predecessor cleanup"
  assert_present "$CASE_DIR/endpoint-live" "predecessor cleanup failure killed the healthy replacement endpoint"
  assert_grep 'account_predecessor_cleanup=pending' "$HOME_DIR/state/$id.meta" "predecessor cleanup failure lost its retry marker"
  assert_grep "lease release --task $old_task --force" "$AF_LOG" "predecessor lease release was not attempted"
  assert_not_grep "lease release --task $new_task --force" "$AF_LOG" "predecessor cleanup failure rolled back the healthy replacement lease"
  assert_contains "$out" "cleanup remains pending" "predecessor cleanup failure was not explicit"

  clear_case_logs
  out=$(FM_FAKE_AF_PROFILE=claude-3 FM_FAKE_AF_POOL=explicit FM_FAKE_AF_SESSION_REMOVE_FAIL_ONCE="$fail_once" \
    run_spawn "$id" --continue-account --account-profile claude-3)
  status=$?
  [ "$status" -eq 0 ] || fail "predecessor cleanup retry failed: $out"
  assert_contains "$out" "completed predecessor Agent Fleet cleanup" "predecessor cleanup retry did not report completion"
  assert_not_grep 'lease choose\|lease acquire' "$AF_LOG" "predecessor cleanup retry created another replacement generation"
  assert_not_grep '^new-window ' "$TMUX_LOG" "predecessor cleanup retry created another endpoint"
  assert_not_grep '^account_predecessor_' "$HOME_DIR/state/$id.meta" "predecessor cleanup retry left pending metadata"
  assert_grep "account_task=$new_task" "$HOME_DIR/state/$id.meta" "predecessor cleanup retry changed the healthy replacement"
  pass "predecessor cleanup retries without destroying the verified replacement"
}

test_failed_continuation_cleanup_restores_predecessor_for_retry() {
  local id rec old_task failed_task final_task out status
  id=account-continuation-rollback-z21c
  rec=$(make_case continuation-rollback claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "continuation rollback precondition spawn failed"
  old_task=$(meta_account_task "$id")
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs

  out=$(FM_FAKE_AF_PROFILE=claude-3 FM_FAKE_AF_POOL=explicit FM_FAKE_AF_SESSION_MISSING=1 FM_FAKE_AF_RELEASE_FAIL=1 \
    run_spawn "$id" --continue-account --account-profile claude-3)
  status=$?
  [ "$status" -ne 0 ] || fail "unbound continuation with failed cleanup unexpectedly succeeded"
  failed_task=$(meta_account_task "$id")
  [ "$failed_task" != "$old_task" ] || fail "failed continuation never installed its cleanup generation"
  assert_grep 'account_rollback_cleanup=pending' "$HOME_DIR/state/$id.meta" "failed continuation cleanup lost its retry marker"
  assert_grep "account_predecessor_task=$old_task" "$HOME_DIR/state/$id.meta" "failed continuation cleanup lost predecessor identity"

  clear_case_logs
  out=$(FM_FAKE_AF_PROFILE=claude-3 FM_FAKE_AF_POOL=explicit run_spawn "$id" --continue-account --account-profile claude-3)
  status=$?
  [ "$status" -eq 0 ] || fail "continuation retry could not clean and replace its failed generation: $out"
  final_task=$(meta_account_task "$id")
  [ "$final_task" != "$old_task" ] && [ "$final_task" != "$failed_task" ] || fail "continuation retry did not create a fresh generation"
  assert_grep "lease release --task $failed_task --force" "$AF_LOG" "continuation retry did not clean its failed lease"
  assert_grep "session remove --task $failed_task" "$AF_LOG" "continuation retry did not clean its failed mapping"
  assert_grep "lease release --task $old_task --force" "$AF_LOG" "continuation retry did not clean its restored predecessor"
  assert_not_grep '^account_rollback_' "$HOME_DIR/state/$id.meta" "continuation retry retained rollback metadata"
  pass "failed continuation cleanup restores predecessor state before retry"
}

test_concurrent_continuations_serialize_before_mutation() {
  local id rec marker gate first_pid second_pid first_rc second_rc lease_count endpoint_count
  id=account-continuation-race-z21d
  rec=$(make_case continuation-race claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "continuation race precondition spawn failed"
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs
  marker="$CASE_DIR/first-endpoint-started"
  gate="$CASE_DIR/allow-first-endpoint"

  FM_FAKE_AF_PROFILE=claude-3 FM_FAKE_AF_POOL=explicit FM_FAKE_TMUX_NEW_WINDOW_MARKER="$marker" FM_FAKE_TMUX_NEW_WINDOW_GATE="$gate" \
    run_spawn "$id" --continue-account --account-profile claude-3 > "$CASE_DIR/first.out" 2>&1 &
  first_pid=$!
  for _ in $(seq 1 100); do
    [ -f "$marker" ] && break
    sleep 0.05
  done
  [ -f "$marker" ] || { kill "$first_pid" 2>/dev/null || true; fail "first continuation never reached endpoint creation"; }
  FM_FAKE_AF_PROFILE=claude-3 FM_FAKE_AF_POOL=explicit \
    run_spawn "$id" --continue-account --account-profile claude-3 > "$CASE_DIR/second.out" 2>&1 &
  second_pid=$!
  sleep 0.2
  touch "$gate"
  wait "$first_pid"
  first_rc=$?
  wait "$second_pid"
  second_rc=$?
  [ "$first_rc" -eq 0 ] || fail "first serialized continuation failed: $(cat "$CASE_DIR/first.out")"
  [ "$second_rc" -ne 0 ] || fail "second concurrent continuation also launched"
  assert_grep 'generation changed before recovery mutation' "$CASE_DIR/second.out" "concurrent continuation did not fail at generation revalidation"
  lease_count=$(grep -Ec 'lease choose|lease acquire' "$AF_LOG" || true)
  endpoint_count=$(grep -c '^new-window ' "$TMUX_LOG" || true)
  [ "$lease_count" -eq 1 ] || fail "concurrent continuations acquired $lease_count leases"
  [ "$endpoint_count" -eq 1 ] || fail "concurrent continuations created $endpoint_count endpoints"
  pass "continuation generation locking serializes before endpoint and lease mutation"
}

test_continuation_fails_closed_without_original_brief() {
  local id rec out status
  id=account-continue-nobrief-z22
  rec=$(make_case continue-nobrief claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "continuation precondition spawn failed"
  rm -f "$CASE_DIR/endpoint-live" "$HOME_DIR/data/$id/brief.md"
  clear_case_logs
  out=$(run_spawn "$id" --continue-account --account-profile claude-3)
  status=$?
  [ "$status" -ne 0 ] || fail "continuation without original brief unexpectedly succeeded"
  assert_not_grep '^new-window ' "$TMUX_LOG" "unsafe continuation created an endpoint"
  [ ! -s "$AF_LOG" ] || fail "unsafe continuation acquired a lease"
  assert_contains "$out" "no safe non-empty original brief" "unsafe continuation blocker was unclear"
  pass "provider-neutral continuation fails closed without a safe task packet"
}

test_session_sync_cannot_recreate_metadata_after_teardown() {
  local id rec release_marker sync_pid teardown_pid sync_rc teardown_rc meta_tmp
  id=account-sync-race-z23
  rec=$(make_case sync-race claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "session sync race precondition spawn failed"
  rm -f "$CASE_DIR/endpoint-live"
  meta_tmp="$HOME_DIR/state/.$id.meta.test"
  grep -v '^provider_session_id=' "$HOME_DIR/state/$id.meta" > "$meta_tmp"
  mv "$meta_tmp" "$HOME_DIR/state/$id.meta"
  release_marker="$CASE_DIR/lease-released"
  FM_FAKE_AF_RELEASE_MARKER="$release_marker" FM_FAKE_TREEHOUSE_SLEEP=1 \
    run_teardown "$id" --force > "$CASE_DIR/teardown-stdout" 2> "$CASE_DIR/teardown-stderr" &
  teardown_pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$release_marker" ] && break
    sleep 0.1
  done
  [ -f "$release_marker" ] || { kill "$teardown_pid" 2>/dev/null || true; fail "session sync race never reached managed account cleanup"; }
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_AGENT_FLEET_BIN="$FAKEBIN_DIR/agent-fleet" FM_FAKE_AF_LOG="$AF_LOG" \
    FM_FAKE_AF_POOL=claude-crew FM_FAKE_AF_PROFILE=claude-2 FM_FAKE_AF_PROVIDER=claude \
    PATH="$FAKEBIN_DIR:$PATH" "$SESSION_SYNC" "$id" --require > "$CASE_DIR/sync-stdout" 2> "$CASE_DIR/sync-stderr" &
  sync_pid=$!
  set +e
  wait "$teardown_pid"
  teardown_rc=$?
  wait "$sync_pid"
  sync_rc=$?
  set -e
  expect_code 0 "$teardown_rc" "session sync race teardown should succeed while holding the metadata lock"
  [ "$sync_rc" -ne 0 ] || fail "late SessionStart sync unexpectedly succeeded after teardown"
  assert_absent "$HOME_DIR/state/$id.meta" "late SessionStart sync recreated metadata after teardown"
  assert_absent "$HOME_DIR/state/.account-meta-$id.lock" "session sync race left the metadata lock behind"
  pass "session synchronization cannot recreate metadata after teardown"
}

test_managed_steering_audit_failure_does_not_reclassify_delivery() {
  local id rec out status
  id=account-steering-audit-z24
  rec=$(make_case steering-audit claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "steering audit precondition spawn failed"
  mkdir "$HOME_DIR/data/$id/steering.md"
  clear_case_logs
  touch "$CASE_DIR/endpoint-live"

  out=$(run_send "$id" "This delivered steer must not be retried." 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "successful steering delivery was reclassified by audit failure: $out"
  assert_contains "$out" "text was sent" "audit failure warning did not preserve delivery truth"
  assert_grep 'This delivered steer must not be retried' "$LAUNCH_LOG" "steering text was not delivered before audit failure"
  pass "steering audit failures cannot turn a delivered message into a retry signal"
}

test_account_metadata_lock_reclaims_orphans_without_overlapping_owners() {
  local case_dir state lock workers pids pid rc
  case_dir="$TMP_ROOT/account-lock"
  state="$case_dir/state"
  lock="$state/.account-meta-lock-task.lock"
  mkdir -p "$lock"

  set +e
  FM_ACCOUNT_META_LOCK_WAIT_SECONDS=0 FM_ACCOUNT_META_LOCK_ORPHAN_GRACE_SECONDS=30 \
    bash -c '. "$1"; fm_account_meta_lock_acquire "$2" lock-task' _ "$ROOT/bin/fm-account-routing-lib.sh" "$state" \
    > "$case_dir/young-stdout" 2> "$case_dir/young-stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "young ownerless metadata lock was reclaimed before its grace"
  assert_present "$lock" "young ownerless metadata lock was deleted"

  touch -t 200001010000 "$lock"
  FM_ACCOUNT_META_LOCK_WAIT_SECONDS=1 FM_ACCOUNT_META_LOCK_ORPHAN_GRACE_SECONDS=0 \
    bash -c '. "$1"; held=$(fm_account_meta_lock_acquire "$2" lock-task); fm_account_meta_lock_release "$held"' \
    _ "$ROOT/bin/fm-account-routing-lib.sh" "$state" || fail "old ownerless metadata lock was not reclaimed"

  mkdir -p "$lock"
  printf '999999\nstale-owner\n' > "$lock/owner"
  workers="$case_dir/workers.sh"
  cat > "$workers" <<'SH'
#!/usr/bin/env bash
set -eu
. "$1"
state=$2
critical=$3
overlap=$4
held=$(FM_ACCOUNT_META_LOCK_WAIT_SECONDS=5 fm_account_meta_lock_acquire "$state" lock-task)
if ! mkdir "$critical" 2>/dev/null; then
  printf 'overlap\n' >> "$overlap"
fi
sleep 0.05
rmdir "$critical" 2>/dev/null || true
fm_account_meta_lock_release "$held"
SH
  chmod +x "$workers"
  pids=
  for _ in 1 2 3 4 5 6; do
    "$workers" "$ROOT/bin/fm-account-routing-lib.sh" "$state" "$case_dir/critical" "$case_dir/overlap" &
    pids="$pids $!"
  done
  for pid in $pids; do
    wait "$pid" || fail "concurrent metadata lock owner lost ownership"
  done
  assert_absent "$case_dir/overlap" "metadata lock admitted overlapping owners"
  assert_absent "$lock" "metadata lock remained after concurrent owners exited"
  pass "metadata locks reclaim abandoned directories without deleting new owners"
}

test_off_is_byte_compatible_and_never_calls_agent_fleet
test_observe_is_dry_run_only
test_enforce_pool_wraps_backend_and_records_real_session
test_explicit_profile_uses_explicit_pool
test_enforce_failure_rolls_back_prepared_endpoint
test_pane_failure_happens_before_account_reservation
test_batch_partial_failure_releases_only_failed_item
test_resume_uses_sticky_recovery_and_preserves_mapping_on_failure
test_recovered_reservations_are_owned_until_launch_commit
test_native_resume_requires_fresh_sessionstart_evidence
test_native_resume_rejects_prelaunch_sessionstart_evidence
test_secondmate_pool_is_nonactivating_and_noninherited
test_secondmate_pool_routes_when_mode_is_enforced_and_mode_inherits
test_managed_shared_namespace_secondmate_uses_primary_endpoint_scope
test_unused_secondmate_pool_never_blocks_unmanaged_spawn
test_agent_fleet_task_keys_are_namespaced_by_home_and_attempt
test_duplicate_spawn_preserves_original_endpoint_and_lease
test_reservation_occurs_after_worktree_preparation
test_raw_enforced_launch_is_rejected_before_mutation
test_malformed_routing_mode_fails_closed
test_invalid_selection_response_releases_reservation
test_fresh_launch_requires_session_binding_and_fully_rolls_back
test_failed_cleanup_persists_retryable_metadata
test_unknown_spawn_endpoint_retains_lease_for_retry
test_rollback_retry_rechecks_live_endpoint_before_release
test_failed_secondmate_rollback_preserves_home_for_relaunch
test_observe_invalid_response_remains_advisory
test_explicit_secondmate_profile_ignores_configured_pool
test_enforced_orca_is_rejected_before_owned_resource_creation
test_cross_profile_continuation_for_harness claude claude-2 claude-3 claude
test_cross_profile_continuation_for_harness codex codex-2 codex-3 codex
test_cross_provider_continuation_uses_target_default_pool claude codex
test_cross_provider_continuation_uses_target_default_pool codex claude
test_continuation_refuses_unknown_endpoint_state
test_predecessor_cleanup_failure_preserves_replacement_for_retry
test_failed_continuation_cleanup_restores_predecessor_for_retry
test_concurrent_continuations_serialize_before_mutation
test_continuation_fails_closed_without_original_brief
test_session_sync_cannot_recreate_metadata_after_teardown
test_managed_steering_audit_failure_does_not_reclassify_delivery
test_account_metadata_lock_reclaims_orphans_without_overlapping_owners

echo "# all fm-account-routing tests passed"
