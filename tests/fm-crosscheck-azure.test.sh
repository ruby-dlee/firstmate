#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ADAPTER="$ROOT/bin/fm-crosscheck-azure.py"
CORE="$ROOT/bin/fm-crosscheck.py"
MODEL_GUEST="$ROOT/bin/fm-crosscheck-azure-model-guest.sh"
BRIDGE="$ROOT/bin/fm-crosscheck-azure-tool-bridge.py"
CLIENT="$ROOT/bin/fm-crosscheck-azure-tool-client.py"
COMMAND="$ROOT/bin/fm-crosscheck-azure-tool-command.py"
REPLAY="$ROOT/bin/fm-crosscheck-azure-replay.py"
TEMPLATE="$ROOT/docs/azure-crosscheck/compartment.json"
DOC="$ROOT/docs/azure-crosscheck.md"
EVIDENCE="$ROOT/docs/azure-crosscheck-evidence-2026-08-12.md"

static_contract() {
  python3 - "$ADAPTER" "$CORE" "$MODEL_GUEST" "$BRIDGE" "$CLIENT" "$COMMAND" "$REPLAY" "$TEMPLATE" "$DOC" <<'PY'
import ast
import json
from pathlib import Path
import sys

adapter, core, guest, bridge, client, command, replay, template, doc = map(Path, sys.argv[1:])
for path in (adapter, core, bridge, client, command, replay):
    ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
value = json.loads(template.read_text(encoding="utf-8"))
resources = value["resources"]
assert len(resources) == 3
nic = next(item for item in resources if item["type"] == "Microsoft.Network/networkInterfaces")
vm = next(item for item in resources if item["type"] == "Microsoft.Compute/virtualMachines")
assert "publicipaddress" not in json.dumps(nic).lower()
assert "identity" not in vm
assert "ssh" not in json.dumps(vm["properties"]["osProfile"]).lower()
assert vm["properties"]["securityProfile"]["securityType"] == "TrustedLaunch"
assert vm["properties"]["storageProfile"]["imageReference"] == {"id": "[parameters('modelImageId')]"}
source = adapter.read_text(encoding="utf-8")
for marker in (
    "azure-compartment-v1",
    "review_generation",
    "claims_sha256",
    "ledger_digest",
    "vm_instance_id",
    "boot_id",
    "network_bytes",
    "credential_present",
    "If-Match=",
):
    assert marker in source
core_source = core.read_text(encoding="utf-8")
assert "load_azure_crosscheck_adapter" in core_source
assert "validate_azure_reviewer_record" in core_source
assert "verify_azure_reviewer_record" in core_source
bridge_source = bridge.read_text(encoding="utf-8")
for marker in ("ALLOWED_OPERATIONS", "crosscheck-tool", "tool_identity", "verifier_identity", "vm_instance_id"):
    assert marker in bridge_source
client_source = client.read_text(encoding="utf-8")
assert "/run/fm-crosscheck/tool-bridge.sock" in client_source
assert "SO_PEERCRED" in bridge_source
guest_source = guest.read_text(encoding="utf-8")
assert "fm-crosscheck-tool-client" in guest_source
assert "AZURE_CLIENT_SECRET" in guest_source
assert "DOCKER_HOST" in guest_source
for forbidden in ("ssh ", "docker ", "az login", "--dangerously-bypass-approvals-and-sandbox"):
    assert forbidden not in guest_source
text = doc.read_text(encoding="utf-8")
for phrase in (
    "fresh identity-less `crosscheck-tool` runner",
    "second newly created identity-less `crosscheck-tool` runner",
    "A single VM containing both provider credentials and repository commands is not accepted",
    "force-push",
    "Two admitted reviews",
    "Cloud-default acceptance",
):
    assert phrase in text
PY
  pass "Azure Crosscheck static contracts separate model, tool, verifier, identity, and cleanup"
}

