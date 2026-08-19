#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Behavior: renewing a Pi credential before it expires, republishing it into the
# account home its consumers read, and refusing every way that can go wrong,
# without writing a token into the transcript or reaching the network on any
# path that must not.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-pi-refresh.py"
ADAPTER="$ROOT/bin/fm-pi-refresh.mjs"
# A marker standing in for token material, so a leak is caught by grep rather
# than by reading the output and hoping.
MARKER=fmtestpirefreshmarker

file_mode() {
  python3 -c 'import os,sys; print("%o" % (os.stat(sys.argv[1]).st_mode & 0o777))' "$1"
}

# Build a pool whose slots differ in exactly the axis under test: how long the
# access token has left, and whether it can be renewed at all.
make_pool() {
  python3 - "$1" "$MARKER" <<'PY'
import json
import sys
import time

path, marker = sys.argv[1], sys.argv[2]
now = time.time() * 1000
day = 86400 * 1000


def entry(account, days, *, refresh=True, kind="oauth"):
    value = {
        "type": kind,
        "access": f"{marker}.access.{account}",
        "refresh": f"{marker}.refresh.{account}" if refresh else "",
        "accountId": account,
        "expires": now + days * day,
    }
    return value


json.dump(
    {
        "openai-codex": entry("acct-one", 2),
        "openai-codex-2": entry("acct-two", 9),
        "openai-codex-3": entry("acct-three", 1, refresh=False),
    },
    open(path, "w"),
    indent=2,
)
PY
}

# A Pi install that is only a shape: enough for the resolver to accept it, with
# no runtime behind it. The CLI-level contracts must hold without a real Pi.
make_fake_pi() {
  local root=$1
  mkdir -p "$root/pkg/dist" "$root/bin"
  printf '{"name":"pi","version":"0.0.0","engines":{"node":">=22.19.0"}}\n' \
    >"$root/pkg/package.json"
  printf '#!/usr/bin/env node\n' >"$root/pkg/dist/cli.js"
  # Executable on purpose: a Pi entrypoint without the bit is not resolvable,
  # and the refusal under test would be that one rather than the intended one.
  chmod +x "$root/pkg/dist/cli.js"
  ln -sf "$root/pkg/dist/cli.js" "$root/bin/pi"
}

# A Node that answers the floor probe honestly and records that it was asked to
# run anything else. `--version` has to work, or the refusal under test would be
# the version refusal rather than the one being exercised.
make_fake_node() {
  local path=$1 version=$2 marker=$3 code=$4
  cat >"$path" <<SH
#!/bin/sh
if [ "\$1" = "--version" ]; then printf '%s\n' '$version'; exit 0; fi
: >'$marker'
exit $code
SH
  chmod +x "$path"
}

selection_contract() {
  local work pool out code
  work=$(fm_test_tmproot fm-pi-refresh-select)
  pool=$work/auth.json
  make_pool "$pool"

  out=$(python3 "$TOOL" report --source "$pool" --json 2>&1) \
    || fail "report refused a readable pool"
  assert_not_contains "$out" "$MARKER" "report leaked token material"

  python3 - "$out" <<'PY' || fail "report classified the pool wrongly"
import json
import sys

value = json.loads(sys.argv[1])
due = {record["slot"] for record in value["due"]}
held = {record["slot"]: record["reason"] for record in value["held"]}
assert due == {"openai-codex"}, due
assert "openai-codex-2" in held and "horizon" in held["openai-codex-2"], held
assert held.get("openai-codex-3", "").startswith("unrenewable"), held
# The account is reported, and only as a digest.
assert all(record["account"] != "acct-one" for record in value["due"]), value
PY

  # A slot outside the horizon becomes due when the horizon widens. Without
  # this the horizon could be ignored entirely and the split above would still
  # look right.
  out=$(python3 "$TOOL" report --source "$pool" --horizon-seconds 864000 --json 2>&1) \
    || fail "report refused a widened horizon"
  python3 - "$out" <<'PY' || fail "the renewal horizon does not select"
import json
import sys

value = json.loads(sys.argv[1])
assert {record["slot"] for record in value["due"]} == {"openai-codex", "openai-codex-2"}, value
PY

  # Reporting is a local read. It must not be able to reach a token endpoint,
  # so a Node that records being run proves the adapter was never invoked.
  local fakebin marker
  fakebin=$(fm_fakebin "$work")
  marker=$work/node-was-run
  make_fake_node "$fakebin/node" v99.0.0 "$marker" 1
  PATH="$fakebin:$PATH" FM_PI_NODE_BIN="$fakebin/node" \
    python3 "$TOOL" report --source "$pool" >/dev/null 2>&1 \
    || fail "report refused with a stubbed Node on PATH"
  assert_absent "$marker" "report invoked the renewal adapter"

  code=0
  out=$(python3 "$TOOL" run-once --source "$pool" 2>&1) || code=$?
  # 1, not 2: the sibling credential tools refuse through their own error class
  # rather than through argparse, so an operator gets one refusal contract.
  expect_code 1 "$code" "run-once accepted no slot selection"
  assert_contains "$out" "--slot" "the refusal did not name how to select a profile"

  pass "report names the due, the held, and the unrenewable without a token or a network call"
}

