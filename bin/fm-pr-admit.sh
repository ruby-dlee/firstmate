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
  PR_STATE=$(scalar "$PR_DOC" state)
  PR_DRAFT=$(scalar "$PR_DOC" draft)
  PR_AUTO=$(scalar "$PR_DOC" auto_merge)
  PR_AUTHOR=$(scalar "$PR_DOC" user)
  PR_CHANGED=$(scalar "$PR_DOC" changed_files)
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

LOCAL_HEAD=$(git -C "$WORKTREE" rev-parse HEAD)
[ "$LOCAL_HEAD" = "$PR_HEAD" ] || {
  echo "error: content containment failed: task HEAD $LOCAL_HEAD is not PR head $PR_HEAD" >&2
  exit 1
}
git -C "$WORKTREE" cat-file -e "$PR_BASE^{commit}" 2>/dev/null \
  || { echo "error: content containment failed: PR base $PR_BASE is unavailable locally" >&2; exit 1; }

TMP_DIR=$(mktemp -d "$STATE/.pr-admit-$ID.XXXXXX") || exit 1
trap 'rm -rf "$TMP_DIR"' EXIT
FILES_DOC=$(gh-axi api "/repos/$OWNER/$REPO/pulls/$NUMBER/files" --paginate) || exit 1
printf '%s\n' "$FILES_DOC" | node "$SCRIPT_DIR/fm-toon-table.mjs" filename | LC_ALL=C sort > "$TMP_DIR/github-files"
git -C "$WORKTREE" diff --name-only "$PR_BASE" "$PR_HEAD" | LC_ALL=C sort > "$TMP_DIR/local-files"
git -C "$WORKTREE" diff --name-only -z "$PR_BASE" "$PR_HEAD" > "$TMP_DIR/local-files-z"
cmp -s "$TMP_DIR/github-files" "$TMP_DIR/local-files" || {
  echo "error: content containment failed: GitHub PR files differ from the exact local base..head diff" >&2
  exit 1
}
[ "$(wc -l < "$TMP_DIR/github-files" | tr -d ' ')" = "$PR_CHANGED" ] || {
  echo "error: content containment failed: PR file enumeration is incomplete" >&2
  exit 1
}
: > "$TMP_DIR/residual.patch"
while IFS= read -r -d '' pr_file; do
  git -C "$WORKTREE" diff --binary "$PR_HEAD" "$LOCAL_HEAD" -- ":(top,literal)$pr_file" >> "$TMP_DIR/residual.patch"
done < "$TMP_DIR/local-files-z"
[ ! -s "$TMP_DIR/residual.patch" ] || {
  echo "error: content containment failed: exact-head residual over PR files is nonzero" >&2
  exit 1
}

CHECKS_DOC=$(gh-axi api "/repos/$OWNER/$REPO/commits/$PR_HEAD/check-runs" --paginate) || exit 1
printf '%s\n' "$CHECKS_DOC" | node "$SCRIPT_DIR/fm-toon-table.mjs" id > "$TMP_DIR/check-ids"
check_total=$(scalar "$CHECKS_DOC" total_count)
case "$check_total" in ''|*[!0-9]*) echo "error: exact-head check-run count is unreadable" >&2; exit 1 ;; esac
check_enumerated=$(wc -l < "$TMP_DIR/check-ids" | tr -d ' ')
check_unique=$(LC_ALL=C sort -u "$TMP_DIR/check-ids" | wc -l | tr -d ' ')
[ "$check_enumerated" = "$check_total" ] && [ "$check_unique" = "$check_total" ] || {
  echo "error: exact-head check-run enumeration is incomplete or duplicated (reported=$check_total enumerated=$check_enumerated unique=$check_unique)" >&2
  exit 1
}
passed=0
failed=0
skipped=0
pending=0
while IFS= read -r check_id; do
  [ -n "$check_id" ] || continue
  check_doc=$(gh-axi api "/repos/$OWNER/$REPO/check-runs/$check_id") || exit 1
  check_status=$(scalar "$check_doc" status)
  conclusion=$(scalar "$check_doc" conclusion)
  if [ "$check_status" != completed ]; then
    pending=$((pending + 1))
  else
    case "$conclusion" in
      success|neutral) passed=$((passed + 1)) ;;
      skipped) skipped=$((skipped + 1)) ;;
      *) failed=$((failed + 1)) ;;
    esac
  fi
