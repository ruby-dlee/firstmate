#!/usr/bin/env bash
# Tests for bin/fm-toon-lib.sh: the strict structural TOON reader that gates
# bin/fm-pr-merge.sh, which arms merges unattended.
#
# These tests are driven from MALFORMED input on purpose. Well-formed fixtures
# are exactly what let a lenient parser survive review: they only ever exercise
# the shape you already believe in. Every case below feeds the reader something
# broken and asserts it REFUSES, because every historical fault in the parser it
# replaces failed in the same direction - a failing check got dropped, absorbed,
# skipped, or normalised away, and the PR read green.
#
# The eight fault instances this replaces, each covered by name below:
#   (1) tabular payload declaring [N] with an extra row silently dropped it
#   (2) expanded-array counting keyed on `- __typename:`, so an item whose first
#       key differed was absorbed into the previous node
#   (3) every value except `true` treated as terminal, so a missing or malformed
#       flag ended a decision as though it were an affirmative negative
#   (4) malformed values normalised into valid ones: quotes stripped
#       independently, booleans lowercased, case variants accepted
#   (5) a key matched at ANY indentation, so a key nested under an unrelated
#       parent satisfied a lookup meant for the top level
#   (6) a block finished on dedent SILENTLY IGNORED the triggering line, so the
#       record that ended one block was lost rather than beginning the next
#   (7) a line the parser could not classify was absorbed rather than refused
#   (8) empty values and values valid for a different field slipped through
#
# Real captured gh-axi payloads live in tests/fixtures/toon/ and are exercised
# first, so the strictness below is proven not to reject the real thing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-toon-lib.sh
. "$ROOT/bin/fm-toon-lib.sh"

FIXTURES="$ROOT/tests/fixtures/toon"

TOON_OUT=
TOON_RC=0

run_toon() {
  local mode=$1 path=$2 payload=$3
  TOON_OUT=$(printf '%s\n' "$payload" | fm_toon_query "$mode" "$path" 2>&1) && TOON_RC=0 || TOON_RC=$?
}

# The reader must refuse, and its message must name the problem.
expect_refuse() {
  local name=$1 mode=$2 path=$3 payload=$4 needle=${5:-}
  run_toon "$mode" "$path" "$payload"
  [ "$TOON_RC" -ne 0 ] \
    || fail "$name: expected a refusal, got rc=0 with [$TOON_OUT]"
  if [ -n "$needle" ]; then
    case "$TOON_OUT" in
      *"$needle"*) ;;
      *) fail "$name: refusal did not mention [$needle]; got [$TOON_OUT]" ;;
    esac
  fi
}

expect_value() {
  local name=$1 mode=$2 path=$3 payload=$4 want=$5
  run_toon "$mode" "$path" "$payload"
  [ "$TOON_RC" -eq 0 ] \
    || fail "$name: expected [$want], but the reader refused with [$TOON_OUT]"
  [ "$TOON_OUT" = "$want" ] \
    || fail "$name: expected [$want], got [$TOON_OUT]"
}

# --- real captured gh-axi payloads ------------------------------------------

