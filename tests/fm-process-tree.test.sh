#!/usr/bin/env bash
# tests/fm-process-tree.test.sh - interrupted bounded-command controllers must
# not leave their TERM-ignoring process-group anchors under pid 1.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-process-tree-lib.sh"
fm_test_tmproot_into TMP_ROOT fm-process-tree-tests
TEST_OWNED_PIDS=

process_tree_test_cleanup() {
  local pid
  for pid in $TEST_OWNED_PIDS; do kill -TERM "$pid" 2>/dev/null || true; done
  sleep 0.1
  for pid in $TEST_OWNED_PIDS; do kill -KILL "$pid" 2>/dev/null || true; done
  for pid in $TEST_OWNED_PIDS; do wait "$pid" 2>/dev/null || true; done
  fm_test_cleanup
}
trap process_tree_test_cleanup EXIT

process_is_live_non_zombie() {  # <pid>
  local state
  state=$(ps -p "$1" -o state= 2>/dev/null | tr -d '[:space:]')
  [ -n "$state" ] || return 1
  case "$state" in *Z*) return 1 ;; esac
  return 0
}

direct_children() {  # <pid>
  ps -axo pid=,ppid= | awk -v parent="$1" '$2 == parent { print $1 }'
}

test_controller_death_reaps_finished_anchor() {
  local ready="$TMP_ROOT/ready" proceed="$TMP_ROOT/proceed" shell_pid controller anchor i
  FM_PROCESS_TREE_TEST_CONTROLLER_READY="$ready" \
    FM_PROCESS_TREE_TEST_CONTROLLER_PROCEED="$proceed" \
    bash -c '. "$1"; fm_run_bounded 30 true' _ "$LIB" >/dev/null 2>&1 &
  shell_pid=$!
  TEST_OWNED_PIDS="$shell_pid"
  i=0
  while [ "$i" -lt 100 ] && [ ! -e "$ready" ]; do
    process_is_live_non_zombie "$shell_pid" || fail "bounded runner exited before its controller pause"
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$ready" ] || fail "bounded runner never reached its post-command controller pause"

  controller=$(direct_children "$shell_pid" | head -1)
  [ -n "$controller" ] || fail "could not resolve the bounded controller from its recorded parent pid"
  anchor=$(direct_children "$controller" | head -1)
  [ -n "$anchor" ] || fail "could not resolve the process-group anchor from controller parentage"
  TEST_OWNED_PIDS="$shell_pid $controller $anchor"

  # Model an operation owner receiving an uncatchable termination after the
  # wrapped command finished. Signal only the exact controller pid discovered
  # from the test-owned root; never select by argv text.
  kill -KILL "$controller" 2>/dev/null || fail "could not stop the test-owned bounded controller"
  wait "$shell_pid" 2>/dev/null || true

  i=0
  while [ "$i" -lt 60 ] && process_is_live_non_zombie "$anchor"; do
    sleep 0.05
    i=$((i + 1))
  done
  if process_is_live_non_zombie "$anchor"; then
    kill -KILL "$anchor" 2>/dev/null || true
    fail "finished process-group anchor survived controller EOF under pid 1"
  fi
  TEST_OWNED_PIDS=
  pass "controller EOF terminates the finished process-group anchor without an orphan"
}

