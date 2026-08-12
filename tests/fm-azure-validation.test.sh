#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Focused queue, identity, security-negative, recovery, cost-admission, and
# static Azure contract tests for isolated no-mistakes validation cells.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VALIDATION="$ROOT/bin/fm-azure-validation.sh"
HOST="$ROOT/bin/fm-azure-validation.py"
GUEST="$ROOT/bin/fm-azure-validation-guest.sh"
BRIDGE="$ROOT/bin/fm-azure-validation-shard-bridge.py"
TEMPLATE="$ROOT/docs/azure-validation/cell.json"
DOC="$ROOT/docs/azure-validation.md"
SUB=11111111-1111-4111-8111-111111111111

make_repo() {
  local root=$1
  mkdir -p "$root/remote.git" "$root/repo"
  git -C "$root/remote.git" init -q --bare
  git -C "$root/repo" init -q -b main
  git -C "$root/repo" config user.name fixture
  git -C "$root/repo" config user.email fixture@example.invalid
  printf '# fixture\n' >"$root/repo/README.md"
  git -C "$root/repo" add README.md
  git -C "$root/repo" commit -qm initial
  git -C "$root/repo" remote add origin "file://$root/remote.git"
  git -C "$root/repo" switch -qc fm/fixture
  git -C "$root/repo" push -q -u origin fm/fixture
}

make_runtime() {
  local root=$1 provider=${2:-codex}
  mkdir -p "$root/runtime/bin"
  printf '#!/bin/sh\nexit 0\n' >"$root/runtime/bin/no-mistakes"
  printf '#!/bin/sh\nexit 0\n' >"$root/runtime/bin/provider"
  chmod +x "$root/runtime/bin/no-mistakes" "$root/runtime/bin/provider"
  python3 - "$root/runtime" "$provider" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
files=[]
for relative in ("bin/no-mistakes", "bin/provider"):
    path=root/relative
    files.append({"path":relative,"digest":"sha256:"+hashlib.sha256(path.read_bytes()).hexdigest()})
manifest={
    "schema":"fm.azure-validation-runtime/v1",
    "provider":sys.argv[2],
    "no_mistakes_version":"1.41.2",
    "no_mistakes_path":"bin/no-mistakes",
    "files":files,
}
(root/"runtime.json").write_text(json.dumps(manifest,separators=(",",":"))+"\n")
PY
  COPYFILE_DISABLE=1 tar -czf "$root/runtime.tar.gz" -C "$root/runtime" runtime.json bin
}

make_lease() {
  local path=$1 task=$2 generation=$3 repo_slug=$4
  cat >"$path" <<JSON
{"schema":"fm.azure-credential-lease/v1","lease_id":"lease-${task}","task":"${task}","task_generation":"${generation}","provider":"codex","provider_account_binding":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","disk_content_binding":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","disk":{"id":"/subscriptions/${SUB}/resourceGroups/rg-firstmate-pilot-eastus-001/providers/Microsoft.Compute/disks/credential-${task}","etag":"etag-${task}","luks_uuid":"33333333-3333-4333-8333-333333333333","zone":"1"},"paths":{"provider_home":"provider","github_token":"github/token"},"github_authority":{"kind":"fine-grained-token","repository":"${repo_slug}","permissions":["contents:write","pull_requests:write","checks:read"]},"expires_at":"2099-08-13T12:00:00Z"}
JSON
  chmod 600 "$path"
}

validation() {
  local home=$1
  shift
  FM_HOME="$home" FM_AZURE_DEPLOYMENT_GENERATION=gen-one "$VALIDATION" "$@"
}

cell_from() {
  printf '%s\n' "$1" | sed -n 's/.*cell=\(azv-[a-z0-9]*\).*/\1/p'
}

