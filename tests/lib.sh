#!/usr/bin/env bash
# tests/lib.sh - shared primitives for firstmate behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# It provides the boilerplate every test file used to re-roll: ok/not-ok
# reporters, a self-cleaning temp root, fakebin/PATH-shim helpers, deterministic
# git identity and fixture builders, state/<id>.meta writers, and the common
# string/exit-code/file assertions. It deliberately does NOT bundle the
# behavior-specific fake tmux/treehouse/no-mistakes mocks: those encode terminal
# and lifecycle assumptions that differ per suite and belong with the tests that
# own them.
#
# ROOT is exported as the firstmate repo root (this file lives in tests/), so a
# sourcing test can use "$ROOT/bin/..." without recomputing it.

# Every test must enter through tests/run-test.sh (normally via tests/run.sh).
# This re-check is deliberate even though BASH_ENV checks Bash children: it
# makes direct execution fail before a test can reach firstmate's live fleet.
# shellcheck source=tests/test-env-guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/test-env-guard.sh"

# The runner proves and records an explicit private state override at entry.
# Test fixtures commonly select another private FM_HOME; after that entry proof,
# let state follow the fixture home unless the fixture names its own override.
unset FM_STATE_OVERRIDE

# The first test process to load this library owns suite cleanup. Nested Bash
# processes deliberately source the same helpers (and therefore install their
# own EXIT trap), but must never interpret the shared sealed process group as
# theirs to terminate. The owner token is exported before any test can launch a
# child; descendants load all functions normally and their trap becomes inert.
if [ -z "${FM_TEST_CLEANUP_OWNER_PID:-}" ]; then
  FM_TEST_CLEANUP_OWNER_PID=$$
  export FM_TEST_CLEANUP_OWNER_PID
fi

