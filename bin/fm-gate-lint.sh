#!/usr/bin/env bash
# fm-gate-lint.sh - run the complete configured gate lint command.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
bin/fm-lint.sh
uv run --directory tools/agent-fleet --locked ruff check .
