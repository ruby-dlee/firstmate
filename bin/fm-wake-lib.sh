#!/usr/bin/env bash
# Shared durable wake queue and portable lock helpers.

FM_WAKE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_WAKE_DEFAULT_ROOT="$(cd "$FM_WAKE_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_WAKE_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"
FM_WAKE_QUEUE="${FM_WAKE_QUEUE:-$STATE/.wake-queue}"
FM_WAKE_QUEUE_LOCK="${FM_WAKE_QUEUE_LOCK:-$STATE/.wake-queue.lock}"
FM_LOCK_STALE_AFTER="${FM_LOCK_STALE_AFTER:-2}"
mkdir -p "$STATE"
if [ -L "$STATE" ] || [ ! -d "$STATE" ]; then
  printf 'error: unsafe wake state directory: %s\n' "$STATE" >&2
  # shellcheck disable=SC2317
  return 1 2>/dev/null || exit 1
fi

fm_wake_safe_file_destination() {
  [ ! -L "$1" ] && { [ ! -e "$1" ] || [ -f "$1" ]; }
}

fm_current_pid() {
  printf '%s\n' "${BASHPID:-$$}"
}

fm_pid_alive() {
  local pid=$1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

fm_pid_identity() {
  local pid=$1 out
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  # Pin LC_ALL=C so lstart's date format is locale-invariant: the identity is
  # written under one locale but re-read under the machine's ambient locale, which
  # would otherwise mismatch on a non-C locale (e.g. ko_KR) and reject a live watcher.
  out=$(LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed 's/^[[:space:]]*//'
}

fm_pid_session() {  # <pid>
  local pid=$1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  python3 -c '
import ctypes
import sys

pid = int(sys.argv[1])
libc = ctypes.CDLL(None, use_errno=True)
session = libc.getsid(pid)
if session < 0:
    raise SystemExit(1)
print(session)
' "$pid"
}

fm_session_snapshot() {  # <session-id> [excluded-root-pid]
  local session=$1 excluded=${2:-}
  case "$session" in ''|*[!0-9]*) return 1 ;; esac
  case "$excluded" in *[!0-9]*) return 1 ;; esac
  python3 -c '
import ctypes
import os
import subprocess
import sys
import time

session = int(sys.argv[1])
excluded = int(sys.argv[2]) if sys.argv[2] else None
enumerator = os.getpid()
enumerator_caller = os.getppid()
libc = ctypes.CDLL(None, use_errno=True)
result = subprocess.run(
    ["ps", "-axo", "pid=,ppid=,state="],
    check=True,
    stdout=subprocess.PIPE,
    universal_newlines=True,
)
processes = {}
for line in result.stdout.splitlines():
    fields = line.split()
    if len(fields) != 3 or not fields[0].isdigit() or not fields[1].isdigit():
        continue
    processes[int(fields[0])] = (int(fields[1]), fields[2])

if (
    os.environ.get("FM_SESSION_SNAPSHOT_TEST_HOOKS") == "firstmate-session-snapshot-tests-v1"
    and os.environ.get("FM_SESSION_SNAPSHOT_TEST_ARMED")
    and os.path.exists(os.environ["FM_SESSION_SNAPSHOT_TEST_ARMED"])
    and os.environ.get("FM_SESSION_SNAPSHOT_TEST_READY")
    and os.environ.get("FM_SESSION_SNAPSHOT_TEST_PROCEED")
    and not os.path.exists(os.environ["FM_SESSION_SNAPSHOT_TEST_READY"])
):
    with open(os.environ["FM_SESSION_SNAPSHOT_TEST_READY"], "x", encoding="utf-8"):
        pass
    while not os.path.exists(os.environ["FM_SESSION_SNAPSHOT_TEST_PROCEED"]):
        time.sleep(0.01)

def in_excluded_tree(pid):
    if pid == enumerator_caller:
        return True
    seen = set()
    while pid not in seen:
        if pid == enumerator or (excluded is not None and pid == excluded):
            return True
        seen.add(pid)
        process = processes.get(pid)
        if process is None:
            break
        pid = process[0]
    return False

for pid, (_, state) in processes.items():
    if "Z" not in state and not in_excluded_tree(pid) and libc.getsid(pid) == session:
        print(pid)
' "$session" "$excluded"
}

fm_session_has_live_processes() {  # <session-id>
  local members
  members=$(fm_session_snapshot "$1") || return 2
  [ -n "$members" ]
}

fm_session_has_live_processes_except() {  # <session-id> <excluded-pid>
  local session=$1 excluded=$2 pid snapshot
  snapshot=$(fm_session_snapshot "$session" "$excluded") || return 2
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    [ "$pid" = "$excluded" ] || return 0
  done <<< "$snapshot"
  return 1
}

