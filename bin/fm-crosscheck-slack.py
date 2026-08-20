#!/usr/bin/env python3
"""Slack Socket Mode exposure of the crosscheck gate for team engineers (R10).

An engineer tags the crosscheck bot in an allowlisted Slack channel with a
GitHub pull-request link; the bot runs the crosscheck CLI for that PR and
posts the findings as a thread reply on the engineer's own message, naming
the lane that produced the review. The listener uses Socket Mode, so no
public inbound endpoint is added to the private lane posture.

Posture, in one place:

- Slack text and PR content are DATA, never instructions. The only thing
  this process ever takes from a mention is one pull-request URL, which is
  validated against the repository allowlist before any credentialed tool
  sees it. Nothing from Slack or from the PR is ever executed.
- Tokens come only from environment variables named by the config file.
  They are never stored in the config, never written to state, never placed
  in a child process environment (except the GitHub read credential, whose
  entire job is to be the crosscheck subprocess's read credential), and
  every log line passes through a redactor that knows every secret value.
- A missing token environment variable is a startup refusal that names the
  exact variable, so the ready-to-flip posture is explicit: the owner
  supplies tokens later and nothing else changes.
- Every Slack event id is claimed durably before any work starts, so a
  retried delivery of the same event never starts a second review.
- Team usage is metered per submitter per UTC day in a durable JSON ledger
  (the C3 hook). When `daily_budget_usd` is set and a submitter's recorded
  day total meets it, the bot says so in the thread instead of silently
  dropping the request. A null budget is unmetered pass-through, still
  ledgered.

The review itself belongs to bin/fm-crosscheck.sh; this file never
reimplements or weakens any part of that gate. The websocket client below
is a deliberately minimal RFC 6455 implementation over the standard
library, because the repo carries no third-party Python dependencies and a
Socket Mode listener needs exactly one client-side websocket.
"""

from __future__ import annotations

import argparse
import base64
import dataclasses
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import secrets
import socket
import ssl
import struct
import sys
import tempfile
import threading
import time
from typing import Any, Callable, NoReturn
import urllib.error
import urllib.parse
import urllib.request

BIN_DIR = Path(__file__).resolve().parent
if str(BIN_DIR) not in sys.path:
    sys.path.insert(0, str(BIN_DIR))

from fm_bounded_io import BoundedIOError, read_bounded_json, run_bounded


TOOL = "fm-crosscheck-slack"
METER_SCHEMA = "firstmate.crosscheck-slack-meter.v1"

CONFIG_KEYS = {
    "app_token_env",
    "bot_token_env",
    "channel_allowlist",
    "repo_allowlist",
    "github_token_env",
    "daily_budget_usd",
    "state_dir",
}
ENV_NAME_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
REPO_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$")
CHANNEL_RE = re.compile(r"^[A-Z0-9]{1,32}$")
EVENT_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
PR_LINK_RE = re.compile(
    r"https://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/"
    r"([A-Za-z0-9._-]{1,100})/pull/([0-9]{1,10})"
)

MAX_CONFIG_BYTES = 64 * 1024
MAX_METER_BYTES = 8 * 1024 * 1024
MAX_LEDGER_BYTES = 16 * 1024 * 1024
MAX_REVIEW_OUTPUT_BYTES = 4 * 1024 * 1024
DEFAULT_REVIEW_TIMEOUT_SECONDS = 5400.0
MAX_REPLY_CHARS = 3500
MAX_SUMMARY_CHARS = 900
MAX_LISTED_FINDINGS = 10
WS_MAX_PAYLOAD = 4 * 1024 * 1024
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
WEB_API_TIMEOUT_SECONDS = 30
REVIEW_QUEUE_LIMIT = 8
RECONNECT_BACKOFF_CAP_SECONDS = 60.0


class SlackExposureError(RuntimeError):
    """A validated refusal with a message safe to show and to log."""


def refuse(message: str) -> NoReturn:
    print(f"{TOOL} REFUSED: {redact(message)}", file=sys.stderr, flush=True)
    raise SystemExit(3)


# --- secret redaction --------------------------------------------------------
#
# Every token this process resolves is registered here, and every line the
# process emits goes through redact(). Belt and braces: no call site is ever
# handed a token to log in the first place, and the redactor catches the
# mistake if one is.

_SECRETS: list[str] = []


def register_secret(value: str) -> None:
    if value and value not in _SECRETS:
        _SECRETS.append(value)


def redact(text: str) -> str:
    for secret in _SECRETS:
        text = text.replace(secret, "[redacted]")
    return text


def log(message: str) -> None:
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"{stamp} {TOOL}: {redact(message)}", flush=True)


# --- configuration ------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class Config:
    path: Path
    app_token_env: str
    bot_token_env: str
    github_token_env: str
    channel_allowlist: tuple[str, ...]
    repo_allowlist: tuple[str, ...]
    daily_budget_usd: float | None
    state_dir: Path


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SlackExposureError(message)


def require_string(value: Any, label: str) -> str:
    require(isinstance(value, str) and value.strip() != "", f"{label} must be a nonempty string")
    return value.strip()


def default_config_path() -> Path:
    override = os.environ.get("FM_CROSSCHECK_SLACK_CONFIG", "")
    if override:
        return Path(override)
    home = os.environ.get("FM_HOME", "")
    if not home:
        raise SlackExposureError(
            "FM_HOME is required to locate config/crosscheck-slack.json "
            "(or set FM_CROSSCHECK_SLACK_CONFIG to an explicit path)"
        )
    return Path(home) / "config" / "crosscheck-slack.json"


