#!/usr/bin/env bash
# Deterministic before/after bridge for Claude Code context compaction.
#
# The tracked .claude/settings.json invokes `capture` from PreCompact and
# `recover` from SessionStart with matcher `compact`.
# Capture atomically replaces data/autocompact-resume.md with a fresh local-only
# view of durable fleet state before either manual or automatic compaction.
# Recover prints that anchor and a fresh fm-session-start.sh digest to stdout,
# which Claude Code injects into the compacted context before the next model
# request.
#
# This script intentionally does not run /stow.
# A shell hook cannot make the model judge conversation-only knowledge, so the
# stow skill remains the one owner of that routing and must run periodically in
# long Claude sessions before compaction pressure becomes acute.
#
# The hook is inert outside a primary firstmate checkout.
# A plain main home is confirmed by equal git-dir and git-common-dir paths.
# A treehouse-leased secondmate home is also a primary when its validated
# .fm-secondmate-home marker names that exact FM_HOME.
# Unmarked linked worktrees are crewmate/scout worktrees and exit silently.
#
# Capture failures in an in-scope primary exit 2 so Claude blocks the
# compaction instead of silently crossing the boundary without a fresh anchor.
# Recovery is best-effort after the boundary: it always emits whatever durable
# context is available and reports a session-start failure inside that context.
#
# Usage:
#   <PreCompact JSON | bin/fm-autocompact.sh capture
#   <SessionStart JSON | bin/fm-autocompact.sh recover
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
ANCHOR=$DATA/autocompact-resume.md
MODE=${1:-}

usage() {
  cat <<'EOF'
usage: fm-autocompact.sh capture|recover

Reads a Claude Code hook payload from stdin.
capture accepts PreCompact payloads and atomically writes the durable resume anchor.
recover accepts SessionStart source=compact payloads and prints the anchor plus a fresh session-start digest.
The script is a silent no-op outside a primary firstmate checkout.
EOF
}

case "$MODE" in
  capture|recover) ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

EVENT=$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // empty' 2>/dev/null) || exit 0
if [ "$MODE" = capture ]; then
  [ "$EVENT" = PreCompact ] || exit 0
else
  SOURCE=$(printf '%s' "$PAYLOAD" | jq -r '.source // empty' 2>/dev/null) || exit 0
  [ "$EVENT" = SessionStart ] && [ "$SOURCE" = compact ] || exit 0
fi