static_contract() {
  python3 - "$TEMPLATE" "$HOST" "$GUEST" "$BRIDGE" "$ROOT/.no-mistakes.yaml" <<'PY'
import json
from pathlib import Path
import sys

template=json.loads(Path(sys.argv[1]).read_text())
text=Path(sys.argv[1]).read_text().lower()
resources=template["resources"]
vm=next(item for item in resources if item["type"]=="Microsoft.Compute/virtualMachines")
nic=next(item for item in resources if item["type"]=="Microsoft.Network/networkInterfaces")
work=next(item for item in resources if item["type"]=="Microsoft.Compute/disks")
identity=next(item for item in resources if item["type"]=="Microsoft.ManagedIdentity/userAssignedIdentities")
assert "publicipaddress" not in json.dumps(nic).lower()
assert "customdata" not in text and "authorized_keys" not in text
assert vm["identity"]["type"]=="userAssigned"
assert vm["properties"]["securityProfile"]["securityType"]=="TrustedLaunch"
assert vm["properties"]["securityProfile"]["encryptionAtHost"] is True
assert vm["properties"]["storageProfile"]["osDisk"]["deleteOption"]=="Delete"
data=vm["properties"]["storageProfile"]["dataDisks"]
assert len(data)==2 and {item["lun"] for item in data}=={0,1}
assert all(item["deleteOption"]=="Detach" for item in data)
assert work["properties"]["networkAccessPolicy"]=="DenyAll"
assert work["properties"]["publicNetworkAccess"]=="Disabled"
assert template["parameters"]["vmSize"]["allowedValues"]==[
    "Standard_D8as_v5","Standard_D8s_v5","Standard_D8ads_v5","Standard_D8ds_v5"
]
assert identity["tags"].find("one-validation-container")!=-1
host=Path(sys.argv[2]).read_text()
guest=Path(sys.argv[3]).read_text()
bridge=Path(sys.argv[4]).read_text()
nm=Path(sys.argv[5]).read_text()
for value in ("REGIONAL_TARGET_VCPUS = 128","VALIDATION_RESERVED_VCPUS = 64","AUTHOR_RESERVED_VCPUS = 64","MONTHLY_VALIDATION_HOURS = 400.0"):
    assert value in host
for value in ("MemoryMax","MemorySwapMax=0","TasksMax","CPUQuota=700%","PrivateTmp=yes","ProtectSystem=strict","CapabilityBoundingSet=","cryptsetup luksUUID","axi status"):
    assert value in guest
for value in ("fm.azure-validation-shard/v1","storage_token","vm_instance_id","boot_id","--verify"):
    assert value in bridge
assert '"$FM_AZURE_VALIDATION_SHARD_BRIDGE" behavior' in nm
assert '"$FM_AZURE_VALIDATION_SHARD_BRIDGE" lint' in nm
assert "no-mistakes daemon start" not in host
assert "no-mistakes daemon stop" not in host
assert "no-mistakes daemon restart" not in host
PY
  pass "cell template and trusted bridge preserve private per-run compute, disks, identity, and cgroup isolation"
}

submit_contract() {
  local tmp home repo out cell state marker rc
  fm_test_tmproot_into tmp fm-azure-validation-submit
  home="$tmp/home"
  mkdir -p "$home"
  make_repo "$tmp/project"
  repo="$tmp/project/repo"
  make_runtime "$tmp"
  make_lease "$tmp/lease.json" task-one generation-one "fixture/repository"
  printf 'validate exact fixture\n' >"$tmp/intent.txt"
  marker="$tmp/az-called"
  mkdir -p "$tmp/fakebin"
  cat >"$tmp/fakebin/az" <<SH
#!/bin/sh
touch '$marker'
exit 99
SH
  cat >"$tmp/fakebin/git" <<SH
#!/bin/sh
case "\$*" in
  *' remote get-url origin') printf '%s\n' 'https://github.com/fixture/repository.git' ;;
  *) exec '$(command -v git)' "\$@" ;;
esac
SH
  chmod +x "$tmp/fakebin/az" "$tmp/fakebin/git"
  out=$(PATH="$tmp/fakebin:$PATH" validation "$home" submit \
    --task task-one --task-generation generation-one --validation-generation validation-one \
    --intent-file "$tmp/intent.txt" --credential-lease "$tmp/lease.json" \
    --runtime-bundle "$tmp/runtime.tar.gz" --repo "$repo") || fail "queue submit failed: $out"
  cell=$(cell_from "$out")
  [ -n "$cell" ] || fail "submit returned no cell id"
  [ ! -e "$marker" ] || fail "non-billable submit contacted Azure"
  state="$home/state/azure-validation/$cell.json"
  [ -f "$state" ] || fail "submit did not persist cell state"
  python3 - "$state" "$repo" <<'PY' || fail "submitted request identity assertions failed"
