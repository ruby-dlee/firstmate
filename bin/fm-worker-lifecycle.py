#!/usr/bin/env python3
"""Provider-neutral queue and lifecycle owner for elastic task workers.

The controller deliberately does not decide that work is landed or safe to
remove.  It consumes an exact release receipt from the ordinary Firstmate
owners, serializes one idempotent provider action at a time, and retains every
ambiguous assignment for investigation.

The provider protocol is JSON over stdin/stdout.  Set FM_WORKER_PROVIDER_COMMAND
for a different implementation; Azure is the default adapter.
See docs/azure-workers.md and `bin/fm-worker-lifecycle.sh help`.
"""

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time
import uuid


ROOT = Path(__file__).resolve().parent.parent
AZURE_PROVIDER = ROOT / "bin" / "fm-azure-worker-provider.py"
STATE_SCHEMA = "fm.worker-lifecycle/v1"
REQUEST_SCHEMA = "fm.worker-request/v1"
RELEASE_SCHEMA = "fm.worker-release/v1"
PROVIDER_REQUEST_SCHEMA = "fm.worker-provider-request/v1"
PROVIDER_RESPONSE_SCHEMA = "fm.worker-provider-response/v1"
SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")
HEX_BINDING = re.compile(r"^[0-9a-f]{64}$")
UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
MAX_WORKERS = 16
VCPUS_PER_WORKER = 4
REGIONAL_LANDING_RESERVE_VCPUS = 62
DEFAULT_COOLDOWN_SECONDS = 300
PROVIDER_TIMEOUT_SECONDS = 300
MAX_PROVIDER_OUTPUT_BYTES = 2 * 1024 * 1024
REQUIRED_RESOURCE_KINDS = (
    "vm", "nic", "os-disk", "task-disk", "account-disk", "identity",
    "role-assignment", "state-container",
)
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


class LifecycleError(RuntimeError):
    pass


