# Structural hardening gates

This document records the six gates added after the 2026-08-01 supervision failures.

Every claimed gate names its covered route, mechanical trigger, deterministic predicate, and failure mode.

An instruction-only boundary is labelled as such instead of being presented as a hard gate.

## Gate A: Codex dispatch and runtime profile

Covered route: every verified `harness=codex` launch through `bin/fm-spawn.sh`, every direct-account Codex steer through `bin/fm-send.sh`, and every recorded Codex task inspected by the watcher.

Mechanical trigger: spawn admission runs before endpoint creation, direct-account steering verifies before and after delivery, and the watcher invokes `bin/fm-runtime-profile.sh` every five minutes.

Each new Codex task generation also lacks a runtime receipt by construction, so the already-required live watcher verifies its harness record immediately after start, with a sixty-second startup grace only for rollout publication.

Deterministic predicate: the only admitted profile is `model=gpt-5.6-sol effort=xhigh`, and the latest matching Codex `turn_context` or `thread_settings_applied` rollout record must contain those exact values.

Recovery re-resolves the current harness, model, and effort policy instead of replaying their recorded metadata values.

When natural-language dispatch rules are active, recovery mechanically requires the caller to pass the freshly selected concrete harness profile because shell code cannot re-evaluate those rules.

A native same-session recovery proceeds only when its recorded provider still equals current harness policy; otherwise it refuses and requires an explicit continuation profile.

Failure mode: a below-policy spawn exits before endpoint creation; a runtime mismatch or unreadable runtime record wakes supervision; a direct-account steer exits nonzero.

Herdr Codex steering uses verified literal pane input because Herdr's native `agent send` reapplies account thread defaults.

An agent-less Herdr pane refuses steering rather than accepting text that the next Enter could execute in a shell.

An opaque raw custom executable remains outside the verified Codex adapter contract because its transitive behavior cannot be inspected deterministically.

Codex account routing does not consume quota-axi telemetry as either an eligibility or refusal signal because measured fixtures proved it wrong in both directions.

Those fixtures make the telemetry permanently contested, not just stale; it never becomes a routing predicate, and an expired ground-truth proof always requires a fresh codex completion probe.

The deterministic capacity predicate is successful completion of a tiny ephemeral exact-profile `codex exec` probe under the account home.

Positive proofs are cached for thirty minutes and unavailable probes for one minute; the former bounds healthy-account probe cost to two per hour, while the latter avoids a spawn loop hammering an exhausted or unauthenticated account.

If the probe command is missing, times out, refuses, fails authentication, or returns no exact sentinel, that account is unavailable; no positive account proof fails spawn closed.

Pane activity and pipeline liveness are never capacity evidence.

Account config pins and explicit launch flags preserve the `refuse loudly rather than degrade silently` invariant for future launches, but they do not retroactively repair a session that already substituted its model; that session remains mismatched until relaunched.

## Gate B: Steering delivery

Covered route: every text or key instruction sent through `bin/fm-send.sh`.

Mechanical trigger: the send command itself requires both backend submission confirmation and a fresh target capture before it prints a delivery receipt or exits zero.

Deterministic predicate: the backend verdict must be confirmed rather than `pending`, `send-failed`, or `unknown`, and the target capture must succeed after submission.

Failure mode: the command exits nonzero and records managed text as unconfirmed where possible.

A supervisor claim made after a nonzero exit is free-form prose and cannot be intercepted mechanically, so the zero-exit delivery receipt is the only supported evidence of delivery.

## Gate C: Positive-only run liveness and destructive-run custody

Covered route: every run-step-based `working` classification shared by the watcher and away-mode supervisor, plus every no-mistakes cancellation performed by the repository-owned automatic reaper.

Mechanical trigger: `crew_absorb_class` invokes `bin/fm-run-liveness.sh` before a running status can be absorbed, and the watcher repeats the same sampler when the repository-derived recheck cadence expires.

