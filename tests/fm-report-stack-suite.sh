#!/usr/bin/env bash
# Behavior tests for the machine-global Firstmate completion report stack.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot_into TMP_ROOT fm-report-stack
HOME_DIR="$TMP_ROOT/home"
STACK="$TMP_ROOT/stack"
SCRIPT=${FM_REPORT_STACK_SCRIPT_OVERRIDE:-$ROOT/bin/fm-report-stack.mjs}
RETENTION_ADMISSION_DIR="$TMP_ROOT/retention-admission"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$RETENTION_ADMISSION_DIR"
export FM_REPORT_RETENTION_ADMISSION_DIR="$RETENTION_ADMISSION_DIR"
export FM_REPORT_RETENTION_INSTALL_TEST_SIMULATE_LAUNCH=1
export FM_REPORT_RETENTION_ACTIVATION_WAIT_MS=250

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

expire_report_entry() {  # <report.html> [completed-at] -> updated report.html
  local entry=$1 completed_at=${2:-2000-01-01T00:00:00.000Z}
  local report_dir report_id cohort manifest destination
  report_dir=$(dirname "$entry")
  report_id=$(basename "$report_dir")
  # shellcheck disable=SC2016
  cohort=$(node -e '
    const timestamp = Date.parse(process.argv[1]);
    const retention = 30 * 24 * 60 * 60 * 1000;
    const width = Number(process.argv[2]);
    process.stdout.write(`cohort-${Math.ceil((timestamp + retention) / width) * width}`);
  ' "$completed_at" "${FM_REPORT_RETENTION_COHORT_MS:-300000}") || return 1
  manifest="$report_dir/manifest.json"
  node - "$manifest" "$completed_at" "$cohort" <<'NODE'
const fs = require("fs");
const [file, completedAt, retentionCohort] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(file, "utf8"));
value.completedAt = completedAt;
value.retentionCohort = retentionCohort;
fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
NODE
  destination="$STACK/entries/$cohort/$report_id"
  mkdir -p "$STACK/entries/$cohort"
  if [ "$report_dir" != "$destination" ]; then
    [ ! -e "$destination" ] || fail "expired report destination already exists: $destination"
    mv "$report_dir" "$destination"
  fi
  printf '%s/report.html\n' "$destination"
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
  cmp -s "$HOME_DIR/data/$id/completion.md" "$(dirname "$entry")/report.md" \
    || fail "published report markdown did not preserve its source bytes"
  cmp -s "$HOME_DIR/data/$id/brief.md" "$(dirname "$entry")/brief.md" \
    || fail "published task brief did not preserve its source bytes"
  cmp -s "$HOME_DIR/state/$id.status" "$(dirname "$entry")/status.log" \
    || fail "published status trail did not preserve its source bytes"

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

test_report_artifacts_remain_verbatim_across_key_shaped_content() {
  local id=report-verbatim-key-a1b source entry
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

## Summary

-----BEGIN PRIVATE KEY-----
Preserve this trusted internal artifact exactly.

## What changed

Recorded work.

## Verification

Evidence checked.

## Visual evidence

None.

## Artifacts

Report.

## Follow-ups

None.
-----END PRIVATE KEY-----
EOF
  run_stack publish "$id" >/dev/null || fail "key-shaped report artifact failed publication"
  entry=$(run_stack path "$id") || fail "key-shaped report artifact path failed"
  cmp -s "$source" "$(dirname "$entry")/report.md" \
    || fail "key-shaped report artifact was inspected or transformed"
  pass "report stack preserves trusted internal artifact bytes verbatim"
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

test_legacy_cutover_preserves_fresh_reports_and_retires_expired_raw_paths() {
  local stack="$TMP_ROOT/legacy-cutover-stack" ready="$TMP_ROOT/legacy-cutover.ready"
  local proceed="$TMP_ROOT/legacy-cutover.proceed" output="$TMP_ROOT/legacy-cutover.out" pid status fresh_path
  mkdir -p "$stack/entries/legacy-fresh" "$stack/entries/legacy-fresh-two" \
    "$stack/entries/legacy-expired" "$stack/entries/.legacy-old.expired"
  printf '{"schemaVersion":1,"reportId":"legacy-fresh","taskId":"legacy-fresh","title":"Fresh","summary":"Fresh","completedAt":"2026-07-15T00:00:00.000Z","kind":"ship","project":"example","harness":"codex"}\n' \
    > "$stack/entries/legacy-fresh/manifest.json"
  printf 'fresh bytes\n' > "$stack/entries/legacy-fresh/report.md"
  printf '<script src="../../.retention-policy.js"></script><a href="../../index.html">stack</a>\n' \
    > "$stack/entries/legacy-fresh/report.html"
  printf '{"schemaVersion":1,"reportId":"legacy-fresh-two","taskId":"legacy-fresh-two","title":"Fresh two","summary":"Fresh two","completedAt":"2026-07-15T00:01:00.000Z","kind":"ship","project":"example","harness":"codex"}\n' \
    > "$stack/entries/legacy-fresh-two/manifest.json"
  printf 'second fresh bytes\n' > "$stack/entries/legacy-fresh-two/report.md"
  printf '{"schemaVersion":1,"reportId":"legacy-expired","taskId":"legacy-expired","title":"Expired","summary":"Expired","completedAt":"2000-01-01T00:00:00.000Z","kind":"ship","project":"example","harness":"codex"}\n' \
    > "$stack/entries/legacy-expired/manifest.json"
  printf 'expired bytes\n' > "$stack/entries/legacy-expired/report.md"
  printf 'old tombstone bytes\n' > "$stack/entries/.legacy-old.expired/report.md"
  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" FM_REPORT_RETENTION_BATCH=1 \
    FM_REPORT_LEGACY_CUTOVER_TEST_READY="$ready" FM_REPORT_LEGACY_CUTOVER_TEST_PROCEED="$proceed" \
    "$SCRIPT" render > "$output" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.02; done
  [ -e "$ready" ] || { kill -TERM "$pid" 2>/dev/null || true; fail "legacy cutover preparation gate did not open"; }
  assert_grep 'fresh bytes' "$stack/entries/legacy-fresh/report.md" \
    "bounded legacy migration hid an unstaged fresh report"
  assert_grep 'second fresh bytes' "$stack/entries/legacy-fresh-two/report.md" \
    "bounded legacy migration hid a pending fresh report"
  assert_absent "$stack/entries/legacy-expired" \
    "legacy cutover left expired raw bytes visible during fresh restoration"
  touch "$proceed"
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "bounded legacy report migration did not surface its pending state"
  assert_grep 'legacy report migration is pending' "$output" \
    "bounded legacy report migration failed without an explicit pending state"
  assert_present "$stack/.legacy-cutover.json" "bounded legacy migration lost its pending marker"
  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" FM_REPORT_RETENTION_BATCH=1 \
    "$SCRIPT" render >/dev/null || fail "legacy report cutover did not finish its pending migration"
  assert_absent "$stack/entries/legacy-fresh" "legacy flat fresh path survived cohort cutover"
  assert_absent "$stack/entries/legacy-expired" "expired legacy raw path survived cohort cutover"
  assert_absent "$stack/entries/legacy-fresh-two" "second legacy flat fresh path survived cohort cutover"
  fresh_path=$(FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" "$SCRIPT" path legacy-fresh) \
    || fail "fresh legacy report was unavailable after atomic cutover"
  assert_grep 'fresh bytes' "$(dirname "$fresh_path")/report.md" \
    "cohort cutover changed fresh legacy artifact bytes"
  assert_grep 'src="../../../.retention-policy.js"' "$fresh_path" \
    "cohort cutover did not rebase the migrated retention-policy link"
  assert_grep 'href="../../../index.html"' "$fresh_path" \
    "cohort cutover did not rebase the migrated stack-navigation link"
  assert_no_grep 'src="../../.retention-policy.js"' "$fresh_path" \
    "cohort cutover retained the flat-entry retention-policy link"
  fresh_path=$(FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" "$SCRIPT" path legacy-fresh-two) \
    || fail "second fresh legacy report was unavailable after atomic cutover"
  assert_grep 'second fresh bytes' "$(dirname "$fresh_path")/report.md" \
    "cohort cutover changed second fresh legacy artifact bytes"
  assert_absent "$stack/entries/.legacy-old.expired" \
    "legacy expired tombstone remained in the public report namespace"
  assert_absent "$stack/.legacy-cutover.json" "completed legacy cutover retained its transaction marker"
  pass "legacy cutover keeps pending fresh reports visible and retires expired raw paths"
}

test_retention_owner_advances_pending_legacy_migration() {
  local stack="$TMP_ROOT/legacy-owner-stack" id completed
  mkdir -p "$stack/entries"
  completed=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
  for id in legacy-owner-one legacy-owner-two legacy-owner-three; do
    mkdir "$stack/entries/$id"
    printf '{"schemaVersion":1,"reportId":"%s","taskId":"%s","title":"Fresh","summary":"Fresh","completedAt":"%s","kind":"ship","project":"example","harness":"codex"}\n' \
      "$id" "$id" "$completed" > "$stack/entries/$id/manifest.json"
    printf '%s bytes\n' "$id" > "$stack/entries/$id/report.md"
  done
  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" FM_REPORT_RETENTION_BATCH=1 \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_NODE="$(command -v node)" \
    "$ROOT/bin/fm-report-retention.sh" run-once >/dev/null \
    || fail "retention owner did not continue bounded legacy migration"
  assert_absent "$stack/.legacy-cutover.json" "retention owner left bounded legacy migration pending"
  for id in legacy-owner-one legacy-owner-two legacy-owner-three; do
    FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" "$SCRIPT" path "$id" >/dev/null \
      || fail "retention owner lost $id while advancing legacy migration"
  done
  pass "retention owner automatically advances bounded legacy migration"
}

test_manifest_cohort_must_match_completion_time() {
  local stack="$TMP_ROOT/manifest-cohort-stack" cohort=cohort-4102444800000 out status
  mkdir -p "$stack/entries/$cohort/cohort-mismatch"
  printf '{"schemaVersion":1,"reportId":"cohort-mismatch","taskId":"cohort-mismatch","title":"Mismatch","summary":"Mismatch","completedAt":"2000-01-01T00:00:00.000Z","retentionCohort":"%s","kind":"ship","project":"example","harness":"codex"}\n' "$cohort" \
    > "$stack/entries/$cohort/cohort-mismatch/manifest.json"
  if out=$(FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" "$SCRIPT" render 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "manifest cohort metadata was accepted despite a mismatched completion time"
  assert_contains "$out" "manifest identity mismatch" "manifest cohort-time mismatch failed unclearly"
  pass "report manifests bind cohort metadata to completion time"
}

test_manifest_cohort_deadline_cannot_precede_expiry() {
  local stack="$TMP_ROOT/manifest-early-cohort-stack" completed cohort out status
  completed=$(node -e 'process.stdout.write(new Date().toISOString())')
  cohort=$(node -e '
    const deadline = Math.ceil((Date.parse(process.argv[1]) + 15 * 24 * 60 * 60 * 1000) / 300000) * 300000;
    process.stdout.write("cohort-" + deadline);
  ' "$completed") || fail "early cohort-deadline fixture could not be computed"
  mkdir -p "$stack/entries/$cohort/early-cohort"
  printf '{"schemaVersion":1,"reportId":"early-cohort","taskId":"early-cohort","title":"Early","summary":"Early","completedAt":"%s","retentionCohort":"%s","kind":"ship","project":"example","harness":"codex"}\n' \
    "$completed" "$cohort" > "$stack/entries/$cohort/early-cohort/manifest.json"
  if out=$(FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" "$SCRIPT" render 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "manifest cohort deadline preceding the 30-day expiry was accepted"
  assert_contains "$out" "manifest identity mismatch" "early cohort-deadline refusal was unclear"
  pass "report manifests reject cohort deadlines that precede the 30-day expiry"
}

test_manifest_validation_is_cohort_width_independent() {
  local id=report-cohort-width-shift-z37a entry json
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Width-shift stable report."
  run_stack publish "$id" >/dev/null || fail "cohort width-shift publication failed"
  entry=$(run_stack path "$id") || fail "cohort width-shift path failed"
  json=$(FM_REPORT_RETENTION_COHORT_MS=3600000 run_stack list --json) \
    || fail "report list rejected existing entries after a cohort width change"
  printf '%s\n' "$json" | grep -F "\"taskId\": \"$id\"" >/dev/null \
    || fail "cohort width change hid an existing report entry"
  FM_REPORT_RETENTION_COHORT_MS=1295000000 run_stack render >/dev/null \
    || fail "report render rejected existing entries after a cohort width change"
  assert_present "$entry" "cohort width change displaced an existing report entry"
  pass "report manifest validation is independent of the retention cohort width"
}

test_retention_cohort_never_precedes_exact_expiry() {
  local id=report-cohort-ceiling-z36a entry manifest completed cohort deadline expiry
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Cohort deadline alignment."
  run_stack publish "$id" >/dev/null || fail "cohort ceiling publication failed"
  entry=$(run_stack path "$id") || fail "cohort ceiling path failed"
  manifest="$(dirname "$entry")/manifest.json"
  completed=$(jq -r '.completedAt' "$manifest")
  cohort=$(jq -r '.retentionCohort' "$manifest")
  deadline=${cohort#cohort-}
  expiry=$(node -e 'process.stdout.write(String(Date.parse(process.argv[1]) + 30 * 24 * 60 * 60 * 1000))' "$completed")
  [ "$deadline" -ge "$expiry" ] || fail "retention cohort deadline preceded the exact 30-day expiry"
  [ "$deadline" -lt $((expiry + 300000)) ] || fail "retention cohort ceiling exceeded one cohort"
  pass "report retention cohorts never expire reports before the published cutoff"
}

test_retention_cohort_and_sweep_share_drift_budget() {
  local stack="$TMP_ROOT/retention-drift-budget-stack" out status
  mkdir -p "$stack/entries"
  if out=$(FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_COHORT_MS=691200000 FM_REPORT_RETENTION_INTERVAL=691200 \
    "$SCRIPT" prune --status --force 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "retention accepted cohort and sweep drift beyond 15 days"
  assert_contains "$out" "must not exceed 15 days" \
    "retention joint drift rejection was not actionable"

  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_COHORT_MS=604800000 FM_REPORT_RETENTION_INTERVAL=691200 \
    "$SCRIPT" prune --status --force >/dev/null \
    || fail "retention rejected cohort and sweep drift at the 15-day boundary"
  pass "retention jointly bounds cohort and sweep drift to 15 days"
}

test_retention_guard_cannot_advance_minimum_age() {
  local stack="$TMP_ROOT/retention-minimum-age-stack" before after completed deadline cohort cutoff
  local retention_ms=2592000000 id legacy_id
  id='minimum-age-cohort'
  legacy_id='minimum-age-legacy'
  mkdir -p "$stack/entries"
  before=$(node -e 'process.stdout.write(String(Date.now()))')
  completed=$(node -e 'process.stdout.write(new Date(Number(process.argv[1]) - 30 * 24 * 60 * 60 * 1000 + 60000).toISOString())' "$before")
  deadline=$(node -e 'process.stdout.write(String(Math.ceil((Date.parse(process.argv[1]) + 30 * 24 * 60 * 60 * 1000) / 300000) * 300000))' "$completed")
  cohort="cohort-$deadline"
  mkdir -p "$stack/entries/$cohort/$id" "$stack/entries/$legacy_id"
  printf '{"schemaVersion":1,"reportId":"%s","taskId":"%s","title":"Minimum age","summary":"Minimum age","completedAt":"%s","retentionCohort":"%s","kind":"ship","project":"example","harness":"codex"}\n' \
    "$id" "$id" "$completed" "$cohort" > "$stack/entries/$cohort/$id/manifest.json"
  printf '{"schemaVersion":1,"reportId":"%s","taskId":"%s","title":"Legacy minimum age","summary":"Legacy minimum age","completedAt":"%s","kind":"ship","project":"example","harness":"codex"}\n' \
    "$legacy_id" "$legacy_id" "$completed" > "$stack/entries/$legacy_id/manifest.json"

  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" FM_REPORT_RETENTION_GUARD_MS=600000 \
    FM_REPORT_RETENTION_INTERVAL=300 FM_REPORT_RETENTION_NODE="$(command -v node)" \
    "$ROOT/bin/fm-report-retention.sh" run-once >/dev/null \
    || fail "retention owner rejected reports inside the minimum age"
  after=$(node -e 'process.stdout.write(String(Date.now()))')
  cutoff=$(node -e '
const source = require("fs").readFileSync(process.argv[1], "utf8");
process.stdout.write(String(JSON.parse(source.match(/=(\{.*\});/)[1]).cutoffMs));
' "$stack/.retention-policy.js")

  [ "$cutoff" -ge $((before - retention_ms)) ] \
    || fail "retention visibility cutoff preceded the exact 30-day boundary"
  [ "$cutoff" -le $((after - retention_ms)) ] \
    || fail "retention visibility cutoff advanced past the exact 30-day boundary"
  assert_present "$stack/entries/$cohort/$id/manifest.json" \
    "cohort cleanup retired a report before its 30-day minimum age"
  assert_present "$stack/entries/$cohort/$legacy_id/manifest.json" \
    "legacy migration retired a report before its 30-day minimum age"
  pass "retention guard cannot advance visibility or cleanup before 30 days"
}

test_retention_cutoff_never_regresses_with_wall_time() {
  local stack="$TMP_ROOT/retention-monotonic-stack" prior actual now retention_ms=2592000000
  mkdir -p "$stack/entries"
  now=$(node -e 'process.stdout.write(String(Date.now()))')
  prior=$((now - retention_ms + 600000))
  printf 'window.firstmateRetentionPolicy={"schemaVersion":1,"generation":"prior-clock","cutoffMs":%s};\n' \
    "$prior" > "$stack/.retention-policy.js"
  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" "$SCRIPT" prune --force >/dev/null \
    || fail "retention rejected an existing cutoff from a later wall-clock reading"
  actual=$(node -e '
const source = require("fs").readFileSync(process.argv[1], "utf8");
process.stdout.write(String(JSON.parse(source.match(/=(\{.*\});/)[1]).cutoffMs));
' "$stack/.retention-policy.js")
  [ "$actual" -ge "$prior" ] || fail "retention visibility cutoff moved backward with wall time"
  pass "report retention cutoff remains monotonic across wall-clock regressions"
}

test_republish_new_generation_refreshes_completion_time() {
  local id=report-generation-a4 repo meta entry manifest staged previous_completed completed
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
  previous_completed=$(sed -n 's/.*"completedAt": "\([^"]*\)".*/\1/p' "$manifest")
  /bin/sleep 0.02

  git -C "$repo" commit -q --allow-empty -m second
  sed 's/^harness=.*/harness=claude/; s/^account_profile=.*/account_profile=claude-3/; s/^generation_id=.*/generation_id=generation-restored/' "$meta" > "$staged"
  mv "$staged" "$meta"
  write_required_report "$HOME_DIR/data/$id/completion.md" "Restored generation."
  run_stack publish "$id" >/dev/null || fail "restored generation report publication failed"
  entry=$(run_stack path "$id") || fail "restored generation report path failed"
  manifest="$(dirname "$entry")/manifest.json"
  completed=$(sed -n 's/.*"completedAt": "\([^"]*\)".*/\1/p' "$manifest")
  [ -n "$completed" ] && [ "$completed" != "$previous_completed" ] \
    || fail "new generation retained the superseded completion timestamp"
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

test_generation_identity_falls_back_only_when_both_sides_are_legacy() {
  local id meta staged entry manifest first second

  id=report-new-id-over-legacy-a4c
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "New identity over legacy manifest."
  run_stack publish "$id" >/dev/null || fail "new-id-over-legacy precondition publication failed"
  entry=$(run_stack path "$id")
  manifest="$(dirname "$entry")/manifest.json"
  staged="$manifest.staged"
  grep -v '"generationId":' "$manifest" > "$staged"
  mv "$staged" "$manifest"
  first=$(sed -n 's/.*"completedAt": "\([^"]*\)".*/\1/p' "$manifest")
  /bin/sleep 0.02
  run_stack publish "$id" >/dev/null || fail "new-id-over-legacy publication failed"
  entry=$(run_stack path "$id") || fail "new-id-over-legacy path lookup failed"
  manifest="$(dirname "$entry")/manifest.json"
  second=$(sed -n 's/.*"completedAt": "\([^"]*\)".*/\1/p' "$manifest")
  [ -n "$second" ] && [ "$second" != "$first" ] \
    || fail "a new generation id reused a legacy manifest completion time"

  id=report-legacy-over-new-id-a4d
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Legacy metadata over new identity."
  run_stack publish "$id" >/dev/null || fail "legacy-over-new-id precondition publication failed"
  entry=$(run_stack path "$id")
  manifest="$(dirname "$entry")/manifest.json"
  meta="$HOME_DIR/state/$id.meta"
  staged="$HOME_DIR/state/.$id.meta.legacy"
  grep -v '^generation_id=' "$meta" > "$staged"
  mv "$staged" "$meta"
  first=$(sed -n 's/.*"completedAt": "\([^"]*\)".*/\1/p' "$manifest")
  /bin/sleep 0.02
  run_stack publish "$id" >/dev/null || fail "legacy-over-new-id publication failed"
  entry=$(run_stack path "$id") || fail "legacy-over-new-id path lookup failed"
  manifest="$(dirname "$entry")/manifest.json"
  second=$(sed -n 's/.*"completedAt": "\([^"]*\)".*/\1/p' "$manifest")
  [ -n "$second" ] && [ "$second" != "$first" ] \
    || fail "legacy metadata reused a generation-bound manifest completion time"

  id=report-both-legacy-a4e
  write_task "$id" ship
  meta="$HOME_DIR/state/$id.meta"
  staged="$HOME_DIR/state/.$id.meta.legacy"
  grep -v '^generation_id=' "$meta" > "$staged"
  mv "$staged" "$meta"
  write_required_report "$HOME_DIR/data/$id/completion.md" "Both sides legacy."
  run_stack publish "$id" >/dev/null || fail "both-legacy precondition publication failed"
  entry=$(run_stack path "$id")
  manifest="$(dirname "$entry")/manifest.json"
  first=$(sed -n 's/.*"completedAt": "\([^"]*\)".*/\1/p' "$manifest")
  /bin/sleep 0.02
  run_stack publish "$id" >/dev/null || fail "both-legacy compatibility publication failed"
  second=$(sed -n 's/.*"completedAt": "\([^"]*\)".*/\1/p' "$manifest")
  [ "$second" = "$first" ] || fail "both-legacy retry lost compatibility generation matching"
  pass "generation matching uses legacy heuristics only for two legacy identities"
}

test_text_sources_are_stored_verbatim_and_completion_is_bounded() {
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
  cmp -s "$HOME_DIR/data/$id/brief.md" "$stored_brief" || fail "oversized brief was truncated or re-encoded"
  cmp -s "$HOME_DIR/state/$id.status" "$stored_status" || fail "oversized status trail was truncated or re-encoded"

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
  pass "report stack preserves informational trails and rejects oversized completion reports"
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
  local id=report-temp-safety-a8 outside entry report_id index_plant transaction_plant
  id=report-temp-safety-a8
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Exclusive report staging."
  outside="$TMP_ROOT/report-temp-sentinel"
  printf 'sentinel\n' > "$outside"
  mkdir -p "$STACK"
  index_plant="$STACK/.index.html.${BASHPID:-$$}.tmp"
  (
    ln -s "$outside" "$index_plant"
    exec env FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$STACK" "$SCRIPT" publish "$id"
  ) >/dev/null || fail "legacy predictable index temp fixture blocked randomized publication"
  assert_grep 'sentinel' "$outside" "report index staging followed a planted temp symlink"
  rm -f "$index_plant"
  entry=$(run_stack path "$id")
  report_id=$(basename "$(dirname "$entry")")
  transaction_plant="$STACK/entries/.$report_id.transaction.${BASHPID:-$$}.tmp"
  (
    ln -s "$outside" "$transaction_plant"
    exec env FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$STACK" "$SCRIPT" publish "$id"
  ) >/dev/null || fail "legacy predictable transaction temp fixture blocked randomized publication"
  assert_grep 'sentinel' "$outside" "report transaction staging followed a planted temp symlink"
  rm -f "$transaction_plant"
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

test_required_sections_reject_empty_bodies() {
  local id=report-empty-sections-b3a source out status heading
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

## Summary

## What changed

## Verification

## Visual evidence

## Artifacts

## Follow-ups
EOF
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "report with empty required sections unexpectedly published"
  assert_contains "$out" "required sections have no substantive content" \
    "empty-section failure did not identify the content requirement"
  for heading in "## Summary" "## What changed" "## Verification" "## Visual evidence" "## Artifacts" "## Follow-ups"; do
    assert_contains "$out" "$heading" "empty-section failure omitted $heading"
  done
  assert_present "$HOME_DIR/state/$id.meta" "empty-section validation removed task state"
  pass "report stack requires substantive content in every completion section"
}

test_required_sections_reject_container_only_markers() {
  local id=report-container-only-sections-b3r source out status heading
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  printf '# Completion\n\n## Summary\n\n> \n\n## What changed\n\n+ \n\n## Verification\n\n1. \n\n## Visual evidence\n\nNone.\n\n## Artifacts\n\nReport.\n\n## Follow-ups\n\nNone.\n' > "$source"
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "container-only section markers unexpectedly satisfied required sections"
  for heading in "## Summary" "## What changed" "## Verification"; do
    assert_contains "$out" "$heading" "container-only failure omitted $heading"
  done
  assert_present "$HOME_DIR/state/$id.meta" "container-only validation removed task state"
  pass "report stack rejects bare container markers as section content"
}

test_fenced_required_section_bodies_use_scoped_content() {
  local id source out status

  id=report-fenced-body-content-b3n
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

## Summary

```console
$ firstmate status
crew ready
```

## What changed

Recorded work.

## Verification

```text
{}
```

## Visual evidence

None.

## Artifacts

Report.

## Follow-ups

None.
EOF
  run_stack publish "$id" >/dev/null \
    || fail "meaningful transcript and punctuation-only fenced bodies were rejected"

  id=report-empty-fenced-body-b3o
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

## Summary

```text

```

## What changed

Recorded work.

## Verification

Verified.

## Visual evidence

None.

## Artifacts

Report.

## Follow-ups

None.
EOF
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "empty fenced body unexpectedly satisfied the Summary section"
  assert_contains "$out" "## Summary" "empty fenced-body failure omitted the blank Summary section"

  id=report-control-only-fenced-body-b3q
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  {
    cat <<'EOF'
# Completion

## Summary

```text
EOF
    printf '\342\200\213\n'
    cat <<'EOF'
```

## What changed

Recorded work.

## Verification

Verified.

## Visual evidence

None.

## Artifacts

Report.

## Follow-ups

None.
EOF
  } > "$source"
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "format-control-only fenced body unexpectedly satisfied the Summary section"
  assert_contains "$out" "## Summary" "control-only fenced-body failure omitted the blank Summary section"

  id=report-container-whitespace-fenced-body-b3p
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

## Summary

Complete.

## What changed

> ```text
>
> ```

## Verification

Verified.

## Visual evidence

None.

## Artifacts

- ```text

  ```

## Follow-ups

None.
EOF
  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "container-scoped whitespace fences unexpectedly satisfied required sections"
  assert_contains "$out" "## What changed" "blank blockquote fence failure omitted What changed"
  assert_contains "$out" "## Artifacts" "blank list fence failure omitted Artifacts"
  pass "report sections accept meaningful fenced content but reject empty scoped fence bodies"
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

test_container_scoped_fences_do_not_close_from_top_level() {
  local container id source out status heading
  for container in quote list; do
    id="report-container-scope-$container-b3m"
    write_task "$id" ship
    source="$HOME_DIR/data/$id/completion.md"
    if [ "$container" = quote ]; then
      cat > "$source" <<'EOF'
# Completion

> ```text
> Nested example.
```text
## Summary
## What changed
## Verification
## Visual evidence
## Artifacts
## Follow-ups
```
EOF
    else
      cat > "$source" <<'EOF'
# Completion

- ```text
  Nested example.
```text
## Summary
## What changed
## Verification
## Visual evidence
## Artifacts
## Follow-ups
```
EOF
    fi
    out=$(run_stack publish "$id" 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$container-scoped fence was closed by a top-level fence"
    for heading in "## Summary" "## What changed" "## Verification" "## Visual evidence" "## Artifacts" "## Follow-ups"; do
      assert_contains "$out" "$heading" "$container fence-scope failure omitted missing heading $heading"
    done
  done
  pass "report parsing keeps fenced blocks scoped to their Markdown containers"
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

test_list_lazy_continuations_do_not_satisfy_required_sections() {
  local id=report-list-lazy-b3k source out status heading
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

- list paragraph
  ## Sacrificial heading
  ## Summary
  ## What changed
  ## Verification
  ## Visual evidence
  ## Artifacts
  ## Follow-ups
EOF
  if out=$(run_stack publish "$id" 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "lazy list-continuation headings unexpectedly satisfied the report contract"
  for heading in "## Summary" "## What changed" "## Verification" "## Visual evidence" "## Artifacts" "## Follow-ups"; do
    assert_contains "$out" "$heading" "lazy list-continuation failure omitted missing heading $heading"
  done
  pass "report parsing excludes headings in lazy list continuations"
}

test_underindented_list_headings_exit_lazy_continuation() {
  local id=report-list-underindent-b3l source entry manifest
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

 - list paragraph
  ## Summary

Accepted top-level summary.

## What changed

Changed.

## Verification

Verified.

## Visual evidence

None.

## Artifacts

None.

## Follow-ups

None.
EOF
  run_stack publish "$id" >/dev/null \
    || fail "a heading indented less than its list item's required content indent stayed hidden"
  entry=$(run_stack path "$id") || fail "underindented-list report path failed"
  manifest="$(dirname "$entry")/manifest.json"
  assert_grep '"summary": "Accepted top level summary."' "$manifest" \
    "underindented list heading did not become the visible Summary section"
  pass "report parsing exits lazy list continuation below the actual required content indent"
}

test_nested_list_parent_scope_hides_required_headings() {
  local id=report-list-parent-b3m source out status heading
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

- outer paragraph
  - inner paragraph
  ## Summary
  ## What changed
  ## Verification
  ## Visual evidence
  ## Artifacts
  ## Follow-ups
EOF
  if out=$(run_stack publish "$id" 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "headings inside a nested list's parent scope unexpectedly satisfied the report contract"
  for heading in "## Summary" "## What changed" "## Verification" "## Visual evidence" "## Artifacts" "## Follow-ups"; do
    assert_contains "$out" "$heading" "nested parent-list failure omitted missing heading $heading"
  done
  pass "report parsing preserves parent list scope after nested lists"
}

test_blockquote_list_scope_requires_quote_markers() {
  local id=report-quote-list-exit-b3p invalid=report-list-quote-nested-b3q source entry manifest out status heading
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

> - quoted list paragraph
  ## Summary

Visible summary after the quote.

## What changed

Changed.

## Verification

Verified.

## Visual evidence

None.

## Artifacts

None.

## Follow-ups

None.
EOF
  run_stack publish "$id" >/dev/null \
    || fail "a heading outside a blockquote list stayed attached without an explicit quote marker"
  entry=$(run_stack path "$id") || fail "blockquote-list report path failed"
  manifest="$(dirname "$entry")/manifest.json"
  assert_grep '"summary": "Visible summary after the quote."' "$manifest" \
    "blockquote-list ancestry hid the valid heading outside the quote"

  write_task "$invalid" ship
  source="$HOME_DIR/data/$invalid/completion.md"
  cat > "$source" <<'EOF'
# Completion

- > quoted list paragraph
  > ## Summary
  > ## What changed
  > ## Verification
  > ## Visual evidence
  > ## Artifacts
  > ## Follow-ups
EOF
  if out=$(run_stack publish "$invalid" 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "headings inside a list-nested blockquote unexpectedly satisfied the report contract"
  for heading in "## Summary" "## What changed" "## Verification" "## Visual evidence" "## Artifacts" "## Follow-ups"; do
    assert_contains "$out" "$heading" "list-nested blockquote failure omitted missing heading $heading"
  done
  pass "report parsing requires explicit blockquote markers for lazy list ancestry"
}

test_container_scopes_preserve_commonmark_blank_and_exit_rules() {
  local valid=report-container-exit-b3n invalid=report-list-blank-b3o source out status heading
  write_task "$valid" ship
  source="$HOME_DIR/data/$valid/completion.md"
  cat > "$source" <<'EOF'
# Completion

> ```text
> Quoted code.
  ## Summary

  Valid summary.

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
  run_stack publish "$valid" >/dev/null || fail "top-level headings after a blockquote fence stayed trapped in the old container"

  write_task "$invalid" ship
  source="$HOME_DIR/data/$invalid/completion.md"
  cat > "$source" <<'EOF'
# Completion

- ```text

  ## Summary
  ## What changed
  ## Verification
  ## Visual evidence
  ## Artifacts
  ## Follow-ups
  ```
EOF
  if out=$(run_stack publish "$invalid" 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "a blank line ended a list-scoped fence and exposed nested headings"
  for heading in "## Summary" "## What changed" "## Verification" "## Visual evidence" "## Artifacts" "## Follow-ups"; do
    assert_contains "$out" "$heading" "list blank-line scope failure omitted missing heading $heading"
  done
  pass "report parsing tracks CommonMark containers independently from indentation"
}

test_large_non_utf8_text_artifacts_are_stored_verbatim() {
  local id=report-verbatim-bytes-b3p entry source brief status
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  brief="$HOME_DIR/data/$id/brief.md"
  status="$HOME_DIR/state/$id.status"
  write_required_report "$source" "Binary-safe report."
  printf '\377\376\375' >> "$source"
  dd if=/dev/zero bs=1048576 count=4 >> "$brief" 2>/dev/null
  printf '\377brief-tail\n' >> "$brief"
  dd if=/dev/zero bs=1048576 count=4 >> "$status" 2>/dev/null
  printf '\376status-tail\n' >> "$status"

  run_stack publish "$id" >/dev/null || fail "large non-UTF-8 artifact publication failed"
  entry=$(run_stack path "$id")
  cmp -s "$source" "$(dirname "$entry")/report.md" || fail "report bytes changed during publication"
  cmp -s "$brief" "$(dirname "$entry")/brief.md" || fail "large brief bytes were truncated or re-encoded"
  cmp -s "$status" "$(dirname "$entry")/status.log" || fail "large status bytes were truncated or re-encoded"
  pass "report publication stores raw text artifact bytes independently from decoded views"
}

test_large_visual_inventory_does_not_share_text_buffer_headroom() {
  local id=report-visual-inventory-b3q entry count
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Large visual inventory."
  mkdir -p "$HOME_DIR/data/$id/visuals"
  python3 - "$HOME_DIR/data/$id/visuals" <<'PY'
import os
import sys

root = os.fsencode(sys.argv[1])
for index in range(503):
    name = f"{index:04d}".encode() + bytes([1 + index % 31]) * 240
    descriptor = os.open(os.path.join(root, name), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.close(descriptor)
PY
  run_stack publish "$id" >/dev/null || fail "valid large visual inventory exhausted text helper headroom"
  entry=$(run_stack path "$id")
  count=$(find "$(dirname "$entry")/visuals" -type f -print0 | tr -cd '\000' | wc -c | tr -d ' ')
  [ "$count" = 503 ] || fail "large visual inventory lost entries (count=$count)"
  pass "visual inventory transport has independently bounded capacity"
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
  local pids="" pid failures=0 i
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
  if [ "$failures" -ne 0 ]; then
    for i in 1 2 3 4 5 6 7 8; do
      [ ! -s "$TMP_ROOT/render-$i.out" ] || printf 'render-%s: %s\n' "$i" "$(cat "$TMP_ROOT/render-$i.out")" >&2
    done
    fail "concurrent stale-lock reclaim lost $failures publisher(s)"
  fi
  assert_absent "$STACK/.publish.lock" "concurrent render retained the publication lock"
  if find "$STACK" -maxdepth 1 -name '.publish.lock.stale.*' | grep . >/dev/null 2>&1; then
    fail "concurrent stale-lock reclaim leaked quarantine state"
  fi
  pass "report stack serializes concurrent stale-lock reclamation"
}

test_install_guard_release_failure_cleans_owned_lock() {
  local stack="$TMP_ROOT/install-guard-release-stack" out status residue
  mkdir -p "$stack"
  out=$(FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_INSTALL_GUARD_RELEASE_TEST_FAILURE=1 "$SCRIPT" render 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "synthetic install-guard release failure exited successfully"
  assert_contains "$out" "synthetic report install-guard release failure" \
    "install-guard release failure was not observable"
  assert_absent "$stack/.publish.lock" \
    "install-guard release failure retained its newly installed canonical lock"
  assert_present "$stack/.publish.lock.reclaim" \
    "install-guard release failure did not leave an owned recoverable guard"

  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" "$SCRIPT" render >/dev/null \
    || fail "next publisher did not recover the failed install guard"
  assert_absent "$stack/.publish.lock" "recovery retained the canonical publication lock"
  assert_absent "$stack/.publish.lock.reclaim" "recovery retained the install guard"
  residue=$(find "$stack" -maxdepth 1 \( \
    -name '.publish.lock.candidate.*' -o \
    -name '.publish.lock.reclaim.candidate.*' -o \
    -name '.publish.lock.reclaim.pin.*' -o \
    -name '..publish.lock.reclaim.removed.*' -o \
    -name '..publish.lock.released.*' -o \
    -name '.publish.lock.stale.*' \
    \) -print)
  [ -z "$residue" ] || fail "install-guard recovery leaked owned residue: $residue"
  pass "install-guard release failure cleans its lock and remains recoverable"
}

test_post_install_guard_owner_death_is_recovered() {
  local stack="$TMP_ROOT/post-install-owner-death-stack"
  local precheck_ready="$TMP_ROOT/post-install-precheck.ready"
  local precheck_proceed="$TMP_ROOT/post-install-precheck.proceed"
  local owner_ready="$TMP_ROOT/post-install-owner.ready"
  local owner_proceed="$TMP_ROOT/post-install-owner.proceed"
  local observed_ready="$TMP_ROOT/post-install-observed.ready"
  local observed_proceed="$TMP_ROOT/post-install-observed.proceed"
  local acquired_ready="$TMP_ROOT/post-install-acquired.ready"
  local acquired_proceed="$TMP_ROOT/post-install-acquired.proceed"
  local owner_out="$TMP_ROOT/post-install-owner.out"
  local waiter_out="$TMP_ROOT/post-install-waiter.out"
  local owner_pid waiter_pid owner_status waiter_status state started_at elapsed residue
  mkdir -p "$stack"
  mkfifo "$precheck_ready" "$precheck_proceed" "$owner_ready" "$owner_proceed" \
    "$observed_ready" "$observed_proceed" "$acquired_ready" "$acquired_proceed"
  exec 7<>"$precheck_ready"
  exec 8<>"$precheck_proceed"
  exec 9<>"$owner_ready"
  exec 10<>"$owner_proceed"
  exec 11<>"$observed_ready"
  exec 12<>"$observed_proceed"
  exec 13<>"$acquired_ready"
  exec 14<>"$acquired_proceed"

  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_LOCK_PRECHECK_TEST_READY="$precheck_ready" \
    FM_REPORT_LOCK_PRECHECK_TEST_PROCEED="$precheck_proceed" \
    FM_REPORT_RECLAIM_WAITER_TEST_READY="$observed_ready" \
    FM_REPORT_RECLAIM_WAITER_TEST_PROCEED="$observed_proceed" \
    FM_REPORT_LOCK_ACQUIRED_TEST_READY="$acquired_ready" \
    FM_REPORT_LOCK_ACQUIRED_TEST_PROCEED="$acquired_proceed" \
    "$SCRIPT" render > "$waiter_out" 2>&1 &
  waiter_pid=$!
  if ! IFS= read -r -t 10 state <&7; then
    kill -TERM "$waiter_pid" 2>/dev/null || true
    fail "report waiter did not reach its pre-install check: $(cat "$waiter_out")"
  fi
  [ "$state" = "guard-absent" ] || {
    kill -TERM "$waiter_pid" 2>/dev/null || true
    fail "report waiter emitted an unexpected pre-install state: $state"
  }

  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_LOCK_INSTALLED_GUARD_TEST_READY="$owner_ready" \
    FM_REPORT_LOCK_INSTALLED_GUARD_TEST_PROCEED="$owner_proceed" \
    "$SCRIPT" render > "$owner_out" 2>&1 &
  owner_pid=$!
  if ! IFS= read -r -t 10 state <&9; then
    kill -TERM "$owner_pid" "$waiter_pid" 2>/dev/null || true
    fail "report owner did not pause after installing its lock: $(cat "$owner_out")"
  fi
  [ "$state" = "lock-installed-guard-held" ] || {
    kill -TERM "$owner_pid" "$waiter_pid" 2>/dev/null || true
    fail "report owner emitted an unexpected post-install state: $state"
  }
  assert_present "$stack/.publish.lock" "post-install owner did not install the canonical lock"
  assert_present "$stack/.publish.lock.reclaim" "post-install owner released its guard before the crash gate"

  printf 'continue\n' >&8
  if ! IFS= read -r -t 10 state <&11; then
    kill -TERM "$owner_pid" "$waiter_pid" 2>/dev/null || true
    fail "already-running report waiter did not observe the installed owner's guard: $(cat "$waiter_out")"
  fi
  [ "$state" = "guard-observed" ] || {
    kill -TERM "$owner_pid" "$waiter_pid" 2>/dev/null || true
    fail "already-running report waiter emitted an unexpected guard state: $state"
  }

  started_at=$(date +%s)
  kill -TERM "$owner_pid" 2>/dev/null || true
  if wait "$owner_pid"; then owner_status=0; else owner_status=$?; fi
  [ "$owner_status" -ne 0 ] || fail "synthetically terminated post-install owner exited successfully"
  printf 'continue\n' >&10
  printf 'continue\n' >&12
  if ! IFS= read -r -t 10 state <&13; then
    kill -TERM "$waiter_pid" 2>/dev/null || true
    fail "report waiter did not recover the freshly installed dead-owner lock: $(cat "$waiter_out")"
  fi
  [ "$state" = "lock-acquired" ] || {
    kill -TERM "$waiter_pid" 2>/dev/null || true
    fail "recovered report waiter emitted an unexpected acquisition state: $state"
  }
  assert_present "$stack/.publish.lock" "recovered report waiter did not own the canonical lock"
  assert_absent "$stack/.publish.lock.reclaim" "recovered report waiter retained the outer guard"
  printf 'continue\n' >&14
  if wait "$waiter_pid"; then waiter_status=0; else waiter_status=$?; fi
  elapsed=$(( $(date +%s) - started_at ))
  [ "$waiter_status" -eq 0 ] || fail "fresh dead-owner recovery failed: $(cat "$waiter_out")"
  [ "$elapsed" -le 15 ] || fail "fresh dead-owner recovery took ${elapsed}s"
  assert_absent "$stack/.publish.lock" "fresh dead-owner recovery retained the canonical lock"
  assert_absent "$stack/.publish.lock.reclaim" "fresh dead-owner recovery retained the outer guard"
  residue=$(find "$stack" -maxdepth 1 \( \
    -name '.publish.lock.candidate.*' -o \
    -name '.publish.lock.reclaim.candidate.*' -o \
    -name '.publish.lock.reclaim.pin.*' -o \
    -name '..publish.lock.reclaim.removed.*' -o \
    -name '..publish.lock.released.*' -o \
    -name '.publish.lock.stale.*' \
    \) -print)
  [ -z "$residue" ] || fail "fresh dead-owner recovery leaked owned residue: $residue"
  exec 7>&-; exec 8>&-; exec 9>&-; exec 10>&-; exec 11>&-; exec 12>&-
  exec 13>&-; exec 14>&-
  pass "already-running report waiters recover a freshly installed dead-owner lock"
}

test_reclaim_guard_fences_the_stale_generation_gap() {
  local stack="$TMP_ROOT/reclaim-fence-stack" precheck_ready precheck_proceed
  local reclaimer_ready reclaimer_proceed waiter_ready waiter_proceed acquired_ready acquired_proceed
  local released_ready released_proceed
  local reclaimer_out waiter_out reclaimer_pid waiter_pid reclaimer_status waiter_status
  local precheck_state waiter_state started_at elapsed
  mkdir -p "$stack"
  precheck_ready="$TMP_ROOT/reclaim-precheck.ready"
  precheck_proceed="$TMP_ROOT/reclaim-precheck.proceed"
  reclaimer_ready="$TMP_ROOT/reclaim-fence.ready"
  reclaimer_proceed="$TMP_ROOT/reclaim-fence.proceed"
  waiter_ready="$TMP_ROOT/reclaim-waiter.ready"
  waiter_proceed="$TMP_ROOT/reclaim-waiter.proceed"
  acquired_ready="$TMP_ROOT/reclaim-acquired.ready"
  acquired_proceed="$TMP_ROOT/reclaim-acquired.proceed"
  released_ready="$TMP_ROOT/reclaim-released.ready"
  released_proceed="$TMP_ROOT/reclaim-released.proceed"
  reclaimer_out="$TMP_ROOT/reclaim-fence.out"
  waiter_out="$TMP_ROOT/reclaim-waiter.out"
  mkfifo "$precheck_ready" "$precheck_proceed" "$reclaimer_ready" "$reclaimer_proceed" \
    "$waiter_ready" "$waiter_proceed" "$released_ready" "$released_proceed" \
    "$acquired_ready" "$acquired_proceed"
  exec 7<>"$precheck_ready"
  exec 8<>"$precheck_proceed"
  exec 9<>"$reclaimer_ready"
  exec 10<>"$reclaimer_proceed"
  exec 11<>"$waiter_ready"
  exec 12<>"$waiter_proceed"
  exec 13<>"$acquired_ready"
  exec 14<>"$acquired_proceed"
  exec 15<>"$released_ready"
  exec 16<>"$released_proceed"

  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_LOCK_PRECHECK_TEST_READY="$precheck_ready" FM_REPORT_LOCK_PRECHECK_TEST_PROCEED="$precheck_proceed" \
    FM_REPORT_RECLAIM_WAITER_TEST_READY="$waiter_ready" FM_REPORT_RECLAIM_WAITER_TEST_PROCEED="$waiter_proceed" \
    FM_REPORT_RECLAIM_GUARD_RELEASED_TEST_READY="$released_ready" \
    FM_REPORT_RECLAIM_GUARD_RELEASED_TEST_PROCEED="$released_proceed" \
    FM_REPORT_LOCK_ACQUIRED_TEST_READY="$acquired_ready" FM_REPORT_LOCK_ACQUIRED_TEST_PROCEED="$acquired_proceed" \
    "$SCRIPT" render > "$waiter_out" 2>&1 &
  waiter_pid=$!
  if ! IFS= read -r -t 10 precheck_state <&7; then
    kill -TERM "$waiter_pid" 2>/dev/null || true
    fail "report contender did not reach its prechecked state: $(cat "$waiter_out")"
  fi
  [ "$precheck_state" = "guard-absent" ] || {
    kill -TERM "$waiter_pid" 2>/dev/null || true
    fail "report contender observed an unexpected precheck state: $precheck_state"
  }

  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_INSTALL_GUARD_TEST_READY="$reclaimer_ready" FM_REPORT_INSTALL_GUARD_TEST_PROCEED="$reclaimer_proceed" \
    "$SCRIPT" render > "$reclaimer_out" 2>&1 &
  reclaimer_pid=$!
  if ! IFS= read -r -t 10 waiter_state <&9; then
    kill -TERM "$reclaimer_pid" "$waiter_pid" 2>/dev/null || true
    fail "report publisher did not pause while holding the install guard: $(cat "$reclaimer_out")"
  fi
  [ "$waiter_state" = "install-guard-held" ] || {
    kill -TERM "$reclaimer_pid" "$waiter_pid" 2>/dev/null || true
    fail "report install-guard owner emitted an unexpected gate state: $waiter_state"
  }

  printf 'continue\n' >&8
  if ! IFS= read -r -t 10 waiter_state <&11; then
    kill -TERM "$reclaimer_pid" "$waiter_pid" 2>/dev/null || true
    fail "prechecked report contender did not observe the active reclaim guard: $(cat "$waiter_out")"
  fi
  [ "$waiter_state" = "guard-observed" ] || {
    kill -TERM "$reclaimer_pid" "$waiter_pid" 2>/dev/null || true
    fail "prechecked report contender emitted an unexpected guard state: $waiter_state"
  }
  assert_absent "$stack/.publish.lock" \
    "prechecked contender installed a replacement lock while the reclaim guard was held"
  assert_present "$stack/.publish.lock.reclaim" \
    "prechecked contender did not remain behind the publisher's install guard"

  started_at=$(date +%s)
  kill -TERM "$reclaimer_pid" 2>/dev/null || true
  if wait "$reclaimer_pid"; then reclaimer_status=0; else reclaimer_status=$?; fi
  [ "$reclaimer_status" -ne 0 ] || fail "synthetically terminated install-guard owner exited successfully"
  printf 'continue\n' >&10
  printf 'continue\n' >&12
  if ! IFS= read -r -t 10 waiter_state <&15; then
    kill -TERM "$waiter_pid" 2>/dev/null || true
    fail "prechecked report contender did not release the dead reclaim guard: $(cat "$waiter_out")"
  fi
  [ "$waiter_state" = "guard-released" ] || {
    kill -TERM "$waiter_pid" 2>/dev/null || true
    fail "prechecked report contender emitted an unexpected guard-release state: $waiter_state"
  }
  assert_absent "$stack/.publish.lock.reclaim" "dead reclaim guard remained after its release event"
  assert_absent "$stack/.publish.lock" "report contender installed before its guard-release event completed"
  printf 'continue\n' >&16
  if ! IFS= read -r -t 10 waiter_state <&13; then
    kill -TERM "$waiter_pid" 2>/dev/null || true
    fail "prechecked report contender did not acquire after guard-owner death: $(cat "$waiter_out")"
  fi
  [ "$waiter_state" = "lock-acquired" ] || {
    kill -TERM "$waiter_pid" 2>/dev/null || true
    fail "prechecked report contender emitted an unexpected acquisition state: $waiter_state"
  }
  assert_present "$stack/.publish.lock" "guard-released contender did not own the canonical report lock"
  assert_absent "$stack/.publish.lock.reclaim" "guard-released contender acquired before reclaim-guard cleanup"
  printf 'continue\n' >&14
  if wait "$waiter_pid"; then waiter_status=0; else waiter_status=$?; fi
  elapsed=$(( $(date +%s) - started_at ))
  [ "$waiter_status" -eq 0 ] || fail "fenced report waiter failed: $(cat "$waiter_out")"
  [ "$elapsed" -le 15 ] || fail "report waiter took ${elapsed}s to recover its dead reclaim-guard owner"
  assert_absent "$stack/.publish.lock" "fenced stale-lock test retained the publication lock"
  assert_absent "$stack/.publish.lock.reclaim" "fenced stale-lock test retained the reclaim guard"
  exec 7>&-; exec 8>&-; exec 9>&-; exec 10>&-; exec 11>&-; exec 12>&-
  exec 13>&-; exec 14>&-; exec 15>&-; exec 16>&-
  pass "report install guard fences a negative precheck and is recovered inside the wait budget"
}

test_abandoned_reclaim_guard_is_recovered() {
  local stack="$TMP_ROOT/abandoned-reclaim-guard-stack"
  mkdir -p "$stack"
  printf '{"pid":%s,"startedAt":"different-process-start","token":"abandoned-guard"}\n' "$$" \
    > "$stack/.publish.lock.reclaim"
  touch -t 200001010000 "$stack/.publish.lock.reclaim"
  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" "$SCRIPT" render >/dev/null \
    || fail "abandoned report-lock reclaim guard was not recovered"
  assert_absent "$stack/.publish.lock" "abandoned reclaim-guard recovery retained the publication lock"
  assert_absent "$stack/.publish.lock.reclaim" "abandoned reclaim-guard recovery retained the reclaim guard"
  pass "report stack recovers an abandoned outer reclaim guard"
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

test_namespace_cutover_waiter_pins_entries_after_lock_acquisition() {
  local id=report-cutover-waiter-k2b stack entry owner_ready owner_proceed waiter_ready waiter_proceed owner_out waiter_out
  local owner_pid waiter_pid owner_status waiter_status state
  stack="$STACK"
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Namespace cutover waiter."
  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" "$SCRIPT" publish "$id" >/dev/null \
    || fail "namespace-cutover waiter precondition publication failed"
  entry=$(FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" "$SCRIPT" path "$id") \
    || fail "namespace-cutover waiter precondition path failed"
  expire_report_entry "$entry" >/dev/null || fail "namespace-cutover waiter report could not be aged"
  owner_ready="$TMP_ROOT/cutover-owner.ready"
  owner_proceed="$TMP_ROOT/cutover-owner.proceed"
  waiter_ready="$TMP_ROOT/cutover-waiter.ready"
  waiter_proceed="$TMP_ROOT/cutover-waiter.proceed"
  owner_out="$TMP_ROOT/cutover-owner.out"
  waiter_out="$TMP_ROOT/cutover-waiter.out"
  mkfifo "$owner_ready" "$owner_proceed" "$waiter_ready" "$waiter_proceed"
  exec 7<>"$owner_ready"
  exec 8<>"$owner_proceed"
  exec 9<>"$waiter_ready"
  exec 10<>"$waiter_proceed"

  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_LOCK_TEST_READY="$owner_ready" FM_REPORT_LOCK_TEST_PROCEED="$owner_proceed" \
    "$SCRIPT" prune --status --force > "$owner_out" 2>&1 &
  owner_pid=$!
  if ! IFS= read -r -t 10 state <&7; then
    kill -TERM "$owner_pid" 2>/dev/null || true
    fail "namespace-cutover owner did not acquire its publication lock: $(cat "$owner_out")"
  fi
  [ "$state" = "lock-acquired" ] || fail "namespace-cutover owner emitted an unexpected lock state: $state"

  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_LOCK_WAITER_TEST_READY="$waiter_ready" FM_REPORT_LOCK_WAITER_TEST_PROCEED="$waiter_proceed" \
    "$SCRIPT" render > "$waiter_out" 2>&1 &
  waiter_pid=$!
  if ! IFS= read -r -t 10 state <&9; then
    kill -TERM "$owner_pid" "$waiter_pid" 2>/dev/null || true
    fail "namespace-cutover waiter did not observe the held publication lock: $(cat "$waiter_out")"
  fi
  [ "$state" = "lock-observed" ] || fail "namespace-cutover waiter emitted an unexpected lock state: $state"
  printf 'continue\n' >&10
  printf 'continue\n' >&8
  if wait "$owner_pid"; then owner_status=0; else owner_status=$?; fi
  if wait "$waiter_pid"; then waiter_status=0; else waiter_status=$?; fi
  [ "$owner_status" -eq 0 ] || fail "namespace-cutover owner failed: $(cat "$owner_out")"
  [ "$waiter_status" -eq 0 ] || fail "namespace-cutover waiter failed after lock acquisition: $(cat "$waiter_out")"
  assert_absent "$stack/.publish.lock" "namespace-cutover waiter retained its publication lock"
  exec 7>&-; exec 8>&-; exec 9>&-; exec 10>&-
  pass "publication waiters pin mutable namespaces only after acquiring the lock"
}

test_post_rename_lock_setup_failure_releases_owned_lock() {
  local stack="$TMP_ROOT/post-rename-setup-stack" out status
  out=$(FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" FM_REPORT_LOCK_TEST_SETUP_FAILURE=1 \
    "$SCRIPT" render 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "synthetic post-rename lock setup failure unexpectedly succeeded"
  assert_contains "$out" "synthetic report publication lock setup failure" \
    "post-rename setup failure did not preserve its primary error"
  assert_absent "$stack/.publish.lock" "post-rename setup failure retained its owned publication lock"
  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" "$SCRIPT" render >/dev/null \
    || fail "post-rename setup cleanup left the report stack blocked"
  pass "post-rename publication setup failures release their owned lock"
}

test_publication_lock_release_failures_are_observable() {
  local stack="$TMP_ROOT/release-failure-stack" setup_stack="$TMP_ROOT/setup-release-failure-stack" out status
  out=$(FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" FM_REPORT_LOCK_TEST_RELEASE_FAILURE=1 \
    "$SCRIPT" render 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "synthetic publication lock release failure was hidden"
  assert_contains "$out" "synthetic report publication lock release failure" \
    "normal publication lock release failure was not observable"
  rm -rf "$stack/.publish.lock"

  out=$(FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$setup_stack" \
    FM_REPORT_LOCK_TEST_SETUP_FAILURE=1 FM_REPORT_LOCK_TEST_RELEASE_FAILURE=1 \
    "$SCRIPT" render 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "combined setup and release failure unexpectedly succeeded"
  assert_contains "$out" "synthetic report publication lock setup failure" \
    "release failure replaced the primary setup error"
  assert_contains "$out" "publication lock release also failed" \
    "secondary setup-cleanup release failure was hidden"
  rm -rf "$setup_stack/.publish.lock"
  pass "publication lock release failures remain observable without replacing primary errors"
}

test_previous_generation_is_recovered_for_readers() {
  local id=report-crash-recovery-k2 entry destination report_id cohort previous transaction json
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Crash-safe report."
  run_stack publish "$id" >/dev/null || fail "crash-recovery report failed to publish"
  entry=$(run_stack path "$id")
  destination=$(dirname "$entry")
  report_id=$(basename "$destination")
  cohort=$(basename "$(dirname "$destination")")
  previous="$STACK/entries/.$report_id.previous"
  transaction="$STACK/entries/.$report_id.transaction"
  mv "$destination" "$previous"
  printf '{"schemaVersion":2,"reportId":"%s","destinationCohort":"%s","previousCohort":"%s"}\n' \
    "$report_id" "$cohort" "$cohort" > "$transaction"

  json=$(run_stack list --json) || fail "report list did not recover the previous generation"
  printf '%s\n' "$json" | grep -F '"taskId": "report-crash-recovery-k2"' >/dev/null \
    || fail "recovered previous generation was absent from report inventory"
  assert_present "$destination/report.html" "reader recovery did not restore the durable report entry"
  assert_absent "$previous" "reader recovery retained the hidden previous generation"
  assert_absent "$transaction" "reader recovery retained the completed report transaction"
  entry=$(run_stack path "$id") || fail "report path did not resolve after generation recovery"
  assert_present "$entry" "recovered report path is missing"
  pass "report readers recover crash-interrupted generation swaps"
}

test_replacement_transaction_recovery_restores_entry_and_index() {
  local id=report-replacement-transaction-k2b entry destination report_id cohort previous transaction staged json
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Original transaction generation."
  run_stack publish "$id" >/dev/null || fail "replacement transaction precondition failed"
  entry=$(run_stack path "$id")
  destination=$(dirname "$entry")
  report_id=$(basename "$destination")
  cohort=$(basename "$(dirname "$destination")")
  previous="$STACK/entries/.$report_id.previous"
  transaction="$STACK/entries/.$report_id.transaction"
  staged="$STACK/entries/.$report_id.999.tmp"
  mv "$destination" "$previous"
  cp -R "$previous" "$destination"
  sed -i.bak 's/Original transaction generation/Unindexed replacement generation/' "$destination/report.md"
  rm -f "$destination/report.md.bak"
  mkdir -p "$staged"
  printf 'stale index\n' > "$STACK/index.html"
  printf '{"schemaVersion":2,"reportId":"%s","destinationCohort":"%s","previousCohort":"%s"}\n' \
    "$report_id" "$cohort" "$cohort" > "$transaction"

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
  local id=report-first-transaction-k2c entry destination report_id cohort transaction json
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Uncommitted first publication."
  run_stack publish "$id" >/dev/null || fail "first-publication transaction precondition failed"
  entry=$(run_stack path "$id")
  destination=$(dirname "$entry")
  report_id=$(basename "$destination")
  cohort=$(basename "$(dirname "$destination")")
  transaction="$STACK/entries/.$report_id.transaction"
  printf 'stale index\n' > "$STACK/index.html"
  printf '{"schemaVersion":2,"reportId":"%s","destinationCohort":"%s","previousCohort":null}\n' \
    "$report_id" "$cohort" > "$transaction"

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

test_pre_rename_transaction_recovery_keeps_previous_generation() {
  local id=report-pre-rename-recovery-k2u entry destination report_id cohort destination_cohort transaction staged json
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Pre-rename crash generation."
  run_stack publish "$id" >/dev/null || fail "pre-rename transaction precondition failed"
  entry=$(run_stack path "$id")
  destination=$(dirname "$entry")
  report_id=$(basename "$destination")
  cohort=$(basename "$(dirname "$destination")")
  destination_cohort="cohort-$((${cohort#cohort-} + 300000))"
  transaction="$STACK/entries/.$report_id.transaction"
  staged="$STACK/entries/.$report_id.999.tmp"
  mkdir -p "$staged"
  printf 'stale index\n' > "$STACK/index.html"
  printf '{"schemaVersion":2,"reportId":"%s","destinationCohort":"%s","previousCohort":"%s"}\n' \
    "$report_id" "$destination_cohort" "$cohort" > "$transaction"

  json=$(run_stack list --json) || fail "report list did not recover a pre-rename report transaction"
  printf '%s\n' "$json" | grep -F '"taskId": "report-pre-rename-recovery-k2u"' >/dev/null \
    || fail "pre-rename recovery lost the intact previous generation"
  assert_present "$destination/report.html" "pre-rename recovery displaced the intact previous generation"
  assert_absent "$STACK/entries/$destination_cohort/$report_id" "pre-rename recovery fabricated a destination generation"
  assert_absent "$transaction" "pre-rename recovery retained its transaction marker"
  assert_absent "$staged" "pre-rename recovery retained transaction staging"
  assert_no_grep 'stale index' "$STACK/index.html" "pre-rename recovery did not rebuild the report index"
  pass "report recovery keeps the intact previous generation when publication never started"
}

test_transaction_recovery_fails_when_every_generation_is_lost() {
  local id=report-lost-generations-k2v entry destination report_id cohort destination_cohort transaction out status
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Lost generations."
  run_stack publish "$id" >/dev/null || fail "lost-generation precondition failed"
  entry=$(run_stack path "$id")
  destination=$(dirname "$entry")
  report_id=$(basename "$destination")
  cohort=$(basename "$(dirname "$destination")")
  destination_cohort="cohort-$((${cohort#cohort-} + 300000))"
  transaction="$STACK/entries/.$report_id.transaction"
  rm -rf "$destination"
  printf '{"schemaVersion":2,"reportId":"%s","destinationCohort":"%s","previousCohort":"%s"}\n' \
    "$report_id" "$destination_cohort" "$cohort" > "$transaction"

  if out=$(run_stack list --json 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "report recovery accepted a transaction with no surviving generation"
  assert_contains "$out" "lost both generations" "lost-generation refusal was unclear"
  assert_present "$transaction" "failed lost-generation recovery cleared its transaction marker"
  rm -f "$transaction"
  pass "report recovery still fails closed when every generation is lost"
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

test_completed_reports_prune_after_minimum_age() {
  local old_id=report-retention-old-k2d fresh_id=report-retention-fresh-k2e old_entry fresh_entry
  write_task "$old_id" ship
  write_required_report "$HOME_DIR/data/$old_id/completion.md" "Expired report content."
  run_stack publish "$old_id" >/dev/null || fail "expired retention precondition publication failed"
  old_entry=$(run_stack path "$old_id") || fail "expired retention precondition path failed"
  write_task "$fresh_id" ship
  write_required_report "$HOME_DIR/data/$fresh_id/completion.md" "Fresh report content."
  run_stack publish "$fresh_id" >/dev/null || fail "fresh retention precondition publication failed"
  fresh_entry=$(run_stack path "$fresh_id") || fail "fresh retention precondition path failed"
  old_entry=$(expire_report_entry "$old_entry") || fail "expired retention fixture could not be aged"
  run_stack render >/dev/null || fail "report retention sweep failed"
  assert_absent "$(dirname "$old_entry")" "expired completed report entry was not pruned"
  assert_present "$fresh_entry" "fresh completed report was pruned"
  assert_no_grep 'Expired report content' "$STACK/index.html" "report index retained an expired completed entry"
  assert_grep 'Fresh report content' "$STACK/index.html" "report index lost the fresh completed entry"
  pass "report stack prunes completed entries after their minimum age"
}

test_retention_binds_manifests_to_entry_directories() {
  local old_id=report-retention-mismatch-old-k2g fresh_id=report-retention-mismatch-fresh-k2h old_entry fresh_entry manifest temp out status fresh_report_id
  write_task "$old_id" ship
  write_required_report "$HOME_DIR/data/$old_id/completion.md" "Expired mismatched report."
  run_stack publish "$old_id" >/dev/null || fail "mismatched retention old publication failed"
  old_entry=$(run_stack path "$old_id") || fail "mismatched retention old path failed"
  write_task "$fresh_id" ship
  write_required_report "$HOME_DIR/data/$fresh_id/completion.md" "Fresh protected report."
  run_stack publish "$fresh_id" >/dev/null || fail "mismatched retention fresh publication failed"
  fresh_entry=$(run_stack path "$fresh_id") || fail "mismatched retention fresh path failed"
  manifest="$(dirname "$old_entry")/manifest.json"
  fresh_report_id=$(basename "$(dirname "$fresh_entry")")
  temp="$manifest.tmp"
  sed -e "s/\"reportId\": \"[^\"]*\"/\"reportId\": \"$fresh_report_id\"/" "$manifest" > "$temp"
  mv "$temp" "$manifest"
  if out=$(run_stack prune --force 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "retention accepted a manifest bound to another entry"
  assert_contains "$out" "report manifest identity mismatch" "retention mismatch refusal was unclear"
  assert_present "$old_entry" "retention mismatch deleted the enclosing expired entry"
  assert_present "$fresh_entry" "retention mismatch deleted the fresh entry named by the manifest"
  rm -rf "$(dirname "$old_entry")"
  pass "report retention binds every manifest to its enclosing entry"
}

test_watcher_periodically_owns_idle_report_retention() {
  local old_id=report-retention-watch-old-k2i fresh_id=report-retention-watch-fresh-k2j old_entry fresh_entry wait_seconds
  write_task "$old_id" ship
  write_required_report "$HOME_DIR/data/$old_id/completion.md" "Watcher-expired report."
  run_stack publish "$old_id" >/dev/null || fail "watch retention old publication failed"
  old_entry=$(run_stack path "$old_id") || fail "watch retention old path failed"
  write_task "$fresh_id" ship
  write_required_report "$HOME_DIR/data/$fresh_id/completion.md" "Watcher-fresh report."
  run_stack publish "$fresh_id" >/dev/null || fail "watch retention fresh publication failed"
  fresh_entry=$(run_stack path "$fresh_id") || fail "watch retention fresh path failed"
  old_entry=$(expire_report_entry "$old_entry") || fail "watcher retention fixture could not be aged"
  wait_seconds=$(fm_test_load_scaled_timeout_seconds 30 150)
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=86400 FM_REPORT_RETENTION_TIMEOUT="$wait_seconds" bash -c '
      . "$1/bin/fm-watch.sh"
      prune_reports_if_due
      prune_reports_if_due
    ' _ "$ROOT" || fail "watcher-owned report retention failed"
  assert_absent "$(dirname "$old_entry")" "watcher-owned retention kept an expired report"
  assert_present "$fresh_entry" "watcher-owned retention removed a fresh report"
  assert_present "$HOME_DIR/state/.last-report-retention" "watcher-owned retention did not persist its cadence"
  pass "watcher supervision periodically owns idle report retention"
}

write_retention_scale_fixture() {
  local stack=$1 reports=$2 cohorts=$3 index_mode=${4:-valid}
  node - "$stack" "$reports" "$cohorts" "$index_mode" <<'NODE'
const fs = require("fs");
const path = require("path");
const [stack, reportsText, cohortsText, indexMode] = process.argv.slice(2);
const reports = Number(reportsText);
const cohorts = Number(cohortsText);
const retentionMs = 30 * 24 * 60 * 60 * 1000;
const firstDeadline = Math.ceil((Date.now() + 17 * 24 * 60 * 60 * 1000) / 300_000) * 300_000;
const cohortNames = [];
fs.mkdirSync(path.join(stack, "entries"), { recursive: true });
for (let index = 0; index < cohorts; index += 1) {
  const cohort = `cohort-${firstDeadline + index * 300_000}`;
  cohortNames.push(cohort);
  fs.mkdirSync(path.join(stack, "entries", cohort));
}
for (let index = 0; index < reports; index += 1) {
  const cohort = cohortNames[index % cohorts];
  const deadline = Number(cohort.slice("cohort-".length));
  const completedAt = new Date(deadline - retentionMs - 60_000).toISOString();
  const reportId = `noop-report-${index}`;
  const reportRoot = path.join(stack, "entries", cohort, reportId);
  fs.mkdirSync(reportRoot);
  fs.writeFileSync(path.join(reportRoot, "manifest.json"), `${JSON.stringify({
    schemaVersion: 1,
    reportId,
    taskId: reportId,
    title: reportId,
    summary: reportId,
    completedAt,
    retentionCohort: cohort,
    kind: "ship",
    project: "example",
    harness: "codex",
  })}\n`);
}
const policy = { schemaVersion: 1, generation: "fixture", cutoffMs: Date.now() - retentionMs };
fs.writeFileSync(
  path.join(stack, ".retention-policy.js"),
  `window.firstmateRetentionPolicy=${JSON.stringify(policy)};\n`,
);
if (indexMode === "corrupt") {
  fs.writeFileSync(path.join(stack, "index.html"), "corrupt index authority\n");
} else {
  const authority = { ...policy };
  if (indexMode === "stale") authority.generation = "stale-fixture";
  if (indexMode === "cutoff") authority.cutoffMs += 1;
  fs.writeFileSync(
    path.join(stack, "index.html"),
    `<!-- firstmate-retention ${JSON.stringify(authority)} -->\nexisting index\n`,
  );
}
NODE
}

write_report_stack_mutant() {
  local destination_root=$1 boundary=$2 replacement=$3
  mkdir -p "$destination_root/bin"
  cp "$ROOT/bin/fm-contained-read.py" "$destination_root/bin/fm-contained-read.py"
  cp "$ROOT/bin/fm-markdown-structure.cjs" "$destination_root/bin/fm-markdown-structure.cjs"
  node - "$SCRIPT" "$destination_root/bin/fm-report-stack.mjs" "$boundary" "$replacement" <<'NODE'
const fs = require("fs");
const [sourceFile, destinationFile, boundary, replacement] = process.argv.slice(2);
const source = fs.readFileSync(sourceFile, "utf8");
if (source.split(boundary).length !== 2) throw new Error(`could not isolate admission predicate: ${boundary}`);
fs.writeFileSync(destinationFile, source.replace(boundary, replacement));
NODE
  chmod +x "$destination_root/bin/fm-report-stack.mjs" "$destination_root/bin/fm-contained-read.py"
}

write_contained_helper_mutant() {
  local destination_root=$1 boundary=$2 replacement=$3
  mkdir -p "$destination_root/bin"
  cp "$SCRIPT" "$destination_root/bin/fm-report-stack.mjs"
  cp "$ROOT/bin/fm-markdown-structure.cjs" "$destination_root/bin/fm-markdown-structure.cjs"
  node - "$ROOT/bin/fm-contained-read.py" "$destination_root/bin/fm-contained-read.py" "$boundary" "$replacement" <<'NODE'
const fs = require("fs");
const [sourceFile, destinationFile, boundary, replacement] = process.argv.slice(2);
const source = fs.readFileSync(sourceFile, "utf8");
const start = source.indexOf("def command_quarantine_owned_entry_fd(arguments):");
const end = source.indexOf("\n\ndef ensure_child_directory", start);
const section = source.slice(start, end);
if (start < 0 || end < 0 || section.split(boundary).length !== 2) {
  throw new Error(`could not isolate quarantine predicate: ${boundary}`);
}
fs.writeFileSync(destinationFile, source.slice(0, start) + section.replace(boundary, replacement) + source.slice(end));
NODE
  chmod +x "$destination_root/bin/fm-report-stack.mjs" "$destination_root/bin/fm-contained-read.py"
}

assert_valid_fresh_retention_attempt() {
  node -e '
    const fs = require("fs");
    const record = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const now = Date.now();
    if (record.schemaVersion !== 1 || !Number.isSafeInteger(record.attemptedAtMs)
      || record.attemptedAtMs < 0 || record.attemptedAtMs > now + 60000
      || now - record.attemptedAtMs >= 3600000) process.exit(1);
  ' "$1"
}

test_noop_retention_skips_helpers_and_publication_lock_at_scale() {
  local fixture="$TMP_ROOT/retention-noop-fixture" baseline_stack="$TMP_ROOT/retention-noop-baseline-stack"
  local target_stack="$TMP_ROOT/retention-noop-target-stack" stale_stack="$TMP_ROOT/retention-noop-stale-stack"
  local cutoff_stack="$TMP_ROOT/retention-noop-cutoff-stack" corrupt_stack="$TMP_ROOT/retention-noop-corrupt-stack"
  local cutoff_mutant_stack="$TMP_ROOT/retention-noop-cutoff-mutant-stack"
  local baseline_root="$TMP_ROOT/retention-noop-baseline" cutoff_mutant_root="$TMP_ROOT/retention-noop-cutoff-mutant"
  local helper="$TMP_ROOT/retention-helper-counter" baseline_log="$TMP_ROOT/retention-baseline-helper.log"
  local target_log="$TMP_ROOT/retention-target-helper.log" base=68f014697d0eea733a4e7c0294becff4e76c7bcf
  local baseline_start baseline_end baseline_ms target_start target_end target_ms baseline_helpers target_helpers
  local mutant_output output observed_reports observed_cohorts stack status

  write_retention_scale_fixture "$fixture" 955 656 valid
  cp -R "$fixture" "$baseline_stack"
  cp -R "$fixture" "$target_stack"
  write_retention_scale_fixture "$stale_stack" 1 1 stale
  write_retention_scale_fixture "$cutoff_stack" 1 1 cutoff
  cp -R "$cutoff_stack" "$cutoff_mutant_stack"
  write_retention_scale_fixture "$corrupt_stack" 1 1 corrupt
  mkdir -p "$baseline_root/bin"
  git -C "$ROOT" show "$base:bin/fm-report-stack.mjs" > "$baseline_root/bin/fm-report-stack.mjs" \
    || fail "could not materialize the retention benchmark baseline"
  git -C "$ROOT" show "$base:bin/fm-contained-read.py" > "$baseline_root/bin/fm-contained-read.py" \
    || fail "could not materialize the baseline contained helper"
  git -C "$ROOT" show "$base:bin/fm-markdown-structure.cjs" > "$baseline_root/bin/fm-markdown-structure.cjs" \
    || fail "could not materialize the baseline markdown parser"
  chmod +x "$baseline_root/bin/fm-report-stack.mjs" "$baseline_root/bin/fm-contained-read.py"
  mkdir -p "$cutoff_mutant_root/bin"
  cp "$ROOT/bin/fm-contained-read.py" "$cutoff_mutant_root/bin/fm-contained-read.py"
  cp "$ROOT/bin/fm-markdown-structure.cjs" "$cutoff_mutant_root/bin/fm-markdown-structure.cjs"
  node - "$SCRIPT" "$cutoff_mutant_root/bin/fm-report-stack.mjs" <<'NODE'
const fs = require("fs");
const [sourceFile, destinationFile] = process.argv.slice(2);
const source = fs.readFileSync(sourceFile, "utf8");
const comparison = "indexAuthority.generation !== policy.generation || indexAuthority.cutoffMs !== policy.cutoffMs";
if (source.split(comparison).length !== 2) throw new Error("could not isolate the cutoff-authority comparison");
fs.writeFileSync(destinationFile, source.replace(comparison, "indexAuthority.generation !== policy.generation"));
NODE
  chmod +x "$cutoff_mutant_root/bin/fm-report-stack.mjs" "$cutoff_mutant_root/bin/fm-contained-read.py"
  cat > "$helper" <<'SH'
#!/bin/sh
printf 'helper\n' >> "$FM_REPORT_HELPER_LOG"
exec "$FM_REPORT_REAL_PYTHON" "$@"
SH
  chmod +x "$helper"
  : > "$baseline_log"
  : > "$target_log"

  baseline_start=$(node -e 'process.stdout.write(process.hrtime.bigint().toString())')
  FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$baseline_stack" \
    FM_REPORT_PYTHON="$helper" FM_REPORT_HELPER_LOG="$baseline_log" \
    FM_REPORT_REAL_PYTHON="$(command -v python3)" \
    "$baseline_root/bin/fm-report-stack.mjs" prune >/dev/null \
    || fail "955-report/656-cohort baseline retention pass failed"
  baseline_end=$(node -e 'process.stdout.write(process.hrtime.bigint().toString())')

  target_start=$(node -e 'process.stdout.write(process.hrtime.bigint().toString())')
  output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$target_stack" \
    FM_REPORT_PYTHON="$helper" FM_REPORT_HELPER_LOG="$target_log" \
    FM_REPORT_REAL_PYTHON="$(command -v python3)" \
    FM_REPORT_LOCK_TEST_SETUP_FAILURE=1 "$SCRIPT" prune --status) \
    || fail "955-report/656-cohort no-op retention did not complete outside the publication lock"
  target_end=$(node -e 'process.stdout.write(process.hrtime.bigint().toString())')

  baseline_ms=$(( (baseline_end - baseline_start + 999999) / 1000000 ))
  target_ms=$(( (target_end - target_start + 999999) / 1000000 ))
  baseline_helpers=$(wc -l < "$baseline_log" | tr -d ' ')
  target_helpers=$(wc -l < "$target_log" | tr -d ' ')
  assert_contains "$output" '"reason":"no-work"' "scaled no-op retention was not classified as no work"
  assert_contains "$output" '"admitted":false' "valid matching index authority did not take the no-work path"
  [ "$target_helpers" -eq 0 ] || fail "scaled no-op retention launched $target_helpers contained helper processes"
  [ "$baseline_helpers" -ge 955 ] \
    || fail "baseline helper-process evidence observed only $baseline_helpers launches for 955 reports"
  observed_reports=$(find "$target_stack/entries" -mindepth 2 -maxdepth 2 -type d | wc -l | tr -d ' ')
  observed_cohorts=$(find "$target_stack/entries" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  [ "$observed_reports" -eq 955 ] || fail "scaled no-op fixture contained $observed_reports reports instead of 955"
  [ "$observed_cohorts" -eq 656 ] || fail "scaled no-op fixture contained $observed_cohorts cohorts instead of 656"

  for stack in "$stale_stack" "$cutoff_stack" "$corrupt_stack"; do
    if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
      FM_REPORT_LOCK_TEST_SETUP_FAILURE=1 "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
    [ "$status" -ne 0 ] || fail "invalid index authority was accepted as a no-op at $stack"
    assert_contains "$output" "synthetic report publication lock setup failure" \
      "invalid index authority did not reach the admitted publication-lock boundary"
    assert_present "$stack/.retention-attempt.json" "invalid index authority was not admitted before repair"
  done

  mutant_output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$cutoff_mutant_stack" \
    FM_REPORT_LOCK_TEST_SETUP_FAILURE=1 "$cutoff_mutant_root/bin/fm-report-stack.mjs" prune --status) \
    || fail "cutoff-comparison mutant unexpectedly reached the publication lock"
  assert_contains "$mutant_output" '"reason":"no-work"' \
    "deleting the cutoff comparison did not disable the cutoff-only authority guard"

  pass "retention benchmark: base ${baseline_ms}ms/${baseline_helpers} helpers; target ${target_ms}ms/${target_helpers} helpers"
}

test_retention_admission_bounds_total_fleet_attempts_above_current_population() {
  local stack="$TMP_ROOT/retention-admission-stack" outdir="$TMP_ROOT/retention-admission-output"
  local homes="$TMP_ROOT/retention-admission-homes"
  local owner_ready="$TMP_ROOT/retention-admission-owner.ready" owner_proceed="$TMP_ROOT/retention-admission-owner.proceed"
  local waiter_ready="$TMP_ROOT/retention-admission-waiter.ready" waiter_proceed="$TMP_ROOT/retention-admission-waiter.proceed"
  local owner_out="$TMP_ROOT/retention-admission-owner.out" owner_pid state extra admitted skipped index status
  local contenders=24
  local -a pids
  mkdir -p "$stack/entries/cohort-1" "$outdir" "$homes"
  mkfifo "$owner_ready" "$owner_proceed" "$waiter_ready" "$waiter_proceed"
  exec 7<>"$owner_ready"
  exec 8<>"$owner_proceed"
  exec 9<>"$waiter_ready"
  exec 10<>"$waiter_proceed"

  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_LOCK_ACQUIRED_TEST_READY="$owner_ready" FM_REPORT_LOCK_ACQUIRED_TEST_PROCEED="$owner_proceed" \
    "$SCRIPT" render > "$owner_out" 2>&1 &
  owner_pid=$!
  if ! IFS= read -r -t 10 state <&7; then
    kill -TERM "$owner_pid" 2>/dev/null || true
    fail "retention admission positive-control owner did not acquire the publication lock: $(cat "$owner_out")"
  fi
  [ "$state" = "lock-acquired" ] || fail "retention admission owner emitted an unexpected state: $state"

  for index in $(seq 1 "$contenders"); do
    mkdir -p "$homes/$index/state" "$homes/$index/data"
    FM_HOME="$homes/$index" FM_REPORT_STACK_ROOT="$stack" FM_REPORT_RETENTION_INTERVAL=3600 \
      FM_REPORT_LOCK_WAITER_TEST_READY="$waiter_ready" FM_REPORT_LOCK_WAITER_TEST_PROCEED="$waiter_proceed" \
      "$SCRIPT" prune --status > "$outdir/$index.out" 2>&1 &
    pids[index]=$!
  done
  if ! IFS= read -r -t 10 state <&9; then
    printf 'continue\n' >&8
    kill -TERM "${pids[@]}" 2>/dev/null || true
    wait "$owner_pid" 2>/dev/null || true
    fail "none of $contenders scheduled contenders reached the held publication lock"
  fi
  [ "$state" = "lock-observed" ] || fail "retention contender emitted an unexpected lock state: $state"

  skipped=0
  for _ in $(seq 1 200); do
    skipped=$(grep -l '"admitted":false,"reason":"cadence"' "$outdir"/*.out 2>/dev/null | wc -l | tr -d ' ')
    [ "$skipped" -eq $((contenders - 1)) ] && break
    sleep 0.05
  done
  [ "$skipped" -eq $((contenders - 1)) ] \
    || fail "machine-global admission did not reject every non-owner contender (skipped=$skipped)"
  if IFS= read -r -t 1 extra <&9; then
    printf 'continue\n' >&10
    printf 'continue\n' >&8
    fail "more than one retention contender reached the publication lock: $extra"
  fi

  printf 'continue\n' >&10
  printf 'continue\n' >&8
  if wait "$owner_pid"; then status=0; else status=$?; fi
  [ "$status" -eq 0 ] || fail "retention admission positive-control owner failed: $(cat "$owner_out")"
  for index in $(seq 1 "$contenders"); do
    if wait "${pids[index]}"; then status=0; else status=$?; fi
    [ "$status" -eq 0 ] || fail "retention contender $index failed: $(cat "$outdir/$index.out")"
  done
  admitted=$(grep -l '"admitted":true' "$outdir"/*.out | wc -l | tr -d ' ')
  skipped=$(grep -l '"admitted":false,"reason":"cadence"' "$outdir"/*.out | wc -l | tr -d ' ')
  [ "$admitted" -eq 1 ] || fail "global admission allowed $admitted of $contenders contenders"
  [ "$skipped" -eq $((contenders - 1)) ] || fail "global admission skipped $skipped of $contenders contenders"
  [ "$(find "$homes" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" -eq "$contenders" ] \
    || fail "retention admission fixture did not create $contenders distinct Firstmate homes"
  assert_present "$stack/.retention-attempt.json" "global retention admission did not persist its attempt record"
  exec 7>&-; exec 8>&-; exec 9>&-; exec 10>&-
  pass "machine-global admission allows one lock attempt across 24 concurrent homes"
}

test_failed_retention_attempt_is_ineligible_on_the_next_loop() {
  local stack="$TMP_ROOT/retention-failure-cadence-stack" mutant_stack="$TMP_ROOT/retention-failure-mutant-stack"
  local mutant_root="$TMP_ROOT/retention-failure-mutant" first second mutant_first mutant_second status
  write_retention_scale_fixture "$stack" 1 1 valid
  printf 'malformed policy\n' > "$stack/.retention-policy.js"
  cp -R "$stack" "$mutant_stack"
  mkdir -p "$mutant_root/bin"
  cp "$ROOT/bin/fm-contained-read.py" "$mutant_root/bin/fm-contained-read.py"
  cp "$ROOT/bin/fm-markdown-structure.cjs" "$mutant_root/bin/fm-markdown-structure.cjs"
  node - "$SCRIPT" "$mutant_root/bin/fm-report-stack.mjs" <<'NODE'
const fs = require("fs");
const [sourceFile, destinationFile] = process.argv.slice(2);
const source = fs.readFileSync(sourceFile, "utf8");
const start = source.indexOf("function prune(force) {");
const endMarker = "\n}\n\nfunction snapshotTaskArtifacts";
const end = source.indexOf(endMarker, start);
if (start < 0 || end < 0) throw new Error("could not locate scheduled prune admission boundary");
const replacement = `function prune(force) {
  if (!force && !retentionWorkDueWithoutLock()) {
    lastPruneStatus = { pruned: 0, pending: false, admitted: false, reason: "no-work" };
    return;
  }
  validateRetentionConfiguration();
  withLock(() => {});
  if (!force) {
    const admission = claimRetentionAttempt();
    if (!admission.admitted) {
      lastPruneStatus = { pruned: 0, pending: false, admitted: false, reason: "cadence" };
      return;
    }
    fs.closeSync(admission.pinnedRoot.descriptor);
  }
  lastPruneStatus = { ...lastPruneStatus, admitted: true, reason: force ? "forced" : "completed" };
}`;
fs.writeFileSync(destinationFile, source.slice(0, start) + replacement + source.slice(end + 2));
NODE
  chmod +x "$mutant_root/bin/fm-report-stack.mjs" "$mutant_root/bin/fm-contained-read.py"

  if mutant_first=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$mutant_stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 "$mutant_root/bin/fm-report-stack.mjs" prune --status 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "success-only admission mutation unexpectedly completed"
  assert_contains "$mutant_first" "invalid report retention authority" \
    "success-only admission mutation did not fail at the pre-existing policy validation boundary"
  assert_absent "$mutant_stack/.retention-attempt.json" \
    "success-only admission mutation unexpectedly recorded its failed attempt"
  if mutant_second=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$mutant_stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 "$mutant_root/bin/fm-report-stack.mjs" prune --status 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "success-only admission mutation was unexpectedly cadence-blocked"
  assert_contains "$mutant_second" "invalid report retention authority" \
    "immediate-next-loop guard did not expose the success-only admission mutation"

  if first=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "admitted malformed-policy retention attempt unexpectedly succeeded"
  assert_contains "$first" "invalid report retention authority" \
    "retention failure fixture did not reach policy validation under the real publication lock"
  assert_present "$stack/.retention-attempt.json" "failed retention did not persist its pre-lock attempt record"

  second=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 "$SCRIPT" prune --status) \
    || fail "next-loop retention invocation retried the failed lock attempt"
  assert_contains "$second" '"admitted":false,"reason":"cadence"' \
    "failed retention became eligible again on the next watcher-equivalent loop"
  pass "preflight failures claim admission before lock-scoped validation and cadence"
}

test_wrong_type_stack_root_is_root_independently_admitted() {
  local stack="$TMP_ROOT/retention-wrong-root" mutant_stack="$TMP_ROOT/retention-wrong-root-mutant"
  local mutant_root="$TMP_ROOT/retention-wrong-root-mutant-root" first second mutant_first mutant_second status
  printf 'wrong root\n' > "$stack"
  printf 'wrong root mutant\n' > "$mutant_stack"
  write_report_stack_mutant "$mutant_root" \
    'rootAdmission = claimRootIndependentRetentionAttempt()' \
    'rootAdmission = { admitted: true }'

  if first=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "wrong-type stack root unexpectedly completed"
  assert_contains "$first" "report stack root must be a real directory" \
    "wrong-type stack root did not fail after root-independent admission"
  second=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 "$SCRIPT" prune --status) \
    || fail "wrong-type stack root retried instead of observing root-independent cadence"
  assert_contains "$second" '"admitted":false,"reason":"cadence"' \
    "wrong-type stack root remained eligible on the immediate next loop"

  if mutant_first=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$mutant_stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 "$mutant_root/bin/fm-report-stack.mjs" prune --status 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "root-admission mutant unexpectedly completed against a wrong-type root"
  if mutant_second=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$mutant_stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 "$mutant_root/bin/fm-report-stack.mjs" prune --status 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "root-admission mutant was unexpectedly cadence-blocked"
  assert_contains "$mutant_first" "report stack root must be a real directory" \
    "root-admission mutant first failure missed the root boundary"
  assert_contains "$mutant_second" "report stack root must be a real directory" \
    "root-admission mutant immediate retry missed the root boundary"
  pass "wrong-type roots are throttled before root inspection"
}

test_malformed_retention_attempt_is_replaced_before_validation_error() {
  local stack="$TMP_ROOT/retention-malformed-attempt-stack" mutant_stack="$TMP_ROOT/retention-malformed-attempt-mutant-stack"
  local mutant_root="$TMP_ROOT/retention-malformed-attempt-mutant" first second mutant_first mutant_second
  local before_identity after_identity status
  write_retention_scale_fixture "$stack" 1 1 valid
  mkdir "$stack/entries/cohort-1"
  printf 'malformed admission\n' > "$stack/.retention-attempt.json"
  cp -R "$stack" "$mutant_stack"
  before_identity=$(if [ "$(uname)" = Darwin ]; then stat -f '%d:%i' "$stack/.retention-attempt.json"; else stat -c '%d:%i' "$stack/.retention-attempt.json"; fi)
  mkdir -p "$mutant_root/bin"
  cp "$ROOT/bin/fm-contained-read.py" "$mutant_root/bin/fm-contained-read.py"
  cp "$ROOT/bin/fm-markdown-structure.cjs" "$mutant_root/bin/fm-markdown-structure.cjs"
  node - "$SCRIPT" "$mutant_root/bin/fm-report-stack.mjs" <<'NODE'
const fs = require("fs");
const [sourceFile, destinationFile] = process.argv.slice(2);
const source = fs.readFileSync(sourceFile, "utf8");
const boundary = `    if (markerState.kind === "fresh" || markerState.kind === "fallback-fresh") {
      inspectPinnedDirectory(pinnedRoot);`;
const mutation = `    if (markerState.kind === "invalid") throw markerState.error;
    if (markerState.kind === "fresh" || markerState.kind === "fallback-fresh") {
      inspectPinnedDirectory(pinnedRoot);`;
if (source.split(boundary).length !== 2) throw new Error("could not isolate malformed-marker admission ordering");
const rootBoundary = "rootAdmission = claimRootIndependentRetentionAttempt();";
if (source.split(rootBoundary).length !== 2) throw new Error("could not isolate root-independent admission ordering");
fs.writeFileSync(destinationFile, source.replace(rootBoundary, "rootAdmission = { admitted: true };").replace(boundary, mutation));
NODE
  chmod +x "$mutant_root/bin/fm-report-stack.mjs" "$mutant_root/bin/fm-contained-read.py"

  if mutant_first=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$mutant_stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 "$mutant_root/bin/fm-report-stack.mjs" prune --status 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "pre-claim malformed-marker mutation unexpectedly succeeded"
  assert_contains "$mutant_first" "invalid report retention attempt marker" \
    "pre-claim malformed-marker mutation did not fail at admission parsing"
  assert_absent "$mutant_stack/.retention-attempt.claim.json" \
    "pre-claim malformed-marker mutation unexpectedly installed a durable claim"
  if mutant_second=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$mutant_stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 "$mutant_root/bin/fm-report-stack.mjs" prune --status 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -ne 0 ] || fail "pre-claim malformed-marker mutation was unexpectedly cadence-blocked"
  assert_contains "$mutant_second" "invalid report retention attempt marker" \
    "immediate-next-loop guard did not expose the pre-claim malformed-marker mutation"

  if first=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "malformed retention attempt unexpectedly completed"
  assert_contains "$first" "invalid report retention attempt marker" \
    "malformed retention attempt did not surface validation after fresh admission"
  assert_absent "$stack/.retention-attempt.claim.json" "malformed-marker recovery retained its admission claim"
  after_identity=$(if [ "$(uname)" = Darwin ]; then stat -f '%d:%i' "$stack/.retention-attempt.json"; else stat -c '%d:%i' "$stack/.retention-attempt.json"; fi)
  [ "$after_identity" != "$before_identity" ] \
    || fail "malformed retention attempt was not quarantined by observed inode identity"
  node -e '
    const fs = require("fs");
    const record = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    if (record.schemaVersion !== 1 || !Number.isSafeInteger(record.attemptedAtMs)) process.exit(1);
  ' "$stack/.retention-attempt.json" \
    || fail "malformed retention attempt was not replaced by a valid fresh admission"

  second=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 "$SCRIPT" prune --status) \
    || fail "fresh admission did not suppress the immediate malformed-marker retry"
  assert_contains "$second" '"admitted":false,"reason":"cadence"' \
    "malformed-marker validation failure remained eligible on the immediate next loop"
  pass "malformed admission markers are inode-quarantined before validation surfaces"
}

test_retention_invalid_marker_quarantine_is_inode_owned() {
  local stack="$TMP_ROOT/retention-invalid-marker-race-stack" saved="$TMP_ROOT/retention-invalid-marker-race-saved"
  local ready="$TMP_ROOT/retention-invalid-marker-race.ready" proceed="$TMP_ROOT/retention-invalid-marker-race.proceed"
  local output="$TMP_ROOT/retention-invalid-marker-race.out" replacement_identity after_identity state pid status
  write_retention_scale_fixture "$stack" 1 1 valid
  mkdir "$stack/entries/cohort-1"
  printf 'observed invalid admission\n' > "$stack/.retention-attempt.json"
  mkfifo "$ready" "$proceed"
  exec 7<>"$ready"
  exec 8<>"$proceed"
  FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 FM_REPORT_RETENTION_INVALID_MARKER_TEST_READY="$ready" \
    FM_REPORT_RETENTION_INVALID_MARKER_TEST_PROCEED="$proceed" \
    "$SCRIPT" prune --status > "$output" 2>&1 &
  pid=$!
  if ! IFS= read -r -t 10 state <&7; then
    kill -TERM "$pid" 2>/dev/null || true
    fail "invalid-marker race did not reach inode-owned quarantine: $(cat "$output")"
  fi
  [ "$state" = "invalid-marker-observed" ] || fail "invalid-marker race emitted an unexpected state: $state"
  mv "$stack/.retention-attempt.json" "$saved"
  # shellcheck disable=SC2016
  node -e '
    const fs = require("fs");
    fs.writeFileSync(process.argv[1], `${JSON.stringify({ schemaVersion: 1, attemptedAtMs: Date.now() })}\n`);
  ' "$stack/.retention-attempt.json"
  replacement_identity=$(if [ "$(uname)" = Darwin ]; then stat -f '%d:%i' "$stack/.retention-attempt.json"; else stat -c '%d:%i' "$stack/.retention-attempt.json"; fi)
  printf 'continue\n' >&8
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -eq 0 ] || fail "invalid-marker inode race did not accept the fresh replacement: $(cat "$output")"
  assert_grep '"admitted":false,"reason":"cadence"' "$output" \
    "invalid-marker inode race did not reject the fresh replacement before further mutation"
  assert_grep "observed invalid admission" "$saved" "invalid-marker quarantine mutated the observed inode after replacement"
  after_identity=$(if [ "$(uname)" = Darwin ]; then stat -f '%d:%i' "$stack/.retention-attempt.json"; else stat -c '%d:%i' "$stack/.retention-attempt.json"; fi)
  [ "$after_identity" = "$replacement_identity" ] \
    || fail "invalid-marker quarantine removed or replaced the unobserved canonical inode"
  assert_absent "$stack/.retention-attempt.claim.json" "invalid-marker inode race retained its admission claim"
  exec 7>&-; exec 8>&-
  pass "invalid admission quarantine preserves a replacement canonical inode"
}

test_retention_admission_recovers_every_marker_path_type() {
  local case_name stack target first second status socket_pid socket_ready probe error
  local -a cases
  cases=(
    marker-nonjson marker-schema marker-negative marker-string marker-symlink marker-directory \
    marker-fifo marker-socket claim-nonjson claim-schema claim-negative claim-string claim-symlink \
    claim-directory claim-fifo claim-socket
  )
  for case_name in character block; do
    probe="$TMP_ROOT/retention-admission-$case_name-probe"
    error="$TMP_ROOT/retention-admission-$case_name-probe.err"
    if python3 - "$probe" "$case_name" 2>"$error" <<'PY'
import os
import stat
import sys

mode = stat.S_IFCHR if sys.argv[2] == "character" else stat.S_IFBLK
os.mknod(sys.argv[1], mode | 0o600, os.makedev(0, 0))
PY
    then
      rm -f "$probe"
      cases+=("marker-$case_name" "claim-$case_name")
    else
      printf 'ok - %s device admission fixture unavailable on this platform: %s\n' \
        "$case_name" "$(tr '\n' ' ' < "$error")"
    fi
  done
  for case_name in "${cases[@]}"; do
    socket_pid=
    stack="$TMP_ROOT/retention-admission-type-$case_name"
    write_retention_scale_fixture "$stack" 1 1 valid
    mkdir "$stack/entries/cohort-1"
    target="$stack/.retention-attempt.json"
    if [[ "$case_name" = claim-* ]]; then
      printf '{"schemaVersion":1,"attemptedAtMs":0}\n' > "$target"
      target="$stack/.retention-attempt.claim.json"
    fi
    case "$case_name" in
      *-nonjson) printf 'not json\n' > "$target" ;;
      *-schema) printf '{"schemaVersion":2,"attemptedAtMs":0}\n' > "$target" ;;
      *-negative) printf '{"schemaVersion":1,"attemptedAtMs":-1}\n' > "$target" ;;
      *-string) printf '{"schemaVersion":1,"attemptedAtMs":"1"}\n' > "$target" ;;
      *-symlink) ln -s missing-admission-target "$target" ;;
      *-directory) mkdir "$target"; printf 'payload\n' > "$target/child" ;;
      *-fifo) mkfifo "$target" ;;
      *-socket)
        socket_ready="$TMP_ROOT/retention-admission-type-$case_name.socket-ready"
        python3 - "$target" "$socket_ready" <<'PY' &
import os
import socket
import sys
import time

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
directory, name = os.path.split(sys.argv[1])
os.chdir(directory)
server.bind(name)
with open(sys.argv[2], "x", encoding="utf-8") as ready:
    ready.write("ready\n")
time.sleep(60)
PY
        socket_pid=$!
        for _ in $(seq 1 100); do
          [ -e "$socket_ready" ] && break
          sleep 0.01
        done
        [ -e "$socket_ready" ] || fail "$case_name socket fixture did not become ready"
        ;;
      *-character) python3 -c 'import os,stat,sys;os.mknod(sys.argv[1],stat.S_IFCHR|0o600,os.makedev(0,0))' "$target" ;;
      *-block) python3 -c 'import os,stat,sys;os.mknod(sys.argv[1],stat.S_IFBLK|0o600,os.makedev(0,0))' "$target" ;;
    esac
    if [[ "$case_name" = claim-* ]]; then
      node -e '
        const fs = require("fs");
        const old = new Date(Date.now() - 7200000);
        if (fs.lstatSync(process.argv[1]).isSymbolicLink()) fs.lutimesSync(process.argv[1], old, old);
        else fs.utimesSync(process.argv[1], old, old);
      ' "$target"
    fi

    if first=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
      FM_REPORT_RETENTION_INTERVAL=3600 "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
    [ "$status" -ne 0 ] || fail "$case_name admission corruption unexpectedly completed"
    if [ -n "$socket_pid" ]; then
      kill -TERM "$socket_pid" 2>/dev/null || true
      wait "$socket_pid" 2>/dev/null || true
    fi
    if [[ "$case_name" = marker-* ]]; then
      assert_contains "$first" "report retention attempt marker" "$case_name did not fail at the canonical marker boundary"
    else
      assert_contains "$first" "report retention admission claim" "$case_name did not fail at the claim boundary"
    fi
    assert_valid_fresh_retention_attempt "$stack/.retention-attempt.json" \
      || fail "$case_name did not leave a valid fresh canonical admission"
    assert_absent "$stack/.retention-attempt.claim.json" "$case_name retained its invalid claim path"
    [ "$(find "$stack" -mindepth 1 -maxdepth 1 -name '..retention-attempt*.invalid.*' | wc -l | tr -d ' ')" -ge 1 ] \
      || fail "$case_name did not persist its invalid-object quarantine"
    second=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
      FM_REPORT_RETENTION_INTERVAL=3600 "$SCRIPT" prune --status) \
      || fail "$case_name retried immediately after its validation failure"
    assert_contains "$second" '"admitted":false,"reason":"cadence"' \
      "$case_name remained eligible on the immediate next loop"
  done
  pass "all creatable operating-system admission entry types are uniformly quarantined"
}

test_valid_retention_claim_release_does_not_persist_quarantine() {
  local stack="$TMP_ROOT/retention-valid-claim-release-stack" output
  mkdir -p "$stack/entries/cohort-1"
  printf '{"schemaVersion":1,"attemptedAtMs":0}\n' > "$stack/.retention-attempt.claim.json"
  output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 "$SCRIPT" prune --status) \
    || fail "valid retention claim release failed"
  assert_contains "$output" '"admitted":true,"reason":"completed"' \
    "valid retention claim did not complete its admitted pass"
  assert_absent "$stack/.retention-attempt.claim.json" "valid retention claim remained canonical after release"
  [ "$(find "$stack" -mindepth 1 -maxdepth 1 \( -name '..retention-attempt.claim.json.released.*' -o -name '..retention-attempt.claim.json.expired.*' \) | wc -l | tr -d ' ')" -eq 0 ] \
    || fail "valid retention claim release leaked persistent quarantine"
  pass "valid claim release removes its inode-owned file"
}

test_stale_claim_quarantine_failure_still_installs_admission() {
  local stack="$TMP_ROOT/retention-claim-quarantine-failure-stack"
  local python_wrapper="$TMP_ROOT/retention-claim-quarantine-python" first second status
  write_retention_scale_fixture "$stack" 1 1 valid
  mkdir "$stack/entries/cohort-1"
  printf '{"schemaVersion":1,"attemptedAtMs":0}\n' > "$stack/.retention-attempt.json"
  mkdir "$stack/.retention-attempt.claim.json"
  printf 'claim payload\n' > "$stack/.retention-attempt.claim.json/child"
  node -e 'const fs=require("fs");const old=new Date(Date.now()-7200000);fs.utimesSync(process.argv[1],old,old)' \
    "$stack/.retention-attempt.claim.json"
  cat > "$python_wrapper" <<'SH'
#!/bin/sh
if [ "${2:-}" = quarantine-owned-entry-fd ] && [ "${3:-}" = .retention-attempt.claim.json ]; then
  find "$FM_REPORT_RETENTION_ADMISSION_DIR" -mindepth 1 -maxdepth 1 -type f \
    -name '.firstmate-report-retention-*' -print -quit | grep -q . || {
    echo 'root-independent admission missing before stale claim quarantine' >&2
    exit 1
  }
  node -e '
    const record=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    if (record.schemaVersion !== 1 || !Number.isSafeInteger(record.attemptedAtMs)) process.exit(1);
  ' "$FM_REPORT_STACK_ROOT/.retention-attempt.json" || {
    echo 'canonical admission missing before stale claim quarantine' >&2
    exit 1
  }
  echo 'synthetic stale claim quarantine failure' >&2
  exit 1
fi
exec "$FM_REAL_PYTHON" "$@"
SH
  chmod +x "$python_wrapper"

  if first=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 FM_REPORT_PYTHON="$python_wrapper" \
    FM_REAL_PYTHON="$(command -v python3)" "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "stale-claim quarantine failure unexpectedly completed"
  assert_contains "$first" "synthetic stale claim quarantine failure" \
    "stale-claim quarantine failure did not reach its actual cleanup boundary"
  assert_valid_fresh_retention_attempt "$stack/.retention-attempt.json" \
    || fail "stale-claim quarantine failure surfaced before installing canonical admission"
  assert_present "$stack/.retention-attempt.claim.json" \
    "stale-claim quarantine failure unexpectedly mutated the observed claim"
  second=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 "$SCRIPT" prune --status) \
    || fail "stale-claim quarantine failure retried on the immediate next loop"
  assert_contains "$second" '"admitted":false,"reason":"cadence"' \
    "canonical admission did not suppress retry after claim cleanup failed"
  pass "canonical admission precedes stale-claim quarantine failure"
}

test_retention_future_timestamp_uses_bounded_file_age_fallback() {
  local stack="$TMP_ROOT/retention-future-attempt-stack" near_stack="$TMP_ROOT/retention-near-future-attempt-stack"
  local first second third before after status
  write_retention_scale_fixture "$stack" 1 1 valid
  mkdir "$stack/entries/cohort-1"
  # shellcheck disable=SC2016
  node -e '
    const fs = require("fs");
    fs.writeFileSync(process.argv[1], `${JSON.stringify({ schemaVersion: 1, attemptedAtMs: Date.now() + 86400000 })}\n`);
  ' "$stack/.retention-attempt.json"
  before=$(cat "$stack/.retention-attempt.json")
  first=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=60 "$SCRIPT" prune --status) \
    || fail "fresh file-age fallback rejected a recently written future timestamp"
  assert_contains "$first" '"admitted":false,"reason":"cadence"' \
    "recent future timestamp did not use bounded file-age fallback"
  [ "$(cat "$stack/.retention-attempt.json")" = "$before" ] \
    || fail "file-age fallback mutated a recently written future timestamp"
  node -e 'const fs=require("fs"); const old=new Date(Date.now()-7200000); fs.utimesSync(process.argv[1], old, old)' \
    "$stack/.retention-attempt.json"
  if second=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=1 "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "aged future timestamp suppressed retention indefinitely"
  assert_contains "$second" "invalid report retention attempt marker" \
    "aged future timestamp did not reach timestamp validation"
  assert_valid_fresh_retention_attempt "$stack/.retention-attempt.json" \
    || fail "aged future timestamp was not replaced with fresh admission"
  third=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 "$SCRIPT" prune --status) \
    || fail "recovered future timestamp retried immediately"
  assert_contains "$third" '"admitted":false,"reason":"cadence"' \
    "future-timestamp validation failure remained immediately eligible"

  write_retention_scale_fixture "$near_stack" 1 1 valid
  mkdir "$near_stack/entries/cohort-1"
  # shellcheck disable=SC2016
  node -e '
    const fs = require("fs");
    fs.writeFileSync(process.argv[1], `${JSON.stringify({ schemaVersion: 1, attemptedAtMs: Date.now() + 30000 })}\n`);
  ' "$near_stack/.retention-attempt.json"
  before=$(cat "$near_stack/.retention-attempt.json")
  first=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$near_stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 "$SCRIPT" prune --status) \
    || fail "bounded forward clock skew was rejected"
  assert_contains "$first" '"admitted":false,"reason":"cadence"' \
    "bounded forward clock skew was not admitted as fresh"
  after=$(cat "$near_stack/.retention-attempt.json")
  [ "$after" = "$before" ] || fail "bounded forward clock skew mutated a valid marker"
  pass "future timestamps recover after bounded file-age fallback"
}

test_retention_admission_record_predicate_mutations() {
  local label boundary replacement expected control_expected stack control_stack mutant_root output control status
  while IFS='|' read -r label boundary replacement expected control_expected; do
    [ -n "$label" ] || continue
    stack="$TMP_ROOT/retention-record-mutant-$label-stack"
    control_stack="$TMP_ROOT/retention-record-control-$label-stack"
    mutant_root="$TMP_ROOT/retention-record-mutant-$label"
    write_retention_scale_fixture "$control_stack" 1 1 valid
    mkdir "$control_stack/entries/cohort-1"
    case "$label" in
      schema) node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({schemaVersion:2,attemptedAtMs:Date.now()})+"\n")' "$control_stack/.retention-attempt.json" ;;
      integer) node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({schemaVersion:1,attemptedAtMs:String(Date.now())})+"\n")' "$control_stack/.retention-attempt.json" ;;
      negative) printf '{"schemaVersion":1,"attemptedAtMs":-1}\n' > "$control_stack/.retention-attempt.json" ;;
      future) node -e 'const fs=require("fs");fs.writeFileSync(process.argv[1],JSON.stringify({schemaVersion:1,attemptedAtMs:Date.now()+86400000})+"\n");const old=new Date(Date.now()-7200000);fs.utimesSync(process.argv[1],old,old)' "$control_stack/.retention-attempt.json" ;;
      future-mtime) node -e 'const fs=require("fs");fs.writeFileSync(process.argv[1],JSON.stringify({schemaVersion:1,attemptedAtMs:Date.now()+86400000})+"\n");const future=new Date(Date.now()+86400000);fs.utimesSync(process.argv[1],future,future)' "$control_stack/.retention-attempt.json" ;;
      stale-mtime) node -e 'const fs=require("fs");fs.writeFileSync(process.argv[1],JSON.stringify({schemaVersion:1,attemptedAtMs:Date.now()+86400000})+"\n");const old=new Date(Date.now()-7200000);fs.utimesSync(process.argv[1],old,old)' "$control_stack/.retention-attempt.json" ;;
      stale-record) printf '{"schemaVersion":1,"attemptedAtMs":0}\n' > "$control_stack/.retention-attempt.json" ;;
    esac
    cp -R "$control_stack" "$stack"
    if control=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$control_stack" \
      FM_REPORT_RETENTION_INTERVAL=3600 "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
    if [ "$control_expected" = completed ]; then
      [ "$status" -eq 0 ] || fail "$label admission-predicate positive control failed: $control"
      assert_contains "$control" '"admitted":true,"reason":"completed"' \
        "$label admission-predicate positive control did not execute the expected due pass"
    else
      [ "$status" -ne 0 ] || fail "$label admission-predicate positive control accepted invalid state"
      assert_contains "$control" "invalid report retention attempt marker" \
        "$label admission-predicate positive control missed its validation boundary"
    fi
    write_report_stack_mutant "$mutant_root" "$boundary" "$replacement"
    if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
      FM_REPORT_RETENTION_INTERVAL=3600 "$mutant_root/bin/fm-report-stack.mjs" prune --status 2>&1); then status=0; else status=$?; fi
    [ "$status" -eq 0 ] || fail "$label admission-predicate mutant was not isolated: $output"
    assert_contains "$output" "$expected" "$label admission-predicate deletion did not bypass its boundary"
  done <<'CASES'
schema|schemaGuard = record?.schemaVersion === 1|schemaGuard = true|"reason":"cadence"|invalid
integer|timestampIntegralGuard = Number.isSafeInteger(record?.attemptedAtMs)|timestampIntegralGuard = true|"reason":"cadence"|invalid
negative|timestampNonnegativeGuard = record?.attemptedAtMs >= 0|timestampNonnegativeGuard = true|"reason":"completed"|invalid
future|timestampWithinSkewGuard = record.attemptedAtMs <= now + retentionAdmissionClockSkewMs|timestampWithinSkewGuard = true|"reason":"cadence"|invalid
future-mtime|fileTimeWithinSkewGuard = fileAgeMs >= -retentionAdmissionClockSkewMs|fileTimeWithinSkewGuard = true|"reason":"cadence"|invalid
stale-mtime|fileAgeWithinIntervalGuard = fileAgeMs < retentionAdmissionIntervalMs()|fileAgeWithinIntervalGuard = true|"reason":"cadence"|invalid
stale-record|ageFreshGuard = ageMs < retentionAdmissionIntervalMs()|ageFreshGuard = true|"reason":"cadence"|completed
CASES
  pass "record schema, timestamp, skew, fallback, and freshness mutants are detected"
}

test_invalid_claim_file_age_fallback_mutation() {
  local control_stack="$TMP_ROOT/retention-invalid-claim-fallback-control-stack"
  local mutant_stack="$TMP_ROOT/retention-invalid-claim-fallback-mutant-stack"
  local mutant_root="$TMP_ROOT/retention-invalid-claim-fallback-mutant" control mutant status
  write_retention_scale_fixture "$control_stack" 1 1 valid
  mkdir "$control_stack/entries/cohort-1"
  printf '{"schemaVersion":1,"attemptedAtMs":0}\n' > "$control_stack/.retention-attempt.json"
  printf 'partial claim write\n' > "$control_stack/.retention-attempt.claim.json"
  cp -R "$control_stack" "$mutant_stack"
  write_report_stack_mutant "$mutant_root" \
    'fallbackEligibleGuard = error.retentionAttemptFuture || invalidFileAgeFallback' \
    'fallbackEligibleGuard = error.retentionAttemptFuture'

  control=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$control_stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 "$SCRIPT" prune --status) \
    || fail "fresh invalid-claim file-age positive control failed"
  assert_contains "$control" '"admitted":false,"reason":"cadence"' \
    "fresh invalid claim did not bound a partial-write retry by file age"
  if mutant=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$mutant_stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 "$mutant_root/bin/fm-report-stack.mjs" prune --status 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "invalid-claim fallback mutant unexpectedly remained cadence-blocked"
  assert_contains "$mutant" "invalid report retention admission claim" \
    "deleting invalid-claim file-age fallback did not expose the partial-write retry"
  pass "invalid-claim file-age fallback mutation is detected"
}

test_retention_candidate_predicate_mutations() {
  local label boundary replacement mutant_expected implementation stack mutant_root executable ready proceed output state pid status saved next
  while IFS='|' read -r label boundary replacement mutant_expected; do
    for implementation in control mutant; do
      stack="$TMP_ROOT/retention-candidate-$label-$implementation-stack"
      mutant_root="$TMP_ROOT/retention-candidate-$label-mutant"
      write_retention_scale_fixture "$stack" 1 1 valid
      mkdir "$stack/entries/cohort-1"
      executable=$SCRIPT
      if [ "$implementation" = mutant ]; then
        write_report_stack_mutant "$mutant_root" "$boundary" "$replacement"
        executable="$mutant_root/bin/fm-report-stack.mjs"
      fi
      ready="$TMP_ROOT/retention-candidate-$label-$implementation.ready"
      proceed="$TMP_ROOT/retention-candidate-$label-$implementation.proceed"
      output="$TMP_ROOT/retention-candidate-$label-$implementation.out"
      saved="$TMP_ROOT/retention-candidate-$label-$implementation.saved"
      mkfifo "$ready" "$proceed"
      exec 7<>"$ready"
      exec 8<>"$proceed"
      FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
        FM_REPORT_RETENTION_INTERVAL=3600 FM_REPORT_RETENTION_CANDIDATE_TEST_READY="$ready" \
        FM_REPORT_RETENTION_CANDIDATE_TEST_PROCEED="$proceed" \
        "$executable" prune --status > "$output" 2>&1 &
      pid=$!
      if ! IFS= read -r -t 10 state <&7; then
        kill -TERM "$pid" 2>/dev/null || true
        fail "$label $implementation did not reach candidate-marker verification: $(cat "$output")"
      fi
      [ "$state" = "candidate-installed" ] || fail "$label candidate gate emitted an unexpected state: $state"
      if [ "$label" = identity ]; then
        mv "$stack/.retention-attempt.json" "$saved"
        cp "$saved" "$stack/.retention-attempt.json"
      else
        # shellcheck disable=SC2016
        node -e '
          const fs = require("fs");
          const file = process.argv[1];
          const record = JSON.parse(fs.readFileSync(file, "utf8"));
          record.attemptedAtMs += 1;
          fs.writeFileSync(file, `${JSON.stringify(record)}\n`);
        ' "$stack/.retention-attempt.json"
      fi
      printf 'continue\n' >&8
      if wait "$pid"; then status=0; else status=$?; fi
      if [ "$implementation" = control ]; then
        [ "$status" -eq 0 ] || fail "$label candidate positive control failed: $(cat "$output")"
        assert_grep '"admitted":false,"reason":"cadence"' "$output" \
          "$label candidate positive control accepted a changed candidate"
        next=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
          FM_REPORT_RETENTION_INTERVAL=3600 "$SCRIPT" prune --status) \
          || fail "$label candidate rejection was not cadence-stable"
        assert_contains "$next" '"admitted":false,"reason":"cadence"' \
          "$label candidate rejection did not preserve fresh admission"
      else
        if [ "$mutant_expected" = completed ]; then
          [ "$status" -eq 0 ] || fail "$label candidate mutant did not bypass its deleted boundary: $(cat "$output")"
          assert_grep '"admitted":true,"reason":"completed"' "$output" \
            "$label candidate mutant was rejected after bypassing its deleted boundary"
        else
          [ "$status" -ne 0 ] || fail "$label candidate mutant did not reach installed-marker verification"
          assert_grep "report retention attempt marker changed while installing" "$output" \
            "$label candidate mutant did not bypass its deleted boundary"
          assert_valid_fresh_retention_attempt "$stack/.retention-attempt.json" \
            || fail "$label candidate mutant did not restore canonical cadence"
        fi
      fi
      exec 7>&-; exec 8>&-
    done
  done <<'CASES'
identity|candidateIdentityGuard = Boolean(installedCandidate && markerState.observed.dev === installedCandidate.dev && markerState.observed.ino === installedCandidate.ino)|candidateIdentityGuard = true|completed
timestamp|candidateTimestampGuard = markerState.record?.attemptedAtMs === attemptedAtMs|candidateTimestampGuard = true|verification
CASES
  pass "candidate-marker identity and timestamp mutants are detected"
}

test_retention_installed_marker_predicate_mutations() {
  local label boundary replacement implementation stack mutant_root executable ready proceed output state pid status saved next
  while IFS='|' read -r label boundary replacement; do
    for implementation in control mutant; do
      stack="$TMP_ROOT/retention-installed-$label-$implementation-stack"
      mutant_root="$TMP_ROOT/retention-installed-$label-mutant"
      write_retention_scale_fixture "$stack" 1 1 valid
      mkdir "$stack/entries/cohort-1"
      executable=$SCRIPT
      if [ "$implementation" = mutant ]; then
        write_report_stack_mutant "$mutant_root" "$boundary" "$replacement"
        executable="$mutant_root/bin/fm-report-stack.mjs"
      fi
      ready="$TMP_ROOT/retention-installed-$label-$implementation.ready"
      proceed="$TMP_ROOT/retention-installed-$label-$implementation.proceed"
      output="$TMP_ROOT/retention-installed-$label-$implementation.out"
      saved="$TMP_ROOT/retention-installed-$label-$implementation.saved"
      mkfifo "$ready" "$proceed"
      exec 7<>"$ready"
      exec 8<>"$proceed"
      FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
        FM_REPORT_RETENTION_INTERVAL=3600 FM_REPORT_RETENTION_INSTALLED_TEST_READY="$ready" \
        FM_REPORT_RETENTION_INSTALLED_TEST_PROCEED="$proceed" \
        "$executable" prune --status > "$output" 2>&1 &
      pid=$!
      if ! IFS= read -r -t 10 state <&7; then
        kill -TERM "$pid" 2>/dev/null || true
        fail "$label $implementation did not reach installed-marker verification: $(cat "$output")"
      fi
      [ "$state" = "attempt-installed" ] || fail "$label installed-marker gate emitted an unexpected state: $state"
      if [ "$label" = inode ]; then
        mv "$stack/.retention-attempt.json" "$saved"
        cp "$saved" "$stack/.retention-attempt.json"
      else
        printf '{"schemaVersion":1,"attemptedAtMs":0}\n' > "$stack/.retention-attempt.json"
      fi
      printf 'continue\n' >&8
      if wait "$pid"; then status=0; else status=$?; fi
      if [ "$implementation" = control ]; then
        [ "$status" -ne 0 ] || fail "$label installed-marker positive control accepted a changed generation"
        assert_grep "report retention attempt marker changed while installing" "$output" \
          "$label installed-marker positive control missed its verification boundary"
        assert_valid_fresh_retention_attempt "$stack/.retention-attempt.json" \
          || fail "$label installed-marker failure did not restore fresh canonical admission"
        next=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
          FM_REPORT_RETENTION_INTERVAL=3600 "$SCRIPT" prune --status) \
          || fail "$label installed-marker failure retried on the immediate next loop"
        assert_contains "$next" '"admitted":false,"reason":"cadence"' \
          "$label installed-marker failure remained immediately eligible"
      else
        [ "$status" -eq 0 ] || fail "$label installed-marker mutant did not bypass its deleted predicate: $(cat "$output")"
        assert_grep '"admitted":true,"reason":"completed"' "$output" \
          "$label installed-marker mutant was not accepted at the actual admission boundary"
      fi
      exec 7>&-; exec 8>&-
    done
  done <<'CASES'
inode|installedIdentityGuard = `${installed.dev}:${installed.ino}` === `${installation.observed.dev}:${installation.observed.ino}`|installedIdentityGuard = true
timestamp|installedTimestampGuard = installedRecord.attemptedAtMs === attemptedAtMs|installedTimestampGuard = true
CASES
  pass "installed-marker inode and timestamp mutants are detected"
}

test_partial_retention_install_restores_canonical_admission() {
  local stack="$TMP_ROOT/retention-partial-install-stack" first second status
  write_retention_scale_fixture "$stack" 1 1 valid
  mkdir "$stack/entries/cohort-1"
  if first=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 FM_REPORT_RETENTION_PARTIAL_INSTALL_TEST=1 \
    "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "partial retention installation unexpectedly completed"
  assert_contains "$first" "invalid report retention attempt marker" \
    "partial retention installation did not fail at marker verification"
  assert_valid_fresh_retention_attempt "$stack/.retention-attempt.json" \
    || fail "partial retention installation did not restore canonical admission"
  second=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 "$SCRIPT" prune --status) \
    || fail "partial retention installation retried on the immediate next loop"
  assert_contains "$second" '"admitted":false,"reason":"cadence"' \
    "partial retention installation remained immediately eligible"
  pass "partial retention installation restores canonical cadence"
}

test_retention_quarantine_identity_mutation_is_detected() {
  local stack="$TMP_ROOT/retention-quarantine-identity-mutant-stack"
  local mutant_root="$TMP_ROOT/retention-quarantine-identity-mutant" ready proceed output state pid status saved
  local replacement_identity after_identity
  write_retention_scale_fixture "$stack" 1 1 valid
  mkdir "$stack/entries/cohort-1"
  printf 'observed invalid admission\n' > "$stack/.retention-attempt.json"
  write_contained_helper_mutant "$mutant_root" \
    'source_identity_guard = f"{before.st_dev}:{before.st_ino}" == identity' \
    'source_identity_guard = True'
  ready="$TMP_ROOT/retention-quarantine-identity-mutant.ready"
  proceed="$TMP_ROOT/retention-quarantine-identity-mutant.proceed"
  output="$TMP_ROOT/retention-quarantine-identity-mutant.out"
  saved="$TMP_ROOT/retention-quarantine-identity-mutant.saved"
  mkfifo "$ready" "$proceed"
  exec 7<>"$ready"
  exec 8<>"$proceed"
  FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 FM_REPORT_RETENTION_INVALID_MARKER_TEST_READY="$ready" \
    FM_REPORT_RETENTION_INVALID_MARKER_TEST_PROCEED="$proceed" \
    "$mutant_root/bin/fm-report-stack.mjs" prune --status > "$output" 2>&1 &
  pid=$!
  if ! IFS= read -r -t 10 state <&7; then
    kill -TERM "$pid" 2>/dev/null || true
    fail "quarantine identity mutant did not reach the observed-inode boundary: $(cat "$output")"
  fi
  [ "$state" = "invalid-marker-observed" ] || fail "quarantine identity mutant emitted an unexpected state: $state"
  mv "$stack/.retention-attempt.json" "$saved"
  node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({schemaVersion:1,attemptedAtMs:Date.now()})+"\n")' \
    "$stack/.retention-attempt.json"
  replacement_identity=$(if [ "$(uname)" = Darwin ]; then stat -f '%d:%i' "$stack/.retention-attempt.json"; else stat -c '%d:%i' "$stack/.retention-attempt.json"; fi)
  printf 'continue\n' >&8
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "quarantine identity mutant unexpectedly completed without surfacing the original validation"
  after_identity=$(if [ "$(uname)" = Darwin ]; then stat -f '%d:%i' "$stack/.retention-attempt.json"; else stat -c '%d:%i' "$stack/.retention-attempt.json"; fi)
  [ "$after_identity" != "$replacement_identity" ] \
    || fail "deleting quarantine identity ownership did not expose replacement mutation"
  exec 7>&-; exec 8>&-
  pass "quarantine source-inode mutation is detected"
}

test_retention_quarantine_postrename_predicate_mutations() {
  local label boundary replacement implementation stack mutant_root executable output status mismatch next
  while IFS='|' read -r label boundary replacement; do
    for implementation in control mutant; do
      stack="$TMP_ROOT/retention-quarantine-post-$label-$implementation-stack"
      mutant_root="$TMP_ROOT/retention-quarantine-post-$label-mutant"
      write_retention_scale_fixture "$stack" 1 1 valid
      mkdir "$stack/entries/cohort-1"
      printf 'observed invalid admission\n' > "$stack/.retention-attempt.json"
      executable=$SCRIPT
      if [ "$implementation" = mutant ]; then
        write_contained_helper_mutant "$mutant_root" "$boundary" "$replacement"
        executable="$mutant_root/bin/fm-report-stack.mjs"
      fi
      output="$TMP_ROOT/retention-quarantine-post-$label-$implementation.out"
      mismatch="$TMP_ROOT/retention-quarantine-post-$label-$implementation.used"
      if [ "$label" = device ]; then
        if FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
          FM_REPORT_RETENTION_INTERVAL=3600 FM_CONTAINED_QUARANTINE_DEVICE_MISMATCH_TEST="$mismatch" \
          "$executable" prune --status > "$output" 2>&1; then status=0; else status=$?; fi
      else
        if FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
          FM_REPORT_RETENTION_INTERVAL=3600 FM_CONTAINED_QUARANTINE_TYPE_MISMATCH_TEST="$mismatch" \
          "$executable" prune --status > "$output" 2>&1; then status=0; else status=$?; fi
      fi
      [ "$status" -ne 0 ] || fail "$label post-rename $implementation unexpectedly completed"
      if [ "$implementation" = control ]; then
        assert_grep "owned entry generation changed during quarantine" "$output" \
          "$label post-rename positive control missed its predicate boundary"
      else
        assert_grep "report retention attempt marker" "$output" \
          "$label post-rename mutant did not bypass its predicate boundary"
        assert_no_grep "owned entry generation changed during quarantine" "$output" \
          "$label post-rename mutant still fired the deleted predicate"
      fi
      assert_valid_fresh_retention_attempt "$stack/.retention-attempt.json" \
        || fail "$label post-rename $implementation did not restore canonical admission"
      next=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
        FM_REPORT_RETENTION_INTERVAL=3600 "$SCRIPT" prune --status) \
        || fail "$label post-rename $implementation retried immediately"
      assert_contains "$next" '"admitted":false,"reason":"cadence"' \
        "$label post-rename $implementation remained immediately eligible"
    done
  done <<'CASES'
device|not moved_device_guard|False
type|not moved_type_guard|False
CASES

  local ready proceed state pid quarantine saved
  for implementation in control mutant; do
    stack="$TMP_ROOT/retention-quarantine-post-inode-$implementation-stack"
    mutant_root="$TMP_ROOT/retention-quarantine-post-inode-mutant"
    write_retention_scale_fixture "$stack" 1 1 valid
    mkdir "$stack/entries/cohort-1"
    printf 'observed invalid admission\n' > "$stack/.retention-attempt.json"
    executable=$SCRIPT
    if [ "$implementation" = mutant ]; then
      write_contained_helper_mutant "$mutant_root" 'not moved_inode_guard' 'False'
      executable="$mutant_root/bin/fm-report-stack.mjs"
    fi
    ready="$TMP_ROOT/retention-quarantine-post-inode-$implementation.ready"
    proceed="$TMP_ROOT/retention-quarantine-post-inode-$implementation.proceed"
    output="$TMP_ROOT/retention-quarantine-post-inode-$implementation.out"
    saved="$TMP_ROOT/retention-quarantine-post-inode-$implementation.saved"
    FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
      FM_REPORT_RETENTION_INTERVAL=3600 FM_CONTAINED_QUARANTINE_TEST_READY="$ready" \
      FM_CONTAINED_QUARANTINE_TEST_PROCEED="$proceed" \
      "$executable" prune --status > "$output" 2>&1 &
    pid=$!
    for _ in $(seq 1 1000); do
      [ -e "$ready" ] && break
      sleep 0.01
    done
    [ -e "$ready" ] || fail "post-rename inode $implementation did not reach its race boundary"
    quarantine=$(sed -n '1p' "$ready")
    mv "$stack/$quarantine" "$saved"
    node -e 'require("fs").writeFileSync(process.argv[1],JSON.stringify({schemaVersion:1,attemptedAtMs:Date.now()})+"\n")' \
      "$stack/$quarantine"
    : > "$proceed"
    if wait "$pid"; then status=0; else status=$?; fi
    if [ "$implementation" = control ]; then
      [ "$status" -eq 0 ] || fail "post-rename inode positive control failed: $(cat "$output")"
      assert_grep '"admitted":false,"reason":"cadence"' "$output" \
        "post-rename inode positive control did not preserve the replacement"
    else
      [ "$status" -ne 0 ] || fail "post-rename inode mutant did not expose replacement quarantine"
      assert_grep "report retention attempt marker" "$output" \
        "post-rename inode mutant failed for the wrong reason"
    fi
  done
  pass "post-rename device, inode, and type mutants are detected"
}

test_retention_postquarantine_javascript_predicate_mutations() {
  local stack="$TMP_ROOT/retention-postquarantine-absent-mutant-stack"
  local mutant_root="$TMP_ROOT/retention-postquarantine-absent-mutant" output status next
  write_retention_scale_fixture "$stack" 1 1 valid
  mkdir "$stack/entries/cohort-1"
  printf 'observed invalid admission\n' > "$stack/.retention-attempt.json"
  write_report_stack_mutant "$mutant_root" 'pathAbsentGuard = !current' 'pathAbsentGuard = false'
  if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 "$mutant_root/bin/fm-report-stack.mjs" prune --status 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "post-quarantine absence mutant unexpectedly completed"
  assert_contains "$output" "Cannot read properties of undefined" \
    "post-quarantine absence mutant did not fire at the missing-path boundary"
  assert_valid_fresh_retention_attempt "$stack/.retention-attempt.json" \
    || fail "post-quarantine absence mutant did not restore canonical admission"
  next=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 "$SCRIPT" prune --status) \
    || fail "post-quarantine absence mutant retried immediately"
  assert_contains "$next" '"admitted":false,"reason":"cadence"' \
    "post-quarantine absence mutant remained immediately eligible"

  local ready="$TMP_ROOT/retention-postquarantine-identity-mutant.ready"
  local proceed="$TMP_ROOT/retention-postquarantine-identity-mutant.proceed"
  local saved="$TMP_ROOT/retention-postquarantine-identity-mutant.saved" state pid
  stack="$TMP_ROOT/retention-postquarantine-identity-mutant-stack"
  mutant_root="$TMP_ROOT/retention-postquarantine-identity-mutant"
  output="$TMP_ROOT/retention-postquarantine-identity-mutant.out"
  write_retention_scale_fixture "$stack" 1 1 valid
  mkdir "$stack/entries/cohort-1"
  printf 'observed invalid admission\n' > "$stack/.retention-attempt.json"
  # shellcheck disable=SC2016
  write_report_stack_mutant "$mutant_root" \
    'pathIdentityChangedGuard = `${current.dev}:${current.ino}` !== `${observed.dev}:${observed.ino}`' \
    'pathIdentityChangedGuard = false'
  mkfifo "$ready" "$proceed"
  exec 7<>"$ready"
  exec 8<>"$proceed"
  FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 FM_REPORT_RETENTION_INVALID_MARKER_TEST_READY="$ready" \
    FM_REPORT_RETENTION_INVALID_MARKER_TEST_PROCEED="$proceed" \
    "$mutant_root/bin/fm-report-stack.mjs" prune --status > "$output" 2>&1 &
  pid=$!
  if ! IFS= read -r -t 10 state <&7; then
    kill -TERM "$pid" 2>/dev/null || true
    fail "post-quarantine identity mutant did not reach its replacement boundary: $(cat "$output")"
  fi
  mv "$stack/.retention-attempt.json" "$saved"
  node -e 'require("fs").writeFileSync(process.argv[1],JSON.stringify({schemaVersion:1,attemptedAtMs:Date.now()})+"\n")' \
    "$stack/.retention-attempt.json"
  printf 'continue\n' >&8
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "post-quarantine identity mutant unexpectedly accepted the replacement"
  assert_grep "owned entry generation changed before quarantine" "$output" \
    "post-quarantine identity mutant failed outside its intended boundary"
  next=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 "$SCRIPT" prune --status) \
    || fail "post-quarantine identity mutant retried immediately"
  assert_contains "$next" '"admitted":false,"reason":"cadence"' \
    "post-quarantine identity mutant remained immediately eligible"
  exec 7>&-; exec 8>&-
  pass "post-quarantine absence and generation mutants are detected"
}

retention_admission_prefix_for_stack() {
  # shellcheck disable=SC2016
  node -e '
    const crypto = require("crypto");
    const path = require("path");
    const stack = path.resolve(process.argv[1]);
    const scope = crypto.createHash("sha256").update(stack).digest("hex").slice(0, 24);
    const uid = typeof process.getuid === "function" ? process.getuid() : "user";
    process.stdout.write(`.firstmate-report-retention-${uid}-${scope}`);
  ' "$1"
}

test_retention_changed_index_read_races() {
  local stage stack ready proceed saved output state pid status ready_name proceed_name
  for stage in preopen postread; do
    stack="$TMP_ROOT/mutant-contract-index-$stage"
    ready="$TMP_ROOT/mutant-contract-index-$stage.ready"
    proceed="$TMP_ROOT/mutant-contract-index-$stage.proceed"
    saved="$TMP_ROOT/mutant-contract-index-$stage.saved"
    output="$TMP_ROOT/mutant-contract-index-$stage.out"
    write_retention_scale_fixture "$stack" 1 1 valid
    mkfifo "$ready" "$proceed"
    exec 7<>"$ready"
    exec 8<>"$proceed"
    if [ "$stage" = preopen ]; then
      ready_name=FM_REPORT_RETENTION_INDEX_PREOPEN_TEST_READY
      proceed_name=FM_REPORT_RETENTION_INDEX_PREOPEN_TEST_PROCEED
    else
      ready_name=FM_REPORT_RETENTION_INDEX_POSTREAD_TEST_READY
      proceed_name=FM_REPORT_RETENTION_INDEX_POSTREAD_TEST_PROCEED
    fi
    env FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
      FM_REPORT_LOCK_TEST_SETUP_FAILURE=1 "$ready_name=$ready" "$proceed_name=$proceed" \
      "$SCRIPT" prune --status > "$output" 2>&1 &
    pid=$!
    if ! IFS= read -r -t 10 state <&7; then
      kill -TERM "$pid" 2>/dev/null || true
      fail "changed-control index $stage race did not reach its boundary: $(cat "$output")"
    fi
    mv "$stack/index.html" "$saved"
    cp "$saved" "$stack/index.html"
    printf 'continue\n' >&8
    if wait "$pid"; then status=0; else status=$?; fi
    [ "$status" -ne 0 ] || fail "changed-control index $stage race was accepted as a no-op"
    assert_grep "synthetic report publication lock setup failure" "$output" \
      "changed-control index $stage race missed stable authority validation"
    exec 7>&-; exec 8>&-
  done
  pass "changed index authority reads reject pre-open and post-read replacement"
}

test_installed_retention_marker_contract() {
  local mode stack ready proceed saved output state pid status
  for mode in identity timestamp; do
    stack="$TMP_ROOT/mutant-contract-installed-$mode"
    ready="$TMP_ROOT/mutant-contract-installed-$mode.ready"
    proceed="$TMP_ROOT/mutant-contract-installed-$mode.proceed"
    saved="$TMP_ROOT/mutant-contract-installed-$mode.saved"
    output="$TMP_ROOT/mutant-contract-installed-$mode.out"
    mkdir -p "$stack/entries/cohort-1"
    mkfifo "$ready" "$proceed"
    exec 7<>"$ready"
    exec 8<>"$proceed"
    FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
      FM_REPORT_RETENTION_INTERVAL=3600 FM_REPORT_RETENTION_INSTALLED_TEST_READY="$ready" \
      FM_REPORT_RETENTION_INSTALLED_TEST_PROCEED="$proceed" FM_REPORT_LOCK_TEST_SETUP_FAILURE=1 \
      "$SCRIPT" prune --status > "$output" 2>&1 &
    pid=$!
    if ! IFS= read -r -t 10 state <&7; then
      kill -TERM "$pid" 2>/dev/null || true
      fail "changed-control installed $mode case did not reach verification: $(cat "$output")"
    fi
    if [ "$mode" = identity ]; then
      mv "$stack/.retention-attempt.json" "$saved"
      cp "$saved" "$stack/.retention-attempt.json"
    else
      node -e 'require("fs").writeFileSync(process.argv[1],"{\"schemaVersion\":1,\"attemptedAtMs\":0}\n")' \
        "$stack/.retention-attempt.json"
    fi
    printf 'continue\n' >&8
    if wait "$pid"; then status=0; else status=$?; fi
    [ "$status" -ne 0 ] || fail "changed-control installed $mode mutation unexpectedly completed"
    assert_grep "report retention attempt marker changed while installing" "$output" \
      "changed-control installed $mode mutation missed installation verification"
    assert_valid_fresh_retention_attempt "$stack/.retention-attempt.json" \
      || fail "changed-control installed $mode failure did not restore canonical admission"
    exec 7>&-; exec 8>&-
  done
  pass "installed retention markers verify identity and timestamp"
}

test_candidate_prelink_contract() {
  local mode stack ready proceed output candidate state pid status
  for mode in fresh fallback; do
    stack="$TMP_ROOT/mutant-contract-candidate-prelink-$mode"
    ready="$TMP_ROOT/mutant-contract-candidate-prelink-$mode.ready"
    proceed="$TMP_ROOT/mutant-contract-candidate-prelink-$mode.proceed"
    output="$TMP_ROOT/mutant-contract-candidate-prelink-$mode.out"
    mkdir -p "$stack/entries/cohort-1"
    mkfifo "$ready" "$proceed"
    exec 7<>"$ready"
    exec 8<>"$proceed"
    FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
      FM_REPORT_RETENTION_INTERVAL=3600 FM_REPORT_RETENTION_CANDIDATE_PRELINK_TEST_READY="$ready" \
      FM_REPORT_RETENTION_CANDIDATE_PRELINK_TEST_PROCEED="$proceed" \
      "$SCRIPT" prune --status > "$output" 2>&1 &
    pid=$!
    if ! IFS= read -r -t 10 state <&7; then
      kill -TERM "$pid" 2>/dev/null || true
      fail "changed-control candidate $mode did not reach the pre-link boundary: $(cat "$output")"
    fi
    candidate=$state
    if [ "$mode" = fresh ]; then
      ln "$stack/$candidate" "$stack/.retention-attempt.json"
    else
      node -e 'require("fs").writeFileSync(process.argv[1],JSON.stringify({schemaVersion:1,attemptedAtMs:Date.now()+86400000})+"\n")' \
        "$stack/.retention-attempt.json"
    fi
    printf 'continue\n' >&8
    if wait "$pid"; then status=0; else status=$?; fi
    [ "$status" -eq 0 ] || fail "changed-control candidate $mode link collision failed: $(cat "$output")"
    assert_grep '"admitted":false,"reason":"cadence"' "$output" \
      "changed-control candidate $mode link collision was not rejected by canonical ownership"
    assert_absent "$stack/$candidate" "changed-control candidate $mode link collision leaked its candidate"
    exec 7>&-; exec 8>&-
  done
  pass "candidate link collisions preserve canonical ownership"
}

test_candidate_postlink_contract() {
  local mode stack ready proceed output state pid status
  for mode in timestamp claim-error; do
    stack="$TMP_ROOT/mutant-contract-candidate-$mode"
    ready="$TMP_ROOT/mutant-contract-candidate-$mode.ready"
    proceed="$TMP_ROOT/mutant-contract-candidate-$mode.proceed"
    output="$TMP_ROOT/mutant-contract-candidate-$mode.out"
    mkdir -p "$stack/entries/cohort-1"
    mkfifo "$ready" "$proceed"
    exec 7<>"$ready"
    exec 8<>"$proceed"
    FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
      FM_REPORT_RETENTION_INTERVAL=3600 FM_REPORT_RETENTION_CANDIDATE_TEST_READY="$ready" \
      FM_REPORT_RETENTION_CANDIDATE_TEST_PROCEED="$proceed" \
      "$SCRIPT" prune --status > "$output" 2>&1 &
    pid=$!
    if ! IFS= read -r -t 10 state <&7; then
      kill -TERM "$pid" 2>/dev/null || true
      fail "changed-control candidate $mode did not reach the post-link boundary: $(cat "$output")"
    fi
    if [ "$mode" = timestamp ]; then
      node -e '
        const fs=require("fs");
        const value=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
        value.attemptedAtMs += 1;
        fs.writeFileSync(process.argv[1],JSON.stringify(value)+"\n");
      ' "$stack/.retention-attempt.json"
    else
      printf 'invalid claim\n' > "$stack/.retention-attempt.claim.json"
    fi
    printf 'continue\n' >&8
    if wait "$pid"; then status=0; else status=$?; fi
    if [ "$mode" = timestamp ]; then
      [ "$status" -eq 0 ] || fail "changed-control candidate timestamp race failed: $(cat "$output")"
      assert_grep '"admitted":false,"reason":"cadence"' "$output" \
        "changed-control candidate timestamp race claimed an unowned record"
    else
      [ "$status" -ne 0 ] || fail "changed-control candidate claim error unexpectedly completed"
      assert_grep "invalid report retention admission claim" "$output" \
        "changed-control candidate claim error missed validation"
    fi
    exec 7>&-; exec 8>&-
  done
  pass "candidate ownership verifies timestamps and post-link claim validation"
}

test_post_quarantine_replacement_contract() {
  local stack="$TMP_ROOT/mutant-contract-post-quarantine-replacement"
  local ready="$TMP_ROOT/mutant-contract-post-quarantine-replacement.ready"
  local proceed="$TMP_ROOT/mutant-contract-post-quarantine-replacement.proceed"
  local output="$TMP_ROOT/mutant-contract-post-quarantine-replacement.out" state pid status
  write_retention_scale_fixture "$stack" 1 1 valid
  mkdir "$stack/entries/cohort-1"
  printf 'invalid canonical\n' > "$stack/.retention-attempt.json"
  mkfifo "$ready" "$proceed"
  exec 7<>"$ready"
  exec 8<>"$proceed"
  FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 FM_REPORT_RETENTION_QUARANTINED_TEST_READY="$ready" \
    FM_REPORT_RETENTION_QUARANTINED_TEST_PROCEED="$proceed" \
    "$SCRIPT" prune --status > "$output" 2>&1 &
  pid=$!
  if ! IFS= read -r -t 10 state <&7; then
    kill -TERM "$pid" 2>/dev/null || true
    fail "changed-control quarantine did not reach the post-mutation boundary: $(cat "$output")"
  fi
  node -e 'require("fs").writeFileSync(process.argv[1],JSON.stringify({schemaVersion:1,attemptedAtMs:Date.now()})+"\n")' \
    "$stack/.retention-attempt.json"
  printf 'continue\n' >&8
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -eq 0 ] || fail "changed-control quarantine rejected a replacement generation: $(cat "$output")"
  assert_grep '"admitted":false,"reason":"cadence"' "$output" \
    "changed-control quarantine did not preserve replacement cadence"
  exec 7>&-; exec 8>&-
  pass "post-quarantine generation checks preserve replacements"
}

test_quarantine_error_after_absence_contract() {
  local stack="$TMP_ROOT/mutant-contract-quarantine-error-absent"
  local wrapper="$TMP_ROOT/mutant-contract-quarantine-error-python" output status
  write_retention_scale_fixture "$stack" 1 1 valid
  mkdir "$stack/entries/cohort-1"
  printf 'invalid canonical\n' > "$stack/.retention-attempt.json"
  node - "$wrapper" <<'NODE'
const fs = require("fs");
fs.writeFileSync(process.argv[2], `#!/usr/bin/env bash
if [ "\${2:-}" = quarantine-owned-entry-fd ]; then
  "\$FM_REAL_PYTHON" "\$@" || exit \$?
  printf 'synthetic post-quarantine failure\\n' >&2
  exit 1
fi
exec "\$FM_REAL_PYTHON" "\$@"
`);
NODE
  chmod +x "$wrapper"
  if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 FM_REPORT_PYTHON="$wrapper" FM_REAL_PYTHON="$(command -v python3)" \
    "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "changed-control post-quarantine failure unexpectedly completed"
  assert_contains "$output" "invalid report retention attempt marker" \
    "changed-control post-quarantine absence did not preserve validation"
  assert_valid_fresh_retention_attempt "$stack/.retention-attempt.json" \
    || fail "changed-control post-quarantine absence did not restore admission"
  pass "post-quarantine helper errors accept an already absent generation"
}

test_fresh_retention_marker_short_circuits_installation() {
  local kind stack ready output status
  for kind in fresh fallback-fresh; do
    stack="$TMP_ROOT/mutant-contract-marker-short-circuit-$kind"
    ready="$TMP_ROOT/mutant-contract-marker-short-circuit-$kind.ready"
    mkdir -p "$stack/entries/cohort-1"
    if [ "$kind" = fresh ]; then
      node -e 'require("fs").writeFileSync(process.argv[1],JSON.stringify({schemaVersion:1,attemptedAtMs:Date.now()})+"\n")' \
        "$stack/.retention-attempt.json"
    else
      node -e 'require("fs").writeFileSync(process.argv[1],JSON.stringify({schemaVersion:1,attemptedAtMs:Date.now()+86400000})+"\n")' \
        "$stack/.retention-attempt.json"
    fi
    if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
      FM_REPORT_RETENTION_INTERVAL=3600 FM_REPORT_RETENTION_INSTALL_TEST_READY="$ready" \
      "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
    [ "$status" -eq 0 ] || fail "changed-control $kind marker reached canonical installation: $output"
    assert_contains "$output" '"admitted":false,"reason":"cadence"' \
      "changed-control $kind marker missed cadence"
    assert_absent "$ready" "changed-control $kind marker reached the candidate boundary"
  done
  pass "fresh and fallback-fresh markers short-circuit installation"
}

test_initial_claim_validation_survives_installation_race() {
  local stack="$TMP_ROOT/mutant-contract-initial-claim-validation"
  local ready="$TMP_ROOT/mutant-contract-initial-claim-validation.ready"
  local proceed="$TMP_ROOT/mutant-contract-initial-claim-validation.proceed"
  local saved="$TMP_ROOT/mutant-contract-initial-claim-validation.saved"
  local output="$TMP_ROOT/mutant-contract-initial-claim-validation.out" state pid status second
  mkdir -p "$stack/entries/cohort-1"
  printf '{"schemaVersion":1,"attemptedAtMs":0}\n' > "$stack/.retention-attempt.json"
  printf 'invalid claim\n' > "$stack/.retention-attempt.claim.json"
  touch -t 200001010000 "$stack/.retention-attempt.claim.json"
  mkfifo "$ready" "$proceed"
  exec 7<>"$ready"
  exec 8<>"$proceed"
  FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 FM_REPORT_RETENTION_CANDIDATE_PRELINK_TEST_READY="$ready" \
    FM_REPORT_RETENTION_CANDIDATE_PRELINK_TEST_PROCEED="$proceed" \
    "$SCRIPT" prune --status > "$output" 2>&1 &
  pid=$!
  if ! IFS= read -r -t 10 state <&7; then
    kill -TERM "$pid" 2>/dev/null || true
    fail "changed-control initial claim validation did not reach installation: $(cat "$output")"
  fi
  mv "$stack/.retention-attempt.claim.json" "$saved"
  printf 'continue\n' >&8
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "changed-control initial claim validation was lost after path replacement"
  assert_grep "invalid report retention admission claim" "$output" \
    "changed-control initial claim validation failed outside its observation boundary"
  assert_valid_fresh_retention_attempt "$stack/.retention-attempt.json" \
    || fail "changed-control initial claim validation did not install canonical admission"
  second=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 "$SCRIPT" prune --status) \
    || fail "changed-control initial claim validation retried immediately"
  assert_contains "$second" '"admitted":false,"reason":"cadence"' \
    "changed-control initial claim validation remained immediately eligible"
  exec 7>&-; exec 8>&-
  pass "initial claim validation survives installation races"
}

test_missing_policy_frame_item_uses_default_authority() {
  local stack="$TMP_ROOT/mutant-contract-missing-policy-frame-item"
  local wrapper="$TMP_ROOT/mutant-contract-missing-policy-frame-item-python" output status
  mkdir -p "$stack/entries/cohort-1"
  node - "$wrapper" <<'NODE'
const fs = require("fs");
fs.writeFileSync(process.argv[2], `#!/usr/bin/env bash
if [ "\${2:-}" = read-fd ] && [ "\${3:-}" = .retention-policy.js ]; then
  printf '{"items":[]}\\n'
  exit 0
fi
exec "\$FM_REAL_PYTHON" "\$@"
`);
NODE
  chmod +x "$wrapper"
  if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 FM_REPORT_PYTHON="$wrapper" FM_REAL_PYTHON="$(command -v python3)" \
    "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
  [ "$status" -eq 0 ] || fail "changed-control missing policy frame item rejected default authority: $output"
  assert_contains "$output" '"admitted":true,"reason":"completed"' \
    "changed-control missing policy frame item did not complete"
  pass "missing policy frame items use default authority"
}

test_retention_changed_control_flow_contract() {
  local stack output status second prefix old_marker sentinel foreign_marker mismatch authority helper marker bucket expected

  stack="$TMP_ROOT/mutant-contract-valid-noop"
  write_retention_scale_fixture "$stack" 1 1 valid
  output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    "$SCRIPT" prune --status) || fail "changed-control valid no-op failed"
  assert_contains "$output" '"admitted":false,"reason":"no-work"' \
    "changed-control valid no-op reached admission"

  stack="$TMP_ROOT/mutant-contract-missing-root"
  output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    "$SCRIPT" prune --status) || fail "changed-control missing-root no-op failed"
  assert_contains "$output" '"admitted":false,"reason":"no-work"' \
    "changed-control missing root was not a no-op"

  stack="$TMP_ROOT/mutant-contract-force"
  output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    "$SCRIPT" prune --force --status) || fail "changed-control forced prune failed"
  assert_contains "$output" '"admitted":true,"reason":"forced"' \
    "changed-control forced prune did not bypass scheduled admission"

  stack="$TMP_ROOT/mutant-contract-due"
  mkdir -p "$stack/entries/cohort-1"
  prefix=$(retention_admission_prefix_for_stack "$stack")
  old_marker="$RETENTION_ADMISSION_DIR/$prefix.0.json"
  sentinel="$RETENTION_ADMISSION_DIR/$prefix.sentinel"
  foreign_marker="$RETENTION_ADMISSION_DIR/x${prefix#?}.0.json"
  printf 'old admission\n' > "$old_marker"
  printf 'unrelated admission sentinel\n' > "$sentinel"
  printf 'foreign admission marker\n' > "$foreign_marker"
  output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    "$SCRIPT" prune --status) || fail "changed-control due pass failed"
  assert_contains "$output" '"admitted":true,"reason":"completed"' \
    "changed-control due pass did not complete"
  [ "$(find "$stack" -mindepth 1 -maxdepth 1 -name '.*retention-attempt.json.candidate.*' | wc -l | tr -d ' ')" -eq 0 ] \
    || fail "changed-control due pass leaked a canonical admission candidate"
  assert_absent "$old_marker" "root-independent admission did not retire an old bucket"
  assert_present "$sentinel" "root-independent admission cleanup removed an unrelated entry"
  assert_present "$foreign_marker" "root-independent admission cleanup crossed its stack namespace"
  [ "$(find "$RETENTION_ADMISSION_DIR" -mindepth 1 -maxdepth 1 -type f -name "$prefix.*.json" | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "root-independent admission did not retain exactly its current bucket"
  test_fresh_retention_marker_short_circuits_installation
  test_initial_claim_validation_survives_installation_race
  test_missing_policy_frame_item_uses_default_authority
  test_candidate_prelink_contract
  test_candidate_postlink_contract

  stack="$TMP_ROOT/mutant-contract-internal-cadence"
  mkdir -p "$stack/entries/cohort-1"
  node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({schemaVersion:1,attemptedAtMs:Date.now()})+"\n")' \
    "$stack/.retention-attempt.json"
  prefix=$(retention_admission_prefix_for_stack "$stack")
  output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    "$SCRIPT" prune --status) || fail "changed-control internal cadence failed"
  assert_contains "$output" '"admitted":false,"reason":"cadence"' \
    "changed-control internal marker did not suppress admission"
  [ "$(find "$RETENTION_ADMISSION_DIR" -mindepth 1 -maxdepth 1 -name "$prefix.*.json" | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "root-independent admission did not remain durable after internal cadence"

  stack="$TMP_ROOT/mutant-contract-cutover"
  write_retention_scale_fixture "$stack" 1 1 valid
  printf 'pending cutover\n' > "$stack/.retention-cutover.json"
  if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_LOCK_TEST_SETUP_FAILURE=1 "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "changed-control cutover marker became a no-op"
  assert_contains "$output" "synthetic report publication lock setup failure" \
    "changed-control cutover marker missed admission"

  stack="$TMP_ROOT/mutant-contract-legacy-cutover"
  write_retention_scale_fixture "$stack" 1 1 valid
  printf 'pending legacy cutover\n' > "$stack/.legacy-cutover.json"
  if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_LOCK_TEST_SETUP_FAILURE=1 "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "changed-control legacy cutover marker became a no-op"
  assert_contains "$output" "synthetic report publication lock setup failure" \
    "changed-control legacy cutover marker missed admission"

  stack="$TMP_ROOT/mutant-contract-due-cohort"
  write_retention_scale_fixture "$stack" 0 1 valid
  mv "$(find "$stack/entries" -mindepth 1 -maxdepth 1 -type d -print -quit)" "$stack/entries/cohort-1"
  if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_LOCK_TEST_SETUP_FAILURE=1 "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "changed-control due cohort became a no-op"
  assert_contains "$output" "synthetic report publication lock setup failure" \
    "changed-control due cohort missed admission"

  stack="$TMP_ROOT/mutant-contract-cohort-file"
  write_retention_scale_fixture "$stack" 0 0 valid
  printf 'not a cohort directory\n' > "$stack/entries/cohort-9999999999999"
  if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_LOCK_TEST_SETUP_FAILURE=1 "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "changed-control cohort-shaped file became a no-op"
  assert_contains "$output" "synthetic report publication lock setup failure" \
    "changed-control cohort directory predicate missed its boundary"

  stack="$TMP_ROOT/mutant-contract-noncohort-directory"
  write_retention_scale_fixture "$stack" 0 0 stale
  mkdir "$stack/entries/.hidden-cohort"
  output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    "$SCRIPT" prune --status) || fail "changed-control hidden non-cohort failed"
  assert_contains "$output" '"admitted":false,"reason":"no-work"' \
    "changed-control hidden non-cohort was treated as a cohort"

  for authority in tmp-file tmp-name tmp-age; do
    stack="$TMP_ROOT/mutant-contract-$authority"
    write_retention_scale_fixture "$stack" 0 0 valid
    case "$authority" in
      tmp-file)
        printf 'not a directory\n' > "$stack/entries/.report.1.tmp"
        touch -t 200001010000 "$stack/entries/.report.1.tmp"
        ;;
      tmp-name)
        mkdir "$stack/entries/.hidden-staging"
        touch -t 200001010000 "$stack/entries/.hidden-staging"
        ;;
      tmp-age)
        mkdir "$stack/entries/.report.1.tmp"
        ;;
    esac
    output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
      "$SCRIPT" prune --status) || fail "changed-control $authority negative control failed"
    assert_contains "$output" '"admitted":false,"reason":"no-work"' \
      "changed-control $authority negative control became due"
  done

  stack="$TMP_ROOT/mutant-contract-previous-file"
  write_retention_scale_fixture "$stack" 0 0 valid
  printf 'not a recovery directory\n' > "$stack/entries/.report.previous"
  output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    "$SCRIPT" prune --status) || fail "changed-control previous-file negative control failed"
  assert_contains "$output" '"admitted":false,"reason":"no-work"' \
    "changed-control previous-file negative control became due"

  stack="$TMP_ROOT/mutant-contract-wrong-root"
  printf 'wrong root\n' > "$stack"
  if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "changed-control wrong root unexpectedly completed"
  second=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    "$SCRIPT" prune --status) || fail "changed-control wrong root retried"
  assert_contains "$second" '"admitted":false,"reason":"cadence"' \
    "changed-control wrong root was not root-independently throttled"

  stack="$TMP_ROOT/mutant-contract-malformed-policy"
  write_retention_scale_fixture "$stack" 1 1 valid
  printf 'malformed policy\n' > "$stack/.retention-policy.js"
  if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "changed-control malformed policy unexpectedly completed"
  assert_contains "$output" "invalid report retention authority" \
    "changed-control malformed policy missed validation"
  second=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    "$SCRIPT" prune --status) || fail "changed-control malformed policy retried"
  assert_contains "$second" '"admitted":false,"reason":"cadence"' \
    "changed-control malformed policy was immediately eligible"

  stack="$TMP_ROOT/mutant-contract-index-schema"
  write_retention_scale_fixture "$stack" 1 1 valid
  node - "$stack/.retention-policy.js" "$stack/index.html" <<'NODE'
const fs = require("fs");
const [policyFile, indexFile] = process.argv.slice(2);
const source = fs.readFileSync(policyFile, "utf8").trim();
const policy = JSON.parse(source.match(/^window\.firstmateRetentionPolicy=(\{.*\});$/)[1]);
fs.writeFileSync(indexFile, `<!-- firstmate-retention ${JSON.stringify({ ...policy, schemaVersion: 2 })} -->\nexisting index\n`);
NODE
  if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_LOCK_TEST_SETUP_FAILURE=1 "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "changed-control index schema mismatch became a no-op"
  assert_contains "$output" "synthetic report publication lock setup failure" \
    "changed-control index schema mismatch missed admission"

  stack="$TMP_ROOT/mutant-contract-index-header-limit"
  write_retention_scale_fixture "$stack" 1 1 valid
  node - "$stack/.retention-policy.js" "$stack/index.html" <<'NODE'
const fs = require("fs");
const [policyFile, indexFile] = process.argv.slice(2);
const source = fs.readFileSync(policyFile, "utf8").trim();
const policy = JSON.parse(source.match(/^window\.firstmateRetentionPolicy=(\{.*\});$/)[1]);
const json = JSON.stringify(policy);
const prefix = `<!-- firstmate-retention ${json.slice(0, -1)}`;
const suffix = "} -->";
const padding = 512 - Buffer.byteLength(prefix + suffix);
if (padding < 0) throw new Error("authority fixture exceeds its intended boundary");
fs.writeFileSync(indexFile, `${prefix}${" ".repeat(padding)}${suffix}x`);
NODE
  if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_LOCK_TEST_SETUP_FAILURE=1 "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "changed-control unterminated index header became a no-op"
  assert_contains "$output" "synthetic report publication lock setup failure" \
    "changed-control index header limit missed admission"

  test_retention_changed_index_read_races

  for stack in \
    "$TMP_ROOT/mutant-contract-stale-index" \
    "$TMP_ROOT/mutant-contract-cutoff-index" \
    "$TMP_ROOT/mutant-contract-corrupt-index"; do
    case "$stack" in
      *stale*) write_retention_scale_fixture "$stack" 1 1 stale ;;
      *cutoff*) write_retention_scale_fixture "$stack" 1 1 cutoff ;;
      *) write_retention_scale_fixture "$stack" 1 1 corrupt ;;
    esac
    if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
      FM_REPORT_LOCK_TEST_SETUP_FAILURE=1 "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
    [ "$status" -ne 0 ] || fail "changed-control invalid index authority became a no-op at $stack"
    assert_contains "$output" "synthetic report publication lock setup failure" \
      "changed-control invalid index authority missed the lock boundary at $stack"
  done

  for stack in \
    "$TMP_ROOT/mutant-contract-entries-symlink" \
    "$TMP_ROOT/mutant-contract-transaction" \
    "$TMP_ROOT/mutant-contract-previous" \
    "$TMP_ROOT/mutant-contract-aged-temp" \
    "$TMP_ROOT/mutant-contract-public-entry" \
    "$TMP_ROOT/mutant-contract-tombstone"; do
    mkdir -p "$stack"
    case "$stack" in
      *entries-symlink*) ln -s missing "$stack/entries" ;;
      *transaction*) mkdir -p "$stack/entries"; printf 'transaction\n' > "$stack/entries/.report.transaction" ;;
      *previous*) mkdir -p "$stack/entries/.report.previous" ;;
      *aged-temp*) mkdir -p "$stack/entries/.report.1.tmp"; touch -t 200001010000 "$stack/entries/.report.1.tmp" ;;
      *public-entry*) mkdir -p "$stack/entries/report-visible" ;;
      *tombstone*) mkdir -p "$stack/entries" "$stack/.retention-tombstones/tombstone-1" ;;
    esac
    if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
      FM_REPORT_LOCK_TEST_SETUP_FAILURE=1 "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
    [ "$status" -ne 0 ] || fail "changed-control recovery work became a no-op at $stack"
    assert_contains "$output" "synthetic report publication lock setup failure" \
      "changed-control recovery work missed admission at $stack"
  done

  stack="$TMP_ROOT/mutant-contract-malformed-marker"
  write_retention_scale_fixture "$stack" 1 1 valid
  mkdir "$stack/entries/cohort-1"
  printf 'malformed admission\n' > "$stack/.retention-attempt.json"
  if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "changed-control malformed marker unexpectedly completed"
  assert_contains "$output" "invalid report retention attempt marker" \
    "changed-control malformed marker missed validation"
  assert_valid_fresh_retention_attempt "$stack/.retention-attempt.json" \
    || fail "changed-control malformed marker did not restore canonical admission"
  [ "$(find "$stack" -mindepth 1 -maxdepth 1 -name '.*retention-attempt.json.invalid.*' | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "changed-control malformed marker was not persistently quarantined"

  stack="$TMP_ROOT/mutant-contract-marker-schema"
  write_retention_scale_fixture "$stack" 1 1 valid
  mkdir "$stack/entries/cohort-1"
  node -e 'require("fs").writeFileSync(process.argv[1],JSON.stringify({schemaVersion:2,attemptedAtMs:Date.now()})+"\n")' \
    "$stack/.retention-attempt.json"
  if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "changed-control marker schema mismatch unexpectedly completed"
  assert_contains "$output" "invalid report retention attempt marker" \
    "changed-control marker schema mismatch missed validation"

  for authority in integral negative; do
    stack="$TMP_ROOT/mutant-contract-marker-$authority"
    write_retention_scale_fixture "$stack" 1 1 valid
    mkdir "$stack/entries/cohort-1"
    if [ "$authority" = integral ]; then
      node -e 'require("fs").writeFileSync(process.argv[1],JSON.stringify({schemaVersion:1,attemptedAtMs:String(Date.now())})+"\n")' \
        "$stack/.retention-attempt.json"
    else
      printf '{"schemaVersion":1,"attemptedAtMs":-1}\n' > "$stack/.retention-attempt.json"
    fi
    if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
      FM_REPORT_RETENTION_INTERVAL=3600 "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
    [ "$status" -ne 0 ] || fail "changed-control marker $authority mismatch unexpectedly completed"
    assert_contains "$output" "invalid report retention attempt marker" \
      "changed-control marker $authority mismatch missed validation"
  done

  stack="$TMP_ROOT/mutant-contract-fresh-invalid-claim"
  write_retention_scale_fixture "$stack" 1 1 valid
  mkdir "$stack/entries/cohort-1"
  printf '{"schemaVersion":1,"attemptedAtMs":0}\n' > "$stack/.retention-attempt.json"
  printf 'partial claim\n' > "$stack/.retention-attempt.claim.json"
  output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 "$SCRIPT" prune --status) \
    || fail "changed-control fresh invalid claim rejected its bounded fallback"
  assert_contains "$output" '"admitted":false,"reason":"cadence"' \
    "changed-control fresh invalid claim missed bounded fallback"

  stack="$TMP_ROOT/mutant-contract-fresh-valid-claim"
  write_retention_scale_fixture "$stack" 1 1 valid
  mkdir "$stack/entries/cohort-1"
  printf '{"schemaVersion":1,"attemptedAtMs":0}\n' > "$stack/.retention-attempt.json"
  node -e 'require("fs").writeFileSync(process.argv[1],JSON.stringify({schemaVersion:1,attemptedAtMs:Date.now()})+"\n")' \
    "$stack/.retention-attempt.claim.json"
  output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 "$SCRIPT" prune --status) \
    || fail "changed-control fresh valid claim failed"
  assert_contains "$output" '"admitted":false,"reason":"cadence"' \
    "changed-control fresh valid claim missed cadence"

  stack="$TMP_ROOT/mutant-contract-stale-claim"
  write_retention_scale_fixture "$stack" 1 1 valid
  mkdir "$stack/entries/cohort-1" "$stack/.retention-attempt.claim.json"
  printf '{"schemaVersion":1,"attemptedAtMs":0}\n' > "$stack/.retention-attempt.json"
  touch -t 200001010000 "$stack/.retention-attempt.claim.json"
  if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "changed-control stale wrong-type claim unexpectedly completed"
  assert_contains "$output" "report retention admission claim" \
    "changed-control stale wrong-type claim missed validation"
  assert_absent "$stack/.retention-attempt.claim.json" \
    "changed-control stale wrong-type claim was not retired after canonical admission"

  stack="$TMP_ROOT/mutant-contract-future-marker"
  write_retention_scale_fixture "$stack" 1 1 valid
  mkdir "$stack/entries/cohort-1"
  node -e '
    const fs=require("fs");
    fs.writeFileSync(process.argv[1],JSON.stringify({schemaVersion:1,attemptedAtMs:Date.now()+86400000})+"\n");
    const old=new Date(Date.now()-7200000);
    fs.utimesSync(process.argv[1],old,old);
  ' "$stack/.retention-attempt.json"
  if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "changed-control future marker unexpectedly completed"
  assert_contains "$output" "invalid report retention attempt marker" \
    "changed-control future marker missed timestamp validation"

  for authority in recent future-mtime; do
    stack="$TMP_ROOT/mutant-contract-future-$authority"
    write_retention_scale_fixture "$stack" 1 1 valid
    mkdir "$stack/entries/cohort-1"
    node -e '
      const fs=require("fs");
      fs.writeFileSync(process.argv[1],JSON.stringify({schemaVersion:1,attemptedAtMs:Date.now()+86400000})+"\n");
      if (process.argv[2] === "future-mtime") {
        const future=new Date(Date.now()+86400000);
        fs.utimesSync(process.argv[1],future,future);
      }
    ' "$stack/.retention-attempt.json" "$authority"
    if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
      FM_REPORT_RETENTION_INTERVAL=3600 "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
    if [ "$authority" = recent ]; then
      [ "$status" -eq 0 ] || fail "changed-control recent future marker rejected bounded fallback"
      assert_contains "$output" '"admitted":false,"reason":"cadence"' \
        "changed-control recent future marker missed bounded fallback"
    else
      [ "$status" -ne 0 ] || fail "changed-control future file timestamp bypassed validation"
      assert_contains "$output" "invalid report retention attempt marker" \
        "changed-control future file timestamp missed validation"
    fi
  done

  stack="$TMP_ROOT/mutant-contract-post-quarantine"
  write_retention_scale_fixture "$stack" 1 1 valid
  mkdir "$stack/entries/cohort-1"
  printf 'malformed admission\n' > "$stack/.retention-attempt.json"
  mismatch="$TMP_ROOT/mutant-contract-post-quarantine.used"
  if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 FM_CONTAINED_QUARANTINE_DEVICE_MISMATCH_TEST="$mismatch" \
    "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "changed-control post-quarantine mismatch unexpectedly completed"
  assert_contains "$output" "owned entry generation changed during quarantine" \
    "changed-control post-quarantine mismatch missed helper validation"

  test_quarantine_error_after_absence_contract
  test_post_quarantine_replacement_contract

  for authority in batch batch-zero cohort cohort-zero interval interval-zero interval-overflow drift; do
    stack="$TMP_ROOT/mutant-contract-invalid-$authority"
    write_retention_scale_fixture "$stack" 1 1 valid
    case "$authority" in
      batch)
        if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
          FM_REPORT_RETENTION_BATCH=invalid "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
        ;;
      batch-zero)
        if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
          FM_REPORT_RETENTION_BATCH=0 "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
        ;;
      cohort)
        if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
          FM_REPORT_RETENTION_COHORT_MS=invalid "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
        ;;
      cohort-zero)
        if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
          FM_REPORT_RETENTION_COHORT_MS=0 "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
        ;;
      interval)
        if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
          FM_REPORT_RETENTION_INTERVAL=1.5 "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
        ;;
      interval-zero)
        if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
          FM_REPORT_RETENTION_INTERVAL=0 "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
        ;;
      interval-overflow)
        if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
          FM_REPORT_RETENTION_INTERVAL=9007199254740991 "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
        ;;
      drift)
        if output=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
          FM_REPORT_RETENTION_COHORT_MS=1296000000 FM_REPORT_RETENTION_INTERVAL=1 \
          "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
        ;;
    esac
    [ "$status" -ne 0 ] || fail "changed-control invalid $authority configuration unexpectedly completed"
    prefix=$(retention_admission_prefix_for_stack "$stack")
    marker=$(find "$RETENTION_ADMISSION_DIR" -mindepth 1 -maxdepth 1 -type f -name "$prefix.*.json" -print -quit)
    [ -n "$marker" ] || fail "changed-control invalid $authority configuration missed root-independent admission"
    case "$authority" in
      interval*)
        bucket=${marker#"$RETENTION_ADMISSION_DIR/$prefix."}
        bucket=${bucket%.json}
        expected=$(node -e 'process.stdout.write(String(Math.floor(Date.now()/300000)))')
        case "$bucket" in *[!0-9]*|'') fail "changed-control invalid $authority configuration used a non-fallback bucket" ;; esac
        [ "$bucket" -ge $((expected - 1)) ] && [ "$bucket" -le $((expected + 1)) ] \
          || fail "changed-control invalid $authority configuration bypassed the five-minute admission fallback"
        ;;
    esac
  done

  helper=$(dirname "$SCRIPT")/fm-contained-read.py
  if output=$(python3 "$helper" quarantine-owned-entry-fd 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "changed-control quarantine helper accepted missing arguments"
  assert_contains "$output" "usage: fm-contained-read.py quarantine-owned-entry-fd" \
    "changed-control quarantine helper missed argument validation"
  stack="$TMP_ROOT/mutant-contract-helper-root"
  mkdir -p "$stack"
  if output=$(python3 "$helper" quarantine-owned-entry-fd safe/source 0:0 quarantine 3<"$stack" 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "changed-control quarantine helper accepted an unsafe component"
  assert_contains "$output" "owned entry names must be single safe components" \
    "changed-control quarantine helper missed component validation"
  printf 'source\n' > "$stack/source"
  if output=$(python3 "$helper" quarantine-owned-entry-fd source 0:0 safe/quarantine 3<"$stack" 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "changed-control quarantine helper accepted an unsafe destination"
  assert_contains "$output" "owned entry names must be single safe components" \
    "changed-control quarantine helper missed destination validation"

  test_installed_retention_marker_contract
  test_retention_invalid_marker_quarantine_is_inode_owned
  test_retention_quarantine_postrename_predicate_mutations
  test_retention_admission_and_lock_share_root_generation
  test_root_retention_admission_preserves_newer_bucket
  test_busy_lock_error_names_holder_identity_and_age
  pass "changed retention control flow has valid positive and negative controls"
}

test_root_retention_admission_preserves_newer_bucket() {
  local implementation mutant_root executable stack prefix marker first_bucket current_bucket
  local first_ready first_proceed second_ready second_proceed third_ready third_proceed
  local first_output second_output third_output first_pid second_pid third_pid state status
  for implementation in control mutant; do
    mutant_root="$TMP_ROOT/retention-root-boundary-$implementation"
    executable="$SCRIPT"
    if [ "$implementation" = mutant ]; then
      write_report_stack_mutant "$mutant_root" \
        'markerBucketOlderGuard = Number.isSafeInteger(markerBucket) && markerBucket < bucket' \
        'markerBucketOlderGuard = Number.isSafeInteger(markerBucket) && markerBucket >= bucket'
      executable="$mutant_root/bin/fm-report-stack.mjs"
    fi
    stack="$TMP_ROOT/retention-root-boundary-stack-$implementation"
    mkdir -p "$stack/entries/cohort-1"
    prefix=$(retention_admission_prefix_for_stack "$stack")
    first_ready="$TMP_ROOT/retention-root-boundary-$implementation-first.ready"
    first_proceed="$TMP_ROOT/retention-root-boundary-$implementation-first.proceed"
    second_ready="$TMP_ROOT/retention-root-boundary-$implementation-second.ready"
    second_proceed="$TMP_ROOT/retention-root-boundary-$implementation-second.proceed"
    third_ready="$TMP_ROOT/retention-root-boundary-$implementation-third.ready"
    third_proceed="$TMP_ROOT/retention-root-boundary-$implementation-third.proceed"
    first_output="$TMP_ROOT/retention-root-boundary-$implementation-first.out"
    second_output="$TMP_ROOT/retention-root-boundary-$implementation-second.out"
    third_output="$TMP_ROOT/retention-root-boundary-$implementation-third.out"
    mkfifo "$first_ready" "$first_proceed" "$second_ready" "$second_proceed" "$third_ready" "$third_proceed"
    exec 7<>"$first_ready"; exec 8<>"$first_proceed"
    exec 9<>"$second_ready"; exec 10<>"$second_proceed"
    exec 11<>"$third_ready"; exec 12<>"$third_proceed"
    FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
      FM_REPORT_RETENTION_INTERVAL=3 FM_REPORT_RETENTION_ROOT_ADMISSION_TEST_READY="$first_ready" \
      FM_REPORT_RETENTION_ROOT_ADMISSION_TEST_PROCEED="$first_proceed" \
      "$executable" prune --status > "$first_output" 2>&1 &
    first_pid=$!
    IFS= read -r -t 10 state <&7 || fail "$implementation bucket-N process missed root admission"
    [ "$state" = root-attempt-admitted ] || fail "$implementation bucket-N process emitted $state"
    marker=$(find "$RETENTION_ADMISSION_DIR" -mindepth 1 -maxdepth 1 -type f -name "$prefix.*.json" | head -1)
    first_bucket=${marker#"$RETENTION_ADMISSION_DIR/$prefix."}
    first_bucket=${first_bucket%.json}
    current_bucket=$first_bucket
    while [ "$current_bucket" -le "$first_bucket" ]; do
      current_bucket=$(node -e 'process.stdout.write(String(Math.floor(Date.now() / 3000)))')
    done
    FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
      FM_REPORT_RETENTION_INTERVAL=3 FM_REPORT_RETENTION_ROOT_ADMISSION_TEST_READY="$second_ready" \
      FM_REPORT_RETENTION_ROOT_ADMISSION_TEST_PROCEED="$second_proceed" \
      "$executable" prune --status > "$second_output" 2>&1 &
    second_pid=$!
    IFS= read -r -t 10 state <&9 || fail "$implementation bucket-N+1 process missed root admission"
    [ "$state" = root-attempt-admitted ] || fail "$implementation bucket-N+1 process emitted $state"
    printf 'continue\n' >&8
    wait "$first_pid" || fail "$implementation bucket-N process failed: $(cat "$first_output")"
    mkdir -p "$stack/entries/cohort-1"
    FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
      FM_REPORT_RETENTION_INTERVAL=3 FM_REPORT_RETENTION_ROOT_ADMISSION_TEST_READY="$third_ready" \
      FM_REPORT_RETENTION_ROOT_ADMISSION_TEST_PROCEED="$third_proceed" \
      "$executable" prune --status > "$third_output" 2>&1 &
    third_pid=$!
    if [ "$implementation" = control ]; then
      if wait "$third_pid"; then status=0; else status=$?; fi
      [ "$status" -eq 0 ] || fail "control third process failed: $(cat "$third_output")"
      assert_grep '"admitted":false,"reason":"cadence"' "$third_output" \
        "control third process was not rejected by the N+1 root admission"
    else
      IFS= read -r -t 10 state <&11 || fail "strict-older mutant did not admit a second N+1 process"
      [ "$state" = root-attempt-admitted ] \
        || fail "strict-older mutant failed for the wrong second-admission reason: $state"
      printf 'continue\n' >&12
      wait "$third_pid" || fail "strict-older mutant third process failed: $(cat "$third_output")"
    fi
    printf 'continue\n' >&10
    wait "$second_pid" || fail "$implementation bucket-N+1 process failed: $(cat "$second_output")"
    exec 7>&-; exec 8>&-; exec 9>&-; exec 10>&-; exec 11>&-; exec 12>&-
  done
  pass "root admission cleanup preserves current and future buckets"
}

test_retention_admission_mutation_inventory_is_complete() {
  node - "$ROOT" "$ROOT/tests/fm-report-stack-suite.sh" "$TMP_ROOT/changed-control-mutants" <<'NODE' \
    || fail "changed-control mutation inventory failed"
const fs = require("fs");
const path = require("path");
const { spawn, spawnSync } = require("child_process");
const [root, suite, mutantRoot] = process.argv.slice(2);
const base = "68f014697d0eea733a4e7c0294becff4e76c7bcf";
const javascriptFile = path.join(root, "bin", "fm-report-stack.mjs");
const pythonFile = path.join(root, "bin", "fm-contained-read.py");
const parserFile = path.join(root, "bin", "fm-markdown-structure.cjs");

function changedLines(file) {
  const relative = path.relative(root, file);
  const diff = spawnSync("git", ["-C", root, "diff", "--unified=0", base, "--", relative], { encoding: "utf8" });
  if (diff.status !== 0) throw new Error(`could not derive changed lines for ${relative}: ${diff.stderr}`);
  const result = new Set();
  for (const line of diff.stdout.split("\n")) {
    const match = line.match(/^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/);
    if (!match) continue;
    const start = Number(match[1]);
    const count = match[2] === undefined ? 1 : Number(match[2]);
    for (let index = 0; index < count; index += 1) result.add(start + index);
  }
  return result;
}

function lineStarts(source) {
  const starts = [0];
  for (let index = 0; index < source.length; index += 1) {
    if (source[index] === "\n") starts.push(index + 1);
  }
  return starts;
}

function lineForOffset(starts, offset) {
  let low = 0;
  let high = starts.length;
  while (low + 1 < high) {
    const middle = Math.floor((low + high) / 2);
    if (starts[middle] <= offset) low = middle;
    else high = middle;
  }
  return low + 1;
}

function scrubJavascript(source) {
  const output = [...source];
  let index = 0;
  let state = "code";
  while (index < source.length) {
    if (state === "code") {
      if (source.startsWith("//", index)) {
        output[index] = output[index + 1] = " ";
        index += 2;
        state = "line";
      } else if (source.startsWith("/*", index)) {
        output[index] = output[index + 1] = " ";
        index += 2;
        state = "block";
      } else if (source[index] === "\"" || source[index] === "'" || source[index] === "`") {
        state = source[index];
        output[index] = " ";
        index += 1;
      } else {
        index += 1;
      }
    } else if (state === "line") {
      if (source[index] === "\n") state = "code";
      else output[index] = " ";
      index += 1;
    } else if (state === "block") {
      if (source.startsWith("*/", index)) {
        output[index] = output[index + 1] = " ";
        index += 2;
        state = "code";
      } else {
        if (source[index] !== "\n") output[index] = " ";
        index += 1;
      }
    } else if (source[index] === "\\") {
      output[index] = " ";
      index += 1;
      if (index < source.length) output[index] = " ";
      index += 1;
    } else if (source[index] === state) {
      output[index] = " ";
      index += 1;
      state = "code";
    } else {
      if (source[index] !== "\n") output[index] = " ";
      index += 1;
    }
  }
  return output.join("");
}

function javascriptPredicates() {
  const source = fs.readFileSync(javascriptFile, "utf8");
  const clean = scrubJavascript(source);
  const changed = changedLines(javascriptFile);
  const starts = lineStarts(source);
  const predicates = [];
  function logicalLeaves(start, end, fallbackReplacement = "false") {
    while (start < end && /\s/.test(source[start])) start += 1;
    while (end > start && /\s/.test(source[end - 1])) end -= 1;
    if (clean[start] === "(") {
      let depth = 0;
      let closesAtEnd = false;
      for (let index = start; index < end; index += 1) {
        if (clean[index] === "(") depth += 1;
        else if (clean[index] === ")") {
          depth -= 1;
          if (depth === 0) {
            closesAtEnd = index === end - 1;
            break;
          }
        }
      }
      if (closesAtEnd) return logicalLeaves(start + 1, end - 1, fallbackReplacement);
    }
    for (const operator of ["||", "&&"]) {
      const separators = [];
      let round = 0;
      let square = 0;
      let brace = 0;
      for (let index = start; index < end - 1; index += 1) {
        if (clean[index] === "(") round += 1;
        else if (clean[index] === ")") round -= 1;
        else if (clean[index] === "[") square += 1;
        else if (clean[index] === "]") square -= 1;
        else if (clean[index] === "{") brace += 1;
        else if (clean[index] === "}") brace -= 1;
        if (round === 0 && square === 0 && brace === 0 && clean.startsWith(operator, index)) {
          separators.push(index);
          index += 1;
        }
      }
      if (!separators.length) continue;
      const replacement = operator === "||" ? "false" : "true";
      const result = [];
      let segmentStart = start;
      for (const separator of separators) {
        result.push(...logicalLeaves(segmentStart, separator, replacement));
        segmentStart = separator + 2;
      }
      result.push(...logicalLeaves(segmentStart, end, replacement));
      return result;
    }
    return [{ start, end, replacement: fallbackReplacement }];
  }
  const pattern = /\bif\s*\(/g;
  for (const match of clean.matchAll(pattern)) {
    const open = clean.indexOf("(", match.index);
    let depth = 0;
    let close = open;
    for (; close < clean.length; close += 1) {
      if (clean[close] === "(") depth += 1;
      else if (clean[close] === ")") {
        depth -= 1;
        if (depth === 0) break;
      }
    }
    if (depth !== 0) throw new Error(`unterminated changed predicate at ${javascriptFile}:${lineForOffset(starts, open)}`);
    const firstLine = lineForOffset(starts, match.index);
    const lastLine = lineForOffset(starts, close);
    if (![...changed].some((line) => line >= firstLine && line <= lastLine)) continue;
    const branchPredicate = source.slice(open + 1, close);
    if (/process\.env\.[A-Z0-9_]*(?:_TEST|TEST_)/.test(branchPredicate)) continue;
    if (branchPredicate.includes("retentionInvalidMarkerTestGateUsed")) continue;
    for (const leaf of logicalLeaves(open + 1, close)) {
      const predicate = source.slice(leaf.start, leaf.end).replace(/\s+/g, " ").trim();
      predicates.push({
        file: javascriptFile,
        source,
        start: leaf.start,
        end: leaf.end,
        line: lineForOffset(starts, leaf.start),
        predicate,
        replacement: leaf.replacement,
      });
    }
  }
  return predicates;
}

function pythonPredicates() {
  const changed = [...changedLines(pythonFile)];
  const program = String.raw`
import ast, json, sys
source = open(sys.argv[1], encoding="utf-8").read()
changed = set(json.loads(sys.argv[2]))
tree = ast.parse(source)
lines = source.splitlines(keepends=True)
offsets = [0]
for line in lines:
    offsets.append(offsets[-1] + len(line))
parents = {}
for parent in ast.walk(tree):
    for child in ast.iter_child_nodes(parent):
        parents[child] = parent

hook_names = set()
for node in ast.walk(tree):
    if not isinstance(node, (ast.Assign, ast.AnnAssign)):
        continue
    value = node.value
    if not isinstance(value, ast.Call) or not value.args:
        continue
    if not isinstance(value.args[0], ast.Constant) or not isinstance(value.args[0].value, str):
        continue
    if "FM_" not in value.args[0].value or "TEST" not in value.args[0].value:
        continue
    targets = node.targets if isinstance(node, ast.Assign) else [node.target]
    for target in targets:
        if isinstance(target, ast.Name):
            hook_names.add(target.id)

def uses_hook_name(test):
    return any(isinstance(item, ast.Name) and item.id in hook_names for item in ast.walk(test))

def test_hook(node):
    current = node
    while current in parents:
        current = parents[current]
        if isinstance(current, ast.If) and uses_hook_name(current.test):
            return True
    return uses_hook_name(node.test)

result = []
def logical_leaves(test, fallback=False):
    if isinstance(test, ast.BoolOp):
        replacement = True if isinstance(test.op, ast.And) else False
        leaves = []
        for value in test.values:
            leaves.extend(logical_leaves(value, replacement))
        return leaves
    return [(test, fallback)]

for node in ast.walk(tree):
    if not isinstance(node, ast.If):
        continue
    test = node.test
    if not any(line in changed for line in range(test.lineno, test.end_lineno + 1)):
        continue
    if test_hook(node):
        continue
    for leaf, replacement in logical_leaves(test):
        start = offsets[leaf.lineno - 1] + leaf.col_offset
        end = offsets[leaf.end_lineno - 1] + leaf.end_col_offset
        result.append({"start": start, "end": end, "line": leaf.lineno, "predicate": ast.get_source_segment(source, leaf), "replacement": replacement})
print(json.dumps(result))
`;
  const parsed = spawnSync("python3", ["-c", program, pythonFile, JSON.stringify(changed)], { encoding: "utf8" });
  if (parsed.status !== 0) throw new Error(`could not derive Python predicates: ${parsed.stderr}`);
  const source = fs.readFileSync(pythonFile, "utf8");
  return JSON.parse(parsed.stdout).map((item) => ({ ...item, file: pythonFile, source, predicate: item.predicate.replace(/\s+/g, " ").trim() }));
}

const predicates = [...javascriptPredicates(), ...pythonPredicates()];
if (predicates.length < 40) throw new Error(`changed-control predicate derivation was unexpectedly narrow (${predicates.length})`);
fs.mkdirSync(mutantRoot, { recursive: true });
const jobs = [];
for (const [index, predicate] of predicates.entries()) {
  for (const replacement of [predicate.replacement]) {
    const directory = path.join(mutantRoot, `${String(index + 1).padStart(3, "0")}-${replacement}`);
    const bin = path.join(directory, "bin");
    fs.mkdirSync(bin, { recursive: true });
    const javascript = predicate.file === javascriptFile
      ? predicate.source.slice(0, predicate.start) + replacement + predicate.source.slice(predicate.end)
      : fs.readFileSync(javascriptFile, "utf8");
    const python = predicate.file === pythonFile
      ? predicate.source.slice(0, predicate.start) + (replacement === "true" ? "True" : "False") + predicate.source.slice(predicate.end)
      : fs.readFileSync(pythonFile, "utf8");
    const executable = path.join(bin, "fm-report-stack.mjs");
    fs.writeFileSync(executable, javascript);
    fs.writeFileSync(path.join(bin, "fm-contained-read.py"), python);
    fs.copyFileSync(parserFile, path.join(bin, "fm-markdown-structure.cjs"));
    fs.chmodSync(executable, 0o755);
    fs.chmodSync(path.join(bin, "fm-contained-read.py"), 0o755);
    jobs.push({ index, predicate, replacement, executable });
  }
}

function runContract(executable) {
  return new Promise((resolve) => {
    const child = spawn("bash", [suite], {
      env: { ...process.env, FM_TEST_FOCUSED: "retention-mutant-contract", FM_REPORT_STACK_SCRIPT_OVERRIDE: executable },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let output = "";
    let timedOut = false;
    child.stdout.on("data", (chunk) => { output += chunk; });
    child.stderr.on("data", (chunk) => { output += chunk; });
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGKILL");
    }, 900000);
    child.on("close", (status, signal) => {
      clearTimeout(timer);
      resolve({ status, signal, timedOut, output });
    });
  });
}

async function main() {
  const positive = await runContract(javascriptFile);
  if (positive.status !== 0) throw new Error(`changed-control positive controls failed:\n${positive.output}`);

  const results = new Array(jobs.length);
  let nextJob = 0;
  async function worker() {
    while (true) {
      const jobIndex = nextJob;
      nextJob += 1;
      if (jobIndex >= jobs.length) return;
      results[jobIndex] = await runContract(jobs[jobIndex].executable);
    }
  }
  await Promise.all(Array.from({ length: Math.min(8, jobs.length) }, () => worker()));

  const failures = [];
  for (const [jobIndex, job] of jobs.entries()) {
    const result = results[jobIndex];
    const reason = result.output.split("\n").find((line) => line.startsWith("not ok -"));
    if (result.status === 0 || !reason) {
      failures.push(`${path.relative(root, job.predicate.file)}:${job.predicate.line} ${job.replacement} survived status=${result.status} signal=${result.signal || ""} timedOut=${result.timedOut}`);
      continue;
    }
    job.reason = reason.replace(/^not ok -\s*/, "").slice(0, 180);
  }
  if (failures.length) throw new Error(`uncovered or unexecuted changed-control mutants:\n${failures.join("\n")}`);

  for (const [index, predicate] of predicates.entries()) {
    const falseJob = jobs[index];
    process.stdout.write(`ok - executed mutant ${path.relative(root, predicate.file)}:${predicate.line} predicate=${JSON.stringify(predicate.predicate)} replacement=${falseJob.replacement} red=${JSON.stringify(falseJob.reason)}\n`);
  }
}
main().catch((error) => { console.error(error.stack || error.message); process.exit(1); });
NODE
  pass "complete changed control flow has executed red mutants"
}

test_invalid_retention_configuration_is_admitted_before_validation() {
  local stack="$TMP_ROOT/retention-invalid-configuration-stack" first second status
  write_retention_scale_fixture "$stack" 1 1 valid
  if first=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_COHORT_MS=invalid FM_REPORT_RETENTION_INTERVAL=3600 \
    "$SCRIPT" prune --status 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "invalid retention configuration unexpectedly succeeded"
  assert_contains "$first" "FM_REPORT_RETENTION_COHORT_MS must be a positive integer" \
    "invalid retention configuration did not fail at its validation boundary"
  assert_present "$stack/.retention-attempt.json" \
    "invalid retention configuration failed before recording scheduled admission"
  second=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_COHORT_MS=invalid FM_REPORT_RETENTION_INTERVAL=3600 \
    "$SCRIPT" prune --status) \
    || fail "invalid retention configuration retried before its admission interval"
  assert_contains "$second" '"admitted":false,"reason":"cadence"' \
    "invalid retention configuration was eligible again on the immediate next loop"
  pass "configuration validation cannot bypass scheduled retention admission"
}

test_retention_admission_and_lock_share_root_generation() {
  local stack="$TMP_ROOT/retention-root-generation-stack" old_stack="$TMP_ROOT/retention-root-generation-old"
  local ready="$TMP_ROOT/retention-root-generation.ready" proceed="$TMP_ROOT/retention-root-generation.proceed"
  local output="$TMP_ROOT/retention-root-generation.out" state contender pid status
  mkdir -p "$stack/entries/cohort-1"
  mkfifo "$ready" "$proceed"
  exec 7<>"$ready"
  exec 8<>"$proceed"
  FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 FM_REPORT_RETENTION_ADMITTED_TEST_READY="$ready" \
    FM_REPORT_RETENTION_ADMITTED_TEST_PROCEED="$proceed" \
    "$SCRIPT" prune --status > "$output" 2>&1 &
  pid=$!
  if ! IFS= read -r -t 10 state <&7; then
    kill -TERM "$pid" 2>/dev/null || true
    fail "root-generation fixture did not reach the post-admission boundary: $(cat "$output")"
  fi
  [ "$state" = "attempt-admitted" ] || fail "root-generation fixture emitted an unexpected state: $state"
  mv "$stack" "$old_stack"
  mkdir -p "$stack/entries/cohort-1"
  printf 'continue\n' >&8
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "retention accepted a replacement stack root after admission"
  assert_grep "report stack root generation changed between retention admission and publication lock acquisition" \
    "$output" "retention did not refuse the root generation disagreement"
  assert_present "$old_stack/.retention-attempt.json" "admission record was not bound to the original stack generation"
  assert_absent "$old_stack/.publish.lock" "original stack generation received a lock after its path was replaced"
  assert_absent "$stack/.publish.lock" "replacement stack generation received an unadmitted lock"

  contender=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_RETENTION_INTERVAL=3600 FM_REPORT_LOCK_TEST_SETUP_FAILURE=1 \
    "$SCRIPT" prune --status) \
    || fail "replacement generation did not observe the root-independent admission"
  assert_contains "$contender" '"admitted":false,"reason":"cadence"' \
    "replacement root generation split the fleet admission namespace"
  assert_absent "$stack/.retention-attempt.json" "replacement generation installed a second local admission"
  assert_absent "$old_stack/.publish.lock" "root swap split the admitted attempt across lock namespaces"
  exec 7>&-; exec 8>&-
  pass "retention admission and publication lock remain on one root generation"
}

test_retention_restores_expired_entries_when_index_swap_fails() {
  local id=report-retention-rollback-k2f entry out status tombstone index
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Retention rollback content."
  run_stack publish "$id" >/dev/null || fail "retention rollback precondition publication failed"
  entry=$(run_stack path "$id") || fail "retention rollback precondition path failed"
  entry=$(expire_report_entry "$entry") || fail "retention rollback fixture could not be aged"
  rm -f "$STACK/index.html"
  mkdir "$STACK/index.html"
  if out=$(run_stack render 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "retention unexpectedly replaced an unsafe report index destination"
  assert_absent "$(dirname "$entry")" "failed retention index swap restored an expired entry"
  tombstone=$(find "$STACK/.retention-tombstones" -mindepth 1 -maxdepth 1 -type d -name 'tombstone-*' -print -quit)
  [ -n "$tombstone" ] || fail "failed retention index swap lost its durable deletion tombstone"
  assert_present "$tombstone" "failed retention index swap lost its durable deletion tombstone"
  rmdir "$STACK/index.html"
  for index in $(seq 1 100); do
    run_stack prune --force >/dev/null || fail "retention could not resume a deletion tombstone"
    [ ! -e "$tombstone" ] && break
  done
  assert_absent "$tombstone" "resumed retention kept a completed deletion tombstone"
  [ -n "$out" ] || true
  pass "report retention preserves deletion tombstones across index failures"
}

test_retention_batches_make_interruption_safe_progress() {
  local id entry output index tombstone
  local -a entries
  for index in 1 2 3; do
    id="report-retention-batch-$index-k2l"
    write_task "$id" ship
    write_required_report "$HOME_DIR/data/$id/completion.md" "Expired batch $index."
    run_stack publish "$id" >/dev/null || fail "retention batch precondition $index failed"
    entry=$(run_stack path "$id") || fail "retention batch path $index failed"
    entries[index]="$entry"
  done
  for index in 1 2 3; do
    entries[index]=$(expire_report_entry "${entries[index]}") \
      || fail "retention batch fixture $index could not be aged"
  done
  output=$(FM_REPORT_RETENTION_BATCH=1 run_stack prune --status --force) || fail "first bounded retention batch failed"
  assert_contains "$output" '"pending":true' "bounded retention did not advertise remaining work"
  tombstone=$(find "$STACK/.retention-tombstones" -mindepth 1 -maxdepth 1 -type d -name 'tombstone-*' -print -quit)
  [ -n "$tombstone" ] || fail "bounded retention did not retain its pending tombstone"
  for index in 1 2 3; do
    assert_absent "$(dirname "${entries[index]}")" \
      "bounded retention left due report $index live after its visibility transaction"
  done
  assert_no_grep 'report-retention-batch-' "$STACK/index.html" \
    "bounded retention left a due report in the current index"
  for index in $(seq 1 100); do
    output=$(FM_REPORT_RETENTION_BATCH=1 run_stack prune --status --force) || fail "retention progress batch $index failed"
    case "$output" in *'"pending":false'*) break ;; esac
  done
  assert_absent "$tombstone" "bounded retention did not finish its expired cohort tombstone"
  pass "report retention removes every due report before bounded tombstone cleanup"
}

test_persistent_retention_owner_prunes_without_tasks_or_watcher() {
  local id=report-retention-owner-k2m entry fakebin install_root agents heartbeat out status bash_runtime node_runtime python_runtime plist log
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Persistent-owner expiry."
  run_stack publish "$id" >/dev/null || fail "persistent retention owner precondition failed"
  entry=$(run_stack path "$id") || fail "persistent retention owner path failed"
  entry=$(expire_report_entry "$entry") || fail "persistent retention fixture could not be aged"
  fakebin="$TMP_ROOT/retention-launchctl"; install_root="$TMP_ROOT/retention-install"; agents="$TMP_ROOT/LaunchAgents"
  log="$TMP_ROOT/launchctl.log"
  mkdir -p "$fakebin" "$agents"
  : > "$log"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_LAUNCHCTL_LOG"
case "${1:-}" in print|bootstrap|kickstart) exit 0 ;; bootout) exit 1 ;; esac
SH
  chmod +x "$fakebin/launchctl"
  FM_GATE_REFUSE_BYPASS=1 FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-bootstrap.sh" install report-retention >/dev/null \
    || fail "retention LaunchAgent installation through bootstrap failed"
  node_runtime=$(command -v node)
  python_runtime=$(command -v python3)
  bash_runtime=$(command -v bash)
  plist="$agents/com.firstmate.report-retention.plist"
  assert_grep "<string>$bash_runtime</string>" "$plist" \
    "retention LaunchAgent did not persist the absolute Bash runtime"
  assert_grep "<key>FM_REPORT_RETENTION_NODE</key><string>$node_runtime</string>" "$plist" \
    "retention LaunchAgent did not persist the absolute Node runtime"
  assert_grep "<key>FM_REPORT_PYTHON</key><string>$python_runtime</string>" "$plist" \
    "retention LaunchAgent did not persist the absolute Python runtime"
  assert_grep "<key>FM_REPORT_RETENTION_COHORT_MS</key><string>${FM_REPORT_RETENTION_COHORT_MS:-300000}</string>" "$plist" \
    "retention LaunchAgent did not pin the publisher cohort width"
  assert_absent "$(dirname "$entry")" "installed retention owner did not enforce retention"
  heartbeat="$STACK/.retention-heartbeat"
  assert_present "$heartbeat" "installed retention owner did not record a successful-prune heartbeat"
  FM_GATE_REFUSE_BYPASS=1 FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" ensure || fail "healthy installed retention owner was rejected"
  temp="$heartbeat.tmp"
  { printf '1\n'; sed -n '2p' "$heartbeat"; } > "$temp"
  mv "$temp" "$heartbeat"
  if out=$(FM_GATE_REFUSE_BYPASS=1 FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" ensure 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "stale successful-prune heartbeat was accepted"
  assert_contains "$out" "heartbeat is stale" "stale retention heartbeat refusal was unclear"
  assert_grep 'bootstrap' "$log" "retention install did not bootstrap its LaunchAgent"
  assert_grep 'kickstart' "$log" "retention install did not start its LaunchAgent"
  pass "restart-capable retention installation is stable, task-independent, and health-checked"
}

test_retention_activation_restores_previous_generation_on_failure() {
  local fakebin install_root agents marker plist saved_plist out status failure failure_command node_runtime fail_marker fake_node log
  fakebin="$TMP_ROOT/retention-transaction-launchctl"
  install_root="$TMP_ROOT/retention-transaction-install"
  agents="$TMP_ROOT/retention-transaction-agents"
  marker="$install_root/bin/previous-generation-marker"
  plist="$agents/com.firstmate.report-retention.plist"
  saved_plist="$TMP_ROOT/retention-transaction-previous.plist"
  fake_node="$TMP_ROOT/retention-transaction-failing-node"
  log="$TMP_ROOT/retention-transaction.log"
  mkdir -p "$fakebin" "$agents"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_LAUNCHCTL_LOG"
if [ "${1:-}" = "${FM_FAKE_LAUNCHCTL_FAIL_COMMAND:-none}" ] \
  && [ ! -e "$FM_FAKE_LAUNCHCTL_FAIL_MARKER" ]; then
  : > "$FM_FAKE_LAUNCHCTL_FAIL_MARKER"
  exit 1
fi
case "${1:-}" in print|bootstrap|kickstart) exit 0 ;; bootout) exit 1 ;; esac
SH
  chmod +x "$fakebin/launchctl"
  cat > "$fake_node" <<'SH'
#!/usr/bin/env bash
echo 'synthetic first-prune failure'
exit 1
SH
  chmod +x "$fake_node"
  FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    FM_FAKE_LAUNCHCTL_FAIL_COMMAND=none FM_FAKE_LAUNCHCTL_FAIL_MARKER="$TMP_ROOT/unused-retention-failure" \
    "$ROOT/bin/fm-report-retention.sh" install >/dev/null \
    || fail "retention transaction precondition installation failed"
  printf 'previous generation\n' > "$marker"
  cp "$plist" "$saved_plist"
  for failure in bootstrap kickstart prune; do
    fail_marker="$TMP_ROOT/retention-$failure.failure-used"
    rm -f "$fail_marker"
    : > "$log"
    failure_command=$failure
    node_runtime=
    if [ "$failure" = prune ]; then
      failure_command=none
      node_runtime=$fake_node
    fi
    if out=$(FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
      FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
      FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
      FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
      FM_FAKE_LAUNCHCTL_FAIL_COMMAND="$failure_command" FM_FAKE_LAUNCHCTL_FAIL_MARKER="$fail_marker" \
      FM_REPORT_RETENTION_NODE="$node_runtime" "$ROOT/bin/fm-report-retention.sh" install 2>&1); then status=0; else status=$?; fi
    [ "$status" -ne 0 ] || fail "$failure retention activation unexpectedly succeeded"
    assert_contains "$out" "previous generation restored" "$failure retention activation rollback was not reported"
    assert_present "$marker" "$failure retention activation discarded the previous owner bundle"
    cmp -s "$saved_plist" "$plist" || fail "$failure retention activation did not restore the previous LaunchAgent"
    assert_grep 'bootstrap' "$log" "$failure retention rollback did not re-bootstrap the prior LaunchAgent"
    assert_grep 'kickstart' "$log" "$failure retention rollback did not restart the prior LaunchAgent"
  done
  FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    FM_FAKE_LAUNCHCTL_FAIL_COMMAND=none FM_FAKE_LAUNCHCTL_FAIL_MARKER="$TMP_ROOT/unused-retention-failure" \
    "$ROOT/bin/fm-report-retention.sh" install >/dev/null \
    || fail "healthy retention replacement failed after rollback checks"
  assert_absent "$marker" "healthy retention replacement kept the superseded generation after its first prune"
  assert_present "$STACK/.retention-heartbeat" "healthy retention replacement removed the previous generation before its first-prune heartbeat"
  pass "retention activation keeps and restores the prior healthy generation"
}

test_retention_install_recovers_interrupted_generation_transaction() {
  local fakebin install_root agents marker plist saved_plist log out status transaction
  fakebin="$TMP_ROOT/retention-crash-launchctl"
  install_root="$TMP_ROOT/retention-crash-install"
  agents="$TMP_ROOT/retention-crash-agents"
  marker="$install_root/bin/previous-generation-marker"
  plist="$agents/com.firstmate.report-retention.plist"
  saved_plist="$TMP_ROOT/retention-crash-previous.plist"
  log="$TMP_ROOT/retention-crash.log"
  transaction="$install_root/.install-transaction"
  mkdir -p "$fakebin" "$agents"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_LAUNCHCTL_LOG"
case "${1:-}" in print|bootstrap|kickstart) exit 0 ;; bootout) exit 1 ;; esac
SH
  chmod +x "$fakebin/launchctl"
  FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" install >/dev/null \
    || fail "retention crash-recovery precondition installation failed"
  printf 'previous generation\n' > "$marker"
  cp "$plist" "$saved_plist"

  if out=$(FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    FM_REPORT_RETENTION_INSTALL_TEST_INTERRUPT=plist-published \
    "$ROOT/bin/fm-report-retention.sh" install 2>&1); then status=0; else status=$?; fi
  [ "$status" -eq 99 ] || fail "retention installation interruption hook did not strand its transaction: $out"
  assert_present "$transaction" "interrupted retention installation did not persist its recovery transaction"
  assert_absent "$marker" "interrupted retention installation did not replace the canonical bundle before recovery"

  FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" ensure \
    || fail "retention ensure did not recover an interrupted installation"
  assert_present "$marker" "retention recovery did not restore the previous owner bundle"
  cmp -s "$saved_plist" "$plist" || fail "retention recovery did not restore the previous LaunchAgent"
  assert_absent "$transaction" "retention recovery left its completed install transaction"
  [ -z "$(find "$install_root" "$agents" -maxdepth 1 -name '*.previous.*' -print -quit)" ] \
    || fail "retention recovery left previous-generation backups"
  assert_grep 'bootstrap' "$log" "retention recovery did not re-bootstrap the previous LaunchAgent"
  assert_grep 'kickstart' "$log" "retention recovery did not restart the previous LaunchAgent"
  pass "retention install transactions recover the prior generation after interruption"
}

test_retention_install_and_recovery_share_owned_generation_lock() {
  local fakebin install_root agents log transaction snapshot ready release used
  local installer ensure_pid second_pid owner generation token unchanged=1 live_ensure=1 live_second=1
  local installer_status ensure_status second_status
  fakebin="$TMP_ROOT/retention-race-launchctl"
  install_root="$TMP_ROOT/retention-race-install"
  agents="$TMP_ROOT/retention-race-agents"
  log="$TMP_ROOT/retention-race.log"
  transaction="$install_root/.install-transaction"
  snapshot="$TMP_ROOT/retention-race.transaction"
  ready="$TMP_ROOT/retention-race.ready"
  release="$TMP_ROOT/retention-race.release"
  used="$TMP_ROOT/retention-race.used"
  mkdir -p "$fakebin" "$agents"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_LAUNCHCTL_LOG"
if [ "${1:-}" = bootstrap ] && [ ! -e "$FM_FAKE_BLOCK_USED" ]; then
  : > "$FM_FAKE_BLOCK_USED"
  : > "$FM_FAKE_BLOCK_READY"
  while [ ! -e "$FM_FAKE_BLOCK_RELEASE" ]; do sleep 0.05; done
fi
case "${1:-}" in print|bootstrap|kickstart) exit 0 ;; bootout) exit 1 ;; esac
SH
  chmod +x "$fakebin/launchctl"
  FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    FM_FAKE_BLOCK_USED="$used" FM_FAKE_BLOCK_READY="$ready" FM_FAKE_BLOCK_RELEASE="$release" \
    "$ROOT/bin/fm-report-retention.sh" install > "$TMP_ROOT/retention-race-first.out" 2>&1 &
  installer=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.05; done
  [ -e "$ready" ] && [ -f "$transaction" ] \
    || { touch "$release"; wait "$installer" 2>/dev/null || true; fail "live retention installer did not reach its owned transaction"; }
  cp "$transaction" "$snapshot"
  owner=$(sed -n '5p' "$transaction")
  generation=$(sed -n '7p' "$transaction")
  token=$(sed -n '2p' "$transaction")

  FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    FM_FAKE_BLOCK_USED="$used" FM_FAKE_BLOCK_READY="$ready" FM_FAKE_BLOCK_RELEASE="$release" \
    "$ROOT/bin/fm-report-retention.sh" ensure > "$TMP_ROOT/retention-race-ensure.out" 2>&1 &
  ensure_pid=$!
  FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    FM_FAKE_BLOCK_USED="$used" FM_FAKE_BLOCK_READY="$ready" FM_FAKE_BLOCK_RELEASE="$release" \
    "$ROOT/bin/fm-report-retention.sh" install > "$TMP_ROOT/retention-race-second.out" 2>&1 &
  second_pid=$!
  sleep 0.2
  cmp -s "$snapshot" "$transaction" || unchanged=0
  kill -0 "$ensure_pid" 2>/dev/null || live_ensure=0
  kill -0 "$second_pid" 2>/dev/null || live_second=0
  touch "$release"
  if wait "$installer"; then installer_status=0; else installer_status=$?; fi
  if wait "$ensure_pid"; then ensure_status=0; else ensure_status=$?; fi
  if wait "$second_pid"; then second_status=0; else second_status=$?; fi

  [ "$owner" = "$installer" ] || fail "retention transaction did not record its installer owner"
  [ "$generation" = "$token" ] || fail "retention transaction generation did not bind its backup token"
  [ "$unchanged" -eq 1 ] || fail "a concurrent install overwrote the live installer's transaction generation"
  [ "$live_ensure" -eq 1 ] || fail "ensure raced through recovery while the installer was live"
  [ "$live_second" -eq 1 ] || fail "a concurrent install bypassed global serialization"
  [ "$installer_status" -eq 0 ] && [ "$ensure_status" -eq 0 ] && [ "$second_status" -eq 0 ] \
    || fail "serialized retention install/ensure operations did not all complete successfully"
  assert_absent "$transaction" "serialized retention operations left a transaction marker"
  assert_absent "$install_root/.install-lock" "serialized retention operations left the global install lock"
  pass "retention install and recovery serialize on one owned transaction generation"
}

test_retention_error_publication_is_atomic_and_nonfollowing() {
  local stack fake_node outside out status
  stack="$TMP_ROOT/retention-error-stack"
  fake_node="$TMP_ROOT/retention-failing-node"
  outside="$TMP_ROOT/retention-error-outside"
  mkdir -p "$stack"
  printf 'outside bytes\n' > "$outside"
  ln -s "$outside" "$stack/.retention-error"
  cat > "$fake_node" <<'SH'
#!/usr/bin/env bash
echo 'synthetic prune failure'
exit 1
SH
  chmod +x "$fake_node"
  if out=$(FM_REPORT_STACK_ROOT="$stack" FM_REPORT_RETENTION_NODE="$fake_node" \
    FM_REPORT_RETENTION_INTERVAL=1 "$ROOT/bin/fm-report-retention.sh" run-once 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "retention error publication unexpectedly accepted a symlink control path"
  assert_contains "$out" "unsafe report-retention error control file" "unsafe retention error refusal was unclear"
  [ "$(cat "$outside")" = "outside bytes" ] \
    || fail "retention error publication followed and changed a symlink target"
  [ -L "$stack/.retention-error" ] || fail "retention error publication replaced an unsafe control symlink"
  pass "retention errors publish atomically without following control symlinks"
}

test_report_destination_roots_remain_pinned_during_ancestor_swap() {
  local id=report-destination-race-k2n ready proceed output moved outside pid status published_manifest state
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Pinned destination roots."
  ready="$TMP_ROOT/report-destination.ready"; proceed="$TMP_ROOT/report-destination.proceed"
  output="$TMP_ROOT/report-destination.out"; moved="$TMP_ROOT/stack-original"; outside="$TMP_ROOT/stack-outside"
  mkdir -p "$STACK" "$outside"
  mkfifo "$ready" "$proceed"
  exec 7<>"$ready"
  exec 8<>"$proceed"
  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_STACK_DESTINATION_TEST_READY="$ready" FM_REPORT_STACK_DESTINATION_TEST_PROCEED="$proceed" \
    "$SCRIPT" publish "$id" > "$output" 2>&1 &
  pid=$!
  if ! IFS= read -r -t 10 state <&7; then
    kill -TERM "$pid" 2>/dev/null || true
    fail "report destination race gate did not open: $(cat "$output")"
  fi
  [ "$state" = "destination-pinned" ] || fail "report destination gate emitted an unexpected state: $state"
  mv "$STACK" "$moved"
  ln -s "$outside" "$STACK"
  printf 'continue\n' >&8
  wait "$pid"; status=$?
  [ "$status" -eq 0 ] || fail "pinned report publication failed after ancestor swap: $(cat "$output")"
  published_manifest=$(grep -R -l -F "\"taskId\": \"$id\"" "$moved/entries")
  [ -n "$published_manifest" ] || fail "pinned report publication did not retain its task manifest"
  assert_grep 'Pinned destination roots.' "$(dirname "$published_manifest")/report.md" \
    "report publication left the originally pinned destination"
  [ -z "$(find "$outside" -mindepth 1 -print -quit)" ] || fail "report publication was redirected through the swapped stack path"
  rm "$STACK"
  mv "$moved" "$STACK"
  exec 7>&-; exec 8>&-
  pass "report stack serializes and publishes through pinned destination roots"
}

test_report_publication_gate_uses_framed_fifo() {
  local id=report-publish-fifo-k2na ready proceed output pid status staged entry
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Framed report publication."
  ready="$TMP_ROOT/report-publish-fifo.ready"; proceed="$TMP_ROOT/report-publish-fifo.proceed"
  output="$TMP_ROOT/report-publish-fifo.out"
  mkfifo "$ready" "$proceed"
  exec 7<>"$ready"
  exec 8<>"$proceed"
  FM_CONTAINED_REPORT_PUBLISH_TEST_READY="$ready" FM_CONTAINED_REPORT_PUBLISH_TEST_PROCEED="$proceed" \
    run_stack publish "$id" > "$output" 2>&1 &
  pid=$!
  if ! IFS= read -r -t 10 staged <&7; then
    kill -TERM "$pid" 2>/dev/null || true
    fail "report publication FIFO did not emit its staged generation: $(cat "$output")"
  fi
  case "$staged" in ".$id-"*.tmp) ;; *) fail "report publication FIFO emitted an unexpected frame: $staged" ;; esac
  printf 'continue\n' >&8
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -eq 0 ] || fail "framed report publication failed: $(cat "$output")"
  entry=$(run_stack path "$id") || fail "framed report publication did not install a report"
  assert_grep 'Framed report publication.' "$(dirname "$entry")/report.md" \
    "framed report publication installed the wrong generation"
  exec 7>&-; exec 8>&-
  pass "report publication synchronization uses a framed one-shot FIFO"
}

test_index_failure_restores_previous_generation() {
  local id=report-index-rollback-k3 entry invalid out status
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Original generation."
  run_stack publish "$id" >/dev/null || fail "index rollback precondition failed"
  entry=$(run_stack path "$id")
  invalid="$(dirname "$(dirname "$entry")")/invalid-manifest"
  mkdir -p "$invalid"
  printf '{invalid\n' > "$invalid/manifest.json"
  write_required_report "$HOME_DIR/data/$id/completion.md" "Replacement generation."

  out=$(run_stack publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "publication unexpectedly succeeded with an unreadable index manifest"
  assert_grep 'Original generation' "$(dirname "$entry")/report.md" "failed index rendering did not restore the previous report generation"
  if grep -F 'Replacement generation' "$(dirname "$entry")/report.md" >/dev/null 2>&1; then
    fail "failed index rendering retained the unindexed replacement generation"
  fi
  rm -rf "$invalid"
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
  wait "$reader" || fail "report reader failed after the publication lock was released: $(cat "$TMP_ROOT/locked-reader.err")"
  pass "report readers hold the publication lock while resolving entries"
}

test_busy_lock_error_names_holder_identity_and_age() {
  local short_root="$TMP_ROOT/report-lock-diagnostic-short" executable ready proceed
  local STACK="$TMP_ROOT/report-lock-diagnostic-stack"
  local owner_output="$TMP_ROOT/report-lock-diagnostic-owner.out"
  local waiter_output="$TMP_ROOT/report-lock-diagnostic-waiter.out"
  local legacy_output="$TMP_ROOT/report-lock-diagnostic-legacy.out"
  local guard_output="$TMP_ROOT/report-lock-diagnostic-guard.out"
  local ownerless_output="$TMP_ROOT/report-lock-diagnostic-ownerless.out"
  local owner_pid owner_state owner_status waiter_status legacy_status guard_status ownerless_status
  local started control
  mkdir -p "$STACK"
  write_report_stack_mutant "$short_root" \
    'const reportLockWaitMs = 60_000;' \
    'const reportLockWaitMs = 250;'
  executable="$short_root/bin/fm-report-stack.mjs"
  ready="$TMP_ROOT/report-lock-diagnostic.ready"
  proceed="$TMP_ROOT/report-lock-diagnostic.proceed"
  mkfifo "$ready" "$proceed"
  exec 7<>"$ready"; exec 8<>"$proceed"
  FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_LOCK_TEST_READY="$ready" FM_REPORT_LOCK_TEST_PROCEED="$proceed" \
    "$executable" prune --force --status > "$owner_output" 2>&1 &
  owner_pid=$!
  if ! IFS= read -r -t 10 owner_state <&7; then
    kill -TERM "$owner_pid" 2>/dev/null || true
    wait "$owner_pid" 2>/dev/null || true
    fail "report lock diagnostic owner did not acquire the publication lock: $(cat "$owner_output")"
  fi
  if [ "$owner_state" != "lock-acquired" ]; then
    printf 'continue\n' >&8
    wait "$owner_pid" 2>/dev/null || true
    exec 7>&-; exec 8>&-
    fail "report lock diagnostic owner emitted an unexpected state: $owner_state"
  fi

  if FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$STACK" \
    "$executable" list --json > "$waiter_output" 2>&1; then
    waiter_status=0
  else
    waiter_status=$?
  fi
  printf 'continue\n' >&8
  if wait "$owner_pid"; then owner_status=0; else owner_status=$?; fi
  exec 7>&-; exec 8>&-
  [ "$owner_status" -eq 0 ] || fail "report lock diagnostic owner failed: $(cat "$owner_output")"
  [ "$waiter_status" -ne 0 ] || fail "report lock diagnostic waiter unexpectedly crossed the held publication lock"

  started=$(LC_ALL=C ps -p "$$" -o lstart= | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]][[:space:]]*/ /g')
  mkdir "$STACK/.publish.lock"
  printf '{"pid":%s,"startedAt":"%s"}\n' "$$" "$started" > "$STACK/.publish.lock/owner"
  if FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$STACK" \
    "$executable" list --json > "$legacy_output" 2>&1; then
    legacy_status=0
  else
    legacy_status=$?
  fi
  rm -rf "$STACK/.publish.lock"

  printf '{"pid":%s,"startedAt":"%s","token":"diagnostic-guard"}\n' "$$" "$started" \
    > "$STACK/.publish.lock.reclaim"
  if FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$STACK" \
    "$executable" list --json > "$guard_output" 2>&1; then
    guard_status=0
  else
    guard_status=$?
  fi
  rm -f "$STACK/.publish.lock.reclaim"

  mkdir "$STACK/.publish.lock"
  if FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$STACK" \
    "$executable" list --json > "$ownerless_output" 2>&1; then
    ownerless_status=0
  else
    ownerless_status=$?
  fi
  rm -rf "$STACK/.publish.lock"

  if control=$(FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$STACK" \
    "$executable" list --json 2>&1); then
    :
  else
    fail "report lock diagnostic positive control could not cross the released boundary: $control"
  fi
  [ "$legacy_status" -ne 0 ] || fail "legacy report lock unexpectedly crossed the held publication lock"
  [ "$guard_status" -ne 0 ] || fail "report reclaim guard unexpectedly crossed the held publication boundary"
  [ "$ownerless_status" -ne 0 ] || fail "ownerless report lock unexpectedly crossed the held publication lock"

  node - "$waiter_output" "$legacy_output" "$guard_output" "$ownerless_output" "$owner_pid" "$$" <<'NODE' \
    || fail "busy holder diagnostic payload did not satisfy the boundary contract"
const fs = require("fs");
const [currentFile, legacyFile, guardFile, ownerlessFile, ownerPidText, shellPidText] = process.argv.slice(2);
const marker = "; holder ";
function holder(file) {
  const line = fs.readFileSync(file, "utf8").split(/\r?\n/)
    .find((candidate) => candidate.includes("report stack is busy at .publish.lock; holder "));
  if (!line) throw new Error(`busy refusal omitted structured holder diagnostics in ${file}`);
  return JSON.parse(line.slice(line.indexOf(marker) + marker.length));
}
const current = holder(currentFile);
if (current.resource !== "publication-lock" || current.kind !== "identified") {
  throw new Error(`busy refusal did not identify the publication lock holder: ${JSON.stringify(current)}`);
}
if (current.pid !== Number(ownerPidText) || current.operation !== "prune --force --status") {
  throw new Error(`busy refusal named the wrong holder: ${JSON.stringify(current)}`);
}
if (current.liveness !== "live" || typeof current.processStartedAt !== "string" || !current.processStartedAt) {
  throw new Error(`busy refusal omitted the holder process generation or liveness: ${JSON.stringify(current)}`);
}
if (!Number.isSafeInteger(current.acquiredAtMs) || !Number.isSafeInteger(current.ageMs)
  || current.ageMs < 0 || current.ageBasis !== "recorded-acquisition") {
  throw new Error(`busy refusal omitted the measured lock-hold age: ${JSON.stringify(current)}`);
}
const legacy = holder(legacyFile);
if (legacy.resource !== "publication-lock" || legacy.kind !== "identified"
  || legacy.pid !== Number(shellPidText) || legacy.operation !== "unknown"
  || legacy.acquiredAtMs !== null || !Number.isSafeInteger(legacy.ageMs)
  || legacy.ageBasis !== "resource-generation") {
  throw new Error(`legacy busy refusal did not make its acquisition-time limit explicit: ${JSON.stringify(legacy)}`);
}
const guard = holder(guardFile);
if (guard.resource !== "reclaim-guard" || guard.kind !== "identified"
  || guard.pid !== Number(shellPidText) || !Number.isSafeInteger(guard.ageMs)
  || guard.ageBasis !== "resource-generation") {
  throw new Error(`reclaim-guard refusal did not identify its holder and age: ${JSON.stringify(guard)}`);
}
const ownerless = holder(ownerlessFile);
if (ownerless.resource !== "publication-lock" || ownerless.kind !== "legacy-unowned"
  || ownerless.identity !== "unknown" || ownerless.liveness !== "legacy-unowned"
  || !Number.isSafeInteger(ownerless.ageMs) || ownerless.ageBasis !== "resource-generation"
  || typeof ownerless.reason !== "string" || !ownerless.reason) {
  throw new Error(`ownerless busy refusal claimed unsupported identity evidence: ${JSON.stringify(ownerless)}`);
}
NODE
  pass "busy report-lock refusals name the live holder identity and measured age"
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

if [ "${FM_TEST_FOCUSED:-}" = lock-diagnostics ]; then
  test_busy_lock_error_names_holder_identity_and_age
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = retention-noop-benchmark ]; then
  test_noop_retention_skips_helpers_and_publication_lock_at_scale
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = retention-admission-core ]; then
  test_retention_admission_bounds_total_fleet_attempts_above_current_population
  test_failed_retention_attempt_is_ineligible_on_the_next_loop
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-10 ]; then
  test_stale_lock_rejects_reused_pid
  test_stale_lock_reclaim_is_serialized
  test_abandoned_reclaim_marker_is_recovered
  test_publish_lock_directory_symlink_fails_closed
  test_lock_control_files_are_bounded_and_nonfollowing
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = retention-root-boundary ]; then
  test_root_retention_admission_preserves_newer_bucket
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
  test_text_sources_are_stored_verbatim_and_completion_is_bounded
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
  test_completed_reports_prune_after_minimum_age
  test_retention_restores_expired_entries_when_index_swap_fails
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-23 ]; then
  test_report_artifacts_remain_verbatim_across_key_shaped_content
  test_container_scoped_fences_do_not_close_from_top_level
  test_retention_binds_manifests_to_entry_directories
  test_watcher_periodically_owns_idle_report_retention
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-24 ]; then
  test_large_non_utf8_text_artifacts_are_stored_verbatim
  test_large_visual_inventory_does_not_share_text_buffer_headroom
  test_container_scopes_preserve_commonmark_blank_and_exit_rules
  test_retention_restores_expired_entries_when_index_swap_fails
  test_retention_batches_make_interruption_safe_progress
  test_persistent_retention_owner_prunes_without_tasks_or_watcher
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-25 ]; then
  test_list_lazy_continuations_do_not_satisfy_required_sections
  test_persistent_retention_owner_prunes_without_tasks_or_watcher
  test_report_destination_roots_remain_pinned_during_ancestor_swap
  exit 0
fi

test_lazy_list_blocks_retain_their_container_scope() {
  local id=report-lazy-block-scope-b3p source entry manifest
  write_task "$id" ship
  source="$HOME_DIR/data/$id/completion.md"
  cat > "$source" <<'EOF'
# Completion

- list paragraph
  ```text
  ## Hidden heading
  ```
## Summary

Visible summary.

## What changed

Changed.

## Verification

Verified.

## Visual evidence

None.

## Artifacts

None.

## Follow-ups

None.
EOF
  run_stack publish "$id" >/dev/null || fail "a lazy-list fence consumed headings after the list ended"
  entry=$(run_stack path "$id") || fail "lazy-list fence report path failed"
  manifest="$(dirname "$entry")/manifest.json"
  assert_grep '"summary": "Visible summary."' "$manifest" "lazy-list fence did not release its container scope"
  pass "lazy-list fenced blocks retain and exit their actual container scope"
}

test_contained_reader_rejects_special_files_without_blocking() {
  local root="$TMP_ROOT/contained-special" fifo output status pid
  mkdir -p "$root"
  fifo="$root/source"
  mkfifo "$fifo"
  output="$TMP_ROOT/contained-special.out"
  (
    cd "$root" || exit 1
    python3 "$ROOT/bin/fm-contained-read.py" read-fd source 1024 strict 3< "$root"
  ) > "$output" 2>&1 &
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "contained reader blocked while opening a FIFO"
  fi
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "contained reader accepted a FIFO"
  assert_contains "$(cat "$output")" "not a real regular file" "contained reader special-file refusal was unclear"
  pass "contained reads reject special files before nonblocking open"
}

test_report_contract_and_task_transaction_reject_fifos_without_blocking() {
  local root="$TMP_ROOT/task-special" fifo output pid status
  mkdir -p "$root/data/task"
  fifo="$root/data/task/brief.md"; mkfifo "$fifo"; output="$root/out"
  FM_GATE_REFUSE_BYPASS=1 bash -c '. "$1/bin/fm-report-contract-lib.sh"; fm_completion_report_contract_present "$2"' \
    _ "$ROOT" "$fifo" > "$output" 2>&1 &
  pid=$!
  for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.02; done
  if kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fail "report contract blocked on FIFO"; fi
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "report contract accepted FIFO"
  node - "$ROOT/bin/fm-file-transaction.cjs" "$root/data" > "$output" 2>&1 <<'JS' &
const { pinnedTaskFileTransaction } = require(process.argv[2]);
pinnedTaskFileTransaction(process.argv[3], 'task', 'brief.md', content => content);
JS
  pid=$!
  for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.02; done
  if kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fail "task transaction blocked on FIFO"; fi
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "task transaction accepted FIFO"
  pass "task-file readers reject special files before nonblocking open"
}

test_report_entry_manifest_reads_stay_on_pinned_generation() {
  local id=report-entry-pin-z30c stack entry moved outside ready proceed output pid status
  stack="$TMP_ROOT/entry-pin-stack"
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Pinned manifest content."
  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" "$SCRIPT" publish "$id" >/dev/null \
    || fail "entry-pin publication failed"
  entry=$(dirname "$(FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" "$SCRIPT" path "$id")") \
    || fail "entry-pin path failed"
  moved="$TMP_ROOT/pinned-entry"; outside="$TMP_ROOT/outside-entry"; mkdir -p "$outside"
  printf '{"outside":true}\n' > "$outside/manifest.json"
  ready="$TMP_ROOT/entry-pin.ready"; proceed="$TMP_ROOT/entry-pin.proceed"; output="$TMP_ROOT/entry-pin.out"
  FM_HOME="$HOME_DIR" FM_REPORT_STACK_ROOT="$stack" \
    FM_REPORT_ENTRY_TEST_READY="$ready" FM_REPORT_ENTRY_TEST_PROCEED="$proceed" \
    "$SCRIPT" list --json > "$output" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.02; done
  [ -e "$ready" ] || { kill -TERM "$pid" 2>/dev/null || true; fail "entry manifest pin gate did not open"; }
  mv "$entry" "$moved"; ln -s "$outside" "$entry"; touch "$proceed"
  if wait "$pid"; then status=0; else status=$?; fi
  rm "$entry"; mv "$moved" "$entry"
  [ "$status" -eq 0 ] || fail "pinned manifest read failed: $(cat "$output")"
  assert_no_grep '"outside": true' "$output" "manifest read followed a swapped entry ancestor"
  pass "report manifests are read relative to pinned entry descriptors"
}

test_repository_fingerprint_recurses_through_submodule_worktrees() {
  local root="$TMP_ROOT/fingerprint-root" paths="$TMP_ROOT/fingerprint-paths" first second
  mkdir -p "$root/submodule/nested"
  printf 'first\n' > "$root/submodule/nested/file.txt"
  printf 'submodule\0' > "$paths"
  first=$(python3 "$ROOT/bin/fm-contained-read.py" fingerprint-paths-fd "$paths" 3< "$root") \
    || fail "initial descriptor-relative repository fingerprint failed"
  printf 'second\n' > "$root/submodule/nested/file.txt"
  second=$(python3 "$ROOT/bin/fm-contained-read.py" fingerprint-paths-fd "$paths" 3< "$root") \
    || fail "updated descriptor-relative repository fingerprint failed"
  [ "$first" != "$second" ] || fail "nested dirty submodule content did not change repository identity"
  assert_contains "$second" "submodule/nested/file.txt" "recursive repository identity omitted nested submodule content"
  pass "repository identity traverses pinned roots and dirty submodule content"
}

test_retention_cutoff_is_authoritative_before_cleanup() {
  local id=report-retention-cutoff-k2q second=report-retention-cutoff-k2r fresh=report-retention-fresh-k2q
  local entry second_entry fresh_entry ready output policy cutoff
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Cutoff-visible report."
  run_stack publish "$id" >/dev/null || fail "cutoff precondition publication failed"
  entry=$(run_stack path "$id") || fail "cutoff precondition path failed"
  write_task "$fresh" ship
  write_required_report "$HOME_DIR/data/$fresh/completion.md" "Fresh report."
  run_stack publish "$fresh" >/dev/null || fail "fresh cutoff precondition publication failed"
  fresh_entry=$(run_stack path "$fresh") || fail "fresh cutoff precondition path failed"
  entry=$(expire_report_entry "$entry") || fail "retention cutoff fixture could not be aged"
  write_task "$second" ship
  write_required_report "$HOME_DIR/data/$second/completion.md" "Second cutoff-visible report."
  run_stack publish "$second" >/dev/null || fail "second cutoff precondition publication failed"
  second_entry=$(run_stack path "$second") || fail "second cutoff precondition path failed"
  second_entry=$(expire_report_entry "$second_entry" '1999-12-31T00:00:00.000Z') \
    || fail "second retention cutoff fixture could not be aged"
  ready="$TMP_ROOT/retention-policy.ready"; output="$TMP_ROOT/retention-policy.out"
  if FM_REPORT_RETENTION_POLICY_TEST_READY="$ready" FM_REPORT_RETENTION_POLICY_TEST_ABORT=1 \
    run_stack prune --status --force > "$output" 2>&1; then
    fail "retention namespace interruption hook unexpectedly completed"
  fi
  assert_present "$ready" "retention cutoff publication hook did not run"
  assert_absent "$(dirname "$entry")" "expired raw artifacts remained in the public namespace after the cutoff milestone"
  assert_absent "$(dirname "$second_entry")" "a later due cohort remained public after the atomic cutoff milestone"
  assert_present "$(dirname "$fresh_entry")" "fresh report became unavailable while an expired cohort was retired"
  policy="$STACK/.retention-policy.js"
  assert_present "$policy" "retention did not atomically publish its cutoff generation and index"
  assert_grep 'window.firstmateRetentionPolicy={"schemaVersion":1,"generation":"' "$policy" \
    "retention authority omitted its cutoff generation"
  cutoff=$(sed -n 's/.*"cutoffMs":\([0-9]*\).*/\1/p' "$policy")
  [ -n "$cutoff" ] && [ "$cutoff" -gt 946684800000 ] \
    || fail "retention authority did not hide the expired report before scanning manifests"
  assert_absent "$(dirname "$entry")" "interrupted retention restored expired raw artifacts"
  assert_absent "$(dirname "$second_entry")" "interrupted retention restored a later expired cohort"
  run_stack prune --status --force >/dev/null || fail "retention did not recover its interrupted namespace generation"
  assert_absent "$(dirname "$entry")" "retention cutoff cleanup left the expired report live"
  assert_present "$(dirname "$fresh_entry")" "retention cleanup removed an unrelated fresh cohort"
  assert_no_grep "$id" "$STACK/index.html" "completed retention rendering left an expired report visible"
  pass "retention atomically retires due cohorts without interrupting fresh reports"
}

test_retention_cohort_tombstone_is_noreplace_owned() {
  local id=report-retention-cohort-race-k2s entry source retired retired_name tombstone ready proceed output pid status
  id=report-retention-cohort-race-k2s
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Cohort rename race."
  run_stack publish "$id" >/dev/null || fail "cohort rename race precondition publication failed"
  entry=$(run_stack path "$id") || fail "cohort rename race path failed"
  entry=$(expire_report_entry "$entry") || fail "cohort rename fixture could not be aged"
  source=$(dirname "$(dirname "$entry")")
  ready="$TMP_ROOT/cohort-rename.ready"; proceed="$TMP_ROOT/cohort-rename.proceed"; output="$TMP_ROOT/cohort-rename.out"
  FM_CONTAINED_RENAME_TEST_READY="$ready" FM_CONTAINED_RENAME_TEST_PROCEED="$proceed" \
    run_stack prune --status --force > "$output" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.02; done
  [ -e "$ready" ] || { kill -TERM "$pid" 2>/dev/null || true; fail "cohort no-replace gate did not open"; }
  tombstone="$STACK/.retention-tombstones/$(cat "$ready")"
  retired_name=$(sed -n 's/.*"retiredName":"\([^"]*\)".*/\1/p' "$STACK/.retention-cutover.json")
  retired="$STACK/$retired_name"
  [ -n "$retired_name" ] || fail "cohort retirement did not retain its cutover identity"
  mkdir "$tombstone"; printf 'replacement\n' > "$tombstone/sentinel"
  touch "$proceed"
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "cohort retirement replaced a concurrently created tombstone"
  assert_present "$retired" "failed cohort retirement lost its uncommitted retired namespace"
  assert_grep replacement "$tombstone/sentinel" "cohort retirement mutated a replacement tombstone"
  rm -rf "$retired" "$tombstone" "$source"
  rm -f "$STACK/.retention-cutover.json"
  pass "retention cohort retirement is no-replace and generation-owned"
}

test_retention_cohort_source_swap_restores_replacement() {
  local source="$TMP_ROOT/cohort-source-swap" original="$TMP_ROOT/cohort-source-original"
  local tombstones="$TMP_ROOT/cohort-source-tombstones" ready="$TMP_ROOT/cohort-source.ready"
  local proceed="$TMP_ROOT/cohort-source.proceed" output="$TMP_ROOT/cohort-source.out" pid status identity
  mkdir -p "$source" "$tombstones"
  printf 'original\n' > "$source/sentinel"
  identity=$(if [ "$(uname)" = Darwin ]; then stat -f '%d:%i' "$source"; else stat -c '%d:%i' "$source"; fi)
  FM_CONTAINED_RENAME_TEST_READY="$ready" FM_CONTAINED_RENAME_TEST_PROCEED="$proceed" \
    python3 "$ROOT/bin/fm-contained-read.py" rename-noreplace-owned-fd \
      "$(basename "$source")" tombstone "$identity" 3< "$(dirname "$source")" 4< "$tombstones" \
      > "$output" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.02; done
  [ -e "$ready" ] || { kill -TERM "$pid" 2>/dev/null || true; fail "owned source-swap gate did not open"; }
  mv "$source" "$original"
  mkdir "$source"
  printf 'replacement\n' > "$source/sentinel"
  touch "$proceed"
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "owned cohort rename accepted a swapped source generation"
  assert_grep replacement "$source/sentinel" "swapped source generation was not restored to its public name"
  assert_grep original "$original/sentinel" "original owned generation was changed during the race"
  assert_absent "$tombstones/tombstone" "swapped source generation remained stranded in tombstones"
  pass "owned cohort retirement restores a replacement raced through rename"
}

test_retention_handoff_persists_and_retries_old_owner_fencing() {
  local fakebin="$TMP_ROOT/retention-handoff-launchctl" install_root="$TMP_ROOT/retention-handoff-install"
  local agents="$TMP_ROOT/retention-handoff-agents" log="$TMP_ROOT/retention-handoff.log" output status old_label
  mkdir -p "$fakebin" "$agents"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_LAUNCHCTL_LOG"
case "${1:-}" in
  print|bootstrap|kickstart) exit 0 ;;
  bootout) [ "${FM_FAKE_BOOTOUT_FAIL:-0}" != 1 ] || exit 1; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/launchctl"
  if ! output=$(FM_REPORT_RETENTION_INSTALL_TEST_SIMULATE_LAUNCH=1 FM_REPORT_RETENTION_PLATFORM=Darwin \
    FM_REPORT_STACK_ROOT="$STACK" FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" install 2>&1); then
    fail "retention handoff precondition installation failed: $output; retention error: $(cat "$STACK/.retention-error" 2>/dev/null)"
  fi
  old_label=$(sed -n 's/.*<key>Label<\/key><string>\([^<]*\)<\/string>.*/\1/p' \
    "$agents/com.firstmate.report-retention.plist")
  if output=$(FM_REPORT_RETENTION_INSTALL_TEST_SIMULATE_LAUNCH=1 FM_REPORT_RETENTION_PLATFORM=Darwin \
    FM_REPORT_STACK_ROOT="$STACK" FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" FM_FAKE_BOOTOUT_FAIL=1 \
    "$ROOT/bin/fm-report-retention.sh" install 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "retention handoff completed while the previous owner remained loaded"
  assert_contains "$output" "previous owner fencing is pending" "unfenced previous owner failure was unclear"
  assert_present "$install_root/.owner-handoff-fence" "unfenced previous owner lacked a durable retry record"
  assert_grep "bootout gui/$(id -u)/$old_label" "$log" "retention handoff did not attempt to fence the previous owner"
  FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" FM_REPORT_RETENTION_INTERVAL=1 \
    FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" \
    FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" \
    FM_FAKE_LAUNCHCTL_LOG="$log" "$ROOT/bin/fm-report-retention.sh" ensure \
    || fail "retention ensure did not retry previous-owner fencing"
  assert_absent "$install_root/.owner-handoff-fence" "successful retry retained the previous-owner fence"
  pass "retention handoff persists and retries previous-owner fencing"
}

test_failed_initial_retention_activation_disarms_plist() {
  local fakebin="$TMP_ROOT/retention-initial-failure-launchctl" install_root="$TMP_ROOT/retention-initial-failure-install"
  local agents="$TMP_ROOT/retention-initial-failure-agents" log="$TMP_ROOT/retention-initial-failure.log"
  local plist out status
  mkdir -p "$fakebin" "$agents"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_LAUNCHCTL_LOG"
case "${1:-}" in print|bootstrap|kickstart) exit 0 ;; bootout) exit 1 ;; esac
SH
  chmod +x "$fakebin/launchctl"
  plist="$agents/com.firstmate.report-retention.plist"
  if out=$(FM_REPORT_RETENTION_INSTALL_TEST_SIMULATE_LAUNCH='' \
    FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_ACTIVATION_WAIT_MS=100 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" install 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "first retention installation unexpectedly accepted missing launched health"
  assert_contains "$out" "activation failed" "first-install activation failure was not reported"
  assert_absent "$plist" "failed first retention installation left an unproven reboot-armed plist"
  assert_grep 'bootout' "$log" "failed first retention installation did not unload its replacement job"
  pass "failed first retention installation removes its owned canonical plist"
}

test_retention_activation_wait_budget_accepts_delayed_health() {
  local fakebin="$TMP_ROOT/retention-delayed-launchctl" install_root="$TMP_ROOT/retention-delayed-install"
  local agents="$TMP_ROOT/retention-delayed-agents" log="$TMP_ROOT/retention-delayed.log"
  mkdir -p "$fakebin" "$agents"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_LAUNCHCTL_LOG"
case "${1:-}" in
  print|bootstrap) exit 0 ;;
  kickstart)
    (
      sleep 5.5
      temp="$FM_REPORT_STACK_ROOT/.retention-heartbeat.delayed.$$"
      printf '%s\n%s\n%s\n%s\n' "$(date +%s)" "$FM_REPORT_RETENTION_EXPECTED_PROVENANCE" \
        "$FM_REPORT_RETENTION_EXPECTED_NONCE" "delayed-$$" > "$temp"
      mv -f "$temp" "$FM_REPORT_STACK_ROOT/.retention-heartbeat"
    ) &
    exit 0
    ;;
  bootout) exit 1 ;;
