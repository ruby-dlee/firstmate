#!/usr/bin/env bash
set -eu

default_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
test_dir=${1:-$default_test_dir}
allowlist=${2:-$default_test_dir/bash-env-allowlist.txt}
seen=

for test_script in "$test_dir"/*.test.sh; do
  relative=tests/${test_script##*/}
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    record=$(printf '%s\t%s' "$relative" "$line")
    grep -Fqx "$record" "$allowlist" || {
      printf 'unaudited BASH_ENV mutation: %s\n' "$record" >&2
      exit 97
    }
    seen="$seen
$record"
  done <<EOF
$(grep -E 'BASH_ENV=|(^|[[:space:](;])(export|declare|typeset|readonly|unset)([[:space:]]+-[^[:space:]]+)*[[:space:]]+BASH_ENV([[:space:]=;]|$)|(^|[[:space:](;])-u[[:space:]]*BASH_ENV([[:space:];]|$)|--unset(=|[[:space:]])BASH_ENV' "$test_script" || true)
EOF
done

while IFS= read -r allowed; do
  [ -n "$allowed" ] || continue
  printf '%s\n' "$seen" | grep -Fqx "$allowed" || {
    printf 'stale BASH_ENV allowlist entry: %s\n' "$allowed" >&2
    exit 97
  }
done < "$allowlist"
