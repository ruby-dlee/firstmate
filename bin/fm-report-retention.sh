#!/usr/bin/env bash
# Keep the machine-global completion report stack below its 30-day ceiling.
# Usage: fm-report-retention.sh ensure
#        fm-report-retention.sh install
#        fm-report-retention.sh run-once
#
# Installation publishes immutable, self-contained generations, then atomically
# replaces the LaunchAgent plist that points at one complete generation.
# The previously runnable generation remains in place until the replacement has
# completed a successful prune and heartbeat.
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
GENERATIONS="$INSTALL_ROOT/generations"
LAUNCH_AGENTS_DIR=${FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}
PLIST="$LAUNCH_AGENTS_DIR/$LABEL.plist"
LAUNCHCTL=${FM_REPORT_RETENTION_LAUNCHCTL:-launchctl}
HEARTBEAT="$STACK_ROOT/.retention-heartbeat"
ERROR_FILE="$STACK_ROOT/.retention-error"
INSTALL_LOCK="$INSTALL_ROOT/.install-lock"
INSTALL_RECLAIM="$INSTALL_ROOT/.install-lock-reclaim"
INSTALL_LOCK_TOKEN=
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
  for file in "${SOURCE_FILES[@]}"; do shasum -a 256 "$directory/$file"; done \
    | awk '{print $1}' | shasum -a 256 | awk '{print $1}'
}

xml_escape() {
  printf '%s' "$1" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g;s/"/\&quot;/g;s/'"'"'/\&apos;/g'
}