refusal_contract() {
  local work pool out code fakebin marker piroot
  work=$(fm_test_tmproot fm-pi-refresh-refuse)
  pool=$work/auth.json
  make_pool "$pool"
  piroot=$work/pi
  make_fake_pi "$piroot"
  fakebin=$(fm_fakebin "$work")
  marker=$work/adapter-was-run

  # An adapter that fails must not be reported as a renewal, and the pre-rotation
  # copy must already exist when it fails: the copy is the only thing standing
  # between an interrupted in-place write and every slot in the file.
  make_fake_node "$fakebin/node" v99.0.0 "$marker" 3
  code=0
  out=$(FM_PI_BIN="$piroot/bin/pi" FM_PI_NODE_BIN="$fakebin/node" \
    python3 "$TOOL" run-once --source "$pool" --slot openai-codex \
    --backup-root "$work/backups" --destination-root "$work/homes" 2>&1) || code=$?
  expect_code 1 "$code" "a failed adapter was reported as a renewal"
  assert_present "$marker" "run-once never invoked the adapter"
  assert_not_contains "$out" "$MARKER" "the refusal leaked token material"
  [ -n "$(find "$work/backups" -name 'auth.json.*' -type f 2>/dev/null)" ] \
    || fail "run-once rotated without first copying the pool"
  expect_code 600 \
    "$(file_mode "$(find "$work/backups" -name 'auth.json.*' -type f | head -1)")" \
    "the pre-rotation copy is not owner-only"

  # A Node below the floor the install declares does not merely warn: it dies
  # inside undici with an unrelated message. Refusing by version keeps that from
  # being reported as a provider failure.
  make_fake_node "$fakebin/oldnode" v20.20.2 "$work/oldnode-ran" 0
  code=0
  out=$(FM_PI_BIN="$piroot/bin/pi" FM_PI_NODE_BIN="$fakebin/oldnode" \
    python3 "$TOOL" run-once --source "$pool" --slot openai-codex \
    --backup-root "$work/backups" --destination-root "$work/homes" 2>&1) || code=$?
  expect_code 1 "$code" "a Node below the declared floor was accepted"
  assert_contains "$out" "22" "the refusal did not name the floor it applied"
  assert_absent "$work/oldnode-ran" "the refused Node was run anyway"

  # A run whose only selected profile cannot be renewed at all exits non-zero:
  # a scheduled run must not report success over an account that needs a login.
  code=0
  out=$(FM_PI_BIN="$piroot/bin/pi" FM_PI_NODE_BIN="$fakebin/node" \
    python3 "$TOOL" run-once --source "$pool" --slot openai-codex-3 \
    --backup-root "$work/backups" --destination-root "$work/homes" 2>&1) || code=$?
  expect_code 1 "$code" "an unrenewable profile was reported as a clean run"
  assert_contains "$out" "unrenewable" "the report did not name why it cannot be renewed"
  assert_absent "$work/adapter-was-run-unrenewable" "an unrenewable profile reached the adapter"

  code=0
  out=$(python3 "$TOOL" run-once --source "$pool" --slot no-such-slot \
    --backup-root "$work/backups" --destination-root "$work/homes" 2>&1) || code=$?
  expect_code 1 "$code" "a slot absent from the pool was accepted"
  assert_contains "$out" "no-such-slot" "the refusal did not name the missing slot"

  pass "run-once copies before it rotates, and refuses a failed adapter, an underpowered Node, an unrenewable profile, and an absent slot"
}

