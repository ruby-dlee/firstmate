#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi with default --squash
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is forwarded unchanged
#   (h) repo override args fail fast because the repo comes from the URL
#   (i) merge-queue acceptance is not reported as success unless PR state is merged
#   (j) no-method queue requests preserve queue statuses and record metadata first
#   (k) draft PRs are clearly refused after metadata is recorded
#   (l) payloads the strict reader cannot verify refuse instead of reading green
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
fm_test_tmproot_into TMP_ROOT fm-pr-merge-tests

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for fm-pr-check.sh's pr_head lookup. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view") printf '%s\n' "pull_request:" "  number: ${3:-}" "  state: merged" "  draft: no" ; exit 0 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock for the merge-queue false-success shape: the merge command itself
# returns zero, but the subsequent independent PR view still reports open.
add_gh_mocks_merge_accepted_not_merged() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view") printf '%s\n' "pull_request:" "  number: ${3:-}" "  state: open" "  draft: no" ; exit 0 ;;
  "pr merge")
    case " $* " in
      *" --squash "*) echo "error: the base branch merge queue owns the merge strategy" >&2 ; exit 1 ;;
      *) printf '%s\n' "merged:" "  number: ${3:-}" "  status: ok" "  method: default" ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view") printf '%s\n' "pull_request:" "  number: ${3:-}" "  state: open" "  draft: no" ; exit 0 ;;
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock for no-method merge queue results. The merge call checks that
# fm-pr-check.sh recorded both containment fields before GitHub is invoked.
add_gh_mocks_queue_status() {
  local case_dir=$1 head=$2 status=$3
  printf '%s\n' "$head" > "$case_dir/expected-head"
  printf '%s\n' "$status" > "$case_dir/queue-status"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    printf '%s\n' "pull_request:" "  number: ${3:-}" "  state: open" "  draft: no"
    exit 0
    ;;
  "pr merge")
    grep -qxF "pr=$FM_TEST_EXPECTED_PR" "$FM_TEST_META" \
      || { echo "error: pr= was not recorded before enqueue" >&2; exit 91; }
    grep -qxF "pr_head=$FM_TEST_EXPECTED_HEAD" "$FM_TEST_META" \
      || { echo "error: pr_head= was not recorded before enqueue" >&2; exit 92; }
    case " $* " in
      *" --squash "*) echo "error: the base branch merge queue owns the merge strategy" >&2 ; exit 1 ;;
      *) printf '%s\n' "merge:" "  number: ${3:-}" "  status: $FM_TEST_QUEUE_STATUS" "  method: default" ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

add_gh_mocks_draft() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view") printf '%s\n' "pull_request:" "  number: ${3:-}" "  state: open" "  draft: yes" ; exit 0 ;;
  "pr merge") echo "error: draft merge should not be attempted" >&2 ; exit 93 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

run_pr_merge() {
  local case_dir=$1 expected_head='' queue_status=''
  shift
  [ ! -f "$case_dir/expected-head" ] || expected_head=$(cat "$case_dir/expected-head")
  [ ! -f "$case_dir/queue-status" ] || queue_status=$(cat "$case_dir/queue-status")
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_META="$case_dir/state/${1}.meta" \
  FM_TEST_EXPECTED_PR="${2}" \
  FM_TEST_EXPECTED_HEAD="$expected_head" \
  FM_TEST_QUEUE_STATUS="$queue_status" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
}

# gh-axi mock whose `pr view` output is supplied verbatim by the caller, so a
# deliberately malformed payload can be driven through the real merge gate.
# The merge call always "succeeds", which is the dangerous shape: the gate must
# refuse on the strength of the payload it cannot verify, not on a merge error.
add_gh_mocks_view_payload() {
  local case_dir=$1 payload=$2
  printf '%s\n' "$payload" > "$case_dir/view-payload"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view") cat "$FM_TEST_VIEW_PAYLOAD" ; exit 0 ;;
  "pr merge") printf '%s\n' "merged:" "  number: ${3:-}" "  status: ok" "  method: squash" ; exit 0 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Drive one malformed-payload case end to end and require a refusal.
