#!/usr/bin/env bash
# Behavior: projecting one Pi profile into the single-profile account home its
# consumers actually read, without ever writing a token into the transcript.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

TOOL="$ROOT/bin/fm-pi-account-home.py"
# A marker standing in for token material, so leakage is detectable by grep
# rather than by inspection.
MARKER=fmtestpitokenmarker

make_pool() {
  python3 - "$1" "$MARKER" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
marker = sys.argv[2]


def entry(account, expires=1893456000000, access=None, refresh=None, kind="oauth"):
    return {
        "type": kind,
        "access": marker + "-access" if access is None else access,
        "refresh": marker + "-refresh" if refresh is None else refresh,
        "expires": expires,
        "accountId": account,
    }


pool = {
    "openai-codex": entry("acct-one"),
    "openai-codex-2": entry("acct-two"),
    # The shape a de-authenticated profile leaves behind: the keys are all
    # present, and both token strings are empty.
    "openai-codex-3": entry("acct-three", access="", refresh=""),
    "openai-codex-4": entry("acct-four", kind="apikey"),
    "openai-codex-5": {"type": "oauth", "access": marker, "refresh": marker,
                       "accountId": "acct-five"},
    "openai-codex-6": entry("   "),
}
path.write_text(json.dumps(pool, indent=2) + "\n", encoding="utf-8")
PY
}

projection_contract() {
  local work pool out code
  work=$(fm_test_tmproot fm-pi-account-home)
  pool=$work/auth.json
  make_pool "$pool"

  # A named profile lands under the fixed consumer key, not under its pool name.
  "$TOOL" project --source "$pool" --destination-root "$work/homes" \
    --profile openai-codex-2 >"$work/out.txt" 2>&1 \
    || fail "projecting a usable profile refused"
  assert_present "$work/homes/openai-codex-2/auth.json" "the projected account home has no credential"
  python3 - "$work/homes/openai-codex-2/auth.json" <<'PY' || fail "the projected credential is not consumer-shaped"
import json
import sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
assert list(value) == ["openai-codex"], list(value)
assert value["openai-codex"]["accountId"] == "acct-two", value["openai-codex"]["accountId"]
PY

  # Exactly one credential reaches the home. Handing over the pool would carry
  # every signed-in account into a compartment that needs one.
  assert_no_grep "acct-one" "$work/homes/openai-codex-2/auth.json" \
    "a sibling profile's account rode along into the projected home"

  # The consumer reads this file directly; wrong modes expose a live token.
  expect_code 600 "$(stat -f '%Lp' "$work/homes/openai-codex-2/auth.json" 2>/dev/null \
    || stat -c '%a' "$work/homes/openai-codex-2/auth.json")" "the projected credential is not owner-only"
  expect_code 700 "$(stat -f '%Lp' "$work/homes/openai-codex-2" 2>/dev/null \
    || stat -c '%a' "$work/homes/openai-codex-2")" "the projected account home is not owner-only"

  # Nothing the command prints may carry token material.
  assert_no_grep "$MARKER" "$work/out.txt" "the projection printed token material"
  "$TOOL" report --source "$pool" >"$work/report.txt" 2>&1 || fail "report refused a readable pool"
  assert_no_grep "$MARKER" "$work/report.txt" "the report printed token material"
  assert_grep "distinct-accounts" "$work/report.txt" "the report omitted its account summary"

  # Re-projecting is idempotent, so a refreshed pool can be re-run at any time.
  "$TOOL" project --source "$pool" --destination-root "$work/homes" \
    --profile openai-codex-2 >/dev/null 2>&1 || fail "re-projecting the same profile refused"

  # A blanked profile reads as present to anything checking only for the key.
  code=0
  out=$("$TOOL" project --source "$pool" --destination-root "$work/blank" \
    --profile openai-codex-3 2>&1) || code=$?
  expect_code 1 "$code" "a blanked-token profile was projected"
  assert_contains "$out" "blank access" "the refusal did not name the blank token"
  assert_absent "$work/blank/openai-codex-3/auth.json" "a refused profile still wrote a credential"

  for bad in openai-codex-4 openai-codex-5 openai-codex-6; do
    code=0
    "$TOOL" project --source "$pool" --destination-root "$work/bad" --profile "$bad" >/dev/null 2>&1 || code=$?
    expect_code 1 "$code" "an unusable profile ($bad) was projected"
  done

  # --all refuses as a set rather than leaving a half-projected root behind.
  code=0
  out=$("$TOOL" project --source "$pool" --destination-root "$work/every" --all 2>&1) || code=$?
  expect_code 1 "$code" "--all projected a pool containing unusable profiles"
  assert_contains "$out" "4 of 6" "the refusal did not report the full unusable set"
  assert_absent "$work/every/openai-codex/auth.json" "a refused --all run projected the usable profiles anyway"

  # A planted symlink at the credential path must not be followed into a write.
  mkdir -p "$work/planted/openai-codex-2" "$work/target"
  ln -s "$work/target/stolen.json" "$work/planted/openai-codex-2/auth.json"
  code=0
  out=$("$TOOL" project --source "$pool" --destination-root "$work/planted" \
    --profile openai-codex-2 2>&1) || code=$?
  expect_code 1 "$code" "a symlinked credential path was followed into a write"
  assert_absent "$work/target/stolen.json" "the projection wrote through a planted symlink"

  code=0
  "$TOOL" project --source "$pool" --destination-root "$work/none" --profile absent >/dev/null 2>&1 || code=$?
  expect_code 1 "$code" "a profile absent from the pool was projected"

  code=0
  "$TOOL" report --source "$work/missing.json" >/dev/null 2>&1 || code=$?
  expect_code 1 "$code" "an absent pool was reported as readable"

  printf 'not json\n' >"$work/malformed.json"
  code=0
  "$TOOL" report --source "$work/malformed.json" >/dev/null 2>&1 || code=$?
  expect_code 1 "$code" "a malformed pool was reported as readable"

  pass "one Pi profile projects into the single-profile account home its consumers read, and unusable or planted paths refuse"
}

consumer_agreement_contract() {
  local work pool
  work=$(fm_test_tmproot fm-pi-account-home-consumer)
  pool=$work/auth.json
  make_pool "$pool"
  "$TOOL" project --source "$pool" --destination-root "$work/homes" \
    --profile openai-codex-2 >/dev/null 2>&1 || fail "projection refused"

  # The real consumer, not a restatement of it: fm-crosscheck.py's own reader
  # must accept the projected home and derive the expected identity from it.
  # Asserting the key name here instead would only prove this test agrees with
  # itself.
  python3 - "$ROOT/bin/fm-crosscheck.py" "$work/homes/openai-codex-2" <<'PY' \
    || fail "the real Pi credential reader rejected a projected account home"
import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location("core", sys.argv[1])
core = importlib.util.module_from_spec(spec)
spec.loader.exec_module(core)
home = pathlib.Path(sys.argv[2])
source, identifier = core.inspect_pi_credential(home)
assert source == "pi-openai-codex-oauth-file", source
assert identifier == str(home / "auth.json"), identifier
identity = core.account_identity("pi", home)
assert identity == "openai-codex:acct-two", identity
PY
  pass "the real fm-crosscheck Pi reader accepts a projected home and derives its executing account"
}

projection_contract
consumer_agreement_contract
