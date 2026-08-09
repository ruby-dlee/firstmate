#!/usr/bin/env bash
# tests/fm-watcher-lock.test.sh - watcher singleton + lock-primitive races +
# PID identity stability + watch-arm liveness + guard warnings. These are
# safety-critical process invariants (a race bug may not reproduce through an
# e2e), so they stay as focused real-process units.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"

fm_test_tmproot_into TMP_ROOT fm-watcher-lock-tests


test_singleton_start() {
  local dir state fakebin out1 out2 pid1 pid2 live i
  dir=$(make_case singleton)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out1="$dir/watch-one.out"
  out2="$dir/watch-two.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out1" &
  pid1=$!
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out2" &
  pid2=$!
  i=0
  while [ "$i" -lt 50 ]; do
    live=0
    is_live_non_zombie "$pid1" && live=$((live + 1))
    is_live_non_zombie "$pid2" && live=$((live + 1))
    [ "$live" -eq 1 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$live" -eq 1 ] || fail "expected exactly one live watcher, got $live"
  grep -h 'watcher: already running pid ' "$out1" "$out2" >/dev/null || fail "second watcher did not report existing singleton"
  kill "$pid1" "$pid2" 2>/dev/null || true
  wait "$pid1" 2>/dev/null || true
  wait "$pid2" 2>/dev/null || true
  pass "simultaneous watcher starts leave exactly one live process"
}

test_stale_watch_lock_reclaimed() {
  local dir state fakebin out dead_pid pid live lock_pid i
  dir=$(make_case stale-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  dead_pid=999999
  while kill -0 "$dead_pid" 2>/dev/null; do
    dead_pid=$((dead_pid + 1))
  done
  mkdir "$state/.watch.lock"
  printf '%s\n' "$dead_pid" > "$state/.watch.lock/pid"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  live=0
  lock_pid=
  while [ "$i" -lt 50 ]; do
    live=0
    is_live_non_zombie "$pid" && live=1
    lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    [ "$live" -eq 1 ] && [ "$lock_pid" != "$dead_pid" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$live" -eq 1 ] || fail "watcher did not reclaim stale lock and stay alive"
  [ "$lock_pid" != "$dead_pid" ] || fail "stale watch lock pid was not replaced"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "killed watcher stale lock is reclaimed"
}

test_live_stale_watch_lock_is_actionable() {
  local dir state fakebin out err status
  dir=$(make_case live-stale-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  err="$dir/watch.err"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  touch -t 200001010000 "$state/.last-watcher-beat"
  status=0
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2> "$err" || status=$?
  [ "$status" -ne 0 ] || fail "watcher silently no-opped behind a live stale holder"
  grep -F 'heartbeat is stale' "$err" >/dev/null || fail "watcher did not explain the stale live lock"
  pass "live watcher lock with stale heartbeat is actionable"
}

test_guard_warnings() {
  # The guard's two operator-visible states, with resilient substrings instead of
  # four copy-coupled tests:
  #   (1) watcher DOWN + queued wakes: a prominent no-watcher banner leads (alarm
  #       title, in-flight count, beacon age, fix command), the queued-wakes
  #       warning follows it, and the guidance is re-arm-after-drain (never the
  #       old conflicting "restart NOW first").
  #   (2) a fresh watcher and an empty queue: total silence.
  local dir state err first banner_line queue_line
  dir=$(make_case guard)
  state="$dir/state"
  err="$dir/guard.err"

  # (1) watcher down (no beacon) + two in-flight tasks + a queued wake.
  # FM_ROOT_OVERRIDE points the worktree-tangle check at a non-git dir so it stays
  # inert here; this case is about the watcher-down banner, not the tangle guard.
  printf 'project=x\n' > "$state/task.meta"
  printf 'project=y\n' > "$state/task2.meta"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "guard heartbeat append failed"
  FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  first=$(grep -v '^[[:space:]]*$' "$err" | head -1)
  case "$first" in
    '●'*) ;;
    *) fail "no-watcher banner is not the first thing the guard prints (got '$first')" ;;
  esac
  grep -F 'WATCHER DOWN - SUPERVISION IS OFF' "$err" >/dev/null || fail "guard banner missing the alarm title"
  grep -F '2 task(s) in flight' "$err" >/dev/null || fail "guard banner missing the in-flight count"
  grep -F 'last beat: never' "$err" >/dev/null || fail "guard banner missing the beacon age"
  grep -F 'guarded operation WILL still run' "$err" >/dev/null || fail "guard banner missing generic continuation wording"
  ! grep -F 'requested message WILL still be sent' "$err" >/dev/null || fail "shared guard used send-specific continuation wording"
  grep -F 'resume supervision' "$err" >/dev/null || fail "guard banner missing the harness-aware fix command"
  grep -F 'queued wakes pending - drain them' "$err" >/dev/null || fail "guard did not warn about pending queue"
  grep -F 'After draining queued wakes, resume supervision' "$err" >/dev/null || fail "guard did not order supervision repair after drain"
  ! grep -F 'Restart it NOW, before anything else' "$err" >/dev/null || fail "guard still gave conflicting restart-first instruction"
  ! grep -F 'as the harness-tracked background task' "$err" >/dev/null || fail "guard still printed the old universal background-task repair text"
  banner_line=$(grep -n 'WATCHER DOWN' "$err" | head -1 | cut -d: -f1)
  queue_line=$(grep -n 'queued wakes pending - drain them' "$err" | head -1 | cut -d: -f1)
  [ "$banner_line" -lt "$queue_line" ] || fail "queued-wakes warning printed before the no-watcher banner"

  dir=$(make_case guard-xmode)
  state="$dir/state"
  err="$dir/guard.err"
  mkdir -p "$dir/config"
  printf 'project=x\n' > "$state/task.meta"
  : > "$dir/config/x-mode.env"
  FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  grep -F "source '$dir/config/x-mode.env' first" "$err" >/dev/null || fail "guard repair line did not source the X-mode cadence config"

  # (2) fresh watcher, empty queue -> silence.
  dir=$(make_case guard-fresh)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'project=x\n' > "$state/task.meta"
  touch "$state/.last-watcher-beat"
  # Non-git FM_ROOT keeps the worktree-tangle check inert so "fresh watcher ->
  # total silence" stays a pure assertion about watcher state.
  FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  [ ! -s "$err" ] || fail "guard warned with a fresh watcher and no queued wakes: $(cat "$err")"
  pass "guard banner leads when down with pending wakes (re-arm-after-drain) and stays silent when fresh"
}

test_guard_detects_live_watcher_that_missed_cadence() {
  local dir state err sleeper identity
  dir=$(make_case guard-missed-cadence)
  state="$dir/state"
  err="$dir/guard.err"
  sleep 60 &
  sleeper=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$sleeper") \
    || fail "could not identify cadence-stale guard fixture"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$sleeper" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  printf 'project=x\n' > "$state/task.meta"
  mkdir -p "$dir/config"
  printf 'FM_WATCH_PROGRESS_GRACE=60\n' > "$dir/config/watcher.env"
  touch "$state/.last-watcher-beat"
  perl -e '$time = time - 120; utime $time, $time, $ARGV[0]' "$state/.last-watcher-beat"
  FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_GUARD_GRACE=300 \
    "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "cadence-stale guard failed"
  kill "$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true
  grep -qF 'WATCHER WEDGED - LIVE SUPERVISION MISSED ITS CADENCE' "$err" \
    || fail "guard stayed silent for a live watcher with a 120-second-old beacon: $(cat "$err")"
  grep -qF 'bin/fm-watch-arm.sh --restart' "$err" || fail "cadence-stale guard omitted supported recovery"
  ! grep -qF 'WATCHER DOWN - SUPERVISION IS OFF' "$err" \
    || fail "guard misreported the live cadence wedge as an absent watcher"
  pass "guard makes a live watcher loud when it misses cadence before broad stale grace"
}

test_guard_accepts_identity_matched_active_phase() {
  local dir state err sleeper identity deadline
  dir=$(make_case guard-active-phase)
  state="$dir/state"
  err="$dir/guard.err"
  sleep 60 &
  sleeper=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$sleeper") \
    || fail "could not identify active-phase guard fixture"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$sleeper" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  printf 'project=x\n' > "$state/task.meta"
  touch "$state/.last-watcher-beat"
  perl -e '$time = time - 120; utime $time, $time, $ARGV[0]' "$state/.last-watcher-beat"
  deadline=$(( $(date +%s) + 60 ))
  {
    printf 'pid=%s\n' "$sleeper"
    printf 'phase=task-check\n'
    printf 'deadline=%s\n' "$deadline"
    printf 'pid-identity=%s\n' "$identity"
  } > "$state/.watch.phase"
  FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_GUARD_GRACE=1 FM_WATCH_PROGRESS_GRACE=1 \
    "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "active-phase guard failed"
  kill "$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true
  [ ! -s "$err" ] || fail "guard warned during an identity-matched active phase: $(cat "$err")"
  pass "guard treats an identity-matched bounded phase as current progress"
}

test_guard_detects_hot_recorded_watcher_tree() {
  local dir state err hot identity i
  dir=$(make_case guard-hot-tree)
  state="$dir/state"
  err="$dir/guard.err"
  bash -c 'while :; do :; done' &
  hot=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$hot") \
    || fail "could not identify hot guard fixture"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$hot" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  printf 'project=x\n' > "$state/task.meta"
  touch "$state/.last-watcher-beat"
  i=0
  while [ "$i" -lt 30 ]; do
    FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_WATCH_CPU_LIMIT=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "hot-tree guard failed"
    grep -qF 'WATCHER RUNAWAY - SUPERVISION IS CONSUMING A CORE' "$err" && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'WATCHER RUNAWAY - SUPERVISION IS CONSUMING A CORE' "$err" \
    || fail "guard stayed silent for a fresh-beacon watcher consuming a core: $(cat "$err")"
  grep -qF 'bin/fm-watch-arm.sh --restart' "$err" || fail "hot-tree guard omitted the supported recovery command"
  kill -KILL "$hot" 2>/dev/null || true
  wait "$hot" 2>/dev/null || true
  pass "guard makes a fresh-beacon watcher consuming a core loud"
}

test_lock_single_winner_under_concurrency() {
  local dir state lockdir marker i pids pid wins
  dir=$(make_case lock-concurrency)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  marker="$dir/wins"
  : > "$marker"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then
        printf "%s\n" "$$" >> "$3"
        # Stay alive so the held lock names a live pid for the whole window;
        # otherwise a late contender could legitimately reclaim a dead-pid lock.
        sleep 1
      fi
    ' _ "$LIB" "$lockdir" "$marker" &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  wins=$(awk 'NF { c++ } END { print c + 0 }' "$marker")
  [ "$wins" -eq 1 ] || fail "expected exactly one lock winner under concurrency, got $wins"
  pass "concurrent fm_lock_try_acquire yields exactly one winner"
}

test_lock_steals_dead_pid_lock() {
  local dir state lockdir dead rc newpid
  dir=$(make_case lock-dead-steal)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  rc=0
  newpid=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then cat "$2/pid"; else exit 7; fi
  ' _ "$LIB" "$lockdir") || rc=$?
  [ "$rc" -eq 0 ] || fail "acquirer failed to steal a dead-pid stale lock (rc=$rc)"
  [ "$newpid" != "$dead" ] || fail "stale dead-pid lock was not replaced (still $dead)"
  [ -n "$newpid" ] || fail "reclaimed lock has no pid recorded"
  pass "dead-pid stale lock is reclaimed by a single acquirer"
}

test_lock_stale_steal_single_winner_under_concurrency() {
  local dir state lockdir dead marker i pids pid wins
  dir=$(make_case lock-stale-concurrency)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  marker="$dir/wins"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  : > "$marker"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then
        printf "%s\n" "${BASHPID:-$$}" >> "$3"
        sleep 1
      fi
    ' _ "$LIB" "$lockdir" "$marker" &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  wins=$(awk 'NF { c++ } END { print c + 0 }' "$marker")
  [ "$wins" -eq 1 ] || fail "expected exactly one stale-lock stealer, got $wins"
  pass "concurrent stale-lock steal yields exactly one winner"
}

test_lock_stale_steal_chain_is_bounded() {
  local dir state lockdir dead rc suffix i
  dir=$(make_case lock-stale-steal-chain)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  dead=$(dead_pid)
  mkdir "$lockdir" "$lockdir.steal"
  printf '%s\n' "$dead" > "$lockdir/pid"
  printf '%s\n' "$dead" > "$lockdir.steal/pid"
  rc=0
  FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2"
  ' _ "$LIB" "$lockdir" || rc=$?
  [ "$rc" -eq 0 ] || fail "acquirer failed to recover a stale steal mutex (rc=$rc)"

  lockdir="$state/.bounded.lock"
  suffix=
  i=0
  while [ "$i" -le 9 ]; do
    mkdir "$lockdir$suffix"
    printf '%s\n' "$dead" > "$lockdir$suffix/pid"
    suffix="$suffix.steal"
    i=$((i + 1))
  done
  rc=0
  FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2"
  ' _ "$LIB" "$lockdir" || rc=$?
  [ "$rc" -ne 0 ] || fail "an excessive stale steal chain was recursively reclaimed"
  [ ! -e "$lockdir$suffix" ] && [ ! -L "$lockdir$suffix" ] || fail "stale steal recovery grew beyond its bounded guard depth"
  pass "stale steal mutex recovery is bounded"
}

test_lock_live_steal_mutex_is_not_reclaimed() {
  local dir state lockdir dead holder_file holder out i lockpid stealpid
  dir=$(make_case lock-live-stealer)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  holder_file="$dir/holder"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2.steal" || exit 7
    printf "%s\n" "${BASHPID:-$$}" > "$3"
    sleep 2
    fm_lock_release "$2.steal"
  ' _ "$LIB" "$lockdir" "$holder_file" &
  holder=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -s "$holder_file" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$holder_file" ] || fail "live steal mutex holder did not start"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s lockpid=%s stealpid=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}" "$(cat "$2/pid" 2>/dev/null || true)" "$(cat "$2.steal/pid" 2>/dev/null || true)"
  ' _ "$LIB" "$lockdir")
  wait "$holder" || fail "live steal mutex holder failed"
  case "$out" in
    *"rc=1"*) ;;
    *) fail "stale lock was stolen while a live stealer held the mutex: $out" ;;
  esac
  lockpid=${out#*lockpid=}; lockpid=${lockpid%% *}
  stealpid=${out#*stealpid=}; stealpid=${stealpid%% *}
  [ "$lockpid" = "$dead" ] || fail "primary lock changed while live steal mutex was held: $out"
  [ "$stealpid" = "$(cat "$holder_file")" ] || fail "live steal mutex owner changed: $out"
  pass "live steal mutex is not reclaimed"
}

test_lock_does_not_steal_live_lock() {
  local dir state lockdir live out lockpid
  dir=$(make_case lock-live-noop)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  sleep 300 &
  live=$!
  mkdir "$lockdir"
  printf '%s\n' "$live" > "$lockdir/pid"
  out=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}"
  ' _ "$LIB" "$lockdir")
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  case "$out" in
    *"rc=1"*) ;;
    *) fail "live-held lock was acquired instead of refused: $out" ;;
  esac
  case "$out" in
    *"held=$live"*) ;;
    *) fail "live holder pid not reported via FM_LOCK_HELD_PID: $out" ;;
  esac
  lockpid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$lockpid" = "$live" ] || fail "live holder's lock pid was clobbered (got '$lockpid')"
  pass "live-held lock is not stolen"
}

