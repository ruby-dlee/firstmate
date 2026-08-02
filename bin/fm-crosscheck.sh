#!/usr/bin/env bash
# Firstmate crosscheck: independent adversarial PR review with a durable finding
# ledger.
#
# crosscheck is Firstmate's local fifth merge property.
# It does not record a per-head pass verdict.
# Every run verifies each active finding from the ledger against the current PR
# head, hunts for new reproduced findings, and blocks merge until no finding is
# open or claimed-fixed.
#
# A finding counts only when the reviewer supplies executed reproduction
# evidence.
# A fix counts only when the reviewer supplies mutation proof: a named test that
# fails when the fix is reverted or broken in the scratch review checkout.
#
# Usage:
#   fm-crosscheck.sh run <task-id> <pr-url> [--head <sha>]
#   fm-crosscheck.sh verify <task-id> <pr-url>
#
# Test-only runner and reviewer overrides require
# FM_CROSSCHECK_TEST_LAB=firstmate-crosscheck-test-lab-v1.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
TEST_LAB_TOKEN=firstmate-crosscheck-test-lab-v1

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
# shellcheck source=bin/fm-account-routing-lib.sh
. "$SCRIPT_DIR/fm-account-routing-lib.sh"

usage() {
  sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//' >&2
}

test_lab_enabled() {
  [ "${FM_CROSSCHECK_TEST_LAB:-}" = "$TEST_LAB_TOKEN" ]
}

die() {
  echo "critical: crosscheck $*" >&2
  exit 1
}

safe_sha() {
  case "$1" in
    [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) return 0 ;;
    *) return 1 ;;
  esac
}

parse_pr_url() {
  local url=$1
  if [[ "$url" =~ ^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]+)/pull/([0-9]+)/?$ ]]; then
    PR_OWNER=${BASH_REMATCH[1]}
    PR_REPO=${BASH_REMATCH[2]}
    PR_NUMBER=${BASH_REMATCH[3]}
    [[ "$PR_OWNER" != *- ]] || return 1
    return 0
  fi
  return 1
}

meta_tail_value() {
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

require_meta() {
  META="$STATE/$ID.meta"
  [ -f "$META" ] || die "has no task metadata for $ID at $META"
  WT=$(fm_account_meta_value "$META" worktree)
  PROJ=$(fm_account_meta_value "$META" project)
  AUTHOR_HARNESS=$(fm_account_meta_value "$META" harness)
  AUTHOR_MODEL=$(fm_account_meta_value "$META" model)
  AUTHOR_ACCOUNT_HOME=$(fm_account_meta_value "$META" account_home)
  [ -n "$WT" ] || die "cannot run; meta for $ID is missing worktree="
  [ -n "$PROJ" ] || die "cannot run; meta for $ID is missing project="
  [ -d "$WT" ] || die "cannot run; worktree for $ID is missing: $WT"
  [ -d "$PROJ" ] || die "cannot run; project for $ID is missing: $PROJ"
}

current_pr_head() {
  if command -v gh-axi >/dev/null 2>&1; then
    gh-axi pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" --json headRefOid -q .headRefOid 2>/dev/null || true
  elif test_lab_enabled && command -v gh >/dev/null 2>&1; then
    gh pr view "$PR_URL" --json headRefOid -q .headRefOid 2>/dev/null || true
  fi
}

current_pr_base() {
  if command -v gh-axi >/dev/null 2>&1; then
    gh-axi pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" --json baseRefName,baseRefOid \
      -q '[.baseRefName, .baseRefOid] | @tsv' 2>/dev/null || true
  elif test_lab_enabled && command -v gh >/dev/null 2>&1; then
    gh pr view "$PR_URL" --json baseRefName,baseRefOid \
      -q '[.baseRefName, .baseRefOid] | @tsv' 2>/dev/null || true
  fi
}

pr_claims() {
  if command -v gh-axi >/dev/null 2>&1; then
    gh-axi pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" --json title,body \
      -q '.title + "\n\n" + (.body // "")' 2>/dev/null || true
  elif test_lab_enabled && command -v gh >/dev/null 2>&1; then
    gh pr view "$PR_URL" --json title,body -q '.title + "\n\n" + (.body // "")' 2>/dev/null || true
  fi
}

choose_reviewer_harnesses() {
  case "$AUTHOR_HARNESS" in
    codex) printf '%s\n' claude codex ;;
    claude) printf '%s\n' codex claude ;;
    *) printf '%s\n' codex claude ;;
  esac
}

