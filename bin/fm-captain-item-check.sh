#!/usr/bin/env bash
# fm-captain-item-check.sh - pre-surface guard for captain-facing risk and decision items.
#
# WHY THIS EXISTS: a risk label, an internal mechanism, and a failure mode do
# not give the captain enough information to weigh a tradeoff or correct a bad
# premise.
# A promise to write more clearly is not enforcement, so this check refuses an
# item until it names the system's purpose, the business impact, both sides of
# the cost tradeoff, and the exact decision being requested in plain language.
#
# Each file contains exactly one item with these level-two sections, in order:
#
#   ## System and purpose
#   ## Business impact
#   ## Fix cost
#   ## Leave cost
#   ## Decision requested
#
# Usage:
#   fm-captain-item-check.sh <risk|decision> <file-with-one-item>
#
# Exit 0 = clear to surface.
# Exit 1 = hard draft failure; fix every reported element first.
# Exit 2 = invalid mode or unreadable file.
set -uo pipefail

MODE=${1:-}
FILE=${2:-}

case "$MODE" in
  risk|decision) ;;
  *)
    printf 'usage: %s <risk|decision> <file>\n' "${0##*/}" >&2
    exit 2
    ;;
esac

[ -n "$FILE" ] && [ -r "$FILE" ] || {
  printf 'captain-item-check: error: unreadable item file: %s\n' "$FILE" >&2
  exit 2
}

failures=''

add_failure() {
  failures="${failures}${1}"$'\n'
}

heading_count() {
  local heading=$1
  awk -v heading="$heading" '$0 == heading { count += 1 } END { print count + 0 }' "$FILE"
}

section_body() {
  local heading=$1
  awk -v heading="$heading" '
    $0 == heading { inside = 1; next }
    inside && /^## / { exit }
    inside { print }
  ' "$FILE"
}

word_count() {
  awk '{ count += NF } END { print count + 0 }'
}

check_section() {
  local heading=$1 element=$2 description=$3 minimum_words=$4 count body words
  count=$(heading_count "$heading")
  if [ "$count" -eq 0 ]; then
    add_failure "missing: $element - $description"
    return
  fi
  if [ "$count" -ne 1 ]; then
    add_failure "invalid: $element - heading must appear exactly once"
    return
  fi
  body=$(section_body "$heading")
  words=$(printf '%s\n' "$body" | word_count)
  if [ "$words" -lt "$minimum_words" ]; then
    add_failure "thin: $element - $description must be substantive (found $words words, need at least $minimum_words)"
  fi
}

check_section '## System and purpose' \
  'system-purpose' 'what the system does and why it exists' 12
check_section '## Business impact' \
  'business-impact' 'what breaks and which customers or business outcome feel it' 12
check_section '## Fix cost' \
  'tradeoff.fix-cost' 'what fixing or containing the risk costs' 8
check_section '## Leave cost' \
  'tradeoff.leave-cost' 'what leaving the item unchanged costs' 8
check_section '## Decision requested' \
  'decision' 'the specific call the captain is making' 8

headings=$(awk '/^## / { print }' "$FILE")
expected_headings=$(cat <<'EOF'
## System and purpose
## Business impact
## Fix cost
## Leave cost
## Decision requested
EOF
)
if [ "$headings" != "$expected_headings" ]; then
  add_failure 'invalid: structure - use the five required sections once each and in the documented order'
fi

system_body=$(section_body '## System and purpose')
if [ -n "$system_body" ] && ! printf '%s\n' "$system_body" \
  | grep -qiE '(^|[[:space:][:punct:]])(to|so|because|exists to)([[:space:][:punct:]]|$)'; then
  add_failure 'missing: system-purpose - state why the system exists, not only what it does'
fi

impact_body=$(section_body '## Business impact')
if [ -n "$impact_body" ] && ! printf '%s\n' "$impact_body" \
  | grep -qiE 'customer|shopper|merchant|buyer|subscriber|user|people|operator|team|business|Relvino'; then
  add_failure 'missing: business-impact - name who feels the failure'
fi
if [ -n "$impact_body" ] && ! printf '%s\n' "$impact_body" \
  | grep -qiE 'charge|bill|pay|lose|miss|wrong|delay|stop|fail|expose|privacy|revenue|trust|service|cashback|report|recommendation|purchase|campaign|message|harm|risk'; then
  add_failure 'missing: business-impact - name the customer or business outcome that changes'
fi

decision_body=$(section_body '## Decision requested')
if [ -n "$decision_body" ] && ! printf '%s\n' "$decision_body" | grep -q '?'; then
  add_failure 'missing: decision - ask the specific call as a question'
fi
if [ -n "$decision_body" ] && ! printf '%s\n' "$decision_body" \
  | grep -qiE 'approve|authorize|choose|decide|allow|keep|disable|accept|whether|which|should'; then
  add_failure 'missing: decision - name the action or choice being decided'
fi

# These terms are not forbidden in engineering work.
# They are refused here because an unexplained mechanism name displaces the
# captain-facing explanation this format exists to require.
for term in \
  cron guard pointer route path main branch commit 'pull request' test tests \
  'test suite' Redis ClickHouse DML TTL mutex lease feed ingest API HTTP JSON \
  SQL schema module class function method
do
  if grep -qiE "(^|[^[:alnum:]_])${term}([^[:alnum:]_]|$)" "$FILE"; then
    add_failure "opaque: internal term '$term' - replace it with the user-visible behavior"
  fi
done

if grep -qE '`|[[:alnum:]]_[[:alnum:]]|[[:lower:]][[:upper:]][[:alnum:]]*' "$FILE"; then
  add_failure 'opaque: code-shaped name - remove internal identifiers from the captain-facing item'
fi
if grep -qiE '(^|[^[:alnum:]])(PR[[:space:]]*#[0-9]+|[[:xdigit:]]{7,40}|[^[:space:]]+\.(py|sh|ts|tsx|js|json|md)(:[0-9]+)?)([^[:alnum:]]|$)' "$FILE"; then
  add_failure 'opaque: engineering reference - explain the business behavior instead of citing implementation evidence'
fi

if [ -n "$failures" ]; then
  printf 'captain-item-check: FAIL (mode=%s, file=%s)\n' "$MODE" "$FILE"
  printf '%s' "$failures" | while IFS= read -r failure; do
    [ -n "$failure" ] && printf '  %s\n' "$failure"
  done
  exit 1
fi

printf 'captain-item-check: CLEAR (mode=%s, file=%s)\n' "$MODE" "$FILE"
