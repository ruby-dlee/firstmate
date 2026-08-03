# Structural hardening gates

This document records the six gates added after the 2026-08-01 supervision failures.

Every claimed gate names its covered route, mechanical trigger, deterministic predicate, and failure mode.

An instruction-only boundary is labelled as such instead of being presented as a hard gate.

## Gate A: Codex dispatch and runtime profile

Covered route: every verified `harness=codex` launch through `bin/fm-spawn.sh` and every recorded Codex task inspected by the watcher.

Mechanical trigger: spawn admission runs before endpoint creation, and the watcher invokes `bin/fm-runtime-profile.sh` every five minutes.

Each new Codex task generation also lacks a runtime receipt by construction, so the already-required live watcher verifies its harness record immediately after start, with a sixty-second startup grace only for rollout publication.

Deterministic predicate: the only admitted profile is `model=gpt-5.6-sol effort=xhigh`, and the latest matching Codex `turn_context` or `thread_settings_applied` rollout record from the recorded provider session and runtime start must contain those exact values.

The launch record persists the exact runtime home used by direct selection or the Agent Fleet profile, and the verifier never falls back to its own ambient Codex home.

Recovery re-resolves the current harness, model, and effort policy instead of replaying their recorded metadata values.

When natural-language dispatch rules are active, recovery mechanically requires the caller to pass the freshly selected concrete harness profile because shell code cannot re-evaluate those rules.

A native same-session recovery proceeds only when its recorded provider still equals current harness policy; otherwise it refuses and requires an explicit continuation profile.

Failure mode: a below-policy spawn exits before endpoint creation, and a runtime mismatch or unreadable runtime record wakes supervision.

An opaque raw custom executable remains outside the verified Codex adapter contract because its transitive behavior cannot be inspected deterministically.

Codex account routing does not consume quota-axi telemetry as either an eligibility or refusal signal because measured fixtures proved it wrong in both directions.

Those fixtures make the telemetry permanently contested, not just stale; it never becomes a routing predicate, and an expired ground-truth proof always requires a fresh codex completion probe.

The deterministic capacity predicate is successful completion of a tiny ephemeral exact-profile `codex exec` probe under the account home.

Positive proofs are cached for thirty minutes and unavailable probes for one minute; the former bounds healthy-account probe cost to two per hour, while the latter avoids a spawn loop hammering an exhausted or unauthenticated account.

If the probe command is missing, times out, refuses, fails authentication, or returns no exact sentinel, that account is unavailable; no positive account proof fails spawn closed.

Pane activity and pipeline liveness are never capacity evidence.

Account config pins and explicit launch flags preserve the `refuse loudly rather than degrade silently` invariant for future launches, but they do not retroactively repair a session that already substituted its model; that session remains mismatched until relaunched.

## Gate B: Steering delivery

Gate B is not shipped by this lane after the ownership split.

Finding F16 remains open: sibling pane adapters can change from an agent session to a bare shell between text entry and Enter, so the checked session and the acted-on session are not atomic.

The affected production path `bin/fm-send.sh` and its behavioral fixture `tests/fm-send-strict.test.sh` were released to lane `steer-enter-accepts-open-modal` at commit `acbd0908` and are not modified again here.

That owner must make session identity, text entry, and submission indivisible against agent exit or refuse the route, while preserving verified future atomic-backend success.

Until that lane lands and demonstrates a real session-transition violation being caught, text delivery retains a stated route-completeness gap rather than a clean gate claim.

## Gate C: Positive-only run liveness and destructive-run custody

Covered route: every run-step-based `working` classification shared by the watcher and away-mode supervisor.

Mechanical trigger: `crew_absorb_class` invokes `bin/fm-run-liveness.sh` before a running status can be absorbed, and the watcher repeats the same sampler when the repository-derived recheck cadence expires.

The sampler rejects scouts, detached worktrees, non-task branches, and branch-blind status answers before sampling; it re-reads the selected run by exact run ID and requires that response to carry the task branch.

Before interpreting the window, it mechanically records contemporaneous `uptime` and `vm_stat` output through `bin/fm-host-pressure.sh`.

Deterministic liveness predicate: seven untruncated, exact-run process-table samples span sixty seconds by default; the sampler excludes its own process family, attributes exact-path process roots, follows their descendants, and any sample with a run-owned process proves `BUSY`; every result without affirmative evidence is `UNKNOWN`, never `IDLE`, dead, or wedged.

CPU totals and cumulative CPU delta are recorded as evidence but never override the asymmetric process predicate.

This positive-only formulation is required and no longer a tunable preference.

Sixteen consecutive zero samples across two minutes were observed on a provably healthy run.

Natural subprocess sawtooth behavior is one measured explanation.

