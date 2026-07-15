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
  display-message*"#{window_name}"*)
    if [ "${FM_FAKE_TMUX_RENAMED:-0}" = 1 ]; then
      printf 'fm-renamed-task\n'
    else
      cat "${FM_FAKE_TMUX_LABEL_FILE:-/nonexistent}"
    fi
    exit $?
    ;;
  display-message*"#{pane_id}"*)
    case "${FM_FAKE_TARGET_STATE:-auto}" in
      present) exit 0 ;;
      absent|unknown) exit 1 ;;
    esac
    if [ "${FM_FAKE_TMUX_RENAMED:-0}" = 1 ]; then
      case "$*" in *'%77'*) [ -f "${FM_FAKE_ENDPOINT_FILE:-/nonexistent}" ]; exit $? ;; *) exit 1 ;; esac
    fi
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
    prev=
    for arg in "$@"; do
      if [ "$prev" = -n ]; then
        printf '%s\n' "$arg" > "${FM_FAKE_TMUX_LABEL_FILE:-/nonexistent}"
        break
      fi
      prev=$arg
    done
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
  '--format json contract')
    [ -z "${FM_FAKE_AF_CONTRACT_SLEEP:-}" ] || sleep "$FM_FAKE_AF_CONTRACT_SLEEP"
    printf '{"contract_version":%s}\n' "${FM_FAKE_AF_CONTRACT_VERSION:-1}"
    ;;
  *" choose "*|*" lease choose "*|*" lease acquire "*|*" lease recover "*)
    if [ -n "${FM_FAKE_AF_REQUIRE_PRELEASE_META:-}" ]; then
      grep -qxF "account_task=$task" "$FM_FAKE_AF_REQUIRE_PRELEASE_META" \
        && grep -qxF 'account_rollback_cleanup=pending' "$FM_FAKE_AF_REQUIRE_PRELEASE_META" \
        && grep -qxF 'tmux_window_id=%77' "$FM_FAKE_AF_REQUIRE_PRELEASE_META" \
        || { echo "managed account identity was not durable before lease mutation" >&2; exit 91; }
    fi
    [ -z "${FM_FAKE_AF_SELECT_MUTATE_FILE:-}" ] || printf 'replacement-state\n' > "$FM_FAKE_AF_SELECT_MUTATE_FILE"
    [ "${FM_FAKE_AF_SELECT_FAIL:-0}" != 1 ] || exit 42
    if [ "${FM_FAKE_AF_BAD_SELECTION:-0}" = 1 ]; then printf '{bad json\n'; exit 0; fi
    [ -n "$pool" ] || pool=${FM_FAKE_AF_POOL:-claude-crew}
    case "$*" in
      *" lease recover "*)
        [ -z "${FM_FAKE_AF_RECOVER_SLEEP:-}" ] || sleep "$FM_FAKE_AF_RECOVER_SLEEP"
        [ -z "${FM_FAKE_AF_RECOVER_TASK:-}" ] || task=$FM_FAKE_AF_RECOVER_TASK
        [ "${FM_FAKE_AF_STALE_REFRESH_ON_RECOVER:-0}" != 1 ] || touch "${FM_FAKE_AF_SESSION_REFRESHED:?}"
        ;;
      *" lease choose "*|*" lease acquire "*)
        [ -z "${FM_FAKE_AF_SELECT_SLEEP:-}" ] || sleep "$FM_FAKE_AF_SELECT_SLEEP"
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
    [ -z "${FM_FAKE_AF_RELEASE_SLEEP:-}" ] || sleep "$FM_FAKE_AF_RELEASE_SLEEP"
    [ -z "${FM_FAKE_AF_RELEASE_MARKER:-}" ] || touch "$FM_FAKE_AF_RELEASE_MARKER"
    [ "${FM_FAKE_AF_RELEASE_FAIL:-0}" != 1 ] || exit 43
    if [ -n "${FM_FAKE_AF_RELEASE_FAIL_ONCE:-}" ] && [ ! -f "$FM_FAKE_AF_RELEASE_FAIL_ONCE" ]; then
      touch "$FM_FAKE_AF_RELEASE_FAIL_ONCE"
      exit 43
    fi
    printf '{"ok":true}\n'
    ;;
  *" session remove "*)
    [ -z "${FM_FAKE_AF_SESSION_REMOVE_SLEEP:-}" ] || sleep "$FM_FAKE_AF_SESSION_REMOVE_SLEEP"
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
    FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" FM_FAKE_TMUX_LABEL_FILE="$CASE_DIR/tmux-label" \
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
    FM_FAKE_TMUX_LABEL_FILE="$CASE_DIR/tmux-label" \
    FM_AGENT_FLEET_BIN="$FAKEBIN_DIR/agent-fleet" \
    TMUX="fake,1,0" PATH="$FAKEBIN_DIR:$PATH" "$TEARDOWN" "$@"
}