def expand_state_dir(raw: str) -> Path:
    if raw == "$FM_HOME" or raw.startswith("$FM_HOME/"):
        home = os.environ.get("FM_HOME", "")
        require(
            home != "",
            "state_dir references $FM_HOME but FM_HOME is not set in the environment",
        )
        raw = home + raw[len("$FM_HOME"):]
    require(
        "$" not in raw,
        "state_dir supports only a literal leading $FM_HOME reference; "
        f"other substitutions are refused: {raw!r}",
    )
    path = Path(raw)
    require(path.is_absolute(), f"state_dir must resolve to an absolute path, got {raw!r}")
    return path


def load_config(path: Path) -> Config:
    try:
        value = read_bounded_json(path, maximum_bytes=MAX_CONFIG_BYTES)
    except BoundedIOError as exc:
        raise SlackExposureError(f"configuration at {path} is unreadable: {exc}") from exc
    require(isinstance(value, dict), f"configuration at {path} must be a JSON object")
    unexpected = sorted(set(value) - CONFIG_KEYS)
    missing = sorted(CONFIG_KEYS - set(value))
    require(not unexpected, f"configuration at {path} has unexpected keys: {', '.join(unexpected)}")
    require(not missing, f"configuration at {path} is missing keys: {', '.join(missing)}")

    env_names: dict[str, str] = {}
    for key in ("app_token_env", "bot_token_env", "github_token_env"):
        name = require_string(value.get(key), f"configuration {key}")
        require(
            ENV_NAME_RE.fullmatch(name) is not None,
            f"configuration {key} must name an environment variable "
            f"(uppercase letters, digits, underscores), got {name!r}",
        )
        env_names[key] = name
    require(
        len(set(env_names.values())) == 3,
        "configuration app_token_env, bot_token_env, and github_token_env "
        "must name three distinct environment variables",
    )

    channels_raw = value.get("channel_allowlist")
    require(
        isinstance(channels_raw, list) and channels_raw,
        "configuration channel_allowlist must be a nonempty array of Slack channel ids",
    )
    channels: list[str] = []
    for index, channel in enumerate(channels_raw):
        channel = require_string(channel, f"configuration channel_allowlist[{index}]")
        require(
            CHANNEL_RE.fullmatch(channel) is not None,
            f"configuration channel_allowlist[{index}] must be a Slack channel id "
            f"(e.g. C0123ABCDEF), got {channel!r}",
        )
        channels.append(channel)

    repos_raw = value.get("repo_allowlist")
    require(
        isinstance(repos_raw, list) and repos_raw,
        "configuration repo_allowlist must be a nonempty array of owner/name repositories",
    )
    repos: list[str] = []
    for index, repo in enumerate(repos_raw):
        repo = require_string(repo, f"configuration repo_allowlist[{index}]")
        require(
            REPO_RE.fullmatch(repo) is not None,
            f"configuration repo_allowlist[{index}] must be owner/name, got {repo!r}",
        )
        repos.append(repo.lower())

    budget_raw = value.get("daily_budget_usd")
    budget: float | None
    if budget_raw is None:
        budget = None
    else:
        require(
            isinstance(budget_raw, (int, float)) and not isinstance(budget_raw, bool),
            "configuration daily_budget_usd must be null or a positive number",
        )
        budget = float(budget_raw)
        require(budget > 0, "configuration daily_budget_usd must be null or a positive number")

    state_dir = expand_state_dir(require_string(value.get("state_dir"), "configuration state_dir"))

    return Config(
        path=path,
        app_token_env=env_names["app_token_env"],
        bot_token_env=env_names["bot_token_env"],
        github_token_env=env_names["github_token_env"],
        channel_allowlist=tuple(channels),
        repo_allowlist=tuple(repos),
        daily_budget_usd=budget,
        state_dir=state_dir,
    )


def required_token(env_name: str, role: str) -> str:
    value = os.environ.get(env_name)
    if value is None or value == "":
        refuse(
            f"cannot start: the {role} environment variable {env_name} is not set. "
            f"Export {env_name} with the credential and start again; the token is "
            "never stored in the config file"
        )
    register_secret(value)
    return value


# --- durable event dedupe -----------------------------------------------------