model_for_harness() {
  case "$1" in
    codex) printf '%s\n' "${FM_CROSSCHECK_CODEX_MODEL:-gpt-5}" ;;
    claude) "$SCRIPT_DIR/fm-harness.sh" claude-crew-model ;;
    *) return 1 ;;
  esac
}

candidate_is_usable() {
  local candidate=$1 selected model
  command -v "$candidate" >/dev/null 2>&1 || return 1
  selected=$("$SCRIPT_DIR/fm-account-directory.sh" select "$candidate" 2>"$RUN_DIR/$candidate-account.err") || {
    cat "$RUN_DIR/$candidate-account.err" >&2
    return 1
  }
  model=$(model_for_harness "$candidate") || return 1
  [ -n "$selected" ] || return 1
  [ "$selected" != "$AUTHOR_ACCOUNT_HOME" ] || return 1
  printf '%s\t%s\t%s\n' "$candidate" "$selected" "$model"
}

select_reviewer() {
  local candidate usable chosen model_diff
  [ -n "$AUTHOR_MODEL" ] \
    || die "refuses to run; cannot prove model separation because author model is absent"
  if test_lab_enabled && [ -n "${FM_CROSSCHECK_REVIEWER_HARNESS:-}" ]; then
    REVIEWER_HARNESS=$FM_CROSSCHECK_REVIEWER_HARNESS
    REVIEWER_ACCOUNT_HOME=${FM_CROSSCHECK_REVIEWER_ACCOUNT_HOME:-}
    REVIEWER_MODEL=${FM_CROSSCHECK_REVIEWER_MODEL:-}
    [ -n "$REVIEWER_ACCOUNT_HOME" ] || die "test-lab reviewer override requires FM_CROSSCHECK_REVIEWER_ACCOUNT_HOME"
    [ -n "$REVIEWER_MODEL" ] || REVIEWER_MODEL=$(model_for_harness "$REVIEWER_HARNESS")
  else
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      usable=$(candidate_is_usable "$candidate" || true)
      [ -n "$usable" ] || continue
      model_diff=${usable##*$'\t'}
      if [ "$model_diff" != "$AUTHOR_MODEL" ]; then
        chosen=$usable
        break
      fi
    done <<EOF
$(choose_reviewer_harnesses)
EOF
    if [ -n "${chosen:-}" ]; then
      IFS=$'\t' read -r REVIEWER_HARNESS REVIEWER_ACCOUNT_HOME REVIEWER_MODEL <<EOF
$chosen
EOF
    fi
  fi
  [ -n "${REVIEWER_HARNESS:-}" ] || die "reviewer unavailable; no independent account could be selected"
  [ -n "${REVIEWER_ACCOUNT_HOME:-}" ] || die "reviewer unavailable; account selection returned no home"
  [ -n "${REVIEWER_MODEL:-}" ] || die "reviewer unavailable; model could not be resolved"
  [ "$AUTHOR_MODEL" != "$REVIEWER_MODEL" ] \
    || die "refuses to run; author and reviewer models are identical"
  [ -n "$AUTHOR_ACCOUNT_HOME" ] \
    || die "refuses to run; cannot prove reviewer is not author because author account_home is absent"
  [ "$AUTHOR_ACCOUNT_HOME" != "$REVIEWER_ACCOUNT_HOME" ] \
    || die "refuses to run; author and reviewer account_home are identical"
  MODEL_SEPARATION=different_model
  ISOLATION_PROOF="different_account_home author=$AUTHOR_ACCOUNT_HOME reviewer=$REVIEWER_ACCOUNT_HOME author_harness=${AUTHOR_HARNESS:-unknown} author_model=${AUTHOR_MODEL:-unknown} reviewer_harness=$REVIEWER_HARNESS reviewer_model=$REVIEWER_MODEL model_separation=$MODEL_SEPARATION"
}

prepare_review_checkout() {
  local base_metadata origin resolved_base
  base_metadata=$(current_pr_base)
  IFS=$'\t' read -r BASE_NAME BASE_HEAD <<EOF
$base_metadata
EOF
  [ -n "$BASE_NAME" ] || die "could not resolve PR base ref for $PR_URL"
  safe_sha "$BASE_HEAD" || die "could not resolve exact PR base OID for $PR_URL"
  git check-ref-format "refs/heads/$BASE_NAME" >/dev/null 2>&1 \
    || die "PR base ref is invalid: $BASE_NAME"
  origin=$(git -C "$WT" remote get-url origin 2>/dev/null) \
    || die "requires an origin remote in $WT"
  REVIEW_WT="$RUN_DIR/review-worktree"
  git clone --quiet --no-checkout "$origin" "$REVIEW_WT" \
    || die "could not create scratch review checkout from origin"
  BASE_REF="refs/remotes/origin/$BASE_NAME"
  git -C "$REVIEW_WT" fetch origin "+refs/heads/$BASE_NAME:$BASE_REF" --quiet \
    || die "could not fetch PR base $BASE_NAME"
  resolved_base=$(git -C "$REVIEW_WT" rev-parse --verify --quiet "$BASE_REF^{commit}") \
    || die "base $BASE_REF does not exist in scratch checkout"
  [ "$resolved_base" = "$BASE_HEAD" ] \
    || die "PR base moved while preparing crosscheck: expected $BASE_HEAD, fetched $resolved_base"
  if ! git -C "$REVIEW_WT" cat-file -e "$HEAD_SHA^{commit}" 2>/dev/null; then
    git -C "$REVIEW_WT" fetch --quiet origin "refs/pull/$PR_NUMBER/head" >/dev/null 2>&1 \
      || die "cannot fetch PR head for $PR_URL"
  fi
  git -C "$REVIEW_WT" cat-file -e "$HEAD_SHA^{commit}" 2>/dev/null \
    || die "PR head $HEAD_SHA is not present in scratch checkout after fetch"
  git -C "$REVIEW_WT" checkout --quiet --detach "$HEAD_SHA" \
    || die "could not check out PR head $HEAD_SHA in scratch checkout"
  MERGE_BASE=$(git -C "$REVIEW_WT" merge-base "$BASE_REF" "$HEAD_SHA") \
    || die "cannot compute merge base for $BASE_REF and $HEAD_SHA"
}

ledger_json_or_empty() {
  if [ -f "$LEDGER" ]; then
    cat "$LEDGER"
  else
    printf '{"version":1,"findings":[],"suspicions":[],"runs":[]}\n'
  fi
}

active_findings_json() {
  ledger_json_or_empty | node -e '
const fs = require("fs");
const ledger = JSON.parse(fs.readFileSync(0, "utf8"));
const active = (ledger.findings || []).filter((f) => ["open", "claimed-fixed"].includes(f.lifecycle));
process.stdout.write(JSON.stringify(active, null, 2));
'
}

make_prompt() {
  local claims stat name_status diff active
  claims=$(pr_claims)
  stat=$(git -C "$REVIEW_WT" diff --stat "$MERGE_BASE...$HEAD_SHA" --)
  name_status=$(git -C "$REVIEW_WT" diff --name-status "$MERGE_BASE...$HEAD_SHA" --)
  diff=$(git -C "$REVIEW_WT" diff --find-renames --find-copies --unified=80 "$MERGE_BASE...$HEAD_SHA" --)
  active=$(active_findings_json)
  cat > "$PROMPT_FILE" <<EOF
You are Firstmate crosscheck, an independent adversarial PR reviewer.
Your job is to refute the PR's own claims, not confirm them.
You are not given the author's intent.

Hard constraints:
- Review exactly head SHA $HEAD_SHA against merge base $MERGE_BASE.
- You are in a scratch checkout: $REVIEW_WT.
- You may run commands and make temporary mutations in this scratch checkout only.
- Do not commit, push, post comments, or mutate any path outside the scratch checkout.
- A new finding must be reproduced by executing a command and recording its output.
- Unreproduced observations are suspicions, not findings.
- A prior finding is fixed only with mutation proof: reverting or breaking the fix makes a named test fail.
- Silence never closes a prior finding.
- Return only strict JSON matching the output contract.

Output contract:
{
  "review": {
    "head_sha": "$HEAD_SHA",
    "summary": "short adversarial summary",
    "citations": [{"path": "file", "line": 1}]
  },
  "finding_updates": [
    {
      "id": "existing finding id",
      "status": "still_reproduced | claimed_fixed | verified_fixed",
      "evidence": {
        "command": "command executed",
        "output": "relevant output",
        "citations": [{"path": "file", "line": 1}]
      },
      "mutation_proof": {
        "test_name": "stable name of the regression test",
        "command": "test command that fails after reverting or breaking the fix",
        "exit_code": 1,
        "output": "failing output",
        "mutation": "what was reverted or broken in the scratch checkout"
      }
    }
  ],
  "new_findings": [
    {
      "title": "concise defect title",
      "category": "business/domain logic defects | concurrency, publication, and idempotency defects | environment/config/deploy mismatches | observability and false-assurance defects | test-harness validity defects | tooling/CI guard holes",
      "severity": "blocking",
      "description": "concrete failure mode and why it blocks merge",
      "reproduction": {"command": "command executed", "output": "relevant output"},
      "citations": [{"path": "file", "line": 1}]
    }
  ],
  "suspicions": [
    {
      "title": "unreproduced concern",
      "description": "why it is suspicious but not a finding",
      "citations": [{"path": "file", "line": 1}]
    }
  ]
}

Prior active findings to verify:
$active

Isolation proof supplied by Firstmate:
$ISOLATION_PROOF

PR URL:
$PR_URL

PR claims:
$claims

Useful commands:
- git diff --find-renames --find-copies $MERGE_BASE...$HEAD_SHA --
- git show $HEAD_SHA:path/to/file | nl -ba | sed -n 'START,ENDp'
- git grep -n PATTERN $HEAD_SHA -- path/

Diff stat:
$stat

Changed files:
$name_status

Full diff:
$diff
EOF
}

run_reviewer() {
  local timeout
  timeout=${FM_CROSSCHECK_TIMEOUT_SECS:-1800}
  case "$timeout" in ''|*[!0-9]*|0) die "timeout must be a positive integer" ;; esac
  if test_lab_enabled && [ -n "${FM_CROSSCHECK_RUNNER:-}" ]; then
    "$FM_CROSSCHECK_RUNNER" "$PROMPT_FILE" "$AGENT_OUT" "$REVIEWER_HARNESS" "$REVIEWER_ACCOUNT_HOME" "$REVIEWER_MODEL"
    return
  fi
  case "$REVIEWER_HARNESS" in
    codex)
      fm_account_run_bounded "$timeout" env \
        CODEX_HOME="$REVIEWER_ACCOUNT_HOME" \
        XDG_CACHE_HOME="$REVIEWER_ACCOUNT_HOME/.agent-fleet-quota-cache" \
        codex exec -C "$REVIEW_WT" --sandbox workspace-write --ask-for-approval never --ephemeral \
          --model "$REVIEWER_MODEL" --color never --output-last-message "$AGENT_OUT" \
          < "$PROMPT_FILE" > "$RUN_DIR/codex.stdout" 2> "$RUN_DIR/codex.stderr"
      ;;
    claude)
      fm_account_run_bounded "$timeout" env \
        CLAUDE_CONFIG_DIR="$REVIEWER_ACCOUNT_HOME" \
        CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
        claude -p --model "$REVIEWER_MODEL" --permission-mode dontAsk \
          --output-format text --no-session-persistence \
          < "$PROMPT_FILE" > "$AGENT_OUT" 2> "$RUN_DIR/claude.stderr"
      ;;
    *)
      die "unsupported reviewer harness: $REVIEWER_HARNESS"
      ;;
  esac
}

