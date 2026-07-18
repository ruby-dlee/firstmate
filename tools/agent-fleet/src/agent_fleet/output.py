from __future__ import annotations

import json
import shutil
import subprocess
import sys
from typing import Any


def preflight(output_format: str) -> None:
    if output_format != "toon":
        return
    toon = shutil.which("toon")
    if toon is None:
        raise ValueError("TOON output requested but `toon` is not on PATH; use --format json")
    result = subprocess.run(
        [toon],
        input="{}",
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise ValueError(f"TOON encoder preflight failed: {result.stderr.strip()}")


def emit(payload: Any, output_format: str) -> None:
    if output_format == "json":
        json.dump(payload, sys.stdout, sort_keys=True, separators=(",", ":"))
        sys.stdout.write("\n")
        return
    if output_format == "toon":
        toon = shutil.which("toon")
        if toon is None:
            raise ValueError("TOON output requested but `toon` is not on PATH; use --format json")
        encoded = json.dumps(payload, separators=(",", ":"))
        result = subprocess.run(
            [toon],
            input=encoded,
            text=True,
            capture_output=True,
            check=False,
        )
        if result.returncode != 0:
            raise ValueError(f"TOON encoder failed: {result.stderr.strip()}")
        sys.stdout.write(result.stdout)
        return
    _emit_human(payload)


def _emit_human(payload: Any, prefix: str = "") -> None:
    if isinstance(payload, dict):
        for key, value in payload.items():
            if isinstance(value, (dict, list)):
                print(f"{prefix}{key}:")
                _emit_human(value, prefix + "  ")
            else:
                print(f"{prefix}{key}: {value}")
    elif isinstance(payload, list):
        for item in payload:
            if isinstance(item, (dict, list)):
                print(f"{prefix}-")
                _emit_human(item, prefix + "  ")
            else:
                print(f"{prefix}- {item}")
    else:
        print(f"{prefix}{payload}")
