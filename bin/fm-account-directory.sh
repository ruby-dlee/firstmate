#!/usr/bin/env bash
# Select and prepare direct Claude or Codex account-directory launches.
# Usage:
#   fm-account-directory.sh select <claude|codex>
#   fm-account-directory.sh install-herdr-hook <claude|codex> <account-home>
#   fm-account-directory.sh prepare <claude|codex>
#
# This header is the single owner of the direct account-directory contract.
# Account homes are discovered under
# $HOME/.local/share/agent-fleet/accounts/<vendor>/ without fixed counts.
# Codex selection removes that account's quota-axi window cache immediately
# before every read, sets CODEX_HOME plus the account-isolated XDG_CACHE_HOME,
# accepts only a fresh result with at least one numeric five_hour or weekly
# window, and picks the account with the highest minimum remaining percentage.
# A Codex account with no such freshly readable window is skipped as unhealthy.
# Claude quota is not currently distinguishable per config directory because
# quota-axi cannot non-interactively resolve Claude's config-dir-specific macOS
# Keychain credential.
# Claude therefore never treats a missing usage window as account failure and
# selects the first real account directory in stable bytewise sort order.
# Selection prints only the chosen absolute account home on stdout and logs
# health, fallback, and choice diagnostics on stderr.
# prepare selects the account and idempotently runs Herdr's own integration
# installer with CODEX_HOME or CLAUDE_CONFIG_DIR set to the chosen home.
# It verifies the installed per-profile hook before printing the chosen home.
#
# Credential state is read-only.
# This script never logs in, imports credentials, or invokes a provider model.
# Test-only command and root overrides require
# FM_ACCOUNT_DIRECTORY_TEST_LAB=firstmate-account-directory-test-lab-v1.
set -u

TEST_LAB_TOKEN=firstmate-account-directory-test-lab-v1

usage() {
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//' >&2
}

log() {
  printf 'fm-account-directory: %s\n' "$*" >&2
}

test_lab_enabled() {
  [ "${FM_ACCOUNT_DIRECTORY_TEST_LAB:-}" = "$TEST_LAB_TOKEN" ]
}

account_root() {
  local root
  if test_lab_enabled && [ -n "${FM_ACCOUNT_DIRECTORY_ROOT:-}" ]; then
    root=$FM_ACCOUNT_DIRECTORY_ROOT
  else
    root=$HOME/.local/share/agent-fleet/accounts
  fi
  case "$root" in
    *$'\n'*|*$'\r'*)
      echo "error: account-directory root contains a line break" >&2
      return 1
      ;;
    /*) ;;
    *)
      echo "error: account-directory root must be absolute: $root" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$root"
}

quota_command() {
  if test_lab_enabled && [ -n "${FM_ACCOUNT_DIRECTORY_QUOTA_AXI:-}" ]; then
    printf '%s\n' "$FM_ACCOUNT_DIRECTORY_QUOTA_AXI"
    return 0
  fi
  command -v quota-axi 2>/dev/null || {
    echo "error: quota-axi is required for fresh Codex account selection" >&2
    return 1
  }
}

herdr_command() {
  if test_lab_enabled && [ -n "${FM_ACCOUNT_DIRECTORY_HERDR:-}" ]; then
    printf '%s\n' "$FM_ACCOUNT_DIRECTORY_HERDR"
    return 0
  fi
  command -v herdr 2>/dev/null || {
    echo "error: herdr is required to install the selected account's integration hook" >&2
    return 1
  }
}

valid_account_home() { # <vendor-dir> <candidate>
  local vendor_dir=$1 candidate=$2 name
  [ -d "$candidate" ] && [ ! -L "$candidate" ] || return 1
  case "$candidate" in
    "$vendor_dir"/*) ;;
    *) return 1 ;;
  esac
  name=${candidate##*/}
  case "$name" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

