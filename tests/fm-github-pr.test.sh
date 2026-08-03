#!/usr/bin/env bash
# Contract tests for bin/fm-github-pr.py.
#
# The TOON fixtures were reduced from real gh-axi 0.1.25 output observed on
# 2026-08-02 and 2026-08-03, including a nonempty labels table from PR 8166.
# The fake accepts only the exact installed command forms used in production,
# so raw-gh flags such as --json or -q cannot make the suite falsely green.
# Every invocation below is hermetic coverage of those observed shapes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ADAPTER="$ROOT/bin/fm-github-pr.py"
fm_test_tmproot_into TMP_ROOT fm-github-pr-tests
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "$*" in
  "api /repos/ruby-dlee/firstmate/pulls/72")
    [ "${FM_TEST_API_MODE:-ok}" = ok ] || {
      [ "$FM_TEST_API_MODE" = error ] && exit 42
      sed '/^  sha:/d' "$FM_TEST_API_FIXTURE"
      exit 0
    }
    cat "$FM_TEST_API_FIXTURE"
    ;;
  "pr view 72 --repo ruby-dlee/firstmate --full")
    [ "${FM_TEST_CLAIMS_MODE:-ok}" = ok ] || exit 43
    cat "$FM_TEST_CLAIMS_FIXTURE"
    ;;
  "api PUT /repos/ruby-dlee/firstmate/pulls/72/merge --field sha=c9cbe79154013efcec9aa478f1476d0eff6c63df --field merge_method=squash")
    cat "$FM_TEST_MERGE_FIXTURE"
    ;;
  *)
    echo "unsupported fake gh-axi invocation: $*" >&2
    exit 97
    ;;
esac
SH
chmod +x "$FAKEBIN/gh-axi"

export FM_GH_AXI_BIN="$FAKEBIN/gh-axi"
export FM_TEST_GH_AXI_LOG="$TMP_ROOT/gh-axi.log"
export FM_TEST_API_FIXTURE="$ROOT/tests/fixtures/gh-axi-v0.1.25-pr-api.toon"
export FM_TEST_CLAIMS_FIXTURE="$ROOT/tests/fixtures/gh-axi-v0.1.25-pr-view-full.toon"
export FM_TEST_MERGE_FIXTURE="$ROOT/tests/fixtures/gh-axi-v0.1.25-merge-success.toon"
PR_URL=https://github.com/ruby-dlee/firstmate/pull/72

test_snapshot_uses_observed_contract() {
  local output
  : > "$FM_TEST_GH_AXI_LOG"
  output=$("$ADAPTER" snapshot "$PR_URL") || fail "snapshot rejected observed gh-axi fixtures"
  python3 -c '
import json, sys
value = json.load(sys.stdin)
assert value["head_sha"] == "c9cbe79154013efcec9aa478f1476d0eff6c63df"
assert value["base_sha"] == "68f014697d0eea733a4e7c0294becff4e76c7bcf"
assert value["claims_document"].startswith("pull_request:\n")
assert value["claims_identity"] == {
    "number": 72,
    "title": "feat: observed contract fixture",
    "body": "Complete claims returned by --full.",
}
' <<< "$output" || fail "snapshot did not preserve the observed head, base, and claims"
  grep -qxF 'api /repos/ruby-dlee/firstmate/pulls/72' "$FM_TEST_GH_AXI_LOG" \
    || fail "snapshot did not use the observed gh-axi API form"
  grep -qxF 'pr view 72 --repo ruby-dlee/firstmate --full' "$FM_TEST_GH_AXI_LOG" \
    || fail "snapshot did not use the observed full-claims form"
  assert_no_grep '--json' "$FM_TEST_GH_AXI_LOG" \
    "snapshot regressed to unsupported raw-gh --json"
  assert_no_grep '-q' "$FM_TEST_GH_AXI_LOG" \
    "snapshot regressed to unsupported raw-gh -q"
  pass "GitHub snapshot accepts observed gh-axi arrays without trusting them"
}

test_lookup_errors_fail_closed() {
  local rc
  set +e
  FM_TEST_CLAIMS_MODE=error "$ADAPTER" snapshot "$PR_URL" > "$TMP_ROOT/error.out" 2> "$TMP_ROOT/error.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "claims lookup error"
  assert_grep 'GitHub state is unreviewed' "$TMP_ROOT/error.err" \
    "claims lookup error was not loud"

  set +e
  FM_TEST_API_MODE=malformed "$ADAPTER" snapshot "$PR_URL" > "$TMP_ROOT/malformed.out" 2> "$TMP_ROOT/malformed.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "malformed API output"
  assert_grep 'missing head.sha' "$TMP_ROOT/malformed.err" \
    "malformed API output was not rejected"
  pass "GitHub lookup errors and malformed documents fail closed"
}

test_merge_uses_exact_sha_field() {
  local output
  : > "$FM_TEST_GH_AXI_LOG"
  output=$("$ADAPTER" merge "$PR_URL" c9cbe79154013efcec9aa478f1476d0eff6c63df squash) \
    || fail "exact-head merge rejected observed success fixture"
  assert_contains "$output" '"merged": true' "merge did not confirm success"
  grep -qxF 'api PUT /repos/ruby-dlee/firstmate/pulls/72/merge --field sha=c9cbe79154013efcec9aa478f1476d0eff6c63df --field merge_method=squash' "$FM_TEST_GH_AXI_LOG" \
    || fail "merge omitted or changed the exact reviewed SHA field"

  printf 'sha: b507a2d799059c6a766bd0dd3d5ceebb40586b5b\nmerged: false\nmessage: refused\n' > "$TMP_ROOT/not-merged.toon"
  set +e
  FM_TEST_MERGE_FIXTURE="$TMP_ROOT/not-merged.toon" "$ADAPTER" merge "$PR_URL" c9cbe79154013efcec9aa478f1476d0eff6c63df squash \
    > "$TMP_ROOT/not-merged.out" 2> "$TMP_ROOT/not-merged.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "non-merged response"
  assert_grep 'did not confirm merged: true' "$TMP_ROOT/not-merged.err" \
    "merge accepted a non-merged response"
  pass "GitHub merge sends the expected SHA atomically and requires merged true"
}

test_snapshot_uses_observed_contract
test_lookup_errors_fail_closed
test_merge_uses_exact_sha_field
