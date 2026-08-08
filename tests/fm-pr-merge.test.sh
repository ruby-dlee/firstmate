#!/usr/bin/env bash
# Structural and behavioral tests for the fail-closed PR merge boundary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
CROSSCHECK="$ROOT/bin/fm-crosscheck.sh"
CROSSCHECK_PY="$ROOT/bin/fm-crosscheck.py"
PR_URL=https://github.com/example/repo/pull/9
HEAD_SHA=deadbeefcafefeed0000000000000000deadbeef
fm_test_tmproot_into TMP_ROOT fm-pr-merge

make_case() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/wt" "$dir/fakebin"
  fm_write_meta "$dir/home/state/task-x1.meta" \
    "window=sess:fm-task-x1" "worktree=$dir/wt" "project=$dir/wt" \
    "kind=ship" "mode=no-mistakes" "generation_id=test:1"
  cat > "$dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
printf '%s\n' \
  'number: 9' \
  'state: open' \
  'merged: false' \
  'draft: false' \
  'head:' \
  '  ref: fm/task-x1' \
  '  sha: deadbeefcafefeed0000000000000000deadbeef' \
  '  repo:' \
  '    full_name: example/repo' \
  'base:' \
  '  ref: main' \
  '  sha: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  '  repo:' \
  '    full_name: example/repo'
SH
  chmod +x "$dir/fakebin/gh-axi"
  printf '%s\n' "$dir"
}

run_merge() {  # <case-dir> [args...]
  local dir=$1
  shift
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_TEST_GH_LOG="$dir/gh.log" "$PR_MERGE" task-x1 "$PR_URL" "$@"
}

test_armed_and_side_effect_flags_refuse_before_network() {
  local flag dir rc
  for flag in --auto --queue --admin --delete-branch; do
    dir=$(make_case "armed-${flag#--}")
    : > "$dir/gh.log"
    set +e
    run_merge "$dir" -- "$flag" > "$dir/out" 2> "$dir/err"
    rc=$?
    set -e
    expect_code 1 "$rc" "$flag"
    assert_grep 'incompatible with an immediate atomic expected-head merge' "$dir/err" \
      "$flag refusal did not name the immediate boundary"
    [ ! -s "$dir/gh.log" ] || fail "$flag reached GitHub before refusal"
    assert_no_grep '^pr=' "$dir/home/state/task-x1.meta" \
      "$flag recorded merge state before refusal"
  done
  pass "armed, queued, admin, and delete-after merge modes refuse before network access"
}

test_pr_check_preserves_custom_poll_and_records_exact_head() {
  local dir before
  dir=$(make_case pr-check)
  printf '#!/usr/bin/env bash\necho custom-check\n' > "$dir/home/state/task-x1.check.sh"
  chmod +x "$dir/home/state/task-x1.check.sh"
  before=$(shasum -a 256 "$dir/home/state/task-x1.check.sh" | awk '{print $1}')
  : > "$dir/gh.log"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_TEST_GH_LOG="$dir/gh.log" \
    "$PR_CHECK" task-x1 "$PR_URL" > "$dir/out" 2> "$dir/err" \
    || fail "PR metadata recording failed: $(cat "$dir/err")"
  assert_grep "pr=$PR_URL" "$dir/home/state/task-x1.meta" "PR URL was not recorded"
  assert_grep "pr_head=$HEAD_SHA" "$dir/home/state/task-x1.meta" "exact PR head was not recorded"
  [ "$(shasum -a 256 "$dir/home/state/task-x1.check.sh" | awk '{print $1}')" = "$before" ] \
    || fail "fm-pr-check overwrote the task-owned custom poll"
  [ "$("$dir/home/state/task-x1.check.sh")" = custom-check ] \
    || fail "custom poll no longer executes after PR recording"
  pass "fm-pr-check records exact metadata without arming or overwriting a poll"
}

test_every_repository_merge_route_refuses_before_api() {
  local dir rc
  dir=$(make_case crosscheck-merge)
  : > "$dir/gh.log"
  set +e
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_TEST_GH_LOG="$dir/gh.log" \
    "$CROSSCHECK" merge task-x1 "$PR_URL" "$HEAD_SHA" squash \
    > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  expect_code 2 "$rc" "removed crosscheck merge route"
  assert_grep 'supports only run and verify' "$dir/err" \
    "crosscheck merge command remained selectable"
  [ ! -s "$dir/gh.log" ] || fail "crosscheck merge refusal reached GitHub"

  set +e
  python3 "$CROSSCHECK_PY" merge task-x1 "$PR_URL" "$HEAD_SHA" squash \
    > "$dir/py.out" 2> "$dir/py.err"
  rc=$?
  set -e
  expect_code 2 "$rc" "private Python merge route"
  assert_grep 'invalid choice' "$dir/py.err" "private Python merge command remained selectable"
  pass "both crosscheck entrypoints make merge execution unreachable"
}

test_merge_gate_order_is_structurally_pinned() {
  # Structural test: component behavior is covered in fm-pr-admit and
  # fm-crosscheck tests; this pins their mandatory order at the sole merge path.
  python3 - "$PR_MERGE" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
needles = [
    '"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"',
    '"$SCRIPT_DIR/fm-crosscheck.sh" verify "$ID" "$URL"',
    '"$SCRIPT_DIR/fm-pr-admit.sh" "$ID" "$URL"',
    'fm_pr_require_atomic_merge_boundary "$MERGE_METHOD"',
]
positions = [text.index(item) for item in needles]
if positions != sorted(positions) or len(set(positions)) != len(positions):
    raise SystemExit("merge gate order is not record -> independent verdict -> admission -> refusal")
for forbidden in ('"$SCRIPT_DIR/fm-crosscheck.sh" merge', 'gh-axi api PUT'):
    if forbidden in text:
        raise SystemExit(f"forbidden merge route remains: {forbidden}")
PY
  pass "structural: sole merge path orders exact evidence and ends at unconditional refusal"
}

test_armed_and_side_effect_flags_refuse_before_network
test_pr_check_preserves_custom_poll_and_records_exact_head
test_every_repository_merge_route_refuses_before_api
test_merge_gate_order_is_structurally_pinned
