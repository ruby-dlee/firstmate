#!/usr/bin/env bash
# Send a special key or attempt verified text steering to a crewmate endpoint.
# Usage: fm-send.sh <target> <text...>
#   <target> may be an exact task id, a legacy fm-<id> task label resolved
#   through this home's state/<id>.meta, or an explicit well-formed backend
#   target. fm-send refuses unresolved guesses rather than falling back to a
#   tmux window search, because a "successful" send to the wrong endpoint is
#   worse than a loud failure.
# Special keys instead of text: fm-send.sh <target> --key Enter
# Key support is backend-specific: tmux/herdr support Escape, Enter, and C-c;
# Orca currently supports Enter and C-c only, and rejects Escape.
#
# Text steering is admitted only through an atomic agent-session-bound backend
# operation. Current terminal adapters expose pane input or literal native input
# plus a later submit, so text steering fails closed on every backend.
#
# From-firstmate marker: when the resolved target is a task selector whose meta
# records kind=secondmate, the text is prefixed with the from-firstmate marker
# (bin/fm-marker-lib.sh) so the secondmate routes its reply via its status file
# or a status-pointed doc instead of stranding it in chat the main firstmate
# never reads. A crewmate/scout target, an explicit backend-target escape-hatch
# target, and the --key path are never marked - their behavior is unchanged.
# Successful text steering for a managed account task is also appended to the
# task-owned data/<id>/steering.md trail for provider-neutral continuation.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never steer
# a crewmate (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-send refuses to resolve targets without an explicit firstmate home" >&2
  exit 1
fi

STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
if [ ! -d "$FM_HOME" ]; then
  echo "error: FM_HOME '$FM_HOME' is not a directory; fm-send cannot resolve this home's state" >&2
  exit 1
fi
if [ ! -d "$STATE" ]; then
  echo "error: state dir '$STATE' is missing; fm-send cannot resolve targets for FM_HOME '$FM_HOME'" >&2
  exit 1
fi

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-account-routing-lib.sh
. "$SCRIPT_DIR/fm-account-routing-lib.sh"
# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"

FM_GUARD_CONTINUE_LINE='This is a supervision warning only; backend admission still decides whether the requested action is safe.' "$SCRIPT_DIR/fm-guard.sh" || true

