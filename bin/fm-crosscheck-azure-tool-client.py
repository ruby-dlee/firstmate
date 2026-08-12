#!/usr/bin/env python3
"""Unprivileged bounded client for the local Azure Crosscheck tool bridge."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import socket
import stat


SOCKET = Path("/run/fm-crosscheck/tool-bridge.sock")
MAX_REQUEST = 2 * 1024 * 1024
MAX_RESPONSE = 2 * 1024 * 1024
ALLOWED_OPERATIONS = {"read", "grep", "find", "ls", "git-diff", "bash-evidence", "finalize"}


def contained_regular(path: Path, root: Path) -> Path:
    resolved = path.resolve(strict=True)
    if root != resolved and root not in resolved.parents:
        raise ValueError(f"path escapes request root: {path}")
    metadata = os.stat(resolved, follow_symlinks=False)
    if not stat.S_ISREG(metadata.st_mode):
        raise ValueError(f"path must be a regular file: {path}")
    return resolved


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=sorted(ALLOWED_OPERATIONS))
    parser.add_argument("--request", required=True)
    parser.add_argument("--verdict")
    parser.add_argument("--output", required=True)
    parser.add_argument("arguments", nargs="*")
    args = parser.parse_args()
    request_root = Path(os.environ.get("FM_CROSSCHECK_REQUEST_ROOT", "/var/lib/fm-crosscheck-model")).resolve()
    request_path = contained_regular(Path(args.request), request_root)
    verdict_path = contained_regular(Path(args.verdict), request_root) if args.verdict else None
    request = json.loads(request_path.read_text(encoding="utf-8"))
    generation = os.environ.get("FM_CROSSCHECK_REVIEW_GENERATION")
    if request.get("identity", {}).get("review_generation") != generation:
        raise SystemExit("tool client: review generation mismatch")
    payload = {
        "schema": "fm.azure-crosscheck-tool-rpc/v1",
        "operation": args.operation,
        "review_generation": generation,
        "request_digest": request.get("request_digest"),
        "arguments": args.arguments,
        "request": request,
        "verdict": (
            json.loads(verdict_path.read_text(encoding="utf-8"))
            if verdict_path is not None
            else None
        ),
    }
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8") + b"\n"
    if len(encoded) > MAX_REQUEST:
        raise SystemExit("tool client: request exceeds byte bound")
    if not SOCKET.is_socket():
        raise SystemExit("tool client: trusted bridge socket is absent")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(900)
        client.connect(str(SOCKET))
        client.sendall(len(encoded).to_bytes(4, "big") + encoded)
        size = int.from_bytes(client.recv(4), "big")
        if not 1 <= size <= MAX_RESPONSE:
            raise SystemExit("tool client: response size is invalid")
        chunks = bytearray()
        while len(chunks) < size:
            chunk = client.recv(min(65536, size - len(chunks)))
            if not chunk:
                raise SystemExit("tool client: response ended early")
            chunks.extend(chunk)
    response = json.loads(bytes(chunks))
    if response.get("schema") != "fm.azure-crosscheck-tool-rpc-result/v1":
        raise SystemExit("tool client: response schema mismatch")
    if response.get("review_generation") != generation:
        raise SystemExit("tool client: response generation mismatch")
    if response.get("request_digest") != request.get("request_digest"):
        raise SystemExit("tool client: response request identity mismatch")
    if response.get("ok") is not True:
        raise SystemExit("tool client: " + str(response.get("error") or "bridge refused"))
    output = Path(args.output)
    descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        rendered = json.dumps(response["result"], sort_keys=True, separators=(",", ":")).encode("utf-8") + b"\n"
        handle.write(rendered)
        handle.flush()
        os.fsync(handle.fileno())
    print("fm-crosscheck-tool-result sha256:" + hashlib.sha256(rendered).hexdigest())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
