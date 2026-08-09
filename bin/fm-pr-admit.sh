#!/usr/bin/env bash
# Fail-closed synchronous admission for one exact PR head.
# Usage: fm-pr-admit.sh <task-id> <pr-url>
# A zero exit prints one admitted receipt consumed immediately by fm-pr-merge.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ID=${1:?usage: fm-pr-admit.sh <task-id> <pr-url>}
URL=${2:?usage: fm-pr-admit.sh <task-id> <pr-url>}
META="$STATE/$ID.meta"

# shellcheck source=bin/fm-account-routing-lib.sh
. "$SCRIPT_DIR/fm-account-routing-lib.sh"
# shellcheck source=bin/fm-pr-evidence-lib.sh
. "$SCRIPT_DIR/fm-pr-evidence-lib.sh"

if [[ "$URL" =~ ^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]+)/pull/([0-9]+)/?$ ]] \
  && [[ "${BASH_REMATCH[1]}" != *- ]]; then
  OWNER=${BASH_REMATCH[1]}
  REPO=${BASH_REMATCH[2]}
  NUMBER=${BASH_REMATCH[3]}
else
  echo "error: invalid GitHub PR URL: $URL" >&2
  exit 1
fi
[ -f "$META" ] && [ ! -L "$META" ] || { echo "error: no safe metadata for task $ID" >&2; exit 1; }
WORKTREE=$(fm_account_meta_value "$META" worktree)
[ -d "$WORKTREE" ] && [ ! -L "$WORKTREE" ] || { echo "error: no safe worktree for task $ID" >&2; exit 1; }

scalar() {  # <document> <top-level-key>
  printf '%s\n' "$1" | sed -n "s/^$2: *//p" | head -1 | sed 's/^"//; s/"$//'
}
section_scalar() {  # <document> <section> <key>
  printf '%s\n' "$1" | awk -v section="$2" -v key="$3" '
    $0 == section ":" { inside = 1; next }
    inside && /^[^ ]/ { inside = 0 }
    inside && $1 == key ":" { gsub(/"/, "", $2); print $2; exit }
  '
}
read_pr() {
  PR_DOC=$(gh-axi api "/repos/$OWNER/$REPO/pulls/$NUMBER") || return 1
  PR_HEAD=$(section_scalar "$PR_DOC" head sha)
  PR_BASE=$(section_scalar "$PR_DOC" base sha)
  PR_BASE_REF=$(section_scalar "$PR_DOC" base ref)
  PR_STATE=$(scalar "$PR_DOC" state)
  PR_DRAFT=$(scalar "$PR_DOC" draft)
  PR_AUTO=$(scalar "$PR_DOC" auto_merge)
  PR_MERGEABLE=$(scalar "$PR_DOC" mergeable)
  PR_MERGEABLE_STATE=$(scalar "$PR_DOC" mergeable_state)
  PR_AUTHOR=$(section_scalar "$PR_DOC" user login)
  PR_CHANGED=$(scalar "$PR_DOC" changed_files)
  case "$PR_CHANGED" in ''|*[!0-9]*) return 1 ;; esac
  case "$PR_AUTHOR" in ''|*[!A-Za-z0-9-]*|-|*-) return 1 ;; esac
  [ "${#PR_AUTHOR}" -le 39 ] || return 1
  case "$PR_BASE_REF" in ''|*[!A-Za-z0-9._/-]*) return 1 ;; esac
  case "$PR_HEAD:$PR_BASE" in
    ????????????????????????????????????????:????????????????????????????????????????)
      case "$PR_HEAD$PR_BASE" in *[!0-9a-fA-F]*) return 1 ;; esac
      ;;
    *) return 1 ;;
  esac
}

read_pr || { echo "error: could not read exact PR head/base for $URL" >&2; exit 1; }
[ "$PR_STATE" = open ] || { echo "error: PR is not open (state=$PR_STATE)" >&2; exit 1; }
[ "$PR_DRAFT" = false ] || { echo "error: PR is draft" >&2; exit 1; }
[ "$PR_AUTO" = null ] || { echo "error: PR already has an armed auto-merge" >&2; exit 1; }
[ "$PR_MERGEABLE" = true ] && [ "$PR_MERGEABLE_STATE" = clean ] || {
  echo "error: exact head is UNREVIEWED: GitHub protected-review eligibility is not clean (mergeable=$PR_MERGEABLE mergeable_state=$PR_MERGEABLE_STATE)" >&2
  exit 1
}

