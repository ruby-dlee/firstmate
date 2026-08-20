#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Hermetic coverage for the secondmate compartment evidence mode of
# bin/fm-worker-authority.py (R2/R3 PR 6, design B.7): the same
# fm.worker-release/v2 bundle with the same five receipt names, whose report,
# landing, and worktree receipts prove compartment closeout evidence when the
# ordinary task metadata records kind=secondmate - and whose bundle still
# passes the lifecycle's UNMODIFIED release_receipt and
# verify_release_against_worker, exercised here through the real release CLI.
#
# Durable-shape coupling, named: the terminal status file
# (state/<task>.cloud-secondmate-status: closed|idle|ttl-exhausted), the
# durable monitor state (state/<task>.cloud-secondmate-state.json with
# last_summary/landed_bundles/kept_bundles), and the collected mailbox
# (state/<task>.cloud-mailbox with <seq8>-<sha256>.json leg summaries,
# bundle-<seq8>-<sha256>.bundle files, and the sticky .chain-break marker)
# are the shapes bin/fm-secondmate-cloud-monitor.{sh,py} writes on branch
# fm/secondmate-cloud-monitor; these fixtures pin that contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AUTHORITY="$ROOT/bin/fm-worker-authority.py"
CONTROLLER="$ROOT/bin/fm-worker-lifecycle.py"
WRAPPER="$ROOT/bin/fm-worker-lifecycle.sh"
SUB=11111111-1111-4111-8111-111111111111