resolve_runtime() {
  local configured=$1 name=$2 resolved
  if [ -n "$configured" ]; then resolved=$configured; else resolved=$(command -v "$name" 2>/dev/null) || return 1; fi
  case "$resolved" in /*) ;; *) return 1 ;; esac
  [ -x "$resolved" ] || return 1
  printf '%s\n' "$resolved"
}

publish_error() {
  local output=$1 temp
  mkdir -p "$STACK_ROOT" || return 1
  temp=$(mktemp "$STACK_ROOT/.retention-error.XXXXXX") || return 1
  printf '%s\n' "$output" > "$temp" || { rm -f "$temp"; return 1; }
  chmod 600 "$temp" || { rm -f "$temp"; return 1; }
  if [ -e "$ERROR_FILE" ] || [ -L "$ERROR_FILE" ]; then
    [ -f "$ERROR_FILE" ] && [ ! -L "$ERROR_FILE" ] \
      || { rm -f "$temp"; echo "error: unsafe report-retention error control file" >&2; return 1; }
  fi
  mv -f "$temp" "$ERROR_FILE"
}

write_heartbeat() {
  local provenance_value=$1 temp
  mkdir -p "$STACK_ROOT" || return 1
  temp=$(mktemp "$STACK_ROOT/.retention-heartbeat.XXXXXX") || return 1
  printf '%s\n%s\n' "$(date +%s)" "$provenance_value" > "$temp" || { rm -f "$temp"; return 1; }
  chmod 600 "$temp" || { rm -f "$temp"; return 1; }
  mv -f "$temp" "$HEARTBEAT"
}

heartbeat_matches() {
  local expected=$1 epoch recorded now
  [ -f "$HEARTBEAT" ] && [ ! -L "$HEARTBEAT" ] || return 1
  epoch=$(sed -n '1p' "$HEARTBEAT")
  recorded=$(sed -n '2p' "$HEARTBEAT")
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  [ "$recorded" = "$expected" ] || return 1
  now=$(date +%s)
  [ "$((now - epoch))" -le "$((INTERVAL * 2 + 60))" ]
}

process_start_time() {
  LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

install_lock_state() {
  local pid started token extra current
  [ -f "$INSTALL_LOCK" ] && [ ! -L "$INSTALL_LOCK" ] || { printf 'unknown'; return; }
  pid=$(sed -n '1p' "$INSTALL_LOCK"); started=$(sed -n '2p' "$INSTALL_LOCK")
  token=$(sed -n '3p' "$INSTALL_LOCK"); extra=$(sed -n '4p' "$INSTALL_LOCK")
  case "$pid" in ''|*[!0-9]*) printf 'unknown'; return ;; esac
  [ -n "$started" ] && [ -n "$token" ] && [ -z "$extra" ] || { printf 'unknown'; return; }
  if ! kill -0 "$pid" 2>/dev/null; then printf 'stale'; return; fi
  current=$(process_start_time "$pid") || { printf 'unknown'; return; }
  if [ "$current" = "$started" ]; then printf 'live'; else printf 'stale'; fi
}

install_lock_acquire() {
  local candidate started state quarantine
  mkdir -p "$INSTALL_ROOT" || return 1
  INSTALL_LOCK_TOKEN="$$.$RANDOM.$(date +%s)"
  started=$(process_start_time "$$") || return 1
  candidate=$(mktemp "$INSTALL_ROOT/.install-lock.XXXXXX") || return 1
  printf '%s\n%s\n%s\n' "$$" "$started" "$INSTALL_LOCK_TOKEN" > "$candidate" || return 1
  for _attempt in $(seq 1 100); do
    if [ ! -e "$INSTALL_RECLAIM" ] && ln "$candidate" "$INSTALL_LOCK" 2>/dev/null; then
      rm -f "$candidate"
      return 0
    fi
    state=$(install_lock_state)
    if [ "$state" = stale ] && mkdir "$INSTALL_RECLAIM" 2>/dev/null; then
      state=$(install_lock_state)
      if [ "$state" = stale ]; then
        quarantine="$INSTALL_LOCK.stale.$INSTALL_LOCK_TOKEN"
        mv "$INSTALL_LOCK" "$quarantine" 2>/dev/null || true
        rm -f "$quarantine"
      fi
      rmdir "$INSTALL_RECLAIM" 2>/dev/null || true
      [ "$state" != stale ] || continue
    fi
    sleep 0.05
  done
  rm -f "$candidate"
  echo "error: report-retention installation is already in progress" >&2
  return 1
}

install_lock_release() {
  [ -f "$INSTALL_LOCK" ] && [ ! -L "$INSTALL_LOCK" ] || return 0
  [ "$(sed -n '3p' "$INSTALL_LOCK")" = "$INSTALL_LOCK_TOKEN" ] || return 0
  rm -f "$INSTALL_LOCK"
}

run_once() {
  local output pending guard_ms provenance_value node_runtime
  provenance_value=$(provenance "$SCRIPT_DIR") || { echo "error: retention owner bundle is incomplete" >&2; return 1; }
  node_runtime=$(resolve_runtime "${FM_REPORT_RETENTION_NODE:-}" node) \
    || { echo "error: report-retention Node runtime is unavailable" >&2; return 1; }
  guard_ms=$((INTERVAL * 2000))
  while :; do
    if output=$(FM_REPORT_RETENTION_GUARD_MS="$guard_ms" "$node_runtime" "$SCRIPT_DIR/fm-report-stack.mjs" prune --status 2>&1); then
      rm -f "$ERROR_FILE"
      write_heartbeat "$provenance_value" || return 1
      case "$output" in *'"pending":true'*) pending=1 ;; *) pending=0 ;; esac
    else
      publish_error "$output" || return 1
      return 1
    fi
    [ "$pending" -eq 1 ] || return 0
    sleep "$PROGRESS_INTERVAL"
  done
}

plist_program() {
  sed -n '/<key>ProgramArguments<\/key>/,/<\/array>/s/.*<string>\([^<]*\)<\/string>.*/\1/p' "$1" | sed -n '2p'
}