republish_contract() {
  local work pool out
  work=$(fm_test_tmproot fm-pi-refresh-republish)
  pool=$work/auth.json
  make_pool "$pool"
  mkdir -p "$work/homes/openai-codex"

  # The republish and verify halves drive the real projection tool and the real
  # expiry owner, not a restatement of either. Only a home that already exists
  # is republished, because the reviewer roster names homes by path and one
  # appearing on its own is a reviewer nobody added.
  python3 - "$TOOL" "$pool" "$work/homes" <<'PY' \
    || fail "the real projection and expiry owners rejected a republished home"
import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location("refresh", sys.argv[1])
refresh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(refresh)

pool = pathlib.Path(sys.argv[2])
homes = pathlib.Path(sys.argv[3])
present, absent = refresh.reproject(
    source=pool, destination_root=homes, slots=["openai-codex", "openai-codex-2"]
)
assert present == ["openai-codex"], present
assert absent == ["openai-codex-2"], absent
assert (homes / "openai-codex" / "auth.json").is_file()
assert not (homes / "openai-codex-2").exists(), "an unrequested account home was created"

verified = refresh.verify_homes(homes, present)
assert verified[0]["state"] == "usable", verified
PY

  # Verification is a gate, not a report: a republished home whose credential
  # dies inside the margin must refuse rather than be counted as renewed.
  python3 - "$TOOL" "$work/homes" <<'PY' \
    || fail "verification admitted a home that expires inside its margin"
import importlib.util
import json
import pathlib
import sys

spec = importlib.util.spec_from_file_location("refresh", sys.argv[1])
refresh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(refresh)

home = pathlib.Path(sys.argv[2]) / "openai-codex"
credential = home / "auth.json"
value = json.loads(credential.read_text())
value["openai-codex"]["expires"] = 1000.0
credential.write_text(json.dumps(value))
try:
    refresh.verify_homes(pathlib.Path(sys.argv[2]), ["openai-codex"])
except refresh.RefreshError as error:
    assert "openai-codex" in str(error), error
else:
    raise AssertionError("an expired republished home was accepted")
PY

  out=$(cat "$work/homes/openai-codex/auth.json")
  assert_contains "$out" "openai-codex" "the republished home lost its consumer key"

  pass "renewed profiles republish only into homes that exist, and a home that expires inside its margin refuses"
}

pool_integrity_contract() {
  local work pool
  work=$(fm_test_tmproot fm-pi-refresh-integrity)
  pool=$work/auth.json
  make_pool "$pool"

  python3 - "$TOOL" "$pool" <<'PY' || fail "pool damage was not detected"
import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location("refresh", sys.argv[1])
refresh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(refresh)

pool = pathlib.Path(sys.argv[2])
expected = {"openai-codex", "openai-codex-2", "openai-codex-3"}
assert refresh.pool_is_intact(pool, expected) == "", "an intact pool was called damaged"

pool.write_text('{"openai-codex": {}}')
assert "lost profiles" in refresh.pool_is_intact(pool, expected)

pool.write_text("not json at all")
assert "no longer reads as JSON" in refresh.pool_is_intact(pool, expected)
PY

  # Backups protect exactly one failure and are credential material at rest
  # otherwise, so the run prunes down to the retained count.
  python3 - "$TOOL" "$work" <<'PY' || fail "backups were not bounded"
import importlib.util
import pathlib
import stat
import sys

spec = importlib.util.spec_from_file_location("refresh", sys.argv[1])
refresh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(refresh)

work = pathlib.Path(sys.argv[2])
source = work / "seed.json"
source.write_text("{}")
root = work / "backups"
made = [
    refresh.backup_pool(source, root, now=1_700_000_000 + index * 60)
    for index in range(refresh.BACKUP_KEEP + 2)
]
assert all(path.is_file() for path in made), made
assert stat.S_IMODE(root.stat().st_mode) == 0o700, oct(root.stat().st_mode)
refresh.prune_backups(root, refresh.BACKUP_KEEP)
kept = sorted(path.name for path in root.glob("auth.json.*"))
assert len(kept) == refresh.BACKUP_KEEP, kept
assert kept == sorted(path.name for path in made)[-refresh.BACKUP_KEEP :], kept
PY

  pass "a damaged pool is named rather than reported as renewed, and the pre-rotation copies stay bounded and owner-only"
}

