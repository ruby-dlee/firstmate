#!/usr/bin/env bash
# Behavioral coverage for report-only startup trust-dialog surfacing.
# The spawn cases drive the real fm-spawn.sh boundary with a fake tmux backend
# that records every key. The watcher cases drive the real fm-watch.sh process.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-harness-prompt-lib.sh
. "$ROOT/bin/fm-harness-prompt-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-startup-trust)

fixture_codex_trust() {
  cat <<'EOF'
You are in /worktree/example

Do you trust the contents of this directory? Working with untrusted contents comes with higher risk of prompt injection.

› 1. Yes, continue
  2. No, quit
EOF
}

fixture_claude_workspace_trust() {
  cat <<'EOF'
Accessing workspace:

/worktree/example

Quick safety check: Is this a project you created or one you trust?

Claude Code'll be able to read, edit, and execute files here.

❯ 1. Yes, I trust this folder
  2. No, exit

Enter to confirm · Esc to cancel
EOF
}

fixture_claude_hook_trust() {
  cat <<'EOF'
Hooks need review

❯ 1. Trust all on first launch
  2. Review hooks
  3. Exit

Enter to confirm · Esc to cancel
EOF
}

drop_fixture_token() {  # <token>
  awk -v token="$1" 'index($0, token) == 0 { print }'
}

assert_classifier_fixture() {  # <harness> <expected-kind> <fixture-function> <required-token>...
  local harness=$1 expected=$2 fixture_fn=$3 fixture actual token mutated
  shift 3
  fixture=$($fixture_fn)
  actual=$(fm_startup_trust_dialog_kind "$harness" "$fixture" || true)
  [ "$actual" = "$expected" ] || fail "$expected fixture classified as '$actual'"
  for token in "$@"; do
    mutated=$(printf '%s\n' "$fixture" | drop_fixture_token "$token")
    actual=$(fm_startup_trust_dialog_kind "$harness" "$mutated" || true)
    [ -z "$actual" ] || fail "$expected still matched after required token '$token' was removed"
  done
}

