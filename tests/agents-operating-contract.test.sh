#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Contract tests for curation-sensitive firstmate operating rules.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGENTS="$ROOT/AGENTS.md"

assert_single_exact_rule() {
  local rule=$1 label=$2 count
  count=$(grep -Fxc -- "$rule" "$AGENTS" || true)
  [ "$count" -eq 1 ] || fail "$label must appear once verbatim in AGENTS.md, found $count"
}

# Literal Markdown backticks are intentional in the two contract strings below.
# shellcheck disable=SC2016
assert_single_exact_rule \
  'Add the line when you clone or create a project, keep the description useful for identifying the project, and drop the line if a project is ever removed from `projects/`.' \
  "project-registry lifecycle rule"
pass "project-registry lifecycle rule remains verbatim"

# shellcheck disable=SC2016
assert_single_exact_rule \
  'If `config/crew-harness` or `config/secondmate-harness` names an unverified one, tell the captain and fall back to your own harness until it is verified.' \
  "invalid static harness escalation rule"
pass "invalid static harness escalation rule remains verbatim"