test_controller_death_reaps_running_group() {
  local shell_pid controller anchor command_pid i owned remaining
  bash -c '. "$1"; fm_run_bounded 30 node -e '\''process.on("SIGTERM",()=>{});setTimeout(()=>{},300000)'\''' _ "$LIB" >/dev/null 2>&1 &
  shell_pid=$!
  TEST_OWNED_PIDS="$shell_pid"
  i=0
  while [ "$i" -lt 100 ]; do
    controller=$(direct_children "$shell_pid" | head -1)
    anchor=$(direct_children "${controller:-0}" | head -1)
    command_pid=$(direct_children "${anchor:-0}" | head -1)
    [ -n "$controller" ] && [ -n "$anchor" ] && [ -n "$command_pid" ] && break
    sleep 0.05
    i=$((i + 1))
  done
  [ -n "${command_pid:-}" ] || fail "running bounded tree did not reach its command"
  owned="$controller $anchor $command_pid"
  TEST_OWNED_PIDS="$shell_pid $owned"
  kill -KILL "$controller" 2>/dev/null || fail "could not stop the running test controller"
  wait "$shell_pid" 2>/dev/null || true
  i=0
  while [ "$i" -lt 80 ]; do
    process_is_live_non_zombie "$anchor" || break
    sleep 0.05
    i=$((i + 1))
  done
  remaining=
  for command_pid in $owned; do
    process_is_live_non_zombie "$command_pid" && remaining="$remaining $command_pid"
  done
  if [ -n "$remaining" ]; then
    for command_pid in $remaining; do kill -KILL "$command_pid" 2>/dev/null || true; done
    fail "controller death left running bounded-tree pid(s) alive:$remaining"
  fi
  TEST_OWNED_PIDS=
  pass "controller EOF terminates and reaps a still-running TERM-resistant group"
}

test_controller_death_reaps_residual_grandchild() {
  local shell_pid controller anchor command_pid grandchild_file grandchild_pid guard i remaining
  grandchild_file="$TMP_ROOT/residual-grandchild.pid"
  guard="$TMP_ROOT/residual-grandchild.guard"
  FM_PROCESS_TREE_GUARD_FILE="$guard" bash -c '. "$1"; fm_run_bounded 30 perl -e '\''
    my $path = shift;
    my $child = fork;
    die "fork failed" unless defined $child;
    if (!$child) { $SIG{TERM} = "IGNORE"; sleep 300; exit 0 }
    open my $file, ">", $path or die "pid file failed";
    print {$file} "$child\n";
    close $file;
    $SIG{TERM} = sub { exit 0 };
    sleep 300;
  '\'' "$2"' _ "$LIB" "$grandchild_file" >/dev/null 2>&1 &
  shell_pid=$!
  TEST_OWNED_PIDS="$shell_pid"
  i=0
  while [ "$i" -lt 100 ]; do
    anchor=$(cat "$guard" 2>/dev/null || true)
    controller=$(ps -p "${anchor:-0}" -o ppid= 2>/dev/null | tr -d '[:space:]')
    command_pid=$(direct_children "${anchor:-0}" | head -1)
    [ -n "$controller" ] && [ -n "$command_pid" ] && [ -s "$grandchild_file" ] && break
    sleep 0.05
    i=$((i + 1))
  done
  [ -n "${command_pid:-}" ] && [ -s "$grandchild_file" ] \
    || fail "residual-grandchild bounded tree did not start"
  grandchild_pid=$(cat "$grandchild_file")
  TEST_OWNED_PIDS="$shell_pid $controller $anchor $command_pid $grandchild_pid"
  kill -KILL "$controller" 2>/dev/null || fail "could not stop residual-grandchild controller"
  wait "$shell_pid" 2>/dev/null || true
  i=0
  while [ "$i" -lt 100 ]; do
    remaining=
    for command_pid in "$anchor" "$grandchild_pid"; do
      process_is_live_non_zombie "$command_pid" && remaining="$remaining $command_pid"
    done
    [ -z "$remaining" ] && break
    sleep 0.05
    i=$((i + 1))
  done
  if [ -n "$remaining" ]; then
    for command_pid in $remaining; do kill -KILL "$command_pid" 2>/dev/null || true; done
    fail "controller death left residual same-group pid(s) alive:$remaining"
  fi
  TEST_OWNED_PIDS=
  pass "controller EOF kills a TERM-resistant grandchild after its direct parent exits"
}

if [ "${FM_TEST_FOCUSED:-}" = running ]; then
  test_controller_death_reaps_running_group
  exit 0
fi

test_controller_death_reaps_finished_anchor
test_controller_death_reaps_running_group
test_controller_death_reaps_residual_grandchild
