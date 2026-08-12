#!/usr/bin/env python3
"""Allow-listed repository inspection command for Azure Crosscheck tool VMs."""

import argparse
from pathlib import Path
import re
import subprocess
import sys


MAX_CAPTURE = 8 * 1024 * 1024
SAFE_PATH = re.compile(r"^(?!/)(?!.*(?:^|/)\.\.(?:/|$))[A-Za-z0-9._/+@:-]{1,240}$")


def bounded_run(argv: list[str]) -> int:
    result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300)
    if len(result.stdout) + len(result.stderr) > MAX_CAPTURE:
        raise SystemExit("tool command: output exceeded byte bound")
    sys.stdout.buffer.write(result.stdout)
    sys.stderr.buffer.write(result.stderr)
    return result.returncode


def require_path(root: Path, raw: str) -> Path:
    if not SAFE_PATH.fullmatch(raw):
        raise SystemExit("tool command: path is invalid")
    lexical = root / raw
    resolved = lexical.resolve(strict=True)
    if root != resolved and root not in resolved.parents:
        raise SystemExit("tool command: path escapes repository")
    current = root
    for part in Path(raw).parts:
        current = current / part
        if current.is_symlink():
            raise SystemExit("tool command: path traverses a symlink")
    return resolved


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("read", "grep", "find", "ls"))
    parser.add_argument("arguments", nargs="*")
    args = parser.parse_args()
    root = Path.cwd().resolve()
    if args.operation == "read":
        if len(args.arguments) != 3:
            raise SystemExit("tool command: read requires path, offset, and limit")
        path = require_path(root, args.arguments[0])
        offset = int(args.arguments[1])
        limit = int(args.arguments[2])
        if not 1 <= offset or not 1 <= limit <= 2000 or not path.is_file():
            raise SystemExit("tool command: read range or file is invalid")
        captured = bytearray()
        with path.open("rb") as handle:
            for number, line in enumerate(handle, start=1):
                if number < offset:
                    continue
                if number >= offset + limit:
                    break
                captured.extend(line)
                if len(captured) > MAX_CAPTURE:
                    raise SystemExit("tool command: output exceeded byte bound")
        sys.stdout.buffer.write(captured)
        return 0
    if args.operation == "grep":
        if not 1 <= len(args.arguments) <= 8:
            raise SystemExit("tool command: grep requires one pattern and optional roots")
        pattern = args.arguments[0]
        roots = args.arguments[1:] or ["."]
        for item in roots:
            if item != ".":
                require_path(root, item)
        return bounded_run(["rg", "--line-number", "--color", "never", "--", pattern, *roots])
    if args.operation == "find":
        if len(args.arguments) > 2:
            raise SystemExit("tool command: find accepts root and optional bounded depth")
        relative = args.arguments[0] if args.arguments else "."
        depth = int(args.arguments[1]) if len(args.arguments) == 2 else 4
        if relative != ".":
            require_path(root, relative)
        if not 0 <= depth <= 8:
            raise SystemExit("tool command: find depth is invalid")
        return bounded_run(["find", relative, "-maxdepth", str(depth), "-type", "f", "-print"])
    if len(args.arguments) > 1:
        raise SystemExit("tool command: ls accepts at most one path")
    relative = args.arguments[0] if args.arguments else "."
    if relative != ".":
        require_path(root, relative)
    return bounded_run(["find", relative, "-maxdepth", "1", "-mindepth", "1", "-print"])


if __name__ == "__main__":
    raise SystemExit(main())