esac
SH
  chmod +x "$fakebin/launchctl"
  FM_REPORT_RETENTION_INSTALL_TEST_SIMULATE_LAUNCH='' \
    FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_ACTIVATION_WAIT_MS=7000 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" install >/dev/null \
    || fail "retention activation rejected health inside its configured wait budget"
  assert_present "$agents/com.firstmate.report-retention.plist" \
    "successful delayed retention activation removed its canonical plist"
  pass "retention activation honors its explicit launched-health wait budget"
}

test_bounded_report_reads_reject_fifo_swaps_without_blocking() {
  local id=bounded-read-race-z31 transaction saved ready proceed output pid status
  transaction="$STACK/entries/.$id.transaction"
  saved="$TMP_ROOT/bounded-read-race.transaction"
  ready="$TMP_ROOT/bounded-read-race.ready"
  proceed="$TMP_ROOT/bounded-read-race.proceed"
  output="$TMP_ROOT/bounded-read-race.out"
  printf '{"schemaVersion":1,"reportId":"%s","hadPrevious":false}\n' "$id" > "$transaction"
  FM_REPORT_BOUNDED_READ_TEST_READY="$ready" FM_REPORT_BOUNDED_READ_TEST_PROCEED="$proceed" \
    run_stack render > "$output" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.02; done
  [ -e "$ready" ] || { kill -TERM "$pid" 2>/dev/null || true; fail "bounded report read race gate did not open"; }
  mv "$transaction" "$saved"
  mkfifo "$transaction"
  touch "$proceed"
  for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.02; done
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "bounded report read blocked after a regular file became a FIFO"
  fi
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "bounded report read accepted a FIFO replacement"
  assert_contains "$(cat "$output")" "stable real regular file" \
    "bounded report read FIFO refusal was unclear"
  rm -f "$transaction"
  pass "bounded report reads open nonblocking and reject FIFO swaps"
}

