#!/usr/bin/env bash
# fm-provision.sh - bring a leased task worktree to a proven-ready state before
# an agent is launched into it, so a crewmate can validate its OWN work.
#
# Usage:
#   fm-provision.sh <project-dir> <worktree-dir> [--task <id>] [--kind <kind>]
#                   [--force] [--manifest <file>] [--quiet]
#   fm-provision.sh --manifest-path <project-dir>   print the resolved manifest path
#   --force overrides the manifest's kind gate and rebuilds every component
#   instead of reusing a matching fingerprint.
#
# WHY THIS EXISTS
#   A Treehouse lease delivers a clean Git worktree and nothing else. The
#   environments validation actually needs - a project's virtualenv, its
#   node_modules, the interpreter and runtime those were built for - are
#   gitignored, so a fresh lease never carries them, and Treehouse exposes no
#   setup hook. Host installs and repo pins (.nvmrc, engines, lockfiles) describe
#   the desired state but never create or activate it inside a lease. An agent
#   that starts in an unprovisioned worktree cannot run the project's checks, so
#   it either borrows evidence from a second agent in a different worktree or
#   reports work it never verified. This script closes that gap at the one seam
#   where the worktree is known and no agent is running yet.
#
# WHAT IT KNOWS
#   Nothing project-specific. All project knowledge lives in a per-project JSON
#   manifest resolved from $FM_HOME/config/provision/<project>.json, which is
#   local and gitignored exactly like the other config/ knobs. No manifest means
#   this is a no-op, so every project and every home that has not opted in is
#   unaffected and pays only one file-existence check. docs/configuration.md
#   "Worktree provisioning" owns the manifest schema; that section and
#   docs/examples/provision-relvino.json are the places to read it.
#
# WHAT IT GUARANTEES
#   - A merely existing environment directory is never assumed healthy. Reuse
#     requires BOTH a matching fingerprint AND passing probes; probes run on
#     every invocation, including a fingerprint hit.
#   - A fingerprint whose inputs cannot be read, or whose version commands fail
#     or print nothing, is unavailable rather than empty, and an unavailable
#     fingerprint forces a rebuild. No verdict is ever derived from an empty
#     computed value.
#   - Runtime checks run BEFORE install, so a component is never built under the
#     wrong runtime. This is what stops npm delegating a native build to whatever
#     node happens to be first on PATH.
#   - A fingerprint file lives inside the tree it describes (for example under
#     .venv/), so it cannot outlive that tree. This script never creates that
#     parent directory just to record a fingerprint.
#   - A fingerprint version command must be independent of the thing it
#     fingerprints. The value is recomputed after a build, and a fingerprint is
#     recorded only when both values are non-empty and equal. A changed value is
#     reported instead of silently recording a digest that can never match and
#     rebuilding on every lease.
#     (`uv python find 3.11` is exactly this trap: it resolves the project's own
#     .venv once one exists. Use `uv python find --system 3.11`.)
#   - Every step is bounded by its local limit and the whole-run budget, and
#     every reset is bounded by the whole-run budget. The whole child process
#     group stays supervised through completion or TERM-then-KILL escalation,
#     including when its leader exits before a background descendant.
#   - Manifest paths are contained: existing ancestors are resolved, symlinks
#     are refused, and component paths must stay physically inside the worktree.
#     Reset and fingerprint paths must be strict descendants of their component,
#     so no normalized reset can ever target the component root itself.
#
# FAILURE POLICY
#   The manifest's on_failure decides, and the DEFAULT IS "warn": a provisioning
#   failure is loud and durable but does not block the spawn. Provisioning
#   depends on package registries, and spawn is the fleet's availability-critical
#   path; a readiness improvement must not become a single point of failure for
#   dispatching work at all. The defect being fixed is silence, not the absence
#   of a toolchain, so a failure that firstmate sees in-band at dispatch and that
#   the crewmate is told about in its brief already removes the silence. Projects
#   where unverifiable work is worse than no work set "on_failure": "block".
#
# EXIT CODES
#   0  ready, or skipped because nothing applied (no manifest, or kind excluded)
#   2  usage error
#   3  provisioning failed and the policy is warn (caller should continue loudly)
#   4  provisioning failed and the policy is block (caller must abort the spawn)
#   A manifest that cannot be read or parsed is a failure under the warn default,
#   because a typo in one home's local config must not brick that fleet's spawns.
#
# OUTPUT
#   stdout: exactly one compact JSON verdict (schema fm-provision.v1).
#   stderr: human progress and failure reasons.
#   With --task <id>, an applicable run also writes the verdict to
#   $FM_STATE/<id>.provision and the full step log to
#   $FM_STATE/<id>.provision.log, so a failure stays diagnosable long after the
#   spawn output scrolled away. A skipped run creates neither artifact.
#   A step's captured value - what "expect" compares against, and what a
#   fingerprint version command contributes - is its LAST non-empty output line,
#   trimmed. Commands that trail their value with chatter need a wrapper that
#   prints only the value.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# A reset directive removes a whole environment tree, so a confused gate agent
# reaching for this against a shared worktree is destructive, not merely noisy.
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent

