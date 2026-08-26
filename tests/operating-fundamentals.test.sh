#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Contract tests for direct answers, live ownership, recursive unblocking,
# bounded validation, cleanup, and the concise skills that own those practices.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/operating-fundamentals/SKILL.md"
CREW_SKILL="$ROOT/.agents/skills/crew-steering/SKILL.md"
HARNESS_SKILL="$ROOT/.agents/skills/harness-adapters/SKILL.md"
LAVISH_SKILL="$ROOT/.agents/skills/lavish-decisions/SKILL.md"
AGENTS="$ROOT/AGENTS.md"

section_body() {
  local heading=$1
  awk -v heading="$heading" '$0 == heading { capture=1; next } capture && /^## / { exit } capture' "$SKILL"
}

test_operating_skill_shape() {
  local frontmatter headings expected line_count
  assert_present "$SKILL" "operating-fundamentals skill missing"
  frontmatter=$(awk 'NR == 1 && $0 == "---" { capture=1; next } capture && $0 == "---" { exit } capture' "$SKILL")
  assert_contains "$frontmatter" "name: operating-fundamentals" "canonical name missing"
  assert_contains "$frontmatter" "description: >-" "folded YAML required"
  assert_contains "$frontmatter" "user-invocable: false" "agent-only flag missing"
  assert_contains "$frontmatter" "actionable work that stays continuously owned" "description lost its outcome"
  assert_contains "$frontmatter" "making or relaying a consequential claim" "claim trigger missing"
  [ "$(grep -c '^---$' "$SKILL")" -eq 2 ] || fail "invalid frontmatter delimiters"
  line_count=$(wc -l < "$SKILL" | tr -d '[:space:]')
  [ "$line_count" -le 80 ] || fail "operating skill exceeds 80 lines: $line_count"

  headings=$(sed -nE 's/^## ([0-9]+\. .*)$/\1/p' "$SKILL")
  expected=$(printf '%s\n' \
    "1. Preserve the direct-answer boundary" \
    "2. Keep one live owner" \
    "3. Unblock recursively" \
    "4. Bound validation" \
    "5. Reap continuously" \
    "6. Execute explicit orders decisively" \
    "7. Prove consequential claims at their reported scope")
  [ "$headings" = "$expected" ] || fail "operating principles are incomplete or out of order"
  pass "operating skill shape and seven owners"
}

test_direct_answer_and_live_owner() {
  local answer owner
  answer=$(section_body "## 1. Preserve the direct-answer boundary")
  owner=$(section_body "## 2. Keep one live owner")
  assert_contains "$answer" "direct-answer obligation in \`AGENTS.md\`" "direct-answer owner missing"
  assert_contains "$answer" "return it without loading the captain with records, investigation, or machinery" "process substitution remains"
  assert_contains "$answer" "only the bounded work needed" "bounded uncertainty work missing"
  assert_contains "$owner" "one durable record and one live owner" "single ownership missing"
  assert_contains "$owner" "through proof, landing when applicable, reporting, and cleanup" "end-to-end ownership missing"
  assert_contains "$owner" "do not manufacture work merely to fill capacity" "passive lane saturation remains"
  pass "direct answers and live ownership"
}

test_recursive_unblocking_and_bounded_validation() {
  local unblock validation
  unblock=$(section_body "## 3. Unblock recursively")
  validation=$(section_body "## 4. Bound validation")
  assert_contains "$unblock" "routing problem before treating it as a stopping point" "blocker routing missing"
  assert_contains "$unblock" "apply the same test to that blocker" "recursive unblocking missing"
  assert_contains "$unblock" "not scope expansion or a safety bypass" "unblocking boundary missing"
  assert_contains "$unblock" "every materially independent safe route is exhausted with evidence" "escalation bar missing"
  assert_contains "$validation" "finite capacity, not an unbounded fan-out target" "validation bound missing"
  assert_contains "$validation" "excess ready work durably owned in a visible validation queue" "queued ownership missing"
  assert_contains "$validation" "worker drives every synchronous gate return" "validation custody missing"
  assert_contains "$validation" "never an external pause" "parked validation contradiction remains"
  pass "recursive unblocking and bounded validation"
}

test_cleanup_orders_and_claims() {
  local cleanup orders claims
  cleanup=$(section_body "## 5. Reap continuously")
  orders=$(section_body "## 6. Execute explicit orders decisively")
  claims=$(section_body "## 7. Prove consequential claims at their reported scope")
  assert_contains "$cleanup" "On every terminal event" "terminal cleanup trigger missing"
  assert_contains "$cleanup" "cleanup refusal as retained owned work" "cleanup refusal ownership missing"
  assert_contains "$cleanup" "re-evaluate blocked and queued work recursively" "cleanup refill missing"
  assert_contains "$orders" "explicit captain order as the governing objective" "captain order priority missing"
  assert_contains "$orders" "higher-priority safety and authority constraints" "order safety boundary missing"
  for proof in "every leg covered" "single route failure" "report observations only" "direct end-to-end evidence" "unverified" "authoritative reference" "materially independent safe route" "narrowest supported result" "critical path"; do
    assert_contains "$claims" "$proof" "claim proof missing: $proof"
  done
  pass "continuous cleanup, decisive orders, and scoped proof"
}

