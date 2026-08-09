# Structural gates

This document records the six hardening gates, every production route each gate covers, the mechanical trigger and predicate, and the fail-closed result.
The route inventory was checked against the firstmate instruction-surface audit and the gate taxonomy report supplied with the implementation.

## Gate A - Codex capability and runtime integrity

### Risk

A Codex lane can silently run below the required reasoning policy because launch metadata, quota telemetry, and process presence do not prove which model actually completed a turn.

### Complete route inventory

- New Codex ship and scout launches pass through `bin/fm-spawn.sh`, which calls the runtime-policy assertion before endpoint creation and emits explicit `--model gpt-5.6-sol -c model_reasoning_effort=xhigh` launch settings.
- Direct-account selection passes through `bin/fm-account-directory.sh`, which considers only accounts with a current positive completion proof from an isolated real `codex exec` probe and ignores quota telemetry for admission.
- Positive and negative account proofs have bounded lifetimes, are serialized, and are bound to the physical account-directory identity, so stale or redirected caches cannot authorize routing.
- Direct-account recovery passes through `bin/fm-spawn.sh --recover-direct-account`, which re-resolves the current harness and Codex policy instead of replaying the recorded model and effort.
- Steering a managed Codex target passes through `bin/fm-send.sh`, which runs `bin/fm-runtime-profile.sh` before the delivery gate; a runtime mismatch refuses there, and a verified runtime still reaches Gate B's current no-session-bound-route refusal.
- Runtime supervision passes through `bin/fm-watch.sh` and `bin/fm-supervise-daemon.sh`, which re-run the exact-generation runtime verifier at bounded intervals and surface a mismatch instead of treating the lane as healthy.
- `bin/fm-codex-runtime-profile.mjs` reads Codex's own session records and requires the recorded provider session, generation, model, and reasoning effort to match the task metadata and policy.
- Herdr's Codex pane-input steering route is closed because pane input cannot atomically preserve the registered agent session and Herdr's native send can reapply stored settings.

### Trigger, predicate, and failure mode

- Trigger: account selection, new spawn, direct recovery, each managed steer, startup verification, and periodic in-flight verification.
- Predicate: a ground-truth completion probe succeeds under the selected account and the live exact-generation Codex record says `gpt-5.6-sol` with `xhigh` effort.
- Failure mode: account selection excludes the account, launch or recovery refuses, steering exits nonzero before input, or supervision reports an unverified runtime and retains the lane for diagnosis.

### Provider boundary

Firstmate can deterministically set and verify launch settings and can repeatedly read Codex's own turn record, but it cannot interpose inside Codex's provider-side model substitution mechanism.
The structural response is therefore prevention at every firstmate-owned launch and steer boundary plus automatic bounded re-verification while the lane remains live.
A substitution may exist until the next Codex-owned record is readable, so no status or process signal is allowed to conceal that interval as verified.

### Deterministic evidence

- `tests/fm-account-directory.test.sh` covers ground-truth routing, cache bounds, identity binding, exact launch policy, and recovery re-resolution.
- `tests/fm-spawn-dispatch-profile.test.sh` covers the mandatory Codex model and effort policy.
- `tests/fm-runtime-profile.test.sh` covers exact-generation verification, substitution detection, mismatched sessions, and unreadable records.
- `tests/fm-send-strict.test.sh` covers refusal to steer an unverified Codex runtime.

## Gate B - Verified message delivery

### Risk

A command can be accepted by a backend client without reaching the intended live target, which previously allowed callers to report delivery on submit success alone.

### Complete route inventory

- Text delivery through `bin/fm-send.sh` requires target resolution, endpoint identity verification, lifecycle revalidation for managed targets, an atomic agent-session-bound backend confirmation, and a fresh identity-bound target read after submission.
- No current backend can bind terminal input atomically to the registered agent session, so every production text-steering adapter refuses before pane input instead of falling back to split text-plus-Enter.
- Control-key delivery through `bin/fm-send.sh` uses the same target resolution and managed lifecycle checks but remains a backend-specific one-shot operation; its zero exit reports only that key call, never delivery of a text instruction.
- Tmux verification binds the recorded stable window ID and session identity, so a reused window name in another session is not the target.
- Herdr verification preserves the exact backend target and registered label when metadata exists, and an explicit metadata-free target remains visibly unbound.
- Secondmate markers and ordinary steering both use the same `fm-send` boundary, so no alternate supervisor send path can claim success from submit alone.
- Terminal-backed away-mode delivery and `bin/fm-lavish-queue.sh` both call `fm_backend_send_steering`; they preserve their durable buffers or answer records and refuse visible-delivery claims when the current atomic route is unavailable.

