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
# Enforce atomically reserves one profile after endpoint and worktree setup,
# immediately before provider launch, and fails closed on every Agent Fleet or
# validation error.
#
# FM_AGENT_FLEET_BIN may name a deterministic fake or a pinned candidate in
# tests/labs. Otherwise `agent-fleet` is resolved from PATH.

fm_account_shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

fm_account_run_bounded() {
  local seconds=$1
  shift
  case "$seconds" in ''|*[!0-9]*|0) return 2 ;; esac
  if command -v timeout >/dev/null 2>&1; then
    timeout --kill-after=1 "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout --kill-after=1 "$seconds" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$seconds" "$@"
  else
    return 127
  fi
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

fm_account_control_timeout() {
  local seconds=${FM_ACCOUNT_CONTROL_TIMEOUT:-10}
  case "$seconds" in
    ''|*[!0-9]*|0)
      echo "error: FM_ACCOUNT_CONTROL_TIMEOUT must be a positive integer" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$seconds"
}

fm_account_run_control() {
  local seconds
  seconds=$(fm_account_control_timeout) || return 1
  fm_account_run_bounded "$seconds" "$@"
}

FM_ACCOUNT_CONTRACT_BIN=
fm_account_validate_contract() {  # <agent-fleet-bin>
  local binary=$1 json version
  [ "$FM_ACCOUNT_CONTRACT_BIN" != "$binary" ] || return 0
  command -v jq >/dev/null 2>&1 || {
    echo "error: jq is required for account routing" >&2
    return 1
  }
  json=$(fm_account_run_control "$binary" --format json contract 2>/dev/null) || {
    echo "error: cannot verify the Agent Fleet contract" >&2
    return 1
  }
  version=$(printf '%s\n' "$json" | jq -er '.contract_version | select(type == "number")' 2>/dev/null) || {
    echo "error: agent-fleet returned an invalid contract" >&2
    return 1
  }
  [ "$version" = 1 ] || {
    echo "error: unsupported Agent Fleet contract version $version (expected 1)" >&2
    return 1
  }
  FM_ACCOUNT_CONTRACT_BIN=$binary
}

fm_account_read_single_value() {  # <file>
  local file=$1 values count value
  [ -e "$file" ] || return 1
  [ -f "$file" ] && [ -r "$file" ] || {
    echo "error: cannot read $file" >&2
    return 2
  }
  values=$(awk '
    {
      sub(/[[:space:]]*#.*/, "")
      gsub(/[[:space:]]/, "")
      if (length($0) > 0) print
    }
  ' "$file") || {
    echo "error: cannot read $file" >&2
    return 2
  }
  count=$(printf '%s\n' "$values" | awk 'NF { count++ } END { print count + 0 }')
  [ "$count" -le 1 ] || {
    echo "error: $file must contain exactly one value" >&2
    return 2
  }
  [ "$count" -eq 1 ] || return 1
  value=$(printf '%s\n' "$values" | awk 'NF { print; exit }')
  printf '%s\n' "$value"
}

fm_account_resolve_mode() {  # <config-dir> <explicit-route:0|1> <disabled:0|1>
  local config=$1 explicit=$2 disabled=$3 value source status
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
  else
    if value=$(fm_account_read_single_value "$config/account-routing-mode"); then
      status=0
    else
      status=$?
    fi
    case "$status" in
      0) source=config/account-routing-mode ;;
      1) value=off; source=default ;;
      *) return "$status" ;;
    esac
  fi
  case "$value" in
    off|observe|enforce) printf '%s\n' "$value" ;;
    *) echo "error: invalid account routing mode '$value' from $source (expected off, observe, or enforce)" >&2; return 1 ;;
  esac
}

fm_account_attempt_id() {  # <home> <task>
  local home=$1 task=$2 seed
  fm_account_valid_id "$task" || {
    echo "error: invalid task id '$task' for account routing" >&2
    return 1
  }
  seed=$(printf '%s\n%s\n%s\n%s\n%s\n' "$home" "$task" "$$" "$(date +%s)" "${RANDOM:-0}" | git hash-object --stdin 2>/dev/null) || {
    echo "error: cannot generate Agent Fleet attempt identity" >&2
    return 1
  }
  printf 'a%.15s\n' "$seed"
}

