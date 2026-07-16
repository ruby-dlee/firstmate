#!/usr/bin/env bash
# Keep the machine-global completion report stack below its 30-day ceiling.
# Usage: fm-report-retention.sh ensure
#        fm-report-retention.sh run
#
# `ensure` starts one detached machine-global owner when none is live.
# `run` prunes immediately, drains bounded deletion batches, and then repeats
# before the report stack's matching early-prune guard can reach 30 days.
# FM_REPORT_STACK_ROOT selects an isolated stack for tests.
# FM_REPORT_RETENTION_INTERVAL sets the owner cadence in seconds (default 300).
# FM_REPORT_RETENTION_PROGRESS_INTERVAL sets the bounded-drain cadence (default 1).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent

STACK_ROOT="${FM_REPORT_STACK_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/firstmate/report-stack}"
OWNER="$STACK_ROOT/.retention-owner"
ERROR_FILE="$STACK_ROOT/.retention-error"
INTERVAL=${FM_REPORT_RETENTION_INTERVAL:-300}
PROGRESS_INTERVAL=${FM_REPORT_RETENTION_PROGRESS_INTERVAL:-1}
case "$INTERVAL" in ''|*[!0-9]*|0) echo "error: FM_REPORT_RETENTION_INTERVAL must be a positive integer" >&2; exit 2 ;; esac
case "$PROGRESS_INTERVAL" in ''|*[!0-9]*|0) echo "error: FM_REPORT_RETENTION_PROGRESS_INTERVAL must be a positive integer" >&2; exit 2 ;; esac
[ "$INTERVAL" -lt 1296000 ] || { echo "error: FM_REPORT_RETENTION_INTERVAL must be below 15 days" >&2; exit 2; }
[ "$PROGRESS_INTERVAL" -le "$INTERVAL" ] || { echo "error: FM_REPORT_RETENTION_PROGRESS_INTERVAL must not exceed the owner interval" >&2; exit 2; }

process_identity() {
  LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]][[:space:]]*/ /g;s/[[:space:]]*$//'
}

path_age() {
  local mtime now
  if [ "$(uname)" = Darwin ]; then
    mtime=$(stat -f %m "$1" 2>/dev/null) || return 1
  else
    mtime=$(stat -c %Y "$1" 2>/dev/null) || return 1
  fi
  now=$(date +%s)
  printf '%s\n' "$((now - mtime))"
}

read_owner() {
  local file="$OWNER/owner" pid identity token
  [ -d "$OWNER" ] && [ ! -L "$OWNER" ] && [ -f "$file" ] && [ ! -L "$file" ] || return 1
  pid=$(sed -n '1p' "$file" 2>/dev/null) || return 1
  identity=$(sed -n '2p' "$file" 2>/dev/null) || return 1
  token=$(sed -n '3p' "$file" 2>/dev/null) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$identity" ] && [ -n "$token" ] || return 1
  printf '%s\n%s\n%s\n' "$pid" "$identity" "$token"
}

owner_alive() {
  local record pid identity current
  record=$(read_owner) || return 1
  pid=${record%%$'\n'*}
  record=${record#*$'\n'}
  identity=${record%%$'\n'*}
  current=$(process_identity "$pid") || return 1
  [ -n "$current" ] && [ "$current" = "$identity" ]
}

OWNER_TOKEN=
acquire_owner() {
  local attempt stale identity token
  mkdir -p "$STACK_ROOT" || return 1
  [ -d "$STACK_ROOT" ] && [ ! -L "$STACK_ROOT" ] || return 1
  for attempt in $(seq 1 40); do
    token="$$.$RANDOM.$attempt"
    if mkdir "$OWNER" 2>/dev/null; then
      chmod 700 "$OWNER" || return 1
      identity=$(process_identity "$$") || return 1
      [ -n "$identity" ] || return 1
      printf '%s\n%s\n%s\n' "$$" "$identity" "$token" > "$OWNER/owner" || return 1
      chmod 600 "$OWNER/owner" || return 1
      OWNER_TOKEN=$token
      return 0
    fi
    [ -d "$OWNER" ] && [ ! -L "$OWNER" ] || return 1
    owner_alive && return 2
    [ "$(path_age "$OWNER" 2>/dev/null || echo 0)" -ge 2 ] || { sleep 0.05; continue; }
    stale="$STACK_ROOT/.retention-owner.stale.$$.$RANDOM"
    if mv "$OWNER" "$stale" 2>/dev/null; then
      rm -rf "$stale"
    fi
    sleep 0.05
  done
  return 1
}

release_owner() {
  local record token
  [ -n "$OWNER_TOKEN" ] || return 0
  record=$(read_owner 2>/dev/null) || return 0
  token=${record##*$'\n'}
  [ "$token" = "$OWNER_TOKEN" ] || return 0
  rm -rf "$OWNER"
}

run_owner() {
  local acquire_status output pending guard_ms
  acquire_owner
  acquire_status=$?
  [ "$acquire_status" -eq 0 ] || { [ "$acquire_status" -eq 2 ] && return 0; return 1; }
  trap 'release_owner; exit 0' HUP INT TERM
  trap release_owner EXIT
  guard_ms=$((INTERVAL * 2000))
  while :; do
    if output=$(FM_REPORT_RETENTION_GUARD_MS="$guard_ms" "$SCRIPT_DIR/fm-report-stack.mjs" prune --status 2>&1); then
      rm -f "$ERROR_FILE"
      case "$output" in *'"pending":true'*) pending=1 ;; *) pending=0 ;; esac
    else
      printf '%s\n' "$output" > "$ERROR_FILE"
      pending=0
    fi
    if [ "$pending" -eq 1 ]; then sleep "$PROGRESS_INTERVAL"; else sleep "$INTERVAL"; fi
  done
}

ensure_owner() {
  local attempt
  owner_alive && return 0
  perl -MPOSIX=setsid -e '
    my $pid = fork();
    exit 1 unless defined $pid;
    exit 0 if $pid;
    setsid() or exit 1;
    $pid = fork();
    exit 1 unless defined $pid;
    exit 0 if $pid;
    open STDIN, "<", "/dev/null" or exit 1;
    open STDOUT, ">", "/dev/null" or exit 1;
    open STDERR, ">", "/dev/null" or exit 1;
    exec @ARGV;
  ' "$SCRIPT_DIR/fm-report-retention.sh" run || return 1
  for attempt in $(seq 1 100); do
    owner_alive && return 0
    sleep 0.05
  done
  return 1
}

case "${1:-}" in
  ensure) ensure_owner ;;
  run) run_owner ;;
  *) echo "usage: fm-report-retention.sh ensure|run" >&2; exit 2 ;;
esac