Host load was separately measured at 21-30, later 60, and a peak of 88 before an xdist cap returned it to 21; under 60-88 load, descheduling that widens observable process gaps is a well-supported mechanism.

It is not established as the cause of the particular sixteen-sample gaps because those sampling windows were not correlated to those load spikes.

That epistemic label is part of the gate: a well-supported mechanism must not be persisted as a proven incident cause.

The implementation does not need to decide between them: if the observable gap has no proved upper bound, no fixed sampling window at any length can establish absence.

The stronger host-load evidence strengthens the conclusion that no threshold exists; it does not license tuning a longer window.

The governing principle is `absence of evidence is not evidence of absence`.

Inferring idle from an empty process sample is the same invalid predicate shape as treating a missing consent row as permission, confusing never-acquired with released custody, or reading an empty reviewer result as clean; all four failure classes occurred in this fleet.

No daemon-side heartbeat or other load-independent affirmative run-liveness signal is currently exposed.

Lifecycle `status` and `updated_at` values remain records rather than heartbeats and are not relabelled as one.

If an independently verified load-independent signal becomes available, it should precede process sampling as affirmative evidence without changing the UNKNOWN result for absence.

Failure mode: an all-zero window, changed or cross-branch run record, unreadable status, or failed process sample is surfaced as UNKNOWN and routes only to the non-destructive alternative.

Nothing reachable from absence authorizes cancellation, restart, replacement, or teardown.

Finding F12 remains open for destructive custody: an independent no-mistakes writer can advance a run after proof but before an abort addressed only by run ID, so the proof and irreversible act are not atomic against run-head transition.

The affected production path `bin/fm-auto-reap.sh` and behavioral fixture `tests/fm-auto-reap.test.sh` were released to lane `autoreap-cancels-before-containment` at commit `acbd0908` and are not modified again here.

That owner must make expected run, head, generation, and abort indivisible against every run-head writer and demonstrate the concurrent transition being rejected.

Until that lane lands, automatic cancellation is a stated gap and is not counted as part of the shipped Gate C liveness control.

Destructive run-control instructions remain a carried two-sided boundary outside the automatic reaper, not a structural gate: the sender must identify the exact run ID and branch, include authoritative proof that the target is dead, and prove current head equals pushed head; a receiving lane must independently verify every property before acting, whether or not the instruction claims proof.

Process absence at any sampled window is explicitly not acceptable proof.

Free-form instructions and arbitrary shell commands have no route-complete deterministic intercept in the current architecture, so this change does not mislabel that carrier as a hard gate.

Likewise, the automatic liveness route records host pressure before its diagnosis, while a free-form claim that repeated agent death, a daemon socket timeout, or a test flake is a code defect cannot be structurally intercepted today.

Generated briefs therefore require contemporaneous `bin/fm-host-pressure.sh` evidence for such a claim, but that prose route remains an explicitly stated carrier gap.

Recent completed `test` durations are selected by the same no-mistakes repository id, and the median controls recheck cadence.

Another repository's durations never enter the query.

## Gate D: One-shot merge

Covered route: `bin/fm-pr-merge.sh`, the canonical Firstmate PR merge entrypoint.

Mechanical trigger: the script rejects scheduling flags before any GitHub call, acquires the task lifecycle and shared checkout locks, proves the exact endpoint absent, runs synchronous admission, repeats local and remote identity checks, and calls GitHub's merge REST endpoint with the admitted `sha` value.

Deterministic predicate: `--auto`, queueing, admin, and delete-after flags are forbidden; protected-branch required checks must be strict and nonempty; stale reviews must be dismissed; code-owner and last-push approval must be required; at least two approvals and admin enforcement must apply; and the REST merge succeeds only if the current PR head still equals the admitted head and GitHub still accepts every native policy predicate.

Failure mode: any endpoint uncertainty, task generation movement, head or base movement, worktree residual, mutable check or review violation, policy weakening, or merge refusal exits nonzero and no merge remains armed.

`bin/fm-pr-check.sh` now records only PR metadata and never creates or overwrites `state/<id>.check.sh`.

Raw GitHub clients are outside this repository entrypoint, so the standing operating contract still forbids bypassing `fm-pr-merge.sh`.

## Gate E: Blocker discipline gap

This requested gate cannot meet the structural bar in the current architecture.

The blocker routes include free-form supervisor prose and direct append-only writes to `state/<id>.status`.

There is no single interceptable operation and no deterministic parser can prove that an unstated premise was identified and tested.

A helper or prose checklist would be an intentional-trigger control with ordinary bypass routes, so this change does not ship one and does not label instruction text as a gate.