fm_session_wait_quiescent_except() {  # <session-id> <excluded-pid> [wait-tenths]
  local session=$1 excluded=$2 wait_tenths=${3:-20} iteration=0 status empty_streak=0
  while [ "$iteration" -lt "$wait_tenths" ]; do
    status=0
    fm_session_has_live_processes_except "$session" "$excluded" || status=$?
    case "$status" in
      0) empty_streak=0 ;;
      1)
        empty_streak=$((empty_streak + 1))
        [ "$empty_streak" -lt 2 ] || return 0
        ;;
      *) return 1 ;;
    esac
    sleep 0.1
    iteration=$((iteration + 1))
  done
  return 1
}

fm_session_signal_members() {  # <signal> <session-id> [excluded-pid]
  local signal=$1 session=$2 excluded=${3:-} pid identity index snapshot
  local pids=() identities=()
  snapshot=$(fm_session_snapshot "$session" "$excluded") || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    identity=$(fm_pid_identity "$pid") || continue
    pids+=("$pid")
    identities+=("$identity")
  done <<< "$snapshot"
  for index in "${!pids[@]}"; do
    pid=${pids[$index]}
    [ "$pid" != "$excluded" ] || continue
    [ "$(fm_pid_identity "$pid" 2>/dev/null || true)" = "${identities[$index]}" ] || continue
    [ "$(fm_pid_session "$pid" 2>/dev/null || true)" = "$session" ] || continue
    kill "-$signal" "$pid" 2>/dev/null || true
  done
}

fm_session_stop_owned_except() {  # <session-id> <excluded-pid> [term-wait-tenths]
  local session=$1 excluded=$2 wait_tenths=${3:-30} iteration status empty_streak=0 excluded_identity=
  if [ -n "$excluded" ]; then
    excluded_identity=$(fm_pid_identity "$excluded") || return 1
    [ "$(fm_pid_session "$excluded" 2>/dev/null || true)" = "$session" ] || return 1
  fi
  fm_session_signal_members TERM "$session" "$excluded" || return 1
  iteration=0
  while [ "$iteration" -lt "$wait_tenths" ]; do
    status=0
    fm_session_has_live_processes_except "$session" "$excluded" || status=$?
    case "$status" in
      0)
        if [ "$empty_streak" -gt 0 ] && [ -z "$excluded_identity" ]; then
          return 1
        fi
        empty_streak=0
        ;;
      1)
        empty_streak=$((empty_streak + 1))
        [ "$empty_streak" -lt 2 ] || return 0
        ;;
      *) return 1 ;;
    esac
    sleep 0.1
    iteration=$((iteration + 1))
  done
  iteration=0
  empty_streak=0
  while [ "$iteration" -lt 20 ]; do
    if [ "$empty_streak" -eq 0 ]; then
      if [ -n "$excluded_identity" ]; then
        [ "$(fm_pid_identity "$excluded" 2>/dev/null || true)" = "$excluded_identity" ] || return 1
        [ "$(fm_pid_session "$excluded" 2>/dev/null || true)" = "$session" ] || return 1
      fi
      fm_session_signal_members KILL "$session" "$excluded" || return 1
    fi
    sleep 0.1
    status=0
    fm_session_has_live_processes_except "$session" "$excluded" || status=$?
    case "$status" in
      0)
        if [ "$empty_streak" -gt 0 ] && [ -z "$excluded_identity" ]; then
          return 1
        fi
        empty_streak=0
        ;;
      1)
        empty_streak=$((empty_streak + 1))
        [ "$empty_streak" -lt 2 ] || return 0
        ;;
      *) return 1 ;;
    esac
    iteration=$((iteration + 1))
  done
  return 1
}

fm_session_stop_owned() {  # <session-id> [term-wait-tenths]
  fm_session_stop_owned_except "$1" "" "${2:-30}"
}

fm_pid_stop_identity() {  # <pid> <pid-identity> [term-wait-tenths]
  local pid=$1 identity=$2 wait_tenths=${3:-30} iteration=0
  [ -n "$identity" ] || return 1
  [ "$(fm_pid_identity "$pid" 2>/dev/null || true)" = "$identity" ] || return 1
  kill -TERM "$pid" 2>/dev/null || true
  while [ "$iteration" -lt "$wait_tenths" ]; do
    [ "$(fm_pid_identity "$pid" 2>/dev/null || true)" = "$identity" ] || return 0
    sleep 0.1
    iteration=$((iteration + 1))
  done
  kill -KILL "$pid" 2>/dev/null || true
  iteration=0
  while [ "$iteration" -lt 20 ]; do
    [ "$(fm_pid_identity "$pid" 2>/dev/null || true)" = "$identity" ] || return 0
    sleep 0.1
    iteration=$((iteration + 1))
  done
  return 1
}

fm_session_anchor_matches() {  # <session-id> <anchor-pid> <anchor-identity>
  local session=$1 anchor=$2 identity=$3
  [ -n "$identity" ] || return 1
  [ "$(fm_pid_identity "$anchor" 2>/dev/null || true)" = "$identity" ] || return 1
  [ "$(fm_pid_session "$anchor" 2>/dev/null || true)" = "$session" ]
}