test_retention_activation_requires_launched_nonce_without_owner_gap() {
  local fakebin="$TMP_ROOT/retention-nonce-launchctl" install_root="$TMP_ROOT/retention-nonce-install"
  local agents="$TMP_ROOT/retention-nonce-agents" log="$TMP_ROOT/retention-nonce.log"
  local plist saved old_label out status
  mkdir -p "$fakebin" "$agents"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_LAUNCHCTL_LOG"
case "${1:-}" in print|bootstrap|kickstart) exit 0 ;; bootout) exit 1 ;; esac
SH
  chmod +x "$fakebin/launchctl"
  plist="$agents/com.firstmate.report-retention.plist"
  FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" install >/dev/null \
    || fail "retention activation-nonce precondition installation failed"
  old_label=$(sed -n 's/.*<key>Label<\/key><string>\([^<]*\)<\/string>.*/\1/p' "$plist")
  saved="$TMP_ROOT/retention-nonce-prior.plist"
  cp "$plist" "$saved"
  : > "$log"
  if out=$(FM_REPORT_RETENTION_INSTALL_TEST_SIMULATE_LAUNCH='' \
    FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" install 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "retention activation reused its preflight heartbeat"
  assert_contains "$out" "activation failed" "missing launched heartbeat refusal was unclear"
  if grep -F "bootout gui/$(id -u)/$old_label" "$log" >/dev/null 2>&1; then
    fail "retention activation unloaded the working owner before replacement health"
  fi
  cmp -s "$saved" "$plist" \
    || fail "failed retention activation did not preserve its authoritative prior plist"
  pass "retention activation overlaps owners and requires a launched-job nonce"
}

