#!/usr/bin/env bash

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
    case "$name" in
      FM_HOME|FM_ROOT_OVERRIDE|FM_STATE_OVERRIDE|FM_CONFIG_OVERRIDE|FM_DATA_OVERRIDE|FM_PROJECTS_OVERRIDE|FM_PROCESS_TREE_RESULT_FILE)
        printf 'error: structural variable %s is not allowed in %s\n' "$name" "$path" >&2
        return 1
        ;;
    esac
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
    printf -v "$name" '%s' "$value"
    export "$name"
  done < "$path"
  FM_WATCHER_CONFIG_LOADED_PATH=$path
}

fm_watcher_config_positive_integer() {  # <name> <default>
  local name=$1 fallback=$2 value
  eval "value=\${$name:-}"
  case "$value" in ''|*[!0-9]*|0) value=$fallback ;; esac
  printf -v "$name" '%s' "$value"
  export "$name"
}
