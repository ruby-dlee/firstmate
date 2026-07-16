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
# FM_REPORT_RETENTION_BASH, FM_REPORT_RETENTION_NODE, FM_REPORT_PYTHON, and
# FM_REPORT_GIT override the absolute runtimes persisted at installation.
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
INSTALL_TRANSACTION="$INSTALL_ROOT/.install-transaction"
INSTALL_LOCK="$INSTALL_ROOT/.install-lock"
INSTALL_RECLAIM="$INSTALL_ROOT/.install-lock-reclaim"
INSTALL_LOCK_GENERATION=
INSTALL_OWNER_PID=${BASHPID:-$$}
INSTALL_OWNER_START=
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

resolve_runtime() {
  local configured=$1 name=$2 resolved
  if [ -n "$configured" ]; then
    resolved=$configured
  else
    resolved=$(command -v "$name" 2>/dev/null) || return 1
  fi
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

heartbeat_matches() {
  local expected=$1 epoch recorded now max_age
  [ -f "$HEARTBEAT" ] && [ ! -L "$HEARTBEAT" ] || return 1
  epoch=$(sed -n '1p' "$HEARTBEAT" 2>/dev/null)
  recorded=$(sed -n '2p' "$HEARTBEAT" 2>/dev/null)
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  [ "$recorded" = "$expected" ] || return 1
  now=$(date +%s)
  max_age=$((INTERVAL * 2 + 60))
  [ "$((now - epoch))" -le "$max_age" ]
}

write_heartbeat() {
  local provenance_value=$1 temp
  mkdir -p "$STACK_ROOT" || return 1
  temp=$(mktemp "$STACK_ROOT/.retention-heartbeat.XXXXXX") || return 1
  printf '%s\n%s\n' "$(date +%s)" "$provenance_value" > "$temp" || { rm -f "$temp"; return 1; }
  chmod 600 "$temp" || { rm -f "$temp"; return 1; }
  mv "$temp" "$HEARTBEAT"
}

process_start_time() {
  local out
  out=$(LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null) || return 1
  out=$(printf '%s\n' "$out" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

install_generation_valid() {
  case "$1" in
    ''|*[!0-9.]*|.*|*.|*..*) return 1 ;;
    *) return 0 ;;
  esac
}

install_owner_state() {
  local owner=$1 pid recorded generation extra current
  [ -f "$owner" ] && [ ! -L "$owner" ] || { printf 'unknown'; return 0; }
  [ "$(wc -c < "$owner" | tr -d '[:space:]')" -le 256 ] || { printf 'unknown'; return 0; }
  pid=$(sed -n '1p' "$owner")
  recorded=$(sed -n '2p' "$owner")
  generation=$(sed -n '3p' "$owner")
  extra=$(sed -n '4p' "$owner")
  case "$pid" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  [ -n "$recorded" ] && install_generation_valid "$generation" && [ -z "$extra" ] \
    || { printf 'unknown'; return 0; }
  if ! kill -0 "$pid" 2>/dev/null; then
    printf 'stale'
    return 0
  fi
  current=$(process_start_time "$pid") || { printf 'unknown'; return 0; }
  if [ "$current" = "$recorded" ]; then printf 'live'; else printf 'stale'; fi
}

install_lock_acquire() {
  local temp deadline state wait_seconds
  wait_seconds=${FM_REPORT_RETENTION_INSTALL_LOCK_WAIT_SECONDS:-10}
  case "$wait_seconds" in ''|*[!0-9]*|0) echo "error: invalid report-retention install lock wait" >&2; return 1 ;; esac
  mkdir -p "$INSTALL_ROOT" "$LAUNCH_AGENTS_DIR" || return 1
  [ -d "$INSTALL_ROOT" ] && [ ! -L "$INSTALL_ROOT" ] \
    && [ -d "$LAUNCH_AGENTS_DIR" ] && [ ! -L "$LAUNCH_AGENTS_DIR" ] \
    || { echo "error: unsafe report-retention installation directories" >&2; return 1; }
  INSTALL_OWNER_START=$(process_start_time "$INSTALL_OWNER_PID") \
    || { echo "error: cannot identify report-retention installer" >&2; return 1; }
  INSTALL_LOCK_GENERATION="$(date +%s).$INSTALL_OWNER_PID.$RANDOM"
  temp=$(mktemp "$INSTALL_ROOT/.install-lock.XXXXXX") || return 1
  printf '%s\n%s\n%s\n' "$INSTALL_OWNER_PID" "$INSTALL_OWNER_START" "$INSTALL_LOCK_GENERATION" > "$temp" \
    || { rm -f "$temp"; return 1; }
  chmod 600 "$temp" || { rm -f "$temp"; return 1; }
  deadline=$(( $(date +%s) + wait_seconds ))
  while :; do
    if [ -L "$INSTALL_RECLAIM" ] || { [ -e "$INSTALL_RECLAIM" ] && [ ! -d "$INSTALL_RECLAIM" ]; }; then
      rm -f "$temp"
      echo "error: unsafe report-retention install lock reclaim" >&2
      return 1
    fi
    if [ ! -e "$INSTALL_RECLAIM" ] && ln "$temp" "$INSTALL_LOCK" 2>/dev/null; then
      rm -f "$temp"
      return 0
    fi
    if [ -L "$INSTALL_LOCK" ] || { [ -e "$INSTALL_LOCK" ] && [ ! -f "$INSTALL_LOCK" ]; }; then
      rm -f "$temp"
      echo "error: unsafe report-retention install lock" >&2
      return 1
    fi
    if [ -f "$INSTALL_LOCK" ]; then
      state=$(install_owner_state "$INSTALL_LOCK")
      if [ "$state" = stale ] && mkdir "$INSTALL_RECLAIM" 2>/dev/null; then
        state=$(install_owner_state "$INSTALL_LOCK")
        [ "$state" != stale ] || rm -f "$INSTALL_LOCK"
        rmdir "$INSTALL_RECLAIM" 2>/dev/null || true
        [ "$state" != stale ] || continue
      fi
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      rm -f "$temp"
      echo "error: timed out waiting for report-retention install lock" >&2
      return 1
    fi
    sleep 0.05
  done
}

