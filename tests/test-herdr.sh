#!/usr/bin/env bash
# Route real Herdr test traffic through the owned, never-default lab helper.
set -euo pipefail

session=${FM_TEST_HERDR_LAB_SESSION:-}
helper=${FM_TEST_HERDR_LAB_HELPER:-}
argv_helper=${FM_TEST_REPO_ROOT:-}/bin/fm-herdr-lab.sh
original_path=${FM_TEST_ORIGINAL_PATH:-}
client_home=${FM_TEST_HERDR_CLIENT_HOME:-}
lab_state_dir=${FM_TEST_HERDR_LAB_STATE_DIR:-}
client_bin=${FM_TEST_HERDR_CLIENT_BIN:-}

case "$session" in
  fm-lab-?*) ;;
  *)
    printf 'test isolation violation: Herdr resolved outside an owned lab session: %s\n' \
      "${session:-<unset>}" >&2
    exit 97
    ;;
esac
[ -x "$helper" ] || {
  printf 'test isolation violation: Herdr lab helper is not executable: %s\n' \
    "${helper:-<unset>}" >&2
  exit 97
}
[ -x "$argv_helper" ] || {
  printf 'test isolation violation: argv-aware Herdr lab helper is not executable: %s\n' \
    "${argv_helper:-<unset>}" >&2
  exit 97
}
[ -n "$original_path" ] || {
  printf 'test isolation violation: original PATH for Herdr is unset\n' >&2
  exit 97
}
[ -n "$client_home" ] || {
  printf 'test isolation violation: Herdr client home is unset\n' >&2
  exit 97
}
[ -n "$lab_state_dir" ] || {
  printf 'test isolation violation: Herdr lab state directory is unset\n' >&2
  exit 97
}
[ -d "$client_bin" ] || {
  printf 'test isolation violation: Herdr client shim directory is unavailable: %s\n' \
    "${client_bin:-<unset>}" >&2
  exit 97
}
[ "$#" -gt 0 ] || {
  printf 'test isolation violation: Herdr command is empty\n' >&2
  exit 97
}

args=("$@")
count=${#args[@]}
argv_command=0
argv_separator=-1
if [ "$count" -ge 3 ] && [ "${args[0]} ${args[1]}" = "agent start" ]; then
  argv_command=1
  for ((index = 2; index < count; index += 1)); do
    if [ "${args[$index]}" = -- ]; then
      argv_separator=$index
      break
    fi
  done
  [ "$argv_separator" -ge 2 ] || {
    printf 'test isolation violation: Herdr agent start lacks its argv separator\n' >&2
    exit 97
  }
  if [ "$argv_separator" -ge 4 ] \
    && [ "${args[$((argv_separator - 2))]}" = --session ]; then
    [ "${args[$((argv_separator - 1))]}" = "$session" ] || {
      printf 'test isolation violation: Herdr command named foreign session: %s (owned: %s)\n' \
        "${args[$((argv_separator - 1))]}" "$session" >&2
      exit 97
    }
    args=("${args[@]:0:$((argv_separator - 2))}" "${args[@]:$argv_separator}")
  elif [ "$argv_separator" -ge 3 ] \
    && [[ "${args[$((argv_separator - 1))]}" == --session=* ]]; then
    named_session=${args[$((argv_separator - 1))]#--session=}
    [ "$named_session" = "$session" ] || {
      printf 'test isolation violation: Herdr command named foreign session: %s (owned: %s)\n' \
        "$named_session" "$session" >&2
      exit 97
    }
    args=("${args[@]:0:$((argv_separator - 1))}" "${args[@]:$argv_separator}")
  else
    for ((index = 0; index < argv_separator; index += 1)); do
      case "${args[$index]}" in
        --session|--session=*)
          printf 'test isolation violation: Herdr agent start session must immediately precede its argv separator\n' >&2
          exit 97
          ;;
      esac
    done
  fi
elif [ "$count" -ge 2 ] && [ "${args[$((count - 2))]}" = --session ]; then
  [ "${args[$((count - 1))]}" = "$session" ] || {
    printf 'test isolation violation: Herdr command named foreign session: %s (owned: %s)\n' \
      "${args[$((count - 1))]}" "$session" >&2
    exit 97
  }
  args=("${args[@]:0:$((count - 2))}")
elif [ "$count" -ge 1 ] && [[ "${args[$((count - 1))]}" == --session=* ]]; then
  named_session=${args[$((count - 1))]#--session=}
  [ "$named_session" = "$session" ] || {
    printf 'test isolation violation: Herdr command named foreign session: %s (owned: %s)\n' \
      "$named_session" "$session" >&2
    exit 97
  }
  args=("${args[@]:0:$((count - 1))}")
else
  for arg in "${args[@]}"; do
    case "$arg" in
      --session|--session=*)
        printf 'test isolation violation: Herdr --session must be the final argument for owned lab %s\n' \
          "$session" >&2
        exit 97
        ;;
    esac
  done
fi

if [ "$argv_command" = 1 ]; then
  FM_HERDR_LAB_STATE_DIR="$lab_state_dir" \
    PATH="$client_bin:$original_path" HERDR_SESSION="$session" \
    exec "$argv_helper" run-argv "$session" "${args[@]}"
fi
FM_HERDR_LAB_STATE_DIR="$lab_state_dir" \
  PATH="$client_bin:$original_path" HERDR_SESSION="$session" \
  exec "$helper" run "$session" "${args[@]}"