validate_and_update_ledger() {
  node - "$LEDGER" "$AGENT_OUT" "$LEDGER_TMP" <<'NODE'
const fs = require("fs");
const crypto = require("crypto");
const [ledgerPath, resultPath, outputPath] = process.argv.slice(2);

function fail(message) {
  console.error(`critical: crosscheck ${message}`);
  process.exit(1);
}

function readJson(path, fallback) {
  if (!fs.existsSync(path)) return fallback;
  try {
    return JSON.parse(fs.readFileSync(path, "utf8"));
  } catch (error) {
    fail(`ledger is malformed JSON: ${error.message}`);
  }
}

function parseReviewerJson(path) {
  const raw = fs.readFileSync(path, "utf8").trim();
  if (!raw) fail("reviewer returned no output");
  try {
    return JSON.parse(raw);
  } catch (error) {
    fail(`reviewer returned malformed JSON: ${error.message}`);
  }
}

function nonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0;
}

function citations(value) {
  return Array.isArray(value) && value.length > 0 && value.every((item) =>
    item && nonEmptyString(item.path) && Number.isInteger(item.line) && item.line > 0
  );
}

function evidence(value) {
  return value && nonEmptyString(value.command) && nonEmptyString(value.output) && citations(value.citations);
}

function mutationProof(value) {
  return value && nonEmptyString(value.test_name) && nonEmptyString(value.command) &&
    Number.isInteger(value.exit_code) && value.exit_code !== 0 &&
    nonEmptyString(value.output) && nonEmptyString(value.mutation);
}

