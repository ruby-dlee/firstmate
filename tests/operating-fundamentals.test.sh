#!/usr/bin/env bash
# Contract tests for operating fundamentals and related behavioral guardrails.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/operating-fundamentals/SKILL.md"
CREW_SKILL="$ROOT/.agents/skills/crew-steering/SKILL.md"
LAVISH_SKILL="$ROOT/.agents/skills/lavish-decision-boards/SKILL.md"
AGENTS="$ROOT/AGENTS.md"

test_agent_only_folded_frontmatter_and_size() {
  local frontmatter line_count delimiter_count

  assert_present "$SKILL" "operating-fundamentals SKILL.md is missing"
  frontmatter=$(awk 'NR == 1 && $0 == "---" { capture=1; next } capture && $0 == "---" { exit } capture' "$SKILL")
  assert_contains "$frontmatter" "name: operating-fundamentals" "skill frontmatter is missing its canonical name"
  assert_contains "$frontmatter" "description: >-" "skill description must use folded YAML metadata"
  assert_contains "$frontmatter" "user-invocable: false" "skill must remain agent-only"
  assert_contains "$frontmatter" "metadata:" "skill frontmatter is missing internal metadata"
  assert_contains "$frontmatter" "  internal: true" "skill must remain internal"
  assert_contains "$frontmatter" "Use when intaking any captain ask" "folded metadata must name a concrete intake trigger"
  assert_contains "$frontmatter" "supervising under load" "folded metadata must name a concrete supervision trigger"
  assert_contains "$frontmatter" "about to assert a fleet fact" "folded metadata must name a concrete verification trigger"

  delimiter_count=$(grep -c '^---$' "$SKILL")
  [ "$delimiter_count" -eq 2 ] || fail "skill must have one closed YAML frontmatter block"
  line_count=$(wc -l < "$SKILL" | tr -d '[:space:]')
  [ "$line_count" -le 90 ] || fail "skill exceeds the 90-line limit: $line_count"
  pass "operating-fundamentals has folded agent-only frontmatter, concrete triggers, and stays within 90 lines"
}

test_seven_ordered_principles() {
  local headings expected

  headings=$(sed -nE 's/^## ([0-9]+\. .*)$/\1/p' "$SKILL")
  expected=$(printf '%s\n' \
    "1. Orchestrate; never work inline" \
    "2. Saturate every available lane" \
    "3. Route around blockers" \
    "4. Decouple validation from worker budgets" \
    "5. Reap continuously" \
    "6. Obey explicit orders decisively" \
    "7. Always check before asserting")
  [ "$headings" = "$expected" ] || fail "skill must contain exactly seven ordered operating-principle headings"

  assert_grep "every captain ask" "$SKILL" "orchestration principle must cover every captain ask"
  assert_grep "durable backlog item" "$SKILL" "orchestration principle must require durable backlog tracking"
  assert_grep "tracked crew assignment" "$SKILL" "orchestration principle must require a tracked owner"
  assert_grep "never perform project investigation, planning, implementation, or deliverable production inline" "$SKILL" "orchestration principle must forbid inline project and deliverable work"
  assert_grep "every healthy lane" "$SKILL" "lane-saturation principle is missing"
  assert_grep "blocker as a routing problem" "$SKILL" "blocker-routing principle is missing"
  assert_grep "shared validation" "$SKILL" "independent-validation principle is missing"
  assert_grep "single exhaustible budget" "$SKILL" "independent-validation principle must cover depleted worker budgets"
  assert_grep "On every terminal wake" "$SKILL" "continuous-reaping principle is missing"
  assert_grep "Fill released capacity" "$SKILL" "continuous-reaping principle must refill freed lanes"
  assert_grep "explicit captain order as the governing objective" "$SKILL" "explicit-order principle is missing"
  assert_grep "non-overridable safety and instruction constraints" "$SKILL" "explicit-order principle must retain non-overridable constraints"
  assert_grep "consequential action" "$SKILL" "premise-check principle must cover consequential actions"
  assert_grep "load-bearing assumption" "$SKILL" "premise-check principle must identify one load-bearing assumption"
  assert_grep "clearly-false premises" "$SKILL" "premise-check principle must catch clearly-false premises"
  assert_grep "do not overcorrect" "$SKILL" "premise-check principle must forbid overcorrection"
  assert_grep "safe to bypass" "$SKILL" "purpose-before-bypass principle must cover bypass classification"
  assert_grep "target outcome" "$SKILL" "purpose-before-bypass principle must establish the operation's purpose"
  assert_grep "critical path" "$SKILL" "purpose-before-bypass principle must protect the target's critical path"
  assert_grep "consequential bypass that gates an irreversible or high-stakes action" "$SKILL" "purpose-before-bypass principle must scope written rationale to consequential bypasses"
  assert_grep "record that target outcome and the rationale" "$SKILL" "purpose-before-bypass principle must require a written purpose and rationale"
  assert_grep "trivial skips do not require this written record" "$SKILL" "purpose-before-bypass principle must exempt trivial skips from written rationale"
  assert_grep "operation failing, not noise" "$SKILL" "purpose-before-bypass principle must treat target-capability failure as operation failure"
  pass "operating-fundamentals encodes all seven principles in the required order"
}

