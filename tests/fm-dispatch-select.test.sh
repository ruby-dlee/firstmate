#!/usr/bin/env bash
# Behavior tests for deterministic crew-dispatch profile selection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-dispatch-select-tests)
mkdir -p "$TMP_ROOT"

write_quota() {
  local file=$1 claude_status=$2 claude_five=$3 claude_week=$4 codex_status=$5 codex_five=$6 codex_week=$7
  mkdir -p "$(dirname "$file")"
  cat > "$file" <<JSON
{
  "providers": [
    {
      "provider": "claude",
      "state": { "status": "$claude_status" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": $claude_five },
        { "id": "seven_day", "kind": "weekly", "percentRemaining": $claude_week },
        { "id": "model:fable", "kind": "model", "percentRemaining": 100 }
      ]
    },
    {
      "provider": "codex",
      "state": { "status": "$codex_status" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": $codex_five },
        { "id": "weekly", "kind": "weekly", "percentRemaining": $codex_week },
        { "id": "model:codex_bengalfox:5h", "kind": "model", "percentRemaining": 100 }
      ]
    }
  ]
}
JSON
}

profiles='[{"harness":"claude","model":"claude-sonnet-5","effort":"high"},{"harness":"codex","model":"gpt-5.5","effort":"high"}]'

test_higher_min_vendor_wins() {
  local quota out
  quota="$TMP_ROOT/higher.json"
  write_quota "$quota" fresh 80 30 fresh 70 60
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles")
  [ "$out" = '{"harness":"codex","model":"gpt-5.5","effort":"high"}' ] \
    || fail "higher-min vendor should win, got: $out"
  pass "quota-balanced picks the candidate with the higher general-window minimum"
}

test_exact_tie_uses_first_profile() {
  local quota out
  quota="$TMP_ROOT/tie.json"
  write_quota "$quota" fresh 90 50 fresh 60 50
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles")
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "exact tie should pick first profile, got: $out"
  pass "quota-balanced exact tie uses the first ordered profile"
}

test_quota_missing_falls_back_to_first() {
  local fakebin out err status
  fakebin=$(fm_fakebin "$TMP_ROOT/missing")
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$profiles" 2>"$TMP_ROOT/missing.err")
  status=$?
  err=$(cat "$TMP_ROOT/missing.err")
  expect_code 0 "$status" "missing quota-axi should not fail dispatch"
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "missing quota-axi should fall back to first, got: $out"
  assert_contains "$err" "quota-axi missing" "missing quota-axi fallback should be logged"
  pass "quota-axi missing falls back to the first profile and logs"
}

test_quota_error_falls_back_to_first() {
  local fakebin out err status
  fakebin=$(fm_fakebin "$TMP_ROOT/error")
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
exit 42
SH
  chmod +x "$fakebin/quota-axi"
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$profiles" 2>"$TMP_ROOT/error.err")
  status=$?
  err=$(cat "$TMP_ROOT/error.err")
  expect_code 0 "$status" "quota-axi error should not fail dispatch"
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "quota-axi error should fall back to first, got: $out"
  assert_contains "$err" "quota-axi exited 42" "quota-axi error fallback should be logged"
  pass "quota-axi non-zero exit falls back to the first profile and logs"
}

test_bad_quota_json_falls_back_to_first() {
  local quota out err
  quota="$TMP_ROOT/bad.json"
  printf '%s\n' 'not-json' > "$quota"
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles" 2>"$TMP_ROOT/bad.err")
  err=$(cat "$TMP_ROOT/bad.err")
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "bad quota JSON should fall back to first, got: $out"
  assert_contains "$err" "unparseable JSON" "bad quota JSON fallback should be logged"
  pass "unparseable quota JSON falls back to the first profile and logs"
}

test_stale_with_cache_needs_clear_margin_to_beat_fresh() {
  local quota out
  quota="$TMP_ROOT/stale-margin.json"
  write_quota "$quota" stale 85 70 fresh 65 60
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles")
  [ "$out" = '{"harness":"codex","model":"gpt-5.5","effort":"high"}' ] \
    || fail "fresh vendor should win when stale lead is below margin, got: $out"

  write_quota "$quota" stale 90 85 fresh 65 60
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles")
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "stale vendor should win when lead clears margin, got: $out"
  pass "stale cached quota is usable only when it clears the documented margin over fresh"
}