fm_session_stop_owned_with_anchor() {  # <session-id> <anchor-pid> <anchor-identity> [term-wait-tenths]
  local session=$1 anchor=$2 identity=$3 wait_tenths=${4:-30}
  fm_session_anchor_matches "$session" "$anchor" "$identity" || return 1
  fm_session_stop_owned_except "$session" "$anchor" "$wait_tenths" || return 1
  fm_session_anchor_matches "$session" "$anchor" "$identity" || return 1
  fm_pid_stop_identity "$anchor" "$identity" "$wait_tenths" || return 1
  fm_session_wait_quiescent_except "$session" "" 20
}

fm_pid_session_stop() {  # <root-pid> <session-id> [term-wait-tenths] [expected-root-identity]
  local root=$1 session=$2 wait_tenths=${3:-30} expected_identity=${4:-} current_identity
  [ "$session" = "$root" ] || return 1
  current_identity=$(fm_pid_identity "$root") || return 1
  [ -z "$expected_identity" ] || [ "$current_identity" = "$expected_identity" ] || return 1
  [ "$(fm_pid_session "$root" 2>/dev/null || true)" = "$session" ] || return 1
  fm_session_stop_owned "$session" "$wait_tenths"
}

fm_watcher_lock_owner_record_matches() {  # <state> <watch-path> <home> <pid> <pid-identity>
  local state=$1 watch_path=$2 home=$3 expected_pid=$4 expected_identity=$5 lockdir
  lockdir="$state/.watch.lock"
  [ -n "$expected_identity" ] || return 1
  [ "$(cat "$lockdir/pid" 2>/dev/null || true)" = "$expected_pid" ] || return 1
  [ "$(cat "$lockdir/pid-identity" 2>/dev/null || true)" = "$expected_identity" ] || return 1
  [ "$(cat "$lockdir/fm-home" 2>/dev/null || true)" = "$home" ] || return 1
  [ "$(cat "$lockdir/watcher-path" 2>/dev/null || true)" = "$watch_path" ]
}

fm_watcher_lock_session_record_matches() {  # <state> <watch-path> <home> <session-id>
  local state=$1 watch_path=$2 home=$3 session=$4 lockdir identity
  lockdir="$state/.watch.lock"
  identity=$(cat "$lockdir/pid-identity" 2>/dev/null || true)
  fm_watcher_lock_owner_record_matches "$state" "$watch_path" "$home" "$session" "$identity" \
    || return 1
  [ "$(cat "$lockdir/process-session" 2>/dev/null || true)" = "$session" ]
}

fm_watcher_lock_session_anchor_matches() {  # <state> <session-id>
  local state=$1 session=$2 lockdir anchor identity
  lockdir="$state/.watch.lock"
  anchor=$(cat "$lockdir/session-anchor-pid" 2>/dev/null || true)
  identity=$(cat "$lockdir/session-anchor-identity" 2>/dev/null || true)
  fm_session_anchor_matches "$session" "$anchor" "$identity"
}

fm_watcher_lock_stop_session_anchor() {  # <state> <session-id> <expected-anchor-pid> [term-wait-tenths]
  local state=$1 session=$2 expected_anchor=$3 wait_tenths=${4:-30} lockdir anchor identity
  lockdir="$state/.watch.lock"
  anchor=$(cat "$lockdir/session-anchor-pid" 2>/dev/null || true)
  identity=$(cat "$lockdir/session-anchor-identity" 2>/dev/null || true)
  [ "$anchor" = "$expected_anchor" ] || return 1
  fm_session_anchor_matches "$session" "$anchor" "$identity" || return 1
  fm_pid_stop_identity "$anchor" "$identity" "$wait_tenths"
}

fm_watcher_lock_session_matches_pid() {  # <state> <watch-path> <home> <watcher-pid>
  local state=$1 watch_path=$2 home=$3 pid=$4 session
  session=$(cat "$state/.watch.lock/process-session" 2>/dev/null || true)
  [ "$session" = "$pid" ] || return 1
  fm_watcher_lock_session_record_matches "$state" "$watch_path" "$home" "$session" || return 1
  [ "$(fm_pid_session "$pid" 2>/dev/null || true)" = "$session" ]
}

fm_watcher_session_guard_release() {  # <lockdir> <watcher-pid>
  local lockdir=$1 pid=$2 session member snapshot
  session=$(cat "$lockdir/process-session" 2>/dev/null || true)
  [ "$session" = "$pid" ] || return 1
  [ "$(fm_pid_session "$pid" 2>/dev/null || true)" = "$session" ] || return 1
  snapshot=$(fm_session_snapshot "$session") || return 1
  while IFS= read -r member; do
    [ -z "$member" ] || [ "$member" = "$pid" ] || return 1
  done <<< "$snapshot"
  [ "$(cat "$lockdir/process-session" 2>/dev/null || true)" = "$session" ] || return 1
  rm -f "$lockdir/process-session"
}

