#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Behavioral contract for the lavish-repair skill's route order, download-only
# recovery boundary, and prohibition on browser-owned pickup machinery.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SKILL="$ROOT/.agents/skills/lavish-repair/SKILL.md"
AGENTS="$ROOT/AGENTS.md"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

assert_grep() {
  local pattern=$1
  local file=$2
  local message=$3
  grep -Fq -- "$pattern" "$file" || fail "$message"
}

test_internal_skill_and_trigger() {
  local section global_count section_count

  [ -f "$SKILL" ] || fail "lavish-repair SKILL.md is missing"
  assert_grep "name: lavish-repair" "$SKILL" "skill name is missing"
  assert_grep "user-invocable: false" "$SKILL" "skill must not be captain-invocable"
  assert_grep "metadata:" "$SKILL" "skill is missing internal metadata"
  assert_grep "internal: true" "$SKILL" "skill is not marked internal"

  section=$(awk '/^## 13\. Agent-only reference skills$/ { capture=1; next } capture && /^## / { exit } capture' "$AGENTS")
  global_count=$(grep -Fc "\`lavish-repair\`" "$AGENTS")
  section_count=$(printf '%s\n' "$section" | grep -Fc "\`lavish-repair\`")
  [ "$global_count" -eq 1 ] || fail "AGENTS.md must reference lavish-repair exactly once"
  [ "$section_count" -eq 1 ] || fail "lavish-repair trigger must live in section 13"
  assert_grep "self-contained Lavish board fails preflight, default-browser open, interaction, answer download, or bounded intake" \
    "$AGENTS" "trigger must cover every file-board failure stage"
  assert_grep "before touching a generated board or downloaded-answer artifact" \
    "$AGENTS" "trigger must fire before artifact repair"
  pass "lavish-repair is internal and has one route-complete conditional trigger"
}

test_route_order_and_owners() {
  local preflight_line browser_line interaction_line download_line intake_line

  preflight_line=$(grep -nF '### 1. Answerability preflight' "$SKILL" | cut -d: -f1) ||
    fail "answerability-preflight diagnosis stage is missing"
  browser_line=$(grep -nF '### 2. Browser open' "$SKILL" | cut -d: -f1) ||
    fail "browser-open diagnosis stage is missing"
  interaction_line=$(grep -nF '### 3. Board interaction' "$SKILL" | cut -d: -f1) ||
    fail "board-interaction diagnosis stage is missing"
  download_line=$(grep -nF '### 4. Downloaded answer' "$SKILL" | cut -d: -f1) ||
    fail "downloaded-answer diagnosis stage is missing"
  intake_line=$(grep -nF '### 5. Intake and collection' "$SKILL" | cut -d: -f1) ||
    fail "intake diagnosis stage is missing"
  [ "$preflight_line" -lt "$browser_line" ] || fail "preflight must precede browser diagnosis"
  [ "$browser_line" -lt "$interaction_line" ] || fail "browser open must precede interaction diagnosis"
  [ "$interaction_line" -lt "$download_line" ] || fail "interaction must precede download diagnosis"
  [ "$download_line" -lt "$intake_line" ] || fail "download must precede intake diagnosis"

  assert_grep "Read \`bin/fm-lavish-board.sh\`'s header and \`--help\` output" \
    "$SKILL" "board helper ownership is missing"
  assert_grep "Read \`tools/lavish/README.md\` for the durable decision, downloaded payload, and intake protocol" \
    "$SKILL" "durable protocol ownership is missing"
  assert_grep "Load \`lavish-decisions\` before completing the normal consume workflow" \
    "$SKILL" "normal workflow handoff is missing"
  assert_grep "has no server, session URL, live channel, browser automation session, listener, poller, or armed submission check" \
    "$SKILL" "removed browser-anchor boundary is missing"
  pass "lavish-repair diagnoses the download-only route in owner-defined order"
}

test_preflight_and_browser_contracts() {
  assert_grep "read its named missing components" "$SKILL" \
    "preflight failure must report missing answerability components"
  assert_grep "Do not bypass the preflight or substitute hand-authored HTML" \
    "$SKILL" "preflight bypasses must remain forbidden"
  assert_grep "has not invoked the default browser when this check fails" \
    "$SKILL" "preflight failure boundary is missing"
  assert_grep "exact terminal fallback emitted by \`lavish-axi create\`" \
    "$SKILL" "preflight terminal fallback is missing"
  assert_grep "Do not launch a dedicated browser profile, Chrome DevTools process, browser automation session, server, or resident helper" \
    "$SKILL" "browser-anchor workaround is not forbidden"
  assert_grep "protect any unsubmitted captain input before reloading or reopening" \
    "$SKILL" "unsubmitted-input guard is missing"
  assert_grep "download button, or manual payload backup are missing" \
    "$SKILL" "answerability drift must include the new landing surfaces"
  pass "lavish-repair preserves preflight and unowned-browser boundaries"
}

test_download_and_intake_contracts() {
  assert_grep "landing record is \`lavish-answer-<decision-id>-<request-digest>.json\`" \
    "$SKILL" "downloaded landing record is missing"
  assert_grep "exposes the exact JSON as a manual backup" \
    "$SKILL" "manual payload recovery is missing"
  assert_grep "Do not report automatic delivery or wait for a submission prompt; neither exists" \
    "$SKILL" "removed automatic pickup is still being promised"
  assert_grep "Do not add browser-profile storage, an armed check, filesystem watcher, timer sweep, long poll, server, or resident process" \
    "$SKILL" "replacement pickup machinery is not forbidden"
  assert_grep "Run \`lavish-axi intake --home <resolved-absolute-home>\` once" \
    "$SKILL" "bounded intake handoff is missing"
  assert_grep "validates the schema, decision id, request digest, ordered keys, and declared values" \
    "$SKILL" "immutable request and ordered-entry validation is missing"
  assert_grep "commits \`answer.toon\`, writes the declared destination, and then writes \`receipt.toon\`" \
    "$SKILL" "durable answer publication order is missing"
  assert_grep "do not weaken the schema, key, option, annotation, home-marker, or request-digest checks" \
    "$SKILL" "collection validation must remain fail-closed"
  pass "lavish-repair retains the downloaded answer and durable intake contracts"
}

test_recovery_contract() {
  assert_grep "A surface failure does not erase the durable decision, a downloaded payload, a manual payload backup, or a collected answer" \
    "$SKILL" "durable-state survival boundary is missing"
  assert_grep "Use \`lavish show\` and \`lavish inbox\` with the explicit Firstmate home" \
    "$SKILL" "durable-state inspection sequence is missing"
  assert_grep "Reopen a board only when no submitted payload exists" \
    "$SKILL" "safe reopen gate is missing"
  assert_grep "the exact \`lavish answer ... --home ...\` creation fallback keeps the decision answerable" \
    "$SKILL" "browser-independent answer fallback is missing"
  pass "lavish-repair retains durable recovery without process lifecycle advice"
}

test_internal_skill_and_trigger
test_route_order_and_owners
test_preflight_and_browser_contracts
test_download_and_intake_contracts
test_recovery_contract
