#!/usr/bin/env bash
# Render one durable Lavish decision, assert its download-based answering
# machinery before it can be surfaced, open the self-contained file through the
# operating system's default browser, and exit without owning a browser session.
#
# Usage:
#   fm-lavish-board.sh <decision-id> [--home <path>]
#
# FM_LAVISH_OPEN_COMMAND may name an absolute executable for tests or hosts that
# do not provide macOS `open` or `xdg-open`. The executable receives the board's
# absolute HTML path as its only argument and must return after handing the file
# to the user's browser.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LAVISH_BIN=${FM_LAVISH_BIN:-$REPO_ROOT/tools/lavish/src/cli.mjs}

usage() {
  cat <<'USAGE'
Usage: fm-lavish-board.sh <decision-id> [--home <path>]

Render a self-contained Lavish board, verify that its declared mode has the
required inputs and schema-version-2 answer download, open the file through the
operating system's default browser, and exit. The helper creates no dedicated
browser profile, automation session, submission check, watcher, or listener.

After saving the complete answer batch, tell firstmate it is ready. The next
bounded Lavish intake validates the downloaded payload against the immutable
request and ordered question or item set before committing it.
USAGE
}

fail() {
  printf 'fm-lavish-board: %s\n' "$*" >&2
  exit 2
}

validate_id() {
  local value=$1
  [[ "$value" =~ ^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$ ]] \
    || fail 'decision id must be a lowercase slug of at most 64 characters'
}

resolve_home() {
  local requested=$1
  [ -d "$requested" ] && [ ! -L "$requested" ] \
    || fail "unsafe or missing home: $requested"
  (cd "$requested" && pwd -P)
}