test_real_payloads_parse() {
  local f
  for f in "$FIXTURES"/*.toon; do
    fm_toon_validate < "$f" \
      || fail "real payload $(basename "$f") did not validate"
  done

  [ "$(fm_toon_get pull_request.state < "$FIXTURES/gh-axi-pr-view-merged.toon")" = merged ] \
    || fail "real merged payload: state was not read as merged"
  [ "$(fm_toon_bool pull_request.draft < "$FIXTURES/gh-axi-pr-view-merged.toon")" = false ] \
    || fail "real merged payload: draft was not read as false"
  [ "$(fm_toon_get pull_request.state < "$FIXTURES/gh-axi-pr-view-open.toon")" = open ] \
    || fail "real open payload: state was not read as open"

  # A quoted scalar containing a colon must decode to its exact contents.
  [ "$(fm_toon_get pull_request.title < "$FIXTURES/gh-axi-pr-view-merged.toon")" \
    = "fix(teardown): prevent descriptor exhaustion during Treehouse return" ] \
    || fail "real payload: quoted title did not decode exactly"

  # Tabular rows, including an unquoted field containing spaces and a quoted
  # field containing a colon.
  [ "$(fm_toon_get 'checks[0].name' < "$FIXTURES/gh-axi-pr-checks.toon")" = "Lint shell scripts" ] \
    || fail "real checks payload: first row name was not read"
  [ "$(fm_toon_get 'checks[4].conclusion' < "$FIXTURES/gh-axi-pr-checks.toon")" = pass ] \
    || fail "real checks payload: last row conclusion was not read"
  [ "$(fm_toon_get 'pull_requests[1].title' < "$FIXTURES/gh-axi-pr-list.toon")" \
    = "Make Lavish captain boards permanent and durable" ] \
    || fail "real list payload: unquoted row field with spaces was not read"

  # A list item that legitimately contains double quotes must survive verbatim.
  case "$(fm_toon_get 'help[1]' < "$FIXTURES/gh-axi-pr-list.toon")" in
    *'--title "..."'*) ;;
    *) fail "real list payload: list item with embedded quotes was altered" ;;
  esac

  pass "fm-toon-lib parses every real captured gh-axi payload and reads by path"
}

# --- fault 1: declared counts are verified ----------------------------------

test_fault1_declared_counts_verified() {
  # An extra row must NOT be silently dropped by stopping at seen == expected.
  expect_refuse "fault1 tabular extra row" validate '' \
'checks[1]{name,conclusion}:
  a,pass
  b,fail' \
    'declares [1] but its block holds 2 rows'

  # The failing row is the one a truncating parser dropped. Prove the whole
  # document is rejected rather than the failure being lost.
  expect_refuse "fault1 dropped row was the failing one" get 'checks[0].conclusion' \
'checks[1]{name,conclusion}:
  a,pass
  b,fail' \
    'declares [1] but its block holds 2 rows'

  expect_refuse "fault1 tabular missing rows" validate '' \
'checks[3]{name,conclusion}:
  a,pass' \
    'declares [3] but its block holds 1 rows'

  expect_refuse "fault1 list extra item" validate '' \
'help[1]:
  one
  two' \
    'declares [1] but its block holds 2 items'

  expect_refuse "fault1 inline list count mismatch" validate '' \
'items[4]:
  a,b,c' \
    'declares [4] but its block holds 3 items'

  # The inline list form gh-axi really emits must still be accepted when the
  # count agrees, so strictness has not simply banned a real shape.
  expect_value "fault1 inline list accepted when count agrees" get 'items[2]' \
'items[3]:
  a,b,c' \
    c

  pass "fm-toon-lib verifies declared array counts and names both numbers"
}

# --- fault 2: expanded-array items counted by structure, not by key name ----

test_fault2_expanded_items_counted_structurally() {
  # Counting keyed on `- __typename:` missed an item whose first key differed.
  # Here NO item uses __typename at all and both must still be counted.
  expect_refuse "fault2 item whose first key is not __typename" validate '' \
'nodes[1]:
  - name: a
  - name: b' \
    'declares [1] but its block holds 2 items'

  # An undeclared trailing item must not be absorbed into the previous node.
  expect_refuse "fault2 undeclared trailing item" validate '' \
'nodes[2]:
  - __typename: CheckRun
    name: a
  - __typename: CheckRun
    name: b
  - __typename: CheckRun
    name: c' \
    'declares [2] but its block holds 3 items'

  # A field line sitting at item-marker depth with no marker is precisely the
  # line that used to get mixed into the previous node.
  expect_refuse "fault2 field line at item depth without a marker" validate '' \
'nodes[2]:
  - __typename: CheckRun
    name: a
  conclusion: failure' \
    'must start a new item with a dash and a space'

  # Fields of distinct items must stay in distinct records.
  expect_value "fault2 second item keeps its own fields" get 'nodes[1].name' \
'nodes[2]:
  - __typename: CheckRun
    name: a
  - __typename: CheckRun
    name: b' \
    b

  pass "fm-toon-lib counts expanded-array items by the dash marker, not a key name"
}

# --- fault 3: unknown is never permissive -----------------------------------

test_fault3_unknown_is_never_permissive() {
  # The original fault: everything except `true` was treated as terminal, so an
  # absent or malformed flag ended a decision as though it read an affirmative
  # negative. Absence must refuse, never resolve to false.
  expect_refuse "fault3 absent flag does not mean false" bool page.hasNextPage \
'page:
  endCursor: abc' \
    'no value at path page.hasNextPage'

  expect_refuse "fault3 malformed flag does not mean false" bool page.hasNextPage \
'page:
  hasNextPage: tru' \
    'is not a boolean'

  expect_refuse "fault3 empty flag does not mean false" bool page.hasNextPage \
'page:
  hasNextPage: ""' \
    'is not a boolean'

  # Only an affirmative literal produces a decision, in either direction.
  expect_value "fault3 affirmative false" bool page.hasNextPage \
'page:
  hasNextPage: false' \
    false
  expect_value "fault3 affirmative true" bool page.hasNextPage \
'page:
  hasNextPage: true' \
    true

  # A later page holding the required failure must be reachable: proving the
  # flag on page one is an affirmative true is what keeps the walk going.
  expect_value "fault3 continue decision is affirmative" bool page.hasNextPage \
'page:
  hasNextPage: true
  endCursor: "Y3Vyc29yOjE="' \
    true

  pass "fm-toon-lib refuses unknown flags instead of reading them as terminal"
}

# --- fault 4: no coercion whatsoever ----------------------------------------

test_fault4_no_coercion() {
  local variant
  # Booleans are a closed whitelist of exact literal forms. No lowercasing, no
  # case variants, no numeric or quoted spellings.
  for variant in TRUE True tRue YES Yes FALSE False NO No 1 0 '"yes"' '"true"' 'y' 'n'; do
    expect_refuse "fault4 boolean variant [$variant]" bool pull_request.draft \
"pull_request:
  draft: $variant" \
      'is not a boolean'
  done

  # Quotes are never repaired. An unmatched leading quote is an error, not a
  # value with the quote stripped off.
  expect_refuse "fault4 unmatched leading quote" get pull_request.state \
'pull_request:
  state: "merged' \
    'malformed scalar'

  expect_refuse "fault4 quote-only value" get pull_request.state \
'pull_request:
  state: "' \
    'malformed scalar'

  expect_refuse "fault4 unescaped inner quote" get pull_request.state \
'pull_request:
  state: "mer"ged"' \
    'malformed scalar'

  expect_refuse "fault4 invalid escape" get pull_request.title \
'pull_request:
  title: "bad \q escape"' \
    'malformed scalar'

  # An unmatched TRAILING quote is not stripped either. The value keeps the
  # stray character verbatim so it can never equal the literal it is compared
  # against; independent stripping is what used to turn it into a match.
  expect_value "fault4 trailing quote is not stripped" get pull_request.state \
'pull_request:
  state: merged"' \
    'merged"'

  # Whitespace is never trimmed into validity.
  expect_refuse "fault4 value with leading whitespace" get pull_request.state \
'pull_request:
  state:  merged' \
    'leading whitespace'

  expect_value "fault4 trailing whitespace is kept verbatim" get pull_request.state \
'pull_request:
  state: merged ' \
    'merged '

  pass "fm-toon-lib never coerces a malformed value into a valid-looking one"
}

# --- fault 5: a key means what its POSITION says ----------------------------

test_fault5_lookup_is_positional() {
  # The live fault: a matching key at ANY indentation satisfied a top-level
  # lookup. Here `state: merged` exists in the document but NOT at the path
  # being asked for, and the lookup must fail rather than borrow it.
  expect_refuse "fault5 nested key does not satisfy a top-level lookup" get pull_request.state \
'pull_request:
  number: 1
review:
  state: merged' \
    'no value at path pull_request.state'

  # ... while the key at its real path still resolves.
  expect_value "fault5 correct path still resolves" get review.state \
'pull_request:
  number: 1
review:
  state: merged' \
    merged

  expect_refuse "fault5 key under an unrelated child parent" bool pull_request.draft \
'pull_request:
  number: 1
  labels:
    draft: yes' \
    'no value at path pull_request.draft'

  # A deeper key of the same name must not shadow or be shadowed.
  expect_value "fault5 same key at two depths stays distinct" get pull_request.labels.state \
'pull_request:
  state: open
  labels:
    state: merged' \
    merged
  expect_value "fault5 outer key of the same name is unaffected" get pull_request.state \
'pull_request:
  state: open
  labels:
    state: merged' \
    open

  # A duplicate at the SAME path is ambiguous, so it refuses rather than
  # silently taking the first match the way `head -1` did.
  expect_refuse "fault5 duplicate path refuses rather than taking the first" get pull_request.state \
'pull_request:
  state: merged
  state: open' \
    'duplicate path'

  pass "fm-toon-lib resolves keys by structural path, not by first textual match"
}

# --- fault 6: the dedent-triggering line is not swallowed -------------------

test_fault6_dedent_line_is_not_lost() {
  # The record that ENDS one block must begin the next, not vanish with it.
  expect_value "fault6 line after an expanded array" get next_key \
'outer[1]:
  - a: 1
next_key: value' \
    value

  expect_value "fault6 line after a tabular array" get next_key \
'checks[1]{name,conclusion}:
  a,pass
next_key: value' \
    value

  expect_value "fault6 line after a list array" get next_key \
'help[1]:
  one
next_key: value' \
    value

  expect_value "fault6 line after a nested object" get top \
'pull_request:
  inner:
    deep: 1
top: value' \
    value

  # The triggering line must still be VALIDATED, not merely retained: a broken
  # line that happens to end a block is caught rather than dropped with it.
  expect_refuse "fault6 unclassifiable line that ends a block" validate '' \
'help[1]:
  one
garbage' \
    'not classifiable'

  # And closing the block still verifies its count, so a dedent cannot be used
  # to escape an unsatisfied declaration.
  expect_refuse "fault6 dedent does not escape count verification" validate '' \
'help[3]:
  one
next_key: value' \
    'declares [3] but its block holds 1 items'

  pass "fm-toon-lib re-classifies the dedent-triggering line instead of discarding it"
}

# --- fault 7: every line is positively classified ---------------------------

test_fault7_every_line_classified() {
  expect_refuse "fault7 bare word" validate '' \
'pull_request:
  number: 1
garbage line here' \
    'line 3 is not classifiable'

  expect_refuse "fault7 gh-axi help block shape is not a payload" validate '' \
'flags{list}:
  --state <open|closed|all>' \
    'not classifiable'

  expect_refuse "fault7 blank line" validate '' \
'pull_request:

  number: 1' \
    'is blank'

  expect_refuse "fault7 tab indentation" validate '' \
"pull_request:
$(printf '\t')number: 1" \
    'indents with a tab'

  expect_refuse "fault7 odd indent" validate '' \
'pull_request:
   number: 1' \
    'odd indent'

  expect_refuse "fault7 over-indented child" validate '' \
'pull_request:
    number: 1' \
    'requires 2'

  # A stderr line that is not TOON at all is refused outright.
  expect_refuse "fault7 non-TOON stderr line" validate '' \
'Traceback (most recent call last):
pull_request:
  number: 1' \
    'not classifiable'

  # A stderr line that happens to LOOK like TOON (`warning: ...`) is a valid
  # scalar, so validation accepts it - but it cannot corrupt a lookup, because
  # lookups are path-anchored, and it does make the root-block accessor refuse.
  expect_value "fault7 lookalike warning cannot corrupt a path lookup" get pull_request.number \
'warning: rate limit approaching
pull_request:
  number: 1' \
    1
  expect_refuse "fault7 lookalike warning is caught by the root accessor" rootkey '' \
'warning: rate limit approaching
pull_request:
  number: 1' \
    'expected exactly one top-level block but found 2'

  # An injected SECOND copy of a real block is ambiguity about the value we
  # asked for, and that always refuses.
  expect_refuse "fault7 injected duplicate block" get pull_request.state \
'pull_request:
  state: merged
pull_request:
  state: open' \
    'duplicate path'

  expect_refuse "fault7 row with the wrong field count" validate '' \
'checks[1]{name,conclusion}:
  a,pass,extra' \
    'has 3 values but the header declares 2 fields'

  expect_refuse "fault7 unterminated quote in a row" validate '' \
'checks[1]{name,conclusion}:
  "a,pass' \
    'unreadable row'

  pass "fm-toon-lib refuses any line it cannot positively classify"
}

# --- fault 8: empty values and cross-field values ---------------------------

test_fault8_empty_and_cross_field_values() {
  expect_refuse "fault8 empty value" validate '' \
'pull_request:
  state: ' \
    'has an empty value'

  expect_refuse "fault8 no space after the colon" validate '' \
'pull_request:
  state:merged' \
    'must be followed by a colon and one space'

  # A value that is perfectly valid for a DIFFERENT field must not satisfy this
  # one. `merged` is a real state, and it is not a boolean.
  expect_refuse "fault8 state value read as a boolean" bool pull_request.draft \
'pull_request:
  draft: merged' \
    'is not a boolean'

  # An array is not a scalar, and asking for one as a scalar refuses rather
  # than returning something incidental.
  expect_refuse "fault8 array asked for as a scalar" get reviews \
'reviews: []' \
    'is an array, not a scalar'

  expect_refuse "fault8 object asked for as a scalar" get pull_request \
'pull_request:
  number: 1' \
    'no value at path pull_request'

  pass "fm-toon-lib refuses empty values and values belonging to another field"
}

# --- root-key accessor used by the merge-result label -----------------------

test_root_key_is_structural() {
  expect_value "root key of a merge result" rootkey '' \
'merge:
  number: 42
  status: enqueued' \
    merge

  expect_refuse "root key refuses an ambiguous document" rootkey '' \
'a: 1
b: 2' \
    'expected exactly one top-level block but found 2'

  pass "fm-toon-lib names the single root block and refuses an ambiguous one"
}

test_real_payloads_parse
test_fault1_declared_counts_verified
test_fault2_expanded_items_counted_structurally
test_fault3_unknown_is_never_permissive
test_fault4_no_coercion
test_fault5_lookup_is_positional
test_fault6_dedent_line_is_not_lost
test_fault7_every_line_classified
test_fault8_empty_and_cross_field_values
test_root_key_is_structural
