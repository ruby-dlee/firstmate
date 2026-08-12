#!/usr/bin/env python3
"""Dedicated Azure compartment adapter for policy-grade Crosscheck.

This module owns only the remote execution boundary and its durable identity.
The existing fm-crosscheck.py core continues to own GitHub snapshots, reviewer
selection, finding lifecycle, readable reports, and expected-head merge gating.

The adapter creates three independent disposable private VMs per attempt:

- a credentialed model compartment with no repository shell;
- an uncredentialed networkless tool compartment for repository commands; and
- a second fresh networkless verifier compartment for independent replay.

See docs/azure-crosscheck.md for the operator and acceptance contract.
"""

from __future__ import annotations

import base64
import contextlib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time
from typing import Any


SCHEMA = "fm.azure-crosscheck/v1"
RESULT_SCHEMA = "fm.azure-crosscheck-result/v1"
EXECUTION_MODE = "azure-compartment-v1"
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", re.I)
MAX_CONFIG_BYTES = 64 * 1024
MAX_RESULT_BYTES = 2 * 1024 * 1024
MAX_PROMPT_BYTES = 2 * 1024 * 1024
MAX_AZURE_CALL_SECONDS = 300
MAX_REVIEW_SECONDS = 7200
MODEL_CAPTURE_BYTES = 16 * 1024 * 1024
MAX_ACTIVE_REVIEWS = 4
STAGING_CONTAINER = "validation-shards"

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "docs" / "azure-crosscheck" / "compartment.json"
MODEL_GUEST = ROOT / "bin" / "fm-crosscheck-azure-model-guest.sh"
RUNNER_CONTROLLER = ROOT / "bin" / "fm-azure-runner.py"
RUNNER_GUEST = ROOT / "bin" / "fm-azure-runner-guest.sh"
RUNNER_EXECUTOR = ROOT / "bin" / "fm-azure-runner-exec.py"


class AzureCrosscheckError(RuntimeError):
    """Remote compartment or identity failure."""


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def digest_bytes(value: bytes) -> str:
    return "sha256:" + hashlib.sha256(value).hexdigest()


def digest_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                return "sha256:" + digest.hexdigest()
            digest.update(chunk)


def bounded_environment_integer(name: str, default: int, minimum: int, maximum: int) -> int:
    raw = os.environ.get(name, str(default))
    try:
        value = int(raw)
    except ValueError as exc:
        raise AzureCrosscheckError(f"{name} must be an integer") from exc
    if not minimum <= value <= maximum:
        raise AzureCrosscheckError(f"{name} must be between {minimum} and {maximum}")
    return value


