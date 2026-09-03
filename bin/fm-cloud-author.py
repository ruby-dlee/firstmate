#!/usr/bin/env python3
"""Prepare and publish one credentialless Azure author assignment.

The prepare leg turns a trusted host brief into a bounded, digest-manifested
repository/context payload.  The publish leg runs only on the trusted host:
it verifies the returned tip, pushes the exact task branch, and creates or
reuses the matching pull request.  Neither leg handles Crosscheck resources.
"""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile


CONTEXT_SCHEMA = "fm.azure-author-context/v1"
REPOSITORY_SCHEMA = "fm.azure-author-repository/v1"
PUBLICATION_SCHEMA = "fm.azure-author-publication/v1"
CONFIG_SCHEMA = "fm.azure-author-context-config/v1"
SAFE_TASK = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
SAFE_BRANCH = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,254}$")
SHA40 = re.compile(r"^[0-9a-f]{40}$")
PR_URL = re.compile(r"https://github\.com/[A-Za-z0-9-]+/[A-Za-z0-9._-]+/pull/[0-9]+")
MAX_BRIEF_BYTES = 256 * 1024
MAX_CONTEXT_BYTES = 32 * 1024 * 1024
MAX_CONTEXT_ENTRIES = 256
MAX_PR_CONTEXT_BYTES = 1024 * 1024
MAX_COMMAND_BYTES = 2 * 1024 * 1024


class AuthorError(RuntimeError):
    pass


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def sha256(body):
    return hashlib.sha256(body).hexdigest()


def run(arguments, cwd=None, input_bytes=None, check=True, limit=MAX_COMMAND_BYTES):
    try:
        completed = subprocess.run(
            arguments,
            cwd=str(cwd) if cwd is not None else None,
            input=input_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=120,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise AuthorError("{} could not complete: {}".format(arguments[0], exc))
    if len(completed.stdout) + len(completed.stderr) > limit:
        raise AuthorError("{} output exceeded its byte bound".format(arguments[0]))
    if check and completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).decode("utf-8", errors="replace").strip()
        raise AuthorError(
            "{} failed: {}".format(" ".join(arguments[:3]), detail[-500:] or "no diagnostic")
        )
    return completed


def git(worktree, *arguments, check=True):
    return run(["git", "-C", str(worktree), *arguments], check=check)


def read_regular(path, label, maximum):
    if path.is_symlink() or not path.is_file():
        raise AuthorError("{} is absent or redirected: {}".format(label, path))
    body = path.read_bytes()
    if not body or len(body) > maximum:
        raise AuthorError("{} has an invalid byte count: {}".format(label, len(body)))
    return body


def physical_directory(path, label):
    path = Path(os.path.abspath(str(path)))
    if path.is_symlink() or not path.is_dir() or path.resolve() != path:
        raise AuthorError("{} is unavailable or redirected: {}".format(label, path))
    return path


def validate_branch(value, label):
    if not isinstance(value, str) or not SAFE_BRANCH.fullmatch(value):
        raise AuthorError("{} is malformed".format(label))
    if value.startswith(("/", ".")) or value.endswith(("/", ".")) or ".." in value.split("/"):
        raise AuthorError("{} is malformed".format(label))
    checked = run(["git", "check-ref-format", "refs/heads/{}".format(value)], check=False)
    if checked.returncode != 0:
        raise AuthorError("{} is not a valid Git branch".format(label))
    return value


def remote_slug(worktree, remote):
    if os.environ.get("FM_CLOUD_AUTHOR_TEST_HOOKS") == "azure-author-tests-v1":
        fixture = os.environ.get("FM_CLOUD_AUTHOR_TEST_REPOSITORY", "")
        if re.fullmatch(r"[A-Za-z0-9-]+/[A-Za-z0-9._-]+", fixture):
            return fixture
    raw = git(worktree, "remote", "get-url", remote).stdout.decode().strip()
    patterns = (
        r"^https://github\.com/([^/]+/[^/]+?)(?:\.git)?$",
        r"^(?:ssh://)?git@github\.com[:/]([^/]+/[^/]+?)(?:\.git)?$",
    )
    for pattern in patterns:
        match = re.fullmatch(pattern, raw)
        if match:
            value = match.group(1)
            return value[:-4] if value.endswith(".git") else value
    raise AuthorError("Azure author publication requires one GitHub remote URL")


