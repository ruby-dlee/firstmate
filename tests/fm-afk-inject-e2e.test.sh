#!/usr/bin/env bash
# Private-socket end-to-end proof that away-mode text cannot fall back to split
# pane input while no backend has an atomic agent-session-bound steering route.
set -u

export FM_GATE_REFUSE_BYPASS=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEND="$ROOT/bin/fm-send.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="afk-e2e-$$"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-e2e.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
TARGET=supervisor:0.0

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

mkdir -p "$FAKEBIN" "$HOME_DIR/state"
cat > "$FAKEBIN/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$FAKEBIN/tmux"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s supervisor -x 120 -y 30
sleep 0.5
before=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" -S -20)
err="$TMP_ROOT/send.err"
if PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" \
  "$SEND" "$TARGET" $'\x1faway-mode escalation digest' >/dev/null 2>"$err"; then
  fail "away-mode text unexpectedly cleared atomic backend admission"
fi
after=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" -S -20)
[ "$before" = "$after" ] || fail "atomic refusal changed the supervisor pane"
case "$(cat "$err")" in
  *"atomic tmux steering verdict=send-failed"*) ;;
  *) fail "atomic refusal omitted its backend verdict" ;;
esac
pass "away-mode text refusal leaves a real private tmux pane byte-stable"
