#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-prompt-exec)
mkdir -p "$TMP_ROOT"

path_identity() {
  python3 -c 'import os, sys; value = os.stat(sys.argv[1], follow_symlinks=False); print(f"{value.st_dev}:{value.st_ino}")' "$1"
}

test_prompt_transport_preserves_non_nul_bytes() {
  local transport="$TMP_ROOT/transport" prompt capture="$TMP_ROOT/capture" script="$TMP_ROOT/capture.py" command parent_id file_id
  mkdir "$transport"
  prompt="$transport/prompt"
  printf 'prefix\377suffix\n\n' > "$prompt"
  cat > "$script" <<'PY'
import os
import sys
with open(sys.argv[1], "wb") as output:
    output.write(os.fsencode(sys.argv[2]))
PY
  command="exec python3 '$script' '$capture' \"\$1\""
  parent_id=$(path_identity "$transport"); file_id=$(path_identity "$prompt")
  python3 "$ROOT/bin/fm-prompt-exec.py" "$prompt" "$parent_id" "$file_id" "$command" \
    || fail "continuation prompt transport rejected representable bytes"
  cmp -s "$capture" <(printf 'prefix\377suffix\n\n') \
    || fail "continuation prompt transport changed invalid UTF-8 or trailing newlines"
  assert_absent "$prompt" "continuation prompt transport retained its consumed generation"
  assert_absent "$transport" "continuation prompt transport retained its private launch directory"
  pass "continuation prompt transport preserves every representable argument byte"
}

test_prompt_transport_rejects_nul_before_launch() {
  local transport="$TMP_ROOT/nul" prompt marker="$TMP_ROOT/launched" output="$TMP_ROOT/nul.out" status parent_id file_id
  mkdir "$transport"; prompt="$transport/prompt"
  printf 'before\0after' > "$prompt"
  parent_id=$(path_identity "$transport"); file_id=$(path_identity "$prompt")
  if python3 "$ROOT/bin/fm-prompt-exec.py" "$prompt" "$parent_id" "$file_id" \
    "printf launched > '$marker'" > "$output" 2>&1; then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "continuation prompt transport accepted an unrepresentable NUL byte"
  assert_absent "$marker" "continuation prompt transport launched after NUL validation failed"
  assert_contains "$(cat "$output")" "cannot be represented" "NUL transport refusal was unclear"
  pass "continuation prompt transport fails closed on unrepresentable NUL bytes"
}

test_prompt_transport_rejects_replaced_generation() {
  local transport="$TMP_ROOT/replaced-file" prompt prior marker="$TMP_ROOT/replaced-launched" \
    output="$TMP_ROOT/replaced.out" status parent_id file_id
  mkdir "$transport"; prompt="$transport/prompt"; prior="$transport/prior"
  printf 'verified bytes\n' > "$prompt"
  parent_id=$(path_identity "$transport"); file_id=$(path_identity "$prompt")
  mv "$prompt" "$prior"; printf 'unowned replacement\n' > "$prompt"
  if python3 "$ROOT/bin/fm-prompt-exec.py" "$prompt" "$parent_id" "$file_id" \
    "printf launched > '$marker'" > "$output" 2>&1; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "prompt transport consumed an unowned replacement generation"
  assert_absent "$marker" "prompt transport launched an unowned replacement generation"
  assert_contains "$(cat "$prompt")" "unowned replacement" "prompt transport changed the unowned replacement"
  pass "continuation prompt consumption requires its owned file generation"
}

test_prompt_transport_rejects_replaced_parent() {
  local transport="$TMP_ROOT/replaced-parent" moved="$TMP_ROOT/replaced-parent-owned" prompt marker="$TMP_ROOT/parent-launched" \
    output="$TMP_ROOT/parent.out" status parent_id file_id
  mkdir "$transport"; prompt="$transport/prompt"; printf 'verified bytes\n' > "$prompt"
  parent_id=$(path_identity "$transport"); file_id=$(path_identity "$prompt")
  mv "$transport" "$moved"; mkdir "$transport"; printf 'replacement parent bytes\n' > "$prompt"
  if python3 "$ROOT/bin/fm-prompt-exec.py" "$prompt" "$parent_id" "$file_id" \
    "printf launched > '$marker'" > "$output" 2>&1; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "prompt transport repinned an unowned parent generation"
  assert_absent "$marker" "prompt transport launched from an unowned parent generation"
  assert_contains "$(cat "$prompt")" "replacement parent bytes" "prompt transport changed the replacement parent"
  pass "continuation prompt consumption requires its owned parent generation"
}

test_prompt_transport_preserves_non_nul_bytes
test_prompt_transport_rejects_nul_before_launch
test_prompt_transport_rejects_replaced_generation
test_prompt_transport_rejects_replaced_parent