test_lock_empty_pid_uses_minimum_grace() {
  local dir state lockdir out
  dir=$(make_case lock-empty-grace)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  mkdir "$lockdir"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"rc=1"*) ;;
    *) fail "empty mid-acquire lock was stolen with zero stale threshold: $out" ;;
  esac
  [ -d "$lockdir" ] || fail "empty mid-acquire lock dir was removed during grace"
  [ ! -e "$lockdir/pid" ] || fail "empty mid-acquire lock gained a pid during grace"
  pass "empty mid-acquire lock keeps a minimum grace"
}

test_lock_late_claim_loses_after_recreate() {
  local dir state lockdir out
  dir=$(make_case lock-late-claim)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    owner1=$(fm_lock_owner_dir "$2") || exit 20
    ln -s "$owner1" "$2" || exit 21
    touch -h -t 200001010000 "$2" 2>/dev/null || sleep 2
    if ! fm_lock_try_acquire "$2"; then exit 22; fi
    before=$(cat "$2/pid" 2>/dev/null || true)
    if fm_lock_claim "$2" "$owner1"; then late=won; else late=lost; fi
    after=$(cat "$2/pid" 2>/dev/null || true)
    current_owner=$(readlink "$2" 2>/dev/null || true)
    printf "late=%s before=%s after=%s owner_changed=%s\n" "$late" "$before" "$after" "$([ "$current_owner" != "$owner1" ] && echo yes || echo no)"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"late=lost"*) ;;
    *) fail "late original claimant succeeded after lock recreation: $out" ;;
  esac
  case "$out" in
    *"owner_changed=yes"*) ;;
    *) fail "stale owner was not replaced before late claim: $out" ;;
  esac
  before=${out#*before=}; before=${before%% *}
  after=${out#*after=}; after=${after%% *}
  [ -n "$before" ] || fail "recreated lock did not record a pid: $out"
  [ "$before" = "$after" ] || fail "late claim changed the recreated lock pid: $out"
  pass "late original claimant cannot claim a recreated lock"
}

test_lock_paused_mid_acquire_claim_fails_during_steal() {
  local dir state lockdir out pid
  dir=$(make_case lock-paused-claim-steal)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    owner=$(fm_lock_owner_dir "$2") || exit 20
    ln -s "$owner" "$2" || exit 21
    fm_lock_try_acquire "$2.steal" || exit 22
    steal_owner=${FM_LOCK_OWNER_DIR:-}
    if fm_lock_claim "$2" "$owner"; then late=won; else late=lost; fi
    if fm_lock_try_create "$2" "$steal_owner"; then stealer=won; else stealer=lost; fi
    pid=$(cat "$2/pid" 2>/dev/null || true)
    printf "late=%s stealer=%s pid=%s\n" "$late" "$stealer" "$pid"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"late=lost"*) ;;
    *) fail "paused claimant succeeded while steal mutex was held: $out" ;;
  esac
  case "$out" in
    *"stealer=won"*) ;;
    *) fail "stealer could not claim after paused claimant backed off: $out" ;;
  esac
  pid=${out#*pid=}; pid=${pid%% *}
  [ -n "$pid" ] || fail "stealer claim did not record a pid: $out"
  pass "paused mid-acquire claimant backs off to active stealer"
}

test_pid_tree_stop_refuses_mismatched_root_identity() {
  local dir state live identity
  dir=$(make_case tree-stop-reused-root)
  state="$dir/state"
  sleep 60 &
  live=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live") \
    || fail "could not identify tree-stop reuse fixture"
  if FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_tree_stop "$2" 1 "$3"' \
    _ "$LIB" "$live" "not-$identity"; then
    fail "tree stop accepted a mismatched expected identity"
  fi
  is_live_non_zombie "$live" || fail "tree stop signalled a live pid whose identity did not match the recorded root"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "exact-tree stop refuses a root whose pid identity was reused"
}