# One shared fixture builder: a primary home with the compartment evidence a
# closed-out secondmate leaves behind, plus the secondmate home worktree.
write_compartment_fixture() {  # <home> <task>
  python3 - "$1" "$2" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

home = Path(sys.argv[1])
task = sys.argv[2]
state = home / "state"
state.mkdir(parents=True, exist_ok=True)

bundle_body = b"fixture-compartment-bundle"
bundle_digest = hashlib.sha256(bundle_body).hexdigest()

(state / (task + ".cloud-secondmate-status")).write_text("closed\n")

mailbox = state / (task + ".cloud-mailbox")
mailbox.mkdir(exist_ok=True)
# A REAL collected chain: sequences 1..N with no gaps, each entry content
# addressed and chained onto the previous, exactly as the monitor collects
# them. delivered_sequence/verified_tip below must agree with what is here -
# the authority now refuses a mailbox holding fewer entries than the durable
# state claims, which is the rewound-outbox rule the monitor itself applies.
chain = "0" * 64
for sequence, body in enumerate((
    {"kind": "fm.secondmate-message/v1", "text": "checking in"},
    {
        "kind": "fm.secondmate-leg-summary/v1",
        "reason": "close",
        "legs_completed": 2,
        "bundles": [{
            "name": "session/out/bundle-00000001-{}.bundle".format(bundle_digest),
            "sha256": bundle_digest, "bytes": len(bundle_body), "commits": 1,
        }],
    },
), 1):
    message = dict(body, sequence=sequence)
    unsigned = json.dumps(message, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    content = hashlib.sha256(unsigned).hexdigest()
    chain = hashlib.sha256((chain + content).encode()).hexdigest()
    message["content_sha256"] = content
    message["chain_digest"] = chain
    (mailbox / "{:08d}-{}.json".format(sequence, content)).write_text(
        json.dumps(message, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
(mailbox / "bundle-00000001-{}.bundle".format(bundle_digest)).write_bytes(bundle_body)

# The durable state is written from the chain that was actually built, so the
# verified tip carries the REAL recomputed chain digest - the authority now
# re-derives the chain by content and requires it to reproduce this tip.
(state / (task + ".cloud-secondmate-state.json")).write_text(json.dumps({
    "delivered_sequence": 2,
    "landed_bundles": [bundle_digest],
    "kept_bundles": [],
    "last_summary": {"reason": "close", "legs_completed": 2},
    "verified_tip": {"sequence": 2, "chain_digest": chain},
}, sort_keys=True, separators=(",", ":")) + "\n")

report = home / "data" / task
report.mkdir(parents=True, exist_ok=True)
(report / "completion.md").write_text(
    "## Summary\nclosed\n## What changed\nx\n## Verification\nx\n"
    "## Visual evidence\nnone\n## Artifacts\nnone\n## Follow-ups\nnone\n")
print(bundle_digest)
PY
}

write_home_worktree() {  # <path>
  git init --quiet -b main "$1"
  git -C "$1" config user.name Test
  git -C "$1" config user.email test@example.invalid
  printf 'charter\n' >"$1/charter.md"
  git -C "$1" add charter.md
  git -C "$1" commit --quiet -m charter
}

secondmate_evidence_refusal_matrix() {
  local tmp
  fm_test_tmproot_into tmp fm-authority-secondmate-matrix
  mkdir -p "$tmp/home"
  write_home_worktree "$tmp/subhome"
  bundle_digest=$(write_compartment_fixture "$tmp/home" smc-1) || fail "compartment fixture build failed"
  python3 - "$AUTHORITY" "$tmp/home" "$tmp/subhome" "$bundle_digest" <<'PY' || fail "a secondmate evidence leg refusal is missing or indistinct"
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location("worker_authority", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
home = Path(sys.argv[2])
subhome = Path(sys.argv[3])
bundle_digest = sys.argv[4]
task = "smc-1"
state = home / "state"
status_path = state / (task + ".cloud-secondmate-status")
state_path = state / (task + ".cloud-secondmate-state.json")
mailbox = state / (task + ".cloud-mailbox")
values = {"worktree": [str(subhome)]}

def monitor_state():
    return json.loads(state_path.read_text())

def put_state(value):
    state_path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")

def expect(callable_, fragment):
    try:
        callable_()
    except module.AuthorityError as exc:
        assert fragment in str(exc), (fragment, str(exc))
    else:
        raise AssertionError("no refusal: {}".format(fragment))

HEAD = module.git(subhome, "rev-parse", "HEAD")

def landing(generation=None):
    return module.secondmate_landing_evidence(
        home, task, subhome, generation if generation is not None else HEAD)

# The good fixture proves all three compartment legs.
report = module.secondmate_report_evidence(home, task)
assert report.startswith(b"closed\0close\x002\0"), report[:40]
assert b"## Summary" in report
landing_bytes = landing()
assert bundle_digest.encode() in landing_bytes
worktree_info, worktree = module.secondmate_worktree_evidence(home, task, values)
assert worktree == subhome.resolve()

# The ack mapping binds every terminal reason the monitor writes.
saved = monitor_state()
for terminal, ack in (("idle", "idle"), ("ttl-exhausted", "wall")):
    status_path.write_text(terminal + "\n")
    value = monitor_state()
    value["last_summary"]["reason"] = ack
    put_state(value)
    assert module.secondmate_report_evidence(home, task).startswith(
        "{}\0{}\x002\0".format(terminal, ack).encode())
status_path.write_text("closed\n")
put_state(saved)

# report: missing terminal status.
status_path.unlink()
expect(lambda: module.secondmate_report_evidence(home, task),
       "lacks the terminal session status")
# report: unrecognized terminal value.
status_path.write_text("done\n")
expect(lambda: module.secondmate_report_evidence(home, task),
       "terminal status is unrecognized")
status_path.write_text("closed\n")
# report: the chained close ack must MATCH the terminal reason.
value = monitor_state()
value["last_summary"]["reason"] = "idle"
put_state(value)
expect(lambda: module.secondmate_report_evidence(home, task),
       "lacks the chained close ack")
put_state(saved)
# report: no durable monitor state at all.
state_path.rename(str(state_path) + ".away")
expect(lambda: module.secondmate_report_evidence(home, task),
       "no durable monitor state")
expect(lambda: landing(),
       "no durable monitor state")
Path(str(state_path) + ".away").rename(state_path)
# landing: a bundle the monitor kept instead of landing.
value = monitor_state()
value["kept_bundles"] = [bundle_digest]
put_state(value)
expect(lambda: landing(),
       "kept unlanded")
put_state(saved)
# landing: a DECLARED bundle absent from the landed record.
value = monitor_state()
value["landed_bundles"] = []
put_state(value)
expect(lambda: landing(),
       "unlanded outbox bundles")
# worktree: the same unlanded evidence blocks the quiesced-home receipt.
expect(lambda: module.secondmate_worktree_evidence(home, task, values),
       "not quiesced: unlanded outbox bundles remain")
put_state(saved)
# landing: a collected-but-undeclared bundle FILE must also be landed.
stray = mailbox / ("bundle-00000009-" + "a" * 64 + ".bundle")
stray.write_bytes(b"stray")
expect(lambda: landing(),
       "unlanded outbox bundles")
stray.unlink()
# landing: a recorded chain break freezes the receipt...
(mailbox / ".chain-break").write_text("{}")
expect(lambda: landing(),
       "frozen by a recorded outbox chain break")
(mailbox / ".chain-break").unlink()
# ... and a DANGLING SYMLINK named .chain-break is still a marker: exists()
# follows it into nothing, which bypassed the freeze a real marker triggers.
(mailbox / ".chain-break").symlink_to(mailbox / "no-such-target")
expect(lambda: landing(),
       "frozen by a recorded outbox chain break")
(mailbox / ".chain-break").unlink()

# landing: THE THREE PROVEN FORGERIES. Each one minted all five proved
# receipts and passed the real release CLI while a declared bundle was
# unlanded, because the checks trusted things inside the attacker's own write
# set - the mailbox filenames, and the durable state file that sits in the
# same state/ directory. Verification is now by CONTENT over the chain's own
# arithmetic, and malformed durable state refuses instead of zeroing.
kept_entries = {entry.name: entry.read_bytes() for entry in mailbox.iterdir()}

def wipe_mailbox():
    for entry in list(mailbox.iterdir()):
        entry.unlink()

def restore_mailbox():
    for entry in list(mailbox.iterdir()):
        entry.unlink()
    for name, body in kept_entries.items():
        (mailbox / name).write_bytes(body)

def honest():
    """A fresh copy of the state the honest monitor wrote, so one forgery
    never inherits the previous one's edits."""
    return json.loads(json.dumps(saved))

# F1: empty the mailbox, then zero the very fields the completeness check read,
# in the same JSON the attacker was already rewriting to set landed_bundles=[].
value = honest()
value["landed_bundles"] = []
value["delivered_sequence"] = 0
value.pop("verified_tip", None)
put_state(value)
wipe_mailbox()
expect(lambda: landing(), "records no verified delivered outbox sequence")

# F2, THE ISOLATING FORM: keep the honest mailbox EXACTLY as the monitor
# wrote it - same filenames, same content_sha256 and chain_digest fields, so
# the chain links and reproduces the durable tip perfectly - and rewrite only
# the leg summary's BODY to drop its `bundles` declaration. Every structural
# check still passes; the declared set silently empties and the unlanded
# bundle disappears from view. ONLY recomputing SHA-256 over the body catches
# this, which is what makes content verification load-bearing rather than
# merely one more gate.
value = honest()
value["landed_bundles"] = []
put_state(value)
restore_mailbox()
summary_name = None
for entry in sorted(mailbox.iterdir()):
    if entry.name.endswith(".json"):
        body = json.loads(entry.read_text())
        if body.get("kind") == "fm.secondmate-leg-summary/v1":
            summary_name = entry
            break
assert summary_name is not None, "fixture has no leg summary to rewrite"
tampered = json.loads(summary_name.read_text())
assert tampered["bundles"], "fixture leg summary declares no bundle"
tampered["bundles"] = []
summary_name.write_text(
    json.dumps(tampered, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
expect(lambda: landing(), "content differs from its content address")
put_state(saved)
restore_mailbox()

# F2 (the worst): leave delivered_sequence and verified_tip exactly as the
# honest monitor wrote them and replace the real entries with well-named junk.
# Cardinality and the name regex were the only gates, so contents were never
# read: declared came out empty and the unlanded bundle vanished from view.
value = honest()
value["landed_bundles"] = []
put_state(value)
wipe_mailbox()
for sequence in (1, 2):
    (mailbox / "{:08d}-{}.json".format(sequence, "b" * 64)).write_text('{"kind":"noise"}')
expect(lambda: landing(), "content differs from its content address")

# F3: the type guards failed OPEN - a string or negative sequence coerced to 0.
for forged in ("2", -1, 2.0, None, True):
    value = honest()
    value["landed_bundles"] = []
    value["delivered_sequence"] = forged
    put_state(value)
    wipe_mailbox()
    expect(lambda: landing(), "records no verified delivered outbox sequence")
# ... and the same fail-open in the verified tip itself.
for forged in ({"sequence": "2", "chain_digest": "a" * 64}, {"sequence": 2},
               {"sequence": 2, "chain_digest": "nothex"}, {}, "tip", None):
    value = honest()
    value["verified_tip"] = forged
    put_state(value)
    expect(lambda: landing(), "verified chain tip")
put_state(saved)
restore_mailbox()

# A wiped store re-minted as a fresh, internally consistent chain from genesis
# must not verify: the durable tip is what ties the chain to this compartment.
value = honest()
value["landed_bundles"] = []
put_state(value)
wipe_mailbox()
chain = "0" * 64
for sequence, body in enumerate((
    {"kind": "fm.secondmate-message/v1", "text": "fresh"},
    {"kind": "fm.secondmate-leg-summary/v1", "reason": "close", "legs_completed": 2, "bundles": []},
), 1):
    message = dict(body, sequence=sequence)
    unsigned = json.dumps(message, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    content = hashlib.sha256(unsigned).hexdigest()
    chain = hashlib.sha256((chain + content).encode()).hexdigest()
    message["content_sha256"] = content
    message["chain_digest"] = chain
    (mailbox / "{:08d}-{}.json".format(sequence, content)).write_text(
        json.dumps(message, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
expect(lambda: landing(), "does not reproduce the durable verified tip")
put_state(saved)
restore_mailbox()

# A truncated chain, a wiped mailbox, and a symlinked one all still refuse.
wipe_mailbox()
expect(lambda: landing(), "a rewound or truncated outbox")
mailbox.rmdir()
expect(lambda: landing(), "its mailbox is absent or redirected")
decoy = home / "state" / "decoy-mailbox"
decoy.mkdir()
mailbox.symlink_to(decoy)
expect(lambda: landing(), "its mailbox is absent or redirected")
mailbox.unlink()
mailbox.mkdir()
restore_mailbox()

# landing: the compartment head must descend from the assignment's exact
# starting repository generation, the same lineage tether the ordinary lane
# applies - local files alone are not a landing proof.
expect(lambda: landing("0" * 40),
       "does not descend from the assignment repository generation")

# landing: "provably none" is about BUNDLES, not about an empty chain. A
# VERIFIED chain whose leg summaries declare nothing, with nothing collected,
# proves - and that is the only shape that does.
value = honest()
value["landed_bundles"] = []
put_state(value)
wipe_mailbox()
chain = "0" * 64
for sequence, body in enumerate((
    {"kind": "fm.secondmate-message/v1", "text": "checking in"},
    {"kind": "fm.secondmate-leg-summary/v1", "reason": "close", "legs_completed": 2, "bundles": []},
), 1):
    message = dict(body, sequence=sequence)
    unsigned = json.dumps(message, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    content = hashlib.sha256(unsigned).hexdigest()
    chain = hashlib.sha256((chain + content).encode()).hexdigest()
    message["content_sha256"] = content
    message["chain_digest"] = chain
    (mailbox / "{:08d}-{}.json".format(sequence, content)).write_text(
        json.dumps(message, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
value = honest()
value["landed_bundles"] = []
value["verified_tip"] = {"sequence": 2, "chain_digest": chain}
put_state(value)
empty = landing()
assert b'"declared":[]' in empty and b'"landed":[]' in empty
put_state(saved)
restore_mailbox()

# worktree: tracked modifications are not a quiesced home.
(subhome / "charter.md").write_text("edited\n")
expect(lambda: module.secondmate_worktree_evidence(home, task, values),
       "not quiesced: uncommitted or untracked work remains")
import subprocess
subprocess.run(["git", "-C", str(subhome), "checkout", "--", "charter.md"], check=True)
module.secondmate_worktree_evidence(home, task, values)
# UNTRACKED never-added work is work left behind too: a release receipt
# answers "is anything left here", not the monitor's narrower "can I
# fast-forward into this", and the ordinary lane has always refused it.
(subhome / "new_feature.py").write_text("print('unsaved')\n")
expect(lambda: module.secondmate_worktree_evidence(home, task, values),
       "not quiesced: uncommitted or untracked work remains")
(subhome / "new_feature.py").unlink()
# A gitignored runtime path is still not "work left behind": --untracked-files=all
# never lists ignored paths, which is why the ordinary strictness is safe here.
(subhome / ".gitignore").write_text("runtime/\n")
subprocess.run(["git", "-C", str(subhome), "add", ".gitignore"], check=True)
subprocess.run(["git", "-C", str(subhome), "commit", "--quiet", "-m", "ignore runtime"], check=True)
(subhome / "runtime").mkdir()
(subhome / "runtime" / "monitor.log").write_text("noise\n")
module.secondmate_worktree_evidence(home, task, values)
PY
  pass "every secondmate evidence leg refuses distinctly and the ack mapping binds all three terminals"
}

secondmate_authority_bundle_end_to_end() {
  local tmp
  fm_test_tmproot_into tmp fm-authority-secondmate-e2e
  mkdir -p "$tmp/home" "$tmp/accounts/codex/1" "$tmp/shim"
  cat > "$tmp/shim/tmux" <<'SH'
#!/bin/sh
echo "no server running on /tmp/fm-secondmate-authority-test" >&2
exit 1
SH
  chmod +x "$tmp/shim/tmux"
  write_home_worktree "$tmp/subhome"
  write_compartment_fixture "$tmp/home" smc-1 >/dev/null || fail "compartment fixture build failed"
  cat > "$tmp/home/state/smc-1.meta" <<EOF
window=fmtest:1
worktree=$tmp/subhome
kind=secondmate
mode=secondmate
yolo=off
generation_id=gen-s1
account_home=$tmp/accounts/codex/1
account_task=smc-1
EOF
  PATH="$tmp/shim:$PATH" \
  FM_ACCOUNT_DIRECTORY_TEST_LAB=firstmate-account-directory-test-lab-v1 \
  FM_ACCOUNT_DIRECTORY_ROOT="$tmp/accounts" \
  FM_HOME="$tmp/home" \
  FM_AZURE_SUBSCRIPTION_ID=$SUB \
  FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
  FM_AZURE_OWNER_TAG=owner \
  FM_AZURE_NAMING_PREFIX=fmtest \
  python3 - "$AUTHORITY" "$CONTROLLER" "$WRAPPER" "$tmp/home" <<'PY' || fail "the secondmate authority bundle did not verify through the unmodified release path"
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

authority, controller_path, wrapper, home_raw = sys.argv[1:]
home = Path(home_raw)

spec = importlib.util.spec_from_file_location("controller", controller_path)
controller = importlib.util.module_from_spec(spec)
spec.loader.exec_module(controller)

# One assigned compartment in REAL durable controller state, hand-minted
# through the module's own constructors so load_state/verify_state accept it.
menv = controller.environment()
state = controller.empty_state(menv)
resources = {
    kind: {"id": "/fixture/slot/1/{}".format(kind), "immutable_id": "{}-1".format(kind)}
    for kind in controller.REQUIRED_RESOURCE_KINDS
}
# The compartment landing receipt is tethered to the controller-owned
# repository generation, so the fixture binds the home's REAL starting head.
subhome_path = Path(
    (home / "state" / "smc-1.meta").read_text().splitlines()[1].split("=", 1)[1])
start_head = subprocess.run(
    ["git", "-C", str(subhome_path), "rev-parse", "HEAD"],
    text=True, stdout=subprocess.PIPE, check=True).stdout.strip()
bindings = {
    "home_binding": "1" * 64, "task": "smc-1", "task_generation": "gen-s1",
    "assignment_generation": "asg-00000001", "account_binding": "2" * 64,
    "worktree_binding": "3" * 64, "repository_binding": "4" * 64,
    "repository_generation": start_head,
}
worker = {
    "slot": 1, "role": "secondmate", "sku": "sku", "sku_family": "fam",
    "deployment_generation": menv["deployment_generation"], "owner": menv["owner"],
    "assignment_generation": "asg-00000001", "cloud_generation": 1,
    "bindings": bindings, "queue_key": "smc-1@gen-s1", "phase": "assigned",
    "created_at": controller.iso_utc(), "assigned_at": controller.iso_utc(),
    "released_at": None, "release_proof": None, "cooldown_started_at": None,
    "reservation_usd": 1.0, "resources": resources, "cloud_instance_id": "cloud-1",
    "last_classification": "assigned", "last_refusal": None,
}
state["queue"]["smc-1@gen-s1"] = {
    "schema": "fm.worker-request/v1", "task": "smc-1", "task_generation": "gen-s1",
    "owner_kind": "primary", "role": "secondmate", "eligible": True,
    "discretionary": True, "status": "assigned", "slot": 1,
    "assignment_generation": "asg-00000001", **bindings,
}
state["workers"]["1"] = worker
menv["state_dir"].mkdir(parents=True, exist_ok=True)
menv["state_path"].write_text(json.dumps(state, sort_keys=True, separators=(",", ":")) + "\n")

worker_state = home / "worker-state.json"
worker_state.write_text(json.dumps(worker, sort_keys=True, separators=(",", ":")))
proof_path = home / "smc-1-proof.json"

def authority_run():
    return subprocess.run([
        "python3", authority, "--home", str(home), "--task", "smc-1",
        "--task-generation", "gen-s1", "--assignment-generation", "asg-00000001",
        "--worker-state", str(worker_state), "--output", str(proof_path),
    ], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

# Each missing compartment evidence leg refuses the REAL CLI distinctly.
smstate = home / "state"
status_path = smstate / "smc-1.cloud-secondmate-status"
monitor_path = smstate / "smc-1.cloud-secondmate-state.json"
terminal = status_path.read_text()
status_path.unlink()
refused = authority_run()
assert refused.returncode == 2 and "lacks the terminal session status" in refused.stderr, refused.stderr
status_path.write_text(terminal)

monitor = json.loads(monitor_path.read_text())
broken = json.loads(monitor_path.read_text())
broken["last_summary"]["reason"] = "idle"
monitor_path.write_text(json.dumps(broken, sort_keys=True, separators=(",", ":")))
refused = authority_run()
assert refused.returncode == 2 and "lacks the chained close ack" in refused.stderr, refused.stderr

broken = json.loads(monitor_path.read_text())
broken["last_summary"]["reason"] = "close"
broken["landed_bundles"] = []
monitor_path.write_text(json.dumps(broken, sort_keys=True, separators=(",", ":")))
refused = authority_run()
assert refused.returncode == 2 and "unlanded outbox bundles" in refused.stderr, refused.stderr
monitor_path.write_text(json.dumps(monitor, sort_keys=True, separators=(",", ":")))

subhome = subhome_path
(subhome / "charter.md").write_text("dirty\n")
refused = authority_run()
assert refused.returncode == 2 and "not quiesced: uncommitted or untracked work remains" in refused.stderr, refused.stderr
subprocess.run(["git", "-C", str(subhome), "checkout", "--", "charter.md"], check=True)

# The complete fixture mints five proved receipts.
minted = authority_run()
assert minted.returncode == 0, minted.stderr
proof = json.loads(proof_path.read_text())
assert proof["schema"] == "fm.worker-release/v2"
assert sorted(proof["authorities"]) == ["account", "endpoint", "landing", "report", "worktree"]
assert all(value["verdict"] == "proved" for value in proof["authorities"].values())
assert proof["assignment_generation"] == "asg-00000001"

# The UNMODIFIED release byte-path: the real CLI accepts the bundle...
released = subprocess.run(
    [wrapper, "release", "--task", "smc-1", "--task-generation", "gen-s1",
     "--proof-file", str(proof_path)],
    text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=os.environ.copy())
assert released.returncode == 0, released.stderr
after = json.loads(menv["state_path"].read_text())
assert after["queue"]["smc-1@gen-s1"]["status"] == "releasing"
assert after["workers"]["1"]["release_proof"] == proof

# ... and refuses a tampered receipt through the same unmodified validators:
# a fully re-signed non-proved verdict still cannot release.
import hashlib
def resign(value):
    unsigned = dict(value)
    unsigned.pop("receipt_digest", None)
    unsigned.pop("proof_digest", None)
    return hashlib.sha256(json.dumps(unsigned, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
tampered = json.loads(proof_path.read_text())
tampered["authorities"]["report"]["verdict"] = "surrendered"
tampered["authorities"]["report"]["receipt_digest"] = resign(tampered["authorities"]["report"])
tampered["proof_digest"] = resign(tampered)
tampered_path = home / "tampered-proof.json"
tampered_path.write_text(json.dumps(tampered, sort_keys=True, separators=(",", ":")))
menv["state_path"].write_text(json.dumps(state, sort_keys=True, separators=(",", ":")) + "\n")
refused = subprocess.run(
    [wrapper, "release", "--task", "smc-1", "--task-generation", "gen-s1",
     "--proof-file", str(tampered_path)],
    text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=os.environ.copy())
assert refused.returncode != 0 and "did not prove release safety" in refused.stderr, refused.stderr
PY
  pass "the secondmate bundle proves five receipts and releases through the unmodified verify path"
}

ordinary_mode_selection_golden() {
  # kind selects the mode: a non-secondmate meta must take the ORDINARY
  # evidence path (its refusal strings, not the compartment ones), and an
  # ambiguous kind refuses outright.
  local tmp
  fm_test_tmproot_into tmp fm-authority-mode-golden
  mkdir -p "$tmp/home/state" "$tmp/accounts/codex/1" "$tmp/shim"
  cat > "$tmp/shim/tmux" <<'SH'
#!/bin/sh
echo "no server running on /tmp/fm-secondmate-authority-test" >&2
exit 1
SH
  chmod +x "$tmp/shim/tmux"
  write_home_worktree "$tmp/subhome"
  cat > "$tmp/home/state/task-o.meta" <<EOF
window=fmtest:1
worktree=$tmp/subhome
kind=ship
generation_id=gen-o
account_home=$tmp/accounts/codex/1
account_task=task-o
EOF
  PATH="$tmp/shim:$PATH" python3 - "$AUTHORITY" "$tmp/home" <<'PY' || fail "kind-based evidence mode selection failed"
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

authority, home_raw = sys.argv[1:]
home = Path(home_raw)
worker_state = home / "worker-state.json"
worker_state.write_text(json.dumps({
    "assignment_generation": "asg-00000001",
    "bindings": {"repository_generation": "repo-o", "home_binding": "1" * 64,
                 "account_binding": "2" * 64, "worktree_binding": "3" * 64,
                 "repository_binding": "4" * 64},
    "cloud_instance_id": "cloud-1", "resources": {},
}))

def run(task):
    return subprocess.run([
        "python3", authority, "--home", str(home), "--task", task,
        "--task-generation", "gen-o", "--assignment-generation", "asg-00000001",
        "--worker-state", str(worker_state), "--output", str(home / "out.json"),
    ], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

# kind=ship: the ordinary lane runs - no compartment file is consulted; with
# the endpoint provably absent, the first refusal is the ORDINARY report one
# (no completion.md), never the secondmate terminal-status string.
result = run("task-o")
assert result.returncode == 2, result.stderr
assert "secondmate" not in result.stderr, result.stderr
assert "completion report authority is absent" in result.stderr, result.stderr

# An ambiguous kind refuses before any evidence is weighed.
meta = home / "state" / "task-o.meta"
meta.write_text(meta.read_text() + "kind=secondmate\n")
result = run("task-o")
assert result.returncode == 2 and "kind identity is not exact" in result.stderr, result.stderr
PY
  pass "evidence mode selection follows the exact task metadata kind"
}

role_kind_cross_check() {
  # The adversarial finding this closes: the evidence mode used to be chosen
  # from the LOCAL task meta's kind= line alone. Flipping that one line (plus
  # planting the two compartment state files) moved a role=author worker
  # holding an UNLANDED COMMIT onto the compartment lane, where the ordinary
  # "reachable from origin" landing proof does not apply - all five receipts
  # minted proved and the real release moved the queue to `releasing` with the
  # work still only local. The controller-owned role decides now, and both
  # directions refuse.
  local tmp
  fm_test_tmproot_into tmp fm-authority-role-kind
  mkdir -p "$tmp/home" "$tmp/accounts/codex/1" "$tmp/shim"
  cat > "$tmp/shim/tmux" <<'SH'
#!/bin/sh
echo "no server running on /tmp/fm-secondmate-authority-test" >&2
exit 1
SH
  chmod +x "$tmp/shim/tmux"
  write_home_worktree "$tmp/subhome"
  # A REAL origin with the base commit pushed, then an UNLANDED commit on top:
  # the ordinary landing authority reaches its own proof and refuses because
  # the work is not reachable from origin - which is exactly the refusal the
  # compartment lane was bypassing.
  git init --quiet --bare "$tmp/origin.git"
  git -C "$tmp/origin.git" symbolic-ref HEAD refs/heads/main
  git -C "$tmp/subhome" remote add origin "$tmp/origin.git"
  git -C "$tmp/subhome" push --quiet -u origin main
  printf 'unlanded\n' >"$tmp/subhome/feature.txt"
  git -C "$tmp/subhome" add feature.txt
  git -C "$tmp/subhome" commit --quiet -m "UNLANDED WORK"
  write_compartment_fixture "$tmp/home" task-a >/dev/null || fail "compartment fixture build failed"
  cat > "$tmp/home/state/task-a.meta" <<EOF
window=fmtest:1
worktree=$tmp/subhome
kind=ship
generation_id=gen-a
account_home=$tmp/accounts/codex/1
account_task=task-a
EOF
  PATH="$tmp/shim:$PATH" \
  FM_ACCOUNT_DIRECTORY_TEST_LAB=firstmate-account-directory-test-lab-v1 \
  FM_ACCOUNT_DIRECTORY_ROOT="$tmp/accounts" \
  python3 - "$AUTHORITY" "$tmp/home" "$tmp/subhome" <<'PY' || fail "the controller role does not decide the evidence mode"
import json
from pathlib import Path
import subprocess
import sys

authority, home_raw, subhome_raw = sys.argv[1:]
home = Path(home_raw)
subhome = Path(subhome_raw)
meta = home / "state" / "task-a.meta"
worker_state = home / "worker-state.json"
head = subprocess.run(["git", "-C", str(subhome), "rev-parse", "HEAD"],
                      text=True, stdout=subprocess.PIPE, check=True).stdout.strip()

def write_worker(role):
    worker = {
        "assignment_generation": "asg-00000001", "role": role,
        "bindings": {"repository_generation": head, "home_binding": "1" * 64,
                     "account_binding": "2" * 64, "worktree_binding": "3" * 64,
                     "repository_binding": "4" * 64},
        "cloud_instance_id": "cloud-1", "resources": {},
    }
    worker_state.write_text(json.dumps(worker, sort_keys=True, separators=(",", ":")))

def set_kind(kind):
    lines = [line for line in meta.read_text().splitlines() if not line.startswith("kind=")]
    lines.insert(3, "kind=" + kind)
    meta.write_text("\n".join(lines) + "\n")

def run():
    return subprocess.run([
        "python3", authority, "--home", str(home), "--task", "task-a",
        "--task-generation", "gen-a", "--assignment-generation", "asg-00000001",
        "--worker-state", str(worker_state), "--output", str(home / "out.json"),
    ], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

# The reviewer's exact escalation: an ORDINARY author worker whose meta claims
# a compartment. It must refuse on the role mismatch, never mint.
write_worker("author")
set_kind("secondmate")
result = run()
assert result.returncode == 2, (result.returncode, result.stdout)
assert "the controller-owned worker role is 'author'" in result.stderr, result.stderr
assert not (home / "out.json").exists(), "a refused authority still wrote a bundle"

# Control: the SAME author worker on its honest meta refuses for the ordinary
# reason - the commit is genuinely not landed. This is what the compartment
# lane was letting through.
set_kind("ship")
result = run()
assert result.returncode == 2, result.stdout
assert "landing authority did not prove committed work reachable" in result.stderr, result.stderr

# The mirror direction: a controller-owned compartment whose meta says
# otherwise refuses too, rather than quietly taking the ordinary lane.
write_worker("secondmate")
set_kind("ship")
result = run()
assert result.returncode == 2, result.stdout
assert "the task metadata kind is 'ship'" in result.stderr, result.stderr

# Positive control: role and kind agreeing on secondmate reaches the
# compartment evidence and mints (the fixture is a clean closed-out home).
set_kind("secondmate")
result = run()
assert result.returncode == 0, result.stderr
proof = json.loads((home / "out.json").read_text())
assert all(v["verdict"] == "proved" for v in proof["authorities"].values()), proof["authorities"]
PY
  pass "the controller-owned worker role decides the evidence mode in both directions"
}

secondmate_evidence_refusal_matrix
secondmate_authority_bundle_end_to_end
ordinary_mode_selection_golden
role_kind_cross_check

echo "# fm-worker-authority-secondmate.test.sh: all assertions passed"
