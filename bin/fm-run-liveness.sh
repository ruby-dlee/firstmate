#!/usr/bin/env bash
# Prove liveness for one task's running no-mistakes step from a process window.
# Usage: fm-run-liveness.sh <task-id>
# Exit 0 = BUSY from at least one affirmative run-owned process sample, 1 = an
# all-zero window while the same run still says running (UNKNOWN, never idle,
# dead, or wedged), 2 = no stable exact run/branch record to test.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ID=${1:?usage: fm-run-liveness.sh <task-id>}
META="$STATE/$ID.meta"
CACHE="$STATE/.run-liveness-$ID"
NM_BIN=${FM_RUN_LIVENESS_NM_BIN:-no-mistakes}
PS_BIN=${FM_RUN_LIVENESS_PS_BIN:-ps}
CWD_BIN=${FM_RUN_LIVENESS_CWD_BIN:-lsof}
HOST_PRESSURE_BIN=${FM_RUN_LIVENESS_HOST_PRESSURE_BIN:-$SCRIPT_DIR/fm-host-pressure.sh}
SAMPLES=${FM_RUN_LIVENESS_SAMPLES:-7}
INTERVAL=${FM_RUN_LIVENESS_INTERVAL:-10}
DB=${FM_RUN_LIVENESS_DB:-$HOME/.no-mistakes/state.sqlite}
HOST_EVIDENCE=unavailable

# shellcheck source=bin/fm-account-routing-lib.sh
. "$SCRIPT_DIR/fm-account-routing-lib.sh"

fm_account_valid_id "$ID" || { echo "inconclusive: invalid task id '$ID'" >&2; exit 2; }

emit_result() {  # <exit> <line>
  local result=$1 line=$2 tmp
  line="$line host_pressure=$HOST_EVIDENCE"
  tmp=$(mktemp "$STATE/.run-liveness-$ID.XXXXXX") || {
    printf '%s\n' "$line" >&2
    exit 2
  }
  printf '%s\n' "$line" > "$tmp" || { rm -f "$tmp"; exit 2; }
  fm_account_safe_file_destination "$CACHE" || { rm -f "$tmp"; exit 2; }
  mv "$tmp" "$CACHE" || { rm -f "$tmp"; exit 2; }
  if [ "$result" -eq 0 ]; then printf '%s\n' "$line"; else printf '%s\n' "$line" >&2; fi
  exit "$result"
}

case "$SAMPLES" in ''|*[!0-9]*|0|1) emit_result 2 "inconclusive: sample count must be at least 2" ;; esac
case "$INTERVAL" in
  ''|*[!0-9]*) emit_result 2 "inconclusive: sample interval must be an integer" ;;
  0)
    [ "${FM_RUN_LIVENESS_TEST_LAB:-}" = firstmate-run-liveness-test-lab-v1 ] \
      || emit_result 2 "inconclusive: zero sample interval is test-lab only"
    ;;
