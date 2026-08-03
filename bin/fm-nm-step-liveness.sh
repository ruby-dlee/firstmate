#!/usr/bin/env bash
# fm-nm-step-liveness.sh - verify one configured command's process identity.
set -u

VERDICT_SEP=' · '
NM_HOME="${FM_NM_HOME:-${NO_MISTAKES_HOME:-$HOME/.no-mistakes}}"
STATE_DIR="${FM_NM_COMMAND_STATE_DIR:-$NM_HOME/command-state}"
SAMPLE_DEFAULT=3
ABSENCE_RECHECK_DEFAULT=1

RUN_ID=""
STEP=""
SAMPLE=$SAMPLE_DEFAULT
WORKTREE=""

usage() {
  echo "usage: fm-nm-step-liveness.sh <run-id> [--step <name>] [--sample <seconds>] [--worktree <path>]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --step)
      [ $# -ge 2 ] || usage
      STEP=$2
      shift 2
      ;;
    --sample)
      [ $# -ge 2 ] || usage
      SAMPLE=$2
      shift 2
      ;;
    --worktree)
      [ $# -ge 2 ] || usage
      WORKTREE=$2
      shift 2
      ;;
    -h|--help) usage ;;
    -*) usage ;;
    *)
      [ -z "$RUN_ID" ] || usage
      RUN_ID=$1
      shift
      ;;
  esac
done

[ -n "$RUN_ID" ] || usage
case "$RUN_ID" in *[!A-Za-z0-9._-]*) usage ;; esac
case "$STEP" in *[!A-Za-z0-9._-]*) usage ;; esac
case "$SAMPLE" in ''|*[!0-9]*) SAMPLE=$SAMPLE_DEFAULT ;; esac
ABSENCE_RECHECK=${FM_NM_LIVENESS_RECHECK_SECS:-$ABSENCE_RECHECK_DEFAULT}
case "$ABSENCE_RECHECK" in ''|*[!0-9]*) ABSENCE_RECHECK=$ABSENCE_RECHECK_DEFAULT ;; esac
[ "$ABSENCE_RECHECK" -gt 0 ] || ABSENCE_RECHECK=$ABSENCE_RECHECK_DEFAULT

emit() {
  local line="liveness: $1${VERDICT_SEP}run: $RUN_ID${VERDICT_SEP}procs: $2"
  [ -n "${3:-}" ] && line="$line${VERDICT_SEP}$3"
  printf '%s\n' "$line"
  exit 0
}