test_single_conditional_agents_trigger() {
  local section global_count section_count

  section=$(awk '/^## 13\. Agent-only reference skills$/ { capture=1; next } capture && /^## / { exit } capture' "$AGENTS")
  global_count=$(grep -Fc "\`operating-fundamentals\`" "$AGENTS")
  section_count=$(printf '%s\n' "$section" | grep -Fc "\`operating-fundamentals\`")
  [ "$global_count" -eq 1 ] || fail "AGENTS.md must reference operating-fundamentals exactly once"
  [ "$section_count" -eq 1 ] || fail "the sole operating-fundamentals reference must be in section 13"
  assert_contains "$section" "\`operating-fundamentals\` - load when intaking any captain ask" "section 13 must conditionally load the skill at intake"
  pass "AGENTS.md contains one conditional section-13 trigger and no every-turn duplicate"
}

test_crew_steering_contract_and_trigger() {
  local section headings expected

  assert_present "$CREW_SKILL" "crew-steering SKILL.md is missing"
  assert_grep "name: crew-steering" "$CREW_SKILL" "crew-steering skill is missing its canonical name"
  headings=$(sed -nE 's/^## ([1-6]\. .*)$/\1/p' "$CREW_SKILL")
  expected=$(printf '%s\n' \
    "1. Demand ownership" \
    "2. Reject vague or optimistic claims" \
    "3. Fact-check the load-bearing premise" \
    "4. Prefer quality and robustness" \
    "5. Preserve goal fidelity" \
    "6. Be direct and early")
  [ "$headings" = "$expected" ] || fail "crew-steering must retain all six captain-standard guardrails"

  section=$(awk '/^## 13\. Agent-only reference skills$/ { capture=1; next } capture && /^## / { exit } capture' "$AGENTS")
  assert_contains "$section" "\`crew-steering\` - load before writing or materially revising any crew brief and before live-steering a crew" "section 13 must trigger crew-steering for briefs and live steers"
  pass "crew-steering retains its six guardrails and conditional trigger"
}

test_live_surface_freshness_contract() {
  assert_grep "reconcile it against live fleet state" "$AGENTS" "captain-facing surfaces must reconcile against live state"
  assert_grep "removing resolved actionable or decision items" "$AGENTS" "serve-fresh removal must cover resolved actionable and decision items"
  assert_grep "Recently Landed section of \`/bearings\` and \`/reports\`" "$AGENTS" "completion-oriented surfaces must retain relevant history"
  assert_grep "never render it from a remembered snapshot" "$LAVISH_SKILL" "Lavish boards must use live fleet state"
  assert_grep "Answer preservation takes precedence over the serve-fresh rule" "$LAVISH_SKILL" "answer preservation must take precedence while input is unsubmitted"
  assert_grep "Never edit, refresh, or reload a served board while the captain is answering" "$LAVISH_SKILL" "served boards must preserve in-progress answers"
  assert_grep "After submission, reconcile and refresh before continuing" "$LAVISH_SKILL" "served boards must refresh safely after answer submission"
  pass "live-surface freshness preserves completion history and in-progress answers"
}

test_provider_neutral_and_no_maintenance_boilerplate() {
  if grep -Eiq 'Claude|Codex|OpenAI|Anthropic|Gemini|Grok|Orca|Herdr|tmux|zellij|cmux|AWS|GitHub|provider|account' "$SKILL"; then
    fail "skill contains a named provider, harness, account, or incident-specific dependency"
  fi
  if grep -Eiq 'https?://|@[[:alnum:]_.-]+|[[:xdigit:]]{8}-[[:xdigit:]-]{27,}' "$SKILL"; then
    fail "skill contains an incident-specific URL, address, or identifier"
  fi
  if grep -Eiq 'maintain|maintenance|when updating|keep this file|for maintainers' "$SKILL"; then
    fail "skill contains maintenance boilerplate"
  fi
  pass "operating-fundamentals stays provider-neutral and omits incident and maintenance detail"
}

test_agent_only_folded_frontmatter_and_size
test_seven_ordered_principles
test_single_conditional_agents_trigger
test_crew_steering_contract_and_trigger
test_live_surface_freshness_contract
test_provider_neutral_and_no_maintenance_boilerplate