test_vendor_absent_or_unusable_falls_back_conservatively() {
  local quota out err
  quota="$TMP_ROOT/absent.json"
  cat > "$quota" <<'JSON'
{
  "providers": [
    {
      "provider": "codex",
      "state": { "status": "fresh" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": 40 },
        { "id": "weekly", "kind": "weekly", "percentRemaining": 50 }
      ]
    }
  ]
}
JSON
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles")
  [ "$out" = '{"harness":"codex","model":"gpt-5.5","effort":"high"}' ] \
    || fail "available candidate should win over absent vendor, got: $out"

  cat > "$quota" <<'JSON'
{ "providers": [] }
JSON
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced --quota-json "$quota" "$profiles" 2>"$TMP_ROOT/none.err")
  err=$(cat "$TMP_ROOT/none.err")
  [ "$out" = '{"harness":"claude","model":"claude-sonnet-5","effort":"high"}' ] \
    || fail "no usable vendors should fall back to first, got: $out"
  assert_contains "$err" "no usable quota windows" "no usable vendor fallback should be logged"
  pass "absent or unusable vendors resolve to an available candidate or the first fallback"
}

test_backward_compatible_first_selection() {
  local fakebin marker out single array_rule
  fakebin=$(fm_fakebin "$TMP_ROOT/no-call")
  marker="$TMP_ROOT/quota-called"
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
printf called > '$marker'
exit 1
SH
  chmod +x "$fakebin/quota-axi"

  single='{"harness":"grok","model":"grok-4","effort":"high"}'
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" "$single")
  [ "$out" = '{"harness":"grok","model":"grok-4","effort":"high"}' ] \
    || fail "single-object use should resolve to itself, got: $out"

  array_rule='{"when":"big work","use":[{"harness":"claude","effort":"high"},{"harness":"codex","effort":"high"}]}'
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" "$array_rule")
  [ "$out" = '{"harness":"claude","effort":"high"}' ] \
    || fail "array without select should resolve to first, got: $out"
  [ ! -e "$marker" ] || fail "quota-axi should not be called without quota-balanced select"
  pass "single-object use and no-select arrays preserve first-profile selection"
}

make_fake_agent_fleet() {
  local fakebin=$1
  cat > "$fakebin/agent-fleet" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_AF_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_AF_LOG"
pool=
provider=
prev=
for arg in "$@"; do
  case "$prev" in --pool) pool=$arg ;; --provider) provider=$arg ;; esac
  prev=$arg
done
case "$pool" in
  claude-crew) available=true; mode=quota; headroom=${FM_FAKE_CLAUDE_HEADROOM:-25} ;;
  codex-crew) available=true; mode=quota; headroom=${FM_FAKE_CODEX_HEADROOM:-70} ;;
  stale-crew) available=true; mode=least-active-fallback; headroom=null ;;
  *) available=false; mode=unavailable; headroom=null ;;
esac
printf '{"schema":1,"pool":"%s","providers":[{"provider":"%s","available":%s,"selection_mode":"%s","degraded":false,"best_adjusted_headroom_percent":%s,"eligible_profiles":1,"active_leases":0,"profiles":[]}]}\n' \
  "$pool" "$provider" "$available" "$mode" "$headroom"
SH
  chmod +x "$fakebin/agent-fleet"
}

test_account_pool_summary_owns_provider_quota_choice() {
  local fakebin af_log quota_marker out pooled
  fakebin=$(fm_fakebin "$TMP_ROOT/agent-fleet-pools")
  af_log="$TMP_ROOT/agent-fleet-pools/calls.log"
  quota_marker="$TMP_ROOT/agent-fleet-pools/quota-called"
  make_fake_agent_fleet "$fakebin"
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
touch '$quota_marker'
exit 1
SH
  chmod +x "$fakebin/quota-axi"
  pooled='[{"harness":"claude","model":"sonnet","account_pool":"claude-crew"},{"harness":"codex","model":"gpt-5","account_pool":"codex-crew"}]'
  out=$(FM_FAKE_AF_LOG="$af_log" FM_DISPATCH_AGENT_FLEET="$fakebin/agent-fleet" \
    FM_DISPATCH_QUOTA_AXI="$fakebin/quota-axi" "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$pooled")
  [ "$out" = '{"harness":"codex","model":"gpt-5","account_pool":"codex-crew"}' ] \
    || fail "Agent Fleet pool headroom should choose codex, got: $out"
  assert_grep 'pool status --pool claude-crew --provider claude' "$af_log" "claude pool summary was not queried"
  assert_grep 'pool status --pool codex-crew --provider codex' "$af_log" "codex pool summary was not queried"
  [ ! -e "$quota_marker" ] || fail "account_pool selection consulted default-account quota-axi"
  pass "account_pool quota-balanced selection consumes only Agent Fleet pool summaries"
}