if [ -z "$WORKTREE" ]; then
  for candidate in "$NM_HOME"/worktrees/*/"$RUN_ID"; do
    [ -d "$candidate" ] || continue
    WORKTREE=$candidate
    break
  done
fi
[ -n "$WORKTREE" ] && [ -d "$WORKTREE" ] || emit unknown 0 "run worktree unavailable"
WORKTREE_REAL=$(cd "$WORKTREE" 2>/dev/null && pwd -P) || WORKTREE_REAL=""
[ -n "$WORKTREE_REAL" ] || emit unknown 0 "run worktree unreadable"

state_file_for_step() {
  local candidate found=""
  if [ -n "$STEP" ]; then
    printf '%s' "$STATE_DIR/$RUN_ID.$STEP.state"
    return
  fi
  for candidate in "$STATE_DIR"/"$RUN_ID".*.state; do
    [ -f "$candidate" ] || continue
    [ -z "$found" ] || return 1
    found=$candidate
  done
  [ -n "$found" ] || return 1
  printf '%s' "$found"
}

state_field() {
  sed -n "s/^$1=//p" "$2" 2>/dev/null | tail -1
}

process_row() {
  LC_ALL=C ps -p "$1" -o pid= -o pgid= -o stat= -o lstart= 2>/dev/null \
    | awk '{$1=$1; print}'
}

fd_identity_verdict() {
  local pid=$1 identity_file=$2 target out
  if [ -d /proc ] && [ -e "/proc/$pid/fd" ]; then
    target=$(readlink "/proc/$pid/fd/9" 2>/dev/null) || { printf 'mismatch'; return; }
    [ "$target" = "$identity_file" ] && printf 'match' || printf 'mismatch'
    return
  fi
  command -v lsof >/dev/null 2>&1 || { printf 'unknown'; return; }
  out=$(lsof -a -p "$pid" -d 9 -Fn 2>/dev/null) || out=""
  target=$(printf '%s\n' "$out" | sed -n 's/^n//p' | head -1)
  if [ -n "$target" ]; then
    [ "$target" = "$identity_file" ] && printf 'match' || printf 'mismatch'
    return
  fi
  lsof -p "$pid" -Fp >/dev/null 2>&1 && printf 'mismatch' || printf 'unknown'
}

identity_verdict() {
  local file=$1 expected_snapshot=${2:-} snapshot version state_run state_step state_worktree pid pgid start identity_file
  local row actual_pid actual_pgid actual_stat actual_start fd_verdict
  [ -f "$file" ] || { printf 'missing'; return; }
  snapshot=$(sed -n '1,20p' "$file" 2>/dev/null) || { printf 'unknown'; return; }
  [ -z "$expected_snapshot" ] || [ "$snapshot" = "$expected_snapshot" ] || { printf 'changed'; return; }
  version=$(state_field version "$file")
  state_run=$(state_field run_id "$file")
  state_step=$(state_field step "$file")
  state_worktree=$(state_field worktree "$file")
  pid=$(state_field pid "$file")
  pgid=$(state_field pgid "$file")
  start=$(state_field start "$file")
  identity_file=$(state_field identity_file "$file")
  [ "$version" = 2 ] && [ "$state_run" = "$RUN_ID" ] && [ -n "$state_step" ] \
    && [ "$state_worktree" = "$WORKTREE_REAL" ] && [ -n "$start" ] && [ -n "$identity_file" ] \
    || { printf 'unknown'; return; }
  [ -z "$STEP" ] || [ "$state_step" = "$STEP" ] || { printf 'unknown'; return; }
  case "$pid:$pgid" in *[!0-9:]*|:*|*:) printf 'unknown'; return ;; esac
  row=$(process_row "$pid")
  [ -n "$row" ] || { printf 'absent'; return; }
  actual_pid=${row%% *}; row=${row#* }
  actual_pgid=${row%% *}; row=${row#* }
  actual_stat=${row%% *}; actual_start=${row#* }
  [ "$actual_pid" = "$pid" ] && [ "$actual_pgid" = "$pgid" ] && [ "$actual_start" = "$start" ] \
    || { printf 'absent'; return; }
  case "$actual_stat" in Z*) printf 'absent'; return ;; esac
  fd_verdict=$(fd_identity_verdict "$pid" "$identity_file")
  case "$fd_verdict" in match) printf 'alive' ;; mismatch) printf 'absent' ;; *) printf 'unknown' ;; esac
}

procs_in_worktree() {
  local pid cwd line out
  if [ -d /proc ] && [ -r /proc/self/cwd ]; then
    for pid in /proc/[0-9]*; do
      cwd=$(readlink "$pid/cwd" 2>/dev/null) || continue
      case "$cwd" in "$WORKTREE_REAL"|"$WORKTREE_REAL"/*) printf '%s\n' "${pid#/proc/}" ;; esac
    done
    return 0
  fi
  command -v lsof >/dev/null 2>&1 || return 1
  out=$(lsof -a -d cwd -Fpn 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  pid=""
  while IFS= read -r line; do
    case "$line" in
      p*) pid=${line#p} ;;
      n*)
        cwd=${line#n}
        case "$cwd" in "$WORKTREE_REAL"|"$WORKTREE_REAL"/*) [ -n "$pid" ] && printf '%s\n' "$pid" ;; esac
        ;;
    esac
  done <<EOF
$out
EOF
}

procs_in_group() {
  local wanted=$1 pid ppid group
  while read -r pid ppid group; do
    [ "$group" = "$wanted" ] && printf '%s\n' "$pid"
  done < <(ps -eo pid=,ppid=,pgid= 2>/dev/null)
}

current_work() {
  local pids=$1 pid ppid args elapsed roots="" out="" table
  table=$(ps -o pid=,ppid= -p "$(printf '%s' "$pids" | tr '\n' ',' | sed 's/,$//')" 2>/dev/null) || return 0
  while read -r pid ppid; do
    [ -n "${pid:-}" ] || continue
    case "
$pids
" in *"
$ppid
"*) ;; *) roots="$roots $pid" ;; esac
  done <<EOF
$table
EOF
  for pid in $roots; do
    while read -r child parent; do
      [ "${parent:-}" = "$pid" ] || continue
      args=$(ps -o args= -p "$child" 2>/dev/null | cut -c1-60) || continue
      elapsed=$(ps -o etime= -p "$child" 2>/dev/null | tr -d ' ')
      [ -n "$args" ] || continue
      out="$args (${elapsed:-?})"
      break
    done <<EOF
$table
EOF
    [ -n "$out" ] && break
  done
  printf '%s' "$out"
}

cpu_hundredths() {
  local pid t total=0 part days=0
  for pid in "$@"; do
    t=$(ps -o time= -p "$pid" 2>/dev/null | tr -d ' ') || continue
    [ -n "$t" ] || continue
    case "$t" in *-*) days=${t%%-*}; t=${t#*-} ;; *) days=0 ;; esac
    case "$t" in *:*:*) ;; *:*) t="0:$t" ;; *) t="0:0:$t" ;; esac
    part=$(printf '%s\n' "$t" | awk -F: '{ printf "%d\n", ($1 * 3600 + $2 * 60 + $3) * 100 }' 2>/dev/null)
    case "$part" in ''|*[!0-9]*) part=0 ;; esac
    total=$((total + part + days * 8640000))
  done
  printf '%s' "$total"
}

STATE_FILE=$(state_file_for_step) || STATE_FILE=""
if [ -n "$STATE_FILE" ] && [ -f "$STATE_FILE" ]; then
  SNAPSHOT=$(sed -n '1,20p' "$STATE_FILE" 2>/dev/null) || emit unknown 0 "command identity unreadable"
  IDENTITY=$(identity_verdict "$STATE_FILE" "$SNAPSHOT")
  case "$IDENTITY" in
    absent)
      sleep "$ABSENCE_RECHECK"
      IDENTITY=$(identity_verdict "$STATE_FILE" "$SNAPSHOT")
      case "$IDENTITY" in
        absent) emit dead 0 "supervised command identity absent after two checks" ;;
        alive) ;;
        *) emit unknown 0 "command identity changed while rechecking absence" ;;
      esac
      ;;
    alive) ;;
    *) emit unknown 0 "command identity unavailable or invalid" ;;
  esac

  PGID=$(state_field pgid "$STATE_FILE")
  PIDS_T0=$(procs_in_group "$PGID")
  COUNT_T0=$(printf '%s' "$PIDS_T0" | grep -c . || true)
  DOING=$(current_work "$PIDS_T0")
  [ -n "$DOING" ] && DOING="${VERDICT_SEP}doing: $DOING"
  if [ "$SAMPLE" = 0 ]; then
    emit alive "$COUNT_T0" "supervised pid $(state_field pid "$STATE_FILE"), pgid $PGID$DOING"
  fi

  # shellcheck disable=SC2086
  CPU_T0=$(cpu_hundredths $PIDS_T0)
  sleep "$SAMPLE"
  IDENTITY=$(identity_verdict "$STATE_FILE" "$SNAPSHOT")
  case "$IDENTITY" in
    alive) ;;
    absent)
      sleep "$ABSENCE_RECHECK"
      [ "$(identity_verdict "$STATE_FILE" "$SNAPSHOT")" = absent ] \
        && emit dead 0 "supervised command identity absent after two checks"
      emit unknown 0 "command identity changed while rechecking absence"
      ;;
    *) emit unknown 0 "command identity changed during sample" ;;
  esac
  PIDS_T1=$(procs_in_group "$PGID")
  COUNT_T1=$(printf '%s' "$PIDS_T1" | grep -c . || true)
  # shellcheck disable=SC2086
  CPU_T1=$(cpu_hundredths $PIDS_T1)
  CPU_DELTA=$((CPU_T1 - CPU_T0))
  [ "$CPU_DELTA" -lt 0 ] && CPU_DELTA=0
  CPU_NOTE=$(awk -v d="$CPU_DELTA" 'BEGIN { printf "%.2fs", d / 100 }')
  DOING=$(current_work "$PIDS_T1")
  [ -n "$DOING" ] && DOING="${VERDICT_SEP}doing: $DOING"
  emit alive "$COUNT_T1" "supervised command present; cpu +$CPU_NOTE in ${SAMPLE}s$DOING"
fi

PIDS_T0=$(procs_in_worktree) || emit unknown 0 "cannot inspect worktree process presence"
COUNT_T0=$(printf '%s' "$PIDS_T0" | grep -c . || true)
if [ "$COUNT_T0" -gt 0 ]; then
  emit unknown "$COUNT_T0" "processes present, but no supervised command identity"
fi
sleep "$ABSENCE_RECHECK"
PIDS_T1=$(procs_in_worktree) || emit unknown 0 "cannot recheck worktree process presence"
COUNT_T1=$(printf '%s' "$PIDS_T1" | grep -c . || true)
if [ "$COUNT_T1" -gt 0 ]; then
  emit unknown "$COUNT_T1" "processes appeared, but no supervised command identity"
fi
emit unknown 0 "no worktree process in two checks; supervised command identity unavailable"