fm_path_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fm_path_age() {
  local path=$1 m
  m=$(fm_path_mtime "$path") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

fm_watcher_lock_matches_pid() {
  local state=$1 watch_path=$2 pid=$3 home=${4:-$FM_HOME} lockdir lock_home lock_path lock_identity current_identity
  lockdir="$state/.watch.lock"
  lock_home=$(cat "$lockdir/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$lockdir/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$lockdir/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$home" ] || return 1
  [ "$lock_path" = "$watch_path" ] || return 1
  [ -n "$lock_identity" ] || return 1
  current_identity=$(fm_pid_identity "$pid") || return 1
  [ "$current_identity" = "$lock_identity" ]
}

FM_WATCHER_HEALTHY_PID=
FM_WATCHER_ACTIVE_PHASE=
FM_WATCHER_ACTIVE_PHASE_REMAINING=
fm_watcher_phase_active() {  # <state> <watcher-pid>
  local state=$1 pid=$2 phase_file snapshot phase_pid phase_name phase_deadline phase_identity current_identity now
  FM_WATCHER_ACTIVE_PHASE=
  FM_WATCHER_ACTIVE_PHASE_REMAINING=
  phase_file="$state/.watch.phase"
  [ -f "$phase_file" ] && [ ! -L "$phase_file" ] || return 1
  snapshot=$(cat "$phase_file" 2>/dev/null) || return 1
  [ "$(printf '%s\n' "$snapshot" | grep -c '^pid=' || true)" = 1 ] || return 1
  [ "$(printf '%s\n' "$snapshot" | grep -c '^phase=' || true)" = 1 ] || return 1
  [ "$(printf '%s\n' "$snapshot" | grep -c '^deadline=' || true)" = 1 ] || return 1
  [ "$(printf '%s\n' "$snapshot" | grep -c '^pid-identity=' || true)" = 1 ] || return 1
  phase_pid=$(printf '%s\n' "$snapshot" | sed -n 's/^pid=//p')
  phase_name=$(printf '%s\n' "$snapshot" | sed -n 's/^phase=//p')
  phase_deadline=$(printf '%s\n' "$snapshot" | sed -n 's/^deadline=//p')
  phase_identity=$(printf '%s\n' "$snapshot" | sed -n 's/^pid-identity=//p')
  [ "$phase_pid" = "$pid" ] || return 1
  case "$phase_name" in ''|*[!a-z0-9-]*) return 1 ;; esac
  case "$phase_deadline" in ''|*[!0-9]*) return 1 ;; esac
  current_identity=$(fm_pid_identity "$pid") || return 1
  [ "$phase_identity" = "$current_identity" ] || return 1
  now=$(date +%s)
  [ "$phase_deadline" -ge "$now" ] || return 1
  FM_WATCHER_ACTIVE_PHASE=$phase_name
  FM_WATCHER_ACTIVE_PHASE_REMAINING=$((phase_deadline - now))
  return 0
}

fm_watcher_progress_current() {  # <state> <watcher-pid> <grace>
  local state=$1 pid=$2 grace=$3 age
  age=$(fm_path_age "$state/.last-watcher-beat")
  [ "$age" -lt "$grace" ] && return 0
  fm_watcher_phase_active "$state" "$pid" && return 0
  age=$(fm_path_age "$state/.last-watcher-beat")
  [ "$age" -lt "$grace" ]
}

fm_watcher_healthy() {
  local state=$1 watch_path=$2 grace=${3:-${FM_GUARD_GRACE:-300}} home=${4:-$FM_HOME} lockdir pid
  FM_WATCHER_HEALTHY_PID=
  lockdir="$state/.watch.lock"
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  fm_watcher_lock_matches_pid "$state" "$watch_path" "$pid" "$home" || return 1
  fm_watcher_progress_current "$state" "$pid" "$grace" || return 1
  # shellcheck disable=SC2034 # Read by callers after fm_watcher_healthy returns.
  FM_WATCHER_HEALTHY_PID=$pid
  return 0
}

# Enumerate one recorded process tree strictly by numeric pid and parentage.
# Command text is intentionally absent from both the input and the selection:
# watcher strings routinely appear in agent briefs and cannot identify a
# process. Output is deepest-first "<depth> <pid>" for bounded descendant drain
# and KILL escalation.
fm_pid_tree_snapshot() {  # <root-pid>
  local root=$1
  case "$root" in ''|*[!0-9]*) return 1 ;; esac
  LC_ALL=C ps -axo pid=,ppid= 2>/dev/null | awk -v root="$root" '
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
      count++
      pid[count] = $1
      parent[count] = $2
    }
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

FM_WATCHER_TREE_CPU=
FM_WATCHER_TREE_COUNT=0
fm_watcher_tree_usage() {  # <recorded-root-pid>
  local root=$1 result
  case "$root" in ''|*[!0-9]*) return 1 ;; esac
  result=$(LC_ALL=C ps -axo pid=,ppid=,%cpu= 2>/dev/null | awk -v root="$root" '
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
        current = pid[index_value]
        if (current in owned) {
          total += cpu[index_value]
          members++
        }
      }
      if (!members) exit 1
      printf "%.1f\t%d\n", total, members
    }
  ') || return 1
  # shellcheck disable=SC2034 # CPU and count are the caller-facing snapshot globals.
  IFS=$(printf '\t') read -r FM_WATCHER_TREE_CPU FM_WATCHER_TREE_COUNT <<EOF