The failure mode remains explicit: a supervisor can still invent a blocker unless blocker reporting is moved behind a structured, mandatory transport carrying `assumption`, `test`, and `result` fields.

That transport is a separate owner-level architecture change.

## Gate F: Exact-head merge evidence

Covered route: every merge execution through `bin/fm-pr-merge.sh`.

Mechanical trigger: synchronous `bin/fm-pr-admit.sh` runs immediately before the atomic exact-head merge call.

Deterministic predicate: one unchanged head, base, and base ref must have a nonempty green and settled check set; two distinct non-author exact-head `APPROVED` review verdicts with no exact-head change request; exact local and PR head equality; an identical GitHub-file and local base-to-head file set; and a mechanically clean index and worktree including untracked paths.

Files, check runs, and reviews are fetched as explicit bounded pages and combined only after every page is structurally validated and its reported count reconciles.

Independent adversarial review is represented by a current exact-head code-owner approval under protected-branch stale-review dismissal and last-push approval, rather than by mutable spelling in a review body.

A reviewer that stopped without submitting an exact-head `APPROVED` review contributes no verdict and the head is `UNREVIEWED`.

Admission does not publish a sticky client-side success status because same-head review and check state can change afterward.

GitHub's strict required-check and protected-review rules remain the authoritative mutable predicate at the atomic server merge boundary.

The task endpoint is quiesced and task lifecycle plus checkout custody stays held from before admission through the merge request, with a second tracked, staged, and untracked residual check immediately before that request.

Failure mode: any absent, pending, failed, stale, truncated, moved, dirty, unprotected, or contradictory property exits nonzero before the merge endpoint is called.

Free-form recommendations remain prose and cannot be made route-complete by this repository without the structured reporting transport described under Gate E.

The merge executor itself never treats CI colour as sufficient.

## Mutation evidence ledger

Each shipped gate below mutates the production representation, invokes the production observing path, proves deterministic refusal, removes the violation, and observes the repaired outcome.

Gate E is listed as an evidenced gap because its real carrier accepts the violation instead of rejecting it.

- Gate A scope is one recorded Codex generation, the behavioral representation is a later wrong `thread_settings_applied` record, the observing layer is `bin/fm-runtime-profile.sh`, the reachable production path is `fm-codex-runtime-profile.mjs`, deterministic failure is exit 1 with the observed wrong axes, and retirement is a later exact-profile runtime record that verifies in `tests/fm-runtime-profile.test.sh`.
- Gate B has no shipped mutation proof in this lane because F16 and its released `bin/fm-send.sh` boundary are owned by `steer-enter-accepts-open-modal`; retirement requires that lane to inject an agent-to-shell transition between entry and submission and prove atomic delivery or refusal.
- Gate C liveness scope is exact-run diagnosis, the behavioral representation is an all-zero real sampler window, the observing layer is `bin/fm-run-liveness.sh`, the reachable path is the run-owned sampler, deterministic failure is UNKNOWN, and retirement supplies an affirmative owned process in `tests/fm-run-liveness.test.sh`.
- Gate C destructive custody has no shipped mutation proof in this lane because F12 and its released `bin/fm-auto-reap.sh` boundary are owned by `autoreap-cancels-before-containment`; retirement requires that lane to race a real run-head transition against abort and prove the transition or abort is rejected atomically.
- Gate D scope is one PR head and base combination, the behavioral representation is `strict: false` on the real protected-branch policy response, the observing layer is `bin/fm-pr-merge.sh`, the reachable production symbol is `fm_pr_require_server_admission_rule`, deterministic failure occurs before the merge endpoint, and retirement restores strict policy and permits the exact-head request in `tests/fm-pr-merge.test.sh`.
- Gate E scope is the append-only task status carrier, the behavioral representation is an invented `blocked [key=premise]:` event with no assumption test, the observing layer is the shared watcher classifier, the reachable production symbols are `status_is_captain_relevant` and `status_open_decisions`, deterministic evidence is that the carrier accepts rather than rejects it, and retirement requires an explicit `resolved` event in `tests/fm-blocker-discipline-gap.test.sh`.
- Gate E remains unshipped until a mandatory structured blocker transport rejects missing `assumption`, `test`, and `result` fields, at which point the mutation test must flip from demonstrating acceptance to demonstrating refusal.
- Gate F scope is one exact-head independent-review and worktree evidence set, the behavioral representations are a dismissed same-head code-owner approval and a late real untracked file, the observing layers are GitHub's protected merge endpoint and the final local custody check, the reachable production paths are `fm-pr-admit.sh` and `fm-pr-merge.sh`, deterministic failures are server rejection or refusal before PUT, and retirement restores the review and removes the residual before the successful exact-head request in `tests/fm-pr-merge.test.sh`.
