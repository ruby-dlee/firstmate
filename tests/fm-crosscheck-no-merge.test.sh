#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_tmproot_into TMP_ROOT fm-crosscheck-no-merge

python3 - "$ROOT/bin/fm-crosscheck.py" "$ROOT/bin/fm-github-pr.py" <<'PY' \
  || fail "Crosscheck still exposes a merge mutation definition"
import ast
from pathlib import Path
import sys

tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
names = {node.name for node in tree.body if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}
assert "merge_crosschecked" not in names
assert "load_github_adapter" not in names
adapter_text = Path(sys.argv[2]).read_text(encoding="utf-8")
adapter_tree = ast.parse(adapter_text)
adapter_names = {
    node.name for node in adapter_tree.body
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
}
assert "merge_exact" not in adapter_names
assert "/merge" not in adapter_text
PY

set +e
"$ROOT/bin/fm-crosscheck.sh" merge lane https://github.com/ruby-dlee/firstmate/pull/1 \
  0123456789012345678901234567890123456789 squash >"$TMP_ROOT/shell.out" 2>"$TMP_ROOT/shell.err"
shell_rc=$?
set -e
expect_code 2 "$shell_rc" "removed Crosscheck shell merge command"
assert_grep 'supports only run and verify' "$TMP_ROOT/shell.err" \
  "Crosscheck shell did not refuse at its command boundary"

set +e
python3 "$ROOT/bin/fm-crosscheck.py" merge lane https://github.com/ruby-dlee/firstmate/pull/1 \
  0123456789012345678901234567890123456789 squash >"$TMP_ROOT/merge.out" 2>"$TMP_ROOT/merge.err"
rc=$?
set -e
expect_code 2 "$rc" "removed Crosscheck merge command"
assert_grep 'invalid choice' "$TMP_ROOT/merge.err" "removed merge command did not fail at parser boundary"
pass "Crosscheck exposes only read-only run and verify routes"