root_is_secondmate_home() {
  local marker=$1/.fm-secondmate-home id root_real home_real LC_ALL=C
  root_real=$(CDPATH='' cd -- "$1" 2>/dev/null && pwd -P) || return 1
  home_real=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || return 1
  [ "$home_real" = "$root_real" ] || return 1
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1
  IFS= read -r id < "$marker" 2>/dev/null || return 1
  id=${id//[[:space:]]/}
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

in_primary_scope() {
  local git_dir git_common_dir
  [ -f "$FM_ROOT/AGENTS.md" ] || return 1
  [ -d "$FM_ROOT/bin" ] || return 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  root_is_secondmate_home "$FM_ROOT" && return 0
  command -v git >/dev/null 2>&1 || return 1
  git_dir=$(git -C "$FM_ROOT" rev-parse --git-dir 2>/dev/null) || return 1
  git_common_dir=$(git -C "$FM_ROOT" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ "$git_dir" = "$git_common_dir" ]
}

in_primary_scope || exit 0

capture_failed() {
  local message=$1
  printf 'FIRSTMATE AUTOCOMPACT CAPTURE FAILED: %s\n' "$message" >&2
  exit 2
}

capture_anchor() {
  local trigger session_id transcript generated snapshot tmp meta id
  trigger=$(printf '%s' "$PAYLOAD" | jq -r '.trigger // empty' 2>/dev/null) \
    || capture_failed 'invalid PreCompact payload'
  case "$trigger" in
    auto|manual) ;;
    *) capture_failed 'PreCompact payload has no recognized trigger' ;;
  esac
  session_id=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // "unknown"' 2>/dev/null) \
    || capture_failed 'invalid session id'
  transcript=$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // "unknown"' 2>/dev/null) \
    || capture_failed 'invalid transcript path'
  generated=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
    || capture_failed 'could not read the clock'

  snapshot=$(
    FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_HOME="$FM_HOME" \
      FM_STATE_OVERRIDE="$STATE" \
      FM_DATA_OVERRIDE="$DATA" \
      "$SCRIPT_DIR/fm-bearings-snapshot.sh" \
        --all-in-flight \
        --all-decisions \
        --all-landed \
        --all-reports \
        --all-queued \
        --all-recorded-prs \
        --all-unhealthy \
        --fields bodies,paths,actions,endpoints
  ) || capture_failed 'the deterministic fleet snapshot failed'

  if [ -L "$DATA" ] || { [ -e "$DATA" ] && [ ! -d "$DATA" ]; }; then
    capture_failed "unsafe data directory at $DATA"
  fi
  mkdir -p "$DATA" || capture_failed "could not create data directory at $DATA"
  [ -d "$DATA" ] && [ ! -L "$DATA" ] \
    || capture_failed "unsafe data directory at $DATA"
  if [ -L "$ANCHOR" ] || { [ -e "$ANCHOR" ] && [ ! -f "$ANCHOR" ]; }; then
    capture_failed "unsafe resume anchor at $ANCHOR"
  fi

  umask 077
  tmp=$(mktemp "$DATA/.autocompact-resume.md.XXXXXX") \
    || capture_failed 'could not allocate a temporary anchor'
  {
    printf '# Autocompact resume anchor\n\n'
    printf "Generated: \`%s\`\n" "$generated"
    printf "Trigger: \`%s\`\n" "$trigger"
    printf "Session: \`%s\`\n" "$session_id"
    printf "Transcript: \`%s\`\n\n" "$transcript"
    printf 'This file is the deterministic bridge across Claude Code context compaction.\n'
    printf "It captures durable file state only and does not replace the judgment-based \`stow\` skill.\n"
    printf "The compact-sourced SessionStart hook prints this anchor and then runs \`bin/fm-session-start.sh\` for normal lock, wake, backlog, task, and endpoint reconciliation.\n\n"
    printf '## Fleet pickup snapshot\n\n'
    printf '%s\n' "$snapshot" | sed 's/^/    /'
    printf '\n## Backlog at capture\n\n'
    if [ -f "$DATA/backlog.md" ] && [ ! -L "$DATA/backlog.md" ]; then
      sed 's/^/    /' "$DATA/backlog.md"
    else
      printf '    (absent)\n'
    fi
    printf '\n## In-flight metadata at capture\n'
    meta_found=0
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      meta_found=1
      id=$(basename "$meta" .meta)
      printf '\n### %s\n\n' "$id"
      sed 's/^/    /' "$meta"
    done
    [ "$meta_found" -eq 1 ] || printf '\n(none)\n'
  } > "$tmp" || {
    rm -f "$tmp"
    capture_failed 'could not render the resume anchor'
  }
  mv -f "$tmp" "$ANCHOR" || {
    rm -f "$tmp"
    capture_failed 'could not publish the resume anchor atomically'
  }
}

recover_context() {
  local digest digest_rc
  digest=$(
    FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_HOME="$FM_HOME" \
      FM_STATE_OVERRIDE="$STATE" \
      FM_DATA_OVERRIDE="$DATA" \
      "$SCRIPT_DIR/fm-session-start.sh" 2>&1
  )
  digest_rc=$?

  printf '%s\n' 'FIRSTMATE AUTOCOMPACT RECOVERY CONTEXT'
  printf '%s\n' 'Treat the fresh durable anchor and session-start digest below as authoritative over the lossy compaction summary.'
  printf '%s\n' 'Resume the in-flight work directly after reconciling the drained wake queue and live endpoints.'
  printf '\n=== FRESH RESUME ANCHOR: %s ===\n' "$ANCHOR"
  if [ -f "$ANCHOR" ] && [ ! -L "$ANCHOR" ]; then
    cat "$ANCHOR"
  else
    printf '%s\n' 'MISSING - PreCompact did not leave a readable anchor; rely on the session-start digest and surface the capture failure.'
  fi
  printf '\n=== NORMAL SESSION-START RECONCILIATION ===\n'
  printf '%s\n' "$digest"
  if [ "$digest_rc" -ne 0 ]; then
    printf '\nSESSION-START RECONCILIATION FAILED WITH EXIT %s.\n' "$digest_rc"
    printf '%s\n' 'Surface the failure and do not infer current fleet state from the compaction summary.'
  fi
}

if [ "$MODE" = capture ]; then
  capture_anchor
else
  recover_context
fi