resolve_open_command() {
  local requested=${FM_LAVISH_OPEN_COMMAND:-} resolved
  if [ -n "$requested" ]; then
    case "$requested" in
      /*) ;;
      *) fail 'FM_LAVISH_OPEN_COMMAND must be an absolute executable path' ;;
    esac
    [ -f "$requested" ] && [ ! -L "$requested" ] && [ -x "$requested" ] \
      || fail "unsafe or missing browser opener: $requested"
    printf '%s\n' "$requested"
    return
  fi
  if [ -x /usr/bin/open ]; then
    printf '%s\n' /usr/bin/open
    return
  fi
  resolved=$(command -v xdg-open 2>/dev/null || true)
  [ -n "$resolved" ] && [ -x "$resolved" ] \
    || fail 'no default browser opener found (expected /usr/bin/open or xdg-open)'
  printf '%s\n' "$resolved"
}

assert_answerable_board() {
  local board_path=$1
  node - "$board_path" <<'NODE'
const fs = require('node:fs');

let html;
try {
  html = fs.readFileSync(process.argv[2], 'utf8');
} catch (error) {
  process.stderr.write(`could not read generated HTML: ${error.message}\n`);
  process.exit(1);
}

const tags = (name) => html.match(new RegExp(`<${name}\\b[^>]*>`, 'gis')) ?? [];
const hasAttribute = (tag, name, value = undefined) => {
  const match = tag.match(new RegExp(`\\b${name}\\s*=\\s*(["'])(.*?)\\1`, 'is'));
  if (match === null) return value === undefined && new RegExp(`\\b${name}(?:\\s|>|$)`, 'i').test(tag);
  return value === undefined || match[2].toLowerCase() === value.toLowerCase();
};
const hasClass = (tag, className) => {
  const match = tag.match(/\bclass\s*=\s*(["'])(.*?)\1/is);
  return match !== null && match[2].split(/\s+/).includes(className);
};

const radios = tags('input').filter((tag) => hasAttribute(tag, 'type', 'radio'));
const optionNotes = tags('textarea').filter((tag) => hasAttribute(tag, 'data-option-comment'));
const questionNotes = tags('textarea').filter((tag) => hasAttribute(tag, 'data-question-note'));
const itemNotes = tags('textarea').filter((tag) => hasAttribute(tag, 'data-item-note'));
const cards = tags('section').filter((tag) => hasClass(tag, 'question'));
const submit = tags('button').some((tag) => hasAttribute(tag, 'id', 'submit-button'));
const overallNote = tags('textarea').some((tag) => hasAttribute(tag, 'id', 'overall-note'));
const payloadBackup = tags('textarea').some((tag) => hasAttribute(tag, 'id', 'submitted-payload'));
const annotation = tags('body').some((tag) => hasAttribute(tag, 'data-lavish-mode', 'annotation'));
const missing = [];

if (annotation) {
  if (itemNotes.length === 0) missing.push('per-item annotation inputs');
  if (cards.length === 0 || itemNotes.length !== cards.length) {
    missing.push(`one per-item annotation for each item (${itemNotes.length}/${cards.length})`);
  }
  if (radios.length > 0) missing.push('an annotation board must offer no choices');
} else {
  if (radios.length === 0) missing.push('radio choices');
  if (optionNotes.length === 0) missing.push('per-option annotation inputs');
  if (radios.length !== optionNotes.length) {
    missing.push(`one per-option annotation for each radio (${optionNotes.length}/${radios.length})`);
  }
  if (questionNotes.length === 0) missing.push('per-question annotation inputs');
  if (cards.length === 0 || questionNotes.length !== cards.length) {
    missing.push(`one per-question annotation for each question (${questionNotes.length}/${cards.length})`);
  }
}
if (!overallNote) missing.push('overall note input');
if (!submit) missing.push('save button');
if (!payloadBackup) missing.push('manual payload backup');
if (!/\bschema_version\s*:\s*2\b/.test(html)) missing.push('schema_version 2 payload');
if (!/querySelector\(\s*['"]#submit-button['"]\s*\)\.addEventListener\(\s*['"]click['"]/.test(html)) {
  missing.push('save click handler');
}
if (!/JSON\.stringify\(\s*payload\b/.test(html)) missing.push('JSON payload serialization');
if (!/new Blob\(\s*\[\s*payloadJson\s*\]/.test(html)) missing.push('JSON download');
if (!/anchor\.download\s*=\s*downloadFilename\b/.test(html)) missing.push('download filename');
if (!/anchor\.click\(\s*\)/.test(html)) missing.push('download activation');
if (!/submittedPayload\.value\s*=\s*payloadJson\b/.test(html)) missing.push('manual payload publication');

if (missing.length > 0) {
  process.stderr.write(`missing ${missing.join(', ')}\n`);
  process.exit(1);
}
NODE
}

if [ "${1:-}" = --help ]; then
  usage
  exit 0
fi
[ "$#" -gt 0 ] || { usage >&2; exit 2; }
DECISION_ID=$1
shift
validate_id "$DECISION_ID"

HOME_ARG=${FM_HOME:-$REPO_ROOT}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home)
      [ "$#" -gt 1 ] || fail '--home requires a path'
      HOME_ARG=$2
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

HOME_PATH=$(resolve_home "$HOME_ARG")
STATE_ARG=${FM_STATE_OVERRIDE:-$HOME_PATH/state}
mkdir -p "$STATE_ARG"
[ -d "$STATE_ARG" ] && [ ! -L "$STATE_ARG" ] \
  || fail "unsafe state directory: $STATE_ARG"
STATE_DIR=$(cd "$STATE_ARG" && pwd -P)

[ -x "$LAVISH_BIN" ] || fail "Lavish fork CLI is not executable: $LAVISH_BIN"
command -v node >/dev/null 2>&1 || fail 'node is not installed'
OPEN_COMMAND=$(resolve_open_command)

umask 077
HTML_PATH="$STATE_DIR/lavish-board-$DECISION_ID.html"
"$LAVISH_BIN" board "$DECISION_ID" --home "$HOME_PATH" --out "$HTML_PATH"
ANSWERABILITY_ERROR=
if ! ANSWERABILITY_ERROR=$(assert_answerable_board "$HTML_PATH" 2>&1); then
  rm -f "$HTML_PATH"
  fail "refusing to surface an unanswerable board: $ANSWERABILITY_ERROR"
fi

if ! "$OPEN_COMMAND" "$HTML_PATH"; then
  fail 'could not open the board in the default browser'
fi

printf 'Opened Lavish board %s in the default browser.\n' "$DECISION_ID"
printf 'After saving the answer, tell firstmate it is ready; bounded intake will validate the downloaded file.\n'
