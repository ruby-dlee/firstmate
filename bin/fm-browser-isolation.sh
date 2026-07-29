#!/usr/bin/env bash
# Stable shell entrypoint for firstmate's task-scoped browser lifecycle.
# Usage: fm-browser-isolation.sh <prepare|run|reap|sweep|classify> ...
# The full lifecycle, process discrimination, and safety contract live in the
# adjacent fm-browser-isolation.mjs implementation and docs/browser-isolation.md.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "$SCRIPT_DIR/fm-browser-isolation.mjs" "$@"
