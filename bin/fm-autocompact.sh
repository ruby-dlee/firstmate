#!/usr/bin/env bash
# Deterministic before/after bridge for Claude Code context compaction.
#
# The tracked .claude/settings.json invokes `capture` from PreCompact and
# `recover` from SessionStart with matcher `compact`.
# Capture atomically replaces data/autocompact-resume.md with a fresh local-only
# view of durable fleet state before either manual or automatic compaction.
# Recover prints that anchor, a scoped stow directive, and a fresh
# fm-session-start.sh digest to stdout, which Claude Code injects into the
# compacted context before the next model request.
#
# This script intentionally does not run /stow.
# A shell hook cannot make the model judge conversation-only knowledge, so the
# recovery directive tells the resumed model to load the stow skill and inspect
# the unswept pre-compact transcript slice.
# After a successful sweep, the model runs `mark-stowed` to atomically advance
# the durable byte marker; an incomplete sweep therefore remains pending.
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
#   bin/fm-autocompact.sh mark-stowed <transcript> <end> <absent|present> [<prior-transcript> <prior-end>]
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
ANCHOR=$DATA/autocompact-resume.md
STOW_MARKER=$STATE/.autocompact-stow.marker
STOW_LOCK=$STATE/.autocompact-stow.lock
MODE=${1:-}

usage() {
  cat <<'EOF'
usage: fm-autocompact.sh capture|recover|mark-stowed

Reads a Claude Code hook payload from stdin.
capture accepts PreCompact payloads and atomically writes the durable resume anchor.
recover accepts SessionStart source=compact payloads and prints the anchor plus a fresh session-start digest.
mark-stowed atomically records the exact recovery directive's transcript slice as swept successfully.
The script is a silent no-op outside a primary firstmate checkout.
EOF
}

case "$MODE" in
  capture|recover|mark-stowed) ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

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