install_lock_release() {
  local pid recorded generation extra
  [ -e "$INSTALL_LOCK" ] || return 0
  [ -f "$INSTALL_LOCK" ] && [ ! -L "$INSTALL_LOCK" ] \
    || { echo "error: unsafe report-retention install lock" >&2; return 1; }
  pid=$(sed -n '1p' "$INSTALL_LOCK")
  recorded=$(sed -n '2p' "$INSTALL_LOCK")
  generation=$(sed -n '3p' "$INSTALL_LOCK")
  extra=$(sed -n '4p' "$INSTALL_LOCK")
  [ "$pid" = "$INSTALL_OWNER_PID" ] && [ "$recorded" = "$INSTALL_OWNER_START" ] \
    && [ "$generation" = "$INSTALL_LOCK_GENERATION" ] && [ -z "$extra" ] \
    || { echo "error: refusing to release another report-retention installer's lock" >&2; return 1; }
  rm -f "$INSTALL_LOCK"
}

write_install_transaction() {
  local phase=$1 token=$2 had_bundle=$3 had_plist=$4 temp owner_pid owner_start owner_generation extra
  temp=$(mktemp "$INSTALL_ROOT/.install-transaction.XXXXXX") || return 1
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$phase" "$token" "$had_bundle" "$had_plist" \
    "$INSTALL_OWNER_PID" "$INSTALL_OWNER_START" "$INSTALL_LOCK_GENERATION" > "$temp" \
    || { rm -f "$temp"; return 1; }
  chmod 600 "$temp" || { rm -f "$temp"; return 1; }
  if [ -e "$INSTALL_TRANSACTION" ] || [ -L "$INSTALL_TRANSACTION" ]; then
    [ -f "$INSTALL_TRANSACTION" ] && [ ! -L "$INSTALL_TRANSACTION" ] \
      || { rm -f "$temp"; echo "error: unsafe report-retention install transaction" >&2; return 1; }
    owner_pid=$(sed -n '5p' "$INSTALL_TRANSACTION")
    owner_start=$(sed -n '6p' "$INSTALL_TRANSACTION")
    owner_generation=$(sed -n '7p' "$INSTALL_TRANSACTION")
    extra=$(sed -n '8p' "$INSTALL_TRANSACTION")
    [ "$owner_pid" = "$INSTALL_OWNER_PID" ] && [ "$owner_start" = "$INSTALL_OWNER_START" ] \
      && [ "$owner_generation" = "$INSTALL_LOCK_GENERATION" ] && [ -z "$extra" ] \
      || { rm -f "$temp"; echo "error: refusing to overwrite another report-retention install transaction" >&2; return 1; }
  fi
  mv -f "$temp" "$INSTALL_TRANSACTION"
}