def load_context_config(brief):
    path = brief.parent / "cloud-context.json"
    if not path.exists():
        return {}
    body = read_regular(path, "cloud context config", 1024 * 1024)
    try:
        value = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise AuthorError("cloud context config is unreadable: {}".format(exc))
    allowed = {"schema", "base_branch", "preserved_refs", "artifacts", "include_open_prs", "remote"}
    if not isinstance(value, dict) or value.get("schema") != CONFIG_SCHEMA or set(value) - allowed:
        raise AuthorError("cloud context config schema or fields are not exact")
    for field in ("preserved_refs", "artifacts"):
        entries = value.get(field, [])
        if not isinstance(entries, list) or any(not isinstance(item, str) or not item for item in entries):
            raise AuthorError("cloud context config {} are malformed".format(field))
    if "include_open_prs" in value and not isinstance(value["include_open_prs"], bool):
        raise AuthorError("cloud context config include_open_prs is malformed")
    return value


def default_branch(worktree, remote):
    shown = git(worktree, "symbolic-ref", "--quiet", "refs/remotes/{}/HEAD".format(remote), check=False)
    if shown.returncode == 0:
        prefix = "refs/remotes/{}/".format(remote)
        ref = shown.stdout.decode().strip()
        if ref.startswith(prefix):
            return validate_branch(ref[len(prefix):], "remote default branch")
    shown = git(worktree, "remote", "show", remote, check=False)
    if shown.returncode == 0:
        match = re.search(r"^[ ]*HEAD branch: (\S+)[ ]*$", shown.stdout.decode(), re.MULTILINE)
        if match:
            return validate_branch(match.group(1), "remote default branch")
    raise AuthorError("the repository's remote default branch is not established")


def intended_base(brief_text, config, worktree, remote):
    configured = config.get("base_branch")
    if configured:
        return validate_branch(configured, "configured base branch")
    matches = re.findall(r"integration authority is\s+`([^`]+)`", brief_text, flags=re.IGNORECASE)
    matches = sorted(set(matches))
    if len(matches) > 1:
        raise AuthorError("the brief names more than one integration authority")
    if matches:
        return validate_branch(matches[0], "brief integration authority")
    return default_branch(worktree, remote)


def path_has_redirect(root, path):
    current = root
    relative = path.relative_to(root)
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            return True
    return False


def is_task_return_path(task_relative):
    if not task_relative.parts:
        return False
    name = task_relative.parts[0]
    outputs = {
        "completion.md", "report.md", "visuals", "cloud-return.json",
        "cloud-publication.json", "cloud-status.log", "cloud-return-report.invalid.md",
    }
    return name in outputs or name.startswith("cloud-scratch")


