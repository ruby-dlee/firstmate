#!/usr/bin/env bash
# Behavior tests for Claude Code's deterministic autocompact recovery bridge.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck disable=SC2153
AUTOCOMPACT="$ROOT/bin/fm-autocompact.sh"
TMP_ROOT=$(fm_test_tmproot fm-autocompact-tests)
fm_git_identity fmtest fmtest@example.invalid

new_primary() {
  local root="$TMP_ROOT/$1/root" home="$TMP_ROOT/$1/home"
  fm_git_init_commit "$root"
  mkdir -p "$root/bin" "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '# Firstmate fixture\n' > "$root/AGENTS.md"
  printf '%s|%s\n' "$root" "$home"
}

capture() {
  local root=$1 home=$2 trigger=${3:-auto}
  printf '{"hook_event_name":"PreCompact","trigger":"%s","session_id":"session-%s","transcript_path":"%s/transcript.jsonl"}\n' \
    "$trigger" "$trigger" "$home" \
    | FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$AUTOCOMPACT" capture
}

test_tracked_hook_registration_preserves_existing_hooks() {
  local settings="$ROOT/.claude/settings.json" pre recover
  pre=$(jq -r '.hooks.PreCompact[]?.hooks[]?.command // empty' "$settings")
  recover=$(jq -r '.hooks.SessionStart[]? | select(.matcher == "compact") | .hooks[]?.command // empty' "$settings")
  assert_contains "$pre" "\"\$CLAUDE_PROJECT_DIR\"/bin/fm-autocompact.sh capture" "PreCompact hook is not project-root anchored"
  assert_contains "$recover" "\"\$CLAUDE_PROJECT_DIR\"/bin/fm-autocompact.sh recover" "compact SessionStart hook is not project-root anchored"
  [ "$(jq '.hooks.Stop | length' "$settings")" -gt 0 ] || fail "Stop hooks were disturbed"
  [ "$(jq '.hooks.PreToolUse | length' "$settings")" -gt 0 ] || fail "PreToolUse hooks were disturbed"
  pass "tracked Claude settings register both compaction phases without disturbing existing hooks"
}

test_capture_writes_fresh_durable_anchor() {
  local rec root home anchor first second
  rec=$(new_primary capture)
  IFS='|' read -r root home <<EOF
$rec
EOF
  mkdir -p "$home/worktree"
  printf '%s\n' '# backlog-v1' '## Queued' '- [ ] queued-1 - Follow-up task blocked-by: active-1 - wait for held merge' > "$home/data/backlog.md"
  fm_write_meta "$home/state/active-1.meta" \
    'window=firstmate:fm-active-1' \
    "worktree=$home/worktree" \
    'kind=ship' \
    'pr=https://github.com/example/firstmate/pull/123' \
    'mode=no-mistakes'
  printf '%s\n' 'needs-decision: PR held for captain merge [key=merge-hold]' > "$home/state/active-1.status"

  capture "$root" "$home" manual
  anchor="$home/data/autocompact-resume.md"
  assert_present "$anchor" "PreCompact did not write the resume anchor"
  first=$(cat "$anchor")
  assert_contains "$first" "Trigger: \`manual\`" "manual trigger was not captured"
  assert_contains "$first" 'in_flight[1]' "live fleet pickup state is missing"
  assert_contains "$first" 'PR held for captain merge' "held merge decision is missing"
  assert_contains "$first" 'https://github.com/example/firstmate/pull/123' "recorded PR is missing"
  assert_contains "$first" '# backlog-v1' "full backlog is missing"
  assert_contains "$first" 'window=firstmate:fm-active-1' "raw in-flight metadata is missing"

  printf '%s\n' '# backlog-v2' '## Queued' '- [ ] queued-2 - Replacement next step' > "$home/data/backlog.md"
  capture "$root" "$home" auto
  second=$(cat "$anchor")
  assert_contains "$second" "Trigger: \`auto\`" "automatic trigger was not captured"
  assert_contains "$second" '# backlog-v2' "fresh backlog did not replace the prior anchor"
  assert_not_contains "$second" '# backlog-v1' "capture appended instead of atomically replacing the anchor"
  pass "PreCompact atomically refreshes all durable pickup surfaces"
}

test_capture_is_inert_in_child_worktree() {
  local parent="$TMP_ROOT/worktree/parent" child="$TMP_ROOT/worktree/child" home="$TMP_ROOT/worktree/home" out
  fm_git_worktree "$parent" "$child" task-branch
  mkdir -p "$child/bin" "$home/state" "$home/data"
  printf '# Firstmate fixture\n' > "$child/AGENTS.md"
  out=$(capture "$child" "$home" auto 2>&1)
  [ -z "$out" ] || fail "child worktree capture was noisy: $out"
  assert_absent "$home/data/autocompact-resume.md" "child worktree wrote a primary resume anchor"
  pass "tracked hook is a silent no-op in a crewmate worktree"
}

test_capture_failure_blocks_compaction() {
  local rec root home rc out
  rec=$(new_primary failure)
  IFS='|' read -r root home <<EOF
$rec
EOF
  mv "$home/data" "$home/data-real"
  ln -s "$home/data-real" "$home/data"
  set +e
  out=$(capture "$root" "$home" auto 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "failed primary capture"
  assert_contains "$out" 'FIRSTMATE AUTOCOMPACT CAPTURE FAILED' "capture failure was not surfaced"
  assert_absent "$home/data/autocompact-resume.md" "failed capture published a partial anchor"
  pass "an in-scope capture failure blocks compaction instead of silently losing the anchor"
}

test_compact_sessionstart_injects_anchor_and_reconciles() {
  local rec root home out
  rec=$(new_primary recover)
  IFS='|' read -r root home <<EOF
$rec
EOF
  printf '%s\n' '# recovery-backlog' > "$home/data/backlog.md"
  fm_write_meta "$home/state/active-1.meta" 'window=firstmate:fm-active-1' 'kind=ship'
  capture "$root" "$home" auto

  out=$(printf '%s\n' '{"hook_event_name":"SessionStart","source":"compact","session_id":"session-auto"}' \
    | FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$AUTOCOMPACT" recover)
  assert_contains "$out" 'FIRSTMATE AUTOCOMPACT RECOVERY CONTEXT' "recovery context marker is missing"
  assert_contains "$out" '# Autocompact resume anchor' "fresh anchor was not re-read"
  assert_contains "$out" 'SESSION START -' "normal session-start reconciliation did not run"
  assert_contains "$out" '# recovery-backlog' "session-start did not read the current backlog"
  assert_contains "$out" 'window=firstmate:fm-active-1' "session-start did not read in-flight metadata"
  pass "compact SessionStart re-reads the anchor and runs normal durable-state reconciliation"
}

test_noncompact_sessionstart_is_inert() {
  local rec root home out
  rec=$(new_primary noncompact)
  IFS='|' read -r root home <<EOF
$rec
EOF
  out=$(printf '%s\n' '{"hook_event_name":"SessionStart","source":"resume"}' \
    | FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$AUTOCOMPACT" recover)
  [ -z "$out" ] || fail "ordinary resume unexpectedly ran compact recovery: $out"
  pass "ordinary startup and resume events do not run compact recovery"
}

test_tracked_hook_registration_preserves_existing_hooks
test_capture_writes_fresh_durable_anchor
test_capture_is_inert_in_child_worktree
test_capture_failure_blocks_compaction
test_compact_sessionstart_injects_anchor_and_reconciles
test_noncompact_sessionstart_is_inert
