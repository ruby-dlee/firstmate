#!/usr/bin/env bash

fm_pr_evidence_scalar() {  # <document> <key>
  printf '%s\n' "$1" | sed -n "s/^$2: *//p" | head -1 | sed 's/^"//; s/"$//'
}

fm_pr_require_server_admission_rule() {  # <owner> <repo> <base-ref>
  local owner=$1 repo=$2 base_ref=$3 encoded checks reviews admins
  local strict context_count check_count review_count dismiss_stale code_owners last_push admins_enabled
  case "$base_ref" in
    ''|*[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  encoded=${base_ref//\//%2F}
  checks=$(gh-axi api "/repos/$owner/$repo/branches/$encoded/protection/required_status_checks") || return 1
  strict=$(fm_pr_evidence_scalar "$checks" strict)
  [ "$strict" = true ] || return 1
  context_count=$(printf '%s\n' "$checks" | sed -n 's/^contexts\[\([0-9][0-9]*\)\].*/\1/p' | head -1)
  check_count=$(printf '%s\n' "$checks" | sed -n 's/^checks\[\([0-9][0-9]*\)\].*/\1/p' | head -1)
  case "${context_count:-0}:${check_count:-0}" in *[!0-9:]*) return 1 ;; esac
  [ $(( ${context_count:-0} + ${check_count:-0} )) -gt 0 ] || return 1
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
  [ "$admins_enabled" = true ]
}
