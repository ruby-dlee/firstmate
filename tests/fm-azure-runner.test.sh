#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOST="$ROOT/bin/fm-azure-runner.py"
RUNNER="$ROOT/bin/fm-azure-runner.sh"
GUEST="$ROOT/bin/fm-azure-runner-guest.sh"
EXECUTOR="$ROOT/bin/fm-azure-runner-exec.py"
TEMPLATE="$ROOT/docs/azure-runner/invocation.json"
SUB=11111111-1111-4111-8111-111111111111
TENANT=22222222-2222-4222-8222-222222222222
PE_GUID=33333333-3333-4333-8333-333333333333

make_repo() {
  local path=$1
  mkdir -p "$path/tools/agent-fleet" "$path/declared"
  git -C "$path" init -q -b topic
  git -C "$path" config user.name fixture
  git -C "$path" config user.email fixture@example.invalid
  cp "$ROOT/tools/agent-fleet/uv.lock" "$path/tools/agent-fleet/uv.lock"
  printf 'locked\n' >"$path/declared/dependency.lock"
  git -C "$path" remote add origin https://github.com/Ruby-Labs/cloud-host-owner.git
  git -C "$path" add . && git -C "$path" commit -qm initial
}

runner() {
  local home=$1; shift
  env FM_HOME="$home" FM_AZURE_TENANT_ID="$TENANT" FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_NAMING_PREFIX=fmtest FM_AZURE_STORAGE_NAME=fmteststorage0001 FM_AZURE_OWNER_TAG=owner \
    FM_AZURE_DEPLOYMENT_GENERATION=gen-one FM_AZURE_BLOB_PE_NIC_RESOURCE_GUID="$PE_GUID" "$RUNNER" "$@"
}

static_private_controller_contract() {
  python3 - "$TEMPLATE" "$HOST" "$GUEST" <<'PY' || fail "private controller static contract failed"
import json, pathlib, sys
template=json.loads(pathlib.Path(sys.argv[1]).read_text()); host=pathlib.Path(sys.argv[2]).read_text(); guest=pathlib.Path(sys.argv[3]).read_text()
vm=next(r for r in template["resources"] if r["type"]=="Microsoft.Compute/virtualMachines")
nic=next(r for r in template["resources"] if r["type"]=="Microsoft.Network/networkInterfaces")
assert template["parameters"]["controllerIdentityId"]["type"] == "string"
assert vm["identity"]["type"] == "UserAssigned"
assert "controllerIdentityId" in json.dumps(vm["identity"])
assert "publicipaddress" not in json.dumps(nic).lower()
assert "ssh" not in json.dumps(vm["properties"]["osProfile"]).lower()
assert "customdata" not in json.dumps(template).lower()
for value in ("PrivateNetwork=yes","RestrictAddressFamilies=AF_UNIX","IPAddressDeny=any","CapabilityBoundingSet=CAP_SETUID CAP_SETGID","AmbientCapabilities=","NoNewPrivileges=yes"):
    assert value in guest
run_at=guest.index("systemd-run --quiet")
token_at=guest.index("metadata/identity/oauth2/token")
assert token_at > run_at
assert '/usr/bin/python3 "$EXECUTOR"' in guest
assert "https://files.pythonhosted.org/packages/*.whl" in guest
assert 'fetch_exact "$url"' in guest and '--location' not in guest[guest.index('while IFS=$\'\\t\' read -r url'):guest.index('done <"$BASE/wheels.tsv"')]
assert "protectedParameters" not in host
assert "generate-sas" not in host
assert "controller_identity_client_id" in host
assert "If-Match=" in host and "runner-cost-reservation" in host
assert "bootstrapadmission" in host and "BOOTSTRAP_ADMISSION_MAX_AGE_SECONDS" in host
assert host.index("lease.renew_and_assert()", host.index("def dispatch_prepared")) < host.index("create_vm(env, state)", host.index("def dispatch_prepared"))
cleanup=host[host.index("def cleanup(env, state):"):host.index("def dispatch_prepared")]
assert cleanup.index('"run-command-execute"') < cleanup.index('if "vm" in by_key') < cleanup.index('"ttl-schedule" in by_key')
PY
  pass "private controller has exact UAMI, no public ingress/SAS, isolated command, trusted post-command uploader, and safe cleanup order"
}

