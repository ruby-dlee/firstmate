# Away-mode injection wedge

## Incident summary

Claude away-mode failed to wake firstmate overnight for captain-relevant events even though the sub-supervisor daemon remained alive and continued receiving watcher output.

The events were durably queued and batched, but their final delivery depended on typing into Claude's composer through tmux.

That delivery could defer indefinitely when either the pane busy detector or the composer classifier reported a false positive.

The supposed max-defer escape called the same guarded injection path again, so it made the failure visible without making delivery reliable.

All file and line references in this postmortem describe the pre-fix baseline commit `bf7c5ad167514cba879cb095c091fe1627549ccc`, which is the parent of this document's commit.

## Impact

Captain-relevant `needs-decision`, ready-to-merge, and failure signals could remain buffered for the full away period instead of waking firstmate.

The durable wake queue prevented data loss, but firstmate did not drain that backlog until a later session wake, typically when the captain returned.

The failure defeated the core overnight reliability contract while leaving the supervising daemon apparently healthy.

## Failure sequence

1. The watcher wrote every detected wake to `state/.wake-queue` before emitting its marker, as documented in `bin/fm-supervise-daemon.sh:31-37`.
2. The daemon's bash triage absorbed routine events and added captain-relevant summaries to `state/.subsuper-escalations` through `escalate_add` at `bin/fm-supervise-daemon.sh:598-603`.
3. `escalate_flush` read the batch, built one digest, and called `inject_msg` at `bin/fm-supervise-daemon.sh:605-619`.
4. The buffer was deleted only after `inject_msg` returned success, so every failed or deferred injection left the escalation in `state/.subsuper-escalations` at `bin/fm-supervise-daemon.sh:616-619`.
5. `inject_msg` attempted to deliver by typing the digest into Claude's composer at `bin/fm-supervise-daemon.sh:1079-1135`.
6. The tmux implementation performed literal `tmux send-keys -l` followed by Enter at `bin/fm-tmux-lib.sh:157-162`.
7. Before that submit, `inject_msg` returned failure whenever `pane_is_busy` matched the pane tail at `bin/fm-supervise-daemon.sh:1102-1105`.
8. It also returned failure unless `fm_backend_composer_state` was affirmatively `empty` at `bin/fm-supervise-daemon.sh:1115-1119`, so both `pending` and `unknown` deferred delivery.
9. Housekeeping later detected an over-age batch, but housekeeping 1b simply called `escalate_flush` again at `bin/fm-supervise-daemon.sh:939-955`.
10. The same busy and composer guards therefore rejected the same delivery on every later tick when a false-positive condition persisted.
11. Housekeeping wrote `state/.subsuper-inject-wedged` and fired the wedge alarm at `bin/fm-supervise-daemon.sh:947-954`, but it retained the undelivered batch.
12. The marker and alarm made the wedge visible to an already attentive operator, but they did not wake the parked Claude session or deliver the escalation.

## Root cause

The root cause was an unreliable delivery primitive behind guards whose conservative failure mode was unbounded deferral.

Away-mode correctly kept routine supervision in bash and correctly retained captain-relevant events, but it treated tmux composer injection as the only way to wake Claude.

The injection path combined three fragile observations: pane existence, pane-tail activity text, and inferred composer emptiness.

Any persistent false positive in the last two observations prevented `send-keys` from running.

The max-defer path was not a separate recovery mechanism because it re-entered `escalate_flush`, which re-entered `inject_msg`, which re-applied the identical guards.

The code therefore had no transition from "guard says defer" to a reliable wake delivery, regardless of how old the buffer became.

## Why the normal Claude wake did not recover the session

`bin/fm-afk-start.sh:20-24` explains that a native Claude away-mode launch runs the daemon as Claude's tracked background task, and `bin/fm-afk-start.sh:400-401` keeps that command alive by `exec`-ing the long-running daemon.

Claude's reliable native notification occurs when a tracked background task completes.

The daemon is intentionally long-lived, installs termination cleanup at `bin/fm-supervise-daemon.sh:1373-1391`, and remains in its main loop at `bin/fm-supervise-daemon.sh:1420-1480` while watcher children are restarted and housekeeping continues.

A guard-deferred escalation neither completed nor terminated that daemon.

The daemon staying alive all night therefore meant the tracked background task never completed, so the normal Claude reap-wake notification never fired either.

This produced the paradoxical incident signature: the supervisor process was healthy, the queue and escalation buffer were durable, and the LLM was never woken.

## Concrete false-positive candidates

The incident mechanism does not require one particular rendering bug because any persistent busy or non-empty classification wedges the shared injection path.

Two concrete Claude TUI conditions can sustain those classifications.

- Busy footer: `bin/fm-afk-start.sh:20-24` runs the daemon as one of Claude's own tracked background tasks, so Claude can render a persistent background-task footer while otherwise idle.
- Busy footer: `pane_is_busy` scans the pane's final six lines against the busy regular expression at `bin/fm-tmux-lib.sh:127-134`, so a footer containing a matching activity phrase can classify the primary as busy forever.
- 256-color ghost: the composer placeholder stripper documents its history of ghost text causing false `pending` classifications at `bin/fm-composer-lib.sh:25-39`.
- 256-color ghost: `fm_composer_strip_ghost` deliberately does not luminance-test `38;5;n` foreground colors and keeps that text at `bin/fm-composer-lib.sh:77-81`, so a placeholder rendered with a 256-color code can survive stripping and look like pending user content.

The busy-guard form of the wedge was reproduced deterministically in an isolated worktree state directory by forcing `pane_is_busy` to stay positive and aging the escalation beyond the max-defer threshold.

After one housekeeping pass, the reproduction still had one buffered escalation and had created `state/.subsuper-inject-wedged`, proving that max-defer surfaced the condition without delivering it.

## Prior evidence

The source already recorded the same structural failure class before this incident.

`bin/fm-supervise-daemon.sh:622-628` describes an earlier passive-marker incident in which 20 escalations remained buffered for about 8.5 hours.

`docs/wedge-alarm.md:8-15` records that the first response added an active alert while retaining the marker, which improved visibility but did not replace composer injection.

`docs/herdr-backend.md:524-552` records both an `unknown` composer-state redelivery incident and ghost text that caused a false `pending` result until the wedge marker surfaced.

`docs/herdr-backend.md:762-767` summarizes the accumulated guard hardening and the max-defer alarm, demonstrating that the path had become a history of rendering-specific mitigations rather than a delivery guarantee.

## Corrective action

The delivery path must use Claude's native tracked-background-task completion wake instead of typing into the composer.

The daemon should retain its bash triage and batching so routine wakes do not spend LLM tokens.

Only a captain-relevant batch should cause the tracked daemon task to complete, with `state/.wake-queue` remaining the lossless backlog that the woken firstmate drains.

That design removes the busy and composer guards from captain-relevant delivery while preserving the token-saving parked-LLM behavior.

The implementation and regression coverage follow this postmortem as a separate commit in the same single-concern pull request.
