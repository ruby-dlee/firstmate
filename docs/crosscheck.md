# Crosscheck

Crosscheck is an independent exact-head finding ledger at the PR merge gate.
It is not a second implementation of tests, lint, documentation checks, pushing, PR creation, or CI.
No-mistakes remains the owner of that validation pipeline.

The review portion is intentionally close to "no-mistakes review with a fresh, different model."
Most of its review-quality value comes from that cross-model independence.
The separate mechanism earns its keep only through four contracts that no-mistakes does not currently own: durable finding lifecycle across runs, gate-executed reproduction evidence, gate-executed mutation proof for fixes, and an exact reviewed SHA passed atomically to GitHub at merge.
If those contracts move into no-mistakes, the separate reviewer runner should be removed rather than defended as a parallel product.

## Operator flow

Configure one or more policy-grade reviewer accounts per firstmate home.
The file is local and gitignored at `config/crosscheck-reviewer.json`.

```json
{
  "reviewers": [
    {
      "harness": "codex",
      "model": "gpt-5.6-sol",
      "effort": "xhigh",
      "account_home": "/absolute/path/to/an/independent/codex/home"
    },
    {
      "harness": "claude",
      "model": "claude-opus-5",
      "effort": "xhigh",
      "account_home": "/absolute/path/to/an/independent/claude/home"
    },
    {
      "harness": "pi",
      "model": "gpt-5.6-sol",
      "effort": "xhigh",
      "account_home": "/absolute/path/to/an/independent/pi/home"
    }
  ]
}
```

Crosscheck resolves each configured account home and keeps every entry whose model differs from the routed author identity recorded in task metadata and whose account is provably not the author's, in configured order.
It then binds the provider's executing credential selector to that exact path and requires the verdict plus a Bash-created receipt to report the selector and actual private `HOME`.
Account separation therefore depends on the executing credential source rather than a configuration label.
Every reviewer disables reviewed-repository instruction discovery at launch: Codex sets `project_doc_max_bytes=0`, Claude uses `--safe-mode`, and Pi uses `--no-context-files`.
Pi is launched through the resolved installed executable with `openai-codex/gpt-5.6-sol` at `xhigh`, JSON event output, an ephemeral session, and only the read and Bash-capable review tools.
For the installed npm entrypoint, Crosscheck also resolves Pi's sibling Node runtime before launch instead of allowing the reviewer environment's `PATH` to substitute another interpreter.
That pin recognizes every `env`-based Node shebang, including `#!/usr/bin/env -S node --flag`, and preserves the flags; an `env` shebang naming no interpreter fails closed rather than silently falling back to `PATH`.
Its event stream must contain at least one completed turn, end with a successful `stop` assistant turn, and complete the agent before Crosscheck accepts that terminal turn's JSON verdict.
Pi credential provisioning is a captain-owned prerequisite: the selected `account_home` must contain a usable `openai-codex` OAuth entry in `auth.json`, and Firstmate does not create or copy that credential.
Because Pi selects only the default `openai-codex` slot and reviewer launches disable extension discovery, a Pi reviewer home holds exactly one account; a multi-slot Pi home reviews as its default slot, not as whichever slot has capacity.

Pi is a third client, not extra capacity.
It authenticates against the same upstream OpenAI accounts the Codex reviewer uses, so a Codex account at its usage limit is equally unavailable through Pi, and a Pi reviewer does not route around an exhausted Codex account.
What Pi adds is an independent client path and a reviewer that is separate from a Claude author by construction.
A usage-limited reviewer account records a `tool-failure`, never a verdict about code, and Crosscheck then advances to the next independent entry rather than refusing the merge.
Failover is limited to faults that prevented a verdict: a launch failure, an unusable credential, a provider that was never reached, or an exhausted account.
A reviewer that reached the model and then declined clearance, returned no valid artifact, or returned a malformed one ends the run on the spot, because that is the reviewer's own conclusion and a second account must not be used to shop for a friendlier one.
Each abandoned attempt is recorded as its own `tool-failure` run, so the ledger names every account that was tried and why it was left, and each attempt gets its own pristine exact-head checkout so no reviewer inherits an earlier reviewer's helpers or scratch state.
Selection therefore makes the gate as available as the roster rather than as available as its first entry, and independence is unchanged: every candidate passed the same model and account separation screen, and `run_reviewer` still re-proves separation against the credential it actually binds.

