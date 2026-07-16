#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-prompt-exec)
mkdir -p "$TMP_ROOT"

path_identity() {
  python3 -c 'import os, sys; value = os.stat(sys.argv[1], follow_symlinks=False); print(f"{value.st_dev}:{value.st_ino}")' "$1"
}

content_identity() {
  shasum -a 256 "$1" | awk '{print $1}'
}

test_prompt_transport_preserves_all_bytes() {
  local transport="$TMP_ROOT/transport" prompt capture="$TMP_ROOT/capture" script="$TMP_ROOT/capture.py" command parent_id file_id content_id
  mkdir "$transport"
  prompt="$transport/prompt"
  printf 'prefix\0middle\377suffix\n\n' > "$prompt"
  cat > "$script" <<'PY'
import sys
with open(sys.argv[1], "wb") as output:
    output.write(sys.stdin.buffer.read())
PY
  command="exec python3 '$script' '$capture'"
  parent_id=$(path_identity "$transport"); file_id=$(path_identity "$prompt"); content_id=$(content_identity "$prompt")
  python3 "$ROOT/bin/fm-prompt-exec.py" "$prompt" "$parent_id" "$file_id" "$content_id" "$command" \
    || fail "continuation prompt transport rejected byte-verbatim stdin"
  cmp -s "$capture" <(printf 'prefix\0middle\377suffix\n\n') \
    || fail "continuation prompt transport changed NUL, invalid UTF-8, or trailing newlines"
  assert_absent "$prompt" "continuation prompt transport retained its consumed generation"
  assert_absent "$transport" "continuation prompt transport retained its private launch directory"
  pass "continuation prompt transport preserves every byte through stdin"
}

test_prompt_transport_rejects_replaced_generation() {
  local transport="$TMP_ROOT/replaced-file" prompt prior marker="$TMP_ROOT/replaced-launched" \
    output="$TMP_ROOT/replaced.out" status parent_id file_id content_id
  mkdir "$transport"; prompt="$transport/prompt"; prior="$transport/prior"
  printf 'verified bytes\n' > "$prompt"
  parent_id=$(path_identity "$transport"); file_id=$(path_identity "$prompt"); content_id=$(content_identity "$prompt")
  mv "$prompt" "$prior"; printf 'unowned replacement\n' > "$prompt"
  if python3 "$ROOT/bin/fm-prompt-exec.py" "$prompt" "$parent_id" "$file_id" "$content_id" \
    "printf launched > '$marker'" > "$output" 2>&1; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "prompt transport consumed an unowned replacement generation"
  assert_absent "$marker" "prompt transport launched an unowned replacement generation"
  assert_contains "$(cat "$prompt")" "unowned replacement" "prompt transport changed the unowned replacement"
  pass "continuation prompt consumption requires its owned file generation"
}

test_prompt_transport_rejects_replaced_parent() {
  local transport="$TMP_ROOT/replaced-parent" moved="$TMP_ROOT/replaced-parent-owned" prompt marker="$TMP_ROOT/parent-launched" \
    output="$TMP_ROOT/parent.out" status parent_id file_id content_id
  mkdir "$transport"; prompt="$transport/prompt"; printf 'verified bytes\n' > "$prompt"
  parent_id=$(path_identity "$transport"); file_id=$(path_identity "$prompt"); content_id=$(content_identity "$prompt")
  mv "$transport" "$moved"; mkdir "$transport"; printf 'replacement parent bytes\n' > "$prompt"
  if python3 "$ROOT/bin/fm-prompt-exec.py" "$prompt" "$parent_id" "$file_id" "$content_id" \
    "printf launched > '$marker'" > "$output" 2>&1; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "prompt transport repinned an unowned parent generation"
  assert_absent "$marker" "prompt transport launched from an unowned parent generation"
  assert_contains "$(cat "$prompt")" "replacement parent bytes" "prompt transport changed the replacement parent"
  pass "continuation prompt consumption requires its owned parent generation"
}

test_prompt_transport_rejects_in_place_mutation() {
  local transport="$TMP_ROOT/in-place" prompt marker="$TMP_ROOT/in-place-launched" output="$TMP_ROOT/in-place.out"
  local status parent_id file_id content_id
  mkdir "$transport"; prompt="$transport/prompt"; printf 'verified bytes\n' > "$prompt"
  parent_id=$(path_identity "$transport"); file_id=$(path_identity "$prompt"); content_id=$(content_identity "$prompt")
  printf 'mutated bytes!\n' > "$prompt"
  if python3 "$ROOT/bin/fm-prompt-exec.py" "$prompt" "$parent_id" "$file_id" "$content_id" \
    "printf launched > '$marker'" > "$output" 2>&1; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "prompt transport consumed in-place-mutated bytes"
  assert_absent "$marker" "prompt transport launched in-place-mutated bytes"
  assert_contains "$(cat "$prompt")" "mutated bytes" "prompt transport changed the mutated source"
  pass "continuation prompt consumption verifies content identity"
}

test_prompt_transport_consumes_verified_snapshot_after_mutation() {
  local transport="$TMP_ROOT/post-hash" prompt="$TMP_ROOT/post-hash/prompt" expected="$TMP_ROOT/post-hash.expected"
  local capture="$TMP_ROOT/post-hash.capture" script="$TMP_ROOT/post-hash-capture.py"
  local ready="$TMP_ROOT/post-hash.ready" proceed="$TMP_ROOT/post-hash.proceed"
  local command parent_id file_id content_id pid
  mkdir "$transport"
  printf 'verified prefix\0verified suffix\377\n' > "$prompt"
  cp "$prompt" "$expected"
  cat > "$script" <<'PY'
import sys
with open(sys.argv[1], "wb") as output:
    output.write(sys.stdin.buffer.read())
PY
  command="exec python3 '$script' '$capture'"
  parent_id=$(path_identity "$transport"); file_id=$(path_identity "$prompt"); content_id=$(content_identity "$prompt")
  FM_PROMPT_EXEC_TEST_READY="$ready" FM_PROMPT_EXEC_TEST_PROCEED="$proceed" \
    python3 "$ROOT/bin/fm-prompt-exec.py" "$prompt" "$parent_id" "$file_id" "$content_id" "$command" &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.02; done
  [ -e "$ready" ] || { kill -TERM "$pid" 2>/dev/null || true; fail "prompt snapshot gate did not open"; }
  printf 'mutated after verification\n' > "$prompt"
  touch "$proceed"
  wait "$pid" || fail "prompt transport failed after its verified snapshot was captured"
  cmp -s "$capture" "$expected" || fail "prompt transport consumed bytes mutated after verification"
  assert_absent "$prompt" "prompt transport retained its consumed source after post-hash mutation"
  pass "continuation prompt transport consumes its immutable verified snapshot"
}

test_prompt_transport_preserves_all_bytes
test_prompt_transport_rejects_replaced_generation
test_prompt_transport_rejects_replaced_parent
test_prompt_transport_rejects_in_place_mutation
test_prompt_transport_consumes_verified_snapshot_after_mutation
