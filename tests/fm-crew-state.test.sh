#!/usr/bin/env bash
# Behavior tests for bin/fm-crew-state.sh - the deterministic crewmate-current-state
# helper.
#
# The status file (state/<id>.status) is a best-effort append-only EVENT LOG, so
# `tail -1` of it reports the last event, not the current state. fm-crew-state
# reads the AUTHORITATIVE source (a matching no-mistakes run-step, else the
# pane busy-signature) and reconciles the possibly-stale log against it. These
# cases pin every branch of that logic, hermetically, over real throwaway git
# repos with a fake `no-mistakes` (run-step source) and a fake `tmux` (pane
# source):
#   (a) active run-step is authoritative                          -> run-step
#   (b) needs-decision/blocked log + resumed run = SUPERSEDED     -> run-step
#   (c) genuine parked run + needs-decision log = NOT superseded  -> run-step
#   (d) terminal run-step is authoritative, while passed PR state is verified
#       against GitHub rather than inferred from the run outcome  -> run-step
#   (e) task-branch attribution: metadata wins over pooled worktree HEAD in both
#       directions; missing/disagreeing/ambiguous identity refuses; another
#       active branch still falls through to the task branch's list row
#   (f) no run + busy pane                                        -> pane
#   (g) no run + idle pane falls to the status-log verb           -> status-log
#   (h) dead pane: no run -> unknown/none; with a run -> run-step (not the shell)
#   (i) kind=scout skips the run lookup                           -> pane/status-log
#   (j) torn-down worktree / missing meta                         -> unknown/none
#   (l) an active or parked run carries separate agent-liveness; a quiet active
#       command step also carries run-liveness from bin/fm-nm-step-liveness.sh,
#       and liveness remains their fail-closed supervision aggregate; the ci
#       step is exempt from run-liveness because it owns no worktree process
#   (k) crew_is_provably_working end-to-end over the REAL helper (not a canned
#       fake fm-crew-state.sh verdict): cross-branch attribution via the runs
#       list -> absorbed; genuinely no run anywhere + idle pane -> surfaced.
#       This is the direct regression pair for the 2026-07-02 herdr incident,
#       proving the watcher's own absorb-only-when-provably-working predicate
#       benefits from the fix in both directions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

CREW_STATE=${FM_CREW_STATE_BIN:-$ROOT/bin/fm-crew-state.sh}
fm_test_tmproot_into TMP_ROOT fm-crew-state
fm_git_identity fmtest fmtest@example.invalid

# A real git repo checked out on <branch>, so the helper's branch attribution
# (git symbolic-ref) resolves like it would for a live crewmate worktree.
make_repo_on_branch() {  # <dir> <branch>
  local dir=$1 branch=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" checkout -q -b "$branch"
}

# A fakebin with a fake `no-mistakes` (serves the env-driven run output) and a
# fake `tmux` (serves a busy or idle pane). The fake no-mistakes mirrors the real
# command surface the helper uses: `axi status`, `axi status --run <id>` (the
# `axi` surface - no runs-listing subcommand exists under it, verified against
# the real CLI), and the actual top-level run-listing command, `no-mistakes
# runs --limit N`, which is plain text - no run id, no quoting - serving
# FM_FAKE_RUNS_LIST verbatim.
make_fakebin() {  # <dir> -> echoes fakebin path
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      status)
        shift
        if [ "${1:-}" = --run ]; then printf '%s\n' "${FM_FAKE_AXI_STATUS_RUN:-}"
        else printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"; fi ;;
      logs)
        printf '%s\n' "${FM_FAKE_CI_LOGS:-}" ;;
    esac
    ;;
  runs)
    printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
esac
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
all=$*
case "${1:-}" in
  display-message)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    case "$all" in
      *'#{pane_current_command}'*) printf '%s\n' "${FM_FAKE_TMUX_COMMAND:-codex}" ;;
      *'#{window_name}'*) printf '%s\n' "${FM_FAKE_TMUX_LABEL:-fm-fixture}" ;;
      *) printf '%%1\n' ;;
    esac ;;
  capture-pane)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    [ "${FM_FAKE_TMUX_CAPTURE_TIMEOUT:-0}" = 0 ] || sleep 30
    [ "${FM_FAKE_TMUX_EMPTY_PANE:-0}" = 0 ] || exit 0
    if [ -n "${FM_FAKE_TMUX_PANE:-}" ]; then printf '%s\n' "$FM_FAKE_TMUX_PANE"
    elif [ "${FM_FAKE_BUSY:-0}" = 1 ]; then printf 'work in progress\nesc to interrupt\n'
    else printf 'all quiet\n> \n'; fi ;;
esac
exit 0
SH
  cat > "$fb/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
[ "${FM_FAKE_GH_AXI_FAIL:-0}" = 0 ] || exit 1
case "${1:-}" in
pr)
  [ "${2:-}" = view ] || exit 2
  [ "${3:-}" = 1 ] || exit 2
  [ "${4:-}" = --repo ] || exit 2
  [ "${5:-}" = o/r ] || exit 2
  cat <<EOF
pull_request:
  number: 1
  state: ${FM_FAKE_PR_STATE:-merged}
EOF
  ;;
api)
  case "${2:-}" in
  /repos/o/r/pulls/[0-9]*) cat <<EOF
state: open
head:
  ref: fm/test
  sha: ${FM_FAKE_PR_HEAD:-abc1234deadbeef}
base:
  ref: main
