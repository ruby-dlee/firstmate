#!/usr/bin/env bash
# Terminal-state automatic reclamation behavior.
# Ordinary fm-teardown.sh remains the only landed-work authority; these tests
# cover supervision routing, refusal preservation, secondmate exclusion, and
# exact no-mistakes/agent process cleanup after successful teardown.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AUTO_REAP="$ROOT/bin/fm-auto-reap.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-auto-reap-tests)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
ORDER_LOG="$TMP_ROOT/order.log"
TEARDOWN_LOG="$TMP_ROOT/teardown.log"
LIVE_PIDS=
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"
fm_git_identity

cleanup_auto_reap_tests() {
  local pid
  for pid in $LIVE_PIDS; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup_auto_reap_tests EXIT

cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'pull_request:' "  state: ${FM_FAKE_PR_STATE:-merged}"
SH

cat > "$FAKEBIN/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_CREW_STATE:-state: failed · source: status-log · failed cleanly}"
SH

cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  axi)
    printf 'runs[1]{id,branch,status,head,pr}:\n'
    printf '  "%s",%s,running,abc1234,""\n' \
      "${FM_FAKE_NM_RUN_ID:-RUN-1}" "${FM_FAKE_NM_BRANCH:?}"
    ;;
  "axi status")
    printf '%s\n' \
      'run:' \
      "  id: \"${FM_FAKE_NM_RUN_ID:-RUN-1}\"" \
      "  branch: ${FM_FAKE_NM_BRANCH:?}" \
      '  status: running' \
      '  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:'
    printf '    review,running,1s,active,"%s",round-1\n' "${FM_FAKE_NM_AGENT_PID:-}"
    ;;
  "runs --limit 200")
    printf '  running      %s abc1234  2026-07-29 00:00\n' "${FM_FAKE_NM_BRANCH:?}"
    ;;
  "axi abort --run "*)
    printf 'abort\n' >> "${FM_FAKE_ORDER_LOG:?}"
    printf '%s\n' "$*" >> "${FM_FAKE_NM_LOG:?}"
    if [ "${FM_FAKE_NM_ABORT_STATUS:-0}" -ne 0 ]; then
      exit "$FM_FAKE_NM_ABORT_STATUS"
    fi
    if [ -n "${FM_FAKE_NM_AGENT_PID:-}" ]; then
      kill "$FM_FAKE_NM_AGENT_PID" 2>/dev/null || true
    fi
    ;;
  *) exit 2 ;;
esac
SH

cat > "$FAKEBIN/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
set -u
id=$1
printf 'teardown\n' >> "${FM_FAKE_ORDER_LOG:?}"
printf '%s\n' "$id" >> "${FM_FAKE_TEARDOWN_LOG:?}"
if [ "${FM_FAKE_TEARDOWN_STATUS:-0}" -ne 0 ]; then
  printf 'REFUSED: worktree has uncommitted or unlanded work\n' >&2
  exit "$FM_FAKE_TEARDOWN_STATUS"
fi
if [ -n "${FM_FAKE_CREW_PID:-}" ]; then
  kill "$FM_FAKE_CREW_PID" 2>/dev/null || true
fi
rm -f "$FM_STATE_OVERRIDE/$id.meta" "$FM_STATE_OVERRIDE/$id.status" \
  "$FM_STATE_OVERRIDE/$id.check.sh"
printf 'teardown %s complete\n' "$id"
SH
chmod +x "$FAKEBIN/gh-axi" "$FAKEBIN/fm-crew-state.sh" \
  "$FAKEBIN/no-mistakes" "$FAKEBIN/fm-teardown.sh"

export FM_HOME="$HOME_DIR"
export FM_STATE_OVERRIDE="$HOME_DIR/state"
export FM_DATA_OVERRIDE="$HOME_DIR/data"
export FM_AUTO_REAP_TEST_HOOKS=firstmate-auto-reap-tests-v2
export FM_AUTO_REAP_GH_AXI_BIN="$FAKEBIN/gh-axi"
export FM_AUTO_REAP_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh"
export FM_AUTO_REAP_NO_MISTAKES_BIN="$FAKEBIN/no-mistakes"
export FM_AUTO_REAP_TEARDOWN_BIN="$FAKEBIN/fm-teardown.sh"
export FM_FAKE_ORDER_LOG="$ORDER_LOG"
export FM_FAKE_TEARDOWN_LOG="$TEARDOWN_LOG"
export FM_FAKE_NM_LOG="$TMP_ROOT/no-mistakes.log"

