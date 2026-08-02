# Adversarial PR Review Lane

This lane replaces Cursor Bugbot as Firstmate's fifth merge property.
It is owned by `bin/fm-adversarial-pr-review.sh`.

## Contract

`bin/fm-pr-check.sh <task-id> <pr-url>` records `pr=` and `pr_head=`, then runs an independent adversarial review before arming the merge poll.
`bin/fm-pr-merge.sh <task-id> <pr-url>` re-runs the PR check path and then verifies the adversarial verdict before invoking `gh-axi pr merge`.
The merge helper refuses unless the current GitHub PR head equals the recorded `adversarial_review_head=` and the latest `adversarial_review_verdict=` is `CLEAN`.
That makes a pushed fix round invalidate the prior verdict automatically.

The report lives at `data/<task-id>/adversarial-review.md`.
It records the PR URL, base ref, merge-base SHA, exact head SHA, verdict, reviewer harness, reviewer account home, author harness/account metadata, and the isolation proof.
The metadata file records the latest verdict fields so the merge bar can read them cheaply:

```text
adversarial_review_head=<sha>
adversarial_review_verdict=<CLEAN|BLOCKING>
adversarial_review_report=<path>
adversarial_review_reviewer_harness=<harness>
adversarial_review_reviewer_account_home=<path>
```

Reviewer failure, missing account selection, missing isolation proof, malformed output, and a blocking finding are all non-clean outcomes.
An unavailable reviewer is recorded as no verdict in the report and never as a pass.

## Reviewer Prompt

The reviewer is told to refute the PR claims rather than confirm them.
The prompt targets the classes proven valuable in `data/bugbot-value-analysis-v2/report.md`: business/domain logic, concurrency and idempotency, environment/config/deploy mismatch, observability false assurance, test-harness validity, and tooling/CI guard holes.
The output contract is intentionally small:

```text
VERDICT: BLOCKING
FINDINGS:
- path/to/file:123: [category] concise title - concrete failure mode and why it blocks merge.
```

or:

```text
VERDICT: CLEAN
FINDINGS:
- none
```

A blocking verdict without at least one file:line citation is treated as no verdict.

## Isolation

The lane selects a direct account-directory reviewer account and records the non-secret account home.
It prefers a different harness from the author when possible.
If it must use the same harness, it requires a different recorded account home or a legacy author profile that proves the author identity is not the selected reviewer home.
If the author identity is too vague to prove separation, the lane refuses.

This is deliberately stricter than ordinary "run another model" review.
The failure mode being guarded is self-review bias, so the proof is about account identity first and model choice second.

## Alternatives

Cursor Bugbot is now structurally usage-priced.
Cursor's own Bugbot change notice says Teams bill Bugbot from on-demand spend, and it gives an average run cost of about $1.00-$1.50 depending on PR size and complexity: <https://cursor.com/blog/may-2026-bugbot-changes>.
Cursor's pricing page also lists Bugbot as usage-based for paid plans: <https://cursor.com/pricing>.
That shape scales with review count, so fleet throughput directly increases spend.

CodeRabbit is a hosted AI review vendor with subscription and credit controls rather than a pure per-PR invoice shape.
Its pricing page describes unlimited PR/CLI reviews on paid plans plus usage-based add-ons and credit purchasing: <https://www.coderabbit.ai/pricing>.
It can reduce marginal PR-review anxiety, but it still leaves vendor lock-in and does not prove independent account isolation from the authoring agent.

GitHub Copilot code review is seat-priced for Copilot plans, with code-review model costs handled through GitHub's AI-credit system.
GitHub documents Copilot plan prices and says code review is included in paid plans: <https://docs.github.com/en/copilot/get-started/plans>.
GitHub also documents that Copilot code review auto-selects an undisclosed model, so per-token cost can vary: <https://docs.github.com/copilot/reference/copilot-billing/models-and-pricing>.
The cost shape is mostly per-seat plus shared AI credits, not per PR, but it is still an external black-box reviewer.

Graphite's Diamond/AI Reviews product is another hosted reviewer.
Its public product page emphasizes PR review but does not make a simple public per-PR price the primary shape: <https://graphite.com/features/ai-reviews>.
Treat it as a seat/custom hosted vendor until a current quote proves otherwise.

Semgrep and CodeQL-class tools are valuable but not substitutes for this lane.
Semgrep sells AppSec scanning by contributor and product bundle, starting from contributor-priced plans: <https://semgrep.dev/pricing>.
GitHub Code Security/CodeQL is also active-committer priced for private-org advanced security features, while public repository code scanning is free: <https://github.com/security/plans> and <https://docs.github.com/en/billing/concepts/product-billing/github-advanced-security>.
These tools are excellent at known vulnerability classes, custom rules, variant analysis, secrets, dependency issues, and policy checks.
They do not generally understand a merchant erasure flow, a fleet teardown invariant, or an observability claim unless someone first encodes that invariant as a rule or query.

## Residual Risk

This lane is still semantic AI review, not a proof system.
It can miss novel business-logic or state-machine defects, just as no-mistakes review missed Relvino PR #857's stashed-email-hash erasure defect before Bugbot caught it.
The accepted residual risk is broad novel semantic review of code paths whose invariants have not yet been converted into deterministic tests, Semgrep rules, CodeQL queries, or repo-specific validators.
When the lane finds a real issue, the follow-up is to backfill a deterministic guard where practical, not to rely on the reviewer remembering the same class next time.