One upstream account routinely exists behind several directories at once, so two different `account_home` paths can execute as the same account.
Codex and Pi both authenticate against OpenAI, and a Claude config home that records no account of its own borrows whatever credential the environment supplies.
Path inequality therefore cannot establish account separation on either provider.
When the author and the reviewer resolve to the same provider, Crosscheck compares the account each home executes as and refuses a reviewer that resolves to the author's account, an unreadable identity on either side, or a credential such as an API key that names no account at all.
An identity that cannot be resolved is never separation, and the refusal happens at selection so a genuinely provable reviewer later in the list can still be chosen.
The account is read from `tokens.account_id` for Codex, `openai-codex.accountId` for Pi, and `oauthAccount.accountUuid` in `.claude.json` for Claude; `bin/fm-crosscheck.py`'s `account_identity` keys that resolution on the provider so a new client on an existing provider cannot reopen the hole.
`run_reviewer` repeats the comparison against the credential it actually binds, and that launch-time check is the authoritative one.
A lane that records no `account_home` is an ordinary supported author identity, not an emergency.
Account routing is off by design for any harness outside Codex and Claude, so a Pi lane structurally cannot record an `account_home`.
Requiring one, or an `account_routing_emergency_bypass=1` marker in its place, made every Pi-launched lane permanently unmergeable through this gate, and a bypass that has to be set on the majority of lanes is not a gate.
Such a lane is refused only when its harness maps to no known provider namespace, because then nothing is left to prove separation with.
For an account-bearing lane a reviewer is proved independent on the executing account; for an account-less lane the equivalent fact is the provider namespace, since an Anthropic account cannot be an OpenAI account and the two model namespaces are disjoint.
A reviewer on the other supported provider therefore establishes both account-namespace and model separation without inventing an `account_home` for the author, and `account_routing_emergency_bypass=1` remains accepted but is no longer required.
Model separation compares the model itself, not the recorded string: Pi records `<provider-slot>/<model>`, so `openai-codex-2/gpt-5.6-sol` is the same model as a Codex reviewer's `gpt-5.6-sol` and must never read as separate from it.
Provider is what that lane compares, not harness: Codex and Pi are both the OpenAI provider, so an unrouted Codex author is reviewable only by Claude, while an unrouted Claude author is reviewable by either Codex or Pi.
A same-provider reviewer still fails closed for that structurally unrouted task because account independence cannot be proved.
The accepted profiles are Codex `gpt-5.6-sol` xhigh, Claude `claude-opus-5` xhigh, and Pi `gpt-5.6-sol` xhigh.
Absent configuration, unavailable credentials, missing model separation, and unprovable account separation all produce `CROSSCHECK TOOL-FAILURE` and a nonzero exit before reviewer launch.

Crosscheck requires Python 3.11 or newer and refuses to run on anything older.
This is a safety floor rather than a style preference: the bounded-read layer rejects hostile JSON integers by relying on CPython's integer/string conversion limit, which first exists in 3.11, and on an older interpreter that rejection silently stops happening while every banner the gate prints reads exactly the same.
Stock macOS `python3` is 3.9, so `bin/fm-crosscheck.sh` resolves a supported sibling interpreter instead of assuming `python3` qualifies, and `bin/fm-crosscheck.py` enforces the same minimum itself so a direct invocation cannot bypass it.
`bin/fm-crosscheck-python-lib.sh` owns that resolution for both the wrapper and the behavior tests; `FM_CROSSCHECK_PYTHON` selects an explicit interpreter and `FM_CROSSCHECK_MIN_PYTHON` overrides the minimum.
A `FM_CROSSCHECK_MIN_PYTHON` that is not `<major>.<minor>` is refused rather than parsed into a lower floor, because a bare `3` would otherwise silently admit Python 3.3.
An explicitly configured `FM_CROSSCHECK_PYTHON` that is missing or below the floor refuses by name rather than falling through to some other interpreter, so a typo or a stale path cannot silently unpin the gate.
CI pins a single modern interpreter and therefore cannot observe this class of defect on its own, which is why the floor is asserted at runtime rather than assumed from the CI matrix.

Start crosscheck as soon as a PR URL exists so it can overlap no-mistakes' remaining CI work.
The reviewer is a real policy-grade agent invocation and normally takes minutes, so Crosscheck is not a fast local check.

```sh
bin/fm-crosscheck.sh run <task-id> <https://github.com/owner/repo/pull/number>
```

The run writes `data/<task-id>/crosscheck-ledger.json` and the readable `data/<task-id>/crosscheck.md` report.
The run exits zero only when the exact head has a complete review, the reviewer supplied a successfully gate-reexecuted exact-base/exact-head reproduction, the durable ledger has no active blocker, and the reviewer returned no unreproduced suspicion.
It fetches `refs/pull/<number>/head` from the base repository into a disposable Git checkout and requires that ref to resolve to the exact live API head SHA before reviewer launch.

The reviewed base is the merge base of that head and the live base branch, resolved in the review checkout, and it is the base every downstream consumer uses: the reviewer prompt, the verdict-level execution proof, the ledger run, and verification.
It is deliberately not GitHub's `base.sha`.
GitHub reports `base.sha` as the base branch tip observed when the snapshot was taken, so on an active default branch it is usually not an ancestor of the PR head and it changes whenever anything else merges.
Treating it as the reviewed base made two failures routine: an un-rebased PR was refused before launch because the live base was not the checkout's merge base, and a ledger written minutes earlier stopped matching at the merge gate because the branch had moved for reasons unrelated to the PR.
Both refusals were artifacts of comparing a moving value, not evidence about the change, and a gate that cannot be satisfied is worse than no gate because it trains its operators to route around it.
The merge base converges instead: the default branch advancing cannot change it unless the branch absorbs commits already reachable from this head, in which case the remaining diff is a subset of what was reviewed and the review stays sound.
Any change to the PR itself - a new commit, a rebase, a force-push - changes the head SHA, which invalidates the ledger match on its own, so the head remains the pin GitHub's atomic merge enforces.
Verification therefore matches the live head and the stable claims digest, and checks the execution proof against the merge base the run recorded.
Each run records both values: `base_sha` is the reviewed merge base, and `base_branch_sha` is the base branch tip GitHub reported at snapshot time, so a ledger shows on its face when the default branch had moved ahead of the review.
The authoring worktree is not cloned, checked for cleanliness, or required to match the PR head because no verdict about the remote PR may depend on mutable author-lane filesystem state.
An empty `FM_STATE_OVERRIDE` falls back to the home state directory, so task metadata, the shared per-task lock, and the disposable review checkout cannot split across callers' current working directories.