import hashlib,json,subprocess,sys,tarfile
from pathlib import Path
state=json.loads(Path(sys.argv[1]).read_text())
request=state["request"]
unsigned=dict(request); supplied=unsigned.pop("request_digest")
canonical=json.dumps(unsigned,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()
assert supplied=="sha256:"+hashlib.sha256(canonical).hexdigest()
head=subprocess.check_output(["git","-C",sys.argv[2],"rev-parse","HEAD"],text=True).strip()
assert request["repository"]["head"]==head
assert request["deployment_generation"]=="gen-one"
assert request["limits"]["vcpus"]==8 and request["limits"]["memory_gib"]==32
assert request["limits"]["behavior_shards"]==8
assert state["phase"]=="queued"
assert state["staging"]["container"].startswith("fmval")
serialized=Path(sys.argv[1]).read_text().lower()
for forbidden in ("ghp_","github_pat_","access_token","refresh_token","private_key"):
    assert forbidden not in serialized
with tarfile.open(state["input_path"],"r:gz") as archive:
    assert set(archive.getnames())=={"request.json","snapshot.bundle","runtime.tar.gz","shard-bridge.py"}
PY
  out=$(PATH="$tmp/fakebin:$PATH" validation "$home" queue) || fail "queue read failed: $out"
  assert_contains "$out" "cell=$cell phase=queued" "queue did not report the exact cell"
  printf 'dirty\n' >"$repo/untracked"
  rc=0
  PATH="$tmp/fakebin:$PATH" validation "$home" submit \
    --task task-two --task-generation generation-two --validation-generation validation-two \
    --intent-file "$tmp/intent.txt" --credential-lease "$tmp/lease.json" \
    --runtime-bundle "$tmp/runtime.tar.gz" --repo "$repo" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "submit accepted a dirty worktree"
  pass "submit queues a clean pushed exact head without Azure or local validation execution"
}

security_negative_contract() {
  local tmp home repo rc out
  fm_test_tmproot_into tmp fm-azure-validation-security
  home="$tmp/home"
  mkdir -p "$home"
  make_repo "$tmp/project"
  repo="$tmp/project/repo"
  mkdir -p "$tmp/fakebin"
  cat >"$tmp/fakebin/git" <<SH
#!/bin/sh
case "\$*" in
  *' remote get-url origin') printf '%s\n' 'https://github.com/fixture/repository.git' ;;
  *) exec '$(command -v git)' "\$@" ;;
esac
SH
  chmod +x "$tmp/fakebin/git"
  PATH="$tmp/fakebin:$PATH"
  make_runtime "$tmp"
  make_lease "$tmp/lease.json" task-one generation-one "fixture/repository"
  printf 'validate fixture\n' >"$tmp/intent.txt"
  python3 - "$tmp/lease.json" <<'PY'
