# shellcheck shell=bash
# Agent Fleet account-routing helpers shared by spawn, recovery, supervision,
# and teardown.
#
# This file owns Firstmate's shell-side Agent Fleet contract.
# It consumes only `agent-fleet --format json contract` version 1 commands and
# never reads Agent Fleet state, profile homes, provider credentials, or quota
# caches directly.
#
# Routing mode precedence is:
#   1. an explicit per-spawn account pool/profile (enforce for that spawn), or
#      --no-account-routing (off for that spawn);
#   2. FM_ACCOUNT_ROUTING;
#   3. config/account-routing-mode;
#   4. off.
# Valid modes are off, observe, and enforce.
# Off does not invoke Agent Fleet.
# Observe performs only `choose --dry-run`, never creates a lease, and never
# changes the provider launch or task metadata.
# Enforce atomically reserves one profile before endpoint creation and fails
# closed on every Agent Fleet or validation error.
#
# FM_AGENT_FLEET_BIN may name a deterministic fake or a pinned candidate in
# tests/labs. Otherwise `agent-fleet` is resolved from PATH.

fm_account_shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

fm_account_valid_id() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*|.*|-*) return 1 ;;
  esac
  return 0
}

fm_account_fleet_bin() {
  if [ -n "${FM_AGENT_FLEET_BIN:-}" ]; then
    [ -x "$FM_AGENT_FLEET_BIN" ] || {
      echo "error: FM_AGENT_FLEET_BIN is not executable: $FM_AGENT_FLEET_BIN" >&2
      return 1
    }
    printf '%s\n' "$FM_AGENT_FLEET_BIN"
    return 0
  fi
  command -v agent-fleet 2>/dev/null || {
    echo "error: agent-fleet is required for account routing" >&2
    return 1
  }
}

fm_account_read_single_value() {  # <file>
  local file=$1 value extra
  [ -f "$file" ] || return 1
  value=$(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$file" | head -1 | tr -d '[:space:]')
  extra=$(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$file" | sed -n '2p')
  [ -z "$extra" ] || {
    echo "error: $file must contain exactly one value" >&2
    return 2
  }
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

fm_account_resolve_mode() {  # <config-dir> <explicit-route:0|1> <disabled:0|1>
  local config=$1 explicit=$2 disabled=$3 value source
  if [ "$disabled" = 1 ]; then
    printf 'off\n'
    return 0
  fi
  if [ "$explicit" = 1 ]; then
    printf 'enforce\n'
    return 0
  fi
  if [ -n "${FM_ACCOUNT_ROUTING:-}" ]; then
    value=$FM_ACCOUNT_ROUTING
    source=FM_ACCOUNT_ROUTING
  elif value=$(fm_account_read_single_value "$config/account-routing-mode" 2>/dev/null); then
    source=config/account-routing-mode
  else
    value=off
    source=default
  fi
  case "$value" in
    off|observe|enforce) printf '%s\n' "$value" ;;
    *) echo "error: invalid account routing mode '$value' from $source (expected off, observe, or enforce)" >&2; return 1 ;;
  esac
}

fm_account_secondmate_pool() {  # <config-dir>
  local value
  value=$(fm_account_read_single_value "$1/secondmate-account-pool") || return $?
  fm_account_valid_id "$value" || {
    echo "error: invalid account pool '$value' in config/secondmate-account-pool" >&2
    return 2
  }
  printf '%s\n' "$value"
}

fm_account_default_pool() {  # <harness>
  case "$1" in
    claude|codex) printf '%s-crew\n' "$1" ;;
    *) return 1 ;;
  esac
}

fm_account_json_field() {  # <json> <jq-expression> <label>
  local json=$1 expression=$2 label=$3 value
  command -v jq >/dev/null 2>&1 || {
    echo "error: jq is required for account routing" >&2
    return 1
  }
  value=$(printf '%s\n' "$json" | jq -er "$expression" 2>/dev/null) || {
    echo "error: agent-fleet returned invalid $label JSON" >&2
    return 1
  }
  printf '%s\n' "$value"
}