prepare_contract() {
  python3 - "$HOST" <<'PY'
import importlib.util, pathlib, types, sys
spec=importlib.util.spec_from_file_location("runner",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
remote="https://github.com/Ruby-Labs/cloud-host-owner.git"; head="a"*40; candidate="b"*40; tree="c"*40
class Result:
    def __init__(self,stdout="",returncode=0): self.stdout=stdout; self.returncode=returncode
calls=[]
def public_git(_repo,*args,check=True):
    calls.append(args)
    if args[:2]==("init","--bare"): return Result()
    if args[:2]==("ls-remote","--symref"): return Result("ref: refs/heads/main\tHEAD\n{}\tHEAD\n".format(head))
    if args[:1]==("ls-remote",): return Result("{}\trefs/heads/main\n".format(head))
    if args[:1]==("fetch",): return Result()
    if args[:2]==("rev-parse","--verify"): return Result(head+"\n")
    if args[:2]==("merge-base","--is-ancestor"): return Result(returncode=1)
    raise AssertionError(args)
m.public_git=public_git
try: m.public_origin_proof(pathlib.Path("/repo"),remote,candidate)
except m.RunnerError as exc: assert "not reachable" in str(exc)
else: raise AssertionError("unmerged branch accepted")
assert ("fetch","--no-tags","--force",remote,"+refs/heads/main:refs/fm-azure-runner/public-main") in calls
# A stale tracking ref is irrelevant; proof uses fresh advertisement/fetch.
assert not any("origin/main" in part for call in calls for part in call)
PY
  pass "prepare binds freshly fetched public main and rejects a clean attached unmerged branch"
}

executor_credential_adversary() {
  local tmp repo request output uid gid
  fm_test_tmproot_into tmp fm-azure-exec-adversary
  repo="$tmp/repo"; make_repo "$repo"; request="$tmp/request.json"; output="$tmp/output"; uid=$(id -u); gid=$(id -g)
  python3 - "$request" <<'PY'
import hashlib,json,sys
command={"argv":["python3","-c","import os,pathlib; forbidden=[k for k in os.environ if any(x in k for x in ('TOKEN','SAS','SECRET','CREDENTIAL','CLIENT_ID','SUBSCRIPTION','TENANT'))]; targets=[]\nfor p in pathlib.Path('/dev/fd').iterdir():\n try: targets.append(os.readlink(p))\n except OSError: pass\nraise SystemExit(0 if not forbidden and not any(any(x in t.lower() for x in ('token','sas','credential','secret')) for t in targets) else 91)"]}
r={"invocation":"azr-aaaaaaaaaaaa","attempt":1,"fence":"sha256:"+"1"*64,"repository":{"snapshot_digest":"sha256:"+"2"*64,"commit":"a"*40,"tree":"b"*40},"command":command,"limits":{"cpu_cores":1,"memory_bytes":2**30,"pid_max":64,"disk_bytes":2**30,"log_bytes":1024,"artifact_bytes":0,"network_bytes":0,"wall_seconds":10}}
canon=lambda v:json.dumps(v,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode(); r["command_digest"]="sha256:"+hashlib.sha256(canon(command)).hexdigest(); r["request_digest"]="sha256:"+hashlib.sha256(canon(r)).hexdigest(); open(sys.argv[1],"wb").write(canon(r)+b"\n")
PY
  printf '44444444-4444-4444-8444-444444444444\n' >"$tmp/boot"
  env AZURE_CLIENT_SECRET=must-not-pass FM_AZURE_RUNNER_TEST_NO_DROP=1 FM_AZURE_RUNNER_BOOT_ID_PATH="$tmp/boot" \
    /usr/bin/python3 "$EXECUTOR" "$request" "$repo" "$output" "$uid" "$gid" /vm/id vm-instance >/dev/null || \
    fail "credential adversary escaped sanitized executor"
  [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["exit_code"])' "$output/result.json")" = 0 ] || fail "credential/fd adversary observed inherited authority"
  pass "repository command receives no Azure/token/SAS/secret environment or inherited credential descriptor"
}

linux_systemd_drop_integration() {
  [ "$(uname -s)" = Linux ] || { pass "Linux systemd uid/capability integration is CI-owned"; return; }
  if ! command -v systemd-run >/dev/null || ! sudo -n true >/dev/null 2>&1; then
    fail "Linux systemd integration requires passwordless sudo"
  fi
  local tmp repo controller_base work_base request output uid gid tracked_digest staged_digest systemd_rc
  fm_test_tmproot_into tmp fm-azure-systemd-drop
  repo="$tmp/repo"; make_repo "$repo"
  controller_base=$(sudo -n mktemp -d /var/lib/fm-azure-runner-test.XXXXXXXX)
  work_base=$(sudo -n mktemp -d /var/lib/fm-azure-runner-work.XXXXXXXX)
  request="$controller_base/request.json"; output="$controller_base/output"
  uid=$(id -u nobody); gid=$(id -g nobody)
  sudo -n install -d -m 0700 -o root -g root "$controller_base"
  sudo -n chmod 0755 "$work_base"
  sudo -n install -d -m 0755 -o "$uid" -g "$gid" "$work_base/repo"
  sudo -n cp -R "$repo/." "$work_base/repo/"
  sudo -n chown -R "$uid:$gid" "$work_base/repo"
  sudo -n install -m 0600 -o root -g root "$EXECUTOR" "$controller_base/runner-exec.py"
  tracked_digest=$(sha256sum "$EXECUTOR" | awk '{print $1}')
  staged_digest=$(sudo -n sha256sum "$controller_base/runner-exec.py" | awk '{print $1}')
  [ "$tracked_digest" = "$staged_digest" ] || fail "root-staged executor digest differs from tracked executor"
  python3 - "$tmp/request.json" "$uid" "$gid" <<'PY'
import hashlib,json,sys
uid=int(sys.argv[2]); gid=int(sys.argv[3])
code="""import os,pathlib
s={}
for line in pathlib.Path('/proc/self/status').read_text().splitlines():
    if ':' in line:
        k,v=line.split(':',1); s[k]=v.strip()
assert os.getuid()==%d and os.getgid()==%d and os.getgroups()==[]
assert all(int(s[k],16)==0 for k in ('CapEff','CapPrm','CapAmb'))
assert s['NoNewPrivs']=='1'
"""%(uid,gid)
command={"argv":["python3","-c",code]}
r={"invocation":"azr-aaaaaaaaaaaa","attempt":1,"fence":"sha256:"+"1"*64,"repository":{"snapshot_digest":"sha256:"+"2"*64,"commit":"a"*40,"tree":"b"*40},"command":command,"limits":{"cpu_cores":1,"memory_bytes":2**30,"pid_max":64,"disk_bytes":2**30,"log_bytes":1024,"artifact_bytes":0,"network_bytes":0,"wall_seconds":10}}
canon=lambda v:json.dumps(v,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode(); r["command_digest"]="sha256:"+hashlib.sha256(canon(command)).hexdigest(); r["request_digest"]="sha256:"+hashlib.sha256(canon(r)).hexdigest(); open(sys.argv[1],"wb").write(canon(r)+b"\n")
PY
  printf '44444444-4444-4444-8444-444444444444\n' >"$tmp/boot"
  sudo -n install -m 0600 -o root -g root "$tmp/request.json" "$request"
  sudo -n install -m 0600 -o root -g root "$tmp/boot" "$controller_base/boot"
  chmod 0755 "$tmp" "$repo"
  # The broker intentionally lacks CAP_DAC_OVERRIDE. Pinned Python reads the
  # staged executor and request as root inside the root-traversable BASE; only
  # the child needs access to the repository and its already-open log pipes.
  systemd_rc=0
  sudo -n systemd-run --quiet --wait --collect --pipe \
    --property=NoNewPrivileges=yes --property=PrivateNetwork=yes --property=RestrictAddressFamilies=AF_UNIX \
    --property=IPAddressDeny=any --property='CapabilityBoundingSet=CAP_SETUID CAP_SETGID' \
    --property=AmbientCapabilities= --property=RestrictSUIDSGID=yes \
    env FM_AZURE_RUNNER_BOOT_ID_PATH="$controller_base/boot" /usr/bin/python3 "$controller_base/runner-exec.py" \
    "$request" "$work_base/repo" "$output" "$uid" "$gid" /vm/id vm-instance >/dev/null || systemd_rc=$?
  [ "$systemd_rc" -eq 0 ] && \
    [ "$(sudo python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["exit_code"])' "$output/result.json")" = 0 ] || \
    systemd_rc=1
  sudo -n find "$controller_base" -xdev -mindepth 1 -delete
  sudo -n rmdir "$controller_base"
  sudo -n find "$work_base" -xdev -mindepth 1 -delete
  sudo -n rmdir "$work_base"
  [ "$systemd_rc" -eq 0 ] || fail "actual Linux/systemd broker could not run the secured child"
  pass "actual Linux/systemd broker drops uid/gid/groups and repository child has empty capabilities/no-new-privileges/networkless"
}

management_fencing_unit() {
  python3 - "$HOST" <<'PY'
import datetime as dt, importlib.util, sys
spec=importlib.util.spec_from_file_location("runner",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
env={"subscription":"sub","resource_group":"rg","control_storage":"stctl","deployment_generation":"gen","state_dir":__import__('pathlib').Path('/tmp'),"azure_operation_count":0}
state={"invocation":"azr-aaaaaaaaaaaa","request":{"fence":"sha256:"+"a"*64}}
metadata={"schema":"fm-azure-runner-control-v1","deploymentgeneration":"gen","lockowner":"","lockfence":"","lockexpiry":"","bootstrapadmission":"consumed","bootstrapinvocation":"azr-cccccccccccc","bootstrapfence":"c"*64,"bootstrapat":"2026-08-12T00:00:00Z","bootstrapcorrelation":"11111111-1111-4111-8111-111111111111","bootstraptemplatehash":"123","bootstrapbudgetid":"/subscriptions/sub/providers/Microsoft.Consumption/budgets/bud-prefix-monthly","bootstrapbudgetetag":"E","bootstrapbudgetspendmicrousd":"0","bootstrapfoundationstartedat":"2026-08-12T00:00:00Z"}; etag=['E1']
def az(_env,args,**kwargs):
    if args[:2]==["resource","show"]: return {"etag":etag[0],"properties":{"metadata":dict(metadata)}},0,""
    if args[:2]==["rest","--method"]:
        header=next(x for x in args if x.startswith("If-Match="))
        if header != "If-Match="+etag[0]: return None,1,"412"
        body=__import__('json').loads(args[args.index("--body")+1]); metadata.clear(); metadata.update(body["properties"]["metadata"]); etag[0]="E"+str(int(etag[0][1:])+1); return {"etag":etag[0]},0,""
    raise AssertionError(args)
m.az_command=az; m.time.sleep=lambda _:None
a=m.ManagementAdmissionLease(env,state); a.__enter__()
assert metadata["bootstrapinvocation"]=="azr-cccccccccccc"
metadata.update({"lockowner":"azr-bbbbbbbbbbbb","lockfence":"b"*64,"lockexpiry":m.iso_utc(m.now_utc()+dt.timedelta(seconds=60))}); etag[0]="E99"
try: a.renew_and_assert()
except m.RunnerError: pass
else: raise AssertionError("stale writer renewed successor lock")
assert a.failed.is_set()
# A hung/throwing renewal is sticky and admission cannot locally outlive it.
b=m.ManagementAdmissionLease(env,state); b.expires_at=m.time.monotonic()+1
b._read=lambda: (_ for _ in ()).throw(m.RunnerError("timeout"))
try: b.renew_and_assert()
except m.RunnerError: pass
else: raise AssertionError("timeout renewal passed")
assert b.failed.is_set()
try: b.assert_held()
except m.RunnerError: pass
else: raise AssertionError("failed renewal was forgotten")
PY
  pass "management ETag CAS rejects stale successor clobber and a hung renewal permanently closes admission"
}

effective_rbac_adversaries() {
  python3 - "$HOST" <<'PY'
import importlib.util, sys
spec=importlib.util.spec_from_file_location("runner",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
env={"subscription":"sub","resource_group":"rg","prefix":"prefix"}
seen=[]
def az(_env,args,**kwargs):
    seen.append(args)
    return ([{"scope":"/subscriptions/sub","roleDefinitionId":"/role/owner","principalId":"group"}],0,"")
m.az_command=az
for label in ("direct","parent inherited","group derived"):
    try: m.require_zero_effective_rbac(env,"principal",label)
    except m.RunnerError: pass
    else: raise AssertionError(label+" assignment accepted")
assert all("--include-inherited" in args and "--include-groups" in args and "--all" in args for args in seen)
m.az_command=lambda *_a,**_k: ({"not":"a list"},0,"")
try: m.require_zero_effective_rbac(env,"principal","unreadable")
except m.RunnerError: pass
else: raise AssertionError("unreadable effective RBAC accepted")
reservation_id="/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-prefix-rsv-aaaaaaaaaaaa"
identity={"id":reservation_id,"location":"eastus","etag":"E","properties":{"principalId":"p"},"tags":{"workload":"firstmate","firstmate-role":"runner-cost-reservation","deployment-generation":"gen","cleanup-owner":"owner","invocation-binding":"azr-aaaaaaaaaaaa","fence-digest":"a"*64,"lineage-root":"azr-aaaaaaaaaaaa","parent-invocation":"none","amount-microusd":"1","reserved-at":"2026-01-01T00:00:00Z","compute-deadline":"2026-01-02T00:00:00Z","cleanup-verified-at":"none","reservation-principal":"p"}}
env.update({"deployment_generation":"gen","owner":"owner"})
calls=[]
def reservation_az(_env,args,**kwargs):
    calls.append(args)
    if args[:2]==["identity","list"]: return ([identity],0,"")
    if args[:2]==["resource","show"]: return (identity,0,"")
    if args[:3]==["role","assignment","list"]: return ([{"scope":"/subscriptions/sub"}],0,"")
    raise AssertionError(args)
m.az_command=reservation_az
try: m.list_management_reservations(env)
except m.RunnerError: pass
else: raise AssertionError("authorized reservation principal accepted")
assert any(args[:3]==["role","assignment","list"] for args in calls)
m.az_command=lambda *_a,**_k: ([{"identity":{"userAssignedIdentities":{"/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-prefix-rsv-aaaaaaaaaaaa":{}}},"tags":{},"powerState":"VM running"}],0,"")
try: m.active_runner_vms(env)
except m.RunnerError: pass
else: raise AssertionError("VM-attached reservation identity accepted")
PY
  pass "direct, inherited, group, unreadable, replacement, and VM-attached reservation RBAC adversaries refuse"
}

cost_retry_unit() {
  python3 - "$HOST" <<'PY'
import datetime as dt, email.message, importlib.util, io, json, pathlib, tempfile, types, urllib.error, sys
spec=importlib.util.spec_from_file_location("runner",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
env={"subscription":"sub","resource_group":"rg","state_dir":pathlib.Path(tempfile.mkdtemp()),"azure_operation_count":0,"home_binding":"sha256:"+"a"*64,"deployment_generation":"gen"}
m.record_azure_operation=lambda *_:None; m.run=lambda *a,**k:types.SimpleNamespace(stdout="token\n")
headers=email.message.Message(); headers["x-ms-ratelimit-microsoft.costmanagement-qpu-retry-after"]="2"
throttle=urllib.error.HTTPError("https://management.azure.com/x",429,"throttle",headers,io.BytesIO())
class Response:
    headers={"Date":__import__('email').utils.format_datetime(m.now_utc())}
    def __enter__(self): return self
    def __exit__(self,*_): pass
    def read(self): return b'{"properties":{"columns":[],"rows":[]}}'
calls=[throttle,Response()]; sleeps=[]
def urlopen(*_a,**_k):
    item=calls.pop(0)
    if isinstance(item,Exception): raise item
    return item
m.urllib.request.urlopen=urlopen; m.time.sleep=lambda seconds:sleeps.append(seconds)
result=m.cost_http_query(env,"query","https://management.azure.com/x",{"type":"Usage"})
assert result["properties"]["rows"]==[] and sleeps==[2]
# Only exact body/endpoint bindings can read the authoritative success cache.
body=m.canonical_bytes({"type":"Usage"}); digest="sha256:"+m.sha256_bytes(body); key=m.sha256_bytes(("query\0https://management.azure.com/x\0"+digest).encode())
assert m.load_cost_cache(env,key,"query",digest) is not None
assert m.load_cost_cache(env,key,"forecast",digest) is None
assert m.COST_RETRY_DEADLINE_SECONDS==900 and m.COST_CACHE_MAX_AGE_SECONDS==14400
# Only the exact new-scope forecast failure is bootstrap-classified.
empty=urllib.error.HTTPError("https://management.azure.com/x",424,"failed dependency",email.message.Message(),io.BytesIO(b'{"error":{"code":"FailedDependency","message":"Can\\u0027t do forecast - cost training data is empty"}}'))
m.urllib.request.urlopen=lambda *_a,**_k: (_ for _ in ()).throw(empty)
try: m.cost_http_query(env,"forecast","https://management.azure.com/x",{"type":"Usage"})
except m.CostAdmissionUnavailable as exc: assert exc.reason=="forecast-empty-training"
else: raise AssertionError("empty-training forecast failure was not classified")
other=urllib.error.HTTPError("https://management.azure.com/x",424,"failed dependency",email.message.Message(),io.BytesIO(b'{"error":{"code":"FailedDependency","message":"other"}}'))
m.urllib.request.urlopen=lambda *_a,**_k: (_ for _ in ()).throw(other)
try: m.cost_http_query(env,"forecast","https://management.azure.com/x",{"type":"Usage"})
except m.RunnerError as exc: assert not isinstance(exc,m.CostAdmissionUnavailable)
else: raise AssertionError("non-specific Cost Management error entered bootstrap")
PY
  pass "Cost Management retry is bounded, honors both Azure guidance headers, and only permits a short exact authoritative cache"
}

bootstrap_admission_adversaries() {
  python3 - "$HOST" <<'PY' || fail "bootstrap admission adversaries failed"
import datetime as dt, importlib.util, sys
spec=importlib.util.spec_from_file_location("runner",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
env={"subscription":"sub","resource_group":"rg","control_storage":"stctl","deployment_generation":"gen","prefix":"prefix","owner":"owner","budget_limit":1500,"blob_private_endpoint_nic":"nic-prefix-pe-blob","blob_private_endpoint":"pe-prefix-blob","vnet":"vnet-prefix-eus","storage":"storage","tenant":"tenant","blob_private_endpoint_nic_resource_guid":"33333333-3333-4333-8333-333333333333"}
state={"invocation":"azr-aaaaaaaaaaaa","request":{"fence":"sha256:"+"a"*64}}
limits=dict(m.RESOURCE_CLASSES["behavior-heavy"]); limits.update({"sku":"Standard_D4as_v6","sku_family":"standardDav6Family"})
deployment={"name":"fm-azure-pilot-gen","deployed_at":m.now_utc()-dt.timedelta(hours=1),"age_seconds":3600,"correlation_id":"11111111-1111-4111-8111-111111111111","template_hash":"123","key_vault_name":"kv"}
base={"schema":"fm-azure-runner-control-v1","deploymentgeneration":"gen","lockowner":state["invocation"],"lockfence":"a"*64,"lockexpiry":m.iso_utc(m.now_utc()+dt.timedelta(seconds=60))}
class Lease:
    def __init__(self,metadata): self.metadata=metadata; self.etag="E1"; self.expires_at=0
    def _read(self): return dict(self.metadata),self.etag
    def _cas(self,_etag,new): self.metadata.clear(); self.metadata.update(new); self.etag="E2"; return self.etag
    def _record_success(self): self.expires_at=1
    def assert_held(self): pass
m.foundation_gate=lambda _env:None
real_deployment=m.exact_bootstrap_deployment
m.exact_bootstrap_deployment=lambda _env:dict(deployment)
m.exact_bootstrap_inventory=lambda _env,_deployment:deployment["deployed_at"]
m.active_runner_vms=lambda _env:[]
m.list_management_reservations=lambda _env:[]
real_budget=m.exact_bootstrap_budget
m.exact_bootstrap_budget=lambda _env:{"id":"/subscriptions/sub/providers/Microsoft.Consumption/budgets/bud-prefix-monthly","etag":"E","current_spend":0.0}
m.retail_rate=lambda _env,_sku:0.10
lease=Lease(dict(base)); unavailable=m.CostAdmissionUnavailable("forecast-empty-training","empty")
cost=m.bootstrap_admission_cost(env,state,lease,limits,unavailable)
assert cost["bootstrap_admission"] is True and cost["forecast"] is None and cost["admission_pressure"]<1500
assert cost["cost_lower_bound"]==max(cost["budget_current_spend"],cost["foundation_bound"])
assert lease.metadata["bootstrapadmission"]=="consumed" and lease.metadata["bootstrapinvocation"]==state["invocation"]
for field in ("bootstrapfence","bootstrapcorrelation","bootstraptemplatehash","bootstrapbudgetid","bootstrapbudgetetag","bootstrapbudgetspendmicrousd","bootstrapfoundationstartedat"):
    assert lease.metadata[field]
# The retained ARM marker makes every later bootstrap attempt refuse, including a concurrent stale contender.
try: m.bootstrap_admission_cost(env,state,lease,limits,unavailable)
except m.RunnerError as exc: assert "already consumed" in str(exc)
else: raise AssertionError("second bootstrap marker won")
# Old or foreign foundation, inventory drift, a VM, a reservation, and over-ceiling pressure all refuse before another marker.
def refuses(change,text):
    lease=Lease(dict(base)); restore=change()
    try: m.bootstrap_admission_cost(env,state,lease,limits,unavailable)
    except m.RunnerError as exc: assert text in str(exc),str(exc)
    else: raise AssertionError(text+" accepted")
    finally: restore()
def replace(name,value):
    old=getattr(m,name); setattr(m,name,value); return lambda:setattr(m,name,old)
refuses(lambda:replace("exact_bootstrap_deployment",lambda _env: (_ for _ in ()).throw(m.RunnerError("deployment old/foreign"))),"old/foreign")
refuses(lambda:replace("exact_bootstrap_inventory",lambda *_: (_ for _ in ()).throw(m.RunnerError("foreign resource"))),"foreign resource")
refuses(lambda:replace("exact_bootstrap_inventory",lambda *_:m.now_utc()-dt.timedelta(hours=73)),"outside the allowed window")
refuses(lambda:replace("active_runner_vms",lambda _env:[{}]),"zero active")
refuses(lambda:replace("list_management_reservations",lambda _env:[{}]),"zero outstanding")
refuses(lambda:replace("exact_bootstrap_budget",lambda _env:{"id":"/subscriptions/sub/providers/Microsoft.Consumption/budgets/bud-prefix-monthly","etag":"E","current_spend":1499.0}),"exceeds")
try: m.bootstrap_admission_cost(env,state,Lease(dict(base)),limits,m.CostAdmissionUnavailable("other","other"))
except m.RunnerError as exc: assert "not eligible" in str(exc)
else: raise AssertionError("non-specific failure entered bootstrap")
# Budget identity, amount, currency, grain, filter, currentSpend, and ETag are all mandatory.
m.exact_bootstrap_budget=real_budget
budget={"id":"/subscriptions/sub/providers/Microsoft.Consumption/budgets/bud-prefix-monthly","name":"bud-prefix-monthly","type":"Microsoft.Consumption/budgets","eTag":"E","properties":{"amount":1500.0,"timeGrain":"Monthly","filter":{"dimensions":{"name":"ResourceGroupName","operator":"In","values":["rg"]}},"currentSpend":{"amount":0,"unit":"USD"}}}
m.az_command=lambda *_a,**_k:(budget,0,"")
assert m.exact_bootstrap_budget(env)["current_spend"]==0
for field,value in (("amount",1000),("timeGrain","Annually"),("filter",{}),("currentSpend",{"amount":0,"unit":"EUR"})):
    old=budget["properties"][field]; budget["properties"][field]=value
    try: m.exact_bootstrap_budget(env)
    except m.RunnerError: pass
    else: raise AssertionError("wrong budget "+field+" accepted")
    budget["properties"][field]=old
budget.pop("eTag")
try: m.exact_bootstrap_budget(env)
except m.RunnerError: pass
else: raise AssertionError("budget without ETag accepted")
# Succeeded/fresh/correlation/template/output and reviewed main parameters are direct deployment gates.
m.exact_bootstrap_deployment=real_deployment
now=m.now_utc()
parameters={k:{"value":v} for k,v in {"tenantId":"tenant","subscriptionId":"sub","deploymentGeneration":"gen","namingPrefix":"prefix","resourceGroupName":"rg","storageAccountName":"storage","capacityProfile":"foundation","keyVaultName":"kv"}.items()}
deployment_doc={"name":"fm-azure-pilot-gen","properties":{"provisioningState":"Succeeded","timestamp":now.isoformat().replace("+00:00","Z"),"correlationId":"11111111-1111-4111-8111-111111111111","templateHash":"123","parameters":parameters,"outputs":{"capacityProfile":{"value":"foundation"},"region":{"value":"eastus"},"blobPrivateEndpointNicResourceGuid":{"value":env["blob_private_endpoint_nic_resource_guid"]}}}}
m.az_command=lambda *_a,**_k:(deployment_doc,0,"")
assert m.exact_bootstrap_deployment(env)["template_hash"]=="123"
for field,value in (("provisioningState","Failed"),("correlationId","foreign"),("templateHash","foreign")):
    old=deployment_doc["properties"][field]; deployment_doc["properties"][field]=value
    try: m.exact_bootstrap_deployment(env)
    except m.RunnerError: pass
    else: raise AssertionError("wrong deployment "+field+" accepted")
    deployment_doc["properties"][field]=old
old=parameters["storageAccountName"]["value"]; parameters["storageAccountName"]["value"]="foreign"
try: m.exact_bootstrap_deployment(env)
except m.RunnerError: pass
else: raise AssertionError("foreign deployment parameter accepted")
parameters["storageAccountName"]["value"]=old
deployment_doc["properties"]["timestamp"]=(now-dt.timedelta(hours=73)).isoformat().replace("+00:00","Z")
try: m.exact_bootstrap_deployment(env)
except m.RunnerError: pass
else: raise AssertionError("old foundation deployment accepted")
# Partial or malformed markers are never accepted by either gate or lease.
assert m.bootstrap_marker_metadata_is_exact({})
assert not m.bootstrap_marker_metadata_is_exact({"bootstrapadmission":"consumed"})
PY
  pass "one-shot bootstrap is exact, conservative, CAS-marked, and refuses old/foreign/budget/VM/reservation/concurrency/error adversaries"
}

static_private_controller_contract
prepare_contract
executor_credential_adversary
linux_systemd_drop_integration
management_fencing_unit
effective_rbac_adversaries
cost_retry_unit
bootstrap_admission_adversaries

echo "# fm-azure-runner.test.sh: all assertions passed"