fm_account_task_key() {  # <home> <task> <attempt>
  local home=$1 task=$2 attempt=$3 abs_home home_hash
  fm_account_valid_id "$task" || { echo "error: invalid task id '$task' for account routing" >&2; return 1; }
  fm_account_valid_id "$attempt" || { echo "error: invalid account attempt '$attempt'" >&2; return 1; }
  abs_home=$(cd "$home" 2>/dev/null && pwd -P) || {
    echo "error: cannot resolve firstmate home for account routing: $home" >&2
    return 1
  }
  home_hash=$(printf '%s\n' "$abs_home" | git hash-object --stdin 2>/dev/null) || {
    echo "error: cannot namespace Agent Fleet task for $abs_home" >&2
    return 1
  }
  printf 'fm-%.16s-%s-%s\n' "$home_hash" "$task" "$attempt"
}

fm_account_process_start_time() {  # <pid>
  local out
  out=$(LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null) || return 1
  out=$(printf '%s\n' "$out" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

fm_account_meta_lock_owner_alive() {  # <lock-path>
  local lock=$1 owner pid recorded current
  if [ -f "$lock" ] && [ ! -L "$lock" ]; then
    owner=$lock
  elif [ -d "$lock" ] && [ ! -L "$lock" ]; then
    owner=$lock/owner
  else
    return 1
  fi
  [ -f "$owner" ] || return 1
  pid=$(sed -n '1p' "$owner" 2>/dev/null)
  recorded=$(sed -n '2p' "$owner" 2>/dev/null)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$recorded" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  current=$(fm_account_process_start_time "$pid") || return 1
  [ "$current" = "$recorded" ]
}

fm_account_path_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

fm_account_path_inode() {
  stat -f %i "$1" 2>/dev/null || stat -c %i "$1" 2>/dev/null
}

fm_account_meta_lock_reclaim() {  # <lock-path> <ownerless-grace-seconds>
  local lock=$1 grace=$2 now mtime reclaim guard inode_before inode_after
  local ownerless_since baseline required_grace
  [ ! -L "$lock" ] || return 1
  if [ -f "$lock" ]; then
    guard="$lock.reclaiming"
    mkdir "$guard" 2>/dev/null || return 1
    inode_before=$(fm_account_path_inode "$lock") || { rmdir "$guard" 2>/dev/null || true; return 1; }
    if fm_account_meta_lock_owner_alive "$lock"; then
      rmdir "$guard" 2>/dev/null || true
      return 1
    fi
    inode_after=$(fm_account_path_inode "$lock") || { rmdir "$guard" 2>/dev/null || true; return 1; }
    if [ "$inode_before" != "$inode_after" ]; then
      rmdir "$guard" 2>/dev/null || true
      return 1
    fi
    rm -f "$lock" || { rmdir "$guard" 2>/dev/null || true; return 1; }
    rmdir "$guard" 2>/dev/null || true
    return 0
  fi
  [ -d "$lock" ] || return 1
  inode_before=$(fm_account_path_inode "$lock") || return 1
  mtime=$(fm_account_path_mtime "$lock") || return 1
  guard="$lock/.reclaiming"
  mkdir "$guard" 2>/dev/null || return 1
  inode_after=$(fm_account_path_inode "$lock") || { rmdir "$guard" 2>/dev/null || true; return 1; }
  if [ "$inode_before" != "$inode_after" ]; then
    rmdir "$guard" 2>/dev/null || true
    return 1
  fi
  if [ -f "$lock/owner" ]; then
    if fm_account_meta_lock_owner_alive "$lock"; then
      rmdir "$guard" 2>/dev/null || true
      return 1
    fi
  else
    ownerless_since="$lock/.ownerless-since"
    if [ ! -f "$ownerless_since" ]; then
      printf '%s\n' "$mtime" > "$ownerless_since" || {
        rmdir "$guard" 2>/dev/null || true
        return 1
      }
    fi
    baseline=$(sed -n '1p' "$ownerless_since" 2>/dev/null)
    case "$baseline" in
      ''|*[!0-9]*) rmdir "$guard" 2>/dev/null || true; return 1 ;;
    esac
    required_grace=$grace
    [ "$required_grace" -ge 1 ] || required_grace=1
    now=$(date +%s)
    if [ $((now - baseline)) -lt "$required_grace" ]; then
      if fm_account_meta_lock_owner_alive "$lock"; then
        rm -f "$ownerless_since"
      fi
      rmdir "$guard" 2>/dev/null || true
      return 1
    fi
  fi
  if fm_account_meta_lock_owner_alive "$lock"; then
    rm -f "$lock/.ownerless-since"
    rmdir "$guard" 2>/dev/null || true
    return 1
  fi
  reclaim="$lock.reclaim.$$.$RANDOM"
  mv "$lock" "$reclaim" 2>/dev/null || { rmdir "$guard" 2>/dev/null || true; return 1; }
  rm -rf "$reclaim"
}

fm_account_meta_lock_acquire() {  # <state-dir> <task>
  local state=$1 task=$2 lock deadline now start owner_tmp owner_inode lock_inode
  local wait_seconds=${FM_ACCOUNT_META_LOCK_WAIT_SECONDS:-10}
  local ownerless_grace=${FM_ACCOUNT_META_LOCK_ORPHAN_GRACE_SECONDS:-2}
  fm_account_valid_id "$task" || { echo "error: invalid task id '$task' for account metadata lock" >&2; return 1; }
  case "$wait_seconds" in ''|*[!0-9]*) echo "error: invalid account metadata lock wait '$wait_seconds'" >&2; return 1 ;; esac
  case "$ownerless_grace" in ''|*[!0-9]*) echo "error: invalid account metadata lock ownerless grace '$ownerless_grace'" >&2; return 1 ;; esac
  start=$(fm_account_process_start_time "$$") || {
    echo "error: cannot record account metadata lock owner for $task" >&2
    return 1
  }
  mkdir -p "$state" || return 1
  lock="$state/.account-meta-$task.lock"
  owner_tmp="$state/.account-meta-$task.owner.$$.$RANDOM"
  printf '%s\n%s\n' "$$" "$start" > "$owner_tmp" || {
    rm -f "$owner_tmp"
    return 1
  }
  owner_inode=$(fm_account_path_inode "$owner_tmp") || { rm -f "$owner_tmp"; return 1; }
  deadline=$(( $(date +%s) + wait_seconds ))
  while :; do
    if ln -n "$owner_tmp" "$lock" 2>/dev/null; then
      lock_inode=$(fm_account_path_inode "$lock" 2>/dev/null || true)
      if [ -f "$lock" ] && [ ! -L "$lock" ] && [ "$lock_inode" = "$owner_inode" ]; then
        break
      fi
      if [ -d "$lock" ] && [ ! -L "$lock" ]; then
        rm -f "$lock/${owner_tmp##*/}" 2>/dev/null || true
      fi
    fi
    if fm_account_meta_lock_reclaim "$lock" "$ownerless_grace"; then
      continue
    fi
    now=$(date +%s)
    [ "$now" -lt "$deadline" ] || {
      echo "error: timed out waiting for account metadata lock for $task" >&2
      rm -f "$owner_tmp"
      return 1
    }
    sleep 0.05
  done
  rm -f "$owner_tmp"
  printf '%s\n' "$lock"
}