test_watch_restart_rejects_reused_pid() {
  local dir state fakebin out live pid i lock_pid
  dir=$(make_case restart-reused-pid)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  sleep 300 &
  live=$!
  mkdir "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "stale watcher identity" > "$state/.watch.lock/pid-identity"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" --restart > "$out" &
  pid=$!
  # The honest arm forks the fresh watcher as a tracked child and waits on it, so
  # the lock now names that child, not the arm invocation. The property is the
  # same: the stale reused-pid lock is replaced by a genuinely live watcher, which
  # the arm confirms before reporting it. Wait for that confirmation, not just for
  # the lock pid to appear (identity and beacon land a beat later).
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  { [ -n "$lock_pid" ] && [ "$lock_pid" != "$live" ] && kill -0 "$lock_pid" 2>/dev/null; } \
    || fail "restart did not replace stale reused-pid lock with a live watcher (got '$lock_pid')"
  grep -F "watcher: started pid=$lock_pid" "$out" >/dev/null || fail "restart did not report the fresh watcher it confirmed"
  is_live_non_zombie "$live" || fail "restart killed a reused unrelated pid"
  kill "$pid" "$lock_pid" "$live" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "watch restart refuses to signal a reused pid"
}

test_watch_restart_reaps_term_resistant_owned_tree() {
  local dir state fakebin out peer_file peer child_file child identity armpid i lock_pid root_live child_live root_state root_cpu
  dir=$(make_case restart-term-resistant-tree)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  peer_file="$dir/peer.pid"
  child_file="$dir/child.pid"
  node -e '
    const fs = require("fs");
    const { spawn } = require("child_process");
    const rootProgram = `
      const fs = require("fs");
      const { spawn } = require("child_process");
      const child = spawn(process.execPath, ["-e", "process.on(\\"SIGTERM\\",()=>{});setTimeout(()=>{},300000)"], { stdio: "ignore" });
      fs.writeFileSync(process.argv[1], String(child.pid));
      process.on("SIGTERM", () => {});
      setTimeout(() => {}, 300000);
    `;
    const root = spawn(process.execPath, ["-e", rootProgram, process.argv[2]], { detached: true, stdio: "ignore" });
    fs.writeFileSync(process.argv[1], String(root.pid));
    root.unref();
  ' "$peer_file" "$child_file"
  peer=$(cat "$peer_file")
  i=0
  while [ "$i" -lt 80 ] && [ ! -s "$child_file" ]; do sleep 0.1; i=$((i + 1)); done
  if [ ! -s "$child_file" ]; then
    kill -KILL "$peer" 2>/dev/null || true
    fail "TERM-resistant watcher-tree fixture did not start its child"
  fi
  child=$(cat "$child_file")
  i=0
  root_state=
  root_cpu=100
  while [ "$i" -lt 50 ]; do
    read -r root_state root_cpu <<EOF
$(LC_ALL=C ps -p "$peer" -o state=,%cpu= 2>/dev/null | awk 'NR == 1 { print $1, $2 }')
EOF
    case "$root_state" in
      S*) awk -v cpu="$root_cpu" 'BEGIN { exit !(cpu < 1.0) }' && break ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  case "$root_state" in
    S*) ;;
    *)
      kill -KILL "$peer" "$child" 2>/dev/null || true
      fail "watcher-tree root was not sleeping before restart (state $root_state)"
      ;;
  esac
  awk -v cpu="$root_cpu" 'BEGIN { exit !(cpu < 1.0) }' || {
    kill -KILL "$peer" "$child" 2>/dev/null || true
    fail "watcher-tree root was not near-zero CPU before restart (${root_cpu}%)"
  }
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || {
    kill -KILL "$peer" "$child" 2>/dev/null || true
    fail "could not identify owned restart root"
  }
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch -t 200001010000 "$state/.last-watcher-beat"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" --restart > "$out" &
  armpid=$!
  i=0
  while [ "$i" -lt 150 ]; do
    grep -qF 'watcher: started pid=' "$out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  if ! grep -qF 'watcher: started pid=' "$out"; then
    kill -KILL "$armpid" "$peer" "$child" 2>/dev/null || true
    wait "$armpid" 2>/dev/null || true
    fail "restart did not replace the wedged watcher tree: $(cat "$out")"
  fi
  root_live=0
  child_live=0
  is_live_non_zombie "$peer" && root_live=1
  is_live_non_zombie "$child" && child_live=1
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  if [ "$root_live" -eq 1 ] || [ "$child_live" -eq 1 ]; then
    kill -KILL "$peer" "$child" 2>/dev/null || true
  fi
  kill -TERM "$armpid" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  [ "$root_live" -eq 0 ] || fail "restart left the TERM-resistant recorded watcher root alive"
  [ "$child_live" -eq 0 ] || fail "restart left a TERM-resistant recorded watcher descendant alive"
  [ -n "$lock_pid" ] && [ "$lock_pid" != "$peer" ] || fail "restart did not install a fresh watcher lock"
  pass "watch restart migrates a pre-session watcher through identity-pinned tree cleanup"
}

test_watch_restart_recovers_dead_session_leader() {
  local dir state fakebin out peer_file child_file peer child identity anchor_identity armpid i lock_pid members
  dir=$(make_case restart-dead-session-leader)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  peer_file="$dir/peer.pid"
  child_file="$dir/child.pid"
  node -e '
    const fs = require("fs");
    const { spawn } = require("child_process");
    const rootProgram = `
      const fs = require("fs");
      const { spawn } = require("child_process");
      const child = spawn(process.execPath, ["-e", "process.on(\\"SIGTERM\\",()=>{});setTimeout(()=>{},300000)"], { stdio: "ignore" });
      fs.writeFileSync(process.argv[1], String(child.pid));
      setTimeout(() => {}, 300000);
    `;
    const root = spawn(process.execPath, ["-e", rootProgram, process.argv[2]], { detached: true, stdio: "ignore" });
    fs.writeFileSync(process.argv[1], String(root.pid));
    root.unref();
  ' "$peer_file" "$child_file"
  peer=$(cat "$peer_file")
  i=0
  while [ "$i" -lt 80 ] && [ ! -s "$child_file" ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$child_file" ] || { kill -KILL "$peer" 2>/dev/null || true; fail "dead-leader fixture did not start"; }
  child=$(cat "$child_file")
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || {
    kill -KILL "$peer" "$child" 2>/dev/null || true
    fail "could not identify dead-leader fixture"
  }
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  printf '%s\n' "$peer" > "$state/.watch.lock/process-session"
  anchor_identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$child") || {
    kill -KILL "$peer" "$child" 2>/dev/null || true
    fail "could not identify dead-leader session anchor"
  }
  printf '%s\n' "$child" > "$state/.watch.lock/session-anchor-pid"
  printf '%s\n' "$anchor_identity" > "$state/.watch.lock/session-anchor-identity"
  kill -KILL "$peer" 2>/dev/null || true
  i=0
  while [ "$i" -lt 50 ] && is_live_non_zombie "$peer"; do sleep 0.1; i=$((i + 1)); done
  ! is_live_non_zombie "$peer" || { kill -KILL "$child" 2>/dev/null || true; fail "session leader did not die"; }
  is_live_non_zombie "$child" || fail "dead-leader fixture lost its surviving session child"
  [ "$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_session "$2"' _ "$LIB" "$child")" = "$peer" ] || {
    kill -KILL "$child" 2>/dev/null || true
    fail "surviving child left the recorded session"
  }
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" --restart > "$out" &
  armpid=$!
  i=0
  while [ "$i" -lt 150 ]; do
    grep -qF 'watcher: started pid=' "$out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$out" || {
    kill -KILL "$armpid" "$child" 2>/dev/null || true
    wait "$armpid" 2>/dev/null || true
    fail "restart did not recover the dead session leader: $(cat "$out")"
  }
  ! is_live_non_zombie "$child" || { kill -KILL "$child" 2>/dev/null || true; fail "restart left the dead leader's session child alive"; }
  members=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_session_snapshot "$2"' _ "$LIB" "$peer") \
    || fail "could not verify the drained dead-leader session"
  [ -z "$members" ] || fail "restart left recorded session members: $members"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$lock_pid" ] && [ "$lock_pid" != "$peer" ] || fail "restart did not replace the dead leader lock"
  kill -TERM "$armpid" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  pass "watch restart drains a verified session after its leader dies"
}

test_arm_owner_death_reaps_watcher_session() {
  local dir state fakebin out armpid watcher_pid session i members state_snapshot
  dir=$(make_case arm-owner-death)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/arm.out"
  touch "$state/.last-check"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 FM_WATCH_CPU_LIMIT=999 "$WATCH_ARM" > "$out" &
  armpid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    session=$(cat "$state/.watch.lock/process-session" 2>/dev/null || true)
    grep -qF 'watcher: started pid=' "$out" 2>/dev/null \
      && [ -n "$watcher_pid" ] && [ "$session" = "$watcher_pid" ] && break
    is_live_non_zombie "$armpid" || break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$out" || fail "arm did not establish its watcher before owner-death test: $(cat "$out")"
  kill -KILL "$armpid" 2>/dev/null || fail "could not kill the tracked arm"
  wait "$armpid" 2>/dev/null || true
  i=0
  while [ "$i" -lt 120 ]; do
    members=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_session_snapshot "$2"' _ "$LIB" "$session" 2>/dev/null || true)
    [ -z "$members" ] && [ ! -e "$state/.watch.lock" ] && [ ! -L "$state/.watch.lock" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ -z "$members" ] || { for watcher_pid in $members; do kill -KILL "$watcher_pid" 2>/dev/null || true; done; fail "arm death left watcher session members: $members"; }
  if [ -e "$state/.watch.lock" ] || [ -L "$state/.watch.lock" ]; then
    state_snapshot=$(find "$state" -maxdepth 3 -print 2>/dev/null | sort)
    fail "arm death left the watcher lock behind: $state_snapshot"
  fi
  pass "arm controller death closes ownership and reaps the watcher session"
}

