#!/usr/bin/env bash
# Hard guard for firstmate's sealed test processes.
#
# tests/run-test.sh exports one private sandbox and installs this file as
# BASH_ENV, so every Bash subprocess validates its operational paths before it
# can read fleet state, acquire a Treehouse worktree, or signal a lifecycle PID.
# tests/lib.sh also sources it, making direct execution of a test fail before
# the test body can run.

fm_test_isolation_fail() {
  printf 'test isolation violation: %s\n' "$1" >&2
  exit 97
}

fm_test_isolation_assert_path() {  # <label> <path> [directory|entry]
  local label=$1 path=$2 kind=${3:-directory} root=$FM_TEST_SANDBOX_ROOT probe physical
  [ -n "$path" ] || return 0
  case "$path" in
    /*) ;;
    *) fm_test_isolation_fail "$label resolved to non-absolute path: $path" ;;
  esac
  case "/${path#/}/" in
    */../*) fm_test_isolation_fail "$label resolved outside sandbox: $path (sandbox: $root)" ;;
  esac
  case "$path" in
    "$root"|"$root"/*) ;;
    *) fm_test_isolation_fail "$label resolved outside sandbox: $path (sandbox: $root)" ;;
  esac

  probe=$path
  if [ -e "$probe" ] || [ -L "$probe" ]; then
    if { [ -L "$probe" ] && [ ! -d "$probe" ]; } \
      || { [ ! -L "$probe" ] && [ ! -d "$probe" ] && { [ "$kind" != entry ] || [ ! -f "$probe" ]; }; }; then
      fm_test_isolation_fail "$label is not a safe $kind path: $path"
    fi
    [ -d "$probe" ] || probe=${probe%/*}
    [ -n "$probe" ] || probe=/
  fi
  while [ ! -d "$probe" ]; do
    if [ -e "$probe" ] || [ -L "$probe" ]; then
      fm_test_isolation_fail "$label is not a safe directory path: $path"
    fi
    [ "$probe" != / ] || fm_test_isolation_fail "$label has no existing directory ancestor: $path"
    probe=${probe%/*}
    [ -n "$probe" ] || probe=/
  done
  physical=$(cd "$probe" 2>/dev/null && pwd -P) \
    || fm_test_isolation_fail "$label cannot be resolved safely: $path"
  case "$physical" in
    "$root"|"$root"/*) ;;
    *) fm_test_isolation_fail "$label resolves through a path outside sandbox: $path -> $physical (sandbox: $root)" ;;
  esac
}

fm_test_isolation_pid_is_descendant() {  # <pid>
  local pid=$1 parent root=$FM_TEST_PROCESS_ROOT_PID
  case "$pid:$root" in *[!0-9:]*) return 1 ;; esac
  [ "$pid" -gt 1 ] 2>/dev/null && [ "$root" -gt 1 ] 2>/dev/null || return 1
  [ "$pid" != "$root" ] || return 1
  while [ "$pid" -gt 1 ] 2>/dev/null; do
    parent=$("$FM_TEST_GUARD_PS" -o ppid= -p "$pid" 2>/dev/null | "$FM_TEST_GUARD_TR" -d '[:space:]') || return 1
    case "$parent" in ''|*[!0-9]*) return 1 ;; esac
    [ "$parent" = "$root" ] && return 0
    [ "$parent" != "$pid" ] || return 1
    pid=$parent
  done
  return 1
}

fm_test_isolation_group_has_owned_anchor() {  # <positive-pgid>
  local group=$1 guard_file=${FM_PROCESS_TREE_GUARD_FILE:-} recorded anchor_line anchor_pid anchor_group
  [ -n "$guard_file" ] || return 1
  fm_test_isolation_assert_path "process-group ownership record" "$guard_file" entry
  [ -f "$guard_file" ] && [ ! -L "$guard_file" ] || return 1
  IFS= read -r recorded < "$guard_file" || return 1
  [ "$recorded" = "$group" ] || return 1
  anchor_line=$("$FM_TEST_GUARD_PS" -ww -p "$group" -o pid= -o pgid= -o command= 2>/dev/null) || return 1
  anchor_line=${anchor_line#"${anchor_line%%[![:space:]]*}"}
  anchor_pid=${anchor_line%%[[:space:]]*}
  anchor_line=${anchor_line#"$anchor_pid"}
  anchor_line=${anchor_line#"${anchor_line%%[![:space:]]*}"}
  anchor_group=${anchor_line%%[[:space:]]*}
  [ "$anchor_pid" = "$group" ] && [ "$anchor_group" = "$group" ] || return 1
  case "$anchor_line" in
    *FM_PROCESS_TREE_GUARD_FILE*'bounded command process-group'*) return 0 ;;
  esac
  return 1
}

fm_test_isolation_assert_pid_target() {  # <pid-or-negative-pgid>
  local target=$1 group members member
  case "$target" in
    -[0-9]*)
      group=${target#-}
      fm_test_isolation_group_has_owned_anchor "$group" && return 0
      # shellcheck disable=SC2016  # $2/$1 belong to awk, not this shell.
      members=$("$FM_TEST_GUARD_PS" -axo pid=,pgid= 2>/dev/null \
        | "$FM_TEST_GUARD_AWK" -v group="$group" '$2 == group { print $1 }') \
        || fm_test_isolation_fail "cannot inspect process group targeted by test: $target"
      [ -n "$members" ] || return 0
      for member in $members; do
        fm_test_isolation_pid_is_descendant "$member" \
          || fm_test_isolation_fail "daemon/watcher PID resolves outside sandbox process tree: $member (target group: $target; test root PID: $FM_TEST_PROCESS_ROOT_PID)"
      done
      ;;
    [0-9]*)
      if ! "$FM_TEST_GUARD_PS" -p "$target" -o pid= >/dev/null 2>&1; then
        return 0
      fi
      fm_test_isolation_group_has_owned_anchor "$target" && return 0
      fm_test_isolation_pid_is_descendant "$target" \
        || fm_test_isolation_fail "daemon/watcher PID resolves outside sandbox process tree: $target (test root PID: $FM_TEST_PROCESS_ROOT_PID)"
      ;;
    *) return 0 ;;
  esac
}

fm_test_isolation_guard_kill_args() {
  local target
  case "${1:-}" in
    -l|-L) return 0 ;;
    -s) shift 2 ;;
    -[A-Za-z0-9]*) shift ;;
  esac
  [ "${1:-}" != -- ] || shift
  for target in "$@"; do
    fm_test_isolation_assert_pid_target "$target"
  done
}

kill() {
  fm_test_isolation_guard_kill_args "$@"
  "$FM_TEST_GUARD_REAL_KILL" "$@"
}

fm_test_isolation_guard_environment() {
  local effective_home effective_state effective_pool label value lock_name
  [ "${FM_TEST_SEALED:-}" = firstmate-test-v1 ] \
    || fm_test_isolation_fail 'test was not launched through tests/run-test.sh'
  [ -n "${FM_TEST_SANDBOX_ROOT:-}" ] \
    || fm_test_isolation_fail 'FM_TEST_SANDBOX_ROOT is unset; use tests/run-test.sh'
  case "$FM_TEST_SANDBOX_ROOT" in /*) ;; *) fm_test_isolation_fail "sandbox root is not absolute: $FM_TEST_SANDBOX_ROOT" ;; esac
  [ -d "$FM_TEST_SANDBOX_ROOT" ] && [ ! -L "$FM_TEST_SANDBOX_ROOT" ] \
    || fm_test_isolation_fail "sandbox root is not a real directory: $FM_TEST_SANDBOX_ROOT"
  [ "$(cd "$FM_TEST_SANDBOX_ROOT" && pwd -P)" = "$FM_TEST_SANDBOX_ROOT" ] \
    || fm_test_isolation_fail "sandbox root is not canonical: $FM_TEST_SANDBOX_ROOT"
  case "${FM_TEST_PROCESS_ROOT_PID:-}" in ''|*[!0-9]*) fm_test_isolation_fail 'test process-root PID is unset or malformed' ;; esac
  for label in FM_TEST_GUARD_PS FM_TEST_GUARD_AWK FM_TEST_GUARD_TR \
    FM_TEST_GUARD_REAL_KILL FM_TEST_GUARD_KILL_WRAPPER FM_TEST_GUARD_ENV \
    FM_TEST_REAL_BASH FM_TEST_BASH; do
    eval "value=\${$label:-}"
    [ -x "$value" ] || fm_test_isolation_fail "$label is not a pinned executable: ${value:-<unset>}"
  done
  [ "${BASH_ENV:-}" = "$FM_TEST_GUARD_ENV" ] \
    || fm_test_isolation_fail "BASH_ENV bypassed the sealed launcher: ${BASH_ENV:-<unset>}"
  "$FM_TEST_GUARD_PS" -p "$FM_TEST_PROCESS_ROOT_PID" -o pid= >/dev/null 2>&1 \
    || fm_test_isolation_fail "test process-root PID is not alive: $FM_TEST_PROCESS_ROOT_PID"

  fm_test_isolation_assert_path HOME "${HOME:-}"
  fm_test_isolation_assert_path TMPDIR "${TMPDIR:-}"

  effective_home=${FM_HOME:-${FM_ROOT_OVERRIDE:-${FM_TEST_REPO_ROOT:-}}}
  [ -n "$effective_home" ] \
    || fm_test_isolation_fail 'firstmate home is unset and has no sandboxed fallback'
  fm_test_isolation_assert_path FM_HOME "$effective_home"
  effective_state=${FM_STATE_OVERRIDE:-$effective_home/state}
  fm_test_isolation_assert_path FM_STATE_OVERRIDE "$effective_state"
  for lock_name in .lock .watch.lock .wake-queue.lock .supervise-daemon.lock .afk-launch.lock; do
    fm_test_isolation_assert_path "state lock $lock_name" "$effective_state/$lock_name" entry
  done
  effective_pool=${FM_TREEHOUSE_ROOT:-${HOME:-}/.treehouse}
  fm_test_isolation_assert_path FM_TREEHOUSE_ROOT "$effective_pool"

  for label in FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE \
    FM_CHECKOUT_REFRESH_STATE_ROOT FM_CHECKOUT_REFRESH_LOCK_ROOT \
    FM_REPORT_STACK_ROOT FM_ACCOUNT_DIRECTORY_ROOT FM_ACCOUNT_DIRECTORY_STATE_ROOT \
    XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME XDG_CACHE_HOME; do
    eval "value=\${$label:-}"
    [ -z "$value" ] || fm_test_isolation_assert_path "$label" "$value"
  done
}

enable -n kill 2>/dev/null \
  || fm_test_isolation_fail 'the Bash kill builtin could not be disabled'
hash -p "$FM_TEST_GUARD_KILL_WRAPPER" kill \
  || fm_test_isolation_fail "the guarded kill command could not be pinned: $FM_TEST_GUARD_KILL_WRAPPER"
fm_test_isolation_guard_environment
if [ -n "${FM_TEST_BASH_ENV_PAYLOAD:-}" ]; then
  fm_test_isolation_assert_path FM_TEST_BASH_ENV_PAYLOAD "$FM_TEST_BASH_ENV_PAYLOAD" entry
  [ -f "$FM_TEST_BASH_ENV_PAYLOAD" ] && [ ! -L "$FM_TEST_BASH_ENV_PAYLOAD" ] \
    || fm_test_isolation_fail "FM_TEST_BASH_ENV_PAYLOAD is not a regular sandbox file: $FM_TEST_BASH_ENV_PAYLOAD"
  . "$FM_TEST_BASH_ENV_PAYLOAD"
fi
