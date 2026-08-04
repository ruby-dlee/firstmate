# Spawn-time startup trust-dialog reporting

Status: implemented on the feature branch in the route-complete shape described below; live-harness and delivery-gate validation remain before publication.

## Objective

`fm-spawn.sh` must surface a recognized startup trust dialog while the decision is still useful to the operator.
The mechanism is report-only.
It must never send a key, select a choice, dismiss a prompt, or change the spawn result because of the prompt classification.
It must never reuse a startup acceptance instruction for a permission or trust grant that appears after brief processing has begun.

## Current boundary

All managed task endpoints are created through `bin/fm-spawn.sh`.
The backend branches create tmux, Herdr, Zellij, cmux, or legacy Orca endpoints and set `ENDPOINT_CREATED=1`.
Herdr starts the harness atomically inside `fm_backend_herdr_create_task`, while the other backends create a shell endpoint and submit the harness launch later.
The common point at which every successful path has both an installed `state/<id>.meta` record and an initiated harness launch is near the end of `fm-spawn.sh`, after managed account launch commit and before the final `spawned ...` line.
That common point is the detection point.

The poll belongs immediately before the final success line and after lifecycle locks have been released.
Waiting there avoids holding a project lifecycle lock for the observation window and ensures a dialog is reported only for an endpoint whose spawn transaction has otherwise committed.
The reporter must use the already resolved backend, target, expected task label, recorded scoped target, harness, task id, and active `FM_HOME` from the spawn process.
It must call the backend-neutral `fm_backend_capture` boundary rather than shelling out to `fm-peek.sh` or re-resolving the target from mutable metadata.
A small spawn-local wrapper must apply the same secondmate endpoint-home routing that `spawn_managed_endpoint_state` already applies.

The production observation window should default to 20 seconds with a one-second interval and stop early on positive evidence.
A test-lab-only timeout override may shorten fixture runs, but production callers must not be able to disable the observation accidentally through an undocumented environment variable.
The poll does not alter `fm-spawn.sh`'s exit status or rollback behavior.

## Classifier and phase boundary

The implementation needs one pure classifier owner shared by the spawn reporter and the watcher.
It should expose separate startup and mid-run classification functions rather than a phase flag whose caller can accidentally invert the security boundary.
The existing `permission_prompt_kind` implementation in `bin/fm-watch.sh` is the source to extract, not a second contract to copy.
The shared classifier should remain side-effect free and accept the resolved harness plus a bounded plain-text pane tail.

The startup classifier examines the final 16 lines of a 40-line capture and requires the complete verified shape, not a title fragment.
The initial verified set is:

- Claude workspace trust requires `Quick safety check: Is this a project you created or one you trust?`, `Yes, I trust this folder`, `No, exit`, and the confirmation footer.
- Claude hook trust requires `Hooks need review`, `Trust all on first launch`, `Review hooks`, `Exit`, and the confirmation footer.
- Codex directory trust requires `Do you trust the contents of this directory?`, `Yes, continue`, and `No, quit`.

The harness-adapters skill names Claude's bypass-permissions confirmation and Pi's project-trust dialog as startup categories, but it does not currently preserve complete stable render tokens for either one.
Those categories must receive an empirical capture and a full-shape fixture before they can produce an acceptance command.
Until then, either shape is `UNKNOWN`, not a recognized dialog and not evidence that no dialog exists.
OpenCode has no verified startup trust dialog, and Grok's project picker is unreachable for the repository-root launch used by `fm-spawn.sh`, but the reporter still requires positive processing evidence before it becomes quiet.
An unknown or raw harness is never matched by borrowing another harness's acceptance rule.

