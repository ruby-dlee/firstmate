#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Tests for bounded foreground watcher checkpoints used by Codex supervision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
fm_test_tmproot_into TMP_ROOT fm-watch-checkpoint

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  # Keep this checkpoint fixture isolated from the machine-global report stack
  # and account-session reconciliation. Those slow cadences are covered by
  # their own suites; a foreground checkpoint must begin at signal polling.
  touch "$home/state/.last-report-retention" \
    "$home/state/.last-account-session-sync"
  printf '%s\n' "$home"
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" \
    "watch lock pid survived quiet checkpoint timeout: out=$(cat "$out"); err=$(cat "$err")"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_quiet_checkpoint_reclaims_forced_kill_lock() {
  local home fakebin out err status
  home=$(make_home forced-kill)
  fakebin=$(fm_fakebin "$home")
  out="$home/out.txt"
  err="$home/err.txt"
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
mkdir -p "$FM_HOME/state/.watch.lock"
printf '99999999\n' > "$FM_HOME/state/.watch.lock/pid"
exit 124
SH
  chmod +x "$fakebin/timeout"
  status=0
  PATH="$fakebin:$PATH" FM_HOME="$home" "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "forced-kill checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "forced-kill checkpoint line missing"
  assert_absent "$home/state/.watch.lock" \
    "forced-kill checkpoint left its stale watch lock: out=$(cat "$out"); err=$(cat "$err")"
  pass "quiet checkpoint reclaims a forced-kill stale watcher lock"
}

test_forced_kill_cleanup_ignores_ambient_state() {
  local home ambient fakebin out err status
  home=$(make_home forced-kill-ambient-state)
  ambient="$home/ambient-state"
  mkdir -p "$ambient/.watch.lock"
  printf 'keep\n' > "$ambient/.watch.lock/sentinel"
  fakebin=$(fm_fakebin "$home")
  out="$home/out.txt"
  err="$home/err.txt"
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
mkdir -p "$FM_HOME/state/.watch.lock"
printf '99999999\n' > "$FM_HOME/state/.watch.lock/pid"
exit 124
SH
  chmod +x "$fakebin/timeout"
  status=0
  PATH="$fakebin:$PATH" FM_HOME="$home" STATE="$ambient" "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "forced-kill checkpoint with ambient STATE exit"
  assert_absent "$home/state/.watch.lock" \
    "forced-kill cleanup targeted ambient STATE instead of FM_HOME: out=$(cat "$out"); err=$(cat "$err")"
  [ -e "$ambient/.watch.lock/sentinel" ] \
    || fail "forced-kill cleanup modified the ignored ambient STATE"
  pass "forced-kill cleanup uses the watcher's state precedence"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  # Startup and the first poll can contend with other Behavior jobs on CI; the
  # assertion is signal delivery, so give that observable path a bounded 20s.
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 20 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" \
    "signal checkpoint exit: out=$(cat "$out"); err=$(cat "$err")"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod +x "$home/state/env-check.check.sh"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for the foreground fm-watch.sh"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

test_quiet_checkpoint_exits_124_cleanly
test_quiet_checkpoint_reclaims_forced_kill_lock
test_forced_kill_cleanup_ignores_ambient_state
test_signal_passes_through_and_exits_zero
test_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