write_generation_plist() {
  local destination=$1 bash_runtime=$2 node_runtime=$3 python_runtime=$4 generation=$5 runtime_path
  runtime_path="$(dirname "$node_runtime"):$(dirname "$python_runtime"):/usr/bin:/bin:/usr/sbin:/sbin"
  cat > "$destination" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$(xml_escape "$LABEL")</string>
<key>ProgramArguments</key><array>
<string>$(xml_escape "$bash_runtime")</string>
<string>$(xml_escape "$generation/bin/fm-report-retention.sh")</string>
<string>run-once</string>
</array>
<key>EnvironmentVariables</key><dict>
<key>PATH</key><string>$(xml_escape "$runtime_path")</string>
<key>FM_REPORT_RETENTION_NODE</key><string>$(xml_escape "$node_runtime")</string>
<key>FM_REPORT_PYTHON</key><string>$(xml_escape "$python_runtime")</string>
<key>FM_REPORT_STACK_ROOT</key><string>$(xml_escape "$STACK_ROOT")</string>
<key>FM_REPORT_RETENTION_INTERVAL</key><string>$(xml_escape "$INTERVAL")</string>
<key>FM_REPORT_RETENTION_PROGRESS_INTERVAL</key><string>$(xml_escape "$PROGRESS_INTERVAL")</string>
</dict>
<key>RunAtLoad</key><true/><key>StartInterval</key><integer>$INTERVAL</integer>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict></plist>
EOF
}

install_test_interrupt() {
  [ "${FM_REPORT_RETENTION_INSTALL_TEST_INTERRUPT:-}" != "$1" ] || return 99
}