# Args: label, pr view payload, expected stderr fragment
expect_gate_refuses() {
  local label=$1 payload=$2 needle=$3 case_dir rc
  case_dir=$(make_case "gate-$label")
  mkdir -p "$case_dir/wt"
  add_gh_mocks_view_payload "$case_dir" "$payload"
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_VIEW_PAYLOAD="$case_dir/view-payload" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/42 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] \
    || fail "gate-$label: merge gate exited zero on a payload it cannot verify"
  assert_no_grep 'status: ok' "$case_dir/stdout" \
    "gate-$label: gate reported a confirmed merge from an unverifiable payload"
  assert_grep "$needle" "$case_dir/stderr" \
    "gate-$label: refusal did not explain the problem"
}

# The merge gate must refuse every payload it cannot fully account for. Each
# case below is a shape the previous pattern-matching parser turned into a
# green read.
test_gate_refuses_unverifiable_payloads() {
  # An unmatched quote used to be stripped into a bare word, so a malformed
  # payload was reported as a CONFIRMED MERGE. This is the exact false success.
  expect_gate_refuses unmatched-quote \
'pull_request:
  number: 42
  draft: no
  state: "merged' \
    'malformed scalar'

  # Case variants used to be accepted on both the draft gate and the merged
  # check, so a payload in the wrong vocabulary read as verified.
  expect_gate_refuses uppercase-state \
'pull_request:
  number: 42
  draft: no
  state: MERGED' \
    'did not confirm'

  expect_gate_refuses uppercase-draft-flag \
'pull_request:
  number: 42
  draft: FALSE
  state: merged' \
    'readable draft status'

  # A key matched at any depth used to satisfy a top-level lookup: here the
  # PR itself has no state, and a review does.
  expect_gate_refuses state-only-nested \
'pull_request:
  number: 42
  draft: no
  reviews[1]:
    - state: merged' \
    'readable PR state'

  # An absent flag is not a negative.
  expect_gate_refuses draft-absent \
'pull_request:
  number: 42
  state: merged' \
    'readable draft status'

  # A declared count that disagrees with the block means we do not understand
  # the payload, so even a green-looking state elsewhere cannot be trusted.
  expect_gate_refuses array-count-mismatch \
'pull_request:
  number: 42
  draft: no
  state: merged
checks[1]{name,conclusion}:
  lint,pass
  tests,fail' \
    'declares [1] but its block holds 2 rows'

  # A line we cannot classify is never absorbed into the record before it.
  expect_gate_refuses unclassifiable-line \
'pull_request:
  number: 42
  draft: no
  state: merged
Traceback (most recent call last):' \
    'not classifiable'

  pass "fm-pr-merge refuses every gh-axi payload it cannot fully verify"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with default --squash"
  grep -qxF 'pr view 9 --repo example/repo' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr view was not invoked to verify the merge"
  assert_grep 'observed_state: merged' "$case_dir/stdout" \
    "records-before-merge: successful merge did not report confirmed merged state"
  assert_grep 'method: squash' "$case_dir/stdout" \
    "records-before-merge: ordinary no-method merge was not reported as squash"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  grep -qxF 'pr merge 13 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "merge-fails: unrelated failure did not come from the default squash attempt"
  [ "$(grep -c '^pr merge ' "$case_dir/gh-axi.log")" -eq 1 ] \
    || fail "merge-fails: unrelated merge error triggered a no-method retry"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_merge_queue_acceptance_is_not_success() {
  local case_dir rc
  case_dir=$(make_case queued-not-merged)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_accepted_not_merged "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/42 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "queued-not-merged: fm-pr-merge must not exit zero for an unconfirmed merge"
  # gh-axi labelled this result `merged:` with `status: ok` while GitHub still
  # reports the PR open. That is a payload we do not understand, so the label
  # must say so. The old parser fabricated `enqueued` here, which read like an
  # orderly queue wait for a state that is actually unexplained.
  assert_grep 'status: unrecognized' "$case_dir/stdout" \
    "queued-not-merged: an unexplained merge result was not labelled unrecognized"
  assert_no_grep 'status: enqueued' "$case_dir/stdout" \
    "queued-not-merged: an unexplained merge result was fabricated as enqueued"
  assert_grep 'observed_state: open' "$case_dir/stdout" \
    "queued-not-merged: observed open state was not reported"
  assert_no_grep 'status: ok' "$case_dir/stdout" \
    "queued-not-merged: helper reported success without a confirmed merged state"
  assert_grep 'still reports example/repo#42 as open' "$case_dir/stderr" \
    "queued-not-merged: refusal did not explain the observed open state"
  grep -qxF 'pr merge 42 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "queued-not-merged: default squash attempt was not invoked"
  grep -qxF 'pr merge 42 --repo example/repo' "$case_dir/gh-axi.log" \
    || fail "queued-not-merged: queue-specific no-method retry was not invoked"
  grep -qxF 'pr view 42 --repo example/repo' "$case_dir/gh-axi.log" \
    || fail "queued-not-merged: gh-axi pr view was not invoked to verify the merge"
  pass "fm-pr-merge labels an unexplained merge result unrecognized, not merged success"
}

test_no_method_queue_statuses_are_not_merge_success() {
  local status case_dir rc head
  head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  for status in enqueued accepted queued; do
    case_dir=$(make_case "queue-status-$status")
    mkdir -p "$case_dir/wt"
    add_gh_mocks_queue_status "$case_dir" "$head" "$status"
    : > "$case_dir/gh-axi.log"

    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/44 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "queue-status-$status: queue acceptance must not exit zero"
    grep -qxF 'pr merge 44 --repo example/repo --squash' "$case_dir/gh-axi.log" \
      || fail "queue-status-$status: default squash attempt was not invoked"
    grep -qxF 'pr merge 44 --repo example/repo' "$case_dir/gh-axi.log" \
      || fail "queue-status-$status: queue-specific retry retained an explicit method"
    assert_grep "status: $status" "$case_dir/stdout" \
      "queue-status-$status: queue status was not preserved"
    assert_grep 'observed_state: open' "$case_dir/stdout" \
      "queue-status-$status: helper did not report the still-open PR state"
    assert_no_grep 'status: ok' "$case_dir/stdout" \
      "queue-status-$status: unmerged PR was reported as merged success"
    assert_grep 'not verified merged' "$case_dir/stderr" \
      "queue-status-$status: refusal did not explain that queue acceptance is not a merge"
  done
  pass "fm-pr-merge preserves queue statuses without reporting unmerged PRs as merged"
}

test_draft_refusal_is_clear_and_records_first() {
  local case_dir rc head
  head=cccccccccccccccccccccccccccccccccccccccc
  case_dir=$(make_case draft-refusal)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_draft "$case_dir" "$head"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/691 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "draft-refusal: draft PR must be refused"
  assert_grep 'pr=https://github.com/example/repo/pull/691' "$case_dir/state/task-x1.meta" \
    "draft-refusal: pr= was not recorded before refusing the draft"
  assert_grep "pr_head=$head" "$case_dir/state/task-x1.meta" \
    "draft-refusal: pr_head= was not recorded before refusing the draft"
  assert_grep 'because it is a draft' "$case_dir/stderr" \
    "draft-refusal: refusal did not clearly identify draft status"
  assert_grep 'gh-axi pr ready 691 --repo example/repo' "$case_dir/stderr" \
    "draft-refusal: refusal did not provide the ready-for-review action"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "draft-refusal: helper called merge for a draft PR"
  pass "fm-pr-merge records containment metadata before clearly refusing a draft PR"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'no meta for task missing-x1' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "malformed-url: refusal did not explain the expected URL shape"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'must not override --repo parsed from PR URL' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded unchanged"
  pass "fm-pr-merge forwards an explicit merge method unchanged"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded unchanged"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126/ \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_merge_queue_acceptance_is_not_success
test_no_method_queue_statuses_are_not_merge_success
test_draft_refusal_is_clear_and_records_first
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_gate_refuses_unverifiable_payloads