test_retention_accepts_runatload_heartbeat_after_prebootstrap_baseline() {
  local fakebin="$TMP_ROOT/retention-bootstrap-heartbeat-launchctl"
  local install_root="$TMP_ROOT/retention-bootstrap-heartbeat-install"
  local agents="$TMP_ROOT/retention-bootstrap-heartbeat-agents"
  mkdir -p "$fakebin" "$agents"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in print|bootstrap|kickstart) exit 0 ;; bootout) exit 1 ;; esac
SH
  chmod +x "$fakebin/launchctl"
  FM_REPORT_RETENTION_INSTALL_TEST_SIMULATE_LAUNCH='' \
    FM_REPORT_RETENTION_INSTALL_TEST_SIMULATE_BOOTSTRAP=1 \
    FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" \
    "$ROOT/bin/fm-report-retention.sh" install >/dev/null \
    || fail "retention rejected a RunAtLoad heartbeat produced after bootstrap"
  assert_present "$agents/com.firstmate.report-retention.plist" \
    "retention did not publish the owner proven healthy during bootstrap"
  pass "retention activation baselines health before bootstrap RunAtLoad"
}

test_retention_pointer_failure_retires_only_candidate() {
  local fakebin="$TMP_ROOT/retention-pointer-failure-launchctl"
  local install_root="$TMP_ROOT/retention-pointer-failure-install"
  local agents="$TMP_ROOT/retention-pointer-failure-agents" log="$TMP_ROOT/retention-pointer-failure.log"
  local plist saved_plist saved_heartbeat old_label out status generations
  mkdir -p "$fakebin" "$agents"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_LAUNCHCTL_LOG"
case "${1:-}" in print|bootstrap|kickstart|bootout) exit 0 ;; esac
SH
  chmod +x "$fakebin/launchctl"
  plist="$agents/com.firstmate.report-retention.plist"
  FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" install >/dev/null \
    || fail "retention pointer-failure precondition installation failed"
  saved_plist="$TMP_ROOT/retention-pointer-failure.saved.plist"
  saved_heartbeat="$TMP_ROOT/retention-pointer-failure.saved.heartbeat"
  cp "$plist" "$saved_plist"; cp "$STACK/.retention-heartbeat" "$saved_heartbeat"
  old_label=$(sed -n 's/.*<key>Label<\/key><string>\([^<]*\)<\/string>.*/\1/p' "$plist")
  : > "$log"
  if out=$(FM_REPORT_RETENTION_INSTALL_TEST_FAIL_POINTER=1 \
    FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" install 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "retention pointer publication failure unexpectedly succeeded"
  assert_contains "$out" "pointer publication failed" "retention pointer failure diagnostic was unclear"
  cmp -s "$saved_plist" "$plist" || fail "pointer failure changed the authoritative prior plist"
  cmp -s "$saved_heartbeat" "$STACK/.retention-heartbeat" || fail "pointer failure changed the authoritative prior heartbeat"
  if grep -F "bootout gui/$(id -u)/$old_label" "$log" >/dev/null 2>&1; then
    fail "pointer failure booted out the authoritative prior owner"
  fi
  assert_grep 'bootout ' "$log" "pointer failure did not retire its candidate owner"
  generations=$(find "$install_root/generations" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  [ "$generations" -eq 1 ] || fail "pointer failure retained candidate staging or generation state"
  pass "retention pointer failure preserves the authoritative owner and heartbeat"
}

test_retention_pointer_failure_retains_unfenced_candidate() {
  local fakebin="$TMP_ROOT/retention-unfenced-launchctl" install_root="$TMP_ROOT/retention-unfenced-install"
  local agents="$TMP_ROOT/retention-unfenced-agents" log="$TMP_ROOT/retention-unfenced.log"
  local plist saved_plist saved_heartbeat out status generations
  mkdir -p "$fakebin" "$agents"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_LAUNCHCTL_LOG"
case "${1:-}" in
  print|bootstrap|kickstart) exit 0 ;;
  bootout) [ "${FM_FAKE_BOOTOUT_FAIL:-}" != 1 ] ;;