fm_account_meta_lock_release() {  # <lock-path>
  local lock=$1 owner pid released
  [ -e "$lock" ] || return 0
  if [ -f "$lock" ] && [ ! -L "$lock" ]; then
    owner=$lock
  elif [ -d "$lock" ] && [ ! -L "$lock" ]; then
    owner=$lock/owner
  else
    echo "error: refusing to release unsafe account metadata lock $lock" >&2
    return 1
  fi
  pid=$(sed -n '1p' "$owner" 2>/dev/null)
  [ "$pid" = "$$" ] || {
    echo "error: refusing to release account metadata lock owned by ${pid:-unknown}" >&2
    return 1
  }
  if [ -f "$lock" ]; then
    rm -f "$lock"
    return
  fi
  released="$lock.release.$$.$RANDOM"
  mv "$lock" "$released" || return 1
  rm -rf "$released"
}

fm_account_safe_lineage_value() {
  case "$1" in *$'\t'*|*$'\n'*) return 1 ;; esac
}

fm_account_lineage_append() {  # <data-dir> <task> <event> <attempt> <fleet-task> <provider> <pool> <profile> <session> <predecessor>
  local data=$1 task=$2 event=$3 attempt=$4 fleet_task=$5 provider=$6 pool=$7 profile=$8 session=$9 predecessor=${10} dir value
  for value in "$task" "$event" "$attempt" "$fleet_task" "$provider" "$pool" "$profile" "$session" "$predecessor"; do
    fm_account_safe_lineage_value "$value" || {
      echo "error: unsafe account-attempt lineage value" >&2
      return 1
    }
  done
  dir="$data/$task"
  mkdir -p "$dir" || return 1
  if [ ! -f "$dir/account-attempts.md" ]; then
    printf '# Account attempt lineage\n\n' > "$dir/account-attempts.md"
  fi
  printf -- '- %s event=%s attempt=%s agent_fleet_task=%s provider=%s pool=%s profile=%s session=%s predecessor=%s.\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event" "$attempt" "$fleet_task" "$provider" "$pool" "$profile" "${session:-pending}" "${predecessor:-none}" \
    >> "$dir/account-attempts.md"
}

