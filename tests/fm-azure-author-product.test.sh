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
DEFAULT=$(git -C "$WORKTREE" rev-parse HEAD)

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

print_footer() {
  printf '%s\n' \
    'help[2]:' \
    '  Run `gh-axi -R ruby-labs/b2c pr view <number>` to view details' \
    '  Run `gh-axi -R ruby-labs/b2c pr create --title "..." --body-file <path>` to create'
}

print_rows() {
  local count=$1 row
  shift
  printf 'count: %s\n' "$count"
  printf 'pull_requests[%s]{number,title,state,author,draft,review,url}:\n' "$count"
  for row in "$@"; do
    printf '  %s\n' "$row"
  done
  print_footer
}

print_api() {
  local number=$1 state=$2 base=$3 head=$4 sha=$5 head_repo=$6 base_repo=$7
  cat <<EOF
number: $number
state: $state
title: "PR $number"
body: "Exact REST details."
merged: false
head:
  label: "ruby-labs:$head"
  ref: $head
  sha: $sha
  repo:
    full_name: $head_repo
base:
  label: "ruby-labs:$base"
  ref: $base
  sha: ${FM_TEST_BASE:?}
  repo:
    full_name: $base_repo
EOF
}

context_row='17,"Context, ""quoted"" repair",open,ruby-labs,no,none,"https://github.com/ruby-labs/b2c/pull/17"'
published_row='99,"Published repair",open,ruby-labs,no,none,"https://github.com/ruby-labs/b2c/pull/99"'
second_row='100,"Published repair duplicate",open,ruby-labs,no,none,"https://github.com/ruby-labs/b2c/pull/100"'

case "${1:-} ${2:-}" in
  'pr list')
    case "$*" in
      'pr list --repo ruby-labs/b2c --state open --limit 100 --fields url') head_filter=0 ;;
      'pr list --repo ruby-labs/b2c --state open --head fm/b2c-current --limit 100 --fields url') head_filter=1 ;;
      *) printf '%s\n' 'error: unsupported fake gh-axi list invocation' >&2; exit 2 ;;
    esac
    case "${FM_TEST_GH_LIST_MODE:-ok}" in
      legacy)
        printf '%s\n' 'count: 1 (showing first 1)' 'pull_requests[1]{url}:' \
          '  https://github.com/ruby-labs/b2c/pull/17'
        ;;
      count-mismatch)
        printf '%s\n' 'count: 2' \
          'pull_requests[1]{number,title,state,author,draft,review,url}:' \
          "  $context_row"
        print_footer
        ;;
      bad-schema)
        printf '%s\n' 'count: 1' 'pull_requests[1]{number,state,url}:' \
          '  17,open,"https://github.com/ruby-labs/b2c/pull/17"'
        print_footer
        ;;
      bad-help)
        printf '%s\n' 'count: 1' \
          'pull_requests[1]{number,title,state,author,draft,review,url}:' \
          "  $context_row" 'help[1]:' '  Try another command'
        ;;
      bad-csv)
        print_rows 1 '17,"unterminated,open,ruby-labs,no,none,"https://github.com/ruby-labs/b2c/pull/17"'
        ;;
      empty) print_rows 0 ;;
      too-many)
        printf '%s\n' 'count: 101' \
          'pull_requests[101]{number,title,state,author,draft,review,url}:'
        print_footer
        ;;
      duplicate) print_rows 2 "$context_row" "$context_row" ;;
      foreign)
        print_rows 1 '17,"Foreign",open,ruby-labs,no,none,"https://github.com/other/b2c/pull/17"'
        ;;
      malformed)
        print_rows 1 '017,"Malformed",open,ruby-labs,no,none,"https://github.com/ruby-labs/b2c/pull/017"'
        ;;
      conflicting-list)
        print_rows 1 '17,"Conflict",open,ruby-labs,no,none,"https://github.com/ruby-labs/b2c/pull/18"'
        ;;
      unresolved)
        print_rows 1 '18,"Unresolved",open,ruby-labs,no,none,"https://github.com/ruby-labs/b2c/pull/18"'
        ;;
      ambiguous|exact-with-other-base)
        if [ "$head_filter" -eq 1 ]; then
          print_rows 2 "$published_row" "$second_row"
        else
          print_rows 3 "$context_row" "$published_row" "$second_row"
        fi
        ;;
      conflicting-head|conflicting-oid)
        if [ "$head_filter" -eq 1 ]; then
          print_rows 1 "$second_row"
        else
          print_rows 2 "$context_row" "$second_row"
        fi
        ;;
      *)
        rows=()
        [ "$head_filter" -eq 1 ] || rows+=("$context_row")
        if [ -f "${FM_TEST_PR_API:?}" ]; then
          rows+=("$published_row")
        fi
        if [ -f "${FM_TEST_AMBIGUOUS_CREATED:?}" ]; then
          rows+=("$second_row")
        fi
        print_rows "${#rows[@]}" "${rows[@]}"
        ;;
    esac
    ;;
  'pr view')
    selector=${3:-}
    if ! [[ "$selector" =~ ^[1-9][0-9]*$ ]]; then
      printf '%s\n' 'error: Missing PR number' 'code: VALIDATION_ERROR' >&2
      exit 1
    fi
    cat <<EOF
