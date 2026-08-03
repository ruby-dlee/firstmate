#!/usr/bin/env bash
# Repeated, untruncated, run-owned process-window liveness tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIVE="$ROOT/bin/fm-run-liveness.sh"
fm_test_tmproot_into TMP_ROOT fm-run-liveness

make_case() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/fakebin"
  fm_git_init_commit "$dir/wt"
  git -C "$dir/wt" checkout -qb fm/lane
  fm_write_meta "$dir/home/state/lane.meta" "worktree=$dir/wt" "harness=codex" "kind=ship"
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
n=$(cat "$FM_TEST_NM_COUNT" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FM_TEST_NM_COUNT"
status=running
if [ "${FM_TEST_STATUS_CHANGES:-0}" = 1 ] && [ "$n" -gt 2 ]; then status=completed; fi
run_id=${FM_TEST_RUN_ID:-RUN123}
branch=${FM_TEST_RUN_BRANCH:-fm/lane}
if [ "$#" -eq 4 ] && [ "$1:$2:$3" = axi:status:--run ]; then
  [ "$4" = "$run_id" ] || exit 3
fi
printf 'run:\n  id: "%s"\n  branch: %s\n  status: %s\n' "$run_id" "$branch" "$status"
SH
  cat > "$dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
n=$(cat "$FM_TEST_PS_COUNT" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FM_TEST_PS_COUNT"
value=$(printf '%s' "$FM_TEST_COUNTS" | cut -d, -f"$n")
case "$value" in ''|*[!0-9]*) value=0 ;; esac
i=1
while [ "$i" -le "$value" ]; do
  if [ "$i" -eq 1 ]; then
    printf '101 1 1.5 00:0%d worker /.no-mistakes/worktrees/repo/RUN123/job-1\n' "$n"
  else
    printf '%d 101 1.5 00:0%d compiler-child-%d\n' "$((100 + i))" "$n" "$i"
  fi
  i=$((i + 1))
done
if [ "${FM_TEST_INCLUDE_SAMPLER:-0}" = 1 ]; then
  printf '%s 1 9.0 00:09 sampler /.no-mistakes/worktrees/repo/RUN123/self\n' "$FM_RUN_LIVENESS_SAMPLER_PID"
  printf '%s %s 9.0 00:09 awk /.no-mistakes/worktrees/repo/RUN123/self-child\n' \
    "$((FM_RUN_LIVENESS_SAMPLER_PID + 1))" "$FM_RUN_LIVENESS_SAMPLER_PID"
fi
SH
  cat > "$dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
n=$(cat "$FM_TEST_PS_COUNT" 2>/dev/null || echo 0)
value=$(printf '%s' "$FM_TEST_COUNTS" | cut -d, -f"$n")
case "$value" in ''|*[!0-9]*) value=0 ;; esac
if [ "$value" -gt 0 ]; then
  printf 'p101\nn/.no-mistakes/worktrees/repo/RUN123/work\n'
fi
if [ "${FM_TEST_INCLUDE_SAMPLER:-0}" = 1 ]; then
  printf 'p%s\nn/.no-mistakes/worktrees/repo/RUN123/sampler\n' "$FM_RUN_LIVENESS_SAMPLER_PID"
fi
SH
  cat > "$dir/fakebin/host-pressure" <<'SH'
#!/usr/bin/env bash
printf 'host-pressure observed_at=fixture\nuptime: load averages: 29.0 25.0 20.0\nvm_stat:\nPages swapped out: 42.\n'
SH
  chmod +x "$dir/fakebin/no-mistakes" "$dir/fakebin/ps" "$dir/fakebin/lsof" "$dir/fakebin/host-pressure"
  printf '%s\n' "$dir"
}

run_live() {
  local dir=$1; shift
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_RUN_LIVENESS_NM_BIN="$dir/fakebin/no-mistakes" \
    FM_RUN_LIVENESS_PS_BIN="$dir/fakebin/ps" \
    FM_RUN_LIVENESS_CWD_BIN="$dir/fakebin/lsof" \
    FM_RUN_LIVENESS_HOST_PRESSURE_BIN="$dir/fakebin/host-pressure" \
    FM_RUN_LIVENESS_DB="$dir/state.sqlite" \
    FM_RUN_LIVENESS_TEST_LAB=firstmate-run-liveness-test-lab-v1 \
    FM_RUN_LIVENESS_INTERVAL=0 FM_TEST_NM_COUNT="$dir/nm.count" \
    FM_TEST_PS_COUNT="$dir/ps.count" "$@" "$LIVE" lane
}

test_any_process_sample_is_alive() {
  local dir out rc
  dir=$(make_case any-positive)
  out=$(FM_TEST_COUNTS=0,0,8,0 FM_RUN_LIVENESS_SAMPLES=4 run_live "$dir" env); rc=$?
  expect_code 0 "$rc" "one positive process sample should prove life"
  assert_contains "$out" 'counts=0,0,8,0' "sampler truncated or omitted the per-run process count"
  assert_grep 'load averages: 29.0' "$dir/home/state/.host-pressure-lane" \
    "sampler did not record host load before interpreting liveness"
  pass "run liveness reports BUSY only from an affirmative process sample and records host pressure"
}

