#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Product regression for the failed B2C cloud shape: current non-default base,
# task data, PR/preserved refs, credentialless guest delivery, and host publish.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AUTHOR="$ROOT/bin/fm-cloud-author.py"
SUPERVISOR="$ROOT/bin/fm-worker-supervisor.py"
TMP_ROOT=$(fm_test_tmproot fm-azure-author-product)
HOME_DIR="$TMP_ROOT/home"
REMOTE="$TMP_ROOT/remote.git"
SOURCE="$TMP_ROOT/source"
WORKTREE="$TMP_ROOT/worktree"
PAYLOAD="$HOME_DIR/state/b2c-current.cloud-payload"
FAKEBIN="$TMP_ROOT/fakebin"
ID=b2c-current
mkdir -p "$HOME_DIR/data/$ID" "$HOME_DIR/data/b2c-app-freshness-v4" \
  "$HOME_DIR/state" "$HOME_DIR/config" "$FAKEBIN"
printf 'Crosscheck must stay untouched.\n' > "$HOME_DIR/config/crosscheck-azure.json"
printf 'Canonical pool must not travel.\n' > "$HOME_DIR/config/canonical-account-pool"
printf 'Plan section 6.\n' > "$HOME_DIR/data/product-resumption-plan-2026-08-31.md"
printf 'Freshness report v4.\n' > "$HOME_DIR/data/b2c-app-freshness-v4/report.md"
printf 'Task-specific producer contract.\n' > "$HOME_DIR/data/$ID/producer-contract.txt"

fm_git_init_commit "$SOURCE"
fm_git_identity "$SOURCE"
git -C "$SOURCE" branch -M main
git init --quiet --bare "$REMOTE"
git -C "$SOURCE" remote add origin "$REMOTE"
git -C "$SOURCE" push --quiet origin main
git --git-dir="$REMOTE" symbolic-ref HEAD refs/heads/main
printf 'develop base\n' > "$SOURCE/base.txt"
git -C "$SOURCE" add base.txt
git -C "$SOURCE" commit --quiet -m 'develop base'
git -C "$SOURCE" branch env/develop
git -C "$SOURCE" push --quiet origin env/develop
BASE=$(git -C "$SOURCE" rev-parse env/develop)
git -C "$SOURCE" checkout --quiet -b fm/server-idempotency env/develop
printf 'queued idempotency\n' > "$SOURCE/idempotency.txt"
git -C "$SOURCE" add idempotency.txt
git -C "$SOURCE" commit --quiet -m 'queued server idempotency'
git -C "$SOURCE" push --quiet origin fm/server-idempotency
PRESERVED=$(git -C "$SOURCE" rev-parse HEAD)
git -C "$SOURCE" checkout --quiet -b pr/open-candidate env/develop
printf 'open PR candidate\n' > "$SOURCE/pr.txt"
git -C "$SOURCE" add pr.txt
git -C "$SOURCE" commit --quiet -m 'open pull request candidate'
git -C "$SOURCE" push --quiet origin pr/open-candidate
PR_HEAD=$(git -C "$SOURCE" rev-parse HEAD)
git --git-dir="$REMOTE" update-ref refs/pull/17/head "$PR_HEAD"
git clone --quiet "$REMOTE" "$WORKTREE"
fm_git_identity "$WORKTREE"

