#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# tests/fm-watch-pause-absorb.test.sh - pause absorption requires a durable
# declaration, no open keyed decision, and precedence-compatible current state.
#
# The third row is the safety boundary and the reason this is not simply "absorb
# every pause": a lane with an unanswered captain question must never go quiet, so
# the open/resolved fold (status_open_decisions) gates absorption independently of
# the pause verb. Run this file on demand to reproduce the incident.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"

fm_test_tmproot_into TMP_ROOT fm-watch-pause-absorb-tests

seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

wait_live() {
  local pid=$1 limit i=0
  limit=$(fm_test_liveness_iterations "${2:-30}" 0.1)
  while [ "$i" -lt "$limit" ]; do
    is_live_non_zombie "$pid" || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

# Drive one real fm-watch.sh poll cycle over a single stale, idle, paused pane and
# report what triage did with it. Sets four globals rather than echoing, so a case
# can assert on the durable artifacts as well as the outcome: TRIAGE (absorbed or
# surfaced), PAUSE_FLAG, WAKE_QUEUE, WATCH_OUT. Call it directly, never in a command
# substitution, or the globals are lost with the subshell.
#
# <verdict> is the canned fm-crew-state.sh answer. The pane is primed as already-stale
# (.hash/.count pre-seeded) so the poll reaches stale triage immediately, and
# .seen-* is primed so the signal scan does not pre-empt it. A generous
# FM_PAUSE_RESURFACE_SECS keeps a legitimate absorb silent, so any wake at all is a
# genuine surface rather than the hourly pause recheck.
# PRESEED_PAUSED=1 starts from an already-absorbed pause with an old proof signature.
PRESEED_PAUSED=0
run_pause_case() {  # <case-name> <status-stream> <crew-state-verdict>
  local name=$1 stream=$2 verdict=$3
  local dir state fakebin out capture window key pane_hash sig pid
  dir=$(make_case "$name"); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture="$dir/pane.txt"
  window="test:fm-$name"
  printf 'idle at the composer' > "$capture"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/$name.meta"
  printf '%s' "$stream" > "$state/$name.status"
  sig=$(seen_sig "$state/$name.status"); printf '%s' "$sig" > "$state/.seen-${name}_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle at the composer")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  if [ "$PRESEED_PAUSED" = 1 ]; then
    : > "$state/.paused-$key"
    printf 'stale-signature-from-an-earlier-stream' > "$state/.paused-rechecked-$key"
  fi

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE="$verdict" FM_PAUSE_RESURFACE_SECS=999999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" &
  pid=$!
  if wait_live "$pid" 30; then TRIAGE=absorbed; else TRIAGE=surfaced; fi
  reap "$pid"

  # Cross-check the outcome against the durable artifacts triage leaves behind, so a
  # case can never pass on liveness timing alone.
  PAUSE_FLAG=absent; [ -e "$state/.paused-$key" ] && PAUSE_FLAG=present
  WAKE_QUEUE=$(cat "$state/.wake-queue" 2>/dev/null || true)
  WATCH_OUT=$(cat "$out" 2>/dev/null || true)
}

# --- branch 1: live-but-idle paused pane -----------------------------------------
# A parked run yields to a pause that names its exact run id.
test_live_idle_paused_pane_absorbed() {
  run_pause_case live-idle-paused \
    'paused: work complete and verified; waiting on the merge of PR 882 by the main firstmate; owner=main firstmate; clears=PR 882 is merged; run=01RUN
' \
    'state: parked · source: run-step · parked at ci: 1 finding(s) · run: 01RUN'
  [ "$TRIAGE" = absorbed ] \
    || fail "live-but-idle declared pause was surfaced as a suspected wedge: $WATCH_OUT"
  [ "$PAUSE_FLAG" = present ] \
    || fail "live-but-idle declared pause never recorded .paused-<key> (handle_paused_stale did not run)"
  [ -z "$WAKE_QUEUE" ] || fail "live-but-idle declared pause enqueued a wake: $WAKE_QUEUE"
  pass "live-but-idle paused pane: a parked run-step no longer vetoes a declared pause"
}

# --- branch 2: dead paused pane --------------------------------------------------
# A gone backend target is unknown current state and remains actionable.
test_dead_paused_pane_surfaced() {
  run_pause_case dead-paused \
    'paused: agent is quota-dead, work preserved and verified; waiting on the account reset; owner=account owner; clears=the account quota resets
' \
    'state: unknown · source: none · backend target gone: test:fm-dead-paused'
  [ "$TRIAGE" = surfaced ] \
    || fail "unknown current state was hidden behind a pause: $WATCH_OUT"
  [ "$PAUSE_FLAG" = absent ] \
    || fail "unknown current state recorded .paused-<key>"
  printf '%s' "$WAKE_QUEUE" | grep -q 'stale' \
    || fail "unknown current state did not enqueue a stale wake: $WAKE_QUEUE"
  pass "dead paused pane: unknown current state retains precedence"
}