pull_request:
  number: $selector
  title: "Installed rich summary"
  state: open
  author: ruby-labs
  draft: no
  merged: no
  body: "No exact branch or OID fields are exposed."
  comment_count: 0 — use --comments to see full comments
  review_count: 0 — use --reviews to see full reviews
EOF
    ;;
  'api /repos/ruby-labs/b2c/pulls/17')
    case "${FM_TEST_GH_LIST_MODE:-ok}" in
      incomplete-api)
        cat <<EOF
number: 17
state: open
head:
  ref: pr/open-candidate
  repo:
    full_name: ruby-labs/b2c
base:
  ref: env/develop
  repo:
    full_name: ruby-labs/b2c
EOF
        ;;
      foreign-api)
        print_api 17 open env/develop pr/open-candidate "${FM_TEST_PR_HEAD:?}" other/b2c ruby-labs/b2c
        ;;
      bad-oid)
        print_api 17 open env/develop pr/open-candidate abc ruby-labs/b2c ruby-labs/b2c
        ;;
      bad-branch)
        print_api 17 open env/develop 'bad branch' "${FM_TEST_PR_HEAD:?}" ruby-labs/b2c ruby-labs/b2c
        ;;
      conflict-number)
        print_api 19 open env/develop pr/open-candidate "${FM_TEST_PR_HEAD:?}" ruby-labs/b2c ruby-labs/b2c
        ;;
      closed-api)
        print_api 17 closed env/develop pr/open-candidate "${FM_TEST_PR_HEAD:?}" ruby-labs/b2c ruby-labs/b2c
        ;;
      *)
        print_api 17 open env/develop pr/open-candidate "${FM_TEST_PR_HEAD:?}" ruby-labs/b2c ruby-labs/b2c
        ;;
    esac
    ;;
  'api /repos/ruby-labs/b2c/pulls/18')
    printf '%s\n' 'error: pull request not found' >&2
    exit 1
    ;;
  'api /repos/ruby-labs/b2c/pulls/99')
    if [ "${FM_TEST_GH_LIST_MODE:-ok}" = retargeted-receipt ]; then
      head=$(git --git-dir="${FM_TEST_REMOTE:?}" rev-parse refs/heads/fm/b2c-current)
      print_api 99 open main fm/b2c-current "$head" ruby-labs/b2c ruby-labs/b2c
    elif [ -f "${FM_TEST_PR_API:?}" ]; then
      cat "$FM_TEST_PR_API"
    else
      printf '%s\n' 'error: pull request not found' >&2
      exit 1
    fi
    ;;
  'api /repos/ruby-labs/b2c/pulls/100')
    head=$(git --git-dir="${FM_TEST_REMOTE:?}" rev-parse refs/heads/fm/b2c-current)
    base=env/develop
    case "${FM_TEST_GH_LIST_MODE:-ok}" in
      conflicting-head|exact-with-other-base) base=main ;;
    esac
    [ "${FM_TEST_GH_LIST_MODE:-ok}" != conflicting-oid ] || head=${FM_TEST_PR_HEAD:?}
    print_api 100 open "$base" fm/b2c-current "$head" ruby-labs/b2c ruby-labs/b2c
    ;;
  'pr create')
    if [ "${FM_TEST_GH_CREATE_MODE:-accepted}" = no-server-result ]; then
      printf '%s\n' 'error: client lost the create response' >&2
      exit 75
    fi
    head=$(git --git-dir="${FM_TEST_REMOTE:?}" rev-parse refs/heads/fm/b2c-current)
    print_api 99 open env/develop fm/b2c-current "$head" ruby-labs/b2c ruby-labs/b2c \
      > "${FM_TEST_PR_API:?}"
    if [ "${FM_TEST_GH_CREATE_MODE:-accepted}" = ambiguous ]; then
      : > "${FM_TEST_AMBIGUOUS_CREATED:?}"
    fi
    # Model a client failure after GitHub accepted the create. The host helper
    # must rediscover through the bounded rich list plus numeric REST API.
    exit 75
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$FAKEBIN/gh-axi"