fm_send_id_from_meta() {  # <meta-file>
  local base
  base=${1##*/}
  printf '%s' "${base%.meta}"
}

fm_send_meta_for_key_value() {  # <state-dir> <key> <value>
  local state=$1 key=$2 value=$3 meta got
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    got=$(fm_meta_get "$meta" "$key")
    [ "$got" = "$value" ] || continue
    printf '%s' "$meta"
    return 0
  done
  return 1
}

fm_send_count_colons() {  # <string>
  local s=$1 no_colons
  no_colons=${s//:/}
  printf '%s' $(( ${#s} - ${#no_colons} ))
}

fm_send_resolve_target() {  # <raw-target>
  local raw=$1 meta pane_meta target backend assumed colons id session hint

  RESOLVED_TARGET=""
  TARGET_BACKEND=""
  TARGET_HARNESS=""
  EXPECTED_LABEL=""
  TARGET_META=""
  TARGET_SELECTOR=""
  RESOLUTION_TRIED=""

  meta=$(fm_backend_meta_for_selector "$raw" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    RESOLUTION_TRIED="meta=$meta; backend=from-meta"
    target=$(fm_backend_target_of_meta "$meta")
    if [ -z "$target" ]; then
      echo "error: no backend target recorded in $meta (tried $RESOLUTION_TRIED)" >&2
      return 1
    fi
    backend=$(fm_backend_of_meta "$meta")
    RESOLVED_TARGET=$target
    TARGET_BACKEND=$backend
    TARGET_META=$meta
    TARGET_HARNESS=$(fm_meta_get "$meta" harness)
    EXPECTED_LABEL=$(fm_backend_expected_label_of_selector "$raw" "$STATE")
    TARGET_SELECTOR=1
    return 0
  fi

  case "$raw" in
    fm-*)
      RESOLUTION_TRIED="meta=$STATE/$raw.meta; legacy-meta=$STATE/${raw#fm-}.meta; backend=none"
      echo "error: no metadata for $raw in $STATE (tried $RESOLUTION_TRIED); pass a well-formed explicit backend target only when targeting outside this firstmate home" >&2
      return 1
      ;;
  esac

  pane_meta=$(fm_send_meta_for_key_value "$STATE" herdr_pane_id "$raw" 2>/dev/null || true)
  if [ -n "$pane_meta" ]; then
    session=$(fm_meta_get "$pane_meta" herdr_session)
    hint="${session:-<herdr-session>}:$raw"
    id=$(fm_send_id_from_meta "$pane_meta")
    echo "error: target '$raw' matches herdr_pane_id in $pane_meta but is missing its herdr session prefix; expected <herdr-session>:<pane-id> such as '$hint' or use 'fm-$id' (tried meta=$STATE/$raw.meta; backend=herdr)" >&2
    return 1
  fi

  meta=$(fm_backend_meta_for_window "$raw" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    target=$(fm_backend_target_of_meta "$meta")
    if [ -z "$target" ]; then
      echo "error: no backend target recorded in $meta (tried explicit target '$raw' via recorded window/terminal; backend=from-meta)" >&2
      return 1
    fi
    RESOLVED_TARGET=$target
    TARGET_BACKEND=$(fm_backend_of_meta "$meta")
    TARGET_META=$meta
    TARGET_HARNESS=$(fm_meta_get "$meta" harness)
    id=$(fm_send_id_from_meta "$meta")
    EXPECTED_LABEL="fm-$id"
    RESOLUTION_TRIED="explicit target '$raw' matched $meta; backend=$TARGET_BACKEND"
    return 0
  fi

  case "$raw" in
    *:*)
      colons=$(fm_send_count_colons "$raw")
      if [ "$colons" -ge 2 ]; then
        assumed=herdr
      else
        assumed=tmux
      fi
      if ! fm_backend_target_exists "$assumed" "$raw"; then
        echo "error: explicit target '$raw' is not a live $assumed endpoint (tried meta=$STATE/$raw.meta; metadata window/terminal lookup; backend=$assumed). Use fm-<id> for a recorded task/lane, or pass a target whose backend endpoint can be verified." >&2
        return 1
      fi
      RESOLVED_TARGET=$raw
      TARGET_BACKEND=$assumed
      RESOLUTION_TRIED="meta=$STATE/$raw.meta; metadata window/terminal lookup; backend=$assumed; endpoint=verified"
      return 0
      ;;
  esac

  echo "error: target '$raw' is not resolvable (tried meta=$STATE/$raw.meta; metadata window/terminal lookup; backend=none). Use fm-$raw for a recorded task/lane, or pass a well-formed explicit backend target such as session:window." >&2
  return 1
}

RAW_TARGET=$1
fm_send_resolve_target "$RAW_TARGET" || exit 1
T=$RESOLVED_TARGET
shift

fm_backend_validate "$TARGET_BACKEND" || exit 1

# Classify a from-firstmate -> secondmate request. Only a task selector resolved
# through this home's meta whose authoritative kind is secondmate is marked: the
# secondmate then routes its reply via the status path (see fm-marker-lib.sh).
# An explicit backend target (the escape hatch for endpoints outside this home)
# and any crewmate/scout target are left unmarked, and so is the --key path.
MARK_FROM_FIRSTMATE=0
if [ -n "$TARGET_SELECTOR" ] && [ -n "$TARGET_META" ] && [ "$(fm_meta_get "$TARGET_META" kind)" = secondmate ]; then
  MARK_FROM_FIRSTMATE=1
fi

# Resolve the target's harness from its meta (recorded by fm-spawn), used only to
# scope the codex `$<skill>` popup-settle below. A task selector carries
# meta; an explicit backend-target escape hatch has none, so its harness is
# unknown and treated as non-codex (the safe default that keeps the fast path).
# The target's BACKEND comes from selector meta, from matching an explicit target
# back to recorded meta, or from strict explicit-target shape validation.
# Do not add a separate passive liveness preflight here. Active send paths own
# backend readiness: herdr, for example, must route through its session-aware
# target_ready path before sending, while zellij verifies pane labels in its
# send implementation. A failed backend send is still surfaced below as a hard
# error with the attempted resolution attached.

MANAGED_LIFECYCLE_LOCK=
MANAGED_STEERING_ID=
EXPECTED_ACCOUNT_PROFILE=
EXPECTED_GENERATION=
RECORDED_SCOPED_TARGET=
if [ -n "$TARGET_META" ]; then
  EXPECTED_ACCOUNT_PROFILE=$(fm_meta_get "$TARGET_META" account_profile)
  [ "$TARGET_BACKEND" != tmux ] || RECORDED_SCOPED_TARGET=$(fm_meta_get "$TARGET_META" tmux_session_target)
fi
if [ -n "$EXPECTED_ACCOUNT_PROFILE" ]; then
  MANAGED_STEERING_ID=$(fm_send_id_from_meta "$TARGET_META")
  EXPECTED_GENERATION=$(fm_meta_get "$TARGET_META" generation_id)
  [ -n "$EXPECTED_GENERATION" ] || {
    echo "error: managed task metadata has no generation_id: $TARGET_META" >&2
    exit 1
  }
  MANAGED_LIFECYCLE_LOCK=$(fm_account_lifecycle_lock_acquire "$STATE" "$MANAGED_STEERING_ID") || exit 1
  cleanup_managed_send_lifecycle() {
    [ -z "$MANAGED_LIFECYCLE_LOCK" ] \
      || fm_account_lifecycle_lock_release "$MANAGED_LIFECYCLE_LOCK" >/dev/null 2>&1 \
      || true
  }
  trap cleanup_managed_send_lifecycle EXIT
  trap 'exit 1' HUP INT TERM
  if [ ! -f "$TARGET_META" ] || [ -L "$TARGET_META" ] \
    || [ "$(fm_meta_get "$TARGET_META" generation_id)" != "$EXPECTED_GENERATION" ] \
    || [ "$(fm_meta_get "$TARGET_META" account_profile)" != "$EXPECTED_ACCOUNT_PROFILE" ] \
    || [ "$(fm_backend_of_meta "$TARGET_META")" != "$TARGET_BACKEND" ] \
    || [ "$(fm_backend_target_of_meta "$TARGET_META")" != "$T" ]; then
    echo "error: managed task generation or endpoint changed while fm-send waited for $MANAGED_STEERING_ID" >&2
    exit 1
  fi
fi

verify_codex_runtime_if_owned() {
  local account_home task_id
  [ "$TARGET_HARNESS" = codex ] || return 0
  [ -n "$TARGET_META" ] || return 0
  account_home=$(fm_meta_get "$TARGET_META" account_home)
  [ -n "$account_home" ] || return 0
  task_id=$(fm_send_id_from_meta "$TARGET_META")
  if ! "$SCRIPT_DIR/fm-runtime-profile.sh" "$task_id"; then
    echo "error: Codex runtime profile verification failed for $task_id; refusing to claim or deliver steering under an unproved model" >&2
    return 1
  fi
}

# Direct Codex accounts expose the harness-owned rollout record.
# Check it immediately before every steer, then again after delivery below.
verify_codex_runtime_if_owned || exit 1

if [ "${1:-}" = "--key" ]; then
  if ! fm_backend_send_key "$TARGET_BACKEND" "$T" "$2" "$EXPECTED_LABEL" "$RECORDED_SCOPED_TARGET"; then
    echo "error: key '$2' not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
    exit 1
  fi
  if ! fm_backend_capture "$TARGET_BACKEND" "$T" 2 "$EXPECTED_LABEL" "$RECORDED_SCOPED_TARGET" >/dev/null; then
    echo "error: key '$2' was submitted to $T but the required target verification read failed; delivery is unconfirmed" >&2
    exit 1
  fi
  verify_codex_runtime_if_owned || exit 1
  if [ -n "$MANAGED_LIFECYCLE_LOCK" ]; then
    if fm_account_lifecycle_lock_release "$MANAGED_LIFECYCLE_LOCK"; then
      MANAGED_LIFECYCLE_LOCK=
    else
      echo "warning: key '$2' was sent to $T but its managed lifecycle lock could not be released cleanly" >&2
    fi
  fi
  printf 'delivered: key %s to %s (target verification read passed)\n' "$2" "$T"
else
  MESSAGE=$*
  if [ "$MARK_FROM_FIRSTMATE" = 1 ]; then
    fm_message_mark_from_firstmate "$MESSAGE" MESSAGE
  fi
  persist_managed_steering() (  # <file-name> <header> <annotation> <message...>
    local file_name=$1 header=$2 annotation=$3
    shift 3
    local steering_id steering_dir steering_file steering_lock
    steering_id=$(fm_send_id_from_meta "$TARGET_META")
    steering_lock=$(fm_account_lock_acquire "$STATE" "$steering_id" account-steering "managed steering" "${FM_ACCOUNT_STEERING_LOCK_WAIT_SECONDS:-10}") || return 1
    trap 'fm_account_meta_lock_release "$steering_lock" >/dev/null 2>&1 || true' EXIT
    trap 'exit 1' HUP INT TERM
    steering_dir=$(fm_account_task_dir "$DATA" "$steering_id" create) || return 1
    steering_file="$steering_dir/$file_name"
    fm_account_safe_task_file "$steering_file" || return 1
    {
      printf -- '- %s%s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$annotation"
      if [ "$#" -gt 0 ]; then
        printf '%s\n' "$*" | sed 's/^/> /'
        printf '\n'
      fi
    } | node "$SCRIPT_DIR/fm-task-file-append.mjs" "$DATA" "$steering_id" "$file_name" "$header"
  )
  record_managed_steering() {
    persist_managed_steering steering.md '# Steering trail' '' "$@"
  }
  record_pending_managed_steering() {
    persist_managed_steering steering-pending.md '' ' (delivered; steering trail append pending)' "$@"
  }
  record_unconfirmed_managed_steering() {
    persist_managed_steering steering-unconfirmed.md '# Unconfirmed steering' ' (delivery unconfirmed)' "$@"
  }
  record_managed_delivery_event() {
    if [ "$#" -gt 1 ]; then
      persist_managed_steering steering-journal.md '# Steering delivery journal' " (intent $STEERING_EVENT_ID $1)" "$2"
    else
      persist_managed_steering steering-journal.md '# Steering delivery journal' " (intent $STEERING_EVENT_ID $1)"
    fi
  }
  if [ -n "$MANAGED_STEERING_ID" ]; then
    STEERING_EVENT_ID=$(python3 -c 'import secrets; print(secrets.token_hex(16))') || {
      echo "error: could not allocate a managed steering intent id" >&2
      exit 1
    }
    if ! record_managed_delivery_event pending "$MESSAGE"; then
      echo "error: managed steering intent could not be durably recorded before delivery" >&2
      exit 1
    fi
  fi
  if ! fm_backend_send_steering "$TARGET_BACKEND" "$T" "$MESSAGE" "$EXPECTED_LABEL" "$RECORDED_SCOPED_TARGET"; then
    [ -z "$MANAGED_STEERING_ID" ] || record_managed_delivery_event send-failed >/dev/null 2>&1 || true
    echo "error: text not sent to $T (no atomic agent-session-bound $TARGET_BACKEND route; tried $RESOLUTION_TRIED)" >&2
    exit 1
  fi
  verify_codex_runtime_if_owned || exit 1
  if [ -n "$MANAGED_STEERING_ID" ]; then
    record_managed_delivery_event confirmed >/dev/null 2>&1 || true
    if ! record_managed_steering "$MESSAGE"; then
      if record_pending_managed_steering "$MESSAGE"; then
        echo "warning: text was delivered atomically and recorded as pending because its steering trail could not be appended" >&2
      else
        echo "warning: text was delivered atomically but its managed steering delivery could not be durably recorded" >&2
      fi
    fi
    if fm_account_lifecycle_lock_release "$MANAGED_LIFECYCLE_LOCK"; then
      MANAGED_LIFECYCLE_LOCK=
    else
      echo "warning: text was delivered atomically but its managed lifecycle lock could not be released cleanly" >&2
    fi
  fi
  printf 'delivered: text to %s (atomic agent-session-bound submit)\n' "$T"
fi
