#!/usr/bin/env bash
# Behavior tests for the machine-global Firstmate completion report stack.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-report-stack)
HOME_DIR="$TMP_ROOT/home"
STACK="$TMP_ROOT/stack"
SCRIPT="$ROOT/bin/fm-report-stack.mjs"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"

write_task() {
  local id=$1 kind=${2:-ship} task_dir="$HOME_DIR/data/$1"
  mkdir -p "$task_dir"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$TMP_ROOT/no-longer-present" \
    "project=$TMP_ROOT/projects/example" \
    "harness=codex" \
    "kind=$kind" \
    "mode=no-mistakes" \
    "report_required=1" \
    "account_profile=codex-2" \
    "provider_session_id=must-not-leak"
  printf '# Task\n\nFinish the report stack\n\n# Rules\n' > "$task_dir/brief.md"
  printf 'working: implementing\ndone: report stack ready\n' > "$HOME_DIR/state/$id.status"
}

run_stack() {
  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$STACK" "$SCRIPT" "$@"
}

test_publish_ship_with_visual() {
  local id=report-ship-a1 entry count manifest report_id completed_at
  write_task "$id" ship
  mkdir -p "$HOME_DIR/data/$id/visuals"
  printf '# Completion\n\n## Summary\n\nA searchable report stack is ready.\n\n## What changed\n\nAdded publication.\n\n## Verification\n\nTests passed.\n\npassword=must-also-not-leak\n\n## Visual evidence\n\nSee overview.\n\n## Artifacts\n\nIndex.\n\n## Follow-ups\n\nNone.\n' > "$HOME_DIR/data/$id/completion.md"
  printf 'synthetic image bytes' > "$HOME_DIR/data/$id/visuals/overview.png"

  run_stack publish "$id" >/dev/null || fail "ship report publication failed"
  entry=$(run_stack path "$id")
  assert_present "$entry" "published report HTML is missing"
  assert_present "$STACK/index.html" "report stack index is missing"
  assert_present "$(dirname "$entry")/visuals/overview.png" "visual evidence was not copied"
  assert_grep 'Finish the report stack' "$entry" "report page lost the task title"
  assert_grep 'overview.png' "$entry" "report page lost the visual gallery"
  assert_grep 'codex-2' "$(dirname "$entry")/manifest.json" "safe account routing label was not retained"
  if grep -R -F 'must-not-leak' "$STACK" >/dev/null 2>&1; then
    fail "provider session id leaked into the report stack"
  fi
  if grep -R -F 'must-also-not-leak' "$STACK" >/dev/null 2>&1; then
    fail "credential-like report text was not redacted"
  fi
  assert_grep 'password=[REDACTED]' "$(dirname "$entry")/report.md" "report redaction left no visible marker"

  manifest="$(dirname "$entry")/manifest.json"
  report_id=$(sed -n 's/.*"reportId": "\([^"]*\)".*/\1/p' "$manifest")
  completed_at=$(sed -n 's/.*"completedAt": "\([^"]*\)".*/\1/p' "$manifest")
  rm -f "$HOME_DIR/data/$id/visuals/overview.png"
  printf 'replacement image bytes' > "$HOME_DIR/data/$id/visuals/corrected.png"
  printf '# Completion\n\n## Summary\n\nThe corrected searchable report is ready.\n\n## What changed\n\nRebuilt publication.\n\n## Verification\n\nRetry passed.\n\n## Visual evidence\n\nSee corrected.\n\n## Artifacts\n\nIndex.\n\n## Follow-ups\n\nNone.\n' > "$HOME_DIR/data/$id/completion.md"
  printf 'working: implementing\ndone: corrected report stack ready\n' > "$HOME_DIR/state/$id.status"
  run_stack publish "$id" >/dev/null || fail "corrected report retry failed"
  assert_grep 'The corrected searchable report is ready' "$(dirname "$entry")/report.md" "report retry retained stale completion text"
  assert_grep 'corrected report stack ready' "$(dirname "$entry")/status.log" "report retry retained a stale status trail"
  assert_present "$(dirname "$entry")/visuals/corrected.png" "report retry lost corrected visual evidence"
  assert_absent "$(dirname "$entry")/visuals/overview.png" "report retry retained removed visual evidence"
  assert_grep "\"reportId\": \"$report_id\"" "$manifest" "report retry changed its stable id"
  assert_grep "\"completedAt\": \"$completed_at\"" "$manifest" "report retry changed its original completion timestamp"
  count=$(find "$STACK/entries" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "report retry created duplicate entries (count=$count)"
  pass "report stack replaces corrected ship reports without changing stable identity"
}

test_required_source_fails_closed() {
  local id=report-missing-b2 out status
  write_task "$id" ship
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "missing required completion report unexpectedly published"
  assert_contains "$out" "required completion report is missing" "missing report failure was not actionable"
  pass "report stack refuses a required ship report with no completion source"
}

test_scout_and_legacy_sources() {
  local scout=report-scout-c3 legacy=report-legacy-d4 json
  write_task "$scout" scout
  printf '# Scout report\n\n## Summary\n\nThe investigation is complete.\n' > "$HOME_DIR/data/$scout/report.md"
  run_stack publish "$scout" >/dev/null || fail "scout report publication failed"

  write_task "$legacy" ship
  run_stack publish "$legacy" --legacy >/dev/null || fail "legacy compatibility publication failed"
  json=$(run_stack list --json)
  printf '%s' "$json" | grep -F '"taskId": "report-scout-c3"' >/dev/null || fail "scout is absent from report inventory"
  printf '%s' "$json" | grep -F '"taskId": "report-legacy-d4"' >/dev/null || fail "legacy task is absent from report inventory"
  assert_grep 'compatibility report was synthesized' "$(dirname "$(run_stack path "$legacy")")/report.md" "legacy synthesis was not preserved"
  pass "report stack accepts scout reports and intentional legacy synthesis"
}

test_stale_lock_rejects_reused_pid() {
  mkdir -p "$STACK/.publish.lock"
  printf '{"pid":%s,"startedAt":"different-process-start"}\n' "$$" > "$STACK/.publish.lock/owner"
  touch -t 200001010000 "$STACK/.publish.lock"
  run_stack render >/dev/null || fail "stale report lock with a reused pid was not reclaimed"
  assert_absent "$STACK/.publish.lock" "report render retained a reclaimed publication lock"
  pass "report stack lock verifies process-start identity before trusting a live pid"
}

test_visual_symlink_fails_closed_and_cleans_staging() {
  local id=report-symlink-e5 out status staged
  write_task "$id" ship
  printf '# Completion\n\n## Summary\n\nSymlink safety.\n' > "$HOME_DIR/data/$id/completion.md"
  mkdir -p "$TMP_ROOT/outside-visuals"
  printf 'private visual bytes\n' > "$TMP_ROOT/outside-visuals/private.png"
  ln -s "$TMP_ROOT/outside-visuals" "$HOME_DIR/data/$id/visuals"
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "symlinked visual root unexpectedly published"
  assert_contains "$out" "visual evidence root must be a real directory" "symlinked visual refusal was not actionable"
  if grep -R -F 'private visual bytes' "$STACK" >/dev/null 2>&1; then
    fail "symlinked visual content escaped into the report stack"
  fi
  staged=$(find "$STACK/entries" -maxdepth 1 -type d -name ".*${id}*.tmp" -print 2>/dev/null)
  [ -z "$staged" ] || fail "failed report publication leaked staging directory $staged"
  pass "report stack rejects symlinked visuals and removes failed staging"
}

test_publish_ship_with_visual
test_required_source_fails_closed
test_scout_and_legacy_sources
test_stale_lock_rejects_reused_pid
test_visual_symlink_fails_closed_and_cleans_staging
