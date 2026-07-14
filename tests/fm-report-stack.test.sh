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
  local id=report-ship-a1 entry count
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

  run_stack publish "$id" >/dev/null || fail "idempotent report retry failed"
  count=$(find "$STACK/entries" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "report retry created duplicate entries (count=$count)"
  pass "report stack publishes one visual ship entry without session secrets"
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

test_publish_ship_with_visual
test_required_source_fails_closed
test_scout_and_legacy_sources
