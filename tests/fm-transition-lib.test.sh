#!/usr/bin/env bash
# tests/fm-transition-lib.test.sh - unit tests for the shared, backend-neutral
# normalized-transition shape and the single-owner status->action policy table
# (bin/fm-transition-lib.sh). Pure functions, no backend required.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-transition-lib.sh
. "$ROOT/bin/fm-transition-lib.sh"

# --- record construction + accessors ----------------------------------------

REC=$(fm_transition_record "wG:pQ" "wG" "" "blocked" "claude" "task-a" "generation-a" "default:wG:pQ" "1:2:3:abcd")
[ "$(fm_transition_pane_id "$REC")" = "wG:pQ" ] || fail "pane_id accessor wrong: $REC"
[ "$(fm_transition_workspace_id "$REC")" = "wG" ] || fail "workspace_id accessor wrong: $REC"
[ "$(fm_transition_from_status "$REC")" = "" ] || fail "from_status should be empty: $REC"
[ "$(fm_transition_to_status "$REC")" = "blocked" ] || fail "to_status accessor wrong: $REC"
[ "$(fm_transition_agent "$REC")" = "claude" ] || fail "agent accessor wrong: $REC"
[ "$(fm_transition_task_id "$REC")" = "task-a" ] || fail "task accessor wrong: $REC"
[ "$(fm_transition_generation_id "$REC")" = "generation-a" ] || fail "generation accessor wrong: $REC"
[ "$(fm_transition_window "$REC")" = "default:wG:pQ" ] || fail "window accessor wrong: $REC"
[ "$(fm_transition_meta_identity "$REC")" = "1:2:3:abcd" ] || fail "metadata identity accessor wrong: $REC"
fm_transition_binding_complete "$REC" || fail "complete record binding was rejected"
pass "fm_transition_record builds a 9-field record and every accessor reads its field"

# The record is exactly TAB-separated (nine fields, eight tabs).
TABS=$(printf '%s' "$REC" | tr -cd '\t' | wc -c | tr -d '[:space:]')
[ "$TABS" = "8" ] || fail "record must have exactly 8 TAB separators, got $TABS"
pass "fm_transition_record uses a single TAB between each of the nine fields"

# A field containing a stray TAB/newline is scrubbed to spaces so the record
# never desyncs into more than nine fields.
DIRTY=$(fm_transition_record "wG:pQ" "wG" "" "blocked" $'multi\tline\nagent')
DIRTY_TABS=$(printf '%s' "$DIRTY" | tr -cd '\t' | wc -c | tr -d '[:space:]')
[ "$DIRTY_TABS" = "8" ] || fail "a field with a stray TAB must not add columns, got $DIRTY_TABS tabs"
[ "$(fm_transition_to_status "$DIRTY")" = "blocked" ] || fail "stray-field scrub desynced to_status: $DIRTY"
! fm_transition_binding_complete "$DIRTY" || fail "unbound record was treated as exact"
pass "fm_transition_record scrubs TAB/newline out of fields so the record stays exactly nine columns"

# Empty optional fields are allowed (herdr leaves workspace/agent empty on the
# reconcile path).
REC2=$(fm_transition_record "w1:p3" "" "" "working" "")
[ "$(fm_transition_pane_id "$REC2")" = "w1:p3" ] || fail "pane_id wrong with empty optionals: $REC2"
[ "$(fm_transition_to_status "$REC2")" = "working" ] || fail "to_status wrong with empty optionals: $REC2"
pass "fm_transition_record tolerates empty workspace/from/agent fields"

BOUND=$(fm_transition_bind "$REC2" task-b generation-b default:w1:p3 4:5:6:efgh)
fm_transition_binding_complete "$BOUND" || fail "fm_transition_bind did not create complete custody"
[ "$(fm_transition_task_id "$BOUND")" = task-b ] || fail "fm_transition_bind lost task custody"
[ "$(fm_transition_to_status "$BOUND")" = working ] || fail "fm_transition_bind changed transition semantics"
pass "fm_transition_bind adds custody without changing provider fields"

# --- the single-owner policy table ------------------------------------------

[ "$(fm_transition_policy blocked)" = "actionable" ] || fail "blocked must be actionable"
[ "$(fm_transition_policy working)" = "absorb" ] || fail "working must be absorb"
[ "$(fm_transition_policy idle)" = "defer" ] || fail "idle must be defer"
[ "$(fm_transition_policy "done")" = "defer" ] || fail "done must be defer"
[ "$(fm_transition_policy unknown)" = "fallback" ] || fail "unknown must be fallback"
[ "$(fm_transition_policy "")" = "fallback" ] || fail "empty status must be fallback"
[ "$(fm_transition_policy some-future-status)" = "fallback" ] || fail "an unrecognized status must be fallback"
pass "fm_transition_policy is the single-owner status->action table (blocked=actionable, working=absorb, idle/done=defer, else=fallback)"

echo "# fm-transition-lib.test.sh: all assertions passed"
