#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Regression coverage for the declarative Azure pilot safety and mutation gates.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-azure-pilot.sh"
TEMPLATE="$ROOT/docs/azure-pilot/main.json"
DOC="$ROOT/docs/azure-pilot.md"

run_static_template_checks() {
  if ! python3 - "$TEMPLATE" <<'PY'
import json
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
text = path.read_text(encoding="utf-8")
lower = text.lower()

assert data["parameters"]["capacityProfile"]["defaultValue"] == "foundation"
assert data["parameters"]["authorCapacityMode"]["defaultValue"] == "mixed-current"
assert data["parameters"]["vmFamily"]["defaultValue"] == "Dasv6"
assert data["parameters"]["workerSlots"]["defaultValue"] == []
assert data["parameters"]["workerSkus"]["defaultValue"] == []
assert data["parameters"]["incrementalWorkerDeploy"]["defaultValue"] is False
assert "incrementalWorkerDeploy" in data["variables"]["capacityMatches"]
assert "equals(length(parameters('workerSlots')), 1)" in data["variables"]["capacityMatches"]
assert data["parameters"]["requiredRegionalFreeVcpus"]["defaultValue"] == 128
assert data["parameters"]["requiredAuthorFamilyFreeVcpus"]["defaultValue"] == 96
assert data["parameters"]["reservedLandingVcpus"]["defaultValue"] == 62
assert data["parameters"]["commissioningBudgetCeilingUsd"]["defaultValue"] == 1500
assert data["parameters"]["steadyStateBudgetTargetUsd"]["defaultValue"] == 1000
assert data["parameters"]["runnerValidationSku"]["defaultValue"] == "Standard_E8as_v6"

# No private identifiers or notification values may be committed.
assert "defaultValue" not in json.dumps(data["parameters"]["tenantId"])
assert "defaultValue" not in json.dumps(data["parameters"]["subscriptionId"])
assert "defaultValue" not in json.dumps(data["parameters"]["administratorNotificationEmail"])
assert "adminSshPublicKey" not in data["parameters"]
assert not re.search(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", text)
assert "stfm7c799deus01" not in lower
assert "kv-fm-7c799d-eus" not in lower
assert "customdata" not in lower
assert "0.0.0.0/0" not in text
assert "spot" not in lower

nested = next(resource for resource in data["resources"] if resource["type"] == "Microsoft.Resources/deployments")
resources = nested["properties"]["template"]["resources"]

nics = [resource for resource in resources if resource["type"] == "Microsoft.Network/networkInterfaces"]
assert nics
for nic in nics:
    serialized = json.dumps(nic["properties"]).lower()
    assert "publicipaddress" not in serialized

nsgs = [resource for resource in resources if resource["type"] == "Microsoft.Network/networkSecurityGroups"]
assert nsgs
for nsg in nsgs:
    for rule in nsg["properties"]["securityRules"]:
        props = rule["properties"]
        if props["direction"] == "Inbound" and props["sourceAddressPrefix"] in ("Internet", "*"):
            assert props["access"] == "Deny"

storage = next(resource for resource in resources if resource["type"] == "Microsoft.Storage/storageAccounts")
props = storage["properties"]
assert props["allowBlobPublicAccess"] is False
assert props["allowSharedKeyAccess"] is False
assert props["supportsHttpsTrafficOnly"] is True
assert props["publicNetworkAccess"] == "Disabled"

vms = [resource for resource in resources if resource["type"] == "Microsoft.Compute/virtualMachines"]
assert len(vms) == 2  # supervisor plus one copied worker declaration
for vm in vms:
    security = vm["properties"]["securityProfile"]
    assert security["securityType"] == "TrustedLaunch"
    assert security["uefiSettings"]["secureBootEnabled"] is True
    assert security["uefiSettings"]["vTpmEnabled"] is True
    assert security["encryptionAtHost"] is True
    os_profile = vm["properties"].get("osProfile", {})
    assert "customData" not in os_profile
    assert "ssh" not in os_profile["linuxConfiguration"]
    for disk in vm["properties"]["storageProfile"]["dataDisks"]:
        assert disk["deleteOption"] == "Detach"

worker_vm = next(vm for vm in vms if "workerVms" == vm.get("copy", {}).get("name"))
assert worker_vm["properties"]["hardwareProfile"]["vmSize"] == "[parameters('workerSkus')[copyIndex()]]"
worker_tags = worker_vm["tags"]
for marker in ("one-task-scoped-crewmate", "secondmate-placement", "home-binding", "task-binding", "invocation-binding", "snapshot-digest", "cost-attribution"):
    assert marker in worker_tags

# Separate landing seams exist without always-on validation/review/browser VMs.
for marker in ("snet-validation", "snet-validation-shards", "snet-policy-review", "snet-crosscheck-tools", "snet-networkless-verifier", "validation-evidence", "validation-shards", "crosscheck-evidence", "networkless-verifier"):
    assert marker in text
assert all("validation" not in vm["name"].lower() and "review" not in vm["name"].lower() and "browser" not in vm["name"].lower() for vm in vms)

vnet = next(resource for resource in resources if resource["type"] == "Microsoft.Network/virtualNetworks")
verifier_subnet = next(subnet for subnet in vnet["properties"]["subnets"] if subnet["name"] == "snet-networkless-verifier")
assert "verifierNsgName" in verifier_subnet["properties"]["networkSecurityGroup"]["id"]
assert "natGateway" not in verifier_subnet["properties"]
assert verifier_subnet["properties"]["defaultOutboundAccess"] is False
verifier_nsg = next(resource for resource in nsgs if "verifierNsgName" in resource["name"])
verifier_rules = verifier_nsg["properties"]["securityRules"]
assert any(rule["name"] == "deny-all-outbound" and rule["properties"]["direction"] == "Outbound" and rule["properties"]["access"] == "Deny" and rule["properties"]["destinationAddressPrefix"] == "*" for rule in verifier_rules)

alerts = [resource for resource in resources if resource["type"] == "Microsoft.Insights/scheduledQueryRules"]
worker_alert = next(alert for alert in alerts if "worker-heartbeat" in alert["name"])
worker_criterion = worker_alert["properties"]["criteria"]["allOf"][0]
assert "workerCount" in worker_alert["condition"]
assert worker_criterion["operator"] == "LessThan"
assert "workerCount" in worker_criterion["threshold"]
assert "ago(" not in worker_criterion["query"]
sync_alert = next(alert for alert in alerts if "sync-age" in alert["name"])
sync_criterion = sync_alert["properties"]["criteria"]["allOf"][0]
assert sync_criterion["query"] == "FMStateSync_CL"
assert sync_criterion["operator"] == "LessThan"
assert sync_criterion["threshold"] == 1
PY
  then
    fail "Azure template static invariants failed"
  fi
  pass "Azure template preserves capacity, secret, network, storage, compute, and topology invariants"
}

run_explicit_mutation_gate_checks() {
  local tmp fakebin output status sub tenant wrong
  tmp=$(mktemp -d)
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  cat >"$fakebin/az" <<'SH'
#!/usr/bin/env bash
echo "az must not run before explicit local gates" >&2
exit 99
SH
  chmod +x "$fakebin/az"
  sub=$(python3 -c 'import uuid; print(uuid.uuid4())')
  tenant=$(python3 -c 'import uuid; print(uuid.uuid4())')
  wrong=$(python3 -c 'import uuid; print(uuid.uuid4())')

  run_gated() {
    env \
      PATH="$fakebin:$PATH" \
      FM_AZURE_TENANT_ID="$tenant" \
      FM_AZURE_SUBSCRIPTION_ID="$sub" \
      FM_AZURE_ADMIN_EMAIL=private-notification \
      FM_AZURE_ADMIN_USERNAME=privateadmin \
      FM_AZURE_OWNER_TAG=owner \
      FM_AZURE_NAMING_PREFIX=fmtest \
      FM_AZURE_STORAGE_NAME=fmteststorage0001 \
      FM_AZURE_KEY_VAULT_NAME=fm-test-vault-001 \
      FM_AZURE_DEPLOYMENT_GENERATION=test-generation \
      FM_AZURE_BUDGET_START_DATE=2026-08-01 \
      "$SCRIPT" "$@"
  }

  set +e
  output=$(run_gated apply 2>&1)
  status=$?
  set -e
  [ "$status" -eq 2 ] || fail "apply without explicit confirmation returned $status"
  assert_contains "$output" "--confirm-apply is required" "apply did not require its explicit flag"
  assert_not_contains "$output" "az must not run" "apply touched Azure before explicit confirmation"

  set +e
  output=$(run_gated apply --confirm-apply --confirm-subscription "$wrong" 2>&1)
  status=$?
  set -e
  [ "$status" -eq 2 ] || fail "apply with the wrong subscription confirmation returned $status"
  assert_contains "$output" "does not exactly match" "apply did not bind the exact subscription"
  assert_not_contains "$output" "az must not run" "apply touched Azure before exact-subscription confirmation"

  set +e
  output=$(run_gated destroy --confirm-subscription "$sub" 2>&1)
  status=$?
  set -e
  [ "$status" -eq 2 ] || fail "destroy without explicit confirmation returned $status"
  assert_contains "$output" "--confirm-destroy is required" "destroy did not require its explicit flag"
  assert_not_contains "$output" "az must not run" "destroy touched Azure before explicit confirmation"

  rm -rf "$tmp"
  pass "apply and destroy refuse before Azure without explicit flags and exact scope confirmation"
}

run_safe_cleanup_order_check() {
  python3 - "$SCRIPT" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
destroy = text.split("run_destroy() {", 1)[1].split("\n}\n\ncase ", 1)[0]
steps = [
    'az vm deallocate',
    'az vm delete',
    'az lock delete',
    'az disk delete',
    'az group delete',
]
positions = [destroy.index(step) for step in steps]
assert positions == sorted(positions), positions
assert '--state-export-confirmed' in destroy
assert '--provider-sessions-revoked' in destroy
assert '--confirm-delete-retained-disks' in destroy
PY
  pass "destroy cleanup order quiesces compute and protects retained state before group deletion"
}

write_sourceable_script() {
  python3 - "$SCRIPT" "$1" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
assert "XXXXXX.json" not in text
marker = '\ncase "$COMMAND" in\n'
assert marker in text
Path(sys.argv[2]).write_text(text.split(marker, 1)[0] + "\n", encoding="utf-8")
PY
}

run_worker_create_plan_gate_check() {
  local sourceable output status
  sourceable=$(mktemp)
  write_sourceable_script "$sourceable"
  set +e
  # Assignments below intentionally stay inside the isolated runtime-test subshell.
  # shellcheck disable=SC2030
  output=$(
    (
      set --
      # shellcheck source=bin/fm-azure-pilot.sh
      . "$sourceable"
      export FM_AZURE_TENANT_ID FM_AZURE_SUBSCRIPTION_ID FM_AZURE_ADMIN_EMAIL
      export FM_AZURE_ADMIN_USERNAME FM_AZURE_OWNER_TAG FM_AZURE_NAMING_PREFIX
      export FM_AZURE_STORAGE_NAME FM_AZURE_KEY_VAULT_NAME FM_AZURE_DEPLOYMENT_GENERATION
      export FM_AZURE_BUDGET_START_DATE FM_AZURE_CAPACITY_PROFILE FM_AZURE_AUTHOR_CAPACITY_MODE
      FM_AZURE_TENANT_ID=$(python3 -c 'import uuid; print(uuid.uuid4())')
      FM_AZURE_SUBSCRIPTION_ID=$(python3 -c 'import uuid; print(uuid.uuid4())')
      FM_AZURE_ADMIN_EMAIL=private-notification
      FM_AZURE_ADMIN_USERNAME=privateadmin
      FM_AZURE_OWNER_TAG=owner
      FM_AZURE_NAMING_PREFIX=fmtest
      FM_AZURE_STORAGE_NAME=fmteststorage0001
      FM_AZURE_KEY_VAULT_NAME=fm-test-vault-001
      FM_AZURE_DEPLOYMENT_GENERATION=test-generation
      FM_AZURE_BUDGET_START_DATE=2026-08-01
      FM_AZURE_CAPACITY_PROFILE=foundation
      FM_AZURE_AUTHOR_CAPACITY_MODE=mixed-current
      require_cloud_environment
      [ "$WORKER_SLOTS_JSON" = '[]' ]
      [ "$WORKER_SKUS_JSON" = '[]' ]
      WORKER_SLOTS_JSON='[3]'
      WORKER_SKUS_JSON='["Standard_D4as_v7"]'
      INCREMENTAL_WORKER_DEPLOY=1
      require_tool() { :; }
      local_validate() { :; }
      scope_gate() { :; }
      provider_gate() { :; }
      sku_gate() {
        [ "$WORKER_SKUS_JSON" = '["Standard_D4as_v7"]' ]
      }
      quota_gate() {
        [ "$WORKER_SLOTS_JSON" = '[3]' ]
      }
      name_gate() { :; }
      cost_gate() {
        [ "$INCREMENTAL_WORKER_DEPLOY" -eq 1 ]
      }
      live_gates >/dev/null
      make_parameters_file
      python3 - "$PARAMS_FILE" <<'PY'
import json
import sys

parameters = json.load(open(sys.argv[1], encoding="utf-8"))["parameters"]
assert parameters["workerSlots"]["value"] == [3]
assert parameters["workerSkus"]["value"] == ["Standard_D4as_v7"]
assert parameters["incrementalWorkerDeploy"]["value"] is True
assert "adminSshPublicKey" not in parameters
PY
      cleanup_parameters
    ) 2>&1
  )
  status=$?
  set -e
  rm -f "$sourceable"
  [ "$status" -eq 0 ] || fail "worker-create singleton plan was reset or rejected: $output"
  pass "worker-create executes live gates and parameters with its exact singleton plan"
}

run_destroy_inventory_failure_checks() {
  local sourceable mode call_log calls output status
  sourceable=$(mktemp)
  write_sourceable_script "$sourceable"
  for mode in vm disk; do
    call_log=$(mktemp)
    set +e
    output=$(
      (
        set --
        # shellcheck source=bin/fm-azure-pilot.sh
        . "$sourceable"
        require_tool() { :; }
        require_cloud_environment() {
          FM_AZURE_SUBSCRIPTION_ID=private-subscription
          RESOURCE_GROUP=private-resource-group
          FM_AZURE_STORAGE_NAME=private-storage
          FM_AZURE_KEY_VAULT_NAME=private-vault
        }
        require_exact_confirmation() {
          STATE_EXPORT_CONFIRMED=1
          PROVIDER_SESSIONS_REVOKED=1
          DELETE_RETAINED_DISKS=1
          CONFIRM_DELETE_RETAINED_DISKS=1
        }
        scope_gate() { :; }
        az() {
          printf '%s\n' "$*" >>"$call_log"
          if [ "$1 $2 $mode" = "vm list vm" ]; then
            return 42
          fi
          if [ "$1 $2 $mode" = "disk list disk" ]; then
            return 43
          fi
          if [ "$1 $2" = "vm list" ]; then
            printf 'worker-one\n'
          elif [ "$1 $2" = "disk list" ]; then
            printf 'disk-one\n'
          fi
        }
        run_destroy
      ) 2>&1
    )
    status=$?
    set -e
    calls=$(<"$call_log")
    rm -f "$call_log"
    [ "$status" -eq 2 ] || fail "destroy did not refuse a failed $mode inventory (status $status): $output"
    assert_not_contains "$calls" "vm deallocate" "destroy mutated compute after a failed $mode inventory"
    assert_not_contains "$calls" "lock delete" "destroy removed locks after a failed $mode inventory"
    assert_not_contains "$calls" "disk delete" "destroy deleted disks after a failed $mode inventory"
    assert_not_contains "$calls" "group delete" "destroy deleted the resource group after a failed $mode inventory"
  done
  rm -f "$sourceable"
  pass "destroy preflights VM and retained-disk inventories before every mutation"
}

run_documentation_contract_checks() {
  assert_grep 'https://portal.azure.com' "$DOC" "portal-only quota fallback URL is missing"
  assert_grep 'InvalidSupportPlan' "$DOC" "support API blocker is missing"
  assert_grep 'Herdr is the required primary' "$DOC" "Herdr primary boundary is missing"
  assert_grep 'tmux exists only as a recovery fallback' "$DOC" "tmux recovery-only boundary is missing"
  assert_grep 'downloaded self-contained form artifact' "$DOC" "Lavish file contract is missing"
  assert_grep 'complete Azure no-mistakes run' "$DOC" "isolated no-mistakes acceptance gate is missing"
  assert_grep 'policy-grade Azure Crosscheck' "$DOC" "isolated Crosscheck acceptance gate is missing"
  assert_no_grep 'seven-day canary' "$DOC" "superseded time-based canary remains documented"
  pass "operator documentation preserves activation, interface, review, and file-transfer contracts"
}

"$SCRIPT" local-validate >/dev/null || fail "script local validation failed"
pass "fm-azure-pilot local-validate executes"
run_static_template_checks
run_explicit_mutation_gate_checks
run_safe_cleanup_order_check
run_worker_create_plan_gate_check
run_destroy_inventory_failure_checks
run_documentation_contract_checks

echo "# fm-azure-pilot.test.sh: all assertions passed"
