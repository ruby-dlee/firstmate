#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Behavior tests for the cross-home terminal green-PR sweep.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SWEEP="$ROOT/bin/fm-terminal-pr-sweep.sh"
TMP=$(fm_test_tmproot fm-terminal-pr-sweep)
FAKEBIN=$(fm_fakebin "$TMP")
PRIMARY="$TMP/primary"
SECONDARY="$TMP/secondary"
UNREGISTERED="$TMP/unregistered"
REMOTE_STATE="$TMP/remote-state"
MERGE_LOG="$TMP/merge.log"
TEARDOWN_LOG="$TMP/teardown.log"
mkdir -p "$PRIMARY/state" "$PRIMARY/data" "$PRIMARY/config" "$PRIMARY/projects"
mkdir -p "$SECONDARY/state" "$SECONDARY/data" "$SECONDARY/config" "$SECONDARY/projects" "$SECONDARY/bin"
mkdir -p "$UNREGISTERED/state" "$UNREGISTERED/data" "$UNREGISTERED/config" "$UNREGISTERED/projects" "$UNREGISTERED/bin"
mkdir -p "$REMOTE_STATE"
: > "$MERGE_LOG"
: > "$TEARDOWN_LOG"
printf '# Fixture Firstmate home\n' > "$SECONDARY/AGENTS.md"
printf '# Fixture Firstmate home\n' > "$UNREGISTERED/AGENTS.md"
printf 'domain\n' > "$SECONDARY/.fm-secondmate-home"
printf 'unregistered\n' > "$UNREGISTERED/.fm-secondmate-home"
printf -- '- domain - fixture (home: %s; scope: fixture; projects: alpha; added 2026-08-12)\n' \
  "$SECONDARY" > "$PRIMARY/data/secondmates.md"

cat > "$FAKEBIN/fm-github-pr.py" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = merge-readiness ] || exit 97
url=${2:-}
number=${url##*/}
head=$(printf '%040x' "$number")
if [ -f "$FM_TEST_REMOTE_STATE/$number.merged" ]; then
  printf 'MERGED %s\n' "$head"
  exit 0
fi
case "$number" in
  1|2|4|6|7|8) printf 'READY %s\n' "$head" ;;
  3) printf 'RED %s\n' "$head" ;;
  5|9) printf 'MERGED %s\n' "$head" ;;
  *) printf 'UNKNOWN %s\n' "$head" ;;
esac
SH

cat > "$FAKEBIN/fm-pr-merge.sh" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$FM_HOME" "$*" >> "$FM_TEST_MERGE_LOG"
id=$1
url=$2
if [ "$id" = blocking-yolo ]; then
  printf 'CROSSCHECK BLOCKING: fixture blocker\n' >&2
  exit 1