fm_account_meta_value() {  # <meta> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1
}

fm_account_restore_artifacts() {
  local state=$1 task=$2 backup_name=$3 tasktmp=${4:-} retain=${5:-0} backup name source
  [ -n "$backup_name" ] || return 0
  case "$backup_name" in
    ".$task.artifacts.rollback."*) ;;
    *) return 1 ;;
  esac
  fm_account_valid_id "${backup_name#".$task.artifacts.rollback."}" || return 1
  backup="$state/$backup_name"
  [ -d "$backup" ] && [ ! -L "$backup" ] || return 1
  for name in "$task.status" "$task.turn-ended" "$task.check.sh" "$task.pi-ext.ts" "$task.grok-turnend-token"; do
    rm -f "$state/$name" || return 1
    source="$backup/$name"
    if [ -e "$source" ] || [ -L "$source" ]; then
      cp -Pp "$source" "$state/$name" || return 1
    fi
  done
  if [ -n "$tasktmp" ]; then
    [ "$tasktmp" = "/tmp/fm-$task" ] || return 1
    if [ -e "$backup/tasktmp-existed" ]; then
      [ -e "$backup/gotmp-existed" ] || rm -rf "$tasktmp/gotmp" || return 1
    else
      rm -rf "$tasktmp" || return 1
    fi
  fi
  [ "$retain" = 1 ] || rm -rf "$backup"
}