adapter_contract() {
  local work pool package
  work=$(fm_test_tmproot fm-pi-refresh-adapter)
  pool=$work/auth.json
  make_pool "$pool"

  package=${FM_PI_PACKAGE_DIR:-}
  if [ -z "$package" ]; then
    local located
    located=$(command -v pi 2>/dev/null || true)
    [ -n "$located" ] || { echo "skip: pi is not installed for the adapter contract"; return 0; }
    package=$(cd "$(dirname "$(readlink -f "$located")")/.." && pwd -P)
  fi
  [ -f "$package/dist/core/auth-storage.js" ] || {
    echo "skip: the installed Pi carries no credential store to contract against"
    return 0
  }
  command -v node >/dev/null 2>&1 || { echo "skip: node not found"; return 0; }

  # The rotation itself is the only thing stubbed. The credential store is Pi's
  # real one, so the lock, the read-modify-write, and the on-disk result are the
  # production mechanism rather than a description of it.
  node --input-type=module -e "
import { readFileSync } from 'node:fs';
const adapter = await import('file://$ADAPTER');
const { AuthStorage } = await import('file://$package/dist/core/auth-storage.js');

const rotating = {
  refresh: async (current) => ({
    type: 'oauth',
    access: 'rotated.' + current.accountId,
    refresh: 'rotated-refresh.' + current.accountId,
    expires: Date.now() + 864e5,
    accountId: current.accountId,
  }),
};
const identical = { refresh: async (current) => ({ ...current }) };
const drifting = {
  refresh: async (current) => ({ ...current, access: 'x', accountId: 'someone-else' }),
};
const failing = {
  refresh: async () => {
    throw new Error('token refresh response missing fields: {\"access_token\":\"$MARKER-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}');
  },
};

const run = (oauth, slots) => adapter.refreshSlots({
  storeFactory: (path) => AuthStorage.create(path),
  oauth, poolPath: '$pool', slots, timeoutMs: 5000,
});

const first = await run(rotating, ['openai-codex', 'no-such-slot']);
const rotated = first.find((record) => record.slot === 'openai-codex');
if (rotated.outcome !== 'refreshed') throw new Error('a rotation was not reported: ' + rotated.outcome);
if (!rotated.account_stable) throw new Error('a stable account was reported as changed');
if (JSON.stringify(first).includes('$MARKER')) throw new Error('the adapter emitted token material');
if (JSON.stringify(first).includes('acct-one')) throw new Error('the adapter emitted a raw account id');
if (first.find((record) => record.slot === 'no-such-slot').outcome !== 'absent') {
  throw new Error('an absent slot was not reported as absent');
}

const onDisk = JSON.parse(readFileSync('$pool', 'utf8'));
if (onDisk['openai-codex'].access !== 'rotated.acct-one') {
  throw new Error('the rotation did not land in the pool');
}
if (Object.keys(onDisk).length !== 3) throw new Error('the pool lost a slot');
if (onDisk['openai-codex-3'].accountId !== 'acct-three') throw new Error('an untouched slot changed');

// A store that writes back an identical credential is not a renewal, and must
// not be counted as one just because the call returned a credential.
const second = await run(identical, ['openai-codex']);
if (second[0].outcome !== 'unchanged') {
  throw new Error('an unrotated credential was counted as renewed: ' + second[0].outcome);
}

const third = await run(drifting, ['openai-codex-2']);
if (third[0].account_stable !== false) throw new Error('an account change was not reported');

const fourth = await run(failing, ['openai-codex-2']);
if (fourth[0].outcome !== 'failed') throw new Error('a throwing refresh was not reported as failed');
if (fourth[0].detail.includes('$MARKER')) throw new Error('a provider error leaked token material');
if (!fourth[0].detail.includes('[redacted]')) throw new Error('a token-shaped run was not redacted');
" || fail "the adapter contract against Pi's real credential store failed"

  pass "the adapter rotates through Pi's real credential store, distinguishes an unrotated credential, and redacts a provider error"
}

selection_contract
refusal_contract
republish_contract
pool_integrity_contract
adapter_contract