test_arm_owner_death_before_monitor_start_reaps_session() {
  local dir state fakebin out ready proceed armpid watcher_pid session i members
  dir=$(make_case arm-owner-preconnect)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/arm.out"
  ready="$dir/monitor.ready"
  proceed="$dir/monitor.proceed"
  touch "$state/.last-check"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 FM_WATCH_CPU_LIMIT=999 \
    FM_WATCH_OWNER_TEST_HOOKS=firstmate-watcher-owner-tests-v1 \
    FM_WATCH_OWNER_TEST_READY="$ready" FM_WATCH_OWNER_TEST_PROCEED="$proceed" \
    "$WATCH_ARM" > "$out" &
  armpid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    session=$(cat "$state/.watch.lock/process-session" 2>/dev/null || true)
    [ -e "$ready" ] && [ -n "$watcher_pid" ] && [ "$session" = "$watcher_pid" ] && break
    is_live_non_zombie "$armpid" || break
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$ready" ] || fail "watcher did not pause before ownership monitor startup: $(cat "$out")"
  kill -KILL "$armpid" 2>/dev/null || fail "could not kill arm before ownership monitor startup"
  wait "$armpid" 2>/dev/null || true
  touch "$proceed"
  i=0
  while [ "$i" -lt 120 ]; do
    members=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_session_snapshot "$2"' _ "$LIB" "$session" 2>/dev/null || true)
    [ -z "$members" ] && [ ! -e "$state/.watch.lock" ] && [ ! -L "$state/.watch.lock" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ -z "$members" ] || { for watcher_pid in $members; do kill -KILL "$watcher_pid" 2>/dev/null || true; done; fail "pre-monitor arm death left watcher session members: $members"; }
  [ ! -e "$state/.watch.lock" ] && [ ! -L "$state/.watch.lock" ] \
    || fail "pre-monitor arm death left the watcher lock behind"
  pass "inherited ownership channel observes arm death before monitor startup"
}

test_session_cleanup_requires_stable_quiescence() {
  local dir state root_file anchor_file late_file armed ready proceed fork_now result_file root anchor late cleanup i identity
  dir=$(make_case session-stable-quiescence)
  state="$dir/state"
  root_file="$dir/root.pid"
  anchor_file="$dir/anchor.pid"
  late_file="$dir/late.pid"
  armed="$dir/snapshot.armed"
  ready="$dir/snapshot.ready"
  proceed="$dir/snapshot.proceed"
  fork_now="$dir/fork.now"
  result_file="$dir/cleanup.status"
  node -e '
    const fs = require("fs");
    const { spawn } = require("child_process");
    const rootProgram = `
      const fs = require("fs");
      const { spawn } = require("child_process");
      const anchor = spawn(process.execPath, ["-e", "process.on(\\"SIGTERM\\",()=>{});setTimeout(()=>{},300000)"], { stdio: "ignore" });
      fs.writeFileSync(process.argv[1], String(anchor.pid));
      process.on("SIGTERM", () => {
        fs.writeFileSync(process.argv[2], "ready");
        const timer = setInterval(() => {
          if (!fs.existsSync(process.argv[3])) return;
          clearInterval(timer);
          const late = spawn(process.execPath, ["-e", "process.on(\\"SIGTERM\\",()=>{});setTimeout(()=>{},300000)"], { stdio: "ignore" });
          fs.writeFileSync(process.argv[4], String(late.pid));
          process.exit(0);
        }, 5);
      });
      setTimeout(() => {}, 300000);
    `;
    const root = spawn(process.execPath, ["-e", rootProgram, process.argv[2], process.argv[3], process.argv[4], process.argv[5]], { detached: true, stdio: "ignore" });
    fs.writeFileSync(process.argv[1], String(root.pid));
    root.unref();
  ' "$root_file" "$anchor_file" "$armed" "$fork_now" "$late_file"
  root=$(cat "$root_file")
  i=0
  while [ "$i" -lt 80 ] && [ ! -s "$anchor_file" ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$anchor_file" ] || { kill -KILL "$root" 2>/dev/null || true; fail "stable-quiescence fixture did not start its anchor"; }
  anchor=$(cat "$anchor_file")
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$anchor") \
    || { kill -KILL "$root" "$anchor" 2>/dev/null || true; fail "could not identify stable-quiescence anchor"; }
  FM_STATE_OVERRIDE="$state" FM_SESSION_SNAPSHOT_TEST_HOOKS=firstmate-session-snapshot-tests-v1 \
    FM_SESSION_SNAPSHOT_TEST_ARMED="$armed" FM_SESSION_SNAPSHOT_TEST_READY="$ready" \
    FM_SESSION_SNAPSHOT_TEST_PROCEED="$proceed" bash -c \
    '. "$1"; status=0; fm_session_stop_owned_except "$2" "$3" 5 || status=$?; printf "%s\n" "$status" > "$4"' \
    _ "$LIB" "$root" "$anchor" "$result_file" &
  cleanup=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -e "$ready" ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$ready" ] || { kill -KILL "$cleanup" "$root" "$anchor" 2>/dev/null || true; fail "session snapshot did not reach its deterministic race barrier"; }
  touch "$fork_now"
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$late_file" ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$late_file" ] || { kill -KILL "$cleanup" "$root" "$anchor" 2>/dev/null || true; fail "TERM trap did not spawn its late session child"; }
  late=$(cat "$late_file")
  touch "$proceed"
  wait "$cleanup" 2>/dev/null || true
  [ "$(cat "$result_file" 2>/dev/null || true)" = 0 ] || { kill -KILL "$anchor" "$late" 2>/dev/null || true; fail "session cleanup did not establish stable quiescence"; }
  ! is_live_non_zombie "$late" || { kill -KILL "$late" 2>/dev/null || true; fail "session cleanup missed the child created after its first empty snapshot"; }
  is_live_non_zombie "$anchor" || fail "session cleanup killed its identity-pinned anchor"
  [ "$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$anchor")" = "$identity" ] \
    || fail "session cleanup changed its identity-pinned anchor"
  kill -KILL "$anchor" 2>/dev/null || true
  pass "session cleanup requires stable quiescence across consecutive snapshots"
}

test_watch_restart_refuses_reused_session_without_anchor() {
  local dir state fakebin out peer_file peer current_identity status
  dir=$(make_case restart-reused-session)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  peer_file="$dir/peer.pid"
  node -e '
    const fs = require("fs");
    const { spawn } = require("child_process");
    const peer = spawn(process.execPath, ["-e", `process.on("SIGTERM",()=>{});setTimeout(()=>{},300000)`], { detached: true, stdio: "ignore" });
    fs.writeFileSync(process.argv[1], String(peer.pid));
    peer.unref();
  ' "$peer_file"
  peer=$(cat "$peer_file")
  current_identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") \
    || { kill -KILL "$peer" 2>/dev/null || true; fail "could not identify reused-session fixture"; }
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "stale-$current_identity" > "$state/.watch.lock/pid-identity"
  printf '%s\n' "$peer" > "$state/.watch.lock/process-session"
  status=0
  PATH="$fakebin:$PATH" FM_HOME="$dir" "$WATCH_ARM" --restart > "$out" 2>&1 || status=$?
  [ "$status" -ne 0 ] || { kill -KILL "$peer" 2>/dev/null || true; fail "restart accepted a reused session without a live identity anchor"; }
  is_live_non_zombie "$peer" || fail "restart signalled an unrelated reused session"
  kill -KILL "$peer" 2>/dev/null || true
  pass "restart refuses reused sessions without a live identity anchor"
}

test_normal_session_watcher_releases_guard() {
  local dir state fakebin out watcher_pid i
  dir=$(make_case normal-session-release)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  touch "$state/.last-check" "$state/.last-account-session-sync" "$state/.last-report-retention"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_WATCHER_OWN_SESSION=1 FM_POLL=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 perl -MPOSIX -e '
      my $session = POSIX::setsid();
      exit 126 if !defined $session || $session != $$;
      exec @ARGV;
      exit 127;
    ' "$WATCH" > "$out" 2>&1 &
  watcher_pid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    [ "$(cat "$state/.watch.lock/process-session" 2>/dev/null || true)" = "$watcher_pid" ] && break
    is_live_non_zombie "$watcher_pid" || break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/process-session" 2>/dev/null || true)" = "$watcher_pid" ] \
    || fail "direct session watcher did not establish its guard: $(cat "$out")"
  kill -TERM "$watcher_pid" 2>/dev/null || fail "could not terminate direct session watcher"
  wait "$watcher_pid" 2>/dev/null || true
  [ ! -e "$state/.watch.lock" ] && [ ! -L "$state/.watch.lock" ] \
    || fail "normal session watcher exit left a guarded lock"
  pass "normal session watcher exit excludes its snapshot enumerator"
}

test_watcher_self_evicts_on_lock_takeover() {
  local dir state fakebin out pid i lock_pid
  dir=$(make_case self-evict)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  # Keep this lifecycle test out of unrelated first-cycle maintenance. The
  # beacon below is then a deterministic observation that the watcher has
  # entered its supervision loop and passed its ownership check.
  touch "$state/.last-check" "$state/.last-account-session-sync" "$state/.last-report-retention"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 50 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] &&
      [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] || fail "watcher did not record its own pid in the lock"
  i=0
  while [ "$i" -lt 100 ] && [ ! -e "$state/.last-watcher-beat" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$state/.last-watcher-beat" ] || fail "watcher did not reach the ownership-observation loop"
  # Simulate a second watcher taking over the singleton lock. $$ (the test
  # runner) is a live pid that is not the watcher.
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  wait_for_exit "$pid" 60 || fail "watcher did not self-evict after lock takeover"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ "$lock_pid" = "$$" ] || fail "self-evicting watcher clobbered the new holder's lock (got '$lock_pid')"
  pass "watcher self-evicts when the lock pid no longer names it"
}