fi
number=${url##*/}
touch "$FM_TEST_REMOTE_STATE/$number.merged"
printf '{"merged": true, "outcome": "merged"}\n'
SH

cat > "$FAKEBIN/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
[ "$#" -eq 1 ] || {
  printf 'teardown received forbidden arguments: %s\n' "$*" >&2
  exit 90
}
id=$1
meta="$FM_STATE_OVERRIDE/$id.meta"
if [ "$id" = already-merged-zero ]; then
  grep -qx 'report_required=0' "$meta" || exit 91
fi
printf '%s|%s\n' "$FM_HOME" "$*" >> "$FM_TEST_TEARDOWN_LOG"
if [ "$id" = retry-lock ]; then
  printf 'error: report stack lock timeout: retry, lock held by 4242 for 03:45\n' >&2
  exit 75
fi
rm -f "$meta" "$FM_STATE_OVERRIDE/$id.status" "$FM_STATE_OVERRIDE/$id.check.sh"
printf 'teardown %s complete\n' "$id"
SH
chmod +x "$FAKEBIN/fm-github-pr.py" "$FAKEBIN/fm-pr-merge.sh" "$FAKEBIN/fm-teardown.sh"

write_task() {  # <home> <id> <yolo> <pr-number> [report-required]
  local home=$1 id=$2 yolo=$3 number=$4 report_required=${5:-1}
  fm_write_meta "$home/state/$id.meta" \
    "window=fm-$id" \
    "worktree=$TMP/worktrees/$id" \
    "project=$TMP/projects/repo" \
    'kind=ship' \
    'mode=no-mistakes' \
    "yolo=$yolo" \
    "report_required=$report_required" \
    "pr=https://github.com/acme/repo/pull/$number"
  printf 'done: terminal fixture\n' > "$home/state/$id.status"
}

write_task "$PRIMARY" ready-yolo on 1
write_task "$PRIMARY" ready-captain off 2
write_task "$PRIMARY" red-yolo on 3
write_task "$PRIMARY" blocking-yolo on 4
write_task "$PRIMARY" already-merged-zero on 5 0
write_task "$SECONDARY" secondmate-yolo on 6
write_task "$SECONDARY" secondmate-captain off 7
write_task "$UNREGISTERED" unregistered-yolo on 8
write_task "$PRIMARY" retry-lock on 9
printf '#!/usr/bin/env bash\nprintf "merged\\n"\n' \
  > "$PRIMARY/state/retry-lock.check.sh"
chmod +x "$PRIMARY/state/retry-lock.check.sh"

run_sweep() {
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$PRIMARY" \
  FM_STATE_OVERRIDE="$PRIMARY/state" \
  FM_DATA_OVERRIDE="$PRIMARY/data" \
  FM_TERMINAL_PR_SWEEP_TEST_HOOKS=firstmate-terminal-pr-sweep-tests-v1 \
  FM_TERMINAL_PR_SWEEP_GITHUB_PR_BIN="$FAKEBIN/fm-github-pr.py" \
  FM_TERMINAL_PR_SWEEP_PR_MERGE_BIN="$FAKEBIN/fm-pr-merge.sh" \
  FM_TERMINAL_PR_SWEEP_TEARDOWN_BIN="$FAKEBIN/fm-teardown.sh" \
  FM_TEST_REMOTE_STATE="$REMOTE_STATE" \
  FM_TEST_MERGE_LOG="$MERGE_LOG" \
  FM_TEST_TEARDOWN_LOG="$TEARDOWN_LOG" \
    "$SWEEP" "$@"
}

test_dry_run_is_read_only_and_cross_home() {
  local output
  output=$(run_sweep --dry-run) || fail "terminal PR dry-run failed"
  assert_contains "$output" \
    'would-merge: primary ready-yolo https://github.com/acme/repo/pull/1' \
    "dry-run omitted primary merge intent"
  assert_contains "$output" \
    'would-reap: primary already-merged-zero https://github.com/acme/repo/pull/5' \
    "dry-run omitted already-merged reap intent"
  assert_contains "$output" \
    'would-merge: secondmate:domain secondmate-yolo https://github.com/acme/repo/pull/6' \
    "dry-run omitted registered secondmate"
  assert_contains "$output" \
    'captain: primary ready-captain https://github.com/acme/repo/pull/2' \
    "dry-run omitted captain-owned PR"
  assert_contains "$output" \
    'retained: primary red-yolo https://github.com/acme/repo/pull/3 (red PR checks; never merged)' \
    "dry-run did not make red-PR refusal explicit"
  assert_not_contains "$output" 'unregistered-yolo' \
    "dry-run escaped the registered-home boundary"
  [ ! -s "$MERGE_LOG" ] || fail "dry-run invoked the merge gate"
  [ ! -s "$TEARDOWN_LOG" ] || fail "dry-run invoked teardown"
  assert_present "$PRIMARY/state/retry-lock.check.sh" \
    "dry-run retired a merged-PR check"
  if find "$PRIMARY/state" "$SECONDARY/state" -name '.terminal-pr-sweep-observed-*' \
    -print -quit | grep -q .; then
    fail "dry-run wrote observation markers"
  fi
  pass "dry-run reports cross-home conditional actions without mutation"
}

test_live_sweep_merges_only_yolo_and_reaps_confirmed_merges() {
  local output merge_log teardown_log
  output=$(run_sweep) || fail "live terminal PR sweep failed"
  merge_log=$(cat "$MERGE_LOG")
  teardown_log=$(cat "$TEARDOWN_LOG")

  assert_contains "$output" \
    'merged: primary ready-yolo https://github.com/acme/repo/pull/1' \
    "primary merge was not reported"
  assert_contains "$output" \
    'reaped: primary ready-yolo https://github.com/acme/repo/pull/1' \
    "primary reap was not reported"
  assert_contains "$output" \
    'merged: secondmate:domain secondmate-yolo https://github.com/acme/repo/pull/6' \
    "secondmate merge was not reported"
  assert_contains "$output" \
    'reaped: secondmate:domain secondmate-yolo https://github.com/acme/repo/pull/6' \
    "secondmate reap was not reported"
  assert_contains "$output" \
    'reaped: primary already-merged-zero https://github.com/acme/repo/pull/5' \
    "report_required=0 merged lane did not reap"
  assert_contains "$output" \
    'captain: primary ready-captain https://github.com/acme/repo/pull/2' \
    "yolo=off PR was not surfaced to the captain"
  assert_contains "$output" \
    'blocked: primary blocking-yolo https://github.com/acme/repo/pull/4' \
    "blocking Crosscheck refusal was not reported"
  assert_contains "$output" \
    'retry: primary retry-lock https://github.com/acme/repo/pull/9' \
    "retryable report-lock contention was not reported"

  assert_contains "$merge_log" 'ready-yolo https://github.com/acme/repo/pull/1' \
    "ready yolo PR did not use fm-pr-merge.sh"
  assert_contains "$merge_log" 'blocking-yolo https://github.com/acme/repo/pull/4' \
    "blocking PR never reached the existing gate"
  assert_contains "$merge_log" 'secondmate-yolo https://github.com/acme/repo/pull/6' \
    "registered secondmate PR did not use the merge gate"
  assert_not_contains "$merge_log" 'ready-captain' \
    "yolo=off PR was merged without captain authority"
  assert_not_contains "$merge_log" 'red-yolo' \
    "red PR reached the merge gate"
  assert_not_contains "$merge_log" 'secondmate-captain' \
    "secondmate yolo=off PR was merged"
  assert_not_contains "$merge_log" 'unregistered-yolo' \
    "unregistered home was swept"

  assert_contains "$teardown_log" 'already-merged-zero' \
    "report_required=0 lane did not reach ordinary teardown"
  assert_not_contains "$teardown_log" 'blocking-yolo' \
    "blocking Crosscheck was reaped"
  assert_not_contains "$teardown_log" 'ready-captain' \
    "captain-owned PR was reaped before merge"
  assert_not_contains "$teardown_log" '--force' \
    "terminal PR sweep bypassed ordinary teardown safety"
  assert_absent "$PRIMARY/state/ready-yolo.meta" \
    "merged primary lane retained metadata"
  assert_absent "$PRIMARY/state/already-merged-zero.meta" \
    "merged report_required=0 lane retained metadata"
  assert_absent "$SECONDARY/state/secondmate-yolo.meta" \
    "merged secondmate lane retained metadata"
  assert_present "$PRIMARY/state/ready-captain.meta" \
    "captain-owned lane was removed"
  assert_present "$PRIMARY/state/red-yolo.meta" \
    "red lane was removed"
  assert_present "$PRIMARY/state/blocking-yolo.meta" \
    "blocking Crosscheck lane was removed"
  assert_present "$PRIMARY/state/retry-lock.meta" \
    "retryable report-lock contention removed its lane"
  assert_absent "$PRIMARY/state/retry-lock.check.sh" \
    "confirmed merged lane retained its obsolete polling check"
  pass "live sweep uses the merge gate, respects authority, and ordinarily reaps confirmed merges"
}

test_unchanged_reports_are_deduplicated_while_retries_continue() {
  local before after retry_before retry_after output
  before=$(grep -c 'blocking-yolo' "$MERGE_LOG" || true)
  retry_before=$(grep -c 'retry-lock' "$TEARDOWN_LOG" || true)
  output=$(run_sweep) || fail "repeat terminal PR sweep failed"
  after=$(grep -c 'blocking-yolo' "$MERGE_LOG" || true)
  retry_after=$(grep -c 'retry-lock' "$TEARDOWN_LOG" || true)
  [ "$after" -eq $((before + 1)) ] \
    || fail "blocking merge gate was not retried"
  [ "$retry_after" -eq $((retry_before + 1)) ] \
    || fail "retryable teardown was not retried"
  [ -z "$output" ] \
    || fail "unchanged terminal PR observations caused another wake: $output"
  pass "periodic retries do not create an unchanged watcher wake loop"
}

test_dry_run_is_read_only_and_cross_home
test_live_sweep_merges_only_yolo_and_reaps_confirmed_merges
test_unchanged_reports_are_deduplicated_while_retries_continue

printf 'all fm-terminal-pr-sweep tests passed\n'