install_owner() {
  local token staging generation generation_plist plist_temp previous_plist domain file
  local bash_runtime node_runtime python_runtime source_provenance installed_provenance old_program=
  [ "$PLATFORM" = Darwin ] || { echo "error: report-retention LaunchAgent installation requires macOS" >&2; return 1; }
  command -v "$LAUNCHCTL" >/dev/null 2>&1 || { echo "error: launchctl is unavailable" >&2; return 1; }
  mkdir -p "$GENERATIONS" "$LAUNCH_AGENTS_DIR" || return 1
  [ -d "$GENERATIONS" ] && [ ! -L "$GENERATIONS" ] && [ -d "$LAUNCH_AGENTS_DIR" ] && [ ! -L "$LAUNCH_AGENTS_DIR" ] \
    || { echo "error: unsafe report-retention installation directories" >&2; return 1; }
  bash_runtime=$(resolve_runtime "${FM_REPORT_RETENTION_BASH:-}" bash) || return 1
  node_runtime=$(resolve_runtime "${FM_REPORT_RETENTION_NODE:-}" node) || return 1
  python_runtime=$(resolve_runtime "${FM_REPORT_PYTHON:-}" python3) || return 1
  token="$(date +%s).$$.$RANDOM"
  staging=$(mktemp -d "$GENERATIONS/.staging.$token.XXXXXX") || return 1
  generation="$GENERATIONS/$token"
  generation_plist="$staging/$LABEL.plist"
  plist_temp=$(mktemp "$LAUNCH_AGENTS_DIR/.$LABEL.XXXXXX") || { rm -rf "$staging"; return 1; }
  previous_plist=$(mktemp "$LAUNCH_AGENTS_DIR/.$LABEL.previous.XXXXXX") || { rm -rf "$staging"; rm -f "$plist_temp"; return 1; }
  rm -f "$previous_plist"
  mkdir "$staging/bin" || return 1
  for file in "${SOURCE_FILES[@]}"; do cp "$SCRIPT_DIR/$file" "$staging/bin/$file" || return 1; done
  chmod 700 "$staging/bin/fm-report-retention.sh" "$staging/bin/fm-report-stack.mjs" "$staging/bin/fm-contained-read.py" || return 1
  source_provenance=$(provenance "$SCRIPT_DIR") || return 1
  installed_provenance=$(provenance "$staging/bin") || return 1
  [ "$source_provenance" = "$installed_provenance" ] || return 1
  write_generation_plist "$generation_plist" "$bash_runtime" "$node_runtime" "$python_runtime" "$generation" || return 1
  chmod 600 "$generation_plist" || return 1
  cp "$generation_plist" "$plist_temp" || return 1
  chmod 600 "$plist_temp" || return 1
  mv "$staging" "$generation" || return 1
  install_test_interrupt generation-published || return $?
  if ! FM_REPORT_RETENTION_NODE="$node_runtime" FM_REPORT_PYTHON="$python_runtime" \
    "$bash_runtime" "$generation/bin/fm-report-retention.sh" run-once \
    || ! heartbeat_matches "$installed_provenance"; then
    echo "error: report-retention LaunchAgent activation failed; previous generation restored" >&2
    return 1
  fi
  if [ -e "$PLIST" ] || [ -L "$PLIST" ]; then
    [ -f "$PLIST" ] && [ ! -L "$PLIST" ] || { echo "error: unsafe installed report-retention plist" >&2; return 1; }
    cp -p "$PLIST" "$previous_plist" || return 1
    old_program=$(plist_program "$previous_plist")
  fi
  mv -f "$plist_temp" "$PLIST" || return 1
  install_test_interrupt pointer-published || return $?
  domain="gui/$(id -u)"
  "$LAUNCHCTL" bootout "$domain/$LABEL" >/dev/null 2>&1 || true
  if "$LAUNCHCTL" bootstrap "$domain" "$PLIST" \
    && "$LAUNCHCTL" kickstart "$domain/$LABEL" \
    && heartbeat_matches "$installed_provenance"; then
    rm -f "$previous_plist"
    for file in "$GENERATIONS"/*; do
      [ -d "$file" ] || continue
      [ "$file" = "$generation" ] || [ "$file/bin/fm-report-retention.sh" = "$old_program" ] || rm -rf "$file"
    done
    return 0
  fi
  if [ -f "$previous_plist" ]; then
    mv -f "$previous_plist" "$PLIST"
    "$LAUNCHCTL" bootout "$domain/$LABEL" >/dev/null 2>&1 || true
    "$LAUNCHCTL" bootstrap "$domain" "$PLIST" >/dev/null 2>&1 || true
    "$LAUNCHCTL" kickstart "$domain/$LABEL" >/dev/null 2>&1 || true
  fi
  echo "error: report-retention LaunchAgent activation failed; previous generation restored" >&2
  return 1
}

ensure_owner() {
  local program installed_provenance source_provenance domain
  [ "$PLATFORM" = Darwin ] || { echo "error: report-retention LaunchAgent requires macOS" >&2; return 1; }
  [ -f "$PLIST" ] && [ ! -L "$PLIST" ] \
    || { echo "error: report-retention LaunchAgent is not installed; run bin/fm-bootstrap.sh install report-retention after captain approval" >&2; return 1; }
  program=$(plist_program "$PLIST")
  case "$program" in "$GENERATIONS"/*/bin/fm-report-retention.sh) ;; *) echo "error: report-retention LaunchAgent provenance is invalid" >&2; return 1 ;; esac
  [ -x "$program" ] && [ -f "$program" ] && [ ! -L "$program" ] || return 1
  installed_provenance=$(provenance "$(dirname "$program")") || return 1
  source_provenance=$(provenance "$SCRIPT_DIR") || return 1
  [ "$installed_provenance" = "$source_provenance" ] \
    || { echo "error: installed report-retention owner is stale; rerun bin/fm-bootstrap.sh install report-retention after captain approval" >&2; return 1; }
  domain="gui/$(id -u)"
  "$LAUNCHCTL" print "$domain/$LABEL" >/dev/null 2>&1 || { echo "error: report-retention LaunchAgent is not loaded" >&2; return 1; }
  heartbeat_matches "$installed_provenance" || { echo "error: report-retention successful-prune heartbeat is stale" >&2; return 1; }
}

run_with_install_lock() {
  local operation=$1 status
  install_lock_acquire || return 1
  trap 'install_lock_release >/dev/null 2>&1 || true' EXIT
  "$operation"; status=$?
  install_lock_release
  trap - EXIT
  return "$status"
}

case "${1:-}" in
  ensure) run_with_install_lock ensure_owner ;;
  install) run_with_install_lock install_owner ;;
  run-once) run_once ;;
  *) echo "usage: fm-report-retention.sh ensure|install|run-once" >&2; exit 2 ;;
esac