esac
SH
  chmod +x "$fakebin/launchctl"
  plist="$agents/com.firstmate.report-retention.plist"
  FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" install >/dev/null \
    || fail "unfenced-candidate precondition installation failed"
  saved_plist="$TMP_ROOT/retention-unfenced.saved.plist"
  saved_heartbeat="$TMP_ROOT/retention-unfenced.saved.heartbeat"
  cp "$plist" "$saved_plist"; cp "$STACK/.retention-heartbeat" "$saved_heartbeat"
  if out=$(FM_REPORT_RETENTION_INSTALL_TEST_FAIL_POINTER=1 FM_FAKE_BOOTOUT_FAIL=1 \
    FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" install 2>&1); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "unfenced candidate pointer failure unexpectedly succeeded"
  assert_contains "$out" "candidate fencing is pending" "unfenced candidate failure was unclear"
  cmp -s "$saved_plist" "$plist" || fail "unfenced candidate replaced the authoritative plist"
  cmp -s "$saved_heartbeat" "$STACK/.retention-heartbeat" \
    && fail "unfenced candidate restored the prior heartbeat before bootout"
  assert_present "$install_root/.candidate-fence" "unfenced candidate lost its durable recovery record"
  generations=$(find "$install_root/generations" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  [ "$generations" -eq 2 ] || fail "unfenced candidate executable generation was removed"
  FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" ensure >/dev/null \
    || fail "later ensure could not finish candidate fencing"
  cmp -s "$saved_heartbeat" "$STACK/.retention-heartbeat" \
    || fail "successful later fencing did not restore the prior heartbeat"
  assert_absent "$install_root/.candidate-fence" "successful later fencing retained its recovery record"
  generations=$(find "$install_root/generations" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  [ "$generations" -eq 1 ] || fail "successful later fencing retained the candidate generation"
  pass "pointer failure retains candidates until bootout is positively confirmed"
}

test_retention_install_recovers_owned_stale_reclaim_marker() {
  local fakebin="$TMP_ROOT/retention-reclaim-launchctl" install_root="$TMP_ROOT/retention-reclaim-install"
  local agents="$TMP_ROOT/retention-reclaim-agents" reclaim="$TMP_ROOT/retention-reclaim-install/.install-lock-reclaim"
  mkdir -p "$fakebin" "$agents" "$install_root"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in print|bootstrap|kickstart) exit 0 ;; bootout) exit 1 ;; esac
SH
  chmod +x "$fakebin/launchctl"
  printf '999999\nMon Jan  1 00:00:00 2001\nstale-reclaim-generation\n' > "$reclaim"
  FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" \
    "$ROOT/bin/fm-report-retention.sh" install >/dev/null \
    || fail "retention install did not recover a positively stale reclaim owner"
  assert_absent "$reclaim" "retention install retained an abandoned owned reclaim marker"
  pass "retention install reclaim markers are owned and stale-recoverable"
}

