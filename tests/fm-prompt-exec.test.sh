#!/usr/bin/env bash
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-prompt-exec)
mkdir -p "$TMP_ROOT"

test_prompt_transport_preserves_non_nul_bytes() {
  local transport="$TMP_ROOT/transport" prompt capture="$TMP_ROOT/capture" script="$TMP_ROOT/capture.py" command
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
  python3 "$ROOT/bin/fm-prompt-exec.py" "$prompt" "$command" \
    || fail "continuation prompt transport rejected representable bytes"
  cmp -s "$capture" <(printf 'prefix\377suffix\n\n') \
    || fail "continuation prompt transport changed invalid UTF-8 or trailing newlines"
  assert_absent "$prompt" "continuation prompt transport retained its consumed generation"
  assert_absent "$transport" "continuation prompt transport retained its private launch directory"
  pass "continuation prompt transport preserves every representable argument byte"
}

test_prompt_transport_rejects_nul_before_launch() {
  local prompt="$TMP_ROOT/prompt-nul" marker="$TMP_ROOT/launched" output="$TMP_ROOT/nul.out" status
  printf 'before\0after' > "$prompt"
  if python3 "$ROOT/bin/fm-prompt-exec.py" "$prompt" "printf launched > '$marker'" > "$output" 2>&1; then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "continuation prompt transport accepted an unrepresentable NUL byte"
  assert_absent "$marker" "continuation prompt transport launched after NUL validation failed"
  assert_contains "$(cat "$output")" "cannot be represented" "NUL transport refusal was unclear"
  pass "continuation prompt transport fails closed on unrepresentable NUL bytes"
}

test_prompt_transport_preserves_non_nul_bytes
test_prompt_transport_rejects_nul_before_launch
