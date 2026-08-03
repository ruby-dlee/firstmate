#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HELPER="$ROOT/bin/fm_bounded_io.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "$3 (missing: $2)" ;;
  esac
}

test_output_limit_terminates_noisy_process() {
  output="$TMP/output-limit"
  if python3 "$HELPER" run --timeout 5 --max-output-bytes 1024 -- \
    python3 -c 'import sys; sys.stdout.write("x" * 4096)' >"$output" 2>&1; then
    fail "noisy process crossed the aggregate output ceiling"
  fi
  value=$(cat "$output")
  assert_contains "$value" "1024-byte aggregate output limit" \
    "output-limit failure was not loud"
  [ "$(wc -c < "$output" | tr -d '[:space:]')" -lt 2048 ] \
    || fail "output-limit diagnostic was itself unbounded"
}

test_final_wait_keeps_original_deadline() {
  started=$(python3 -c 'import time; print(time.monotonic())')
  output="$TMP/final-wait"
  if python3 "$HELPER" run --timeout 0.25 --max-output-bytes 1024 -- \
    python3 -c 'import os,time; os.close(1); os.close(2); time.sleep(1.5)' \
    >"$output" 2>&1; then
    fail "closed output pipes escaped the command deadline"
  fi
  elapsed=$(python3 -c 'import sys,time; print(time.monotonic()-float(sys.argv[1]))' "$started")
  python3 -c 'import sys; raise SystemExit(0 if float(sys.argv[1]) < 1.25 else 1)' "$elapsed" \
    || fail "final wait exceeded the original deadline: ${elapsed}s"
  assert_contains "$(cat "$output")" "timed out after 0.25 seconds" \
    "final-wait timeout was not loud"
}

test_success_reaps_residual_process_group() {
  pid_file="$TMP/residual-pid"
  python3 "$HELPER" run --timeout 2 --max-output-bytes 1024 -- \
    python3 -c 'import subprocess,sys; child=subprocess.Popen([sys.executable,"-c","import time; time.sleep(3)"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); print(child.pid)' \
    >"$pid_file"
  child_pid=$(cat "$pid_file")
  case "$child_pid" in ''|*[!0-9]*) fail "residual child PID was malformed" ;; esac
  if kill -0 "$child_pid" 2>/dev/null; then
    fail "successful leader left residual process $child_pid alive"
  fi
}

test_json_artifact_is_bounded_and_regular() {
  artifact="$TMP/verdict.json"
  python3 -c 'import json,sys; open(sys.argv[1],"w").write(json.dumps({"padding":"x"*4096}))' "$artifact"
  output="$TMP/artifact-output"
  if python3 "$HELPER" json --max-bytes 1024 "$artifact" >"$output" 2>&1; then
    fail "oversized structured artifact bypassed its byte ceiling"
  fi
  assert_contains "$(cat "$output")" "exceeds 1024 bytes" \
    "oversized artifact failure was not loud"
  ln -s "$artifact" "$TMP/verdict-link.json"
  if python3 "$HELPER" json --max-bytes 8192 "$TMP/verdict-link.json" \
    >"$output" 2>&1; then
    fail "symlinked structured artifact was accepted"
  fi
  assert_contains "$(cat "$output")" "not a regular file" \
    "symlinked artifact failure was not loud"
}

test_json_decoded_strings_are_bounded() {
  artifact="$TMP/strings.json"
  python3 -c 'import json,sys; open(sys.argv[1],"w").write(json.dumps({"padding":"x"*512}))' "$artifact"
  output="$TMP/structure-output"
  if python3 "$HELPER" json --max-bytes 2048 --max-string-bytes 128 "$artifact" \
    >"$output" 2>&1; then
    fail "decoded strings bypassed their aggregate ceiling"
  fi
  assert_contains "$(cat "$output")" "decoded string limit" \
    "decoded-string failure was not loud"
}

test_batch_item_count_is_bounded() {
  python3 - "$HELPER" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("fm_bounded_io", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
budget = module.DeadlineBudget(1, 2)
budget.consume_items([1, 2], "review items")
try:
    budget.consume_item("review items")
except module.BoundedIOError as error:
    assert "2-item limit" in str(error)
else:
    raise AssertionError("batch item ceiling was not enforced")
PY
}

run_case() {
  case "$1" in
    output-limit) test_output_limit_terminates_noisy_process ;;
    final-wait) test_final_wait_keeps_original_deadline ;;
    residual-group) test_success_reaps_residual_process_group ;;
    artifact) test_json_artifact_is_bounded_and_regular ;;
    decoded-strings) test_json_decoded_strings_are_bounded ;;
    batch-items) test_batch_item_count_is_bounded ;;
    *) fail "unknown bounded-I/O test case: $1" ;;
  esac
}

if [ "$#" -gt 0 ]; then
  run_case "$1"
else
  for case_name in output-limit final-wait residual-group artifact decoded-strings batch-items; do
    run_case "$case_name"
  done
fi

echo "fm-bounded-io tests passed"
