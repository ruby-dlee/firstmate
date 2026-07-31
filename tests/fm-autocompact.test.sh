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

recover() {
  local root=$1 home=$2
  printf '%s\n' '{"hook_event_name":"SessionStart","source":"compact","session_id":"session-auto"}' \
    | FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$AUTOCOMPACT" recover
}

mark_stowed() {
  local root=$1 home=$2 transcript=$3 end=$4 state=$5
  shift 5
  FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$AUTOCOMPACT" mark-stowed "$transcript" "$end" "$state" "$@"
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

test_scope_excludes_nonfirstmate_and_includes_secondmate_home() {
  local plain="$TMP_ROOT/scope/plain" plain_home="$TMP_ROOT/scope/plain-home"
  local parent="$TMP_ROOT/scope/parent" secondmate="$TMP_ROOT/scope/secondmate" out
  fm_git_init_commit "$plain"
  mkdir -p "$plain_home/state" "$plain_home/data"
  out=$(capture "$plain" "$plain_home" auto 2>&1)
  [ -z "$out" ] || fail "non-Firstmate capture was noisy: $out"
  assert_absent "$plain_home/data/autocompact-resume.md" "non-Firstmate repository wrote a resume anchor"

  fm_git_worktree "$parent" "$secondmate" secondmate-branch
  mkdir -p "$secondmate/bin" "$secondmate/state" "$secondmate/data"
  printf '# Firstmate secondmate fixture\n' > "$secondmate/AGENTS.md"
  printf 'probe-sm\n' > "$secondmate/.fm-secondmate-home"
  printf '%s\n' '{"type":"user","message":"secondmate conversation"}' > "$secondmate/transcript.jsonl"
  capture "$secondmate" "$secondmate" auto
  assert_present "$secondmate/data/autocompact-resume.md" "valid secondmate home did not capture a resume anchor"
  assert_contains "$(recover "$secondmate" "$secondmate")" 'REQUIRED POST-COMPACTION STOW SWEEP' "valid secondmate home did not receive the recovery directive"
  pass "scope excludes non-Firstmate repositories while preserving valid secondmate homes"
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

test_capture_and_recovery_do_not_require_jq() {
  local rec root home no_jq anchor capture_out recover_out
  rec=$(new_primary no-jq)
  IFS='|' read -r root home <<EOF
$rec
EOF
  printf '%s\n' '# no-jq-backlog' > "$home/data/backlog.md"
  fm_write_meta "$home/state/no-jq-1.meta" 'window=firstmate:fm-no-jq-1' 'kind=ship'
  no_jq="$TMP_ROOT/no-jq/bash-env"
  mkdir -p "$(dirname "$no_jq")"
  cat > "$no_jq" <<'EOF'
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = jq ]; then
    return 1
  fi
  builtin command "$@"
}
jq() {
  return 127
}
EOF

  capture_out=$(printf '%s\n' '{"hook_event_name":"PreCompact","trigger":"auto","session_id":"session-no-jq","transcript_path":"/tmp/no-jq.jsonl"}' \
    | BASH_ENV="$no_jq" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$AUTOCOMPACT" capture 2>&1)
  anchor="$home/data/autocompact-resume.md"
  assert_present "$anchor" "capture without jq did not publish an anchor"
  assert_contains "$capture_out" 'FIRSTMATE AUTOCOMPACT CAPTURE LIMITED' "missing jq was not surfaced loudly"
  assert_contains "$(cat "$anchor")" 'LIMITED - jq is unavailable' "limited anchor did not explain the omitted projection"
  assert_contains "$(cat "$anchor")" '# no-jq-backlog' "capture without jq omitted the raw backlog"
  assert_contains "$(cat "$anchor")" 'window=firstmate:fm-no-jq-1' "capture without jq omitted in-flight metadata"

  recover_out=$(printf '%s\n' '{"hook_event_name":"SessionStart","source":"compact","session_id":"session-no-jq"}' \
    | BASH_ENV="$no_jq" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$AUTOCOMPACT" recover)
  assert_contains "$recover_out" 'FIRSTMATE AUTOCOMPACT RECOVERY CONTEXT' "recovery without jq emitted no context"
  assert_contains "$recover_out" '# no-jq-backlog' "recovery without jq omitted the durable anchor"
  assert_contains "$recover_out" 'NORMAL SESSION-START RECONCILIATION' "recovery without jq skipped reconciliation output"
  pass "capture and compact recovery preserve durable context without jq"
}

test_intermediate_render_failure_preserves_prior_anchor() {
  local rec root home anchor prior out rc fakebin real_sed
  local -a leftovers
  rec=$(new_primary render-failure)
  IFS='|' read -r root home <<EOF
$rec
EOF
  printf '%s\n' '# render-v1' > "$home/data/backlog.md"
  capture "$root" "$home" auto
  anchor="$home/data/autocompact-resume.md"
  prior=$(cat "$anchor")
  printf '%s\n' '# render-v2' > "$home/data/backlog.md"
  fakebin=$(fm_fakebin "$TMP_ROOT/render-failure")
  real_sed=$(command -v sed)
  cat > "$fakebin/sed" <<'EOF'
#!/usr/bin/env bash
if [ "${!#}" = "$FM_AUTOCOMPACT_FAIL_FILE" ]; then
  exit 71
fi
exec "$FM_AUTOCOMPACT_REAL_SED" "$@"
EOF
  chmod +x "$fakebin/sed"

  set +e
  out=$(printf '%s\n' '{"hook_event_name":"PreCompact","trigger":"auto","session_id":"session-render","transcript_path":"/tmp/render.jsonl"}' \
    | PATH="$fakebin:$PATH" \
      FM_AUTOCOMPACT_FAIL_FILE="$home/data/backlog.md" \
      FM_AUTOCOMPACT_REAL_SED="$real_sed" \
      FM_ROOT_OVERRIDE="$root" \
      FM_HOME="$home" \
      "$AUTOCOMPACT" capture 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "intermediate anchor render failure"
  assert_contains "$out" 'could not render the resume anchor' "intermediate render failure was not surfaced"
  [ "$(cat "$anchor")" = "$prior" ] || fail "intermediate render failure replaced the prior good anchor"
  shopt -s nullglob
  leftovers=("$home/data"/.autocompact-resume.md.*)
  shopt -u nullglob
  [ "${#leftovers[@]}" -eq 0 ] || fail "intermediate render failure left a temporary anchor"
  pass "every intermediate render failure blocks partial anchor publication"
}

test_compact_sessionstart_injects_anchor_and_reconciles() {
  local rec root home transcript transcript_end out
  rec=$(new_primary recover)
  IFS='|' read -r root home <<EOF
$rec
EOF
  printf '%s\n' '# recovery-backlog' > "$home/data/backlog.md"
  fm_write_meta "$home/state/active-1.meta" 'window=firstmate:fm-active-1' 'kind=ship'
  transcript="$home/transcript.jsonl"
  printf '%s\n' '{"type":"user","message":"remember the recovery preference"}' > "$transcript"
  transcript_end=$(LC_ALL=C wc -c < "$transcript" | tr -d '[:space:]')
  capture "$root" "$home" auto

  out=$(recover "$root" "$home")
  assert_contains "$out" 'FIRSTMATE AUTOCOMPACT RECOVERY CONTEXT' "recovery context marker is missing"
  assert_contains "$out" 'REQUIRED POST-COMPACTION STOW SWEEP' "compact recovery omitted the required stow directive"
  assert_contains "$out" 'load the stow skill and sweep the whole recovered context' "missing marker did not request a full stow sweep"
  assert_contains "$out" "Pre-compact transcript: $transcript" "stow directive omitted the transcript path"
  assert_contains "$out" "zero-based byte offset 0 inclusive through $transcript_end exclusive" "stow directive omitted the captured byte boundary"
  assert_contains "$out" '.agents/skills/stow/SKILL.md' "stow directive did not point at the routing owner"
  assert_contains "$out" 'fm-autocompact.sh mark-stowed' "stow directive omitted the completion-marker action"
  assert_contains "$out" '# Autocompact resume anchor' "fresh anchor was not re-read"
  assert_contains "$out" 'SESSION START -' "normal session-start reconciliation did not run"
  assert_contains "$out" '# recovery-backlog' "session-start did not read the current backlog"
  assert_contains "$out" 'window=firstmate:fm-active-1' "session-start did not read in-flight metadata"
  pass "compact SessionStart injects a scoped stow directive, re-reads the anchor, and reconciles durable state"
}

test_stow_marker_advances_and_suppresses_duplicate_sweeps() {
  local rec root home transcript first_end second_end out marker mark_out
  rec=$(new_primary marker-advance)
  IFS='|' read -r root home <<EOF
$rec
EOF
  transcript="$home/transcript.jsonl"
  printf '%s\n' '{"type":"user","message":"first durable preference"}' > "$transcript"
  first_end=$(LC_ALL=C wc -c < "$transcript" | tr -d '[:space:]')
  capture "$root" "$home" auto

  out=$(recover "$root" "$home")
  assert_contains "$out" 'ACTION REQUIRED' "the first boundary did not request a stow sweep"
  mark_out=$(mark_stowed "$root" "$home" "$transcript" "$first_end" absent)
  assert_contains "$mark_out" 'STOW MARKER ADVANCED' "successful stow acknowledgement did not advance the marker"
  marker="$home/state/.autocompact-stow.marker"
  assert_present "$marker" "successful stow acknowledgement did not publish a marker"
  assert_contains "$(cat "$marker")" "transcript_path=$transcript" "marker recorded the wrong transcript"
  assert_contains "$(cat "$marker")" "completed_bytes=$first_end" "marker recorded the wrong first boundary"

  out=$(recover "$root" "$home")
  assert_contains "$out" 'NO STOW SWEEP PENDING' "completed boundary did not suppress a duplicate sweep"
  assert_not_contains "$out" 'ACTION REQUIRED' "completed boundary repeated the stow directive"

  printf '%s\n' '{"type":"assistant","message":"second conversation-only learning"}' >> "$transcript"
  second_end=$(LC_ALL=C wc -c < "$transcript" | tr -d '[:space:]')
  capture "$root" "$home" auto
  out=$(recover "$root" "$home")
  assert_contains "$out" "Read zero-based byte offset $first_end inclusive through $second_end exclusive" "next compaction did not scope the sweep to new transcript bytes"
  mark_stowed "$root" "$home" "$transcript" "$second_end" present "$transcript" "$first_end" >/dev/null
  assert_contains "$(cat "$marker")" "completed_bytes=$second_end" "marker did not advance to the second boundary"
  pass "the durable marker advances only after acknowledgement and suppresses duplicate transcript sweeps"
}

test_stale_sweep_cannot_advance_a_changed_boundary() {
  local rec root home transcript first_end second_end out marker rc
  rec=$(new_primary stale-sweep)
  IFS='|' read -r root home <<EOF
$rec
EOF
  transcript="$home/transcript.jsonl"
  printf '%s\n' '{"type":"user","message":"first boundary"}' > "$transcript"
  first_end=$(LC_ALL=C wc -c < "$transcript" | tr -d '[:space:]')
  capture "$root" "$home" auto
  recover "$root" "$home" >/dev/null
  marker="$home/state/.autocompact-stow.marker"
  printf '%s\n' "transcript_path=$transcript" 'completed_bytes=changed-under-sweep' > "$marker"

  set +e
  out=$(mark_stowed "$root" "$home" "$transcript" "$first_end" absent 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "stale sweep after marker change"
  assert_contains "$out" 'the completion marker changed during the sweep' "stale sweep did not reject the changed marker"
  assert_contains "$(cat "$marker")" 'completed_bytes=changed-under-sweep' "stale sweep replaced the changed marker"
  out=$(recover "$root" "$home")
  assert_contains "$out" 'ACTION REQUIRED' "changed marker suppressed the required re-sweep"

  rm "$marker"
  printf '%s\n' '{"type":"assistant","message":"new boundary"}' >> "$transcript"
  second_end=$(LC_ALL=C wc -c < "$transcript" | tr -d '[:space:]')
  capture "$root" "$home" auto

  set +e
  out=$(mark_stowed "$root" "$home" "$transcript" "$first_end" absent 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "stale sweep acknowledgement"
  assert_contains "$out" 'the recovery anchor changed during the sweep' "stale sweep did not reject the changed anchor"
  assert_absent "$marker" "stale sweep advanced the marker"
  out=$(recover "$root" "$home")
  assert_contains "$out" "through $second_end exclusive" "changed boundary did not require a re-sweep"
  assert_contains "$out" 'ACTION REQUIRED' "changed boundary suppressed its re-sweep"
  pass "stale sweep acknowledgement fails closed and leaves the new boundary pending"
}

test_missing_or_corrupt_stow_marker_degrades_to_full_sweep() {
  local rec root home transcript out marker rc
  rec=$(new_primary marker-fallback)
  IFS='|' read -r root home <<EOF
$rec
EOF
  transcript="$home/transcript.jsonl"
  printf '%s\n' '{"type":"user","message":"unswept knowledge"}' > "$transcript"
  capture "$root" "$home" auto
  marker="$home/state/.autocompact-stow.marker"

  out=$(recover "$root" "$home")
  rc=$?
  expect_code 0 "$rc" "recovery with a missing stow marker"
  assert_contains "$out" 'the completion marker is missing' "missing marker reason was not surfaced"
  assert_contains "$out" 'sweep the whole recovered context' "missing marker did not degrade to a full sweep"

  printf '%s\n' "transcript_path=$transcript" 'completed_bytes=not-a-byte-offset' > "$marker"
  out=$(recover "$root" "$home")
  rc=$?
  expect_code 0 "$rc" "recovery with a corrupt stow marker"
  assert_contains "$out" 'the completion marker offset is malformed' "corrupt marker reason was not surfaced"
  assert_contains "$out" 'sweep the whole recovered context' "corrupt marker did not degrade to a full sweep"

  printf '%s\n' "transcript_path=$transcript" 'completed_bytes=99999999999999999999999999999999999999999999999999' > "$marker"
  out=$(recover "$root" "$home")
  rc=$?
  expect_code 0 "$rc" "recovery with an overflowing stow marker offset"
  assert_contains "$out" 'the completion marker offset exceeds the captured boundary' "overflowing marker offset was not bounded safely"
  assert_contains "$out" 'sweep the whole recovered context' "overflowing marker offset did not degrade to a full sweep"
  pass "missing and corrupt stow markers fail open to a whole-context sweep"
}

test_unreadable_transcript_does_not_block_recovery() {
  local rec root home transcript out rc
  rec=$(new_primary unreadable-transcript)
  IFS='|' read -r root home <<EOF
$rec
EOF
  transcript="$home/transcript.jsonl"
  printf '%s\n' '{"type":"user","message":"knowledge behind an unreadable path"}' > "$transcript"
  capture "$root" "$home" auto
  chmod 000 "$transcript"

  set +e
  out=$(recover "$root" "$home" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "recovery with an unreadable transcript"
  assert_contains "$out" 'the pre-compact transcript is unreadable' "unreadable transcript reason was not surfaced"
  assert_contains "$out" 'sweep the whole recovered context' "unreadable transcript did not degrade to a full sweep"
  assert_contains "$out" 'leave the marker unchanged so a later recovery retries the sweep' "unreadable transcript could be silently marked complete"
  chmod 600 "$transcript"
  pass "an unreadable transcript fails open to recovered context without blocking recovery"
}

test_recovery_payload_failures_still_emit_durable_context() {
  local rec root home out payload fakebin real_cat
  rec=$(new_primary recover-payload-failure)
  IFS='|' read -r root home <<EOF
$rec
EOF
  printf '%s\n' '# recovery-payload-fallback' > "$home/data/backlog.md"
  capture "$root" "$home" auto

  for payload in '' '{not-json' '{"hook_event_name":"SessionStart"}'; do
    out=$(printf '%s' "$payload" \
      | FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$AUTOCOMPACT" recover)
    assert_contains "$out" 'FIRSTMATE AUTOCOMPACT RECOVERY WARNING' "invalid recovery payload was not surfaced"
    assert_contains "$out" '# recovery-payload-fallback' "invalid recovery payload suppressed the durable anchor"
    assert_contains "$out" 'NORMAL SESSION-START RECONCILIATION' "invalid recovery payload suppressed reconciliation"
  done

  fakebin=$(fm_fakebin "$TMP_ROOT/recover-payload-failure")
  real_cat=$(command -v cat)
  cat > "$fakebin/cat" <<'EOF'
#!/usr/bin/env bash
if [ "$#" -eq 0 ]; then
  exit 72
fi
exec "$FM_AUTOCOMPACT_REAL_CAT" "$@"
EOF
  chmod +x "$fakebin/cat"
  out=$(printf '%s\n' '{"hook_event_name":"SessionStart","source":"compact"}' \
    | PATH="$fakebin:$PATH" \
      FM_AUTOCOMPACT_REAL_CAT="$real_cat" \
      FM_ROOT_OVERRIDE="$root" \
      FM_HOME="$home" \
      "$AUTOCOMPACT" recover)
  assert_contains "$out" 'FIRSTMATE AUTOCOMPACT RECOVERY WARNING' "unreadable recovery payload was not surfaced"
  assert_contains "$out" '# recovery-payload-fallback' "unreadable recovery payload suppressed the durable anchor"
  assert_contains "$out" 'NORMAL SESSION-START RECONCILIATION' "unreadable recovery payload suppressed reconciliation"
  pass "recovery payload failures still emit all durable context"
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
test_scope_excludes_nonfirstmate_and_includes_secondmate_home
test_capture_failure_blocks_compaction
test_capture_and_recovery_do_not_require_jq
test_intermediate_render_failure_preserves_prior_anchor
test_compact_sessionstart_injects_anchor_and_reconciles
test_stow_marker_advances_and_suppresses_duplicate_sweeps
test_stale_sweep_cannot_advance_a_changed_boundary
test_missing_or_corrupt_stow_marker_degrades_to_full_sweep
test_unreadable_transcript_does_not_block_recovery
test_recovery_payload_failures_still_emit_durable_context
test_noncompact_sessionstart_is_inert