`bin/fm-pr-merge.sh` calls the verification form automatically after approval.
Do not call the verification form as a substitute for running a reviewer.

```sh
bin/fm-crosscheck.sh verify <task-id> <https://github.com/owner/repo/pull/number>
```

Verification re-reads the live PR head and complete claims document.
It requires the latest attempt matching that head and the stable PR number/title/body claims digest to be clear, then prints only the exact reviewed SHA.
Dynamic check counts in the full `gh-axi` document remain visible to the reviewer but are excluded from the digest so CI completing in parallel does not invalidate an otherwise exact review.
The merge helper sends that SHA in GitHub's atomic merge request.
A force-push before verification invalidates the ledger match, while a force-push after verification makes GitHub reject the expected-head merge request.

## Finding lifecycle

The ledger schema is `firstmate.crosscheck-ledger.v2`.
An existing ledger is validated before a reviewer runs.
A null, absent, or wrong-typed `findings` or `runs` collection is rejected rather than normalized.

Findings have exactly four lifecycle values.

- `open` means an executed reproduction admitted the defect and it remains a blocker.
- `claimed-fixed` records a reviewer's claim but remains a blocker.
- `verified-fixed` requires a tracked named test that passes on the exact head and fails after a supplied implementation mutation is applied.
- `closed-equivalent` requires a direct reference to another currently `verified-fixed` finding.

A later review that omits a finding leaves its lifecycle unchanged.
Silence never closes, supersedes, or deletes a finding.
A `verified-fixed` lifecycle remains durable, but its proof clears only the exact head on which the gate executed it; a new head requires a fresh mutation proof.

Each run has one outcome class.

- `tool-failure` means environment, task metadata, reviewer configuration, exact-head fetch, executing-account binding, or required command-execution proof prevented a trustworthy verdict.
- `unreviewed` means a reviewer ran but no valid exact-head verdict artifact exists.
- `blocking` means a completed reviewer with successful command-execution evidence declined clearance through a suspicion or admitted finding.
- `clear` means a completed reviewer with successful command-execution evidence earned clearance and no durable blocker remains.

CLI banners preserve the same distinction as `CROSSCHECK TOOL-FAILURE`, `CROSSCHECK UNREVIEWED`, and `CROSSCHECK BLOCKING`.
Only `blocking` is a review verdict about code.

New findings must supply a helper under `.crosscheck/reproductions/`, a command naming that helper, an expected exit code, and a distinctive output marker.
Crosscheck executes the command itself and stores its actual exit and bounded output in the ledger.
Every verdict artifact must also carry one verdict-level reproduction whose command names the exact base and head SHAs.
The reviewer must create and run that helper with its own command tool, and the helper must leave a receipt naming both SHAs, `HOME`, and the provider account selector.
Crosscheck inspects that receipt before independently re-executing the helper, then stores the receipt digest and bounded content with the verdict.
A missing or failed verdict-level reproduction is a `tool-failure`, so a reading-only concern from a reviewer with a dead command tool can never become a blocking code verdict.
The gate's re-execution is deliberately independent: it re-runs the helper itself in the review checkout with no network and none of the reviewer's provider credentials or account environment.
Reviewer helpers must therefore be self-contained and must not require reviewer-only variables to be set, even though the receipt they write records `HOME` and the provider account selector.
That asymmetry is the trap this contract exists to name: a helper that reads those variables unguarded under `set -u` succeeds for the reviewer and fails for the gate.
Every evidence-execution refusal carries the command's own bounded output, because a bare unexpected exit reads as a substantive verdict about the code when it is often a failure to execute at all.
The post-review integrity check reads `git status --porcelain --untracked-files=normal`, not `--untracked-files=all`.
`normal` collapses the wholly untracked `.crosscheck/` tree into one status entry, so the check costs a fixed amount however much evidence the reviewer wrote.
With `all` the check's output scaled with the evidence, and a reviewer that substantiated a finding could exceed the bounded-output limit and have its whole review refused as `unreviewed` - the gate could block but never clear.
Detection is unchanged either way: a modified tracked file, an untracked file inside a tracked directory, and an unauthorized new directory are each still reported individually and still refused.
Authorized evidence therefore cannot reach the limit at all, and every shape that still can - loose untracked files, untracked files inside tracked directories, stray directories - is already an unauthorized state that the check refuses anyway.
That inspection carries its own larger budget so such a state is refused by name rather than as a bare output-limit error; overflow past it still refuses, and can never become a pass.