reset_fakes() {
  : > "$ORDER_LOG"
  : > "$TEARDOWN_LOG"
  : > "$FM_FAKE_NM_LOG"
  FM_FAKE_PR_STATE=merged
  FM_FAKE_TEARDOWN_STATUS=0
  FM_FAKE_CREW_PID=
  FM_FAKE_NM_AGENT_PID=
  FM_FAKE_NM_RUN_ID=RUN-1
  FM_FAKE_NM_ABORT_STATUS=0
  FM_FAKE_CREW_STATE='state: failed · source: status-log · failed cleanly'
  export FM_FAKE_PR_STATE FM_FAKE_TEARDOWN_STATUS FM_FAKE_CREW_PID
  export FM_FAKE_NM_AGENT_PID FM_FAKE_NM_RUN_ID FM_FAKE_NM_ABORT_STATUS
  export FM_FAKE_CREW_STATE
}

make_task() {  # <id> <kind> <mode>
  local id=$1 kind=$2 mode=$3 worktree
  worktree="$TMP_ROOT/$id"
  fm_git_init_commit "$worktree"
  git -C "$worktree" checkout -qb "fm/$id"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$worktree" \
    "project=$worktree" \
    "kind=$kind" \
    "mode=$mode" \
    "generation_id=generation-$id" \
    "pr=https://github.com/acme/repo/pull/7"
}

wait_dead() {  # <pid>
  local pid=$1 attempt=0
  while kill -0 "$pid" 2>/dev/null && [ "$attempt" -lt 40 ]; do
    sleep 0.05
    attempt=$((attempt + 1))
  done
  ! kill -0 "$pid" 2>/dev/null
}

test_terminal_task_reclaims_task_and_processes() {
  local id=terminal-processes crew_pid agent_pid out rc order
  reset_fakes
  make_task "$id" ship no-mistakes
  printf 'done: PR checks green\n' > "$HOME_DIR/state/$id.status"
  sleep 300 &
  crew_pid=$!
  sleep 300 &
  agent_pid=$!
  LIVE_PIDS="$LIVE_PIDS $crew_pid $agent_pid"
  FM_FAKE_CREW_PID=$crew_pid
  FM_FAKE_NM_AGENT_PID=$agent_pid
  FM_FAKE_NM_BRANCH="fm/$id"
  export FM_FAKE_CREW_PID FM_FAKE_NM_AGENT_PID FM_FAKE_NM_BRANCH

  out=$("$AUTO_REAP" task "$id" pr-merged 2>&1)
  rc=$?
  expect_code 0 "$rc" "terminal task auto-reap"
  assert_contains "$out" "auto-reap collected task=$id" "terminal task did not report collection"
  assert_absent "$HOME_DIR/state/$id.meta" "terminal task metadata survived collection"
  wait_dead "$crew_pid" || fail "task endpoint process survived successful teardown"
  wait_dead "$agent_pid" || fail "no-mistakes agent process survived exact run abort"
  order=$(tr '\n' ' ' < "$ORDER_LOG")
  assert_contains "$order" "teardown abort" "no-mistakes run was not collected after teardown succeeded"
  assert_contains "$(cat "$FM_FAKE_NM_LOG")" "axi abort --run RUN-1" \
    "exact no-mistakes run id was not aborted"
  wait "$crew_pid" 2>/dev/null || true
  wait "$agent_pid" 2>/dev/null || true
  pass "terminal task is reclaimed and its endpoint plus no-mistakes agent processes are collected"
}

test_supervision_scan_discovers_merged_terminal_task() {
  local id=scan-merged out rc
  reset_fakes
  make_task "$id" ship direct-PR
  printf 'done: PR checks green\n' > "$HOME_DIR/state/$id.status"

  out=$("$AUTO_REAP" scan 2>&1)
  rc=$?
  expect_code 0 "$rc" "merged terminal supervision scan"
  assert_contains "$out" "auto-reap collected task=$id trigger=pr-merged" \
    "supervision scan did not surface the merged terminal task"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "supervision scan left merged terminal task metadata"
  assert_contains "$(cat "$TEARDOWN_LOG")" "$id" \
    "supervision scan did not route the merged terminal task through teardown"
  pass "supervision scan discovers and reclaims a merged terminal task"
}