The startup phase remains eligible only until positive evidence shows the current launch processed the brief.
Positive evidence is a backend-native busy verdict, a verified busy signature in the pane tail, or a current-launch turn-end signal observed after its pre-launch baseline.
The spawn poll keeps this as a local irreversible latch.
Once the latch is set, no later capture in that spawn invocation may produce a startup acceptance command.
The watcher's existing generation-bound `.brief-started-<id>` marker remains the durable post-spawn phase boundary and must not be written directly by `fm-spawn.sh`.

A pane containing both a complete trust shape and a busy signature is not a startup match.
A pane containing only a title, only choices, truncated content, multiple conflicting complete shapes, or a shape for the wrong harness is not a startup match.
These rules prevent transcript text and partial terminal reads from becoming trust instructions.

## Outcomes and output

The reporter has three outcome classes.
There is deliberately no `no-dialog` outcome because failure to observe a dialog does not prove its absence.

| Outcome | Required evidence | Spawn behavior |
|---|---|---|
| `processing` | Positive current-launch processing evidence | Finish normally without a trust warning. |
| `startup-dialog:<kind>` | One complete harness-specific startup shape before processing evidence | Print one loud actionable report and finish normally. |
| `unconfirmed` | Deadline, empty capture, capture failure, endpoint disappearance, partial shape, conflicting shape, or otherwise unclassified readable pane | Print one loud `STARTUP STATE UNKNOWN` report and finish normally. |

A recognized prompt is reported to stderr in this form, with every shell word generated by the script's existing shell-quoting helper.

```text
STARTUP TRUST DIALOG: task=<id> harness=<harness> window=<target>; no input was sent.
Review the prompt and, only if you choose to trust it, run: FM_HOME=<quoted-home> <quoted-root>/bin/fm-send.sh <quoted-id> --key Enter
```

The hook-review variant should say `STARTUP HOOK TRUST DIALOG` so the operator knows what is being trusted.
The exact command should target the task id under the active home rather than an unscoped bare window name.
This lets `fm-send.sh` apply metadata identity checks and backend routing before any later human-authorized key is sent.

An unconfirmed launch is reported to stderr in this form.

```text
STARTUP STATE UNKNOWN: task=<id> harness=<harness> window=<target>; brief processing and a known startup dialog were both unproven within 20s; no input was sent.
Inspect it with: FM_HOME=<quoted-home> <quoted-root>/bin/fm-peek.sh <quoted-id>
```

A capture error should add its bounded reason without dumping pane contents, credentials, or provider configuration.
An unconfirmed report never includes an acceptance command.
The ordinary `spawned ...` success line remains byte-compatible for existing parsers.

## Startup versus mid-run permissions

Startup trust and mid-run permission grants are distinct security states even when a harness reuses similar chrome.
A startup report is eligible only before positive current-generation processing evidence.
It offers a command the operator may choose to run, but the reporter does not run it.

After processing evidence exists, Claude workspace trust and Codex directory trust are protected mid-run grants.
Command execution, file edit, permission-profile, and network-access prompts are always mid-run permission classes and never startup acceptance classes.
The existing watcher response remains authoritative for those prompts: inspect the requested action, escalate it to the captain, and do not press an approval or denial key automatically.
The Claude hook-review shape is startup-only in the verified launch path.
If it appears after processing evidence, the correct result is `UNKNOWN` plus inspection, not reuse of the startup Enter instruction.

The classifier must not expose one generic `trust` return that a caller can map to Enter without phase information.
Separate function names and separate result enums are the mechanical guard against crossing this boundary.

## Fail-closed behavior

Fail-closed applies to the classification claim, not to the already committed spawn transaction.
Any inability to prove `processing` or a complete recognized startup dialog produces `STARTUP STATE UNKNOWN`.
The implementation must preserve backend capture failures instead of hiding them behind `|| true`.
Empty output, a timeout, an absent endpoint, malformed text, a partial read, an unsupported harness, and an ambiguous match are explicit outcome cases.
None may fall through to the quiet `processing` path.