test_pure_startup_classifier_distinguishes_every_shape() {
  local fixture actual conflict
  assert_classifier_fixture codex codex-directory-trust fixture_codex_trust \
    'Do you trust the contents of this directory?' 'Yes, continue' 'No, quit'
  assert_classifier_fixture claude claude-workspace-trust fixture_claude_workspace_trust \
    'Quick safety check: Is this a project you created or one you trust?' \
    'Yes, I trust this folder' 'No, exit' 'Enter to confirm · Esc to cancel'
  assert_classifier_fixture claude claude-hook-trust fixture_claude_hook_trust \
    'Hooks need review' 'Trust all on first launch' 'Review hooks' 'Exit' \
    'Enter to confirm · Esc to cancel'

  fixture=$(fixture_codex_trust)
  actual=$(fm_startup_trust_dialog_kind claude "$fixture" || true)
  [ -z "$actual" ] || fail "wrong-harness Codex fixture matched Claude"
  actual=$(fm_startup_trust_dialog_kind unknown "$fixture" || true)
  [ -z "$actual" ] || fail "unknown harness borrowed Codex's startup acceptance rule"
  actual=$(fm_startup_trust_dialog_kind codex "$fixture
• Working (2s • esc to interrupt)" || true)
  [ -z "$actual" ] || fail "busy-plus-dialog pane matched a startup acceptance class"

  conflict=$(cat <<'EOF'
Quick safety check: Is this a project you created or one you trust?
1. Yes, I trust this folder
2. No, exit
Hooks need review
1. Trust all on first launch
2. Review hooks
3. Exit
Enter to confirm · Esc to cancel
EOF
)
  actual=$(fm_startup_trust_dialog_kind claude "$conflict" || true)
  [ -z "$actual" ] || fail "two conflicting complete startup shapes produced an acceptance class"

  fixture=$(fixture_codex_trust)
  fixture="$fixture
filler 01
filler 02
filler 03
filler 04
filler 05
filler 06
filler 07
filler 08
filler 09
filler 10
filler 11
filler 12
filler 13
filler 14
filler 15
filler 16"
  actual=$(fm_startup_trust_dialog_kind codex "$fixture" || true)
  [ -z "$actual" ] || fail "prompt outside the final 16 lines matched"

  fixture=$(cat <<'EOF'
Would you like to run the following command?
1. Yes, proceed
3. No, and tell Codex what to do differently
Press enter to confirm or esc to cancel
EOF
)
  actual=$(fm_startup_trust_dialog_kind codex "$fixture" || true)
  [ -z "$actual" ] || fail "mid-run command grant matched a startup acceptance class"
  [ "$(fm_midrun_permission_prompt_kind codex "$fixture" 0 || true)" = 'command/tool permission' ] \
    || fail "mid-run positive control did not reach its separate protected classifier"
  pass "startup classifier requires EVERY token, rejects wrong phase/harness/busy/conflicting shapes, and has a mid-run positive control"
}

make_spawn_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    case "$*" in
      *pane_current_path*) printf '%s\n' "${FM_FAKE_PANE_PATH:?}"; exit 0 ;;
      *pane_id*)
        capture_count=$(cat "${FM_FAKE_CAPTURE_COUNT:?}" 2>/dev/null || printf 0)
        [ "${FM_FAKE_ENDPOINT_DISAPPEAR:-0}" != 1 ] || [ "$capture_count" -eq 0 ] || exit 1
        printf '%%1\n'; exit 0 ;;
      *session_name*window_name*) printf 'firstmate\t%s\n' "${FM_FAKE_WINDOW_LABEL:?}"; exit 0 ;;
    esac
    printf 'firstmate\n'
    exit 0
    ;;
  list-windows)
    capture_count=$(cat "${FM_FAKE_CAPTURE_COUNT:?}" 2>/dev/null || printf 0)
    if [ -e "${FM_FAKE_CREATED:?}" ] \
      && { [ "${FM_FAKE_ENDPOINT_DISAPPEAR:-0}" != 1 ] || [ "$capture_count" -eq 0 ]; }; then
      printf '%s\n' "${FM_FAKE_WINDOW_LABEL:?}"
    fi
    exit 0
    ;;
  has-session) exit 0 ;;
  new-window)
    : > "${FM_FAKE_CREATED:?}"
    printf '@77\n'
    exit 0
    ;;
  set-window-option|kill-window) exit 0 ;;
  capture-pane)
    count=$(cat "${FM_FAKE_CAPTURE_COUNT:?}" 2>/dev/null || printf 0)
    count=$((count + 1))
    printf '%s\n' "$count" > "$FM_FAKE_CAPTURE_COUNT"
    case "${FM_FAKE_CAPTURE_MODE:-prompt}" in
      fail) exit 7 ;;
      empty|disappear) exit 0 ;;
      late) [ "$count" -ge 2 ] && cat "${FM_FAKE_PROMPT_FILE:?}"; exit 0 ;;
      partial) sed -n '1p' "${FM_FAKE_PROMPT_FILE:?}"; exit 0 ;;
      busy) printf '• Working (1s • esc to interrupt)\n'; exit 0 ;;
      prompt|conflict) cat "${FM_FAKE_PROMPT_FILE:?}"; exit 0 ;;
    esac
    exit 0
    ;;
  send-keys)
    printf 'send-keys' >> "${FM_FAKE_KEY_LOG:?}"
    shift
    for arg in "$@"; do printf ' %s' "$arg" >> "$FM_FAKE_KEY_LOG"; done
    printf '\n' >> "$FM_FAKE_KEY_LOG"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = get ]; then
  printf '%s\n' "${FM_FAKE_TREEHOUSE_WORKTREE:?}"
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {  # <name> <id> <harness> <fixture-function>
  local name=$1 fixture_fn=$4
  CASE_ID=$2
  CASE_HARNESS=$3
  CASE_DIR="$TMP_ROOT/spawn-$name"
  CASE_HOME="$CASE_DIR/home"
  CASE_PROJECT="$CASE_DIR/project"
  CASE_WORKTREE="$CASE_DIR/worktree"
  CASE_PROMPT="$CASE_DIR/prompt.txt"
  CASE_KEYS="$CASE_DIR/keys.log"
  CASE_CAPTURE_COUNT="$CASE_DIR/capture.count"
  CASE_CREATED="$CASE_DIR/created"
  CASE_FAKEBIN=$(make_spawn_fakebin "$CASE_DIR/fake")
  mkdir -p "$CASE_HOME/data/$CASE_ID" "$CASE_HOME/state" "$CASE_HOME/config" \
    "$CASE_HOME/projects" "$CASE_HOME/treehouse-pools"
  printf '%s\n' "$CASE_HARNESS" > "$CASE_HOME/config/crew-harness"
  printf '%s\n' manual > "$CASE_HOME/config/backlog-backend"
  printf '# Backlog\n\n## In flight\n- [ ] %s - startup trust test (repo: project)\n\n## Queued\n\n## Done\n' \
    "$CASE_ID" > "$CASE_HOME/data/backlog.md"
  printf 'brief for %s\n' "$CASE_ID" > "$CASE_HOME/data/$CASE_ID/brief.md"
  fm_git_worktree "$CASE_PROJECT" "$CASE_WORKTREE" "wt-$name"
  git -C "$CASE_WORKTREE" checkout --quiet --detach HEAD
  git -C "$CASE_PROJECT" branch --quiet -D "wt-$name"
  "$fixture_fn" > "$CASE_PROMPT"
  : > "$CASE_KEYS"
  printf '0\n' > "$CASE_CAPTURE_COUNT"
  touch "$CASE_HOME/state/.last-watcher-beat"
}

