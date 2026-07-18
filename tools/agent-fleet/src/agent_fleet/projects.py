from __future__ import annotations

import os
import stat
import subprocess
from dataclasses import dataclass
from pathlib import Path

from .models import Registry


@dataclass(frozen=True)
class TrustedProject:
    active_root: Path
    canonical_root: Path
    common_dir: Path


def lexical_path(path: Path) -> Path:
    return Path(os.path.abspath(os.path.expandvars(os.path.expanduser(str(path)))))


def invocation_workspace() -> Path:
    current = Path.cwd()
    raw = os.environ.get("PWD")
    if not raw:
        return current
    candidate = Path(raw)
    try:
        if candidate.resolve() == current.resolve():
            return candidate
    except OSError:
        pass
    return current


def _owned_directory(path: Path, label: str) -> None:
    try:
        current = path.lstat()
    except FileNotFoundError as exc:
        raise ValueError(f"{label} is missing: {path}") from exc
    if not stat.S_ISDIR(current.st_mode) or current.st_uid != os.getuid():
        raise ValueError(f"{label} must be a current-user directory: {path}")


def _git_path(path: Path, argument: str) -> Path:
    environment = {name: value for name, value in os.environ.items() if not name.startswith("GIT_")}
    try:
        result = subprocess.run(
            ["git", "-C", str(path), "rev-parse", "--path-format=absolute", argument],
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as exc:
        raise ValueError("Git is required to validate trusted projects") from exc
    value = result.stdout.strip()
    if result.returncode != 0 or not value:
        raise ValueError(f"trusted project must be inside a Git worktree: {path}")
    return Path(value)


def canonical_git_project(path: Path) -> tuple[Path, Path]:
    expanded = lexical_path(path)
    if expanded.is_symlink() or expanded.resolve() != expanded:
        raise ValueError(f"trusted project path must not be symlinked: {path}")
    _owned_directory(expanded, "trusted project path")
    root = _git_path(expanded, "--show-toplevel")
    common_dir = _git_path(expanded, "--git-common-dir")
    if root.is_symlink() or root.resolve() != root:
        raise ValueError(f"Git worktree root must not be symlinked: {root}")
    _owned_directory(root, "Git worktree root")
    _owned_directory(common_dir, "Git common directory")
    if root == Path(root.anchor) or root == Path.home().resolve():
        raise ValueError(f"trusted project root is too broad: {root}")
    try:
        expanded.relative_to(root)
    except ValueError as exc:
        raise ValueError(f"trusted project path escaped its Git worktree: {path}") from exc
    return root, common_dir.resolve()


def register_trusted_project(path: Path) -> Path:
    root, _ = canonical_git_project(path)
    return root


def resolve_trusted_project(registry: Registry, provider: str, workspace: Path) -> TrustedProject:
    active_root, active_common_dir = canonical_git_project(workspace)
    configured = registry.require_provider(provider).trusted_projects
    matches: list[Path] = []
    for configured_path in configured:
        try:
            canonical_root, common_dir = canonical_git_project(configured_path)
        except ValueError:
            continue
        if common_dir == active_common_dir:
            matches.append(canonical_root)
    if not matches:
        raise ValueError(
            f"workspace is not registered for {provider}: {active_root}; "
            f"run `agent-fleet project register --provider {provider} {active_root}`"
        )
    return TrustedProject(active_root, sorted(set(matches), key=str)[0], active_common_dir)
