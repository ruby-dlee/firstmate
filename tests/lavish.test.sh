#!/bin/sh
# Durable Lavish protocol, failure recovery, migration, and no-resident-resource
# behavior.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

npm ci --ignore-scripts --prefix "$ROOT/tools/lavish"
exec npm run check --prefix "$ROOT/tools/lavish"