### Trigger, predicate, and failure mode

- Trigger: every `fm-send` text request; control-key requests take the narrower routed lifecycle path described above.
- Predicate: for text, the exact target remains identity-matched, the backend returns `confirmed` from an atomic agent-session-bound submit, and a fresh post-submit read succeeds from that same target.
- Failure mode: an unavailable atomic route, submit failure, pending confirmation, unknown confirmation, malformed verdict, lifecycle drift, identity mismatch, or failed post-submit read exits nonzero and is journaled as not delivered or not submitted.

### Deterministic evidence

- `tests/fm-send-strict.test.sh` covers a test-lab atomic receipt plus production no-route refusal, submit-only false positives, malformed verdicts, identity reuse, lifecycle races, and audit outcomes.
- `tests/fm-send-permission-modal-probe.sh` proves every Herdr composer and modal state remains untouched when no atomic steering route exists.

## Gate C - Epistemically safe liveness and custody

### Risk

Absence of a process sample, a stale status field, or one quiet observation can be mistaken for death and used to cancel or destroy work that is still active.

### Complete route inventory

- `bin/fm-run-liveness.sh` is the exact run-ID, branch, and head-attributed process owner and emits only `BUSY` from affirmative process evidence or `UNKNOWN` otherwise.
- `bin/fm-nm-step-liveness.sh` remains a legacy diagnostic that can render confirmed process absence as `dead`; every production supervision consumer downgrades that vocabulary to UNKNOWN, while `bin/fm-run-liveness.sh` owns the exact-run process window used for absorption.
- `bin/fm-crew-state.sh` consumes branch-matched run evidence before pane and status evidence and exposes the legacy liveness verdict only as a diagnostic that cannot override current run state.
- `bin/fm-classify-lib.sh`, `bin/fm-watch.sh`, and `bin/fm-supervise-daemon.sh` absorb a lane only from affirmative run-owned process evidence; pane, status, missing-target, and unreadable observations remain UNKNOWN.
- Watcher hash, pause, permission, signal, turn-end, surfaced-heartbeat, and daemon state families use bounded SHA-256 task keys with safe exact-identity owner records and migrate legacy state only for one positively verified owner.
- The owner record is claimed without overwrite and revalidated before carrier reads, migration, attribution, or deletion, so a digest collision or forged owner fails closed.
- Unsafe uniquely owned carriers are quarantined without following links, exact-key observation continues, and ambiguous UNKNOWN markers remain behind an atomic per-marker retry cadence and buffered-event dedupe.
- Herdr native-transition dedupe keys use the same bounded SHA-256 identity key and an exact safe task owner resolved from uniquely matching Herdr metadata; migration preserves both deployed lossy and v2 dedupe state only after proving that owner, while ambiguous or unsafe carriers remain visible and fail closed.
- Each Herdr subscription snapshot binds every pane edge to the exact task ID, generation ID, window, and safe metadata file identity before the provider stream can buffer it; apply, working-edge clear, watcher handling, and commit revalidate that immutable record while holding the task lifecycle lock followed by its metadata lock, so a reassigned edge becomes UNKNOWN without waking or clearing the new owner.
- Herdr transition migration, wake-and-commit, ordinary teardown, direct recovery, failed direct-spawn teardown, and immediate spawn rollback use that lifecycle-to-metadata lock order; direct recovery clears the old window before replacement, legacy teardown safely backfills one generation identity, and failed-generation restoration remains unavailable until exact transition cleanup succeeds.
- Daemon stale and pause marker writes serialize with the task lifecycle lock held by spawn and teardown.
- `bin/fm-auto-reap.sh` has no validation-abort route and retains every active, cross-branch, ambiguously attributed, or otherwise uncustodied run.
- Teardown remains the sole destructive boundary and still requires its independent exact ownership, cleanliness, landed-work, and endpoint proofs.