test_retention_reclaim_never_removes_replacement_generation() {
  local fakebin="$TMP_ROOT/retention-reclaim-race-launchctl" install_root="$TMP_ROOT/retention-reclaim-race-install"
  local agents="$TMP_ROOT/retention-reclaim-race-agents" reclaim="$install_root/.install-lock-reclaim"
  local ready="$TMP_ROOT/retention-reclaim-race.ready" proceed="$TMP_ROOT/retention-reclaim-race.proceed"
  local replacement="$TMP_ROOT/retention-reclaim-race.replacement" output="$TMP_ROOT/retention-reclaim-race.out"
  local started installer status
  mkdir -p "$fakebin" "$agents" "$install_root"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/launchctl"; chmod +x "$fakebin/launchctl"
  printf '999999\nMon Jan  1 00:00:00 2001\nstale-reclaim-generation\n' > "$reclaim"
  started=$(LC_ALL=C ps -o lstart= -p "$$" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  printf '%s\n%s\n%s\n' "$$" "$started" live-reclaim-generation > "$replacement"
  FM_CONTAINED_REMOVE_TEST_READY="$ready" FM_CONTAINED_REMOVE_TEST_PROCEED="$proceed" \
    FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" \
    "$ROOT/bin/fm-report-retention.sh" install > "$output" 2>&1 &
  installer=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.02; done
  [ -e "$ready" ] || { kill -TERM "$installer" 2>/dev/null || true; fail "retention reclaim removal gate did not open"; }
  mv -f "$replacement" "$reclaim"
  touch "$proceed"
  if wait "$installer"; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "retention install bypassed a live replacement reclaim owner"
  [ "$(sed -n '3p' "$reclaim")" = live-reclaim-generation ] \
    || fail "retention stale reclaim deleted or overwrote a replacement generation"
  pass "retention reclaim removes only the observed stale inode"
}

test_retention_generations_survive_install_interruptions() {
  local fakebin="$TMP_ROOT/retention-launchctl" install_root="$TMP_ROOT/retention-install"
  local agents="$TMP_ROOT/LaunchAgents" plist old_program new_program saved status out
  plist="$agents/com.firstmate.report-retention.plist"
  old_program=$(sed -n '/<key>ProgramArguments<\/key>/,/<\/array>/s/.*<string>\([^<]*\)<\/string>.*/\1/p' "$plist" | sed -n '2p')
  assert_present "$old_program" "retention precondition generation is missing"
  saved="$TMP_ROOT/retention-old.plist"
  cp "$plist" "$saved"
  if out=$(FM_GATE_REFUSE_BYPASS=1 FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$TMP_ROOT/launchctl.log" \
    FM_REPORT_RETENTION_INSTALL_TEST_INTERRUPT=generation-published \
    "$ROOT/bin/fm-report-retention.sh" install 2>&1); then status=0; else status=$?; fi
  [ "$status" -eq 99 ] || fail "generation publication interrupt hook failed: $out"
  cmp -s "$saved" "$plist" || fail "publishing an immutable generation changed the authoritative job early"
  assert_present "$old_program" "generation publication moved the runnable prior owner"

  if out=$(FM_GATE_REFUSE_BYPASS=1 FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$TMP_ROOT/launchctl.log" \
    FM_REPORT_RETENTION_INSTALL_TEST_INTERRUPT=pointer-published \
    "$ROOT/bin/fm-report-retention.sh" install 2>&1); then status=0; else status=$?; fi
  [ "$status" -eq 99 ] || fail "authoritative pointer interrupt hook failed: $out"
  new_program=$(sed -n '/<key>ProgramArguments<\/key>/,/<\/array>/s/.*<string>\([^<]*\)<\/string>.*/\1/p' "$plist" | sed -n '2p')
  [ "$new_program" != "$old_program" ] || fail "authoritative retention pointer did not advance generations"
  assert_present "$new_program" "authoritative retention pointer references an incomplete generation"
  assert_present "$old_program" "authoritative retention transition removed its prior runnable generation"
  pass "retention installation atomically points at immutable reboot-safe generations"
}

test_retention_install_reclaims_positively_stale_lock() {
  local fakebin="$TMP_ROOT/retention-launchctl" install_root="$TMP_ROOT/retention-install"
  local agents="$TMP_ROOT/LaunchAgents" lock="$TMP_ROOT/retention-install/.install-lock"
  printf '999999\nMon Jan  1 00:00:00 2001\nstale-install-token\n' > "$lock"
  FM_GATE_REFUSE_BYPASS=1 FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$TMP_ROOT/launchctl.log" \
    "$ROOT/bin/fm-report-retention.sh" ensure \
    || fail "retention ensure did not reclaim a positively stale install lock"
  assert_absent "$lock" "retention ensure retained its reclaimed install lock"
  pass "retention installation reclaims only a positively stale owned lock"
}

test_retention_prepointer_recovery_fences_candidate() {
  local fakebin="$TMP_ROOT/retention-prepointer-launchctl" install_root="$TMP_ROOT/retention-prepointer-install"
  local agents="$TMP_ROOT/retention-prepointer-agents" log="$TMP_ROOT/retention-prepointer.log"
  local plist old_label candidate_label out status
  mkdir -p "$fakebin" "$agents"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_LAUNCHCTL_LOG"
case "${1:-}" in print|bootstrap|kickstart|bootout) exit 0 ;; esac
exit 0
SH
  chmod +x "$fakebin/launchctl"
  plist="$agents/com.firstmate.report-retention.plist"
  FM_REPORT_RETENTION_INSTALL_TEST_SIMULATE_LAUNCH=1 FM_REPORT_RETENTION_PLATFORM=Darwin \
    FM_REPORT_STACK_ROOT="$STACK" FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" install >/dev/null \
    || fail "retention pre-pointer recovery precondition failed"
  old_label=$(sed -n 's/.*<key>Label<\/key><string>\([^<]*\)<\/string>.*/\1/p' "$plist")
  if out=$(FM_REPORT_RETENTION_INSTALL_TEST_SIMULATE_LAUNCH=1 FM_REPORT_RETENTION_PLATFORM=Darwin \
    FM_REPORT_STACK_ROOT="$STACK" FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    FM_REPORT_RETENTION_INSTALL_TEST_INTERRUPT=owner-handoff-prepointer \
    "$ROOT/bin/fm-report-retention.sh" install 2>&1); then status=0; else status=$?; fi
  [ "$status" -eq 99 ] || fail "retention pre-pointer interruption hook failed: $out"
  [ "$(sed -n 's/.*<key>Label<\/key><string>\([^<]*\)<\/string>.*/\1/p' "$plist")" = "$old_label" ] \
    || fail "retention pre-pointer interruption advanced the authoritative plist"
  assert_absent "$install_root/.candidate-fence" \
    "retention pre-pointer handoff retained duplicate candidate ownership"
  candidate_label=$(sed -n '4p' "$install_root/.owner-handoff-fence")
  FM_REPORT_RETENTION_PLATFORM=Darwin FM_REPORT_STACK_ROOT="$STACK" \
    FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" ensure >/dev/null \
    || fail "retention ensure did not recover its pre-pointer handoff"
  assert_grep "bootout gui/$(id -u)/$candidate_label" "$log" \
    "pre-pointer recovery did not fence the running candidate"
  assert_absent "$install_root/.owner-handoff-fence" "pre-pointer recovery retained its handoff fence"
  pass "retention pre-pointer recovery fences the uncommitted candidate"
}

test_retention_candidate_is_fenced_before_bootstrap() {
  local fakebin="$TMP_ROOT/retention-candidate-launchctl" install_root="$TMP_ROOT/retention-candidate-install"
  local agents="$TMP_ROOT/retention-candidate-agents" log="$TMP_ROOT/retention-candidate.log"
  local candidate_label out status
  mkdir -p "$fakebin" "$agents"
  : > "$log"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_LAUNCHCTL_LOG"
case "${1:-}" in print|bootstrap|kickstart|bootout) exit 0 ;; esac
exit 0
SH
  chmod +x "$fakebin/launchctl"
  if out=$(FM_REPORT_RETENTION_INSTALL_TEST_SIMULATE_LAUNCH=1 FM_REPORT_RETENTION_PLATFORM=Darwin \
    FM_REPORT_STACK_ROOT="$STACK" FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    FM_REPORT_RETENTION_INSTALL_TEST_INTERRUPT=candidate-fenced \
    "$ROOT/bin/fm-report-retention.sh" install 2>&1); then status=0; else status=$?; fi
  [ "$status" -eq 99 ] || fail "retention candidate-fence interruption hook failed: $out"
  assert_present "$install_root/.candidate-fence" "candidate ownership was not durable before bootstrap"
  candidate_label=$(sed -n '2p' "$install_root/.candidate-fence")
  assert_no_grep "bootstrap .*${candidate_label}" "$log" \
    "candidate LaunchAgent bootstrapped before its durable ownership fence"
  if FM_REPORT_RETENTION_INSTALL_TEST_SIMULATE_LAUNCH=1 FM_REPORT_RETENTION_PLATFORM=Darwin \
    FM_REPORT_STACK_ROOT="$STACK" FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" ensure >/dev/null 2>&1; then
    fail "retention ensure unexpectedly treated the interrupted first installation as installed"
  fi
  assert_grep "bootout gui/$(id -u)/$candidate_label" "$log" \
    "retention recovery did not fence its recorded candidate"
  assert_absent "$install_root/.candidate-fence" "retention recovery retained its candidate fence"
  FM_REPORT_RETENTION_INSTALL_TEST_SIMULATE_LAUNCH=1 FM_REPORT_RETENTION_PLATFORM=Darwin \
    FM_REPORT_STACK_ROOT="$STACK" FM_REPORT_RETENTION_INTERVAL=1 FM_REPORT_RETENTION_PROGRESS_INTERVAL=1 \
    FM_REPORT_RETENTION_INSTALL_ROOT="$install_root" FM_REPORT_RETENTION_LAUNCH_AGENTS_DIR="$agents" \
    FM_REPORT_RETENTION_LAUNCHCTL="$fakebin/launchctl" FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-report-retention.sh" install >/dev/null \
    || fail "retention installation did not recover after fencing its interrupted candidate"
  pass "retention records candidate ownership before LaunchAgent bootstrap"
}

test_retention_cleanup_is_file_granular() {
  local tombstones="$TMP_ROOT/file-granular-tombstones" tombstone="$TMP_ROOT/file-granular-tombstones/tombstone-test"
  local before after output
  mkdir -p "$tombstone/cohort/report/visuals"
  printf 'one\n' > "$tombstone/cohort/report/report.md"
  printf 'two\n' > "$tombstone/cohort/report/visuals/one.png"
  printf 'three\n' > "$tombstone/cohort/report/visuals/two.png"
  before=$(find "$tombstone" -mindepth 1 | wc -l | tr -d ' ')
  output=$(python3 "$ROOT/bin/fm-contained-read.py" prune-tombstones-fd 1 3< "$tombstones") \
    || fail "file-granular retention cleanup failed"
  after=$(find "$tombstone" -mindepth 1 | wc -l | tr -d ' ')
  [ "$after" -eq "$((before - 1))" ] || fail "one retention batch removed more than one filesystem item"
  assert_contains "$output" '"pending":true' "file-granular retention cleanup did not persist remaining work"
  pass "retention cleanup budgets progress at file granularity"
}

test_retention_fresh_handoff_is_cohort_bounded_and_continuous() {
  local due="$STACK/entries/cohort-946684700000"
  local base name probe probe_identity after_identity count=64 i
  mkdir "$due"
  printf 'expired bytes\n' > "$due/sentinel"
  base=$(( $(date +%s) * 1000 + 86400000 ))
  for i in $(seq 1 "$count"); do
    name="cohort-$((base + i * 300000))"
    mkdir "$STACK/entries/$name"
    printf 'fresh-%s\n' "$i" > "$STACK/entries/$name/sentinel"
  done
  probe="$STACK/entries/cohort-$((base + 300000))"
  probe_identity=$(if [ "$(uname)" = Darwin ]; then stat -f '%d:%i' "$probe"; else stat -c '%d:%i' "$probe"; fi)
  run_stack prune --status --force >/dev/null || fail "retention did not retire its due cohort"
  assert_absent "$due" "retention left its due cohort public while preserving fresh cohorts"
  for i in $(seq 1 "$count"); do
    name="cohort-$((base + i * 300000))"
    assert_grep "fresh-$i" "$STACK/entries/$name/sentinel" \
      "recovered retention handoff lost fresh cohort $i"
  done
  after_identity=$(if [ "$(uname)" = Darwin ]; then stat -f '%d:%i' "$probe"; else stat -c '%d:%i' "$probe"; fi)
  [ "$after_identity" = "$probe_identity" ] || fail "fresh cohort handoff copied instead of moving its owned directory generation"
  pass "retention retires due cohorts without staging or replacing fresh cohorts"
}

test_report_publication_restores_swapped_staging_generation() {
  local id=report-publish-generation-race-k2t entry ready proceed output pid status staged saved wait_seconds
  write_task "$id" ship
  write_required_report "$HOME_DIR/data/$id/completion.md" "Original published report."
  run_stack publish "$id" >/dev/null || fail "report generation-race precondition failed"
  entry=$(run_stack path "$id") || fail "report generation-race precondition path failed"
  write_required_report "$HOME_DIR/data/$id/completion.md" "Replacement report attempt."
  ready="$TMP_ROOT/report-publish-generation.ready"; proceed="$TMP_ROOT/report-publish-generation.proceed"
  output="$TMP_ROOT/report-publish-generation.out"
  mkfifo "$ready" "$proceed"
  exec 7<>"$ready"
  exec 8<>"$proceed"
  FM_CONTAINED_REPORT_RENAME_TEST_READY="$ready" FM_CONTAINED_REPORT_RENAME_TEST_PROCEED="$proceed" \
    run_stack publish "$id" > "$output" 2>&1 &
  pid=$!
  wait_seconds=$(fm_test_load_scaled_timeout_seconds 30 150)
  if ! IFS= read -r -t "$wait_seconds" staged <&7; then
    kill -TERM "$pid" 2>/dev/null || true
    fail "report generation rename gate did not open: $(cat "$output")"
  fi
  staged="$STACK/entries/$staged"
  saved="$staged.saved"
  mv "$staged" "$saved"
  mkdir "$staged"
  printf 'unowned replacement\n' > "$staged/sentinel"
  printf 'continue\n' >&8
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "report publication accepted a swapped staging generation"
  assert_grep 'Original published report' "$(dirname "$entry")/report.md" \
    "failed report publication did not preserve the prior generation"
  assert_absent "$(dirname "$entry")/sentinel" "unowned staging replacement was published"
  assert_grep 'unowned replacement' "$staged/sentinel" \
    "failed report publication did not restore the unowned staging replacement"
  assert_present "$saved/manifest.json" "failed report publication lost its displaced owned staging generation"
  rm -rf "$staged" "$saved"
  exec 7>&-; exec 8>&-
  pass "report publication restores a staging generation raced through rename"
}

test_owned_tree_cleanup_quarantines_before_deletion() {
  local root="$TMP_ROOT/owned-tree-cleanup" owned="$TMP_ROOT/owned-tree-cleanup/owned"
  local tombstones="$TMP_ROOT/owned-tree-cleanup-tombstones"
  local ready="$TMP_ROOT/owned-tree-cleanup.ready" proceed="$TMP_ROOT/owned-tree-cleanup.proceed"
  local output="$TMP_ROOT/owned-tree-cleanup.out" identity quarantine pid status
  mkdir -p "$owned/nested" "$tombstones"
  printf 'owned generation\n' > "$owned/nested/sentinel"
  identity=$(if [ "$(uname)" = Darwin ]; then stat -f '%d:%i' "$owned"; else stat -c '%d:%i' "$owned"; fi)
  FM_CONTAINED_REMOVE_TREE_TEST_READY="$ready" FM_CONTAINED_REMOVE_TREE_TEST_PROCEED="$proceed" \
    python3 "$ROOT/bin/fm-contained-read.py" remove-owned-tree-fd owned "$identity" \
      3< "$root" 4< "$tombstones" > "$output" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.02; done
  [ -e "$ready" ] || { kill -TERM "$pid" 2>/dev/null || true; fail "owned tree quarantine gate did not open"; }
  quarantine=$(cat "$ready")
  assert_absent "$owned" "owned tree remained at its public name during recursive deletion"
  mkdir "$owned"
  printf 'concurrent replacement\n' > "$owned/sentinel"
  touch "$proceed"
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -eq 0 ] || fail "quarantined owned tree cleanup failed: $(cat "$output")"
  assert_grep 'concurrent replacement' "$owned/sentinel" \
    "owned tree cleanup removed a concurrent replacement generation"
  assert_absent "$tombstones/$quarantine" "owned tree cleanup retained its private quarantine"
  pass "owned tree cleanup quarantines its generation before recursive deletion"
}