adapter_mode_unit() {
  python3 - "$ADAPTER" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import sys

spec = importlib.util.spec_from_file_location("azure_crosscheck", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as temporary:
    home = Path(temporary)
    (home / "config").mkdir()
    assert module.azure_review_enabled(home) is False
    os.environ["FM_CROSSCHECK_EXECUTION_MODE"] = "azure"
    assert module.azure_review_enabled(home) is True
    os.environ["FM_CROSSCHECK_EXECUTION_MODE"] = "local"
    assert module.azure_review_enabled(home) is False
    os.environ["FM_CROSSCHECK_EXECUTION_MODE"] = "bad"
    try:
        module.azure_review_enabled(home)
    except module.AzureCrosscheckError as exc:
        assert "exactly local or azure" in str(exc)
    else:
        raise AssertionError("invalid execution mode did not fail")
    del os.environ["FM_CROSSCHECK_EXECUTION_MODE"]
    path = home / "config" / "crosscheck-azure.json"
    path.write_text(json.dumps({"enabled": True}), encoding="utf-8")
    os.chmod(path, 0o600)
    assert module.azure_review_enabled(home) is True
    os.chmod(path, 0o666)
    try:
        module.azure_review_enabled(home)
    except module.AzureCrosscheckError as exc:
        assert "non-group/world-writable" in str(exc)
    else:
        raise AssertionError("unsafe config mode did not fail")
PY
  pass "Azure selection is explicit, local-default, and unsafe config fails closed"
}

identity_outcome_unit() {
  python3 - "$ADAPTER" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("azure_crosscheck", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
base = {
    "execution_mode": "azure-compartment-v1",
    "harness": "pi",
    "model": "gpt-5.6-sol",
    "account_home": "/independent/pi",
    "reviewer_account_identity_sha256": "2" * 64,
    "azure_identity": {
        "home_binding": "sha256:" + "1" * 64,
        "task_id": "task-one",
        "pull_request": "https://github.com/example/repo/pull/1",
        "head_sha": "a" * 40,
        "base_sha": "b" * 40,
        "claims_sha256": "c" * 64,
        "reviewer_harness": "pi",
        "reviewer_model": "gpt-5.6-sol",
        "reviewer_account_digest": "sha256:" + "2" * 64,
        "review_generation": "e" * 24,
        "ledger_digest": "sha256:" + "f" * 64,
        "request_digest": "sha256:" + "0" * 64,
        "model": {"resource_id": "/model", "vm_instance_id": "model", "boot_id": "boot-model"},
        "tool": {
            "resource_id": "/tool", "vm_instance_id": "tool", "boot_id": "boot-tool",
            "review_generation": "e" * 24, "network_bytes": 0, "credential_present": False,
        },
        "verifier": {
            "resource_id": "/verifier", "vm_instance_id": "verifier", "boot_id": "boot-verifier",
            "review_generation": "e" * 24, "network_bytes": 0, "credential_present": False,
        },
    },
}
run = {"head_sha": "a" * 40, "base_sha": "b" * 40, "claims_sha256": "c" * 64}
module.validate_azure_reviewer_record(base, run, "run")
for mutation, expected in (
    (("head_sha", "9" * 40), "head/base"),
    (("tool.vm_instance_id", "model"), "reused"),
    (("verifier.network_bytes", 1), "networkless"),
    (("verifier.credential_present", True), "networkless"),
    (("verifier.review_generation", "wrong"), "generation"),
):
    import copy
    candidate = copy.deepcopy(base)
    path, value = mutation
    if "." in path:
        first, second = path.split(".")
        candidate["azure_identity"][first][second] = value
    else:
        candidate["azure_identity"][path] = value
    try:
        module.validate_azure_reviewer_record(candidate, run, "run")
    except RuntimeError as exc:
        assert expected in str(exc), (expected, str(exc))
    else:
        raise AssertionError("identity mismatch did not fail: " + path)
PY
  pass "wrong head, stale endpoint, shared VM, network, credential, and generation outcomes fail closed"
}

account_and_cleanup_identity_unit() {
  python3 - "$ADAPTER" <<'PY'
import importlib.util
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location("azure_crosscheck", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
common = {
    "home": Path("/home/firstmate"),
    "task_id": "review-one",
    "pr_url": "https://github.com/example/repo/pull/1",
    "snapshot_value": {
        "head_sha": "a" * 40,
        "base_sha": "b" * 40,
        "base_branch_sha": "c" * 40,
        "claims_sha256": "d" * 64,
    },
    "config": {
        "harness": "pi",
        "model": "gpt-5.6-sol",
        "effort": "xhigh",
        "account_home": "/same/path",
    },
    "ledger": {"schema": "firstmate.crosscheck-ledger.v2", "findings": [], "runs": []},
}
first = module.review_identity(**common, reviewer_account_identity="account-one")
second = module.review_identity(**common, reviewer_account_identity="account-two")
assert first["reviewer_account_digest"] != second["reviewer_account_digest"]
assert first["review_generation"] != second["review_generation"]

original = module.az
module.az = lambda *_args, **_kwargs: (None, 1, "AuthorizationFailed")
try:
    module.delete_exact_resource({}, "/resource", "1", {}, "fixture")
except module.AzureCrosscheckError as exc:
    assert "ambiguous" in str(exc)
else:
    raise AssertionError("an unreadable resource became cleanup absence")
module.az = lambda *_args, **_kwargs: (None, 1, "ResourceNotFound")
module.delete_exact_resource({}, "/resource", "1", {}, "fixture")
module.az = original
PY
  pass "review generation binds the executing account and ambiguous cleanup never becomes absence"
}

bridge_security_unit() {
  python3 - "$BRIDGE" <<'PY'
import importlib.util
import copy
import hashlib
import json
import sys

spec = importlib.util.spec_from_file_location("bridge", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
request = {
    "schema": "fm.azure-crosscheck/v1",
    "identity": {"review_generation": "a" * 24, "head_sha": "b" * 40, "base_sha": "c" * 40},
}
request["request_digest"] = module.digest(module.canonical(request))
base = {
    "schema": "fm.azure-crosscheck-tool-rpc/v1",
    "operation": "git-diff",
    "review_generation": "a" * 24,
    "request_digest": request["request_digest"],
    "arguments": [],
    "request": request,
    "verdict": None,
}
module.validate_request(base)
assert module.operation_command(base) == [
    "git", "diff", "--no-ext-diff", "--no-renames", "c" * 40, "b" * 40, "--"
]
read_command = copy.deepcopy(base)
read_command["operation"] = "read"
read_command["arguments"] = ["README.md"]
read_argv = module.operation_command(read_command)
assert read_argv[:2] == ["python3", "-c"]
assert "fm-crosscheck-azure-tool-command.py" not in read_argv
assert "Allow-listed repository inspection command" in read_argv[2]
for update, expected in (
    ({"operation": "shell"}, "allow-listed"),
    ({"review_generation": "wrong"}, "generation"),
    ({"request_digest": "sha256:" + "0" * 64}, "digest"),
    ({"arguments": ["x"] * 65}, "item bound"),
):
    candidate = copy.deepcopy(base)
    candidate.update(update)
    try:
        module.validate_request(candidate)
    except module.BridgeError as exc:
        assert expected in str(exc), (expected, str(exc))
    else:
        raise AssertionError("malicious bridge request did not fail")
for malicious in (
    ["../../control-home"],
    ["/etc/passwd"],
    [".crosscheck/reproductions/linked/../../token"],
):
    candidate = copy.deepcopy(base)
    candidate["operation"] = "bash-evidence"
    candidate["arguments"] = [*malicious, "IyEvYmluL2Jhc2gK"]
    try:
        module.operation_command(candidate)
    except module.BridgeError:
        pass
    else:
        raise AssertionError("malicious evidence path did not fail: " + repr(malicious))
PY
  pass "bridge rejects shell, identity drift, oversized items, traversal, absolute paths, and symlink-shaped escape"
}

tool_command_security_unit() {
  local tmp
  fm_test_tmproot_into tmp fm-crosscheck-azure-tool-command
  printf 'allowed counterpart\n' >"$tmp/allowed.txt"
  (
    cd "$tmp" || exit
    "$COMMAND" read allowed.txt 1 10
  ) >"$tmp/allowed.out"
  assert_grep 'allowed counterpart' "$tmp/allowed.out" "allowed regular-file positive control was not observable"
  ln -s allowed.txt "$tmp/linked.txt"
  if (
    cd "$tmp" || exit
    "$COMMAND" read linked.txt 1 10
  ) >"$tmp/linked.out" 2>&1; then
    fail "symlink file became an allowed read"
  fi
  python3 - "$tmp/oversized.txt" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes(b"x" * (8 * 1024 * 1024 + 1) + b"\n")
PY
  if (
    cd "$tmp" || exit
    "$COMMAND" read oversized.txt 1 1
  ) >"$tmp/oversized.out" 2>&1; then
    fail "oversized regular-file output became an allowed read"
  fi
  assert_grep 'output exceeded byte bound' "$tmp/oversized.out" "oversized output refusal was not named"
  pass "tool VM file reads have observable positive control and deny symlinks and oversized output"
}

replay_positive_and_failure_unit() {
  local tmp evidence
  fm_test_tmproot_into tmp fm-crosscheck-azure-replay
  mkdir -p "$tmp/.crosscheck/reproductions"
  cat >"$tmp/.crosscheck/reproductions/pass.sh" <<'SH'
#!/usr/bin/env bash
printf 'allowed-positive-control\n'
SH
  chmod +x "$tmp/.crosscheck/reproductions/pass.sh"
  evidence=$(python3 - "$tmp/.crosscheck/reproductions/pass.sh" <<'PY'
import base64,json,sys
body=base64.b64encode(open(sys.argv[1],"rb").read()).decode()
print(base64.b64encode(json.dumps({".crosscheck/reproductions/pass.sh":body},sort_keys=True,separators=(",",":")).encode()).decode())
PY
)
  (
    cd "$tmp" || exit
    rm .crosscheck/reproductions/pass.sh
    "$REPLAY" --mode verify --evidence-json "$evidence" -- bash --noprofile --norc .crosscheck/reproductions/pass.sh --next-command
  ) >"$tmp/out"
  assert_grep 'allowed-positive-control' "$tmp/out" "allowed replay positive control was not observable"
  python3 - "$tmp/out" <<'PY'
import json,sys
value=json.load(open(sys.argv[1])); assert value["schema"]=="fm.azure-crosscheck-replay/v1"; assert value["results"][0]["exit"]==0
PY
  cat >"$tmp/.crosscheck/reproductions/fail.sh" <<'SH'
#!/usr/bin/env bash
printf 'denied-probe-observed\n'
exit 23
SH
  chmod +x "$tmp/.crosscheck/reproductions/fail.sh"
  evidence=$(python3 - "$tmp/.crosscheck/reproductions/fail.sh" <<'PY'
import base64,json,sys
body=base64.b64encode(open(sys.argv[1],"rb").read()).decode()
print(base64.b64encode(json.dumps({".crosscheck/reproductions/fail.sh":body},sort_keys=True,separators=(",",":")).encode()).decode())
PY
)
  if (
    cd "$tmp" || exit
    rm .crosscheck/reproductions/fail.sh
    "$REPLAY" --mode verify --evidence-json "$evidence" -- bash --noprofile --norc .crosscheck/reproductions/fail.sh --next-command
  ) >"$tmp/fail-out" 2>&1; then
    fail "failed evidence helper became a verifier pass"
  fi
  assert_grep 'denied-probe-observed' "$tmp/fail-out" "failed replay output was not preserved"
  pass "networkless replay observes an allowed control and preserves a denied helper failure"
}

documented_acceptance_contract() {
  for required in \
    'reviewer-token reads' \
    'cloud metadata' \
    'symlink swaps' \
    'fork, daemon, detached descendant' \
    'wrong reviewer account' \
    'Run two real reviews concurrently' \
    'Kill one model compartment' \
    'Force-push' \
    'Cloud-default acceptance'; do
    assert_grep "$required" "$DOC" "operator acceptance omits $required"
  done
  assert_grep '2026-08-12' "$EVIDENCE" "dated Linux evidence is missing"
  pass "operator documentation enumerates malicious, concurrency, fault, force-push, and cloud-default acceptance"
}

static_contract
adapter_mode_unit
identity_outcome_unit
account_and_cleanup_identity_unit
bridge_security_unit
tool_command_security_unit
replay_positive_and_failure_unit
documented_acceptance_contract
printf 'Azure Crosscheck tests passed.\n'