run_send() {
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" FM_FAKE_TMUX_LABEL_FILE="$CASE_DIR/tmux-label" \
    FM_SEND_RETRIES=1 FM_SEND_SLEEP=0 FM_SEND_SETTLE=0 \
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
  assert_grep 'report_required=1' "$HOME_DIR/state/$id.meta" "post-cutover spawn did not activate the report gate"
  assert_grep '# Completion report' "$HOME_DIR/data/$id/brief.md" "post-cutover spawn did not upgrade a legacy unspawned brief"
  assert_grep "Summary, What changed, Verification, Visual evidence, Artifacts, and Follow-ups" "$HOME_DIR/data/$id/brief.md" "upgraded brief omitted the completion-report sections"
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
  assert_grep 'report_required=1' "$HOME_DIR/state/$id.meta" "fresh spawn did not require a completion report"
  before_session=$(sed -n 's/^provider_session_id=//p' "$HOME_DIR/state/$id.meta" | tail -1)
  account_task=$(meta_account_task "$id")
  grep -v '^report_required=' "$HOME_DIR/state/$id.meta" > "$HOME_DIR/state/$id.meta.precutover"
  mv "$HOME_DIR/state/$id.meta.precutover" "$HOME_DIR/state/$id.meta"
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
  assert_not_grep '^report_required=' "$HOME_DIR/state/$id.meta" "pre-cutover recovery silently activated the report gate"

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

test_unmanaged_respawn_preserves_report_cutover_state() {
  local id rec out status
  id=account-legacy-respawn-z9b
  rec=$(make_case legacy-respawn claude "$id")
  read_case "$rec"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "pr=418" \
    "x_request=req-legacy" \
    "custom_extension=preserve-success"
  out=$(run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -eq 0 ] || fail "pre-cutover unmanaged respawn should succeed (exit $status): $out"
  assert_not_grep '^report_required=' "$HOME_DIR/state/$id.meta" "pre-cutover unmanaged respawn silently activated the report gate"
  assert_grep 'pr=418' "$HOME_DIR/state/$id.meta" "managed respawn dropped the existing PR pointer"
  assert_grep 'x_request=req-legacy' "$HOME_DIR/state/$id.meta" "managed respawn dropped the existing X-mode link"
  assert_grep 'custom_extension=preserve-success' "$HOME_DIR/state/$id.meta" "managed respawn dropped extension metadata"
  pass "unmanaged respawn preserves a legacy task's report cutover state"
}

test_failed_managed_respawn_restores_unmanaged_metadata() {
  local id rec expected out status artifact
  id=account-unmanaged-rollback-z9c
  rec=$(make_case unmanaged-rollback claude "$id")
  read_case "$rec"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "pr=417" \
    "custom_extension=preserve-me"
  expected="$CASE_DIR/original.meta"
  cp "$HOME_DIR/state/$id.meta" "$expected"
  for artifact in status turn-ended check.sh pi-ext.ts grok-turnend-token; do
    printf 'prior-%s\n' "$artifact" > "$HOME_DIR/state/$id.$artifact"
  done
  out=$(FM_FAKE_AF_SESSION_MISSING=1 run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "managed respawn without a session mapping unexpectedly succeeded"
  cmp -s "$HOME_DIR/state/$id.meta" "$expected" || fail "failed managed respawn did not restore the original unmanaged metadata"
  for artifact in status turn-ended check.sh pi-ext.ts grok-turnend-token; do
    [ "$(cat "$HOME_DIR/state/$id.$artifact" 2>/dev/null)" = "prior-$artifact" ] \
      || fail "failed managed respawn did not restore prior $artifact state"
  done
  assert_grep 'lease release ' "$AF_LOG" "failed managed respawn leaked its acquired reservation"
  [ -n "$out" ] || true
  pass "failed managed respawn restores every field from existing unmanaged metadata"
}

test_preinstall_managed_failure_restores_artifact_snapshot() {
  local id rec expected out status artifact
  id=account-preinstall-rollback-z9f
  rec=$(make_case preinstall-rollback claude "$id")
  read_case "$rec"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes"
  artifact="$HOME_DIR/state/$id.pi-ext.ts"
  printf 'prior-state\n' > "$artifact"
  expected="$CASE_DIR/original.meta"
  cp "$HOME_DIR/state/$id.meta" "$expected"
  out=$(FM_FAKE_AF_SELECT_MUTATE_FILE="$artifact" FM_FAKE_AF_SELECT_FAIL=1 \
    run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "pre-install account selection failure unexpectedly spawned"
  cmp -s "$HOME_DIR/state/$id.meta" "$expected" || fail "pre-install failure changed retained unmanaged metadata"
  [ "$(cat "$artifact" 2>/dev/null)" = prior-state ] || fail "pre-install failure discarded the retained artifact snapshot"
  [ -n "$out" ] || true
  pass "pre-install managed failures restore retained task artifacts"
}

test_session_sync_bounds_agent_fleet_queries() {
  local id rec meta_tmp started elapsed out status
  id=account-sync-timeout-z9d
  rec=$(make_case sync-timeout claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "session timeout precondition spawn failed"
  meta_tmp="$HOME_DIR/state/.$id.meta.test"
  grep -v '^provider_session_id=' "$HOME_DIR/state/$id.meta" > "$meta_tmp"
  mv "$meta_tmp" "$HOME_DIR/state/$id.meta"
  started=$(date +%s)
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_AGENT_FLEET_BIN="$FAKEBIN_DIR/agent-fleet" \
    FM_FAKE_AF_SESSION_SLEEP=10 FM_ACCOUNT_SESSION_QUERY_TIMEOUT=1 \
    PATH="$FAKEBIN_DIR:$PATH" "$SESSION_SYNC" "$id" --wait 0 --require 2>&1)
  status=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$status" -ne 0 ] || fail "timed-out session query unexpectedly succeeded"
  [ "$elapsed" -lt 5 ] || fail "session query exceeded its command timeout (${elapsed}s)"
  assert_absent "$HOME_DIR/state/.account-meta-$id.lock" "timed-out session query retained the metadata lock"
  [ -n "$out" ] || true
  pass "session synchronization bounds every Agent Fleet query"
}

test_session_sync_releases_metadata_lock_during_provider_query() {
  local id rec meta_tmp marker sync_pid sync_rc
  id=account-sync-lock-z9e
  rec=$(make_case sync-lock claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "session lock precondition spawn failed"
  meta_tmp="$HOME_DIR/state/.$id.meta.test"
  grep -v '^provider_session_id=' "$HOME_DIR/state/$id.meta" > "$meta_tmp"
  mv "$meta_tmp" "$HOME_DIR/state/$id.meta"
  marker="$CASE_DIR/session-query-started"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_AGENT_FLEET_BIN="$FAKEBIN_DIR/agent-fleet" \
    FM_FAKE_AF_SESSION_MARKER="$marker" FM_FAKE_AF_SESSION_SLEEP=2 \
    PATH="$FAKEBIN_DIR:$PATH" "$SESSION_SYNC" "$id" --require > "$CASE_DIR/sync.out" 2>&1 &
  sync_pid=$!
  for _ in $(seq 1 50); do
    [ -f "$marker" ] && break
    sleep 0.05
  done
  [ -f "$marker" ] || { kill "$sync_pid" 2>/dev/null || true; fail "session query did not start"; }
  FM_ACCOUNT_META_LOCK_WAIT_SECONDS=0 bash -c '
    . "$1"
    held=$(fm_account_meta_lock_acquire "$2" "$3")
    fm_account_meta_lock_release "$held"
  ' _ "$ROOT/bin/fm-account-routing-lib.sh" "$HOME_DIR/state" "$id" \
    || { kill "$sync_pid" 2>/dev/null || true; fail "provider query retained the metadata lock"; }
  wait "$sync_pid"
  sync_rc=$?
  expect_code 0 "$sync_rc" "session sync should complete after the unlocked provider query"
  pass "session queries hold lifecycle ownership without blocking metadata writers"
}

test_continuation_rejects_symlinked_charter_ancestor() {
  local id rec outside out status
  id=account-charter-escape-z9e
  rec=$(make_case charter-escape claude "$id")
  read_case "$rec"
  outside="$CASE_DIR/outside-data"
  mkdir -p "$outside"
  printf 'outside charter\n' > "$outside/charter.md"
  ln -s "$outside" "$WT_DIR/data"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=claude" \
    "kind=secondmate" \
    "home=$WT_DIR" \
    "account_pool=claude-crew" \
    "account_profile=claude-2" \
    "account_task=$id" \
    "account_attempt=legacy"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" safe-attempt 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "continuation accepted a charter through a symlinked ancestor"
  assert_contains "$out" "no safe non-empty original brief or charter" "unsafe charter rejection was unclear"
  assert_absent "$HOME_DIR/data/$id/continuation-safe-attempt.md" "unsafe charter was copied into a continuation packet"
  pass "secondmate continuation requires a contained charter path"
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
  local id rec out status artifact
  id=account-duplicate-z13
  rec=$(make_case duplicate claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "initial duplicate test spawn failed"
  for artifact in status turn-ended check.sh pi-ext.ts grok-turnend-token; do
    printf 'existing-%s\n' "$artifact" > "$HOME_DIR/state/$id.$artifact"
  done
  clear_case_logs
  out=$(run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "duplicate managed spawn unexpectedly succeeded"
  [ ! -s "$AF_LOG" ] || fail "duplicate managed spawn touched the original lease: $(cat "$AF_LOG")"
  assert_not_grep '^kill-window ' "$TMUX_LOG" "duplicate managed spawn killed the original endpoint"
  assert_present "$CASE_DIR/endpoint-live" "duplicate managed spawn removed the original endpoint marker"
  for artifact in status turn-ended check.sh pi-ext.ts grok-turnend-token; do
    [ "$(cat "$HOME_DIR/state/$id.$artifact" 2>/dev/null)" = "existing-$artifact" ] \
      || fail "duplicate managed spawn removed the existing $artifact sidecar"
  done
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

test_reserved_generation_is_durable_before_lease_mutation() {
  local id rec real_mv marker gate installed_marker installed_gate spawn_pid status meta task
  id=account-durable-lease-z14b
  rec=$(make_case durable-lease claude "$id")
  read_case "$rec"
  real_mv=$(command -v mv)
  marker="$CASE_DIR/provisional-meta-persisted"
  gate="$CASE_DIR/continue-after-provisional-meta"
  installed_marker="$CASE_DIR/endpoint-meta-installed"
  installed_gate="$CASE_DIR/continue-after-endpoint-meta"
  cat > "$FAKEBIN_DIR/mv" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  *.meta.rollback-pending.*)
    "$FM_FAKE_REAL_MV" "$@" || exit $?
    touch "$FM_FAKE_PROVISIONAL_META_MARKER"
    while [ ! -f "$FM_FAKE_PROVISIONAL_META_GATE" ]; do sleep 0.05; done
    exit 0
    ;;
  *.meta.[0-9]*)
    "$FM_FAKE_REAL_MV" "$@" || exit $?
    touch "$FM_FAKE_INSTALLED_META_MARKER"
    while [ ! -f "$FM_FAKE_INSTALLED_META_GATE" ]; do sleep 0.05; done
    exit 0
    ;;
esac
exec "$FM_FAKE_REAL_MV" "$@"
SH
  chmod +x "$FAKEBIN_DIR/mv"

  FM_FAKE_REAL_MV="$real_mv" FM_FAKE_PROVISIONAL_META_MARKER="$marker" \
    FM_FAKE_PROVISIONAL_META_GATE="$gate" FM_FAKE_INSTALLED_META_MARKER="$installed_marker" \
    FM_FAKE_INSTALLED_META_GATE="$installed_gate" FM_FAKE_AF_REQUIRE_PRELEASE_META="$HOME_DIR/state/$id.meta" \
    run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew \
    > "$CASE_DIR/spawn-stdout" 2> "$CASE_DIR/spawn-stderr" &
  spawn_pid=$!
  for _ in $(seq 1 100); do
    [ -f "$marker" ] && break
    kill -0 "$spawn_pid" 2>/dev/null || break
    sleep 0.05
  done
  [ -f "$marker" ] || { touch "$gate"; wait "$spawn_pid" 2>/dev/null || true; fail "spawn never persisted provisional managed metadata"; }
  meta="$HOME_DIR/state/$id.meta"
  task=$(meta_account_task "$id")
  assert_grep 'account_rollback_cleanup=pending' "$meta" "provisional metadata was not marked for rollback recovery"
  assert_grep "account_task=$task" "$meta" "provisional metadata lost the pending Agent Fleet task"
  assert_not_grep '^account_profile=' "$meta" "provisional metadata invented a profile before Agent Fleet selection"
  assert_grep "window=firstmate:fm-$id" "$meta" "provisional metadata lost the prepared endpoint"
  assert_regex '^tmux_window_id=%77$' "$meta" "provisional metadata lost the stable replacement endpoint identity"
  touch "$gate"
  for _ in $(seq 1 100); do
    [ -f "$installed_marker" ] && break
    kill -0 "$spawn_pid" 2>/dev/null || break
    sleep 0.05
  done
  [ -f "$installed_marker" ] || { touch "$installed_gate"; wait "$spawn_pid" 2>/dev/null || true; fail "spawn never installed endpoint metadata"; }
  assert_grep 'account_rollback_cleanup=pending' "$meta" "endpoint metadata cleared rollback recovery before launch commit"
  assert_grep 'account_profile=claude-2' "$meta" "endpoint metadata lost the selected account profile"
  touch "$installed_gate"
  status=0
  wait "$spawn_pid" || status=$?
  expect_code 0 "$status" "spawn should continue after its provisional generation is durable"
  assert_not_grep 'account_rollback_cleanup=pending' "$meta" "committed metadata retained the provisional rollback marker"
  pass "managed account identity is durable before lease mutation and through launch commit"
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

test_global_enforce_refuses_unsupported_harnesses() {
  local first second rec out status
  first=account-enforce-opencode-z15b
  second=account-enforce-raw-z15c
  rec=$(make_case enforce-unsupported opencode "$first" "$second")
  read_case "$rec"
  printf 'enforce\n' > "$HOME_DIR/config/account-routing-mode"

  out=$(run_spawn "$first" "$PROJ_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "global enforce unexpectedly admitted opencode"
  assert_contains "$out" "enforced account routing requires a claude or codex harness" "unsupported enforced harness blocker was unclear"
  assert_not_grep '^new-window ' "$TMUX_LOG" "unsupported enforced harness created an endpoint"
  assert_absent "$HOME_DIR/state/$first.meta" "unsupported enforced harness wrote task metadata"

  clear_case_logs
  out=$(run_spawn "$second" "$PROJ_DIR" --harness 'custom-agent --unsafe')
  status=$?
  [ "$status" -ne 0 ] || fail "global enforce unexpectedly admitted a raw unsupported harness"
  assert_contains "$out" "enforced account routing requires a claude or codex harness" "raw unsupported enforced harness blocker was unclear"
  assert_not_grep '^new-window ' "$TMUX_LOG" "raw unsupported enforced harness created an endpoint"
  assert_absent "$HOME_DIR/state/$second.meta" "raw unsupported enforced harness wrote task metadata"
  pass "global enforced routing refuses unsupported and raw harnesses before mutation"
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
  local id rec out status task release_count retained_id retained_rec retained_task
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

  retained_id=account-invalid-select-retained-z17b
  retained_rec=$(make_case invalid-select-retained claude "$retained_id")
  read_case "$retained_rec"
  out=$(FM_FAKE_AF_BAD_SELECTION=1 FM_FAKE_AF_RELEASE_FAIL=1 \
    run_spawn "$retained_id" "$PROJ_DIR" --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "malformed lease response with persistent release failure unexpectedly succeeded"
  retained_task=$(logged_account_task)
  assert_grep 'account_rollback_cleanup=pending' "$HOME_DIR/state/$retained_id.meta" \
    "unreleased invalid selection did not persist rollback metadata"
  assert_grep "account_task=$retained_task" "$HOME_DIR/state/$retained_id.meta" \
    "unreleased invalid selection lost its Agent Fleet task identity"
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

test_failed_secondmate_respawn_rollback_restores_prior_state() {
  local id rec sm expected out status artifact
  id=account-secondmate-restore-z18f
  rec=$(make_case secondmate-restore claude "$id")
  read_case "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$sm" \
    "project=$sm" \
    "home=$sm" \
    "harness=claude" \
    "kind=secondmate" \
    "mode=secondmate" \
    "custom_extension=preserve-secondmate"
  expected="$CASE_DIR/original-secondmate.meta"
  cp "$HOME_DIR/state/$id.meta" "$expected"
  for artifact in status turn-ended check.sh pi-ext.ts grok-turnend-token; do
    printf 'prior-%s\n' "$artifact" > "$HOME_DIR/state/$id.$artifact"
  done

  out=$(FM_FAKE_AF_SESSION_MISSING=1 FM_FAKE_AF_RELEASE_FAIL=1 FM_TEST_PANE_PATH="$sm" \
    run_spawn "$id" "$sm" --secondmate --account-pool claude-crew)
  status=$?
  [ "$status" -ne 0 ] || fail "failed secondmate respawn precondition unexpectedly succeeded"
  assert_grep 'account_rollback_cleanup=pending' "$HOME_DIR/state/$id.meta" "failed secondmate respawn lost cleanup metadata"

  clear_case_logs
  out=$(run_spawn "$id" --continue-account --account-profile claude-3)
  status=$?
  [ "$status" -ne 0 ] || fail "secondmate rollback cleanup continued through a restored generation"
  cmp -s "$HOME_DIR/state/$id.meta" "$expected" || fail "secondmate rollback cleanup deleted or changed restored metadata"
  for artifact in status turn-ended check.sh pi-ext.ts grok-turnend-token; do
    [ "$(cat "$HOME_DIR/state/$id.$artifact" 2>/dev/null)" = "prior-$artifact" ] \
      || fail "secondmate rollback cleanup deleted restored $artifact state"
  done
  assert_contains "$out" "previous task state was restored" "secondmate rollback restoration guidance was unclear"
  assert_present "$sm/.fm-secondmate-home" "secondmate rollback cleanup retired the persistent home"
  pass "failed secondmate respawn rollback preserves restored metadata and sidecars"
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
  local harness=$1 old_profile=$2 new_profile=$3 provider=$4 id rec old_task new_task packet out status launch source_model
  id="account-continue-$harness-z21"
  rec=$(make_case "continue-$harness" "$harness" "$id")
  read_case "$rec"
  source_model="$harness-source-model"
  out=$(FM_FAKE_AF_PROVIDER="$provider" FM_FAKE_AF_PROFILE="$old_profile" FM_FAKE_AF_POOL="$harness-crew" \
    run_spawn "$id" "$PROJ_DIR" --account-pool "$harness-crew" --model "$source_model" --effort high)
  status=$?
  [ "$status" -eq 0 ] || fail "$harness initial managed spawn failed: $out"
  old_task=$(meta_account_task "$id")
  printf 'done: external side effect alpha; do not rerun\nnext: verify beta\n' > "$HOME_DIR/state/$id.status"
  printf '# Completion\n\nShip completion evidence for %s.\n' "$harness" > "$HOME_DIR/data/$id/completion.md"
  printf '# Decisions\n\n- Keep the existing branch.\n' > "$HOME_DIR/data/$id/decisions.md"
  run_send "$id" "Preserve the verified next action for $harness." >/dev/null \
    || fail "$harness steering trail precondition failed"
  assert_grep "Preserve the verified next action for $harness." "$HOME_DIR/data/$id/steering.md" "$harness managed steering was not recorded"
  printf '# Pending steering audit\n\n- Preserve pending delivery for %s.\n' "$harness" > "$HOME_DIR/data/$id/steering-pending.md"
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
  assert_grep "Ship completion evidence for $harness." "$packet" "$harness continuation packet lost ship completion evidence"
  assert_grep 'Keep the existing branch' "$packet" "$harness continuation packet lost decisions"
  assert_grep "Preserve the verified next action for $harness." "$packet" "$harness continuation packet lost steering"
  assert_grep "Preserve pending delivery for $harness." "$packet" "$harness continuation packet lost pending steering audit"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--profile '$new_profile' --task '$new_task'" "$harness continuation did not use the new profile/generation"
  assert_contains "$launch" "cat '$packet'" "$harness continuation did not seed the fresh provider from task-owned state"
  assert_contains "$launch" "--model '$source_model'" "$harness same-provider continuation lost its inherited model"
  assert_regex '^effort=high$' "$HOME_DIR/state/$id.meta" "$harness same-provider continuation lost its inherited effort"
  assert_grep "lease release --task $old_task --force" "$AF_LOG" "$harness continuation did not release its predecessor after binding"
  assert_grep "session remove --task $old_task" "$AF_LOG" "$harness continuation did not remove its predecessor mapping"
  assert_grep "agent_fleet_task=$new_task" "$HOME_DIR/data/$id/account-attempts.md" "$harness continuation lineage lost the new attempt"
  pass "$harness can continue safely under a different account profile"
}

test_cross_provider_continuation_uses_target_default_pool() {
  local source=$1 target=$2 id rec old_task out status source_model launch
  id="account-continue-$source-to-$target-z21a"
  rec=$(make_case "continue-$source-to-$target" "$source" "$id")
  read_case "$rec"
  source_model="$source-source-model"
  out=$(FM_FAKE_AF_PROVIDER="$source" FM_FAKE_AF_PROFILE="$source-2" FM_FAKE_AF_POOL="$source-crew" \
    run_spawn "$id" "$PROJ_DIR" --account-pool "$source-crew" --model "$source_model" --effort high)
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
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "$source_model" "$source-to-$target continuation inherited the source provider's model"
  assert_regex '^model=default$' "$HOME_DIR/state/$id.meta" "$source-to-$target continuation did not restore the target model default"
  assert_regex '^effort=default$' "$HOME_DIR/state/$id.meta" "$source-to-$target continuation did not restore the target effort default"
  assert_grep "predecessor=$old_task" "$HOME_DIR/data/$id/account-attempts.md" \
    "$source-to-$target continuation lost predecessor lineage"
  pass "$source-to-$target continuation resolves the target provider pool"
}

test_continuation_refuses_unknown_endpoint_state() {
  local id rec old_task out status meta_tmp
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

  meta_tmp="$HOME_DIR/state/.$id.meta.missing-target"
  grep -Ev '^(window|tmux_window_id)=' "$HOME_DIR/state/$id.meta" > "$meta_tmp"
  mv "$meta_tmp" "$HOME_DIR/state/$id.meta"
  clear_case_logs
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" direct-missing 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "continuation packet builder accepted missing endpoint metadata"
  assert_contains "$out" "endpoint state is unknown" "missing continuation endpoint did not fail closed"

  out=$(run_spawn "$id" --continue-account --account-profile claude-3)
  status=$?
  [ "$status" -ne 0 ] || fail "continuation accepted missing endpoint metadata"
  assert_contains "$out" "endpoint state is unknown" "managed recovery skipped its missing endpoint"
  assert_not_grep 'lease choose\|lease acquire\|lease release' "$AF_LOG" "missing endpoint recovery mutated Agent Fleet state"
  assert_not_grep '^new-window ' "$TMUX_LOG" "missing endpoint recovery created a replacement endpoint"
  pass "continuation requires a recorded endpoint with confirmed absence"
}

test_missing_endpoint_target_retains_managed_lease() {
  local id rec out status meta_tmp account_task
  id=account-missing-endpoint-z21ab
  rec=$(make_case missing-endpoint claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "missing endpoint teardown precondition spawn failed"
  account_task=$(meta_account_task "$id")
  rm -f "$CASE_DIR/endpoint-live"
  meta_tmp="$HOME_DIR/state/.$id.meta.missing-target"
  grep -Ev '^(window|tmux_window_id)=' "$HOME_DIR/state/$id.meta" > "$meta_tmp"
  mv "$meta_tmp" "$HOME_DIR/state/$id.meta"
  clear_case_logs

  out=$(run_teardown "$id" --force 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "managed teardown released a lease with missing endpoint metadata"
  assert_contains "$out" "endpoint state for $id is unknown" "missing teardown endpoint did not report its blocker"
  assert_not_grep "lease release --task $account_task" "$AF_LOG" "missing teardown endpoint released its Agent Fleet lease"
  assert_present "$HOME_DIR/state/$id.meta" "missing teardown endpoint lost retry metadata"
  pass "managed teardown retains leases when endpoint identity is missing"
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
  assert_grep 'managed recovery endpoint is still alive' "$CASE_DIR/second.out" "concurrent continuation did not revalidate the serialized replacement endpoint"
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
  assert_grep 'This delivered steer must not be retried' "$HOME_DIR/data/$id/steering-pending.md" \
    "delivered steering was not durably recorded after the canonical trail failed"
  pass "steering audit failures durably spool delivery without returning a retry signal"
}

test_managed_tmux_identity_survives_window_rename() {
  local id rec out status
  id=account-tmux-identity-z25
  rec=$(make_case tmux-identity claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "stable tmux identity precondition spawn failed"
  assert_regex '^window=firstmate:fm-account-tmux-identity-z25$' "$HOME_DIR/state/$id.meta" "managed tmux metadata lost its user-facing window label"
  assert_regex '^tmux_window_id=%77$' "$HOME_DIR/state/$id.meta" "managed tmux metadata did not persist the stable window id"
  clear_case_logs

  set +e
  out=$(FM_FAKE_TMUX_RENAMED=1 FM_FAKE_TMUX_KILL_FAIL=1 run_teardown "$id" --force 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "renamed live tmux endpoint allowed managed teardown"
  assert_not_grep 'lease release' "$AF_LOG" "renamed live tmux endpoint released its Agent Fleet lease"
  assert_present "$HOME_DIR/state/$id.meta" "renamed live tmux endpoint lost its recovery metadata"
  [ -n "$out" ] || true
  pass "managed tmux lifecycle uses rename-stable endpoint identity"
}

test_native_resume_rejects_regressed_sessionstart_evidence() {
  local id rec out status account_task
  id=account-resume-regressed-z26
  rec=$(make_case resume-regressed claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "regressed resume precondition spawn failed"
  account_task=$(meta_account_task "$id")
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs

  set +e
  out=$(FM_FAKE_AF_UPDATED_AT_BEFORE=2026-07-13T00:00:01Z FM_FAKE_AF_UPDATED_AT_AFTER=2026-07-13T00:00:00Z \
    run_spawn "$id" --resume-account)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "native resume accepted a regressed SessionStart timestamp"
  assert_contains "$out" "no fresh Agent Fleet SessionStart update" "regressed SessionStart evidence did not fail as stale"
  assert_grep "lease release --task $account_task --force" "$AF_LOG" "regressed SessionStart failure leaked its recovered reservation"
  pass "native resume requires monotonically newer SessionStart evidence"
}

test_session_sync_metadata_publish_failure_is_closed() {
  local id rec meta_tmp before_lineage after_lineage failbin out status
  id=account-sync-publish-z27
  rec=$(make_case sync-publish claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "session publish precondition spawn failed"
  meta_tmp="$HOME_DIR/state/.$id.meta.test"
  grep -v '^provider_session_id=' "$HOME_DIR/state/$id.meta" > "$meta_tmp"
  mv "$meta_tmp" "$HOME_DIR/state/$id.meta"
  before_lineage=$(grep -c 'event=session-bound' "$HOME_DIR/data/$id/account-attempts.md")
  failbin="$CASE_DIR/failbin"
  mkdir -p "$failbin"
  cat > "$failbin/mv" <<'SH'
#!/usr/bin/env bash
case "$*" in *'.meta.sync.'*) exit 71 ;; esac
exec /bin/mv "$@"
SH
  chmod +x "$failbin/mv"

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_AGENT_FLEET_BIN="$FAKEBIN_DIR/agent-fleet" FM_FAKE_AF_LOG="$AF_LOG" \
    FM_FAKE_AF_POOL=claude-crew FM_FAKE_AF_PROFILE=claude-2 FM_FAKE_AF_PROVIDER=claude \
    PATH="$failbin:$FAKEBIN_DIR:$PATH" "$SESSION_SYNC" "$id" --require 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "session sync reported success after metadata replacement failed"
  assert_not_grep '^provider_session_id=' "$HOME_DIR/state/$id.meta" "failed session publication changed durable metadata"
  after_lineage=$(grep -c 'event=session-bound' "$HOME_DIR/data/$id/account-attempts.md")
  [ "$after_lineage" -eq "$before_lineage" ] || fail "failed session publication appended lineage before durable metadata"
  [ -n "$out" ] || true
  pass "session synchronization fails closed on metadata publication"
}

test_oversized_continuation_stops_before_mutation() {
  local id rec out status
  id=account-continuation-size-z28
  rec=$(make_case continuation-size claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "continuation size precondition spawn failed"
  dd if=/dev/zero bs=70000 count=1 2>/dev/null | tr '\0' x > "$HOME_DIR/state/$id.status"
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs

  set +e
  out=$(run_spawn "$id" --continue-account --account-profile claude-3)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "oversized continuation packet was accepted"
  assert_contains "$out" 'maximum is 65536' "oversized continuation rejection did not report its bound"
  assert_not_grep '^new-window ' "$TMUX_LOG" "oversized continuation created a replacement endpoint"
  assert_not_grep 'lease choose\|lease acquire' "$AF_LOG" "oversized continuation acquired an Agent Fleet lease"
  pass "continuation packet size is bounded before external mutation"
}

test_account_metadata_lock_reclaims_orphans_without_overlapping_owners() {
  local case_dir state lock workers pids pid rc owner_lines
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

  owner_lines=$(FM_ACCOUNT_META_LOCK_WAIT_SECONDS=1 bash -c '
    . "$1"
    held=$(fm_account_meta_lock_acquire "$2" lock-task)
    [ -f "$held" ] || exit 71
    wc -l < "$held" | tr -d "[:space:]"
    fm_account_meta_lock_release "$held"
  ' _ "$ROOT/bin/fm-account-routing-lib.sh" "$state") || fail "metadata lock ownership was not atomically published"
  [ "$owner_lines" -eq 2 ] || fail "published metadata lock did not contain complete ownership"

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

  mkdir -p "$lock"
  FM_ACCOUNT_META_LOCK_ORPHAN_GRACE_SECONDS=0 bash -c '
    . "$1"
    fm_account_reclaim_guard_acquire "$2/.reclaiming" 1
    [ -f "$2/.reclaiming" ] && [ "$(wc -l < "$2/.reclaiming" | tr -d "[:space:]")" -eq 2 ]
  ' _ "$ROOT/bin/fm-account-routing-lib.sh" "$lock" \
    || fail "metadata reclaim ownership was not atomically published"
  rm -rf "$lock"

  mkdir -p "$lock/.reclaiming"
  printf '999999\nstale-reclaimer\n' > "$lock/.reclaiming/owner"
  touch -t 200001010000 "$lock" "$lock/.reclaiming"
  FM_ACCOUNT_META_LOCK_WAIT_SECONDS=2 FM_ACCOUNT_META_LOCK_ORPHAN_GRACE_SECONDS=0 \
    bash -c '. "$1"; held=$(fm_account_meta_lock_acquire "$2" lock-task); fm_account_meta_lock_release "$held"' \
    _ "$ROOT/bin/fm-account-routing-lib.sh" "$state" || fail "abandoned metadata reclaim owner blocked acquisition"
  assert_absent "$lock" "metadata lock retained an abandoned reclaim owner"
  pass "metadata locks reclaim abandoned directories without deleting new owners"
}

test_linux_stat_selection_avoids_filesystem_stat_output() {
  local case_dir fakebin file output
  case_dir="$TMP_ROOT/linux-stat-selection"
  fakebin="$case_dir/fakebin"
  file="$case_dir/file"
  mkdir -p "$fakebin"
  : > "$file"
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf 'Linux\n'
SH
  cat > "$fakebin/stat" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -f) printf 'File: poisoned-filesystem-output\n'; exit 0 ;;
  -c)
    case "${2:-}" in
      %Y) printf '12345\n' ;;
      %i) printf '67890\n' ;;
      *) exit 2 ;;
    esac
    ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/uname" "$fakebin/stat"
  output=$(PATH="$fakebin:$PATH" bash -c '. "$1"; printf "%s:%s\n" "$(fm_account_path_mtime "$2")" "$(fm_account_path_inode "$2")"' \
    _ "$ROOT/bin/fm-account-routing-lib.sh" "$file") || fail "Linux account stat helpers failed"
  [ "$output" = '12345:67890' ] || fail "Linux account stat helpers accepted filesystem-stat output: $output"
  pass "account metadata stat helpers select GNU stat without probing BSD filesystem stat"
}

test_stale_reclaim_guard_is_owned_before_lock_removal() {
  local case_dir lock output status
  case_dir="$TMP_ROOT/reclaim-guard-ownership"
  lock="$case_dir/meta.lock"
  mkdir -p "$case_dir"
  printf '999999\nstale-owner\n' > "$lock"
  printf '999999\nstale-reclaimer\n' > "$lock.reclaiming"
  touch -t 200001010000 "$lock.reclaiming"
  bash -c '
    . "$1"
    fm_account_reclaim_guard_acquire "$2.reclaiming" 1 || exit 71
    fm_account_reclaim_guard_owned "$2.reclaiming" || exit 72
    fm_account_reclaim_guard_release "$2.reclaiming"
  ' _ "$ROOT/bin/fm-account-routing-lib.sh" "$lock" || fail "stale reclaim guard was observed but not acquired"

  printf '999999\nstale-owner\n' > "$lock"
  set +e
  output=$(LOCK="$lock" bash -c '
    . "$1"
    replaced=0
    fm_account_reclaim_guard_acquire() { printf "%s\n%s\n" "$$" "$(fm_account_process_start_time "$$")" > "$1"; }
    fm_account_reclaim_guard_owned() {
      if [ "$replaced" = 0 ]; then
        replaced=1
        rm -f "$LOCK"
        printf "%s\n%s\n" "$$" "$(fm_account_process_start_time "$$")" > "$LOCK"
      fi
      return 0
    }
    fm_account_reclaim_guard_release() { rm -rf "$1"; }
    fm_account_meta_lock_reclaim "$LOCK" 1
  ' _ "$ROOT/bin/fm-account-routing-lib.sh" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "metadata reclaim deleted a lock generation replaced after guard acquisition"
  [ "$(sed -n '1p' "$lock")" != 999999 ] || fail "metadata reclaim did not install the simulated replacement lock"
  [ -n "$output" ] || true
  pass "stale metadata reclaim owns its guard and preserves a replaced lock generation"
}

test_task_owned_account_artifacts_reject_symlink_paths() {
  local id rec outside original out status before
  id=account-symlink-safety-z29
  rec=$(make_case symlink-safety claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "symlink safety precondition spawn failed"
  original="$HOME_DIR/data/$id"
  outside="$CASE_DIR/outside-task"
  mv "$original" "$outside"
  ln -s "$outside" "$original"
  before=$(cat "$outside/account-attempts.md")

  if bash -c '. "$1"; fm_account_lineage_append "$2" "$3" unsafe attempt fleet claude pool profile session none' \
    _ "$ROOT/bin/fm-account-routing-lib.sh" "$HOME_DIR/data" "$id"; then
    fail "account lineage followed a symlinked task directory"
  fi
  [ "$(cat "$outside/account-attempts.md")" = "$before" ] || fail "account lineage changed a symlink target outside the data root"

  out=$(run_send "$id" "Delivered without following the task symlink." 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "symlinked steering audit changed delivery truth: $out"
  assert_absent "$outside/steering.md" "managed steering followed a symlinked task directory"
  assert_absent "$outside/steering-pending.md" "pending steering followed a symlinked task directory"

  rm -f "$CASE_DIR/endpoint-live"
  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_FAKE_ENDPOINT_FILE="$CASE_DIR/endpoint-live" \
    FM_FAKE_TMUX_LOG="$TMUX_LOG" PATH="$FAKEBIN_DIR:$PATH" \
    "$CONTINUATION" "$id" symlink-attempt 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "continuation accepted a symlinked task directory"
  assert_contains "$out" "task directory is unsafe" "continuation task-directory refusal was unclear"

  rm -f "$original"
  mv "$outside" "$original"
  printf 'outside\n' > "$CASE_DIR/outside-steering"
  ln -s "$CASE_DIR/outside-steering" "$original/steering.md"
  touch "$CASE_DIR/endpoint-live"
  out=$(run_send "$id" "Delivered without following the steering symlink." 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "symlinked steering file changed delivery truth: $out"
  [ "$(cat "$CASE_DIR/outside-steering")" = outside ] || fail "managed steering followed a symlinked output file"
  assert_grep 'Delivered without following the steering symlink' "$original/steering-pending.md" \
    "safe pending steering was not recorded after a symlinked canonical trail was rejected"
  pass "task-owned lineage, steering, and continuation artifacts reject symlink escapes"
}

test_agent_fleet_contract_is_validated_before_routing() {
  local id rec out status
  id=account-contract-z26
  rec=$(make_case contract claude "$id")
  read_case "$rec"
  if out=$(FM_FAKE_AF_CONTRACT_VERSION=2 run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "incompatible Agent Fleet contract unexpectedly enforced routing"
  assert_not_grep 'lease (choose|acquire)' "$AF_LOG" "incompatible Agent Fleet contract mutated a lease"
  assert_contains "$out" "unsupported Agent Fleet contract version 2" "contract mismatch was not actionable"

  clear_case_logs
  if out=$(FM_ACCOUNT_ROUTING=observe FM_FAKE_AF_CONTRACT_VERSION=2 run_spawn "$id" "$PROJ_DIR"); then status=0; else status=$?; fi
  [ "$status" -eq 0 ] || fail "observe mode should degrade on an incompatible Agent Fleet contract"
  assert_not_grep ' choose ' "$AF_LOG" "incompatible observe contract still queried selection"
  assert_contains "$out" "observe contract unavailable" "observe contract fallback was not surfaced"
  pass "Agent Fleet contract v1 is required before observation or enforcement"
}

test_agent_fleet_lifecycle_calls_are_bounded() {
  local id rec out status started elapsed
  id=account-control-timeout-z27
  rec=$(make_case control-timeout claude "$id")
  read_case "$rec"
  started=$(date +%s)
  if out=$(FM_FAKE_AF_SELECT_SLEEP=10 FM_ACCOUNT_CONTROL_TIMEOUT=1 run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew); then status=0; else status=$?; fi
  elapsed=$(( $(date +%s) - started ))
  [ "$status" -eq 0 ] || fail "timed-out lease choice was not reconciled through recovery: $out"
  [ "$elapsed" -lt 5 ] || fail "lease choice timeout was not bounded (elapsed ${elapsed}s)"
  assert_grep 'lease recover ' "$AF_LOG" "timed-out lease choice did not reconcile ownership"

  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs
  started=$(date +%s)
  if out=$(FM_FAKE_AF_RELEASE_SLEEP=10 FM_ACCOUNT_CONTROL_TIMEOUT=1 run_teardown "$id" --force 2>&1); then status=0; else status=$?; fi
  elapsed=$(( $(date +%s) - started ))
  [ "$status" -ne 0 ] || fail "ambiguous timed-out lease release unexpectedly completed teardown"
  [ "$elapsed" -lt 5 ] || fail "lease release timeout was not bounded (elapsed ${elapsed}s)"
  assert_present "$HOME_DIR/state/$id.meta" "ambiguous lease release discarded retry metadata"
  pass "Agent Fleet lease mutations are bounded and ambiguous outcomes retain ownership state"
}

test_account_timeout_wrapper_uses_hard_kill_fallback() {
  local fakebin log status perl_bin
  fakebin=$(fm_fakebin "$TMP_ROOT/hard-timeout")
  log="$TMP_ROOT/hard-timeout.args"
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FM_FAKE_TIMEOUT_LOG"
SH
  chmod +x "$fakebin/timeout"
  PATH="$fakebin:$PATH" FM_FAKE_TIMEOUT_LOG="$log" bash -c '
    . "$1"
    fm_account_run_bounded 3 true
  ' _ "$ROOT/bin/fm-account-routing-lib.sh" || fail "account timeout wrapper invocation failed"
  assert_grep '--kill-after=1 3 true' "$log" "account timeout wrapper omitted the hard KILL fallback"

  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
exit 137
SH
  chmod +x "$fakebin/timeout"
  if PATH="$fakebin:$PATH" bash -c '. "$1"; fm_account_run_bounded 3 true' _ "$ROOT/bin/fm-account-routing-lib.sh"; then
    status=0
  else
    status=$?
  fi
  [ "$status" -eq 124 ] || fail "hard-kill timeout status was not normalized for reconciliation (status=$status)"

  perl_bin=$(command -v perl || true)
  if [ -n "$perl_bin" ]; then
    rm -rf "$fakebin"
    mkdir -p "$fakebin"
    ln -s "$perl_bin" "$fakebin/perl"
    cat > "$fakebin/signaled" <<'SH'
#!/bin/sh
kill -TERM $$
SH
    chmod +x "$fakebin/signaled"
    if PATH="$fakebin" /bin/bash -c '. "$1"; fm_account_run_bounded 3 "$2"' \
      _ "$ROOT/bin/fm-account-routing-lib.sh" "$fakebin/signaled"; then
      status=0
    else
      status=$?
    fi
    [ "$status" -eq 143 ] || fail "Perl timeout fallback converted a signaled child into success (status=$status)"
  fi
  pass "Agent Fleet control timeouts force-kill TERM-resistant subprocesses"
}

test_teardown_stops_after_rollback_restores_predecessor() {
  local id rec old_task failed_task out status
  id=account-teardown-restore-z28
  rec=$(make_case teardown-restore claude "$id")
  read_case "$rec"
  run_spawn "$id" "$PROJ_DIR" --account-pool claude-crew >/dev/null || fail "rollback restore precondition spawn failed"
  old_task=$(meta_account_task "$id")
  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs
  if out=$(FM_FAKE_AF_PROFILE=claude-3 FM_FAKE_AF_POOL=explicit FM_FAKE_AF_SESSION_MISSING=1 FM_FAKE_AF_RELEASE_FAIL=1 \
    run_spawn "$id" --continue-account --account-profile claude-3); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "failed continuation precondition unexpectedly succeeded"
  failed_task=$(meta_account_task "$id")
  [ "$failed_task" != "$old_task" ] || fail "failed continuation did not install its rollback generation"

  rm -f "$CASE_DIR/endpoint-live"
  clear_case_logs
  if out=$(run_teardown "$id" --force 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "teardown continued after restoring predecessor metadata"
  [ "$(meta_account_task "$id")" = "$old_task" ] || fail "teardown did not preserve restored predecessor metadata"
  assert_not_grep "lease release --task $old_task" "$AF_LOG" "teardown released the restored predecessor in the stale generation pass"
  assert_contains "$out" "rerun teardown against the restored task generation" "rollback restoration retry guidance was not surfaced"

  clear_case_logs
  run_teardown "$id" --force >/dev/null || fail "restored predecessor could not be torn down on a fresh pass"
  assert_grep "lease release --task $old_task" "$AF_LOG" "fresh teardown did not release the restored predecessor"
  pass "teardown stops and revalidates after rollback restores predecessor state"
}

test_reserved_generation_is_durable_before_lease_mutation
test_off_is_byte_compatible_and_never_calls_agent_fleet
test_observe_is_dry_run_only
test_enforce_pool_wraps_backend_and_records_real_session
test_explicit_profile_uses_explicit_pool
test_enforce_failure_rolls_back_prepared_endpoint
test_pane_failure_happens_before_account_reservation
test_batch_partial_failure_releases_only_failed_item
test_resume_uses_sticky_recovery_and_preserves_mapping_on_failure
test_unmanaged_respawn_preserves_report_cutover_state
test_failed_managed_respawn_restores_unmanaged_metadata
test_preinstall_managed_failure_restores_artifact_snapshot
test_session_sync_bounds_agent_fleet_queries
test_session_sync_releases_metadata_lock_during_provider_query
test_continuation_rejects_symlinked_charter_ancestor
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
test_global_enforce_refuses_unsupported_harnesses
test_malformed_routing_mode_fails_closed
test_invalid_selection_response_releases_reservation
test_fresh_launch_requires_session_binding_and_fully_rolls_back
test_failed_cleanup_persists_retryable_metadata
test_unknown_spawn_endpoint_retains_lease_for_retry
test_rollback_retry_rechecks_live_endpoint_before_release
test_failed_secondmate_rollback_preserves_home_for_relaunch
test_failed_secondmate_respawn_rollback_restores_prior_state
test_observe_invalid_response_remains_advisory
test_explicit_secondmate_profile_ignores_configured_pool
test_enforced_orca_is_rejected_before_owned_resource_creation
test_cross_profile_continuation_for_harness claude claude-2 claude-3 claude
test_cross_profile_continuation_for_harness codex codex-2 codex-3 codex
test_cross_provider_continuation_uses_target_default_pool claude codex
test_cross_provider_continuation_uses_target_default_pool codex claude
test_continuation_refuses_unknown_endpoint_state
test_missing_endpoint_target_retains_managed_lease
test_predecessor_cleanup_failure_preserves_replacement_for_retry
test_failed_continuation_cleanup_restores_predecessor_for_retry
test_concurrent_continuations_serialize_before_mutation
test_continuation_fails_closed_without_original_brief
test_session_sync_cannot_recreate_metadata_after_teardown
test_managed_steering_audit_failure_does_not_reclassify_delivery
test_managed_tmux_identity_survives_window_rename
test_native_resume_rejects_regressed_sessionstart_evidence
test_session_sync_metadata_publish_failure_is_closed
test_oversized_continuation_stops_before_mutation
test_account_metadata_lock_reclaims_orphans_without_overlapping_owners
test_linux_stat_selection_avoids_filesystem_stat_output
test_stale_reclaim_guard_is_owned_before_lock_removal
test_task_owned_account_artifacts_reject_symlink_paths
test_agent_fleet_contract_is_validated_before_routing
test_agent_fleet_lifecycle_calls_are_bounded
test_account_timeout_wrapper_uses_hard_kill_fallback
test_teardown_stops_after_rollback_restores_predecessor

echo "# all fm-account-routing tests passed"
