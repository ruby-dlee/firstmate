from __future__ import annotations

import os
import stat
import subprocess
from dataclasses import dataclass
from pathlib import Path

from .executables import CONTROL_PATH, resolve_control_executable, validated_safe_directory
from .models import Registry
from .paths import current_user_home, expand_lexical_path

PROJECT_CONTROL_FILES = {
    "claude": (
        Path(".claude/settings.json"),
        Path(".claude/settings.local.json"),
        Path(".mcp.json"),
    ),
    "codex": (
        Path(".codex/config.toml"),
        Path(".codex/hooks.json"),
        Path(".mcp.json"),
    ),
}


@dataclass(frozen=True)
class TrustedProject:
    active_root: Path
    canonical_root: Path
    common_dir: Path
    active_identity: tuple[int, int]
    canonical_identity: tuple[int, int]
    common_identity: tuple[int, int]


def lexical_path(path: Path) -> Path:
    return expand_lexical_path(path)


def _owned_directory(path: Path, label: str) -> tuple[int, int]:
    resolved = validated_safe_directory(path, label=label)
    if resolved != path:
        raise ValueError(f"{label} must name its physical directory: {path}")
    try:
        current = path.lstat()
    except FileNotFoundError as exc:
        raise ValueError(f"{label} is missing: {path}") from exc
    if not stat.S_ISDIR(current.st_mode) or current.st_uid != os.getuid():
        raise ValueError(f"{label} must be a current-user directory: {path}")
    return current.st_dev, current.st_ino


def _git_path(path: Path, argument: str) -> Path:
    git = resolve_control_executable("git")
    environment = {
        "HOME": str(current_user_home()),
        "PATH": CONTROL_PATH,
        "LC_ALL": "C",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0",
    }
    try:
        result = subprocess.run(
            [str(git), "-C", str(path), "rev-parse", "--path-format=absolute", argument],
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


def _canonical_git_project(path: Path) -> tuple[Path, Path, tuple[int, int], tuple[int, int]]:
    expanded = lexical_path(path)
    if expanded.is_symlink() or expanded.resolve() != expanded:
        raise ValueError(f"trusted project path must not be symlinked: {path}")
    expanded_identity = _owned_directory(expanded, "trusted project path")
    root = _git_path(expanded, "--show-toplevel")
    common_dir = _git_path(expanded, "--git-common-dir")
    if root.is_symlink() or root.resolve() != root:
        raise ValueError(f"Git worktree root must not be symlinked: {root}")
    root_identity = _owned_directory(root, "Git worktree root")
    common_identity = _owned_directory(common_dir, "Git common directory")
    if expanded == root and expanded_identity != root_identity:
        raise ValueError("trusted project root changed during validation")
    if _git_path(expanded, "--show-toplevel") != root or _git_path(
        expanded, "--git-common-dir"
    ) != common_dir:
        raise ValueError("trusted project Git metadata changed during validation")
    if _owned_directory(root, "Git worktree root") != root_identity or _owned_directory(
        common_dir, "Git common directory"
    ) != common_identity:
        raise ValueError("trusted project directories changed during validation")
    if root == Path(root.anchor) or root == current_user_home():
        raise ValueError(f"trusted project root is too broad: {root}")
    try:
        expanded.relative_to(root)
    except ValueError as exc:
        raise ValueError(f"trusted project path escaped its Git worktree: {path}") from exc
    return root, common_dir, root_identity, common_identity


def canonical_git_project(path: Path) -> tuple[Path, Path]:
    root, common_dir, _, _ = _canonical_git_project(path)
    return root, common_dir


def _trusted_project(active_root: Path, canonical_root: Path, common_dir: Path) -> TrustedProject:
    active_identity = _owned_directory(active_root, "active Git worktree root")
    canonical_identity = _owned_directory(canonical_root, "registered Git worktree root")
    common_identity = _owned_directory(common_dir, "Git common directory")
    return TrustedProject(
        active_root,
        canonical_root,
        common_dir,
        active_identity,
        canonical_identity,
        common_identity,
    )


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
        projects.append(_trusted_project(canonical_root, canonical_root, common_dir))
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
    return _trusted_project(active_root, sorted(set(matches), key=str)[0], active_common_dir)


def project_control_file(project: TrustedProject, provider: str) -> Path | None:
    for relative in PROJECT_CONTROL_FILES[provider]:
        candidate = project.active_root / relative
        if candidate.exists() or candidate.is_symlink():
            return candidate
    return None


def assert_project_controls_absent(project: TrustedProject, provider: str) -> None:
    control_file = project_control_file(project, provider)
    if control_file is not None:
        raise ValueError(
            f"managed {provider.title()} launch refuses project control file: {control_file}"
        )


def revalidate_trusted_project(
    registry: Registry,
    provider: str,
    workspace: Path,
    expected: TrustedProject,
) -> TrustedProject:
    current = resolve_trusted_project(registry, provider, workspace)
    if current != expected:
        raise ValueError("trusted project changed before provider launch")
    assert_project_controls_absent(current, provider)
    return current


def enter_trusted_project(project: TrustedProject) -> None:
    """Enter the already-sealed active root without following a replacement."""

    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(project.active_root, flags)
    except OSError as exc:
        raise ValueError("trusted project changed before provider launch") from exc
    try:
        opened = os.fstat(descriptor)
        current = os.stat(project.active_root, follow_symlinks=False)
        expected = project.active_identity
        if (
            (opened.st_dev, opened.st_ino) != expected
            or (current.st_dev, current.st_ino) != expected
        ):
            raise ValueError("trusted project changed before provider launch")
        os.fchdir(descriptor)
        entered = os.stat(".", follow_symlinks=False)
        if (entered.st_dev, entered.st_ino) != expected:
            raise ValueError("trusted project changed while entering provider workspace")
    finally:
        os.close(descriptor)
