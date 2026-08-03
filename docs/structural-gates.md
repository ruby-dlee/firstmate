# Structural hardening gates

This document records the six gates added after the 2026-08-01 supervision failures.

Every claimed gate names its covered route, mechanical trigger, deterministic predicate, and failure mode.

An instruction-only boundary is labelled as such instead of being presented as a hard gate.

## Gate A: Codex dispatch and runtime profile

Covered route: every verified `harness=codex` launch through `bin/fm-spawn.sh`, every direct-account Codex steer through `bin/fm-send.sh`, and every recorded Codex task inspected by the watcher.

Mechanical trigger: spawn admission runs before endpoint creation, attempted direct-account text steering verifies before backend admission, and the watcher invokes `bin/fm-runtime-profile.sh` every five minutes.

Each new Codex task generation also lacks a runtime receipt by construction, so the already-required live watcher verifies its harness record immediately after start, with a sixty-second startup grace only for rollout publication.

Deterministic predicate: the only admitted profile is `model=gpt-5.6-sol effort=xhigh`, and the latest matching Codex `turn_context` or `thread_settings_applied` rollout record from the recorded provider session and runtime start must contain those exact values.

The launch record persists the exact runtime home used by direct selection or the Agent Fleet profile, and the verifier never falls back to its own ambient Codex home.

Recovery re-resolves the current harness, model, and effort policy instead of replaying their recorded metadata values.

When natural-language dispatch rules are active, recovery mechanically requires the caller to pass the freshly selected concrete harness profile because shell code cannot re-evaluate those rules.

A native same-session recovery proceeds only when its recorded provider still equals current harness policy; otherwise it refuses and requires an explicit continuation profile.

Failure mode: a below-policy spawn exits before endpoint creation; a runtime mismatch or unreadable runtime record wakes supervision; a direct-account steer exits nonzero.

Text steering refuses on Herdr and every pane-backed adapter because none exposes one atomic operation bound to an expected agent session that both writes and submits the instruction.

Native Herdr `agent send` writes literal input but does not submit it, so it cannot satisfy this boundary for any harness.

An opaque raw custom executable remains outside the verified Codex adapter contract because its transitive behavior cannot be inspected deterministically.

Codex account routing does not consume quota-axi telemetry as either an eligibility or refusal signal because measured fixtures proved it wrong in both directions.

Those fixtures make the telemetry permanently contested, not just stale; it never becomes a routing predicate, and an expired ground-truth proof always requires a fresh codex completion probe.

The deterministic capacity predicate is successful completion of a tiny ephemeral exact-profile `codex exec` probe under the account home.

Positive proofs are cached for thirty minutes and unavailable probes for one minute; the former bounds healthy-account probe cost to two per hour, while the latter avoids a spawn loop hammering an exhausted or unauthenticated account.

If the probe command is missing, times out, refuses, fails authentication, or returns no exact sentinel, that account is unavailable; no positive account proof fails spawn closed.

Pane activity and pipeline liveness are never capacity evidence.

Account config pins and explicit launch flags preserve the `refuse loudly rather than degrade silently` invariant for future launches, but they do not retroactively repair a session that already substituted its model; that session remains mismatched until relaunched.

## Gate B: Steering delivery

Status: unshipped stated gap, with a production hard-stop protecting the away-mode supervisor route.

Gate B is not shipped by this lane after the ownership split.

Covered route: every text instruction sent through `bin/fm-send.sh` or the away-mode supervisor injection path.

Mechanical trigger: the away-mode supervisor dispatches through `fm_backend_send_steering` before any pane input operation, while `bin/fm-send.sh` remains a separately owned route-completeness gap.

Deterministic predicate: text can be delivered only by one backend operation that atomically binds the expected live agent session and instruction submission.

Failure mode: every current `fm_backend_send_steering` adapter exits nonzero before sending literal text or Enter because none implements that primitive, while special-key control and the separately owned `bin/fm-send.sh` path remain outside that hard-stop.

A supervisor claim made after a nonzero exit is free-form prose and cannot be intercepted mechanically, and no current backend can produce a supported text-delivery receipt.

