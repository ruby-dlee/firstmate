#!/usr/bin/env bash
# Behavioral probe that no Herdr composer state can reach split text-plus-Enter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
STUB="$ROOT/tests/fixtures/herdr-permission-tui.py"
TMP_ROOT=$(mktemp -d "$ROOT/.fm-send-permission-modal.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
STATE_FILE="$TMP_ROOT/tui-state.json"
SESSION=permission-stub
TARGET="$SESSION:w1:p1"
MESSAGE='permission boundary probe'

cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

mkdir -p "$FAKEBIN" "$HOME_DIR/state" "$HOME_DIR/data"
cp "$STUB" "$FAKEBIN/herdr"
chmod 0500 "$FAKEBIN/herdr"

stub() {
  FM_PERMISSION_TUI_STATE="$STATE_FILE" FM_PERMISSION_TUI_SESSION="$SESSION" \
    python3 "$STUB" "$@"
}

for mode in composer modal pending unreadable malformed; do
  stub stub-init "$mode"
  if FM_PERMISSION_TUI_STATE="$STATE_FILE" FM_PERMISSION_TUI_SESSION="$SESSION" \
    FM_BACKEND_HERDR_TEST_LAB=firstmate-herdr-test-lab-v1 \
    FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" \
    "$SEND" "$TARGET" "$MESSAGE" >/dev/null 2>"$TMP_ROOT/$mode.err"; then
    fail "$mode Herdr surface admitted split steering"
  fi
  snapshot=$(stub stub-snapshot)
  jq -e '.approved == false and .turn_started == false and .events == []' \
    >/dev/null <<<"$snapshot" \
    || fail "$mode refusal delivered text or a key: $snapshot"
  assert_contains "$(cat "$TMP_ROOT/$mode.err")" \
    "atomic herdr steering verdict=send-failed" \
    "$mode refusal omitted the atomic steering predicate"
done

pass "Herdr split text-plus-Enter is unreachable for every composer and modal state"