function blocker(lifecycle) {
  return lifecycle === "open" || lifecycle === "claimed-fixed";
}

const now = process.env.FM_CROSSCHECK_NOW || new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
const task = process.env.ID;
const pr = process.env.PR_URL;
const head = process.env.HEAD_SHA;
const base = process.env.BASE_HEAD;
const mergeBase = process.env.MERGE_BASE;
const reviewer = {
  harness: process.env.REVIEWER_HARNESS,
  model: process.env.REVIEWER_MODEL,
  account_home: process.env.REVIEWER_ACCOUNT_HOME,
};
const isolation = process.env.ISOLATION_PROOF;
const ledger = readJson(ledgerPath, { version: 1, findings: [], suspicions: [], runs: [] });
ledger.version = 1;
ledger.task = task;
ledger.pr = pr;
ledger.findings = Array.isArray(ledger.findings) ? ledger.findings : [];
ledger.suspicions = Array.isArray(ledger.suspicions) ? ledger.suspicions : [];
ledger.runs = Array.isArray(ledger.runs) ? ledger.runs : [];

const result = parseReviewerJson(resultPath);
if (!result.review || result.review.head_sha !== head || !nonEmptyString(result.review.summary) || !citations(result.review.citations)) {
  fail("reviewer result is citation-less or does not prove it reviewed the requested head");
}
const updates = Array.isArray(result.finding_updates) ? result.finding_updates : [];
const newFindings = Array.isArray(result.new_findings) ? result.new_findings : [];
const suspicions = Array.isArray(result.suspicions) ? result.suspicions : [];
const active = ledger.findings.filter((finding) => blocker(finding.lifecycle));
const updateById = new Map();
for (const update of updates) {
  if (!update || !nonEmptyString(update.id)) fail("finding update is missing id");
  if (updateById.has(update.id)) fail(`finding ${update.id} was updated more than once`);
  updateById.set(update.id, update);
}
for (const finding of active) {
  if (!updateById.has(finding.id)) {
    fail(`reviewer did not verify active finding ${finding.id}; silence never closes a finding`);
  }
}
for (const update of updates) {
  const finding = ledger.findings.find((item) => item.id === update.id);
  if (!finding) fail(`reviewer updated unknown finding ${update.id}`);
  if (!["still_reproduced", "claimed_fixed", "verified_fixed"].includes(update.status)) {
    fail(`finding ${update.id} has invalid status ${update.status}`);
  }
  if (update.status === "still_reproduced" && !evidence(update.evidence)) {
    fail(`finding ${update.id} is still_reproduced without reproduction evidence`);
  }
  if (update.status === "claimed_fixed" && !evidence(update.evidence)) {
    fail(`finding ${update.id} is claimed_fixed without proof of attempted reproduction`);
  }
  if (update.status === "verified_fixed" && (!evidence(update.evidence) || !mutationProof(update.mutation_proof))) {
    fail(`finding ${update.id} is verified_fixed without reproduction and mutation proof`);
  }
  const event = {
    at: now,
    head_sha: head,
    status: update.status,
    evidence: update.evidence,
  };
  if (update.mutation_proof) event.mutation_proof = update.mutation_proof;
  finding.history = Array.isArray(finding.history) ? finding.history : [];
  finding.history.push(event);
  finding.last_checked_head = head;
  if (update.status === "verified_fixed") {
    finding.lifecycle = "verified-fixed";
    finding.verified_fixed_at = now;
    finding.mutation_proof = update.mutation_proof;
  } else if (update.status === "claimed_fixed") {
    finding.lifecycle = "claimed-fixed";
  } else {
    finding.lifecycle = "open";
    finding.last_reproduced_head = head;
  }
}
for (const finding of newFindings) {
  if (!finding || !nonEmptyString(finding.title) || !nonEmptyString(finding.category) || finding.severity !== "blocking") {
    fail("new finding is missing title/category or is not severity=blocking");
  }
  if (!nonEmptyString(finding.description) || !finding.reproduction || !nonEmptyString(finding.reproduction.command) || !nonEmptyString(finding.reproduction.output)) {
    fail(`new finding ${finding.title} lacks executed reproduction evidence`);
  }
  if (!citations(finding.citations)) {
    fail(`new finding ${finding.title} lacks file:line citations`);
  }
  const seed = JSON.stringify([pr, finding.title, finding.category, finding.citations, finding.reproduction.command]);
  const id = `cc-${crypto.createHash("sha256").update(seed).digest("hex").slice(0, 12)}`;
  let existing = ledger.findings.find((item) => item.id === id);
  if (!existing) {
    existing = {
      id,
      lifecycle: "open",
      title: finding.title,
      category: finding.category,
      severity: finding.severity,
      description: finding.description,
      first_seen_at: now,
      first_seen_head: head,
      citations: finding.citations,
      reproduction: finding.reproduction,
      history: [],
    };
    ledger.findings.push(existing);
  }
  existing.lifecycle = "open";
  existing.last_reproduced_head = head;
  existing.last_checked_head = head;
  existing.history.push({
    at: now,
    head_sha: head,
    status: "new_reproduced",
    evidence: {
      command: finding.reproduction.command,
      output: finding.reproduction.output,
      citations: finding.citations,
    },
  });
}
for (const suspicion of suspicions) {
  if (!suspicion || !nonEmptyString(suspicion.title) || !nonEmptyString(suspicion.description) || !citations(suspicion.citations)) {
    fail("suspicion lacks title, description, or citations");
  }
  ledger.suspicions.push({
    id: `susp-${crypto.createHash("sha256").update(JSON.stringify([now, suspicion.title, suspicion.citations])).digest("hex").slice(0, 12)}`,
    at: now,
    head_sha: head,
    title: suspicion.title,
    description: suspicion.description,
    citations: suspicion.citations,
  });
}
const blockers = ledger.findings.filter((finding) => blocker(finding.lifecycle));
const run = {
  at: now,
  head_sha: head,
  base_head_sha: base,
  merge_base_sha: mergeBase,
  reviewer,
  isolation_proof: isolation,
  prior_active_verified: active.length,
  new_findings: newFindings.length,
  suspicions: suspicions.length,
  state: blockers.length === 0 ? "clear" : "blocked",
  active_blockers: blockers.map((finding) => finding.id),
  review: result.review,
};
ledger.runs.push(run);
fs.writeFileSync(outputPath, `${JSON.stringify(ledger, null, 2)}\n`);
console.log(JSON.stringify(run));
NODE
}

