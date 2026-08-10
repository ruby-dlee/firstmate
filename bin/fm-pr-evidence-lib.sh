#!/usr/bin/env bash

fm_pr_evidence_scalar() {  # <document> <key>
  printf '%s\n' "$1" | sed -n "s/^$2: *//p" | head -1 | sed 's/^"//; s/"$//'
}

fm_pr_require_server_admission_rule() {  # <owner> <repo> <base-ref> [snapshot-file]
  local owner=$1 repo=$2 base_ref=$3 snapshot_file=${4:-} encoded checks reviews admins
  local strict context_count check_count review_count dismiss_stale code_owners last_push admins_enabled
  local evidence_dir context_rows check_rows context_requirements check_requirements requirements
  case "$base_ref" in
    ''|*[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  encoded=${base_ref//\//%2F}
  checks=$(gh-axi api "/repos/$owner/$repo/branches/$encoded/protection/required_status_checks") || return 1
  strict=$(fm_pr_evidence_scalar "$checks" strict)
  [ "$strict" = true ] || return 1
  context_count=$(printf '%s\n' "$checks" | sed -n 's/^contexts\[\([0-9][0-9]*\)\].*/\1/p' | head -1)
  check_count=$(printf '%s\n' "$checks" | sed -n 's/^checks\[\([0-9][0-9]*\)\].*/\1/p' | head -1)
  case "$context_count:$check_count" in *[!0-9:]*) return 1 ;; esac
  [ $(( context_count + check_count )) -gt 0 ] || return 1
  evidence_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || return 1
  context_rows=$(printf '%s\n' "$checks" | node "$evidence_dir/fm-toon-table.mjs" --array contexts value) || return 1
  check_rows=$(printf '%s\n' "$checks" | node "$evidence_dir/fm-toon-table.mjs" --array checks context app_id) || return 1
  [ "$(printf '%s\n' "$context_rows" | awk 'NF { count++ } END { print count + 0 }')" -eq "$context_count" ] || return 1
  [ "$(printf '%s\n' "$check_rows" | awk 'NF { count++ } END { print count + 0 }')" -eq "$check_count" ] || return 1
  context_requirements=
  if [ "$context_count" -gt 0 ]; then
    context_requirements=$(printf '%s\n' "$context_rows" | awk '
      length($0) > 0 && $0 != "null" { print "requirement\tcontext\t" $0 "\t*"; next }
      { invalid=1 }
      END { exit invalid }
    ') || return 1
  fi
  check_requirements=
  if [ "$check_count" -gt 0 ]; then
    check_requirements=$(printf '%s\n' "$check_rows" | awk -F '\t' '
      NF == 2 && length($1) > 0 && $1 != "null" && ($2 == "null" || $2 == "-1" || $2 ~ /^[1-9][0-9]*$/) {
        app_id=$2
        if (app_id == "null" || app_id == "-1") app_id="*"
        print "requirement\tcheck\t" $1 "\t" app_id
        next
      }
      { invalid=1 }
      END { exit invalid }
    ') || return 1
  fi
  requirements=$(printf '%s\n%s\n' "$context_requirements" "$check_requirements" | awk 'NF')
  [ "$(printf '%s\n' "$requirements" | awk 'NF { count++ } END { print count + 0 }')" -eq $((context_count + check_count)) ] || return 1
  [ "$(printf '%s\n' "$requirements" | LC_ALL=C sort -u | awk 'NF { count++ } END { print count + 0 }')" -eq $((context_count + check_count)) ] || return 1
  reviews=$(gh-axi api "/repos/$owner/$repo/branches/$encoded/protection/required_pull_request_reviews") || return 1
  review_count=$(fm_pr_evidence_scalar "$reviews" required_approving_review_count)
  case "$review_count" in ''|*[!0-9]*) return 1 ;; esac
  [ "$review_count" -ge 2 ] || return 1
  dismiss_stale=$(fm_pr_evidence_scalar "$reviews" dismiss_stale_reviews)
  code_owners=$(fm_pr_evidence_scalar "$reviews" require_code_owner_reviews)
  last_push=$(fm_pr_evidence_scalar "$reviews" require_last_push_approval)
  [ "$dismiss_stale" = true ] && [ "$code_owners" = true ] && [ "$last_push" = true ] || return 1
  admins=$(gh-axi api "/repos/$owner/$repo/branches/$encoded/protection/enforce_admins") || return 1
  admins_enabled=$(fm_pr_evidence_scalar "$admins" enabled)
  [ "$admins_enabled" = true ] || return 1
  if [ -n "$snapshot_file" ]; then
    {
      printf 'strict\ttrue\n'
      printf 'required_approvals\t%s\n' "$review_count"
      printf 'dismiss_stale_reviews\ttrue\n'
      printf 'require_code_owner_reviews\ttrue\n'
      printf 'require_last_push_approval\ttrue\n'
      printf 'enforce_admins\ttrue\n'
      printf '%s\n' "$requirements" | LC_ALL=C sort
    } > "$snapshot_file" || return 1
  fi
}

fm_pr_require_atomic_merge_boundary() {
  echo "error: exact-head merge is unavailable: GitHub cannot require arbitrary later check contexts and Firstmate cannot prove detached worktree-writer custody; endpoint and metadata preserved" >&2
  return 1
}