LOCAL_HEAD=$(git -C "$WORKTREE" rev-parse HEAD)
[ "$LOCAL_HEAD" = "$PR_HEAD" ] || {
  echo "error: content containment failed: task HEAD $LOCAL_HEAD is not PR head $PR_HEAD" >&2
  exit 1
}
git -C "$WORKTREE" cat-file -e "$PR_BASE^{commit}" 2>/dev/null \
  || { echo "error: content containment failed: PR base $PR_BASE is unavailable locally" >&2; exit 1; }

TMP_DIR=$(mktemp -d "$STATE/.pr-admit-$ID.XXXXXX") || exit 1
trap 'rm -rf "$TMP_DIR"' EXIT
: > "$TMP_DIR/github-files-unsorted"
file_page=1
file_enumerated=0
while :; do
  [ "$file_page" -le 1000 ] || { echo "error: PR file pagination exceeded the safe bound" >&2; exit 1; }
  FILES_DOC=$(gh-axi api "/repos/$OWNER/$REPO/pulls/$NUMBER/files?per_page=100&page=$file_page") || exit 1
  printf '%s\n' "$FILES_DOC" | node "$SCRIPT_DIR/fm-toon-table.mjs" filename > "$TMP_DIR/files-page"
  file_page_count=$(wc -l < "$TMP_DIR/files-page" | tr -d ' ')
  cat "$TMP_DIR/files-page" >> "$TMP_DIR/github-files-unsorted"
  file_enumerated=$((file_enumerated + file_page_count))
  [ "$file_enumerated" -lt "$PR_CHANGED" ] || break
  [ "$file_page_count" -eq 100 ] || {
    echo "error: content containment failed: PR file pagination ended before the reported count" >&2
    exit 1
  }
  file_page=$((file_page + 1))
done
LC_ALL=C sort "$TMP_DIR/github-files-unsorted" > "$TMP_DIR/github-files"
git -C "$WORKTREE" diff --name-only "$PR_BASE" "$PR_HEAD" | LC_ALL=C sort > "$TMP_DIR/local-files"
cmp -s "$TMP_DIR/github-files" "$TMP_DIR/local-files" || {
  echo "error: content containment failed: GitHub PR files differ from the exact local base..head diff" >&2
  exit 1
}
[ "$(wc -l < "$TMP_DIR/github-files" | tr -d ' ')" = "$PR_CHANGED" ] || {
  echo "error: content containment failed: PR file enumeration is incomplete" >&2
  exit 1
}
git -C "$WORKTREE" status --porcelain=v1 --untracked-files=all > "$TMP_DIR/worktree-status"
[ ! -s "$TMP_DIR/worktree-status" ] || {
  echo "error: content containment failed: admitted worktree has tracked, staged, or untracked residual" >&2
  exit 1
}

fm_pr_require_server_admission_rule "$OWNER" "$REPO" "$PR_BASE_REF" "$TMP_DIR/policy-initial" || {
  echo "error: base branch does not enforce strict required checks, stale-review dismissal, code-owner and last-push review, required approvals, and admin protection" >&2
  exit 1
}