run_spawn_case() {  # <capture-mode> <timeout> [endpoint-disappear]
  local mode=$1 timeout=$2 disappear=${3:-0}
  FM_ROOT_OVERRIDE='' FM_HOME="$CASE_HOME" \
    FM_STATE_OVERRIDE="$CASE_HOME/state" FM_DATA_OVERRIDE="$CASE_HOME/data" \
    FM_PROJECTS_OVERRIDE="$CASE_HOME/projects" FM_CONFIG_OVERRIDE="$CASE_HOME/config" \
    FM_TREEHOUSE_ROOT="$CASE_HOME/treehouse-pools" \
    FM_CHECKOUT_REFRESH_STATE_BASE="$CASE_HOME/checkout-refresh-state" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$CASE_WORKTREE" TMUX='fake,1,0' \
    FM_FAKE_TREEHOUSE_WORKTREE="$CASE_WORKTREE" FM_FAKE_WINDOW_LABEL="fm-$CASE_ID" \
    FM_FAKE_CREATED="$CASE_CREATED" FM_FAKE_PROMPT_FILE="$CASE_PROMPT" \
    FM_FAKE_CAPTURE_COUNT="$CASE_CAPTURE_COUNT" FM_FAKE_CAPTURE_MODE="$mode" \
    FM_FAKE_ENDPOINT_DISAPPEAR="$disappear" FM_FAKE_KEY_LOG="$CASE_KEYS" \
    FM_SPAWN_STARTUP_TEST_LAB=firstmate-spawn-startup-test-lab-v1 \
    FM_TEST_SPAWN_STARTUP_TIMEOUT="$timeout" FM_TEST_SPAWN_STARTUP_POLL_INTERVAL=0.05 \
    PATH="$CASE_FAKEBIN:$PATH" "$SPAWN" "$CASE_ID" "$CASE_PROJECT" --harness "$CASE_HARNESS" 2>&1
}

