#!/usr/bin/env bash
# Verify that the checked-out HEAD has one expected parent and one expected tree.
# Expected object IDs are gate inputs so this tracked helper remains unchanged
# when a repository-shape assertion is updated for a new exact head.
set -u

MATCH_MARKER=CROSSCHECK_REPOSITORY_SHAPE_MATCH
MISMATCH_MARKER=CROSSCHECK_REPOSITORY_SHAPE_MISMATCH
INPUT_MARKER=CROSSCHECK_REPOSITORY_SHAPE_INPUT_INVALID
INSPECTION_MARKER=CROSSCHECK_REPOSITORY_SHAPE_INSPECTION_FAILED

if [ "$#" -ne 2 ]; then
  printf '%s expected_parent_and_tree_required\n' "$INPUT_MARKER" >&2
  exit 64
fi
expected_parent=$1
expected_tree=$2
case "$expected_parent$expected_tree" in
  *[!0-9a-f]*) inputs_valid=no ;;
  *) inputs_valid=yes ;;
esac
if [ "$inputs_valid" != yes ] \
  || [ "${#expected_parent}" -ne 40 ] \
  || [ "${#expected_tree}" -ne 40 ]; then
  printf '%s expected_parent=%s expected_tree=%s\n' \
    "$INPUT_MARKER" "$expected_parent" "$expected_tree" >&2
  exit 64
fi

head_sha=$(git --no-replace-objects rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || {
  printf '%s cannot_resolve_head\n' "$INSPECTION_MARKER" >&2
  exit 65
}
commit=$(git --no-replace-objects cat-file commit "$head_sha" 2>/dev/null) || {
  printf '%s cannot_read_head=%s\n' "$INSPECTION_MARKER" "$head_sha" >&2
  exit 65
}

actual_tree=
actual_parents=
while IFS=' ' read -r key value _rest; do
  [ -n "$key" ] || break
  case "$key" in
    tree) actual_tree=$value ;;
    parent) actual_parents="${actual_parents}${actual_parents:+ }$value" ;;
  esac
done <<EOF
$commit
EOF

case "$actual_tree" in
  *[!0-9a-f]*|"") actual_tree_valid=no ;;
  *) actual_tree_valid=yes ;;
esac
if [ "$actual_tree_valid" != yes ] || [ "${#actual_tree}" -ne 40 ]; then
  printf '%s invalid_actual_tree=%s\n' "$INSPECTION_MARKER" "${actual_tree:-missing}" >&2
  exit 65
fi

case "$actual_parents" in
  "") actual_parent=none ;;
  *[!0-9a-f]*|?????????????????????????????????????????*) actual_parent=multiple ;;
  *)
    if [ "${#actual_parents}" -eq 40 ]; then
      actual_parent=$actual_parents
    else
      actual_parent=multiple
    fi
    ;;
esac

if [ "$actual_parent" != "$expected_parent" ] || [ "$actual_tree" != "$expected_tree" ]; then
  printf '%s head=%s expected_parent=%s actual_parent=%s expected_tree=%s actual_tree=%s\n' \
    "$MISMATCH_MARKER" "$head_sha" "$expected_parent" "$actual_parent" \
    "$expected_tree" "$actual_tree" >&2
  exit 86
fi

printf '%s head=%s parent=%s tree=%s\n' \
  "$MATCH_MARKER" "$head_sha" "$actual_parent" "$actual_tree"
