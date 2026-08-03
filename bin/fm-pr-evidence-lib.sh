#!/usr/bin/env bash

FM_PR_ADMISSION_CONTEXT=firstmate/exact-head-admission

fm_pr_evidence_scalar() {  # <document> <key>
  printf '%s\n' "$1" | sed -n "s/^$2: *//p" | head -1 | sed 's/^"//; s/"$//'
}

fm_pr_require_server_admission_rule() {  # <owner> <repo> <base-ref>
  local owner=$1 repo=$2 base_ref=$3 encoded contexts reviews admins review_count admins_enabled
  case "$base_ref" in
    ''|*[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  encoded=${base_ref//\//%2F}
  contexts=$(gh-axi api "/repos/$owner/$repo/branches/$encoded/protection/required_status_checks/contexts") || return 1
  printf '%s\n' "$contexts" \
    | grep -Eq "^[[:space:]]*-[[:space:]]*\"?$FM_PR_ADMISSION_CONTEXT\"?[[:space:]]*$" || return 1
  reviews=$(gh-axi api "/repos/$owner/$repo/branches/$encoded/protection/required_pull_request_reviews") || return 1
  review_count=$(fm_pr_evidence_scalar "$reviews" required_approving_review_count)
  case "$review_count" in ''|*[!0-9]*) return 1 ;; esac
  [ "$review_count" -ge 2 ] || return 1
  admins=$(gh-axi api "/repos/$owner/$repo/branches/$encoded/protection/enforce_admins") || return 1
  admins_enabled=$(fm_pr_evidence_scalar "$admins" enabled)
  [ "$admins_enabled" = true ]
}
