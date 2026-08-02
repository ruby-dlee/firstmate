#!/usr/bin/env bash
# Behavior tests for deterministic crew-dispatch profile selection.
set -u
export FM_ACCOUNT_ROUTING_TEST_LAB=firstmate-account-routing-test-lab-v1

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

test_dispatch_ignores_hostile_path_jq_and_dirname() {
  local fakebin jq_marker dirname_marker cat_marker awk_marker spec out stdin_out
  fakebin=$(fm_fakebin "$TMP_ROOT/hostile-path-tools")
  jq_marker="$TMP_ROOT/hostile-path-tools/jq-called"
  dirname_marker="$TMP_ROOT/hostile-path-tools/dirname-called"
  cat_marker="$TMP_ROOT/hostile-path-tools/cat-called"
  awk_marker="$TMP_ROOT/hostile-path-tools/awk-called"
  cat > "$fakebin/jq" <<SH
#!/bin/sh
printf called > '$jq_marker'
printf '%s\n' '{"harness":"forged"}'
SH
  cat > "$fakebin/dirname" <<SH
#!/bin/sh
printf called > '$dirname_marker'
printf '%s\n' /forged
SH
  cat > "$fakebin/cat" <<SH
#!/bin/sh
printf called > '$cat_marker'
printf '%s\n' '{"harness":"forged"}'
SH
  cat > "$fakebin/awk" <<SH
#!/bin/sh
printf called > '$awk_marker'
printf '%s\n' 'forged help'
SH
  chmod +x "$fakebin/jq" "$fakebin/dirname" "$fakebin/cat" "$fakebin/awk"
  spec='{"harness":"claude","model":"sonnet"}'

  out=$(CDPATH='' builtin cd -- "$ROOT/bin" && \
    PATH="$fakebin:$BASE_PATH" /bin/bash fm-dispatch-select.sh "$spec")
  stdin_out=$(printf '%s\n' "$spec" | (CDPATH='' builtin cd -- "$ROOT/bin" && \
    PATH="$fakebin:$BASE_PATH" /bin/bash fm-dispatch-select.sh))

  [ "$out" = '{"harness":"claude","model":"sonnet"}' ] \
    || fail "hostile PATH forged dispatch selection: $out"
  [ "$stdin_out" = "$out" ] || fail "hostile PATH forged stdin dispatch selection: $stdin_out"
  [ ! -e "$jq_marker" ] || fail "dispatch executed hostile PATH jq"
  [ ! -e "$dirname_marker" ] || fail "dispatch executed hostile PATH dirname"
  [ ! -e "$cat_marker" ] || fail "dispatch executed hostile PATH cat"
  [ ! -e "$awk_marker" ] || fail "dispatch executed hostile PATH awk"
  pass "dispatch pins its parser and input tools without ambient PATH resolution"
}

test_account_pool_defers_selection_to_direct_spawn() {
  local fakebin af_log quota_marker out pooled err
  fakebin=$(fm_fakebin "$TMP_ROOT/agent-fleet-pools")
  af_log="$TMP_ROOT/agent-fleet-pools/calls.log"
  quota_marker="$TMP_ROOT/agent-fleet-pools/quota-called"
  cat > "$fakebin/agent-fleet" <<SH
#!/usr/bin/env bash
touch '$af_log'
exit 1
SH
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
touch '$quota_marker'
exit 1
SH
  chmod +x "$fakebin/agent-fleet" "$fakebin/quota-axi"
  pooled='[{"harness":"claude","model":"sonnet","account_pool":"claude-crew"},{"harness":"codex","model":"gpt-5","account_pool":"codex-crew"}]'
  out=$(FM_AGENT_FLEET_BIN="$fakebin/agent-fleet" \
    FM_DISPATCH_QUOTA_AXI="$fakebin/quota-axi" "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$pooled" \
    2>"$TMP_ROOT/agent-fleet-pools/error.log")
  err=$(cat "$TMP_ROOT/agent-fleet-pools/error.log")
  [ "$out" = '{"harness":"claude","model":"sonnet","account_pool":"claude-crew"}' ] \
    || fail "pooled dispatch did not preserve ordered direct-routing activation: $out"
  [ ! -e "$af_log" ] || fail "new pooled dispatch queried Agent Fleet: $(cat "$af_log")"
  [ ! -e "$quota_marker" ] || fail "account_pool selection consulted default-account quota-axi"
  assert_contains "$err" 'deferring account selection to spawn' "pooled dispatch did not explain direct selection ownership"
  pass "account_pool dispatch defers account choice to direct spawn selection"
}