# Sets FM_ACCOUNT_SELECTED_PROFILE and FM_ACCOUNT_SELECTED_PROVIDER.
# In observe mode these are shadow values only and callers must not persist or
# apply them.
fm_account_select() {  # <mode> <harness> <pool> <profile-or-empty> <task>
  local mode=$1 harness=$2 pool=$3 requested_profile=$4 task=$5 binary json status
  FM_ACCOUNT_SELECTED_PROFILE=
  FM_ACCOUNT_SELECTED_PROVIDER=
  case "$harness" in
    claude|codex) ;;
    *)
      if [ "$mode" = enforce ]; then
        echo "error: account routing supports only claude and codex, not '$harness'" >&2
        return 1
      fi
      return 0
      ;;
  esac
  fm_account_valid_id "$pool" || { echo "error: invalid account pool '$pool'" >&2; return 1; }
  [ -z "$requested_profile" ] || fm_account_valid_id "$requested_profile" || {
    echo "error: invalid account profile '$requested_profile'" >&2
    return 1
  }
  binary=$(fm_account_fleet_bin) || {
    [ "$mode" = observe ] && { echo "fm-account-routing: observe unavailable; legacy launch unchanged" >&2; return 0; }
    return 1
  }
  if [ "$mode" = observe ]; then
    set +e
    json=$("$binary" --format json choose --pool "$pool" --task "$task" --provider "$harness" --dry-run 2>/dev/null)
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then
      echo "fm-account-routing: observe decision unavailable for pool=$pool provider=$harness; legacy launch unchanged" >&2
      return 0
    fi
  elif [ -n "$requested_profile" ] && [ "$pool" = explicit ]; then
    json=$("$binary" --format json lease acquire --profile "$requested_profile" --task "$task" --pool "$pool") || return 1
  else
    if [ -n "$requested_profile" ]; then
      json=$("$binary" --format json lease choose --pool "$pool" --task "$task" --provider "$harness" --profile "$requested_profile") || return 1
    else
      json=$("$binary" --format json lease choose --pool "$pool" --task "$task" --provider "$harness") || return 1
    fi
  fi
  FM_ACCOUNT_SELECTED_PROFILE=$(fm_account_json_field "$json" '.profile | select(type == "string" and length > 0)' selection) || return 1
  FM_ACCOUNT_SELECTED_PROVIDER=$(fm_account_json_field "$json" '.provider | select(type == "string" and length > 0)' selection) || return 1
  [ "$FM_ACCOUNT_SELECTED_PROVIDER" = "$harness" ] || {
    echo "error: agent-fleet selected provider '$FM_ACCOUNT_SELECTED_PROVIDER' for harness '$harness'" >&2
    return 1
  }
  if [ -n "$requested_profile" ] && [ "$FM_ACCOUNT_SELECTED_PROFILE" != "$requested_profile" ]; then
    echo "error: agent-fleet selected profile '$FM_ACCOUNT_SELECTED_PROFILE', expected '$requested_profile'" >&2
    return 1
  fi
  if [ "$mode" = observe ]; then
    echo "fm-account-routing: observe pool=$pool provider=$harness profile=$FM_ACCOUNT_SELECTED_PROFILE (no lease; legacy launch unchanged)" >&2
  fi
}

fm_account_exec_command() {  # <profile> <pool> <task>
  local binary
  binary=$(fm_account_fleet_bin) || return 1
  printf '%s --format json exec --profile %s --task %s --pool %s --' \
    "$(fm_account_shell_quote "$binary")" \
    "$(fm_account_shell_quote "$1")" \
    "$(fm_account_shell_quote "$3")" \
    "$(fm_account_shell_quote "$2")"
}

fm_account_resume_command() {  # <task>
  local binary
  binary=$(fm_account_fleet_bin) || return 1
  printf '%s --format json resume --task %s --' \
    "$(fm_account_shell_quote "$binary")" \
    "$(fm_account_shell_quote "$1")"
}

# Sets FM_ACCOUNT_SELECTED_PROFILE and FM_ACCOUNT_SELECTED_PROVIDER from a
# sticky recovery reservation. This path intentionally bypasses new-task quota
# reserve filtering inside Agent Fleet while still refusing a live owner.
fm_account_recover() {  # <task> <expected-profile> <expected-pool> <expected-provider>
  local task=$1 expected_profile=$2 expected_pool=$3 expected_provider=$4 binary json profile pool provider
  binary=$(fm_account_fleet_bin) || return 1
  json=$("$binary" --format json lease recover --task "$task") || return 1
  profile=$(fm_account_json_field "$json" '.profile | select(type == "string" and length > 0)' recovery) || return 1
  pool=$(fm_account_json_field "$json" '.pool | select(type == "string" and length > 0)' recovery) || return 1
  provider=$(fm_account_json_field "$json" '.provider | select(type == "string" and length > 0)' recovery) || return 1
  [ "$profile" = "$expected_profile" ] || { echo "error: recovery profile mismatch for $task" >&2; return 1; }
  [ "$pool" = "$expected_pool" ] || { echo "error: recovery pool mismatch for $task" >&2; return 1; }
  [ "$provider" = "$expected_provider" ] || { echo "error: recovery provider mismatch for $task" >&2; return 1; }
  FM_ACCOUNT_SELECTED_PROFILE=$profile
  FM_ACCOUNT_SELECTED_PROVIDER=$provider
}

fm_account_release() {  # <task> [--force]
  local binary task=$1 force=${2:-} out status
  binary=$(fm_account_fleet_bin) || return 1
  set +e
  if [ "$force" = --force ]; then
    out=$("$binary" --format json lease release --task "$task" --force 2>&1)
  else
    out=$("$binary" --format json lease release --task "$task" 2>&1)
  fi
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    return 0
  fi
  case "$out" in
    *"no lease for task"*) return 0 ;;
  esac
  printf '%s\n' "$out" >&2
  return "$status"
}

fm_account_session_remove() {  # <task>
  local binary out status
  binary=$(fm_account_fleet_bin) || return 1
  set +e
  out=$("$binary" --format json session remove --task "$1" 2>&1)
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    return 0
  fi
  case "$out" in
    *"no recorded provider session"*) return 0 ;;
  esac
  printf '%s\n' "$out" >&2
  return "$status"
}