def canonical_bytes(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def digest_value(value):
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


def home_binding(path):
    return hashlib.sha256(str(path.resolve()).encode("utf-8")).hexdigest()


def now_utc():
    return dt.datetime.now(dt.timezone.utc)


def iso_utc(value=None):
    value = value or now_utc()
    return value.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_time(value):
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (AttributeError, TypeError, ValueError):
        raise LifecycleError("durable lifecycle timestamp is malformed")


def require_id(label, value):
    if not isinstance(value, str) or not SAFE_ID.match(value):
        raise LifecycleError("{} must use 1-64 bounded identifier characters".format(label))
    return value


def require_binding(label, value):
    if not isinstance(value, str) or not HEX_BINDING.match(value):
        raise LifecycleError("{} must be an exact lowercase SHA-256 binding".format(label))
    return value


def require_uuid(label, value):
    if not isinstance(value, str) or not UUID.match(value):
        raise LifecycleError("{} must be an exact UUID".format(label))
    return value.lower()


def read_json(path, label):
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise LifecycleError("{} is absent".format(label))
    except (OSError, json.JSONDecodeError) as exc:
        raise LifecycleError("{} is unreadable: {}".format(label, exc))
    if not isinstance(value, dict):
        raise LifecycleError("{} must be a JSON object".format(label))
    return value


def save_json_atomic(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    temp = path.with_name(".{}.{}.tmp".format(path.name, uuid.uuid4().hex))
    fd = os.open(str(temp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(str(temp), str(path))
        directory_fd = os.open(str(path.parent), os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        with contextlib.suppress(FileNotFoundError):
            temp.unlink()


def environment():
    home = Path(os.environ.get("FM_HOME", str(ROOT))).resolve()
    subscription = require_uuid(
        "FM_AZURE_SUBSCRIPTION_ID", os.environ.get("FM_AZURE_SUBSCRIPTION_ID", "")
    )
    deployment_generation = require_id(
        "FM_AZURE_DEPLOYMENT_GENERATION", os.environ.get("FM_AZURE_DEPLOYMENT_GENERATION", "")
    )
    owner = require_id("FM_AZURE_OWNER_TAG", os.environ.get("FM_AZURE_OWNER_TAG", ""))
    prefix = os.environ.get("FM_AZURE_NAMING_PREFIX", "")
    if not re.match(r"^[a-z0-9]{3,12}$", prefix):
        raise LifecycleError("FM_AZURE_NAMING_PREFIX must be 3-12 lowercase alphanumeric characters")
    state_dir = Path(os.environ.get(
        "FM_AZURE_WORKER_STATE_DIR", str(home / "state" / "azure-workers")
    )).resolve()
    max_workers = int(os.environ.get("FM_AZURE_WORKER_MAX", "16"))
    if max_workers < 1 or max_workers > MAX_WORKERS:
        raise LifecycleError("FM_AZURE_WORKER_MAX must be between 1 and 16")
    cooldown = int(os.environ.get(
        "FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS", str(DEFAULT_COOLDOWN_SECONDS)
    ))
    if cooldown < 0 or cooldown > 1800:
        raise LifecycleError("FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS must be between 0 and 1800")
    warm_idle = int(os.environ.get("FM_AZURE_WORKER_WARM_IDLE", "0"))
    if warm_idle != 0:
        raise LifecycleError("FM_AZURE_WORKER_WARM_IDLE currently must remain zero")
    phase = os.environ.get("FM_AZURE_WORKER_POLICY_PHASE", "commissioning")
    if phase not in ("commissioning", "steady"):
        raise LifecycleError("FM_AZURE_WORKER_POLICY_PHASE must be commissioning or steady")
    steady_target = float(os.environ.get("FM_AZURE_WORKER_STEADY_TARGET_USD", "1000"))
    if steady_target < 500 or steady_target > 1500:
        raise LifecycleError("FM_AZURE_WORKER_STEADY_TARGET_USD must be between 500 and 1500")
    commissioning_ceiling = float(os.environ.get("FM_AZURE_WORKER_COMMISSIONING_CEILING_USD", "1500"))
    if commissioning_ceiling != 1500:
        raise LifecycleError("commissioning author admission ceiling must remain exactly 1500 USD")
    forecast_hours = float(os.environ.get("FM_AZURE_WORKER_ADMISSION_HOURS", "24"))
    if forecast_hours < 1 or forecast_hours > 168:
        raise LifecycleError("FM_AZURE_WORKER_ADMISSION_HOURS must be between 1 and 168")
    planning_hours = float(os.environ.get("FM_AZURE_WORKER_HOUR_PLANNING_THRESHOLD", "3500"))
    if planning_hours <= 0:
        raise LifecycleError("FM_AZURE_WORKER_HOUR_PLANNING_THRESHOLD must be positive")
    provider_command = os.environ.get(
        "FM_WORKER_PROVIDER_COMMAND", "python3 {}".format(shlex.quote(str(AZURE_PROVIDER)))
    )
    provider_argv = shlex.split(provider_command)
    if not provider_argv:
        raise LifecycleError("FM_WORKER_PROVIDER_COMMAND is empty")
    return {
        "home": home,
        "home_binding": home_binding(home),
        "subscription": subscription,
        "deployment_generation": deployment_generation,
        "owner": owner,
        "prefix": prefix,
        "resource_group": os.environ.get("FM_AZURE_RESOURCE_GROUP", "rg-firstmate-pilot-eastus-001"),
        "state_dir": state_dir,
        "state_path": state_dir / "controller.json",
        "lock_path": state_dir / ".lock",
        "max_workers": max_workers,
        "cooldown_seconds": cooldown,
        "warm_idle": warm_idle,
        "policy_phase": phase,
        "steady_target_usd": steady_target,
        "commissioning_ceiling_usd": commissioning_ceiling,
        "admission_hours": forecast_hours,
        "planning_hours": planning_hours,
        "provider_argv": provider_argv,
    }


@contextlib.contextmanager
def controller_lock(env):
    env["state_dir"].mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(env["state_dir"], 0o700)
    with open(env["lock_path"], "a+", encoding="utf-8") as handle:
        os.chmod(env["lock_path"], 0o600)
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        yield


def empty_state(env):
    return {
        "schema": STATE_SCHEMA,
        "home_binding": env["home_binding"],
        "subscription_binding": hashlib.sha256(env["subscription"].encode("ascii")).hexdigest(),
        "deployment_generation": env["deployment_generation"],
        "owner": env["owner"],
        "prefix": env["prefix"],
        "created_at": iso_utc(),
        "updated_at": iso_utc(),
        "next_assignment": 1,
        "queue": {},
        "workers": {},
        "completed_worker_seconds": 0.0,
        "pending_action": None,
        "cleanup_refusals": [],
        "last_metrics": None,
    }


def verify_state(env, state):
    expected = empty_state(env)
    for field in (
        "schema", "home_binding", "subscription_binding", "deployment_generation", "owner", "prefix"
    ):
        if state.get(field) != expected[field]:
            raise LifecycleError("lifecycle state {} binding is not exact".format(field))
    if not isinstance(state.get("queue"), dict) or not isinstance(state.get("workers"), dict):
        raise LifecycleError("lifecycle queue or worker inventory is malformed")
    if state.get("pending_action") is not None and not isinstance(state["pending_action"], dict):
        raise LifecycleError("pending provider action is malformed")


def load_state(env):
    try:
        state = read_json(env["state_path"], "lifecycle state")
    except LifecycleError as exc:
        if "is absent" not in str(exc):
            raise
        state = empty_state(env)
    verify_state(env, state)
    return state


def save_state(env, state):
    state["updated_at"] = iso_utc()
    verify_state(env, state)
    save_json_atomic(env["state_path"], state)


def request_key(task, generation):
    return "{}@{}".format(task, generation)


def verify_request(request):
    if request.get("schema") != REQUEST_SCHEMA:
        raise LifecycleError("worker request schema is not supported")
    for field in ("task", "task_generation", "repository_generation"):
        require_id(field, request.get(field))
    for field in ("home_binding", "account_binding", "worktree_binding", "repository_binding"):
        require_binding(field, request.get(field))
    if request.get("role") != "author":
        raise LifecycleError("general worker requests must use the single-agent author role")
    if request.get("owner_kind") not in ("primary", "secondmate"):
        raise LifecycleError("worker request owner_kind must be primary or secondmate")
    if request.get("eligible") is not True:
        raise LifecycleError("worker request must be explicitly eligible")


def active_queue_items(state):
    return [item for item in state["queue"].values() if item.get("status") != "complete"]


def ensure_unique_bindings(state, candidate, ignore_key=None):
    for key, item in state["queue"].items():
        if key == ignore_key or item.get("status") == "complete":
            continue
        if item.get("account_binding") == candidate["account_binding"]:
            raise LifecycleError("provider-account lease binding is already owned by another queued or active task")
        if item.get("worktree_binding") == candidate["worktree_binding"]:
            raise LifecycleError("writable worktree binding is already owned by another queued or active task")


def provider_call(env, operation, action=None):
    request = {
        "schema": PROVIDER_REQUEST_SCHEMA,
        "operation": operation,
        "controller": {
            "home_binding": env["home_binding"],
            "subscription": env["subscription"],
            "deployment_generation": env["deployment_generation"],
            "owner": env["owner"],
            "prefix": env["prefix"],
            "resource_group": env["resource_group"],
        },
    }
    if action is not None:
        request["action"] = action
    try:
        result = subprocess.run(
            env["provider_argv"], input=canonical_bytes(request) + b"\n",
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=PROVIDER_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise LifecycleError("provider operation is unavailable or exceeded its bounded deadline: {}".format(exc))
    if len(result.stdout) > MAX_PROVIDER_OUTPUT_BYTES or len(result.stderr) > MAX_PROVIDER_OUTPUT_BYTES:
        raise LifecycleError("provider response exceeded its bounded output allowance")
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()[-1000:]
        raise LifecycleError("provider {} failed{}".format(operation, ": " + detail if detail else ""))
    try:
        response = json.loads(result.stdout.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise LifecycleError("provider returned malformed JSON: {}".format(exc))
    verify_provider_response(env, operation, response)
    return response


def verify_provider_response(env, operation, response):
    if not isinstance(response, dict) or response.get("schema") != PROVIDER_RESPONSE_SCHEMA:
        raise LifecycleError("provider response schema is not supported")
    if response.get("operation") != operation:
        raise LifecycleError("provider response operation binding is not exact")
    controller = response.get("controller") or {}
    for field in ("home_binding", "subscription", "deployment_generation", "owner", "prefix", "resource_group"):
        expected = env[field]
        if controller.get(field) != expected:
            raise LifecycleError("provider response {} binding is not exact".format(field))
    if operation == "inventory":
        verify_inventory(response.get("inventory"))


def verify_inventory(inventory):
    if not isinstance(inventory, dict) or inventory.get("schema") != "fm.worker-provider-inventory/v1":
        raise LifecycleError("provider inventory schema is not supported")
    workers = inventory.get("workers")
    metrics = inventory.get("metrics")
    if not isinstance(workers, list) or len(workers) > MAX_WORKERS or not isinstance(metrics, dict):
        raise LifecycleError("provider inventory is malformed or exceeds sixteen workers")
    slots = set()
    resource_ids = set()
    for worker in workers:
        slot = worker.get("slot")
        if not isinstance(slot, int) or slot < 1 or slot > MAX_WORKERS or slot in slots:
            raise LifecycleError("provider worker slot inventory is invalid or duplicated")
        slots.add(slot)
        resources = worker.get("resources") or {}
        if not isinstance(resources, dict):
            raise LifecycleError("provider worker resource inventory is malformed")
        for kind, resource in resources.items():
            if kind not in REQUIRED_RESOURCE_KINDS or not isinstance(resource, dict):
                raise LifecycleError("provider returned an unsupported worker resource kind")
            resource_id = resource.get("id")
            if not isinstance(resource_id, str) or not resource_id or resource_id.lower() in resource_ids:
                raise LifecycleError("provider resource identity is absent or duplicated")
            resource_ids.add(resource_id.lower())
    if not isinstance(inventory.get("conflicts", []), list):
        raise LifecycleError("provider conflict inventory is malformed")


def bindings_for_item(item, assignment_generation):
    return {
        "home_binding": item["home_binding"],
        "task": item["task"],
        "task_generation": item["task_generation"],
        "assignment_generation": assignment_generation,
        "account_binding": item["account_binding"],
        "worktree_binding": item["worktree_binding"],
        "repository_binding": item["repository_binding"],
        "repository_generation": item["repository_generation"],
    }


def expected_tags(worker):
    bindings = worker["bindings"]
    return {
        "workload": "firstmate",
        "firstmate-role": "worker",
        "deployment-generation": worker["deployment_generation"],
        "cleanup-owner": worker["owner"],
        "worker-slot": str(worker["slot"]),
        "home-binding": bindings["home_binding"],
        "task-binding": bindings["task"],
        "task-generation": bindings["task_generation"],
        "assignment-generation": bindings["assignment_generation"],
        "account-binding": bindings["account_binding"],
        "worktree-binding": bindings["worktree_binding"],
        "repository-binding": bindings["repository_binding"],
        "repository-generation": bindings["repository_generation"],
        "agent-capacity": "one-task-scoped-crewmate",
        "nested-team": "forbidden",
        "secondmate-placement": "forbidden",
        "browser-profile": "forbidden",
    }


def inventory_by_slot(inventory):
    return {worker["slot"]: worker for worker in inventory["workers"]}


def resource_identity(resource):
    return {
        "id": resource.get("id"),
        "immutable_id": resource.get("immutable_id"),
    }


def resources_exact(worker, cloud, allow_missing_compute=False):
    resources = cloud.get("resources") or {}
    recorded = worker.get("resources") or {}
    missing = []
    for kind in REQUIRED_RESOURCE_KINDS:
        current = resources.get(kind)
        prior = recorded.get(kind)
        if current is None:
            if allow_missing_compute and kind in ("vm", "nic", "os-disk"):
                continue
            missing.append(kind)
            continue
        if prior is not None and resource_identity(current) != resource_identity(prior):
            return False, "{} immutable identity changed".format(kind)
        tags = current.get("tags") or {}
        for key, value in expected_tags(worker).items():
            if kind in ("role-assignment", "state-container") and key not in tags:
                continue
            if tags.get(key) != value:
                return False, "{} tag mismatch: {}".format(kind, key)
    if missing:
        return False, "missing exact resources: {}".format(", ".join(missing))
    return True, ""


def classify_worker(worker, cloud, now=None):
    now = now or now_utc()
    if cloud is None:
        if worker["phase"] in ("creating", "resuming"):
            return "retained-for-investigation", "capacity absent during a submitted create"
        if worker["phase"] in ("compute-removed", "resetting"):
            return "orphaned-safe-to-delete", "release proof owns exact residual cleanup"
        return "retained-for-investigation", "recorded assignment has no exact cloud capacity"
    exact, reason = resources_exact(worker, cloud, allow_missing_compute=True)
    if not exact:
        return "retained-for-investigation", reason
    resources = cloud.get("resources") or {}
    vm = resources.get("vm")
    task_disk = resources.get("task-disk")
    account_disk = resources.get("account-disk")
    if vm is None:
        if task_disk or account_disk:
            if worker.get("release_proof") and worker["phase"] in ("compute-removed", "resetting"):
                return "orphaned-safe-to-delete", "exact released residual data capacity"
            return "retained-for-investigation", "VM missing while task or account disk remains"
        return "retained-for-investigation", "VM and durable task identity are both absent"
    power = str(vm.get("power_state", "unknown")).lower()
    if worker.get("release_proof"):
        started = worker.get("cooldown_started_at")
        if "deallocated" in power and started:
            age = max(0, int((now - parse_time(started)).total_seconds()))
            return "deallocated", "idle cooldown age {} seconds".format(age)
        if "deallocated" in power:
            return "deallocated", "idle worker compute is dark"
    if worker.get("bindings", {}).get("task") == "unbound":
        return "clean-warm", "fresh unassigned generation"
    return "assigned", "one exact active task generation"


def adopt_cloud_resources(worker, cloud):
    resources = cloud.get("resources") or {}
    if set(resources) != set(REQUIRED_RESOURCE_KINDS):
        raise LifecycleError("created worker did not return the complete exact resource set")
    worker["resources"] = {
        kind: resource_identity(resources[kind]) for kind in REQUIRED_RESOURCE_KINDS
    }
    exact, reason = resources_exact(worker, cloud)
    if not exact:
        raise LifecycleError("created worker identity is not exact: {}".format(reason))
    vm = resources["vm"]
    worker["cloud_instance_id"] = vm["immutable_id"]
    worker["phase"] = "assigned"
    worker["assigned_at"] = worker.get("assigned_at") or iso_utc()
    worker["last_classification"] = "assigned"


def metrics_from_inventory(inventory):
    metrics = inventory["metrics"]
    result = {
        "actual_usd": metrics.get("actual_usd"),
        "forecast_usd": metrics.get("forecast_usd"),
        "regional_limit_vcpus": metrics.get("regional_limit_vcpus"),
        "regional_used_vcpus": metrics.get("regional_used_vcpus"),
        "family_free_vcpus": metrics.get("family_free_vcpus"),
        "sku_hourly_usd": metrics.get("sku_hourly_usd"),
        "observed_at": inventory.get("observed_at"),
    }
    return result


def worker_seconds(state, now=None):
    now = now or now_utc()
    total = float(state.get("completed_worker_seconds", 0.0))
    for worker in state["workers"].values():
        if worker.get("assigned_at") and not worker.get("released_at"):
            total += max(0.0, (now - parse_time(worker["assigned_at"])).total_seconds())
    return total


def outstanding_reservations(state):
    return sum(
        float(worker.get("reservation_usd", 0.0))
        for worker in state["workers"].values()
        if not worker.get("released_at")
    )


def budget_limit(env):
    if env["policy_phase"] == "commissioning":
        return env["commissioning_ceiling_usd"]
    return env["steady_target_usd"]


def admission_result(env, state, inventory, slot, item=None, extra_reservations=0.0):
    metrics = inventory["metrics"]
    actual = metrics.get("actual_usd")
    forecast = metrics.get("forecast_usd")
    regional_limit = metrics.get("regional_limit_vcpus")
    regional_used = metrics.get("regional_used_vcpus")
    family_free = metrics.get("family_free_vcpus")
    rates = metrics.get("sku_hourly_usd")
    if not isinstance(actual, (int, float)) or not isinstance(forecast, (int, float)):
        return False, "actual or forecast spend is unreadable", 0.0
    if not isinstance(regional_limit, int) or not isinstance(regional_used, int):
        return False, "regional quota is unreadable", 0.0
    sku, family = SKU_PLAN[slot]
    if not isinstance(family_free, dict) or not isinstance(family_free.get(family), int):
        return False, "exact selected-family quota is unreadable", 0.0
    if not isinstance(rates, dict) or not isinstance(rates.get(sku), (int, float)):
        return False, "selected worker retail rate is unreadable", 0.0
    regional_free = regional_limit - regional_used
    if regional_free < VCPUS_PER_WORKER or regional_free - VCPUS_PER_WORKER < REGIONAL_LANDING_RESERVE_VCPUS:
        return False, "regional landing-capacity reserve would be consumed", 0.0
    if family_free[family] < VCPUS_PER_WORKER:
        return False, "exact selected-family free vCPU quota is insufficient", 0.0
    # The reservation covers the configurable expected author interval plus a
    # conservative retained-disk/control allowance. It supplements lagging Cost
    # Management telemetry and is released only after exact lifecycle cleanup.
    increment = round(float(rates[sku]) * env["admission_hours"] + 2.0, 6)
    pressure = (
        max(float(actual), float(forecast))
        + outstanding_reservations(state)
        + float(extra_reservations)
        + increment
    )
    limit = budget_limit(env)
    if pressure >= limit and (item is None or item.get("discretionary", True)):
        return False, "budget actual/forecast plus durable reservations reaches the active policy limit", increment
    return True, "", increment


def queued_items(state):
    return sorted(
        [item for item in state["queue"].values() if item.get("status") == "queued" and item.get("eligible")],
        key=lambda item: (item.get("enqueued_at", ""), item["task"], item["task_generation"]),
    )


def active_count(state, inventory):
    cloud = inventory_by_slot(inventory)
    count = 0
    for worker in state["workers"].values():
        current = cloud.get(worker["slot"])
        if current and current.get("resources", {}).get("vm"):
            power = str(current["resources"]["vm"].get("power_state", "")).lower()
            if "deallocated" not in power:
                count += 1
    return count


def desired_count(env, state, inventory):
    total_work = sum(
        1 for item in state["queue"].values()
        if item.get("status") in ("queued", "assigning", "assigned") and item.get("eligible")
    )
    actual = active_count(state, inventory)
    quota_capacity = 0
    metrics = inventory["metrics"]
    if isinstance(metrics.get("regional_limit_vcpus"), int) and isinstance(metrics.get("regional_used_vcpus"), int):
        regional_free = metrics["regional_limit_vcpus"] - metrics["regional_used_vcpus"]
        quota_capacity = actual + max(0, (regional_free - REGIONAL_LANDING_RESERVE_VCPUS) // VCPUS_PER_WORKER)
    budget_capacity = actual
    waiting = queued_items(state)
    projected_reservations = 0.0
    projected_family_vcpus = {}
    if waiting:
        for slot in range(1, env["max_workers"] + 1):
            if str(slot) in state["workers"]:
                continue
            family = SKU_PLAN[slot][1]
            family_free = (metrics.get("family_free_vcpus") or {}).get(family)
            used = projected_family_vcpus.get(family, 0)
            if not isinstance(family_free, int) or family_free - used < VCPUS_PER_WORKER:
                continue
            admitted, _, increment = admission_result(
                env, state, inventory, slot, waiting[0], extra_reservations=projected_reservations
            )
            if admitted:
                budget_capacity += 1
                projected_reservations += increment
                projected_family_vcpus[family] = used + VCPUS_PER_WORKER
    desired = min(
        total_work, env["max_workers"], max(actual, quota_capacity), max(actual, budget_capacity)
    )
    return max(actual, desired)


def action_id(action):
    unsigned = dict(action)
    unsigned.pop("idempotency_key", None)
    return digest_value(unsigned)


def make_action(env, action_type, worker=None, item=None, **fields):
    action = {
        "type": action_type,
        "deployment_generation": env["deployment_generation"],
        "owner": env["owner"],
    }
    if worker is not None:
        action.update({
            "slot": worker["slot"],
            "sku": worker["sku"],
            "sku_family": worker["sku_family"],
            "cloud_generation": worker["cloud_generation"],
            "bindings": worker["bindings"],
            "resources": worker.get("resources", {}),
            "cloud_instance_id": worker.get("cloud_instance_id"),
        })
    if item is not None:
        action["request"] = item
    action.update(fields)
    action["idempotency_key"] = action_id(action)
    return action


def next_assignment_generation(state):
    value = int(state.get("next_assignment", 1))
    state["next_assignment"] = value + 1
    return "asg-{:08d}".format(value)


def create_worker_record(env, state, slot, item, reservation):
    assignment_generation = next_assignment_generation(state)
    sku, family = SKU_PLAN[slot]
    return {
        "slot": slot,
        "sku": sku,
        "sku_family": family,
        "deployment_generation": env["deployment_generation"],
        "owner": env["owner"],
        "assignment_generation": assignment_generation,
        "cloud_generation": 1,
        "bindings": bindings_for_item(item, assignment_generation),
        "queue_key": request_key(item["task"], item["task_generation"]),
        "phase": "creating",
        "created_at": iso_utc(),
        "assigned_at": None,
        "released_at": None,
        "release_proof": None,
        "cooldown_started_at": None,
        "reservation_usd": reservation,
        "resources": {},
        "cloud_instance_id": None,
        "last_classification": "retained-for-investigation",
        "last_refusal": None,
    }


def record_refusal(state, worker, note):
    entry = {
        "at": iso_utc(),
        "slot": worker.get("slot") if worker else None,
        "assignment_generation": worker.get("assignment_generation") if worker else None,
        "note": str(note)[:500],
    }
    state["cleanup_refusals"].append(entry)
    state["cleanup_refusals"] = state["cleanup_refusals"][-20:]
    if worker is not None:
        worker["last_refusal"] = entry
        worker["last_classification"] = "retained-for-investigation"


def execute_action(env, state, action):
    state["pending_action"] = action
    save_state(env, state)
    response = provider_call(env, "mutate", action)
    result = response.get("result")
    if not isinstance(result, dict) or result.get("idempotency_key") != action["idempotency_key"]:
        raise LifecycleError("provider mutation result is not bound to the exact idempotency key")
    apply_action_result(env, state, action, result)
    state["pending_action"] = None
    save_state(env, state)


def apply_action_result(env, state, action, result):
    action_type = action["type"]
    slot = str(action.get("slot", ""))
    worker = state["workers"].get(slot) if slot else None
    if action_type in ("create", "resume"):
        if worker is None:
            raise LifecycleError("provider created capacity for an absent durable worker record")
        cloud = result.get("worker")
        if not isinstance(cloud, dict) or cloud.get("slot") != worker["slot"]:
            raise LifecycleError("provider create result returned the wrong worker slot")
        adopt_cloud_resources(worker, cloud)
        queue_item = state["queue"].get(worker["queue_key"])
        if queue_item is None:
            raise LifecycleError("created worker queue owner disappeared")
        queue_item["status"] = "assigned"
        queue_item["assignment_generation"] = worker["assignment_generation"]
        queue_item["slot"] = worker["slot"]
    elif action_type == "deallocate":
        if worker is None:
            raise LifecycleError("deallocate result has no durable worker owner")
        worker["phase"] = "deallocated"
        worker["cooldown_started_at"] = worker.get("cooldown_started_at") or iso_utc()
        worker["last_classification"] = "deallocated"
    elif action_type == "delete-compute":
        if worker is None:
            raise LifecycleError("compute deletion result has no durable worker owner")
        worker["phase"] = "compute-removed"
        cloud = result.get("worker")
        if cloud is not None:
            returned = cloud.get("resources") or {}
            for kind in ("task-disk", "account-disk", "identity", "role-assignment", "state-container"):
                resource = returned.get(kind)
                if resource is None:
                    raise LifecycleError("compute cleanup result lost exact retained {}".format(kind))
                worker.setdefault("resources", {})[kind] = resource_identity(resource)
        for kind in ("vm", "nic", "os-disk"):
            worker.get("resources", {}).pop(kind, None)
        worker["cloud_instance_id"] = None
        worker["last_classification"] = "orphaned-safe-to-delete"
    elif action_type == "reset":
        if worker is None:
            raise LifecycleError("reset result has no durable worker owner")
        queue_item = state["queue"].get(worker["queue_key"])
        if queue_item is not None:
            queue_item["status"] = "complete"
            queue_item["completed_at"] = iso_utc()
        if worker.get("assigned_at"):
            end = parse_time(worker.get("released_at") or iso_utc())
            state["completed_worker_seconds"] = float(state.get("completed_worker_seconds", 0.0)) + max(
                0.0, (end - parse_time(worker["assigned_at"])).total_seconds()
            )
        state["workers"].pop(slot, None)
    elif action_type == "steer":
        if worker is None:
            raise LifecycleError("steer result has no durable worker owner")
        worker["last_steer_digest"] = action["request_digest"]
        worker["last_steer_at"] = iso_utc()
    else:
        raise LifecycleError("unsupported provider mutation result: {}".format(action_type))


def replay_pending(env, state):
    action = state.get("pending_action")
    if action is None:
        return False
    response = provider_call(env, "mutate", action)
    result = response.get("result")
    if not isinstance(result, dict) or result.get("idempotency_key") != action.get("idempotency_key"):
        raise LifecycleError("replayed provider mutation is not idempotently bound")
    apply_action_result(env, state, action, result)
    state["pending_action"] = None
    save_state(env, state)
    return True


def refresh_classifications(state, inventory, now=None):
    cloud = inventory_by_slot(inventory)
    for worker in state["workers"].values():
        classification, note = classify_worker(worker, cloud.get(worker["slot"]), now=now)
        worker["last_classification"] = classification
        worker["classification_note"] = note


def choose_free_slot(env, state, inventory):
    occupied = set(int(slot) for slot in state["workers"])
    occupied.update(worker["slot"] for worker in inventory["workers"])
    for slot in range(1, env["max_workers"] + 1):
        if slot not in occupied:
            return slot
    return None


def next_reconcile_action(env, state, inventory, now=None):
    now = now or now_utc()
    cloud = inventory_by_slot(inventory)
    conflicts = inventory.get("conflicts", [])
    if conflicts:
        raise LifecycleError("provider found same-fleet worker-name conflicts; unrelated resources were not adopted")

    # Released work is the only path to ordinary destruction. With queued work,
    # reset immediately; otherwise deallocate first and honor the short cooldown.
    waiting = queued_items(state)
    for slot_key in sorted(state["workers"], key=int):
        worker = state["workers"][slot_key]
        current = cloud.get(worker["slot"])
        classification, note = classify_worker(worker, current, now=now)
        worker["last_classification"] = classification
        worker["classification_note"] = note
        if not worker.get("release_proof"):
            continue
        if classification == "retained-for-investigation":
            continue
        if classification == "assigned":
            return make_action(env, "deallocate", worker=worker)
        if classification == "deallocated":
            started = parse_time(worker["cooldown_started_at"]) if worker.get("cooldown_started_at") else now
            elapsed = (now - started).total_seconds()
            if waiting or elapsed >= env["cooldown_seconds"]:
                return make_action(
                    env, "delete-compute", worker=worker,
                    release_proof_digest=worker["release_proof"]["proof_digest"],
                )
            continue
        if classification == "orphaned-safe-to-delete":
            return make_action(
                env, "reset", worker=worker,
                release_proof_digest=worker["release_proof"]["proof_digest"],
            )

    if not waiting:
        return None
    if active_count(state, inventory) >= env["max_workers"]:
        return None
    slot = choose_free_slot(env, state, inventory)
    if slot is None:
        return None
    item = waiting[0]
    admitted, reason, reservation = admission_result(env, state, inventory, slot, item)
    if not admitted:
        return {"type": "admission-refused", "reason": reason, "slot": slot, "reservation_usd": reservation}
    worker = create_worker_record(env, state, slot, item, reservation)
    state["workers"][str(slot)] = worker
    item["status"] = "assigning"
    action = make_action(env, "create", worker=worker, item=item, reuse_retained=False)
    return action


def reconcile(env, state, apply, confirm_subscription):
    if apply and confirm_subscription != env["subscription"]:
        raise LifecycleError("--confirm-subscription must exactly match FM_AZURE_SUBSCRIPTION_ID")
    if apply and replay_pending(env, state):
        pass
    actions = []
    for _ in range(64):
        response = provider_call(env, "inventory")
        inventory = response["inventory"]
        state["last_metrics"] = metrics_from_inventory(inventory)
        refresh_classifications(state, inventory)
        action = next_reconcile_action(env, state, inventory)
        if action is None:
            save_state(env, state)
            return actions, inventory
        if action.get("type") == "admission-refused":
            actions.append(action)
            save_state(env, state)
            return actions, inventory
        actions.append(action)
        if not apply:
            # Dry planning may have allocated an in-memory worker record. Do not
            # persist or continue beyond the first mutation boundary.
            if action["type"] == "create":
                state["workers"].pop(str(action.get("slot")), None)
                key = request_key(action["request"]["task"], action["request"]["task_generation"])
                state["queue"][key]["status"] = "queued"
            return actions, inventory
        try:
            execute_action(env, state, action)
        except LifecycleError as exc:
            worker = state["workers"].get(str(action.get("slot")))
            record_refusal(state, worker, exc)
            save_state(env, state)
            raise
    raise LifecycleError("reconcile exceeded its bounded 64-action convergence allowance")


def release_receipt(state, path):
    proof = read_json(path, "worker release proof")
    if proof.get("schema") != RELEASE_SCHEMA:
        raise LifecycleError("worker release proof schema is not supported")
    supplied_digest = proof.get("proof_digest")
    unsigned = dict(proof)
    unsigned.pop("proof_digest", None)
    if supplied_digest != digest_value(unsigned):
        raise LifecycleError("worker release proof digest is not exact")
    for field in (
        "home_binding", "account_binding", "worktree_binding", "repository_binding",
        "endpoint_receipt", "report_receipt", "landed_work_receipt",
        "account_release_receipt", "cleanup_receipt",
    ):
        require_binding(field, proof.get(field))
    for field in ("task", "task_generation", "assignment_generation", "repository_generation"):
        require_id(field, proof.get(field))
    resources = proof.get("resources")
    if not isinstance(resources, dict) or set(resources) != set(REQUIRED_RESOURCE_KINDS):
        raise LifecycleError("worker release proof must bind every exact worker resource")
    for kind, identity in resources.items():
        if not isinstance(identity, dict) or not identity.get("id") or not identity.get("immutable_id"):
            raise LifecycleError("worker release proof {} identity is incomplete".format(kind))
    return proof


def verify_release_against_worker(proof, worker):
    bindings = worker["bindings"]
    checks = {
        "home_binding": bindings["home_binding"],
        "task": bindings["task"],
        "task_generation": bindings["task_generation"],
        "assignment_generation": worker["assignment_generation"],
        "account_binding": bindings["account_binding"],
        "worktree_binding": bindings["worktree_binding"],
        "repository_binding": bindings["repository_binding"],
        "repository_generation": bindings["repository_generation"],
        "cloud_instance_id": worker["cloud_instance_id"],
        "resources": worker["resources"],
    }
    for field, expected in checks.items():
        if proof.get(field) != expected:
            raise LifecycleError("worker release proof {} binding is not exact".format(field))


def proof_template(state, task, generation):
    key = request_key(task, generation)
    item = state["queue"].get(key)
    if item is None or item.get("status") != "assigned":
        raise LifecycleError("proof template requires one exact assigned queue item")
    worker = state["workers"].get(str(item.get("slot")))
    if worker is None or worker.get("queue_key") != key:
        raise LifecycleError("assigned queue item has no exact worker owner")
    proof = {
        "schema": RELEASE_SCHEMA,
        "home_binding": worker["bindings"]["home_binding"],
        "task": task,
        "task_generation": generation,
        "assignment_generation": worker["assignment_generation"],
        "account_binding": worker["bindings"]["account_binding"],
        "worktree_binding": worker["bindings"]["worktree_binding"],
        "repository_binding": worker["bindings"]["repository_binding"],
        "repository_generation": worker["bindings"]["repository_generation"],
        "cloud_instance_id": worker["cloud_instance_id"],
        "resources": worker["resources"],
        "endpoint_receipt": "REPLACE_WITH_SHA256",
        "report_receipt": "REPLACE_WITH_SHA256",
        "landed_work_receipt": "REPLACE_WITH_SHA256",
        "account_release_receipt": "REPLACE_WITH_SHA256",
        "cleanup_receipt": "REPLACE_WITH_SHA256",
        "proof_digest": "RECOMPUTE_FROM_ALL_OTHER_FIELDS",
    }
    return proof


def status_projection(env, state, inventory=None):
    if inventory is None:
        metrics = state.get("last_metrics") or {}
        actual_active = sum(
            1 for worker in state["workers"].values()
            if worker.get("last_classification") == "assigned"
        )
        desired = min(
            sum(1 for item in state["queue"].values() if item.get("status") in ("queued", "assigned")),
            env["max_workers"],
        )
    else:
        metrics = metrics_from_inventory(inventory)
        actual_active = active_count(state, inventory)
        desired = desired_count(env, state, inventory)
    classes = {name: 0 for name in (
        "assigned", "clean-warm", "deallocated", "orphaned-safe-to-delete", "retained-for-investigation"
    )}
    assignment_generations = []
    retained_disks = 0
    for worker in state["workers"].values():
        classification = worker.get("last_classification", "retained-for-investigation")
        classes[classification] = classes.get(classification, 0) + 1
        assignment_generations.append(worker["assignment_generation"])
        if classification == "retained-for-investigation":
            retained_disks += sum(
                1 for kind in ("task-disk", "account-disk") if kind in worker.get("resources", {})
            )
    hours = worker_seconds(state) / 3600.0
    return {
        "schema": "fm.worker-status/v1",
        "queue_depth": sum(1 for item in state["queue"].values() if item.get("status") != "complete"),
        "eligible_queue_depth": sum(1 for item in state["queue"].values() if item.get("status") == "queued" and item.get("eligible")),
        "desired_active_workers": desired,
        "actual_active_workers": actual_active,
        "classification_counts": classes,
        "assignment_generations": sorted(assignment_generations),
        "worker_hours": round(hours, 3),
        "worker_hour_planning_threshold": env["planning_hours"],
        "worker_hour_warning": hours >= env["planning_hours"],
        "actual_spend_usd": metrics.get("actual_usd"),
        "forecast_spend_usd": metrics.get("forecast_usd"),
        "policy_phase": env["policy_phase"],
        "active_admission_limit_usd": budget_limit(env),
        "planning_target_usd": env["steady_target_usd"],
        "commissioning_ceiling_usd": env["commissioning_ceiling_usd"],
        "idle_cooldown_seconds": env["cooldown_seconds"],
        "warm_idle_target": env["warm_idle"],
        "retained_disks": retained_disks,
        "cleanup_refusals": state["cleanup_refusals"][-10:],
    }


def print_status(status, json_output):
    if json_output:
        print(json.dumps(status, sort_keys=True, separators=(",", ":")))
        return
    print("queue: depth={} eligible={}".format(status["queue_depth"], status["eligible_queue_depth"]))
    print("workers: desired={} active={} classes={}".format(
        status["desired_active_workers"], status["actual_active_workers"],
        json.dumps(status["classification_counts"], sort_keys=True, separators=(",", ":")),
    ))
    print("assignments: {}".format(",".join(status["assignment_generations"]) or "none"))
    print("worker-hours: {:.3f}/{} warning={}".format(
        status["worker_hours"], status["worker_hour_planning_threshold"],
        str(status["worker_hour_warning"]).lower(),
    ))
    print("cost: actual={} forecast={} phase={} admission-limit={} planning-target={} commissioning-ceiling={}".format(
        status["actual_spend_usd"], status["forecast_spend_usd"], status["policy_phase"],
        status["active_admission_limit_usd"], status["planning_target_usd"],
        status["commissioning_ceiling_usd"],
    ))
    print("idle: cooldown={}s warm={} retained-disks={} cleanup-refusals={}".format(
        status["idle_cooldown_seconds"], status["warm_idle_target"],
        status["retained_disks"], len(status["cleanup_refusals"]),
    ))


def parser():
    top = argparse.ArgumentParser(description="Queue-driven provider-neutral elastic worker lifecycle")
    sub = top.add_subparsers(dest="command", required=True)
    request = sub.add_parser("request", help="enqueue one exact eligible author task")
    request.add_argument("--task", required=True)
    request.add_argument("--task-generation", required=True)
    request.add_argument("--home-binding", required=True)
    request.add_argument("--account-binding", required=True)
    request.add_argument("--worktree-binding", required=True)
    request.add_argument("--repository-binding", required=True)
    request.add_argument("--repository-generation", required=True)
    request.add_argument("--owner-kind", choices=("primary", "secondmate"), required=True)
    request.add_argument("--eligible", action="store_true")
    request.add_argument("--required", action="store_true", help="mark non-discretionary recovery/landing work")

    reconcile_parser = sub.add_parser("reconcile", help="plan or apply bounded convergence")
    reconcile_parser.add_argument("--apply", action="store_true")
    reconcile_parser.add_argument("--confirm-subscription")
    reconcile_parser.add_argument("--json", action="store_true")

    proof = sub.add_parser("proof-template", help="print the exact release-receipt skeleton")
    proof.add_argument("--task", required=True)
    proof.add_argument("--task-generation", required=True)

    release = sub.add_parser("release", help="accept exact ordinary lifecycle proofs")
    release.add_argument("--task", required=True)
    release.add_argument("--task-generation", required=True)
    release.add_argument("--proof-file", required=True)

    resume = sub.add_parser("resume", help="reattach exact retained dirty task capacity")
    resume.add_argument("--task", required=True)
    resume.add_argument("--task-generation", required=True)
    resume.add_argument("--repository-binding", required=True)
    resume.add_argument("--confirm-resume", action="store_true")
    resume.add_argument("--confirm-subscription", required=True)

    steer = sub.add_parser("steer", help="send one digest-bound request to the minimal guest supervisor")
    steer.add_argument("--task", required=True)
    steer.add_argument("--task-generation", required=True)
    steer.add_argument("--assignment-generation", required=True)
    steer.add_argument("--request-digest", required=True)
    steer.add_argument("--confirm-steer", action="store_true")
    steer.add_argument("--confirm-subscription", required=True)

    status = sub.add_parser("status", help="show bounded local lifecycle and cost evidence")
    status.add_argument("--live", action="store_true")
    status.add_argument("--json", action="store_true")

    sub.add_parser("acceptance-plan", help="print the isolated post-release acceptance checklist")
    return top


def command_request(env, args):
    item = {
        "schema": REQUEST_SCHEMA,
        "task": args.task,
        "task_generation": args.task_generation,
        "home_binding": args.home_binding,
        "account_binding": args.account_binding,
        "worktree_binding": args.worktree_binding,
        "repository_binding": args.repository_binding,
        "repository_generation": args.repository_generation,
        "owner_kind": args.owner_kind,
        "role": "author",
        "eligible": args.eligible,
        "discretionary": not args.required,
        "status": "queued",
        "enqueued_at": iso_utc(),
    }
    verify_request(item)
    key = request_key(item["task"], item["task_generation"])
    with controller_lock(env):
        state = load_state(env)
        existing = state["queue"].get(key)
        if existing is not None:
            identity_fields = (
                "schema", "task", "task_generation", "home_binding", "account_binding",
                "worktree_binding", "repository_binding", "repository_generation",
                "owner_kind", "role", "eligible", "discretionary",
            )
            if any(existing.get(field) != item.get(field) for field in identity_fields):
                raise LifecycleError("task generation already exists with different queue identity")
            print("request already exists with exact identity")
            return
        ensure_unique_bindings(state, item)
        state["queue"][key] = item
        save_state(env, state)
    print("queued {} generation {} for one isolated author worker".format(item["task"], item["task_generation"]))


def public_action(action):
    value = {
        key: action[key]
        for key in ("type", "slot", "sku", "sku_family", "reason", "reservation_usd")
        if key in action
    }
    if isinstance(action.get("bindings"), dict):
        value["assignment_generation"] = action["bindings"]["assignment_generation"]
    return value


def command_reconcile(env, args):
    with controller_lock(env):
        state = load_state(env)
        actions, inventory = reconcile(env, state, args.apply, args.confirm_subscription)
        status = status_projection(env, state, inventory)
    safe_actions = [public_action(action) for action in actions]
    output = {"actions": safe_actions, "status": status}
    if args.json:
        print(json.dumps(output, sort_keys=True, separators=(",", ":")))
    else:
        for action in safe_actions:
            if action["type"] == "admission-refused":
                print("admission refused: {}".format(action["reason"]))
            else:
                print("{}: slot={} generation={}".format(
                    action["type"], action.get("slot"),
                    (action.get("bindings") or {}).get("assignment_generation", "n/a"),
                ))
        print_status(status, False)


def command_release(env, args):
    require_id("task", args.task)
    require_id("task generation", args.task_generation)
    with controller_lock(env):
        state = load_state(env)
        key = request_key(args.task, args.task_generation)
        item = state["queue"].get(key)
        if item is None or item.get("status") != "assigned":
            raise LifecycleError("release requires one exact assigned task generation")
        worker = state["workers"].get(str(item.get("slot")))
        if worker is None:
            raise LifecycleError("release task has no exact durable worker owner")
        proof = release_receipt(state, args.proof_file)
        verify_release_against_worker(proof, worker)
        if worker.get("release_proof") is not None:
            if worker["release_proof"] != proof:
                raise LifecycleError("worker already has a different release proof")
            print("release proof already recorded with exact identity")
            return
        worker["release_proof"] = proof
        worker["released_at"] = iso_utc()
        worker["phase"] = "release-proved"
        item["status"] = "releasing"
        save_state(env, state)
    print("release proofs recorded; only exact idle capacity is now eligible for deallocation and reset")


def command_resume(env, args):
    if not args.confirm_resume:
        raise LifecycleError("--confirm-resume is required")
    if args.confirm_subscription != env["subscription"]:
        raise LifecycleError("--confirm-subscription must exactly match FM_AZURE_SUBSCRIPTION_ID")
    require_binding("repository binding", args.repository_binding)
    with controller_lock(env):
        state = load_state(env)
        if state.get("pending_action") is not None:
            replay_pending(env, state)
        key = request_key(require_id("task", args.task), require_id("task generation", args.task_generation))
        item = state["queue"].get(key)
        if item is None or item.get("status") != "assigned":
            raise LifecycleError("resume requires one exact assigned task generation")
        worker = state["workers"].get(str(item.get("slot")))
        if worker is None or worker.get("queue_key") != key:
            raise LifecycleError("retained task has no exact durable worker owner")
        if worker.get("release_proof") is not None:
            raise LifecycleError("released work cannot use dirty-task resume")
        if worker.get("bindings", {}).get("repository_binding") != args.repository_binding:
            raise LifecycleError("retained repository/task generation proof is not exact")
        inventory = provider_call(env, "inventory")["inventory"]
        cloud = inventory_by_slot(inventory).get(worker["slot"])
        classification, reason = classify_worker(worker, cloud)
        if classification != "retained-for-investigation" or cloud is None:
            raise LifecycleError("resume requires retained dirty disks and a missing worker VM: {}".format(reason))
        resources = cloud.get("resources") or {}
        if any(resources.get(kind) is not None for kind in ("vm", "nic", "os-disk")) or not resources.get("task-disk") or not resources.get("account-disk"):
            raise LifecycleError("resume requires exact retained task/account disks and no VM/NIC/OS disk")
        exact, identity_reason = resources_exact(worker, cloud, allow_missing_compute=True)
        if not exact:
            raise LifecycleError("retained disk identity proof failed: {}".format(identity_reason))
        for kind in ("vm", "nic", "os-disk"):
            worker.get("resources", {}).pop(kind, None)
        worker["cloud_instance_id"] = None
        previous_cloud_generation = worker["cloud_generation"]
        worker["cloud_generation"] += 1
        worker["phase"] = "resuming"
        action = make_action(
            env, "resume", worker=worker, item=item, reuse_retained=True,
            previous_cloud_generation=previous_cloud_generation,
        )
        execute_action(env, state, action)
    print("replacement generation attached the exact retained task and account disks")


def command_steer(env, args):
    if not args.confirm_steer:
        raise LifecycleError("--confirm-steer is required")
    if args.confirm_subscription != env["subscription"]:
        raise LifecycleError("--confirm-subscription must exactly match FM_AZURE_SUBSCRIPTION_ID")
    request_digest = require_binding("steer request digest", args.request_digest)
    with controller_lock(env):
        state = load_state(env)
        key = request_key(require_id("task", args.task), require_id("task generation", args.task_generation))
        item = state["queue"].get(key)
        if item is None or item.get("status") != "assigned":
            raise LifecycleError("steer requires one exact assigned task generation")
        worker = state["workers"].get(str(item.get("slot")))
        if worker is None or worker["assignment_generation"] != args.assignment_generation:
            raise LifecycleError("steer assignment generation is not exact")
        inventory = provider_call(env, "inventory")["inventory"]
        cloud = inventory_by_slot(inventory).get(worker["slot"])
        classification, reason = classify_worker(worker, cloud)
        if classification != "assigned":
            raise LifecycleError("steer refuses a non-assigned or ambiguous worker: {}".format(reason))
        action = make_action(env, "steer", worker=worker, request_digest=request_digest)
        execute_action(env, state, action)
    print("steer request digest delivered to the exact worker generation")


def command_status(env, args):
    with controller_lock(env):
        state = load_state(env)
        inventory = None
        if args.live:
            inventory = provider_call(env, "inventory")["inventory"]
            state["last_metrics"] = metrics_from_inventory(inventory)
            refresh_classifications(state, inventory)
            save_state(env, state)
        projection = status_projection(env, state, inventory)
    print_status(projection, args.json)


def command_proof_template(env, args):
    with controller_lock(env):
        state = load_state(env)
        proof = proof_template(
            state, require_id("task", args.task), require_id("task generation", args.task_generation)
        )
    print(json.dumps(proof, sort_keys=True, indent=2))


def acceptance_plan():
    print("""Post-release Azure acceptance (every leg also needs an unsafe positive control):
1. Start from zero and admit at least three parallel representative author tasks.
2. Finish one while another request waits; prove delete/reset precedes the next assignment generation.
3. Drain all work; prove active worker VMs reach zero and disposable VM/NIC/OS disks are absent.
4. Delete one unfinished worker VM; prove its exact task disk is retained and resumes only by explicit exact-generation recovery.
5. Restart after a submitted create; prove the idempotency key yields one cloud assignment.
6. Force actual and forecast budget pressure; prove new author admission stops and active work remains.
7. Probe public ingress plus account, worktree, browser, process, socket, cache, and cloud-identity residue across generations.
8. Use deliberately foreign tags/IDs, a stale result, a shared lease, a public rule, and planted residue as positive controls.
Do not run this acceptance until the reviewed foundation is released and the operator explicitly authorizes billable reconciliation.""")


def main(argv=None):
    args = parser().parse_args(argv)
    if args.command == "acceptance-plan":
        acceptance_plan()
        return 0
    env = environment()
    if args.command == "request":
        command_request(env, args)
    elif args.command == "reconcile":
        command_reconcile(env, args)
    elif args.command == "proof-template":
        command_proof_template(env, args)
    elif args.command == "release":
        command_release(env, args)
    elif args.command == "resume":
        command_resume(env, args)
    elif args.command == "steer":
        command_steer(env, args)
    elif args.command == "status":
        command_status(env, args)
    else:
        raise LifecycleError("unknown lifecycle command")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except LifecycleError as exc:
        print("ELASTIC WORKER REFUSED: {}".format(exc), file=sys.stderr)
        raise SystemExit(2)