### Trigger, predicate, and failure mode

- Trigger: current-state reads, watcher triage, away-mode triage, stale classification, and automatic reap attempts.
- Predicate: BUSY requires a current affirmative process sample attributed to the exact run ID, task branch, and head before and after sampling, while destructive cleanup additionally requires terminal state and exact safe custody.
- Failure mode: any absence, mismatch, timeout, single quiet sample, repeated zero sample, stale field, unknown owner, or cross-branch run becomes UNKNOWN and retains the lane without cancellation.

### BUSY, UNKNOWN, and not acceptable

- BUSY means affirmative evidence says attributed work is executing now, and it is sufficient only to suppress a benign wake.
- UNKNOWN means the system cannot prove activity or inactivity, and it must surface or retain custody without claiming idle, dead, wedged, or safe to cancel.
- A cancellation-quality verdict would require exact run, task branch, and head attribution, terminal state from the authoritative run, no contradictory process evidence, and safe endpoint and worktree custody; this hardening intentionally grants no automatic validation-abort authority even when those facts appear available.

### Deterministic evidence

- `tests/fm-run-liveness.test.sh` covers affirmative BUSY, absence as UNKNOWN, branch blindness, detached work, and host-pressure recording.
- `tests/fm-nm-step-liveness.test.sh` preserves the legacy diagnostic vocabulary, while `tests/fm-crew-state.test.sh`, `tests/fm-watch-triage.test.sh`, and `tests/fm-fleet-snapshot-view.test.sh` prove a legacy `dead` result cannot become a production death or cancellation verdict.
- Focused liveness shards in `tests/fm-watch-triage.test.sh` and `tests/fm-daemon.test.sh` cover status-field and heartbeat non-inference, bounded long-identity custody, adversarial owner rejection, collision-free signal custody, unsafe legacy quarantine, and atomic UNKNOWN retry publication.
- `tests/fm-backend-herdr.test.sh` proves native transition markers remain collision-free, safely migrate deployed carriers, retain ambiguous ownership, and reject teardown races, buffered edges, and stale owners after window reuse.
- Focused direct-spawn cases in `tests/fm-account-directory.test.sh` and `tests/fm-teardown-suite.sh` prove both immediate and retained rollback clear failed-generation transition custody before prior metadata restoration.
- `tests/fm-auto-reap.test.sh` covers active-run and ambiguous-run retention and the absence of abort authority.

## Gate D - No armed merge and preserved task checks

### Risk

A scheduled merge can execute after its evidence becomes stale, and writing a merge poll into `state/<id>.check.sh` can overwrite a task-owned custom check.

### Complete route inventory

- `bin/fm-pr-check.sh` records the canonical PR URL and live head only and does not create, replace, chmod, or remove `state/<id>.check.sh`.
- `bin/fm-pr-merge.sh` rejects `--auto`, `--queue`, `--admin`, `--delete-branch`, repository overrides, and unknown options before any GitHub merge request.
- `bin/fm-pr-merge.sh` is a synchronous preflight only and ends in an unconditional atomic-boundary refusal after all evidence checks.
- `bin/fm-crosscheck.sh` and its Python parser expose only `run` and `verify`, and the read-only GitHub adapter exports no merge mutation primitive.
- Watcher PR handling reads canonical PR metadata instead of depending on a generated task poll file.

### Trigger, predicate, and failure mode

- Trigger: PR recording, merge preflight, Crosscheck merge invocation, and watcher PR observation.
- Predicate: no accepted route may arm deferred execution or mutate the task-owned poll file.
- Failure mode: armed, queued, administrative, branch-deleting, repository-overriding, or direct Crosscheck merge attempts exit nonzero before network mutation, while custom checks remain byte-identical and executable.

### Deterministic evidence

- `tests/fm-pr-merge.test.sh` covers every refused merge mode, custom-check preservation, retired routes, and unconditional refusal ordering.

## Gate E - Falsifiable blocker assumptions

### Risk

A remembered scheduler mode, stale configuration assumption, or neighboring failure can be promoted into a blocker and drive the wrong operational action.

### Complete route inventory