first_account_home() { # <vendor>
  local vendor=$1 root vendor_dir candidate
  root=$(account_root) || return 1
  vendor_dir=$root/$vendor
  [ -d "$vendor_dir" ] && [ ! -L "$vendor_dir" ] || {
    echo "error: no account-directory root for $vendor at $vendor_dir" >&2
    return 1
  }
  LC_ALL=C
  export LC_ALL
  for candidate in "$vendor_dir"/*; do
    valid_account_home "$vendor_dir" "$candidate" || continue
    printf '%s\n' "$candidate"
    return 0
  done
  echo "error: no account directories found for $vendor under $vendor_dir" >&2
  return 1
}

fresh_codex_usage_json() { # <account-home> <quota-command>
  local account_home=$1 quota_bin=$2 cache_home cache_file environment_name
  cache_home=$account_home/.agent-fleet-quota-cache
  cache_file=$cache_home/quota-axi/quotas.json
  if { [ -e "$cache_home" ] || [ -L "$cache_home" ]; } \
    && { [ ! -d "$cache_home" ] || [ -L "$cache_home" ]; }; then
    log "codex account $account_home skipped: its quota cache root is not a real directory"
    return 1
  fi
  if { [ -e "$cache_home/quota-axi" ] || [ -L "$cache_home/quota-axi" ]; } \
    && { [ ! -d "$cache_home/quota-axi" ] || [ -L "$cache_home/quota-axi" ]; }; then
    log "codex account $account_home skipped: its quota-axi cache directory is not a real directory"
    return 1
  fi
  if [ -e "$cache_file" ] || [ -L "$cache_file" ]; then
    rm -f "$cache_file" || {
      log "codex account $account_home skipped: could not clear its quota cache for a fresh health read"
      return 1
    }
  fi
  (
    while IFS='=' read -r environment_name _; do
      case "$environment_name" in
        XDG_*|QUOTA_AXI_*|AGENT_FLEET_*) unset "$environment_name" ;;
      esac
    done < <(/usr/bin/env)
    CODEX_HOME=$account_home
    XDG_CACHE_HOME=$cache_home
    export CODEX_HOME XDG_CACHE_HOME
    "$quota_bin" --provider codex --json 2>/dev/null
  )
}

codex_score() { # <quota-json>
  jq -er '
    [.providers[]?
      | select(.provider == "codex" and .state.status == "fresh")
      | (.windows // [])[]?
      | select((.id == "five_hour" or .id == "weekly")
          and (.kind // "") != "model"
          and (.percentRemaining | type) == "number")
      | .percentRemaining]
    | if length == 0 then empty else min end
  ' 2>/dev/null <<EOF
$1
EOF
}

select_codex() {
  local root vendor_dir quota_bin candidate usage score
  local best_home='' best_score=''
  root=$(account_root) || return 1
  vendor_dir=$root/codex
  [ -d "$vendor_dir" ] && [ ! -L "$vendor_dir" ] || {
    echo "error: no account-directory root for codex at $vendor_dir" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "error: jq is required for Codex account usage selection" >&2
    return 1
  }
  quota_bin=$(quota_command) || return 1
  LC_ALL=C
  export LC_ALL
  for candidate in "$vendor_dir"/*; do
    valid_account_home "$vendor_dir" "$candidate" || continue
    usage=$(fresh_codex_usage_json "$candidate" "$quota_bin") || usage=
    score=$(codex_score "$usage") || score=
    if [ -z "$score" ]; then
      log "codex account $candidate skipped: no freshly readable usage window"
      continue
    fi
    log "codex account $candidate fresh remaining score=$score"
    if [ -z "$best_home" ] || awk -v candidate_score="$score" -v current_score="$best_score" \
      'BEGIN { exit !(candidate_score > current_score) }'; then
      best_home=$candidate
      best_score=$score
    fi
  done
  [ -n "$best_home" ] || {
    echo "error: no healthy Codex account has a freshly readable usage window" >&2
    return 1
  }
  log "selected codex account $best_home with fresh remaining score=$best_score"
  printf '%s\n' "$best_home"
}

select_claude() {
  local selected
  selected=$(first_account_home claude) || return 1
  log "CLAUDE USAGE UNREADABLE: quota-axi cannot non-interactively resolve Claude's config-dir-specific macOS Keychain credential today; selecting the first account directory by stable sort: $selected"
  printf '%s\n' "$selected"
}

select_account() { # <vendor>
  case "$1" in
    codex) select_codex ;;
    claude) select_claude ;;
    *)
      echo "error: direct account-directory selection supports only claude or codex, not '$1'" >&2
      return 1
      ;;
  esac
}

install_herdr_hook() { # <vendor> <account-home>
  local vendor=$1 account_home=$2 root vendor_dir herdr_bin expected_hook
  root=$(account_root) || return 1
  vendor_dir=$root/$vendor
  valid_account_home "$vendor_dir" "$account_home" || {
    echo "error: unsafe $vendor account home for Herdr hook installation: $account_home" >&2
    return 1
  }
  herdr_bin=$(herdr_command) || return 1
  case "$vendor" in
    codex)
      CODEX_HOME=$account_home "$herdr_bin" integration install codex >/dev/null || {
        echo "error: Herdr Codex integration install failed for $account_home" >&2
        return 1
      }
      expected_hook=$account_home/herdr-agent-state.sh
      ;;
    claude)
      CLAUDE_CONFIG_DIR=$account_home "$herdr_bin" integration install claude >/dev/null || {
        echo "error: Herdr Claude integration install failed for $account_home" >&2
        return 1
      }
      expected_hook=$account_home/hooks/herdr-agent-state.sh
      ;;
    *)
      echo "error: Herdr account hook installation supports only claude or codex, not '$vendor'" >&2
      return 1
      ;;
  esac
  [ -f "$expected_hook" ] && [ ! -L "$expected_hook" ] || {
    echo "error: Herdr installer did not create the expected $vendor hook at $expected_hook" >&2
    return 1
  }
  log "Herdr $vendor hook ready at $expected_hook"
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  select)
    [ "$#" -eq 2 ] || { usage; exit 2; }
    select_account "$2"
    ;;
  install-herdr-hook)
    [ "$#" -eq 3 ] || { usage; exit 2; }
    install_herdr_hook "$2" "$3"
    ;;
  prepare)
    [ "$#" -eq 2 ] || { usage; exit 2; }
    selected_home=$(select_account "$2") || exit 1
    install_herdr_hook "$2" "$selected_home" || exit 1
    printf '%s\n' "$selected_home"
    ;;
  *)
    usage
    exit 2
    ;;
esac
