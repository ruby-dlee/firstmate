#!/usr/bin/env bash
# Five-minute regression for the production watcher runaway: one paused,
# long-lived secondmate status stream must not trap a nested Bash fold at a full
# core, starve progress, or create more than one recorded watcher tree.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
DURATION=${FM_WATCH_RUNAWAY_REGRESSION_SECONDS:-300}
SAMPLE_INTERVAL=${FM_WATCH_RUNAWAY_SAMPLE_INTERVAL:-15}
CPU_CEILING=${FM_WATCH_RUNAWAY_CPU_CEILING:-80}
CPU_AVERAGE_CEILING=${FM_WATCH_RUNAWAY_CPU_AVERAGE_CEILING:-10}
CPU_WARMUP=${FM_WATCH_RUNAWAY_CPU_WARMUP:-30}
PROGRESS_CEILING=${FM_WATCH_PROGRESS_GRACE:-60}

fm_test_tmproot_into TMP_ROOT fm-watcher-runaway
DIR=$(make_case five-minute)
STATE="$DIR/state"
FAKEBIN="$DIR/fakebin"
OUT="$DIR/arm.out"
STATUS="$STATE/long-lived.status"
ARM_PID=
ROOT_PID=
ROOT_IDENTITY=

regression_cleanup() {
  if [ -n "$ARM_PID" ] && is_live_non_zombie "$ARM_PID"; then
    kill -TERM "$ARM_PID" 2>/dev/null || true
    wait "$ARM_PID" 2>/dev/null || true
  fi
  if [ -n "$ROOT_PID" ] && [ -n "$ROOT_IDENTITY" ]; then
    FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_pid_tree_stop "$2" 10 "$3"' \
      _ "$ROOT/bin/fm-wake-lib.sh" "$ROOT_PID" "$ROOT_IDENTITY" >/dev/null 2>&1 || true
  fi
  fm_test_cleanup
}
trap regression_cleanup EXIT

seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1"; else stat -c '%s:%Y' "$1"; fi
}

owned_tree_rows() {  # <root-pid>
  LC_ALL=C ps -axo pid=,ppid= | awk -v root="$1" '
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { count++; pid[count] = $1; parent[count] = $2 }
    END {
      depth[root] = 0
      for (round = 1; round <= count; round++) {
        changed = 0
        for (index_value = 1; index_value <= count; index_value++) {
          current = pid[index_value]
          if (!(current in depth) && (parent[index_value] in depth)) {
            depth[current] = depth[parent[index_value]] + 1
            changed = 1
          }
        }
        if (!changed) break
      }
      for (index_value = 1; index_value <= count; index_value++) {
        current = pid[index_value]
        if (current in depth) print depth[current], current
      }
    }
  ' | sort -k1,1nr -k2,2nr
}