class EventDeduper:
    """Durable first-claim-wins registry of processed Slack event ids."""

    def __init__(self, directory: Path) -> None:
        self.directory = directory
        directory.mkdir(parents=True, exist_ok=True)

    def claim(self, event_id: str) -> bool:
        require(
            EVENT_ID_RE.fullmatch(event_id) is not None,
            f"event id validation rejected {event_id!r}",
        )
        path = self.directory / f"{event_id}.claimed"
        try:
            descriptor = os.open(str(path), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError:
            return False
        try:
            os.write(
                descriptor,
                json.dumps({"claimed_at": utc_now()}).encode("utf-8") + b"\n",
            )
        finally:
            os.close(descriptor)
        return True


# --- per-submitter daily meter --------------------------------------------------


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def utc_day() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")


class DailyMeter:
    """Durable per-UTC-day, per-submitter request ledger (the C3 hook).

    Each request lands as one record: submitter, PR, timestamps, outcome,
    token usage when the crosscheck output exposes it, and estimated USD when
    derivable (else null). Writes are atomic (temp file + rename) under one
    advisory lock so a crash never leaves a torn ledger.
    """

    def __init__(self, directory: Path) -> None:
        self.directory = directory
        directory.mkdir(parents=True, exist_ok=True)

    def _day_path(self, day: str) -> Path:
        return self.directory / f"{day}.json"

    def _load(self, day: str) -> dict[str, Any]:
        path = self._day_path(day)
        if not path.exists():
            return {"schema": METER_SCHEMA, "day": day, "requests": []}
        value = read_bounded_json(path, maximum_bytes=MAX_METER_BYTES)
        require(
            isinstance(value, dict)
            and value.get("schema") == METER_SCHEMA
            and isinstance(value.get("requests"), list),
            f"meter ledger at {path} is not a {METER_SCHEMA} document",
        )
        return value

    def _write(self, day: str, value: dict[str, Any]) -> None:
        path = self._day_path(day)
        encoded = json.dumps(value, indent=2, sort_keys=True) + "\n"
        descriptor, temp_name = tempfile.mkstemp(prefix=".meter.", dir=str(self.directory))
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                handle.write(encoded)
            os.chmod(temp_name, 0o600)
            os.replace(temp_name, path)
        except BaseException:
            try:
                os.unlink(temp_name)
            except OSError:
                pass
            raise

    def _locked(self) -> Any:
        lock_path = self.directory / ".lock"
        handle = lock_path.open("a+", encoding="utf-8")
        fcntl.flock(handle, fcntl.LOCK_EX)
        return handle

    def begin(self, submitter: str, pr_url: str, event_id: str) -> str:
        day = utc_day()
        request_id = f"req-{secrets.token_hex(6)}"
        with self._locked():
            ledger = self._load(day)
            ledger["requests"].append(
                {
                    "id": request_id,
                    "submitter": submitter,
                    "pr_url": pr_url,
                    "event_id": event_id,
                    "started_at": utc_now(),
                    "finished_at": None,
                    "status": "started",
                    "lane": None,
                    "tokens": None,
                    "estimated_usd": None,
                }
            )
            self._write(day, ledger)
        return request_id

    def finish(
        self,
        request_id: str,
        status: str,
        lane: str | None,
        tokens: dict[str, int] | None,
        estimated_usd: float | None,
    ) -> None:
        day = utc_day()
        with self._locked():
            ledger = self._load(day)
            for record in ledger["requests"]:
                if record.get("id") == request_id:
                    record["finished_at"] = utc_now()
                    record["status"] = status
                    record["lane"] = lane
                    record["tokens"] = tokens
                    record["estimated_usd"] = estimated_usd
                    break
            else:
                # A request begun just before midnight UTC finishes in the
                # next day's ledger as its own completed record rather than
                # being dropped.
                ledger["requests"].append(
                    {
                        "id": request_id,
                        "submitter": "unknown",
                        "pr_url": "unknown",
                        "event_id": "unknown",
                        "started_at": None,
                        "finished_at": utc_now(),
                        "status": status,
                        "lane": lane,
                        "tokens": tokens,
                        "estimated_usd": estimated_usd,
                    }
                )
            self._write(day, ledger)

    def submitter_day_usd(self, submitter: str) -> float:
        with self._locked():
            ledger = self._load(utc_day())
        total = 0.0
        for record in ledger["requests"]:
            if record.get("submitter") != submitter:
                continue
            cost = record.get("estimated_usd")
            if isinstance(cost, (int, float)) and not isinstance(cost, bool):
                total += float(cost)
        return total

    def submitter_day_count(self, submitter: str) -> int:
        with self._locked():
            ledger = self._load(utc_day())
        return sum(1 for record in ledger["requests"] if record.get("submitter") == submitter)


# --- pull-request link handling -------------------------------------------------


def extract_pr_links(text: str) -> list[str]:
    """Return unique canonical GitHub PR URLs from Slack message text.

    Slack wraps links as <url> or <url|label>; the regex matches the URL body
    directly because '|' and '>' cannot appear inside it. Order is preserved
    and duplicates (case-insensitive owner/repo) collapse to one entry.
    """

    links: list[str] = []
    seen: set[str] = set()
    for match in PR_LINK_RE.finditer(text or ""):
        owner, repo, number = match.group(1), match.group(2), match.group(3)
        if repo.lower().endswith(".git"):
            repo = repo[: -len(".git")]
        key = f"{owner.lower()}/{repo.lower()}#{number}"
        if key in seen:
            continue
        seen.add(key)
        links.append(f"https://github.com/{owner}/{repo}/pull/{number}")
    return links


def repo_of(pr_url: str) -> str:
    match = PR_LINK_RE.fullmatch(pr_url)
    require(match is not None, f"internal error: unparseable PR URL {pr_url!r}")
    return f"{match.group(1)}/{match.group(2)}".lower()


# --- lane naming -----------------------------------------------------------------


def lane_name(reviewer: Any) -> str:
    """Name the lane that produced a ledger run, for the R6/R10 visibility rule.

    Prefers an explicit lane marker recorded by the crosscheck ledger (the
    sibling GLM/degraded-mode work); when the run predates that marker, the
    lane is derived from the reviewer profile that ran: a GLM model is the
    primary lane and the retained pi/codex roster is the recorded degraded
    fallback.
    """

    if not isinstance(reviewer, dict):
        return "unknown lane"
    marker = reviewer.get("lane")
    if isinstance(marker, str) and marker.strip():
        name = marker.strip()
        if reviewer.get("degraded") is True and "degraded" not in name.lower():
            name += " (degraded)"
        return name
    model = str(reviewer.get("model") or "")
    harness = str(reviewer.get("harness") or "")
    lowered = model.lower()
    if "glm" in lowered:
        return "GLM-5.2 primary" if "5.2" in lowered else f"{model} primary"
    if harness in {"pi", "codex"}:
        return "pi-codex fallback (degraded)"
    if harness or model:
        return f"{harness} {model}".strip() + " lane"
    return "unknown lane"


# --- reply rendering ---------------------------------------------------------------


def escape_slack(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def clamp(text: str, limit: int) -> str:
    text = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", text)
    if len(text) <= limit:
        return text
    return text[: limit - 12].rstrip() + " [truncated]"


@dataclasses.dataclass
class ReviewOutcome:
    ok: bool
    state: str
    lane: str | None
    reply_text: str
    tokens: dict[str, int] | None
    estimated_usd: float | None
    task_id: str


def usage_from_run(run: dict[str, Any]) -> tuple[dict[str, int] | None, float | None]:
    """Read token usage and estimated USD when the crosscheck output exposes it.

    Today's ledger schema does not record usage; the sibling GLM lane work may
    add it. Absent or malformed usage is null, never guessed.
    """

    usage = run.get("usage")
    if not isinstance(usage, dict):
        return None, None
    tokens: dict[str, int] = {}
    for key in (
        "input_tokens",
        "output_tokens",
        "prompt_tokens",
        "completion_tokens",
        "total_tokens",
    ):
        raw = usage.get(key)
        if isinstance(raw, int) and not isinstance(raw, bool) and raw >= 0:
            tokens[key] = raw
    estimated: float | None = None
    for key in ("estimated_usd", "cost_usd"):
        raw = usage.get(key)
        if isinstance(raw, (int, float)) and not isinstance(raw, bool) and raw >= 0:
            estimated = float(raw)
            break
    return (tokens or None), estimated


def render_verdict_reply(
    pr_url: str,
    run: dict[str, Any],
    ledger: dict[str, Any],
    lane: str,
    report_path: Path,
) -> str:
    state = str(run.get("state") or "unknown").upper()
    lines = [
        f"Crosscheck {state} for {pr_url}",
        f"Lane: {lane}",
    ]
    head = run.get("head_sha")
    if isinstance(head, str) and head:
        lines.append(f"Reviewed head: {head}")
    summary = run.get("summary")
    if isinstance(summary, str) and summary.strip():
        lines.append(f"Summary: {escape_slack(clamp(summary.strip(), MAX_SUMMARY_CHARS))}")
    findings = ledger.get("findings")
    if isinstance(findings, list) and findings:
        active = [
            finding
            for finding in findings
            if isinstance(finding, dict)
            and finding.get("lifecycle") in {"open", "claimed-fixed"}
        ]
        if active:
            lines.append(f"Active findings ({len(active)}):")
            for finding in active[:MAX_LISTED_FINDINGS]:
                title = escape_slack(clamp(str(finding.get("title") or "(untitled)"), 200))
                severity = str(finding.get("severity") or "unrated")
                lines.append(f"- [{severity}] {title}")
            if len(active) > MAX_LISTED_FINDINGS:
                lines.append(f"- ... and {len(active) - MAX_LISTED_FINDINGS} more in the report")
        else:
            lines.append("No active findings for this head.")
    else:
        lines.append("No active findings for this head.")
    lines.append(f"Full report: {report_path}")
    return clamp("\n".join(lines), MAX_REPLY_CHARS)


def render_failure_reply(pr_url: str, reason: str) -> str:
    body = escape_slack(clamp(redact(reason), MAX_SUMMARY_CHARS))
    return clamp(
        f"Crosscheck TOOL FAILURE for {pr_url}: {body}\n"
        "No verdict was produced; this is an infrastructure failure, not a "
        "review outcome. Retry after the failure is addressed.",
        MAX_REPLY_CHARS,
    )


# --- running the crosscheck CLI ------------------------------------------------------


def review_timeout_seconds() -> float:
    raw = os.environ.get("FM_CROSSCHECK_SLACK_REVIEW_TIMEOUT_SECONDS", "")
    if not raw:
        return DEFAULT_REVIEW_TIMEOUT_SECONDS
    try:
        value = float(raw)
    except ValueError:
        raise SlackExposureError(
            f"FM_CROSSCHECK_SLACK_REVIEW_TIMEOUT_SECONDS is not a number: {raw!r}"
        )
    require(0 < value <= 24 * 3600, "review timeout must be between 0 and 86400 seconds")
    return value


def crosscheck_argv(task_id: str, pr_url: str) -> list[str]:
    override = os.environ.get("FM_CROSSCHECK_SLACK_CROSSCHECK_BIN", "")
    binary = override or str(BIN_DIR / "fm-crosscheck.sh")
    return [binary, "run", task_id, pr_url]


def scrubbed_child_environment(config: Config, github_token: str) -> dict[str, str]:
    """Build the crosscheck subprocess environment.

    Only the process-neutral basics and FM_* configuration pass through; the
    Slack tokens never do, and neither does any variable whose value matches
    a registered secret other than the GitHub read credential, which is
    exported both under its configured name and as GH_TOKEN because being the
    subprocess's repository read credential is its entire purpose.
    """

    excluded = {config.app_token_env, config.bot_token_env}
    child: dict[str, str] = {}
    for key, value in os.environ.items():
        if key in excluded:
            continue
        keep = key in {"PATH", "HOME", "TMPDIR", "LANG", "USER", "SHELL"}
        keep = keep or key.startswith("LC_") or key.startswith("FM_")
        if not keep:
            continue
        if value in _SECRETS and value != github_token:
            continue
        child[key] = value
    child[config.github_token_env] = github_token
    child["GH_TOKEN"] = github_token
    return child


def make_run_review(config: Config, github_token: str) -> Callable[[str], ReviewOutcome]:
    fm_home_raw = os.environ.get("FM_HOME", "")
    if not fm_home_raw:
        raise SlackExposureError("FM_HOME is required to run crosscheck reviews")
    fm_home = Path(fm_home_raw).resolve()
    state = Path(os.environ.get("FM_STATE_OVERRIDE") or fm_home / "state")
    data = Path(os.environ.get("FM_DATA_OVERRIDE") or fm_home / "data")

    def run_review(pr_url: str) -> ReviewOutcome:
        task_id = f"slack-{secrets.token_hex(6)}"
        state.mkdir(parents=True, exist_ok=True)
        # The crosscheck gate derives the author's model family from task
        # metadata; a Slack-submitted engineer PR is human-authored, so every
        # reviewer model family is structurally separate from the author.
        (state / f"{task_id}.meta").write_text(
            "harness=slack-team\nmodel=human-authored\n", encoding="utf-8"
        )
        argv = crosscheck_argv(task_id, pr_url)
        try:
            result = run_bounded(
                argv,
                timeout_seconds=review_timeout_seconds(),
                maximum_output_bytes=MAX_REVIEW_OUTPUT_BYTES,
                env=scrubbed_child_environment(config, github_token),
            )
        except BoundedIOError as exc:
            return ReviewOutcome(
                ok=False,
                state="tool-failure",
                lane=None,
                reply_text=render_failure_reply(pr_url, f"the crosscheck run exceeded its bounds: {exc}"),
                tokens=None,
                estimated_usd=None,
                task_id=task_id,
            )
        ledger_path = data / task_id / "crosscheck-ledger.json"
        report_path = data / task_id / "crosscheck.md"
        if not ledger_path.is_file():
            stderr_tail = result.stderr.decode("utf-8", "replace")[-800:].strip()
            return ReviewOutcome(
                ok=False,
                state="tool-failure",
                lane=None,
                reply_text=render_failure_reply(
                    pr_url,
                    f"the crosscheck CLI exited {result.returncode} without a ledger: "
                    f"{stderr_tail or 'no diagnostic'}",
                ),
                tokens=None,
                estimated_usd=None,
                task_id=task_id,
            )
        try:
            ledger = read_bounded_json(ledger_path, maximum_bytes=MAX_LEDGER_BYTES)
        except BoundedIOError as exc:
            return ReviewOutcome(
                ok=False,
                state="tool-failure",
                lane=None,
                reply_text=render_failure_reply(pr_url, f"the crosscheck ledger is unreadable: {exc}"),
                tokens=None,
                estimated_usd=None,
                task_id=task_id,
            )
        runs = ledger.get("runs") if isinstance(ledger, dict) else None
        if not isinstance(runs, list) or not runs or not isinstance(runs[-1], dict):
            return ReviewOutcome(
                ok=False,
                state="tool-failure",
                lane=None,
                reply_text=render_failure_reply(pr_url, "the crosscheck ledger recorded no runs"),
                tokens=None,
                estimated_usd=None,
                task_id=task_id,
            )
        run = runs[-1]
        lane = lane_name(run.get("reviewer"))
        tokens, estimated = usage_from_run(run)
        reply = render_verdict_reply(pr_url, run, ledger, lane, report_path)
        return ReviewOutcome(
            ok=True,
            state=str(run.get("state") or "unknown"),
            lane=lane,
            reply_text=reply,
            tokens=tokens,
            estimated_usd=estimated,
            task_id=task_id,
        )

    return run_review


# --- the event-handling core (driven directly by the tests) -------------------------


@dataclasses.dataclass
class MentionContext:
    config: Config
    meter: DailyMeter
    deduper: EventDeduper
    post: Callable[[str, str, str], None]  # channel, thread_ts, text
    react: Callable[[str, str, str], None]  # channel, ts, emoji name
    run_review: Callable[[str], ReviewOutcome]
    log: Callable[[str], None] = log


def usage_reply() -> str:
    return (
        "Tag me with one GitHub pull-request link to get a crosscheck review, "
        "for example: @crosscheck https://github.com/ORG/REPO/pull/123"
    )


def handle_mention(event_id: str, event: dict[str, Any], ctx: MentionContext) -> str:
    """Process one app_mention event. Returns the action taken (for tests/logs).

    Slack text is data: the only value this function extracts from it is a
    pull-request URL validated against the repository allowlist. Nothing in
    the message is executed or interpolated into a command line beyond that
    single validated URL.
    """

    channel = str(event.get("channel") or "")
    user = str(event.get("user") or "unknown")
    ts = str(event.get("ts") or "")
    thread_ts = str(event.get("thread_ts") or ts)
    text = str(event.get("text") or "")
    if not channel or not ts:
        ctx.log(f"ignoring malformed mention event {event_id}: missing channel or ts")
        return "malformed"

    if not ctx.deduper.claim(event_id):
        ctx.log(f"duplicate delivery of event {event_id}; not starting a second review")
        return "duplicate"

    if channel not in ctx.config.channel_allowlist:
        ctx.post(
            channel,
            thread_ts,
            "This channel is not enabled for crosscheck reviews. "
            "Ask the owner to add it to the channel allowlist.",
        )
        return "channel-refused"

    links = extract_pr_links(text)
    if not links:
        ctx.post(channel, thread_ts, usage_reply())
        return "no-link"
    if len(links) > 1:
        ctx.post(
            channel,
            thread_ts,
            "One pull-request link per request, please; I received "
            f"{len(links)}. Mention me once per PR.",
        )
        return "multiple-links"
    pr_url = links[0]

    repo = repo_of(pr_url)
    if repo not in ctx.config.repo_allowlist:
        allowed = ", ".join(ctx.config.repo_allowlist)
        ctx.post(
            channel,
            thread_ts,
            f"Refusing to review {pr_url}: repository {repo} is not in the "
            f"crosscheck repository allowlist ({allowed}). The bot's read "
            "credential is never pointed at repositories outside the allowlist.",
        )
        return "repo-refused"

    budget = ctx.config.daily_budget_usd
    if budget is not None:
        spent = ctx.meter.submitter_day_usd(user)
        if spent >= budget:
            ctx.post(
                channel,
                thread_ts,
                f"Daily crosscheck budget reached: ${spent:.2f} of ${budget:.2f} "
                "recorded for you today, so this review is not starting. "
                "The bound resets at midnight UTC.",
            )
            return "budget-refused"

    try:
        ctx.react(channel, ts, "hourglass_flowing_sand")
    except Exception as exc:  # a failed reaction never blocks the review
        ctx.log(f"reaction failed for event {event_id}: {exc}")
    ctx.post(
        channel,
        thread_ts,
        f"Review started for {pr_url}. Findings will land in this thread "
        "with the reviewing lane named.",
    )

    request_id = ctx.meter.begin(user, pr_url, event_id)
    try:
        outcome = ctx.run_review(pr_url)
    except Exception as exc:
        ctx.meter.finish(request_id, "tool-failure", None, None, None)
        ctx.post(channel, thread_ts, render_failure_reply(pr_url, f"unexpected {type(exc).__name__}: {exc}"))
        return "failed"
    ctx.meter.finish(
        request_id,
        outcome.state if outcome.ok else "tool-failure",
        outcome.lane,
        outcome.tokens,
        outcome.estimated_usd,
    )
    ctx.post(channel, thread_ts, outcome.reply_text)
    return f"completed:{outcome.state}" if outcome.ok else "failed"


# --- Slack Web API client ---------------------------------------------------------


class SlackWebClient:
    def __init__(self, bot_token: str, app_token: str) -> None:
        self._bot_token = bot_token
        self._app_token = app_token

    def _call(self, method: str, payload: dict[str, Any], token: str) -> dict[str, Any]:
        request = urllib.request.Request(
            f"https://slack.com/api/{method}",
            data=json.dumps(payload).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json; charset=utf-8",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=WEB_API_TIMEOUT_SECONDS) as response:
                body = response.read(1024 * 1024)
        except (urllib.error.URLError, OSError) as exc:
            raise SlackExposureError(f"Slack API {method} failed: {exc}") from exc
        try:
            value = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise SlackExposureError(f"Slack API {method} returned malformed JSON") from exc
        if not isinstance(value, dict) or value.get("ok") is not True:
            error = value.get("error") if isinstance(value, dict) else "unknown"
            raise SlackExposureError(f"Slack API {method} refused: {error}")
        return value

    def connections_open(self) -> str:
        value = self._call("apps.connections.open", {}, self._app_token)
        url = value.get("url")
        if not isinstance(url, str) or not url.startswith("wss://"):
            raise SlackExposureError("apps.connections.open returned no wss URL")
        return url

    def post_message(self, channel: str, thread_ts: str, text: str) -> None:
        self._call(
            "chat.postMessage",
            {"channel": channel, "thread_ts": thread_ts, "text": redact(text)},
            self._bot_token,
        )

    def add_reaction(self, channel: str, ts: str, name: str) -> None:
        self._call(
            "reactions.add",
            {"channel": channel, "timestamp": ts, "name": name},
            self._bot_token,
        )


# --- minimal RFC 6455 websocket client (client side only, TLS, masked frames) -------


class WebSocketError(RuntimeError):
    pass


class WebSocketClient:
    """The smallest websocket client that can hold a Socket Mode session.

    Text, ping/pong, and close frames only; client frames are masked as the
    RFC requires; payloads are bounded; fragmented messages are reassembled
    up to the same bound. No extensions, no subprotocols, no third-party
    dependency.
    """

    def __init__(self, url: str, timeout: float = 90.0) -> None:
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != "wss" or not parsed.hostname:
            raise WebSocketError(f"unsupported websocket URL scheme in {parsed.scheme!r}")
        self._host = parsed.hostname
        self._port = parsed.port or 443
        path = parsed.path or "/"
        if parsed.query:
            path += "?" + parsed.query
        self._resource = path
        self._timeout = timeout
        self._sock: ssl.SSLSocket | None = None
        self._buffer = b""
        # Reassembly state survives across recv_message calls so a control
        # frame interleaved into a fragmented data message never discards the
        # fragments already received.
        self._assembled = b""
        self._assembled_opcode: int | None = None

    def connect(self) -> None:
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        expected_accept = base64.b64encode(
            hashlib.sha1((key + WS_GUID).encode("ascii")).digest()
        ).decode("ascii")
        raw = socket.create_connection((self._host, self._port), timeout=self._timeout)
        context = ssl.create_default_context()
        sock = context.wrap_socket(raw, server_hostname=self._host)
        handshake = (
            f"GET {self._resource} HTTP/1.1\r\n"
            f"Host: {self._host}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n"
        )
        sock.sendall(handshake.encode("ascii"))
        response = b""
        while b"\r\n\r\n" not in response:
            chunk = sock.recv(4096)
            if not chunk:
                raise WebSocketError("connection closed during websocket handshake")
            response += chunk
            if len(response) > 64 * 1024:
                raise WebSocketError("oversized websocket handshake response")
        head, _, rest = response.partition(b"\r\n\r\n")
        status_line = head.split(b"\r\n", 1)[0]
        if b" 101 " not in status_line + b" ":
            raise WebSocketError(f"websocket upgrade refused: {status_line[:200]!r}")
        accept = ""
        for line in head.split(b"\r\n")[1:]:
            name, _, value = line.partition(b":")
            if name.strip().lower() == b"sec-websocket-accept":
                accept = value.strip().decode("ascii", "replace")
        if accept != expected_accept:
            raise WebSocketError("websocket accept key mismatch")
        self._sock = sock
        self._buffer = rest

    def _read_exact(self, count: int) -> bytes:
        assert self._sock is not None
        while len(self._buffer) < count:
            chunk = self._sock.recv(65536)
            if not chunk:
                raise WebSocketError("websocket connection closed")
            self._buffer += chunk
        value, self._buffer = self._buffer[:count], self._buffer[count:]
        return value

    def _send_frame(self, opcode: int, payload: bytes) -> None:
        assert self._sock is not None
        mask = os.urandom(4)
        header = bytes([0x80 | opcode])
        length = len(payload)
        if length < 126:
            header += bytes([0x80 | length])
        elif length < 65536:
            header += bytes([0x80 | 126]) + struct.pack(">H", length)
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", length)
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self._sock.sendall(header + mask + masked)

    def send_text(self, text: str) -> None:
        self._send_frame(0x1, text.encode("utf-8"))

    def pong(self, payload: bytes) -> None:
        self._send_frame(0xA, payload)

    def recv_message(self) -> tuple[int, bytes]:
        """Return the next complete (opcode, payload) message."""

        while True:
            first, second = self._read_exact(2)
            fin = bool(first & 0x80)
            opcode = first & 0x0F
            if first & 0x70:
                raise WebSocketError("websocket reserved bits set without an extension")
            length = second & 0x7F
            if second & 0x80:
                raise WebSocketError("server-to-client websocket frames must be unmasked")
            if length == 126:
                (length,) = struct.unpack(">H", self._read_exact(2))
            elif length == 127:
                (length,) = struct.unpack(">Q", self._read_exact(8))
            if length > WS_MAX_PAYLOAD:
                raise WebSocketError(f"websocket frame exceeds the {WS_MAX_PAYLOAD}-byte bound")
            payload = self._read_exact(length)
            if opcode in (0x8, 0x9, 0xA):  # control frames may interleave
                if not fin:
                    raise WebSocketError("fragmented websocket control frame")
                return opcode, payload
            if opcode == 0x0:
                if self._assembled_opcode is None:
                    raise WebSocketError("websocket continuation without a first frame")
            else:
                if self._assembled_opcode is not None:
                    raise WebSocketError("interleaved websocket data messages")
                self._assembled_opcode = opcode
            self._assembled += payload
            if len(self._assembled) > WS_MAX_PAYLOAD:
                raise WebSocketError(f"websocket message exceeds the {WS_MAX_PAYLOAD}-byte bound")
            if fin:
                message_opcode = self._assembled_opcode
                message = self._assembled
                self._assembled = b""
                self._assembled_opcode = None
                return message_opcode, message

    def close(self) -> None:
        if self._sock is not None:
            try:
                self._send_frame(0x8, struct.pack(">H", 1000))
            except OSError:
                pass
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None


# --- the Socket Mode service loop ----------------------------------------------------


class SocketModeService:
    def __init__(self, config: Config) -> None:
        self.config = config
        app_token = required_token(config.app_token_env, "Slack app-level (Socket Mode) token")
        bot_token = required_token(config.bot_token_env, "Slack bot token")
        github_token = required_token(config.github_token_env, "GitHub read credential")
        self.web = SlackWebClient(bot_token=bot_token, app_token=app_token)
        self.config.state_dir.mkdir(parents=True, exist_ok=True)
        self.meter = DailyMeter(config.state_dir / "meter")
        self.deduper = EventDeduper(config.state_dir / "events")
        self.run_review = make_run_review(config, github_token)
        self.queue: queue.Queue[tuple[str, dict[str, Any]]] = queue.Queue(
            maxsize=REVIEW_QUEUE_LIMIT
        )
        self.worker = threading.Thread(target=self._drain, name="crosscheck-slack-worker", daemon=True)

    def _context(self) -> MentionContext:
        return MentionContext(
            config=self.config,
            meter=self.meter,
            deduper=self.deduper,
            post=self.web.post_message,
            react=self.web.add_reaction,
            run_review=self.run_review,
        )

    def _drain(self) -> None:
        while True:
            event_id, event = self.queue.get()
            try:
                action = handle_mention(event_id, event, self._context())
                log(f"event {event_id}: {action}")
            except Exception as exc:
                log(f"event {event_id} failed: {type(exc).__name__}: {exc}")

    def _enqueue(self, event_id: str, event: dict[str, Any]) -> None:
        try:
            self.queue.put_nowait((event_id, event))
        except queue.Full:
            channel = str(event.get("channel") or "")
            thread_ts = str(event.get("thread_ts") or event.get("ts") or "")
            log(f"review queue full; refusing event {event_id}")
            if channel and thread_ts:
                try:
                    self.web.post_message(
                        channel,
                        thread_ts,
                        f"The review queue is full ({REVIEW_QUEUE_LIMIT} pending); "
                        "try again once the current reviews finish.",
                    )
                except SlackExposureError as exc:
                    log(f"could not post queue-full refusal: {exc}")

    def _handle_envelope(self, ws: WebSocketClient, raw: bytes) -> None:
        try:
            envelope = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            log("ignoring undecodable Socket Mode payload")
            return
        if not isinstance(envelope, dict):
            return
        kind = envelope.get("type")
        if kind == "hello":
            log("Socket Mode session established")
            return
        if kind == "disconnect":
            raise WebSocketError(f"server asked to reconnect: {envelope.get('reason')}")
        envelope_id = envelope.get("envelope_id")
        if isinstance(envelope_id, str) and envelope_id:
            ws.send_text(json.dumps({"envelope_id": envelope_id}))
        if kind != "events_api":
            return
        payload = envelope.get("payload")
        if not isinstance(payload, dict):
            return
        event = payload.get("event")
        event_id = payload.get("event_id")
        if (
            isinstance(event, dict)
            and event.get("type") == "app_mention"
            and isinstance(event_id, str)
            and EVENT_ID_RE.fullmatch(event_id)
        ):
            self._enqueue(event_id, event)

    def serve_forever(self) -> NoReturn:
        self.worker.start()
        backoff = 1.0
        while True:
            try:
                url = self.web.connections_open()
                ws = WebSocketClient(url)
                ws.connect()
                backoff = 1.0
                try:
                    while True:
                        opcode, payload = ws.recv_message()
                        if opcode == 0x9:
                            ws.pong(payload)
                        elif opcode == 0x8:
                            raise WebSocketError("server closed the websocket")
                        elif opcode == 0x1:
                            self._handle_envelope(ws, payload)
                finally:
                    ws.close()
            except (WebSocketError, SlackExposureError, OSError) as exc:
                log(f"Socket Mode connection ended: {exc}; reconnecting in {backoff:.0f}s")
                time.sleep(backoff)
                backoff = min(backoff * 2, RECONNECT_BACKOFF_CAP_SECONDS)


# --- selftest and entry ----------------------------------------------------------------


def selftest(config_path: Path) -> int:
    config = load_config(config_path)
    lines = [
        f"config: {config.path}",
        "schema: valid",
        f"app_token_env: {config.app_token_env} "
        f"({'set' if os.environ.get(config.app_token_env) else 'UNSET'})",
        f"bot_token_env: {config.bot_token_env} "
        f"({'set' if os.environ.get(config.bot_token_env) else 'UNSET'})",
        f"github_token_env: {config.github_token_env} "
        f"({'set' if os.environ.get(config.github_token_env) else 'UNSET'})",
        f"channel_allowlist: {len(config.channel_allowlist)} channel(s)",
        f"repo_allowlist: {', '.join(config.repo_allowlist)}",
        "daily_budget_usd: "
        + (f"{config.daily_budget_usd:.2f}" if config.daily_budget_usd is not None else "null (unmetered pass-through, still ledgered)"),
        f"state_dir: {config.state_dir}",
    ]
    print("\n".join(lines))
    return 0


def assert_supported_interpreter() -> None:
    """Mirror the crosscheck gate's interpreter floor.

    This process parses hostile JSON (Slack payloads, config, ledgers) through
    the same bounded-read layer as the gate, whose hostile-integer rejection
    relies on the CPython conversion limit introduced in 3.11.
    """

    minimum = (3, 11)
    if sys.version_info[:2] < minimum:
        running = ".".join(str(part) for part in sys.version_info[:3])
        refuse(
            f"interpreter inspection found Python {running}, but this listener "
            "requires 3.11 or newer because its hostile-JSON defense does not "
            "exist on older interpreters"
        )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog=TOOL, description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    run = subparsers.add_parser("run", help="start the Socket Mode listener")
    run.add_argument("--config", default="", help="config path (default: $FM_HOME/config/crosscheck-slack.json)")
    check = subparsers.add_parser("selftest", help="validate config shape and exit")
    check.add_argument("config", nargs="?", default="", help="config path override")
    return parser


def main() -> int:
    assert_supported_interpreter()
    args = build_parser().parse_args()
    try:
        if args.command == "selftest":
            path = Path(args.config) if args.config else default_config_path()
            return selftest(path)
        path = Path(args.config) if args.config else default_config_path()
        config = load_config(path)
        service = SocketModeService(config)
        log(
            f"starting Socket Mode listener; repos: {', '.join(config.repo_allowlist)}; "
            f"channels: {len(config.channel_allowlist)}; budget: "
            + (
                f"${config.daily_budget_usd:.2f}/submitter/day"
                if config.daily_budget_usd is not None
                else "unmetered (null)"
            )
        )
        service.serve_forever()
    except SlackExposureError as exc:
        refuse(str(exc))
    except KeyboardInterrupt:
        log("interrupted; shutting down")
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