The reporter never retries with a keystroke and never probes by changing the pane.
It does not kill or restart an endpoint whose startup state is unknown.
It does not print `clear`, `safe`, `no dialog`, or any equivalent claim based on a quiet timeout.

## Route completeness and watcher fallback

Endpoint creation is route-complete because `fm-spawn.sh` is the only creator, but a bounded spawn-time poll is not temporally observation-complete.
A dialog can render after the 20-second window, or the endpoint can remain readable without showing either a busy signature or a complete known prompt during that window.
Shipping only the spawn poll would therefore leave a faster silent path after the deadline.

The watcher should add a startup-specific semantic subtype on its existing `stale` wake route.
A new durable wake wire kind is unnecessary because the required supervisor action is still to inspect the pane, and the queue currently admits the intentionally small `signal`, `stale`, `check`, and `heartbeat` vocabulary.

The watcher fallback has two cases.

- When the current-generation brief-start marker is absent and the shared startup classifier positively recognizes a complete prompt, enqueue a `stale` wake whose reason begins `startup-trust-dialog detected`, states that no input was sent, and includes the same exact review-and-accept command.
- When the endpoint remains present beyond a bounded startup grace period and current-generation processing evidence is still absent, enqueue a deduplicated `stale` wake whose reason begins `startup-unconfirmed` and requests a peek without offering an acceptance command.

The second case must not say that the brief never started.
Marker absence proves only that Firstmate did not observe its positive start evidence, so the wake must report `UNKNOWN` even if the pane has been unchanged for a long time.
This conservative semantic class answers the late-dialog question without violating the rule that absence of evidence is not evidence of absence.
It may surface a fast task whose busy state was never sampled, but that is an explicit unknown requiring inspection rather than a false claim about the task.

If the marker is present, a recognized directory-trust shape takes the existing protected mid-run permission path and never receives a startup accept command.
If the watcher is not healthy, the existing watcher-liveness guard remains responsible for reporting that supervision gap.
With the spawn reporter, the recurring recognized-dialog fallback, and the `startup-unconfirmed` fallback, every successful endpoint either gains positive processing evidence or produces a report instead of silently waiting forever.

The watcher portion must ship in the same change as the spawn reporter if the feature is described as route-complete.
If ownership or validation sequencing forces separate delivery, the spawn-only release must be labeled a bounded detector with the late-dialog gap still open.

## Test plan

The test suite must exercise the actual reporting and send-key boundaries, not only a classifier return value.
The quantifier for recognized shapes is `EVERY`: every complete startup shape in the shared classifier must surface through the real `fm-spawn.sh` path.
The quantifier for backend dispatch is also `EVERY`: every spawn-capable backend and every supported task kind must route capture through its correct endpoint home and target identity.
Unsupported backend and kind combinations remain explicit exclusions rather than silently skipped rows.

### Pure classifier cases

Table-driven fixtures should cover every complete recognized shape and its harness.
For every positive fixture, delete each required token in turn and prove the result becomes `unconfirmed`.
Wrong-harness, busy-plus-quoted-prompt, partial final line, prompt outside the final 16 lines, two conflicting complete prompts, empty input, and malformed terminal fragments are separate outcomes.
Mid-run command, edit, profile, and network prompts must never return a startup acceptance class.

### Spawn boundary cases

A new `tests/fm-spawn-startup-trust.test.sh` should drive the real `fm-spawn.sh` with a fake backend executable that records captures and every send-key call.
The fixture should transition from an empty pane to each known prompt so the test proves the bounded poll observes a late render rather than only its first sample.
It should separately transition to a verified busy signature and assert that no trust warning is printed.

The fake backend log must distinguish the Enter used to launch a non-Herdr harness from any later Enter that would approve a dialog.
The assertion is on the actual backend send-key log after the dialog is visible.
As a positive control, the test should then invoke the printed `fm-send.sh ... --key Enter` command explicitly and prove one additional Enter reaches that same log.
That control demonstrates the instrument can observe approval at the real boundary and that the reporter itself sent none.
Herdr provides the complementary zero-versus-one control because its native agent launch does not require a launch Enter.

