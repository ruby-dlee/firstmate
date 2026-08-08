#!/usr/bin/env bash

fm_marker_identity_key() {
  local identity=$1 hex
  case "$identity" in ''|*$'\n'*) return 1 ;; esac
  hex=$(LC_ALL=C printf '%s' "$identity" | od -An -tx1 | tr -d ' \n') || return 1
  [ -n "$hex" ] || return 1
  printf 'v2-%s' "$hex"
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
  printf '%s' "$1" | tr ':/.' '___'
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
  [ -e "$old" ] || { printf '%s' "$new"; return 0; }
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
