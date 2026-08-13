#!/usr/bin/env python3
"""Azure adapter for the provider-neutral elastic worker lifecycle.

The adapter accepts one bounded JSON request on stdin and prints one JSON
response. It never adopts names outside the reviewed resource group and never
mutates a resource until complete owner, generation, task, cloud-instance,
disk, account, and worktree identity matches the controller action.
"""

import contextlib
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request


ROOT = Path(__file__).resolve().parent.parent
PILOT = ROOT / "bin" / "fm-azure-pilot.sh"
LANDED_FILES = (
    "bin/fm-azure-worker-provider.py",
    "bin/fm-worker-lifecycle.py",
    "bin/fm-worker-lifecycle.sh",
    "bin/fm-azure-runner.py",
    "bin/fm-azure-pilot.sh",
    "docs/azure-pilot/main.json",
    "docs/azure-runner.md",
    "docs/azure-workers.md",
)
REQUEST_SCHEMA = "fm.worker-provider-request/v1"
RESPONSE_SCHEMA = "fm.worker-provider-response/v1"
INVENTORY_SCHEMA = "fm.worker-provider-inventory/v1"
MAX_INPUT_BYTES = 2 * 1024 * 1024
AZ_TIMEOUT_SECONDS = 300
RESOURCE_API = {
    "vm": "2024-03-01",
    "nic": "2023-09-01",
    "os-disk": "2023-10-02",
    "task-disk": "2023-10-02",
    "account-disk": "2023-10-02",
    "identity": "2023-01-31",
    "role-assignment": "2022-04-01",
}
SPECIALIZED_ROLES = {
    "validation-shard", "validation-cell", "policy-review", "browser-tool",
    "networkless-verifier", "crosscheck-tool",
}
SAFE_INVOCATION = re.compile(r"^azr-[0-9a-f]{12}(?:-a[2-9][0-9]*)?$")
RUNNER_COMMISSIONING_SKU_POOL = (
    "Standard_D4as_v7",
    "Standard_D4as_v6",
    "Standard_D4s_v6",
    "Standard_D4ads_v7",
    "Standard_D4ads_v6",
    "Standard_E4as_v7",
    "Standard_E4as_v6",
    "Standard_D4ds_v6",
)
REVIEWED_SKU_FAMILY = {
    "Standard_D4as_v6": "standardDav6Family",
    "Standard_D4as_v7": "StandardDasv7Family",
    "Standard_D4s_v6": "StandardDsv6Family",
    "Standard_D4ads_v7": "StandardDadsv7Family",
    "Standard_D4ds_v6": "StandardDdsv6Family",
    "Standard_D4s_v7": "StandardDsv7Family",
    "Standard_D4ds_v7": "StandardDdsv7Family",
    "Standard_D4ads_v6": "standardDadv6Family",
    "Standard_E4as_v7": "StandardEasv7Family",
    "Standard_E4as_v6": "standardEav6Family",
}
SKU_VCPUS = {sku: 4 for sku in REVIEWED_SKU_FAMILY}
SKU_VCPUS["Standard_D2as_v6"] = 2
SKU_PLAN = {
    1: ("Standard_D4as_v6", "standardDav6Family"),
    2: ("Standard_D4as_v6", "standardDav6Family"),
    3: ("Standard_D4as_v7", "StandardDasv7Family"),
    4: ("Standard_D4as_v7", "StandardDasv7Family"),
    5: ("Standard_D4s_v6", "StandardDsv6Family"),
    6: ("Standard_D4s_v6", "StandardDsv6Family"),
    7: ("Standard_D4ads_v7", "StandardDadsv7Family"),
    8: ("Standard_D4ads_v7", "StandardDadsv7Family"),
    9: ("Standard_D4ads_v6", "standardDadv6Family"),
    10: ("Standard_D4ads_v6", "standardDadv6Family"),
    11: ("Standard_E4as_v7", "StandardEasv7Family"),
    12: ("Standard_E4as_v7", "StandardEasv7Family"),
    13: ("Standard_E4as_v6", "standardEav6Family"),
    14: ("Standard_E4as_v6", "standardEav6Family"),
    15: ("Standard_D4ds_v6", "StandardDdsv6Family"),
    16: ("Standard_D4ds_v6", "StandardDdsv6Family"),
}
REQUIRED_RESOURCE_KINDS = (
    "vm", "nic", "os-disk", "task-disk", "account-disk", "identity",
    "role-assignment", "state-container",
)


class ProviderError(RuntimeError):
    pass