Separate cases must cover all-capture failure, empty captures until timeout, endpoint disappearance, partial captures, conflicting shapes, and a readable but unclassified idle pane.
Every one must print `STARTUP STATE UNKNOWN`, omit an acceptance command, preserve the committed endpoint, and retain the ordinary successful spawn exit status.
A fake capture that returns a complete known prompt after the spawn deadline must be surfaced by the watcher fallback.
A task with an absent current-generation brief-start marker and no recognized prompt must produce `startup-unconfirmed`, not `brief never started`.
A current-generation marker plus the same directory-trust fixture must produce the protected mid-run permission wake and omit the startup accept command.

### Mutation proof

After the targeted tests pass, make one temporary product-code mutation in the disposable worktree that disables the Codex startup-trust branch in the shared classifier without changing the fixture.
Run `tests/fm-spawn-startup-trust.test.sh` and require a nonzero result whose failure names the missing Codex startup report.
Verify that the sibling busy-processing control still passes so the red result is tied to the disabled guard rather than a broken fixture environment.
Restore the product branch with a reverse patch and require the same test to pass.

Make a second temporary mutation that sends Enter inside the recognized-dialog reporting branch.
The actual backend boundary assertion must fail because it observes one additional key, while the explicit `fm-send.sh` positive control demonstrates that the log is capable of seeing that key.
Restore the mutation with a reverse patch and rerun green.
These two mutations prove both halves of the contract: the guard fires on a known startup dialog, and surfacing never becomes approval.

### Live use

Before completion, exercise the feature with a real verified harness in an isolated scratch firstmate home and a newly created repository path that has not yet been trusted.
The spawn command must print the loud report while the real pane remains visibly blocked on the trust dialog.
Capture the pane again before any manual action and verify that the dialog is still present.
Only after that evidence is recorded may the printed command be run as an explicit trust decision for the scratch repository.
Verify that the brief then begins processing and that no second key was sent by the reporter.

The live exercise must record the harness version, backend, exact commands, output, and pane evidence without exposing credentials.
At least one live Codex directory-trust path is required because that is the incident path this design closes.
Claude workspace and hook-review paths require live coverage when reproducible without changing shared harness configuration.

## Delivery sequence

The implementation extracts the shared classifier, adds the common post-commit spawn reporter, adds the watcher fallback, and extends colocated tests in one route-complete change.
Delivery requires `bin/fm-lint.sh`, the two mutation proofs, and the isolated live Codex exercise described above.
No implementation step may auto-accept a prompt.

## Live verification record

On 2026-08-04, Codex CLI `0.146.0-alpha.9.2` was launched by the real `fm-spawn.sh` path on an isolated private tmux server and a newly leased scratch worktree.
The spawn output reported `STARTUP TRUST DIALOG`, named `codex-directory-trust`, printed the scoped `fm-send.sh <id> --key Enter` command, and stated that no input was sent.
A separate pane capture before any action positively showed the complete directory-trust dialog while `pane_current_command` was `codex`.
Only then was the printed command executed, after which the directory dialog cleared.

That explicit decision exposed a second Codex startup prompt for project hooks whose complete current shape is not in the verified classifier set.
The real watcher fallback reported `startup-unconfirmed`, classified both brief processing and a known dialog as `UNKNOWN`, printed only the scoped peek command, and sent no input.
After an explicit choice to continue without trusting hooks, Codex replied with the brief's exact `LIVE_STARTUP_TRUST_BRIEF_PROCESSING` marker and the current-launch turn-end file existed.
This demonstrates the route-completeness distinction: endpoint creation is closed by the common spawn reporter, while a late or not-yet-recognized startup shape remains closed by the watcher's actionable UNKNOWN class rather than by an unsafe inferred absence.
