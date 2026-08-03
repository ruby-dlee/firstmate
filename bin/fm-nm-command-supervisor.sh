#!/usr/bin/env bash
# fm-nm-command-supervisor.sh - own one configured no-mistakes command process.
set -u

usage() {
  echo "usage: fm-nm-command-supervisor.sh <step> <command> [args...]" >&2
}

case "${1:-}" in -h|--help) usage; exit 0 ;; esac
STEP=${1:-}
[ -n "$STEP" ] || { usage; exit 2; }
shift
[ $# -gt 0 ] || { usage; exit 2; }
case "$STEP" in *[!A-Za-z0-9._-]*|'') echo "error: invalid step name: $STEP" >&2; exit 2 ;; esac

WORKTREE=$(pwd -P) || exit 1
RUN_ID=${WORKTREE##*/}
case "$RUN_ID" in *[!A-Za-z0-9._-]*|'') echo "error: invalid run worktree name: $RUN_ID" >&2; exit 1 ;; esac

REPO_DIR=${WORKTREE%/*}
WORKTREES_DIR=${REPO_DIR%/*}
DERIVED_NM_HOME=""
[ "${WORKTREES_DIR##*/}" = worktrees ] && DERIVED_NM_HOME=${WORKTREES_DIR%/*}
NM_HOME=${FM_NM_HOME:-${NO_MISTAKES_HOME:-${DERIVED_NM_HOME:-$HOME/.no-mistakes}}}
STATE_DIR=${FM_NM_COMMAND_STATE_DIR:-$NM_HOME/command-state}
umask 077
mkdir -p "$STATE_DIR" || exit 1
STATE_FILE="$STATE_DIR/$RUN_ID.$STEP.state"
STATE_TMP="$STATE_FILE.$$"
STOP_FILE="$STATE_DIR/$RUN_ID.$STEP.stop.$$"
OUTPUT_FILE=$(mktemp "$STATE_DIR/$RUN_ID.$STEP.output.XXXXXX") || exit 1
IDENTITY_FILE="$STATE_DIR/$RUN_ID.$STEP.identity.$$"
exec 9> "$IDENTITY_FILE" || exit 1

setup_error() {
  local message=$1
  exec 9>&-
  rm -f "$OUTPUT_FILE" "$IDENTITY_FILE" "$STATE_TMP"
  echo "error: $message" >&2
  exit 1
}

PGID=$(ps -p "$$" -o pgid= 2>/dev/null | tr -d '[:space:]')
START=$(LC_ALL=C ps -p "$$" -o lstart= 2>/dev/null | awk '{$1=$1; print}')
case "$PGID" in ''|*[!0-9]*) setup_error "cannot resolve command process group" ;; esac
[ -n "$START" ] || setup_error "cannot resolve command start identity"
[ "$PGID" = "$$" ] || setup_error "command supervisor must be an isolated process-group leader"

printf 'version=2\nrun_id=%s\nstep=%s\nworktree=%s\npid=%s\npgid=%s\nstart=%s\nidentity_file=%s\n' \
  "$RUN_ID" "$STEP" "$WORKTREE" "$$" "$PGID" "$START" "$IDENTITY_FILE" > "$STATE_TMP" \
  || setup_error "cannot write command identity"
mv "$STATE_TMP" "$STATE_FILE" || setup_error "cannot publish command identity"

(
  exec 9>&-
  trap '' HUP INT TERM
  while [ ! -e "$STOP_FILE" ]; do
    row=$(LC_ALL=C ps -p "$$" -o pgid= -o stat= 2>/dev/null | awk '{$1=$1; print}')
    case "$row" in
      "$PGID "Z*|"")
        kill -TERM "-$PGID" 2>/dev/null || true
        sleep 1
        kill -KILL "-$PGID" 2>/dev/null || true
        exit 0
        ;;
    esac
    sleep 1
  done
) </dev/null >/dev/null 2>&1 &
WATCHDOG=$!

# shellcheck disable=SC2329
cleanup() {
  local pid group table
  : > "$STOP_FILE"
  wait "$WATCHDOG" 2>/dev/null || true
  table=$(ps -eo pid=,pgid= 2>/dev/null) || table=""
  while read -r pid group; do
    [ "$group" = "$PGID" ] || continue
    [ "$pid" = "$$" ] || kill -TERM "$pid" 2>/dev/null || true
  done <<< "$table"
  sleep 1
  table=$(ps -eo pid=,pgid= 2>/dev/null) || table=""
  while read -r pid group; do
    [ "$group" = "$PGID" ] || continue
    [ "$pid" = "$$" ] || kill -KILL "$pid" 2>/dev/null || true
  done <<< "$table"
  if [ -f "$STATE_FILE" ] && grep -q "^pid=$$\$" "$STATE_FILE" 2>/dev/null; then
    rm -f "$STATE_FILE"
  fi
  exec 9>&-
  rm -f "$STOP_FILE" "$OUTPUT_FILE" "$STATE_TMP" "$IDENTITY_FILE"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

"$@" 9>&- > "$OUTPUT_FILE" 2>&1 &
COMMAND_PID=$!
wait "$COMMAND_PID"
RC=$?
cat "$OUTPUT_FILE"
exit "$RC"