test_arm_attaches_and_waits_for_live_fresh_watcher() {
  local dir state fakebin out armout i wpid armpid status
  dir=$(make_case arm-attach)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  # A genuinely live watcher with a fresh beacon already holds the singleton.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wpid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "seed watcher did not take the lock"
  # Arming must attach to the existing watcher, NOT start a second one, and NOT
  # exit while the seed still holds the healthy lock.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$wpid" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$wpid" "$armout" || fail "arm did not report attach to the live watcher"
  ! grep -qF 'watcher: started' "$armout" || fail "arm started a second watcher behind a healthy one"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm reported FAILED for a healthy watcher"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "arm disturbed the healthy watcher's lock"
  is_live_non_zombie "$armpid" || fail "arm exited while the seed watcher was still healthy"
  # After the seed dies the attached arm must end, and must say so: no live cycle
  # exists any more, so it exits non-zero with the terminal line
  # (test_arm_attach_end_is_never_a_silent_false_attach owns that contract).
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -ne 124 ] || fail "attached arm never returned after the seed died"
  [ "$status" -ne 0 ] || fail "attached arm exited zero after the seed died, reading as live supervision"
  pass "arm attaches to a live fresh watcher and exits only when that cycle ends"
}

test_arm_refuses_live_lock_with_bad_attach_cadence() {
  local dir state out peer identity status
  dir=$(make_case arm-refuse-missed-cadence)
  state="$dir/state"
  out="$dir/arm.out"
  sleep 300 &
  peer=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || {
    kill "$peer" 2>/dev/null || true
    wait "$peer" 2>/dev/null || true
    fail "could not identify cadence-stale attach fixture"
  }
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  mkdir -p "$dir/config"
  printf 'FM_WATCH_PROGRESS_GRACE=60\n' > "$dir/config/watcher.env"
  touch "$state/.last-watcher-beat"
  perl -e '$time = time - 155; utime $time, $time, $ARGV[0]' "$state/.last-watcher-beat"
  status=0
  FM_HOME="$dir" FM_GUARD_GRACE=300 FM_ARM_CONFIRM_TIMEOUT=1 \
    "$WATCH_ARM" > "$out" || status=$?
  kill "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  [ "$status" -ne 0 ] || fail "arm reported a 155-second-old live-lock beacon as healthy"
  ! grep -qF "watcher: attached pid=$peer" "$out" \
    || fail "arm attached to a watcher already far outside normal cadence: $(cat "$out")"
  grep -qF "watcher: FAILED - live watcher pid=$peer missed progress cadence" "$out" \
    || fail "arm did not fail loudly for the already-sick watcher: $(cat "$out")"
  grep -qF 'bin/fm-watch-arm.sh --restart' "$out" \
    || fail "arm did not give the supported recovery for the already-sick watcher"
  pass "arm refuses to attach to a live watcher already outside progress cadence"
}

test_arm_attach_end_is_never_a_silent_false_attach() {
  # REGRESSION: an `attached` line is true only at the instant it is printed, but
  # the caller reads the whole buffer after the task completes. The arm used to
  # exit 0 and SILENT when the attached holder stopped being healthy, leaving
  # `watcher: attached pid=<N>` as the caller's final word - a pid that no longer
  # passed the liveness proof, and a beacon age frozen at attach time and so
  # understated by the whole attach duration. The caller read that as live
  # supervision and ended its turn with nothing watching the fleet.
  #
  # The rows cover every way an attach can stop - the holder exits, the holder
  # wedges and its beacon goes stale, or this arm is signalled away - and all
  # assert the same thing: the LAST word is never a bare attach claim.
  local row dir state fakebin armout armpid status peer identity last claimed
  for row in holder-exited beacon-stale interrupted; do
    dir=$(make_case "arm-attach-end-$row")
    state="$dir/state"
    fakebin="$dir/fakebin"
    armout="$dir/arm.out"
    peer=
    if [ "$row" = holder-exited ]; then
      # A genuinely live watcher holding the singleton, which then dies.
      PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch.out" &
      peer=$!
      i=0
      while [ "$i" -lt 80 ]; do
        [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$peer" ] && [ -e "$state/.last-watcher-beat" ] && break
        sleep 0.1
        i=$((i + 1))
      done
      [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$peer" ] || fail "seed watcher ($row) did not take the lock"
    else
      # A live, identity-matched holder. The beacon-stale row later wedges it
      # (stops beating, never exits); the interrupted row leaves it healthy and
      # signals the arm instead.
      sleep 300 &
      peer=$!
      identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || fail "could not identify peer pid"
      mkdir "$state/.watch.lock"
      printf '%s\n' "$peer" > "$state/.watch.lock/pid"
      printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
      printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
      printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
      touch "$state/.last-watcher-beat"
    fi

    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$armout" &
    armpid=$!
    i=0
    while [ "$i" -lt 80 ]; do
      grep -qF "watcher: attached pid=$peer" "$armout" 2>/dev/null && break
      sleep 0.1
      i=$((i + 1))
    done
    grep -qF "watcher: attached pid=$peer" "$armout" || fail "arm ($row) did not attach to the healthy holder: $(cat "$armout")"
    # The frozen reading must date itself, so a caller reading it later cannot
    # mistake an attach-time age for the age now.
    grep -qE "watcher: attached pid=$peer \(beacon [0-9]+s as of [0-9]{2}:[0-9]{2}:[0-9]{2}\)" "$armout" \
      || fail "arm ($row) attach line did not stamp when the beacon age was measured: $(cat "$armout")"

    # End the attach.
    case "$row" in
      holder-exited)
        kill -KILL "$peer" 2>/dev/null || true
        wait "$peer" 2>/dev/null || true
        ;;
      beacon-stale)
        touch -t 200001010000 "$state/.last-watcher-beat"
        ;;
      interrupted)
        kill -TERM "$armpid" 2>/dev/null || true
        ;;
    esac

    wait_for_exit "$armpid" 100
    status=$?
    [ "$status" -ne 124 ] || fail "arm ($row) never returned after the attached cycle ended"

    # The assertion that catches the bug: with the terminal line removed, the
    # buffer's final word is the stale `attached` claim.
    last=$(grep -v '^[[:space:]]*$' "$armout" | tail -1)
    case "$last" in
      *"watcher: attached"*)
        fail "arm ($row) left a bare attach claim as its final word: $last"
        ;;
    esac
    [ "$status" -ne 0 ] || fail "arm ($row) exited zero after the attach stopped, reading as live supervision"
    if [ "$row" = interrupted ]; then
      grep -qF "watcher: FAILED - attach interrupted" "$armout" \
        || fail "arm ($row) did not report that the attach was interrupted: $(cat "$armout")"
      # The holder is still fine here; the honest report is that WAKE DELIVERY
      # stopped, not that the watcher died.
      grep -qF "watcher pid=$peer is still live" "$armout" \
        || fail "arm ($row) did not distinguish a live holder from a dead one: $(cat "$armout")"
    else
      grep -qF "watcher: FAILED - attached cycle ended" "$armout" \
        || fail "arm ($row) did not report that the attached cycle ended: $(cat "$armout")"
      grep -qF "(was pid=$peer," "$armout" \
        || fail "arm ($row) terminal line did not name the holder whose cycle ended: $(cat "$armout")"
    fi

    # And the claim the caller would otherwise have believed really is false: no
    # watcher is live for this home at return.
    claimed=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    if [ "$row" = holder-exited ]; then
      [ -z "$claimed" ] || ! kill -0 "$claimed" 2>/dev/null \
        || fail "arm ($row) fixture is wrong: a watcher is still live, so there was no false attach to catch"
    fi
    kill "$peer" 2>/dev/null || true
    wait "$peer" 2>/dev/null || true
  done
  pass "arm never leaves a bare attach claim as its final word when an attach stops"
}