usage() {
  sed -n '2,91p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

DEFAULT_STEP_TIMEOUT=600
DEFAULT_TOTAL_TIMEOUT=1800

die_usage() {
  printf 'fm-provision: %s\n' "$*" >&2
  exit 2
}

QUIET=0

note() {
  [ "$QUIET" = 1 ] || printf 'fm-provision: %s\n' "$*" >&2
}

LOG_FILE=

log_line() {
  [ -n "$LOG_FILE" ] || return 0
  printf '%s\n' "$*" >> "$LOG_FILE"
}

# --- arguments --------------------------------------------------------------

PROJECT=
WORKTREE=
TASK_ID=
KIND=ship
FORCE=0
MANIFEST=

manifest_for_project() {
  local project=$1 name
  name=$(basename "$project")
  [ -n "$name" ] || return 1
  printf '%s/provision/%s.json\n' "$CONFIG" "$name"
}

if [ "${1:-}" = "--manifest-path" ]; then
  [ -n "${2:-}" ] || die_usage "--manifest-path needs a project directory"
  manifest_for_project "$2" || die_usage "cannot derive a project name from '$2'"
  exit 0
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --task) TASK_ID=${2:-}; [ -n "$TASK_ID" ] || die_usage "--task needs a task id"; shift 2 ;;
    --kind) KIND=${2:-}; [ -n "$KIND" ] || die_usage "--kind needs a value"; shift 2 ;;
    --manifest) MANIFEST=${2:-}; [ -n "$MANIFEST" ] || die_usage "--manifest needs a file"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --quiet) QUIET=1; shift ;;
    -*) die_usage "unknown flag: $1" ;;
    *)
      if [ -z "$PROJECT" ]; then PROJECT=$1
      elif [ -z "$WORKTREE" ]; then WORKTREE=$1
      else die_usage "unexpected argument: $1"
      fi
      shift ;;
  esac
done

[ -n "$PROJECT" ] || die_usage "a project directory is required"
[ -n "$WORKTREE" ] || die_usage "a worktree directory is required"
case "$TASK_ID" in
  *[!A-Za-z0-9._-]*) die_usage "task id must be [A-Za-z0-9._-]" ;;
esac

if [ -z "$MANIFEST" ]; then
  MANIFEST=$(manifest_for_project "$PROJECT") || die_usage "cannot derive a manifest path"
fi
if [ ! -f "$MANIFEST" ]; then
  printf '{"schema":"fm-provision.v1","status":"skipped","reason":"no provisioning manifest","path_prepend":"","components":[]}\n'
  exit 0
fi

PROJECT_REAL=$(cd "$PROJECT" 2>/dev/null && pwd -P) || die_usage "project directory is unreadable: $PROJECT"
WORKTREE_REAL=$(cd "$WORKTREE" 2>/dev/null && pwd -P) || die_usage "worktree directory is unreadable: $WORKTREE"
PROJECT_NAME=$(basename "$PROJECT_REAL")
[ -n "$PROJECT_NAME" ] || die_usage "cannot derive a project name from '$PROJECT'"

RECORD_FILE=
if [ -n "$TASK_ID" ] && [ -d "$STATE" ]; then
  RECORD_FILE="$STATE/$TASK_ID.provision"
fi

# --- verdict emission -------------------------------------------------------

COMPONENT_RECORDS=
WORK_DIR=

# shellcheck disable=SC2329
cleanup() {
  [ -z "$COMPONENT_RECORDS" ] || /bin/rm -f "$COMPONENT_RECORDS"
  [ -z "$WORK_DIR" ] || /bin/rm -rf "$WORK_DIR"
}
trap cleanup EXIT

POLICY=warn
PATH_PREPEND=

activate_artifacts() {
  [ -z "$LOG_FILE" ] || return 0
  [ -n "$RECORD_FILE" ] || return 0
  LOG_FILE="$STATE/$TASK_ID.provision.log"
  : > "$LOG_FILE" 2>/dev/null || LOG_FILE=
}

init_work_area() {
  COMPONENT_RECORDS=$(mktemp "${TMPDIR:-/tmp}/fm-provision-components.XXXXXX") || return 1
  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-provision.XXXXXX") || return 1
}