snapshot_checks() {
  local prefix=$1 check_page=1 check_total='' check_enumerated=0 page_total check_page_count check_unique
  local check_id check_doc check_name check_app check_status conclusion status_page=1 status_total='' status_enumerated=0
  local STATUS_DOC status_page_count status_unique status_id status_context status_state
  local passed=0 failed=0 skipped=0 pending=0 total
  : > "$prefix-check-ids"
  : > "$prefix-check-runs-unsorted"
  while :; do
    [ "$check_page" -le 1000 ] || { echo "error: check-run pagination exceeded the safe bound" >&2; return 1; }
    CHECKS_DOC=$(gh-axi api "/repos/$OWNER/$REPO/commits/$PR_HEAD/check-runs?per_page=100&page=$check_page") || return 1
    page_total=$(scalar "$CHECKS_DOC" total_count)
    case "$page_total" in ''|*[!0-9]*) echo "error: exact-head check-run count is unreadable" >&2; return 1 ;; esac
    if [ -z "$check_total" ]; then check_total=$page_total; else
      [ "$page_total" = "$check_total" ] || { echo "error: exact-head check-run count changed during pagination" >&2; return 1; }
    fi
    printf '%s\n' "$CHECKS_DOC" | node "$SCRIPT_DIR/fm-toon-table.mjs" --array check_runs id > "$prefix-check-page" || return 1
    check_page_count=$(wc -l < "$prefix-check-page" | tr -d ' ')
    cat "$prefix-check-page" >> "$prefix-check-ids"
    check_enumerated=$((check_enumerated + check_page_count))
    [ "$check_enumerated" -lt "$check_total" ] || break
    [ "$check_page_count" -eq 100 ] || {
      echo "error: exact-head check-run enumeration is incomplete or duplicated (reported=$check_total enumerated=$check_enumerated)" >&2
      return 1
    }
    check_page=$((check_page + 1))
  done
  check_enumerated=$(wc -l < "$prefix-check-ids" | tr -d ' ')
  check_unique=$(LC_ALL=C sort -u "$prefix-check-ids" | wc -l | tr -d ' ')
  [ "$check_enumerated" = "$check_total" ] && [ "$check_unique" = "$check_total" ] || {
    echo "error: exact-head check-run enumeration is incomplete or duplicated (reported=$check_total enumerated=$check_enumerated unique=$check_unique)" >&2
    return 1
  }
  while IFS= read -r check_id; do
    [ -n "$check_id" ] || continue
    case "$check_id" in *[!0-9]*) echo "error: exact-head check-run id is malformed" >&2; return 1 ;; esac
    check_doc=$(gh-axi api "/repos/$OWNER/$REPO/check-runs/$check_id") || return 1
    check_name=$(scalar "$check_doc" name)
    check_app=$(section_scalar "$check_doc" app id)
    check_status=$(scalar "$check_doc" status)
    conclusion=$(scalar "$check_doc" conclusion)
    case "$check_name" in ''|null|*$'\t'*|*$'\n'*) echo "error: exact-head check-run identity is malformed" >&2; return 1 ;; esac
    case "$check_app" in ''|*[!0-9]*|0) echo "error: exact-head check-run app identity is malformed" >&2; return 1 ;; esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$check_id" "$check_name" "$check_app" "$check_status" "$conclusion" >> "$prefix-check-runs-unsorted"
    if [ "$check_status" != completed ]; then
      pending=$((pending + 1))
    else
      case "$conclusion" in
        success|neutral) passed=$((passed + 1)) ;;
        skipped) skipped=$((skipped + 1)) ;;
        *) failed=$((failed + 1)) ;;
      esac
    fi
  done < "$prefix-check-ids"
  LC_ALL=C sort -t $'\t' -k1,1n "$prefix-check-runs-unsorted" > "$prefix-check-runs"

  : > "$prefix-statuses-unsorted"
  : > "$prefix-status-ids"
  while :; do
    [ "$status_page" -le 1000 ] || { echo "error: commit-status pagination exceeded the safe bound" >&2; return 1; }
    STATUS_DOC=$(gh-axi api "/repos/$OWNER/$REPO/commits/$PR_HEAD/status?per_page=100&page=$status_page") || return 1
    page_total=$(scalar "$STATUS_DOC" total_count)
    case "$page_total" in ''|*[!0-9]*) echo "error: commit status count is unreadable" >&2; return 1 ;; esac
    if [ -z "$status_total" ]; then status_total=$page_total; else
      [ "$page_total" = "$status_total" ] || { echo "error: exact-head commit status count changed during pagination" >&2; return 1; }
    fi
    printf '%s\n' "$STATUS_DOC" | node "$SCRIPT_DIR/fm-toon-table.mjs" --array statuses id context state > "$prefix-status-page" || return 1
    status_page_count=$(wc -l < "$prefix-status-page" | tr -d ' ')
    cat "$prefix-status-page" >> "$prefix-statuses-unsorted"
    status_enumerated=$((status_enumerated + status_page_count))
    [ "$status_enumerated" -lt "$status_total" ] || break
    [ "$status_page_count" -eq 100 ] || {
      echo "error: exact-head commit status enumeration is incomplete or duplicated (reported=$status_total enumerated=$status_enumerated)" >&2
      return 1
    }
    status_page=$((status_page + 1))
  done
  while IFS=$'\t' read -r status_id status_context status_state; do
    [ -n "$status_id" ] || continue
    case "$status_id" in *[!0-9]*) echo "error: exact-head commit status id is malformed" >&2; return 1 ;; esac
    case "$status_context" in ''|null|*$'\t'*|*$'\n'*) echo "error: exact-head commit status context is malformed" >&2; return 1 ;; esac
    printf '%s\n' "$status_id" >> "$prefix-status-ids"
    case "$status_state" in
      success) passed=$((passed + 1)) ;;
      pending) pending=$((pending + 1)) ;;
      *) failed=$((failed + 1)) ;;
    esac
  done < "$prefix-statuses-unsorted"
  status_enumerated=$(wc -l < "$prefix-status-ids" | tr -d ' ')
  status_unique=$(LC_ALL=C sort -u "$prefix-status-ids" | wc -l | tr -d ' ')
  [ "$status_enumerated" = "$status_total" ] && [ "$status_unique" = "$status_total" ] || {
    echo "error: exact-head commit status enumeration is incomplete or duplicated (reported=$status_total enumerated=$status_enumerated unique=$status_unique)" >&2
    return 1
  }
  LC_ALL=C sort -t $'\t' -k1,1n "$prefix-statuses-unsorted" > "$prefix-statuses"
  total=$((passed + failed + skipped + pending))
  [ "$total" -gt 0 ] && [ "$failed" -eq 0 ] && [ "$pending" -eq 0 ] \
    && [ $((passed + skipped)) -eq "$total" ] || {
      echo "error: exact-head checks are not green and settled (total=$total passed=$passed failed=$failed skipped=$skipped pending=$pending)" >&2
      return 1
    }
  printf '%s\t%s\t%s\t%s\t%s\n' "$total" "$passed" "$failed" "$skipped" "$pending" > "$prefix-check-summary"
}