launch_enter_count() {
  grep -c ' Enter$' "$CASE_KEYS" 2>/dev/null || true
}

exercise_reported_dialog() {  # <name> <id> <harness> <fixture-function> <kind> <capture-mode>
  local name=$1 id=$2 harness=$3 fixture_fn=$4 expected_kind=$5 mode=$6 out rc heading command before after
  make_spawn_case "$name" "$id" "$harness" "$fixture_fn"
  out=$(run_spawn_case "$mode" 2)
  rc=$?
  expect_code 0 "$rc" "$name spawn"
  heading='STARTUP TRUST DIALOG'
  [ "$expected_kind" != claude-hook-trust ] || heading='STARTUP HOOK TRUST DIALOG'
  assert_contains "$out" "$heading: task=$id harness=$harness" "$name did not surface its loud startup report"
  assert_contains "$out" "kind=$expected_kind; no input was sent" "$name report omitted its exact kind or non-mutation claim"
  assert_contains "$out" "spawned $id harness=$harness" "$name changed the ordinary spawn success boundary"
  assert_not_contains "$out" 'STARTUP STATE UNKNOWN' "$name known prompt fell through to UNKNOWN"
  before=$(launch_enter_count)
  [ "$before" -eq 2 ] || fail "$name reporter sent a key: expected exactly two launch Enters, observed $before\n$(cat "$CASE_KEYS")"

  if [ "$name" = codex ]; then
    command=$(printf '%s\n' "$out" | sed -n 's/^Review the prompt and, only if you choose to trust it, run: //p' | tail -1)
    [ -n "$command" ] || fail "Codex report did not expose an executable review command"
    PATH="$CASE_FAKEBIN:$PATH" FM_FAKE_KEY_LOG="$CASE_KEYS" FM_FAKE_WINDOW_LABEL="fm-$CASE_ID" \
      FM_FAKE_CREATED="$CASE_CREATED" FM_FAKE_PANE_PATH="$CASE_WORKTREE" \
      bash -c "$command" >/dev/null 2>&1 || fail "printed Codex acceptance command did not reach fm-send"
    after=$(launch_enter_count)
    [ "$after" -eq 3 ] || fail "positive control could not observe the explicit operator Enter: before=$before after=$after"
  fi
}

test_spawn_reports_every_known_dialog_without_approval() {
  exercise_reported_dialog codex startup-codex-a1 codex fixture_codex_trust codex-directory-trust late
  [ "$(cat "$CASE_CAPTURE_COUNT")" -ge 2 ] || fail "Codex late-render fixture was not polled more than once"
  exercise_reported_dialog claude-workspace startup-claude-a2 claude fixture_claude_workspace_trust claude-workspace-trust prompt
  exercise_reported_dialog claude-hook startup-hook-a3 claude fixture_claude_hook_trust claude-hook-trust prompt
  pass "EVERY complete startup shape surfaces through real fm-spawn, no reporter sends Enter, and the printed Codex command is an observable positive control"
}

assert_spawn_unknown() {  # <name> <mode> <fixture-function> [disappear]
  local name=$1 mode=$2 fixture_fn=$3 disappear=${4:-0} out rc
  make_spawn_case "$name" "startup-unknown-$name" codex "$fixture_fn"
  out=$(run_spawn_case "$mode" 0 "$disappear")
  rc=$?
  expect_code 0 "$rc" "$name UNKNOWN spawn"
  assert_contains "$out" "STARTUP STATE UNKNOWN: task=startup-unknown-$name" "$name did not report UNKNOWN"
  assert_contains "$out" 'no input was sent' "$name UNKNOWN report omitted the non-mutation claim"
  assert_contains "$out" "spawned startup-unknown-$name harness=codex" "$name UNKNOWN changed spawn success"
  assert_not_contains "$out" 'only if you choose to trust it' "$name UNKNOWN offered an acceptance command"
  assert_present "$CASE_HOME/state/startup-unknown-$name.meta" "$name UNKNOWN rolled back the committed endpoint metadata"
  [ "$(launch_enter_count)" -eq 2 ] || fail "$name UNKNOWN path sent a post-launch key"
}

