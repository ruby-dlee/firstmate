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
    if lexical_path(path) != root:
        raise ValueError(f"trusted project must name its canonical Git worktree root: {root}")
    return root


def registered_trusted_projects(registry: Registry, provider: str) -> tuple[TrustedProject, ...]:
    projects: list[TrustedProject] = []
    for configured_path in registry.require_provider(provider).trusted_projects:
        canonical_root, common_dir = canonical_git_project(configured_path)
        if lexical_path(configured_path) != canonical_root:
            raise ValueError(
                f"configured trusted project must name its canonical Git worktree root: "
                f"{configured_path}"
            )
        projects.append(TrustedProject(canonical_root, canonical_root, common_dir))
    return tuple(projects)


def remove_trusted_project(
    registry: Registry,
    provider: str,
    path: Path,
) -> tuple[Path, ...]:
    configured = registry.require_provider(provider).trusted_projects
    target = lexical_path(path)
    exact = {entry for entry in configured if lexical_path(entry) == target}
    common_dir: Path | None = None
    try:
        _, common_dir = canonical_git_project(target)
    except ValueError:
        if not exact:
            raise
    retained: list[Path] = []
    for entry in configured:
        if entry in exact:
            continue
        if common_dir is not None:
            try:
                _, entry_common_dir = canonical_git_project(entry)
            except ValueError:
                retained.append(entry)
                continue
            if entry_common_dir == common_dir:
                continue
        retained.append(entry)
    if len(retained) == len(configured):
        raise ValueError(f"trusted project is not registered for {provider}: {target}")
    return tuple(sorted(retained, key=str))


def resolve_trusted_project(registry: Registry, provider: str, workspace: Path) -> TrustedProject:
    active_root, active_common_dir = canonical_git_project(workspace)
    if lexical_path(workspace) != active_root:
        raise ValueError(f"workspace must name its Git worktree root: {active_root}")
    matches: list[Path] = []
    for project in registered_trusted_projects(registry, provider):
        if project.common_dir == active_common_dir:
            matches.append(project.canonical_root)
    if not matches:
        raise ValueError(
            f"workspace is not registered for {provider}: {active_root}; "
            f"run `agent-fleet project register --provider {provider} {active_root}`"
        )
    return TrustedProject(active_root, sorted(set(matches), key=str)[0], active_common_dir)