test_arm_attach_end_after_peer_wake_preserves_the_wake() {
  # The DOMINANT production shape, and why the silent exit fired on nearly every
  # plain arm in a busy home: fm-watch.sh exits normally as soon as it surfaces a
  # wake, by design. So an attach routinely lasts only until the next wake, the
  # holder is gone moments after the `attached` line is printed, and the caller
  # reads a pid with no live process behind it. No watcher crash is involved.
  #
  # Two things must hold when that happens: the arm says the cycle ended, and the
  # wake the holder queued is still there for the caller to drain, because the
  # repair for the terminal line is "drain queued wakes, then re-arm".
  local dir state fakebin armout drain_out check_file peer armpid status i
  dir=$(make_case arm-attach-end-after-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  drain_out="$dir/drain.out"
  check_file="$state/task.check.sh"
  # Emits a wake only once the trigger exists, so the seed watcher blocks first
  # and lets the arm attach to a genuinely healthy holder.
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
[ -e "${FM_TEST_WAKE_TRIGGER:-/nonexistent}" ] || exit 0
printf 'merged: https://example.test/pr/9\n'
SH
  chmod +x "$check_file"

  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_TEST_WAKE_TRIGGER="$dir/trigger" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch.out" &
  peer=$!
  i=0
  while [ "$i" -lt 80 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$peer" ] && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$peer" ] || fail "seed watcher did not take the lock"

  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_TEST_WAKE_TRIGGER="$dir/trigger" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$peer" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$peer" "$armout" || fail "arm did not attach to the seed watcher: $(cat "$armout")"

  # The holder now does the normal thing: surface a wake and exit zero.
  touch "$dir/trigger"
  wait "$peer" 2>/dev/null \
    || fail "seed watcher did not exit cleanly after its wake, so this is not the normal-exit path"

  i=0
  while [ "$i" -lt 100 ]; do
    grep -qF 'watcher: FAILED - attached cycle ended' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  wait_for_exit "$armpid" 100
  status=$?
  [ "$status" -ne 124 ] || fail "arm never returned after its holder woke and exited: $(cat "$armout")"
  [ "$status" -ne 0 ] || fail "arm exited zero after its holder woke and exited, reading as live supervision"
  # The cause text is deliberately not pinned: the holder releases its lock in an
  # EXIT trap and stays a not-yet-reaped zombie for a moment, so this race
  # honestly reports either "holder exited" or "lock no longer names that
  # watcher". Both are true; what must hold is that the ended cycle is reported
  # at all and names the holder.
  grep -qF 'watcher: FAILED - attached cycle ended' "$armout" \
    || fail "arm did not report the ended cycle on the normal peer-wake exit (status $status): $(cat "$armout")"
  grep -qF "(was pid=$peer," "$armout" \
    || fail "arm terminal line did not name the holder whose cycle ended: $(cat "$armout")"

  # The queued wake must survive: the caller's repair is drain-then-re-arm, so
  # reporting the ended cycle must not cost the wake that ended it.
  FM_HOME="$dir" "$DRAIN" > "$drain_out" || fail "drain after the attached holder's wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F 'merged: https://example.test/pr/9' >/dev/null \
    || fail "the wake that ended the attach was lost: $(cat "$drain_out")"
  pass "arm reports the ended cycle when its holder wakes and exits normally, and the wake survives to drain"
}

test_arm_starts_and_self_heals() {
  # Arming with no confirmable watcher must FORK one and confirm it live + fresh
  # before reporting 'started' - whether the lock is empty (clean start) or held
  # by a dead pid with a fresh-looking leftover beacon (self-heal). It must never
  # report 'healthy' off a dead pid. One row per pre-state, one assertion block.
  local row dir state fakebin armout armpid i lock_pid dead_pid
  for row in clean dead-pid; do
    dir=$(make_case "arm-$row")
    state="$dir/state"
    fakebin="$dir/fakebin"
    armout="$dir/arm.out"
    dead_pid=
    if [ "$row" = dead-pid ]; then
      dead_pid=999999
      while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid + 1)); done
      mkdir "$state/.watch.lock"
      printf '%s\n' "$dead_pid" > "$state/.watch.lock/pid"
      printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
      printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
      printf '%s\n' "dead watcher identity" > "$state/.watch.lock/pid-identity"
      touch "$state/.last-watcher-beat"
    fi
    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
    armpid=$!
    i=0
    while [ "$i" -lt 80 ]; do
      grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
      sleep 0.1; i=$((i + 1))
    done
    grep -qF 'watcher: started pid=' "$armout" || fail "arm ($row) did not report a started watcher"
    ! grep -qE 'watcher: (healthy|attached)' "$armout" || fail "arm ($row) wrongly reported attached/healthy instead of starting a fresh watcher"
    lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    # The 'started' line prints only after the fresh watcher passed (live pid +
    # fresh beacon), so it doubles as proof the beacon was confirmed fresh.
    grep -F "watcher: started pid=$lock_pid (beacon fresh)" "$armout" >/dev/null \
      || fail "arm ($row) started line did not name the confirmed live watcher (lock '$lock_pid')"
    kill -0 "$lock_pid" 2>/dev/null || fail "arm ($row) confirmed-started watcher is not actually alive"
    [ -z "$dead_pid" ] || [ "$lock_pid" != "$dead_pid" ] || fail "arm ($row) did not replace the dead-pid lock with a live watcher"
    kill "$armpid" "$lock_pid" 2>/dev/null || true
    wait "$armpid" 2>/dev/null || true
  done
  pass "arm starts+confirms a fresh watcher on a clean lock and self-heals a dead-pid lock (never healthy off a dead pid)"
}

test_arm_hup_cleans_child_and_temp_output() {
  local dir state fakebin armout i armpid lock_pid status
  dir=$(make_case arm-hup-cleanup)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$armout" || fail "arm did not start before HUP cleanup check"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  kill -HUP "$armpid" 2>/dev/null || fail "could not send HUP to arm"
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -eq 129 ] || fail "arm did not exit with HUP status (got $status)"
  i=0
  while [ "$i" -lt 80 ] && is_live_non_zombie "$lock_pid"; do
    sleep 0.1
    i=$((i + 1))
  done
  ! is_live_non_zombie "$lock_pid" || fail "HUP cleanup left watcher child running"
  ! ls "$state"/.watch-arm-output.* >/dev/null 2>&1 || fail "HUP cleanup left temp output behind"
  pass "arm cleans child watcher and temp output on HUP"
}

test_arm_propagates_immediate_wake_before_confirmation() {
  local dir state fakebin armout drain_out check_file rc
  dir=$(make_case arm-immediate-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  drain_out="$dir/drain.out"
  check_file="$state/task.check.sh"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'merged: https://example.test/pr/7\n'
SH
  chmod +x "$check_file"
  rc=0
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=0 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" || rc=$?
  [ "$rc" -eq 0 ] || fail "arm returned non-zero for an immediate wake (status $rc): $(cat "$armout")"
  grep -F "check: $check_file: merged: https://example.test/pr/7" "$armout" >/dev/null || fail "arm did not propagate the immediate check wake"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm printed FAILED after a valid immediate wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after immediate arm wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "$check_file" | grep -F 'merged: https://example.test/pr/7' >/dev/null || fail "immediate arm wake was not queued"
  pass "arm propagates an immediate watcher wake before confirmation"
}

test_arm_waits_for_peer_beacon_after_child_stands_down() {
  local dir state fakebin armout peer beater identity armpid status i
  dir=$(make_case arm-peer-startup-race)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  sleep 300 &
  peer=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || fail "could not identify peer pid"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  (
    sleep 1
    touch "$state/.last-watcher-beat"
  ) &
  beater=$!
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=4 FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$peer" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  wait "$beater" 2>/dev/null || true
  grep -qF "watcher: attached pid=$peer" "$armout" || fail "arm did not wait for and attach to the peer watcher: $(cat "$armout")"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm falsely reported FAILED during peer startup race"
  is_live_non_zombie "$armpid" || fail "arm exited while the peer was still healthy"
  # After the peer dies the attached arm must end the same way as the pre-fork
  # attach: non-zero, with the terminal line, never a silent zero.
  kill "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -ne 124 ] || fail "attached arm never returned after the peer died: $(cat "$armout")"
  [ "$status" -ne 0 ] || fail "attached arm exited zero after peer died, reading as live supervision: $(cat "$armout")"
  grep -qF "watcher: FAILED - attached cycle ended" "$armout" \
    || fail "attached arm did not report that the peer's cycle ended: $(cat "$armout")"
  pass "arm attaches to a peer watcher after child stands down and exits when peer dies"
}

test_arm_fails_loud_when_no_fresh_watcher_confirmable() {
  local dir state fakebin armout live armpid status
  dir=$(make_case arm-failed-stale)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  sleep 300 &
  live=$!
  # A live process holds the lock but is NOT a confirmable watcher (no identity),
  # and the beacon is stale. The fresh child cannot steal a LIVE lock, so no
  # watcher can ever be confirmed - the honest answer is FAILED, not healthy.
  mkdir "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  touch -t 200001010000 "$state/.last-watcher-beat"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=3 "$WATCH_ARM" > "$armout" &
  armpid=$!
  wait_for_exit "$armpid" 120
  status=$?
  [ "$status" -ne 124 ] || fail "arm never returned for an unconfirmable watcher"
  [ "$status" -ne 0 ] || fail "arm exited zero when no fresh watcher could be confirmed"
  grep -F 'watcher: FAILED - no live watcher with a fresh beacon' "$armout" >/dev/null || fail "arm did not print the FAILED line"
  ! grep -qE 'watcher: (healthy|attached)' "$armout" || fail "arm reported attached/healthy off a stale beacon"
  ! grep -qF 'watcher: started' "$armout" || fail "arm falsely reported started"
  is_live_non_zombie "$live" || fail "arm killed the unrelated live lock holder"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "arm reports FAILED and exits non-zero when no fresh watcher can be confirmed"
}

test_arm_detects_and_reaps_sustained_watcher_cpu() {
  local dir state fakebin out check armpid status i watcher_pid
  dir=$(make_case arm-resource-runaway)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/arm.out"
  check="$state/hot.check.sh"
  cat > "$check" <<'SH'
#!/usr/bin/env bash
while :; do :; done
SH
  chmod +x "$check"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=30 FM_HEARTBEAT=999999 \
    FM_WATCH_CPU_LIMIT=20 FM_WATCH_CPU_POLL=1 FM_WATCH_CPU_SAMPLES=2 \
    "$WATCH_ARM" > "$out" &
  armpid=$!
  i=0
  while [ "$i" -lt 150 ]; do
    grep -qF 'SUPERVISION IS CONSUMING' "$out" 2>/dev/null && break
    is_live_non_zombie "$armpid" || break
    sleep 0.1
    i=$((i + 1))
  done
  wait_for_exit "$armpid" 100
  status=$?
  if [ "$status" -eq 124 ]; then
    kill -TERM "$armpid" 2>/dev/null || true
    wait "$armpid" 2>/dev/null || true
    fail "arm did not stop a sustained full-core watcher tree"
  fi
  [ "$status" -ne 0 ] || fail "arm reported success after detecting a sustained full-core watcher tree"
  grep -qF 'process tree is consuming' "$out" || fail "arm did not name the watcher CPU failure: $(cat "$out")"
  grep -qF 'exact recorded pid and parentage' "$out" || fail "arm CPU diagnostic did not state its identity boundary"
  grep "$(printf '\tstale\twatcher-health\t')" "$state/.wake-queue" >/dev/null \
    || fail "arm did not queue the watcher resource failure durably"
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ -z "$watcher_pid" ] || ! is_live_non_zombie "$watcher_pid" \
    || fail "resource recovery left the recorded watcher alive"
  pass "arm detects sustained watcher-tree CPU and reaps the owned cycle loudly"
}