export FM_GH_AXI_BIN="$FAKEBIN/gh-axi"
export FM_TEST_GH_LOG="$TMP_ROOT/gh.log"
export FM_TEST_PR_HEAD="$PR_HEAD"
export FM_TEST_BASE="$BASE"
export FM_TEST_PR_API="$TMP_ROOT/pr-api.toon"
export FM_TEST_AMBIGUOUS_CREATED="$TMP_ROOT/ambiguous-created"
export FM_TEST_REMOTE="$REMOTE"
export FM_CLOUD_AUTHOR_TEST_HOOKS=azure-author-tests-v1
export FM_CLOUD_AUTHOR_TEST_REPOSITORY=ruby-labs/b2c
mkdir -p "$PAYLOAD"

for selector in 'https://github.com/ruby-labs/b2c/pull/17' 'fm/b2c-current'; do
  if selector_out=$("$FM_GH_AXI_BIN" pr view "$selector" --repo ruby-labs/b2c \
    --fields url,state,baseRefName,headRefName,headRefOid 2>&1); then
    fail "fake gh-axi accepted the installed client's unsupported selector: $selector"
  fi
  test "$selector_out" = $'error: Missing PR number\ncode: VALIDATION_ERROR' \
    || fail "fake gh-axi did not reproduce the installed non-numeric selector refusal"
done
selector_out=$("$FM_GH_AXI_BIN" pr view 17 --repo ruby-labs/b2c \
  --fields url,state,baseRefName,headRefName,headRefOid) \
  || fail "fake gh-axi rejected the installed numeric view surface"
assert_contains "$selector_out" 'pull_request:' \
  "fake gh-axi did not reproduce the installed rich numeric view summary"
assert_not_contains "$selector_out" 'headRefOid' \
  "fake gh-axi invented exact detail fields unsupported by gh-axi 0.1.25"

mv "$HOME_DIR/data/$ID/cloud-context.json" "$HOME_DIR/data/$ID/cloud-context.saved"
if prepare_out=$(python3 "$AUTHOR" prepare --home "$HOME_DIR" --task "$ID" \
  --worktree "$WORKTREE" --payload "$PAYLOAD" --brief "$HOME_DIR/data/$ID/brief.md" 2>&1); then
  fail "B2C payload silently omitted its unnamed required preserved branches: $prepare_out"
