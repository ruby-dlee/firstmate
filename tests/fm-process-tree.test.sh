#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Direct lifecycle regressions for bin/fm-process-tree-lib.sh and the bounded,
# read-only classification contract of bin/fm-process-tree-health.py.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib.sh disable=SC1091
. "$ROOT/tests/lib.sh"
# shellcheck source=bin/fm-process-tree-lib.sh
. "$ROOT/bin/fm-process-tree-lib.sh"

fm_test_tmproot_into TMP fm-process-tree-tests
ACTIVE_CALLER=
ACTIVE_SUPERVISOR=
ACTIVE_ANCHOR=
ACTIVE_COMMAND=

cleanup() {
  local process_id
  for process_id in "$ACTIVE_COMMAND" "$ACTIVE_ANCHOR" "$ACTIVE_SUPERVISOR" "$ACTIVE_CALLER"; do
    [ -n "$process_id" ] || continue
    kill -CONT "$process_id" 2>/dev/null || true
    kill -KILL "$process_id" 2>/dev/null || true
  done
  [ -z "$ACTIVE_CALLER" ] || wait "$ACTIVE_CALLER" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

wait_for_file() {
  local path=$1 count=0
  while [ ! -s "$path" ] && [ "$count" -lt 300 ]; do
    sleep 0.01
    count=$((count + 1))
  done
  [ -s "$path" ] || fail "fixture did not create $path"
}

wait_for_exit() {
  local process_id=$1 label=$2 count=0
  while kill -0 "$process_id" 2>/dev/null && [ "$count" -lt 600 ]; do
    sleep 0.01
    count=$((count + 1))
  done
  ! kill -0 "$process_id" 2>/dev/null \
    || fail "$label remained alive as process $process_id"
}

find_child() {
  local parent=$1 command=$2
  ps -axo pid=,ppid=,comm= | awk -v parent="$parent" -v command="$command" '
    $2 == parent {
      observed = $3
      sub(/^.*\//, "", observed)
      if (observed == command) { print $1; exit }
    }
  '
}

write_fixture() {
  FIXTURE=$TMP/caller.sh
  cat > "$FIXTURE" <<'SH'
#!/usr/bin/env bash
set -u
root=$1
temp_dir=$2
command_pid_file=$3
mode=$4
# shellcheck source=bin/fm-process-tree-lib.sh
. "$root/bin/fm-process-tree-lib.sh"
captured=
status=0
if [ "$mode" = capture ]; then
  TMPDIR=$temp_dir fm_run_bounded_capture captured 30 sh -c '
    printf "%s\n" "$$" > "$1"
    sleep 30
  ' sh "$command_pid_file" || status=$?
else
  TMPDIR=$temp_dir fm_run_bounded 30 sh -c '
    printf "%s\n" "$$" > "$1"
    sleep 30
  ' sh "$command_pid_file" || status=$?
fi
printf '%s\n' "$status" > "$temp_dir/caller.status"
exit "$status"
SH
  chmod +x "$FIXTURE"
}

start_fixture() {
  local case_dir=$1 mode=${2:-plain}
  mkdir -p "$case_dir"
  "$FIXTURE" "$ROOT" "$case_dir" "$case_dir/command.pid" "$mode" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" &
  ACTIVE_CALLER=$!
  wait_for_file "$case_dir/command.pid"
  ACTIVE_COMMAND=$(cat "$case_dir/command.pid")
  ACTIVE_SUPERVISOR=$(find_child "$ACTIVE_CALLER" perl)
  [ -n "$ACTIVE_SUPERVISOR" ] || fail "fixture did not expose its Perl supervisor"
  ACTIVE_ANCHOR=$(find_child "$ACTIVE_SUPERVISOR" perl)
  [ -n "$ACTIVE_ANCHOR" ] || fail "fixture did not expose its process-group anchor"
}

clear_fixture() {
  ACTIVE_CALLER=
  ACTIVE_SUPERVISOR=
  ACTIVE_ANCHOR=
  ACTIVE_COMMAND=
}

assert_no_artifacts() {
  local case_dir=$1
  [ "$(find "$case_dir" -type f -name 'fm-process-tree-*' | wc -l | tr -d ' ')" -eq 0 ] \
    || fail "bounded runner left temporary channels under $case_dir"
}

test_orphaned_anchor_exits_on_finish_pipe_eof() {
  local case_dir=$TMP/orphan-anchor
  start_fixture "$case_dir"

  # Hold the outer supervisor so the command can exit and the anchor can write
  # status before the supervisor is killed. This deterministically reaches the
  # old defective state: the anchor is already waiting on the finish pipe when
  # its only writer disappears.
  kill -STOP "$ACTIVE_SUPERVISOR"
  kill -TERM "$ACTIVE_COMMAND"
  wait_for_exit "$ACTIVE_COMMAND" "test-owned wrapped command"
  ACTIVE_COMMAND=
  sleep 0.2
  kill -KILL "$ACTIVE_SUPERVISOR"
  ACTIVE_SUPERVISOR=
  wait "$ACTIVE_CALLER" 2>/dev/null || true
  ACTIVE_CALLER=

  wait_for_exit "$ACTIVE_ANCHOR" "orphaned process-group anchor"
  ACTIVE_ANCHOR=
  assert_no_artifacts "$case_dir"
}

test_foreground_supervisor_exits_when_shell_owner_dies() {
  local case_dir=$TMP/orphan-supervisor
  start_fixture "$case_dir" capture
  kill -KILL "$ACTIVE_CALLER"
  wait "$ACTIVE_CALLER" 2>/dev/null || true
  ACTIVE_CALLER=

  wait_for_exit "$ACTIVE_SUPERVISOR" "caller-orphaned foreground supervisor"
  wait_for_exit "$ACTIVE_ANCHOR" "caller-orphaned process-group anchor"
  wait_for_exit "$ACTIVE_COMMAND" "caller-orphaned wrapped command"
  clear_fixture
  assert_no_artifacts "$case_dir"
}

test_supervisor_alarm_is_not_inherited_by_command() {
  local case_dir=$TMP/alarm-isolation
  mkdir -p "$case_dir"
  # shellcheck disable=SC2016 # The Perl source owns its variables.
  TMPDIR=$case_dir fm_run_bounded 2 perl -MTime::HiRes=time -e '
    my $started = time();
    select undef, undef, undef, 0.45;
    exit(time() - $started >= 0.4 ? 0 : 1);
  ' >/dev/null 2>&1 || fail "wrapped command inherited the supervisor alarm pulse"
  [ "$FM_PROCESS_TREE_CLEANUP_STATUS" = verified ] \
    || fail "alarm-isolation command did not verify cleanup"
  assert_no_artifacts "$case_dir"
}

test_health_classification_and_apply_gate() {
  python3 - "$ROOT/bin/fm-process-tree-health.py" <<'PY'
import contextlib
import importlib.util
import io
import os
import sys
import tempfile

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("fm_process_tree_health", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
uid = os.getuid()
marker = b" ".join(module.SUPERVISOR_MARKERS)
process = module.ProcessInfo
single = process(10, 1, 10, uid, (1, 0), "perl")
owned_group = process(20, 1, 20, uid, (2, 0), "perl")
owned_child = process(21, 20, 20, uid, (2, 1), "sleep")
unrelated = process(30, 1, 30, uid, (3, 0), "python3")
guarded = process(40, 1, 40, uid, (4, 0), "perl")
with tempfile.NamedTemporaryFile() as guard:
    guard.write(b"40\n")
    guard.flush()
    guarded_arguments = marker + b"\0FM_PROCESS_TREE_GUARD_FILE=" + os.fsencode(guard.name)
    census = module._summarize(
        {10: single, 20: owned_group, 21: owned_child, 30: unrelated, 40: guarded},
        {
            10: (marker, 100),
            20: (marker, 200),
            30: (b"python3 service.py", 50),
            40: (guarded_arguments, 400),
        },
        True,
    )
assert [item.process_id for item in census.leaked_supervisors] == [10, 20, 40], census
assert [item.process_id for item in census.reaper_candidates] == [10], census
assert census.parentless_argument_bytes == 750, census
assert census.complete and not census.gap, census
module.reap_orphans = lambda _limit: (_ for _ in ()).throw(
    AssertionError("reap ran without --apply")
)
error = io.StringIO()
with contextlib.redirect_stderr(error):
    assert module.main(["reap"]) == 2
assert "explicit captain authorization" in error.getvalue(), error.getvalue()
PY

  local report
  report=$("$ROOT/bin/fm-process-tree-health.py" report) \
    || fail "read-only process-tree health report failed"
  case "$report" in
    leaked_supervisors=[0-9]*\ parentless_argv_bytes=[0-9]*\ census_complete=[01]\ reaper_candidates=[0-9]*\ gap=*) ;;
    *) fail "read-only process-tree health report was malformed: $report" ;;
  esac
}

write_fixture
test_orphaned_anchor_exits_on_finish_pipe_eof
test_foreground_supervisor_exits_when_shell_owner_dies
test_supervisor_alarm_is_not_inherited_by_command
test_health_classification_and_apply_gate
printf 'fm-process-tree tests passed\n'