test_interrupted_owned_tree_cleanup_enters_retention_recovery() {
  local root="$TMP_ROOT/owned-tree-interrupt" owned="$TMP_ROOT/owned-tree-interrupt/owned"
  local tombstones="$TMP_ROOT/owned-tree-interrupt-tombstones"
  local ready="$TMP_ROOT/owned-tree-interrupt.ready" proceed="$TMP_ROOT/owned-tree-interrupt.proceed"
  local output="$TMP_ROOT/owned-tree-interrupt.out" identity quarantine pid status
  mkdir -p "$owned/nested" "$tombstones"
  printf 'recoverable generation\n' > "$owned/nested/sentinel"
  identity=$(if [ "$(uname)" = Darwin ]; then stat -f '%d:%i' "$owned"; else stat -c '%d:%i' "$owned"; fi)
  FM_CONTAINED_REMOVE_TREE_TEST_READY="$ready" FM_CONTAINED_REMOVE_TREE_TEST_PROCEED="$proceed" \
    python3 "$ROOT/bin/fm-contained-read.py" remove-owned-tree-fd owned "$identity" \
      3< "$root" 4< "$tombstones" > "$output" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.02; done
  [ -e "$ready" ] || { kill -TERM "$pid" 2>/dev/null || true; fail "interrupted owned tree quarantine gate did not open"; }
  quarantine=$(cat "$ready")
  kill -KILL "$pid" 2>/dev/null || true
  if wait "$pid"; then status=0; else status=$?; fi
  [ "$status" -ne 0 ] || fail "owned tree interruption fixture exited successfully"
  assert_absent "$owned" "interrupted cleanup restored an expired public generation"
  assert_grep 'recoverable generation' "$tombstones/$quarantine/nested/sentinel" \
    "interrupted cleanup did not leave its generation in retention recovery"
  python3 "$ROOT/bin/fm-contained-read.py" prune-tombstones-fd 10 3< "$tombstones" >/dev/null \
    || fail "retention recovery did not sweep an interrupted owned tree"
  assert_absent "$tombstones/$quarantine" "retention recovery left the interrupted owned tree indefinitely"
  pass "interrupted owned tree cleanup remains enrolled in retention recovery"
}

