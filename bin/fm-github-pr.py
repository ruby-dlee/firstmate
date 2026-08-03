#!/usr/bin/env python3
"""Strict adapter for the installed gh-axi pull-request surface.

Observed against gh-axi 0.1.25 on 2026-08-02:

* ``gh-axi api /repos/<owner>/<repo>/pulls/<number>`` emits a nested TOON
  document whose ``head.sha`` and ``base.sha`` values are exact Git SHAs.
* ``gh-axi pr view <number> --repo <owner>/<repo> --full`` emits the complete
  pull-request claims as a ``pull_request:`` TOON document.
* ``gh-axi api PUT .../merge --field sha=<sha> --field merge_method=<method>``
  emits root ``sha``, ``merged``, and ``message`` fields on success.

The adapter deliberately does not pass raw-gh ``--json`` or ``-q`` flags.
It fails closed when gh-axi exits nonzero or its observed document shape is
missing, duplicated, malformed, or inconsistent with the requested PR.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from typing import Any


PR_URL_RE = re.compile(
    r"^https://github\.com/"
    r"(?P<owner>[A-Za-z0-9][A-Za-z0-9-]{0,38})/"
    r"(?P<repo>[A-Za-z0-9._-]+)/pull/(?P<number>[0-9]+)/?$"
)
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
ARRAY_HEADER_RE = re.compile(
    r"^(?P<key>[A-Za-z_][A-Za-z0-9_]*)"
    r"\[(?P<count>0|[1-9][0-9]*)\]"
    r"(?:\{(?P<fields>[A-Za-z_][A-Za-z0-9_]*"
    r"(?:,[A-Za-z_][A-Za-z0-9_]*)*)\})?:$"
)


class GitHubContractError(RuntimeError):
    """Raised when the external GitHub contract cannot be established."""


def parse_pr_url(url: str) -> tuple[str, str, int]:
    match = PR_URL_RE.fullmatch(url)
    if match is None or match.group("owner").endswith("-"):
        raise GitHubContractError(
            "PR URL must match https://github.com/<owner>/<repo>/pull/<number>"
        )
    return match.group("owner"), match.group("repo"), int(match.group("number"))


def _parse_scalar(raw: str, line_number: int) -> Any:
    if raw.startswith(('"', "[", "{")):
        try:
            return json.loads(raw)
        except json.JSONDecodeError as exc:
            raise GitHubContractError(
                f"malformed gh-axi TOON scalar at line {line_number}: {exc.msg}"
            ) from exc
    if raw == "true":
        return True
    if raw == "false":
        return False
    if raw == "null":
        return None
    if re.fullmatch(r"-?[0-9]+", raw):
        return int(raw)
    if not raw or any(char in raw for char in "\r\n"):
        raise GitHubContractError(
            f"malformed gh-axi TOON scalar at line {line_number}"
        )
    return raw


def parse_toon_mapping(document: str) -> dict[tuple[str, ...], Any]:
    """Parse required mappings while isolating unrelated TOON array subtrees."""

    values: dict[tuple[str, ...], Any] = {}
    sections: set[tuple[str, ...]] = set()
    stack: list[str] = []
    saw_content = False
    ignored_array_depth: int | None = None

    for line_number, raw_line in enumerate(document.splitlines(), start=1):
        if not raw_line.strip():
            continue
        saw_content = True
        indent = len(raw_line) - len(raw_line.lstrip(" "))
        if indent % 2:
            raise GitHubContractError(
                f"malformed gh-axi TOON indentation at line {line_number}"
            )
        depth = indent // 2
        if ignored_array_depth is not None:
            if depth > ignored_array_depth:
                continue
            ignored_array_depth = None
        if depth > len(stack):
            raise GitHubContractError(
                f"malformed gh-axi TOON nesting at line {line_number}"
            )
        stack = stack[:depth]
        content = raw_line[indent:]
        array_header = ARRAY_HEADER_RE.fullmatch(content)
        if array_header is not None:
            key = array_header.group("key")
            path = tuple(stack + [key])
            if path in values or path in sections:
                raise GitHubContractError(
                    f"duplicate gh-axi TOON field {'.'.join(path)}"
                )
            sections.add(path)
            ignored_array_depth = depth
            continue
        if ":" not in content:
            raise GitHubContractError(
                f"malformed gh-axi TOON mapping at line {line_number}"
            )
        key, raw_value = content.split(":", 1)
        if KEY_RE.fullmatch(key) is None:
            raise GitHubContractError(
                f"malformed gh-axi TOON key at line {line_number}"
            )
        path = tuple(stack + [key])
        if path in values or path in sections:
            raise GitHubContractError(
                f"duplicate gh-axi TOON field {'.'.join(path)}"
            )
        raw_value = raw_value.lstrip(" ")
        if raw_value == "":
            sections.add(path)
            stack.append(key)
        else:
            values[path] = _parse_scalar(raw_value, line_number)

    if not saw_content:
        raise GitHubContractError("gh-axi returned an empty document")
    return values


def _required(values: dict[tuple[str, ...], Any], *path: str) -> Any:
    key = tuple(path)
    if key not in values:
        raise GitHubContractError(f"gh-axi document is missing {'.'.join(path)}")
    return values[key]


def _command_timeout() -> int:
    raw = os.environ.get("FM_GH_AXI_TIMEOUT_SECONDS", "60")
    try:
        timeout = int(raw)
    except ValueError as exc:
        raise GitHubContractError("FM_GH_AXI_TIMEOUT_SECONDS must be an integer") from exc
    if timeout < 1 or timeout > 600:
        raise GitHubContractError(
            "FM_GH_AXI_TIMEOUT_SECONDS must be between 1 and 600"
        )
    return timeout


def run_gh_axi(arguments: list[str]) -> str:
    binary = os.environ.get("FM_GH_AXI_BIN", "gh-axi")
    try:
        result = subprocess.run(
            [binary, *arguments],
            check=False,
            capture_output=True,
            text=True,
            timeout=_command_timeout(),
        )
    except FileNotFoundError as exc:
        raise GitHubContractError(f"gh-axi is unavailable at {binary}") from exc
    except subprocess.TimeoutExpired as exc:
        raise GitHubContractError("gh-axi timed out") from exc
    except OSError as exc:
        raise GitHubContractError(f"gh-axi could not start: {exc}") from exc
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        if len(detail) > 500:
            detail = detail[:500] + "..."
        raise GitHubContractError(
            f"gh-axi exited {result.returncode}: {detail or 'no diagnostic'}"
        )
    if not result.stdout.strip():
        raise GitHubContractError("gh-axi returned no document")
    return result.stdout


def fetch_pr_api(url: str) -> dict[str, Any]:
    owner, repo, number = parse_pr_url(url)
    raw = run_gh_axi(["api", f"/repos/{owner}/{repo}/pulls/{number}"])
    values = parse_toon_mapping(raw)
    actual_number = _required(values, "number")
    state = _required(values, "state")
    merged = _required(values, "merged")
    head_sha = _required(values, "head", "sha")
    head_ref = _required(values, "head", "ref")
    head_repo = _required(values, "head", "repo", "full_name")
    base_sha = _required(values, "base", "sha")
    base_ref = _required(values, "base", "ref")
    base_repo = _required(values, "base", "repo", "full_name")

    if actual_number != number:
        raise GitHubContractError(
            f"gh-axi returned PR {actual_number!r}, expected {number}"
        )
    if state not in {"open", "closed"} or not isinstance(merged, bool):
        raise GitHubContractError("gh-axi returned invalid PR state fields")
    if not isinstance(head_sha, str) or SHA_RE.fullmatch(head_sha) is None:
        raise GitHubContractError("gh-axi returned an invalid head.sha")
    if not isinstance(base_sha, str) or SHA_RE.fullmatch(base_sha) is None:
        raise GitHubContractError("gh-axi returned an invalid base.sha")
    for label, value in (
        ("head.ref", head_ref),
        ("head.repo.full_name", head_repo),
        ("base.ref", base_ref),
        ("base.repo.full_name", base_repo),
    ):
        if not isinstance(value, str) or not value:
            raise GitHubContractError(f"gh-axi returned an invalid {label}")

    return {
        "url": url.rstrip("/"),
        "owner": owner,
        "repo": repo,
        "number": number,
        "state": state,
        "merged": merged,
        "head_sha": head_sha,
        "head_ref": head_ref,
        "head_repo": head_repo,
        "base_sha": base_sha,
        "base_ref": base_ref,
        "base_repo": base_repo,
        "api_document": raw,
    }


def fetch_claims(url: str) -> tuple[str, dict[str, Any]]:
    owner, repo, number = parse_pr_url(url)
    raw = run_gh_axi(
        ["pr", "view", str(number), "--repo", f"{owner}/{repo}", "--full"]
    )
    values = parse_toon_mapping(raw)
    actual_number = _required(values, "pull_request", "number")
    if actual_number != number:
        raise GitHubContractError(
            f"gh-axi claims document returned PR {actual_number!r}, expected {number}"
        )
    title = _required(values, "pull_request", "title")
    body = _required(values, "pull_request", "body")
    if not isinstance(title, str) or not title:
        raise GitHubContractError("gh-axi claims document has an invalid title")
    if not isinstance(body, str):
        raise GitHubContractError("gh-axi claims document has a non-string body")
    return raw, {"number": number, "title": title, "body": body}


def snapshot(url: str) -> dict[str, Any]:
    result = fetch_pr_api(url)
    claims_document, claims_identity = fetch_claims(url)
    result["claims_document"] = claims_document
    result["claims_identity"] = claims_identity
    return result


def merge_exact(
    url: str,
    expected_sha: str,
    method: str,
    title: str | None,
    body: str | None,
) -> dict[str, Any]:
    owner, repo, number = parse_pr_url(url)
    if SHA_RE.fullmatch(expected_sha) is None:
        raise GitHubContractError("expected merge head must be one 40-hex SHA")
    if method not in {"merge", "squash", "rebase"}:
        raise GitHubContractError("merge method must be merge, squash, or rebase")
    arguments = [
        "api",
        "PUT",
        f"/repos/{owner}/{repo}/pulls/{number}/merge",
        "--field",
        f"sha={expected_sha}",
        "--field",
        f"merge_method={method}",
    ]
    if title is not None:
        arguments.extend(["--field", f"commit_title={title}"])
    if body is not None:
        arguments.extend(["--field", f"commit_message={body}"])
    raw = run_gh_axi(arguments)
    values = parse_toon_mapping(raw)
    merge_sha = _required(values, "sha")
    merged = _required(values, "merged")
    message = _required(values, "message")
    if not isinstance(merge_sha, str) or SHA_RE.fullmatch(merge_sha) is None:
        raise GitHubContractError("gh-axi merge response has an invalid sha")
    if merged is not True or not isinstance(message, str) or not message:
        raise GitHubContractError("gh-axi merge response did not confirm merged: true")
    return {"sha": merge_sha, "merged": True, "message": message}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("snapshot", "head", "state"):
        command = subparsers.add_parser(name)
        command.add_argument("pr_url")
    merge = subparsers.add_parser("merge")
    merge.add_argument("pr_url")
    merge.add_argument("expected_sha")
    merge.add_argument("method", choices=("merge", "squash", "rebase"))
    merge.add_argument("--title")
    merge.add_argument("--body")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.command == "snapshot":
            print(json.dumps(snapshot(args.pr_url), sort_keys=True))
        elif args.command == "head":
            print(fetch_pr_api(args.pr_url)["head_sha"])
        elif args.command == "state":
            state = fetch_pr_api(args.pr_url)
            print("MERGED" if state["merged"] else str(state["state"]).upper())
        elif args.command == "merge":
            print(
                json.dumps(
                    merge_exact(
                        args.pr_url,
                        args.expected_sha,
                        args.method,
                        args.title,
                        args.body,
                    ),
                    sort_keys=True,
                )
            )
        else:
            raise AssertionError(f"unhandled command {args.command}")
    except GitHubContractError as exc:
        print(f"error: GitHub state is unreviewed: {exc}", file=sys.stderr)
        return 1
    except Exception as exc:
        print(
            f"error: GitHub state is unreviewed: unexpected {type(exc).__name__}: {exc}",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
