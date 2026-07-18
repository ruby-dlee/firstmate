from __future__ import annotations

import os
from pathlib import Path


def expand_path(value: str | Path) -> Path:
    return Path(os.path.expandvars(os.path.expanduser(str(value)))).resolve()


def expand_lexical_path(value: str | Path) -> Path:
    return Path(os.path.abspath(os.path.expandvars(os.path.expanduser(str(value)))))


def default_config_path() -> Path:
    override = os.environ.get("AGENT_FLEET_CONFIG")
    if override:
        return expand_path(override)
    return Path.home() / ".config" / "agent-fleet" / "accounts.toml"


def default_state_dir() -> Path:
    override = os.environ.get("AGENT_FLEET_STATE_DIR")
    if override:
        return expand_path(override)
    return Path.home() / ".local" / "state" / "agent-fleet"


def default_share_dir() -> Path:
    override = os.environ.get("AGENT_FLEET_SHARE_DIR")
    if override:
        return expand_path(override)
    return Path.home() / ".local" / "share" / "agent-fleet"


def ensure_private_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.chmod(0o700)