cleanup_owned_tree() {  # <root-pid>
  local root=$1 rows pid
  rows=$(owned_tree_rows "$root")
  printf '%s\n' "$rows" | while read -r _ pid; do
    [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 0.5
  printf '%s\n' "$rows" | while read -r _ pid; do
    [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null || true
  done
}

path_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

tree_cpu() {  # <root-pid>
  LC_ALL=C ps -axo pid=,ppid=,%cpu= | awk -v root="$1" '
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+([.][0-9]+)?$/ {
      count++
      pid[count] = $1
      parent[count] = $2
      cpu[count] = $3
    }
    END {
      owned[root] = 1
      for (round = 1; round <= count; round++) {
        changed = 0
        for (index_value = 1; index_value <= count; index_value++) {
          current = pid[index_value]
          if (!(current in owned) && (parent[index_value] in owned)) {
            owned[current] = 1
            changed = 1
          }
        }
        if (!changed) break
      }
      total = 0
      members = 0
      for (index_value = 1; index_value <= count; index_value++) {
        if (pid[index_value] in owned) {
          total += cpu[index_value]
          members++
        }
      }
      printf "%.1f %d\n", total, members
    }
  '
}

{
  awk 'BEGIN { payload = ""; for (i = 0; i < 3200; i++) payload = payload "x"; for (line = 0; line < 390; line++) printf "needs-decision [key=k%03d]: %s\\n", line, payload; for (line = 0; line < 390; line++) printf "resolved [key=k%03d]: cleared\\n", line }'
  printf 'paused: waiting on a bounded external event\n'
} > "$STATUS"
fm_write_meta "$STATE/long-lived.meta" \
  'window=test:fm-long-lived' \
  'kind=secondmate' \
  'harness=pi' \
  'generation_id=test:long-lived'
printf '%s' "$(seen_sig "$STATUS")" > "$STATE/.seen-long-lived_status"
cat > "$STATE/long-lived.check.sh" <<SH
#!/usr/bin/env bash
. '$ROOT/bin/fm-classify-lib.sh'
status_open_decisions '$STATUS' >/dev/null
SH
chmod +x "$STATE/long-lived.check.sh"
touch "$STATE/.last-report-retention" "$STATE/.last-account-session-sync" \
  "$STATE/.last-check" "$STATE/.last-heartbeat"
printf 'idle\n' > "$DIR/capture"

PATH="$FAKEBIN:$PATH" FM_HOME="$DIR" FM_FAKE_TMUX_WINDOW='test:fm-long-lived' FM_FAKE_TMUX_CAPTURE="$DIR/capture" \
  FM_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh" \
  FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting' \
  FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=10 FM_HEARTBEAT=999999 \
  FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999999 "$WATCH_ARM" > "$OUT" &
ARM_PID=$!

for _ in $(seq 1 150); do
  grep -qF 'watcher: started pid=' "$OUT" 2>/dev/null && break
  is_live_non_zombie "$ARM_PID" || fail "watcher arm exited before startup: $(cat "$OUT")"
  sleep 0.1
done
grep -qF 'watcher: started pid=' "$OUT" || fail "watcher arm did not confirm startup"
ROOT_PID=$(cat "$STATE/.watch.lock/pid" 2>/dev/null || true)
[ -n "$ROOT_PID" ] || fail "watcher lock did not record its root pid"
ROOT_IDENTITY=$(cat "$STATE/.watch.lock/pid-identity" 2>/dev/null || true)
[ -n "$ROOT_IDENTITY" ] || fail "watcher lock did not record its root identity"

elapsed=0
max_cpu=0
cpu_sum=0
cpu_samples=0
max_members=0
beat_changes=0
max_beat_age=0
last_beat=
while [ "$elapsed" -lt "$DURATION" ]; do
  is_live_non_zombie "$ARM_PID" || {
    cleanup_owned_tree "$ROOT_PID"
    fail "watcher arm ended during the ${DURATION}s stability window: $(cat "$OUT")"
  }
  [ "$(cat "$STATE/.watch.lock/pid" 2>/dev/null || true)" = "$ROOT_PID" ] || {
    cleanup_owned_tree "$ROOT_PID"
    fail "watcher root changed during one arm cycle"
  }
  beat=$(path_mtime "$STATE/.last-watcher-beat" || true)
  [ -n "$beat" ] || fail "watcher progress beacon disappeared during the stability window"
  beat_age=$(( $(date +%s) - beat ))
  [ "$beat_age" -le "$max_beat_age" ] || max_beat_age=$beat_age
  if [ "$beat" != "$last_beat" ]; then
    beat_changes=$((beat_changes + 1))
    last_beat=$beat
  fi
  read -r cpu members <<EOF
$(tree_cpu "$ROOT_PID")
EOF
  if [ "$elapsed" -ge "$CPU_WARMUP" ]; then
    max_cpu=$(awk -v left="$max_cpu" -v right="$cpu" 'BEGIN { print (left > right ? left : right) }')
    cpu_sum=$(awk -v total="$cpu_sum" -v sample="$cpu" 'BEGIN { printf "%.3f", total + sample }')
    cpu_samples=$((cpu_samples + 1))
  fi
  [ "$members" -le "$max_members" ] || max_members=$members
  sleep_for=$SAMPLE_INTERVAL
  [ "$((elapsed + sleep_for))" -le "$DURATION" ] || sleep_for=$((DURATION - elapsed))
  [ "$sleep_for" -gt 0 ] && sleep "$sleep_for"
  elapsed=$((elapsed + sleep_for))
done

# Exercise the user-visible wake path rather than terminating a passing fixture.
printf 'done: five-minute watcher regression complete\n' >> "$STATUS"
wait_for_exit "$ARM_PID" 200
arm_status=$?
if [ "$arm_status" -eq 124 ]; then
  cleanup_owned_tree "$ROOT_PID"
  fail "watcher did not surface the terminal signal after the stability window"
fi
wait "$ARM_PID" 2>/dev/null || true
average_cpu=$(awk -v total="$cpu_sum" -v count="$cpu_samples" 'BEGIN { if (count == 0) print "0.0"; else printf "%.1f", total / count }')
printf 'watcher-regression evidence duration=%ss average_cpu=%s%% max_cpu=%s%% max_tree_processes=%s beacon_writes=%s max_beat_age=%ss root=%s\n' \
  "$DURATION" "$average_cpu" "$max_cpu" "$max_members" "$beat_changes" "$max_beat_age" "$ROOT_PID"
awk -v actual="$max_cpu" -v ceiling="$CPU_CEILING" 'BEGIN { exit !(actual < ceiling) }' \
  || fail "watcher tree reached ${max_cpu}% CPU (ceiling ${CPU_CEILING}%)"
awk -v actual="$average_cpu" -v ceiling="$CPU_AVERAGE_CEILING" 'BEGIN { exit !(actual < ceiling) }' \
  || fail "watcher tree averaged ${average_cpu}% CPU (ceiling ${CPU_AVERAGE_CEILING}%)"
[ "$beat_changes" -ge 2 ] || fail "watcher did not reach a second progress beacon in ${DURATION}s"
[ "$max_beat_age" -lt "$PROGRESS_CEILING" ] \
  || fail "watcher beacon reached ${max_beat_age}s (progress ceiling ${PROGRESS_CEILING}s)"
grep -qF "signal: $STATUS" "$OUT" || fail "terminal wake did not propagate through the arm: $(cat "$OUT")"
[ ! -e "$STATE/.watch.lock" ] && [ ! -L "$STATE/.watch.lock" ] \
  || fail "intentional wake exit did not release the watcher lock"
printf 'ok - five-minute watcher stability: average_cpu=%s%% max_cpu=%s%% max_tree_processes=%s beacon_writes=%s max_beat_age=%ss one_recorded_root=%s\n' \
  "$average_cpu" "$max_cpu" "$max_members" "$beat_changes" "$max_beat_age" "$ROOT_PID"
