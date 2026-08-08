#!/usr/bin/env bash

_fm_marker_system_exec() {
  local name=$1 bin
  shift
  bin=$(PATH=/usr/bin:/bin:/usr/sbin:/sbin type -P "$name") || return 127
  case "$bin" in /usr/bin/*|/bin/*|/usr/sbin/*|/sbin/*) ;; *) return 127 ;; esac
  local -x LD_PRELOAD='' LD_LIBRARY_PATH='' LD_AUDIT='' LD_DEBUG=''
  local -x DYLD_INSERT_LIBRARIES='' DYLD_LIBRARY_PATH='' DYLD_FRAMEWORK_PATH=''
  local -x DYLD_FALLBACK_LIBRARY_PATH='' DYLD_FALLBACK_FRAMEWORK_PATH=''
  local -x PERL5OPT='' PERL5LIB='' PERLLIB='' NODE_OPTIONS='' NODE_PATH=''
  local -x PYTHONHOME='' PYTHONPATH='' RUBYOPT='' RUBYLIB='' BASH_ENV='' ENV=''
  local -x GCONV_PATH=''
  "$bin" "$@"
}

fm_marker_identity_key_with_executor() {
  local identity=$1 executor=$2 hex
  case "$identity" in ''|*$'\n'*) return 1 ;; esac
  hex=$(LC_ALL=C printf '%s' "$identity" | "$executor" od -An -tx1 | "$executor" tr -d ' \n') || return 1
  [ -n "$hex" ] || return 1
  printf 'v2-%s' "$hex"
}

fm_marker_identity_key() {
  fm_marker_identity_key_with_executor "$1" _fm_marker_system_exec
}

fm_marker_task_key() {
  case "$1" in ''|.*|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  fm_marker_identity_key "$1"
}

fm_marker_task_from_key() {
  local key=$1 hex task
  case "$key" in v2-*) hex=${key#v2-} ;; *) return 1 ;; esac
  case "$hex" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ $(( ${#hex} % 2 )) -eq 0 ] || return 1
  task=$(printf '%s' "$hex" | perl -e '
    my $hex = <STDIN>;
    exit 1 if !defined($hex) || $hex !~ /\A[0-9a-f]+\z/ || length($hex) % 2;
    print pack(q{H*}, $hex);
  ') || return 1
  case "$task" in ''|.*|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "$(fm_marker_task_key "$task")" = "$key" ] || return 1
  printf '%s' "$task"
}

fm_marker_legacy_key() {
  printf '%s' "$1" | _fm_marker_system_exec tr ':/.' '___'
}

fm_marker_state_path_safe_or_absent() {
  [ ! -L "$1" ] || return 1
  [ ! -e "$1" ] || [ -f "$1" ]
}

fm_marker_legacy_owner() {
  local state=$1 key=$2 meta task owner= count=0
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    task=$(basename "$meta")
    task=${task%.meta}
    [ "$(fm_marker_legacy_key "$task")" = "$key" ] || continue
    [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
    case "$task" in ''|.*|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac
    owner=$task
    count=$((count + 1))
  done
  [ "$count" -eq 1 ] || return 1
  printf '%s' "$owner"
}

fm_marker_task_for_key() {
  local state=$1 key=$2
  case "$key" in
    v2-*) fm_marker_task_from_key "$key" ;;
    *) fm_marker_legacy_owner "$state" "$key" ;;
  esac
}

fm_marker_legacy_window_owner() {
  local state=$1 key=$2 meta task target owner= count=0
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  type fm_backend_target_of_meta >/dev/null 2>&1 || return 1
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
    task=$(basename "$meta")
    task=${task%.meta}
    case "$task" in ''|.*|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac
    target=$(fm_backend_target_of_meta "$meta")
    [ -n "$target" ] || continue
    [ "$(fm_marker_legacy_key "$target")" = "$key" ] || continue
    owner=$task
    count=$((count + 1))
  done
  [ "$count" -eq 1 ] || return 1
  printf '%s' "$owner"
}

fm_marker_migrate_watcher_state() {
  local state=$1 task=$2 target=$3 key legacy owner family old new
  key=$(fm_marker_task_key "$task") || return 1
  [ -f "$state/$task.meta" ] && [ ! -L "$state/$task.meta" ] || return 1
  [ "$(fm_backend_target_of_meta "$state/$task.meta")" = "$target" ] || return 1
  legacy=$(fm_marker_legacy_key "$target")
  owner=$(fm_marker_legacy_window_owner "$state" "$legacy" 2>/dev/null || true)
  [ "$owner" = "$task" ] || { printf '%s' "$key"; return 0; }
  for family in hash count stale stale-since wedge-escalations paused paused-rechecked paused-resurfaced stale-busy-hash stale-busy-since wedge-escalations-busy stale-permission wedge-escalations-permission; do
    old="$state/.$family-$legacy"
    new="$state/.$family-$key"
    [ -e "$old" ] || [ -L "$old" ] || continue
    [ -f "$old" ] && [ ! -L "$old" ] || return 1
    fm_marker_state_path_safe_or_absent "$new" || return 1
    if [ -e "$new" ]; then
      rm -f "$old" || return 1
    else
      mv "$old" "$new" || return 1
    fi
  done
  printf '%s' "$key"
}

fm_marker_migrate_task_state() {
  local state=$1 task=$2 family=$3 key legacy owner old new
  case "$family" in hb-surfaced) ;; *) return 1 ;; esac
  key=$(fm_marker_task_key "$task") || return 1
  legacy=$(fm_marker_legacy_key "$task")
  owner=$(fm_marker_legacy_owner "$state" "$legacy" 2>/dev/null || true)
  if [ "$owner" = "$task" ]; then
    old="$state/.$family-$legacy"
    new="$state/.$family-$key"
    if [ -e "$old" ] || [ -L "$old" ]; then
      [ -f "$old" ] && [ ! -L "$old" ] || return 1
      fm_marker_state_path_safe_or_absent "$new" || return 1
      if [ -e "$new" ]; then rm -f "$old" || return 1; else mv "$old" "$new" || return 1; fi
    fi
  fi
  printf '%s' "$key"
}

fm_marker_remove_owned_kind() {
  local state=$1 task=$2 kind=$3 key legacy owner
  case "$kind" in stale|paused) ;; *) return 1 ;; esac
  key=$(fm_marker_task_key "$task") || return 1
  rm -f "$state/.subsuper-$kind-$key" || return 1
  legacy=$(fm_marker_legacy_key "$task")
  owner=$(fm_marker_legacy_owner "$state" "$legacy" 2>/dev/null || true)
  [ "$owner" != "$task" ] || rm -f "$state/.subsuper-$kind-$legacy"
}

fm_marker_migrate_owned_kind() {
  local state=$1 task=$2 kind=$3 key legacy owner old new
  case "$kind" in stale|paused) ;; *) return 1 ;; esac
  key=$(fm_marker_task_key "$task") || return 1
  legacy=$(fm_marker_legacy_key "$task")
  old="$state/.subsuper-$kind-$legacy"
  new="$state/.subsuper-$kind-$key"
  [ -e "$old" ] || [ -L "$old" ] || { printf '%s' "$new"; return 0; }
  [ -f "$old" ] && [ ! -L "$old" ] || return 1
  fm_marker_state_path_safe_or_absent "$new" || return 1
  owner=$(fm_marker_legacy_owner "$state" "$legacy") || return 1
  [ "$owner" = "$task" ] || return 1
  if [ -e "$new" ]; then
    rm -f "$old" || return 1
  else
    mv "$old" "$new" || return 1
  fi
  printf '%s' "$new"
}

fm_marker_cleanup_owned() {
  fm_marker_remove_owned_kind "$1" "$2" stale || return 1
  fm_marker_remove_owned_kind "$1" "$2" paused
}
