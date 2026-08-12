#!/usr/bin/env python3
"""Trusted model-compartment bridge to fresh Azure tool and verifier VMs.

This root-owned service is installed into the pinned reviewer image.
The unprivileged model talks to one local Unix socket using a bounded request.
The service admits only a fixed operation vocabulary, starts a new networkless
`crosscheck-tool` runner for every tool execution, and starts a second new
networkless attempt for final accepted-evidence replay.
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import socket
from typing import Any


SOCKET = Path("/run/fm-crosscheck/tool-bridge.sock")
MAX_REQUEST = 2 * 1024 * 1024
MAX_RESPONSE = 2 * 1024 * 1024
MAX_ARGUMENTS = 64
MAX_ARGUMENT_BYTES = 64 * 1024
ALLOWED_OPERATIONS = {"read", "grep", "find", "ls", "git-diff", "bash-evidence", "write-mutation", "finalize"}
SAFE_PATH = re.compile(r"^(?!/)(?!.*(?:^|/)\.\.(?:/|$))[A-Za-z0-9._/+@:-]{1,240}$")
ROOT = Path(__file__).resolve().parent.parent
RUNNER = ROOT / "bin" / "fm-azure-runner.py"


class BridgeError(RuntimeError):
    pass


def canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def digest(value: bytes) -> str:
    return "sha256:" + hashlib.sha256(value).hexdigest()


def load_runner() -> Any:
    spec = importlib.util.spec_from_file_location("firstmate_azure_runner", RUNNER)
    if spec is None or spec.loader is None:
        raise BridgeError("Azure runner controller is unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def validate_request(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or value.get("schema") != "fm.azure-crosscheck-tool-rpc/v1":
        raise BridgeError("request schema is invalid")
    operation = value.get("operation")
    if operation not in ALLOWED_OPERATIONS:
        raise BridgeError("operation is not allow-listed")
    request = value.get("request")
    if not isinstance(request, dict) or request.get("schema") != "fm.azure-crosscheck/v1":
        raise BridgeError("bound Crosscheck request is invalid")
    generation = value.get("review_generation")
    if generation != request.get("identity", {}).get("review_generation"):
        raise BridgeError("review generation mismatch")
    if value.get("request_digest") != request.get("request_digest"):
        raise BridgeError("request digest mismatch")
    configured_generation = os.environ.get("FM_CROSSCHECK_REVIEW_GENERATION")
    if configured_generation and configured_generation != generation:
        raise BridgeError("bridge service generation does not own this request")
    unsigned = dict(request)
    supplied = unsigned.pop("request_digest", None)
    if supplied != digest(canonical(unsigned)):
        raise BridgeError("bound Crosscheck request digest is invalid")
    arguments = value.get("arguments")
    if not isinstance(arguments, list) or len(arguments) > MAX_ARGUMENTS:
        raise BridgeError("operation arguments exceed item bound")
    if any(not isinstance(item, str) or "\x00" in item for item in arguments):
        raise BridgeError("operation argument is invalid")
    if sum(len(item.encode("utf-8")) for item in arguments) > MAX_ARGUMENT_BYTES:
        raise BridgeError("operation arguments exceed byte bound")
    return value


def operation_command(value: dict[str, Any]) -> list[str]:
    operation = value["operation"]
    arguments = value["arguments"]
    head = value["request"]["identity"]["head_sha"]
    base = value["request"]["identity"]["base_sha"]
    if operation == "read":
        if len(arguments) not in (1, 3) or not SAFE_PATH.fullmatch(arguments[0]):
            raise BridgeError("read requires path and optional offset/limit")
        offset = arguments[1] if len(arguments) == 3 else "1"
        limit = arguments[2] if len(arguments) == 3 else "400"
        if not offset.isdigit() or not limit.isdigit() or int(limit) > 2000:
            raise BridgeError("read offset/limit is invalid")
        return ["python3", "bin/fm-crosscheck-azure-tool-command.py", "read", arguments[0], offset, limit]
    if operation == "grep":
        if not 1 <= len(arguments) <= 8:
            raise BridgeError("grep requires one pattern and optional roots")
        if any(item != "." and not SAFE_PATH.fullmatch(item) for item in arguments[1:]):
            raise BridgeError("grep repository root is invalid")
        return ["python3", "bin/fm-crosscheck-azure-tool-command.py", operation, *arguments]
    if operation == "find":
        if len(arguments) > 2:
            raise BridgeError("find accepts one root and optional bounded depth")
        if arguments and arguments[0] != "." and not SAFE_PATH.fullmatch(arguments[0]):
            raise BridgeError("find repository root is invalid")
        if len(arguments) == 2 and not arguments[1].isdigit():
            raise BridgeError("find depth is invalid")
        return ["python3", "bin/fm-crosscheck-azure-tool-command.py", operation, *arguments]
    if operation == "ls":
        if len(arguments) > 1 or (
            arguments and arguments[0] != "." and not SAFE_PATH.fullmatch(arguments[0])
        ):
            raise BridgeError("ls repository root is invalid")
        return ["python3", "bin/fm-crosscheck-azure-tool-command.py", operation, *arguments]
    if operation == "git-diff":
        if arguments not in ([], [base, head]):
            raise BridgeError("git-diff may name only the bound base and head")
        return ["git", "diff", "--no-ext-diff", "--no-renames", "--", base, head]
    if operation == "bash-evidence":
        if len(arguments) != 2 or not SAFE_PATH.fullmatch(arguments[0]) or not arguments[0].startswith(".crosscheck/reproductions/"):
            raise BridgeError("bash-evidence requires one reproduction helper path and base64 body")
        evidence = decode_artifact(arguments[1], "evidence helper")
        save_review_artifact(value["review_generation"], arguments[0], evidence)
        encoded = base64.b64encode(canonical(review_artifacts(value["review_generation"]))).decode("ascii")
        return [
            "python3", "bin/fm-crosscheck-azure-replay.py", "--mode", "capture",
            "--evidence-json", encoded, "--", "bash", "--noprofile", "--norc", arguments[0], "--next-command",
        ]
    if operation == "write-mutation":
        if len(arguments) != 2 or not SAFE_PATH.fullmatch(arguments[0]) or not arguments[0].startswith(".crosscheck/mutations/"):
            raise BridgeError("write-mutation requires one mutation path and base64 body")
        save_review_artifact(
            value["review_generation"], arguments[0], decode_artifact(arguments[1], "mutation")
        )
        return ["python3", "-c", "print('mutation-staged-positive-control')"]
    raise BridgeError("finalize has no direct operation command")


def artifact_manifest_path(generation: str) -> Path:
    return Path("/var/lib/fm-crosscheck/tool-artifacts") / (generation + ".json")


def review_artifacts(generation: str) -> dict[str, str]:
    path = artifact_manifest_path(generation)
    if not path.exists():
        return {}
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise BridgeError("stored review artifact manifest is malformed")
    return value


def decode_artifact(encoded: str, label: str) -> bytes:
    try:
        value = base64.b64decode(encoded, validate=True)
    except ValueError as exc:
        raise BridgeError(f"{label} is not canonical base64") from exc
    if not 1 <= len(value) <= 200_000 or b"\x00" in value:
        raise BridgeError(f"{label} violates its byte contract")
    return value


def save_review_artifact(generation: str, relative: str, content: bytes) -> None:
    artifacts = review_artifacts(generation)
    encoded = base64.b64encode(content).decode("ascii")
    previous = artifacts.get(relative)
    if previous is not None and previous != encoded:
        raise BridgeError("review artifact path cannot be overwritten with different content")
    artifacts[relative] = encoded
    path = artifact_manifest_path(generation)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_suffix(".tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(canonical(artifacts) + b"\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def prepare_exact_snapshot(runner: Any, request: dict[str, Any], task_suffix: str, command: list[str]) -> tuple[dict[str, Any], Any]:
    root = Path(os.environ.get("FM_CROSSCHECK_EXACT_REPOSITORY", ".")).resolve()
    if not root.is_dir():
        raise BridgeError("exact staged repository is unavailable")
    if runner.git(root, "rev-parse", "HEAD").stdout.strip() != request["identity"]["head_sha"]:
        raise BridgeError("staged repository head differs from review identity")
    parser = runner.parser()
    task = ("cc-" + request["identity"]["review_generation"][:12] + "-" + task_suffix)[:64]
    generation = request["identity"]["review_generation"][:63]
    arguments = parser.parse_args(
        [
            "prepare",
            "--repo",
            str(root),
            "--task",
            task,
            "--generation",
            generation,
            "--resource-class",
            "crosscheck-tool",
            "--artifact",
            ".crosscheck",
            "--",
            *command,
        ]
    )
    state = runner.prepare(runner.environment(), arguments)
    return state, arguments


def dispatch_once(runner: Any, request: dict[str, Any], suffix: str, command: list[str]) -> tuple[dict[str, Any], int, str, str]:
    env = runner.environment()
    state, _arguments = prepare_exact_snapshot(runner, request, suffix, command)
    exit_code = runner.dispatch_prepared(env, state, env["subscription"])
    if state.get("phase") != "complete":
        raise BridgeError("Azure runner did not prove complete exact cleanup")
    result = state.get("result")
    if not isinstance(result, dict):
        raise BridgeError("Azure runner produced no verified result")
    identity = {
        "invocation": state["invocation"],
        "resource_id": result["vm_resource_id"],
        "vm_instance_id": result["vm_instance_id"],
        "boot_id": result["boot_id"],
        "request_digest": state["request_digest"],
        "review_generation": request["identity"]["review_generation"],
        "network_bytes": state["request"]["limits"]["network_bytes"],
        "credential_present": False,
        "cleanup_phase": state["phase"],
        "result_digest": state["result_digest"],
    }
    extracted = Path(state["result_path"]) / "extracted"
    stdout = (extracted / "stdout.log").read_text(encoding="utf-8", errors="replace")
    stderr = (extracted / "stderr.log").read_text(encoding="utf-8", errors="replace")
    return identity, exit_code, stdout, stderr


def finalize(value: dict[str, Any]) -> dict[str, Any]:
    request = value["request"]
    verdict = value.get("verdict")
    if not isinstance(verdict, dict):
        raise BridgeError("finalize requires one verdict object")
    commands: list[list[str]] = []
    execution = verdict.get("executed_reproduction")
    if not isinstance(execution, dict):
        raise BridgeError("verdict lacks executed reproduction")
    test_path = execution.get("test_path")
    if not isinstance(test_path, str) or not SAFE_PATH.fullmatch(test_path) or not test_path.startswith(".crosscheck/reproductions/"):
        raise BridgeError("verdict reproduction path is invalid")
    commands.append(["bash", "--noprofile", "--norc", test_path])
    for finding in verdict.get("new_findings", []):
        reproduction = finding.get("reproduction") if isinstance(finding, dict) else None
        if isinstance(reproduction, dict):
            path = reproduction.get("test_path")
            if not isinstance(path, str) or not SAFE_PATH.fullmatch(path) or not path.startswith(".crosscheck/reproductions/"):
                raise BridgeError("finding reproduction path is invalid")
            commands.append(["bash", "--noprofile", "--norc", path])
    if len(commands) > 32:
        raise BridgeError("verdict evidence exceeds item bound")
    artifacts = review_artifacts(request["identity"]["review_generation"])
    required_paths = [test_path]
    for finding in verdict.get("new_findings", []):
        reproduction = finding.get("reproduction") if isinstance(finding, dict) else None
        if isinstance(reproduction, dict):
            required_paths.append(reproduction.get("test_path"))
    for path in required_paths:
        if not isinstance(path, str) or path not in artifacts:
            raise BridgeError("verdict references evidence that the tool compartment never executed")
    encoded_artifacts = base64.b64encode(canonical(artifacts)).decode("ascii")
    flattened = sum((cmd + ["--next-command"] for cmd in commands), [])
    runner = load_runner()
    tool_identity, tool_exit, tool_stdout, tool_stderr = dispatch_once(
        runner,
        request,
        "tool",
        [
            "python3", "bin/fm-crosscheck-azure-replay.py", "--mode", "capture",
            "--evidence-json", encoded_artifacts, "--", *flattened,
        ],
    )
    if tool_exit != 0:
        raise BridgeError("tool compartment evidence execution failed")
    verifier_identity, verifier_exit, verifier_stdout, verifier_stderr = dispatch_once(
        runner,
        request,
        "verifier",
        [
            "python3", "bin/fm-crosscheck-azure-replay.py", "--mode", "verify",
            "--evidence-json", encoded_artifacts, "--", *flattened,
        ],
    )
    if verifier_exit != 0:
        raise BridgeError("independent verifier replay failed")
    if tool_identity["vm_instance_id"] == verifier_identity["vm_instance_id"]:
        raise BridgeError("tool and verifier attempts reused a VM instance")
    try:
        tool_replay = json.loads(tool_stdout.strip().splitlines()[-1])
        verifier_replay = json.loads(verifier_stdout.strip().splitlines()[-1])
    except (IndexError, json.JSONDecodeError) as exc:
        raise BridgeError("tool or verifier replay output is malformed") from exc
    if tool_replay.get("results") != verifier_replay.get("results"):
        raise BridgeError("independent verifier replay disagrees with tool execution")
    return {
        "tool_identity": tool_identity,
        "verifier_identity": verifier_identity,
        "evidence_files": artifacts,
        "execution_proofs": tool_replay.get("results"),
        "verifier_proofs": verifier_replay.get("results"),
        "tool_stderr": tool_stderr[-1000:],
        "verifier_stderr": verifier_stderr[-1000:],
    }


def handle(value: dict[str, Any]) -> Any:
    request = value["request"]
    if value["operation"] == "finalize":
        return finalize(value)
    runner = load_runner()
    identity, exit_code, stdout, stderr = dispatch_once(
        runner, request, "tool", operation_command(value)
    )
    return {
        "identity": identity,
        "exit_code": exit_code,
        "stdout": stdout,
        "stderr": stderr,
    }


def receive_exact(client: socket.socket, size: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < size:
        chunk = client.recv(min(65536, size - len(chunks)))
        if not chunk:
            raise BridgeError("request ended early")
        chunks.extend(chunk)
    return bytes(chunks)


def serve_once(listener: socket.socket) -> None:
    client, _address = listener.accept()
    with client:
        peer_pid, peer_uid, _peer_gid = __import__("struct").unpack("3i", client.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
        if peer_uid == 0:
            raise BridgeError("root may not use the unprivileged model RPC")
        size = int.from_bytes(receive_exact(client, 4), "big")
        if not 1 <= size <= MAX_REQUEST:
            raise BridgeError("request size is invalid")
        value = validate_request(json.loads(receive_exact(client, size)))
        try:
            result = handle(value)
            response = {
                "schema": "fm.azure-crosscheck-tool-rpc-result/v1",
                "review_generation": value["review_generation"],
                "request_digest": value["request_digest"],
                "ok": True,
                "result": result,
            }
        except Exception as exc:
            response = {
                "schema": "fm.azure-crosscheck-tool-rpc-result/v1",
                "review_generation": value["review_generation"],
                "request_digest": value["request_digest"],
                "ok": False,
                "error": str(exc)[:1000],
            }
        encoded = canonical(response)
        if len(encoded) > MAX_RESPONSE:
            raise BridgeError("response exceeds byte bound")
        client.sendall(len(encoded).to_bytes(4, "big") + encoded)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", default=str(SOCKET))
    args = parser.parse_args()
    socket_path = Path(args.socket)
    socket_path.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    with contextlib.suppress(FileNotFoundError):
        socket_path.unlink()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
        listener.bind(str(socket_path))
        os.chmod(socket_path, 0o666)
        listener.listen(8)
        while True:
            serve_once(listener)


if __name__ == "__main__":
    raise SystemExit(main())