test_enforced_quota_balancing_rejects_poolless_candidates() {
  local fakebin quota_marker profiles out status
  fakebin=$(fm_fakebin "$TMP_ROOT/enforced-pool-only")
  quota_marker="$TMP_ROOT/enforced-pool-only/quota-called"
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
touch '$quota_marker'
exit 1
SH
  chmod +x "$fakebin/quota-axi"
  profiles='[{"harness":"claude"},{"harness":"codex"}]'
  out=$(FM_ACCOUNT_ROUTING=enforce FM_DISPATCH_QUOTA_AXI="$fakebin/quota-axi" \
    "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$profiles" 2>"$TMP_ROOT/enforced-pool-only/error.log")
  status=$?
  expect_code 2 "$status" "enforced poolless quota-balanced dispatch must be rejected"
  [ -z "$out" ] || fail "rejected enforced selection emitted a profile: $out"
  [ ! -e "$quota_marker" ] || fail "enforced poolless selection consulted ambient quota-axi"
  assert_contains "$(cat "$TMP_ROOT/enforced-pool-only/error.log")" 'requires a non-empty valid account_pool on every candidate' \
    "enforced pool-only error was unclear"

  profiles='[{"harness":"claude","account_pool":""},{"harness":"codex","account_pool":"codex-crew"}]'
  out=$(FM_ACCOUNT_ROUTING=enforce "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$profiles" \
    2>"$TMP_ROOT/enforced-pool-only/empty-error.log")
  status=$?
  expect_code 2 "$status" "enforced empty account pool must be rejected"
  [ -z "$out" ] || fail "rejected empty pool selection emitted a profile: $out"

  profiles='[{"harness":"claude","account_pool":"-invalid"},{"harness":"codex","account_pool":"codex-crew"}]'
  out=$(FM_ACCOUNT_ROUTING=enforce "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$profiles" \
    2>"$TMP_ROOT/enforced-pool-only/invalid-error.log")
  status=$?
  expect_code 2 "$status" "enforced invalid account pool must be rejected"
  [ -z "$out" ] || fail "rejected invalid pool selection emitted a profile: $out"

  profiles='[{"harness":"claude","account_pool":"good\npool"},{"harness":"codex","account_pool":"codex-crew"}]'
  out=$(FM_ACCOUNT_ROUTING=enforce "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$profiles" \
    2>"$TMP_ROOT/enforced-pool-only/newline-error.log")
  status=$?
  expect_code 2 "$status" "enforced account pool with an embedded newline must be rejected"
  [ -z "$out" ] || fail "rejected embedded-newline pool selection emitted a profile: $out"

  profiles='[{"harness":"claude","account_pool":"good-pool\n"},{"harness":"codex","account_pool":"codex-crew"}]'
  out=$(FM_ACCOUNT_ROUTING=enforce "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$profiles" \
    2>"$TMP_ROOT/enforced-pool-only/trailing-newline-error.log")
  status=$?
  expect_code 2 "$status" "enforced account pool with a trailing newline must be rejected"
  [ -z "$out" ] || fail "rejected trailing-newline pool selection emitted a profile: $out"
  pass "enforced quota-balanced dispatch accepts only explicit pools"
}

test_fully_pooled_dispatch_ignores_overridden_ambient_mode() {
  local pooled mixed out status
  pooled='[{"harness":"claude","account_pool":"claude-crew"},{"harness":"codex","account_pool":"codex-crew"}]'
  out=$(FM_ACCOUNT_ROUTING=malformed "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$pooled") \
    || fail "fully pooled dispatch parsed overridden ambient routing policy"
  [ "$out" = '{"harness":"claude","account_pool":"claude-crew"}' ] \
    || fail "fully pooled dispatch returned the wrong selection: $out"

  mixed='[{"harness":"claude","account_pool":"claude-crew"},{"harness":"codex"}]'
  out=$(FM_ACCOUNT_ROUTING=malformed "$ROOT/bin/fm-dispatch-select.sh" --select quota-balanced "$mixed" 2>/dev/null)
  status=$?
  expect_code 2 "$status" "mixed pooled dispatch must still fail closed on malformed routing mode"
  [ -z "$out" ] || fail "rejected mixed dispatch emitted a selection: $out"
  pass "fully pooled dispatch honors explicit pool precedence over ambient routing"
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
  out=$(FM_AGENT_FLEET_BIN="$fakebin/agent-fleet" "$ROOT/bin/fm-dispatch-select.sh" "$profile")
  [ "$out" = "$profile" ] || fail "direct selection dropped account fields: $out"
  [ ! -e "$marker" ] || fail "direct selection should not query Agent Fleet"
  pass "direct dispatch selection preserves account_pool and account_profile"
}

if [ "${FM_TEST_FOCUSED:-}" = account-directory-cutover ]; then
  test_account_pool_defers_selection_to_direct_spawn
  test_fully_pooled_dispatch_ignores_overridden_ambient_mode
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-13 ]; then
  test_enforced_quota_balancing_rejects_poolless_candidates
  test_fully_pooled_dispatch_ignores_overridden_ambient_mode
  exit 0
fi

test_higher_min_vendor_wins
test_exact_tie_uses_first_profile
test_quota_missing_falls_back_to_first
test_quota_error_falls_back_to_first
test_bad_quota_json_falls_back_to_first
test_stale_with_cache_needs_clear_margin_to_beat_fresh
test_vendor_absent_or_unusable_falls_back_conservatively
test_backward_compatible_first_selection
test_account_pool_defers_selection_to_direct_spawn
test_dispatch_ignores_hostile_path_jq_and_dirname
test_enforced_quota_balancing_rejects_poolless_candidates
test_fully_pooled_dispatch_ignores_overridden_ambient_mode
test_account_fields_survive_direct_selection

echo "# all fm-dispatch-select tests passed"