$result
EOF
  [ -n "$FM_WATCHER_TREE_CPU" ]
}

# Stop only a previously validated recorded root and its exact descendants.
# Every signal target comes from fm_pid_tree_snapshot and is identity-pinned
# before the first signal, so pid reuse cannot turn recovery into a broad kill.
fm_pid_tree_stop() {  # <root-pid> [term-wait-tenths] [expected-root-identity]
  local root=$1 wait_tenths=${2:-30} expected_identity=${3:-}
  local pid identity index iteration any root_verified
  local tree_pids=() tree_identities=()
  while IFS=' ' read -r _depth pid; do
    [ -n "$pid" ] || continue
    identity=$(fm_pid_identity "$pid") || continue
    tree_pids+=("$pid")
    tree_identities+=("$identity")
  done < <(fm_pid_tree_snapshot "$root")
  if [ "${#tree_pids[@]}" -eq 0 ]; then
    [ -z "$expected_identity" ] && return 0
    return 1
  fi
  if [ -n "$expected_identity" ]; then
    root_verified=0
    for index in "${!tree_pids[@]}"; do
      [ "${tree_pids[$index]}" = "$root" ] || continue
      [ "${tree_identities[$index]}" = "$expected_identity" ] && root_verified=1
      break
    done
    # The recorded process exited or its pid was reused between lock validation
    # and snapshot. There is no longer an identity-pinned owned tree to signal.
    [ "$root_verified" -eq 1 ] || return 1
  fi
  # Ask the root to stop first so it cannot launch new work as descendants are
  # drained. Bash may defer TERM while waiting on a child, which is why the
  # deepest-first descendant pass and the later KILL bound are still required.
  for index in "${!tree_pids[@]}"; do
    [ "${tree_pids[$index]}" = "$root" ] || continue
    [ "$(fm_pid_identity "$root" 2>/dev/null || true)" = "${tree_identities[$index]}" ] || continue
    kill -TERM "$root" 2>/dev/null || true
    break
  done
  for index in "${!tree_pids[@]}"; do
    pid=${tree_pids[$index]}
    [ "$pid" != "$root" ] || continue
    [ "$(fm_pid_identity "$pid" 2>/dev/null || true)" = "${tree_identities[$index]}" ] || continue
    kill -TERM "$pid" 2>/dev/null || true
  done
  iteration=0
  while [ "$iteration" -lt "$wait_tenths" ]; do
    any=0
    for index in "${!tree_pids[@]}"; do
      pid=${tree_pids[$index]}
      if [ "$(fm_pid_identity "$pid" 2>/dev/null || true)" = "${tree_identities[$index]}" ]; then
        any=1
        break
      fi
    done
    [ "$any" -eq 0 ] && return 0
    sleep 0.1
    iteration=$((iteration + 1))
  done
  for index in "${!tree_pids[@]}"; do
    pid=${tree_pids[$index]}
    [ "$(fm_pid_identity "$pid" 2>/dev/null || true)" = "${tree_identities[$index]}" ] || continue
    kill -KILL "$pid" 2>/dev/null || true
  done
  iteration=0
  while [ "$iteration" -lt 20 ]; do
    any=0
    for index in "${!tree_pids[@]}"; do
      pid=${tree_pids[$index]}
      if [ "$(fm_pid_identity "$pid" 2>/dev/null || true)" = "${tree_identities[$index]}" ]; then
        any=1
        break
      fi
    done
    [ "$any" -eq 0 ] && return 0
    sleep 0.1
    iteration=$((iteration + 1))
  done
  return 1
}

fm_lock_clean_known_files() {
  local lockdir=$1 target=$2 confined
  confined=$(fm_lock_confined_target "$lockdir" "$target") || return 1
  rm -f \
    "$confined/pid" \
    "$confined/fm-home" \
    "$confined/pid-identity" \
    "$confined/process-group" \
    "$confined/process-session" \
    "$confined/session-anchor-pid" \
    "$confined/session-anchor-identity" \
    "$confined/watcher-path" \
    2>/dev/null || true
}

fm_lock_abs_path() {
  local path=$1 dir base
  dir=$(dirname "$path")
  base=$(basename "$path")
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$dir" "$base"
}

fm_lock_owner_dir() {
  local lockdir=$1 lock_abs
  lock_abs=$(fm_lock_abs_path "$lockdir") || return 1
  mktemp -d "${lock_abs}.owner.XXXXXX" 2>/dev/null
}

