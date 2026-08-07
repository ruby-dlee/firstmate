#!/usr/bin/env bash
# Resolve the interpreter the crosscheck gate is allowed to run under.
#
# This is a safety floor, not a style preference. The bounded-read layer in
# bin/fm_bounded_io.py rejects hostile integers by relying on CPython's
# integer/string conversion limit, which first exists in 3.11. On an older
# interpreter that rejection silently stops happening while every banner the
# gate prints still reads exactly the same, so the gate must refuse rather
# than review under a weaker guarantee.
#
# Stock macOS `python3` is 3.9, so an operator running the gate on their own
# machine needs a newer sibling selected for them; otherwise the gate either
# crashes obscurely or, worse, reviews without the defense it claims.
#
# Both bin/fm-crosscheck.sh and the behavior tests resolve through here so the
# floor has exactly one owner. bin/fm-crosscheck.py enforces the same minimum
# itself, so a direct `python3 fm-crosscheck.py` cannot bypass it.
#
# Usage:
#   . bin/fm-crosscheck-python-lib.sh
#   interpreter="$(fm_crosscheck_resolve_python)" || exit 1
#
# Overrides:
#   FM_CROSSCHECK_PYTHON      use this interpreter; the gate refuses to run if
#                             it is missing or below the floor rather than
#                             silently reviewing under a different one
#   FM_CROSSCHECK_MIN_PYTHON  minimum "<major>.<minor>" (default 3.11)

fm_crosscheck_python_meets_floor() {
  local candidate=$1 major=$2 minor=$3
  command -v "$candidate" >/dev/null 2>&1 || return 1
  "$candidate" -c 'import sys
sys.exit(0 if sys.version_info[:2] >= (int(sys.argv[1]), int(sys.argv[2])) else 1)' \
    "$major" "$minor" 2>/dev/null
}

fm_crosscheck_resolve_python() {
  local minimum major minor candidate
  minimum="${FM_CROSSCHECK_MIN_PYTHON:-3.11}"
  major="${minimum%%.*}"
  minor="${minimum#*.}"

  if [ -n "${FM_CROSSCHECK_PYTHON:-}" ]; then
    if fm_crosscheck_python_meets_floor "$FM_CROSSCHECK_PYTHON" "$major" "$minor"
    then
      printf '%s\n' "$FM_CROSSCHECK_PYTHON"
      return 0
    fi
    printf 'CROSSCHECK TOOL-FAILURE: %s\n' \
      "FM_CROSSCHECK_PYTHON='$FM_CROSSCHECK_PYTHON' is missing or below Python $minimum, and the gate refuses to review under a weaker hostile-JSON guarantee; point it at Python $minimum or newer, or unset it to let the gate resolve a supported interpreter" \
      >&2
    return 1
  fi

  for candidate in python3 python3.14 python3.13 python3.12 python3.11; do
    if fm_crosscheck_python_meets_floor "$candidate" "$major" "$minor"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  printf 'CROSSCHECK TOOL-FAILURE: %s\n' \
    "no Python >= $minimum is available, and the gate refuses to review under a weaker hostile-JSON guarantee; install Python $minimum or newer, or set FM_CROSSCHECK_PYTHON to one" \
    >&2
  return 1
}