esac
[ -f "$META" ] && [ ! -L "$META" ] || emit_result 2 "inconclusive: no safe metadata for $ID"
WORKTREE=$(fm_account_meta_value "$META" worktree)
[ -d "$WORKTREE" ] && [ ! -L "$WORKTREE" ] || emit_result 2 "inconclusive: no safe worktree for $ID"
KIND=$(fm_account_meta_value "$META" kind)
[ -n "$KIND" ] || KIND=ship
[ "$KIND" = ship ] || emit_result 2 "inconclusive: kind=$KIND does not own a no-mistakes run"
OWN_BRANCH=$(git -C "$WORKTREE" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
[ -n "$OWN_BRANCH" ] || emit_result 2 "inconclusive: detached worktree has no task-owned run branch"
[ "$OWN_BRANCH" = "fm/$ID" ] || emit_result 2 "inconclusive: worktree branch $OWN_BRANCH is not fm/$ID"

# Capture host pressure before interpreting any liveness sample. Sustained host
# overload is a competing explanation for repeated zero-process observations;
# this evidence is recorded, never promoted into either a code-failure or
# liveness verdict.
HOST_CACHE="$STATE/.host-pressure-$ID"
host_tmp=$(mktemp "$STATE/.host-pressure-$ID.XXXXXX") \
  || emit_result 2 "inconclusive: cannot stage host-pressure evidence"
if "$HOST_PRESSURE_BIN" > "$host_tmp" 2>&1; then :; else
  printf 'host-pressure capture unavailable (exit=%s)\n' "$?" >> "$host_tmp"
fi
fm_account_safe_file_destination "$HOST_CACHE" \
  || { rm -f "$host_tmp"; emit_result 2 "inconclusive: unsafe host-pressure evidence destination"; }
mv "$host_tmp" "$HOST_CACHE" \
  || { rm -f "$host_tmp"; emit_result 2 "inconclusive: cannot publish host-pressure evidence"; }
HOST_EVIDENCE=$HOST_CACHE

read_run_record() {  # [exact-run-id]
  local expected=${1:-} out
  if [ -n "$expected" ]; then
    out=$(cd "$WORKTREE" && "$NM_BIN" axi status --run "$expected" 2>/dev/null) || return 1
  else
    out=$(cd "$WORKTREE" && "$NM_BIN" axi status 2>/dev/null) || return 1
  fi
  RUN_ID=$(printf '%s\n' "$out" | sed -n 's/^  id: *"\([^"]*\)".*/\1/p' | head -1)
  RUN_BRANCH=$(printf '%s\n' "$out" | sed -n 's/^  branch: *\([^[:space:]]*\).*/\1/p' | head -1)
  RUN_BRANCH=${RUN_BRANCH#\"}; RUN_BRANCH=${RUN_BRANCH%\"}
  RUN_STATUS=$(printf '%s\n' "$out" | sed -n 's/^  status: *\([^[:space:]]*\).*/\1/p' | head -1)
  [ -n "$RUN_ID" ] && [ -n "$RUN_BRANCH" ] && [ -n "$RUN_STATUS" ] || return 1
  [ "$RUN_BRANCH" = "$OWN_BRANCH" ] || return 1
  [ -z "$expected" ] || [ "$RUN_ID" = "$expected" ]
}

read_run_record || emit_result 2 "inconclusive: no exact branch-matched no-mistakes run record for $ID"
START_RUN=$RUN_ID
case "$START_RUN" in ''|*[!A-Za-z0-9_-]*) emit_result 2 "inconclusive: unsafe run id in no-mistakes status" ;; esac
[ "$RUN_STATUS" = running ] || emit_result 2 "inconclusive: run $START_RUN status is $RUN_STATUS, not running"
read_run_record "$START_RUN" \
  || emit_result 2 "inconclusive: exact run ID and branch could not be re-verified for $START_RUN"
[ "$RUN_STATUS" = running ] || emit_result 2 "inconclusive: exact run $START_RUN status is $RUN_STATUS, not running"

counts=
cpu_samples=
previous_cpu_time=
cpu_delta=0
any_process=0
i=1
while [ "$i" -le "$SAMPLES" ]; do
  sample_ps=$(mktemp "$STATE/.run-liveness-ps-$ID.XXXXXX") \
    || emit_result 2 "inconclusive: cannot stage process sample for run $START_RUN"
  sample_cwd=$(mktemp "$STATE/.run-liveness-cwd-$ID.XXXXXX") \
    || { rm -f "$sample_ps"; emit_result 2 "inconclusive: cannot stage cwd sample for run $START_RUN"; }
  if ! FM_RUN_LIVENESS_SAMPLER_PID=$$ "$PS_BIN" axww -o pid=,ppid=,%cpu=,time=,command= > "$sample_ps" 2>/dev/null \
    || ! FM_RUN_LIVENESS_SAMPLER_PID=$$ "$CWD_BIN" -d cwd -F pn > "$sample_cwd" 2>/dev/null; then
    rm -f "$sample_ps" "$sample_cwd"
    emit_result 2 "inconclusive: process ownership could not be sampled for run $START_RUN"
  fi
  snapshot=$(awk -v self="$$" -v run="/$START_RUN/" '
          FILENAME == ARGV[1] {
            if ($0 ~ /^p[0-9]+$/) cwd_pid = substr($0, 2)
            else if ($0 ~ /^n\// && cwd_pid != "") cwd[cwd_pid] = substr($0, 2)
            next
          }
          {
            pid = $1
            rows += 1
            parent[pid] = $2
            process_cpu[pid] = $3
            process_time[pid] = $4
            if (index(cwd[pid], "/.no-mistakes/worktrees/") && index(cwd[pid], run)) {
              seed[pid] = 1
            }
          }
          END {
            sampler[self] = 1
            for (pass = 1; pass <= rows; pass += 1) {
              for (pid in parent) {
                if (sampler[parent[pid]]) sampler[pid] = 1
              }
            }
            for (pid in seed) {
              if (!sampler[pid]) owned[pid] = 1
            }
            for (pass = 1; pass <= rows; pass += 1) {
              for (pid in parent) {
                if (!sampler[pid] && owned[parent[pid]]) owned[pid] = 1
              }
            }
            for (pid in owned) {
              if (!owned[pid]) continue
              count += 1
              cpu += process_cpu[pid]
              split(process_time[pid], a, /[:-]/)
              n = length(a)
              if (n == 2) secs += a[1] * 60 + a[2]
              else if (n == 3) secs += a[1] * 3600 + a[2] * 60 + a[3]
              else if (n == 4) secs += a[1] * 86400 + a[2] * 3600 + a[3] * 60 + a[4]
            }
            printf "%d\t%.1f\t%.0f", count + 0, cpu + 0, secs + 0
          }' "$sample_cwd" "$sample_ps") || {
    rm -f "$sample_ps" "$sample_cwd"
    emit_result 2 "inconclusive: process table could not be sampled for run $START_RUN"
  }
  rm -f "$sample_ps" "$sample_cwd"
  count=${snapshot%%$'\t'*}
  rest=${snapshot#*$'\t'}
  cpu=${rest%%$'\t'*}
  cpu_time=${rest##*$'\t'}
  [ "$count" -eq 0 ] || any_process=1
  if [ -n "$previous_cpu_time" ] && [ "$cpu_time" -gt "$previous_cpu_time" ]; then
    cpu_delta=$((cpu_delta + cpu_time - previous_cpu_time))
  fi
  previous_cpu_time=$cpu_time
  counts="${counts}${counts:+,}$count"
  cpu_samples="${cpu_samples}${cpu_samples:+,}$cpu"
  if [ "$i" -lt "$SAMPLES" ]; then sleep "$INTERVAL"; fi
  i=$((i + 1))
done

read_run_record "$START_RUN" || emit_result 2 "inconclusive: exact run record disappeared after sampling run $START_RUN"
if [ "$RUN_ID" != "$START_RUN" ] || [ "$RUN_STATUS" != running ]; then
  emit_result 2 "inconclusive: run record changed during sampling (start=$START_RUN end=${RUN_ID:-none} status=${RUN_STATUS:-none})"
fi

baseline_seconds=
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$DB" ] && [ ! -L "$DB" ]; then
  baseline_seconds=$(sqlite3 "$DB" "
    WITH recent(duration_ms) AS (
      SELECT sr.duration_ms
      FROM step_results sr
      JOIN runs r ON r.id = sr.run_id
      WHERE sr.step_name = 'test'
        AND sr.status = 'completed'
        AND sr.duration_ms > 0
        AND r.repo_id = (SELECT repo_id FROM runs WHERE id = '$START_RUN')
      ORDER BY sr.completed_at DESC
      LIMIT 20
    ), ranked AS (
      SELECT duration_ms, row_number() OVER (ORDER BY duration_ms) AS rn,
             count(*) OVER () AS n
      FROM recent
    )
    SELECT CAST(avg(duration_ms) / 1000 AS INTEGER)
    FROM ranked
    WHERE rn IN ((n + 1) / 2, (n + 2) / 2);
  " 2>/dev/null || true)
fi
case "$baseline_seconds" in ''|*[!0-9]*) baseline_seconds=unknown ;; esac

evidence="run=$START_RUN samples=$SAMPLES interval=${INTERVAL}s counts=$counts cpu=$cpu_samples cpu_delta=${cpu_delta}s repo_test_baseline=${baseline_seconds}s"
if [ "$any_process" = 1 ]; then
  emit_result 0 "busy: $evidence"
fi
emit_result 1 "unknown: $evidence (absence of observed work never proves idle, death, or a wedge)"