fixture_conflicting_claude_shapes() {
  cat <<'EOF'
Quick safety check: Is this a project you created or one you trust?
1. Yes, I trust this folder
2. No, exit
Hooks need review
1. Trust all on first launch
2. Review hooks
3. Exit
Enter to confirm · Esc to cancel
EOF
}

test_spawn_unknown_outcome_classes() {
  assert_spawn_unknown empty empty fixture_codex_trust
  assert_spawn_unknown capture-failure fail fixture_codex_trust
  assert_spawn_unknown partial partial fixture_codex_trust
  assert_spawn_unknown endpoint-disappeared disappear fixture_codex_trust 1
  make_spawn_case conflict startup-unknown-conflict claude fixture_conflicting_claude_shapes
  out=$(run_spawn_case conflict 0)
  rc=$?
  expect_code 0 "$rc" "conflicting-shape UNKNOWN spawn"
  assert_contains "$out" 'STARTUP STATE UNKNOWN: task=startup-unknown-conflict' "conflicting complete shapes did not report UNKNOWN"
  assert_not_contains "$out" 'only if you choose to trust it' "conflicting complete shapes offered acceptance"

  pass "spawn enumerates empty, capture-failure, partial, disappearance, and conflict outcomes without inferring absence"
}

test_spawn_positive_processing_is_quiet() {
  local out rc
  make_spawn_case processing startup-processing-b1 codex fixture_codex_trust
  out=$(run_spawn_case busy 0)
  rc=$?
  expect_code 0 "$rc" "busy processing spawn"
  assert_not_contains "$out" 'STARTUP TRUST DIALOG' "positive processing evidence still emitted a trust report"
  assert_not_contains "$out" 'STARTUP STATE UNKNOWN' "positive processing evidence emitted UNKNOWN"
  pass "positive processing evidence stays quiet"
}

make_watcher_case() {  # <name> <harness> <fixture-function>
  local name=$1 fixture_fn=$3 status_baseline turnend_baseline
  WATCH_ID="watch-$name"
  WATCH_GENERATION="generation:$name"
  WATCH_DIR="$TMP_ROOT/watcher-$name"
  WATCH_STATE="$WATCH_DIR/state"
  WATCH_CONFIG="$WATCH_DIR/config"
  WATCH_CAPTURE="$WATCH_DIR/pane.txt"
  WATCH_OUT="$WATCH_DIR/out"
  WATCH_WINDOW="test:fm-$WATCH_ID"
  WATCH_HARNESS=$2
  WATCH_FAKEBIN=$(fm_fakebin "$WATCH_DIR")
  mkdir -p "$WATCH_STATE" "$WATCH_CONFIG"
  "$fixture_fn" > "$WATCH_CAPTURE"
  touch "$WATCH_STATE/.last-report-retention" "$WATCH_STATE/.last-account-session-sync"
  status_baseline=$(watch_fixture_signature "$WATCH_STATE/$WATCH_ID.status")
  turnend_baseline=$(watch_fixture_signature "$WATCH_STATE/$WATCH_ID.turn-ended")
  fm_write_meta "$WATCH_STATE/$WATCH_ID.meta" \
    "window=$WATCH_WINDOW" "kind=ship" "harness=$WATCH_HARNESS" "generation_id=$WATCH_GENERATION" \
    "startup_status_baseline=$status_baseline" "startup_turnend_baseline=$turnend_baseline"
  cat > "$WATCH_FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) printf '%s\n' "${FM_FAKE_TMUX_WINDOW:?}"; exit 0 ;;
  capture-pane) cat "${FM_FAKE_TMUX_CAPTURE:?}"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$WATCH_FAKEBIN/tmux"
  cat > "$WATCH_FAKEBIN/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: unknown · source: none · startup trust fixture\n'