cat > "$HOME_DIR/data/$ID/brief.md" <<EOF
You are in a disposable worktree of Ruby-Labs/ruby-b2c-app on a clean detached default base.
Its integration authority is \`env/develop\`, not GitHub's default \`main\`; verify the live refs before branching and target the PR appropriately.
Read \`$HOME_DIR/data/product-resumption-plan-2026-08-31.md\` section 6, \`$HOME_DIR/data/b2c-app-freshness-v4/report.md\`, and \`$HOME_DIR/data/$ID/producer-contract.txt\` before choosing the implementation.
First reconcile current \`env/develop\`, open PRs, and preserved relevant branches.
Run \`git checkout -b fm/$ID\` as your first project change.
1. Never push to the default branch (push only your \`fm/$ID\` branch). Never merge a PR.
3. Use gh-axi for GitHub and chrome-devtools-axi for browser operations.
Use an isolated branch and PR. Include the full PR URL, exact head, tests, and remaining gate.
Emit terminal \`done:\` only when the PR is review-ready and all owned checks are green.
Write \`$HOME_DIR/data/$ID/completion.md\` and append status to \`$HOME_DIR/state/$ID.status\`.
Push the branch, open a PR with \`gh-axi\`, append \`done: PR {url}\`, and remain available for corrections.
EOF
cat > "$HOME_DIR/data/$ID/cloud-context.json" <<'EOF'
{"schema":"fm.azure-author-context-config/v1","base_branch":"env/develop","preserved_refs":["fm/server-idempotency"],"include_open_prs":true}
EOF
cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TEST_GH_LOG:?}"
case "${1:-} ${2:-}" in
  'pr list')
    printf '[1]{number,title,url,headRefName,headRefOid,baseRefName}:\n'
    printf '  17,"Queued idempotency","https://github.com/ruby-labs/b2c/pull/17","pr/open-candidate","%s","env/develop"\n' "${FM_TEST_PR_HEAD:?}"
    ;;
  'pr view')
    [ -f "${FM_TEST_PR_VIEW:?}" ] || exit 1
    cat "$FM_TEST_PR_VIEW"
    ;;
  'pr create')
    head=$(git --git-dir="${FM_TEST_REMOTE:?}" rev-parse refs/heads/fm/b2c-current)
    cat > "${FM_TEST_PR_VIEW:?}" <<EOF
url: https://github.com/ruby-labs/b2c/pull/99
state: OPEN
baseRefName: env/develop
headRefName: fm/b2c-current
headRefOid: $head
EOF
    # Model a client failure after GitHub accepted the create. The host helper
    # must resolve by branch and continue without creating a duplicate.
    exit 75
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$FAKEBIN/gh-axi"

export FM_GH_AXI_BIN="$FAKEBIN/gh-axi"
export FM_TEST_GH_LOG="$TMP_ROOT/gh.log"
export FM_TEST_PR_HEAD="$PR_HEAD"
export FM_TEST_PR_VIEW="$TMP_ROOT/pr-view.toon"
export FM_TEST_REMOTE="$REMOTE"
export FM_CLOUD_AUTHOR_TEST_HOOKS=azure-author-tests-v1
export FM_CLOUD_AUTHOR_TEST_REPOSITORY=ruby-labs/b2c
mkdir -p "$PAYLOAD"

mv "$HOME_DIR/data/$ID/cloud-context.json" "$HOME_DIR/data/$ID/cloud-context.saved"
if prepare_out=$(python3 "$AUTHOR" prepare --home "$HOME_DIR" --task "$ID" \
  --worktree "$WORKTREE" --payload "$PAYLOAD" --brief "$HOME_DIR/data/$ID/brief.md" 2>&1); then
  fail "B2C payload silently omitted its unnamed required preserved branches: $prepare_out"
fi
assert_contains "$prepare_out" 'requires preserved refs but cloud-context.json names none' \
  "B2C payload did not diagnose the missing preserved-ref grant"
mv "$HOME_DIR/data/$ID/cloud-context.saved" "$HOME_DIR/data/$ID/cloud-context.json"

prepare_out=$(python3 "$AUTHOR" prepare --home "$HOME_DIR" --task "$ID" \
  --worktree "$WORKTREE" --payload "$PAYLOAD" --brief "$HOME_DIR/data/$ID/brief.md" 2>&1) \
  || fail "B2C payload preparation failed: $prepare_out"
assert_contains "$prepare_out" '"base_branch":"env/develop"' \
  "prepared payload did not report the intended integration base"
test "$(git -C "$WORKTREE" rev-parse HEAD)" = "$BASE" \
  || fail "host worktree did not move to the exact fresh env/develop base"
test -z "$(git -C "$WORKTREE" branch --show-current)" \
  || fail "host base preparation unexpectedly created the task branch"
python3 - "$PAYLOAD/repository.json" "$PAYLOAD/context.json" "$BASE" "$PRESERVED" "$PR_HEAD" <<'PY' \
  || fail "repository/context manifests do not bind the B2C prerequisites"
import json, sys
repository = json.load(open(sys.argv[1]))
context = json.load(open(sys.argv[2]))
assert repository["base_branch"] == "env/develop"
assert repository["base_commit"] == sys.argv[3]
assert repository["task_branch"] == "fm/b2c-current"
commits = {entry["commit"] for entry in repository["preserved_refs"]}
assert {sys.argv[4], sys.argv[5]}.issubset(commits), commits
paths = {entry["path"] for entry in context["entries"]}
assert paths == {
    "data/product-resumption-plan-2026-08-31.md",
    "data/b2c-app-freshness-v4/report.md",
    "data/b2c-current/producer-contract.txt",
    "forge/open-prs.toon",
}, paths
PY
assert_grep '/mnt/task/.fm-context/data/product-resumption-plan-2026-08-31.md' \
  "$PAYLOAD/brief.md" "cloud brief does not point at its staged product plan"
assert_grep '/mnt/task/.fm-context/data/b2c-app-freshness-v4/report.md' \
  "$PAYLOAD/brief.md" "cloud brief does not point at its staged freshness report"
assert_grep '/mnt/task/.fm-context/data/b2c-current/producer-contract.txt' \
  "$PAYLOAD/brief.md" "cloud brief does not point at its task-specific artifact"
assert_grep 'trusted host code verifies the exact descendant' "$PAYLOAD/brief.md" \
  "cloud brief does not state host-managed publication"
assert_no_grep "Push the branch, open a PR with \`gh-axi\`" "$PAYLOAD/brief.md" \
  "cloud brief still orders the credentialless guest to publish"
assert_no_grep "$HOME_DIR" "$PAYLOAD/brief.md" \
  "cloud brief retains a host-only task path"
assert_no_grep 'Include the full PR URL' "$PAYLOAD/brief.md" \
  "cloud brief still requires a PR URL the guest cannot produce"
assert_no_grep 'Use an isolated branch and PR.' "$PAYLOAD/brief.md" \
  "cloud brief still requires the guest to create a PR"
assert_grep 'PR-URL or PR-readiness requirement is a host completion criterion' \
  "$PAYLOAD/brief.md" "cloud brief does not classify custom PR wording truthfully"
if grep -R -F 'Canonical pool must not travel.' "$PAYLOAD" >/dev/null; then
  fail "canonical account pool bytes entered the guest payload"
fi

GUEST="$TMP_ROOT/guest"
mkdir "$GUEST"
python3 - "$SUPERVISOR" "$PAYLOAD" "$GUEST" "$BASE" "$PRESERVED" "$PR_HEAD" <<'PY' \
  || fail "guest could not materialize the labelled repository/context payload"
import importlib.util, json, pathlib, sys
spec = importlib.util.spec_from_file_location("worker_supervisor", sys.argv[1])
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
staging = pathlib.Path(sys.argv[2]); guest = pathlib.Path(sys.argv[3])
repository = json.loads((staging / "repository.json").read_text())
repo = module._stage_author_repository(
    staging, guest, {"task": "b2c-current", "repository_generation": sys.argv[4]}
)
assert module.git_in(repo, "rev-parse", "HEAD").stdout.decode().strip() == sys.argv[4]
assert module.git_in(repo, "symbolic-ref", "HEAD").stdout.decode().strip() == "refs/heads/fm/b2c-current"
held = []
for ref in ("refs/fm-preserved/0001", "refs/fm-preserved/0002"):
    result = module.git_in(repo, "rev-parse", ref)
    held.append(result.stdout.decode().strip())
assert {sys.argv[5], sys.argv[6]}.issubset(set(held)), (held, sys.argv[5:7])
assert (guest / ".fm-context/data/product-resumption-plan-2026-08-31.md").read_text() == "Plan section 6.\n"
assert (guest / ".fm-context/data/b2c-app-freshness-v4/report.md").read_text() == "Freshness report v4.\n"
assert (guest / ".fm-context/data/b2c-current/producer-contract.txt").read_text() == "Task-specific producer contract.\n"
assert "Queued idempotency" in (guest / ".fm-context/forge/open-prs.toon").read_text()
PY
pass "B2C Azure payload carries exact current base, named refs, PR context, and bounded data without pool credentials"

# Model the digest-verified return after fm-cloud-result has fast-forwarded the
# host task branch. Publication must push only this exact commit and create the
# matching PR through host gh-axi credentials.
git -C "$WORKTREE" checkout --quiet -b "fm/$ID" "$BASE"
printf 'small returned change\n' > "$WORKTREE/cloud-smoke.txt"
git -C "$WORKTREE" add cloud-smoke.txt
git -C "$WORKTREE" commit --quiet -m 'test: return one Azure author commit'
TIP=$(git -C "$WORKTREE" rev-parse HEAD)
cat > "$HOME_DIR/state/$ID.meta" <<EOF
window=fixture
worktree=$WORKTREE
project=$SOURCE
kind=ship
mode=direct-PR
placement=azure
generation_id=spawn:one
EOF
cat > "$HOME_DIR/data/$ID/completion.md" <<'EOF'
## Summary

Returned one small commit.

## What changed

Added the smoke file.

## Verification

The focused fixture passed.

## Visual evidence

Not applicable.

## Artifacts

The task branch is the artifact.

## Follow-ups

Run the live post-merge Azure smoke.
EOF
python3 - "$HOME_DIR/data/$ID/cloud-return.json" "$ID" "$BASE" "$TIP" <<'PY'
import json, sys
path, task, base, tip = sys.argv[1:]
value = {
    "schema": "fm.worker-return/v1", "task": task,
    "repository_generation": base, "outcome_tip": tip, "outcome_commits": 1,
    "kind": "ship", "branch": "fm/" + task, "remote": "origin",
    "base_branch": "env/develop", "base_commit": base,
}
open(path, "w").write(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
PY
printf 'working: cloud outcome returned to local custody; host publication pending\n' \
  > "$HOME_DIR/state/$ID.status"

python3 - "$HOME_DIR/data/$ID/cloud-return.json" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path))
value["base_commit"] = "f" * 40
open(path, "w").write(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
PY
if publish_out=$(python3 "$AUTHOR" publish --state "$HOME_DIR/state" --task "$ID" 2>&1); then
  fail "host publication accepted a return whose base contract was changed: $publish_out"
fi
assert_contains "$publish_out" 'base commit differs' \
  "host publication did not diagnose the changed base contract"
if git --git-dir="$REMOTE" show-ref --verify --quiet "refs/heads/fm/$ID"; then
  fail "host publication pushed before verifying the returned base contract"
fi
python3 - "$HOME_DIR/data/$ID/cloud-return.json" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path))
for field in ("remote", "base_branch", "base_commit"):
    value.pop(field)
open(path, "w").write(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
PY

publish_out=$(python3 "$AUTHOR" publish --state "$HOME_DIR/state" --task "$ID" 2>&1) \
  || fail "host publication did not recover the accepted-create/client-failure seam: $publish_out"
assert_contains "$publish_out" 'https://github.com/ruby-labs/b2c/pull/99' \
  "host publication did not return the real PR URL"
test "$(git --git-dir="$REMOTE" rev-parse refs/heads/fm/$ID)" = "$TIP" \
  || fail "host publication did not push the exact returned tip"
assert_grep 'pr=https://github.com/ruby-labs/b2c/pull/99' "$HOME_DIR/state/$ID.meta" \
  "host publication did not bind the PR into task metadata"
assert_grep 'done: PR https://github.com/ruby-labs/b2c/pull/99' "$HOME_DIR/state/$ID.status" \
  "host publication did not replace the pending status with the real PR"
assert_present "$HOME_DIR/data/$ID/cloud-publication.json" \
  "host publication did not persist its retry receipt"

publish_out=$(python3 "$AUTHOR" publish --state "$HOME_DIR/state" --task "$ID" 2>&1) \
  || fail "host publication retry was not idempotent: $publish_out"
test "$(grep -c '^pr create ' "$FM_TEST_GH_LOG")" -eq 1 \
  || fail "host publication retry created a duplicate PR"
test "$(grep -c '^pr=https://github.com/ruby-labs/b2c/pull/99$' "$HOME_DIR/state/$ID.meta")" -eq 1 \
  || fail "host publication retry duplicated task PR metadata"
test "$(grep -c '^done: PR https://github.com/ruby-labs/b2c/pull/99$' "$HOME_DIR/state/$ID.status")" -eq 1 \
  || fail "host publication retry duplicated terminal status"
assert_grep 'Crosscheck must stay untouched.' "$HOME_DIR/config/crosscheck-azure.json" \
  "Azure author preparation or publication changed Crosscheck configuration"
pass "trusted host publication recovers retained-disk contracts and create retries without touching Crosscheck"

echo "# fm-azure-author-product.test.sh: all assertions passed"