A `verified-fixed` update must name a tracked test and provide an implementation-only patch under `.crosscheck/mutations/`.
It supplies an approved test runner plus a structured argument array, never a free-form shell command.
Approval as a general test runner is not certification permission: `MUTATION_RUNNER_POLICIES` in `bin/fm-crosscheck.py` is the single declaration point for runners whose non-execution contract has been measured.
The currently measured certification runners are `pytest`, `jest`, and `vitest`.

An approved runner is a NAME, and the gate resolves that name into an invocation rather than assuming a bare binary on `PATH`.
`pytest` resolves through `uv run pytest`, then `python3 -m pytest`, then the bare binary, preserving the existing uv-aware behavior and native `path::selector` node ids.
Jest and Vitest run from the nearest package directory found by walking from the named test to the checkout root, so a nested monorepo package loads its own tracked configuration and package-relative imports.
For those Node runners the gate prefers an executable `node_modules/.bin/<runner>` in that package and then checks `PATH`.
The proof checkout contains tracked files only, so ordinary untracked `node_modules` dependencies are absent there unless the runner is otherwise available; an absent runner or a runner that starts without its required dependencies is `NON-EXECUTION`, never a pass or silent skip.

`test_path` may be a plain repository path or `path::selector` for a measured selector runner.
Pytest receives the full native node id.
Jest and Vitest receive the path before `::` as their sole file target and the part after `::` as a gate-owned `--testNamePattern` value, which can express the paired control and regression selector used by platform-v3's hand proof without admitting reviewer flags.
The exact gate-owned JavaScript invocations are `jest --json --runTestsByPath <path> [--testNamePattern <selector>]` and `vitest run --reporter=json <path> [--testNamePattern <selector>]`.
Both machine reports must contain at least one `passed` or `failed` assertion before the run counts as execution, and a nonzero mutated run must contain a failed assertion before it can certify the mutation.
A missing or malformed report, a runtime-error suite, an empty assertion list, an all-skipped or all-pending selector result, an inconsistent assertion count, a success/exit contradiction, and a nonzero exit with no failed assertion are all `NON-EXECUTION` and clear nothing.
This report contract is necessary because both measured JavaScript runners exit 0 when a test-name pattern matches no test.

The reviewer-supplied `test_invocation.arguments` array must remain empty for every mutation proof, and any entry is refused by name.
The classified contract belongs to the exact gate-owned invocation, and a supplied flag can rewrite it: measured on pytest 9.1.1, `--continue-on-collection-errors` turns an import-time non-execution from exit 2 into an ordinary exit 1.
A positional argument separately adds a second target, while `test_path` is the only target the gate validates as tracked, symlink-free, and unreachable by the mutation patch.
Requiring no reviewer arguments closes both routes without a runner-specific flag denylist.

Both proof runs execute under an environment constructed from `PROOF_ENVIRONMENT_ALLOWLIST` rather than the caller's environment.
That list is an allowlist because it fails closed: a missing required variable breaks the baseline, while an unlisted variable on a denylist would silently alter the measured runner contract.
The constructed environment applies to mutation proofs and not reproduction re-execution, because proof results can clear a finding while ambient interference with a reproduction can only force refusal.
Crosscheck writes neutral pytest, Jest, and Vitest configuration above the review and proof checkouts, ending upward config discovery inside the gate-owned root while allowing the reviewed repository's closer tracked configuration to win.
For a repository with no pytest config, the neutral boundary makes the temporary root pytest's rootdir and widens conftest discovery by one empty gate-owned directory.
A recorded proof whose invocation predates the empty-arguments rule still loads, but no longer clears its finding and can be re-proved in band.

Crosscheck creates one clean checkout at the exact reviewed head, confirms the named test passes, destroys the entire checkout, recreates the same path from the exact head, applies the patch, and requires the same test to fail.
Destroying all readable baseline state before the mutated run prevents a test from manufacturing causality through a predictable sibling checkout.
Proof sandboxes omit shared POSIX IPC and give each run private writable temporary and cache state, while shared host temporary directories remain outside the write policy.
The named test must be a canonical tracked regular file, and symlinks are rejected so a patch cannot mutate the executed target through an unchanged alias.
Symlink rejection is anchored at the resolved review checkout, so a symlink inside the repository is refused while a symlinked ancestor above the firstmate home is not mistaken for one.
The gate resolves the named runner before launch and reports an absent binary, a failed sandbox exec, a missing named test, and every measured runner non-execution explicitly as `NON-EXECUTION`.
For Jest and Vitest, the gate injects a runner-specific body probe and accepts a passed or failed assertion record only when the probe independently recorded entry into that exact selected test body.
For Jest, a sandboxed `--showConfig` preflight resolves the selected project's effective `setupFilesAfterEnv`, and the gate appends its probe after every tracked setup entry instead of replacing them.
For Vitest, the gate-owned config imports the discovered tracked `vitest.config.*` or `vite.config.*`, preserves its plugins, aliases, and test options, and overrides only the custom runner used for body evidence.
A failed `beforeAll` or `beforeEach` hook can create a failed assertion record without entering the test function, so it remains `NON-EXECUTION` and clears nothing.
Duplicate passed or failed full names are ambiguous and remain `NON-EXECUTION`, so one same-named body's marker can never satisfy another outcome.
That distinction applies to baseline and mutation runs alike because a run that never entered the selected test body can neither condemn the baseline nor vindicate the mutation.
A runner absent from `MUTATION_RUNNER_POLICIES` is refused even if it is generally approved, because guessing its non-execution signal would allow a forged clearance.
The patch may modify only non-test implementation paths already cited by the durable finding.
It cannot modify the named test, conventional test trees, fixtures, Jest/Vitest/Vite runner config, or Crosscheck evidence support.