SH
  chmod +x "$WATCH_FAKEBIN/fm-crew-state.sh"
}

watch_fixture_signature() {  # <path>
  python3 - "$1" <<'PY'
import os
import sys

try:
    value = os.stat(sys.argv[1], follow_symlinks=False)
except FileNotFoundError:
    print("absent")
else:
    print(f"{value.st_size}:{value.st_mtime_ns}:{value.st_ctime_ns}")
PY
}

run_watcher_case() {  # [startup-grace]
  local grace=${1:-30}
  PATH="$WATCH_FAKEBIN:$PATH" FM_HOME="$WATCH_DIR" FM_STATE_OVERRIDE="$WATCH_STATE" \
    FM_CONFIG_OVERRIDE="$WATCH_CONFIG" FM_FAKE_TMUX_WINDOW="$WATCH_WINDOW" \
    FM_FAKE_TMUX_CAPTURE="$WATCH_CAPTURE" FM_CREW_STATE_BIN="$WATCH_FAKEBIN/fm-crew-state.sh" \
    FM_STARTUP_GRACE_SECS="$grace" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_REPORT_RETENTION_INTERVAL=999999 \
    FM_ACCOUNT_SESSION_SYNC_INTERVAL=999999 "$WATCH" > "$WATCH_OUT"
}

backdate_file() {  # <path> <seconds>
  local path=$1 seconds=$2 epoch
  epoch=$(( $(date +%s) - seconds ))
  if [ "$(uname)" = Darwin ]; then
    touch -mt "$(date -r "$epoch" '+%Y%m%d%H%M.%S')" "$path"
  else
    touch -m -d "@$epoch" "$path"
  fi
}

fixture_idle_unclassified() {
  printf 'endpoint ready, no verified harness state\n'
}

