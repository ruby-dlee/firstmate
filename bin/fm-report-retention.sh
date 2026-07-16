#!/usr/bin/env bash
# Keep the machine-global completion report stack below its 30-day ceiling.
# Usage: fm-report-retention.sh ensure
#        fm-report-retention.sh install
#        fm-report-retention.sh run-once
#
# `install` copies a self-contained owner into a stable per-user location and
# activates a restart-capable macOS LaunchAgent.
# `ensure` validates the installed owner and its successful-prune heartbeat.
# `run-once` drains bounded deletion batches before returning.
# FM_REPORT_STACK_ROOT selects an isolated stack for tests.
# FM_REPORT_RETENTION_INTERVAL sets the LaunchAgent cadence (default 300).
# FM_REPORT_RETENTION_PROGRESS_INTERVAL sets the bounded-drain cadence (default 1).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent

STACK_ROOT="${FM_REPORT_STACK_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/firstmate/report-stack}"
INTERVAL=${FM_REPORT_RETENTION_INTERVAL:-300}
PROGRESS_INTERVAL=${FM_REPORT_RETENTION_PROGRESS_INTERVAL:-1}
LABEL=${FM_REPORT_RETENTION_LABEL:-com.firstmate.report-retention}
PLATFORM=${FM_REPORT_RETENTION_PLATFORM:-$(uname)}
INSTALL_ROOT=${FM_REPORT_RETENTION_INSTALL_ROOT:-$HOME/Library/Application Support/Firstmate/report-retention}
LAUNCH_AGENTS_DIR=${FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}
PLIST="$LAUNCH_AGENTS_DIR/$LABEL.plist"
LAUNCHCTL=${FM_REPORT_RETENTION_LAUNCHCTL:-launchctl}
HEARTBEAT="$STACK_ROOT/.retention-heartbeat"
ERROR_FILE="$STACK_ROOT/.retention-error"
SOURCE_FILES=(fm-report-retention.sh fm-report-stack.mjs fm-markdown-structure.cjs fm-contained-read.py fm-gate-refuse-lib.sh)

case "$INTERVAL" in ''|*[!0-9]*|0) echo "error: FM_REPORT_RETENTION_INTERVAL must be a positive integer" >&2; exit 2 ;; esac
case "$PROGRESS_INTERVAL" in ''|*[!0-9]*|0) echo "error: FM_REPORT_RETENTION_PROGRESS_INTERVAL must be a positive integer" >&2; exit 2 ;; esac
[ "$INTERVAL" -lt 1296000 ] || { echo "error: FM_REPORT_RETENTION_INTERVAL must be below 15 days" >&2; exit 2; }
[ "$PROGRESS_INTERVAL" -le "$INTERVAL" ] || { echo "error: FM_REPORT_RETENTION_PROGRESS_INTERVAL must not exceed the owner interval" >&2; exit 2; }

provenance() {
  local directory=$1 file
  for file in "${SOURCE_FILES[@]}"; do
    [ -f "$directory/$file" ] && [ ! -L "$directory/$file" ] || return 1
  done
  if command -v shasum >/dev/null 2>&1; then
    for file in "${SOURCE_FILES[@]}"; do shasum -a 256 "$directory/$file"; done \
      | awk '{print $1}' | shasum -a 256 | awk '{print $1}'
  else
    for file in "${SOURCE_FILES[@]}"; do cksum "$directory/$file"; done \
      | awk '{print $1":"$2}' | cksum | awk '{print $1":"$2}'
  fi
}

xml_escape() {
  printf '%s' "$1" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g;s/"/\&quot;/g;s/'"'"'/\&apos;/g'
}

write_heartbeat() {
  local provenance_value=$1 temp
  mkdir -p "$STACK_ROOT" || return 1
  temp=$(mktemp "$STACK_ROOT/.retention-heartbeat.XXXXXX") || return 1
  printf '%s\n%s\n' "$(date +%s)" "$provenance_value" > "$temp" || { rm -f "$temp"; return 1; }
  chmod 600 "$temp" || { rm -f "$temp"; return 1; }
  mv "$temp" "$HEARTBEAT"
}

run_once() {
  local output pending guard_ms provenance_value
  provenance_value=$(provenance "$SCRIPT_DIR") || { echo "error: retention owner bundle is incomplete" >&2; return 1; }
  guard_ms=$((INTERVAL * 2000))
  while :; do
    if output=$(FM_REPORT_RETENTION_GUARD_MS="$guard_ms" "$SCRIPT_DIR/fm-report-stack.mjs" prune --status 2>&1); then
      rm -f "$ERROR_FILE"
      write_heartbeat "$provenance_value" || return 1
      case "$output" in *'"pending":true'*) pending=1 ;; *) pending=0 ;; esac
    else
      mkdir -p "$STACK_ROOT" || return 1
      printf '%s\n' "$output" > "$ERROR_FILE"
      return 1
    fi
    [ "$pending" -eq 1 ] || return 0
    sleep "$PROGRESS_INTERVAL"
  done
}