test_agents_hot_path_and_single_trigger() {
  local trigger_section count
  assert_grep "Answer the captain's current question directly in the same turn" "$AGENTS" "hot path lacks direct-answer rule"
  assert_grep "Every active outcome has one live owner" "$AGENTS" "hot path lacks live ownership"
  assert_grep "Recursively try safe in-scope alternatives" "$AGENTS" "hot path lacks recursive unblocking"
  assert_grep "Bound validation to shared capacity" "$AGENTS" "hot path lacks bounded validation"
  assert_grep "On every terminal event" "$AGENTS" "hot path lacks continuous cleanup"
  assert_grep "Never discard unlanded work" "$AGENTS" "unlanded-work safety missing"
  assert_grep "Fail-closed is reserved for spending money, credentials leaving custody, and irreversible data loss" "$AGENTS" "single-operator fail-closed boundary missing"
  trigger_section=$(awk '/^## 13\. Agent-only reference skills$/ { capture=1; next } capture && /^## / { exit } capture' "$AGENTS")
  count=$(grep -Fc "\`operating-fundamentals\`" "$AGENTS")
  [ "$count" -eq 1 ] || fail "operating-fundamentals must have one trigger owner, found $count"
  assert_contains "$trigger_section" "requires action beyond a direct answer" "actionable-work trigger missing"
  assert_contains "$trigger_section" "recursively unblocking work" "unblocking trigger missing"
  assert_contains "$trigger_section" "admitting validation" "validation trigger missing"
  assert_contains "$trigger_section" "cleaning a terminal lane" "cleanup trigger missing"
  pass "AGENTS hot path and single conditional trigger"
}

test_crew_steering_is_concise_and_active() {
  local line_count
  assert_present "$CREW_SKILL" "crew-steering skill missing"
  line_count=$(wc -l < "$CREW_SKILL" | tr -d '[:space:]')
  [ "$line_count" -le 60 ] || fail "crew-steering exceeds 60 lines: $line_count"
  assert_grep "result, authority boundary, evidence, and next action" "$CREW_SKILL" "concise steer shape missing"
  assert_grep "unsafe or non-isolated worktree" "$CREW_SKILL" "worktree safety missing"
  assert_grep "Apply the same question recursively" "$CREW_SKILL" "recursive steer missing"
  assert_grep "parked approval or fix-review step is not \`paused:\`" "$CREW_SKILL" "validation custody missing"
  assert_grep "bounded validation queue" "$CREW_SKILL" "bounded validation steer missing"
  assert_grep "Do not add motivational padding" "$CREW_SKILL" "anti-padding rule missing"
  pass "crew steering remains concise and active"
}

test_harness_guidance_is_concise_and_owned() {
  local line_count
  line_count=$(wc -l < "$HARNESS_SKILL" | tr -d '[:space:]')
  [ "$line_count" -le 140 ] || fail "harness-adapters exceeds 140 lines: $line_count"
  assert_grep "Use only the verified adapters \`claude\`, \`codex\`, \`opencode\`, \`pi\`, and \`grok\`" "$HARNESS_SKILL" \
    "verified adapter boundary missing"
  assert_grep "A spawn is not complete until the endpoint is running and processing its brief" "$HARNESS_SKILL" \
    "spawn ownership missing"
  assert_grep "security-sensitive mid-run decision" "$HARNESS_SKILL" "permission boundary missing"
  assert_grep "fm_watch_arm_pi" "$HARNESS_SKILL" "Pi primary supervision owner missing"
  assert_grep "The emitted block, not this summary, owns exact commands and repair behavior" "$HARNESS_SKILL" \
    "primary protocol owner missing"
  assert_no_grep "**Incident" "$HARNESS_SKILL" "incident narrative remains in operational harness guidance"
  assert_no_grep "VERIFIED 2026" "$HARNESS_SKILL" "dated verification narrative remains in operational harness guidance"
  pass "harness guidance stays concise, live, and owner-directed"
}

test_live_surface_freshness_contract() {
  assert_grep "Reconcile every captain-facing status, decision, and summary against live fleet state" "$AGENTS" "captain surface freshness missing"
  assert_grep "Remove resolved actionable or decision items" "$AGENTS" "resolved item cleanup missing"
  assert_grep "Reconcile the proposed decision against live fleet state" "$LAVISH_SKILL" "Lavish decision freshness missing"
  assert_grep "The answer file is authoritative; the wake record is only a pointer" "$LAVISH_SKILL" "answer authority missing"
  pass "captain surfaces remain live and answerable"
}

test_provider_neutral_and_no_maintenance_boilerplate() {
  if grep -Eiq 'Claude|Codex|OpenAI|Anthropic|Gemini|Grok|Orca|Herdr|tmux|zellij|cmux|AWS|GitHub|provider|account' "$SKILL"; then
    fail "operating skill contains a named provider, harness, account, or incident dependency"
  fi
  if grep -Eiq 'https?://|@[[:alnum:]_.-]+|[[:xdigit:]]{8}-[[:xdigit:]-]{27,}' "$SKILL"; then
    fail "operating skill contains an incident-specific URL, address, or identifier"
  fi
  pass "operating skill stays provider-neutral"
}

test_operating_skill_shape
test_direct_answer_and_live_owner
test_recursive_unblocking_and_bounded_validation
test_cleanup_orders_and_claims
test_agents_hot_path_and_single_trigger
test_crew_steering_is_concise_and_active
test_harness_guidance_is_concise_and_owned
test_live_surface_freshness_contract
test_provider_neutral_and_no_maintenance_boilerplate