fi
assert_contains "$prepare_out" 'requires preserved refs but cloud-context.json names none' \
  "B2C payload did not diagnose the missing preserved-ref grant"
mv "$HOME_DIR/data/$ID/cloud-context.saved" "$HOME_DIR/data/$ID/cloud-context.json"

if prepare_out=$(FM_TEST_GH_LIST_MODE=legacy python3 "$AUTHOR" prepare \
  --home "$HOME_DIR" --task "$ID" --worktree "$WORKTREE" \
  --payload "$PAYLOAD" --brief "$HOME_DIR/data/$ID/brief.md" 2>&1); then
  fail "B2C payload accepted the obsolete URL-only list shape: $prepare_out"
fi
assert_contains "$prepare_out" 'malformed open pull request list data' \
  "B2C payload did not require the installed rich gh-axi list schema"
test "$(git -C "$WORKTREE" rev-parse HEAD)" = "$DEFAULT" \
  || fail "failed host context capture moved the lease away from its acquisition tip"

assert_pr_context_refusal() {
  local mode=$1 expected=$2 label=$3 output
  if output=$(FM_TEST_GH_LIST_MODE="$mode" python3 "$AUTHOR" prepare \
    --home "$HOME_DIR" --task "$ID" --worktree "$WORKTREE" \
    --payload "$PAYLOAD" --brief "$HOME_DIR/data/$ID/brief.md" 2>&1); then
    fail "$label was accepted: $output"
  fi
  assert_contains "$output" "$expected" "$label was not diagnosed exactly"
  test "$(git -C "$WORKTREE" rev-parse HEAD)" = "$DEFAULT" \
    || fail "$label moved the lease away from its acquisition tip"
}

assert_pr_context_refusal too-many 'exceeds its entry bound' \
  'over-limit open-PR list context'
assert_pr_context_refusal count-mismatch 'malformed open pull request list data' \
  'inconsistent open-PR row counts'
assert_pr_context_refusal bad-schema 'malformed open pull request list data' \
  'wrong rich open-PR table schema'
assert_pr_context_refusal bad-help 'malformed open pull request list data' \
  'missing installed open-PR help footer'
assert_pr_context_refusal bad-csv 'malformed open pull request CSV data' \
  'malformed quoted open-PR CSV row'
assert_pr_context_refusal duplicate 'duplicate open pull request list data' \
  'duplicate open-PR list context'
assert_pr_context_refusal foreign 'open pull request from another repository' \
  'foreign-repository open-PR URL context'
assert_pr_context_refusal malformed 'malformed open pull request list data' \
  'non-canonical open-PR number context'
assert_pr_context_refusal conflicting-list 'conflicting open pull request list data' \
  'conflicting open-PR number and URL context'
assert_pr_context_refusal unresolved 'could not resolve listed pull request' \
  'unresolved numeric open-PR context'
assert_pr_context_refusal incomplete-api 'lacks exact head.sha' \
  'incomplete open-PR API context'
assert_pr_context_refusal foreign-api 'pull request from another repository' \
  'foreign-repository open-PR API context'
assert_pr_context_refusal bad-oid 'malformed pull request API head OID' \
  'malformed open-PR head OID context'
assert_pr_context_refusal bad-branch 'pull request API head branch is malformed' \
  'malformed open-PR head branch context'
assert_pr_context_refusal conflict-number 'conflicting pull request API number' \
  'conflicting open-PR API number context'
assert_pr_context_refusal closed-api 'conflicting open pull request state data' \
  'conflicting open-PR API state context'

prepare_out=$(FM_TEST_GH_LIST_MODE=empty python3 "$AUTHOR" prepare \
  --home "$HOME_DIR" --task "$ID" --worktree "$WORKTREE" \
  --payload "$PAYLOAD" --brief "$HOME_DIR/data/$ID/brief.md" 2>&1) \
  || fail "empty open-PR context preparation failed: $prepare_out"