def canonical_bytes(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def iso_utc():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def run(command, check=True, input_bytes=None, timeout=AZ_TIMEOUT_SECONDS, env=None):
    try:
        result = subprocess.run(
            command, input=input_bytes, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=timeout, env=env,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ProviderError("bounded command failed or timed out: {}".format(exc))
    if check and result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()[-1000:]
        raise ProviderError("command failed ({}): {}{}".format(
            result.returncode, command[0], ": " + detail if detail else ""
        ))
    return result


def require_landed_code():
    for relative in LANDED_FILES:
        tracked = run(["git", "-C", str(ROOT), "cat-file", "-e", "HEAD:" + relative], check=False)
        unchanged = run(["git", "-C", str(ROOT), "diff", "--quiet", "HEAD", "--", relative], check=False)
        if tracked.returncode != 0 or unchanged.returncode != 0:
            raise ProviderError("Azure worker mutation requires exact committed tracked lifecycle code")
    default_ref = run([
        "git", "-C", str(ROOT), "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD",
    ], check=False)
    if default_ref.returncode != 0:
        raise ProviderError("origin default branch is unavailable for landed-code proof")
    default_name = default_ref.stdout.decode("utf-8", errors="replace").strip()
    ancestry = run([
        "git", "-C", str(ROOT), "merge-base", "--is-ancestor", "HEAD", default_name,
    ], check=False)
    if ancestry.returncode != 0:
        raise ProviderError("Azure worker mutation is allowed only from code landed on origin's default branch")


def az(controller, args, check=True):
    command = ["az"] + list(args) + [
        "--subscription", controller["subscription"], "--only-show-errors",
    ]
    if "--output" not in command and "-o" not in command:
        command += ["--output", "json"]
    result = run(command, check=check)
    stderr = result.stderr.decode("utf-8", errors="replace").strip()
    if result.returncode != 0:
        return None, result.returncode, stderr
    try:
        return json.loads(result.stdout.decode("utf-8") or "null"), 0, stderr
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProviderError("Azure CLI returned malformed JSON: {}".format(exc))


def exact_id(controller, provider, resource_type, name):
    return "/subscriptions/{}/resourceGroups/{}/providers/{}/{}/{}".format(
        controller["subscription"], controller["resource_group"], provider, resource_type, name
    )


def expected_names(controller, slot):
    token = "{:02d}".format(slot)
    prefix = controller["prefix"]
    return {
        "vm": "vm-{}-wkr-{}".format(prefix, token),
        "nic": "nic-{}-wkr-{}".format(prefix, token),
        "os-disk": "disk-{}-wkr-{}-os".format(prefix, token),
        "task-disk": "disk-{}-wkr-{}-task".format(prefix, token),
        "account-disk": "disk-{}-wkr-{}-account".format(prefix, token),
        "identity": "id-{}-wkr-{}".format(prefix, token),
        "state-container": "worker-state-{}".format(token),
    }


def action_tags(controller, action):
    bindings = action["bindings"]
    return {
        "workload": "firstmate",
        "firstmate-role": "worker",
        "deployment-generation": controller["deployment_generation"],
        "cleanup-owner": controller["owner"],
        "worker-slot": str(action["slot"]),
        "home-binding": bindings["home_binding"],
        "task-binding": bindings["task"],
        "task-generation": bindings["task_generation"],
        "assignment-generation": bindings["assignment_generation"],
        "cloud-generation": str(action["cloud_generation"]),
        "account-binding": bindings["account_binding"],
        "worktree-binding": bindings["worktree_binding"],
        "repository-binding": bindings["repository_binding"],
        "repository-generation": bindings["repository_generation"],
        "agent-capacity": "one-task-scoped-crewmate",
        "nested-team": "forbidden",
        "secondmate-placement": "forbidden",
        "browser-profile": "forbidden",
        "lifecycle": "disposable-compute-retained-data",
    }


def metadata_to_tags(metadata):
    tags = {}
    for key, value in (metadata or {}).items():
        tags[key.replace("_", "-")] = value
    return tags


def tags_to_metadata(tags):
    return {key.replace("-", "_"): str(value) for key, value in tags.items()}


def immutable_id(kind, value):
    properties = value.get("properties", value)
    if kind == "vm":
        return properties.get("vmId") or value.get("vmId")
    if kind == "nic":
        return properties.get("resourceGuid") or value.get("resourceGuid")
    if kind in ("os-disk", "task-disk", "account-disk"):
        return properties.get("uniqueId") or value.get("uniqueId")
    if kind == "identity":
        return properties.get("principalId") or value.get("principalId")
    if kind == "role-assignment":
        principal = value.get("principalId") or properties.get("principalId")
        role = value.get("roleDefinitionId") or properties.get("roleDefinitionId")
        return "{}|{}".format(principal, role) if principal and role else None
    if kind == "state-container":
        return value.get("etag") or properties.get("etag") or value.get("version")
    return None


def resource_record(kind, value, power_state=None, tags_override=None):
    resource_id = value.get("id")
    identity = immutable_id(kind, value)
    if not resource_id or not identity:
        raise ProviderError("{} immutable identity is incomplete".format(kind))
    record = {
        "id": resource_id,
        "immutable_id": identity,
        "etag": value.get("etag"),
        "tags": dict(tags_override if tags_override is not None else (value.get("tags") or {})),
    }
    if power_state is not None:
        record["power_state"] = power_state
    properties = value.get("properties", value)
    if kind == "nic":
        record["attached_to"] = (properties.get("virtualMachine") or {}).get("id")
        configs = properties.get("ipConfigurations") or value.get("ipConfigurations") or []
        for config in configs:
            config_properties = config.get("properties", config)
            if config_properties.get("publicIPAddress") or config_properties.get("publicIpAddress"):
                raise ProviderError("worker NIC has a public IP relation")
    if kind in ("os-disk", "task-disk", "account-disk"):
        record["attached_to"] = value.get("managedBy") or properties.get("managedBy")
    return record


def list_json(controller, args):
    value, rc, stderr = az(controller, args, check=False)
    if rc != 0 or not isinstance(value, list):
        raise ProviderError("Azure inventory call failed or was malformed: {}".format(stderr))
    return value


def is_exact_fleet(controller, tags):
    return (
        tags.get("workload") == "firstmate"
        and tags.get("deployment-generation") == controller["deployment_generation"]
        and tags.get("cleanup-owner") == controller["owner"]
    )


def slot_from_name(name, pattern):
    match = re.match(pattern + r"([0-9]{2})(?:-|$)", str(name))
    if not match:
        return None
    slot = int(match.group(1))
    return slot if 1 <= slot <= 16 else None


def cost_body(controller, forecast):
    today = dt.datetime.now(dt.timezone.utc).date()
    month_start = today.replace(day=1)
    if month_start.month == 12:
        month_end = month_start.replace(year=month_start.year + 1, month=1)
    else:
        month_end = month_start.replace(month=month_start.month + 1)
    body = {
        "type": "Usage",
        "timeframe": "MonthToDate",
        "dataset": {
            "granularity": "None",
            "aggregation": {"totalCost": {"name": "PreTaxCost", "function": "Sum"}},
            "filter": {
                "dimensions": {
                    "name": "ResourceGroupName", "operator": "In",
                    "values": [controller["resource_group"]],
                }
            },
        },
    }
    if forecast:
        body["timeframe"] = "Custom"
        body["timePeriod"] = {
            "from": month_start.isoformat() + "T00:00:00Z",
            "to": month_end.isoformat() + "T00:00:00Z",
        }
    return body


def cost_query(controller, forecast):
    endpoint = "forecast" if forecast else "query"
    url = "https://management.azure.com/subscriptions/{}/providers/Microsoft.CostManagement/{}?api-version=2023-11-01".format(
        controller["subscription"], endpoint
    )
    fd, name = tempfile.mkstemp(prefix="fm-worker-cost-", suffix=".json")
    os.chmod(name, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(cost_body(controller, forecast), handle, separators=(",", ":"))
        result, rc, _ = az(controller, [
            "rest", "--method", "post", "--url", url, "--body", "@" + name,
        ], check=False)
        if rc != 0 or not isinstance(result, dict):
            return None
        properties = result.get("properties", result)
        columns = properties.get("columns") or []
        rows = properties.get("rows") or []
        if not rows:
            return 0.0
        names = [item.get("name") for item in columns]
        index = names.index("PreTaxCost") if "PreTaxCost" in names else 0
        return float(rows[0][index])
    except (IndexError, TypeError, ValueError):
        return None
    finally:
        with contextlib.suppress(FileNotFoundError):
            Path(name).unlink()


def retail_rate(sku):
    query = urllib.parse.urlencode({
        "$filter": "armRegionName eq 'eastus' and armSkuName eq '{}' and priceType eq 'Consumption'".format(sku)
    })
    request = urllib.request.Request(
        "https://prices.azure.com/api/retail/prices?" + query,
        headers={"User-Agent": "firstmate-elastic-worker/1"},
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            data = json.load(response)
    except Exception:
        return None
    prices = []
    for item in data.get("Items", []):
        product = str(item.get("productName", "")).lower()
        meter = str(item.get("meterName", "")).lower()
        if item.get("unitOfMeasure") != "1 Hour" or "windows" in product or "spot" in meter:
            continue
        with contextlib.suppress(TypeError, ValueError):
            prices.append(float(item["retailPrice"]))
    return min(prices) if prices else None


def specialized_capacity_inventory(controller, vms, identities):
    active = {}
    active_by_family = {}
    for vm in vms:
        tags = vm.get("tags") or {}
        if tags.get("firstmate-role") not in SPECIALIZED_ROLES:
            continue
        invocation = tags.get("invocation-binding", "")
        # The permanent validation-shards controller identity shares the role
        # tag but has no invocation binding and is not disposable capacity.
        if not invocation:
            continue
        if not is_exact_fleet(controller, tags):
            raise ProviderError("specialized VM has foreign owner or deployment generation")
        sku = tags.get("selected-sku") or (vm.get("hardwareProfile") or {}).get("vmSize")
        family = tags.get("sku-family")
        if (
            not SAFE_INVOCATION.match(invocation)
            or sku not in SKU_VCPUS
            or family is None
            or family.lower() != REVIEWED_SKU_FAMILY.get(sku, "").lower()
        ):
            raise ProviderError("specialized VM capacity identity is malformed")
        power = str(vm.get("powerState") or vm.get("power_state") or "unknown").lower()
        if "deallocated" in power:
            continue
        if invocation in active:
            raise ProviderError("specialized VM invocation is duplicated")
        active[invocation] = {"sku": sku, "sku_family": family, "vcpus": SKU_VCPUS[sku]}
        active_by_family[family] = active_by_family.get(family, 0) + SKU_VCPUS[sku]

    reservations = []
    seen = set()
    for identity in identities:
        tags = identity.get("tags") or {}
        if tags.get("firstmate-role") != "runner-cost-reservation":
            continue
        if not is_exact_fleet(controller, tags):
            raise ProviderError("runner reservation has foreign owner or deployment generation")
        invocation = tags.get("invocation-binding", "")
        sku = tags.get("selected-sku", "")
        family = tags.get("sku-family", "")
        mode = tags.get("cost-admission-mode")
        ordinal_text = tags.get("cell-ordinal", "")
        principal = (identity.get("properties") or {}).get("principalId") or identity.get("principalId")
        expected_name = "id-{}-rsv-{}".format(
            controller["prefix"], invocation.split("-")[1] if SAFE_INVOCATION.match(invocation) else "invalid"
        )
        expected_id = exact_id(
            controller, "Microsoft.ManagedIdentity", "userAssignedIdentities", expected_name
        )
        try:
            amount_microusd = int(tags.get("amount-microusd", ""))
        except (TypeError, ValueError):
            amount_microusd = 0
        exact_slot = ordinal_text == "none" and mode == "strict"
        if mode == "commissioning-bounded":
            try:
                ordinal = int(ordinal_text)
            except (TypeError, ValueError):
                ordinal = 0
            exact_slot = (
                1 <= ordinal <= 16
                and sku == RUNNER_COMMISSIONING_SKU_POOL[(ordinal - 1) // 2]
            )
        cleanup = tags.get("cleanup-verified-at", "")
        cleanup_complete = cleanup != "none"
        if cleanup_complete:
            try:
                dt.datetime.fromisoformat(cleanup.replace("Z", "+00:00"))
            except (TypeError, ValueError):
                raise ProviderError("runner reservation cleanup marker is malformed")
        if (
            not SAFE_INVOCATION.match(invocation)
            or invocation in seen
            or identity.get("location") != "eastus"
            or str(identity.get("id", "")).lower() != expected_id.lower()
            or sku not in SKU_VCPUS
            or REVIEWED_SKU_FAMILY.get(sku, "").lower() != family.lower()
            or mode not in ("strict", "commissioning-bounded")
            or not exact_slot
            or amount_microusd <= 0
            or cleanup == ""
            or not re.fullmatch(r"[0-9a-f]{64}", tags.get("fence-digest", ""))
            or not tags.get("reserved-at")
            or not tags.get("compute-deadline")
            or not principal
            or tags.get("reservation-principal") != principal
        ):
            raise ProviderError("runner reservation capacity identity is not exact")
        seen.add(invocation)
        if cleanup_complete:
            if invocation in active:
                raise ProviderError("cleaned runner reservation still owns active compute")
            continue
        reservations.append({
            "reservation_id": invocation,
            "role": "specialized",
            "sku": sku,
            "sku_family": family,
            "vcpus": SKU_VCPUS[sku],
            "amount_usd": amount_microusd / 1_000_000,
            "active": invocation in active,
        })
    missing = sorted(set(active) - seen)
    if missing:
        raise ProviderError("active specialized VM has no exact durable reservation")
    return reservations, active_by_family


def metrics(controller, vms, capacity_reservations, specialized_active_by_family):
    usage, rc, _ = az(controller, ["vm", "list-usage", "--location", "eastus"], check=False)
    regional_limit = None
    regional_used = None
    family_free = {}
    family_limit = {}
    family_used = {}
    wanted_families = set(REVIEWED_SKU_FAMILY.values()) | {
        reservation["sku_family"] for reservation in capacity_reservations
    }
    if rc == 0 and isinstance(usage, list):
        for item in usage:
            name = str((item.get("name") or {}).get("value", ""))
            try:
                limit = int(item.get("limit"))
                used = int(item.get("currentValue"))
            except (TypeError, ValueError):
                continue
            if name.lower() == "cores":
                regional_limit = limit
                regional_used = used
            for family in wanted_families:
                if name.lower() == family.lower():
                    family_limit[family] = limit
                    family_used[family] = used
                    family_free[family] = limit - used
    return {
        "actual_usd": cost_query(controller, False),
        "forecast_usd": cost_query(controller, True),
        "regional_limit_vcpus": regional_limit,
        "regional_used_vcpus": regional_used,
        "specialized_active_vcpus": sum(specialized_active_by_family.values()),
        "specialized_active_by_family": specialized_active_by_family,
        "family_limit_vcpus": family_limit,
        "family_used_vcpus": family_used,
        "family_free_vcpus": family_free,
        "sku_hourly_usd": {sku: retail_rate(sku) for sku, _ in sorted(set(SKU_PLAN.values()))},
    }


def inventory(controller, include_metrics=True):
    account, rc, stderr = az(controller, ["account", "show"], check=False)
    if rc != 0 or not isinstance(account, dict):
        raise ProviderError("Azure scope is unreadable: {}".format(stderr))
    if account.get("id", "").lower() != controller["subscription"] or account.get("state") != "Enabled":
        raise ProviderError("Azure subscription scope is not the exact enabled controller binding")

    prefix = re.escape(controller["prefix"])
    vms = list_json(controller, ["vm", "list", "--resource-group", controller["resource_group"], "--show-details"])
    nics = list_json(controller, ["network", "nic", "list", "--resource-group", controller["resource_group"]])
    disks = list_json(controller, ["disk", "list", "--resource-group", controller["resource_group"]])
    identities = list_json(controller, ["identity", "list", "--resource-group", controller["resource_group"]])
    roles = list_json(controller, ["role", "assignment", "list", "--resource-group", controller["resource_group"], "--all"])
    containers = list_json(controller, [
        "storage", "container", "list", "--auth-mode", "login",
        "--account-name", os.environ.get("FM_AZURE_STORAGE_NAME", ""),
    ])

    workers = {}
    conflicts = []

    def add(kind, value, slot, power=None, tags_override=None):
        tags = dict(tags_override if tags_override is not None else (value.get("tags") or {}))
        if not is_exact_fleet(controller, tags):
            conflicts.append({"kind": kind, "slot": slot, "reason": "same-fleet name has foreign owner or generation"})
            return
        worker = workers.setdefault(slot, {"slot": slot, "resources": {}})
        if kind in worker["resources"]:
            raise ProviderError("worker slot has duplicate {} resources".format(kind))
        worker["resources"][kind] = resource_record(kind, value, power, tags_override=tags)

    for vm in vms:
        slot = slot_from_name(vm.get("name"), r"^vm-{}-wkr-".format(prefix))
        if slot is not None:
            add("vm", vm, slot, vm.get("powerState") or vm.get("power_state") or "unknown")
    for nic in nics:
        slot = slot_from_name(nic.get("name"), r"^nic-{}-wkr-".format(prefix))
        if slot is not None:
            add("nic", nic, slot)
    for disk in disks:
        slot = slot_from_name(disk.get("name"), r"^disk-{}-wkr-".format(prefix))
        if slot is None:
            continue
        name = str(disk.get("name"))
        if name.endswith("-os"):
            kind = "os-disk"
        elif name.endswith("-task"):
            kind = "task-disk"
        elif name.endswith("-account"):
            kind = "account-disk"
        else:
            conflicts.append({"kind": "disk", "slot": slot, "reason": "unrecognized worker disk name"})
            continue
        add(kind, disk, slot)
    identity_principals = {}
    for identity in identities:
        slot = slot_from_name(identity.get("name"), r"^id-{}-wkr-".format(prefix))
        if slot is not None:
            add("identity", identity, slot)
            principal = immutable_id("identity", identity)
            if principal:
                identity_principals[slot] = principal

    storage = os.environ.get("FM_AZURE_STORAGE_NAME", "")
    container_by_slot = {}
    for container in containers:
        match = re.match(r"^worker-state-([0-9]{2})$", str(container.get("name")))
        if not match:
            continue
        slot = int(match.group(1))
        if not 1 <= slot <= 16:
            continue
        metadata = metadata_to_tags(container.get("metadata") or {})
        if not metadata and slot in workers:
            metadata = dict((workers[slot]["resources"].get("vm") or {}).get("tags") or {})
        container_value = dict(container)
        container_value["id"] = (
            exact_id(controller, "Microsoft.Storage", "storageAccounts", storage)
            + "/blobServices/default/containers/" + container["name"]
        )
        container_by_slot[slot] = container_value
        add("state-container", container_value, slot, tags_override=metadata)

    for role in roles:
        scope = str(role.get("scope") or "")
        match = re.search(r"/containers/worker-state-([0-9]{2})$", scope, re.IGNORECASE)
        if not match:
            continue
        slot = int(match.group(1))
        if not 1 <= slot <= 16:
            continue
        principal = role.get("principalId")
        if identity_principals.get(slot) != principal:
            conflicts.append({"kind": "role-assignment", "slot": slot, "reason": "container role principal is not the exact slot identity"})
            continue
        role_value = dict(role)
        if not role_value.get("id"):
            role_value["id"] = role.get("roleAssignmentId")
        synthesized = {}
        if slot in workers:
            vm_tags = (workers[slot]["resources"].get("vm") or {}).get("tags") or {}
            synthesized = dict(vm_tags)
        if not synthesized:
            synthesized = {
                "workload": "firstmate",
                "deployment-generation": controller["deployment_generation"],
                "cleanup-owner": controller["owner"],
            }
        add("role-assignment", role_value, slot, tags_override=synthesized)

    # A worker may not gain public ingress or an identity other than its one
    # exact slot UAMI. These are provider-level acceptance invariants, not
    # optional controller policy.
    for slot, worker in workers.items():
        vm = worker["resources"].get("vm")
        nic = worker["resources"].get("nic")
        identity = worker["resources"].get("identity")
        if vm:
            vm_value = next(value for value in vms if str(value.get("id", "")).lower() == vm["id"].lower())
            identity_map = ((vm_value.get("identity") or {}).get("userAssignedIdentities") or {})
            if identity:
                if {key.lower() for key in identity_map} != {identity["id"].lower()}:
                    conflicts.append({"kind": "vm", "slot": slot, "reason": "VM cloud identity set is not exactly one slot identity"})
            elif identity_map:
                conflicts.append({"kind": "vm", "slot": slot, "reason": "VM has an unowned cloud identity"})
        if nic and nic.get("attached_to") and vm and nic["attached_to"].lower() != vm["id"].lower():
            conflicts.append({"kind": "nic", "slot": slot, "reason": "NIC is attached to another VM"})

    capacity_reservations, specialized_active_by_family = specialized_capacity_inventory(
        controller, vms, identities
    )
    result = {
        "schema": INVENTORY_SCHEMA,
        "observed_at": iso_utc(),
        "workers": [workers[slot] for slot in sorted(workers)],
        "capacity_reservations": capacity_reservations,
        "conflicts": conflicts,
        "metrics": metrics(
            controller, vms, capacity_reservations, specialized_active_by_family
        ) if include_metrics else {
            "actual_usd": None,
            "forecast_usd": None,
            "regional_limit_vcpus": None,
            "regional_used_vcpus": None,
            "specialized_active_vcpus": None,
            "specialized_active_by_family": {},
            "family_limit_vcpus": {},
            "family_used_vcpus": {},
            "family_free_vcpus": {},
            "sku_hourly_usd": {},
        },
    }
    return result


def worker_by_slot(snapshot, slot):
    matches = [worker for worker in snapshot["workers"] if worker["slot"] == slot]
    if len(matches) > 1:
        raise ProviderError("Azure returned duplicate worker slot inventory")
    return matches[0] if matches else None


def recorded_exact(
    action, worker, allow_missing=(), allow_previous_cloud_generation=False,
    skip_immutable=(),
):
    if worker is None:
        raise ProviderError("exact worker slot is absent")
    resources = worker.get("resources") or {}
    expected = action.get("resources") or {}
    tags = action_tags({
        "deployment_generation": action["deployment_generation"],
        "owner": action["owner"],
    }, action)
    for kind in REQUIRED_RESOURCE_KINDS:
        current = resources.get(kind)
        prior = expected.get(kind)
        if current is None:
            if kind in allow_missing:
                continue
            raise ProviderError("exact {} resource is absent".format(kind))
        if prior is not None:
            if current.get("id") != prior.get("id"):
                raise ProviderError("{} resource ID differs from the recorded assignment".format(kind))
            if kind not in skip_immutable and current.get("immutable_id") != prior.get("immutable_id"):
                raise ProviderError("{} immutable identity differs from the recorded assignment".format(kind))
        for key, value in tags.items():
            if kind in ("role-assignment", "state-container") and key not in current.get("tags", {}):
                continue
            actual = current.get("tags", {}).get(key)
            if (
                allow_previous_cloud_generation
                and key == "cloud-generation"
                and actual == str(action.get("previous_cloud_generation"))
            ):
                continue
            if actual != value:
                raise ProviderError("{} exact task/account/worktree tag differs: {}".format(kind, key))
    return resources


def tag_resource(controller, resource_id, tags):
    _, rc, stderr = az(controller, [
        "tag", "update", "--resource-id", resource_id, "--operation", "Merge",
        "--tags",
    ] + ["{}={}".format(key, value) for key, value in sorted(tags.items())], check=False)
    if rc != 0:
        raise ProviderError("exact worker resource tagging failed: {}".format(stderr))


def tag_container(controller, name, tags):
    _, rc, stderr = az(controller, [
        "storage", "container", "metadata", "update", "--auth-mode", "login",
        "--account-name", os.environ.get("FM_AZURE_STORAGE_NAME", ""),
        "--name", name, "--metadata",
    ] + ["{}={}".format(key, value) for key, value in sorted(tags_to_metadata(tags).items())], check=False)
    if rc != 0:
        raise ProviderError("exact worker state-container metadata update failed: {}".format(stderr))


def cleanup_marker(resource, key, value):
    return (resource.get("tags") or {}).get(key) == value


def mark_cleanup_container(controller, action, key, value):
    tags = action_tags(controller, action)
    tags[key] = value
    if key == "reset-action":
        tags["release-proof"] = action["release_proof_digest"]
    tag_container(
        controller, expected_names(controller, action["slot"])["state-container"], tags
    )


def run_pilot_create(controller, action):
    env = os.environ.copy()
    env.update({
        "FM_AZURE_CAPACITY_PROFILE": "full",
        "FM_AZURE_AUTHOR_CAPACITY_MODE": "mixed-current",
        "FM_AZURE_WORKER_HOME_BINDING": action["bindings"]["home_binding"],
        "FM_AZURE_WORKER_TASK_BINDING": action["bindings"]["task"],
        "FM_AZURE_WORKER_INVOCATION_BINDING": action["bindings"]["assignment_generation"],
        "FM_AZURE_WORKER_SNAPSHOT_DIGEST": "sha256:" + action["bindings"]["repository_binding"],
        "FM_AZURE_WORKER_COST_ATTRIBUTION": "author",
    })
    result = run([
        str(PILOT), "worker-create", "--slot", str(action["slot"]), "--confirm-create",
        "--confirm-subscription", controller["subscription"],
    ], check=False, timeout=3600, env=env)
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()[-1500:]
        raise ProviderError("landed singleton worker deployment failed: {}".format(detail))


def converge_create_tags(controller, action):
    snapshot = inventory(controller, include_metrics=False)
    if snapshot["conflicts"]:
        raise ProviderError("new worker inventory contains foreign or unsafe resources")
    worker = worker_by_slot(snapshot, action["slot"])
    if worker is None:
        raise ProviderError("worker deployment completed without exact slot resources")
    tags = action_tags(controller, action)
    for kind, resource in worker["resources"].items():
        if kind in ("role-assignment", "state-container"):
            continue
        tag_resource(controller, resource["id"], tags)
    tag_container(controller, expected_names(controller, action["slot"])["state-container"], tags)
    snapshot = inventory(controller, include_metrics=False)
    if snapshot["conflicts"]:
        raise ProviderError("tagged worker inventory contains foreign or unsafe resources")
    worker = worker_by_slot(snapshot, action["slot"])
    resources = recorded_exact(action, worker)
    if set(resources) != set(REQUIRED_RESOURCE_KINDS):
        raise ProviderError("worker create did not produce the complete exact resource set")
    return worker


def create_or_resume(controller, action):
    snapshot = inventory(controller, include_metrics=False)
    if snapshot["conflicts"]:
        raise ProviderError("same-name foreign worker resources refuse create/adopt")
    existing = worker_by_slot(snapshot, action["slot"])
    reuse = action.get("reuse_retained") is True
    if existing is not None:
        resources = existing.get("resources") or {}
        if resources.get("vm"):
            try:
                recorded_exact(action, existing)
                return existing
            except ProviderError:
                # A submitted create can be visible with the template's exact VM
                # bindings before child tag convergence. It is safe to replay the
                # same landed incremental deployment and complete the same action.
                vm_tags = resources["vm"].get("tags") or {}
                bindings = action["bindings"]
                if not (
                    vm_tags.get("home-binding") == bindings["home_binding"]
                    and vm_tags.get("task-binding") == bindings["task"]
                    and vm_tags.get("invocation-binding") == bindings["assignment_generation"]
                ):
                    raise ProviderError("visible worker belongs to another task or generation")
        elif reuse:
            recorded_exact(
                action, existing, allow_missing=("vm", "nic", "os-disk"),
                allow_previous_cloud_generation=True,
            )
        else:
            raise ProviderError("fresh assignment found retained slot resources and refuses to inherit them")
    elif reuse:
        raise ProviderError("dirty-task resume found no exact retained capacity")
    run_pilot_create(controller, action)
    return converge_create_tags(controller, action)


def wait_absent(controller, resource_id, timeout=180):
    url = "https://management.azure.com{}?api-version=2024-03-01".format(resource_id)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        _, rc, _ = az(controller, ["rest", "--method", "get", "--url", url], check=False)
        if rc != 0:
            return
        time.sleep(2)
    raise ProviderError("Azure resource remained after bounded exact deletion")


def conditional_delete(controller, kind, resource):
    etag = resource.get("etag")
    if not etag and kind != "role-assignment":
        raise ProviderError("{} ETag is absent; conditional deletion refuses".format(kind))
    url = "https://management.azure.com{}?api-version={}".format(resource["id"], RESOURCE_API[kind])
    arguments = ["rest", "--method", "delete", "--url", url]
    if etag:
        arguments += ["--headers", "If-Match={}".format(etag)]
    _, rc, stderr = az(controller, arguments, check=False)
    if rc != 0:
        raise ProviderError("conditional {} deletion failed: {}".format(kind, stderr))


def mutate_deallocate(controller, action):
    snapshot = inventory(controller, include_metrics=False)
    resources = recorded_exact(action, worker_by_slot(snapshot, action["slot"]))
    power = str(resources["vm"].get("power_state", "")).lower()
    if "deallocated" not in power:
        _, rc, stderr = az(controller, [
            "vm", "deallocate", "--resource-group", controller["resource_group"],
            "--name", expected_names(controller, action["slot"])["vm"],
        ], check=False)
        if rc != 0:
            raise ProviderError("exact worker deallocation failed: {}".format(stderr))
    final = worker_by_slot(inventory(controller, include_metrics=False), action["slot"])
    final_resources = recorded_exact(action, final)
    if "deallocated" not in str(final_resources["vm"].get("power_state", "")).lower():
        raise ProviderError("worker compute did not reach Azure deallocated state")
    return final


def mutate_delete_compute(controller, action):
    snapshot = inventory(controller, include_metrics=False)
    worker = worker_by_slot(snapshot, action["slot"])
    if worker is None:
        raise ProviderError("compute cleanup lost exact retained task/account ownership")
    resources = worker.get("resources") or {}
    container = resources.get("state-container")
    marked = container is not None and cleanup_marker(
        container, "compute-action", action["idempotency_key"]
    )
    if not marked:
        resources = recorded_exact(action, worker)
        if "deallocated" not in str(resources["vm"].get("power_state", "")).lower():
            raise ProviderError("compute deletion requires the exact deallocated worker")
        mark_cleanup_container(
            controller, action, "compute-action", action["idempotency_key"]
        )
        worker = worker_by_slot(inventory(controller, include_metrics=False), action["slot"])
    resources = recorded_exact(
        action, worker, allow_missing=("vm", "nic", "os-disk"),
        skip_immutable=("state-container",),
    )
    vm = resources.get("vm")
    if vm is not None:
        if "deallocated" not in str(vm.get("power_state", "")).lower():
            raise ProviderError("compute deletion requires the exact deallocated worker")
        conditional_delete(controller, "vm", vm)
        wait_absent(controller, vm["id"])
    worker = worker_by_slot(inventory(controller, include_metrics=False), action["slot"])
    if worker is None:
        raise ProviderError("VM deletion also lost exact retained task/account capacity")
    remaining = worker.get("resources") or {}
    for kind in ("nic", "os-disk"):
        resource = remaining.get(kind)
        if resource is None:
            continue
        if resource.get("attached_to"):
            raise ProviderError("{} did not detach from the deleted worker VM".format(kind))
        prior = action["resources"].get(kind)
        if prior is None or resource["id"] != prior["id"] or resource["immutable_id"] != prior["immutable_id"]:
            raise ProviderError("detached {} immutable identity changed".format(kind))
        conditional_delete(controller, kind, resource)
    final = worker_by_slot(inventory(controller, include_metrics=False), action["slot"])
    if final is None:
        raise ProviderError("compute cleanup lost retained task/account ownership")
    final_resources = final.get("resources") or {}
    if any(kind in final_resources for kind in ("vm", "nic", "os-disk")):
        raise ProviderError("disposable VM/NIC/OS capacity remains after exact cleanup")
    recorded_exact(
        action, final, allow_missing=("vm", "nic", "os-disk"),
        skip_immutable=("state-container",),
    )
    return final


def mutate_reset(controller, action):
    if not re.match(r"^[0-9a-f]{64}$", str(action.get("release_proof_digest", ""))):
        raise ProviderError("reset requires the exact ordinary release-proof digest")
    snapshot = inventory(controller, include_metrics=False)
    worker = worker_by_slot(snapshot, action["slot"])
    if worker is None:
        return None
    resources = worker.get("resources") or {}
    container = resources.get("state-container")
    marked = (
        container is not None
        and cleanup_marker(container, "reset-action", action["idempotency_key"])
        and cleanup_marker(container, "release-proof", action["release_proof_digest"])
    )
    if not marked:
        resources = recorded_exact(action, worker, allow_missing=("vm", "nic", "os-disk"))
        if any(kind in resources for kind in ("vm", "nic", "os-disk")):
            raise ProviderError("reset refuses while disposable compute still exists")
        mark_cleanup_container(
            controller, action, "reset-action", action["idempotency_key"]
        )
        worker = worker_by_slot(inventory(controller, include_metrics=False), action["slot"])
    allow_missing = tuple(kind for kind in REQUIRED_RESOURCE_KINDS if kind != "state-container")
    resources = recorded_exact(
        action, worker, allow_missing=allow_missing, skip_immutable=("state-container",)
    )
    if any(kind in resources for kind in ("vm", "nic", "os-disk")):
        raise ProviderError("reset refuses while disposable compute still exists")
    for kind in ("role-assignment", "identity", "account-disk", "task-disk"):
        resource = resources.get(kind)
        if resource is None:
            continue
        if kind in ("account-disk", "task-disk") and resource.get("attached_to"):
            raise ProviderError("retained {} is still attached".format(kind))
        conditional_delete(controller, kind, resource)
    refreshed = worker_by_slot(inventory(controller, include_metrics=False), action["slot"])
    if refreshed is None:
        raise ProviderError("cleanup marker container disappeared before exact reset completed")
    state_container = (refreshed.get("resources") or {}).get("state-container")
    if state_container is None or not cleanup_marker(
        state_container, "reset-action", action["idempotency_key"]
    ):
        raise ProviderError("reset cleanup marker is absent before container deletion")
    if not state_container.get("etag"):
        raise ProviderError("state-container ETag is absent; conditional deletion refuses")
    _, rc, stderr = az(controller, [
        "storage", "container", "delete", "--auth-mode", "login",
        "--account-name", os.environ.get("FM_AZURE_STORAGE_NAME", ""),
        "--name", expected_names(controller, action["slot"])["state-container"],
        "--if-match", state_container["etag"],
    ], check=False)
    if rc != 0:
        raise ProviderError("exact worker state-container deletion failed: {}".format(stderr))
    final = inventory(controller, include_metrics=False)
    if worker_by_slot(final, action["slot"]) is not None:
        raise ProviderError("released worker capacity remains after exact reset")
    return None


def mutate_steer(controller, action):
    snapshot = inventory(controller, include_metrics=False)
    resources = recorded_exact(action, worker_by_slot(snapshot, action["slot"]))
    if "deallocated" in str(resources["vm"].get("power_state", "")).lower():
        raise ProviderError("steer refuses deallocated worker compute")
    digest = action.get("request_digest")
    if not re.match(r"^[0-9a-f]{64}$", str(digest)):
        raise ProviderError("steer request digest is malformed")
    bindings = action["bindings"]
    script = """set -eu
supervisor=/usr/local/libexec/fm-worker-supervisor
[ -x \"$supervisor\" ] || { echo 'minimal worker supervisor absent' >&2; exit 70; }
exec \"$supervisor\" steer --home-binding '{}' --task '{}' --task-generation '{}' --assignment-generation '{}' --request-digest '{}'
""".format(
        bindings["home_binding"], bindings["task"], bindings["task_generation"],
        bindings["assignment_generation"], digest,
    )
    _, rc, stderr = az(controller, [
        "vm", "run-command", "invoke", "--resource-group", controller["resource_group"],
        "--name", expected_names(controller, action["slot"])["vm"],
        "--command-id", "RunShellScript", "--scripts", script,
    ], check=False)
    if rc != 0:
        raise ProviderError("exact guest-supervisor steer failed: {}".format(stderr))
    return worker_by_slot(inventory(controller, include_metrics=False), action["slot"])


def mutate(controller, action):
    if not isinstance(action, dict):
        raise ProviderError("provider mutation action is malformed")
    action_type = action.get("type")
    if action_type not in ("create", "resume", "deallocate", "delete-compute", "reset", "steer"):
        raise ProviderError("unsupported provider mutation action")
    if action.get("deployment_generation") != controller["deployment_generation"] or action.get("owner") != controller["owner"]:
        raise ProviderError("provider mutation owner or deployment generation is not exact")
    if not isinstance(action.get("slot"), int) or action["slot"] not in SKU_PLAN:
        raise ProviderError("provider mutation slot is outside the reviewed sixteen")
    expected_sku, expected_family = SKU_PLAN[action["slot"]]
    if action.get("sku") != expected_sku or action.get("sku_family") != expected_family:
        raise ProviderError("provider mutation SKU/family is not the reviewed mixed plan")
    expected_key = hashlib.sha256(canonical_bytes({
        key: value for key, value in action.items() if key != "idempotency_key"
    })).hexdigest()
    if action.get("idempotency_key") != expected_key:
        raise ProviderError("provider mutation idempotency key is not exact")
    if action_type in ("create", "resume"):
        worker = create_or_resume(controller, action)
    elif action_type == "deallocate":
        worker = mutate_deallocate(controller, action)
    elif action_type == "delete-compute":
        worker = mutate_delete_compute(controller, action)
    elif action_type == "reset":
        worker = mutate_reset(controller, action)
    else:
        worker = mutate_steer(controller, action)
    result = {
        "idempotency_key": action["idempotency_key"],
        "action": action_type,
    }
    if worker is not None:
        result["worker"] = worker
    return result


def read_request():
    data = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
    if len(data) > MAX_INPUT_BYTES:
        raise ProviderError("provider request exceeds its bounded input allowance")
    try:
        request = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProviderError("provider request is malformed: {}".format(exc))
    if not isinstance(request, dict) or request.get("schema") != REQUEST_SCHEMA:
        raise ProviderError("provider request schema is not supported")
    controller = request.get("controller")
    if not isinstance(controller, dict):
        raise ProviderError("provider controller binding is absent")
    required = ("home_binding", "subscription", "deployment_generation", "owner", "prefix", "resource_group")
    if any(not isinstance(controller.get(field), str) or not controller[field] for field in required):
        raise ProviderError("provider controller binding is incomplete")
    if controller["subscription"].lower() != os.environ.get("FM_AZURE_SUBSCRIPTION_ID", "").lower():
        raise ProviderError("provider request subscription differs from the out-of-band Azure scope")
    if controller["deployment_generation"] != os.environ.get("FM_AZURE_DEPLOYMENT_GENERATION"):
        raise ProviderError("provider request deployment generation differs from the out-of-band scope")
    if controller["owner"] != os.environ.get("FM_AZURE_OWNER_TAG"):
        raise ProviderError("provider request cleanup owner differs from the out-of-band scope")
    if controller["prefix"] != os.environ.get("FM_AZURE_NAMING_PREFIX"):
        raise ProviderError("provider request naming prefix differs from the out-of-band scope")
    storage = os.environ.get("FM_AZURE_STORAGE_NAME", "")
    if not re.match(r"^[a-z0-9]{3,24}$", storage):
        raise ProviderError("FM_AZURE_STORAGE_NAME is required with exact Azure storage syntax")
    return request, controller


def response(controller, operation, **fields):
    value = {
        "schema": RESPONSE_SCHEMA,
        "operation": operation,
        "controller": controller,
    }
    value.update(fields)
    return value


def main():
    request, controller = read_request()
    operation = request.get("operation")
    if operation == "inventory":
        value = response(controller, operation, inventory=inventory(controller))
    elif operation == "mutate":
        require_landed_code()
        value = response(controller, operation, result=mutate(controller, request.get("action")))
    else:
        raise ProviderError("provider operation is not supported")
    sys.stdout.buffer.write(canonical_bytes(value) + b"\n")


if __name__ == "__main__":
    try:
        main()
    except ProviderError as exc:
        print("AZURE WORKER PROVIDER REFUSED: {}".format(exc), file=sys.stderr)
        raise SystemExit(2)