# --- branch 3: paused with an OPEN decision --------------------------------------
# The safety boundary. The pause verb is the LAST line, so a last-line read alone
# says "absorb"; only the durable open/resolved fold sees the still-unanswered
# question underneath it. That lane must keep surfacing.
test_paused_with_open_decision_surfaced() {
  run_pause_case paused-open-decision \
    'needs-decision [key=rollback-empty-pointer]: merge as-is, or fix the empty-pointer refusal here?
paused: standing by for the decision on the rollback gap; owner=captain; clears=the rollback decision is answered
' \
    'state: paused · source: status-log · standing by for the decision'
  [ "$TRIAGE" = surfaced ] \
    || fail "a pause masking an UNANSWERED decision was absorbed and went quiet"
  [ "$PAUSE_FLAG" = absent ] \
    || fail "a pause masking an unanswered decision was flagged .paused-<key>"
  printf '%s' "$WAKE_QUEUE" | grep -q 'stale' \
    || fail "a pause masking an unanswered decision did not enqueue a stale wake: $WAKE_QUEUE"
  pass "paused with an OPEN decision: an unanswered question still surfaces, pause verb notwithstanding"
}

# --- branch 4: paused with a CLOSED decision -------------------------------------
# c8's real status stream: working -> done -> needs-decision[key] -> resolved[key] ->
# paused. The keyed decision was explicitly closed, so nothing is outstanding and the
# pause is the lane's current, honest statement about its work.
test_paused_with_closed_decision_absorbed() {
  run_pause_case paused-closed-decision \
    'working: rebased PR 882 onto current main, pushed 590fe3ff7, awaiting fresh CI
done: PR https://github.com/Ruby-Labs/relvino/pull/882 checks green; NOT merged
needs-decision [key=rollback-empty-pointer]: merge as-is, or fix the empty-pointer refusal here?
resolved [key=rollback-empty-pointer]: option (a) approved - merge this rebase as-is
paused: work complete and verified; waiting on the merge of PR 882 by the main firstmate; owner=main firstmate; clears=PR 882 is merged; run=01RUN
' \
    'state: parked · source: run-step · parked at ci: 1 finding(s) · run: 01RUN'
  [ "$TRIAGE" = absorbed ] \
    || fail "a pause whose only decision was explicitly resolved was surfaced: $WATCH_OUT"
  [ "$PAUSE_FLAG" = present ] \
    || fail "a pause whose only decision was explicitly resolved never recorded .paused-<key>"
  [ -z "$WAKE_QUEUE" ] || fail "a resolved-then-paused lane enqueued a wake: $WAKE_QUEUE"
  pass "paused with a CLOSED decision: the resolved-then-paused c8 shape absorbs"
}