test_watcher_closes_late_render_gap_without_crossing_phase_boundary() {
  local out pid key
  make_watcher_case late-dialog codex fixture_codex_trust
  run_watcher_case 30 || fail "watcher late-dialog run failed"
  out=$(cat "$WATCH_OUT")
  assert_contains "$out" 'startup-trust-dialog detected: kind=codex-directory-trust' "watcher did not surface a recognized late startup dialog"
  assert_contains "$out" 'no input was sent' "watcher late-dialog wake omitted the non-mutation claim"
  assert_contains "$out" 'fm-send.sh' "watcher late-dialog wake omitted its exact review command"

  make_watcher_case unconfirmed codex fixture_idle_unclassified
  backdate_file "$WATCH_STATE/$WATCH_ID.meta" 10
  run_watcher_case 1 || fail "watcher startup-unconfirmed run failed"
  out=$(cat "$WATCH_OUT")
  assert_contains "$out" 'startup-unconfirmed:' "watcher did not surface startup UNKNOWN after its grace"
  assert_contains "$out" 'current-generation brief processing and a known startup dialog are both UNKNOWN' \
    "watcher overstated absent processing as never-started"
  assert_contains "$out" 'fm-peek.sh' "watcher startup UNKNOWN omitted its inspection command"
  assert_not_contains "$out" 'fm-send.sh' "watcher startup UNKNOWN offered acceptance"
  key=$(printf '%s' "$WATCH_WINDOW" | tr ':/.' '___')
  [ "$(cat "$WATCH_STATE/.stale-$key")" = "startup-unconfirmed:$WATCH_GENERATION" ] \
    || fail "watcher startup UNKNOWN did not install its generation-bound dedupe token"
  : > "$WATCH_STATE/.wake-queue"
  : > "$WATCH_OUT"
  PATH="$WATCH_FAKEBIN:$PATH" FM_HOME="$WATCH_DIR" FM_STATE_OVERRIDE="$WATCH_STATE" \
    FM_CONFIG_OVERRIDE="$WATCH_CONFIG" FM_FAKE_TMUX_WINDOW="$WATCH_WINDOW" \
    FM_FAKE_TMUX_CAPTURE="$WATCH_CAPTURE" FM_CREW_STATE_BIN="$WATCH_FAKEBIN/fm-crew-state.sh" \
    FM_STARTUP_GRACE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 FM_REPORT_RETENTION_INTERVAL=999999 FM_ACCOUNT_SESSION_SYNC_INTERVAL=999999 \
    "$WATCH" > "$WATCH_OUT" &
  pid=$!
  sleep 2
  kill -0 "$pid" 2>/dev/null || fail "generation-deduped startup UNKNOWN re-woke immediately"
  [ ! -s "$WATCH_OUT" ] || { kill "$pid" 2>/dev/null || true; fail "generation-deduped startup UNKNOWN printed another wake"; }
  [ ! -s "$WATCH_STATE/.wake-queue" ] || { kill "$pid" 2>/dev/null || true; fail "generation-deduped startup UNKNOWN queued another wake"; }
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  make_watcher_case midrun codex fixture_codex_trust
  printf '%s' "$WATCH_GENERATION" > "$WATCH_STATE/.brief-started-$WATCH_ID"
  run_watcher_case 1 || fail "watcher mid-run directory trust run failed"
  out=$(cat "$WATCH_OUT")
  assert_contains "$out" 'permission-prompt detected: waiting for a directory trust grant' \
    "current-generation directory trust did not take the protected mid-run path"
  assert_not_contains "$out" 'only if you choose to trust it' "mid-run directory trust received a startup acceptance instruction"
  assert_not_contains "$out" 'fm-send.sh' "mid-run directory trust exposed a send-key command"

  make_watcher_case fast-turn codex fixture_codex_trust
  : > "$WATCH_STATE/$WATCH_ID.turn-ended"
  run_watcher_case 1 || fail "watcher fast-turn directory trust run failed"
  out=$(cat "$WATCH_OUT")
  assert_contains "$out" 'permission-prompt detected: waiting for a directory trust grant' \
    "current-generation turn-end evidence did not close the startup marker race"
  assert_not_contains "$out" 'fm-send.sh' "fast-turn directory trust exposed a startup acceptance command"

  make_watcher_case late-hook claude fixture_claude_hook_trust
  printf '%s' "$WATCH_GENERATION" > "$WATCH_STATE/.brief-started-$WATCH_ID"
  run_watcher_case 1 || fail "watcher post-processing hook shape run failed"
  out=$(cat "$WATCH_OUT")
  assert_contains "$out" 'startup-only shape appeared after current-generation brief processing' \
    "post-processing hook shape did not report UNKNOWN"
  assert_contains "$out" 'fm-peek.sh' "post-processing hook UNKNOWN omitted inspection"
  assert_not_contains "$out" 'fm-send.sh' "post-processing hook shape exposed startup acceptance"
  pass "watcher closes late-render/unconfirmed routes, deduplicates UNKNOWN, and keeps post-processing grants out of startup acceptance"
}

case "${FM_TEST_FOCUSED:-all}" in
  all)
    test_pure_startup_classifier_distinguishes_every_shape
    test_spawn_reports_every_known_dialog_without_approval
    test_spawn_unknown_outcome_classes
    test_spawn_positive_processing_is_quiet
    test_watcher_closes_late_render_gap_without_crossing_phase_boundary
    ;;
  classifier) test_pure_startup_classifier_distinguishes_every_shape ;;
  spawn-dialogs) test_spawn_reports_every_known_dialog_without_approval ;;
  spawn-unknown) test_spawn_unknown_outcome_classes ;;
  spawn-processing) test_spawn_positive_processing_is_quiet ;;
  watcher) test_watcher_closes_late_render_gap_without_crossing_phase_boundary ;;
  *) fail "unknown FM_TEST_FOCUSED group: $FM_TEST_FOCUSED" ;;
esac
printf '# all fm-spawn startup trust tests passed\n'