### Adding a mutation-proof runner

Do not add a runner to `MUTATION_RUNNER_POLICIES` until its exact gate-owned invocation has an empirically distinguishable execution signal.
Use the real runner in a clean scratch package with one mutation-insensitive control test and one mutation-sensitive regression test.
Run the exact proposed argv with no reviewer arguments for seven cases: matched pass, matched assertion failure, unmatched selector, missing target, missing dependency during collection, conventional tracked configuration that fails at startup, and a selected test whose `beforeAll` or `beforeEach` hook fails before its body.
Record the runner version, date, exact commands, exit statuses, stdout, stderr, and body-probe report before encoding anything.
A future version whose output no longer satisfies the declared parser fails closed as `NON-EXECUTION`; do not loosen the parser until that version has been measured through the same matrix.
If a runner exposes no signal that distinguishes a failed assertion from failed startup or non-collection, it is not eligible for certification.

The JavaScript profile was measured on 2026-08-09 with Jest 29.7.0 and Vitest 4.1.5 using these exact command shapes.

```sh
jest --showConfig --json
jest --json --runTestsByPath /proof/regression.test.js --setupFilesAfterEnv /proof/tests/project-setup.cjs --setupFilesAfterEnv /gate/jest-body-probe.cjs --testNamePattern 'across chats resets state'
vitest run --reporter=json regression.test.js --config /gate/vitest-body-probe.config.mjs --testNamePattern 'across chats resets state'
```

The matched baseline exited 0 and recorded one passed selected assertion on both runners.
The assertion mutation exited 1 and recorded one failed selected assertion plus a matching body-start record on both runners.
An unmatched selector exited 0 on both runners, with Jest recording only `pending` assertions and Vitest recording only `skipped` assertions.
A missing target exited 1 with zero assertions, using a Jest runtime-error suite and an empty Vitest `testResults` array.
A missing imported dependency exited 1 with a failed suite and an empty `assertionResults` array on both runners, with Jest additionally reporting one runtime-error suite.
A conventional `jest.config.cjs` or `vitest.config.js` that threw during loading exited 1 and emitted no JSON stdout on either runner.
A tracked `setupFilesAfterEnv` or `setupFiles` entry that failed before the body remained active after probe injection and was classified as `NON-EXECUTION`.
A failed `beforeAll` or `beforeEach` hook recorded a failed assertion without a matching body-start record and was classified as `NON-EXECUTION`.
The gate-owned Vitest config merges the tracked project config and selects a probe that extends the runtime `TestRunner` export, and its real-runner integration must load both generated modules successfully before Vitest remains eligible for certification.
Those observed shapes are what the shared `jest-compatible-json` report policy and runner-specific body probes encode; exit status and assertion status are deliberately insufficient on their own.

To add a future runner, add one policy entry carrying its invocation ladder, gate-owned arguments, selector mode, project-root rule, report format, measured non-execution exits, and dated measurement string.
Add a parser only when the runner uses a genuinely new measured report format, and keep that parser selected by the policy rather than branching throughout the gate.
Add hermetic behavior coverage for every non-execution shape plus a real-runner end-to-end baseline-pass/control-pass/mutation-only-regression-fail certification before enabling the policy.

### Known limitation: pytest's mutated exit status is still an inference

Jest and Vitest now provide positive test-body execution evidence through gate-owned lifecycle probes paired with their measured machine reports.
Pytest still concludes that the named test detected the regression from the mutated nonzero exit after excluding its measured non-execution statuses.
That status is influenced by reviewer-supplied argv, ambient environment, repository and ancestor configuration, runner version, and installed plugins.
The positional-target rule, argument refusal, environment allowlist, and neutral ancestor config close known channels, but an installed plugin remains an accepted door and the list is hardening rather than a proof of soundness.

The planned pytest replacement is positive proof of execution rather than exit-code inference.
The leading candidate remains a control test that the mutation should not affect, required to pass while the named test fails.
Until that lands, pytest's exit-status inference remains this gate's weakest runner contract.

## Refusal and liveness