assert_grep 'pull_requests[0]' <(tar -xOf "$PAYLOAD/context.tar" forge/open-prs.toon) \
  "empty open-PR context did not produce a bounded empty snapshot"

: > "$FM_TEST_GH_LOG"
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
assert_grep 'https://github.com/ruby-labs/b2c/pull/17' <(tar -xOf "$PAYLOAD/context.tar" forge/open-prs.toon) \
  "cloud PR context omitted the exact pull request URL"
assert_grep '"open"' <(tar -xOf "$PAYLOAD/context.tar" forge/open-prs.toon) \
  "cloud PR context omitted the exact pull request state"
assert_grep 'env/develop' <(tar -xOf "$PAYLOAD/context.tar" forge/open-prs.toon) \
  "cloud PR context omitted the exact base branch"
assert_grep 'pr/open-candidate' <(tar -xOf "$PAYLOAD/context.tar" forge/open-prs.toon) \
  "cloud PR context omitted the exact head branch"
assert_grep "$PR_HEAD" <(tar -xOf "$PAYLOAD/context.tar" forge/open-prs.toon) \
  "cloud PR context omitted the exact head commit"
cp "$PAYLOAD/context.json" "$TMP_ROOT/context.first.json"
cp "$PAYLOAD/context.tar" "$TMP_ROOT/context.first.tar"
prepare_out=$(python3 "$AUTHOR" prepare --home "$HOME_DIR" --task "$ID" \
  --worktree "$WORKTREE" --payload "$PAYLOAD" --brief "$HOME_DIR/data/$ID/brief.md" 2>&1) \
  || fail "repeated B2C payload preparation failed: $prepare_out"
cmp -s "$TMP_ROOT/context.first.json" "$PAYLOAD/context.json" \
  || fail "repeated open-PR context capture changed its manifest"
cmp -s "$TMP_ROOT/context.first.tar" "$PAYLOAD/context.tar" \
  || fail "repeated open-PR context capture changed its bounded snapshot"
test "$(grep -c '^pr list .* --fields url$' "$FM_TEST_GH_LOG")" -eq 2 \
  || fail "repeated context capture did not use the bounded rich gh-axi list twice"
test "$(grep -c '^api /repos/ruby-labs/b2c/pulls/17$' "$FM_TEST_GH_LOG")" -eq 2 \
  || fail "repeated context capture did not resolve exact PR details through the numeric API"
if grep -q '^pr view ' "$FM_TEST_GH_LOG"; then
  fail "open-PR context used the unsupported gh-axi pr view detail surface"
fi
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
pr_context = (guest / ".fm-context/forge/open-prs.toon").read_text()
assert "https://github.com/ruby-labs/b2c/pull/17" in pr_context
assert "env/develop" in pr_context
assert "pr/open-candidate" in pr_context
assert sys.argv[6] in pr_context
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

cat > "$FM_TEST_PR_API" <<EOF
number: 99
state: open
title: "Existing publication"
body: "Exact REST details."
merged: false
head:
  ref: fm/b2c-current
  sha: $TIP
  repo:
    full_name: ruby-labs/b2c
base:
  ref: env/develop
  sha: $BASE
  repo:
    full_name: ruby-labs/b2c
EOF
: > "$FM_TEST_GH_LOG"
publish_out=$(python3 "$AUTHOR" publish --state "$HOME_DIR/state" --task "$ID" 2>&1) \
  || fail "host publication did not reuse an initially existing PR: $publish_out"
assert_contains "$publish_out" 'https://github.com/ruby-labs/b2c/pull/99' \
  "initial existing-PR publication did not return the real URL"
test "$(grep -c '^pr create ' "$FM_TEST_GH_LOG")" -eq 0 \
  || fail "initial existing-PR publication attempted a duplicate create"