Finding F16 remains open: sibling pane adapters can change from an agent session to a bare shell between text entry and Enter, so the checked session and the acted-on session are not atomic.

The production refusal is verified through `inject_msg` and `fm_backend_send_steering` without replacing either symbol, but refusal is not a delivery receipt and does not make this gate shipped.

## Gate C: Positive-only run liveness and destructive-run custody

Covered route: every run-step-based `working` classification shared by the watcher and away-mode supervisor, plus every no-mistakes cancellation performed by the repository-owned automatic reaper.

Mechanical trigger: `crew_absorb_class` invokes `bin/fm-run-liveness.sh` before a running status can be absorbed, and the watcher repeats the same sampler when the repository-derived recheck cadence expires.

The sampler rejects scouts, detached worktrees, non-task branches, and branch-blind status answers before sampling; it re-reads the selected run by exact run ID and requires that response to carry the task branch.

Before interpreting the window, it mechanically records contemporaneous `uptime` and `vm_stat` output through `bin/fm-host-pressure.sh`.

The repository-owned reaper skips no-mistakes lookup entirely for detached scouts, selects an active run from the authoritative database by exact repository and task branch, and verifies that run again by both ID and branch.

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

The positive-only liveness half is shipped, but safe destructive-run custody remains an unshipped stated gap.

Failure mode for liveness: an all-zero window, changed or cross-branch run record, unreadable status, or failed process sample is surfaced as UNKNOWN and routes only to the non-destructive alternative.

The automatic reaper resolves the task branch and exact run ID when the current status supplies one, but an independent no-mistakes executor can still advance the same run before run-ID-only cancellation.

That concurrent run-head writer is not serialized with repository-owned task teardown, so the current route cannot make proof, expected generation and head, cancellation, and teardown one atomic transition.

The required deterministic cancellation predicate would hold one authority shared by every run-head writer from the initial generation, run, and head snapshot through expected-identity cancellation and terminal teardown.

Failure mode for destructive custody: an absent exact run ID or branch mismatch causes refusal, while missing pre-abort pushed-head, dead-agent, and shared run-head authority leave automatic cancellation unshipped.

Nothing reachable from absence authorizes cancellation, restart, replacement, or teardown.

Destructive run-control instructions remain a carried two-sided boundary outside the automatic reaper, not a structural gate: the sender must identify the exact run ID and branch, include authoritative proof that the target is dead, and prove current head equals pushed head; a receiving lane must independently verify every property before acting, whether or not the instruction claims proof.

Process absence at any sampled window is explicitly not acceptable proof.

Free-form instructions and arbitrary shell commands have no route-complete deterministic intercept in the current architecture, so this change does not mislabel that carrier as a hard gate.

Likewise, the automatic liveness route records host pressure before its diagnosis, while a free-form claim that repeated agent death, a daemon socket timeout, or a test flake is a code defect cannot be structurally intercepted today.

Generated briefs therefore require contemporaneous `bin/fm-host-pressure.sh` evidence for such a claim, but that prose route remains an explicitly stated carrier gap.

Recent completed `test` durations are selected by the same no-mistakes repository id, and the median controls recheck cadence.

Another repository's durations never enter the query.

## Gate D: One-shot merge

Status: unshipped stated gap, with a nondestructive production preflight and unconditional fail-closed boundary.

Covered route: `bin/fm-pr-merge.sh`, the canonical Firstmate PR merge entrypoint.

Mechanical trigger: the script rejects scheduling flags before any GitHub call, acquires the task lifecycle and shared checkout locks, runs synchronous snapshot admission, repeats local and remote identity checks, and invokes `fm_pr_require_atomic_merge_boundary` before any PR metadata write, endpoint teardown, or merge request.

Deterministic snapshot predicate: `--auto`, queueing, admin, and delete-after flags are forbidden; protected-branch required checks must be strict and nonempty; base-branch policy must be configured to dismiss stale reviews and require code-owner and last-push approval; at least two generic non-author approvals and admin enforcement must apply; and the sampled head, base, local content, checks, reviews, and residual must agree.