fm_account_cleanup_rollback() {  # <meta> <data-dir> <task>
  local meta=$1 data=$2 task=$3 pending account_task attempt provider pool profile session preserve backup_name backup_token backup predecessor backup_task tmp artifacts_name artifacts_token artifacts tasktmp
  pending=$(fm_account_meta_value "$meta" account_rollback_cleanup)
  [ "$pending" = pending ] || return 0
  account_task=$(fm_account_meta_value "$meta" account_task)
  attempt=$(fm_account_meta_value "$meta" account_attempt)
  provider=$(fm_account_meta_value "$meta" harness)
  pool=$(fm_account_meta_value "$meta" account_pool)
  profile=$(fm_account_meta_value "$meta" account_profile)
  session=$(fm_account_meta_value "$meta" provider_session_id)
  preserve=$(fm_account_meta_value "$meta" account_rollback_preserve_session)
  backup_name=$(fm_account_meta_value "$meta" account_rollback_backup)
  artifacts_name=$(fm_account_meta_value "$meta" account_rollback_artifacts)
  tasktmp=$(fm_account_meta_value "$meta" tasktmp)
  predecessor=$(fm_account_meta_value "$meta" account_predecessor_task)
  fm_account_valid_id "$account_task" || {
    echo "error: invalid failed Agent Fleet attempt for $task" >&2
    return 1
  }
  case "$preserve" in ''|0|1) ;; *) echo "error: invalid rollback session policy for $task" >&2; return 1 ;; esac
  backup=
  if [ -n "$backup_name" ]; then
    case "$backup_name" in
      ".$task.meta.rollback."*) ;;
      *) echo "error: unsafe rollback backup for $task" >&2; return 1 ;;
    esac
    backup_token=${backup_name#".$task.meta.rollback."}
    fm_account_valid_id "$backup_token" || { echo "error: unsafe rollback backup for $task" >&2; return 1; }
    backup="$(dirname "$meta")/$backup_name"
    [ -f "$backup" ] || {
      echo "error: rollback backup is missing for $task" >&2
      return 1
    }
    backup_task=$(fm_account_meta_value "$backup" account_task)
    if [ -n "$predecessor" ]; then
      [ "$backup_task" = "$predecessor" ] || {
        echo "error: rollback backup does not match the predecessor for $task" >&2
        return 1
      }
    elif [ "$preserve" = 1 ]; then
      [ "$backup_task" = "$account_task" ] || {
        echo "error: rollback backup does not match the native recovery for $task" >&2
        return 1
      }
    fi
  fi
  artifacts=
  if [ -n "$artifacts_name" ]; then
    case "$artifacts_name" in
      ".$task.artifacts.rollback."*) ;;
      *) echo "error: unsafe rollback artifact backup for $task" >&2; return 1 ;;
    esac
    artifacts_token=${artifacts_name#".$task.artifacts.rollback."}
    fm_account_valid_id "$artifacts_token" || { echo "error: unsafe rollback artifact backup for $task" >&2; return 1; }
    artifacts="$(dirname "$meta")/$artifacts_name"
    [ -d "$artifacts" ] && [ ! -L "$artifacts" ] || {
      echo "error: rollback artifact backup is missing for $task" >&2
      return 1
    }
  fi
  fm_account_release "$account_task" --force || return 1
  if [ "$preserve" != 1 ]; then
    fm_account_session_remove "$account_task" || return 1
  fi
  fm_account_restore_artifacts "$(dirname "$meta")" "$task" "$artifacts_name" "$tasktmp" 1 || return 1
  if [ -n "$backup" ]; then
    mv "$backup" "$meta" || return 1
  else
    tmp="$(dirname "$meta")/.$task.meta.rollback-clean.$$"
    awk '!/^account_/ && !/^provider_session_id=/ && !/^continuation_packet=/ && !/^rollback_pending=/' "$meta" > "$tmp" || { rm -f "$tmp"; return 1; }
    printf 'rollback_pending=1\n' >> "$tmp"
    mv "$tmp" "$meta" || { rm -f "$tmp"; return 1; }
  fi
  [ -z "$artifacts" ] || rm -rf "$artifacts"
  [ -n "$attempt" ] || attempt=legacy
  fm_account_lineage_append "$data" "$task" rolled-back "$attempt" "$account_task" "$provider" "$pool" "$profile" "$session" "${predecessor:-none}" || {
    echo "warning: failed attempt cleanup completed but lineage recording failed for $task" >&2
  }
}

