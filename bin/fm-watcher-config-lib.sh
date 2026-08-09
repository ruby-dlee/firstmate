#!/usr/bin/env bash

fm_watcher_config_variable_allowed() {  # <name>
  case "$1" in
    FM_ACCOUNT_CONTROL_TIMEOUT|FM_ACCOUNT_LIFECYCLE_LOCK_WAIT_SECONDS|FM_ACCOUNT_LINEAGE_LOCK_WAIT_SECONDS|FM_ACCOUNT_META_LOCK_WAIT_SECONDS|FM_ACCOUNT_SESSION_MAX_PARALLEL|FM_ACCOUNT_SESSION_QUERY_TIMEOUT|FM_ACCOUNT_SESSION_SYNC_INTERVAL|FM_ACCOUNT_SESSION_SYNC_TIMEOUT|FM_ACCOUNT_SESSION_SYNC_TOTAL_TIMEOUT|FM_ACCOUNT_SESSION_TASK_TIMEOUT) return 0 ;;
    FM_ARM_ATTACH_POLL|FM_ARM_CONFIRM_TIMEOUT) return 0 ;;
    FM_AUTO_REAP_COMMAND_TIMEOUT|FM_AUTO_REAP_STALE_SECS) return 0 ;;
    FM_BUSY_REGEX|FM_CAPTAIN_RE|FM_CLASSIFY_PAUSED_VERB) return 0 ;;
    FM_CHECKOUT_REFRESH_PROBE_TIMEOUT|FM_CHECK_INTERVAL|FM_CHECK_TIMEOUT) return 0 ;;
    FM_CREW_STATE_GH_TIMEOUT|FM_CREW_STATE_NM_TIMEOUT|FM_CREW_STATE_READ_TIMEOUT|FM_CREW_STATE_RUNS_LIMIT) return 0 ;;
    FM_EVENT_CAP_FAIL_MAX|FM_GUARD_GRACE|FM_HEARTBEAT|FM_HEARTBEAT_MAX) return 0 ;;
    FM_PAUSE_RESURFACE_SECS|FM_PERMISSION_STALL_ESCALATE_SECS|FM_POLL) return 0 ;;
    FM_REPORT_RETENTION_INTERVAL|FM_REPORT_RETENTION_OWNER_FRESH_SECS|FM_REPORT_RETENTION_TIMEOUT) return 0 ;;
    FM_SIGNAL_GRACE|FM_STALE_ESCALATE_SECS|FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS) return 0 ;;
    FM_TREEHOUSE_RETURN_LOCK_RETRIES|FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS|FM_TREEHOUSE_RETURN_TIMEOUT) return 0 ;;
    FM_WATCHER_STALE_GRACE|FM_WATCH_AUTO_REAP_CLEANUP_MARGIN|FM_WATCH_AUTO_REAP_TIMEOUT) return 0 ;;
    FM_WATCH_CPU_LIMIT|FM_WATCH_CPU_POLL|FM_WATCH_CPU_SAMPLES) return 0 ;;
    FM_WATCH_PHASE_MARGIN|FM_WATCH_PROGRESS_GRACE|FM_WATCH_TRIAGE_LOG_MAX_BYTES) return 0 ;;
    FM_WEDGE_DEMAND_INSPECT_COUNT) return 0 ;;
  esac
  return 1
}

fm_watcher_config_value_valid() {  # <name> <value>
  local name=$1 value=$2 status
  case "$name" in
    FM_BUSY_REGEX|FM_CAPTAIN_RE)
      [ -n "$value" ] && [ "${#value}" -le 4096 ] || return 1
      printf '%s' "$value" | LC_ALL=C grep -q '[[:cntrl:]]' && return 1
      printf '' | LC_ALL=C grep -E "$value" >/dev/null 2>&1
      status=$?
      [ "$status" -ne 2 ]
      ;;
    FM_CLASSIFY_PAUSED_VERB)
      [ -n "$value" ] && [ "${#value}" -le 64 ] || return 1
      case "$value" in *[!A-Za-z0-9_-]*|[0-9_-]*) return 1 ;; esac
      ;;
    FM_ACCOUNT_LIFECYCLE_LOCK_WAIT_SECONDS|FM_ACCOUNT_LINEAGE_LOCK_WAIT_SECONDS|FM_ACCOUNT_META_LOCK_WAIT_SECONDS|FM_CHECK_INTERVAL|FM_SIGNAL_GRACE|FM_TREEHOUSE_RETURN_LOCK_RETRIES|FM_WATCH_PHASE_MARGIN)
      case "$value" in ''|*[!0-9]*|??????????*) return 1 ;; esac
      ;;
    FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS)
      [ -z "$value" ] && return 0
      case "$value" in
        *[!0-9.]*|*.*.*) return 1 ;;
      esac
      printf '%s' "$value" | LC_ALL=C grep -Eq '^([0-9]+([.][0-9]*)?|[.][0-9]+)$'
      ;;
    FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS)
      case "$value" in
        ''|*[!0-9.]*|*.*.*) return 1 ;;
      esac
      printf '%s' "$value" | LC_ALL=C grep -Eq '^([0-9]+([.][0-9]*)?|[.][0-9]+)$'
      ;;
    FM_ARM_ATTACH_POLL)
      case "$value" in
        ''|*[!0-9.]*|*.*.*) return 1 ;;
      esac
      awk -v value="$value" 'BEGIN {
        valid = value ~ /^([0-9]+([.][0-9]*)?|[.][0-9]+)$/
        exit !(valid && value > 0)
      }'
      ;;
    FM_WATCH_AUTO_REAP_TIMEOUT)
      [ -z "$value" ] && return 0
      case "$value" in ''|*[!0-9]*|0|??????????*) return 1 ;; esac
      case "$value" in *[1-9]*) ;; *) return 1 ;; esac
      ;;
    *)
      case "$value" in ''|*[!0-9]*|0|??????????*) return 1 ;; esac
      case "$value" in *[1-9]*) ;; *) return 1 ;; esac
      ;;
  esac
}