GitHub branch protection atomically enforces only configured required contexts, so a new failing unrequired context at the same head can appear after snapshot admission and still permit merge.

Firstmate's checkout and lifecycle locks cover cooperating repository callers, but they cannot prevent a task process, detached child, human shell, or external tool from writing the worktree by path.

Failure mode: after the complete nondestructive preflight, the atomic boundary exits nonzero, leaves task metadata and the endpoint intact, and never calls the merge endpoint.

Retirement requires a server-native required aggregate that is authoritatively invalidated by every exact-head check mutation and a worktree execution authority that excludes every writer for the entire residual-sample-and-merge interval.

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

Status: unshipped stated gap, while exact-head snapshot admission remains available for diagnosis.

Covered route: every merge execution through `bin/fm-pr-merge.sh`.

Mechanical trigger: synchronous `bin/fm-pr-admit.sh` runs from the merge preflight and emits a receipt explicitly labelled `snapshot-native-strict`.

Deterministic predicate: one unchanged head, base, and base ref must have a nonempty green and settled check set; two distinct non-author exact-head `APPROVED` review verdicts with no exact-head change request; exact local and PR head equality; an identical GitHub-file and local base-to-head file set; and a mechanically clean index and worktree including untracked paths.

Files, check runs, and reviews are fetched as explicit bounded pages and combined only after every page is structurally validated and its reported count reconciles.

Admission counts two generic non-author exact-head approvals and separately verifies that base-branch policy is configured to require code-owner reviews, stale-review dismissal, and last-push approval.

It does not prove that this PR has a current exact-head code-owner approval or otherwise satisfies that policy at the PR level.

A reviewer that stopped without submitting an exact-head `APPROVED` review contributes no verdict and the head is `UNREVIEWED`.

Admission does not publish a sticky client-side success status because same-head review and check state can change afterward.

The snapshot catches absent, pending, failed, stale, truncated, moved, dirty, unprotected, or contradictory evidence, but it does not claim an authoritative same-SHA review dismissal or post-snapshot worktree mutation catch.

Failure mode: the merge route refuses after snapshot admission because neither complete mutable server evidence nor exclusive local writer custody is available.

The code-owner and independent-review mutation leg is unverified and unshipped because the repository fixture cannot prove PR-level code-owner satisfaction or perform an authoritative GitHub review dismissal.

Free-form recommendations remain prose and cannot be made route-complete by this repository without the structured reporting transport described under Gate E.

The merge executor itself never treats CI colour as sufficient.

## Shared TOCTOU coverage

The server-side atomic unit must bind the admitted head and base, every exact-head check and review mutation, and the merge request against concurrent GitHub App, reviewer, and base-branch writers.

The local atomic unit must bind task generation and endpoint ownership, complete worktree-writer exclusion, the final tracked, staged, and untracked residual sample, and the merge request against task, child-process, shell, recovery, and external-tool writers.

- Direct writers include the active harness and any command it launches in the task worktree; checkout and lifecycle locks do not cover them after spawn.
- Reconciliation writers include `fm-teardown.sh` cleanup and Treehouse return paths; their cooperating mutations use checkout or lifecycle locks, but an already-running task child does not.
- Retry writers include teardown retry and stale-lock recovery plus checkout-refresh and fleet-sync retries; repository-owned checkout operations are covered where they call `fm_checkout_lock_run`, while raw process writes remain uncovered.
- Watcher writers include `fm-watch.sh` routes into automatic reap and recovery; task lifecycle serialization covers cooperating metadata transitions, but the independent no-mistakes run-head writer remains uncovered.
- Recovery writers include `fm-bootstrap.sh` secondmate liveness recovery and direct or managed recovery through `fm-spawn.sh`; generation checks cover installation of a replacement, but the resumed process can write after the lock is released.
- Resume writers include `fm-spawn.sh --resume-account`, `--continue-account`, and direct-account recovery; their setup is serialized, but their launched harnesses and descendants are deliberately long-lived and therefore outside merge custody.
- Uncovered routes are an arbitrary task process, detached or background descendant, human shell, raw Git or filesystem command, provider-owned worktree process, and any external no-mistakes executor that does not share Firstmate's locks.

