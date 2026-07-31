#!/usr/bin/env bash
# Run one firstmate behavior test inside a fresh, sealed operational home.
set -eu

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/.." && pwd -P)"

[ "$#" -eq 1 ] || { printf 'usage: tests/run-test.sh tests/<name>.test.sh\n' >&2; exit 64; }
case "$1" in
  /*) test_script=$1 ;;
  *) test_script="$ROOT/$1" ;;
esac
[ -f "$test_script" ] || { printf 'test not found: %s\n' "$test_script" >&2; exit 66; }
test_script="$(cd "$(dirname "$test_script")" && pwd -P)/$(basename "$test_script")"
case "$test_script" in
  "$TEST_DIR"/*.test.sh) ;;
  *) printf 'refusing test outside %s: %s\n' "$TEST_DIR" "$test_script" >&2; exit 64 ;;
esac

ambient_tmp=${TMPDIR:-/tmp}
[ -d "$ambient_tmp" ] || { printf 'temporary directory is unavailable: %s\n' "$ambient_tmp" >&2; exit 73; }
sandbox=$(mktemp -d "$ambient_tmp/firstmate-$(basename "$test_script" .test.sh).XXXXXX")
sandbox="$(cd "$sandbox" && pwd -P)"

cleanup() {
  chmod -R u+rwX "$sandbox" 2>/dev/null || true
  rm -rf "$sandbox"
}
trap cleanup EXIT INT TERM

user_home="$sandbox/home"
fm_home="$sandbox/fm-home"
mkdir -p "$user_home/.treehouse" "$fm_home/state" "$fm_home/data" \
  "$fm_home/projects" "$fm_home/config" "$sandbox/tmp"

guard_ps=$(command -v ps) || { printf 'test isolation requires ps\n' >&2; exit 69; }
guard_awk=$(command -v awk) || { printf 'test isolation requires awk\n' >&2; exit 69; }
guard_tr=$(command -v tr) || { printf 'test isolation requires tr\n' >&2; exit 69; }
guard_real_bash=$(command -v bash) || { printf 'test isolation requires bash\n' >&2; exit 69; }
case "$(uname -s)" in
  Darwin) guard_real_kill=/bin/kill ;;
  *) guard_real_kill=/usr/bin/kill ;;
esac
[ -x "$guard_real_kill" ] || { printf 'test isolation requires a fixed system kill\n' >&2; exit 69; }

export FM_TEST_SEALED=firstmate-test-v1
export FM_TEST_SANDBOX_ROOT=$sandbox
export FM_TEST_REPO_ROOT=$ROOT
export FM_TEST_PROCESS_ROOT_PID=$$
export FM_TEST_OUTSIDE_PID=$PPID
export HOME=$user_home
export FM_HOME=$fm_home
export FM_STATE_OVERRIDE=$fm_home/state
export FM_TREEHOUSE_ROOT=$user_home/.treehouse
export TMPDIR=$sandbox/tmp
export TREEHOUSE_NO_UPDATE_CHECK=1
export FM_TEST_INITIAL_STATE_OVERRIDE=$FM_STATE_OVERRIDE
export FM_TEST_GUARD_PS=$guard_ps
export FM_TEST_GUARD_AWK=$guard_awk
export FM_TEST_GUARD_TR=$guard_tr
export FM_TEST_GUARD_REAL_KILL=$guard_real_kill
export FM_TEST_GUARD_KILL_WRAPPER=$TEST_DIR/test-kill-guard.sh
export FM_TEST_GUARD_ENV=$TEST_DIR/test-env-guard.sh
export FM_TEST_REAL_BASH=$guard_real_bash
export FM_TEST_BASH=$TEST_DIR/test-bash.sh
export BASH_ENV=$FM_TEST_GUARD_ENV
export PATH=$TEST_DIR/sealed-bin:$PATH
unset FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE \
  FM_CHECKOUT_REFRESH_STATE_ROOT FM_CHECKOUT_REFRESH_LOCK_ROOT FM_REPORT_STACK_ROOT \
  FM_ACCOUNT_DIRECTORY_ROOT FM_ACCOUNT_DIRECTORY_STATE_ROOT \
  XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME XDG_CACHE_HOME \
  FM_BACKEND FM_SUPERVISOR_BACKEND FM_SUPERVISOR_TARGET \
  TMUX HERDR_ENV HERDR_SESSION ZELLIJ ZELLIJ_SESSION_NAME CMUX_WORKSPACE_ID

"$test_script"