fm_lock_confined_target() {
  local lockdir=$1 target=$2 lock_abs target_abs parent lock_base target_base
  lock_abs=$(fm_lock_abs_path "$lockdir") || return 1
  target_abs=$(fm_lock_abs_path "$target") || return 1
  [ -d "$target_abs" ] && [ ! -L "$target_abs" ] || return 1
  parent=$(dirname "$lock_abs")
  [ "$(dirname "$target_abs")" = "$parent" ] || return 1
  if [ "$target_abs" != "$lock_abs" ]; then
    lock_base=$(basename "$lock_abs")
    target_base=$(basename "$target_abs")
    case "$target_base" in
      "$lock_base".owner.*) ;;
      *) return 1 ;;
    esac
  fi
  printf '%s\n' "$target_abs"
}

fm_lock_prepare_owner() {
  local ownerdir=$1 mypid back
  mypid=${BASHPID:-$$}
  printf '%s\n' "$mypid" > "$ownerdir/pid" 2>/dev/null || return 1
  back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  [ "$back" = "$mypid" ]
}

fm_lock_link_owner() {
  local lockdir=$1 owner resolved
  [ -L "$lockdir" ] || return 1
  owner=$(readlink "$lockdir" 2>/dev/null) || return 1
  [ -n "$owner" ] || return 1
  case "$owner" in
    /*) resolved=$owner ;;
    *) resolved="$(dirname "$lockdir")/$owner" ;;
  esac
  fm_lock_confined_target "$lockdir" "$resolved"
}

fm_lock_points_to_owner() {
  local lockdir=$1 ownerdir=$2 actual expected
  actual=$(fm_lock_link_owner "$lockdir") || return 1
  expected=$(fm_lock_confined_target "$lockdir" "$ownerdir") || return 1
  [ "$actual" = "$expected" ]
}

fm_lock_discard_owner() {
  local lockdir=$1 ownerdir=$2 confined
  [ -n "$ownerdir" ] || return 0
  confined=$(fm_lock_confined_target "$lockdir" "$ownerdir") || return 1
  fm_lock_clean_known_files "$lockdir" "$confined" || return 1
  rmdir "$confined" 2>/dev/null || true
}

fm_lock_remove_stray_owner_link() {
  local lockdir=$1 ownerdir=$2 stray
  [ -d "$lockdir" ] && [ ! -L "$lockdir" ] || return 0
  stray="$lockdir/$(basename "$ownerdir")"
  if [ -L "$stray" ] && [ "$(readlink "$stray" 2>/dev/null || true)" = "$ownerdir" ]; then
    rm -f "$stray" 2>/dev/null || true
  fi
}

fm_lock_claim_blocked_by_steal() {
  local lockdir=$1 allowed_steal_owner=${2:-} steal
  steal="$lockdir.steal"
  [ -e "$steal" ] || [ -L "$steal" ] || return 1
  if [ -n "$allowed_steal_owner" ] && fm_lock_points_to_owner "$steal" "$allowed_steal_owner"; then
    return 1
  fi
  return 0
}

fm_lock_claim() {
  local lockdir=$1 ownerdir=$2 allowed_steal_owner=${3:-} mypid back
  mypid=${BASHPID:-$$}
  if ! { printf '%s\n' "$mypid" > "$ownerdir/pid"; } 2>/dev/null; then
    fm_lock_discard_owner "$lockdir" "$ownerdir"
    return 1
  fi
  back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  if [ "$back" != "$mypid" ]; then
    fm_lock_discard_owner "$lockdir" "$ownerdir"
    return 1
  fi
  if ! fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
    fm_lock_discard_owner "$lockdir" "$ownerdir"
    return 1
  fi
  if fm_lock_claim_blocked_by_steal "$lockdir" "$allowed_steal_owner"; then
    if fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
      rm -f "$lockdir" 2>/dev/null || true
    fi
    fm_lock_discard_owner "$lockdir" "$ownerdir"
    return 1
  fi
  return 0
}

fm_lock_try_create() {
  local lockdir=$1 allowed_steal_owner=${2:-} ownerdir
  FM_LOCK_OWNER_DIR=
  ownerdir=$(fm_lock_owner_dir "$lockdir") || return 1
  if [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    fm_lock_discard_owner "$lockdir" "$ownerdir"
    return 1
  fi
  if ! fm_lock_prepare_owner "$ownerdir"; then
    fm_lock_discard_owner "$lockdir" "$ownerdir"
    return 1
  fi
  if ln -s "$ownerdir" "$lockdir" 2>/dev/null && fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
    if fm_lock_claim "$lockdir" "$ownerdir" "$allowed_steal_owner"; then
      FM_LOCK_OWNER_DIR=$ownerdir
      return 0
    fi
    if fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
      rm -f "$lockdir" 2>/dev/null || true
    fi
  else
    fm_lock_remove_stray_owner_link "$lockdir" "$ownerdir"
  fi
  fm_lock_discard_owner "$lockdir" "$ownerdir"
  return 1
}

fm_lock_remove_path() {
  local lockdir=$1 ownerdir
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir") || return 1
    rm -f "$lockdir" 2>/dev/null || return 1
    fm_lock_discard_owner "$lockdir" "$ownerdir"
    return 0
  fi
  fm_lock_clean_known_files "$lockdir" "$lockdir" || return 1
  rmdir "$lockdir" 2>/dev/null
}

fm_lock_mid_acquire_is_fresh() {
  local lockdir=$1 pid=$2 mid_acquire_stale
  case "$pid" in
    ''|*[!0-9]*)
      mid_acquire_stale=$FM_LOCK_STALE_AFTER
      [ "$mid_acquire_stale" -lt 2 ] && mid_acquire_stale=2
      [ "$(fm_path_age "$lockdir")" -lt "$mid_acquire_stale" ]
      return
      ;;
  esac
  return 1
}

fm_lock_process_group_guarded() {
  local lockdir=$1 ownerdir guard group groups
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir" 2>/dev/null) || return 1
  elif [ -d "$lockdir" ]; then
    ownerdir=$lockdir
  else
    return 1
  fi
  guard="$ownerdir/process-group"
  [ -e "$guard" ] || [ -L "$guard" ] || return 1
  [ -f "$guard" ] && [ ! -L "$guard" ] || {
    FM_LOCK_HELD_PID=unknown
    return 0
  }
  group=$(cat "$guard" 2>/dev/null || true)
  case "$group" in
    ''|*[!0-9]*)
      FM_LOCK_HELD_PID=unknown
      return 0
      ;;
  esac
  FM_LOCK_HELD_PID=$group
  groups=$(ps -axo pgid= 2>/dev/null) || return 0
  if printf '%s\n' "$groups" | awk -v group="$group" '$1 == group { found = 1 } END { exit !found }'; then
    return 0
  fi
  if [ -L "$lockdir" ]; then
    fm_lock_points_to_owner "$lockdir" "$ownerdir" || return 0
  elif [ "$ownerdir" != "$lockdir" ]; then
    return 0
  fi
  [ "$(cat "$guard" 2>/dev/null || true)" = "$group" ] || return 0
  rm -f "$guard" 2>/dev/null || return 0
  FM_LOCK_HELD_PID=
  return 1
}

fm_lock_process_session_guarded() {
  local lockdir=$1 ownerdir guard session
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir" 2>/dev/null) || return 1
  elif [ -d "$lockdir" ]; then
    ownerdir=$lockdir
  else
    return 1
  fi
  guard="$ownerdir/process-session"
  [ -e "$guard" ] || [ -L "$guard" ] || return 1
  [ -f "$guard" ] && [ ! -L "$guard" ] || {
    FM_LOCK_HELD_PID=unknown
    return 0
  }
  session=$(cat "$guard" 2>/dev/null || true)
  case "$session" in
    ''|*[!0-9]*)
      FM_LOCK_HELD_PID=unknown
      return 0
      ;;
  esac
  FM_LOCK_HELD_PID=$session
  fm_session_wait_quiescent_except "$session" "" 2 || return 0
  if [ -L "$lockdir" ]; then
    fm_lock_points_to_owner "$lockdir" "$ownerdir" || return 0
  elif [ "$ownerdir" != "$lockdir" ]; then
    return 0
  fi
  [ "$(cat "$guard" 2>/dev/null || true)" = "$session" ] || return 0
  rm -f "$guard" 2>/dev/null || return 0
  FM_LOCK_HELD_PID=
  return 1
}

fm_lock_recheck_stale_owner() {
  local lockdir=$1 expected_owner=$2 expected_pid=$3 actual_pid
  if [ -n "$expected_owner" ]; then
    fm_lock_points_to_owner "$lockdir" "$expected_owner" || return 1
  elif [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    [ -d "$lockdir" ] && [ ! -L "$lockdir" ] || return 1
  fi
  actual_pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$actual_pid" = "$expected_pid" ] || return 1
  if fm_pid_alive "$actual_pid"; then
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$actual_pid"; then
    return 1
  fi
  return 0
}

fm_lock_try_acquire() {
  local lockdir=$1 steal_depth=${2:-0} pid steal cur rc steal_owner primary_owner
  FM_LOCK_HELD_PID=
  FM_LOCK_OWNER_DIR=

  if fm_lock_try_create "$lockdir"; then
    return 0
  fi

  if fm_lock_process_session_guarded "$lockdir" || fm_lock_process_group_guarded "$lockdir"; then
    return 1
  fi

  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  if fm_pid_alive "$pid"; then
    FM_LOCK_HELD_PID=$pid
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$pid"; then
    FM_LOCK_HELD_PID=$pid
    return 1
  fi

  steal="$lockdir.steal"
  if [ "$steal_depth" -ge 8 ]; then
    # Bound stale-stealer arbitration: the final guard may only be created,
    # never recursively reclaimed through an ever-longer .steal path.
    fm_lock_try_create "$steal" || {
      FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
      FM_LOCK_OWNER_DIR=
      return 1
    }
  elif ! fm_lock_try_acquire "$steal" "$((steal_depth + 1))"; then
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  steal_owner=${FM_LOCK_OWNER_DIR:-}

  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  if fm_pid_alive "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$cur
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$cur
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  if ! fm_lock_points_to_owner "$steal" "$steal_owner"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi

  primary_owner=
  if [ -L "$lockdir" ]; then
    primary_owner=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
  fi
  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  if ! fm_lock_recheck_stale_owner "$lockdir" "$primary_owner" "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi

  fm_lock_remove_path "$lockdir" || true
  rc=1
  if fm_lock_try_create "$lockdir" "$steal_owner"; then
    rc=0
  fi
  if [ "$rc" -ne 0 ]; then
    # shellcheck disable=SC2034 # Read by callers after fm_lock_try_acquire returns.
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
  fi
  fm_lock_release "$steal"
  return "$rc"
}

fm_lock_acquire_wait() {
  local lockdir=$1
  while ! fm_lock_try_acquire "$lockdir"; do
    sleep 0.1
  done
}

fm_lock_release() {
  local lockdir=$1 pid current ownerdir
  current=${BASHPID:-$$}
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
    [ -n "$ownerdir" ] || return 0
    { [ ! -e "$ownerdir/process-group" ] && [ ! -L "$ownerdir/process-group" ]; } || return 0
    { [ ! -e "$ownerdir/process-session" ] && [ ! -L "$ownerdir/process-session" ]; } || return 0
    pid=$(cat "$ownerdir/pid" 2>/dev/null || true)
    [ "$pid" = "$current" ] || return 0
    fm_lock_points_to_owner "$lockdir" "$ownerdir" || return 0
    rm -f "$lockdir" 2>/dev/null || return 0
    fm_lock_discard_owner "$lockdir" "$ownerdir"
    return 0
  fi
  { [ ! -e "$lockdir/process-group" ] && [ ! -L "$lockdir/process-group" ]; } || return 0
  { [ ! -e "$lockdir/process-session" ] && [ ! -L "$lockdir/process-session" ]; } || return 0
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$pid" = "$current" ] || return 0
  fm_lock_clean_known_files "$lockdir" "$lockdir" || return 0
  rmdir "$lockdir" 2>/dev/null || true
}

fm_wake_clean_field() {
  LC_ALL=C tr '\t\r\n' '   '
}

fm_wake_append() {
  local kind=$1 key=$2 payload=$3 clean_key clean_payload epoch seq seq_file seq_tmp status
  case "$kind" in
    signal|stale|check|heartbeat) ;;
    *) printf 'fm_wake_append: invalid wake kind: %s\n' "$kind" >&2; return 2 ;;
  esac

  clean_key=$(printf '%s' "$key" | fm_wake_clean_field)
  clean_payload=$(printf '%s' "$payload" | fm_wake_clean_field)
  epoch=$(date +%s)
  seq_file="$STATE/.wake-queue.seq"
  status=0

  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  if ! fm_wake_safe_file_destination "$seq_file" || ! fm_wake_safe_file_destination "$FM_WAKE_QUEUE"; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 1
  fi
  seq=$(cat "$seq_file" 2>/dev/null || echo 0)
  case "$seq" in
    ''|*[!0-9]*) seq=0 ;;
  esac
  seq=$((seq + 1))
  seq_tmp=$(mktemp "$STATE/.wake-queue.seq.pending.XXXXXX") || status=$?
  if [ "$status" -eq 0 ]; then
    printf '%s\n' "$seq" > "$seq_tmp" || status=$?
  fi
  if [ "$status" -eq 0 ]; then
    fm_wake_safe_file_destination "$seq_file" && mv "$seq_tmp" "$seq_file" || status=$?
  fi
  [ -z "${seq_tmp:-}" ] || [ ! -e "$seq_tmp" ] || rm -f "$seq_tmp"
  if [ "$status" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "$seq" "$kind" "$clean_key" "$clean_payload" >> "$FM_WAKE_QUEUE" || status=$?
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

fm_wake_restore_queue() {
  local drained=$1 restore
  fm_wake_safe_file_destination "$FM_WAKE_QUEUE" || return 1
  if [ -e "$FM_WAKE_QUEUE" ]; then
    restore=$(mktemp "$STATE/.wake-queue.restore.XXXXXX") || return 1
    if cat "$drained" "$FM_WAKE_QUEUE" > "$restore" && fm_wake_safe_file_destination "$FM_WAKE_QUEUE" && mv "$restore" "$FM_WAKE_QUEUE"; then
      return 0
    fi
    rm -f "$restore"
    return 1
  else
    mv "$drained" "$FM_WAKE_QUEUE"
  fi
}

fm_wake_print_deduped() {
  local file=$1
  awk -F '\t' '
    NF >= 5 {
      dedupe = $3 SUBSEP $4
      if ($3 == "heartbeat") {
        dedupe = "heartbeat"
      }
      if (!(dedupe in seen)) {
        order[++count] = dedupe
        seen[dedupe] = 1
      }
      line[dedupe] = $0
    }
    END {
      for (i = 1; i <= count; i++) {
        print line[order[i]]
      }
    }
  ' "$file"
}