test_account_fields_survive_direct_selection() {
  local fakebin marker out profile
  fakebin=$(fm_fakebin "$TMP_ROOT/account-direct")
  marker="$TMP_ROOT/account-direct/agent-fleet-called"
  cat > "$fakebin/agent-fleet" <<SH
#!/usr/bin/env bash
touch '$marker'
exit 1
SH
  chmod +x "$fakebin/agent-fleet"
  profile='{"harness":"claude","model":"sonnet","effort":"high","account_pool":"claude-crew","account_profile":"claude-3"}'
  out=$(FM_DISPATCH_AGENT_FLEET="$fakebin/agent-fleet" "$ROOT/bin/fm-dispatch-select.sh" "$profile")
  [ "$out" = "$profile" ] || fail "direct selection dropped account fields: $out"
  [ ! -e "$marker" ] || fail "direct selection should not query Agent Fleet"
  pass "direct dispatch selection preserves account_pool and account_profile"
}

test_pooled_failures_degrade_without_default_account_quota() {
  local fakebin quota_marker out err pooled pinned status
  fakebin=$(fm_fakebin "$TMP_ROOT/account-fallback")
  quota_marker="$TMP_ROOT/account-fallback/quota-called"
  cat > "$fakebin/agent-fleet" <<'SH'
#!/usr/bin/env bash
exit 42
SH
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
touch '$quota_marker'
exit 1
SH
  chmod +x "$fakebin/agent-fleet" "$fakebin/quota-axi"
  pooled='[{"harness":"claude","account_pool":"claude-crew"},{"harness":"codex","account_pool":"codex-crew"}]'
  out=$(FM_DISPATCH_AGENT_FLEET="$fakebin/agent-fleet" FM_DISPATCH_QUOTA_AXI="$fakebin/quota-axi" \
    "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$pooled" 2>"$TMP_ROOT/account-fallback/error.log")
  err=$(cat "$TMP_ROOT/account-fallback/error.log")
  [ "$out" = '{"harness":"claude","account_pool":"claude-crew"}' ] || fail "pool failure should use first profile"
  assert_contains "$err" 'agent-fleet pool status failed' "pool failure fallback was not logged"
  [ ! -e "$quota_marker" ] || fail "pool failure fell through to default-account quota"

  pinned='[{"harness":"claude","account_pool":"claude-crew","account_profile":"claude-1"},{"harness":"codex","account_pool":"codex-crew"}]'
  out=$(FM_DISPATCH_AGENT_FLEET="$fakebin/agent-fleet" "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$pinned" 2>"$TMP_ROOT/account-fallback/pinned.err")
  status=$?
  expect_code 2 "$status" "quota-balanced pinned candidates must be rejected"
  [ -z "$out" ] || fail "rejected pinned selection emitted a profile: $out"
  assert_contains "$(cat "$TMP_ROOT/account-fallback/pinned.err")" 'cannot carry account_profile' "pinned candidate error was unclear"

  pinned='[{"harness":"claude","account_profile":"claude-1"},{"harness":"codex"}]'
  out=$("$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$pinned" 2>"$TMP_ROOT/account-fallback/profile-only.err")
  status=$?
  expect_code 2 "$status" "profile-only quota-balanced candidates must be rejected"
  [ -z "$out" ] || fail "rejected profile-only selection emitted a profile: $out"
  pass "pool-summary failures degrade safely while every pinned quota-balanced candidate is rejected"
}

test_higher_min_vendor_wins
test_exact_tie_uses_first_profile
test_quota_missing_falls_back_to_first
test_quota_error_falls_back_to_first
test_bad_quota_json_falls_back_to_first
test_stale_with_cache_needs_clear_margin_to_beat_fresh
test_vendor_absent_or_unusable_falls_back_conservatively
test_backward_compatible_first_selection
test_account_pool_summary_owns_provider_quota_choice
test_account_fields_survive_direct_selection
test_pooled_failures_degrade_without_default_account_quota

echo "# all fm-dispatch-select tests passed"
