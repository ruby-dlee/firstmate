#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Behavior tests for /stow's inspect-then-update memory contract.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_stow_skill_task_note_contract() {
  local stow="$ROOT/.agents/skills/stow/SKILL.md"

  assert_grep 'tasks-axi show <id> --full' "$stow" "stow skill does not require inspecting task notes first"
  assert_grep 'tasks-axi update <id> --body-file <path>' "$stow" "stow skill does not require task body replacement"
  assert_grep '--archive-body' "$stow" "stow skill does not document recoverable task body archival"
  assert_grep 'Never append.' "$stow" "stow skill does not forbid append-first task notes"
  assert_no_grep 'carry that context into the replacement body' "$stow" "stow skill still preserves archive-only context in the replacement body"
  pass "stow skill task-note contract includes recoverable body archival"
}

test_agents_routes_task_note_mechanics_to_owner() {
  local agents="$ROOT/AGENTS.md"

  assert_no_grep 'tasks-axi show <id> --full' "$agents" "AGENTS.md duplicates conditional task-note mechanics"
  assert_no_grep 'tasks-axi update <id> --body-file <path>' "$agents" "AGENTS.md duplicates task-note command syntax"
  assert_grep "Load \`/stow\`" "$agents" "AGENTS.md does not route the stow workflow to its skill"
  assert_grep 'current command help own schema, compatibility, retention, and exact verbs' "$agents" \
    "AGENTS.md does not route routine backlog mechanics to command help"
  pass "AGENTS.md routes conditional task-note mechanics to their owner"
}

test_stow_skill_task_note_contract
test_agents_routes_task_note_mechanics_to_owner