install_owner() {
  local bundle="$INSTALL_ROOT/bin" staging plist_temp file source_provenance installed_provenance domain
  [ "$PLATFORM" = Darwin ] || { echo "error: report-retention LaunchAgent installation requires macOS" >&2; return 1; }
  command -v "$LAUNCHCTL" >/dev/null 2>&1 || { echo "error: launchctl is unavailable" >&2; return 1; }
  mkdir -p "$INSTALL_ROOT" "$LAUNCH_AGENTS_DIR" || return 1
  staging=$(mktemp -d "$INSTALL_ROOT/.bin.XXXXXX") || return 1
  plist_temp=$(mktemp "$LAUNCH_AGENTS_DIR/.$LABEL.XXXXXX") || { rm -rf "$staging"; return 1; }
  for file in "${SOURCE_FILES[@]}"; do
    cp "$SCRIPT_DIR/$file" "$staging/$file" || { rm -rf "$staging" "$plist_temp"; return 1; }
  done
  chmod 700 "$staging/fm-report-retention.sh" "$staging/fm-report-stack.mjs" "$staging/fm-contained-read.py" || {
    rm -rf "$staging" "$plist_temp"
    return 1
  }
  source_provenance=$(provenance "$SCRIPT_DIR") || { rm -rf "$staging" "$plist_temp"; return 1; }
  installed_provenance=$(provenance "$staging") || { rm -rf "$staging" "$plist_temp"; return 1; }
  [ "$source_provenance" = "$installed_provenance" ] || { rm -rf "$staging" "$plist_temp"; return 1; }
  rm -rf "$bundle.previous"
  [ ! -e "$bundle" ] || mv "$bundle" "$bundle.previous" || { rm -rf "$staging" "$plist_temp"; return 1; }
  mv "$staging" "$bundle" || {
    [ ! -e "$bundle.previous" ] || mv "$bundle.previous" "$bundle"
    rm -f "$plist_temp"
    return 1
  }
  cat > "$plist_temp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$(xml_escape "$LABEL")</string>
<key>ProgramArguments</key>
<array>
<string>$(xml_escape "$bundle/fm-report-retention.sh")</string>
<string>run-once</string>
</array>
<key>EnvironmentVariables</key><dict>
<key>FM_REPORT_STACK_ROOT</key><string>$(xml_escape "$STACK_ROOT")</string>
<key>FM_REPORT_RETENTION_INTERVAL</key><string>$(xml_escape "$INTERVAL")</string>
<key>FM_REPORT_RETENTION_PROGRESS_INTERVAL</key><string>$(xml_escape "$PROGRESS_INTERVAL")</string>
</dict>
<key>RunAtLoad</key><true/>
<key>StartInterval</key><integer>$INTERVAL</integer>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict></plist>
EOF
  chmod 600 "$plist_temp" || return 1
  mv "$plist_temp" "$PLIST" || return 1
  rm -rf "$bundle.previous"
  domain="gui/$(id -u)"
  "$LAUNCHCTL" bootout "$domain/$LABEL" >/dev/null 2>&1 || true
  "$LAUNCHCTL" bootstrap "$domain" "$PLIST" || return 1
  "$LAUNCHCTL" kickstart "$domain/$LABEL" || return 1
}

ensure_owner() {
  local now heartbeat_epoch heartbeat_provenance installed_provenance source_provenance max_age domain plist_program
  [ "$PLATFORM" = Darwin ] || { echo "error: report-retention LaunchAgent requires macOS" >&2; return 1; }
  [ -f "$PLIST" ] && [ ! -L "$PLIST" ] \
    || { echo "error: report-retention LaunchAgent is not installed; run bin/fm-bootstrap.sh install report-retention after captain approval" >&2; return 1; }
  plist_program=$(sed -n '/<key>ProgramArguments<\/key>/,/<\/array>/s/.*<string>\([^<]*\)<\/string>.*/\1/p' "$PLIST" | head -1)
  [ "$plist_program" = "$INSTALL_ROOT/bin/fm-report-retention.sh" ] \
    || { echo "error: report-retention LaunchAgent provenance is invalid" >&2; return 1; }
  installed_provenance=$(provenance "$INSTALL_ROOT/bin") \
    || { echo "error: installed report-retention owner is incomplete" >&2; return 1; }
  source_provenance=$(provenance "$SCRIPT_DIR") \
    || { echo "error: current report-retention source is incomplete" >&2; return 1; }
  [ "$installed_provenance" = "$source_provenance" ] \
    || { echo "error: installed report-retention owner is stale; rerun bin/fm-bootstrap.sh install report-retention after captain approval" >&2; return 1; }
  domain="gui/$(id -u)"
  "$LAUNCHCTL" print "$domain/$LABEL" >/dev/null 2>&1 \
    || { echo "error: report-retention LaunchAgent is not loaded" >&2; return 1; }
  [ -f "$HEARTBEAT" ] && [ ! -L "$HEARTBEAT" ] \
    || { echo "error: report-retention owner has no successful-prune heartbeat" >&2; return 1; }
  heartbeat_epoch=$(sed -n '1p' "$HEARTBEAT" 2>/dev/null)
  heartbeat_provenance=$(sed -n '2p' "$HEARTBEAT" 2>/dev/null)
  case "$heartbeat_epoch" in ''|*[!0-9]*) echo "error: report-retention heartbeat is invalid" >&2; return 1 ;; esac
  [ "$heartbeat_provenance" = "$installed_provenance" ] \
    || { echo "error: report-retention heartbeat provenance is stale" >&2; return 1; }
  now=$(date +%s)
  max_age=$((INTERVAL * 2 + 60))
  [ "$((now - heartbeat_epoch))" -le "$max_age" ] \
    || { echo "error: report-retention successful-prune heartbeat is stale" >&2; return 1; }
}

case "${1:-}" in
  ensure) ensure_owner ;;
  install) install_owner ;;
  run-once) run_once ;;
  *) echo "usage: fm-report-retention.sh ensure|install|run-once" >&2; exit 2 ;;
esac