# Idempotent guard: behavior-area helper files (secondmate-helpers.sh,
# wake-helpers.sh) source this library for ROOT/fail/pass, and the test that
# includes them may also source it directly. Re-sourcing must not wipe the
# registered-cleanup array or reset state.
if [ -n "${FM_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_LIB_SOURCED=1

# Exempt firstmate's own test suite from the gate-lifecycle refusal
# (bin/fm-gate-refuse-lib.sh). The no-mistakes gate runs this suite FROM a gate
# worktree - the exact environment that guard refuses - so without this every
# test that drives the real fm-spawn/fm-send/fm-teardown would be refused during
# firstmate's own validation. A confused gate agent never sources this helper, so
# the boundary against the real hazard is unaffected. tests/fm-gate-refuse.test.sh
# strips this to verify real refusal.
export FM_GATE_REFUSE_BYPASS=1

# Resolve the repo root from this library's own location. Consumed by sourcing
# test files, not by this library, so it reads as "unused" here.
# shellcheck disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- reporters --------------------------------------------------------------

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# --- bounded liveness waits -------------------------------------------------
#
# These waits synchronize fixtures; they are not performance assertions.
# Keep their ceiling generous on a loaded machine while still guaranteeing
# that a broken test fails instead of hanging forever. Callers may lower or
# raise the shared ceiling for local diagnosis.

FM_TEST_LIVENESS_TIMEOUT_SECONDS=${FM_TEST_LIVENESS_TIMEOUT_SECONDS:-30}

fm_test_liveness_iterations() {
  local requested=${1:-1} interval=${2:-0.1} minimum
  minimum=$(awk -v seconds="$FM_TEST_LIVENESS_TIMEOUT_SECONDS" -v tick="$interval" \
    'BEGIN { value = int((seconds / tick) + 0.999999); if (value > 0) print value; else print 1 }')
  if [ "$requested" -gt "$minimum" ]; then
    printf '%s\n' "$requested"
  else
    printf '%s\n' "$minimum"
  fi
}

fm_test_wait_for_file() {
  local path=$1 pid=${2:-} interval=${3:-0.05} limit i=0
  limit=$(fm_test_liveness_iterations 1 "$interval")
  while [ "$i" -lt "$limit" ]; do
    [ -e "$path" ] && return 0
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      printf 'background process %s exited before %s appeared\n' "$pid" "$path" >&2
      return 125
    fi
    sleep "$interval"
    i=$((i + 1))
  done
  printf 'timed out after %ss waiting for %s\n' "$FM_TEST_LIVENESS_TIMEOUT_SECONDS" "$path" >&2
  return 124
}

# Query Bash's own child-job table before treating a numeric PID as one of this
# test's live processes. `kill -0 "$pid"` can race a short-lived fixture exit
# and inspect an unrelated process after PID reuse; the suite guard correctly
# rejects that ambiguity, so test synchronization must not create it.
fm_test_job_is_running() {  # <pid returned by $!>
  local expected=$1 job_pid
  for job_pid in $(jobs -pr); do
    [ "$job_pid" = "$expected" ] && return 0
  done
  return 1
}

fm_test_job_spec() {  # <pid returned by $!>
  jobs -l | awk -v expected="$1" '
    $1 ~ /^\[[0-9]+\][+-]?$/ && $2 == expected {
      spec = $1
      sub(/^\[/, "%", spec)
      sub(/\][+-]?$/, "", spec)
      print spec
      exit
    }
  '
}

fm_test_signal_job() {  # <pid returned by $!> [signal]
  local pid=$1 signal=${2:--TERM} job_spec status=0
  job_spec=$(fm_test_job_spec "$pid")
  [ -n "$job_spec" ] || return 1
  # The ordinary kill builtin stays disabled so `command kill` cannot bypass
  # the suite guard. Temporarily expose it only inside this validated helper
  # and address Bash's job object, not a reusable numeric PID.
  enable kill
  builtin kill "$signal" "$job_spec" 2>/dev/null || status=$?
  enable -n kill
  return "$status"
}

fm_test_reap_job() {  # <pid returned by $!> [signal]
  local pid=$1 signal=${2:--TERM}
  fm_test_signal_job "$pid" "$signal" || true
  wait "$pid" 2>/dev/null || true
}

# --- self-cleaning temp root ------------------------------------------------
#
# fm_test_tmproot <prefix> echoes a fresh temp dir and registers it for removal
# on EXIT. Most callers use command substitution, whose subshell cannot update
# a parent array and whose inherited EXIT trap runs on Bash 3, so a manifest
# carries registrations back to the parent without deleting fixtures early.
# A test file that needs extra teardown (e.g. killing a daemon) should define
# its own EXIT trap and call fm_test_cleanup from inside it.

FM_TEST_CLEANUP_DIRS=()
FM_TEST_CLEANUP_MANIFEST=$(mktemp "${TMPDIR:-/tmp}/fm-test-cleanup.XXXXXX")
trap fm_test_cleanup EXIT

fm_test_cleanup() {
  local d
  [ "${BASH_SUBSHELL:-0}" -eq 0 ] || return 0
  [ "$$" = "$FM_TEST_CLEANUP_OWNER_PID" ] || return 0
  fm_test_cleanup_owned_processes
  if [ -f "$FM_TEST_CLEANUP_MANIFEST" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] && rm -rf "$d"
    done < "$FM_TEST_CLEANUP_MANIFEST"
    rm -f "$FM_TEST_CLEANUP_MANIFEST"
  fi
  for d in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  return 0
}

fm_test_owned_processes() {
  local root=$1 self=$2 output=$3 raw scan_pid
  raw=$(mktemp "${TMPDIR:?sealed test TMPDIR is required}/fm-test-process-scan.XXXXXX")
  "$FM_TEST_GUARD_PS" -axo pid=,pgid=,state= > "$raw" &
  scan_pid=$!
  wait "$scan_pid" \
    || fail "test isolation: could not inspect the sealed process group"
  # shellcheck disable=SC2016 # awk fields, not shell parameters.
  "$FM_TEST_GUARD_AWK" -v root="$root" -v self="$self" -v scan="$scan_pid" '
      $1 ~ /^[0-9]+$/ && $2 == root && $1 != root && $1 != self && $1 != scan && $3 !~ /^Z/ {
        print $1, $2, $3
      }
    ' "$raw" > "$output"
  rm -f "$raw"
}

fm_test_cleanup_owned_processes() {
  local root=${FM_TEST_PROCESS_ROOT_PID:-} self=$$ line pid i survivors remaining
  [ -n "$root" ] || fail "test isolation: sealed process root PID is missing during cleanup"
  line=$("$FM_TEST_GUARD_PS" -p "$root" -o pid=,pgid= 2>/dev/null || true)
  # shellcheck disable=SC2086 # Deliberately split the two numeric ps fields.
  set -- $line
  [ "${1:-}" = "$root" ] && [ "${2:-}" = "$root" ] \
    || fail "test isolation: refusing process cleanup because $root is not the sealed process-group leader"

  survivors=$(mktemp "${TMPDIR:?sealed test TMPDIR is required}/fm-test-processes.XXXXXX")
  fm_test_owned_processes "$root" "$self" "$survivors"
  if [ -s "$survivors" ]; then
    while IFS=' ' read -r pid _; do
      [ -n "$pid" ] && "$FM_TEST_GUARD_REAL_KILL" -TERM "$pid" 2>/dev/null || true
    done < "$survivors"
    i=0
    while [ "$i" -lt 20 ]; do
      fm_test_owned_processes "$root" "$self" "$survivors"
      [ ! -s "$survivors" ] && break
      sleep 0.05
      i=$((i + 1))
    done
  fi

  if [ -s "$survivors" ]; then
    while IFS=' ' read -r pid _; do
      [ -n "$pid" ] && "$FM_TEST_GUARD_REAL_KILL" -KILL "$pid" 2>/dev/null || true
    done < "$survivors"
    i=0
    while [ "$i" -lt 20 ]; do
      fm_test_owned_processes "$root" "$self" "$survivors"
      [ ! -s "$survivors" ] && break
      sleep 0.05
      i=$((i + 1))
    done
  fi

  if [ -s "$survivors" ]; then
    remaining=$(cat "$survivors")
    rm -f "$survivors"
    fail "test isolation: owned processes survived shared cleanup: $remaining"
  fi
  rm -f "$survivors"
}

fm_test_tmproot() {
  local prefix=${1:-fm-test} root
  root=$(mktemp -d "${TMPDIR:?sealed test TMPDIR is required}/${prefix}.XXXXXX")
  root=$(cd "$root" && pwd -P)
  printf '%s\n' "$root" >> "$FM_TEST_CLEANUP_MANIFEST"
  printf '%s\n' "$root"
}

# --- node capability probe ---------------------------------------------------
#
# fm_node_supports_ts_import succeeds when the ambient node can import a .ts
# module directly (native type stripping, absent before node 22.6 and flagged
# until 22.18/23.6). The tracked Pi primary extensions are TypeScript imported
# as-is by their tests, so on an older node those tests skip instead of failing
# with ERR_UNKNOWN_FILE_EXTENSION. The probe runs once per test file.

FM_NODE_TS_IMPORT_SUPPORT=""

fm_node_supports_ts_import() {
  if [ -z "$FM_NODE_TS_IMPORT_SUPPORT" ]; then
    local probe_dir
    probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-node-ts-probe.XXXXXX") || return 1
    printf 'export const ok: string = "ok";\n' > "$probe_dir/probe.ts"
    if PROBE="$probe_dir/probe.ts" node --input-type=module -e '
      import { pathToFileURL } from "node:url";
      const mod = await import(pathToFileURL(process.env.PROBE).href);
      if (mod.ok !== "ok") process.exit(1);
    ' >/dev/null 2>&1; then
      FM_NODE_TS_IMPORT_SUPPORT=yes
    else
      FM_NODE_TS_IMPORT_SUPPORT=no
    fi
    rm -rf "$probe_dir"
  fi
  [ "$FM_NODE_TS_IMPORT_SUPPORT" = yes ]
}

# --- fakebin / PATH shims ---------------------------------------------------
#
# fm_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. fm_fake_exit0 drops trivial exit-0 stubs for the
# named tools into a fakebin dir.

fm_fakebin() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$fakebin"
}