def run_command(
    argv: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    stdin: bytes | None = None,
    timeout: int = MAX_AZURE_CALL_SECONDS,
    maximum_output: int = MODEL_CAPTURE_BYTES,
    check: bool = True,
) -> subprocess.CompletedProcess[bytes]:
    try:
        result = subprocess.run(
            argv,
            cwd=str(cwd) if cwd else None,
            env=env,
            input=stdin,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise AzureCrosscheckError(
            f"command exceeded its {timeout}-second deadline: {argv[0]}"
        ) from exc
    if len(result.stdout) + len(result.stderr) > maximum_output:
        raise AzureCrosscheckError(
            f"command output exceeded its {maximum_output}-byte bound: {argv[0]}"
        )
    if check and result.returncode != 0:
        detail = (result.stderr or result.stdout).decode("utf-8", errors="replace")[-1000:]
        raise AzureCrosscheckError(
            f"command failed ({result.returncode}): {argv[0]}: {detail or 'no diagnostic'}"
        )
    return result


def load_runner() -> Any:
    spec = importlib.util.spec_from_file_location("firstmate_azure_runner", RUNNER_CONTROLLER)
    if spec is None or spec.loader is None:
        raise AzureCrosscheckError("Azure command-runner controller is unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def azure_review_enabled(home: Path) -> bool:
    explicit = os.environ.get("FM_CROSSCHECK_EXECUTION_MODE")
    if explicit:
        if explicit not in {"local", "azure"}:
            raise AzureCrosscheckError(
                "FM_CROSSCHECK_EXECUTION_MODE must be exactly local or azure"
            )
        return explicit == "azure"
    config = home / "config" / "crosscheck-azure.json"
    if not config.exists():
        return False
    value = read_config(config)
    enabled = value.get("enabled", True)
    if not isinstance(enabled, bool):
        raise AzureCrosscheckError("config/crosscheck-azure.json enabled must be boolean")
    return enabled


def read_config(path: Path) -> dict[str, Any]:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_mode & 0o022:
            raise AzureCrosscheckError(
                f"Azure Crosscheck config must be a non-group/world-writable regular file: {path}"
            )
        raw = os.read(descriptor, MAX_CONFIG_BYTES + 1)
    finally:
        os.close(descriptor)
    if len(raw) > MAX_CONFIG_BYTES:
        raise AzureCrosscheckError("Azure Crosscheck config exceeds its byte bound")
    try:
        value = json.loads(raw)
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise AzureCrosscheckError(f"Azure Crosscheck config is malformed: {exc}") from exc
    if not isinstance(value, dict):
        raise AzureCrosscheckError("Azure Crosscheck config must be an object")
    return value


def runtime_config(home: Path) -> dict[str, Any]:
    file_value: dict[str, Any] = {}
    path = home / "config" / "crosscheck-azure.json"
    if path.exists():
        file_value = read_config(path)
    required_env = (
        "FM_AZURE_TENANT_ID",
        "FM_AZURE_SUBSCRIPTION_ID",
        "FM_AZURE_NAMING_PREFIX",
        "FM_AZURE_STORAGE_NAME",
        "FM_AZURE_DEPLOYMENT_GENERATION",
    )
    missing = [name for name in required_env if not os.environ.get(name)]
    if missing:
        raise AzureCrosscheckError(
            "Azure Crosscheck environment is missing: " + ", ".join(missing)
        )
    provider_host = file_value.get("provider_host") or os.environ.get("FM_CROSSCHECK_PROVIDER_HOST")
    provider_port = file_value.get("provider_port") or os.environ.get("FM_CROSSCHECK_PROVIDER_PORT")
    github_host = file_value.get("github_metadata_host") or "api.github.com"
    if not isinstance(provider_host, str) or not provider_host or ":" in provider_host:
        raise AzureCrosscheckError("Azure Crosscheck provider_host must be one exact DNS name")
    if not isinstance(github_host, str) or not github_host or ":" in github_host:
        raise AzureCrosscheckError("Azure Crosscheck github_metadata_host must be one exact DNS name")
    try:
        port = int(provider_port)
    except (TypeError, ValueError) as exc:
        raise AzureCrosscheckError("Azure Crosscheck provider_port must be an integer") from exc
    if not 1 <= port <= 65535:
        raise AzureCrosscheckError("Azure Crosscheck provider_port is out of range")
    subscription = os.environ["FM_AZURE_SUBSCRIPTION_ID"]
    if not UUID_RE.fullmatch(subscription):
        raise AzureCrosscheckError("FM_AZURE_SUBSCRIPTION_ID must be an exact UUID")
    resource_group = file_value.get("resource_group") or os.environ.get(
        "FM_AZURE_RESOURCE_GROUP", "rg-firstmate-pilot-eastus-001"
    )
    prefix = os.environ["FM_AZURE_NAMING_PREFIX"]
    reviewer_sku = file_value.get("reviewer_sku", "Standard_D4as_v6")
    model_image_id = file_value.get("model_image_id") or os.environ.get(
        "FM_CROSSCHECK_AZURE_MODEL_IMAGE_ID"
    )
    if (
        not isinstance(model_image_id, str)
        or not model_image_id.startswith("/subscriptions/")
        or "/images/" not in model_image_id.lower()
    ):
        raise AzureCrosscheckError(
            "Azure Crosscheck requires exact FM_CROSSCHECK_AZURE_MODEL_IMAGE_ID"
        )
    runner = load_runner()
    if reviewer_sku not in runner.SKU_FAMILY:
        raise AzureCrosscheckError("Azure Crosscheck reviewer SKU is not reviewed")
    return {
        "tenant": os.environ["FM_AZURE_TENANT_ID"],
        "subscription": subscription,
        "prefix": prefix,
        "storage": os.environ["FM_AZURE_STORAGE_NAME"],
        "deployment_generation": os.environ["FM_AZURE_DEPLOYMENT_GENERATION"],
        "resource_group": resource_group,
        "provider_host": provider_host,
        "provider_port": port,
        "github_host": github_host,
        "reviewer_sku": reviewer_sku,
        "model_image_id": model_image_id,
        "max_concurrency": bounded_environment_integer(
            "FM_CROSSCHECK_AZURE_MAX_CONCURRENCY", MAX_ACTIVE_REVIEWS, 1, 8
        ),
        "timeout_seconds": bounded_environment_integer(
            "FM_CROSSCHECK_REVIEWER_TIMEOUT_SECONDS", 1800, 30, MAX_REVIEW_SECONDS
        ),
    }


def az(config: dict[str, Any], args: list[str], *, check: bool = True) -> Any:
    command = [
        "az",
        *args,
        "--subscription",
        config["subscription"],
        "--only-show-errors",
        "--output",
        "json",
    ]
    result = run_command(command, check=check)
    if result.returncode != 0:
        return None, result.returncode, result.stderr.decode("utf-8", errors="replace")
    try:
        return json.loads(result.stdout or b"null"), 0, ""
    except json.JSONDecodeError as exc:
        raise AzureCrosscheckError(f"Azure CLI returned malformed JSON: {exc}") from exc


def verify_scope_and_foundation(config: dict[str, Any]) -> Any:
    runner = load_runner()
    try:
        runner_env = runner.environment()
        runner.scope_gate(runner_env)
        runner.foundation_gate(runner_env)
        runner.sku_quota_gate(
            runner_env,
            {
                "sku": config["reviewer_sku"],
                "sku_family": runner.SKU_FAMILY[config["reviewer_sku"]],
            },
        )
        runner.budget_gate(
            runner_env, {"sku": config["reviewer_sku"], "network_bytes": 0}
        )
    except runner.RunnerError as exc:
        raise AzureCrosscheckError(f"Azure foundation/runner preflight failed: {exc}") from exc
    return runner


def review_identity(
    *,
    home: Path,
    task_id: str,
    pr_url: str,
    snapshot_value: dict[str, Any],
    config: dict[str, str],
    ledger: dict[str, Any],
) -> dict[str, str]:
    claims = snapshot_value["claims_sha256"]
    ledger_digest = digest_bytes(canonical_bytes(ledger))
    author = {
        "home_binding": digest_bytes(str(home.resolve()).encode("utf-8")),
        "task_id": task_id,
        "pull_request": pr_url.rstrip("/"),
        "head_sha": snapshot_value["head_sha"],
        "base_sha": snapshot_value["base_sha"],
        "base_branch_sha": snapshot_value["base_branch_sha"],
        "claims_sha256": claims,
        "reviewer_harness": config["harness"],
        "reviewer_model": config["model"],
        "reviewer_effort": config["effort"],
        "reviewer_account_digest": digest_bytes(
            str(Path(config["account_home"]).resolve()).encode("utf-8")
        ),
        "ledger_digest": ledger_digest,
    }
    generation = digest_bytes(canonical_bytes(author)).split(":", 1)[1][:24]
    author["review_generation"] = generation
    return author


def inspect_reviewer_credential(core: Any, config: dict[str, str]) -> tuple[Path, str, str]:
    account_home = Path(config["account_home"]).resolve()
    if config["harness"] == "codex":
        source, identifier = core.inspect_codex_credential(account_home)
        credential = account_home / "auth.json"
    elif config["harness"] == "pi":
        source, identifier = core.inspect_pi_credential(account_home)
        credential = account_home / "auth.json"
    else:
        credential = account_home / ".credentials.json"
        if not credential.is_file() or credential.is_symlink():
            raise AzureCrosscheckError(
                "Azure Claude review requires a Linux-portable file credential; the macOS Keychain is never copied"
            )
        source, identifier = "oauth-file", str(credential)
    if not credential.is_file() or credential.is_symlink():
        raise AzureCrosscheckError("reviewer credential must be a regular non-symlink file")
    return credential, source, identifier


def create_credential_archive(
    destination: Path, credential: Path, identity: dict[str, str], config: dict[str, str]
) -> tuple[str, str]:
    credential_bytes = credential.read_bytes()
    if len(credential_bytes) > MAX_CONFIG_BYTES:
        raise AzureCrosscheckError("reviewer credential exceeds its byte bound")
    material = {
        "schema": SCHEMA,
        "review_generation": identity["review_generation"],
        "harness": config["harness"],
        "model": config["model"],
        "effort": config["effort"],
        "credential_name": "auth.json" if config["harness"] in {"codex", "pi"} else ".credentials.json",
        "credential_digest": digest_bytes(credential_bytes),
    }
    payload = {
        "manifest.json": canonical_bytes(material) + b"\n",
        material["credential_name"]: credential_bytes,
    }
    import tarfile

    with tarfile.open(destination, "w:gz", format=tarfile.PAX_FORMAT) as archive:
        for name, content in payload.items():
            info = tarfile.TarInfo(name)
            info.size = len(content)
            info.mode = 0o600
            info.uid = 0
            info.gid = 0
            info.mtime = 0
            archive.addfile(info, __import__("io").BytesIO(content))
    return digest_file(destination), material["credential_digest"]


def write_json(path: Path, value: Any) -> None:
    encoded = canonical_bytes(value) + b"\n"
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(encoded)
        handle.flush()
        os.fsync(handle.fileno())


def upload_blob(config: dict[str, Any], local: Path, blob: str) -> None:
    _value, rc, detail = az(
        config,
        [
            "storage",
            "blob",
            "upload",
            "--auth-mode",
            "login",
            "--account-name",
            config["storage"],
            "--container-name",
            STAGING_CONTAINER,
            "--name",
            blob,
            "--file",
            str(local),
            "--overwrite",
            "false",
        ],
        check=False,
    )
    if rc != 0:
        raise AzureCrosscheckError(f"exact Azure Crosscheck input staging failed: {detail}")


def download_blob(config: dict[str, Any], blob: str, local: Path) -> None:
    _value, rc, detail = az(
        config,
        [
            "storage",
            "blob",
            "download",
            "--auth-mode",
            "login",
            "--account-name",
            config["storage"],
            "--container-name",
            STAGING_CONTAINER,
            "--name",
            blob,
            "--file",
            str(local),
            "--overwrite",
            "false",
        ],
        check=False,
    )
    if rc != 0:
        raise AzureCrosscheckError(f"exact Azure Crosscheck result collection failed: {detail}")


def blob_sas(config: dict[str, Any], blob: str, permissions: str, expiry: str) -> str:
    value, rc, detail = az(
        config,
        [
            "storage",
            "blob",
            "generate-sas",
            "--auth-mode",
            "login",
            "--as-user",
            "--account-name",
            config["storage"],
            "--container-name",
            STAGING_CONTAINER,
            "--name",
            blob,
            "--permissions",
            permissions,
            "--expiry",
            expiry,
            "--https-only",
            "--full-uri",
        ],
        check=False,
    )
    if rc != 0 or not isinstance(value, str) or not value.startswith("https://"):
        raise AzureCrosscheckError(f"exact Azure Crosscheck object capability failed: {detail}")
    return value


def active_review_vms(config: dict[str, Any]) -> int:
    value, _rc, _detail = az(
        config,
        ["vm", "list", "--resource-group", config["resource_group"], "--show-details"],
    )
    return sum(
        1
        for vm in value
        if (vm.get("tags") or {}).get("firstmate-role") == "crosscheck-model"
        and "deallocated" not in str(vm.get("powerState", "")).lower()
    )


def provision_model_vm(
    config: dict[str, Any], identity: dict[str, str], staged: dict[str, str]
) -> dict[str, Any]:
    token = identity["review_generation"][:12]
    vm_name = f"vm-{config['prefix']}-ccm-{token}"
    nic_name = f"nic-{config['prefix']}-ccm-{token}"
    disk_name = f"disk-{config['prefix']}-ccm-{token}-os"
    deployment = f"fm-crosscheck-model-{token}"
    tags = {
        "workload": "firstmate",
        "firstmate-role": "crosscheck-model",
        "deployment-generation": config["deployment_generation"],
        "review-generation": identity["review_generation"],
        "head-binding": identity["head_sha"],
        "claims-binding": identity["claims_sha256"],
        "ledger-binding": identity["ledger_digest"],
    }
    expiry = time.strftime(
        "%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + config["timeout_seconds"] + 1800)
    )
    subnet_id = (
        f"/subscriptions/{config['subscription']}/resourceGroups/{config['resource_group']}"
        f"/providers/Microsoft.Network/virtualNetworks/vnet-{config['prefix']}-eus"
        "/subnets/snet-policy-review"
    )
    parameters = {
        "region": {"value": "eastus"},
        "vmName": {"value": vm_name},
        "nicName": {"value": nic_name},
        "osDiskName": {"value": disk_name},
        "subnetId": {"value": subnet_id},
        "vmSize": {"value": config["reviewer_sku"]},
        "expiryUtc": {"value": expiry},
        "tags": {"value": tags},
        "modelImageId": {"value": config["model_image_id"]},
        "providerHost": {"value": config["provider_host"]},
        "providerPort": {"value": config["provider_port"]},
        "githubMetadataHost": {"value": config["github_host"]},
    }
    temporary = Path(tempfile.mkstemp(prefix=".fm-crosscheck-model-", suffix=".json")[1])
    try:
        os.chmod(temporary, 0o600)
        temporary.write_bytes(canonical_bytes(parameters) + b"\n")
        result, rc, detail = az(
            config,
            [
                "deployment",
                "group",
                "create",
                "--resource-group",
                config["resource_group"],
                "--name",
                deployment,
                "--template-file",
                str(TEMPLATE),
                "--parameters",
                "@" + str(temporary),
            ],
            check=False,
        )
    finally:
        temporary.unlink(missing_ok=True)
    if rc != 0:
        raise AzureCrosscheckError(f"credentialed model compartment creation failed: {detail}")
    vm_id = result["properties"]["outputs"]["vmId"]["value"]
    return {
        "deployment": deployment,
        "vm_name": vm_name,
        "nic_name": nic_name,
        "os_disk_name": disk_name,
        "vm_id": vm_id,
        "tags": tags,
        "staged": staged,
    }


def submit_model_run(
    config: dict[str, Any], identity: dict[str, str], resources: dict[str, Any]
) -> dict[str, Any]:
    vm, rc, detail = az(
        config,
        ["vm", "show", "--ids", resources["vm_id"], "--expand", "instanceView"],
        check=False,
    )
    if rc != 0:
        raise AzureCrosscheckError(f"model compartment identity is unreadable: {detail}")
    instance_id = vm.get("properties", {}).get("vmId")
    if not instance_id:
        raise AzureCrosscheckError("model compartment has no immutable VM instance identity")
    expiry = time.strftime("%Y-%m-%dT%H:%MZ", time.gmtime(time.time() + config["timeout_seconds"] + 1200))
    input_url = blob_sas(config, resources["staged"]["input_blob"], "r", expiry)
    credential_url = blob_sas(config, resources["staged"]["credential_blob"], "r", expiry)
    output_url = blob_sas(config, resources["staged"]["output_blob"], "cw", expiry)
    guest_digest = digest_file(MODEL_GUEST)
    script = MODEL_GUEST.read_text(encoding="utf-8")
    run_name = "review"
    command_id = resources["vm_id"] + "/runCommands/" + run_name
    body = {
        "location": "eastus",
        "tags": resources["tags"],
        "properties": {
            "source": {"script": script},
            "parameters": [
                {"name": "review_generation", "value": identity["review_generation"]},
                {"name": "vm_resource_id", "value": resources["vm_id"]},
                {"name": "vm_instance_id", "value": instance_id},
                {"name": "guest_digest", "value": guest_digest},
            ],
            "protectedParameters": [
                {"name": "input_url", "value": input_url},
                {"name": "credential_url", "value": credential_url},
                {"name": "output_url", "value": output_url},
            ],
            "asyncExecution": True,
            "timeoutInSeconds": config["timeout_seconds"] + 600,
            "treatFailureAsDeploymentFailure": True,
        },
    }
    temporary = Path(tempfile.mkstemp(prefix=".fm-crosscheck-run-", suffix=".json")[1])
    try:
        os.chmod(temporary, 0o600)
        temporary.write_bytes(canonical_bytes(body) + b"\n")
        result, rc, detail = az(
            config,
            [
                "rest",
                "--method",
                "put",
                "--url",
                "https://management.azure.com" + command_id + "?api-version=2024-03-01",
                "--body",
                "@" + str(temporary),
            ],
            check=False,
        )
    finally:
        temporary.unlink(missing_ok=True)
    if rc != 0:
        raise AzureCrosscheckError(f"model compartment execution submission failed: {detail}")
    return {
        "resource_id": resources["vm_id"],
        "vm_instance_id": instance_id,
        "run_command_id": command_id,
        "etag": vm.get("etag"),
    }


def poll_model_run(
    config: dict[str, Any], command_id: str, timeout_seconds: int
) -> tuple[str, str]:
    deadline = time.monotonic() + timeout_seconds + 900
    url = "https://management.azure.com" + command_id + "?api-version=2024-03-01&$expand=instanceView"
    while time.monotonic() < deadline:
        value, rc, detail = az(config, ["rest", "--method", "get", "--url", url], check=False)
        if rc != 0:
            raise AzureCrosscheckError(f"model compartment status is unreadable: {detail}")
        properties = value.get("properties", {})
        view = properties.get("instanceView") or {}
        execution = view.get("executionState")
        if execution in {"Succeeded", "Failed", "Canceled", "TimedOut"}:
            if execution != "Succeeded":
                raise AzureCrosscheckError(
                    f"model compartment ended as {execution}: {str(view.get('error', ''))[-1000:]}"
                )
            marker = re.search(
                r"FM_AZURE_CROSSCHECK_RESULT\s+(sha256:[0-9a-f]{64})\s+boot=([0-9a-f-]{36})",
                str(view.get("output", "")),
            )
            if not marker:
                raise AzureCrosscheckError("model compartment omitted its result identity marker")
            return marker.group(1), marker.group(2)
        time.sleep(10)
    raise AzureCrosscheckError("model compartment exceeded its control-plane completion bound")


def verify_compartment_tags(resource: dict[str, Any], expected: dict[str, str], label: str) -> None:
    tags = resource.get("tags") or {}
    for key, value in expected.items():
        if tags.get(key) != value:
            raise AzureCrosscheckError(f"live {label} cleanup tag mismatch: {key}")


def delete_exact_resource(
    config: dict[str, Any], resource_id: str, api_version: str, expected_tags: dict[str, str], label: str
) -> None:
    url = "https://management.azure.com" + resource_id + "?api-version=" + api_version
    resource, rc, detail = az(config, ["rest", "--method", "get", "--url", url], check=False)
    if rc != 0:
        listing, list_rc, list_detail = az(
            config,
            ["resource", "list", "--resource-group", config["resource_group"]],
            check=False,
        )
        if list_rc != 0:
            raise AzureCrosscheckError(f"{label} absence is ambiguous: {detail}; {list_detail}")
        if any(str(item.get("id", "")).lower() == resource_id.lower() for item in listing):
            raise AzureCrosscheckError(f"{label} exact read failed while inventory still contains it")
        return
    verify_compartment_tags(resource, expected_tags, label)
    etag = resource.get("etag")
    if not isinstance(etag, str) or not etag:
        raise AzureCrosscheckError(f"{label} lacks immutable ETag cleanup identity")
    _value, delete_rc, delete_detail = az(
        config,
        [
            "rest",
            "--method",
            "delete",
            "--url",
            url,
            "--headers",
            "If-Match=" + etag,
        ],
        check=False,
    )
    if delete_rc != 0:
        raise AzureCrosscheckError(f"conditional exact {label} deletion failed: {delete_detail}")


def cleanup_model_vm(config: dict[str, Any], resources: dict[str, Any], identity: dict[str, str]) -> None:
    tags = resources["tags"]
    for resource_id, api_version, label in (
        (resources.get("run_command_id"), "2024-03-01", "model run-command"),
        (resources["vm_id"], "2024-03-01", "model VM"),
        (
            f"/subscriptions/{config['subscription']}/resourceGroups/{config['resource_group']}"
            f"/providers/Microsoft.Network/networkInterfaces/{resources['nic_name']}",
            "2023-09-01",
            "model NIC",
        ),
        (
            f"/subscriptions/{config['subscription']}/resourceGroups/{config['resource_group']}"
            f"/providers/Microsoft.Compute/disks/{resources['os_disk_name']}",
            "2023-10-02",
            "model OS disk",
        ),
    ):
        if resource_id:
            delete_exact_resource(config, resource_id, api_version, tags, label)


def parse_result(path: Path, expected_digest: str, identity: dict[str, str]) -> dict[str, Any]:
    if path.stat().st_size > MAX_RESULT_BYTES:
        raise AzureCrosscheckError("model result exceeds its byte bound")
    if digest_file(path) != expected_digest:
        raise AzureCrosscheckError("model result digest does not match control-plane publication")
    try:
        result = json.loads(path.read_bytes())
    except (json.JSONDecodeError, UnicodeError) as exc:
        raise AzureCrosscheckError(f"model result is malformed: {exc}") from exc
    if not isinstance(result, dict) or result.get("schema") != RESULT_SCHEMA:
        raise AzureCrosscheckError("model result schema is invalid")
    for key in (
        "review_generation",
        "home_binding",
        "task_id",
        "pull_request",
        "head_sha",
        "base_sha",
        "claims_sha256",
        "ledger_digest",
    ):
        if result.get(key) != identity.get(key):
            raise AzureCrosscheckError(f"model result identity mismatch: {key}")
    if not isinstance(result.get("verdict"), dict):
        raise AzureCrosscheckError("model result carries no verdict object")
    return result


def make_input(
    destination: Path,
    *,
    prompt: str,
    schema: dict[str, Any],
    identity: dict[str, str],
    config: dict[str, str],
) -> str:
    if len(prompt.encode("utf-8")) > MAX_PROMPT_BYTES:
        raise AzureCrosscheckError("review prompt exceeds its byte bound")
    value = {
        "schema": SCHEMA,
        "identity": identity,
        "reviewer": {
            "harness": config["harness"],
            "model": config["model"],
            "effort": config["effort"],
        },
        "review_schema": schema,
        "prompt": prompt,
        "tool_protocol": {
            "command_set": ["read", "grep", "find", "ls", "git-diff", "bash-evidence"],
            "network_bytes": 0,
            "resource_class": "crosscheck-tool",
            "verifier_fresh_attempt": True,
        },
        "protocol": {
            "model_guest_digest": digest_file(MODEL_GUEST),
            "runner_guest_digest": digest_file(RUNNER_GUEST),
            "runner_executor_digest": digest_file(RUNNER_EXECUTOR),
        },
    }
    value["request_digest"] = digest_bytes(canonical_bytes(value))
    write_json(destination, value)
    return value["request_digest"]


def run_azure_review(
    *,
    core: Any,
    root: Path,
    home: Path,
    task_id: str,
    pr_url: str,
    review_dir: Path,
    proof_root: Path,
    snapshot_value: dict[str, Any],
    ledger: dict[str, Any],
    config: dict[str, str],
    author_account_identity: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    del author_account_identity, root
    azure = runtime_config(home)
    verify_scope_and_foundation(azure)
    if active_review_vms(azure) >= azure["max_concurrency"]:
        raise core.CrosscheckToolError("Azure review admission reached its independent concurrency cap")
    identity = review_identity(
        home=home,
        task_id=task_id,
        pr_url=pr_url,
        snapshot_value=snapshot_value,
        config=config,
        ledger=ledger,
    )
    config["account_selector"] = {
        "codex": "CODEX_HOME",
        "claude": "CLAUDE_CONFIG_DIR",
        "pi": "PI_CODING_AGENT_DIR",
    }[config["harness"]]
    config["executing_account_home"] = config["account_home"]
    # The remote model home is private and deliberately carries no local path.
    # The reviewer schema/report bind this stable compartment path while the
    # account digest and VM identity prove which credential executed there.
    config["execution_home"] = "/var/lib/fm-crosscheck-model/home"
    credential, source, identifier = inspect_reviewer_credential(core, config)
    config["credential_source"] = source
    config["credential_identifier"] = identifier
    schema = core.review_output_schema(config["executing_account_home"], config["execution_home"])
    prompt = core.make_prompt(snapshot_value, ledger, config)
    with tempfile.TemporaryDirectory(prefix=".crosscheck-azure-", dir=proof_root) as temporary:
        work = Path(temporary)
        input_path = work / "request.json"
        credential_path = work / "credential.tar.gz"
        result_path = work / "result.json"
        request_digest = make_input(
            input_path,
            prompt=prompt,
            schema=schema,
            identity=identity,
            config=config,
        )
        credential_archive_digest, credential_digest = create_credential_archive(
            credential_path, credential, identity, config
        )
        prefix = (
            identity["home_binding"].split(":", 1)[1][:16]
            + "/"
            + task_id
            + "/"
            + identity["review_generation"]
        )
        staged = {
            "input_blob": prefix + "/model-input.json",
            "credential_blob": prefix + "/reviewer-credential.tar.gz",
            "output_blob": prefix + "/model-result.json",
        }
        uploaded: set[str] = set()
        resources: dict[str, Any] | None = None
        cleanup_error: Exception | None = None
        try:
            upload_blob(azure, input_path, staged["input_blob"])
            uploaded.add(staged["input_blob"])
            upload_blob(azure, credential_path, staged["credential_blob"])
            uploaded.add(staged["credential_blob"])
            resources = provision_model_vm(azure, identity, staged)
            model_run = submit_model_run(azure, identity, resources)
            resources["resource_id"] = model_run["resource_id"]
            resources["vm_instance_id"] = model_run["vm_instance_id"]
            resources["run_command_id"] = model_run["run_command_id"]
            resources["vm_etag"] = model_run["etag"]
            result_digest, boot_id = poll_model_run(
                azure, resources["run_command_id"], azure["timeout_seconds"]
            )
            download_blob(azure, staged["output_blob"], result_path)
            result = parse_result(result_path, result_digest, identity)
            model_identity = {
                "resource_id": resources["resource_id"],
                "vm_instance_id": resources["vm_instance_id"],
                "boot_id": boot_id,
            }
            tool_identity = result.get("tool_identity")
            verifier_identity = result.get("verifier_identity")
            for label, value in (("tool", tool_identity), ("verifier", verifier_identity)):
                if not isinstance(value, dict):
                    raise AzureCrosscheckError(f"{label} compartment identity is missing")
                for field in ("invocation", "resource_id", "vm_instance_id", "boot_id", "request_digest"):
                    if not isinstance(value.get(field), str) or not value[field]:
                        raise AzureCrosscheckError(f"{label} compartment identity lacks {field}")
                if value.get("review_generation") != identity["review_generation"]:
                    raise AzureCrosscheckError(f"{label} compartment review generation mismatch")
                if value.get("network_bytes") != 0 or value.get("credential_present") is not False:
                    raise AzureCrosscheckError(f"{label} compartment did not prove networkless credentialless execution")
            if tool_identity["vm_instance_id"] == verifier_identity["vm_instance_id"]:
                raise AzureCrosscheckError("tool and verifier reused one VM instance")
            if model_identity["vm_instance_id"] in {
                tool_identity["vm_instance_id"],
                verifier_identity["vm_instance_id"],
            }:
                raise AzureCrosscheckError("credentialed model VM was reused for repository execution")
            evidence_files = result.get("evidence_files")
            if not isinstance(evidence_files, dict) or len(evidence_files) > 64:
                raise AzureCrosscheckError("model result evidence manifest is missing or oversized")
            for relative, encoded in evidence_files.items():
                if (
                    not isinstance(relative, str)
                    or not relative.startswith((".crosscheck/reproductions/", ".crosscheck/mutations/"))
                    or ".." in Path(relative).parts
                    or not isinstance(encoded, str)
                ):
                    raise AzureCrosscheckError("model result evidence path is invalid")
                try:
                    content = base64.b64decode(encoded, validate=True)
                except ValueError as exc:
                    raise AzureCrosscheckError("model result evidence body is malformed") from exc
                if not 1 <= len(content) <= core.MAX_CAPTURE or b"\x00" in content:
                    raise AzureCrosscheckError("model result evidence violates its byte contract")
                destination = review_dir / relative
                destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                descriptor = os.open(
                    destination,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                    0o700 if relative.startswith(".crosscheck/reproductions/") else 0o600,
                )
                with os.fdopen(descriptor, "wb") as handle:
                    handle.write(content)
            raw_review = result["verdict"]
            core.assert_review_checkout_intact(review_dir, snapshot_value["head_sha"])
            review = core.validate_review_shape(raw_review, snapshot_value, review_dir, config)
            working_ledger, run = core.apply_review(
                ledger, review, review_dir, proof_root, snapshot_value, config
            )
            azure_identity = {
                        **identity,
                        "request_digest": request_digest,
                        "credential_archive_digest": credential_archive_digest,
                        "credential_digest": credential_digest,
                        "model": model_identity,
                        "tool": tool_identity,
                        "verifier": verifier_identity,
                    }
            config.update(
                {
                    "execution_mode": EXECUTION_MODE,
                    "azure_identity": azure_identity,
                }
            )
            run["reviewer"].update(
                {
                    "execution_mode": EXECUTION_MODE,
                    "azure_identity": azure_identity,
                }
            )
            return working_ledger, run
        except core.CrosscheckError:
            raise
        except Exception as exc:
            raise core.CrosscheckToolError(str(exc)) from exc
        finally:
            if resources is not None:
                try:
                    cleanup_model_vm(azure, resources, identity)
                except Exception as exc:
                    cleanup_error = exc
            for blob in uploaded | {staged["output_blob"]}:
                with contextlib.suppress(Exception):
                    az(
                        azure,
                        [
                            "storage",
                            "blob",
                            "delete",
                            "--auth-mode",
                            "login",
                            "--account-name",
                            azure["storage"],
                            "--container-name",
                            STAGING_CONTAINER,
                            "--name",
                            blob,
                            "--delete-snapshots",
                            "include",
                        ],
                        check=False,
                    )
            if cleanup_error is not None and sys.exc_info()[0] is None:
                raise core.CrosscheckToolError(
                    f"Azure model compartment cleanup is ambiguous: {cleanup_error}"
                )


def require_identity_record(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise RuntimeError(f"{label} must be an object")
    for field in ("resource_id", "vm_instance_id", "boot_id"):
        if not isinstance(value.get(field), str) or not value[field]:
            raise RuntimeError(f"{label}.{field} is missing")
    return value


def validate_azure_reviewer_record(
    reviewer: dict[str, Any], run: dict[str, Any], label: str
) -> None:
    identity = reviewer.get("azure_identity")
    if not isinstance(identity, dict):
        raise RuntimeError(f"{label}.reviewer.azure_identity must be an object")
    for field in (
        "home_binding",
        "task_id",
        "pull_request",
        "head_sha",
        "base_sha",
        "claims_sha256",
        "reviewer_harness",
        "reviewer_model",
        "reviewer_account_digest",
        "review_generation",
        "ledger_digest",
        "request_digest",
    ):
        if not isinstance(identity.get(field), str) or not identity[field]:
            raise RuntimeError(f"{label}.reviewer.azure_identity.{field} is missing")
    if identity["head_sha"] != run["head_sha"] or identity["base_sha"] != run["base_sha"]:
        raise RuntimeError(f"{label}.reviewer Azure exact-head/base identity mismatches the run")
    if identity["claims_sha256"] != run["claims_sha256"]:
        raise RuntimeError(f"{label}.reviewer Azure claims identity mismatches the run")
    if identity["reviewer_harness"] != reviewer.get("harness"):
        raise RuntimeError(f"{label}.reviewer Azure harness identity mismatches")
    if identity["reviewer_model"] != reviewer.get("model"):
        raise RuntimeError(f"{label}.reviewer Azure model identity mismatches")
    expected_account_digest = digest_bytes(
        str(Path(reviewer.get("account_home", "")).resolve()).encode("utf-8")
    )
    if identity["reviewer_account_digest"] != expected_account_digest:
        raise RuntimeError(f"{label}.reviewer Azure account identity mismatches")
    model = require_identity_record(identity.get("model"), f"{label}.reviewer.azure_identity.model")
    tool = require_identity_record(identity.get("tool"), f"{label}.reviewer.azure_identity.tool")
    verifier = require_identity_record(identity.get("verifier"), f"{label}.reviewer.azure_identity.verifier")
    if len({model["vm_instance_id"], tool["vm_instance_id"], verifier["vm_instance_id"]}) != 3:
        raise RuntimeError(f"{label}.reviewer Azure compartments reused a VM identity")
    for child_label, child in (("tool", tool), ("verifier", verifier)):
        if child.get("network_bytes") != 0 or child.get("credential_present") is not False:
            raise RuntimeError(f"{label}.reviewer Azure {child_label} boundary is not networkless and credentialless")
        if child.get("review_generation") != identity["review_generation"]:
            raise RuntimeError(f"{label}.reviewer Azure {child_label} generation mismatches")


def verify_azure_reviewer_record(
    reviewer: dict[str, Any], run: dict[str, Any], snapshot_value: dict[str, Any]
) -> None:
    try:
        validate_azure_reviewer_record(reviewer, run, "latest exact-head run")
    except RuntimeError as exc:
        raise AzureCrosscheckError(str(exc)) from exc
    identity = reviewer["azure_identity"]
    if identity["head_sha"] != snapshot_value["head_sha"]:
        raise AzureCrosscheckError("Azure review identity is stale for the live PR head")
    if identity["claims_sha256"] != snapshot_value["claims_sha256"]:
        raise AzureCrosscheckError("Azure review identity is stale for the live PR claims")