publish_out=$(python3 "$AUTHOR" publish --state "$HOME_DIR/state" --task "$ID" 2>&1) \
  || fail "initial existing-PR publication was not repeatable: $publish_out"
test "$(grep -c '^pr create ' "$FM_TEST_GH_LOG")" -eq 0 \
  || fail "repeated existing-PR publication attempted a duplicate create"
test "$(grep -c '^pr list ' "$FM_TEST_GH_LOG")" -eq 1 \
  || fail "retained publication replay rediscovered the already-bound PR"

: > "$FM_TEST_GH_LOG"
publish_out=$(FM_TEST_GH_LIST_MODE=retargeted-receipt python3 "$AUTHOR" publish \
  --state "$HOME_DIR/state" --task "$ID" 2>&1) \
  || fail "retained publication did not survive a trusted-host base retarget: $publish_out"
assert_contains "$publish_out" 'https://github.com/ruby-labs/b2c/pull/99' \
  "retained publication did not return its bound PR after a base retarget"
test "$(grep -c '^api /repos/ruby-labs/b2c/pulls/99$' "$FM_TEST_GH_LOG")" -eq 1 \
  || fail "retained publication did not resolve its exact numeric PR once"
if grep -q '^pr \(list\|create\) ' "$FM_TEST_GH_LOG"; then
  fail "retained publication rediscovered or recreated a PR after a base retarget"
fi

rm "$HOME_DIR/data/$ID/cloud-publication.json"
: > "$FM_TEST_GH_LOG"
publish_out=$(FM_TEST_GH_LIST_MODE=exact-with-other-base python3 "$AUTHOR" publish \
  --state "$HOME_DIR/state" --task "$ID" 2>&1) \
  || fail "host publication did not select the exact PR beside another-base sibling: $publish_out"
assert_contains "$publish_out" 'https://github.com/ruby-labs/b2c/pull/99' \
  "publication did not return the exact PR beside another-base sibling"
test "$(grep -c '^pr create ' "$FM_TEST_GH_LOG")" -eq 0 \
  || fail "publication attempted a duplicate create beside another-base sibling"
assert_present "$HOME_DIR/data/$ID/cloud-publication.json" \
  "exact publication beside another-base sibling did not persist its receipt"
rm "$HOME_DIR/data/$ID/cloud-publication.json"

if publish_out=$(FM_TEST_GH_LIST_MODE=ambiguous python3 "$AUTHOR" publish \
  --state "$HOME_DIR/state" --task "$ID" 2>&1); then
  fail "host publication guessed among multiple matching open PRs: $publish_out"
fi
assert_contains "$publish_out" 'multiple exact open pull requests for the publication head' \
  "host publication did not diagnose exact matching-head ambiguity"

if publish_out=$(FM_TEST_GH_LIST_MODE=conflicting-head python3 "$AUTHOR" publish \
  --state "$HOME_DIR/state" --task "$ID" 2>&1); then
  fail "host publication accepted conflicting same-head PR details: $publish_out"
fi
assert_contains "$publish_out" 'conflicting open pull request publication data' \
  "host publication did not diagnose conflicting same-head details"

if publish_out=$(FM_TEST_GH_LIST_MODE=conflicting-oid python3 "$AUTHOR" publish \
  --state "$HOME_DIR/state" --task "$ID" 2>&1); then
  fail "host publication accepted a same-head PR at another OID: $publish_out"
fi
assert_contains "$publish_out" 'conflicting open pull request publication data' \
  "host publication did not diagnose a conflicting publication head OID"

test "$(git --git-dir="$REMOTE" rev-parse refs/heads/fm/$ID)" = "$TIP" \
  || fail "host publication did not push the exact returned tip"
assert_grep 'pr=https://github.com/ruby-labs/b2c/pull/99' "$HOME_DIR/state/$ID.meta" \
  "host publication did not bind the PR into task metadata"