test_teardown_refusal_preserves_unlanded_task_and_processes() {
  local id=retained-unlanded crew_pid agent_pid out rc
  reset_fakes
  make_task "$id" ship no-mistakes
  printf 'failed: validation failed\n' > "$HOME_DIR/state/$id.status"
  sleep 300 &
  crew_pid=$!
  sleep 300 &
  agent_pid=$!
  LIVE_PIDS="$LIVE_PIDS $crew_pid $agent_pid"
  FM_FAKE_CREW_PID=$crew_pid
  FM_FAKE_NM_AGENT_PID=$agent_pid
  FM_FAKE_NM_BRANCH="fm/$id"
  FM_FAKE_TEARDOWN_STATUS=1
  export FM_FAKE_CREW_PID FM_FAKE_NM_AGENT_PID FM_FAKE_NM_BRANCH FM_FAKE_TEARDOWN_STATUS

  set +e
  out=$("$AUTO_REAP" task "$id" failed 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "unlanded task auto-reap refusal"
  assert_contains "$out" "ordinary teardown refused" "teardown refusal was not surfaced"
  assert_present "$HOME_DIR/state/$id.meta" "refused task metadata was removed"
  assert_present "$TMP_ROOT/$id" "refused task worktree was removed"
  kill -0 "$crew_pid" 2>/dev/null || fail "endpoint was collected after teardown refusal"
  kill -0 "$agent_pid" 2>/dev/null || fail "no-mistakes agent was collected after teardown refusal"
  assert_not_contains "$(cat "$FM_FAKE_NM_LOG")" "axi abort" \
    "no-mistakes run was aborted before the landed-work proof succeeded"
  kill "$crew_pid" "$agent_pid" 2>/dev/null || true
  wait "$crew_pid" 2>/dev/null || true
  wait "$agent_pid" 2>/dev/null || true
  rm -f "$HOME_DIR/state/$id.meta" "$HOME_DIR/state/$id.status"
  pass "ordinary teardown refusal retains unlanded task state and every attributed process"
}

test_orphaned_run_cleanup_retries_from_durable_identity() {
  local id=orphaned-run agent_pid out rc
  reset_fakes
  make_task "$id" ship no-mistakes
  printf 'done: PR checks green\n' > "$HOME_DIR/state/$id.status"
  sleep 300 &
  agent_pid=$!
  LIVE_PIDS="$LIVE_PIDS $agent_pid"
  FM_FAKE_NM_AGENT_PID=$agent_pid
  FM_FAKE_NM_BRANCH="fm/$id"
  FM_FAKE_NM_ABORT_STATUS=1
  export FM_FAKE_NM_AGENT_PID FM_FAKE_NM_BRANCH FM_FAKE_NM_ABORT_STATUS

  set +e
  out=$("$AUTO_REAP" task "$id" pr-merged 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "post-teardown process cleanup failure"
  assert_contains "$out" "process cleanup incomplete" \
    "post-teardown process cleanup failure was not surfaced"
  assert_absent "$HOME_DIR/state/$id.meta" "successful teardown left task metadata"
  assert_present "$HOME_DIR/state/.auto-reap-run-$id.pending" \
    "failed process cleanup lost its exact durable run identity"
  kill -0 "$agent_pid" 2>/dev/null || fail "failed abort unexpectedly collected the test agent"

  FM_FAKE_NM_ABORT_STATUS=0
  export FM_FAKE_NM_ABORT_STATUS
  out=$("$AUTO_REAP" scan 2>&1)
  rc=$?
  expect_code 0 "$rc" "orphan process retry scan"
  assert_contains "$out" "auto-reap collected orphan task=$id" \
    "supervision scan did not surface orphan process collection"
  wait_dead "$agent_pid" || fail "durable orphan retry did not collect the attributed agent"
  wait "$agent_pid" 2>/dev/null || true
  assert_absent "$HOME_DIR/state/.auto-reap-run-$id.pending" \
    "successful orphan process retry left its durable marker"
  pass "orphaned no-mistakes agent cleanup retries from an exact durable run identity"
}

test_secondmate_is_never_automatically_reclaimed() {
  local id=persistent-secondmate out rc
  reset_fakes
  make_task "$id" secondmate secondmate
  printf 'failed: synthetic terminal-looking status\n' > "$HOME_DIR/state/$id.status"
  FM_FAKE_NM_BRANCH="fm/$id"
  export FM_FAKE_NM_BRANCH

  out=$("$AUTO_REAP" scan 2>&1)
  rc=$?
  expect_code 0 "$rc" "secondmate scan"
  [ -z "$out" ] || fail "secondmate scan produced a reclamation result: $out"
  assert_present "$HOME_DIR/state/$id.meta" "secondmate metadata was removed by scan"
  [ ! -s "$TEARDOWN_LOG" ] || fail "secondmate scan invoked teardown"

  set +e
  out=$("$AUTO_REAP" task "$id" failed 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "explicit automatic secondmate refusal"
  assert_contains "$out" "secondmates are never automatically reclaimed" \
    "explicit automatic secondmate refusal was unclear"
  [ ! -s "$TEARDOWN_LOG" ] || fail "explicit automatic secondmate path invoked teardown"
  pass "persistent secondmates are excluded before every automatic teardown path"
}

test_ambiguous_metadata_is_retained_without_teardown() {
  local id=ambiguous-meta worktree out rc
  reset_fakes
  worktree="$TMP_ROOT/$id"
  fm_git_init_commit "$worktree"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$worktree" \
    "project=$worktree" \
    "mode=direct-PR"
  printf 'failed: synthetic terminal status\n' > "$HOME_DIR/state/$id.status"

  set +e
  out=$("$AUTO_REAP" task "$id" failed 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "ambiguous metadata auto-reap refusal"
  assert_contains "$out" "metadata field kind is missing or ambiguous" \
    "ambiguous metadata refusal was not explicit"
  assert_present "$HOME_DIR/state/$id.meta" "ambiguous metadata was automatically removed"
  [ ! -s "$TEARDOWN_LOG" ] || fail "ambiguous metadata reached ordinary teardown"
  rm -f "$HOME_DIR/state/$id.meta" "$HOME_DIR/state/$id.status"
  pass "ambiguous task metadata is retained before automatic teardown"
}

test_real_teardown_authority_retains_dirty_worktree() {
  local id=dirty-real case_dir project worktree pool slot fakebin out rc
  reset_fakes
  case_dir="$TMP_ROOT/real-dirty"
  project="$case_dir/project"
  pool="$case_dir/pool"
  slot="$pool/1"
  worktree="$slot/worktree"
  fakebin="$case_dir/fakebin"
  mkdir -p "$slot" "$fakebin"
  fm_git_init_commit "$project"
  git -C "$project" branch -M main
  git -C "$project" worktree add -qb "fm/$id" "$worktree"
  python3 - "$pool/treehouse-state.json" "$worktree" "firstmate-$id" <<'PY'
import json
import sys

path, worktree, holder = sys.argv[1:]
with open(path, "w", encoding="utf-8") as stream:
    json.dump(
        {
            "worktrees": [
                {
                    "path": worktree,
                    "leased": True,
                    "lease_holder": holder,
                    "destroying": False,
                }
            ]
        },
        stream,
    )
PY
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
state="$(dirname "$0")/.live"
case "${1:-}" in
  display-message) [ -f "$state" ] || exit 1; printf 'bash\n'; exit 0 ;;
  list-windows) [ ! -f "$state" ] || printf 'fm-dirty-real\n'; exit 0 ;;
  kill-window) rm -f "$state"; exit 0 ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse return must not run for dirty work\n' >&2
exit 99
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'count: 0 (showing first 0)' 'pull_requests[]: []'
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse" "$fakebin/gh-axi"
  : > "$fakebin/.live"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=fm-$id" \
    "tmux_session_target=firstmate:fm-$id" \
    "worktree=$worktree" \
    "project=$project" \
    "kind=ship" \
    "mode=direct-PR" \
    "generation_id=generation-$id"
  printf 'failed: stopped after an implementation failure\n' > "$HOME_DIR/state/$id.status"
  printf 'uncommitted\n' > "$worktree/valuable.txt"
  FM_FAKE_CREW_STATE='state: failed · source: status-log · stopped after failure'
  export FM_FAKE_CREW_STATE
  unset FM_AUTO_REAP_TEARDOWN_BIN
  set +e
  out=$(PATH="$fakebin:$PATH" "$AUTO_REAP" task "$id" failed 2>&1)
  rc=$?
  set -e
  export FM_AUTO_REAP_TEARDOWN_BIN="$FAKEBIN/fm-teardown.sh"

  expect_code 1 "$rc" "real teardown dirty refusal"
  assert_contains "$out" "uncommitted changes" \
    "automatic path did not surface real teardown's dirty-work proof"
  assert_present "$HOME_DIR/state/$id.meta" "real teardown refusal removed task metadata"
  assert_present "$worktree/valuable.txt" "real teardown refusal discarded uncommitted work"
  pass "automatic path reuses real teardown authority and preserves a dirty worktree"
}

test_watcher_runs_automatic_scan_inside_supervision_loop() {
  local fake_root home state out worktree
  reset_fakes
  fake_root="$TMP_ROOT/watch-root"
  home="$TMP_ROOT/watch-home"
  state="$home/state"
  out="$TMP_ROOT/watch.out"
  worktree="$TMP_ROOT/watch-terminal"
  mkdir -p "$fake_root/bin" "$state" "$home/config"
  fm_git_init_commit "$worktree"
  cat > "$fake_root/bin/fm-account-session-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fake_root/bin/fm-report-stack.mjs" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) exit 0 ;;
esac
exit 1
SH
  chmod +x "$fake_root/bin/"* "$FAKEBIN/tmux"
  fm_write_meta "$state/terminal.meta" \
    "window=" "worktree=$worktree" "project=$worktree" \
    "kind=ship" "mode=direct-PR"
  printf 'failed: stopped without unlanded work\n' > "$state/terminal.status"
  touch "$state/.last-account-session-sync" "$state/.last-report-retention"
  PATH="$FAKEBIN:$PATH" \
    FM_ROOT_OVERRIDE="$fake_root" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" \
    FM_AUTO_REAP_TEST_HOOKS=firstmate-auto-reap-tests-v2 \
    FM_AUTO_REAP_TEARDOWN_BIN="$FAKEBIN/fm-teardown.sh" \
    FM_AUTO_REAP_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: failed · source: status-log · stopped without unlanded work' \
    FM_CHECK_INTERVAL=0 \
    FM_SIGNAL_GRACE=1 \
    FM_HEARTBEAT=999999 \
    FM_POLL=1 \
    "$WATCH" > "$out"
  assert_contains "$(cat "$out")" "auto-reap collected task=terminal" \
    "watcher did not surface automatic collection"
  assert_absent "$state/terminal.meta" "watcher supervision scan did not reclaim terminal task"
  assert_contains "$(cat "$TEARDOWN_LOG")" "terminal" \
    "watcher did not route the terminal task through the automatic reaper into teardown"
  pass "supervision loop invokes the real automatic reaper and surfaces terminal reclamation"
}