EOF
    ;;
  /repos/o/r/commits/*)
    [ "${FM_FAKE_REMOTE_COMMIT_FAIL:-0}" = 0 ] || exit 1
    cat <<EOF
sha: ${FM_FAKE_REMOTE_COMMIT_HEAD:-abc1234cafebabeabc1234cafebabeabc1234caf}
commit:
  tree:
    sha: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
EOF
    ;;
  *) exit 2 ;;
  esac
  ;;
*) exit 2 ;;
esac
SH
  cat > "$fb/git" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${FM_FAIL_ON_LOCAL_COMMIT_LOOKUP:-0}" = 1 ] && [ "${3:-}" = rev-parse ] && [ "${4:-}" = --verify ]; then
  exit 99
fi
exec /usr/bin/git "$@"
SH
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  status)
    [ "${2:-}" = --json ] && {
      printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
      exit 0
    } ;;
  server)
    exit 0 ;;
  pane)
    case "${2:-}" in
      list)
        printf '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2"},{"pane_id":"w1:p3","tab_id":"w1:t3"},{"pane_id":"w1:p4","tab_id":"w1:t4"}]}}\n'
        exit 0 ;;
      read)
        [ "${FM_FAKE_HERDR_MISSING:-0}" = 1 ] && exit 1
        if [ "${FM_FAKE_HERDR_BUSY:-0}" = 1 ]; then printf 'work in progress\nesc to interrupt\n'
        else printf 'all quiet\n> \n'; fi
        exit 0 ;;
    esac ;;
  tab)
    case "${2:-}" in
      list)
        printf '{"result":{"tabs":[{"tab_id":"w1:t2","workspace_id":"ws-home","label":"fm-feat-herdr"},{"tab_id":"w1:t3","workspace_id":"ws-home","label":"fm-feat-herdr-idle"},{"tab_id":"w1:t4","workspace_id":"ws-home","label":"fm-feat-herdr-stopped"}]}}\n'
        exit 0 ;;
    esac ;;
  workspace)
    case "${2:-}" in
      list)
        printf '{"result":{"workspaces":[{"workspace_id":"ws-home","label":"firstmate"}]}}\n'
        exit 0 ;;
    esac ;;
  agent)
    case "${2:-}" in
      get)
        [ -n "${FM_FAKE_HERDR_AGENT_STATUS:-}" ] || exit 1
        printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$FM_FAKE_HERDR_AGENT_STATUS"
        exit 0 ;;
    esac ;;
esac
exit 0
SH
  cat > "$fb/fake-liveness" <<'SH'
#!/usr/bin/env bash
set -u
case "${FM_FAKE_LIVENESS_MODE:-}" in
  dead) printf 'liveness: dead · run: 01RUN · procs: 0 · confirmed by a second scan\n' ;;
  alive) printf 'liveness: alive · run: 01RUN · procs: 2 · doing: sleep 30 (00:01)\n' ;;
  empty) exit 0 ;;
  malformed) printf 'not a liveness result\n' ;;
  multiline) printf 'liveness: alive · run: 01RUN · procs: 3\nunexpected extra output\n' ;;
  malformed-verdict) printf 'liveness: alive junk · run: 01RUN · procs: 3\n' ;;
  malformed-procs) printf 'liveness: alive · run: 01RUN · procs: 3x\n' ;;
  alive-zero) printf 'liveness: alive · run: 01RUN · procs: 0\n' ;;
  dead-nonzero) printf 'liveness: dead · run: 01RUN · procs: 2\n' ;;
  empty-procs) printf 'liveness: unknown · run: 01RUN · procs:  · grade: unreadable · missing count · doing: bash t.sh (1:00)\n' ;;
  argv-fields) printf 'liveness: unknown · run: 01RUN · procs: 3 · grade: present-unproven · presence established · doing: python -c "procs: x grade: bogus" (1:00)\n' ;;
  nonzero) exit 9 ;;
  timeout) sleep 30 ;;
  *) printf 'liveness: alive · run: 01RUN · procs: 1 · processes present\n' ;;
esac
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux" "$fb/gh-axi" "$fb/git" "$fb/herdr" "$fb/fake-liveness"
  printf '%s\n' "$fb"
}

make_no_timeout_toolbin() {  # <dir> -> echoes toolbin path
  local dir=$1 tb="$1/notimeoutbin" tool real
  mkdir -p "$tb"
  for tool in bash git grep sed head cut tail dirname perl; do
    real=$(command -v "$tool" || true)
    [ -n "$real" ] || fail "missing tool for no-timeout path: $tool"
    ln -s "$real" "$tb/$tool"
  done
  printf '%s\n' "$tb"
}

# Run the helper for one case dir. FM_FAKE_* env (run output, busy flag) are read
# from the caller's environment by the fakes above.
run_crew_state() {  # <case-dir> <id> [preserve-missing-task-ref]
  local meta="$1/state/$2.meta" wt branch
  if [ "${3:-}" != preserve-missing-task-ref ] && [ -f "$meta" ] \
    && ! grep -q '^worktree_git_ref=' "$meta" \
    && grep -q '^kind=ship$' "$meta"; then
    wt=$(grep '^worktree=' "$meta" | tail -1 | cut -d= -f2-)
    branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    [ -z "$branch" ] || printf 'worktree_git_ref=refs/heads/%s\n' "$branch" >> "$meta"
  fi
  PATH="$1/fakebin:$PATH" FM_STATE_OVERRIDE="$1/state" \
    FM_BACKEND_HERDR_TEST_LAB=firstmate-herdr-test-lab-v1 \
    FM_BACKEND_HERDR_TEST_HOOKS=firstmate-herdr-tests-v1 \
    FM_TEST_HERDR_READSTEER_REACHABLE=1 \
    FM_NM_HOME="${FM_NM_HOME:-$1/nm-home}" \
    FM_NM_SNAP_DIR="${FM_NM_SNAP_DIR:-$1/nm-snap}" \
    "$CREW_STATE" "$2"
}

new_case() {  # <name> -> echoes case dir with an empty state/
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  printf '%s\n' "$d"
}

# Clear the fake-driver vars and (re-)mark them exported, so the per-test plain
# assignments below stay exported into the fakes without an `export VAR=$(...)`
# command-substitution assignment (SC2155).
reset_fakes() {
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_AXI_STATUS_RUN=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  FM_FAKE_TMUX_MISSING=0
  FM_FAKE_TMUX_CAPTURE_TIMEOUT=0
  FM_FAKE_TMUX_EMPTY_PANE=0
  FM_FAKE_TMUX_COMMAND=codex
  FM_FAKE_TMUX_LABEL=fm-fixture
  FM_FAKE_TMUX_PANE=""
  FM_FAKE_HERDR_BUSY=0
  FM_FAKE_HERDR_MISSING=0
  FM_FAKE_HERDR_AGENT_STATUS=""
  FM_FAKE_CI_LOGS=""
  FM_FAKE_PR_STATE=merged
  FM_FAKE_PR_HEAD=abc1234cafebabeabc1234cafebabeabc1234caf
  FM_FAKE_GH_AXI_FAIL=0
  FM_FAKE_REMOTE_COMMIT_HEAD=abc1234cafebabeabc1234cafebabeabc1234caf
  FM_FAKE_REMOTE_COMMIT_FAIL=0
  FM_FAIL_ON_LOCAL_COMMIT_LOOKUP=0
  export FM_FAKE_AXI_STATUS FM_FAKE_AXI_STATUS_RUN FM_FAKE_RUNS_LIST FM_FAKE_BUSY FM_FAKE_TMUX_MISSING
  export FM_FAKE_TMUX_CAPTURE_TIMEOUT FM_FAKE_TMUX_EMPTY_PANE
  export FM_FAKE_TMUX_COMMAND FM_FAKE_TMUX_LABEL FM_FAKE_TMUX_PANE
  export FM_FAKE_HERDR_BUSY FM_FAKE_HERDR_MISSING FM_FAKE_HERDR_AGENT_STATUS FM_FAKE_CI_LOGS
  export FM_FAKE_PR_STATE FM_FAKE_PR_HEAD FM_FAKE_GH_AXI_FAIL
  export FM_FAKE_REMOTE_COMMIT_HEAD FM_FAKE_REMOTE_COMMIT_FAIL FM_FAIL_ON_LOCAL_COMMIT_LOOKUP
}

# --- run-object fixtures (TOON, as `no-mistakes axi status` emits) -----------

run_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "abc1234"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
EOF
}

# A running run whose active step renders quiet, exactly as `axi status` renders
# a step running a configured shell command: empty agent_pid, round `starting`,
# and a `quiet <duration> ago` last_activity for the step's whole duration
# (2026-08-02 incident; docs/postmortems/nm-quiet-test-step.md).
run_running_quiet_step() {  # <branch> <step>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "abc1234"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    $2,running,0,0
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    $2,running,88m,"quiet 88m ago: log: running tests: ...","",starting
EOF
}

run_fixing() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "abc1234"
  pr: ""
  findings: none
EOF
}

run_top_level_ci() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: ci
  head: "abc1234"
  pr: "https://github.com/o/r/pull/2"
  findings: none
EOF
}

run_parked() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: awaiting_approval
  awaiting_agent: parked 2m10s
  head: "abc1234"
  pr: ""
  findings[2]{id,severity,file,line,action,description}:
    r1,warning,a.go,,auto-fix,ignored error
    r2,error,b.go,,ask-user,changes product behavior
gate: review
EOF
}

run_parked_scalar_gate_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "abc1234"
  pr: ""
  findings[1]{id,severity,file,line,action,description}:
    r1,error,b.go,,ask-user,changes product behavior
gate: review
EOF
}

run_parked_in_gate_block() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "abc1234"
  pr: ""
  findings[1]{id,severity,file,line,action,description}:
    r1,error,b.go,,ask-user,changes product behavior
gate:
  step: review
  status: fix_review
steps[3]{step,status,findings,duration_ms}:
  intent,completed,0,0
  review,fix_review,1,0
  test,pending,0,0
EOF
}

run_passed() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "abc1234"
  pr: "https://github.com/o/r/pull/1"
  findings: none
outcome: passed
EOF
}

run_checks_passed() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "abc1234"
  pr: "https://github.com/o/r/pull/2"
  findings: none
outcome: checks-passed
EOF
}

run_failed() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "abc1234"
  pr: ""
  findings: none
outcome: failed
EOF
}

run_completed_without_outcome() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "abc1234"
  pr: "https://github.com/o/r/pull/2"
  findings: none
EOF
}

run_cancelled() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "abc1234"
  pr: ""
  findings: none
outcome: cancelled
EOF
}

run_ci_monitoring() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "abc1234"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
EOF
}

run_fixing_ci_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "abc1234"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
EOF
}

run_ci_fixing() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "abc1234"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,fixing,0,0
EOF
}

# ---------------------------------------------------------------------------
# (a) active run-step is authoritative
test_active_run_is_authoritative() {
  reset_fakes
  local d; d=$(new_case active)
  make_repo_on_branch "$d/wt" fm/feat-a
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-a.meta" "window=fm:fm-feat-a" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-a)"
  local out; out=$(run_crew_state "$d" feat-a)
  assert_contains "$out" "state: working" "active run -> working"
  assert_contains "$out" "source: run-step" "active run -> run-step source"
  assert_contains "$out" "validating (running)" "active run reports the step"
  pass "active run-step is authoritative"
}

# An active validation run and its agent answer different questions. The run may
# continue after the harness process exits, so the current-state line must keep
# the run working while making a dead agent observably different from a healthy
# one. Before the agent-liveness field existed these two outputs were byte-for-
# byte identical; this assertion is the direct mutation proof for that defect.
test_active_run_distinguishes_dead_agent() {
  reset_fakes
  local d healthy dead
  d=$(new_case agent-dead-vs-alive)
  make_repo_on_branch "$d/wt" fm/feat-agent
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-agent.meta" \
    "window=fm:fm-feat-agent" "worktree=$d/wt" "kind=ship" "harness=codex"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-agent)"

  healthy=$(FM_FAKE_TMUX_COMMAND=codex run_crew_state "$d" feat-agent)
  dead=$(FM_FAKE_TMUX_COMMAND=zsh run_crew_state "$d" feat-agent)

  [ "$healthy" != "$dead" ] \
    || fail "a dead agent on a live run is still reported identically to a healthy agent: $dead"
  assert_contains "$healthy" "agent-liveness: alive" "a confirmed harness process reports alive"
  assert_contains "$healthy" "liveness: alive" "healthy agent evidence keeps aggregate liveness alive"
  assert_contains "$dead" "state: working" "agent death does not overwrite advancing run progress"
  assert_contains "$dead" "validating (running)" "agent death preserves the active run-step detail"
  assert_contains "$dead" "agent-liveness: dead" "a missing harness process is separately visible"
  assert_contains "$dead" "liveness: dead" "dead agent evidence makes aggregate liveness actionable"
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" FM_NM_HOME="$d/nm-home" \
    FM_FAKE_TMUX_COMMAND=codex crew_is_provably_working feat-agent \
    || fail "a healthy agent on an active run was not absorbable as provably working"
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" FM_NM_HOME="$d/nm-home" \
    FM_FAKE_TMUX_COMMAND=zsh crew_is_provably_working feat-agent \
    && fail "a dead agent on an active run was absorbed instead of producing an actionable wake"
  pass "an active run reports dead and healthy agents distinctly without weakening run-step precedence"
}

test_dead_agent_quota_banner_names_terminal_exhaustion() {
  reset_fakes
  local d out
  d=$(new_case agent-quota-exhausted)
  make_repo_on_branch "$d/wt" fm/feat-quota
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-quota.meta" \
    "window=fm:fm-feat-quota" "worktree=$d/wt" "kind=ship" "harness=codex"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-quota)"
  FM_FAKE_TMUX_COMMAND=zsh
  FM_FAKE_TMUX_PANE="The previous turn has ended.
You've hit your usage limit
> "

  out=$(run_crew_state "$d" feat-quota)
  assert_contains "$out" "agent-liveness: dead (agent quota-exhausted; relaunch on another account)" \
    "a dead Codex agent with the status-region banner names quota exhaustion and its only remedy"
  assert_contains "$out" "liveness: dead (agent quota-exhausted; relaunch on another account)" \
    "quota exhaustion makes aggregate liveness actionable"
  assert_not_contains "$out" "stale" "quota exhaustion is not mislabeled as stale"
  assert_not_contains "$out" "wedge" "quota exhaustion is not mislabeled as a wedge"
  pass "a corroborated quota banner is a named terminal agent state"
}

# The banner words can legitimately appear in search output, a diff, a fixture,
# or prose the agent is displaying. Even an exact standalone line inside the
# bounded status region is insufficient by itself: a live harness process is the
# independent signal that prevents a healthy lane from being relaunched.
test_working_agent_displaying_banner_text_is_not_dead() {
  reset_fakes
  local d out
  d=$(new_case agent-banner-content)
  make_repo_on_branch "$d/wt" fm/feat-banner-content
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-banner-content.meta" \
    "window=fm:fm-feat-banner-content" "worktree=$d/wt" "kind=ship" "harness=codex"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-banner-content)"
  FM_FAKE_TMUX_COMMAND=codex
  FM_FAKE_TMUX_PANE="Search You've hit your usage limit|quota exhausted
You've hit your usage limit
esc to interrupt"

  out=$(run_crew_state "$d" feat-banner-content)
  assert_contains "$out" "agent-liveness: alive" "a working agent remains alive while displaying banner text"
  assert_contains "$out" "liveness: alive" "displayed content keeps aggregate liveness healthy"
  assert_not_contains "$out" "quota-exhausted" "displayed content is not mistaken for a harness exhaustion state"
  assert_not_contains "$out" "liveness: dead" "displayed content cannot make a live agent dead"
  pass "ordinary pane content containing the exhaustion banner does not kill a working lane"
}

test_unreadable_agent_probe_remains_unknown() {
  reset_fakes
  local d out
  d=$(new_case agent-unknown)
  make_repo_on_branch "$d/wt" fm/feat-agent-unknown
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-agent-unknown.meta" \
    "window=fm:fm-feat-agent-unknown" "worktree=$d/wt" "kind=ship" "harness=pi"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-agent-unknown)"
  FM_FAKE_TMUX_COMMAND=node

  out=$(run_crew_state "$d" feat-agent-unknown)
  assert_contains "$out" "agent-liveness: unknown" "an ambiguous harness process is visibly unknown"
  assert_contains "$out" "liveness: unknown" "unknown agent evidence keeps aggregate liveness unknown"
  assert_not_contains "$out" "agent-liveness: alive" "unknown agent evidence is never promoted to healthy"
  assert_not_contains "$out" "agent-liveness: dead" "unknown agent evidence is never promoted to dead"
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" FM_NM_HOME="$d/nm-home" \
    FM_FAKE_TMUX_COMMAND=node crew_is_provably_working feat-agent-unknown \
    && fail "unknown agent evidence was absorbed as provably working"
  pass "unknown agent liveness remains a distinct fail-closed third state"
}

test_agent_probe_failures_remain_unknown() {
  reset_fakes
  local d out
  d=$(new_case agent-probe-failures)
  make_repo_on_branch "$d/wt" fm/feat-agent-probe-failures
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-agent-probe-failures.meta" \
    "window=fm:fm-feat-agent-probe-failures" "worktree=$d/wt" "kind=ship" "harness=codex"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-agent-probe-failures)"

  out=$(FM_FAKE_TMUX_EMPTY_PANE=1 run_crew_state "$d" feat-agent-probe-failures)
  assert_contains "$out" "agent-liveness: unknown (agent probe unreadable: empty pane sample)" \
    "an empty agent sample is visibly unknown"
  assert_contains "$out" " · liveness: unknown" \
    "an empty agent sample keeps aggregate liveness unknown"
  assert_not_contains "$out" "agent-liveness: alive" \
    "an empty agent sample is never promoted to healthy"

  out=$(FM_FAKE_TMUX_CAPTURE_TIMEOUT=1 FM_CREW_STATE_NM_TIMEOUT=1 \
    run_crew_state "$d" feat-agent-probe-failures)
  assert_contains "$out" "agent-liveness: unknown (agent probe timed out after 1s)" \
    "a timed-out agent sample is visibly unknown"
  assert_contains "$out" " · liveness: unknown" \
    "a timed-out agent sample keeps aggregate liveness unknown"
  assert_not_contains "$out" "agent-liveness: alive" \
    "a timed-out agent sample is never promoted to healthy"

  out=$(FM_FAKE_TMUX_MISSING=1 run_crew_state "$d" feat-agent-probe-failures)
  assert_contains "$out" "agent-liveness: unknown (agent probe unreadable:" \
    "an unreadable agent endpoint is visibly unknown"
  assert_contains "$out" " · liveness: unknown" \
    "an unreadable agent endpoint keeps aggregate liveness unknown"
  assert_not_contains "$out" "agent-liveness: alive" \
    "an unreadable agent endpoint is never promoted to healthy"
  pass "empty, timed-out, and unreadable agent probes remain fail-closed unknown"
}

# (l) a quiet step carries the liveness probe's verdict instead of leaving
# firstmate to hand-check it. The probe's real process enumeration is covered by
# fm-nm-step-liveness.test.sh; these cases isolate this consumer's mapping.
test_quiet_step_reports_dead_liveness() {
  reset_fakes
  local d; d=$(new_case quiet-dead)
  make_repo_on_branch "$d/wt" fm/feat-q
  make_fakebin "$d" >/dev/null
  mkdir -p "$d/nm-home/worktrees/repo1/01RUN"
  fm_write_meta "$d/state/feat-q.meta" "window=fm:fm-feat-q" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running_quiet_step fm/feat-q test)"
  local out
  out=$(FM_CREW_STATE_NM_LIVENESS_BIN="$d/fakebin/fake-liveness" \
    FM_FAKE_LIVENESS_MODE=dead run_crew_state "$d" feat-q)
  assert_contains "$out" "state: working" "a quiet step is still reported working"
  assert_contains "$out" "run-liveness: dead (0 procs)" "a quiet step with no process reports dead"
  assert_contains "$out" "liveness: dead (run process unavailable)" "dead run-process evidence remains actionable"
  assert_contains "$out" "step: test" "the liveness observation names its active step"
  pass "a quiet step with no live process reports a dead liveness verdict"
}

test_quiet_step_reports_alive_liveness() {
  reset_fakes
  local d; d=$(new_case quiet-alive)
  make_repo_on_branch "$d/wt" fm/feat-q
  make_fakebin "$d" >/dev/null
  mkdir -p "$d/nm-home/worktrees/repo1/01RUN"
  fm_write_meta "$d/state/feat-q.meta" "window=fm:fm-feat-q" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running_quiet_step fm/feat-q test)"
  local out
  out=$(FM_CREW_STATE_NM_LIVENESS_BIN="$d/fakebin/fake-liveness" \
    FM_FAKE_LIVENESS_MODE=alive run_crew_state "$d" feat-q)
  assert_contains "$out" "run-liveness: alive" "a quiet step with a live process reports alive"
  assert_contains "$out" "liveness: alive (agent and run processes confirmed)" \
    "positive evidence on both axes makes aggregate liveness healthy"
  # Alive alone leaves hours of runtime unexplained; naming the current unit of
  # work and its age is what separates a slow step from a hung one without
  # spending a run to find out, so the heartbeat read must carry it.
  assert_contains "$out" " on sleep 30 (" "the alive verdict names the current unit of work and its age"
  pass "a quiet step with a live process reports an alive liveness verdict"
}

test_quiet_step_probe_failures_are_unknown() {
  reset_fakes
  local d out probe
  d=$(new_case quiet-unknown)
  make_repo_on_branch "$d/wt" fm/feat-qu
  make_fakebin "$d" >/dev/null
  probe="$d/fakebin/fake-liveness"
  fm_write_meta "$d/state/feat-qu.meta" "window=fm:fm-feat-qu" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running_quiet_step fm/feat-qu test)"

  FM_FAKE_AXI_STATUS=$(printf '%s\n' "$FM_FAKE_AXI_STATUS" | sed '/active_steps\[1\]/d')
  out=$(FM_CREW_STATE_NM_LIVENESS_BIN="$probe" run_crew_state "$d" feat-qu)
  assert_contains "$out" "run-liveness: unknown" "a quiet result without an identifiable step is visibly unknown"
  assert_contains "$out" "liveness: unknown" "missing run-process identity keeps aggregate liveness unknown"
  assert_contains "$out" "probe unreadable: active step unavailable" "a missing active step explains its unreadable cause"

  FM_FAKE_AXI_STATUS="$(run_running_quiet_step fm/feat-qu test)"
  out=$(FM_CREW_STATE_NM_LIVENESS_BIN="$probe" FM_FAKE_LIVENESS_MODE=empty \
    run_crew_state "$d" feat-qu)
  assert_contains "$out" "run-liveness: unknown" "an empty probe result is visibly unknown"
  assert_contains "$out" "probe unreadable: empty result" "an empty result explains its unreadable cause"

  out=$(FM_CREW_STATE_NM_LIVENESS_BIN="$probe" FM_FAKE_LIVENESS_MODE=nonzero \
    run_crew_state "$d" feat-qu)
  assert_contains "$out" "run-liveness: unknown" "a nonzero probe result is visibly unknown"
  assert_contains "$out" "probe unreadable: exited 9" "a nonzero result reports its exit status"

  out=$(FM_CREW_STATE_NM_LIVENESS_BIN="$probe" FM_FAKE_LIVENESS_MODE=malformed \
    run_crew_state "$d" feat-qu)
  assert_contains "$out" "run-liveness: unknown" "a malformed probe result is visibly unknown"
  assert_contains "$out" "probe protocol unreadable: verdict missing or invalid" \
    "a malformed result reports its distinct protocol failure"

  out=$(FM_CREW_STATE_NM_LIVENESS_BIN="$probe" FM_FAKE_LIVENESS_MODE=multiline \
    run_crew_state "$d" feat-qu)
  assert_contains "$out" "run-liveness: unknown" "a multiline probe result is visibly unknown"
  assert_contains "$out" "probe protocol unreadable: multiline result" \
    "a multiline probe result is rejected before field parsing"

  out=$(FM_CREW_STATE_NM_LIVENESS_BIN="$probe" FM_FAKE_LIVENESS_MODE=malformed-verdict \
    run_crew_state "$d" feat-qu)
  assert_contains "$out" "run-liveness: unknown" "a verdict with trailing data is visibly unknown"
  assert_contains "$out" "probe protocol unreadable: verdict missing or invalid" \
    "a verdict with trailing data is rejected at its field boundary"

  out=$(FM_CREW_STATE_NM_LIVENESS_BIN="$probe" FM_FAKE_LIVENESS_MODE=malformed-procs \
    run_crew_state "$d" feat-qu)
  assert_contains "$out" "run-liveness: unknown" "a process count with trailing data is visibly unknown"
  assert_contains "$out" "probe protocol unreadable: numeric process count missing or invalid" \
    "a process count with trailing data is rejected at its field boundary"

  out=$(FM_CREW_STATE_NM_LIVENESS_BIN="$probe" FM_FAKE_LIVENESS_MODE=alive-zero \
    run_crew_state "$d" feat-qu)
  assert_contains "$out" "run-liveness: unknown" "an alive verdict with no processes is visibly unknown"
  assert_contains "$out" "probe protocol unreadable: alive verdict requires processes" \
    "an alive verdict requires a positive process count"

  out=$(FM_CREW_STATE_NM_LIVENESS_BIN="$probe" FM_FAKE_LIVENESS_MODE=dead-nonzero \
    run_crew_state "$d" feat-qu)
  assert_contains "$out" "run-liveness: unknown" "a dead verdict with processes is visibly unknown"
  assert_contains "$out" "probe protocol unreadable: dead verdict requires zero processes" \
    "a dead verdict requires a zero process count"

  out=$(FM_CREW_STATE_NM_LIVENESS_BIN="$probe" FM_FAKE_LIVENESS_MODE=empty-procs \
    run_crew_state "$d" feat-qu)
  assert_contains "$out" "run-liveness: unknown" "an empty process count is visibly unknown"
  assert_contains "$out" "probe protocol unreadable: numeric process count missing or invalid" \
    "an empty process count reports the probe-side protocol defect"
  assert_not_contains "$out" "grade:" \
    "an empty process count is not collapsed into a measurement-grade unknown"

  out=$(FM_CREW_STATE_NM_LIVENESS_BIN="$probe" FM_FAKE_LIVENESS_MODE=argv-fields \
    run_crew_state "$d" feat-qu)
  assert_contains "$out" "run-liveness: unknown (grade: present-unproven; 3 procs; presence established)" \
    "structured fields are parsed before argv text containing field names"
  assert_contains "$out" " · liveness: unknown" \
    "an unknown run-process reading keeps aggregate liveness unknown"
  assert_contains "$out" 'on python -c "procs: x grade: bogus" (1:00)' \
    "argv field-name text remains visible without corrupting the verdict"

  out=$(FM_CREW_STATE_NM_LIVENESS_BIN="$probe" FM_CREW_STATE_NM_TIMEOUT=1 FM_FAKE_LIVENESS_MODE=timeout \
    run_crew_state "$d" feat-qu)
  assert_contains "$out" "run-liveness: unknown" "a timed-out probe result is visibly unknown"
  assert_contains "$out" "probe timed out after 1s" "a timed-out result reports its timeout"
  pass "quiet-step probe failures remain visibly unknown with distinct causes"
}

# The ci step monitors GitHub from inside the daemon and owns no worktree
# process, so a liveness verdict there would always read dead and mean nothing.
test_quiet_ci_step_skips_liveness() {
  reset_fakes
  local d; d=$(new_case quiet-ci)
  make_repo_on_branch "$d/wt" fm/feat-q
  make_fakebin "$d" >/dev/null
  mkdir -p "$d/nm-home/worktrees/repo1/01RUN"
  fm_write_meta "$d/state/feat-q.meta" "window=fm:fm-feat-q" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running_quiet_step fm/feat-q ci)"
  local out; out=$(run_crew_state "$d" feat-q)
  assert_contains "$out" "agent-liveness: alive" "the ci lane still reports its agent availability"
  assert_contains "$out" "liveness: alive" "the ci lane aggregate follows its agent availability"
  assert_not_contains "$out" "run-liveness:" "the ci step never carries a command-process liveness verdict"
  assert_not_contains "$out" "procs" "the ci step is not probed for worktree processes"
  pass "a quiet ci step is not given a meaningless liveness verdict"
}

# (b) needs-decision log + a resumed (running/fixing) run = SUPERSEDED
test_stale_needs_decision_superseded() {
  reset_fakes
  local d; d=$(new_case superseded)
  make_repo_on_branch "$d/wt" fm/feat-b
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-b.meta" "window=fm:fm-feat-b" "worktree=$d/wt" "kind=ship"
  printf 'working: started\nneeds-decision: pick A or B\n' > "$d/state/feat-b.status"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-b)"
  local out; out=$(run_crew_state "$d" feat-b)
  assert_contains "$out" "state: working" "resumed run -> working despite needs-decision log"
  assert_contains "$out" "source: run-step" "resumed run -> run-step source"
  assert_contains "$out" "superseded" "stale needs-decision log flagged superseded"
  pass "stale needs-decision over active run is superseded"
}

# blocked log + a resumed run is also superseded
test_stale_blocked_superseded() {
  reset_fakes
  local d; d=$(new_case superseded-blocked)
  make_repo_on_branch "$d/wt" fm/feat-bb
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-bb.meta" "window=fm:fm-feat-bb" "worktree=$d/wt" "kind=ship"
  printf 'blocked: waiting on review answer\n' > "$d/state/feat-bb.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-bb)"
  local out; out=$(run_crew_state "$d" feat-bb)
  assert_contains "$out" "state: working" "resumed run -> working despite blocked log"
  assert_contains "$out" "superseded" "stale blocked log flagged superseded"
  pass "stale blocked over active run is superseded"
}

# (c) genuine parked run + needs-decision log AGREE -> parked, NOT superseded
test_genuine_parked_not_superseded() {
  reset_fakes
  local d; d=$(new_case parked)
  make_repo_on_branch "$d/wt" fm/feat-c
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-c.meta" "window=fm:fm-feat-c" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-c.status"
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-c)"
  local out; out=$(run_crew_state "$d" feat-c)
  assert_contains "$out" "state: parked" "genuine parked run -> parked"
  assert_contains "$out" "source: run-step" "parked -> run-step source"
  assert_contains "$out" "2 finding(s)" "parked includes gate finding count"
  assert_contains "$out" "ask-user" "parked surfaces ask-user finding"
  assert_not_contains "$out" "superseded" "agreeing parked+needs-decision not flagged stale"
  pass "genuine parked run is not flagged superseded"
}

test_scalar_gate_parked_not_superseded() {
  reset_fakes
  local d; d=$(new_case parked-scalar-gate)
  make_repo_on_branch "$d/wt" fm/feat-cs
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cs.meta" "window=fm:fm-feat-cs" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-cs.status"
  FM_FAKE_AXI_STATUS="$(run_parked_scalar_gate_running fm/feat-cs)"
  local out; out=$(run_crew_state "$d" feat-cs)
  assert_contains "$out" "state: parked" "scalar gate wait -> parked"
  assert_contains "$out" "source: run-step" "scalar gate wait -> run-step source"
  assert_contains "$out" "parked at review" "scalar gate wait names the gate"
  assert_contains "$out" "1 finding(s)" "scalar gate wait includes finding count"
  assert_not_contains "$out" "superseded" "scalar gate wait not flagged stale"
  pass "scalar gate parked run is not flagged superseded"
}

test_gate_block_parked_not_superseded() {
  reset_fakes
  local d; d=$(new_case parked-gate-block)
  make_repo_on_branch "$d/wt" fm/feat-cb
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cb.meta" "window=fm:fm-feat-cb" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-cb.status"
  FM_FAKE_AXI_STATUS="$(run_parked_in_gate_block fm/feat-cb)"
  local out; out=$(run_crew_state "$d" feat-cb)
  assert_contains "$out" "state: parked" "gate block wait -> parked"
  assert_contains "$out" "source: run-step" "gate block wait -> run-step source"
  assert_contains "$out" "parked at review" "gate block wait names the gate"
  assert_contains "$out" "1 finding(s)" "gate block wait includes finding count"
  assert_not_contains "$out" "superseded" "gate block wait not flagged stale"
  pass "gate block parked run is not flagged superseded"
}

test_ci_ready_done_log_beats_monitoring_run() {
  reset_fakes
  local d; d=$(new_case ci-ready)
  make_repo_on_branch "$d/wt" fm/feat-ci
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ci.meta" "window=fm:fm-feat-ci" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-ci.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-ci)"
  local out; out=$(run_crew_state "$d" feat-ci)
  assert_contains "$out" "state: done" "ci-ready status log -> done"
  assert_contains "$out" "source: status-log" "ci-ready state comes from the status log"
  assert_contains "$out" "checks green" "ci-ready detail preserves the report"
  assert_not_contains "$out" "state: working" "ci-ready is not hidden by monitoring run"
  pass "ci-ready status log beats monitoring run"
}

# A status-log URL is an event-log detail, not evidence that it belongs to the
# current no-mistakes run. Without a PR URL on the exact run object, currentness
# is unknown even when the log claims checks are green.
test_ci_ready_log_pr_url_does_not_supply_run_identity() {
  reset_fakes
  local d out
  d=$(new_case ci-ready-log-pr-only)
  make_repo_on_branch "$d/wt" fm/feat-ci-log-pr-only
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ci-log-pr-only.meta" \
    "window=fm:fm-feat-ci-log-pr-only" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-ci-log-pr-only.status"
  FM_FAKE_AXI_STATUS=$(run_ci_monitoring fm/feat-ci-log-pr-only | sed 's#pr: "https://github.com/o/r/pull/2"#pr: ""#')
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  out=$(run_crew_state "$d" feat-ci-log-pr-only)
  assert_contains "$out" "state: unknown" "log-only PR URL -> unknown"
  assert_contains "$out" "currentness is unavailable" "log-only PR URL names missing run evidence"
  assert_contains "$out" "do not merge" "log-only PR URL is merge-safe"
  assert_not_contains "$out" "state: done" "event-log PR URL must not authorize done"
  pass "status-log PR URL is never promoted to current run identity"
}

# Regression for the PR #252 incident: the crewmate's own status log never got a
# "done: ... checks green" line (log_reports_ci_ready above does not apply),
# but the ci step's log tail shows CI is actually green and only waiting on
# merge/close. fm-crew-state must surface this as done, not "validating
# (running)", so a green PR is never silently absorbed as still-in-progress.
test_ci_monitoring_checks_green_surfaces_done() {
  reset_fakes
  local d; d=$(new_case ci-green)
  make_repo_on_branch "$d/wt" fm/feat-cigreen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cigreen.meta" "window=fm:fm-feat-cigreen" "worktree=$d/wt" "kind=ship"
  # No status-log line at all: the crewmate never reported its own checks-green line.
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cigreen)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
CI checks running, waiting for results...
all CI checks passed - still monitoring until merged or closed
EOF
)
  local out; out=$(run_crew_state "$d" feat-cigreen)
  assert_contains "$out" "state: done" "green ci-monitor run -> done"
  assert_contains "$out" "source: run-step" "green ci-monitor -> run-step source"
  assert_contains "$out" "checks green" "green ci-monitor detail mentions checks green"
  assert_not_contains "$out" "state: working" "green ci-monitor must not read as still validating"
  pass "ci-monitoring run with checks already green surfaces done"
}

test_top_level_ci_checks_green_surfaces_done() {
  reset_fakes
  local d; d=$(new_case top-level-ci-green)
  make_repo_on_branch "$d/wt" fm/feat-topcigreen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-topcigreen.meta" "window=fm:fm-feat-topcigreen" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_top_level_ci fm/feat-topcigreen)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-topcigreen)
  assert_contains "$out" "state: done" "top-level ci with green log -> done"
  assert_contains "$out" "source: run-step" "top-level ci green -> run-step source"
  assert_contains "$out" "checks green" "top-level ci green detail mentions checks green"
  assert_not_contains "$out" "state: working" "top-level ci green must not stay working"
  pass "top-level ci status uses ci log green marker"
}

# A completed run is not current merely because it is the most recent run for
# the branch. If the open PR moved to another head after that run completed,
# calling the old run "checks green" would authorize a merge of unvalidated
# code. The PR head is the live publication authority for this decision.
test_checks_passed_for_older_pr_head_is_stale() {
  reset_fakes
  local d; d=$(new_case stale-run-head)
  make_repo_on_branch "$d/wt" fm/feat-stale-head
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-stale-head.meta" "window=fm:fm-feat-stale-head" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_checks_passed fm/feat-stale-head)"
  FM_FAKE_RUNS_LIST='completed fm/feat-stale-head abc1234 2026-08-01 23:58 https://github.com/o/r/pull/2'
  FM_FAKE_PR_HEAD=def5678cafebabedef5678cafebabedef5678caf
  local out; out=$(run_crew_state "$d" feat-stale-head)
  assert_contains "$out" "state: stale" "older completed run -> stale"
  assert_contains "$out" "source: run-step" "stale verdict identifies the run-step"
  assert_contains "$out" "validated head abc1234" "stale verdict names the validated head"
  assert_contains "$out" "PR head def5678" "stale verdict names the live PR head"
  assert_contains "$out" "do not merge" "stale verdict is merge-safe"
  assert_not_contains "$out" "state: done" "older completed run must not read done"
  pass "checks-passed run whose PR head moved is reported stale"
}

test_checks_passed_for_current_pr_head_is_done() {
  reset_fakes
  local d; d=$(new_case current-run-head)
  make_repo_on_branch "$d/wt" fm/feat-current-head
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-current-head.meta" "window=fm:fm-feat-current-head" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_checks_passed fm/feat-current-head)"
  FM_FAKE_RUNS_LIST='completed fm/feat-current-head abc1234 2026-08-01 23:58 https://github.com/o/r/pull/2'
  FM_FAKE_PR_HEAD=abc1234cafebabeabc1234cafebabeabc1234caf
  local out; out=$(run_crew_state "$d" feat-current-head)
  assert_contains "$out" "state: done" "current completed run -> done"
  assert_contains "$out" "checks green" "current completed run retains ready detail"
  assert_not_contains "$out" "state: stale" "matching PR head is not stale"
  pass "checks-passed run whose PR head matches remains done"
}

test_checks_passed_requires_remote_head_resolution() {
  reset_fakes
  local d; d=$(new_case unresolved-run-head)
  make_repo_on_branch "$d/wt" fm/feat-unresolved-head
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-unresolved-head.meta" "window=fm:fm-feat-unresolved-head" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_checks_passed fm/feat-unresolved-head)"
  FM_FAKE_RUNS_LIST='completed fm/feat-unresolved-head abc1234 2026-08-01 23:58 https://github.com/o/r/pull/2'
  FM_FAKE_REMOTE_COMMIT_FAIL=1
  local out; out=$(run_crew_state "$d" feat-unresolved-head)
  assert_contains "$out" "state: unknown" "unresolved validated head -> unknown"
  assert_contains "$out" "through GitHub" "resolution failure names the missing remote proof"
  assert_contains "$out" "do not merge" "resolution failure is merge-safe"
  assert_not_contains "$out" "state: done" "unresolved validated head must not read done"
  pass "checks-passed run fails closed when GitHub cannot resolve its head"
}

test_checks_passed_rejects_same_prefix_different_full_head() {
  reset_fakes
  local d; d=$(new_case prefix-collision-head)
  make_repo_on_branch "$d/wt" fm/feat-prefix-collision
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-prefix-collision.meta" "window=fm:fm-feat-prefix-collision" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_checks_passed fm/feat-prefix-collision)"
  FM_FAKE_RUNS_LIST='completed fm/feat-prefix-collision abc1234 2026-08-01 23:58 https://github.com/o/r/pull/2'
  FM_FAKE_PR_HEAD=abc1234fffffffffffffffffffffffffffffffff
  local out; out=$(run_crew_state "$d" feat-prefix-collision)
  assert_contains "$out" "state: stale" "same short prefix with different full head -> stale"
  assert_contains "$out" "do not merge" "exact-identity mismatch is merge-safe"
  assert_not_contains "$out" "state: done" "prefix similarity must not authorize done"
  pass "checks-passed run requires exact full-head equality"
}

# Regression for PR #71's adversarial review: publication currentness is a
# remote fact. The exact same remote run and PR state must produce the exact
# same verdict before and after the worktree happens to fetch that commit.
test_remote_currentness_is_independent_of_local_fetch() {
  reset_fakes
  local d remote_head before after
  d=$(new_case remote-currentness)
  make_repo_on_branch "$d/wt" fm/feat-remote-currentness
  git init -q --bare "$d/remote.git"
  git -C "$d/wt" remote add origin "$d/remote.git"
  git -C "$d/wt" push -q -u origin fm/feat-remote-currentness
  git clone -q --branch fm/feat-remote-currentness "$d/remote.git" "$d/publisher"
  git -C "$d/publisher" commit -q --allow-empty -m remote-head
  git -C "$d/publisher" push -q origin fm/feat-remote-currentness
  remote_head=$(git -C "$d/publisher" rev-parse HEAD)
  git -C "$d/wt" cat-file -e "$remote_head^{commit}" 2>/dev/null \
    && fail "remote-only fixture commit unexpectedly exists locally before fetch"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-remote-currentness.meta" \
    "window=fm:fm-feat-remote-currentness" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS=$(run_checks_passed fm/feat-remote-currentness | sed "s/head: \"abc1234\"/head: \"${remote_head:0:7}\"/")
  FM_FAKE_RUNS_LIST="completed fm/feat-remote-currentness ${remote_head:0:7} 2026-08-01 23:58 https://github.com/o/r/pull/2"
  FM_FAKE_PR_HEAD=$remote_head
  FM_FAKE_REMOTE_COMMIT_HEAD=$remote_head
  FM_FAIL_ON_LOCAL_COMMIT_LOOKUP=1
  before=$(run_crew_state "$d" feat-remote-currentness)
  assert_contains "$before" "state: done" "remote current head is done before local fetch"
  git -C "$d/wt" fetch -q origin fm/feat-remote-currentness
  git -C "$d/wt" cat-file -e "$remote_head^{commit}" \
    || fail "remote fixture commit still absent locally after fetch"
  after=$(run_crew_state "$d" feat-remote-currentness)
  [ "$before" = "$after" ] \
    || fail "local fetch changed remote currentness verdict: before=[$before] after=[$after]"
  pass "PR-ready currentness depends on remote identity, not incidental local fetch state"
}

test_earlier_completed_run_is_stale_while_newer_run_active() {
  reset_fakes
  local d; d=$(new_case stale-earlier-run)
  make_repo_on_branch "$d/wt" fm/feat-earlier-run
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-earlier-run.meta" "window=fm:fm-feat-earlier-run" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_checks_passed fm/feat-earlier-run)"
  FM_FAKE_PR_HEAD=abc1234cafebabeabc1234cafebabeabc1234caf
  FM_FAKE_RUNS_LIST='running fm/feat-earlier-run abc1234 2026-08-01 23:59 https://github.com/o/r/pull/2'
  local out; out=$(run_crew_state "$d" feat-earlier-run)
  assert_contains "$out" "state: stale" "earlier completed run -> stale"
  assert_contains "$out" "newer active run exists" "stale verdict names the newer run"
  assert_contains "$out" "do not merge" "newer-run verdict is merge-safe"
  assert_not_contains "$out" "state: done" "earlier completed run must not read done"
  pass "an earlier completed run is stale while a newer branch run is active"
}

test_completed_run_fails_closed_when_newest_run_is_unavailable() {
  reset_fakes
  local d; d=$(new_case unavailable-newest-run)
  make_repo_on_branch "$d/wt" fm/feat-unavailable-newest
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-unavailable-newest.meta" "window=fm:fm-feat-unavailable-newest" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_checks_passed fm/feat-unavailable-newest)"
  FM_FAKE_PR_HEAD=abc1234cafebabeabc1234cafebabeabc1234caf
  FM_FAKE_RUNS_LIST=""
  local out; out=$(run_crew_state "$d" feat-unavailable-newest)
  assert_contains "$out" "state: unknown" "unverifiable newest run -> unknown"
  assert_contains "$out" "could not verify the newest branch run" "unknown verdict names its missing proof"
  assert_contains "$out" "do not merge" "unverifiable newest-run verdict is merge-safe"
  assert_not_contains "$out" "state: done" "unverifiable completed run must not read done"
  pass "a completed run fails closed when newest-run currentness is unavailable"
}

test_completed_run_without_outcome_fails_closed() {
  reset_fakes
  local d; d=$(new_case completed-without-outcome)
  make_repo_on_branch "$d/wt" fm/feat-no-outcome
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-no-outcome.meta" "window=fm:fm-feat-no-outcome" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_completed_without_outcome fm/feat-no-outcome)"
  FM_FAKE_RUNS_LIST='completed fm/feat-no-outcome abc1234 2026-08-01 23:58 https://github.com/o/r/pull/2'
  local out; out=$(run_crew_state "$d" feat-no-outcome)
  assert_contains "$out" "state: unknown" "outcome-less completed run -> unknown"
  assert_contains "$out" "no terminal outcome" "unknown verdict names missing terminal evidence"
  assert_contains "$out" "do not merge" "outcome-less completion is merge-safe"
  assert_not_contains "$out" "state: done" "outcome-less completion must not authorize done"
  pass "completed run without a terminal outcome fails closed"
}

test_ci_monitoring_no_checks_terminal_surfaces_done() {
  reset_fakes
  local d; d=$(new_case ci-nochecks)
  make_repo_on_branch "$d/wt" fm/feat-cinochecks
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cinochecks.meta" "window=fm:fm-feat-cinochecks" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cinochecks)"
  FM_FAKE_CI_LOGS="no CI checks reported - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-cinochecks)
  assert_contains "$out" "state: done" "terminal no-checks ci-monitor run -> done"
  assert_contains "$out" "checks green" "terminal no-checks ci-monitor detail mentions checks green"
  pass "terminal no-checks ci-monitor marker surfaces done"
}

test_ci_monitoring_green_then_rearm_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-green-then-rearm)
  make_repo_on_branch "$d/wt" fm/feat-cirearm
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cirearm.meta" "window=fm:fm-feat-cirearm" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cirearm)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
EOF
)
  local out; out=$(run_crew_state "$d" feat-cirearm)
  assert_contains "$out" "state: working" "base-advance rearm marker -> working"
  assert_not_contains "$out" "state: done" "base-advance rearm marker must not read as done"
  assert_not_contains "$out" "checks green" "base-advance rearm marker must not read as checks green"
  pass "base-advance rearm after green stays working"
}

test_ci_monitoring_no_checks_yet_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-nochecks-yet)
  make_repo_on_branch "$d/wt" fm/feat-cinochecksyet
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cinochecksyet.meta" "window=fm:fm-feat-cinochecksyet" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cinochecksyet)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
no CI checks reported - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
no CI checks reported yet, waiting for checks to register...
EOF
)
  local out; out=$(run_crew_state "$d" feat-cinochecksyet)
  assert_contains "$out" "state: working" "pending no-checks marker -> working"
  assert_not_contains "$out" "state: done" "pending no-checks marker must not read as done"
  assert_not_contains "$out" "checks green" "pending no-checks marker must not read as checks green"
  pass "pending no-checks ci-monitor marker stays working"
}

test_ci_monitoring_still_waiting_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-waiting)
  make_repo_on_branch "$d/wt" fm/feat-ciwait
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ciwait.meta" "window=fm:fm-feat-ciwait" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-ciwait)"
  FM_FAKE_CI_LOGS="CI checks running, waiting for results..."
  local out; out=$(run_crew_state "$d" feat-ciwait)
  assert_contains "$out" "state: working" "ci step still red -> working"
  assert_not_contains "$out" "checks green" "no green marker present -> no checks-green detail"
  pass "ci-monitoring run with checks not yet green stays working"
}

# A later merge-conflict auto-fix round after an earlier green reading must
# not be masked: the MOST RECENT marker in the log tail wins.
test_ci_monitoring_green_then_new_issue_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-green-then-issue)
  make_repo_on_branch "$d/wt" fm/feat-cirelapse
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cirelapse.meta" "window=fm:fm-feat-cirelapse" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cirelapse)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
issues detected: merge conflict - auto-fixing (attempt 2/10)...
EOF
)
  local out; out=$(run_crew_state "$d" feat-cirelapse)
  assert_contains "$out" "state: working" "a later relapse marker must win over an earlier green one"
  assert_not_contains "$out" "state: done" "relapsed ci run must not read as done"
  pass "a fresh issue after an earlier green reading is not masked"
}

test_ci_ready_done_log_relapse_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-ready-then-relapse)
  make_repo_on_branch "$d/wt" fm/feat-cireadyrelapse
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cireadyrelapse.meta" "window=fm:fm-feat-cireadyrelapse" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-cireadyrelapse.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cireadyrelapse)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
CI checks running, waiting for results...
EOF
)
  local out; out=$(run_crew_state "$d" feat-cireadyrelapse)
  assert_contains "$out" "state: working" "a stale ready status must not mask a later CI relapse"
  assert_contains "$out" "source: run-step" "relapsed ci run remains run-step sourced"
  assert_not_contains "$out" "state: done" "relapsed ci run with stale done log must not read as done"
  pass "stale checks-green status log does not mask CI relapse"
}

test_ci_fixing_after_green_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-fixing-after-green)
  make_repo_on_branch "$d/wt" fm/feat-cifixing
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cifixing.meta" "window=fm:fm-feat-cifixing" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-cifixing.status"
  FM_FAKE_AXI_STATUS="$(run_ci_fixing fm/feat-cifixing)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-cifixing)
  assert_contains "$out" "state: working" "ci fixing step must stay working"
  assert_contains "$out" "source: run-step" "ci fixing remains run-step sourced"
  assert_not_contains "$out" "state: done" "ci fixing must not read as checks-green done"
  pass "ci fixing is not overridden by an earlier green marker"
}

test_top_level_fixing_ci_running_after_green_stays_working() {
  reset_fakes
  local d; d=$(new_case top-level-fixing-ci-running)
  make_repo_on_branch "$d/wt" fm/feat-topfixingci
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-topfixingci.meta" "window=fm:fm-feat-topfixingci" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_fixing_ci_running fm/feat-topfixingci)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-topfixingci)
  assert_contains "$out" "state: working" "top-level fixing with ci running must stay working"
  assert_contains "$out" "source: run-step" "top-level fixing with ci running remains run-step sourced"
  assert_contains "$out" "validating (fixing)" "top-level fixing keeps fixing detail"
  assert_not_contains "$out" "state: done" "top-level fixing must not use stale green marker"
  pass "top-level fixing is not overridden by a stale ci running row"
}

test_top_level_fixing_done_log_stays_working() {
  reset_fakes
  local d; d=$(new_case top-level-fixing-done-log)
  make_repo_on_branch "$d/wt" fm/feat-topfixing
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-topfixing.meta" "window=fm:fm-feat-topfixing" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-topfixing.status"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-topfixing)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-topfixing)
  assert_contains "$out" "state: working" "top-level fixing must stay working"
  assert_contains "$out" "source: run-step" "top-level fixing remains run-step sourced"
  assert_contains "$out" "validating (fixing)" "top-level fixing keeps fixing detail"
  assert_not_contains "$out" "state: done" "top-level fixing must not read as stale checks-green done"
  pass "top-level fixing is not overridden by a stale done log"
}

# (d) terminal run-step is authoritative, but a passed outcome does not prove
# GitHub merged or closed the PR.
test_terminal_passed_verifies_merged_pr() {
  reset_fakes
  local d; d=$(new_case passed)
  make_repo_on_branch "$d/wt" fm/feat-d
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-d.meta" "window=fm:fm-feat-d" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-d)"
  local out; out=$(run_crew_state "$d" feat-d)
  assert_contains "$out" "state: done" "passed run -> done"
  assert_contains "$out" "source: run-step" "passed -> run-step source"
  assert_contains "$out" "PR merged (verified)" "passed run reports verified merged PR state"
  pass "terminal passed run reports a verified merged PR"
}

test_terminal_passed_does_not_claim_open_pr_merged() {
  reset_fakes
  local d; d=$(new_case passed-open)
  make_repo_on_branch "$d/wt" fm/feat-do
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-do.meta" "window=fm:fm-feat-do" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-do)"
  FM_FAKE_PR_STATE=open
  FM_FAKE_RUNS_LIST='completed fm/feat-do abc1234 2026-08-01 23:58 https://github.com/o/r/pull/1'
  local out; out=$(run_crew_state "$d" feat-do)
  assert_contains "$out" "state: done" "passed run with open PR remains terminal"
  assert_contains "$out" "PR open (not merged)" "open PR is reported from GitHub state"
  assert_not_contains "$out" "PR merged/closed" "open PR must not inherit merged/closed from outcome"
  pass "terminal passed run does not claim an open PR merged or closed"
}

test_terminal_passed_reports_closed_without_merge() {
  reset_fakes
  local d; d=$(new_case passed-closed)
  make_repo_on_branch "$d/wt" fm/feat-dc
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dc.meta" "window=fm:fm-feat-dc" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-dc)"
  FM_FAKE_PR_STATE=closed
  local out; out=$(run_crew_state "$d" feat-dc)
  assert_contains "$out" "PR closed without merge (verified)" "closed PR is distinguished from merged"
  pass "terminal passed run distinguishes a closed unmerged PR"
}

test_terminal_passed_fails_closed_when_pr_state_unavailable() {
  reset_fakes
  local d; d=$(new_case passed-unavailable)
  make_repo_on_branch "$d/wt" fm/feat-du
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-du.meta" "window=fm:fm-feat-du" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-du)"
  FM_FAKE_GH_AXI_FAIL=1
  local out; out=$(run_crew_state "$d" feat-du)
  assert_contains "$out" "PR state unavailable (not verified)" "failed GitHub query is explicit"
  assert_not_contains "$out" "PR merged/closed" "unknown PR state must not inherit merged/closed from outcome"
  pass "terminal passed run fails closed when GitHub state is unavailable"
}

test_terminal_passed_clamps_invalid_gh_timeouts_and_fails_closed() {
  reset_fakes
  local d timeout_args out value
  d=$(new_case passed-zero-timeout)
  make_repo_on_branch "$d/wt" fm/feat-dz
  make_fakebin "$d" >/dev/null
  cat > "$d/fakebin/timeout" <<'SH'
#!/usr/bin/env bash
if [ "${2:-}" = gh-axi ]; then
  printf '%s\n' "$1" > "$FM_FAKE_TIMEOUT_ARGS"
  exit 124
fi
shift
exec "$@"
SH
  chmod +x "$d/fakebin/timeout"
  timeout_args="$d/timeout-args"
  fm_write_meta "$d/state/feat-dz.meta" "window=fm:fm-feat-dz" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-dz)"
  for value in 0 00 000 0.0 +0 -1 ' 0 ' ' ' invalid; do
    out=$(FM_FAKE_TIMEOUT_ARGS="$timeout_args" FM_CREW_STATE_GH_TIMEOUT="$value" run_crew_state "$d" feat-dz)
    [ "$(cat "$timeout_args")" = 10 ] || fail "GitHub timeout '$value' did not clamp to ten seconds"
    assert_contains "$out" "state: done" "timed-out query preserves terminal state"
    assert_contains "$out" "PR state unavailable (not verified)" "timed-out query fails closed"
    assert_not_contains "$out" "PR merged/closed" "timed-out query never uses pipeline-inferred PR state"
  done
  pass "invalid GitHub timeouts clamp and timed-out queries fail closed"
}

test_terminal_failed() {
  reset_fakes
  local d; d=$(new_case failed)
  make_repo_on_branch "$d/wt" fm/feat-e
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-e.meta" "window=fm:fm-feat-e" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-e)"
  local out; out=$(run_crew_state "$d" feat-e)
  assert_contains "$out" "state: failed" "failed run -> failed"
  assert_contains "$out" "source: run-step" "failed -> run-step source"
  pass "terminal failed run is authoritative"
}

# A pooled worktree can legitimately be checked out on a neighbour task's
# branch while this task's durable metadata remains bound to refs/heads/fm/<id>.
# Exercise the actual reader boundary in both dangerous directions, then prove
# missing, disagreeing, and ambiguous durable identity refuse instead of
# borrowing the worktree branch. Finally, prove that a branch shared by live task
# records is never lane identity: the run-owning lane and runless neighbour use
# their own pane/log evidence, while no positive evidence remains unknown. The
# function accumulates all eight outcomes so a pre-fix run reports the complete
# violation count instead of exiting after the first wrong answer.
test_task_branch_identity_overrides_pooled_worktree_branch() {
  reset_fakes
  local d out violations=0

  d=$(new_case task-live-neighbour-cancelled)
  make_repo_on_branch "$d/wt" fm/neighbour-cancelled
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/task-live.meta" \
    "window=fm:fm-task-live" \
    "worktree=$d/wt" \
    "kind=ship" \
    "mode=no-mistakes" \
    "worktree_git_ref=refs/heads/fm/task-live"
  FM_FAKE_AXI_STATUS="$(run_cancelled fm/neighbour-cancelled)"
  FM_FAKE_RUNS_LIST=$(cat <<'EOF'
  cancelled  fm/neighbour-cancelled aaaaaaa  2026-08-03 01:10
  running    fm/task-live bbbbbbb  2026-08-03 01:05
EOF
)
  out=$(run_crew_state "$d" task-live)
  case "$out" in
    *"state: working"*"source: run-step"*) ;;
    *)
      printf 'task-live wrong boundary result: %s\n' "$out" >&2
      violations=$((violations + 1))
      ;;
  esac

  reset_fakes
  d=$(new_case task-cancelled-neighbour-live)
  make_repo_on_branch "$d/wt" fm/neighbour-live
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/task-cancelled.meta" \
    "window=fm:fm-task-cancelled" \
    "worktree=$d/wt" \
    "kind=ship" \
    "mode=no-mistakes" \
    "worktree_git_ref=refs/heads/fm/task-cancelled"
  FM_FAKE_AXI_STATUS="$(run_running fm/neighbour-live)"
  FM_FAKE_RUNS_LIST=$(cat <<'EOF'
  running    fm/neighbour-live aaaaaaa  2026-08-03 01:10
  cancelled  fm/task-cancelled bbbbbbb  2026-08-03 01:05
EOF
)
  out=$(run_crew_state "$d" task-cancelled)
  case "$out" in
    *"state: failed"*"source: run-step"*) ;;
    *)
      printf 'task-cancelled wrong boundary result: %s\n' "$out" >&2
      violations=$((violations + 1))
      ;;
  esac

  reset_fakes
  d=$(new_case missing-task-branch-identity)
  make_repo_on_branch "$d/wt" fm/neighbour-live
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/task-unbound.meta" \
    "window=fm:fm-task-unbound" \
    "worktree=$d/wt" \
    "kind=ship" \
    "mode=no-mistakes"
  FM_FAKE_AXI_STATUS="$(run_running fm/neighbour-live)"
  FM_FAKE_RUNS_LIST="  running    fm/neighbour-live aaaaaaa  2026-08-03 01:10"
  out=$(run_crew_state "$d" task-unbound preserve-missing-task-ref)
  case "$out" in
    *"state: unknown"*"source: none"*"task branch identity unavailable"*) ;;
    *)
      printf 'task-unbound wrong refusal result: %s\n' "$out" >&2
      violations=$((violations + 1))
      ;;
  esac

  reset_fakes
  d=$(new_case disagreeing-task-branch-identity)
  make_repo_on_branch "$d/wt" fm/neighbour-live
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/task-disagrees.meta" \
    "window=fm:fm-task-disagrees" \
    "worktree=$d/wt" \
    "kind=ship" \
    "mode=no-mistakes" \
    "worktree_git_ref=refs/heads/fm/some-other-task"
  FM_FAKE_AXI_STATUS="$(run_running fm/neighbour-live)"
  FM_FAKE_RUNS_LIST="  running    fm/neighbour-live aaaaaaa  2026-08-03 01:10"
  out=$(run_crew_state "$d" task-disagrees)
  case "$out" in
    *"state: unknown"*"source: none"*"task branch identity disagreement"*) ;;
    *)
      printf 'task-disagrees wrong refusal result: %s\n' "$out" >&2
      violations=$((violations + 1))
      ;;
  esac

  reset_fakes
  d=$(new_case ambiguous-task-branch-identity)
  make_repo_on_branch "$d/wt" fm/neighbour-live
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/task-ambiguous.meta" \
    "window=fm:fm-task-ambiguous" \
    "worktree=$d/wt" \
    "kind=ship" \
    "mode=no-mistakes" \
    "worktree_git_ref=refs/heads/fm/task-ambiguous" \
    "worktree_git_ref=refs/heads/fm/neighbour-live"
  FM_FAKE_AXI_STATUS="$(run_running fm/neighbour-live)"
  FM_FAKE_RUNS_LIST="  running    fm/neighbour-live aaaaaaa  2026-08-03 01:10"
  out=$(run_crew_state "$d" task-ambiguous)
  case "$out" in
    *"state: unknown"*"source: none"*"task branch identity unavailable"*"found 2"*) ;;
    *)
      printf 'task-ambiguous wrong refusal result: %s\n' "$out" >&2
      violations=$((violations + 1))
      ;;
  esac

  reset_fakes
  d=$(new_case shared-task-branch)
  make_repo_on_branch "$d/wt-owner" fm/shared-branch
  make_repo_on_branch "$d/wt-runless" fm/shared-branch
  make_repo_on_branch "$d/wt-unknown" fm/shared-branch
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/shared-owner.meta" \
    "window=fm:fm-shared-owner" \
    "worktree=$d/wt-owner" \
    "kind=ship" \
    "mode=no-mistakes" \
    "worktree_git_ref=refs/heads/fm/shared-branch"
  fm_write_meta "$d/state/shared-runless.meta" \
    "window=fm:fm-shared-runless" \
    "worktree=$d/wt-runless" \
    "kind=ship" \
    "mode=no-mistakes" \
    "worktree_git_ref=refs/heads/fm/shared-branch"
  fm_write_meta "$d/state/shared-unknown.meta" \
    "window=fm:fm-shared-unknown" \
    "worktree=$d/wt-unknown" \
    "kind=ship" \
    "mode=no-mistakes" \
    "worktree_git_ref=refs/heads/fm/shared-branch"
  printf 'paused: waiting for the owning lane\n' > "$d/state/shared-runless.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/shared-branch)"
  FM_FAKE_RUNS_LIST="  running    fm/shared-branch aaaaaaa  2026-08-04 01:10"

  FM_FAKE_BUSY=1
  out=$(run_crew_state "$d" shared-owner)
  case "$out" in
    *"state: working"*"source: pane"*"run attribution unavailable"*"shared by 3 live task records"*) ;;
    *)
      printf 'shared-owner wrong pane result: %s\n' "$out" >&2
      violations=$((violations + 1))
      ;;
  esac

  FM_FAKE_BUSY=0
  out=$(run_crew_state "$d" shared-runless)
  case "$out" in
    *"state: paused"*"source: status-log"*"waiting for the owning lane"*"run attribution unavailable"*) ;;
    *)
      printf 'shared-runless wrong status result: %s\n' "$out" >&2
      violations=$((violations + 1))
      ;;
  esac

  out=$(run_crew_state "$d" shared-unknown)
  case "$out" in
    *"state: unknown"*"source: none"*"no current-state source available"*"run attribution unavailable"*) ;;
    *)
      printf 'shared-unknown wrong third-state result: %s\n' "$out" >&2
      violations=$((violations + 1))
      ;;
  esac

  [ "$violations" -eq 0 ] \
    || fail "$violations task-branch identity boundary violation(s)"
  pass "0 task-branch identity boundary violations across eight outcomes"
}

# (e) cross-branch attribution: `axi status` returns ANOTHER branch's run (the
# routine case once more than one crewmate validates the same underlying repo
# concurrently - they share ONE no-mistakes repo registration), so the helper
# falls back to the real top-level `no-mistakes runs` listing to learn whether
# THIS branch has an active run of its own. Regression coverage for the
# 2026-07-02 herdr incident: the old fallback shelled out to `no-mistakes axi`
# (bare) expecting a `runs[N]{...}:` TOON table that the real CLI never emits
# (verified against the installed v1.32.2 - the `axi` surface has no
# runs-listing subcommand at all), so attribution silently failed every time
# the repo-wide answer was not this crewmate's own branch.
test_cross_branch_attribution_via_runs_list() {
  reset_fakes
  local d; d=$(new_case crossbranch)
  make_repo_on_branch "$d/wt" fm/feat-f
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f.meta" "window=fm:fm-feat-f" "worktree=$d/wt" "kind=ship"
  # The repo-wide active/most-recent run belongs to a different crewmate's branch.
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  # Real `no-mistakes runs` shape: plain text, newest-first, no run id, no
  # quoting - "<status> <branch> <short-sha> <date> [<pr-url>]".
  FM_FAKE_RUNS_LIST="$(cat <<'EOF'
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-f bbbbbbb  2026-07-02 22:05
EOF
)"
  local out; out=$(run_crew_state "$d" feat-f)
  assert_contains "$out" "state: working" "this branch's own run attributed via the runs list"
  assert_contains "$out" "source: run-step" "runs-list-resolved run -> run-step source"
  pass "cross-branch run is attributed via the real runs list"
}

# The runs list is newest-first; a branch with an OLDER completed run must not
# shadow its own newer active one - the first (topmost) matching row wins.
test_cross_branch_attribution_picks_most_recent_row() {
  reset_fakes
  local d; d=$(new_case crossbranch-mostrecent)
  make_repo_on_branch "$d/wt" fm/feat-fq
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-fq.meta" "window=fm:fm-feat-fq" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<'EOF'
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-fq ccccccc  2026-07-02 21:50
  completed  fm/feat-fq bbbbbbb  2026-07-02 20:00  https://github.com/o/r/pull/1
EOF
)"
  local out; out=$(run_crew_state "$d" feat-fq)
  assert_contains "$out" "state: working" "most recent (running) row wins over an older completed row"
  assert_contains "$out" "source: run-step" "most-recent-row resolution -> run-step source"
  pass "cross-branch attribution picks the branch's most recent row"
}

test_coarse_completed_run_without_identity_fails_closed() {
  reset_fakes
  local d; d=$(new_case coarse-completed-stale)
  make_repo_on_branch "$d/wt" fm/feat-coarse-completed
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-coarse-completed.meta" "window=fm:fm-feat-coarse-completed" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST='completed fm/feat-coarse-completed abc1234 2026-08-01 23:58 https://github.com/o/r/pull/2'
  FM_FAKE_PR_HEAD=def5678cafebabedef5678cafebabedef5678caf
  local out; out=$(run_crew_state "$d" feat-coarse-completed)
  assert_contains "$out" "state: unknown" "coarse completed run without exact identity -> unknown"
  assert_contains "$out" "lacks exact current run identity" "coarse completion names the missing proof"
  assert_contains "$out" "do not merge" "coarse currentness failure is merge-safe"
  assert_not_contains "$out" "state: done" "coarse completion alone must not authorize done"
  pass "coarse completed run without identity fails closed"
}

test_coarse_run_does_not_probe_other_branch_ci_log_for_ready_status() {
  reset_fakes
  local d; d=$(new_case coarse-ready-other-log)
  make_repo_on_branch "$d/wt" fm/feat-coarseready
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-coarseready.meta" "window=fm:fm-feat-coarseready" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/4 checks green\n' > "$d/state/feat-coarseready.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<'EOF'
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-coarseready bbbbbbb  2026-07-02 22:05
EOF
)"
  FM_FAKE_PR_HEAD=bbbbbbbcafebabebbbbbbbcafebabebbbbbbbcaf
  FM_FAKE_REMOTE_COMMIT_HEAD=bbbbbbbcafebabebbbbbbbcafebabebbbbbbbcaf
  FM_FAKE_CI_LOGS="CI checks running, waiting for results..."
  local out; out=$(run_crew_state "$d" feat-coarseready)
  assert_contains "$out" "state: unknown" "coarse ready status without run identity -> unknown"
  assert_contains "$out" "source: status-log" "coarse ready status remains status-log sourced"
  assert_contains "$out" "do not merge" "coarse ready status is merge-safe"
  assert_not_contains "$out" "state: done" "coarse ready status must not authorize done"
  pass "coarse checks-green status without identity fails closed"
}

# A different-branch run with NO matching runs-list row must NOT be
# misattributed, and must not be treated as a false "working" verdict either.
test_other_branch_run_ignored() {
  reset_fakes
  local d; d=$(new_case otherbranch)
  make_repo_on_branch "$d/wt" fm/feat-g
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-g.meta" "window=fm:fm-feat-g" "worktree=$d/wt" "kind=ship"
  printf 'done: implemented, ready to validate\n' > "$d/state/feat-g.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/some-other)"
  FM_FAKE_RUNS_LIST="$(cat <<'EOF'
  running    fm/some-other aaaaaaa  2026-07-02 22:10
EOF
)"
  FM_FAKE_BUSY=0
  local out; out=$(run_crew_state "$d" feat-g)
  assert_not_contains "$out" "source: run-step" "another branch's run not misattributed"
  assert_contains "$out" "source: status-log" "no own run -> falls back to status-log"
  assert_contains "$out" "state: done" "falls back to the log verb"
  pass "another branch's run is ignored, falls back"
}

# (f) no run for this crewmate + a busy pane -> working via pane
test_no_run_busy_pane() {
  reset_fakes
  local d; d=$(new_case busy)
  make_repo_on_branch "$d/wt" fm/feat-h
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-h.meta" "window=fm:fm-feat-h" "worktree=$d/wt" "kind=ship"
  # No matching run anywhere.
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  local out; out=$(run_crew_state "$d" feat-h)
  assert_contains "$out" "state: working" "busy pane -> working"
  assert_contains "$out" "source: pane" "busy pane -> pane source"
  pass "no run + busy pane reads working from the pane"
}

test_direct_pr_ship_does_not_require_no_mistakes_identity() {
  reset_fakes
  local d; d=$(new_case direct-pr-busy)
  make_repo_on_branch "$d/wt" fm/direct-pr-busy
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/direct-pr-busy.meta" \
    "window=fm:fm-direct-pr-busy" \
    "worktree=$d/wt" \
    "kind=ship" \
    "mode=direct-PR"
  FM_FAKE_AXI_STATUS="$(run_running fm/some-neighbour)"
  FM_FAKE_BUSY=1
  local out; out=$(run_crew_state "$d" direct-pr-busy preserve-missing-task-ref)
  assert_contains "$out" "state: working" "direct-PR ship still reads the busy pane"
  assert_contains "$out" "source: pane" "direct-PR ship skips no-mistakes attribution"
  assert_not_contains "$out" "task branch identity" "direct-PR ship does not require a no-mistakes task ref"
  pass "direct-PR ship skips no-mistakes task-branch identity"
}

test_no_run_herdr_unknown_uses_backend_capture() {
  command -v jq >/dev/null 2>&1 || { pass "herdr pane fallback skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-busy)
  make_repo_on_branch "$d/wt" fm/feat-herdr
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" "backend=herdr"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_BUSY=1
  FM_FAKE_HERDR_AGENT_STATUS=""
  local out; out=$(run_crew_state "$d" feat-herdr)
  assert_contains "$out" "state: working" "herdr busy pane -> working"
  assert_contains "$out" "source: pane" "herdr busy pane -> pane source"
  pass "herdr unknown native state falls back to backend capture busy regex"
}

# Regression: herdr's agent.get reports generation state ("working" only while
# the model is actively streaming a turn - docs/herdr-backend.md "Busy state"),
# not "this crewmate's tool call is still in progress". A crewmate blocked on its own
# long-running foreground `no-mistakes axi run` (no --yes; blocks until a gate
# or outcome) is not generating for that whole span, so agent.get can read
# idle while the pane's own rendered text still shows the busy banner
# (BUSY_REGEX) for the entire call. `idle` must be corroborated with that text
# exactly like `unknown` already is, not trusted outright - the bug this
# regression pins: crew_pane_is_busy previously returned "not busy" on a bare
# `idle` verdict without ever looking at the pane.
test_no_run_herdr_idle_agent_status_corroborated_by_busy_pane() {
  command -v jq >/dev/null 2>&1 || { pass "herdr idle corroboration skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-idle-busy-pane)
  make_repo_on_branch "$d/wt" fm/feat-herdr-idle
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-idle.meta" "window=default:w1:p3" "worktree=$d/wt" "kind=ship" "backend=herdr"
  # No run attributable (mirrors a no-mistakes run-step lookup that found no
  # matching row within the configured runs-list window): the pane fallback is
  # the only remaining signal.
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_AGENT_STATUS=idle
  FM_FAKE_HERDR_BUSY=1
  local out; out=$(run_crew_state "$d" feat-herdr-idle)
  assert_contains "$out" "state: working" "herdr idle agent_status with a busy-banner pane -> working"
  assert_contains "$out" "source: pane" "herdr idle agent_status with a busy-banner pane -> pane source"
  pass "herdr idle agent_status is corroborated by the pane text, not trusted outright"
}

# The corroboration must not mask a genuinely idle/human-blocked agent: idle
# agent_status AND an idle-looking pane (no busy banner) still reads not-busy.
test_no_run_herdr_idle_agent_status_and_idle_pane_stays_idle() {
  command -v jq >/dev/null 2>&1 || { pass "herdr idle+idle-pane skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-idle-idle-pane)
  make_repo_on_branch "$d/wt" fm/feat-herdr-stopped
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-stopped.meta" "window=default:w1:p4" "worktree=$d/wt" "kind=ship" "backend=herdr"
  printf 'working: implementing\n' > "$d/state/feat-herdr-stopped.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_AGENT_STATUS=idle
  FM_FAKE_HERDR_BUSY=0
  local out; out=$(run_crew_state "$d" feat-herdr-stopped)
  assert_not_contains "$out" "source: pane" "herdr idle agent_status with an idle pane must not read as busy from the pane"
  assert_contains "$out" "source: status-log" "herdr idle agent_status with an idle pane falls to the status log"
  pass "herdr idle agent_status with a genuinely idle pane stays not-busy (no regression for a human-blocked agent)"
}

# (g) no run + idle pane -> the status-log verb, as-is
test_no_run_idle_pane_uses_log() {
  reset_fakes
  local d; d=$(new_case idle)
  make_repo_on_branch "$d/wt" fm/feat-i
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-i.meta" "window=fm:fm-feat-i" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: which database?\n' > "$d/state/feat-i.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  local out; out=$(run_crew_state "$d" feat-i)
  assert_contains "$out" "state: parked" "needs-decision log -> parked"
  assert_contains "$out" "source: status-log" "idle pane -> status-log source"
  pass "no run + idle pane uses the status-log verb"
}

test_empty_run_lookup_rejects_checks_green_log() {
  reset_fakes
  local d; d=$(new_case empty-run-ready-log)
  make_repo_on_branch "$d/wt" fm/feat-empty-ready
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-empty-ready.meta" "window=fm:fm-feat-empty-ready" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-empty-ready.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  local out; out=$(run_crew_state "$d" feat-empty-ready)
  assert_contains "$out" "state: unknown" "empty run lookup with ready log -> unknown"
  assert_contains "$out" "currentness is unavailable" "unknown verdict names missing currentness"
  assert_contains "$out" "do not merge" "missing run identity is merge-safe"
  assert_not_contains "$out" "state: done" "stale ready log must not authorize done"
  pass "empty run lookup rejects a stale checks-green log"
}

test_missing_identity_rejects_checks_green_log() {
  reset_fakes
  local d; d=$(new_case skipped-run-ready-log)
  make_repo_on_branch "$d/wt" fm/feat-detached-ready
  git -C "$d/wt" checkout -q --detach
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-detached-ready.meta" "window=fm:fm-feat-detached-ready" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-detached-ready.status"
  FM_FAKE_AXI_STATUS="$(run_checks_passed fm/feat-detached-ready)"
  FM_FAKE_BUSY=0
  local out; out=$(run_crew_state "$d" feat-detached-ready)
  assert_contains "$out" "state: unknown" "missing task identity with ready log -> unknown"
  assert_contains "$out" "source: none" "missing task identity refuses before status-log attribution"
  assert_contains "$out" "task branch identity unavailable" "refusal names the missing task identity"
  assert_not_contains "$out" "state: done" "missing task identity must not authorize done"
  pass "missing task identity rejects a stale checks-green log"
}

test_no_run_idle_pane_uses_keyed_log() {
  reset_fakes
  local d; d=$(new_case keyed-idle)
  make_repo_on_branch "$d/wt" fm/feat-keyed
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-keyed.meta" "window=fm:fm-feat-keyed" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision [key=q1]: which database?\n' > "$d/state/feat-keyed.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  local out; out=$(run_crew_state "$d" feat-keyed)
  assert_contains "$out" "state: parked" "keyed needs-decision log -> parked"
  assert_contains "$out" "which database?" "key token is excluded from status detail"
  pass "no run + idle pane parses keyed status syntax"
}

# (g') no run + idle pane on a DECLARED external-wait pause -> state: paused, so a
# supervisor reading the crewmate sees a distinct pause (and its reason) rather than a
# wedge-suspect idle. This is the reader half the watcher/daemon build on.
test_no_run_idle_pane_paused() {
  reset_fakes
  local d; d=$(new_case paused)
  make_repo_on_branch "$d/wt" fm/feat-pause
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-pause.meta" "window=fm:fm-feat-pause" "worktree=$d/wt" "kind=ship"
  printf 'paused: holding for the upstream tool release\n' > "$d/state/feat-pause.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  local out; out=$(run_crew_state "$d" feat-pause)
  assert_contains "$out" "state: paused" "paused log -> paused"
  assert_contains "$out" "source: status-log" "idle pause -> status-log source"
  assert_contains "$out" "holding for the upstream tool release" "the pause reason is carried in the detail"
  pass "no run + idle pane on a paused: status reports state: paused with its reason"
}

test_no_run_idle_pane_custom_paused_verb() {
  reset_fakes
  local d; d=$(new_case custom-paused)
  make_repo_on_branch "$d/wt" fm/feat-custom-pause
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-custom-pause.meta" "window=fm:fm-feat-custom-pause" "worktree=$d/wt" "kind=ship"
  printf 'awaiting: vendor maintenance window\n' > "$d/state/feat-custom-pause.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  local out; out=$(FM_CLASSIFY_PAUSED_VERB=awaiting run_crew_state "$d" feat-custom-pause)
  assert_contains "$out" "state: paused" "custom paused verb -> paused"
  assert_contains "$out" "source: status-log" "custom paused verb -> status-log source"
  assert_contains "$out" "vendor maintenance window" "custom pause preserves its reason"
  printf 'paused: default verb no longer selected\n' > "$d/state/feat-custom-pause.status"
  out=$(FM_CLASSIFY_PAUSED_VERB=awaiting run_crew_state "$d" feat-custom-pause)
  assert_contains "$out" "state: unknown" "custom paused verb replaces the default"
  pass "no run + idle pane honors the configured paused verb"
}

# A trailing keyed resolved: event is a decision-CLOSING event, not a run-state
# verb. It must never become the current state or leak its resolution prose as the
# detail: a healthy idle secondmate that just closed a keyed decision falls through
# to the idle default (unknown/none), not `unknown` with the resolution note as its
# `doing`. Regression for the bearings render bug where such a secondmate showed
# state=unknown with resolution prose. The one-owner keyed fold in fm-classify-lib.sh
# is untouched; this only stops the deriver from reading a non-state event as state.
test_no_run_idle_secondmate_resolved_event_not_state() {
  reset_fakes
  local d; d=$(new_case resolved-idle)
  mkdir -p "$d/wt"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/mate.meta" "window=fm:fm-mate" "worktree=$d/wt" "kind=secondmate" "home=$d/wt"
  printf 'needs-decision [key=race]: pick subscribe order\n' > "$d/state/mate.status"
  printf 'resolved [key=race]: went with subscribe-before-write\n' >> "$d/state/mate.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  local out; out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: unknown" "resolved-then-idle secondmate is not a spurious run-state"
  assert_contains "$out" "source: none" "a resolved event is not treated as a status-log state source"
  assert_not_contains "$out" "subscribe-before-write" "resolution prose must not leak into the detail"
  # A bare (non-keyed) resolved: closes the default key and behaves the same.
  printf 'blocked: waiting on infra\nresolved: infra access granted\n' > "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "source: none" "a bare resolved: is not a state source either"
  assert_not_contains "$out" "infra access granted" "bare resolution prose must not leak into the detail"
  # Control: a genuine trailing state verb still renders from the log.
  printf 'working: reconciling routed items\n' > "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: working" "a real trailing state verb still renders"
  assert_contains "$out" "reconciling routed items" "a real state line still carries its detail"
  pass "a trailing resolved: event does not corrupt state render (idle stays idle)"
}

test_dead_window_ignores_stale_status_log() {
  reset_fakes
  local d; d=$(new_case dead-window)
  make_repo_on_branch "$d/wt" fm/feat-dead
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dead.meta" "window=fm:fm-feat-dead" "worktree=$d/wt" "kind=ship"
  printf 'done: old completion event\n' > "$d/state/feat-dead.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  local out; out=$(run_crew_state "$d" feat-dead)
  assert_contains "$out" "state: unknown" "dead window -> unknown"
  assert_contains "$out" "source: none" "dead window -> none source"
  assert_not_contains "$out" "source: status-log" "dead window does not reuse stale log"
  pass "dead window ignores stale status log"
}

# A closed/unreadable pane must NOT mask an authoritative run-step: judge by the
# run-step, not the shell. The common case is a finished crewmate whose agent has
# exited and closed its window (the normal gap between completion and teardown) -
# it must still report its terminal run-step state (e.g. done), never unknown.
test_dead_window_still_reports_terminal_run_step() {
  reset_fakes
  local d; d=$(new_case dead-window-done)
  make_repo_on_branch "$d/wt" fm/feat-dead-done
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dead-done.meta" "window=fm:fm-feat-dead-done" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/3 checks green\n' > "$d/state/feat-dead-done.status"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-dead-done)"
  FM_FAKE_TMUX_MISSING=1   # the crewmate's window has closed
  local out; out=$(run_crew_state "$d" feat-dead-done)
  assert_contains "$out" "state: done" "closed pane still reports terminal run-step done"
  assert_contains "$out" "source: run-step" "closed pane does not mask the run-step"
  assert_not_contains "$out" "state: unknown" "closed pane with a run must never be unknown"
  pass "closed pane still reports a terminal run-step"
}

# The same for an active run: an agent pane that crashed mid-validation while the
# daemon-backed run continues must report the live run-step, not unknown.
test_dead_window_still_reports_active_run_step() {
  reset_fakes
  local d; d=$(new_case dead-window-active)
  make_repo_on_branch "$d/wt" fm/feat-dead-act
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dead-act.meta" "window=fm:fm-feat-dead-act" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-dead-act)"
  FM_FAKE_TMUX_MISSING=1
  local out; out=$(run_crew_state "$d" feat-dead-act)
  assert_contains "$out" "state: working" "closed pane still reports active run-step"
  assert_contains "$out" "source: run-step" "closed pane does not mask the active run-step"
  assert_not_contains "$out" "state: unknown" "closed pane with an active run must never be unknown"
  pass "closed pane still reports an active run-step"
}

test_no_timeout_uses_perl_bound() {
  reset_fakes
  local d toolbin out start elapsed calls_file calls
  d=$(new_case no-timeout)
  make_repo_on_branch "$d/wt" fm/feat-timeout
  make_fakebin "$d" >/dev/null
  calls_file="$d/no-mistakes.calls"
  : > "$calls_file"
  cat > "$d/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_NM_CALLS:-/dev/null}"
while :; do :; done
SH
  chmod +x "$d/fakebin/no-mistakes"
  toolbin=$(make_no_timeout_toolbin "$d")
  fm_write_meta "$d/state/feat-timeout.meta" \
    "window=fm:fm-feat-timeout" \
    "worktree=$d/wt" \
    "kind=ship" \
    "worktree_git_ref=refs/heads/fm/feat-timeout"
  FM_FAKE_BUSY=1
  start=$SECONDS
  out=$(FM_FAKE_NM_CALLS="$calls_file" PATH="$d/fakebin:$toolbin" FM_STATE_OVERRIDE="$d/state" FM_CREW_STATE_NM_TIMEOUT=1 "$CREW_STATE" feat-timeout)
  elapsed=$((SECONDS - start))
  assert_contains "$out" "state: working" "timed-out no-mistakes falls back to pane"
  assert_contains "$out" "source: pane" "timed-out no-mistakes -> pane source"
  [ "$elapsed" -lt 5 ] || fail "perl timeout did not bound no-mistakes calls (elapsed ${elapsed}s)"
  calls=$(awk 'END { print NR + 0 }' "$calls_file" 2>/dev/null || echo 0)
  [ "$calls" -eq 1 ] || fail "empty no-mistakes status triggered extra lookups ($calls calls)"
  pass "no timeout command uses perl bound"
}

# (i) kind=scout skips the run lookup entirely (its deliverable is a report).
test_scout_skips_run_lookup() {
  reset_fakes
  local d; d=$(new_case scout)
  make_repo_on_branch "$d/wt" fm/scout-j
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/scout-j.meta" "window=fm:fm-scout-j" "worktree=$d/wt" "kind=scout"
  # Even if a run existed on this branch, a scout must not read it.
  FM_FAKE_AXI_STATUS="$(run_running fm/scout-j)"
  FM_FAKE_BUSY=1
  local out; out=$(run_crew_state "$d" scout-j)
  assert_not_contains "$out" "source: run-step" "scout ignores no-mistakes run-step"
  assert_contains "$out" "source: pane" "scout reads pane busy-signature"
  pass "scout skips the run lookup"
}

# (j) torn-down worktree and missing meta are graceful (unknown/none, exit 0)
test_torn_down_worktree() {
  reset_fakes
  local d; d=$(new_case torndown)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/gone-k.meta" "window=fm:fm-gone-k" "worktree=$d/no-such-worktree" "kind=ship"
  local out rc
  out=$(run_crew_state "$d" gone-k); rc=$?
  expect_code 0 "$rc" "torn-down worktree exits 0"
  assert_contains "$out" "state: unknown" "torn-down -> unknown"
  assert_contains "$out" "source: none" "torn-down -> none source"
  pass "torn-down worktree is handled gracefully"
}

test_missing_meta() {
  reset_fakes
  local d; d=$(new_case nometa)
  make_fakebin "$d" >/dev/null
  local out rc
  out=$(run_crew_state "$d" ghost-z); rc=$?
  expect_code 0 "$rc" "missing meta exits 0"
  assert_contains "$out" "state: unknown" "missing meta -> unknown"
  assert_contains "$out" "source: none" "missing meta -> none source"
  pass "missing meta is handled gracefully"
}

# (k) crew_is_provably_working end-to-end over the REAL fm-crew-state.sh (not a
# canned fake verdict, unlike tests/fm-watch-triage.test.sh's classifier
# coverage). This is the direct regression pair for the 2026-07-02 herdr
# incident: a validating crewmate whose bare `axi status` answer belongs to
# another branch must still be absorbed by the watcher via the runs-list
# fallback (working), while a crewmate with genuinely no run anywhere and an idle
# pane must still surface (the safety property the fix must never widen away).
test_provably_working_via_runs_list_fallback() {
  reset_fakes
  local d; d=$(new_case provably-working-crossbranch)
  make_repo_on_branch "$d/wt" fm/feat-provable
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-provable.meta" \
    "window=fm:fm-feat-provable" \
    "worktree=$d/wt" \
    "kind=ship" \
    "worktree_git_ref=refs/heads/fm/feat-provable"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<'EOF'
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-provable bbbbbbb  2026-07-02 22:05
EOF
)"
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_is_provably_working feat-provable \
    || fail "cross-branch attribution via the runs list was not treated as provably working"
  pass "crew_is_provably_working absorbs a validating crew found only via the runs-list fallback"
}

test_not_provably_working_when_stopped() {
  reset_fakes
  local d; d=$(new_case provably-working-stopped)
  make_repo_on_branch "$d/wt" fm/feat-stopped
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-stopped.meta" \
    "window=fm:fm-feat-stopped" \
    "worktree=$d/wt" \
    "kind=ship" \
    "worktree_git_ref=refs/heads/fm/feat-stopped"
  # Repo-wide run belongs to someone else, and this branch has no row in the
  # runs list either (it never validated, or genuinely finished/stopped) - the
  # only remaining signal is the pane, which is idle.
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<'EOF'
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
EOF
)"
  FM_FAKE_BUSY=0
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_is_provably_working feat-stopped \
    && fail "a stopped crew with no run anywhere and an idle pane was treated as provably working"
  pass "crew_is_provably_working still surfaces a genuinely stopped crew (safety property preserved)"
}

# Usage error (no id) is the one non-zero exit.
test_usage_error() {
  reset_fakes
  local rc
  "$CREW_STATE" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "no-arg usage error exits 2"
  pass "usage error exits 2"
}

if [ "${FM_TEST_FOCUSED:-}" = agent-distinct ]; then
  test_active_run_distinguishes_dead_agent
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = agent-banner-content ]; then
  test_working_agent_displaying_banner_text_is_not_dead
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = agent-liveness ]; then
  test_active_run_distinguishes_dead_agent
  test_dead_agent_quota_banner_names_terminal_exhaustion
  test_working_agent_displaying_banner_text_is_not_dead
  test_unreadable_agent_probe_remains_unknown
  test_agent_probe_failures_remain_unknown
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = task-branch ]; then
  test_task_branch_identity_overrides_pooled_worktree_branch
  exit 0
fi

test_active_run_is_authoritative
test_active_run_distinguishes_dead_agent
test_dead_agent_quota_banner_names_terminal_exhaustion
test_working_agent_displaying_banner_text_is_not_dead
test_unreadable_agent_probe_remains_unknown
test_agent_probe_failures_remain_unknown
test_quiet_step_reports_dead_liveness
test_quiet_step_reports_alive_liveness
test_quiet_step_probe_failures_are_unknown
test_quiet_ci_step_skips_liveness
test_stale_needs_decision_superseded
test_stale_blocked_superseded
test_genuine_parked_not_superseded
test_scalar_gate_parked_not_superseded
test_gate_block_parked_not_superseded
test_ci_ready_done_log_beats_monitoring_run
test_ci_ready_log_pr_url_does_not_supply_run_identity
test_ci_monitoring_checks_green_surfaces_done
test_top_level_ci_checks_green_surfaces_done
test_checks_passed_for_older_pr_head_is_stale
test_checks_passed_for_current_pr_head_is_done
test_checks_passed_requires_remote_head_resolution
test_checks_passed_rejects_same_prefix_different_full_head
test_remote_currentness_is_independent_of_local_fetch
test_earlier_completed_run_is_stale_while_newer_run_active
test_completed_run_fails_closed_when_newest_run_is_unavailable
test_completed_run_without_outcome_fails_closed
test_ci_monitoring_no_checks_terminal_surfaces_done
test_ci_monitoring_green_then_rearm_stays_working
test_ci_monitoring_no_checks_yet_stays_working
test_ci_monitoring_still_waiting_stays_working
test_ci_monitoring_green_then_new_issue_stays_working
test_ci_ready_done_log_relapse_stays_working
test_ci_fixing_after_green_stays_working
test_top_level_fixing_ci_running_after_green_stays_working
test_top_level_fixing_done_log_stays_working
test_terminal_passed_verifies_merged_pr
test_terminal_passed_does_not_claim_open_pr_merged
test_terminal_passed_reports_closed_without_merge
test_terminal_passed_fails_closed_when_pr_state_unavailable
test_terminal_passed_clamps_invalid_gh_timeouts_and_fails_closed
test_terminal_failed
test_task_branch_identity_overrides_pooled_worktree_branch
test_cross_branch_attribution_via_runs_list
test_cross_branch_attribution_picks_most_recent_row
test_coarse_completed_run_without_identity_fails_closed
test_coarse_run_does_not_probe_other_branch_ci_log_for_ready_status
test_other_branch_run_ignored
test_no_run_busy_pane
test_direct_pr_ship_does_not_require_no_mistakes_identity
test_no_run_herdr_unknown_uses_backend_capture
test_no_run_herdr_idle_agent_status_corroborated_by_busy_pane
test_no_run_herdr_idle_agent_status_and_idle_pane_stays_idle
test_no_run_idle_pane_uses_log
test_empty_run_lookup_rejects_checks_green_log
test_missing_identity_rejects_checks_green_log
test_no_run_idle_pane_uses_keyed_log
test_no_run_idle_pane_paused
test_no_run_idle_pane_custom_paused_verb
test_no_run_idle_secondmate_resolved_event_not_state
test_dead_window_ignores_stale_status_log
test_dead_window_still_reports_terminal_run_step
test_dead_window_still_reports_active_run_step
test_no_timeout_uses_perl_bound
test_scout_skips_run_lookup
test_torn_down_worktree
test_missing_meta
test_provably_working_via_runs_list_fallback
test_not_provably_working_when_stopped
test_usage_error

echo "all fm-crew-state tests passed"