def referenced_artifacts(home, task, brief_text, config):
    data_root = physical_directory(home / "data", "task data root")
    task_root = data_root / task
    candidates = set()
    prefix = re.escape(str(data_root))
    for match in re.finditer(prefix + r"/[A-Za-z0-9._/@+-]+(?:/[A-Za-z0-9._@+-]+)*", brief_text):
        candidates.add(Path(match.group(0)))
    for relative in config.get("artifacts", []):
        candidate = Path(relative)
        if candidate.is_absolute() or not candidate.parts or candidate.parts[0] != "data" or ".." in candidate.parts:
            raise AuthorError("configured context artifact must be a traversal-free data/ path")
        candidates.add(home / candidate)
    files = {}
    roots = []
    for candidate in sorted(candidates, key=lambda value: str(value)):
        absolute = Path(os.path.abspath(str(candidate)))
        try:
            task_relative = absolute.relative_to(task_root)
        except ValueError:
            task_relative = None
        if task_relative is not None and is_task_return_path(task_relative):
            # These are host-owned outputs, frequently named before they exist
            # and sometimes left from an earlier attempt. They never become
            # guest inputs merely because the completion contract names them.
            continue
        try:
            relative = absolute.relative_to(data_root)
        except ValueError:
            raise AuthorError("brief context path escapes the task data root")
        if path_has_redirect(data_root, absolute):
            raise AuthorError("brief context path is redirected: {}".format(absolute))
        if absolute.is_file():
            roots.append((absolute, Path("data") / relative))
        elif absolute.is_dir():
            for current_root, directory_names, file_names in os.walk(str(absolute), followlinks=False):
                current = Path(current_root)
                directory_names[:] = sorted(directory_names)
                for name in list(directory_names):
                    if (current / name).is_symlink():
                        raise AuthorError("brief context directory contains a redirect")
                for name in sorted(file_names):
                    source = current / name
                    if source.is_symlink() or not source.is_file():
                        raise AuthorError("brief context directory contains a non-regular file")
                    try:
                        nested_task_relative = source.relative_to(task_root)
                    except ValueError:
                        nested_task_relative = None
                    if nested_task_relative is not None and is_task_return_path(nested_task_relative):
                        continue
                    roots.append((source, Path("data") / source.relative_to(data_root)))
        else:
            raise AuthorError("brief depends on an unavailable data artifact: {}".format(absolute))
    total = 0
    for source, guest in roots:
        name = guest.as_posix()
        body = source.read_bytes()
        if name in files and files[name][0] != source:
            raise AuthorError("two context artifacts map to the same guest path")
        total += len(body)
        if total > MAX_CONTEXT_BYTES or len(files) >= MAX_CONTEXT_ENTRIES:
            raise AuthorError("authorized task context exceeds its bounded payload")
        files[name] = (source, body)
    return files


def open_pr_context(worktree, remote, required):
    if not required:
        return None, []
    slug = remote_slug(worktree, remote)
    binary = os.environ.get("FM_GH_AXI_BIN", "gh-axi")
    result = run(
        [binary, "pr", "list", "--repo", slug, "--state", "open", "--limit", "100",
         "--fields", "number,title,url,headRefName,headRefOid,baseRefName"],
        check=True,
        limit=MAX_PR_CONTEXT_BYTES,
    )
    body = result.stdout
    if not body or len(body) > MAX_PR_CONTEXT_BYTES:
        raise AuthorError("open pull request context is absent or oversized")
    numbers = []
    for line in body.decode("utf-8", errors="strict").splitlines()[1:]:
        match = re.match(r"^[ ]*([0-9]+),", line)
        if match:
            number = int(match.group(1))
            if number not in numbers:
                numbers.append(number)
    if len(numbers) > 100:
        raise AuthorError("open pull request context exceeds its entry bound")
    return body, numbers


def normalize_preserved_ref(value, remote):
    if value.startswith("refs/heads/"):
        branch = validate_branch(value[len("refs/heads/"):], "preserved branch")
        return "refs/heads/{}".format(branch), "branch/{}".format(branch)
    remote_prefix = "refs/remotes/{}/".format(remote)
    if value.startswith(remote_prefix):
        branch = validate_branch(value[len(remote_prefix):], "preserved remote branch")
        return "refs/heads/{}".format(branch), "branch/{}".format(branch)
    branch = validate_branch(value, "preserved branch")
    return "refs/heads/{}".format(branch), "branch/{}".format(branch)


def inferred_preserved_refs(brief_text):
    found = []
    for line in brief_text.splitlines():
        marker = line.lower().find("preserv")
        if marker < 0:
            continue
        # Only refs named after the preservation instruction are grants. A
        # nearby base or target ref must not silently broaden the payload.
        for value in re.findall(r"`([^`]+)`", line[marker:]):
            if value.startswith("refs/") or "/" in value:
                found.append(value)
    return found


def atomic_write(path, body, mode=0o600):
    if path.parent.is_symlink() or not path.parent.is_dir():
        raise AuthorError("output parent is unavailable or redirected: {}".format(path.parent))
    descriptor, temporary = tempfile.mkstemp(prefix=".fm-cloud-author-", dir=str(path.parent))
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(body)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def context_tar(files):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w") as archive:
        for name in sorted(files):
            body = files[name][1]
            info = tarfile.TarInfo(name)
            info.size = len(body)
            info.mode = 0o600
            info.mtime = 0
            info.uid = info.gid = 0
            archive.addfile(info, io.BytesIO(body))
    return output.getvalue()