write_report() {
  local generated state active_count suspicion_count
  generated=${FM_CROSSCHECK_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  state=$(node -e 'const fs=require("fs"); const l=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); const r=l.runs[l.runs.length-1]; process.stdout.write(r.state);' "$LEDGER")
  active_count=$(node -e 'const fs=require("fs"); const l=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); process.stdout.write(String((l.findings||[]).filter((f)=>["open","claimed-fixed"].includes(f.lifecycle)).length));' "$LEDGER")
  suspicion_count=$(node -e 'const fs=require("fs"); const l=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); process.stdout.write(String((l.suspicions||[]).length));' "$LEDGER")
  REPORT="$TASK_DIR/crosscheck.md"
  TMP_REPORT=$(mktemp "$TASK_DIR/.crosscheck.XXXXXX") || die "cannot create temporary report"
  {
    printf '# Crosscheck\n\n'
    printf 'task: %s\n' "$ID"
    printf 'pr: %s\n' "$PR_URL"
    printf 'generated_at: %s\n' "$generated"
    printf 'head_sha: %s\n' "$HEAD_SHA"
    printf 'base_head_sha: %s\n' "$BASE_HEAD"
    printf 'merge_base_sha: %s\n' "$MERGE_BASE"
    printf 'state: %s\n' "$state"
    printf 'active_blockers: %s\n' "$active_count"
    printf 'suspicions: %s\n' "$suspicion_count"
    printf 'ledger: %s\n' "$LEDGER"
    printf 'reviewer_harness: %s\n' "$REVIEWER_HARNESS"
    printf 'reviewer_model: %s\n' "$REVIEWER_MODEL"
    printf 'reviewer_account_home: %s\n' "$REVIEWER_ACCOUNT_HOME"
    printf 'isolation_proof: %s\n\n' "$ISOLATION_PROOF"
    printf '## Ledger Summary\n\n'
    # shellcheck disable=SC2016  # The JavaScript template literal is evaluated by Node, not Bash.
    node -e '
const fs=require("fs");
const l=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
for (const f of l.findings || []) {
  console.log(`- ${f.id} [${f.lifecycle}] ${f.title}`);
}
if (!(l.findings || []).length) console.log("- no findings recorded");
' "$LEDGER"
    printf '\n## Latest Reviewer JSON\n\n```json\n'
    cat "$AGENT_OUT"
    printf '\n```\n'
  } > "$TMP_REPORT"
  fm_account_safe_file_destination "$REPORT" || { rm -f "$TMP_REPORT"; die "unsafe report path $REPORT"; }
  mv "$TMP_REPORT" "$REPORT"
}

record_meta() {
  local lock state
  state=$(node -e 'const fs=require("fs"); const l=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); const r=l.runs[l.runs.length-1]; process.stdout.write(r.state);' "$LEDGER")
  lock=$(fm_account_meta_lock_acquire "$STATE" "$ID") || exit 1
  trap 'fm_account_meta_lock_release "$lock" >/dev/null 2>&1 || true' EXIT
  [ -f "$META" ] || die "task metadata disappeared for $ID"
  {
    printf 'crosscheck_head=%s\n' "$HEAD_SHA"
    printf 'crosscheck_state=%s\n' "$state"
    printf 'crosscheck_ledger=%s\n' "$LEDGER"
    printf 'crosscheck_report=%s\n' "$REPORT"
    printf 'crosscheck_reviewer_harness=%s\n' "$REVIEWER_HARNESS"
    printf 'crosscheck_reviewer_account_home=%s\n' "$REVIEWER_ACCOUNT_HOME"
  } >> "$META"
  fm_account_meta_lock_release "$lock"
  trap - EXIT
}

run_mode() {
  local supplied_head="" run_json state ledger_lock attempts
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --head)
        shift
        supplied_head=${1:-}
        [ -n "$supplied_head" ] || die "--head requires a SHA"
        ;;
      *) usage; exit 2 ;;
    esac
    shift
  done
  if [ -n "$supplied_head" ]; then
    safe_sha "$supplied_head" || die "invalid supplied head SHA: $supplied_head"
    HEAD_SHA=$supplied_head
  else
    HEAD_SHA=$(current_pr_head)
    safe_sha "$HEAD_SHA" || die "could not resolve current PR head for $PR_URL"
  fi
  TASK_DIR=$(fm_account_task_dir "$DATA" "$ID" create) || die "cannot create data directory for $ID"
  LEDGER="$TASK_DIR/crosscheck-ledger.json"
  RUN_DIR=$(mktemp -d "$STATE/.$ID.crosscheck.XXXXXX") || die "cannot create temp run dir"
  PROMPT_FILE="$RUN_DIR/prompt.md"
  AGENT_OUT="$RUN_DIR/reviewer-output.json"
  LEDGER_TMP="$RUN_DIR/crosscheck-ledger.json"
  ledger_lock="$TASK_DIR/.crosscheck-ledger.lock"
  attempts=0
  while ! mkdir "$ledger_lock" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 600 ] || die "timed out waiting for ledger lock for $ID"
    sleep 0.1
  done
  trap 'rmdir "$ledger_lock" >/dev/null 2>&1 || true' EXIT
  select_reviewer
  prepare_review_checkout
  make_prompt
  if ! run_reviewer; then
    die "reviewer unavailable or failed; no verdict and no merge pass"
  fi
  run_json=$(ID=$ID PR_URL=$PR_URL HEAD_SHA=$HEAD_SHA BASE_HEAD=$BASE_HEAD MERGE_BASE=$MERGE_BASE \
    REVIEWER_HARNESS=$REVIEWER_HARNESS REVIEWER_MODEL=$REVIEWER_MODEL \
    REVIEWER_ACCOUNT_HOME=$REVIEWER_ACCOUNT_HOME ISOLATION_PROOF=$ISOLATION_PROOF \
    validate_and_update_ledger)
  fm_account_safe_file_destination "$LEDGER" || die "unsafe ledger path $LEDGER"
  mv "$LEDGER_TMP" "$LEDGER"
  rmdir "$ledger_lock"
  trap - EXIT
  write_report
  record_meta
  state=$(printf '%s' "$run_json" | node -e 'const fs=require("fs"); const r=JSON.parse(fs.readFileSync(0,"utf8")); process.stdout.write(r.state);')
  case "$state" in
    clear)
      echo "crosscheck clear: $PR_URL head=$HEAD_SHA ledger=$LEDGER report=$REPORT"
      ;;
    blocked)
      echo "crosscheck blocked: $PR_URL head=$HEAD_SHA ledger=$LEDGER report=$REPORT" >&2
      exit 1
      ;;
    *) die "internal invalid run state $state" ;;
  esac
}