# emit <status> <reason>: print the one JSON verdict, mirror it to the task
# record, and exit with the code that status maps to. A non-ready verdict never
# publishes path_prepend, so a caller cannot inherit a runtime pin from a run
# that did not finish proving it.
emit() {
  local status=$1 reason=$2 verdict code=0 components='[]'
  [ "$status" = skipped ] || activate_artifacts
  if [ -n "$COMPONENT_RECORDS" ] && [ -s "$COMPONENT_RECORDS" ]; then
    components=$(jq -c -s '.' "$COMPONENT_RECORDS" 2>/dev/null) || components='[]'
    [ -n "$components" ] || components='[]'
  fi
  [ "$status" = ready ] || PATH_PREPEND=
  verdict=$(jq -c -n \
    --arg status "$status" \
    --arg reason "$reason" \
    --arg policy "$POLICY" \
    --arg project "$PROJECT_NAME" \
    --arg worktree "$WORKTREE_REAL" \
    --arg manifest "$MANIFEST" \
    --arg task "$TASK_ID" \
    --arg log "$LOG_FILE" \
    --arg path_prepend "$PATH_PREPEND" \
    --argjson components "$components" \
    '{schema:"fm-provision.v1",status:$status,reason:$reason,policy:$policy,project:$project,worktree:$worktree,manifest:$manifest,task:$task,log:$log,path_prepend:$path_prepend,components:$components}' \
    2>/dev/null)
  [ -n "$verdict" ] || verdict="{\"schema\":\"fm-provision.v1\",\"status\":\"failed\",\"reason\":\"verdict could not be encoded\",\"policy\":\"$POLICY\",\"path_prepend\":\"\",\"components\":[]}"
  printf '%s\n' "$verdict"
  if [ "$status" != skipped ] && [ -n "$RECORD_FILE" ]; then
    printf '%s\n' "$verdict" > "$RECORD_FILE" 2>/dev/null || true
  fi
  log_line "verdict: $verdict"
  case "$status" in
    ready|skipped) code=0 ;;
    *) if [ "$POLICY" = block ]; then code=4; else code=3; fi ;;
  esac
  exit "$code"
}

record_component() {
  local name=$1 result=$2 detail=$3
  jq -c -n --arg name "$name" --arg result "$result" --arg detail "$detail" \
    '{name:$name,result:$result,detail:$detail}' >> "$COMPONENT_RECORDS" 2>/dev/null || true
}

# --- manifest ---------------------------------------------------------------

if ! command -v jq >/dev/null 2>&1; then
  emit failed "jq is required to read the provisioning manifest"
fi

MANIFEST_JSON=$(jq -c '.' "$MANIFEST" 2>/dev/null) || emit failed "manifest is not valid JSON: $MANIFEST"
[ -n "$MANIFEST_JSON" ] || emit failed "manifest parsed to nothing: $MANIFEST"

mq() {
  printf '%s' "$MANIFEST_JSON" | jq -r "$1" 2>/dev/null
}

policy_raw=$(mq '.on_failure // "warn"')
case "$policy_raw" in
  warn|block) POLICY=$policy_raw ;;
  *) emit failed "on_failure must be \"warn\" or \"block\" (got '$policy_raw')" ;;
esac

STEP_TIMEOUT=$(mq ".step_timeout_seconds // $DEFAULT_STEP_TIMEOUT")
TOTAL_TIMEOUT=$(mq ".timeout_seconds // $DEFAULT_TOTAL_TIMEOUT")
case "$STEP_TIMEOUT" in ''|*[!0-9]*) emit failed "step_timeout_seconds must be a positive integer" ;; esac
case "$TOTAL_TIMEOUT" in ''|*[!0-9]*) emit failed "timeout_seconds must be a positive integer" ;; esac
[ "$STEP_TIMEOUT" -gt 0 ] || emit failed "step_timeout_seconds must be greater than zero"
[ "$TOTAL_TIMEOUT" -gt 0 ] || emit failed "timeout_seconds must be greater than zero"

KINDS=$(mq '(.kinds // ["ship"]) | join(" ")')
[ -n "$KINDS" ] || emit failed "kinds must be a non-empty array of task kinds"
if [ "$FORCE" != 1 ]; then
  case " $KINDS " in
    *" $KIND "*) ;;
    *) emit skipped "kind $KIND is not in the manifest kinds ($KINDS)" ;;
  esac
fi

activate_artifacts
init_work_area || emit failed "temporary provisioning workspace could not be created"

COMPONENT_COUNT=$(mq '.components | length')
case "$COMPONENT_COUNT" in ''|*[!0-9]*) emit failed "manifest has no readable components array" ;; esac
[ "$COMPONENT_COUNT" -gt 0 ] || emit failed "manifest declares no components"