def cloud_brief(brief_text, home, task, base_branch, base_commit, context_files, include_prs):
    task_branch = "fm/{}".format(task)
    replacements = {
        str(home / "data" / task): "/mnt/task/.fm-return/data/{}".format(task),
        str(home / "state" / task): "/mnt/task/.fm-return/state/{}".format(task),
    }
    # Longer source paths first so a declared file beneath a declared directory
    # always receives its exact guest path.
    for guest, (source, _body) in sorted(context_files.items(), key=lambda pair: -len(str(pair[1][0]))):
        replacements[str(source)] = "/mnt/task/.fm-context/{}".format(guest)
    rendered = brief_text
    for source, destination in sorted(replacements.items(), key=lambda pair: -len(pair[0])):
        rendered = rendered.replace(source, destination)
    if str(home) + "/" in rendered:
        raise AuthorError("cloud brief still names an unauthorized host-home path")
    rendered = rendered.replace(
        "You are in a disposable worktree", "You are in a credentialless Azure worktree"
    )
    rendered = re.sub(
        r"Run `git checkout -b fm/[^`]+` as your first project change\.",
        "The host already checked out `{}` from the exact dispatched base; do not recreate it.".format(task_branch),
        rendered,
    )
    rendered = re.sub(
        r"1\. Never push to the default branch \(push only your `fm/[^`]+` branch\)\. Never merge a PR\.",
        "1. Never push or open a PR from the guest. Commit only on `{}`; the trusted host publishes it.".format(task_branch),
        rendered,
    )
    rendered = rendered.replace(
        "3. Use gh-axi for GitHub and chrome-devtools-axi for browser operations.",
        "3. Forge credentials and gh-axi are intentionally absent. Use the staged PR snapshot when supplied; browser work remains unavailable unless the brief provides a separate bounded surface.",
    )
    rendered = rendered.replace(
        "Use an isolated branch and PR.",
        "Use the already-created isolated task branch; the host creates the PR after return.",
    )
    rendered = rendered.replace(
        "Include the full PR URL, exact head, tests, and remaining",
        "Include the exact head, tests, and remaining",
    )
    rendered = rendered.replace(
        "Emit terminal `done:` only when the PR is review-ready and all owned checks are green",
        "Emit terminal `done:` only when the committed return is ready for host publication and all guest-owned checks are green",
    )
    rendered = re.sub(
        r"Push the branch, open a PR with `gh-axi`, append `done: PR \{url\}`, and remain available for corrections\.",
        "Commit the implementation and return it with the required report. Append `done: cloud outcome ready for host publication`; the host replaces that event with the real PR URL after publication.",
        rendered,
    )
    intro = """# Azure host-managed delivery contract
This is the cloud-specific copy of the task brief, and this section overrides any generic local-delivery wording below.
The trusted host fetched `{base}` immediately before dispatch, bound commit `{commit}`, and checked out `{branch}` at that commit.
Read `/mnt/task/.fm-task/repository.json` for the exact base and preserved-ref labels.
{prs}
Do not fetch, pull, push, run gh or gh-axi, open a PR, or change remotes; the guest intentionally has no forge credential.
Make and test the requested change, commit every intended project change on `{branch}`, and write the required return report and status under `/mnt/task/.fm-return`.
A guest `done:` means only that committed bytes are ready to return; any later PR-URL or PR-readiness requirement is a host completion criterion, not a guest deliverable.
After the digest-bound return, trusted host code verifies the exact descendant, fast-forwards the leased worktree, pushes `{branch}`, and opens or reuses a PR targeting `{base}`.

""".format(
        base=base_branch,
        commit=base_commit,
        branch=task_branch,
        prs=("Read `/mnt/task/.fm-context/forge/open-prs.toon` for the bounded host-captured open-PR snapshot." if include_prs else "No open-PR snapshot was requested by this brief."),
    )
    return intro + rendered