fm_account_cleanup_predecessor() {  # <meta> <data-dir> <task>
  local meta=$1 data=$2 task=$3 pending predecessor current attempt provider pool profile session tmp
  pending=$(fm_account_meta_value "$meta" account_predecessor_cleanup)
  [ "$pending" = pending ] || return 0
  predecessor=$(fm_account_meta_value "$meta" account_predecessor_task)
  current=$(fm_account_meta_value "$meta" account_task)
  attempt=$(fm_account_meta_value "$meta" account_predecessor_attempt)
  provider=$(fm_account_meta_value "$meta" account_predecessor_provider)
  [ -n "$provider" ] || provider=$(fm_account_meta_value "$meta" harness)
  pool=$(fm_account_meta_value "$meta" account_predecessor_pool)
  profile=$(fm_account_meta_value "$meta" account_predecessor_profile)
  session=$(fm_account_meta_value "$meta" account_predecessor_session)
  [ -n "$predecessor" ] && [ -n "$current" ] && [ "$predecessor" != "$current" ] || {
    echo "error: invalid predecessor cleanup metadata for $task" >&2
    return 1
  }
  if ! fm_account_valid_id "$predecessor" || ! fm_account_valid_id "$current"; then
    echo "error: unsafe predecessor cleanup identity for $task" >&2
    return 1
  fi
  [ -n "$(fm_account_meta_value "$meta" provider_session_id)" ] || {
    echo "error: current managed session is unverified for predecessor cleanup of $task" >&2
    return 1
  }
  fm_account_release "$predecessor" --force || return 1
  fm_account_session_remove "$predecessor" || return 1
  tmp="$(dirname "$meta")/.$task.meta.predecessor.$$"
  awk '!/^account_predecessor_/ && !/^account_predecessor_cleanup=/' "$meta" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$meta" || { rm -f "$tmp"; return 1; }
  [ -n "$attempt" ] || attempt=legacy
  fm_account_lineage_append "$data" "$task" predecessor-released "$attempt" "$predecessor" "$provider" "$pool" "$profile" "$session" "$current" || {
    echo "warning: predecessor cleanup completed but lineage recording failed for $task" >&2
  }
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
  local mode=$1 harness=$2 pool=$3 requested_profile=$4 task=$5 binary json status acquired=0 selected_task selected_pool
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
  fm_account_validate_contract "$binary" || {
    [ "$mode" = observe ] && { echo "fm-account-routing: observe contract unavailable; legacy launch unchanged" >&2; return 0; }
    return 1
  }
  if [ "$mode" = observe ]; then
    if json=$(fm_account_run_control "$binary" --format json choose --pool "$pool" --task "$task" --provider "$harness" --dry-run 2>/dev/null); then
      status=0
    else
      status=$?
    fi
    if [ "$status" -ne 0 ]; then
      echo "fm-account-routing: observe decision unavailable for pool=$pool provider=$harness; legacy launch unchanged" >&2
      return 0
    fi
  else
    if [ -n "$requested_profile" ] && [ "$pool" = explicit ]; then
      if json=$(fm_account_run_control "$binary" --format json lease acquire --profile "$requested_profile" --task "$task" --pool "$pool"); then status=0; else status=$?; fi
    elif [ -n "$requested_profile" ]; then
      if json=$(fm_account_run_control "$binary" --format json lease choose --pool "$pool" --task "$task" --provider "$harness" --profile "$requested_profile"); then status=0; else status=$?; fi
    else
      if json=$(fm_account_run_control "$binary" --format json lease choose --pool "$pool" --task "$task" --provider "$harness"); then status=0; else status=$?; fi
    fi
    if [ "$status" -eq 124 ]; then
      if json=$(fm_account_run_control "$binary" --format json lease recover --task "$task"); then
        status=0
      else
        echo "error: Agent Fleet lease mutation timed out and ownership could not be reconciled for $task" >&2
        return 2
      fi
    fi
    [ "$status" -eq 0 ] || return "$status"
    acquired=1
  fi
  if ! selected_task=$(fm_account_json_field "$json" '.task | select(type == "string" and length > 0)' selection) \
    || ! selected_pool=$(fm_account_json_field "$json" '.pool | select(type == "string" and length > 0)' selection) \
    || ! FM_ACCOUNT_SELECTED_PROFILE=$(fm_account_json_field "$json" '.profile | select(type == "string" and length > 0)' selection) \
    || ! FM_ACCOUNT_SELECTED_PROVIDER=$(fm_account_json_field "$json" '.provider | select(type == "string" and length > 0)' selection) \
    || [ "$selected_task" != "$task" ] \
    || [ "$selected_pool" != "$pool" ] \
    || ! fm_account_valid_id "$FM_ACCOUNT_SELECTED_PROFILE" \
    || [ "$FM_ACCOUNT_SELECTED_PROVIDER" != "$harness" ] \
    || { [ -n "$requested_profile" ] && [ "$FM_ACCOUNT_SELECTED_PROFILE" != "$requested_profile" ]; }; then
    FM_ACCOUNT_SELECTED_PROFILE=
    FM_ACCOUNT_SELECTED_PROVIDER=
    if [ "$mode" = observe ]; then
      echo "fm-account-routing: observe decision invalid for pool=$pool provider=$harness; legacy launch unchanged" >&2
      return 0
    fi
    echo "error: agent-fleet returned a mismatched account selection" >&2
    if [ "$acquired" = 1 ]; then
      if fm_account_release "$task" --force; then
        :
      else
        echo "error: failed to release invalid Agent Fleet reservation for $task" >&2
        return 2
      fi
    fi
    return 1
  fi
  if [ "$mode" = observe ]; then
    echo "fm-account-routing: observe pool=$pool provider=$harness profile=$FM_ACCOUNT_SELECTED_PROFILE (no lease; legacy launch unchanged)" >&2
  fi
}