require_protected_checks() {
  local policy=$1 check_runs=$2 statuses=$3 record kind context app_id matched required=0
  while IFS=$'\t' read -r record kind context app_id; do
    [ "$record" = requirement ] || continue
    required=$((required + 1))
    matched=0
    if [ "$kind" = context ] || [ "$app_id" = '*' ]; then
      if awk -F '\t' -v context="$context" '$2 == context && $4 == "completed" && ($5 == "success" || $5 == "neutral" || $5 == "skipped") { found=1 } END { exit !found }' "$check_runs" \
        || awk -F '\t' -v context="$context" '$2 == context && $3 == "success" { found=1 } END { exit !found }' "$statuses"; then
        matched=1
      fi
    elif [ "$kind" = check ] && awk -F '\t' -v context="$context" -v app_id="$app_id" '$2 == context && $3 == app_id && $4 == "completed" && ($5 == "success" || $5 == "neutral" || $5 == "skipped") { found=1 } END { exit !found }' "$check_runs"; then
      matched=1
    fi
    [ "$matched" -eq 1 ] || {
      echo "error: protected exact-head check is missing or not supplied by the required app (context=$context app_id=$app_id)" >&2
      return 1
    }
  done < "$policy"
  [ "$required" -gt 0 ] || { echo "error: protected check requirements are empty" >&2; return 1; }
}