No current route supplies both atomic units, so Gates D and F refuse rather than converting cooperative-lock coverage into a claim of exclusive custody.

## Mutation evidence ledger

This ledger distinguishes firing proofs from stated gaps and does not count a snapshot, spelling assertion, wrong observing layer, unreachable symbol, or test-side semantic reimplementation as a shipped catch.

The prior F20 and F21 gate acceptances are RETRACTED because their fixtures demonstrated nothing about the production guards.

All A-F firing proofs were freshly re-executed against real production violations.

Any leg not demonstrated is a STATED GAP.

Gate B's current production-route refusal proof is separate from the retracted F21 fixture.

- Gate A scope is one recorded Codex generation, the behavioral representation is a later wrong `thread_settings_applied` record, the observing layer is `bin/fm-runtime-profile.sh`, the reachable production path is `fm-codex-runtime-profile.mjs`, deterministic failure is exit 1 with the observed wrong axes, and retirement is a later exact-profile runtime record that verifies in `tests/fm-runtime-profile.test.sh`.
- Gate B scope is the away-mode supervisor injection route, the behavioral representation is an actual text digest passed to `inject_msg`, the observing layer is `bin/fm-supervise-daemon.sh`, the reachable production symbol is the unmodified `fm_backend_send_steering`, deterministic failure is nonzero before pane input in `tests/fm-daemon.test.sh`, and retirement requires an atomic agent-session-bound backend receipt; this is a verified refusal and an unshipped delivery gap.
- Gate B has no shipped delivery mutation proof in this lane because F16 and its released `bin/fm-send.sh` boundary are owned by `steer-enter-accepts-open-modal`; retirement requires that lane to inject an agent-to-shell transition between entry and submission and prove atomic delivery or refusal.
- Gate C liveness scope is one exact run, the behavioral representation is an all-zero real sampler window, the observing layer and reachable production path are `bin/fm-run-liveness.sh`, deterministic failure is UNKNOWN, and retirement supplies an affirmative owned process in `tests/fm-run-liveness.test.sh`.
- Gate C destructive custody has no shipped mutation proof in this lane because F12 and its released `bin/fm-auto-reap.sh` boundary are owned by `autoreap-cancels-before-containment`; retirement requires that lane to race a real run-head transition against abort and prove the transition or abort is rejected atomically under one authority shared by every run-head writer.
- Gate D scope is one PR head and base preflight, the behavioral representation is `strict: false` on the protected-branch policy response, the observing layer is `bin/fm-pr-merge.sh`, the reachable production symbol is `fm_pr_require_server_admission_rule`, deterministic failure occurs before metadata, endpoint, or merge mutation, and restoring strict policy retires that violation only as far as the unconditional atomic-boundary refusal in `tests/fm-pr-merge.test.sh`; the merge gate remains unshipped.
- Gate E scope is the append-only task status carrier, the behavioral representation is an invented `blocked [key=premise]:` event with no assumption test, the observing layer is the shared watcher classifier, the reachable production symbols are `status_is_captain_relevant` and `status_open_decisions`, deterministic evidence is that the carrier accepts rather than rejects it, and retirement requires an explicit `resolved` event in `tests/fm-blocker-discipline-gap.test.sh`.
- Gate E remains unshipped until a mandatory structured blocker transport rejects missing `assumption`, `test`, and `result` fields, at which point the mutation test must flip from demonstrating acceptance to demonstrating refusal.
- Gate F scope is one exact-head snapshot evidence set, the behavioral representations exercised through production parsing are a missing generic exact-head approval and a dirty tracked or untracked worktree, the observing layer is `bin/fm-pr-admit.sh`, deterministic failure is snapshot refusal, and removing those violations reaches only `fm_pr_require_atomic_merge_boundary`; PR-level code-owner proof, authoritative review dismissal, and concurrent-writer retirement evidence do not exist, so Gate F remains a STATED GAP.