remove_installed_bundle() {
  local bundle=$1
  if [ -e "$bundle" ] || [ -L "$bundle" ]; then
    [ -d "$bundle" ] && [ ! -L "$bundle" ] \
      || { echo "error: installed report-retention bundle is unsafe" >&2; return 1; }
    rm -rf "$bundle"
  fi
}

remove_installed_plist() {
  local plist=$1
  if [ -e "$plist" ] || [ -L "$plist" ]; then
    [ -f "$plist" ] && [ ! -L "$plist" ] \
      || { echo "error: installed report-retention LaunchAgent is unsafe" >&2; return 1; }
    rm -f "$plist"
  fi
}

recover_install_transaction() {
  local phase token had_bundle had_plist owner_pid owner_start owner_generation extra token_a token_b token_c token_extra owner_state current
  local bundle="$INSTALL_ROOT/bin" bundle_previous plist_previous domain
  [ -e "$INSTALL_TRANSACTION" ] || [ -L "$INSTALL_TRANSACTION" ] || return 0
  [ -f "$INSTALL_TRANSACTION" ] && [ ! -L "$INSTALL_TRANSACTION" ] \
    || { echo "error: unsafe report-retention install transaction" >&2; return 1; }
  [ "$(wc -c < "$INSTALL_TRANSACTION" | tr -d '[:space:]')" -le 256 ] \
    || { echo "error: invalid report-retention install transaction" >&2; return 1; }
  phase=$(sed -n '1p' "$INSTALL_TRANSACTION")
  token=$(sed -n '2p' "$INSTALL_TRANSACTION")
  had_bundle=$(sed -n '3p' "$INSTALL_TRANSACTION")
  had_plist=$(sed -n '4p' "$INSTALL_TRANSACTION")
  owner_pid=$(sed -n '5p' "$INSTALL_TRANSACTION")
  owner_start=$(sed -n '6p' "$INSTALL_TRANSACTION")
  owner_generation=$(sed -n '7p' "$INSTALL_TRANSACTION")
  extra=$(sed -n '8p' "$INSTALL_TRANSACTION")
  IFS=. read -r token_a token_b token_c token_extra <<< "$token"
  case "$phase:$had_bundle:$had_plist" in prepared:0:0|prepared:0:1|prepared:1:0|prepared:1:1|committed:0:0|committed:0:1|committed:1:0|committed:1:1) ;; *) echo "error: invalid report-retention install transaction" >&2; return 1 ;; esac
  case "$token_a" in ''|*[!0-9]*) echo "error: invalid report-retention install transaction" >&2; return 1 ;; esac
  case "$token_b" in ''|*[!0-9]*) echo "error: invalid report-retention install transaction" >&2; return 1 ;; esac
  case "$token_c" in ''|*[!0-9]*) echo "error: invalid report-retention install transaction" >&2; return 1 ;; esac
  [ -z "$token_extra" ] && [ -z "$extra" ] && [ "$owner_generation" = "$token" ] \
    || { echo "error: invalid report-retention install transaction" >&2; return 1; }
  case "$owner_pid" in ''|*[!0-9]*) echo "error: invalid report-retention install transaction" >&2; return 1 ;; esac
  [ -n "$owner_start" ] || { echo "error: invalid report-retention install transaction" >&2; return 1; }
  if [ "$owner_pid" = "$INSTALL_OWNER_PID" ] && [ "$owner_start" = "$INSTALL_OWNER_START" ] \
    && [ "$owner_generation" = "$INSTALL_LOCK_GENERATION" ]; then
    owner_state=owned
  elif ! kill -0 "$owner_pid" 2>/dev/null; then
    owner_state=stale
  elif current=$(process_start_time "$owner_pid"); then
    if [ "$current" = "$owner_start" ]; then owner_state=live; else owner_state=stale; fi
  else
    owner_state=unknown
  fi
  case "$owner_state" in
    owned|stale) ;;
    live) echo "error: report-retention install transaction is owned by a live installer" >&2; return 1 ;;
    *) echo "error: cannot prove report-retention install transaction is stale" >&2; return 1 ;;
  esac
  bundle_previous="$INSTALL_ROOT/.bin.previous.$token"
  plist_previous="$LAUNCH_AGENTS_DIR/.$LABEL.previous.$token.plist"
  if [ "$phase" = committed ]; then
    [ -d "$bundle" ] && [ ! -L "$bundle" ] && [ -f "$PLIST" ] && [ ! -L "$PLIST" ] \
      || { echo "error: committed report-retention installation is incomplete" >&2; return 1; }
    remove_installed_bundle "$bundle_previous" || return 1
    remove_installed_plist "$plist_previous" || return 1
    rm -f "$INSTALL_TRANSACTION"
    return 0
  fi

  domain="gui/$(id -u)"
  "$LAUNCHCTL" bootout "$domain/$LABEL" >/dev/null 2>&1 || true
  if [ "$had_bundle" -eq 1 ]; then
    if [ -e "$bundle_previous" ] || [ -L "$bundle_previous" ]; then
      [ -d "$bundle_previous" ] && [ ! -L "$bundle_previous" ] \
        || { echo "error: previous report-retention bundle is unsafe" >&2; return 1; }
      remove_installed_bundle "$bundle" || return 1
      mv "$bundle_previous" "$bundle" || return 1
    else
      [ -d "$bundle" ] && [ ! -L "$bundle" ] \
        || { echo "error: report-retention transaction lost its previous bundle" >&2; return 1; }
    fi
  else
    [ ! -e "$bundle_previous" ] && [ ! -L "$bundle_previous" ] \
      || { echo "error: unexpected previous report-retention bundle" >&2; return 1; }
    remove_installed_bundle "$bundle" || return 1
  fi
  if [ "$had_plist" -eq 1 ]; then
    if [ -e "$plist_previous" ] || [ -L "$plist_previous" ]; then
      [ -f "$plist_previous" ] && [ ! -L "$plist_previous" ] \
        || { echo "error: previous report-retention LaunchAgent is unsafe" >&2; return 1; }
      remove_installed_plist "$PLIST" || return 1
      mv "$plist_previous" "$PLIST" || return 1
    else
      [ -f "$PLIST" ] && [ ! -L "$PLIST" ] \
        || { echo "error: report-retention transaction lost its previous LaunchAgent" >&2; return 1; }
    fi
    "$LAUNCHCTL" bootstrap "$domain" "$PLIST" >/dev/null 2>&1 \
      && "$LAUNCHCTL" kickstart "$domain/$LABEL" >/dev/null 2>&1 \
      || return 1
  else
    [ ! -e "$plist_previous" ] && [ ! -L "$plist_previous" ] \
      || { echo "error: unexpected previous report-retention LaunchAgent" >&2; return 1; }
    remove_installed_plist "$PLIST" || return 1
  fi
  rm -f "$INSTALL_TRANSACTION"
}