import json,sys
p=sys.argv[1]; value=json.load(open(p)); value["access_token"]="forbidden-secret"; open(p,"w").write(json.dumps(value)+"\n")
PY
  chmod 600 "$tmp/lease.json"
  rc=0
  out=$(validation "$home" submit --task task-one --task-generation generation-one \
    --validation-generation validation-one --intent-file "$tmp/intent.txt" \
    --credential-lease "$tmp/lease.json" --runtime-bundle "$tmp/runtime.tar.gz" \
    --repo "$repo" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "submit accepted a secret-bearing lease descriptor"
  assert_contains "$out" "forbidden secret field" "secret-bearing lease refusal was not explicit"
  make_lease "$tmp/lease.json" task-one generation-one "fixture/repository"
  python3 - "$tmp/lease.json" <<'PY'
import json,sys
p=sys.argv[1]; value=json.load(open(p)); value["github_authority"]["permissions"].append("issues:write"); open(p,"w").write(json.dumps(value)+"\n")
PY
  chmod 600 "$tmp/lease.json"
  rc=0
  out=$(validation "$home" submit --task task-one --task-generation generation-one \
    --validation-generation validation-one --intent-file "$tmp/intent.txt" \
    --credential-lease "$tmp/lease.json" --runtime-bundle "$tmp/runtime.tar.gz" \
    --repo "$repo" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "submit accepted broad GitHub authority"
  assert_contains "$out" "must declare only" "broad GitHub authority refusal was not explicit"
  COPYFILE_DISABLE=1 tar -xzf "$tmp/runtime.tar.gz" -C "$tmp"
  printf 'secret\n' >"$tmp/runtime/auth.json"
  COPYFILE_DISABLE=1 tar -czf "$tmp/bad-runtime.tar.gz" -C "$tmp/runtime" runtime.json auth.json bin
  make_lease "$tmp/lease.json" task-one generation-one "fixture/repository"
  rc=0
  out=$(validation "$home" submit --task task-one --task-generation generation-one \
    --validation-generation validation-one --intent-file "$tmp/intent.txt" \
    --credential-lease "$tmp/lease.json" --runtime-bundle "$tmp/bad-runtime.tar.gz" \
    --repo "$repo" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "submit accepted a credential-like runtime path"
  assert_contains "$out" "credential-like path" "credential-like runtime refusal was not explicit"
  pass "secret-bearing leases, broad GitHub authority, and credential-like runtime bundles fail before admission"
}

admission_contract() {
  local tmp fixture out
  fm_test_tmproot_into tmp fm-azure-validation-admission
  fixture="$tmp/admission.json"
  python3 - "$fixture" <<'PY'
import json,sys
request={"limits":{"vcpus":8},"sku_family":"standarddasv5family"}
value={
 "operation":"admission",
 "policy":{"max_active":8,"validation_reserved_vcpus":64,"monthly_hours":400.0,"budget_limit":1000.0},
 "inventory":[],
 "quota":{"cores":{"limit":128,"used":0},"standarddasv5family":{"limit":64,"used":0}},
 "actual":100.0,"forecast":200.0,"rate":0.35,"used_hours":10.0,"request":request,
}
json.dump(value,open(sys.argv[1],"w"))
PY
  out=$(python3 "$HOST" pure-check --fixture "$fixture") || fail "positive admission fixture failed"
  assert_contains "$out" '"allowed": true' "healthy admission did not pass"
  python3 - "$fixture" <<'PY'
import json,sys
p=sys.argv[1]; value=json.load(open(p)); value["inventory"]=[{"role":"validation-cell","vcpus":8} for _ in range(8)]; json.dump(value,open(p,"w"))
PY
  out=$(python3 "$HOST" pure-check --fixture "$fixture") || fail "saturation fixture command failed"
  assert_contains "$out" '"allowed": false' "saturation was admitted"
  assert_contains "$out" "active validation-cell ceiling" "saturation refusal did not preserve queue reason"
  python3 - "$fixture" <<'PY'
import json,sys
p=sys.argv[1]; value=json.load(open(p)); value["inventory"]=[]; value["forecast"]=999.0; json.dump(value,open(p,"w"))
PY
  out=$(python3 "$HOST" pure-check --fixture "$fixture") || fail "cost-pressure fixture command failed"
  assert_contains "$out" '"allowed": false' "cost pressure was admitted"
  assert_contains "$out" "cost pressure stops new admission" "cost refusal did not name new admission only"
  pass "queue, reserved processor, worker-hour, quota, and cost admission saturate without oversubscription"
}

identity_and_recovery_contract() {
  local tmp fixture out rc
  fm_test_tmproot_into tmp fm-azure-validation-identity
  fixture="$tmp/identity.json"
  python3 - "$fixture" <<'PY'
import json,sys
head="a"*40
state={
 "request_digest":"sha256:"+"1"*64,"cell":"azv-aaaaaaaaaaaa","attempt":1,
 "request":{"home_binding":"sha256:"+"2"*64,"task":"task","task_generation":"gen","validation_generation":"val","fence":"sha256:"+"3"*64,"repository":{"branch":"fm/task","head":head},"credential_lease":{"lease_id":"lease"},"limits":{"behavior_shards":8}},
 "resources":{"worktree_disk_id":"/work","vm_id":"/vm","vm_instance_id":"vm-instance"},
 "expected_boot_id":"44444444-4444-4444-8444-444444444444",
}
result={
 "schema":"fm.azure-validation-result/v1","request_digest":state["request_digest"],"cell":state["cell"],"home_binding":state["request"]["home_binding"],"task":"task","task_generation":"gen","validation_generation":"val","fence":state["request"]["fence"],"branch":"fm/task","submitted_head":head,"current_head":head,"remote_head":head,"worktree_disk_id":"/work","credential_lease_id":"lease","vm_resource_id":"/vm","vm_instance_id":"vm-instance","boot_id":state["expected_boot_id"],"outcome":"checks-passed","checks_green":True,"pr_url":"https://github.com/o/r/pull/1","behavior_shards":[{"boot_id":f"boot-{i}","vm_instance_id":f"vm-{i}"} for i in range(8)]
}
json.dump({"operation":"result-identity","state":state,"result":result},open(sys.argv[1],"w"))
PY
  out=$(python3 "$HOST" pure-check --fixture "$fixture") || fail "positive result identity fixture failed"
  assert_contains "$out" '"valid": true' "exact result was not accepted"
  python3 - "$fixture" <<'PY'
import json,sys
p=sys.argv[1]; value=json.load(open(p)); value["result"]["behavior_shards"][7]["boot_id"]=value["result"]["behavior_shards"][0]["boot_id"]; json.dump(value,open(p,"w"))
PY
  rc=0
  out=$(python3 "$HOST" pure-check --fixture "$fixture" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "result accepted two shards from one boot"
  assert_contains "$out" "independent Azure machines" "shared-boot result refusal was not explicit"
  python3 - "$fixture" <<'PY'
import json,sys
p=sys.argv[1]; value=json.load(open(p)); state=value["state"]
state["phase"]="failed-retained"; state["resources"]["identities"]={"worktree":{"id":"/work","etag":"etag"}}; state["run_id"]="01AAAAAAAAAAAAAAAAAAAAAAAA"
value={"operation":"replacement","state":state,"vm_presence":"absent-proven","worktree_identity":{"id":"/work","etag":"etag"},"remote_head":state["request"]["repository"]["head"]}
json.dump(value,open(p,"w"))
PY
  out=$(python3 "$HOST" pure-check --fixture "$fixture") || fail "positive replacement fixture failed"
  assert_contains "$out" '"allowed": true' "exact replacement was not admitted"
  python3 - "$fixture" <<'PY'
import json,sys
p=sys.argv[1]; value=json.load(open(p)); value["vm_presence"]="missing-unproven"; json.dump(value,open(p,"w"))
PY
  out=$(python3 "$HOST" pure-check --fixture "$fixture") || fail "negative replacement fixture command failed"
  assert_contains "$out" '"allowed": false' "missing VM alone authorized a duplicate"
  assert_contains "$out" "absence is not proven" "replacement refusal did not name absence proof"
  pass "exact result, eight-machine isolation, wrong-boot refusal, and replacement fencing preserve run identity"
}

operator_documentation_contract() {
  for text in \
    'queue depth' \
    'worker-hour' \
    'No behavior test process runs in the credentialed cell or on the Mac.' \
    'No Azure resource was created while implementing this feature.' \
    'Run a real no-mistakes pipeline through review, test' \
    'actual cost' \
    'idle VM count is zero' \
    'Remote Herdr is not part of this path.'; do
    assert_grep "$text" "$DOC" "operator documentation is missing: $text"
  done
  pass "operator documentation records queue, cost, failure, recovery, eight-shard, scale-zero, and real acceptance contracts"
}

static_contract
submit_contract
security_negative_contract
admission_contract
identity_and_recovery_contract
operator_documentation_contract