test_terminal_reap_preserves_coalesced_actionable_signal() {
  local home state out terminal_worktree unrelated_worktree queue
  reset_fakes
  home="$TMP_ROOT/watch-coalesced-home"
  state="$home/state"
  out="$TMP_ROOT/watch-coalesced.out"
  terminal_worktree="$TMP_ROOT/watch-coalesced-terminal"
  unrelated_worktree="$TMP_ROOT/watch-coalesced-unrelated"
  mkdir -p "$state" "$home/config"
  fm_git_init_commit "$terminal_worktree"
  fm_git_init_commit "$unrelated_worktree"
  fm_write_meta "$state/terminal.meta" \
    "window=" "worktree=$terminal_worktree" "project=$terminal_worktree" \
    "kind=ship" "mode=direct-PR"
  fm_write_meta "$state/unrelated.meta" \
    "window=" "worktree=$unrelated_worktree" "project=$unrelated_worktree" \
    "kind=ship" "mode=direct-PR"
  printf 'failed: stopped without unlanded work\n' > "$state/terminal.status"
  printf 'needs-decision: preserve this independent wake\n' > "$state/unrelated.status"
  touch "$state/.last-check" "$state/.last-account-session-sync" \
    "$state/.last-report-retention"

  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" \
    FM_AUTO_REAP_TEST_HOOKS=firstmate-auto-reap-tests-v2 \
    FM_AUTO_REAP_TEARDOWN_BIN="$FAKEBIN/fm-teardown.sh" \
    FM_AUTO_REAP_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: failed · source: status-log · stopped without unlanded work' \
    FM_CHECK_INTERVAL=999999 \
    FM_SIGNAL_GRACE=1 \
    FM_HEARTBEAT=999999 \
    FM_POLL=1 \
    "$WATCH" > "$out"
  assert_contains "$(cat "$out")" "auto-reap collected task=terminal" \
    "terminal signal did not enter automatic reclamation"
  assert_contains "$(cat "$out")" "$state/unrelated.status" \
    "coalesced independent actionable signal disappeared from the surfaced reason"
  queue=$(cat "$state/.wake-queue")
  assert_contains "$queue" "unrelated.status" \
    "coalesced independent actionable signal was not durably queued"
  assert_absent "$state/terminal.meta" "coalesced terminal task was not reclaimed"
  assert_present "$state/unrelated.meta" \
    "automatic reclamation crossed into an unrelated actionable task"
  pass "terminal reclamation preserves unrelated signals coalesced in the same watcher cycle"
}

test_terminal_task_reclaims_task_and_processes
test_supervision_scan_discovers_merged_terminal_task
test_teardown_refusal_preserves_unlanded_task_and_processes
test_orphaned_run_cleanup_retries_from_durable_identity
test_secondmate_is_never_automatically_reclaimed
test_ambiguous_metadata_is_retained_without_teardown
test_real_teardown_authority_retains_dirty_worktree
test_watcher_runs_automatic_scan_inside_supervision_loop
test_terminal_reap_preserves_coalesced_actionable_signal

printf 'all fm-auto-reap tests passed\n'