install_test_interrupt() {
  [ "${FM_REPORT_RETENTION_INSTALL_TEST_INTERRUPT:-}" != "$1" ] || return 99
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

install_owner() {
  local bundle="$INSTALL_ROOT/bin" staging plist_temp file source_provenance installed_provenance domain
  local bash_runtime node_runtime python_runtime git_runtime runtime_path token bundle_previous plist_previous
  local had_bundle=0 had_plist=0 activation_ok=0
  [ "$PLATFORM" = Darwin ] || { echo "error: report-retention LaunchAgent installation requires macOS" >&2; return 1; }
  command -v "$LAUNCHCTL" >/dev/null 2>&1 || { echo "error: launchctl is unavailable" >&2; return 1; }
  mkdir -p "$INSTALL_ROOT" "$LAUNCH_AGENTS_DIR" || return 1
  recover_install_transaction || return 1
  bash_runtime=$(resolve_runtime "${FM_REPORT_RETENTION_BASH:-}" bash) \
    || { echo "error: report-retention Bash runtime is unavailable" >&2; return 1; }
  node_runtime=$(resolve_runtime "${FM_REPORT_RETENTION_NODE:-}" node) \
    || { echo "error: report-retention Node runtime is unavailable" >&2; return 1; }
  python_runtime=$(resolve_runtime "${FM_REPORT_PYTHON:-}" python3) \
    || { echo "error: report-retention Python runtime is unavailable" >&2; return 1; }
  git_runtime=$(resolve_runtime "${FM_REPORT_GIT:-}" git) \
    || { echo "error: report-retention Git runtime is unavailable" >&2; return 1; }
  runtime_path="$(dirname "$node_runtime"):$(dirname "$python_runtime"):$(dirname "$git_runtime"):/usr/bin:/bin:/usr/sbin:/sbin"
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
  cat > "$plist_temp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$(xml_escape "$LABEL")</string>
<key>ProgramArguments</key>
<array>
<string>$(xml_escape "$bash_runtime")</string>
<string>$(xml_escape "$bundle/fm-report-retention.sh")</string>
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
<key>RunAtLoad</key><true/>
<key>StartInterval</key><integer>$INTERVAL</integer>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict></plist>
EOF
  chmod 600 "$plist_temp" || { rm -rf "$staging"; rm -f "$plist_temp"; return 1; }
  token=$INSTALL_LOCK_GENERATION
  bundle_previous="$INSTALL_ROOT/.bin.previous.$token"
  plist_previous="$LAUNCH_AGENTS_DIR/.$LABEL.previous.$token.plist"
  if [ -e "$bundle" ] || [ -L "$bundle" ]; then
    [ -d "$bundle" ] && [ ! -L "$bundle" ] \
      || { rm -rf "$staging"; rm -f "$plist_temp"; echo "error: installed report-retention bundle is unsafe" >&2; return 1; }
    had_bundle=1
  fi
  if [ -e "$PLIST" ] || [ -L "$PLIST" ]; then
    [ -f "$PLIST" ] && [ ! -L "$PLIST" ] \
      || { rm -rf "$staging"; rm -f "$plist_temp"; echo "error: installed report-retention LaunchAgent is unsafe" >&2; return 1; }
    had_plist=1
  fi
  write_install_transaction prepared "$token" "$had_bundle" "$had_plist" \
    || { rm -rf "$staging"; rm -f "$plist_temp"; return 1; }
  if [ "$had_bundle" -eq 1 ]; then
    mv "$bundle" "$bundle_previous" \
      || { recover_install_transaction || true; rm -rf "$staging"; rm -f "$plist_temp"; return 1; }
  fi
  install_test_interrupt bundle-backed-up || return $?
  if [ "$had_plist" -eq 1 ]; then
    mv "$PLIST" "$plist_previous" \
      || { recover_install_transaction || true; rm -rf "$staging"; rm -f "$plist_temp"; return 1; }
  fi
  install_test_interrupt plist-backed-up || return $?
  if mv "$staging" "$bundle"; then
    install_test_interrupt bundle-published || return $?
    if mv "$plist_temp" "$PLIST"; then
      activation_ok=1
      install_test_interrupt plist-published || return $?
    fi
  fi
  domain="gui/$(id -u)"
  if [ "$activation_ok" -eq 1 ]; then
    "$LAUNCHCTL" bootout "$domain/$LABEL" >/dev/null 2>&1 || true
    "$LAUNCHCTL" bootstrap "$domain" "$PLIST" \
      && "$LAUNCHCTL" kickstart "$domain/$LABEL" \
      && FM_REPORT_RETENTION_NODE="$node_runtime" FM_REPORT_PYTHON="$python_runtime" \
        "$bash_runtime" "$bundle/fm-report-retention.sh" run-once \
      && heartbeat_matches "$installed_provenance" \
      || activation_ok=0
  fi
  if [ "$activation_ok" -ne 1 ]; then
    recover_install_transaction || true
    rm -rf "$staging"
    rm -f "$plist_temp"
    echo "error: report-retention LaunchAgent activation failed; previous generation restored" >&2
    return 1
  fi
  if ! write_install_transaction committed "$token" "$had_bundle" "$had_plist"; then
    recover_install_transaction || true
    echo "error: report-retention LaunchAgent activation failed; previous generation restored" >&2
    return 1
  fi
  recover_install_transaction
}

ensure_owner() {
  local now heartbeat_epoch heartbeat_provenance installed_provenance source_provenance max_age domain
  local plist_arguments plist_bash plist_program plist_node plist_python
  [ "$PLATFORM" = Darwin ] || { echo "error: report-retention LaunchAgent requires macOS" >&2; return 1; }
  command -v "$LAUNCHCTL" >/dev/null 2>&1 || { echo "error: launchctl is unavailable" >&2; return 1; }
  recover_install_transaction || return 1
  [ -f "$PLIST" ] && [ ! -L "$PLIST" ] \
    || { echo "error: report-retention LaunchAgent is not installed; run bin/fm-bootstrap.sh install report-retention after captain approval" >&2; return 1; }
  plist_arguments=$(sed -n '/<key>ProgramArguments<\/key>/,/<\/array>/s/.*<string>\([^<]*\)<\/string>.*/\1/p' "$PLIST")
  plist_bash=$(printf '%s\n' "$plist_arguments" | sed -n '1p')
  plist_program=$(printf '%s\n' "$plist_arguments" | sed -n '2p')
  plist_node=$(sed -n 's#.*<key>FM_REPORT_RETENTION_NODE</key><string>\([^<]*\)</string>.*#\1#p' "$PLIST")
  plist_python=$(sed -n 's#.*<key>FM_REPORT_PYTHON</key><string>\([^<]*\)</string>.*#\1#p' "$PLIST")
  case "$plist_bash:$plist_node:$plist_python" in /*:/*:/*) ;; *) echo "error: report-retention LaunchAgent runtimes are invalid" >&2; return 1 ;; esac
  [ -x "$plist_bash" ] && [ -x "$plist_node" ] && [ -x "$plist_python" ] \
    || { echo "error: report-retention LaunchAgent runtimes are unavailable" >&2; return 1; }
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

run_with_install_lock() {
  local operation=$1 status release_status
  install_lock_acquire || return 1
  trap 'install_lock_release >/dev/null 2>&1 || true' EXIT
  "$operation"
  status=$?
  install_lock_release
  release_status=$?
  trap - EXIT
  [ "$status" -ne 0 ] && return "$status"
  return "$release_status"
}

case "${1:-}" in
  ensure) run_with_install_lock ensure_owner ;;
  install) run_with_install_lock install_owner ;;
  run-once) run_once ;;
  *) echo "usage: fm-report-retention.sh ensure|install|run-once" >&2; exit 2 ;;
esac