if [ "${FM_TEST_FOCUSED:-}" = report-lock-handshakes ]; then
  test_stale_lock_reclaim_is_serialized
  test_install_guard_release_failure_cleans_owned_lock
  test_post_install_guard_owner_death_is_recovered
  test_reclaim_guard_fences_the_stale_generation_gap
  test_abandoned_reclaim_guard_is_recovered
  test_report_publication_restores_swapped_staging_generation
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-27 ]; then
  test_retention_batches_make_interruption_safe_progress
  test_persistent_retention_owner_prunes_without_tasks_or_watcher
  test_retention_generations_survive_install_interruptions
  test_retention_install_reclaims_positively_stale_lock
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-29 ]; then
  test_lazy_list_blocks_retain_their_container_scope
  test_contained_reader_rejects_special_files_without_blocking
  test_repository_fingerprint_recurses_through_submodule_worktrees
  test_retention_cutoff_is_authoritative_before_cleanup
  test_persistent_retention_owner_prunes_without_tasks_or_watcher
  test_retention_generations_survive_install_interruptions
  test_retention_install_reclaims_positively_stale_lock
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-30 ]; then
  test_retention_cutoff_is_authoritative_before_cleanup
  test_retention_activation_requires_launched_nonce_without_owner_gap
  test_retention_install_recovers_owned_stale_reclaim_marker
  test_report_contract_and_task_transaction_reject_fifos_without_blocking
  test_report_entry_manifest_reads_stay_on_pinned_generation
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-31 ]; then
  test_retention_cutoff_is_authoritative_before_cleanup
  test_failed_initial_retention_activation_disarms_plist
  test_retention_activation_wait_budget_accepts_delayed_health
  test_bounded_report_reads_reject_fifo_swaps_without_blocking
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-32 ]; then
  test_revision_fields_distinguish_pr_head_from_worktree_head
  test_legacy_cutover_preserves_fresh_reports_and_retires_expired_raw_paths
  test_manifest_cohort_must_match_completion_time
  test_retention_cutoff_is_authoritative_before_cleanup
  test_retention_cohort_tombstone_is_noreplace_owned
  test_retention_activation_requires_launched_nonce_without_owner_gap
  test_retention_accepts_runatload_heartbeat_after_prebootstrap_baseline
  test_retention_pointer_failure_retires_only_candidate
  test_retention_pointer_failure_retains_unfenced_candidate
  test_persistent_retention_owner_prunes_without_tasks_or_watcher
  test_retention_generations_survive_install_interruptions
  test_nested_list_parent_scope_hides_required_headings
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-33 ]; then
  test_retention_cutoff_is_authoritative_before_cleanup
  test_retention_cohort_source_swap_restores_replacement
  test_retention_handoff_persists_and_retries_old_owner_fencing
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-34-retention ]; then
  test_retention_cutoff_is_authoritative_before_cleanup
  test_retention_cleanup_is_file_granular
  test_retention_fresh_handoff_is_cohort_bounded_and_continuous
  test_retention_prepointer_recovery_fences_candidate
  test_report_publication_restores_swapped_staging_generation
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-35 ]; then
  test_legacy_cutover_preserves_fresh_reports_and_retires_expired_raw_paths
  test_report_entry_manifest_reads_stay_on_pinned_generation
  test_retention_fresh_handoff_is_cohort_bounded_and_continuous
  test_retention_candidate_is_fenced_before_bootstrap
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-36 ]; then
  test_publish_ship_with_visual
  test_legacy_cutover_preserves_fresh_reports_and_retires_expired_raw_paths
  test_retention_owner_advances_pending_legacy_migration
  test_retention_cutoff_is_authoritative_before_cleanup
  test_retention_fresh_handoff_is_cohort_bounded_and_continuous
  test_owned_tree_cleanup_quarantines_before_deletion
  test_interrupted_owned_tree_cleanup_enters_retention_recovery
  test_retention_cohort_never_precedes_exact_expiry
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = retention-minimum-age ]; then
  test_retention_guard_cannot_advance_minimum_age
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-37 ]; then
  test_retention_guard_cannot_advance_minimum_age
  test_retention_cutoff_never_regresses_with_wall_time
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-38 ]; then
  test_retention_cohort_and_sweep_share_drift_budget
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-34-parser ]; then
  test_nested_list_parent_scope_hides_required_headings
  test_blockquote_list_scope_requires_quote_markers
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = retention-round-30 ]; then
  test_retention_cutoff_is_authoritative_before_cleanup
  test_retention_activation_requires_launched_nonce_without_owner_gap
  test_retention_install_recovers_owned_stale_reclaim_marker
  test_retention_reclaim_never_removes_replacement_generation
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-28 ]; then
  test_list_lazy_continuations_do_not_satisfy_required_sections
  test_underindented_list_headings_exit_lazy_continuation
  test_persistent_retention_owner_prunes_without_tasks_or_watcher
  test_retention_generations_survive_install_interruptions
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-26 ]; then
  test_list_lazy_continuations_do_not_satisfy_required_sections
  test_persistent_retention_owner_prunes_without_tasks_or_watcher
  test_retention_generations_survive_install_interruptions
  test_retention_error_publication_is_atomic_and_nonfollowing
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

if [ "${FM_TEST_FOCUSED:-}" = fenced-report-body-final ]; then
  test_fenced_required_section_bodies_use_scoped_content
  test_nested_short_fences_do_not_satisfy_required_sections
  test_container_scoped_fences_do_not_close_from_top_level
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = report-container-markers ]; then
  test_required_sections_reject_container_only_markers
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-findings ]; then
  test_required_sections_fail_actionably
  test_required_sections_reject_empty_bodies
  test_namespace_cutover_waiter_pins_entries_after_lock_acquisition
  test_report_destination_roots_remain_pinned_during_ancestor_swap
  test_report_publication_gate_uses_framed_fifo
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = report-generation-recovery ]; then
  test_previous_generation_is_recovered_for_readers
  test_replacement_transaction_recovery_restores_entry_and_index
  test_first_publication_transaction_recovery_removes_unindexed_entry
  test_pre_rename_transaction_recovery_keeps_previous_generation
  test_transaction_recovery_fails_when_every_generation_is_lost
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = retention-cohort-fixtures ]; then
  test_completed_reports_prune_after_minimum_age
  test_retention_binds_manifests_to_entry_directories
  test_watcher_periodically_owns_idle_report_retention
  test_retention_restores_expired_entries_when_index_swap_fails
  test_retention_batches_make_interruption_safe_progress
  test_persistent_retention_owner_prunes_without_tasks_or_watcher
  test_retention_cutoff_is_authoritative_before_cleanup
  test_retention_cohort_tombstone_is_noreplace_owned
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = retention-mutant-contract ]; then
  test_retention_changed_control_flow_contract
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = retention-admission ]; then
  test_noop_retention_skips_helpers_and_publication_lock_at_scale
  test_retention_admission_bounds_total_fleet_attempts_above_current_population
  test_failed_retention_attempt_is_ineligible_on_the_next_loop
  test_wrong_type_stack_root_is_root_independently_admitted
  test_malformed_retention_attempt_is_replaced_before_validation_error
  test_retention_invalid_marker_quarantine_is_inode_owned
  test_retention_admission_recovers_every_marker_path_type
  test_valid_retention_claim_release_does_not_persist_quarantine
  test_stale_claim_quarantine_failure_still_installs_admission
  test_retention_future_timestamp_uses_bounded_file_age_fallback
  test_retention_admission_record_predicate_mutations
  test_invalid_claim_file_age_fallback_mutation
  test_retention_candidate_predicate_mutations
  test_retention_installed_marker_predicate_mutations
  test_partial_retention_install_restores_canonical_admission
  test_retention_quarantine_identity_mutation_is_detected
  test_retention_quarantine_postrename_predicate_mutations
  test_retention_postquarantine_javascript_predicate_mutations
  test_retention_admission_mutation_inventory_is_complete
  test_invalid_retention_configuration_is_admitted_before_validation
  test_retention_admission_and_lock_share_root_generation
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = retention-admission-integrity ]; then
  test_wrong_type_stack_root_is_root_independently_admitted
  test_malformed_retention_attempt_is_replaced_before_validation_error
  test_retention_invalid_marker_quarantine_is_inode_owned
  test_retention_admission_recovers_every_marker_path_type
  test_valid_retention_claim_release_does_not_persist_quarantine
  test_stale_claim_quarantine_failure_still_installs_admission
  test_retention_future_timestamp_uses_bounded_file_age_fallback
  test_retention_admission_record_predicate_mutations
  test_invalid_claim_file_age_fallback_mutation
  test_retention_candidate_predicate_mutations
  test_retention_installed_marker_predicate_mutations
  test_partial_retention_install_restores_canonical_admission
  test_retention_quarantine_identity_mutation_is_detected
  test_retention_quarantine_postrename_predicate_mutations
  test_retention_postquarantine_javascript_predicate_mutations
  test_retention_admission_mutation_inventory_is_complete
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = retention-cohort-width ]; then
  test_manifest_cohort_must_match_completion_time
  test_manifest_cohort_deadline_cannot_precede_expiry
  test_manifest_validation_is_cohort_width_independent
  test_persistent_retention_owner_prunes_without_tasks_or_watcher
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = report-retention-state-leak ]; then
  test_report_temps_are_exclusive_and_randomized
  test_completed_reports_prune_after_minimum_age
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = retention-handoff-state-leak ]; then
  test_persistent_retention_owner_prunes_without_tasks_or_watcher
  test_retention_generations_survive_install_interruptions
  test_retention_cutoff_is_authoritative_before_cleanup
  test_retention_cohort_tombstone_is_noreplace_owned
  test_retention_cohort_source_swap_restores_replacement
  test_retention_handoff_persists_and_retries_old_owner_fencing
  exit 0
fi

run_partitioned_test() {
  FM_TEST_PART_SEQUENCE=$((FM_TEST_PART_SEQUENCE + 1))
  if [ "$FM_TEST_PART_TOTAL" -gt 1 ] \
    && [ $(((FM_TEST_PART_SEQUENCE - 1) % FM_TEST_PART_TOTAL + 1)) -ne "$FM_TEST_PART_INDEX" ]; then
    return 0
  fi
  "$@"
}

run_partitioned_group() {
  local assigned_part group_size=$# test_function
  assigned_part=$((FM_TEST_PART_SEQUENCE % FM_TEST_PART_TOTAL + 1))
  FM_TEST_PART_SEQUENCE=$((FM_TEST_PART_SEQUENCE + group_size))
  if [ "$FM_TEST_PART_TOTAL" -gt 1 ] && [ "$assigned_part" -ne "$FM_TEST_PART_INDEX" ]; then
    return 0
  fi
  for test_function in "$@"; do
    "$test_function"
  done
}

FM_TEST_PART_INDEX=${FM_TEST_PART_INDEX:-1}
FM_TEST_PART_TOTAL=${FM_TEST_PART_TOTAL:-1}
FM_TEST_PART_SEQUENCE=0

run_partitioned_test test_publish_ship_with_visual
run_partitioned_test test_report_artifacts_remain_verbatim_across_key_shaped_content
run_partitioned_test test_report_links_reject_credentials_and_encode_visual_paths
run_partitioned_test test_pr_url_strips_query_and_fragment
run_partitioned_test test_revision_fields_distinguish_pr_head_from_worktree_head
run_partitioned_test test_republish_new_generation_refreshes_completion_time
run_partitioned_test test_same_generation_republish_preserves_revision_without_worktree
run_partitioned_test test_generation_identity_falls_back_only_when_both_sides_are_legacy
run_partitioned_test test_text_sources_are_stored_verbatim_and_completion_is_bounded
run_partitioned_test test_metadata_is_bounded_before_reading
run_partitioned_test test_report_temps_are_exclusive_and_randomized
run_partitioned_test test_visual_inventory_is_count_and_depth_bounded
run_partitioned_test test_required_source_fails_closed
run_partitioned_test test_required_sections_fail_actionably
run_partitioned_test test_required_sections_reject_empty_bodies
run_partitioned_test test_required_sections_reject_container_only_markers
run_partitioned_test test_fenced_required_section_bodies_use_scoped_content
run_partitioned_test test_nested_short_fences_do_not_satisfy_required_sections
run_partitioned_test test_raw_html_does_not_satisfy_required_sections
run_partitioned_test test_container_scoped_fences_do_not_close_from_top_level
run_partitioned_test test_indented_pseudo_closers_do_not_end_fences
run_partitioned_test test_required_headings_follow_commonmark_atx_rules
run_partitioned_test test_invalid_backtick_info_string_does_not_open_fence
run_partitioned_test test_summary_extraction_uses_validated_markdown_structure
run_partitioned_test test_list_container_fences_hide_report_headings_and_summaries
run_partitioned_test test_list_lazy_continuations_do_not_satisfy_required_sections
run_partitioned_test test_underindented_list_headings_exit_lazy_continuation
run_partitioned_test test_nested_list_parent_scope_hides_required_headings
run_partitioned_test test_blockquote_list_scope_requires_quote_markers
run_partitioned_test test_container_scopes_preserve_commonmark_blank_and_exit_rules
run_partitioned_test test_large_non_utf8_text_artifacts_are_stored_verbatim
run_partitioned_test test_large_visual_inventory_does_not_share_text_buffer_headroom
run_partitioned_test test_scout_and_legacy_sources
run_partitioned_test test_stale_lock_rejects_reused_pid
run_partitioned_test test_stale_lock_reclaim_is_serialized
run_partitioned_test test_install_guard_release_failure_cleans_owned_lock
run_partitioned_test test_post_install_guard_owner_death_is_recovered
run_partitioned_test test_reclaim_guard_fences_the_stale_generation_gap
run_partitioned_test test_abandoned_reclaim_guard_is_recovered
run_partitioned_test test_abandoned_reclaim_marker_is_recovered
run_partitioned_test test_abandoned_reclaim_directory_is_recovered
run_partitioned_test test_publish_lock_directory_symlink_fails_closed
run_partitioned_test test_lock_control_files_are_bounded_and_nonfollowing
run_partitioned_test test_namespace_cutover_waiter_pins_entries_after_lock_acquisition
run_partitioned_test test_post_rename_lock_setup_failure_releases_owned_lock
run_partitioned_test test_publication_lock_release_failures_are_observable
run_partitioned_test test_previous_generation_is_recovered_for_readers
run_partitioned_test test_replacement_transaction_recovery_restores_entry_and_index
run_partitioned_test test_first_publication_transaction_recovery_removes_unindexed_entry
run_partitioned_test test_pre_rename_transaction_recovery_keeps_previous_generation
run_partitioned_test test_transaction_recovery_fails_when_every_generation_is_lost
run_partitioned_test test_aged_transactionless_staging_is_reclaimed
run_partitioned_test test_completed_reports_prune_after_minimum_age
run_partitioned_test test_retention_binds_manifests_to_entry_directories
run_partitioned_test test_watcher_periodically_owns_idle_report_retention
run_partitioned_test test_noop_retention_skips_helpers_and_publication_lock_at_scale
run_partitioned_test test_retention_admission_bounds_total_fleet_attempts_above_current_population
run_partitioned_test test_failed_retention_attempt_is_ineligible_on_the_next_loop
run_partitioned_test test_wrong_type_stack_root_is_root_independently_admitted
run_partitioned_test test_malformed_retention_attempt_is_replaced_before_validation_error
run_partitioned_test test_retention_invalid_marker_quarantine_is_inode_owned
run_partitioned_test test_retention_admission_recovers_every_marker_path_type
run_partitioned_test test_valid_retention_claim_release_does_not_persist_quarantine
run_partitioned_test test_stale_claim_quarantine_failure_still_installs_admission
run_partitioned_test test_retention_future_timestamp_uses_bounded_file_age_fallback
run_partitioned_test test_retention_admission_record_predicate_mutations
run_partitioned_test test_invalid_claim_file_age_fallback_mutation
run_partitioned_test test_retention_candidate_predicate_mutations
run_partitioned_test test_retention_installed_marker_predicate_mutations
run_partitioned_test test_partial_retention_install_restores_canonical_admission
run_partitioned_test test_retention_quarantine_identity_mutation_is_detected
run_partitioned_test test_retention_quarantine_postrename_predicate_mutations
run_partitioned_test test_retention_postquarantine_javascript_predicate_mutations
run_partitioned_test test_retention_admission_mutation_inventory_is_complete
run_partitioned_test test_root_retention_admission_preserves_newer_bucket
run_partitioned_test test_invalid_retention_configuration_is_admitted_before_validation
run_partitioned_test test_retention_admission_and_lock_share_root_generation
run_partitioned_test test_retention_batches_make_interruption_safe_progress
run_partitioned_group \
  test_persistent_retention_owner_prunes_without_tasks_or_watcher \
  test_retention_generations_survive_install_interruptions
run_partitioned_test test_retention_error_publication_is_atomic_and_nonfollowing
run_partitioned_test test_legacy_cutover_preserves_fresh_reports_and_retires_expired_raw_paths
run_partitioned_test test_retention_owner_advances_pending_legacy_migration
run_partitioned_test test_manifest_cohort_must_match_completion_time
run_partitioned_test test_manifest_cohort_deadline_cannot_precede_expiry
run_partitioned_test test_manifest_validation_is_cohort_width_independent
run_partitioned_test test_retention_cohort_never_precedes_exact_expiry
run_partitioned_test test_retention_cohort_and_sweep_share_drift_budget
run_partitioned_test test_retention_cutoff_is_authoritative_before_cleanup
run_partitioned_test test_retention_cohort_tombstone_is_noreplace_owned
run_partitioned_test test_retention_cohort_source_swap_restores_replacement
run_partitioned_test test_retention_handoff_persists_and_retries_old_owner_fencing
run_partitioned_test test_retention_prepointer_recovery_fences_candidate
run_partitioned_test test_retention_candidate_is_fenced_before_bootstrap
run_partitioned_test test_retention_cleanup_is_file_granular
run_partitioned_test test_retention_fresh_handoff_is_cohort_bounded_and_continuous
run_partitioned_test test_report_entry_manifest_reads_stay_on_pinned_generation
run_partitioned_test test_report_publication_restores_swapped_staging_generation
run_partitioned_test test_owned_tree_cleanup_quarantines_before_deletion
run_partitioned_test test_interrupted_owned_tree_cleanup_enters_retention_recovery
run_partitioned_test test_retention_activation_requires_launched_nonce_without_owner_gap
run_partitioned_test test_retention_accepts_runatload_heartbeat_after_prebootstrap_baseline
run_partitioned_test test_retention_pointer_failure_retires_only_candidate
run_partitioned_test test_retention_pointer_failure_retains_unfenced_candidate
run_partitioned_test test_nested_list_parent_scope_hides_required_headings
run_partitioned_test test_report_destination_roots_remain_pinned_during_ancestor_swap
run_partitioned_test test_report_publication_gate_uses_framed_fifo
run_partitioned_test test_index_failure_restores_previous_generation
run_partitioned_test test_readers_wait_for_publication_lock
run_partitioned_test test_busy_lock_error_names_holder_identity_and_age
run_partitioned_test test_visual_symlink_fails_closed_and_cleans_staging
run_partitioned_test test_visual_copy_is_descriptor_bounded
run_partitioned_test test_visual_containment_precedes_ancestor_swap
run_partitioned_test test_source_symlinks_fail_closed
run_partitioned_test test_ambiguous_task_ids_require_report_ids