test_neighbor_run_is_inconclusive_before_sampling() {
  local dir rc
  dir=$(make_case neighbor-run)
  FM_TEST_RUN_BRANCH=fm/neighbor FM_TEST_COUNTS=9,9 FM_RUN_LIVENESS_SAMPLES=2 \
    run_live "$dir" env >"$dir/out" 2>"$dir/err"; rc=$?
  expect_code 2 "$rc" "neighbor branch must not be sampled as task liveness"
  assert_grep 'no exact branch-matched' "$dir/err" "neighbor-run attribution refusal was unclear"
  [ ! -e "$dir/ps.count" ] || fail "neighboring run reached the process sampler"
  pass "liveness rejects a branch-blind neighboring run before any process decision"
}

test_detached_scout_never_queries_run_state() {
  local dir rc meta_tmp
  dir=$(make_case detached-scout)
  git -C "$dir/wt" checkout -q --detach
  meta_tmp=$(mktemp "$dir/home/state/.lane.meta.XXXXXX")
  sed 's/^kind=ship$/kind=scout/' "$dir/home/state/lane.meta" > "$meta_tmp"
  mv "$meta_tmp" "$dir/home/state/lane.meta"
  FM_TEST_COUNTS=9,9 FM_RUN_LIVENESS_SAMPLES=2 run_live "$dir" env >"$dir/out" 2>"$dir/err"; rc=$?
  expect_code 2 "$rc" "detached scout run lookup refusal"
  assert_grep 'does not own a no-mistakes run' "$dir/err" "scout ownership refusal was unclear"
  [ ! -e "$dir/nm.count" ] || fail "detached scout queried branch-blind no-mistakes status"
  pass "detached scouts never borrow a neighboring lane run for liveness"
}

test_entire_zero_window_is_unknown() {
  local dir rc
  dir=$(make_case all-zero)
  FM_TEST_COUNTS=0,0,0 FM_RUN_LIVENESS_SAMPLES=3 run_live "$dir" env >"$dir/out" 2>"$dir/err"; rc=$?
  expect_code 1 "$rc" "all-zero stable running window should be unknown"
  assert_grep 'never proves idle, death, or a wedge' "$dir/err" "all-zero uncertainty was not explicit"
  assert_no_grep 'wedged' "$dir/err" "process absence was mislabeled as a wedge"
  pass "run liveness reports an entire zero-process window as UNKNOWN, never death"
}

test_sampler_processes_are_not_run_evidence() {
  local dir rc
  dir=$(make_case sampler-self)
  FM_TEST_COUNTS=0,0 FM_TEST_INCLUDE_SAMPLER=1 FM_RUN_LIVENESS_SAMPLES=2 \
    run_live "$dir" env >"$dir/out" 2>"$dir/err"; rc=$?
  expect_code 1 "$rc" "sampler family must not prove run liveness"
  assert_grep 'counts=0,0' "$dir/err" "sampler processes contaminated exact-run counts"
  pass "run liveness excludes its own process family from affirmative evidence"
}

test_record_change_is_inconclusive() {
  local dir rc
  dir=$(make_case changed-record)
  FM_TEST_COUNTS=0,0,0 FM_TEST_STATUS_CHANGES=1 FM_RUN_LIVENESS_SAMPLES=3 \
    run_live "$dir" env >"$dir/out" 2>"$dir/err"; rc=$?
  expect_code 2 "$rc" "a completed run must not be called wedged"
  assert_grep 'run record changed during sampling' "$dir/err" "record-change refusal was unclear"
  pass "run liveness rechecks the same running record after the process window"
}

test_baseline_is_repository_scoped() {
  local dir out
  dir=$(make_case baseline)
  sqlite3 "$dir/state.sqlite" <<'SQL'
CREATE TABLE runs(id TEXT PRIMARY KEY, repo_id TEXT);
CREATE TABLE step_results(run_id TEXT, step_name TEXT, status TEXT, duration_ms INTEGER, completed_at INTEGER);
INSERT INTO runs VALUES('RUN123','repo-a'),('A1','repo-a'),('A2','repo-a'),('A3','repo-a'),('B1','repo-b');
INSERT INTO step_results VALUES('A1','test','completed',60000,1),('A2','test','completed',120000,2),('A3','test','completed',300000,3),('B1','test','completed',999999000,4);
SQL
  out=$(FM_TEST_COUNTS=1,1 FM_RUN_LIVENESS_SAMPLES=2 run_live "$dir" env) || fail "baseline fixture was not alive"
  assert_contains "$out" 'repo_test_baseline=120s' "another repository contaminated the test baseline"
  pass "run liveness derives duration baselines from the same repository only"
}

test_any_process_sample_is_alive
test_entire_zero_window_is_unknown
test_sampler_processes_are_not_run_evidence
test_record_change_is_inconclusive
test_baseline_is_repository_scoped
test_neighbor_run_is_inconclusive_before_sampling
test_detached_scout_never_queries_run_state