- `bin/fm-brief.sh` requires every crewmate and secondmate blocker to state one premise, name the mechanical probe actually run, and carry the observed result in the same status event.
- `bin/fm-classify-lib.sh` accepts a blocker into the durable keyed open-decision set only when the note has `assumption=...; test=...; result=...` and rejects placeholder assumptions, future tests, or unobserved results.
- A malformed blocker remains captain-relevant for internal repair, so the proof gate cannot hide a real lane failure merely because its report is incomplete.
- The always-loaded escalation contract requires `operating-fundamentals` before blocker claims and consequential config or system changes, and its proof rule requires an authoritative live probe with exact actor, surface, target, and result.
- Before a blocker reaches the captain, `AGENTS.md` requires the same proof rule rather than permitting a status line or confidence statement to stand as evidence.

### Trigger, predicate, and failure mode

- Trigger: generated task instructions, every durable blocked event entering the open-decision fold, any blocker escalation, and every consequential config or system change.
- Predicate: the key assumption is falsifiable, the named probe was run against the authoritative live surface, and the observed result supports only the stated scope.
- Failure mode: a blocker missing any field, carrying an unexecuted placeholder, or relying on a neighboring observation cannot enter the durable open-decision set and must be repaired before escalation or action.

### Structural boundary

No repository script can intercept every arbitrary shell command an operator could use to edit external system configuration.
The hard mechanical boundary is complete for the durable blocker carrier, while direct external config mutation remains governed by the mandatory load-before-action instruction and exact-evidence requirement rather than an operating-system interposition layer.
This limitation is explicit and must not be described as universal syscall-level prevention.

### Deterministic evidence

- `tests/fm-blocker-discipline-gap.test.sh` mutation-tests malformed, placeholder, valid, and resolved blocker events through the production decision fold.
- `tests/fm-captain-item-check.test.sh` covers the separate captain-facing explanation gate.

## Gate F - Exact-head merge admission and independent verdict

### Risk

A merge can be treated as ready while checks are pending, the reviewed head has moved, the local change is not contained in the PR, or the independent reviewer produced no exact-head verdict.

### Complete route inventory

- `bin/fm-pr-check.sh` records canonical live PR metadata without granting merge authority.
- `bin/fm-pr-admit.sh` independently reads the live PR and requires an open non-draft PR, exact expected head, every protected context and app identity in settled successful exact-head evidence, clean exact-head review state, and PR-file and worktree containment.
- Review admission uses the live policy approval count and GitHub's clean protected-merge eligibility to prove enabled code-owner and last-push requirements are satisfied by the exact head.
- Immediately before admission, `bin/fm-pr-admit.sh` re-snapshots protected policy plus the complete exact-head check and review evidence and refuses any same-head change.
- Pending, queued, missing, unreadable, stale, stopped, wrong-head, or absent reviewer output is `UNREVIEWED`, never clean.
- `bin/fm-crosscheck.sh verify` rechecks live head, base, claims digest, reviewer independence, executed reproduction evidence, and durable finding lifecycle.
- `bin/fm-pr-merge.sh` orders canonical PR recording, Crosscheck verification, native five-part admission, and then unconditional refusal before any mutation.
- No retired Crosscheck or GitHub CLI route can bypass the native admission owner.

### Trigger, predicate, and failure mode

- Trigger: every merge preflight and every attempt to use a retired merge entrypoint.
- Predicate: all native admission properties and the independent exact-head adversarial verdict are simultaneously clear for the live head and stable claims digest.
- Failure mode: any pending check, stale or dirty review, head movement, containment mismatch, blocking finding, missing reviewer artifact, tool failure, or unreviewed verdict exits nonzero, and even a clear admission currently ends at the explicit atomic-boundary refusal.

### Deterministic evidence

- `tests/fm-pr-admit.test.sh` mutation-tests nested review identities, missing required contexts, wrong app identity, same-head evidence races, pending checks, dirty and mismatched containment, weak policy, and head movement.
- `tests/fm-crosscheck.test.sh` covers exact-head reviewer execution, independence, evidence reproduction, claims binding, stale artifacts, and UNREVIEWED states.
- `tests/fm-pr-merge.test.sh` proves the sole entrypoint orders exact evidence before an unconditional no-network refusal.

## Behavior-shard inventory

The slow behavior suite inventories these gates explicitly in `tests/behavior-test-durations.tsv` so the route checks remain part of the normal repository evidence surface.