# --- the same four branches at the classifier level -------------------------------
# The behavioral cases above prove the watcher wires this correctly; this matrix pins
# the decision itself.
test_crew_absorb_class_pause_matrix() {
  local dir state fakebin
  dir=$(make_case absorb-pause-matrix); state="$dir/state"; fakebin="$dir/fakebin"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_FAKE_CREW_STATE FM_STATE_OVERRIDE="$state"

  local paused='paused: waiting on the merge of PR 882; owner=main firstmate; clears=PR 882 is merged; run=01RUN'
  printf '%s\n' "$paused" > "$state/a.status"

  local v
  for v in 'state: parked · source: run-step · parked at ci: 1 finding(s) · run: 01RUN' \
           'state: done · source: run-step · run passed: PR merged (verified) · run: 01RUN' \
           'state: paused · source: status-log · waiting on the merge · run: 01RUN'; do
    FM_FAKE_CREW_STATE="$v"
    [ "$(crew_absorb_class a "$paused")" = paused ] \
      || fail "declared pause not honoured over verdict [$v]"
    crew_is_paused a || fail "crew_is_paused disagreed with the class for verdict [$v]"
  done

  for v in 'state: failed · source: run-step · run cancelled · run: 01RUN' \
           'state: stale · source: run-step · stale run' \
           'state: unknown · source: none · backend target gone'; do
    FM_FAKE_CREW_STATE="$v"
    [ "$(crew_absorb_class a "$paused")" = none ] \
      || fail "authoritative verdict was hidden behind a pause [$v]"
  done

  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at ci: 1 finding(s) · run: 02NEW'
  [ "$(crew_absorb_class a "$paused")" = none ] \
    || fail "pause associated with an older run overrode the current parked run"

  # A crewmate that appended a pause and then STARTED working is working, not paused:
  # active work supersedes the stale declaration. This precedence is unchanged.
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  [ "$(crew_absorb_class a "$paused")" = working ] \
    || fail "an active run-step did not outrank a stale pause declaration"
  FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  [ "$(crew_absorb_class a "$paused")" = working ] \
    || fail "a busy pane did not outrank a stale pause declaration"

  # The pause must be read from the durable stream even when no caller passes it,
  # so the two call sites in bin/fm-watch.sh cannot disagree.
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at ci: 1 finding(s) · run: 01RUN'
  [ "$(crew_absorb_class a)" = paused ] \
    || fail "the declared pause was not read from the status stream when unspecified"

  # An open keyed decision blocks absorption on every verdict.
  printf 'needs-decision [key=api-shape]: which shape?\n%s\n' "$paused" > "$state/a.status"
  for v in 'state: parked · source: run-step · parked at ci: 1 finding(s) · run: 01RUN' \
           'state: unknown · source: none · backend target gone' \
           'state: done · source: run-step · run passed: PR merged (verified) · run: 01RUN' \
           'state: paused · source: status-log · waiting on the merge · run: 01RUN'; do
    FM_FAKE_CREW_STATE="$v"
    [ "$(crew_absorb_class a "$paused")" = none ] \
      || fail "an OPEN decision failed to block absorption under verdict [$v]"
  done
  # ...and stops blocking once it is explicitly resolved.
  printf 'needs-decision [key=api-shape]: which shape?\nresolved [key=api-shape]: option (a)\n%s\n' "$paused" > "$state/a.status"
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at ci: 1 finding(s) · run: 01RUN'
  [ "$(crew_absorb_class a "$paused")" = paused ] \
    || fail "a resolved decision still blocked absorption"

  # A FAILURE reported under the pause verb is not a wait and must never absorb.
  local failpause='paused: error: drive run: reconcile run: read response: i/o timeout; owner=drive; clears=the reconcile run returns'
  printf '%s\n' "$failpause" > "$state/a.status"
  FM_FAKE_CREW_STATE='state: paused · source: status-log · failure-shaped pause'
  [ "$(crew_absorb_class a "$failpause")" = none ] \
    || fail "a failure reported under the pause verb was absorbed as a declared wait"

  # No pause at all is never inferred: absence of a signal is not evidence of a pause.
  printf 'working: still going\n' > "$state/a.status"
  FM_FAKE_CREW_STATE='state: unknown · source: none · backend target gone'
  [ "$(crew_absorb_class a)" = none ] || fail "a lane with no pause was absorbed"
  [ "$(crew_absorb_class "")" = none ] || fail "empty id not classed none"

  unset FM_FAKE_CREW_STATE FM_STATE_OVERRIDE
  pass "crew_absorb_class enforces run association, precedence, and open-decision proof"
}

# --- a pause proof marker cannot outlive the stream it was proven from -------------
test_pause_marker_reproven_when_stream_changes() {
  PRESEED_PAUSED=1
  run_pause_case cached-pause-stale-proof \
    'paused: waiting on the merge of PR 882; owner=main firstmate; clears=PR 882 is merged
needs-decision [key=rollback-empty-pointer]: merge as-is, or fix the empty-pointer refusal here?
paused: standing by for the decision on the rollback gap; owner=captain; clears=the rollback decision is answered
' \
    'state: paused · source: status-log · standing by for the decision'
  PRESEED_PAUSED=0
  [ "$TRIAGE" = surfaced ] \
    || fail "a decision opened after the pause flag rode out the cache window and went quiet"
  printf '%s' "$WAKE_QUEUE" | grep -q 'stale' \
    || fail "the re-proven pause did not enqueue a stale wake: $WAKE_QUEUE"
  pass "a pause proof marker is re-proven whenever the status stream changes"
}

test_pause_moving_during_pipeline_read_refused() {
  export FM_FAKE_CREW_STATE_APPEND_STATUS='blocked: stream advanced during pipeline state read'
  run_pause_case pause-moved-during-proof \
    'paused: awaiting ordered PR merges; owner=merge supervisor; clears=ordered merges complete; run=01RUN
' \
    'state: parked · source: run-step · parked at ci: 1 finding(s) · run: 01RUN'
  unset FM_FAKE_CREW_STATE_APPEND_STATUS
  [ "$TRIAGE" = surfaced ] \
    || fail "a pause invalidated during the crew-state read was absorbed"
  [ "$PAUSE_FLAG" = absent ] \
    || fail "a pause invalidated during the crew-state read wrote .paused-<key>"
  pass "a pause invalidated during pipeline-state validation fails closed"
}

test_live_idle_paused_pane_absorbed
test_dead_paused_pane_surfaced
test_paused_with_open_decision_surfaced
test_paused_with_closed_decision_absorbed
test_pause_marker_reproven_when_stream_changes
test_pause_moving_during_pipeline_read_refused
test_crew_absorb_class_pause_matrix