file_size_bytes() {
  local path=$1 bytes
  [ -f "$path" ] && [ -r "$path" ] || return 1
  bytes=$(LC_ALL=C wc -c < "$path" 2>/dev/null) || return 1
  bytes=${bytes//[[:space:]]/}
  case "$bytes" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$bytes"
}

anchor_field() {
  local field=$1
  [ -f "$ANCHOR" ] && [ ! -L "$ANCHOR" ] || return 1
  awk -v field="$field" '
    BEGIN {
      prefix = field ": `"
      count = 0
    }
    index($0, prefix) == 1 {
      value = substr($0, length(prefix) + 1)
      if (substr(value, length(value), 1) != "`") {
        exit 2
      }
      value = substr(value, 1, length(value) - 1)
      count++
    }
    END {
      if (count != 1) {
        exit 1
      }
      printf "%s", value
    }
  ' "$ANCHOR" 2>/dev/null
}

marker_field() {
  local field=$1
  [ -f "$STOW_MARKER" ] && [ ! -L "$STOW_MARKER" ] || return 1
  awk -v field="$field" '
    BEGIN {
      prefix = field "="
      count = 0
    }
    index($0, prefix) == 1 {
      value = substr($0, length(prefix) + 1)
      count++
    }
    END {
      if (count != 1) {
        exit 1
      }
      printf "%s", value
    }
  ' "$STOW_MARKER" 2>/dev/null
}

decimal_compare() {
  local left=$1 right=$2 LC_ALL=C
  case "$left:$right" in
    *[!0-9:]*) return 1 ;;
  esac
  while [ "${left#0}" != "$left" ]; do
    left=${left#0}
  done
  while [ "${right#0}" != "$right" ]; do
    right=${right#0}
  done
  [ -n "$left" ] || left=0
  [ -n "$right" ] || right=0
  if [ "${#left}" -gt "${#right}" ]; then
    printf '%s\n' 1
  elif [ "${#left}" -lt "${#right}" ]; then
    printf '%s\n' -1
  elif [ "$left" = "$right" ]; then
    printf '%s\n' 0
  elif awk -v left="x$left" -v right="x$right" 'BEGIN { exit !(left > right) }'; then
    printf '%s\n' 1
  else
    printf '%s\n' -1
  fi
}

acquire_stow_lock() {
  if [ -d "$STOW_LOCK" ] && [ ! -L "$STOW_LOCK" ]; then
    rmdir "$STOW_LOCK" 2>/dev/null || return 1
  fi
  command -v python3 >/dev/null 2>&1 || return 1
  umask 077
  python3 -c '
import os
import stat
import sys

flags = os.O_RDWR | os.O_CREAT
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
fd = os.open(sys.argv[1], flags, 0o600)
try:
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        raise RuntimeError("lock is not a regular file")
finally:
    os.close(fd)
' "$STOW_LOCK" 2>/dev/null || return 1
  exec 9<> "$STOW_LOCK" || return 1
  python3 -c '
import fcntl
import os
import stat
import sys

held = os.fstat(9)
named = os.lstat(sys.argv[1])
if not stat.S_ISREG(held.st_mode) or not stat.S_ISREG(named.st_mode):
    raise RuntimeError("lock is not a regular file")
if (held.st_dev, held.st_ino) != (named.st_dev, named.st_ino):
    raise RuntimeError("lock pathname changed before acquisition")
fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
confirmed = os.lstat(sys.argv[1])
if (held.st_dev, held.st_ino) != (confirmed.st_dev, confirmed.st_ino):
    raise RuntimeError("lock pathname changed during acquisition")
' "$STOW_LOCK" 2>/dev/null || { exec 9>&-; return 1; }
}

release_stow_lock() {
  { exec 9>&-; } 2>/dev/null || true
}

shell_quote() {
  printf '%q' "$1"
}

capture_failed() {
  local message=$1
  printf 'FIRSTMATE AUTOCOMPACT CAPTURE FAILED: %s\n' "$message" >&2
  exit 2
}

json_string_field() {
  local field=$1 payload=$2
  awk -v want="$field" '
    function invalid() {
      exit 2
    }
    function decode(start, i, c, escaped, hex, out) {
      if (substr(input, start, 1) != "\"") {
        invalid()
      }
      out = ""
      for (i = start + 1; i <= length(input); i++) {
        c = substr(input, i, 1)
        if (c == "\"") {
          value = out
          return
        }
        if (c != "\\") {
          if (c ~ /[[:cntrl:]]/) {
            invalid()
          }
          out = out c
          continue
        }
        i++
        if (i > length(input)) {
          invalid()
        }
        escaped = substr(input, i, 1)
        if (escaped == "\"" || escaped == "\\" || escaped == "/") {
          out = out escaped
        } else if (escaped == "b") {
          out = out sprintf("%c", 8)
        } else if (escaped == "f") {
          out = out sprintf("%c", 12)
        } else if (escaped == "n") {
          out = out "\n"
        } else if (escaped == "r") {
          out = out "\r"
        } else if (escaped == "t") {
          out = out "\t"
        } else if (escaped == "u") {
          hex = substr(input, i + 1, 4)
          if (hex !~ /^[[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]]$/) {
            invalid()
          }
          out = out "\\u" hex
          i += 4
        } else {
          invalid()
        }
      }
      invalid()
    }
    {
      input = input (NR == 1 ? "" : "\n") $0
    }
    END {
      needle = "\"" want "\""
      pos = 1
      while (pos <= length(input)) {
        relative = index(substr(input, pos), needle)
        if (relative == 0) {
          exit 1
        }
        key = pos + relative - 1
        cursor = key + length(needle)
        while (substr(input, cursor, 1) ~ /[[:space:]]/) {
          cursor++
        }
        if (substr(input, cursor, 1) != ":") {
          pos = key + length(needle)
          continue
        }
        cursor++
        while (substr(input, cursor, 1) ~ /[[:space:]]/) {
          cursor++
        }
        if (substr(input, cursor, 4) == "null") {
          exit 1
        }
        decode(cursor)
        printf "%s", value
        exit 0
      }
      exit 1
    }
  ' <<< "$payload"
}

PAYLOAD=
RECOVERY_WARNING=
if [ "$MODE" != mark-stowed ]; then
  if ! PAYLOAD=$(cat 2>/dev/null); then
    if [ "$MODE" = capture ]; then
      capture_failed 'could not read the PreCompact payload'
    fi
    RECOVERY_WARNING='could not read the compact SessionStart payload; recovering from durable state'
  fi
fi

if [ "$MODE" = capture ]; then
  [ -n "$PAYLOAD" ] || capture_failed 'the PreCompact payload was empty'
  EVENT=$(json_string_field hook_event_name "$PAYLOAD") \
    || capture_failed 'invalid PreCompact payload'
  [ "$EVENT" = PreCompact ] || exit 0
elif [ "$MODE" = recover ]; then
  if [ -n "$RECOVERY_WARNING" ]; then
    :
  elif [ -z "$PAYLOAD" ]; then
    RECOVERY_WARNING='the compact SessionStart payload was empty; recovering from durable state'
  elif ! EVENT=$(json_string_field hook_event_name "$PAYLOAD"); then
    RECOVERY_WARNING='the compact SessionStart payload was malformed or missing its event name; recovering from durable state'
  elif [ "$EVENT" != SessionStart ]; then
    RECOVERY_WARNING="the recovery hook received unexpected event $EVENT; recovering from durable state"
  elif ! SOURCE=$(json_string_field source "$PAYLOAD"); then
    RECOVERY_WARNING='the SessionStart payload was malformed or missing its source; recovering from durable state'
  elif [ "$SOURCE" != compact ]; then
    exit 0
  fi
fi

render_anchor() {
  local meta id meta_found=0
  printf '# Autocompact resume anchor\n\n' || return 1
  printf "Generated: \`%s\`\n" "$generated" || return 1
  printf "Trigger: \`%s\`\n" "$trigger" || return 1
  printf "Session: \`%s\`\n" "$session_id" || return 1
  printf "Transcript: \`%s\`\n" "$transcript" || return 1
  printf "Transcript end byte: \`%s\`\n\n" "$transcript_end" || return 1
  printf 'This file is the deterministic bridge across Claude Code context compaction.\n' || return 1
  printf "It captures durable file state only and does not replace the judgment-based \`stow\` skill.\n" || return 1
  printf "The compact-sourced SessionStart hook prints this anchor and then runs \`bin/fm-session-start.sh\` for normal lock, wake, backlog, task, and endpoint reconciliation.\n\n" || return 1
  printf '## Fleet pickup snapshot\n\n' || return 1
  printf '    %s\n' "${snapshot//$'\n'/$'\n    '}" || return 1
  printf '\n## Backlog at capture\n\n' || return 1
  if [ -f "$DATA/backlog.md" ] && [ ! -L "$DATA/backlog.md" ]; then
    sed 's/^/    /' "$DATA/backlog.md" || return 1
  else
    printf '    (absent)\n' || return 1
  fi
  printf '\n## In-flight metadata at capture\n' || return 1
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    meta_found=1
    id=${meta##*/}
    id=${id%.meta}
    printf '\n### %s\n\n' "$id" || return 1
    sed 's/^/    /' "$meta" || return 1
  done
  [ "$meta_found" -eq 1 ] || printf '\n(none)\n' || return 1
}

capture_anchor() {
  local trigger session_id transcript transcript_end generated snapshot tmp
  trigger=$(json_string_field trigger "$PAYLOAD") \
    || capture_failed 'invalid PreCompact payload'
  case "$trigger" in
    auto|manual) ;;
    *) capture_failed 'PreCompact payload has no recognized trigger' ;;
  esac
  session_id=$(json_string_field session_id "$PAYLOAD") || session_id=unknown
  transcript=$(json_string_field transcript_path "$PAYLOAD") || transcript=unknown
  transcript_end=$(file_size_bytes "$transcript") || transcript_end=unknown
  generated=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
    || capture_failed 'could not read the clock'

  if command -v jq >/dev/null 2>&1; then
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
  else
    snapshot='LIMITED - jq is unavailable; the complete raw backlog and in-flight metadata below remain authoritative.'
    printf '%s\n' 'FIRSTMATE AUTOCOMPACT CAPTURE LIMITED: jq is unavailable; capturing raw durable state without the bearings projection.' >&2 \
      || capture_failed 'could not report the limited capture'
  fi

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
  render_anchor > "$tmp" || {
    rm -f "$tmp" || capture_failed 'could not clean the incomplete temporary anchor'
    capture_failed 'could not render the resume anchor'
  }
  acquire_stow_lock || {
    rm -f "$tmp"
    capture_failed 'could not lock the resume anchor for publication'
  }
  if [ -L "$ANCHOR" ] || { [ -e "$ANCHOR" ] && [ ! -f "$ANCHOR" ]; }; then
    release_stow_lock
    rm -f "$tmp"
    capture_failed "unsafe resume anchor at $ANCHOR"
  fi
  mv -f "$tmp" "$ANCHOR" || {
    release_stow_lock
    rm -f "$tmp" || capture_failed 'could not clean the unpublished temporary anchor'
    capture_failed 'could not publish the resume anchor atomically'
  }
  release_stow_lock
}

emit_whole_context_stow_directive() {
  local reason=$1 transcript=${2:-unknown} transcript_end=${3:-unknown} expected_marker=${4:-unusable}
  printf '\n=== REQUIRED POST-COMPACTION STOW SWEEP ===\n'
  printf '%s\n' 'ACTION REQUIRED: Before resuming ordinary work, load the stow skill and sweep the whole recovered context for conversation-only durable knowledge.'
  printf 'Reason for full sweep: %s\n' "$reason"
  if [ "$transcript" != unknown ]; then
    printf 'Pre-compact transcript: %s\n' "$transcript"
  fi
  if [ "$transcript_end" != unknown ]; then
    printf 'Captured boundary: zero-based byte offset 0 inclusive through %s exclusive.\n' "$transcript_end"
  fi
  printf '%s\n' 'Read the available pre-compact transcript through that boundary as part of the sweep; do not rely on the lossy compaction summary.'
  printf 'Use %s as the single owner of routing destinations; do not recreate its routing table here.\n' "$FM_ROOT/.agents/skills/stow/SKILL.md"
  printf 'Completion marker: %s\n' "$STOW_MARKER"
  if [ "$transcript" != unknown ] && [ "$transcript_end" != unknown ] && [ "$expected_marker" = absent ]; then
    printf 'Only after the sweep and every authorized stow write complete, run '
    shell_quote "$SCRIPT_DIR/fm-autocompact.sh"
    printf ' mark-stowed '
    shell_quote "$transcript"
    printf ' %s absent to atomically record completion through this boundary.\n' "$transcript_end"
  else
    printf '%s\n' 'The transcript boundary is not readable enough to mark complete; leave the marker unchanged so a later recovery retries the sweep.'
  fi
}

emit_scoped_stow_directive() {
  local transcript=$1 start=$2 transcript_end=$3
  printf '\n=== REQUIRED POST-COMPACTION STOW SWEEP ===\n'
  printf '%s\n' 'ACTION REQUIRED: Before resuming ordinary work, load the stow skill and sweep the unswept pre-compact conversation slice.'
  printf 'Pre-compact transcript: %s\n' "$transcript"
  printf 'Read zero-based byte offset %s inclusive through %s exclusive; the completion marker already covers every earlier byte.\n' "$start" "$transcript_end"
  printf '%s\n' 'Judge durable conversation-only knowledge from that transcript slice and the recovered context, not from the lossy compaction summary.'
  printf 'Use %s as the single owner of routing destinations; do not recreate its routing table here.\n' "$FM_ROOT/.agents/skills/stow/SKILL.md"
  printf 'Completion marker: %s\n' "$STOW_MARKER"
  printf 'Only after the sweep and every authorized stow write complete, run '
  shell_quote "$SCRIPT_DIR/fm-autocompact.sh"
  printf ' mark-stowed '
  shell_quote "$transcript"
  printf ' %s present ' "$transcript_end"
  shell_quote "$transcript"
  printf ' %s to atomically record completion through byte %s.\n' "$start" "$transcript_end"
}

emit_stow_directive() {
  local transcript transcript_end current_end marker_transcript marker_end comparison
  if ! transcript=$(anchor_field Transcript); then
    emit_whole_context_stow_directive 'the fresh anchor has no readable transcript path'
    return 0
  fi
  if ! transcript_end=$(anchor_field 'Transcript end byte'); then
    emit_whole_context_stow_directive 'the fresh anchor has no valid transcript boundary' "$transcript"
    return 0
  fi
  case "$transcript_end" in
    ''|*[!0-9]*)
      emit_whole_context_stow_directive 'the fresh anchor transcript boundary is malformed' "$transcript"
      return 0
      ;;
  esac
  if ! current_end=$(file_size_bytes "$transcript"); then
    emit_whole_context_stow_directive 'the pre-compact transcript is unreadable' "$transcript"
    return 0
  fi
  if [ "$current_end" -lt "$transcript_end" ]; then
    emit_whole_context_stow_directive 'the pre-compact transcript is shorter than its captured boundary' "$transcript"
    return 0
  fi
  if ! marker_transcript=$(marker_field transcript_path) \
    || ! marker_end=$(marker_field completed_bytes); then
    if [ ! -e "$STOW_MARKER" ] && [ ! -L "$STOW_MARKER" ]; then
      emit_whole_context_stow_directive 'the completion marker is missing' "$transcript" "$transcript_end" absent
    else
      emit_whole_context_stow_directive 'the completion marker is malformed' "$transcript" "$transcript_end"
    fi
    return 0
  fi
  case "$marker_end" in
    ''|*[!0-9]*)
      emit_whole_context_stow_directive 'the completion marker offset is malformed' "$transcript" "$transcript_end"
      return 0
      ;;
  esac
  if [ "$marker_transcript" != "$transcript" ]; then
    emit_whole_context_stow_directive 'the completion marker does not describe this transcript boundary' "$transcript" "$transcript_end"
    return 0
  fi
  if ! comparison=$(decimal_compare "$marker_end" "$transcript_end"); then
    emit_whole_context_stow_directive 'the completion marker offset is malformed' "$transcript" "$transcript_end"
    return 0
  fi
  if [ "$comparison" -gt 0 ]; then
    emit_whole_context_stow_directive 'the completion marker offset exceeds the captured boundary' "$transcript" "$transcript_end"
    return 0
  fi
  if [ "$comparison" -eq 0 ]; then
    printf '\n=== POST-COMPACTION STOW SWEEP ===\n'
    printf 'NO STOW SWEEP PENDING: %s already records %s through byte %s; do not repeat the completed sweep.\n' \
      "$STOW_MARKER" "$transcript" "$transcript_end"
    return 0
  fi
  emit_scoped_stow_directive "$transcript" "$marker_end" "$transcript_end"
}