done < "$TMP_DIR/check-ids"

STATUS_DOC=$(gh-axi api "/repos/$OWNER/$REPO/commits/$PR_HEAD/status") || exit 1
status_total=$(scalar "$STATUS_DOC" total_count)
status_state=$(scalar "$STATUS_DOC" state)
case "$status_total" in ''|*[!0-9]*) echo "error: commit status count is unreadable" >&2; exit 1 ;; esac
if [ "$status_total" -gt 0 ]; then
  case "$status_state" in
    success) passed=$((passed + status_total)) ;;
    pending) pending=$((pending + status_total)) ;;
    *) failed=$((failed + status_total)) ;;
  esac
fi
total=$((passed + failed + skipped + pending))
[ "$total" -gt 0 ] && [ "$failed" -eq 0 ] && [ "$pending" -eq 0 ] \
  && [ $((passed + skipped)) -eq "$total" ] || {
    echo "error: exact-head checks are not green and settled (total=$total passed=$passed failed=$failed skipped=$skipped pending=$pending)" >&2
    exit 1
  }

REVIEWS_DOC=$(gh-axi api "/repos/$OWNER/$REPO/pulls/$NUMBER/reviews" --paginate) || exit 1
printf '%s\n' "$REVIEWS_DOC" | node "$SCRIPT_DIR/fm-toon-table.mjs" user state commit_id body > "$TMP_DIR/reviews"
: > "$TMP_DIR/approved-reviewers"
adversarial_reviewers=0
review_blocked=0
while IFS=$'\t' read -r reviewer review_state review_head review_body; do
  [ "$review_head" = "$PR_HEAD" ] || continue
  [ "$review_state" != CHANGES_REQUESTED ] || { review_blocked=1; continue; }
  [ "$review_state" = APPROVED ] || continue
  [ -n "$reviewer" ] && [ "$reviewer" != "$PR_AUTHOR" ] || continue
  printf '%s\n' "$reviewer" >> "$TMP_DIR/approved-reviewers"
  case "$review_body" in
    *"FIRSTMATE-ADVERSARIAL-VERDICT: CLEAN head=$PR_HEAD"*)
      adversarial_reviewers=$((adversarial_reviewers + 1))
      ;;
  esac
done < "$TMP_DIR/reviews"
reviewers=$(LC_ALL=C sort -u "$TMP_DIR/approved-reviewers" | wc -l | tr -d ' ')
[ "$review_blocked" -eq 0 ] && [ "$reviewers" -ge 2 ] && [ "$adversarial_reviewers" -ge 1 ] || {
  echo "error: exact head is UNREVIEWED: need two distinct non-author APPROVED verdicts, no exact-head change request, and an approval carrying FIRSTMATE-ADVERSARIAL-VERDICT: CLEAN head=$PR_HEAD (approvals=$reviewers adversarial=$adversarial_reviewers blocked=$review_blocked)" >&2
  exit 1
}

# Every property is head-bound and dies on movement.
# Re-read immediately before returning the one-shot admission receipt.
FIRST_HEAD=$PR_HEAD
FIRST_BASE=$PR_BASE
read_pr || { echo "error: PR moved or became unreadable during admission" >&2; exit 1; }
[ "$PR_HEAD" = "$FIRST_HEAD" ] && [ "$PR_BASE" = "$FIRST_BASE" ] \
  && [ "$PR_STATE" = open ] && [ "$PR_DRAFT" = false ] && [ "$PR_AUTO" = null ] || {
    echo "error: PR head/base/state changed during admission; all verdicts are stale" >&2
    exit 1
  }

printf 'admitted: head=%s base=%s total=%s passed=%s failed=%s skipped=%s pending=%s reviewers=%s residual_bytes=0\n' \
  "$PR_HEAD" "$PR_BASE" "$total" "$passed" "$failed" "$skipped" "$pending" "$reviewers"