snapshot_reviews() {
  local prefix=$1 policy=$2 review_page=1 review_page_count review_id reviewer review_state review_head
  local author_key review_blocked=0 reviewers required_approvals
  required_approvals=$(awk -F '\t' '
    $1 == "required_approvals" && $2 ~ /^[1-9][0-9]*$/ { value=$2; count++ }
    END { if (count != 1) exit 1; print value }
  ' "$policy") || { echo "error: required approval policy is unreadable" >&2; return 1; }
  : > "$prefix-reviews-unsorted"
  : > "$prefix-reviews-unsorted-normalized"
  while :; do
    [ "$review_page" -le 1000 ] || { echo "error: review pagination exceeded the safe bound" >&2; return 1; }
    REVIEWS_DOC=$(gh-axi api "/repos/$OWNER/$REPO/pulls/$NUMBER/reviews?per_page=100&page=$review_page") || return 1
    printf '%s\n' "$REVIEWS_DOC" | node "$SCRIPT_DIR/fm-toon-table.mjs" --array reviews id user.login state commit_id > "$prefix-reviews-page" || return 1
    review_page_count=$(wc -l < "$prefix-reviews-page" | tr -d ' ')
    cat "$prefix-reviews-page" >> "$prefix-reviews-unsorted"
    [ "$review_page_count" -eq 100 ] || break
    review_page=$((review_page + 1))
  done
  : > "$prefix-review-ids"
  : > "$prefix-exact-review-states"
  while IFS=$'\t' read -r review_id reviewer review_state review_head; do
    case "$review_id" in ''|*[!0-9]*) echo "error: exact-head review id is malformed" >&2; return 1 ;; esac
    case "$reviewer" in ''|*[!A-Za-z0-9-]*|-|*-) echo "error: exact-head review identity is malformed" >&2; return 1 ;; esac
    [ "${#reviewer}" -le 39 ] || { echo "error: exact-head review identity is malformed" >&2; return 1; }
    case "$review_state" in APPROVED|CHANGES_REQUESTED|COMMENTED|DISMISSED|PENDING) ;; *) echo "error: exact-head review state is malformed" >&2; return 1 ;; esac
    case "$review_head" in
      ????????????????????????????????????????) case "$review_head" in *[!0-9a-fA-F]*) echo "error: exact-head review commit is malformed" >&2; return 1 ;; esac ;;
      *) echo "error: exact-head review commit is malformed" >&2; return 1 ;;
    esac
    grep -qxF "$review_id" "$prefix-review-ids" \
      && { echo "error: exact-head review enumeration contains a duplicate id" >&2; return 1; }
    printf '%s\n' "$review_id" >> "$prefix-review-ids"
    reviewer=$(printf '%s' "$reviewer" | tr '[:upper:]' '[:lower:]')
    printf '%s\t%s\t%s\t%s\n' "$review_id" "$reviewer" "$review_state" "$review_head" >> "$prefix-reviews-unsorted-normalized"
    [ "$review_head" = "$PR_HEAD" ] || continue
    printf '%s\t%s\t%s\n' "$review_id" "$reviewer" "$review_state" >> "$prefix-exact-review-states"
  done < "$prefix-reviews-unsorted"
  LC_ALL=C sort -t $'\t' -k1,1n "$prefix-reviews-unsorted-normalized" > "$prefix-reviews"
  LC_ALL=C sort -t $'\t' -k2,2 -k1,1n "$prefix-exact-review-states" \
    | awk -F '\t' '{ latest[$2] = $0 } END { for (reviewer in latest) print latest[reviewer] }' \
    > "$prefix-latest-review-states"
  : > "$prefix-approved-reviewers"
  author_key=$(printf '%s' "$PR_AUTHOR" | tr '[:upper:]' '[:lower:]')
  while IFS=$'\t' read -r review_id reviewer review_state; do
    [ -n "$review_id" ] || continue
    [ "$review_state" != CHANGES_REQUESTED ] || { review_blocked=1; continue; }
    [ "$review_state" = APPROVED ] || continue
    [ "$reviewer" != "$author_key" ] || continue
    printf '%s\n' "$reviewer" >> "$prefix-approved-reviewers"
  done < "$prefix-latest-review-states"
  reviewers=$(LC_ALL=C sort -u "$prefix-approved-reviewers" | wc -l | tr -d ' ')
  [ "$review_blocked" -eq 0 ] && [ "$reviewers" -ge "$required_approvals" ] || {
    echo "error: exact head is UNREVIEWED: need $required_approvals distinct non-author APPROVED verdicts and no exact-head change request (approvals=$reviewers blocked=$review_blocked)" >&2
    return 1
  }
  printf '%s\t%s\n' "$reviewers" "$review_blocked" > "$prefix-review-summary"
}