The sampler rejects scouts, detached worktrees, non-task branches, and branch-blind status answers before sampling; it re-reads the selected run by exact run ID and requires that response to carry the task branch.

Before interpreting the window, it mechanically records contemporaneous `uptime` and `vm_stat` output through `bin/fm-host-pressure.sh`.

The repository-owned reaper skips no-mistakes lookup entirely for detached scouts, selects an active run from the authoritative database by exact repository and task branch, and verifies that run again by both ID and branch.

Deterministic liveness predicate: seven untruncated, exact-run process-table samples span sixty seconds by default; any sample with a run-owned process proves `BUSY`; every result without affirmative evidence is `UNKNOWN`, never `IDLE`, dead, or wedged.

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

Deterministic cancellation predicate: immediately before `axi abort`, the task must be a ship lane on its exact `fm/<id>` branch; the authoritative run ID and run branch must match that task; the run head and recorded last-pushed head must both equal current `HEAD`; and the task agent must be affirmatively classified `dead` by the backend adapter.

The exact run ID and branch are verified again after cancellation, and cancellation must be reported terminal before teardown proceeds.

Failure mode: an all-zero window, changed or cross-branch run record, unreadable status, failed process sample, missing pushed-head proof, current/pushed divergence, or non-dead agent is surfaced as UNKNOWN or refusal and routes only to the non-destructive alternative.

Nothing reachable from absence authorizes cancellation, restart, replacement, or teardown.

Destructive run-control instructions remain a carried two-sided boundary outside the automatic reaper, not a structural gate: the sender must identify the exact run ID and branch, include authoritative proof that the target is dead, and prove current head equals pushed head; a receiving lane must independently verify every property before acting, whether or not the instruction claims proof.

Process absence at any sampled window is explicitly not acceptable proof.

Free-form instructions and arbitrary shell commands have no route-complete deterministic intercept in the current architecture, so this change does not mislabel that carrier as a hard gate.

Likewise, the automatic liveness route records host pressure before its diagnosis, while a free-form claim that repeated agent death, a daemon socket timeout, or a test flake is a code defect cannot be structurally intercepted today.

Generated briefs therefore require contemporaneous `bin/fm-host-pressure.sh` evidence for such a claim, but that prose route remains an explicitly stated carrier gap.

Recent completed `test` durations are selected by the same no-mistakes repository id, and the median controls recheck cadence.

Another repository's durations never enter the query.

## Gate D: One-shot merge

Covered route: `bin/fm-pr-merge.sh`, the canonical Firstmate PR merge entrypoint.

Mechanical trigger: the script rejects scheduling flags before any GitHub call, runs synchronous admission, and calls GitHub's merge REST endpoint with the admitted `sha` value.

Deterministic predicate: `--auto`, queueing, admin, and delete-after flags are forbidden; the REST merge succeeds only if the current PR head still equals the admitted head.

Failure mode: any head movement or merge refusal exits nonzero and no merge remains armed.

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

Deterministic predicate: one unchanged head and base must have a nonempty green and settled check set; two distinct non-author exact-head `APPROVED` review verdicts with no exact-head change request; exact local and PR head equality; an identical GitHub-file and local base-to-head file set; and an explicitly measured zero-byte residual over those files.

At least one approval must carry the exact machine-readable attestation `FIRSTMATE-ADVERSARIAL-VERDICT: CLEAN head=<sha>`; an ordinary second approval is not relabelled as adversarial evidence.

A reviewer that stopped without submitting an exact-head `APPROVED` review contributes no verdict and the head is `UNREVIEWED`.

Failure mode: any absent, pending, failed, stale, truncated, moved, or contradictory property exits nonzero before the merge endpoint is called.

Free-form recommendations remain prose and cannot be made route-complete by this repository without the structured reporting transport described under Gate E.

The merge executor itself never treats CI colour as sufficient.