mark_stowed() {
  local transcript=${2:-} transcript_end=${3:-} expected_state=${4:-}
  local expected_transcript=${5:-} expected_end=${6:-} current_end marker_transcript marker_end tmp
  [ -n "$transcript" ] && [ -n "$transcript_end" ] || {
    printf '%s\n' 'FIRSTMATE AUTOCOMPACT STOW MARK FAILED: the recovery boundary arguments are required' >&2
    exit 2
  }
  case "$transcript_end" in
    ''|*[!0-9]*)
      printf '%s\n' 'FIRSTMATE AUTOCOMPACT STOW MARK FAILED: the fresh anchor transcript boundary is malformed' >&2
      exit 2
      ;;
  esac
  case "$expected_state" in
    absent) [ "$#" -eq 4 ] || exit 2 ;;
    present) [ "$#" -eq 6 ] || exit 2 ;;
    *) printf '%s\n' 'FIRSTMATE AUTOCOMPACT STOW MARK FAILED: the expected marker state is invalid' >&2; exit 2 ;;
  esac
  acquire_stow_lock || {
    printf '%s\n' 'FIRSTMATE AUTOCOMPACT STOW MARK FAILED: could not lock the recovery boundary' >&2
    exit 2
  }
  trap release_stow_lock EXIT
  [ "$(anchor_field Transcript 2>/dev/null)" = "$transcript" ] \
    && [ "$(anchor_field 'Transcript end byte' 2>/dev/null)" = "$transcript_end" ] || {
    printf '%s\n' 'FIRSTMATE AUTOCOMPACT STOW MARK FAILED: the recovery anchor changed during the sweep' >&2
    exit 2
  }
  if [ "$expected_state" = absent ]; then
    if [ -e "$STOW_MARKER" ] || [ -L "$STOW_MARKER" ]; then
      printf '%s\n' 'FIRSTMATE AUTOCOMPACT STOW MARK FAILED: the completion marker changed during the sweep' >&2
      exit 2
    fi
  else
    marker_transcript=$(marker_field transcript_path) \
      && marker_end=$(marker_field completed_bytes) \
      && [ "$marker_transcript" = "$expected_transcript" ] \
      && [ "$marker_end" = "$expected_end" ] || {
      printf '%s\n' 'FIRSTMATE AUTOCOMPACT STOW MARK FAILED: the completion marker changed during the sweep' >&2
      exit 2
    }
  fi
  current_end=$(file_size_bytes "$transcript") || {
    printf '%s\n' 'FIRSTMATE AUTOCOMPACT STOW MARK FAILED: the pre-compact transcript is unreadable' >&2
    exit 2
  }
  [ "$current_end" -ge "$transcript_end" ] || {
    printf '%s\n' 'FIRSTMATE AUTOCOMPACT STOW MARK FAILED: the pre-compact transcript is shorter than its captured boundary' >&2
    exit 2
  }
  if [ -L "$STOW_MARKER" ] || { [ -e "$STOW_MARKER" ] && [ ! -f "$STOW_MARKER" ]; }; then
    printf 'FIRSTMATE AUTOCOMPACT STOW MARK FAILED: unsafe completion marker at %s\n' "$STOW_MARKER" >&2
    exit 2
  fi
  umask 077
  tmp=$(mktemp "$STATE/.autocompact-stow.marker.XXXXXX") || {
    printf '%s\n' 'FIRSTMATE AUTOCOMPACT STOW MARK FAILED: could not allocate a temporary marker' >&2
    exit 2
  }
  printf 'transcript_path=%s\ncompleted_bytes=%s\n' "$transcript" "$transcript_end" > "$tmp" || {
    rm -f "$tmp"
    printf '%s\n' 'FIRSTMATE AUTOCOMPACT STOW MARK FAILED: could not render the completion marker' >&2
    exit 2
  }
  mv -f "$tmp" "$STOW_MARKER" || {
    rm -f "$tmp"
    printf '%s\n' 'FIRSTMATE AUTOCOMPACT STOW MARK FAILED: could not publish the completion marker atomically' >&2
    exit 2
  }
  trap - EXIT
  release_stow_lock
  printf 'FIRSTMATE AUTOCOMPACT STOW MARKER ADVANCED: %s through byte %s.\n' "$transcript" "$transcript_end"
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
  if [ -n "$RECOVERY_WARNING" ]; then
    printf 'FIRSTMATE AUTOCOMPACT RECOVERY WARNING: %s\n' "$RECOVERY_WARNING"
  fi
  printf '%s\n' 'Treat the fresh durable anchor and session-start digest below as authoritative over the lossy compaction summary.'
  printf '%s\n' 'Resume the in-flight work directly after reconciling the drained wake queue and live endpoints.'
  emit_stow_directive
  printf '\n=== FRESH RESUME ANCHOR: %s ===\n' "$ANCHOR"
  if [ -f "$ANCHOR" ] && [ ! -L "$ANCHOR" ]; then
    cat "$ANCHOR" || printf '%s\n' 'UNREADABLE - the resume anchor could not be read; rely on the session-start digest and surface the read failure.'
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

case "$MODE" in
  capture) capture_anchor ;;
  recover) recover_context ;;
  mark-stowed) mark_stowed "$@" ;;
esac