snapshot_checks "$TMP_DIR/initial" || exit 1
require_protected_checks "$TMP_DIR/policy-initial" "$TMP_DIR/initial-check-runs" "$TMP_DIR/initial-statuses" || exit 1
snapshot_reviews "$TMP_DIR/initial" "$TMP_DIR/policy-initial" || exit 1
IFS=$'\t' read -r total passed failed skipped pending < "$TMP_DIR/initial-check-summary"
IFS=$'\t' read -r reviewers review_blocked < "$TMP_DIR/initial-review-summary"

# Every property is head-bound and dies on movement.
# Re-read immediately before returning the one-shot admission receipt.
FIRST_HEAD=$PR_HEAD
FIRST_BASE=$PR_BASE
FIRST_BASE_REF=$PR_BASE_REF
read_pr || { echo "error: PR moved or became unreadable during admission" >&2; exit 1; }
[ "$PR_HEAD" = "$FIRST_HEAD" ] && [ "$PR_BASE" = "$FIRST_BASE" ] \
  && [ "$PR_BASE_REF" = "$FIRST_BASE_REF" ] && [ "$PR_STATE" = open ] \
  && [ "$PR_DRAFT" = false ] && [ "$PR_AUTO" = null ] \
  && [ "$PR_MERGEABLE" = true ] && [ "$PR_MERGEABLE_STATE" = clean ] || {
    echo "error: PR head/base/state changed during admission; all verdicts are stale" >&2
    exit 1
  }

fm_pr_require_server_admission_rule "$OWNER" "$REPO" "$PR_BASE_REF" "$TMP_DIR/policy-final" || {
  echo "error: base branch does not enforce strict required checks, stale-review dismissal, code-owner and last-push review, required approvals, and admin protection" >&2
  exit 1
}
cmp -s "$TMP_DIR/policy-initial" "$TMP_DIR/policy-final" || {
  echo "error: base branch admission policy changed during admission" >&2
  exit 1
}
git -C "$WORKTREE" status --porcelain=v1 --untracked-files=all > "$TMP_DIR/final-worktree-status"
[ ! -s "$TMP_DIR/final-worktree-status" ] || {
  echo "error: content containment failed: admitted worktree changed during admission" >&2
  exit 1
}
snapshot_checks "$TMP_DIR/final" || exit 1
snapshot_reviews "$TMP_DIR/final" "$TMP_DIR/policy-final" || exit 1
if ! cmp -s "$TMP_DIR/initial-check-runs" "$TMP_DIR/final-check-runs" \
  || ! cmp -s "$TMP_DIR/initial-statuses" "$TMP_DIR/final-statuses" \
  || ! cmp -s "$TMP_DIR/initial-reviews" "$TMP_DIR/final-reviews"; then
    echo "error: exact-head check or review evidence changed during admission" >&2
    exit 1
fi
require_protected_checks "$TMP_DIR/policy-final" "$TMP_DIR/final-check-runs" "$TMP_DIR/final-statuses" || exit 1
read_pr || { echo "error: PR moved after server policy verification" >&2; exit 1; }
[ "$PR_HEAD" = "$FIRST_HEAD" ] && [ "$PR_BASE" = "$FIRST_BASE" ] \
  && [ "$PR_BASE_REF" = "$FIRST_BASE_REF" ] && [ "$PR_STATE" = open ] \
  && [ "$PR_DRAFT" = false ] && [ "$PR_AUTO" = null ] \
  && [ "$PR_MERGEABLE" = true ] && [ "$PR_MERGEABLE_STATE" = clean ] || {
    echo "error: PR changed after server policy verification" >&2
    exit 1
  }

printf 'admitted: head=%s base=%s base_ref=%s policy=snapshot-native-strict-required total=%s passed=%s failed=%s skipped=%s pending=%s reviewers=%s residual_bytes=0\n' \
  "$PR_HEAD" "$PR_BASE" "$PR_BASE_REF" \
  "$total" "$passed" "$failed" "$skipped" "$pending" "$reviewers"