The reviewer is a synchronous Codex or Claude agent invocation with a bounded timeout and a JSON output schema.
Normal runs take minutes and callers should budget them as remote agent work rather than a cheap local preflight.
PR claims are delimited as untrusted data, and the reviewer is directed to ignore embedded instructions and use focused evidence rather than duplicate no-mistakes' broad suite.
Later reviewers receive only a bounded projection of finding IDs, lifecycle state, severity, exact-head clearance, and proof digests.
Finding prose, reproduction output, test output, and lifecycle notes remain durable in the ledger but are never reinjected into a later reviewer prompt.
The Codex path pins `gpt-5.6-sol`, xhigh reasoning, noninteractive approval, an independent `CODEX_HOME`, the same account-bound `HOME`, and the exact review checkout.
The Claude path pins `claude-opus-5`, xhigh effort, the installed unattended `--dangerously-skip-permissions` mode, a Bash-required bounded tool list, no session persistence, an independent `CLAUDE_CONFIG_DIR`, the same `CLAUDE_SECURESTORAGE_CONFIG_DIR`, a disposable private `HOME`, and structured JSON output.
That private `HOME` maps `.claude` and `.claude.json` to the selected reviewer account directory, so Claude's hard-coded `~/.claude/session-env` writes land in per-account state rather than shared operator state.
It also maps the current user's Keychain directory, derives Claude's exact scoped service from the selected account directory, and verifies the non-secret service metadata before reviewer launch.
That mapping is unconditional on macOS, not a fallback for accounts that lack an OAuth file.
macOS resolves a Keychain search through `$HOME/Library/Keychains`, so under a private `HOME` an unmapped Keychain is simply unreachable, and a real account directory routinely holds both a live scoped Keychain item and a stale `.credentials.json` left beside it.
Mapping the Keychain only when `.credentials.json` was absent therefore sent every such reviewer to the stale file, where it failed with `Failed to authenticate: OAuth session expired and could not be refreshed` in one turn, with no tokens and no API time, while the same account worked normally outside the gate.
The scoped Keychain item is preferred when it exists, because it is the credential the launched reviewer actually executes as; a regular non-symlink `.credentials.json` remains the recorded source only when no scoped item is present.
This is a binding inside the reviewer's own private `HOME`, not a sandbox grant: the generated profile is unchanged, and reads of the operator's Keychain directory were already permitted by it.
Because Claude's unattended mode disables its own permission prompts, Crosscheck places the process under the installed macOS `sandbox-exec` contract: reads, process execution, and provider network access remain available, while writes are limited to the disposable review checkout, the selected per-account reviewer directory, and `/dev/null`.
The profile never grants the ambient operator `~/.claude` tree or its session scratch subtree.
Claude's Bash engine otherwise creates workspace scratch under shared `/tmp/claude-<uid>` independently of ordinary `TMPDIR`.
Crosscheck sets the supported `CLAUDE_CODE_TMPDIR` to a private directory inside the disposable checkout, keeping that scratch under the existing checkout write boundary instead of widening the sandbox to shared `/tmp`.
It does not grant write access to the author worktree or the wider filesystem.
An unavailable reviewer binary, sandbox, author-identity proof, executing-account binding, verdict-level execution proof, or exact remote PR head records a `tool-failure` attempt when the live head is already known, and otherwise emits the same tool-failure class without fabricating a ledger run.
A ledger that cannot be read is the one stop that cannot record itself: appending a run to a file that failed to parse would risk destroying the durable findings it still holds, so the ledger is left exactly as it is and only the readable `crosscheck.md` report is rewritten, naming the parse failure so the cause is on disk rather than only in the exit status of a run nobody kept.
A reviewer that never reached its provider is also a `tool-failure` rather than an `unreviewed` attempt, and is the case that fails over.
The two are distinguished by evidence of model work: a Claude result envelope with no API duration, no token usage, and no per-model usage, or a Codex exit that wrote no result artifact at all, means the account never spoke and the gate learned nothing about the code.
Recording that as `unreviewed` also manufactured a suspicion in the ledger, which reads like the reviewer raised a concern about the change when it had not started.
Failure banners quote what the reviewer actually reported - for Claude the envelope's `result`, `subtype`, `terminal_reason`, `api_error_status`, and any permission denials, plus captured stderr - rather than a fixed-length excerpt of the raw envelope, because the sentence that explains a failure sits past the point such an excerpt stops.
A timeout, or a reviewer that reached the model and then produced a missing, empty, malformed, or wrong-head artifact, records an `unreviewed` attempt and exits nonzero.
An unresolved suspicion comes from a completed reviewer and records a `blocking` attempt instead of being conflated with an invalid review artifact.
This includes provider refusals that surface only as a stopped or silent agent.
`bin/fm-crosscheck.sh` refuses earlier than any of these when it cannot resolve a Python 3.11 or newer interpreter for `fm-crosscheck.py`: it prints a `CROSSCHECK UNREVIEWED` banner naming the requested and discovered versions, exits nonzero, and records no ledger run because nothing about the PR was examined.
That fail-closed banner keeps an interpreter defect from reading as a clear review; interpreter discovery order and the `FM_CROSSCHECK_PYTHON` override are owned by [configuration.md](configuration.md#toolchain).
Reviewer stdout plus stderr use a separate 16 MiB capture ceiling because a full agent transcript routinely exceeds the ordinary command budget.
`FM_CROSSCHECK_REVIEWER_MAX_CAPTURE_BYTES` can override that ceiling between 200,000 bytes and 64 MiB, and an invalid value fails closed before reviewer launch.
This remains a hard bound rather than truncation: Claude returns its structured verdict in the captured JSON envelope, while Codex must still provide its separate authoritative result artifact.
Crossing the reviewer ceiling terminates the owned process tree and records a loud `unreviewed` attempt, and captured output alone never substitutes for a valid verdict.
Evidence and every other ordinary command retain the 200,000-byte aggregate stdout-plus-stderr ceiling, except the post-review checkout integrity inspection described above, which carries its own 4 MiB budget.
The final wait and identity-pinned descendant cleanup remain inside the same absolute deadline.
Structured verdict artifacts are stable regular files bounded by the ordinary 200,000-byte ceiling before JSON decoding.
The durable ledger is bounded separately and fails closed when absent, symlinked, malformed, non-finite, or oversized.
The platform-specific containment limits and empirical mutation evidence are recorded in [crosscheck-bounded-io.md](crosscheck-bounded-io.md).
Reviewer result arrays are capped at 32 entries, at most 32 evidence executions are accepted, and all reproduction and mutation work shares a 900-second aggregate deadline by default.

## Installed external contracts

The external surface was observed on 2026-08-02 before implementation, rechecked on 2026-08-03 for nonempty TOON arrays, and re-run against installed `gh-axi 0.1.25` on 2026-08-04.
The current recheck observed `gh-axi 0.1.25`, `codex-cli 0.146.0-alpha.9.2`, and Claude Code 2.1.221; the original Claude contract was first exercised on 2.1.220.

`gh-axi pr view` supports `--full` but does not support raw-gh `--json` or `-q` flags.
The production adapter therefore uses these exact forms.

```sh
gh-axi api /repos/<owner>/<repo>/pulls/<number>
gh-axi pr view <number> --repo <owner>/<repo> --full
gh-axi api PUT /repos/<owner>/<repo>/pulls/<number>/merge \
  --field sha=<reviewed-40-hex-sha> \
  --field merge_method=<merge|squash|rebase>
```

The checked-in TOON fixtures under `tests/fixtures/gh-axi-v0.1.25-*.toon` are reduced from those observed documents.
Every GitHub fake rejects command forms outside this surface.
The `labels[1]{id,name,color,default,description}:` table in the PR API fixture was observed from installed `gh-axi 0.1.25` with `gh-axi api /repos/lance-format/lance/pulls/8166` on 2026-08-03.
The 2026-08-04 recheck used `gh-axi api /repos/ruby-dlee/firstmate/pulls/72` and observed head `c9cbe79154013efcec9aa478f1476d0eff6c63df`, base `68f014697d0eea733a4e7c0294becff4e76c7bcf`, and `merged: true` in the installed TOON shape.
It also confirmed from `gh-axi pr view --help` that view still accepts only `--comments`, `--reviews`, and `--full`, while `gh-axi api --help` still accepts `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, and `HEAD` with repeated `--field` values.
The merge form with optional `commit_title` and `commit_message` fields was separately exercised against an already-merged PR and returned the observed successful no-op response.
The read adapter exposes no merge subcommand; only the gate-refused `fm-crosscheck.sh merge` boundary can reach its private exact-SHA merge primitive, and that boundary freshly verifies the ledger before issuing the request.

The installed reviewer invocation was exercised successfully with `--output-schema`, `--output-last-message`, `--model gpt-5.6-sol`, and `model_reasoning_effort="xhigh"` before production code used those flags.
The installed Claude invocation was exercised successfully with a private `HOME`, selected-account `CLAUDE_CONFIG_DIR` and `CLAUDE_SECURESTORAGE_CONFIG_DIR`, `--model claude-opus-5`, `--effort xhigh`, `--dangerously-skip-permissions`, `--tools Bash,Read,Glob,Grep`, `--no-session-persistence`, `--output-format json`, and `--json-schema` before production code used those flags.
The installed `/usr/bin/sandbox-exec` was also exercised with the generated profile: a write inside the allowed review directory succeeded, while sibling and `/private/tmp` writes failed with `Operation not permitted`.

## Validation evidence boundaries

`tests/fm-github-pr.test.sh` is hermetic coverage using checked-in TOON shapes observed from installed `gh-axi 0.1.25`.
Most of `tests/fm-crosscheck.test.sh` is hermetic coverage using observed-shape GitHub, Codex, Claude, and sandbox fakes.
Its `test_installed_sandbox_denies_shared_private_tmp` case is the exception: it invokes the real installed `/usr/bin/sandbox-exec` and verifies the generated proof profile denies shared host temporary state.
Its tracked `test_real_claude_sandbox_executes_exact_sha_git_diff` case is an opt-in real-runtime guard: with `FM_TEST_REAL_CLAUDE_SANDBOX_GIT_DIFF=1` and `FM_TEST_REAL_CLAUDE_CONFIG_DIR` set to a credentialed independent Claude home, it creates the same private execution `HOME`, verifies the selected OAuth-file or scoped-Keychain source, launches installed Claude under the generated installed sandbox, requires Bash to execute `git diff` between two real exact SHAs, checks the selected config paths and isolated `CLAUDE_CODE_TMPDIR`, and rejects any profile grant for the ambient operator `~/.claude/session-env`.
Ordinary CI prints a named skip for this network- and credential-dependent guard instead of substituting fake-only coverage.
The retained live runtime proof is the change receipt for this patch; the opt-in test is the repeatable regression guard for future environments.
Its `test_pytest_runner_resolves_through_a_uv_aware_ladder` case is the named regression for runner-name resolution: it pins monorepo uv-project discovery, the skipped uv rung outside a project, the unchanged absent-runner refusal, and pytest's retained node-id support.
Its `test_javascript_runner_policy_is_declared_once` case pins the nearest-package working directory, exact gate-owned Jest and Vitest arguments, selector translation, neutral ancestor configs, and single policy registry.
Its `test_javascript_runners_certify_platform_shaped_mutation_proofs` case executes end-to-end Jest and Vitest proofs where the control passes in both runs and the regression fails only after mutation.
Its real Jest and Vitest integration cases retain tracked setup, aliases, and plugins while injecting body evidence, then require a tracked mutation-only startup failure to remain `NON-EXECUTION`.
Its `test_javascript_non_executions_clear_nothing` case executes the measured unmatched-selector, startup-failure, missing-dependency, and missing-test shapes and requires every one to retain the open finding.
Its `test_account_less_known_provider_lane_is_reviewable` case is the named regression for account-less lanes: it drives a Pi lane with no `account_home` and a slot-qualified model, requires a cross-provider reviewer to clear it, and requires a same-provider reviewer to be refused.
Its `test_claude_execution_home_always_binds_the_keychain` case is the named regression for the private-`HOME` Keychain bind, and it fails if the bind is made conditional on `.credentials.json` again.
Its `test_moved_default_branch_stays_reviewable` case is the named regression for base drift: it advances the fake default branch past the PR's branch point, then requires the run to review against the merge base, record it, and still verify.
Its `test_unavailable_reviewer_fails_over_to_the_next_account` case covers reviewer failover using the observed zero-turn Claude error envelope, and asserts the ledger records the abandoned attempt with the reason the reviewer reported rather than a truncated envelope.
Its `test_forged_git_diff_mutation_command_is_rejected` case is the named regression that fails if a free-form `git diff --quiet # tests/regression.test.sh` can replace real mutation verification.
Its `test_baseline_readable_state_is_destroyed_before_mutation` and `test_mutation_is_bound_to_cited_non_test_implementation` cases cover the two mutation-causality bypasses found in the final review round.
Its `test_mutated_non_execution_cannot_clear_a_finding` case covers the third bypass of that class: a mutation that only broke test collection exits nonzero and previously read as a caught regression, so the gate could certify a fix on a test that never ran.
Its `test_evidence_capture_runs_on_older_interpreters` case exists because `fm-crosscheck.sh` execs whichever `python3` is first on `PATH`, which is not always the version CI pins.
A newer-only API on the evidence path therefore surfaces as an uncaught `TypeError` inside evidence capture rather than a gate verdict; the [`firstmate-coding-guidelines`](../.agents/skills/firstmate-coding-guidelines/SKILL.md) skill owns which `stat` form `bin/*.py` must use.
`tests/fm-github-pr.test.sh` includes named cases for fieldless-array grammar, complete timeout-child cleanup, and refusal of the former public merge subcommand.
The focused PR-check cases in `tests/fm-teardown-suite.sh` and the merge cases in `tests/fm-pr-merge.test.sh` also use observed-shape GitHub fakes.
Those deterministic suites validate parsing, lifecycle, failure handling, and atomic request construction; they do not claim to exercise live provider availability.
The real installed-tool exercise is separate and network-dependent: the dated `gh-axi` observations above cover successful documents, while an adapter lookup for an absent PR through installed `gh-axi` must exit nonzero with `GitHub state is unreviewed`.

## Deliberate limitations

Crosscheck supports immediate `merge`, `squash`, and `rebase` methods plus commit title and body fields.
It rejects `--auto` because an asynchronous merge would escape the immediate expected-head request.
It rejects `--delete-branch` because branch deletion is not part of the atomic merge operation.
Delete a branch only in a later separately authorized action after the merge is confirmed.

Reviewer-generated commands execute in a non-login shell, so evidence never depends on the operator's shell profile.
This is not a detail: a login shell runs macOS `path_helper`, which rebuilds `PATH` with `/usr/bin` ahead of everything else, so a bare `python3` in a reproduction resolved to Xcode's Python 3.9 even while the gate itself ran on 3.14.
Any reproduction against a repository requiring 3.10 or newer then died on an unrelated `ImportError`, and because a failed new-finding reproduction voids the run, a complete review with real findings was recorded as `unreviewed`.
Approved mutation-proof runners are resolved from the gate's own `PATH` and were never affected.

Reviewer-generated commands execute in disposable exact-head clones with bounded timeouts.
Codex uses its installed workspace-write sandbox, and Claude uses the explicit macOS profile described above.
Both permit test processes and provider network access, so this is containment for accidental or prompt-directed file mutation, not a guarantee that hostile repository code is safe to execute.