assert_grep 'done: PR https://github.com/ruby-labs/b2c/pull/99' "$HOME_DIR/state/$ID.status" \
  "host publication did not replace the pending status with the real PR"
assert_absent "$HOME_DIR/data/$ID/cloud-publication.json" \
  "a refused publication persisted a receipt"

rm "$FM_TEST_PR_API"
: > "$FM_TEST_GH_LOG"
if publish_out=$(FM_TEST_GH_CREATE_MODE=ambiguous python3 "$AUTHOR" publish \
  --state "$HOME_DIR/state" --task "$ID" 2>&1); then
  fail "host publication accepted multiple exact PRs after create: $publish_out"
fi
assert_contains "$publish_out" 'multiple exact open pull requests for the publication head' \
  "host publication did not diagnose post-create exact-head ambiguity"
rm "$FM_TEST_PR_API" "$FM_TEST_AMBIGUOUS_CREATED"

: > "$FM_TEST_GH_LOG"
if publish_out=$(FM_TEST_GH_CREATE_MODE=no-server-result python3 "$AUTHOR" publish \
  --state "$HOME_DIR/state" --task "$ID" 2>&1); then
  fail "host publication accepted zero matching PRs after create: $publish_out"
fi
assert_contains "$publish_out" 'pull request creation did not converge' \
  "host publication did not refuse zero matching PRs after create"
test "$(grep -c '^pr list .* --fields url$' "$FM_TEST_GH_LOG")" -eq 2 \
  || fail "failed publication did not list before and after create"

: > "$FM_TEST_GH_LOG"
publish_out=$(python3 "$AUTHOR" publish --state "$HOME_DIR/state" --task "$ID" 2>&1) \
  || fail "host publication did not recover the accepted-create/client-failure seam: $publish_out"
assert_contains "$publish_out" 'https://github.com/ruby-labs/b2c/pull/99' \
  "post-create discovery did not return the real PR URL"
test "$(grep -c '^pr list .* --fields url$' "$FM_TEST_GH_LOG")" -eq 2 \
  || fail "accepted-create recovery did not list before and after create"
test "$(grep -c '^pr create ' "$FM_TEST_GH_LOG")" -eq 1 \
  || fail "accepted-create recovery did not make exactly one create attempt"
publish_out=$(python3 "$AUTHOR" publish --state "$HOME_DIR/state" --task "$ID" 2>&1) \
  || fail "post-create publication retry was not idempotent: $publish_out"
test "$(grep -c '^pr create ' "$FM_TEST_GH_LOG")" -eq 1 \
  || fail "post-create publication retry created a duplicate PR"
test "$(grep -c '^api /repos/ruby-labs/b2c/pulls/99$' "$FM_TEST_GH_LOG")" -ge 2 \
  || fail "publication did not inspect the discovered PR through the numeric API"
if grep -q '^pr view ' "$FM_TEST_GH_LOG"; then
  fail "publication used the unsupported gh-axi pr view detail surface"
fi
assert_grep 'pr list --repo ruby-labs/b2c --state open --head fm/b2c-current --limit 100 --fields url' \
  "$FM_TEST_GH_LOG" "publication did not use bounded server-side head filtering"
test "$(grep -c '^pr=https://github.com/ruby-labs/b2c/pull/99$' "$HOME_DIR/state/$ID.meta")" -eq 1 \
  || fail "host publication retry duplicated task PR metadata"
test "$(grep -c '^done: PR https://github.com/ruby-labs/b2c/pull/99$' "$HOME_DIR/state/$ID.status")" -eq 1 \
  || fail "host publication retry duplicated terminal status"
assert_grep 'Crosscheck must stay untouched.' "$HOME_DIR/config/crosscheck-azure.json" \
  "Azure author preparation or publication changed Crosscheck configuration"
pass "trusted host publication uses numeric discovery, refuses ambiguity, and recovers create retries without touching Crosscheck"

echo "# fm-azure-author-product.test.sh: all assertions passed"
