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
    "generation_id=generation-$id" \
    "account_profile=codex-2" \
    "provider_session_id=must-not-leak"
  printf '# Task\n\nFinish the report stack\n\n# Rules\n' > "$task_dir/brief.md"
  printf 'working: implementing\ndone: report stack ready\n' > "$HOME_DIR/state/$id.status"
}

run_stack() {
  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$STACK" "$SCRIPT" "$@"
}

run_stack_home() {
  local home=$1
  shift
  FM_HOME="$home" FM_REPORT_STACK_ROOT="$STACK" "$SCRIPT" "$@"
}

write_required_report() {
  local file=$1 summary=$2
  printf '# Completion\n\n## Summary\n\n%s\n\n## What changed\n\nRecorded work.\n\n## Verification\n\nEvidence checked.\n\n## Visual evidence\n\nNone.\n\n## Artifacts\n\nReport.\n\n## Follow-ups\n\nNone.\n' "$summary" > "$file"
}

test_publish_ship_with_visual() {
  local id=report-ship-a1 entry count manifest report_id completed_at
  write_task "$id" ship
  mkdir -p "$HOME_DIR/data/$id/visuals"
  printf '# Completion\n\n## Summary\n\nA searchable report stack is ready.\n\n## What changed\n\nAdded publication.\n\n## Verification\n\nTests passed.\n\npassword=must-also-not-leak\nAWS_SECRET_ACCESS_KEY=aws-secret-value\nDB_PASSWORD=db-secret-value\nSLACK_BOT_TOKEN=slack-secret-value\nhttps://user:url-secret@example.invalid/path\n{"password":"json-password-secret","access_token":"json-access-secret","safe":"visible"}\n\n## Visual evidence\n\nSee overview.\n\n## Artifacts\n\nIndex.\n\n## Follow-ups\n\nNone.\n' > "$HOME_DIR/data/$id/completion.md"
  printf 'synthetic image bytes' > "$HOME_DIR/data/$id/visuals/overview.png"

  run_stack publish "$id" >/dev/null || fail "ship report publication failed"
  entry=$(run_stack path "$id")
  assert_present "$entry" "published report HTML is missing"
  assert_present "$STACK/index.html" "report stack index is missing"
  assert_present "$(dirname "$entry")/visuals/overview.png" "visual evidence was not copied"
  assert_grep 'Finish the report stack' "$entry" "report page lost the task title"
  assert_grep 'overview.png' "$entry" "report page lost the visual gallery"
  assert_grep 'codex-2' "$(dirname "$entry")/manifest.json" "safe account routing label was not retained"
  assert_grep '"generationId": "generation-report-ship-a1"' "$(dirname "$entry")/manifest.json" "stable generation identity was not published"
  if grep -R -F 'must-not-leak' "$STACK" >/dev/null 2>&1; then
    fail "provider session id leaked into the report stack"
  fi
  if grep -R -F 'must-also-not-leak' "$STACK" >/dev/null 2>&1; then
    fail "credential-like report text was not redacted"
  fi
  assert_grep 'password=[REDACTED]' "$(dirname "$entry")/report.md" "report redaction left no visible marker"
  if grep -E 'aws-secret-value|db-secret-value|slack-secret-value|url-secret|json-password-secret|json-access-secret' "$(dirname "$entry")/report.md" >/dev/null 2>&1; then
    fail "prefixed or URL credentials survived report redaction"
  fi
  assert_grep 'AWS_SECRET_ACCESS_KEY=[REDACTED]' "$(dirname "$entry")/report.md" "prefixed access-key redaction left no marker"
  assert_grep 'https://[REDACTED]@example.invalid/path' "$(dirname "$entry")/report.md" "credential URL redaction left no marker"
  assert_grep '"password":"[REDACTED]","access_token":"[REDACTED]","safe":"visible"' "$(dirname "$entry")/report.md" "inline JSON credential redaction damaged safe fields"

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

test_report_links_reject_credentials_and_encode_visual_paths() {
  local id=report-links-a2 entry manifest visual
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Safe report links."
  printf 'pr=https://report-user:report-secret@example.invalid/pull/1\n' >> "$HOME_DIR/state/$id.meta"
  visual="$HOME_DIR/data/$id/visuals/screens/evidence #1?%.png"
  mkdir -p "$(dirname "$visual")"
  printf 'synthetic image bytes' > "$visual"

  run_stack publish "$id" >/dev/null || fail "safe-link report publication failed"
  entry=$(run_stack path "$id")
  manifest="$(dirname "$entry")/manifest.json"
  assert_grep '"prUrl": ""' "$manifest" "credential-bearing pull request URL was retained"
  if grep -R -F 'report-secret' "$STACK" >/dev/null 2>&1; then
    fail "pull request URL credentials leaked into the report stack"
  fi
  assert_grep 'visuals/screens/evidence%20%231%3F%25.png' "$entry" "visual URL path segments were not encoded"
  assert_present "$(dirname "$entry")/visuals/screens/evidence #1?%.png" "encoded visual link lost its copied artifact"
  pass "report links reject credentials and encode visual paths"
}

test_pr_url_strips_query_and_fragment() {
  local id=report-pr-url-a2b entry manifest
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Sanitized pull request URL."
  printf 'pr=https://github.com/example/repo/pull/42?token=secret-query#private-fragment\n' \
    >> "$HOME_DIR/state/$id.meta"
  run_stack publish "$id" >/dev/null || fail "query-bearing PR URL report publication failed"
  entry=$(run_stack path "$id")
  manifest="$(dirname "$entry")/manifest.json"
  assert_grep '"prUrl": "https://github.com/example/repo/pull/42"' "$manifest" \
    "PR URL query and fragment were not stripped"
  if grep -R -E 'secret-query|private-fragment' "$(dirname "$entry")" >/dev/null 2>&1; then
    fail "PR URL query or fragment leaked into the report entry"
  fi
  pass "report PR URLs discard query strings and fragments"
}

test_revision_fields_distinguish_pr_head_from_worktree_head() {
  local id=report-revisions-a3 repo meta meta_tmp entry manifest page head short pr_head
  repo="$TMP_ROOT/revision-worktree"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.name fmtest
  git -C "$repo" config user.email fmtest@example.invalid
  printf 'revision fixture\n' > "$repo/fixture.txt"
  git -C "$repo" add fixture.txt
  git -C "$repo" commit -q -m fixture
  head=$(git -C "$repo" rev-parse HEAD)
  short=${head:0:12}
  pr_head=abcdef1234567890abcdef1234567890abcdef12

  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Revision identities are precise."
  meta="$HOME_DIR/state/$id.meta"
  meta_tmp="$HOME_DIR/state/.$id.meta.revisions"
  grep -v '^worktree=' "$meta" > "$meta_tmp"
  printf 'worktree=%s\npr_head=%s\n' "$repo" "$pr_head" >> "$meta_tmp"
  mv "$meta_tmp" "$meta"

  run_stack publish "$id" >/dev/null || fail "revision report publication failed"
  entry=$(run_stack path "$id")
  manifest="$(dirname "$entry")/manifest.json"
  page="$entry"
  assert_grep "\"worktreeHead\": \"$short\"" "$manifest" "manifest did not record the local worktree HEAD accurately"
  assert_grep "\"commit\": \"$short\"" "$manifest" "schema-version-1 commit compatibility alias was not retained"
  assert_grep '"prHead": "abcdef123456"' "$manifest" "manifest did not record the delivered PR head consistently"
  assert_grep '<dt>PR head</dt><dd>abcdef123456</dd>' "$page" "report page mislabeled the delivered PR revision"
  assert_grep "<dt>Worktree HEAD</dt><dd>$short</dd>" "$page" "report page mislabeled the local worktree revision"

  mkdir -p "$STACK/entries/legacy-schema-v1"
  printf '{"schemaVersion":1,"reportId":"legacy-schema-v1","taskId":"legacy-schema-v1","title":"Legacy","summary":"Legacy manifest","completedAt":"2026-07-01T00:00:00.000Z","kind":"ship","project":"example","harness":"codex","commit":"1234567890ab"}\n' \
    > "$STACK/entries/legacy-schema-v1/manifest.json"
  run_stack render >/dev/null || fail "report reader rejected a schema-version-1 manifest without new revision fields"
  pass "report manifests distinguish PR head from worktree HEAD compatibly"
}

test_republish_new_generation_refreshes_completion_time() {
  local id=report-generation-a4 repo meta entry manifest staged
  repo="$TMP_ROOT/generation-worktree"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.name fmtest
  git -C "$repo" config user.email fmtest@example.invalid
  git -C "$repo" commit -q --allow-empty -m first
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "First generation."
  meta="$HOME_DIR/state/$id.meta"
  staged="$HOME_DIR/state/.$id.meta.generation"
  grep -v '^worktree=' "$meta" > "$staged"
  printf 'worktree=%s\n' "$repo" >> "$staged"
  mv "$staged" "$meta"
  run_stack publish "$id" >/dev/null || fail "first generation report publication failed"
  entry=$(run_stack path "$id")
  manifest="$(dirname "$entry")/manifest.json"
  sed 's/"completedAt": "[^"]*"/"completedAt": "2000-01-01T00:00:00.000Z"/' "$manifest" > "$manifest.tmp"
  mv "$manifest.tmp" "$manifest"

  git -C "$repo" commit -q --allow-empty -m second
  sed 's/^harness=.*/harness=claude/; s/^account_profile=.*/account_profile=claude-3/; s/^generation_id=.*/generation_id=generation-restored/' "$meta" > "$staged"
  mv "$staged" "$meta"
  write_required_report "$HOME_DIR/data/$id/completion.md" "Restored generation."
  run_stack publish "$id" >/dev/null || fail "restored generation report publication failed"
  if grep -q '"completedAt": "2000-01-01T00:00:00.000Z"' "$manifest"; then
    fail "new generation retained the superseded completion timestamp"
  fi
  assert_grep '"harness": "claude"' "$manifest" "new generation report retained the superseded harness"
  assert_grep '"accountProfile": "claude-3"' "$manifest" "new generation report retained the superseded profile"
  pass "report republish refreshes completion time for a new task generation"
}

test_same_generation_republish_preserves_revision_without_worktree() {
  local id=report-revision-retry-a4b repo meta staged entry manifest head short branch
  repo="$TMP_ROOT/revision-retry-worktree"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.name fmtest
  git -C "$repo" config user.email fmtest@example.invalid
  git -C "$repo" commit -q --allow-empty -m first
  head=$(git -C "$repo" rev-parse HEAD)
  short=${head:0:12}
  branch=$(git -C "$repo" branch --show-current)
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Revision survives retry."
  meta="$HOME_DIR/state/$id.meta"
  staged="$HOME_DIR/state/.$id.meta.revision-retry"
  grep -v '^worktree=' "$meta" > "$staged"
  printf 'worktree=%s\n' "$repo" >> "$staged"
  mv "$staged" "$meta"
  run_stack publish "$id" >/dev/null || fail "revision retry precondition publication failed"
  entry=$(run_stack path "$id")
  manifest="$(dirname "$entry")/manifest.json"

  grep -v '^worktree=' "$meta" > "$staged"
  printf 'worktree=%s\n' "$TMP_ROOT/removed-revision-worktree" >> "$staged"
  mv "$staged" "$meta"
  run_stack publish "$id" >/dev/null || fail "same-generation retry without a worktree failed"
  assert_grep "\"commit\": \"$short\"" "$manifest" \
    "same-generation retry erased the compatibility commit"
  assert_grep "\"worktreeHead\": \"$short\"" "$manifest" \
    "same-generation retry erased the worktree HEAD"
  assert_grep "\"branch\": \"$branch\"" "$manifest" \
    "same-generation retry erased the branch"
  pass "same-generation report retries preserve unavailable revision provenance"
}

test_text_sources_are_bounded_before_reading() {
  local id entry stored_brief stored_status oversized out status
  id=report-bounded-trails-a5
  write_task "$id" ship
  {
    printf '# Task\n\nBounded trail title\n\n'
    dd if=/dev/zero bs=1048576 count=5 2>/dev/null | tr '\000' 'b'
  } > "$HOME_DIR/data/$id/brief.md"
  {
    dd if=/dev/zero bs=1048576 count=5 2>/dev/null | tr '\000' 's'
    printf '\ndone: bounded status tail survives\n'
  } > "$HOME_DIR/state/$id.status"
  write_required_report "$HOME_DIR/data/$id/completion.md" "Bounded informational trails."

  run_stack publish "$id" >/dev/null || fail "bounded informational trails did not publish"
  entry=$(run_stack path "$id")
  stored_brief="$(dirname "$entry")/brief.md"
  stored_status="$(dirname "$entry")/status.log"
  assert_grep 'task brief truncated:' "$stored_brief" "oversized brief lacked a visible truncation marker"
  assert_grep 'Bounded trail title' "$stored_brief" "brief head truncation lost title extraction content"
  assert_grep 'status trail truncated:' "$stored_status" "oversized status lacked a visible truncation marker"
  assert_grep 'done: bounded status tail survives' "$stored_status" "status tail truncation lost the latest status"

  oversized=report-oversized-completion-a6
  write_task "$oversized" ship
  dd if=/dev/zero bs=1048576 count=17 2>/dev/null | tr '\000' 'r' > "$HOME_DIR/data/$oversized/completion.md"
  out=$(run_stack publish "$oversized" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "oversized load-bearing completion report was silently published"
  assert_contains "$out" "exceeds the 16777216-byte publication limit" "oversized report refusal omitted its byte limit"
  assert_contains "$out" "This attempt did not replace the durable report" "oversized report refusal omitted retry safety"
  if find "$STACK/entries" -mindepth 1 -maxdepth 1 -type d -name "$oversized-*" -print -quit | grep -q .; then
    fail "oversized load-bearing completion report created a durable entry"
  fi
  assert_grep 'Buffer.alloc(maxBytes + 1)' "$SCRIPT" \
    "bounded report readers do not reserve an overflow sentinel byte"
  assert_grep 'readDescriptorAtMost(descriptor, maxBytes' "$SCRIPT" \
    "bounded report control readers do not read through the capped descriptor helper"
  pass "report stack truncates informational trails visibly and rejects oversized completion reports"
}

test_metadata_is_bounded_before_reading() {
  local id=report-oversized-meta-a7 out status
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Metadata bounds."
  dd if=/dev/zero bs=1048576 count=2 2>/dev/null | tr '\000' 'm' >> "$HOME_DIR/state/$id.meta"
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "oversized task metadata was read and published"
  assert_contains "$out" "task metadata exceeds its 1048576-byte limit" \
    "oversized metadata refusal omitted its pre-read limit"
  pass "report stack rejects oversized metadata before reading it"
}

test_report_temps_are_exclusive_and_randomized() {
  local id=report-temp-safety-a8 outside entry report_id
  id=report-temp-safety-a8
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Exclusive report staging."
  outside="$TMP_ROOT/report-temp-sentinel"
  printf 'sentinel\n' > "$outside"
  mkdir -p "$STACK"
  (
    ln -s "$outside" "$STACK/.index.html.${BASHPID:-$$}.tmp"
    exec env FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$STACK" "$SCRIPT" publish "$id"
  ) >/dev/null || fail "legacy predictable index temp fixture blocked randomized publication"
  assert_grep 'sentinel' "$outside" "report index staging followed a planted temp symlink"
  entry=$(run_stack path "$id")
  report_id=$(basename "$(dirname "$entry")")
  (
    ln -s "$outside" "$STACK/entries/.$report_id.transaction.${BASHPID:-$$}.tmp"
    exec env FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$STACK" "$SCRIPT" publish "$id"
  ) >/dev/null || fail "legacy predictable transaction temp fixture blocked randomized publication"
  assert_grep 'sentinel' "$outside" "report transaction staging followed a planted temp symlink"
  pass "report transactions and indexes use exclusive randomized staging"
}

test_visual_inventory_is_count_and_depth_bounded() {
  local id out status current i
  id=report-visual-count-a9
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Bound visual count."
  mkdir -p "$HOME_DIR/data/$id/visuals"
  i=1
  while [ "$i" -le 512 ]; do
    : > "$HOME_DIR/data/$id/visuals/file-$i.png"
    i=$((i + 1))
  done
  out=$(run_stack publish "$id" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "oversized visual entry inventory was published"
  assert_contains "$out" "visual evidence exceeds the 512-entry limit" \
    "visual entry refusal omitted its count limit"

  id=report-visual-depth-b1
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Bound visual depth."
  current="$HOME_DIR/data/$id/visuals"
  mkdir -p "$current"
  i=1
  while [ "$i" -le 25 ]; do
    current="$current/level-$i"
    mkdir "$current"
    i=$((i + 1))
  done
  : > "$current/evidence.png"
  out=$(run_stack publish "$id" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "overdeep visual inventory was published"
  assert_contains "$out" "visual evidence exceeds the 24-level depth limit" \
    "visual depth refusal omitted its depth limit"
  pass "report visual traversal rejects excessive count and depth"
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

test_required_sections_fail_actionably() {
  local id=report-headings-b3 out status before after source heading
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  printf '# Completion\n\n## Summary\n\nIncomplete.\n\n## Artifacts\n\nNone.\n' > "$source"
  while [[ "$source" == *//* ]]; do source=${source//\/\//\/}; done
  before=$(find "$STACK/entries" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "report with missing required sections unexpectedly published"
  assert_contains "$out" "$source" "section failure omitted the exact report source"
  for heading in "## What changed" "## Verification" "## Visual evidence" "## Follow-ups"; do
    assert_contains "$out" "$heading" "section failure omitted missing heading $heading"
  done
  assert_contains "$out" "fm-report-stack.mjs publish $id" "section failure omitted the direct publication retry"
  assert_contains "$out" "fm-teardown.sh $id" "section failure omitted the teardown retry"
  assert_contains "$out" "teardown remains stopped before destructive cleanup" "section failure omitted teardown safety state"
  after=$(find "$STACK/entries" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
  [ "$before" = "$after" ] || fail "failed section validation changed the durable report stack"
  assert_present "$HOME_DIR/state/$id.meta" "failed section validation removed task state"
  pass "report stack rejects incomplete reports with a retry-safe actionable correction"
}

test_nested_short_fences_do_not_satisfy_required_sections() {
  local id source out status heading

  id=report-four-backtick-fence-b3b
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

## Summary

Incomplete.

````markdown
```
## What changed

Hidden example.

## Verification

Hidden example.

## Visual evidence

Hidden example.

## Follow-ups

Hidden example.
```
````

## Artifacts

None.
EOF
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "headings inside a four-backtick fence unexpectedly satisfied the report contract"
  for heading in "## What changed" "## Verification" "## Visual evidence" "## Follow-ups"; do
    assert_contains "$out" "$heading" "four-backtick fence failure omitted missing heading $heading"
  done

  id=report-four-tilde-fence-b3c
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

## Summary

Incomplete.

~~~~markdown
~~~
## What changed

Hidden example.

## Verification

Hidden example.

## Visual evidence

Hidden example.

## Follow-ups

Hidden example.
~~~
~~~~

## Artifacts

None.
EOF
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "headings inside a four-tilde fence unexpectedly satisfied the report contract"
  for heading in "## What changed" "## Verification" "## Visual evidence" "## Follow-ups"; do
    assert_contains "$out" "$heading" "four-tilde fence failure omitted missing heading $heading"
  done
  pass "report section validation respects the opening Markdown fence length"
}

test_raw_html_does_not_satisfy_required_sections() {
  local id=report-raw-html-b3k source out status heading
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

## Summary

Incomplete.

<!--
## What changed
-->

<div>
## Verification

Hidden.

## Visual evidence

Hidden.

## Artifacts

Hidden.

## Follow-ups

Hidden.
</div>

EOF
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "headings inside raw HTML unexpectedly satisfied the report contract"
  for heading in "## What changed" "## Verification" "## Visual evidence" "## Artifacts" "## Follow-ups"; do
    assert_contains "$out" "$heading" "raw HTML failure omitted missing heading $heading"
  done
  pass "report parsing excludes CommonMark raw HTML blocks and comments"
}

test_nested_html_containers_do_not_satisfy_required_sections() {
  local id=report-nested-html-b3l source out status heading
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

- <!--
  ## Summary
  ## What changed
  ## Verification
  ## Visual evidence
  ## Artifacts
  ## Follow-ups
  -->
EOF
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "headings inside nested raw HTML unexpectedly satisfied the report contract"
  for heading in "## Summary" "## What changed" "## Verification" "## Visual evidence" "## Artifacts" "## Follow-ups"; do
    assert_contains "$out" "$heading" "nested raw HTML failure omitted missing heading $heading"
  done
  pass "report parsing excludes raw HTML nested in Markdown containers"
}

test_indented_pseudo_closers_do_not_end_fences() {
  local id source out status heading

  for marker in backtick tilde; do
    id="report-indented-$marker-fence-b3d"
    write_task "$id" ship
    source="$HOME_DIR/data/$id/completion.md"
    if [ "$marker" = backtick ]; then
      cat > "$source" <<'EOF'
# Completion

## Summary

Incomplete.

```markdown
    ```
## What changed

Hidden.

## Verification

Hidden.

## Visual evidence

Hidden.

## Follow-ups

Hidden.
```

## Artifacts

None.
EOF
    else
      printf '# Completion\n\n## Summary\n\nIncomplete.\n\n~~~markdown\n    ~~~\n## What changed\n\nHidden.\n\n## Verification\n\nHidden.\n\n## Visual evidence\n\nHidden.\n\n## Follow-ups\n\nHidden.\n~~~\n\n## Artifacts\n\nNone.\n' > "$source"
    fi
    out=$(run_stack publish "$id" 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "four-space $marker pseudo-closer unexpectedly ended its fence"
    for heading in "## What changed" "## Verification" "## Visual evidence" "## Follow-ups"; do
      assert_contains "$out" "$heading" "$marker pseudo-closer failure omitted missing heading $heading"
    done
  done
  pass "four-space pseudo-closers remain code inside Markdown fences"
}

test_required_headings_follow_commonmark_atx_rules() {
  local id source out status

  id=report-indented-headings-b3e
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  printf '# Completion\n\n   ## Summary ###\n\nComplete.\n\n  ## What changed\n\nChanged.\n\n ## Verification ##\n\nVerified.\n\n   ## Visual evidence\t###\n\nNone.\n\n## Artifacts\n\nReport.\n\n   ## Follow-ups\n\nNone.\n' > "$source"
  run_stack publish "$id" >/dev/null || fail "valid indented ATX headings were rejected"

  id=report-unseparated-closing-hash-b3f
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  printf '# Completion\n\n## Summary###\n\nInvalid.\n\n## What changed\n\nChanged.\n\n## Verification\n\nVerified.\n\n## Visual evidence\n\nNone.\n\n## Artifacts\n\nReport.\n\n## Follow-ups\n\nNone.\n' > "$source"
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unseparated closing hashes unexpectedly satisfied the Summary section"
  assert_contains "$out" "## Summary" "invalid closing-hash failure omitted the missing Summary heading"

  id=report-four-space-heading-b3g
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  printf '# Completion\n\n    ## Summary\n\nIndented code.\n\n## What changed\n\nChanged.\n\n## Verification\n\nVerified.\n\n## Visual evidence\n\nNone.\n\n## Artifacts\n\nReport.\n\n## Follow-ups\n\nNone.\n' > "$source"
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "four-space indented code unexpectedly satisfied the Summary section"
  assert_contains "$out" "## Summary" "four-space heading failure omitted the missing Summary heading"
  pass "required headings follow CommonMark ATX indentation and closing-hash rules"
}

test_invalid_backtick_info_string_does_not_open_fence() {
  local id=report-invalid-backtick-info-b3h source
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

```language`invalid

## Summary

Complete.

## What changed

Changed.

## Verification

Verified.

## Visual evidence

None.

## Artifacts

Report.

## Follow-ups

None.
EOF
  run_stack publish "$id" >/dev/null || fail "backtick-containing info string was treated as a valid fence opener"
  pass "invalid backtick fence info strings do not hide report headings"
}

test_summary_extraction_uses_validated_markdown_structure() {
  local id=report-structured-summary-b3i source entry manifest
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

````markdown
## Summary

Fenced fake summary.
```
````

   ## Summary ###

Validated real summary.

## What changed

Changed.

## Verification

Verified.

## Visual evidence

None.

## Artifacts

Report.

## Follow-ups

None.
EOF
  run_stack publish "$id" >/dev/null || fail "structured-summary report failed to publish"
  entry=$(run_stack path "$id")
  manifest="$(dirname "$entry")/manifest.json"
  assert_grep '"summary": "Validated real summary."' "$manifest" "manifest did not use the validated real Summary section"
  assert_no_grep 'Fenced fake summary' "$manifest" "manifest summary used a fenced example"
  pass "summary extraction shares fence-aware ATX parsing"
}

test_list_container_fences_hide_report_headings_and_summaries() {
  local id=report-list-fence-b3j source out status heading
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

- ````markdown
  ## Summary

  Fenced fake summary.

  ## What changed

  Hidden.

  ## Verification

  Hidden.

  ## Visual evidence

  Hidden.

  ## Artifacts

  Hidden.

  ## Follow-ups

  Hidden.
  ```
  ````
EOF
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "headings inside a list-container fence unexpectedly satisfied the report contract"
  for heading in "## Summary" "## What changed" "## Verification" "## Visual evidence" "## Artifacts" "## Follow-ups"; do
    assert_contains "$out" "$heading" "list-container fence failure omitted missing heading $heading"
  done
  pass "report parsing ignores headings and summaries inside list-container fences"
}

test_scout_and_legacy_sources() {
  local scout=report-scout-c3 legacy=report-legacy-d4 json
  write_task "$scout" scout
  printf '# Scout report\n\n## Summary\n\nThe investigation is complete.\n\n## What changed\n\nInvestigated.\n\n## Verification\n\nEvidence checked.\n\n## Visual evidence\n\nNone.\n\n## Artifacts\n\nReport.\n\n## Follow-ups\n\nRecommendation recorded.\n' > "$HOME_DIR/data/$scout/report.md"
  run_stack publish "$scout" >/dev/null || fail "scout report publication failed"

  write_task "$legacy" ship
  grep -v '^report_required=' "$HOME_DIR/state/$legacy.meta" > "$HOME_DIR/state/$legacy.meta.precutover"
  mv "$HOME_DIR/state/$legacy.meta.precutover" "$HOME_DIR/state/$legacy.meta"
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

test_stale_lock_reclaim_is_serialized() {
  local pids="" pid failures=0
  mkdir -p "$STACK/.publish.lock"
  printf '{"pid":%s,"startedAt":"different-process-start"}\n' "$$" > "$STACK/.publish.lock/owner"
  touch -t 200001010000 "$STACK/.publish.lock"
  for i in 1 2 3 4 5 6 7 8; do
    run_stack render > "$TMP_ROOT/render-$i.out" 2>&1 &
    pids="$pids $!"
  done
  for pid in $pids; do
    wait "$pid" || failures=$((failures + 1))
  done
  [ "$failures" -eq 0 ] || fail "concurrent stale-lock reclaim lost $failures publisher(s)"
  assert_absent "$STACK/.publish.lock" "concurrent render retained the publication lock"
  if find "$STACK" -maxdepth 1 -name '.publish.lock.stale.*' | grep . >/dev/null 2>&1; then
    fail "concurrent stale-lock reclaim leaked quarantine state"
  fi
  pass "report stack serializes concurrent stale-lock reclamation"
}

test_abandoned_reclaim_marker_is_recovered() {
  mkdir -p "$STACK/.publish.lock"
  printf '{"pid":%s,"startedAt":"different-process-start"}\n' "$$" > "$STACK/.publish.lock/owner"
  printf '{"pid":%s,"startedAt":"different-process-start","token":"abandoned"}\n' "$$" > "$STACK/.publish.lock/.reclaim"
  touch -t 200001010000 "$STACK/.publish.lock" "$STACK/.publish.lock/owner" "$STACK/.publish.lock/.reclaim"
  run_stack render >/dev/null || fail "abandoned report-lock reclaim marker was not recovered"
  assert_absent "$STACK/.publish.lock" "report render retained a lock with an abandoned reclaim marker"
  pass "report stack recovers abandoned reclaim ownership by process identity and age"
}

test_abandoned_reclaim_directory_is_recovered() {
  mkdir -p "$STACK/.publish.lock/.reclaim"
  printf '{"pid":%s,"startedAt":"different-process-start"}\n' "$$" > "$STACK/.publish.lock/owner"
  printf 'residue\n' > "$STACK/.publish.lock/.reclaim/residue"
  touch -t 200001010000 "$STACK/.publish.lock" "$STACK/.publish.lock/owner" \
    "$STACK/.publish.lock/.reclaim"
  run_stack render >/dev/null || fail "abandoned report-lock reclaim directory was not recovered"
  assert_absent "$STACK/.publish.lock" "report render retained a lock with an abandoned reclaim directory"
  pass "report stack recursively cleans quarantined reclaim directories"
}

test_publish_lock_directory_symlink_fails_closed() {
  local outside out status
  outside="$TMP_ROOT/report-lock-outside"
  mkdir -p "$STACK" "$outside"
  printf 'sentinel\n' > "$outside/sentinel"
  ln -s "$outside" "$STACK/.publish.lock"

  out=$(run_stack list 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "report stack followed a symlinked publish lock directory"
  assert_contains "$out" "report lock must be a real directory" \
    "symlinked report lock refusal was not actionable"
  [ "$(cat "$outside/sentinel")" = sentinel ] || fail "report lock recovery changed outside data"
  assert_absent "$outside/.reclaim" "report lock recovery wrote through a directory symlink"
  [ -L "$STACK/.publish.lock" ] || fail "report lock recovery replaced the unsafe lock symlink"
  rm -f "$STACK/.publish.lock"
  pass "report lock recovery refuses directory symlinks before child access"
}

test_lock_control_files_are_bounded_and_nonfollowing() {
  local outside
  rm -rf "$STACK/.publish.lock"
  mkdir -p "$STACK/.publish.lock"
  outside="$TMP_ROOT/report-lock-owner-target"
  printf '{"pid":999999,"startedAt":"dead","token":"outside"}\n' > "$outside"
  ln -s "$outside" "$STACK/.publish.lock/owner"
  touch -t 200001010000 "$STACK/.publish.lock"
  touch -h -t 200001010000 "$STACK/.publish.lock/owner"
  run_stack render >/dev/null || fail "symlinked report-lock owner permanently blocked recovery"
  [ "$(cat "$outside")" = '{"pid":999999,"startedAt":"dead","token":"outside"}' ] \
    || fail "report-lock owner validation changed the symlink target"
  assert_absent "$STACK/.publish.lock" "report stack retained a lock with a symlinked owner control file"

  mkdir -p "$STACK/.publish.lock"
  dd if=/dev/zero bs=8192 count=1 2>/dev/null | tr '\0' x > "$STACK/.publish.lock/owner"
  touch -t 200001010000 "$STACK/.publish.lock" "$STACK/.publish.lock/owner"
  run_stack render >/dev/null || fail "oversized report-lock owner permanently blocked recovery"
  assert_absent "$STACK/.publish.lock" "report stack retained a lock with an oversized owner control file"
  pass "report lock control reads are bounded, nonfollowing, and recoverable"
}

test_previous_generation_is_recovered_for_readers() {
  local id=report-crash-recovery-k2 entry report_id previous json
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Crash-safe report."
  run_stack publish "$id" >/dev/null || fail "crash-recovery report failed to publish"
  entry=$(run_stack path "$id")
  report_id=$(basename "$(dirname "$entry")")
  previous="$STACK/entries/.$report_id.previous"
  mv "$STACK/entries/$report_id" "$previous"

  json=$(run_stack list --json) || fail "report list did not recover the previous generation"
  printf '%s\n' "$json" | grep -F '"taskId": "report-crash-recovery-k2"' >/dev/null \
    || fail "recovered previous generation was absent from report inventory"
  assert_present "$STACK/entries/$report_id/report.html" "reader recovery did not restore the durable report entry"
  assert_absent "$previous" "reader recovery retained the hidden previous generation"
  entry=$(run_stack path "$id") || fail "report path did not resolve after generation recovery"
  assert_present "$entry" "recovered report path is missing"
  pass "report readers recover crash-interrupted generation swaps"
}

test_replacement_transaction_recovery_restores_entry_and_index() {
  local id=report-replacement-transaction-k2b entry destination report_id previous transaction staged json
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Original transaction generation."
  run_stack publish "$id" >/dev/null || fail "replacement transaction precondition failed"
  entry=$(run_stack path "$id")
  destination=$(dirname "$entry")
  report_id=$(basename "$destination")
  previous="$STACK/entries/.$report_id.previous"
  transaction="$STACK/entries/.$report_id.transaction"
  staged="$STACK/entries/.$report_id.999.tmp"
  mv "$destination" "$previous"
  cp -R "$previous" "$destination"
  sed -i.bak 's/Original transaction generation/Unindexed replacement generation/' "$destination/report.md"
  rm -f "$destination/report.md.bak"
  mkdir -p "$staged"
  printf 'stale index\n' > "$STACK/index.html"
  printf '{"schemaVersion":1,"reportId":"%s","hadPrevious":true}\n' "$report_id" > "$transaction"

  json=$(run_stack list --json) || fail "report list did not recover an interrupted replacement transaction"
  printf '%s\n' "$json" | grep -F '"taskId": "report-replacement-transaction-k2b"' >/dev/null \
    || fail "replacement recovery omitted the restored report"
  assert_grep 'Original transaction generation' "$destination/report.md" "replacement recovery did not restore the prior report"
  assert_no_grep 'Unindexed replacement generation' "$destination/report.md" "replacement recovery retained the unindexed generation"
  assert_no_grep 'stale index' "$STACK/index.html" "replacement recovery did not rebuild the report index"
  assert_absent "$previous" "replacement recovery retained the rollback generation"
  assert_absent "$transaction" "replacement recovery retained its transaction marker"
  assert_absent "$staged" "replacement recovery retained transaction staging"
  pass "report recovery rolls back replacement entries and their stale index"
}

test_first_publication_transaction_recovery_removes_unindexed_entry() {
  local id=report-first-transaction-k2c entry destination report_id transaction json
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Uncommitted first publication."
  run_stack publish "$id" >/dev/null || fail "first-publication transaction precondition failed"
  entry=$(run_stack path "$id")
  destination=$(dirname "$entry")
  report_id=$(basename "$destination")
  transaction="$STACK/entries/.$report_id.transaction"
  printf 'stale index\n' > "$STACK/index.html"
  printf '{"schemaVersion":1,"reportId":"%s","hadPrevious":false}\n' "$report_id" > "$transaction"

  json=$(run_stack list --json) || fail "report list did not recover an interrupted first publication"
  if printf '%s\n' "$json" | grep -F '"taskId": "report-first-transaction-k2c"' >/dev/null; then
    fail "first-publication recovery retained an uncommitted report"
  fi
  assert_absent "$destination" "first-publication recovery retained the unindexed entry"
  assert_absent "$transaction" "first-publication recovery retained its transaction marker"
  assert_present "$STACK/index.html" "first-publication recovery did not rebuild the report index"
  assert_no_grep 'stale index' "$STACK/index.html" "first-publication recovery retained the stale index"
  pass "report recovery removes interrupted first publications and rebuilds the index"
}

test_aged_transactionless_staging_is_reclaimed() {
  local old fresh
  mkdir -p "$STACK/entries"
  old="$STACK/entries/.orphan-report.999.tmp"
  fresh="$STACK/entries/.active-looking-report.1000.tmp"
  mkdir -p "$old/visuals" "$fresh"
  printf 'orphaned visual\n' > "$old/visuals/evidence.txt"
  touch -t 200001010000 "$old"

  run_stack render >/dev/null || fail "report stack could not recover transactionless staging"
  assert_absent "$old" "aged transactionless report staging was not reclaimed"
  assert_present "$fresh" "fresh transactionless staging was reclaimed before the conservative age threshold"
  pass "report recovery reclaims only aged transactionless staging while locked"
}

test_completed_reports_have_a_thirty_day_retention_ceiling() {
  local old_id=report-retention-old-k2d fresh_id=report-retention-fresh-k2e old_entry fresh_entry manifest temp active
  write_task "$old_id" ship
  write_required_report "$HOME_DIR/data/$old_id/completion.md" "Expired report content."
  run_stack publish "$old_id" >/dev/null || fail "expired retention precondition publication failed"
  old_entry=$(run_stack path "$old_id") || fail "expired retention precondition path failed"
  write_task "$fresh_id" ship
  write_required_report "$HOME_DIR/data/$fresh_id/completion.md" "Fresh report content."
  run_stack publish "$fresh_id" >/dev/null || fail "fresh retention precondition publication failed"
  fresh_entry=$(run_stack path "$fresh_id") || fail "fresh retention precondition path failed"
  manifest="$(dirname "$old_entry")/manifest.json"
  temp="$manifest.tmp"
  sed 's/"completedAt": "[^"]*"/"completedAt": "2000-01-01T00:00:00.000Z"/' "$manifest" > "$temp"
  mv "$temp" "$manifest"
  active="$STACK/entries/.active-retention.999.tmp"
  mkdir -p "$active"
  printf 'active staging bytes\n' > "$active/pending.txt"

  run_stack render >/dev/null || fail "report retention sweep failed"
  assert_absent "$(dirname "$old_entry")" "expired completed report entry was not pruned"
  assert_present "$fresh_entry" "fresh completed report was pruned"
  assert_present "$active/pending.txt" "fresh report staging was pruned as completed history"
  assert_no_grep 'Expired report content' "$STACK/index.html" "report index retained an expired completed entry"
  assert_grep 'Fresh report content' "$STACK/index.html" "report index lost the fresh completed entry"
  pass "report stack prunes completed entries at the 30-day ceiling"
}

test_retention_restores_expired_entries_when_index_swap_fails() {
  local id=report-retention-rollback-k2f entry manifest temp out status previous
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Retention rollback content."
  run_stack publish "$id" >/dev/null || fail "retention rollback precondition publication failed"
  entry=$(run_stack path "$id") || fail "retention rollback precondition path failed"
  manifest="$(dirname "$entry")/manifest.json"
  temp="$manifest.tmp"
  sed 's/"completedAt": "[^"]*"/"completedAt": "2000-01-01T00:00:00.000Z"/' "$manifest" > "$temp"
  mv "$temp" "$manifest"
  rm -f "$STACK/index.html"
  mkdir "$STACK/index.html"
  if out=$(run_stack render 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "retention unexpectedly replaced an unsafe report index destination"
  assert_present "$entry" "failed retention index swap did not restore the expired entry"
  previous="$STACK/entries/.$(basename "$(dirname "$entry")").previous"
  assert_absent "$previous" "failed retention index swap retained a rollback generation"
  [ -n "$out" ] || true
  pass "report retention rolls back entry pruning when index publication fails"
}

test_index_failure_restores_previous_generation() {
  local id=report-index-rollback-k3 entry out status
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Original generation."
  run_stack publish "$id" >/dev/null || fail "index rollback precondition failed"
  entry=$(run_stack path "$id")
  mkdir -p "$STACK/entries/invalid-manifest"
  printf '{invalid\n' > "$STACK/entries/invalid-manifest/manifest.json"
  write_required_report "$HOME_DIR/data/$id/completion.md" "Replacement generation."

  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "publication unexpectedly succeeded with an unreadable index manifest"
  assert_grep 'Original generation' "$(dirname "$entry")/report.md" "failed index rendering did not restore the previous report generation"
  if grep -F 'Replacement generation' "$(dirname "$entry")/report.md" >/dev/null 2>&1; then
    fail "failed index rendering retained the unindexed replacement generation"
  fi
  rm -rf "$STACK/entries/invalid-manifest"
  [ -n "$out" ] || true
  pass "report publication restores the previous generation when index rendering fails"
}

test_readers_wait_for_publication_lock() {
  local started reader
  mkdir -p "$STACK/.publish.lock"
  started=$(LC_ALL=C ps -p "$$" -o lstart= | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]][[:space:]]*/ /g')
  printf '{"pid":%s,"startedAt":"%s"}\n' "$$" "$started" > "$STACK/.publish.lock/owner"
  run_stack list --json > "$TMP_ROOT/locked-reader.out" 2> "$TMP_ROOT/locked-reader.err" &
  reader=$!
  sleep 0.2
  kill -0 "$reader" 2>/dev/null || fail "report reader bypassed the publication lock"
  rm -rf "$STACK/.publish.lock"
  wait "$reader" || fail "report reader failed after the publication lock was released"
  pass "report readers hold the publication lock while resolving entries"
}

test_source_symlinks_fail_closed() {
  local id out status outside
  outside="$TMP_ROOT/outside-artifact"
  printf 'outside artifact\n' > "$outside"

  id=report-source-symlink-f6
  write_task "$id" ship
  rm -f "$HOME_DIR/data/$id/completion.md"
  ln -s "$outside" "$HOME_DIR/data/$id/completion.md"
  out=$(run_stack publish "$id" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "symlinked completion report unexpectedly published"
  assert_contains "$out" "completion report must be a real regular file" "completion symlink refusal was not actionable"

  id=report-brief-symlink-g7
  write_task "$id" ship
  printf '# Completion\n\n## Summary\n\nSafe source.\n' > "$HOME_DIR/data/$id/completion.md"
  rm -f "$HOME_DIR/data/$id/brief.md"
  ln -s "$outside" "$HOME_DIR/data/$id/brief.md"
  out=$(run_stack publish "$id" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "symlinked task brief unexpectedly published"
  assert_contains "$out" "task brief must be a real regular file" "brief symlink refusal was not actionable"

  id=report-status-symlink-h8
  write_task "$id" ship
  printf '# Completion\n\n## Summary\n\nSafe source.\n' > "$HOME_DIR/data/$id/completion.md"
  rm -f "$HOME_DIR/state/$id.status"
  ln -s "$outside" "$HOME_DIR/state/$id.status"
  out=$(run_stack publish "$id" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "symlinked status trail unexpectedly published"
  assert_contains "$out" "status trail must be a real regular file" "status symlink refusal was not actionable"

  id=report-data-symlink-i9
  fm_write_meta "$HOME_DIR/state/$id.meta" "kind=ship" "report_required=1"
  mkdir -p "$TMP_ROOT/outside-task"
  printf '# Task\n\nOutside task.\n' > "$TMP_ROOT/outside-task/brief.md"
  printf '# Completion\n\n## Summary\n\nOutside source.\n' > "$TMP_ROOT/outside-task/completion.md"
  ln -s "$TMP_ROOT/outside-task" "$HOME_DIR/data/$id"
  out=$(run_stack publish "$id" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "symlinked task-data directory unexpectedly published"
  assert_contains "$out" "task data directory must be a real directory" "task-data symlink refusal was not actionable"

  if grep -R -F 'outside artifact' "$STACK" >/dev/null 2>&1; then
    fail "symlinked source content escaped into the report stack"
  fi
  assert_grep 'fs.openSync(file, flags)' "$SCRIPT" \
    "report text sources are not opened through their original non-following path"
  assert_grep 'stat.dev !== initial.dev || stat.ino !== initial.ino' "$SCRIPT" \
    "report text sources are not identity-bound after opening"
  pass "report stack rejects symlinked report source artifacts"
}

test_ambiguous_task_ids_require_report_ids() {
  local id=report-shared-j1 other_home out status ids first second exact
  other_home="$TMP_ROOT/other-home"
  mkdir -p "$other_home/state" "$other_home/data/$id"

  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "First home."
  run_stack publish "$id" >/dev/null || fail "first duplicate-id report failed to publish"

  fm_write_meta "$other_home/state/$id.meta" "kind=ship" "report_required=1" "project=other"
  printf '# Task\n\nSecond home task.\n' > "$other_home/data/$id/brief.md"
  printf 'done: second home\n' > "$other_home/state/$id.status"
  write_required_report "$other_home/data/$id/completion.md" "Second home."
  run_stack_home "$other_home" publish "$id" >/dev/null || fail "second duplicate-id report failed to publish"

  ids=$(run_stack list --json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).filter(r=>r.taskId===process.argv[1]).map(r=>r.reportId).join("\n")))' "$id")
  first=$(printf '%s\n' "$ids" | sed -n '1p')
  second=$(printf '%s\n' "$ids" | sed -n '2p')
  [ -n "$first" ] && [ -n "$second" ] || fail "duplicate task ids did not produce two report ids"

  out=$(run_stack path "$id" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "ambiguous bare task id unexpectedly resolved"
  assert_contains "$out" "is ambiguous" "ambiguous task-id lookup was not actionable"
  assert_contains "$out" "$first" "ambiguous task-id lookup omitted the first report id"
  assert_contains "$out" "$second" "ambiguous task-id lookup omitted the second report id"
  exact=$(run_stack path "$first") || fail "exact report-id lookup failed"
  assert_contains "$exact" "/$first/report.html" "exact report-id lookup selected the wrong entry"
  pass "report stack requires report ids for ambiguous cross-home task ids"
}

test_visual_symlink_fails_closed_and_cleans_staging() {
  local id=report-symlink-e5 out status staged
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Symlink safety."
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

test_visual_copy_is_descriptor_bounded() {
  local id=report-visual-bound-f6 out status source
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Bound visual copy."
  mkdir -p "$HOME_DIR/data/$id/visuals"
  source="$HOME_DIR/data/$id/visuals/oversized.png"
  dd if=/dev/zero of="$source" bs=1048576 count=20 2>/dev/null
  printf x >> "$source"
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "oversized visual was copied into the report stack"
  assert_contains "$out" "visual evidence exceeds the 20 MiB report limit" \
    "oversized visual refusal omitted its byte limit"
  assert_no_grep 'copyFileSync' "$SCRIPT" "visual publication still reopens sources with copyFileSync"
  assert_grep 'snapshot-task-fd' "$SCRIPT" "visual publication does not use the descriptor-relative snapshot helper"
  assert_grep 'dir_fd=' "$ROOT/bin/fm-contained-read.py" "visual publication does not traverse through directory descriptors"
  assert_grep 'os.O_NOFOLLOW' "$ROOT/bin/fm-contained-read.py" "visual publication does not use non-following descriptor opens"
  pass "report visual copies are descriptor-bound and byte-capped"
}

test_visual_containment_precedes_ancestor_swap() {
  local id=report-visual-race-f7 out status parent moved outside source hook marker entry tmp_real
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Stable visual containment."
  parent="$HOME_DIR/data/$id/visuals/nested"
  moved="$TMP_ROOT/pinned-visual-parent"
  outside="$TMP_ROOT/outside-visual-parent"
  source="$parent/evidence.png"
  hook="$TMP_ROOT/visual-swap-hook"
  marker="$TMP_ROOT/visual-swap-marker"
  mkdir -p "$parent" "$outside" "$hook"
  tmp_real=$(cd "$TMP_ROOT" && pwd -P)
  parent=$(cd "$parent" && pwd -P)
  outside=$(cd "$outside" && pwd -P)
  moved="$tmp_real/pinned-visual-parent"
  source="$parent/evidence.png"
  printf 'inside visual bytes\n' > "$source"
  printf 'outside private visual bytes\n' > "$outside/evidence.png"
  cat > "$hook/sitecustomize.py" <<'PY'
import os

original_open = os.open
swapped = False


def guarded_open(file, flags, mode=0o777, *, dir_fd=None):
    global swapped
    if not swapped and dir_fd is not None and file == "evidence.png" and not flags & os.O_WRONLY:
        swapped = True
        os.rename(os.environ["FM_REPORT_VISUAL_SWAP_PARENT"], os.environ["FM_REPORT_VISUAL_SWAP_MOVED"])
        os.rename(os.environ["FM_REPORT_VISUAL_SWAP_OUTSIDE"], os.environ["FM_REPORT_VISUAL_SWAP_PARENT"])
        try:
            descriptor = original_open(file, flags, mode, dir_fd=dir_fd)
        finally:
            os.rename(os.environ["FM_REPORT_VISUAL_SWAP_PARENT"], os.environ["FM_REPORT_VISUAL_SWAP_OUTSIDE"])
            os.rename(os.environ["FM_REPORT_VISUAL_SWAP_MOVED"], os.environ["FM_REPORT_VISUAL_SWAP_PARENT"])
            with open(os.environ["FM_REPORT_VISUAL_SWAP_MARKER"], "w", encoding="utf-8") as marker:
                marker.write("swapped\n")
        return descriptor
    return original_open(file, flags, mode, dir_fd=dir_fd)


os.open = guarded_open
PY
  if out=$(PYTHONPATH="$hook" \
    FM_REPORT_VISUAL_SWAP_PARENT="$parent" \
    FM_REPORT_VISUAL_SWAP_MOVED="$moved" \
    FM_REPORT_VISUAL_SWAP_OUTSIDE="$outside" \
    FM_REPORT_VISUAL_SWAP_MARKER="$marker" \
    run_stack publish "$id" 2>&1); then status=0; else status=$?; fi
  [ "$status" -eq 0 ] || fail "descriptor-relative visual publication failed during a restored ancestor swap: $out"
  assert_present "$marker" "visual ancestor-swap hook did not run"
  entry=$(run_stack path "$id") || fail "descriptor-relative visual report could not be resolved"
  assert_grep 'inside visual bytes' "$(dirname "$entry")/visuals/nested/evidence.png" \
    "visual publication lost the file beneath its pinned directory"
  if grep -R -F 'outside private visual bytes' "$STACK" >/dev/null 2>&1; then
    fail "ancestor-swapped outside visual escaped into the report stack"
  fi
  pass "report visual traversal remains anchored across ancestor swaps"
}

test_task_directory_identity_is_pinned_for_all_artifacts() {
  local id=report-task-root-race-f8 out status parent moved outside hook marker entry
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Inside task report."
  parent=$(cd "$HOME_DIR/data/$id" && pwd -P)
  moved="$TMP_ROOT/pinned-task-root"
  outside="$TMP_ROOT/outside-task-root"
  hook="$TMP_ROOT/task-root-swap-hook"
  marker="$TMP_ROOT/task-root-swapped"
  mkdir -p "$parent/visuals" "$outside/visuals" "$hook"
  printf 'inside pinned visual bytes\n' > "$parent/visuals/evidence.png"
  printf '# Task\n\nOutside private task\n' > "$outside/brief.md"
  write_required_report "$outside/completion.md" "Outside private report."
  printf 'outside private visual bytes\n' > "$outside/visuals/evidence.png"
  cat > "$hook/sitecustomize.py" <<'PY'
import os

original_open = os.open
swapped = False


def guarded_open(file, flags, mode=0o777, *, dir_fd=None):
    global swapped
    if not swapped and dir_fd is not None and file == "brief.md":
        swapped = True
        os.rename(os.environ["FM_REPORT_TASK_SWAP_PARENT"], os.environ["FM_REPORT_TASK_SWAP_MOVED"])
        os.rename(os.environ["FM_REPORT_TASK_SWAP_OUTSIDE"], os.environ["FM_REPORT_TASK_SWAP_PARENT"])
        try:
            descriptor = original_open(file, flags, mode, dir_fd=dir_fd)
        finally:
            os.rename(os.environ["FM_REPORT_TASK_SWAP_PARENT"], os.environ["FM_REPORT_TASK_SWAP_OUTSIDE"])
            os.rename(os.environ["FM_REPORT_TASK_SWAP_MOVED"], os.environ["FM_REPORT_TASK_SWAP_PARENT"])
            with open(os.environ["FM_REPORT_TASK_SWAP_MARKER"], "w", encoding="utf-8") as marker:
                marker.write("swapped\n")
        return descriptor
    return original_open(file, flags, mode, dir_fd=dir_fd)


os.open = guarded_open
PY
  if out=$(PYTHONPATH="$hook" FM_REPORT_TASK_SWAP_PARENT="$parent" \
    FM_REPORT_TASK_SWAP_MOVED="$moved" FM_REPORT_TASK_SWAP_OUTSIDE="$outside" \
    FM_REPORT_TASK_SWAP_MARKER="$marker" run_stack publish "$id" 2>&1); then status=0; else status=$?; fi
  [ "$status" -eq 0 ] || fail "descriptor-relative task publication failed during a restored ancestor swap: $out"
  assert_present "$marker" "task-directory swap hook did not run: $out"
  entry=$(run_stack path "$id") || fail "descriptor-relative task report could not be resolved"
  assert_grep 'Inside task report' "$(dirname "$entry")/report.md" "task report did not come from the pinned task directory"
  assert_grep 'inside pinned visual bytes' "$(dirname "$entry")/visuals/evidence.png" "task visual did not come from the pinned task directory"
  if grep -R -E 'Outside private (task|report)|outside private visual bytes' "$STACK" >/dev/null 2>&1; then
    fail "sibling task artifacts escaped into the report stack"
  fi
  pass "report publication traverses every artifact through one pinned task directory"
}

if [ "${FM_TEST_FOCUSED:-}" = review-round-10 ]; then
  test_stale_lock_rejects_reused_pid
  test_stale_lock_reclaim_is_serialized
  test_abandoned_reclaim_marker_is_recovered
  test_publish_lock_directory_symlink_fails_closed
  test_lock_control_files_are_bounded_and_nonfollowing
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-12 ]; then
  test_pr_url_strips_query_and_fragment
  test_abandoned_reclaim_directory_is_recovered
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-13 ]; then
  test_visual_copy_is_descriptor_bounded
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-14 ]; then
  test_text_sources_are_bounded_before_reading
  test_source_symlinks_fail_closed
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-15 ]; then
  test_same_generation_republish_preserves_revision_without_worktree
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-19 ]; then
  test_visual_containment_precedes_ancestor_swap
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-20 ]; then
  test_raw_html_does_not_satisfy_required_sections
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-21 ]; then
  test_nested_html_containers_do_not_satisfy_required_sections
  test_task_directory_identity_is_pinned_for_all_artifacts
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-22 ]; then
  test_task_directory_identity_is_pinned_for_all_artifacts
  test_completed_reports_have_a_thirty_day_retention_ceiling
  test_retention_restores_expired_entries_when_index_swap_fails
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = report-fence-enforcement ]; then
  test_required_sections_fail_actionably
  test_nested_short_fences_do_not_satisfy_required_sections
  test_indented_pseudo_closers_do_not_end_fences
  test_required_headings_follow_commonmark_atx_rules
  test_invalid_backtick_info_string_does_not_open_fence
  test_summary_extraction_uses_validated_markdown_structure
  test_list_container_fences_hide_report_headings_and_summaries
  exit 0
fi

test_publish_ship_with_visual
test_report_links_reject_credentials_and_encode_visual_paths
test_pr_url_strips_query_and_fragment
test_revision_fields_distinguish_pr_head_from_worktree_head
test_republish_new_generation_refreshes_completion_time
test_same_generation_republish_preserves_revision_without_worktree
test_text_sources_are_bounded_before_reading
test_metadata_is_bounded_before_reading
test_report_temps_are_exclusive_and_randomized
test_visual_inventory_is_count_and_depth_bounded
test_required_source_fails_closed
test_required_sections_fail_actionably
test_nested_short_fences_do_not_satisfy_required_sections
test_raw_html_does_not_satisfy_required_sections
test_indented_pseudo_closers_do_not_end_fences
test_required_headings_follow_commonmark_atx_rules
test_invalid_backtick_info_string_does_not_open_fence
test_summary_extraction_uses_validated_markdown_structure
test_list_container_fences_hide_report_headings_and_summaries
test_scout_and_legacy_sources
test_stale_lock_rejects_reused_pid
test_stale_lock_reclaim_is_serialized
test_abandoned_reclaim_marker_is_recovered
test_abandoned_reclaim_directory_is_recovered
test_publish_lock_directory_symlink_fails_closed
test_lock_control_files_are_bounded_and_nonfollowing
test_previous_generation_is_recovered_for_readers
test_replacement_transaction_recovery_restores_entry_and_index
test_first_publication_transaction_recovery_removes_unindexed_entry
test_aged_transactionless_staging_is_reclaimed
test_index_failure_restores_previous_generation
test_readers_wait_for_publication_lock
test_visual_symlink_fails_closed_and_cleans_staging
test_visual_copy_is_descriptor_bounded
test_visual_containment_precedes_ancestor_swap
test_source_symlinks_fail_closed
test_ambiguous_task_ids_require_report_ids