STARTED=$(date +%s)

# --- token expansion and containment ----------------------------------------
#
# Command arguments, expected output, environment values, and path fields may
# reference exactly two tokens, so one manifest can name a host runtime directory
# or a path inside the lease without being rewritten per worktree: ${HOME} and
# ${WORKTREE}. Labels and descriptions do not expand, and no value is implicitly
# evaluated as a shell command.
expand_tokens() {
  local out=$1
  out=${out//\$\{HOME\}/$HOME}
  out=${out//\$\{WORKTREE\}/$WORKTREE_REAL}
  printf '%s' "$out"
}

# contained_path <base> <relative>: echo a physically contained path, refusing
# absolute inputs, symlinks, non-directory ancestors, and traversal escapes.
contained_path() {
  local base=$1 rel=$2 base_real resolved rest part next physical
  case "$rel" in
    ''|/*) return 1 ;;
  esac
  base_real=$(cd "$base" 2>/dev/null && pwd -P) || return 1
  resolved=$base_real
  rest=$rel
  while :; do
    part=${rest%%/*}
    if [ "$rest" = "$part" ]; then
      rest=
    else
      rest=${rest#*/}
    fi
    case "$part" in
      ''|.) ;;
      ..)
        [ "$resolved" != "$base_real" ] || return 1
        resolved=${resolved%/*}
        case "$resolved" in
          "$base_real"|"$base_real"/*) ;;
          *) return 1 ;;
        esac
        ;;
      *)
        next="$resolved/$part"
        [ ! -L "$next" ] || return 1
        if [ -e "$next" ]; then
          if [ -n "$rest" ] && [ ! -d "$next" ]; then
            return 1
          fi
          if [ -d "$next" ]; then
            physical=$(cd "$next" 2>/dev/null && pwd -P) || return 1
          else
            physical=$next
          fi
          case "$physical" in
            "$base_real"|"$base_real"/*) ;;
            *) return 1 ;;
          esac
          resolved=$physical
        else
          resolved=$next
        fi
        ;;
    esac
    [ -n "$rest" ] || break
  done
  printf '%s' "$resolved"
}

strict_descendant_path() {
  local base=$1 rel=$2 base_real resolved
  case "$rel" in
    ''|.|/*) return 1 ;;
  esac
  base_real=$(cd "$base" 2>/dev/null && pwd -P) || return 1
  resolved=$(contained_path "$base_real" "$rel") || return 1
  case "$resolved" in
    "$base_real"/*) printf '%s' "$resolved" ;;
    *) return 1 ;;
  esac
}

# --- bounded execution ------------------------------------------------------
#
# This host has neither timeout(1) nor gtimeout(1), and the failure this script
# exists to prevent was an unbounded hang, so the bound is implemented here.
# set -m gives the child its own process group, which stays supervised as one
# unit rather than orphaning grandchildren when its leader exits.
run_bounded() {
  local seconds=$1
  shift
  local pid status=0 ticks=0 limit grace=0
  set -m
  "$@" &
  pid=$!
  set +m
  limit=$((seconds * 10))
  while kill -0 -"$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$limit" ]; then
      kill -TERM -"$pid" 2>/dev/null || true
      while kill -0 -"$pid" 2>/dev/null && [ "$grace" -lt 20 ]; do
        sleep 0.1
        grace=$((grace + 1))
      done
      if kill -0 -"$pid" 2>/dev/null; then
        kill -KILL -"$pid" 2>/dev/null || true
      fi
      wait "$pid" 2>/dev/null || status=$?
      return 124
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "$pid" 2>/dev/null || status=$?
  return "$status"
}

remaining_budget() {
  local now elapsed left
  now=$(date +%s)
  elapsed=$((now - STARTED))
  left=$((TOTAL_TIMEOUT - elapsed))
  [ "$left" -gt 0 ] || left=0
  printf '%s' "$left"
}

# --- steps ------------------------------------------------------------------

STEP_ARGV=()
STEP_OUT=
STEP_FAILURE=
COMPONENT_ENV=()

# step_argv <step-json>: fill STEP_ARGV with the step's token-expanded argv.
step_argv() {
  local step=$1 arg
  STEP_ARGV=()
  while IFS= read -r -d '' arg; do
    STEP_ARGV[${#STEP_ARGV[@]}]=$(expand_tokens "$arg")
  done < <(printf '%s' "$step" | jq -j '.argv[]? | tostring + "\u0000"' 2>/dev/null)
  [ "${#STEP_ARGV[@]}" -gt 0 ]
}

# run_step <label> <cwd> <step-json>: run one manifest step in <cwd> under the
# component environment, bounded by its own timeout and by whatever is left of
# the total budget. Sets STEP_OUT to the step's last non-empty output line and,
# on failure, STEP_FAILURE to a diagnosable reason.
run_step() {
  local label=$1 cwd=$2 step=$3
  local timeout name budget status out_file expect actual
  STEP_OUT=
  STEP_FAILURE=
  name=$(printf '%s' "$step" | jq -r '.name // ""' 2>/dev/null)
  [ -n "$name" ] || name=$label
  timeout=$(printf '%s' "$step" | jq -r ".timeout_seconds // $STEP_TIMEOUT" 2>/dev/null)
  case "$timeout" in ''|*[!0-9]*) timeout=$STEP_TIMEOUT ;; esac
  [ "$timeout" -gt 0 ] || timeout=$STEP_TIMEOUT
  budget=$(remaining_budget)
  if [ "$budget" -le 0 ]; then
    STEP_FAILURE="$label '$name' skipped: the ${TOTAL_TIMEOUT}s provisioning budget is exhausted"
    return 1
  fi
  [ "$timeout" -le "$budget" ] || timeout=$budget
  if ! step_argv "$step"; then
    STEP_FAILURE="$label '$name' has an empty argv"
    return 1
  fi
  out_file="$WORK_DIR/step.out"
  log_line "=== $label :: $name :: ${STEP_ARGV[*]} (cwd $cwd, timeout ${timeout}s)"
  status=0
  (
    cd "$cwd" || exit 126
    run_bounded "$timeout" \
      /usr/bin/env "${COMPONENT_ENV[@]}" "${STEP_ARGV[@]}"
  ) > "$out_file" 2>&1 || status=$?
  if [ -n "$LOG_FILE" ] && [ -s "$out_file" ]; then
    cat "$out_file" >> "$LOG_FILE"
  fi
  log_line "--- exit $status"
  STEP_OUT=$(awk 'NF { last = $0 } END { if (last != "") print last }' "$out_file" 2>/dev/null \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  if [ "$status" -eq 124 ]; then
    STEP_FAILURE="$label '$name' timed out after ${timeout}s"
    return 1
  fi
  if [ "$status" -ne 0 ]; then
    STEP_FAILURE="$label '$name' exited $status"
    [ -z "$STEP_OUT" ] || STEP_FAILURE="$STEP_FAILURE: $STEP_OUT"
    return 1
  fi
  expect=$(printf '%s' "$step" | jq -r '.expect // ""' 2>/dev/null)
  if [ -n "$expect" ]; then
    actual=$STEP_OUT
    expect=$(expand_tokens "$expect")
    if [ -z "$actual" ]; then
      STEP_FAILURE="$label '$name' printed nothing, expected '$expect'"
      return 1
    fi
    if [ "$actual" != "$expect" ]; then
      STEP_FAILURE="$label '$name' reported '$actual', expected '$expect'"
      return 1
    fi
  fi
  return 0
}

# --- components -------------------------------------------------------------

FAILURES=0
FAILURE_REASON=
ALL_PATH_PREPEND=

# component_env <comp-json>: build COMPONENT_ENV, the exact env every step of
# this component runs under. PATH is composed here and never taken from the
# manifest env map, so the resolved runtime cannot be smuggled past the runtime
# checks.
component_env() {
  local comp=$1 key value prefix path_extra=''
  COMPONENT_ENV=()
  while IFS= read -r -d '' key; do
    IFS= read -r -d '' value || break
    case "$key" in
      PATH) FAILURE_REASON="env must not set PATH; use path_prepend"; return 1 ;;
      ''|*[!A-Za-z0-9_]*) FAILURE_REASON="env name must be [A-Za-z0-9_] (got '$key')"; return 1 ;;
    esac
    COMPONENT_ENV[${#COMPONENT_ENV[@]}]="$key=$(expand_tokens "$value")"
  done < <(printf '%s' "$comp" | jq -j '(.env // {}) | to_entries[] | (.key + "\u0000" + (.value|tostring) + "\u0000")' 2>/dev/null)
  for prefix in $ALL_PATH_PREPEND; do
    path_extra="${path_extra:+$path_extra:}$prefix"
  done
  while IFS= read -r -d '' prefix; do
    prefix=$(expand_tokens "$prefix")
    if [ ! -d "$prefix" ]; then
      FAILURE_REASON="path_prepend directory does not exist: $prefix"
      return 1
    fi
    path_extra="${path_extra:+$path_extra:}$prefix"
  done < <(printf '%s' "$comp" | jq -j '.path_prepend[]? | tostring + "\u0000"' 2>/dev/null)
  COMPONENT_ENV[${#COMPONENT_ENV[@]}]="PATH=${path_extra:+$path_extra:}$PATH"
  return 0
}

# component_fingerprint <comp-json> <dir>: set FINGERPRINT to a digest over the
# component's declared inputs. An unreadable file, a failing version command, or
# an empty value leaves FINGERPRINT empty, which means "unavailable" and always
# forces a rebuild - a reuse verdict is never derived from a value that was not
# actually computed.
FINGERPRINT=
FINGERPRINT_INPUTS=
component_fingerprint() {
  local comp=$1 dir=$2 rel abs sum inputs='' step out
  FINGERPRINT=
  FINGERPRINT_INPUTS=
  while IFS= read -r -d '' rel; do
    if ! abs=$(strict_descendant_path "$dir" "$(expand_tokens "$rel")"); then
      log_line "fingerprint: refusing an input that is not a strict descendant of the component: $rel"
      return 0
    fi
    if [ ! -f "$abs" ]; then
      log_line "fingerprint: missing input file $abs"
      return 0
    fi
    sum=$(shasum -a 256 "$abs" 2>/dev/null | awk '{print $1}')
    if [ -z "$sum" ]; then
      log_line "fingerprint: cannot hash $abs"
      return 0
    fi
    inputs="$inputs
file:$rel=$sum"
  done < <(printf '%s' "$comp" | jq -j '.fingerprint.files[]? | tostring + "\u0000"' 2>/dev/null)
  while IFS= read -r -d '' step; do
    if ! run_step "fingerprint version" "$dir" "$step"; then
      log_line "fingerprint: ${STEP_FAILURE:-version command failed}"
      return 0
    fi
    out=$STEP_OUT
    if [ -z "$out" ]; then
      log_line "fingerprint: version command printed nothing"
      return 0
    fi
    step_argv "$step" || return 0
    inputs="$inputs
version:${STEP_ARGV[*]}=$out"
  done < <(printf '%s' "$comp" | jq -j '.fingerprint.versions[]? | tostring + "\u0000"' 2>/dev/null)
  if [ -z "$inputs" ]; then
    log_line "fingerprint: no inputs declared"
    return 0
  fi
  sum=$(printf '%s\n' "$inputs" | shasum -a 256 2>/dev/null | awk '{print $1}')
  [ -n "$sum" ] || return 0
  FINGERPRINT=$sum
  FINGERPRINT_INPUTS=$inputs
  return 0
}

run_probes() {
  local comp=$1 dir=$2 step
  while IFS= read -r -d '' step; do
    run_step probe "$dir" "$step" || return 1
  done < <(printf '%s' "$comp" | jq -j '.probes[]? | tostring + "\u0000"' 2>/dev/null)
  return 0
}

run_install() {
  local comp=$1 dir=$2 rel abs step budget status out_file detail
  out_file="$WORK_DIR/reset.out"
  while IFS= read -r -d '' rel; do
    if ! abs=$(strict_descendant_path "$dir" "$(expand_tokens "$rel")"); then
      STEP_FAILURE="reset path must be a strict descendant of the component directory: '$rel'"
      return 1
    fi
    budget=$(remaining_budget)
    if [ "$budget" -le 0 ]; then
      STEP_FAILURE="reset '$rel' skipped: the ${TOTAL_TIMEOUT}s provisioning budget is exhausted"
      return 1
    fi
    log_line "=== reset :: rm -rf $abs (timeout ${budget}s)"
    status=0
    run_bounded "$budget" rm -rf -- "$abs" > "$out_file" 2>&1 || status=$?
    if [ -n "$LOG_FILE" ] && [ -s "$out_file" ]; then
      cat "$out_file" >> "$LOG_FILE"
    fi
    log_line "--- exit $status"
    if [ "$status" -eq 124 ]; then
      STEP_FAILURE="reset '$rel' timed out after ${budget}s"
      return 1
    fi
    if [ "$status" -ne 0 ]; then
      STEP_FAILURE="cannot remove $abs (exit $status)"
      detail=$(awk 'NF { last = $0 } END { if (last != "") print last }' "$out_file" 2>/dev/null \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      [ -z "$detail" ] || STEP_FAILURE="$STEP_FAILURE: $detail"
      return 1
    fi
  done < <(printf '%s' "$comp" | jq -j '.reset[]? | tostring + "\u0000"' 2>/dev/null)
  while IFS= read -r -d '' step; do
    run_step install "$dir" "$step" || return 1
  done < <(printf '%s' "$comp" | jq -j '.install[]? | tostring + "\u0000"' 2>/dev/null)
  return 0
}

STORED_FINGERPRINT=

read_fingerprint() {
  local dir=$1 rel=$2 abs
  STORED_FINGERPRINT=
  [ -n "$rel" ] || return 0
  abs=$(strict_descendant_path "$dir" "$(expand_tokens "$rel")") || return 0
  [ -f "$abs" ] || return 0
  STORED_FINGERPRINT=$(jq -r 'select(.schema=="fm-provision-fingerprint.v1") | .digest // ""' "$abs" 2>/dev/null)
}

write_fingerprint() {
  local dir=$1 rel=$2 abs parent
  [ -n "$FINGERPRINT" ] || return 0
  [ -n "$rel" ] || return 0
  if ! abs=$(strict_descendant_path "$dir" "$(expand_tokens "$rel")"); then
    log_line "fingerprint: refusing to write outside the strict descendants of $dir"
    return 0
  fi
  parent=$(dirname "$abs")
  if [ ! -d "$parent" ]; then
    log_line "fingerprint: parent $parent does not exist; not recorded"
    return 0
  fi
  jq -c -n --arg digest "$FINGERPRINT" --arg inputs "$FINGERPRINT_INPUTS" \
    '{schema:"fm-provision-fingerprint.v1",digest:$digest,inputs:$inputs}' > "$abs" 2>/dev/null \
    || log_line "fingerprint: cannot write $abs"
}

validate_component_paths() {
  local comp=$1 dir=$2 rel fp_path fp_path_present
  while IFS= read -r -d '' rel; do
    if ! strict_descendant_path "$dir" "$(expand_tokens "$rel")" >/dev/null; then
      FAILURE_REASON="reset path must be a strict descendant of the component directory: '$rel'"
      return 1
    fi
  done < <(printf '%s' "$comp" | jq -j '.reset[]? | tostring + "\u0000"' 2>/dev/null)
  while IFS= read -r -d '' rel; do
    if ! strict_descendant_path "$dir" "$(expand_tokens "$rel")" >/dev/null; then
      FAILURE_REASON="fingerprint file must be a strict descendant of the component directory: '$rel'"
      return 1
    fi
  done < <(printf '%s' "$comp" | jq -j '.fingerprint.files[]? | tostring + "\u0000"' 2>/dev/null)
  fp_path_present=$(printf '%s' "$comp" | jq -r 'if (.fingerprint? | type) == "object" then if (.fingerprint | has("path")) then "yes" else "no" end else "no" end' 2>/dev/null)
  if [ "$fp_path_present" = yes ]; then
    fp_path=$(printf '%s' "$comp" | jq -r '.fingerprint.path // ""' 2>/dev/null)
    if ! strict_descendant_path "$dir" "$(expand_tokens "$fp_path")" >/dev/null; then
      FAILURE_REASON="fingerprint path must be a strict descendant of the component directory: '$fp_path'"
      return 1
    fi
  fi
  return 0
}

run_component() {
  local comp=$1
  local name dir_rel dir fp_path result detail check built
  name=$(printf '%s' "$comp" | jq -r '.name // ""' 2>/dev/null)
  if [ -z "$name" ]; then
    FAILURE_REASON="a component has no name"
    return 1
  fi
  dir_rel=$(printf '%s' "$comp" | jq -r '.dir // "."' 2>/dev/null)
  if [ "$dir_rel" = "." ]; then
    dir=$WORKTREE_REAL
  elif ! dir=$(contained_path "$WORKTREE_REAL" "$(expand_tokens "$dir_rel")"); then
    FAILURE_REASON="component $name: dir '$dir_rel' escapes the worktree"
    return 1
  fi
  if [ ! -d "$dir" ]; then
    FAILURE_REASON="component $name: directory does not exist: $dir"
    return 1
  fi
  dir=$(cd "$dir" && pwd -P) || { FAILURE_REASON="component $name: directory is unreadable"; return 1; }
  case "$dir" in
    "$WORKTREE_REAL"|"$WORKTREE_REAL"/*) ;;
    *) FAILURE_REASON="component $name: directory resolves outside the worktree"; return 1 ;;
  esac
  fp_path=$(printf '%s' "$comp" | jq -r '.fingerprint.path // ""' 2>/dev/null)

  if ! validate_component_paths "$comp" "$dir"; then
    FAILURE_REASON="component $name: ${FAILURE_REASON:-manifest path validation failed}"
    return 1
  fi

  if ! component_env "$comp"; then
    FAILURE_REASON="component $name: ${FAILURE_REASON:-environment could not be built}"
    return 1
  fi

  # Runtime checks run before anything is built, so a component is never
  # compiled or installed under a runtime the project does not pin.
  while IFS= read -r -d '' check; do
    if ! run_step "runtime check" "$dir" "$check"; then
      FAILURE_REASON="component $name: ${STEP_FAILURE:-runtime check failed}"
      return 1
    fi
  done < <(printf '%s' "$comp" | jq -j '.runtime_checks[]? | tostring + "\u0000"' 2>/dev/null)

  component_fingerprint "$comp" "$dir"
  read_fingerprint "$dir" "$fp_path"

  if [ "$FORCE" != 1 ] && [ -n "$FINGERPRINT" ] && [ "$FINGERPRINT" = "$STORED_FINGERPRINT" ]; then
    note "$name: fingerprint unchanged, verifying health"
    if run_probes "$comp" "$dir"; then
      record_component "$name" reused "fingerprint matched and every probe passed"
      return 0
    fi
    note "$name: probes failed on an unchanged fingerprint, rebuilding"
    log_line "reuse rejected: ${STEP_FAILURE:-probe failed}"
    result=rebuilt
    detail="rebuilt after an unchanged fingerprint failed its probes"
  else
    result=installed
    if [ -z "$FINGERPRINT" ]; then
      detail="built because the fingerprint inputs were unavailable"
    elif [ "$FORCE" = 1 ]; then
      detail="built because --force was requested"
    elif [ -z "$STORED_FINGERPRINT" ]; then
      detail="built because no fingerprint was recorded"
    else
      detail="built because the fingerprint changed"
    fi
  fi

  note "$name: $detail"
  if ! run_install "$comp" "$dir"; then
    FAILURE_REASON="component $name: ${STEP_FAILURE:-install failed}"
    return 1
  fi
  if ! run_probes "$comp" "$dir"; then
    FAILURE_REASON="component $name: ${STEP_FAILURE:-probe failed after install}"
    return 1
  fi
  # Recompute before recording. A version command that reads the very thing it
  # fingerprints (uv python find resolves a project .venv once one exists) yields
  # one value before the build and another after, so recording the pre-build
  # value would silently guarantee a full rebuild on every future lease. Refusing
  # to record it turns that manifest bug into a visible one instead.
  built=$FINGERPRINT
  component_fingerprint "$comp" "$dir"
  if [ "$built" != "$FINGERPRINT" ]; then
    detail="$detail; fingerprint not recorded: a version command's value changed across the build, so it depends on what it fingerprints"
    note "$name: $detail"
    log_line "fingerprint: unstable across the build; not recorded"
  elif [ -n "$built" ] && [ -n "$FINGERPRINT" ]; then
    write_fingerprint "$dir" "$fp_path"
  else
    log_line "fingerprint: unavailable before and after the build; not recorded"
  fi
  record_component "$name" "$result" "$detail"
  return 0
}

# --- run --------------------------------------------------------------------

while IFS= read -r -d '' entry; do
  entry=$(expand_tokens "$entry")
  [ -d "$entry" ] || emit failed "path_prepend directory does not exist: $entry"
  case "$entry" in
    *"'"*) emit failed "path_prepend directory contains a quote: $entry" ;;
    *" "*) emit failed "path_prepend directory contains a space: $entry" ;;
  esac
  ALL_PATH_PREPEND="${ALL_PATH_PREPEND:+$ALL_PATH_PREPEND }$entry"
  PATH_PREPEND="${PATH_PREPEND:+$PATH_PREPEND:}$entry"
done < <(printf '%s' "$MANIFEST_JSON" | jq -j '.path_prepend[]? | tostring + "\u0000"' 2>/dev/null)

note "provisioning $PROJECT_NAME in $WORKTREE_REAL ($COMPONENT_COUNT component(s), policy $POLICY)"
log_line "manifest: $MANIFEST"
log_line "worktree: $WORKTREE_REAL"
log_line "kind: $KIND force: $FORCE policy: $POLICY"

while IFS= read -r component_json; do
  [ -n "$component_json" ] || continue
  FAILURE_REASON=
  if ! run_component "$component_json"; then
    FAILURES=$((FAILURES + 1))
    record_component \
      "$(printf '%s' "$component_json" | jq -r '.name // "unnamed"' 2>/dev/null)" \
      failed "${FAILURE_REASON:-unknown failure}"
    note "FAILED: ${FAILURE_REASON:-unknown failure}"
    break
  fi
done < <(printf '%s' "$MANIFEST_JSON" | jq -c '.components[]' 2>/dev/null)

if [ "$FAILURES" -gt 0 ]; then
  emit failed "${FAILURE_REASON:-provisioning failed}"
fi

note "ready"
emit ready "every declared component is present and passed its probes"
