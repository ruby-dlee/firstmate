from __future__ import annotations

import os
import stat
from dataclasses import dataclass
from pathlib import Path

from .executables import validated_safe_directory
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


_GITFILE_PREFIX = b"gitdir: "


def _valid_head_reference(head: Path) -> bool:
    """Mirror Git's validate_headref: a symlink HEAD is readlink-checked without ever
    reading its target, and a regular HEAD must carry a refs/ symref or an object id."""

    try:
        info = os.lstat(head)
    except OSError:
        return False
    if stat.S_ISLNK(info.st_mode):
        try:
            return os.readlink(head).startswith("refs/")
        except OSError:
            return False
    if not stat.S_ISREG(info.st_mode):
        return False
    try:
        with open(head, "rb") as handle:
            buffer = handle.read(256)
    except OSError:
        return False
    # Git parses a NUL-terminated buffer, skips any whitespace (newlines included)
    # after "ref:", and accepts an object id terminated by end, NUL, or whitespace.
    buffer = buffer.split(b"\0", 1)[0]
    if buffer.startswith(b"ref:"):
        return buffer[len(b"ref:") :].lstrip().startswith(b"refs/")
    for size in (40, 64):
        if (
            len(buffer) >= size
            and all(character in b"0123456789abcdefABCDEF" for character in buffer[:size])
            and (len(buffer) == size or buffer[size : size + 1].isspace())
        ):
            return True
    return False


def _physical_path(path: Path) -> Path | None:
    """Resolve like Git's real_pathdup: symlink-aware, refusing unresolvable paths."""

    try:
        return Path(os.path.realpath(path, strict=True))
    except OSError:
        return None


def _git_common_dir(git_dir: Path) -> Path | None:
    """Resolve a Git directory's common directory through its optional commondir file."""

    try:
        raw = (git_dir / "commondir").read_bytes()
    except FileNotFoundError:
        return git_dir
    except OSError:
        return None
    # Git trims only trailing newline bytes here; other whitespace stays significant.
    value = raw.rstrip(b"\r\n")
    if not value or b"\n" in value or b"\x00" in value:
        return None
    target = Path(os.fsdecode(value))
    if not target.is_absolute():
        target = git_dir / target
    return _physical_path(target)


def _validated_git_dir(git_dir: Path) -> Path | None:
    """Return the common directory when git_dir passes Git's is_git_directory checks."""

    physical = _physical_path(git_dir)
    if physical is None:
        return None
    try:
        info = os.stat(physical, follow_symlinks=False)
    except OSError:
        return None
    # Git's dubious-ownership refusal covered the discovered Git directory itself;
    # the old sanitized subprocess inherited it, so keep the same fail-closed check.
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        return None
    if not _valid_head_reference(physical / "HEAD"):
        return None
    common = _git_common_dir(physical)
    if common is None:
        return None
    if not os.access(common / "objects", os.X_OK) or not os.access(common / "refs", os.X_OK):
        return None
    return common


def _read_gitfile(dotgit: Path, containing: Path) -> Path | None:
    """Parse a .git file's gitdir pointer, or None when malformed."""

    try:
        if os.stat(dotgit, follow_symlinks=True).st_size > 1 << 20:
            # Git refuses oversized .git files ("too large to be a .git file").
            return None
        raw = dotgit.read_bytes()
    except OSError:
        return None
    if not raw.startswith(_GITFILE_PREFIX):
        return None
    value = raw[len(_GITFILE_PREFIX) :].rstrip(b"\r\n")
    if not value or b"\n" in value or b"\x00" in value:
        return None
    target = Path(os.fsdecode(value))
    if not target.is_absolute():
        target = containing / target
    return _physical_path(target)


def _discover_git_worktree(start: Path) -> tuple[Path, Path]:
    """Mirror `git rev-parse --show-toplevel` / `--git-common-dir` with pure filesystem reads.

    This runs under the sealed pure-planning guard, which forbids process and shell
    execution, so Git worktree membership must be resolved without spawning git.
    Discovery matches git run under the sanitized control environment the previous
    subprocess used: no GIT_* environment overrides are honored, and upward discovery
    stops at a filesystem boundary.
    Deliberate fail-closed micro-divergences, all refusing hand-corrupted layouts git
    never writes: an existing-but-unreadable commondir file skips the level instead of
    dying, and NUL bytes in a commondir or gitdir pointer are refused rather than
    C-truncated.
    """

    def refused() -> ValueError:
        return ValueError(f"trusted project must be inside a Git worktree: {start}")

    try:
        device = os.lstat(start).st_dev
    except OSError as exc:
        raise refused() from exc
    level = start
    while True:
        dotgit = level / ".git"
        try:
            info: os.stat_result | None = os.stat(dotgit, follow_symlinks=True)
        except OSError:
            info = None
        if info is not None and stat.S_ISREG(info.st_mode):
            pointed = _read_gitfile(dotgit, level)
            common = _validated_git_dir(pointed) if pointed is not None else None
            if common is None:
                # Git treats a malformed or dangling .git file as fatal, never skippable.
                raise refused()
            return level, common
        if info is not None and stat.S_ISDIR(info.st_mode):
            common = _validated_git_dir(dotgit)
            if common is not None:
                return level, common
        if _validated_git_dir(level) is not None:
            # A bare repository (or the inside of a .git directory) has no work tree.
            raise refused()
        parent = level.parent
        if parent == level:
            raise refused()
        try:
            if os.lstat(parent).st_dev != device:
                raise refused()
        except OSError as exc:
            raise refused() from exc
        level = parent


def _canonical_git_project(path: Path) -> tuple[Path, Path, tuple[int, int], tuple[int, int]]:
    expanded = lexical_path(path)
    if expanded.is_symlink() or expanded.resolve() != expanded:
        raise ValueError(f"trusted project path must not be symlinked: {path}")
    expanded_identity = _owned_directory(expanded, "trusted project path")
    root, common_dir = _discover_git_worktree(expanded)
    if root.is_symlink() or root.resolve() != root:
        raise ValueError(f"Git worktree root must not be symlinked: {root}")
    root_identity = _owned_directory(root, "Git worktree root")
    common_identity = _owned_directory(common_dir, "Git common directory")
    if expanded == root and expanded_identity != root_identity:
        raise ValueError("trusted project root changed during validation")
    if _discover_git_worktree(expanded) != (root, common_dir):
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