def prepare(args):
    if not SAFE_TASK.fullmatch(args.task):
        raise AuthorError("task identity is malformed")
    home = physical_directory(args.home, "task home")
    worktree = physical_directory(args.worktree, "leased worktree")
    payload = physical_directory(args.payload, "cloud payload directory")
    brief = Path(os.path.abspath(args.brief))
    brief_body = read_regular(brief, "task brief", MAX_BRIEF_BYTES)
    try:
        brief_text = brief_body.decode("utf-8")
    except UnicodeDecodeError:
        raise AuthorError("task brief is not UTF-8")
    config = load_context_config(brief)
    remote = config.get("remote", args.remote)
    if not isinstance(remote, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", remote):
        raise AuthorError("publication remote is malformed")
    base_branch = intended_base(brief_text, config, worktree, remote)
    if git(worktree, "status", "--porcelain=v1", "--untracked-files=all").stdout.strip():
        raise AuthorError("leased worktree is dirty before current-base preparation")
    git(
        worktree, "fetch", "--quiet", "--no-tags", remote,
        "+refs/heads/{}:refs/remotes/{}/{}".format(base_branch, remote, base_branch),
    )
    base_ref = "refs/remotes/{}/{}".format(remote, base_branch)
    base_commit = git(worktree, "rev-parse", "--verify", "{}^{{commit}}".format(base_ref)).stdout.decode().strip()
    if not SHA40.fullmatch(base_commit):
        raise AuthorError("fetched base commit is malformed")
    git(worktree, "checkout", "--quiet", "--detach", base_commit)

    files = referenced_artifacts(home, args.task, brief_text, config)
    wants_prs = config.get("include_open_prs", bool(re.search(r"\bopen PRs?\b", brief_text, re.IGNORECASE)))
    pr_body, pr_numbers = open_pr_context(worktree, remote, wants_prs)
    if pr_body is not None:
        files["forge/open-prs.toon"] = (Path("<gh-axi>"), pr_body)
    context_entries = [
        {"path": name, "bytes": len(value[1]), "sha256": sha256(value[1])}
        for name, value in sorted(files.items())
    ]
    context_value = {
        "schema": CONTEXT_SCHEMA,
        "task": args.task,
        "base_branch": base_branch,
        "base_commit": base_commit,
        "task_branch": "fm/{}".format(args.task),
        "entries": context_entries,
    }
    context_body = canonical(context_value) + b"\n"
    context_archive = context_tar(files)
    if len(context_archive) > MAX_CONTEXT_BYTES + 1024 * 1024:
        raise AuthorError("authorized task context archive exceeds its byte bound")

    namespace = "refs/fm-cloud-payload/{}/{}".format(args.task, os.getpid())
    temporary_refs = []
    preserved = []
    try:
        base_bundle_ref = namespace + "/base"
        git(worktree, "update-ref", base_bundle_ref, base_commit)
        temporary_refs.append(base_bundle_ref)
        requested = list(config.get("preserved_refs", [])) + inferred_preserved_refs(brief_text)
        if (
            re.search(r"\bpreserv\w*\s+(?:relevant\s+)?(?:branches|refs)\b", brief_text, re.IGNORECASE)
            and not requested
        ):
            raise AuthorError(
                "the brief requires preserved refs but cloud-context.json names none"
            )
        sources = []
        for value in requested:
            source, label = normalize_preserved_ref(value, remote)
            sources.append((source, label))
        for number in pr_numbers:
            sources.append(("refs/pull/{}/head".format(number), "pull/{}/head".format(number)))
        seen_sources = set()
        unique_sources = []
        for source, label in sources:
            if source not in seen_sources:
                seen_sources.add(source)
                unique_sources.append((source, label))
        if len(unique_sources) > 100:
            raise AuthorError("preserved repository context exceeds its ref bound")
        for index, (source, label) in enumerate(unique_sources, start=1):
            temporary = namespace + "/preserved/{:04d}".format(index)
            git(worktree, "fetch", "--quiet", "--no-tags", remote, "+{}:{}".format(source, temporary))
            commit = git(worktree, "rev-parse", "--verify", "{}^{{commit}}".format(temporary)).stdout.decode().strip()
            temporary_refs.append(temporary)
            preserved.append({"source_ref": source, "label": label, "bundle_ref": temporary, "commit": commit})
        bundle_path = payload / "repo.bundle"
        git(worktree, "bundle", "create", str(bundle_path), base_bundle_ref, *[item["bundle_ref"] for item in preserved])
    finally:
        for reference in temporary_refs:
            git(worktree, "update-ref", "-d", reference, check=False)

    repository_value = {
        "schema": REPOSITORY_SCHEMA,
        "task": args.task,
        "remote": remote,
        "base_branch": base_branch,
        "base_ref": base_ref,
        "base_commit": base_commit,
        "task_branch": "fm/{}".format(args.task),
        "bundle_base_ref": base_bundle_ref,
        "preserved_refs": preserved,
    }
    repository_body = canonical(repository_value) + b"\n"
    rendered = cloud_brief(
        brief_text, home, args.task, base_branch, base_commit, files, wants_prs,
    ).encode("utf-8")
    if len(rendered) > MAX_BRIEF_BYTES:
        raise AuthorError("cloud-specific brief exceeds its byte bound")
    atomic_write(payload / "repository.json", repository_body)
    atomic_write(payload / "context.json", context_body)
    atomic_write(payload / "context.tar", context_archive)
    atomic_write(payload / "brief.md", rendered)
    print(json.dumps({
        "base_branch": base_branch,
        "base_commit": base_commit,
        "context_entries": len(context_entries),
        "preserved_refs": len(preserved),
    }, sort_keys=True, separators=(",", ":")))


def metadata(path):
    body = read_regular(path, "task metadata", 1024 * 1024).decode("utf-8")
    values = {}
    for line in body.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values.setdefault(key, []).append(value)
    return values


def exactly(values, field):
    entries = values.get(field, [])
    if len(entries) != 1 or not entries[0]:
        raise AuthorError("task metadata {} is not exact".format(field))
    return entries[0]


def parse_pr_view(document):
    values = {}
    for raw in document.splitlines():
        if not raw or raw.startswith(" ") or ":" not in raw:
            continue
        key, value = raw.split(":", 1)
        value = value.strip()
        if value.startswith('"'):
            try:
                value = json.loads(value)
            except json.JSONDecodeError:
                raise AuthorError("gh-axi returned malformed pull request data")
        if key in values:
            raise AuthorError("gh-axi returned duplicate pull request data")
        values[key] = value
    required = ("url", "state", "baseRefName", "headRefName", "headRefOid")
    if any(not isinstance(values.get(key), str) or not values[key] for key in required):
        raise AuthorError("gh-axi pull request view lacks exact publication fields")
    return values


def gh_pr_view(binary, slug, branch):
    result = run(
        [binary, "pr", "view", branch, "--repo", slug, "--fields",
         "url,state,baseRefName,headRefName,headRefOid"],
        check=False,
        limit=MAX_PR_CONTEXT_BYTES,
    )
    if result.returncode != 0:
        return None
    return parse_pr_view(result.stdout.decode("utf-8", errors="strict"))


def write_meta_pr(meta_path, url):
    values = metadata(meta_path)
    existing = values.get("pr", [])
    if existing:
        if existing != [url]:
            raise AuthorError("task metadata already names another pull request")
        return
    body = meta_path.read_bytes()
    if body and not body.endswith(b"\n"):
        body += b"\n"
    body += "pr={}\n".format(url).encode()
    atomic_write(meta_path, body)


def write_done(status_path, url):
    terminal = "done: PR {}".format(url)
    existing = ""
    if status_path.exists():
        if status_path.is_symlink() or not status_path.is_file():
            raise AuthorError("task status destination is redirected")
        existing = status_path.read_text(encoding="utf-8")
    lines = [
        line for line in existing.splitlines()
        if line != terminal and not line.startswith("working: cloud outcome returned to local custody;")
    ]
    lines.append(terminal)
    body = "".join(line + "\n" for line in lines).encode()
    if body != existing.encode():
        atomic_write(status_path, body)


def host_repository_publication(state, task, repository_generation):
    path = state / (task + ".cloud-payload") / "repository.json"
    if not path.exists():
        if path.is_symlink():
            raise AuthorError("host repository contract is redirected")
        return None
    body = read_regular(path, "host repository contract", 1024 * 1024)
    try:
        value = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise AuthorError("host repository contract is unreadable: {}".format(exc))
    required = {
        "schema", "task", "remote", "base_branch", "base_ref", "base_commit",
        "task_branch", "bundle_base_ref", "preserved_refs",
    }
    remote = value.get("remote") if isinstance(value, dict) else None
    base_branch = value.get("base_branch") if isinstance(value, dict) else None
    if (
        not isinstance(value, dict)
        or set(value) != required
        or value.get("schema") != REPOSITORY_SCHEMA
        or value.get("task") != task
        or not isinstance(remote, str)
        or not SAFE_TASK.fullmatch(remote)
        or not isinstance(base_branch, str)
        or not SAFE_BRANCH.fullmatch(base_branch)
        or value.get("base_ref") != "refs/remotes/{}/{}".format(remote, base_branch)
        or value.get("base_commit") != repository_generation
        or value.get("task_branch") != "fm/{}".format(task)
        or not isinstance(value.get("preserved_refs"), list)
        or len(value["preserved_refs"]) > 100
    ):
        raise AuthorError("host repository contract binding differs")
    return {
        "remote": remote,
        "base_branch": base_branch,
        "base_commit": repository_generation,
    }


def return_publication(state, task, repository_generation, manifest):
    fields = {"remote", "base_branch", "base_commit"}
    present = fields.intersection(manifest)
    if present and present != fields:
        raise AuthorError("returned publication contract is partial")
    returned = None
    if present:
        returned = {field: manifest[field] for field in fields}
        if returned["base_commit"] != repository_generation:
            raise AuthorError("returned publication base commit differs from its repository generation")
        validate_branch(returned["base_branch"], "returned base branch")
        if not isinstance(returned["remote"], str) or not SAFE_TASK.fullmatch(returned["remote"]):
            raise AuthorError("returned publication remote is malformed")
    hosted = host_repository_publication(state, task, repository_generation)
    if returned is not None and hosted is not None and returned != hosted:
        raise AuthorError("returned publication contract differs from its host repository contract")
    publication = returned or hosted
    if publication is None:
        raise AuthorError("host publication contract is absent for this legacy return")
    return publication


def publish(args):
    if not SAFE_TASK.fullmatch(args.task):
        raise AuthorError("task identity is malformed")
    state = physical_directory(args.state, "task state directory")
    home = state.parent
    meta_path = state / (args.task + ".meta")
    values = metadata(meta_path)
    if exactly(values, "placement") != "azure" or exactly(values, "kind") != "ship":
        raise AuthorError("host publication applies only to Azure ship work")
    if exactly(values, "mode") != "direct-PR":
        print("local-only Azure ship retained in host custody without forge publication")
        return
    worktree = physical_directory(exactly(values, "worktree"), "leased publication worktree")
    manifest_path = home / "data" / args.task / "cloud-return.json"
    manifest_body = read_regular(manifest_path, "cloud return manifest", 1024 * 1024)
    try:
        manifest = json.loads(manifest_body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise AuthorError("cloud return manifest is unreadable: {}".format(exc))
    if (
        manifest.get("schema") != "fm.worker-return/v1"
        or manifest.get("task") != args.task
        or manifest.get("kind") != "ship"
        or not isinstance(manifest.get("outcome_commits"), int)
        or isinstance(manifest.get("outcome_commits"), bool)
        or manifest["outcome_commits"] < 1
    ):
        raise AuthorError("cloud return manifest is not one exact ship outcome")
    branch = validate_branch(manifest.get("branch"), "returned task branch")
    if branch != "fm/{}".format(args.task):
        raise AuthorError("returned task branch is not exact")
    tip = manifest.get("outcome_tip")
    base = manifest.get("repository_generation")
    if not SHA40.fullmatch(str(tip)) or not SHA40.fullmatch(str(base)):
        raise AuthorError("returned publication commits are malformed")
    publication = return_publication(state, args.task, base, manifest)
    base_branch = publication["base_branch"]
    remote = publication["remote"]
    local_tip = git(worktree, "rev-parse", "--verify", "refs/heads/{}".format(branch)).stdout.decode().strip()
    if local_tip != tip:
        raise AuthorError("host task branch moved away from the exact returned tip")
    if git(worktree, "merge-base", "--is-ancestor", base, tip, check=False).returncode != 0:
        raise AuthorError("returned publication tip is not a fast-forward of its intended base")
    if git(worktree, "status", "--porcelain=v1", "--untracked-files=all").stdout.strip():
        raise AuthorError("leased publication worktree is dirty")
    remote_lines = git(worktree, "ls-remote", "--heads", remote, branch).stdout.decode().splitlines()
    if len(remote_lines) > 1:
        raise AuthorError("publication remote returned an ambiguous task branch")
    if remote_lines:
        remote_tip = remote_lines[0].split()[0]
        if remote_tip != tip and git(worktree, "merge-base", "--is-ancestor", remote_tip, tip, check=False).returncode != 0:
            raise AuthorError("remote task branch diverged from the exact returned tip")
    git(worktree, "push", "--porcelain", remote, "{}:refs/heads/{}".format(tip, branch))
    confirmed = git(worktree, "ls-remote", "--heads", remote, branch).stdout.decode().splitlines()
    if len(confirmed) != 1 or confirmed[0].split()[0] != tip:
        raise AuthorError("remote task branch did not confirm the exact returned tip")

    slug = remote_slug(worktree, remote)
    binary = os.environ.get("FM_GH_AXI_BIN", "gh-axi")
    view = gh_pr_view(binary, slug, branch)
    if view is None:
        report = home / "data" / args.task / "completion.md"
        title = git(worktree, "show", "-s", "--format=%s", tip).stdout.decode("utf-8", errors="replace").strip()
        if not title:
            title = "Azure author outcome for {}".format(args.task)
        created = run(
            [binary, "pr", "create", "--repo", slug, "--base", base_branch,
             "--head", branch, "--title", title[:256], "--body-file", str(report)],
            check=False,
            limit=MAX_PR_CONTEXT_BYTES,
        )
        # A create may have succeeded server-side before the client failed or
        # before this process could persist a receipt.  Always resolve by the
        # branch after the attempt; this makes retry and the crash seam one path.
        view = gh_pr_view(binary, slug, branch)
        if view is None:
            detail = (created.stderr or created.stdout).decode("utf-8", errors="replace").strip()
            raise AuthorError("pull request creation did not converge: {}".format(detail[-500:] or "no diagnostic"))
    if (
        view["state"].lower() != "open"
        or view["baseRefName"] != base_branch
        or view["headRefName"] != branch
        or view["headRefOid"] != tip
        or not PR_URL.fullmatch(view["url"])
    ):
        raise AuthorError("existing pull request does not match the exact returned publication")
    receipt = {
        "schema": PUBLICATION_SCHEMA,
        "task": args.task,
        "remote": remote,
        "repository": slug,
        "base_branch": base_branch,
        "base_commit": base,
        "branch": branch,
        "head": tip,
        "url": view["url"],
    }
    receipt["receipt_digest"] = sha256(canonical(receipt))
    publication_path = home / "data" / args.task / "cloud-publication.json"
    receipt_body = canonical(receipt) + b"\n"
    if publication_path.exists():
        if read_regular(publication_path, "cloud publication receipt", 1024 * 1024) != receipt_body:
            raise AuthorError("cloud publication receipt diverged")
    else:
        atomic_write(publication_path, receipt_body)
    write_meta_pr(meta_path, view["url"])
    write_done(state / (args.task + ".status"), view["url"])
    print(view["url"])


def parser():
    value = argparse.ArgumentParser()
    sub = value.add_subparsers(dest="command", required=True)
    prep = sub.add_parser("prepare")
    prep.add_argument("--home", required=True)
    prep.add_argument("--task", required=True)
    prep.add_argument("--worktree", required=True)
    prep.add_argument("--payload", required=True)
    prep.add_argument("--brief", required=True)
    prep.add_argument("--remote", default="origin")
    prep.set_defaults(func=prepare)
    publish_parser = sub.add_parser("publish")
    publish_parser.add_argument("--state", required=True)
    publish_parser.add_argument("--task", required=True)
    publish_parser.set_defaults(func=publish)
    return value


def main(argv=None):
    args = parser().parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AuthorError, OSError, ValueError) as exc:
        print("AZURE AUTHOR REFUSED: {}".format(exc), file=sys.stderr)
        raise SystemExit(2)