fm_fake_exit0() {
  local fakebin=$1 tool
  shift
  for tool in "$@"; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
}

# --- deterministic git identity and fixtures --------------------------------

# fm_git_identity [name] [email]: export a fixed author/committer identity so
# fixture commits never depend on the host git config.
fm_git_identity() {
  export GIT_AUTHOR_NAME=${1:-fmtest} GIT_AUTHOR_EMAIL=${2:-fmtest@example.invalid}
  export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
}

# fm_git_init_commit <dir>: create a git repo at <dir> with a README and one
# commit. Uses an inline identity so it works whether or not fm_git_identity was
# called.
fm_git_init_commit() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# %s\n' "$(basename "$dir")" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# fm_git_add_origin <repo> <bare>: clone <repo> bare into <bare> and register it
# as <repo>'s origin via a file:// URL (so later clones resolve an absolute path).
fm_git_add_origin() {
  local repo=$1 remote=$2 remote_abs
  git clone --quiet --bare "$repo" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$repo" remote add origin "file://$remote_abs"
}

# fm_git_worktree <repo> <worktree> <branch>: init <repo> with one commit, then
# add a worktree on a fresh branch.
fm_git_worktree() {
  local repo=$1 worktree=$2 branch=$3
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b "$branch" "$worktree"
}

# --- state/<id>.meta writers ------------------------------------------------

# fm_write_meta <file> <key=val> ...: write the given key=val lines to a meta
# file (truncating any prior content).
fm_write_meta() {
  local file=$1 kv
  shift
  : > "$file"
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$file"
  done
}

# fm_write_secondmate_meta <file> <home> [window] [projects]: write the standard
# kind=secondmate meta block used across the secondmate suites. window defaults
# to firstmate:fm-<basename-of-home-dir's parent id>? No - window is explicit;
# defaults to firstmate:fm-domain and projects to alpha to match the common case.
fm_write_secondmate_meta() {
  local file=$1 home=$2 window=${3:-firstmate:fm-domain} projects=${4:-alpha}
  fm_write_meta "$file" \
    "window=$window" \
    "worktree=$home" \
    "project=$home" \
    "harness=echo" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$home" \
    "projects=$projects"
}

# --- common assertions ------------------------------------------------------

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

# assert_not_contains <haystack> <needle> <msg>
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

# expect_code <expected> <actual> <label>
expect_code() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

# assert_grep <pattern> <file> <msg>: fixed-string grep must match in <file>.
# `--` guards patterns that begin with '-' (e.g. backlog/registry lines).
assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_no_grep <pattern> <file> <msg>: fixed-string grep must NOT match.
assert_no_grep() {
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_absent <path> <msg>: path must not exist.
assert_absent() {
  [ ! -e "$1" ] || fail "$2"
}

# assert_present <path> <msg>: path must exist.
assert_present() {
  [ -e "$1" ] || fail "$2"
}