verify_mode() {
  local current state current_clear
  TASK_DIR=$(fm_account_task_dir "$DATA" "$ID") || die "has no data directory for $ID"
  LEDGER="$TASK_DIR/crosscheck-ledger.json"
  [ -f "$LEDGER" ] || die "has no ledger for $ID"
  current=$(current_pr_head)
  safe_sha "$current" || die "could not resolve current PR head for $PR_URL"
  current_clear=$(HEAD_SHA=$current node -e '
const fs=require("fs");
const l=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
const blockers=(l.findings||[]).filter((f)=>["open","claimed-fixed"].includes(f.lifecycle));
const run=(l.runs||[]).slice().reverse().find((r)=>r.head_sha===process.env.HEAD_SHA && r.state==="clear");
if (blockers.length || !run) process.exit(1);
' "$LEDGER" && printf yes || true)
  [ "$current_clear" = yes ] || die "does not prove current PR head $current is clear"
  state=$(meta_tail_value crosscheck_state)
  [ "$state" = clear ] || die "latest meta crosscheck_state is not clear"
  echo "$current"
  echo "crosscheck verified: $PR_URL head=$current ledger=$LEDGER" >&2
}

MODE=${1:-}
ID=${2:-}
PR_URL=${3:-}
[ -n "$MODE" ] && [ -n "$ID" ] && [ -n "$PR_URL" ] || { usage; exit 2; }
shift 3
parse_pr_url "$PR_URL" || die "PR URL must match https://github.com/<owner>/<repo>/pull/<number>"
require_meta
case "$MODE" in
  run) run_mode "$@" ;;
  verify)
    [ "$#" -eq 0 ] || { usage; exit 2; }
    verify_mode
    ;;
  *) usage; exit 2 ;;
esac