test_arm_allows_bounded_watcher_phases_past_base_cadence() {
  local dir state fakebin out armpid status i
  dir=$(make_case arm-bounded-auto-reap)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/arm.out"
  touch "$state/.last-account-session-sync" "$state/.last-report-retention"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_TEST_AUTO_REAP_SLEEP=5 \
    FM_TEST_AUTO_REAP_OUTPUT='bounded auto-reap complete' FM_WATCH_PROGRESS_GRACE=3 \
    FM_TREEHOUSE_RETURN_TIMEOUT=1 FM_TREEHOUSE_RETURN_LOCK_RETRIES=0 \
    FM_CHECKOUT_REFRESH_PROBE_TIMEOUT=1 FM_AUTO_REAP_COMMAND_TIMEOUT=1 \
    FM_ACCOUNT_CONTROL_TIMEOUT=1 FM_ACCOUNT_LIFECYCLE_LOCK_WAIT_SECONDS=0 \
    FM_ACCOUNT_META_LOCK_WAIT_SECONDS=0 FM_ACCOUNT_LINEAGE_LOCK_WAIT_SECONDS=0 \
    FM_WATCH_AUTO_REAP_CLEANUP_MARGIN=1 \
    FM_WATCH_AUTO_REAP_TIMEOUT=60 FM_WATCH_PHASE_MARGIN=1 FM_POLL=1 \
    FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$out" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$out" 2>/dev/null && break
    is_live_non_zombie "$armpid" || break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$out" || fail "arm did not confirm watcher during bounded auto-reap: $(cat "$out")"
  sleep 3.5
  is_live_non_zombie "$armpid" || fail "base cadence killed a watcher inside bounded auto-reap: $(cat "$out")"
  grep -qF 'phase=auto-reap' "$state/.watch.phase" \
    || fail "watcher did not publish its bounded auto-reap phase"
  wait_for_exit "$armpid" 100
  status=$?
  [ "$status" -ne 124 ] || fail "bounded auto-reap wake did not finish"
  wait "$armpid" 2>/dev/null || true
  [ "$status" -eq 0 ] || fail "bounded auto-reap wake failed: $(cat "$out")"
  grep -qF 'auto-reap: bounded auto-reap complete' "$out" \
    || fail "bounded auto-reap wake did not propagate: $(cat "$out")"
  [ ! -e "$state/.watch.phase" ] || fail "watcher left its bounded phase record after wake exit"

  dir=$(make_case arm-bounded-poll)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/arm.out"
  touch "$state/.last-account-session-sync" "$state/.last-report-retention" "$state/.last-check"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_WATCH_PROGRESS_GRACE=2 FM_WATCH_PHASE_MARGIN=1 \
    FM_POLL=4 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$out" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$out" 2>/dev/null && break
    is_live_non_zombie "$armpid" || break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$out" || fail "arm did not confirm watcher before configured poll"
  sleep 2.5
  is_live_non_zombie "$armpid" || fail "base cadence killed a watcher inside configured FM_POLL: $(cat "$out")"
  grep -qF 'phase=event-wait' "$state/.watch.phase" \
    || fail "watcher did not publish its bounded event-wait phase"
  kill -TERM "$armpid" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  [ ! -e "$state/.watch.phase" ] || fail "watcher left its bounded event-wait phase after interruption"
  pass "arm honors bounded auto-reap and FM_POLL phases beyond the base cadence"
}

test_heartbeat_aggregate_reads_publish_bounded_progress() {
  local dir state fakebin out trace slow armpid i completed
  dir=$(make_case arm-aggregate-state-progress)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/arm.out"
  trace="$state/beat-trace"
  slow="$fakebin/slow-crew-state"
  cat > "$slow" <<'SH'
#!/usr/bin/env bash
sleep 1
printf 'state: working · source: run-step · liveness: alive\n'
SH
  chmod +x "$slow"
  for i in 1 2 3 4; do
    printf 'kind=ship\n' > "$state/task-$i.meta"
  done
  touch "$state/.last-check"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_CREW_STATE_BIN="$slow" \
    FM_CREW_STATE_READ_TIMEOUT=2 FM_WATCH_PROGRESS_GRACE=3 FM_WATCH_PHASE_MARGIN=1 \
    FM_WATCHER_BEAT_TEST_LOG="$trace" FM_HEARTBEAT=1 FM_HEARTBEAT_MAX=1 \
    FM_CHECK_INTERVAL=999999 FM_POLL=1 FM_WATCH_CPU_LIMIT=999 "$WATCH_ARM" > "$out" &
  armpid=$!
  i=0
  completed=0
  while [ "$i" -lt 100 ]; do
    completed=$(grep -c $'\tcrew-state-complete$' "$trace" 2>/dev/null || true)
    [ -n "$completed" ] || completed=0
    [ "$completed" -ge 3 ] && break
    is_live_non_zombie "$armpid" || break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$completed" -ge 3 ] || fail "aggregate scan did not publish progress between bounded reads: $(cat "$out")"
  is_live_non_zombie "$armpid" || fail "arm killed a healthy watcher during its aggregate state scan: $(cat "$out")"
  kill -TERM "$armpid" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  pass "aggregate heartbeat reads publish bounded progress between tasks"
}

test_arm_recovers_direct_no_progress_wedge() {
  local dir state fakebin out armpid watcher_pid i status
  dir=$(make_case arm-direct-progress-wedge)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/arm.out"
  touch "$state/.last-check"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_WATCH_PROGRESS_GRACE=2 FM_WATCH_PHASE_MARGIN=1 \
    FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 FM_POLL=1 FM_WATCH_CPU_LIMIT=999 \
    "$WATCH_ARM" > "$out" &
  armpid=$!
  i=0
  watcher_pid=
  while [ "$i" -lt 80 ]; do
    watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    grep -qF 'watcher: started pid=' "$out" 2>/dev/null && [ -n "$watcher_pid" ] && break
    is_live_non_zombie "$armpid" || break
    sleep 0.1
    i=$((i + 1))
  done
  [ -n "$watcher_pid" ] || fail "arm did not start a watcher for direct wedge recovery"
  kill -STOP "$watcher_pid" 2>/dev/null || fail "could not stop the recorded watcher"
  wait_for_exit "$armpid" 100
  status=$?
  if [ "$status" -eq 124 ]; then
    kill -CONT "$watcher_pid" 2>/dev/null || true
    kill -TERM "$armpid" 2>/dev/null || true
    wait "$armpid" 2>/dev/null || true
    fail "arm did not recover a watcher that stopped publishing progress"
  fi
  wait "$armpid" 2>/dev/null || true
  [ "$status" -ne 0 ] || fail "arm reported success after direct progress wedge recovery"
  grep -qF 'stopped making supervision progress' "$out" || fail "arm did not report the direct progress wedge: $(cat "$out")"
  ! is_live_non_zombie "$watcher_pid" || fail "direct wedge recovery left the recorded watcher alive"
  pass "arm force-recovers a watcher that stops all progress"
}

test_arm_reaps_term_trap_children_from_owned_session() {
  local dir state fakebin out ready spawned armpid watcher_pid session child_pid i
  dir=$(make_case arm-owned-session)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/arm.out"
  ready="$dir/helper.ready"
  spawned="$dir/helper-child.pid"
  cat > "$state/session.check.sh" <<SH
#!/usr/bin/env bash
trap 'perl -MPOSIX -e '\''POSIX::setpgrp(0, 0); \$SIG{TERM} = "IGNORE"; sleep 300'\'' & printf "%s\\n" \$! > "$spawned"; exit 0' TERM
touch "$ready"
while :; do sleep 1; done
SH
  chmod +x "$state/session.check.sh"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=300 \
    FM_HEARTBEAT=999999 FM_POLL=1 FM_WATCH_CPU_LIMIT=999 "$WATCH_ARM" > "$out" &
  armpid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    session=$(cat "$state/.watch.lock/process-session" 2>/dev/null || true)
    [ -e "$ready" ] && [ -n "$watcher_pid" ] && [ "$session" = "$watcher_pid" ] \
      && grep -qF 'watcher: started pid=' "$out" 2>/dev/null && break
    is_live_non_zombie "$armpid" || break
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$ready" ] || fail "watcher helper did not enter its TERM-trap fixture"
  [ "$session" = "$watcher_pid" ] || fail "arm-launched watcher did not record an owned process session"
  kill -HUP "$armpid" 2>/dev/null || fail "could not interrupt owned-session arm"
  wait "$armpid" 2>/dev/null || true
  [ -s "$spawned" ] || fail "watcher helper TERM trap did not spawn its cleanup child"
  child_pid=$(cat "$spawned")
  ! is_live_non_zombie "$watcher_pid" || fail "owned-session cleanup left the watcher root alive"
  ! is_live_non_zombie "$child_pid" || fail "owned-session cleanup missed the TERM-trap child"
  session=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_session_snapshot "$2"' _ "$LIB" "$watcher_pid") \
    || fail "could not verify the cleaned watcher session"
  [ -z "$session" ] || fail "owned-session cleanup left live session members: $session"
  pass "arm cleanup reaps TERM-trap children across watcher process groups"
}

