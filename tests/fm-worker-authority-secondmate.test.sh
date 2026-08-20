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
(state / (task + ".cloud-secondmate-state.json")).write_text(json.dumps({
    "delivered_sequence": 2,
    "landed_bundles": [bundle_digest],
    "kept_bundles": [],
    "last_summary": {"reason": "close", "legs_completed": 2},
    "verified_tip": {"sequence": 2, "chain_digest": "f" * 64},
}, sort_keys=True, separators=(",", ":")) + "\n")

mailbox = state / (task + ".cloud-mailbox")
mailbox.mkdir(exist_ok=True)
summary = {
    "kind": "fm.secondmate-leg-summary/v1",
    "sequence": 2,
    "reason": "close",
    "legs_completed": 2,
    "bundles": [{
        "name": "session/out/bundle-00000001-{}.bundle".format(bundle_digest),
        "sha256": bundle_digest, "bytes": len(bundle_body), "commits": 1,
    }],
}
unsigned = json.dumps(summary, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
content = hashlib.sha256(unsigned).hexdigest()
summary["content_sha256"] = content
summary["chain_digest"] = hashlib.sha256(("0" * 64 + content).encode()).hexdigest()
(mailbox / "{:08d}-{}.json".format(2, content)).write_text(
    json.dumps(summary, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
(mailbox / "bundle-00000001-{}.bundle".format(bundle_digest)).write_bytes(bundle_body)

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

# The good fixture proves all three compartment legs.
report = module.secondmate_report_evidence(home, task)
assert report.startswith(b"closed\0close\x002\0"), report[:40]
assert b"## Summary" in report
landing = module.secondmate_landing_evidence(home, task)
assert bundle_digest.encode() in landing
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
expect(lambda: module.secondmate_landing_evidence(home, task),
       "no durable monitor state")
Path(str(state_path) + ".away").rename(state_path)
# landing: a bundle the monitor kept instead of landing.
value = monitor_state()
value["kept_bundles"] = [bundle_digest]
put_state(value)
expect(lambda: module.secondmate_landing_evidence(home, task),
       "kept unlanded")
put_state(saved)
# landing: a DECLARED bundle absent from the landed record.
value = monitor_state()
value["landed_bundles"] = []
put_state(value)
expect(lambda: module.secondmate_landing_evidence(home, task),
       "unlanded outbox bundles")
# worktree: the same unlanded evidence blocks the quiesced-home receipt.
expect(lambda: module.secondmate_worktree_evidence(home, task, values),
       "not quiesced: unlanded outbox bundles remain")
put_state(saved)
# landing: a collected-but-undeclared bundle FILE must also be landed.
stray = mailbox / ("bundle-00000009-" + "a" * 64 + ".bundle")
stray.write_bytes(b"stray")
expect(lambda: module.secondmate_landing_evidence(home, task),
       "unlanded outbox bundles")
stray.unlink()
# landing: a recorded chain break freezes the receipt.
(mailbox / ".chain-break").write_text("{}")
expect(lambda: module.secondmate_landing_evidence(home, task),
       "frozen by a recorded outbox chain break")
(mailbox / ".chain-break").unlink()
# landing: provably none - an empty verified chain with nothing declared.
value = monitor_state()
value["landed_bundles"] = []
put_state(value)
for entry in list(mailbox.iterdir()):
    entry.unlink()
empty = module.secondmate_landing_evidence(home, task)
assert b'"declared":[]' in empty and b'"landed":[]' in empty
put_state(saved)
# worktree: tracked modifications are not a quiesced home.
(subhome / "charter.md").write_text("edited\n")
expect(lambda: module.secondmate_worktree_evidence(home, task, values),
       "not quiesced: tracked modifications remain")
# ... while UNTRACKED runtime files are the home's ordinary state.
import subprocess
subprocess.run(["git", "-C", str(subhome), "checkout", "--", "charter.md"], check=True)
(subhome / "runtime.log").write_text("noise\n")
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
bindings = {
    "home_binding": "1" * 64, "task": "smc-1", "task_generation": "gen-s1",
    "assignment_generation": "asg-00000001", "account_binding": "2" * 64,
    "worktree_binding": "3" * 64, "repository_binding": "4" * 64,
    "repository_generation": "repo-s1",
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

subhome = Path((smstate / "smc-1.meta").read_text().splitlines()[1].split("=", 1)[1])
(subhome / "charter.md").write_text("dirty\n")
refused = authority_run()
assert refused.returncode == 2 and "not quiesced: tracked modifications remain" in refused.stderr, refused.stderr
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

secondmate_evidence_refusal_matrix
secondmate_authority_bundle_end_to_end
ordinary_mode_selection_golden

echo "# fm-worker-authority-secondmate.test.sh: all assertions passed"