fm_watcher_config_load() {  # <config-dir>
  local config_dir=$1 path line raw name suffix value first last line_number=0 LC_ALL=C
  path="$config_dir/watcher.env"
  if [ -n "${FM_WATCHER_CONFIG_LOADED_PATH:-}" ]; then
    [ "$FM_WATCHER_CONFIG_LOADED_PATH" = "$path" ] || {
      printf 'error: watcher config already loaded from %s\n' "$FM_WATCHER_CONFIG_LOADED_PATH" >&2
      return 1
    }
    return 0
  fi
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    FM_WATCHER_CONFIG_LOADED_PATH=$path
    return 0
  fi
  [ -f "$path" ] && [ ! -L "$path" ] || {
    printf 'error: unsafe watcher config: %s\n' "$path" >&2
    return 1
  }
  while IFS= read -r raw || [ -n "$raw" ]; do
    line_number=$((line_number + 1))
    line=${raw%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in export[[:space:]]*) line=${line#export}; line=${line#"${line%%[![:space:]]*}"} ;; esac
    case "$line" in *=*) ;; *)
      printf 'error: invalid watcher config assignment at %s:%s\n' "$path" "$line_number" >&2
      return 1
      ;;
    esac
    name=${line%%=*}
    name=${name%"${name##*[![:space:]]}"}
    suffix=${name#FM_}
    if [ "$suffix" = "$name" ]; then
      printf 'error: invalid watcher config variable at %s:%s\n' "$path" "$line_number" >&2
      return 1
    fi
    case "$suffix" in
      ''|*[!A-Z0-9_]*)
        printf 'error: invalid watcher config variable at %s:%s\n' "$path" "$line_number" >&2
        return 1
        ;;
    esac
    fm_watcher_config_variable_allowed "$name" || {
      printf 'error: watcher config variable %s is not allowed in %s\n' "$name" "$path" >&2
      return 1
    }
    value=${line#*=}
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    if [ -n "$value" ]; then
      first=${value:0:1}
      last=${value: -1}
      if [ "$first" = "'" ] || [ "$first" = '"' ]; then
        [ "$last" = "$first" ] && [ "${#value}" -ge 2 ] || {
          printf 'error: unmatched watcher config quote at %s:%s\n' "$path" "$line_number" >&2
          return 1
        }
        value=${value:1:${#value}-2}
      else
        case "$value" in *[[:space:]]*)
          printf 'error: unquoted watcher config whitespace at %s:%s\n' "$path" "$line_number" >&2
          return 1
          ;;
        esac
      fi
    fi
    fm_watcher_config_value_valid "$name" "$value" || {
      printf 'error: invalid value for watcher config variable %s at %s:%s\n' \
        "$name" "$path" "$line_number" >&2
      return 1
    }
    printf -v "$name" '%s' "$value"
    export "$name"
  done < "$path"
  FM_WATCHER_CONFIG_LOADED_PATH=$path
}

fm_watcher_config_positive_decimal() {  # <name> <default>
  local name=$1 fallback=$2 value
  eval "value=\${$name:-$fallback}"
  if ! awk -v value="$value" 'BEGIN {
    valid = value ~ /^[0-9]+([.][0-9]*)?$/ || value ~ /^[.][0-9]+$/
    exit !(valid && value > 0)
  }'; then
    printf 'error: %s must be a positive decimal\n' "$name" >&2
    return 1
  fi
  printf -v "$name" '%s' "$value"
  export "$name"
}

fm_watcher_config_positive_integer() {  # <name> <default>
  local name=$1 fallback=$2 value
  eval "value=\${$name:-}"
  case "$value" in ''|*[!0-9]*|0) value=$fallback ;; esac
  printf -v "$name" '%s' "$value"
  export "$name"
}
