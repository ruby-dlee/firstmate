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
import os, sys
def read_exact(size):
    chunks = []
    while size:
        chunk = os.read(0, size)
        if not chunk:
            raise RuntimeError("early EOF")
        chunks.append(chunk)
        size -= len(chunk)
    return b"".join(chunks)
with open(sys.argv[1], "wb") as output:
    output.write(read_exact(int(sys.argv[2])))
PY
  command="exec python3 '$script' '$capture' 22"
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
import os, sys
def read_exact(size):
    chunks = []
    while size:
        chunk = os.read(0, size)
        if not chunk:
            raise RuntimeError("early EOF")
        chunks.append(chunk)
        size -= len(chunk)
    return b"".join(chunks)
with open(sys.argv[1], "wb") as output:
    output.write(read_exact(int(sys.argv[2])))
PY
  command="exec python3 '$script' '$capture' 33"
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

test_prompt_transport_keeps_provider_stdin_interactive() {
  local transport="$TMP_ROOT/interactive" prompt="$TMP_ROOT/interactive/prompt"
  local capture="$TMP_ROOT/interactive.capture" script="$TMP_ROOT/interactive.py"
  local command parent_id file_id content_id driver="$TMP_ROOT/interactive-driver.py"
  mkdir "$transport"
  printf 'initial packet' > "$prompt"
  cat > "$script" <<'PY'
import os, sys
def read_exact(size):
    chunks = []
    while size:
        chunk = os.read(0, size)
        if not chunk:
            raise RuntimeError("early EOF")
        chunks.append(chunk)
        size -= len(chunk)
    return b"".join(chunks)
initial = read_exact(14)
separator = read_exact(1)
followup = read_exact(16)
with open(sys.argv[1], "wb") as output:
    output.write(b"tty=" + str(os.isatty(0)).encode() + b"\n")
    output.write(initial + b"\n" + separator + b"\n" + followup)
PY
  command="exec python3 '$script' '$capture'"
  parent_id=$(path_identity "$transport"); file_id=$(path_identity "$prompt"); content_id=$(content_identity "$prompt")
  cat > "$driver" <<'PY'
import os, pty, subprocess, sys, time
master, slave = pty.openpty()
process = subprocess.Popen(sys.argv[1:], stdin=slave, stdout=slave, stderr=slave, close_fds=True)
os.close(slave)
time.sleep(0.2)
os.write(master, b"later steering.\r")
status = process.wait(timeout=5)
os.close(master)
raise SystemExit(status)
PY
  python3 "$driver" python3 "$ROOT/bin/fm-prompt-exec.py" "$prompt" "$parent_id" "$file_id" "$content_id" "$command" \
    || fail "continuation prompt transport did not preserve interactive provider stdin"
  assert_grep 'tty=True' "$capture" "continuation provider stdin was not a PTY"
  assert_grep 'initial packet' "$capture" "continuation transport changed the initial packet"
  assert_grep 'later steering.' "$capture" "continuation transport did not relay later steering"
  pass "continuation prompt transport preserves interactive provider stdin after initial delivery"
}

test_prompt_transport_waits_for_raw_mode() {
  local transport="$TMP_ROOT/raw-ready" prompt="$TMP_ROOT/raw-ready/prompt"
  local capture="$TMP_ROOT/raw-ready.capture" script="$TMP_ROOT/raw-ready.py"
  local ready="$TMP_ROOT/raw-ready.ready" proceed="$TMP_ROOT/raw-ready.proceed"
  local command parent_id file_id content_id pid
  mkdir "$transport"
  printf 'before\003middle\004after\377' > "$prompt"
  cat > "$script" <<'PY'
import os, sys
size = int(sys.argv[2])
content = bytearray()
while len(content) < size:
    chunk = os.read(0, size - len(content))
    if not chunk:
        raise RuntimeError("early EOF")
    content.extend(chunk)
with open(sys.argv[1], "wb") as output:
    output.write(content)
PY
  command="exec python3 '$script' '$capture' 20"
  parent_id=$(path_identity "$transport"); file_id=$(path_identity "$prompt"); content_id=$(content_identity "$prompt")
  FM_PROMPT_EXEC_TEST_BEFORE_RAW_READY="$ready" FM_PROMPT_EXEC_TEST_BEFORE_RAW_PROCEED="$proceed" \
    python3 "$ROOT/bin/fm-prompt-exec.py" "$prompt" "$parent_id" "$file_id" "$content_id" "$command" &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.02; done
  [ -e "$ready" ] || { kill -TERM "$pid" 2>/dev/null || true; fail "raw-mode readiness gate did not open"; }
  assert_absent "$capture" "prompt bytes reached the provider before raw mode was active"
  touch "$proceed"
  wait "$pid" || fail "prompt transport failed after raw-mode readiness"
  cmp -s "$capture" <(printf 'before\003middle\004after\377') \
    || fail "prompt transport applied canonical-mode processing before raw readiness"
  pass "continuation prompt transport waits for raw mode before writing bytes"
}

test_prompt_transport_restores_inherited_terminal_state() {
  local transport="$TMP_ROOT/terminal-state" prompt="$TMP_ROOT/terminal-state/prompt"
  local driver="$TMP_ROOT/terminal-state-driver.py" command parent_id file_id content_id
  mkdir "$transport"
  printf 'packet' > "$prompt"
  cat > "$driver" <<'PY'
import fcntl, os, pty, subprocess, sys, termios
master, slave = pty.openpty()
before_flags = fcntl.fcntl(slave, fcntl.F_GETFL)
before_termios = termios.tcgetattr(slave)
process = subprocess.run(sys.argv[1:], stdin=slave, stdout=slave, stderr=slave, close_fds=True, timeout=5)
after_flags = fcntl.fcntl(slave, fcntl.F_GETFL)
after_termios = termios.tcgetattr(slave)
os.close(slave)
os.close(master)
if process.returncode != 0:
    raise SystemExit(process.returncode)
if after_flags != before_flags:
    raise RuntimeError("inherited stdin flags changed")
if after_termios != before_termios:
    raise RuntimeError("inherited stdin termios changed")
PY
  command="exec python3 -c 'import os; os.read(0, 6)'"
  parent_id=$(path_identity "$transport"); file_id=$(path_identity "$prompt"); content_id=$(content_identity "$prompt")
  python3 "$driver" python3 "$ROOT/bin/fm-prompt-exec.py" \
    "$prompt" "$parent_id" "$file_id" "$content_id" "$command" \
    || fail "prompt transport did not restore inherited terminal state"
  pass "continuation prompt transport restores inherited stdin flags and termios"
}

test_prompt_transport_preserves_all_bytes
test_prompt_transport_rejects_replaced_generation
test_prompt_transport_rejects_replaced_parent
test_prompt_transport_rejects_in_place_mutation
test_prompt_transport_consumes_verified_snapshot_after_mutation
test_prompt_transport_keeps_provider_stdin_interactive
test_prompt_transport_waits_for_raw_mode
test_prompt_transport_restores_inherited_terminal_state