fm_account_exec_command() {  # <profile> <pool> <task>
  local binary
  binary=$(fm_account_fleet_bin) || return 1
  fm_account_validate_contract "$binary" || return 1
  printf '%s --format json exec --profile %s --task %s --pool %s --' \
    "$(fm_account_shell_quote "$binary")" \
    "$(fm_account_shell_quote "$1")" \
    "$(fm_account_shell_quote "$3")" \
    "$(fm_account_shell_quote "$2")"
}

fm_account_resume_command() {  # <task>
  local binary
  binary=$(fm_account_fleet_bin) || return 1
  fm_account_validate_contract "$binary" || return 1
  printf '%s --format json resume --task %s --' \
    "$(fm_account_shell_quote "$binary")" \
    "$(fm_account_shell_quote "$1")"
}

# Sets FM_ACCOUNT_SELECTED_PROFILE and FM_ACCOUNT_SELECTED_PROVIDER from a
# sticky recovery reservation. This path intentionally bypasses new-task quota
# reserve filtering inside Agent Fleet while still refusing a live owner.
fm_account_recover() {  # <task> <expected-profile> <expected-pool> <expected-provider>
  local task=$1 expected_profile=$2 expected_pool=$3 expected_provider=$4 binary json status mapped_task profile pool provider
  binary=$(fm_account_fleet_bin) || return 1
  fm_account_validate_contract "$binary" || return 1
  if json=$(fm_account_run_control "$binary" --format json lease recover --task "$task"); then status=0; else status=$?; fi
  if [ "$status" -eq 124 ]; then
    if json=$(fm_account_run_control "$binary" --format json lease recover --task "$task"); then
      status=0
    else
      echo "error: Agent Fleet recovery timed out and ownership could not be reconciled for $task" >&2
      return 2
    fi
  fi
  [ "$status" -eq 0 ] || return "$status"
  if ! mapped_task=$(fm_account_json_field "$json" '.task | select(type == "string" and length > 0)' recovery) \
    || ! profile=$(fm_account_json_field "$json" '.profile | select(type == "string" and length > 0)' recovery) \
    || ! pool=$(fm_account_json_field "$json" '.pool | select(type == "string" and length > 0)' recovery) \
    || ! provider=$(fm_account_json_field "$json" '.provider | select(type == "string" and length > 0)' recovery) \
    || [ "$mapped_task" != "$task" ] \
    || [ "$profile" != "$expected_profile" ] \
    || [ "$pool" != "$expected_pool" ] \
    || [ "$provider" != "$expected_provider" ]; then
    echo "error: agent-fleet returned mismatched recovery state for $task" >&2
    if ! fm_account_release "$task" --force; then
      echo "error: failed to release invalid Agent Fleet recovery reservation for $task" >&2
      return 2
    fi
    return 1
  fi
  FM_ACCOUNT_SELECTED_PROFILE=$profile
  FM_ACCOUNT_SELECTED_PROVIDER=$provider
}

fm_account_release() {  # <task> [--force]
  local binary task=$1 force=${2:-} out status
  binary=$(fm_account_fleet_bin) || return 1
  fm_account_validate_contract "$binary" || return 1
  set +e
  if [ "$force" = --force ]; then
    out=$(fm_account_run_control "$binary" --format json lease release --task "$task" --force 2>&1)
  else
    out=$(fm_account_run_control "$binary" --format json lease release --task "$task" 2>&1)
  fi
  status=$?
  if [ "$status" -eq 124 ]; then
    if [ "$force" = --force ]; then
      out=$(fm_account_run_control "$binary" --format json lease release --task "$task" --force 2>&1)
    else
      out=$(fm_account_run_control "$binary" --format json lease release --task "$task" 2>&1)
    fi
    status=$?
  fi
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
  fm_account_validate_contract "$binary" || return 1
  set +e
  out=$(fm_account_run_control "$binary" --format json session remove --task "$1" 2>&1)
  status=$?
  if [ "$status" -eq 124 ]; then
    out=$(fm_account_run_control "$binary" --format json session remove --task "$1" 2>&1)
    status=$?
  fi
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