test_auto_reap_bound_tracks_inner_configuration() {
  local dir state derived base lock_bound expected out status
  dir=$(make_case derived-auto-reap-bound)
  state="$dir/state"
  derived=$(FM_STATE_OVERRIDE="$state" FM_TREEHOUSE_RETURN_TIMEOUT=900 bash -c \
    '. "$1"; watcher_auto_reap_timeout task' _ "$WATCH") \
    || fail "could not derive auto-reap bound from Treehouse configuration"
  [ "$derived" -gt 900 ] || fail "derived auto-reap bound did not include Treehouse timeout and cleanup: $derived"
  base=$(FM_STATE_OVERRIDE="$state" FM_ACCOUNT_LIFECYCLE_LOCK_WAIT_SECONDS=0 \
    FM_ACCOUNT_META_LOCK_WAIT_SECONDS=0 FM_ACCOUNT_LINEAGE_LOCK_WAIT_SECONDS=0 bash -c \
    '. "$1"; watcher_auto_reap_timeout task' _ "$WATCH") \
    || fail "could not derive baseline auto-reap account-lock bound"
  lock_bound=$(FM_STATE_OVERRIDE="$state" FM_ACCOUNT_LIFECYCLE_LOCK_WAIT_SECONDS=900 \
    FM_ACCOUNT_META_LOCK_WAIT_SECONDS=800 FM_ACCOUNT_LINEAGE_LOCK_WAIT_SECONDS=700 bash -c \
    '. "$1"; watcher_auto_reap_timeout task' _ "$WATCH") \
    || fail "could not derive configured auto-reap account-lock bound"
  expected=$((2 * 900 + 6 * 800 + 2 * 700))
  [ $((lock_bound - base)) -eq "$expected" ] \
    || fail "derived auto-reap bound omitted configured account lock waits: base=$base configured=$lock_bound"
  status=0
  out=$(FM_STATE_OVERRIDE="$state" FM_TREEHOUSE_RETURN_TIMEOUT=900 FM_WATCH_AUTO_REAP_TIMEOUT=600 bash -c \
    '. "$1"; watcher_auto_reap_timeout task' _ "$WATCH" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "incompatible explicit auto-reap bound was accepted"
  grep -qF 'below the derived' <<< "$out" || fail "incompatible auto-reap bound was not diagnosed: $out"
  pass "auto-reap derives its outer bound from configured teardown limits"
}

test_watcher_config_parser_is_shared_and_nonexecuting() {
  local dir config out status marker name_marker structural arm_out
  dir=$(make_case watcher-config-parser)
  config="$dir/config"
  marker="$dir/parser-executed"
  mkdir -p "$config"
  printf "FM_WATCH_PROGRESS_GRACE=17\nFM_CAPTAIN_RE='done:|checks green'\n" > "$config/watcher.env"
  out=$(bash -c '. "$1"; fm_watcher_config_load "$2"; printf "%s|%s" "$FM_WATCH_PROGRESS_GRACE" "$FM_CAPTAIN_RE"' \
    _ "$ROOT/bin/fm-watcher-config-lib.sh" "$config") \
    || fail "shared watcher config parser rejected valid assignments"
  [ "$out" = '17|done:|checks green' ] || fail "shared watcher config parser changed valid values: $out"
  printf 'FM_WATCH_PROGRESS_GRACE=$(touch %s)\n' "$marker" > "$config/watcher.env"
  status=0
  FM_WATCHER_CONFIG_LOADED_PATH= bash -c '. "$1"; fm_watcher_config_load "$2"' \
    _ "$ROOT/bin/fm-watcher-config-lib.sh" "$config" 2>/dev/null || status=$?
  [ "$status" -ne 0 ] || fail "shared watcher config parser accepted executable syntax"
  [ ! -e "$marker" ] || fail "shared watcher config parser executed assignment contents"
  name_marker="$dir/name-parser-executed"
  printf 'FM_A[$(touch${IFS}%s)]=value\n' "$name_marker" > "$config/watcher.env"
  status=0
  FM_WATCHER_CONFIG_LOADED_PATH= bash -c '. "$1"; fm_watcher_config_load "$2"' \
    _ "$ROOT/bin/fm-watcher-config-lib.sh" "$config" 2>/dev/null || status=$?
  [ "$status" -ne 0 ] || fail "shared watcher config parser accepted an array-subscript variable name"
  [ ! -e "$name_marker" ] || fail "shared watcher config parser executed an array subscript"
  for structural in FM_ROOT FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK FM_UNKNOWN_WATCHER_SETTING; do
    printf '%s=%s\n' "$structural" "$dir/redirected" > "$config/watcher.env"
    status=0
    FM_WATCHER_CONFIG_LOADED_PATH= bash -c '. "$1"; fm_watcher_config_load "$2"' \
      _ "$ROOT/bin/fm-watcher-config-lib.sh" "$config" 2>/dev/null || status=$?
    [ "$status" -ne 0 ] || fail "shared watcher config parser accepted non-allowlisted $structural"
  done
  printf 'FM_ARM_ATTACH_POLL=0\n' > "$config/watcher.env"
  arm_out="$dir/arm.out"
  status=0
  FM_HOME="$dir" "$WATCH_ARM" > "$arm_out" 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "arm accepted a zero attach poll cadence"
  grep -qF 'FM_ARM_ATTACH_POLL must be a positive decimal' "$arm_out" \
    || fail "arm did not diagnose its invalid attach poll cadence: $(cat "$arm_out")"
  [ ! -e "$dir/state/.watch.lock" ] || fail "arm entered watcher startup before validating attach cadence"
  pass "watcher config is parsed once without executing shell syntax"
}

test_pid_identity_is_locale_invariant() {
  # The watcher records its process identity under one locale; arm/guard/turn-end
  # re-read it under the machine's ambient locale. ps's lstart date format follows
  # LC_TIME, so an unpinned read on a non-C locale (e.g. ko_KR) would differ only
  # in the date portion and reject a genuinely live watcher. The fix pins LC_ALL=C
  # inside fm_pid_identity, so its output must be byte-identical regardless of the
  # caller's exported LC_ALL/LC_TIME. That invariant holds on any host because the
  # pin is internal, so this stays deterministic on CI even where an alternate
  # locale like ko_KR.UTF-8 is not installed (the equality then holds trivially).
  local live baseline via_lc_all via_lc_time
  sleep 300 &
  live=$!
  baseline=$(LC_ALL=C bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  via_lc_all=$(LC_ALL=ko_KR.UTF-8 bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  via_lc_time=$(LC_TIME=ko_KR.UTF-8 bash -c 'unset LC_ALL; . "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  [ -n "$baseline" ] || fail "fm_pid_identity produced no baseline identity under LC_ALL=C"
  [ "$via_lc_all" = "$baseline" ] || fail "fm_pid_identity varied with exported LC_ALL (got '$via_lc_all', want '$baseline')"
  [ "$via_lc_time" = "$baseline" ] || fail "fm_pid_identity varied with exported LC_TIME (got '$via_lc_time', want '$baseline')"
  pass "fm_pid_identity is locale-invariant across LC_ALL/LC_TIME"
}

if [ "${FM_TEST_FOCUSED:-}" = self-evict ]; then
  test_watcher_self_evicts_on_lock_takeover
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = stale-steal-chain ]; then
  test_lock_stale_steal_chain_is_bounded
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = restart-term-resistant ]; then
  test_watch_restart_reaps_term_resistant_owned_tree
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = ownership-boundary ]; then
  test_watch_restart_reaps_term_resistant_owned_tree
  test_watch_restart_recovers_dead_session_leader
  test_arm_owner_death_reaps_watcher_session
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = ownership-races ]; then
  test_arm_owner_death_before_monitor_start_reaps_session
  test_session_cleanup_requires_stable_quiescence
  test_watch_restart_refuses_reused_session_without_anchor
  test_normal_session_watcher_releases_guard
  test_watch_restart_recovers_dead_session_leader
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = arm-owner-death ]; then
  test_arm_owner_death_reaps_watcher_session
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = phase-bounds ]; then
  test_guard_accepts_identity_matched_active_phase
  test_arm_allows_bounded_watcher_phases_past_base_cadence
  test_heartbeat_aggregate_reads_publish_bounded_progress
  test_arm_recovers_direct_no_progress_wedge
  test_arm_reaps_term_trap_children_from_owned_session
  test_auto_reap_bound_tracks_inner_configuration
  test_watcher_config_parser_is_shared_and_nonexecuting
  exit 0
fi

test_singleton_start
test_pid_identity_is_locale_invariant
test_stale_watch_lock_reclaimed
test_live_stale_watch_lock_is_actionable
test_guard_warnings
test_guard_detects_live_watcher_that_missed_cadence
test_guard_accepts_identity_matched_active_phase
test_guard_detects_hot_recorded_watcher_tree
test_lock_single_winner_under_concurrency
test_lock_steals_dead_pid_lock
test_lock_stale_steal_single_winner_under_concurrency
test_lock_stale_steal_chain_is_bounded
test_lock_live_steal_mutex_is_not_reclaimed
test_lock_does_not_steal_live_lock
test_lock_empty_pid_uses_minimum_grace
test_lock_late_claim_loses_after_recreate
test_lock_paused_mid_acquire_claim_fails_during_steal
test_pid_tree_stop_refuses_mismatched_root_identity
test_watch_restart_rejects_reused_pid
test_watch_restart_reaps_term_resistant_owned_tree
test_watch_restart_recovers_dead_session_leader
test_arm_owner_death_reaps_watcher_session
test_arm_owner_death_before_monitor_start_reaps_session
test_session_cleanup_requires_stable_quiescence
test_watch_restart_refuses_reused_session_without_anchor
test_normal_session_watcher_releases_guard
test_watcher_self_evicts_on_lock_takeover
test_arm_attaches_and_waits_for_live_fresh_watcher
test_arm_refuses_live_lock_with_bad_attach_cadence
test_arm_attach_end_is_never_a_silent_false_attach
test_arm_attach_end_after_peer_wake_preserves_the_wake
test_arm_starts_and_self_heals
test_arm_hup_cleans_child_and_temp_output
test_arm_propagates_immediate_wake_before_confirmation
test_arm_waits_for_peer_beacon_after_child_stands_down
test_arm_fails_loud_when_no_fresh_watcher_confirmable
test_arm_detects_and_reaps_sustained_watcher_cpu
test_arm_allows_bounded_watcher_phases_past_base_cadence
test_heartbeat_aggregate_reads_publish_bounded_progress
test_arm_recovers_direct_no_progress_wedge
test_arm_reaps_term_trap_children_from_owned_session
test_auto_reap_bound_tracks_inner_configuration
test_watcher_config_parser_is_shared_and_nonexecuting
