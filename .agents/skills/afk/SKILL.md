---
name: afk
description: Enter away-mode supervision. Use when the user invokes /afk (e.g. "/afk", "/afk back in an hour", "going afk"). Sets a durable away-mode flag so the sub-supervisor daemon can self-handle routine wakes and escalate captain-relevant events plus bounded declared-external-wait rechecks as batched digests, cutting supervision token cost during walk-away stretches. Exit is automatic; any real user message returns to full per-wake responsiveness.
user-invocable: true
metadata:
  internal: true
---

# afk

Away mode is an explicit, captain-consented token-saving tradeoff.
The daemon triages routine wakes in bash instead of waking firstmate's LLM for each one.
Captain-relevant events still wake firstmate as one pre-read batch.

## Enter away mode

1. Run `bin/fm-afk-launch.sh start-native` when the current harness provides a native tracked-background tool, including Claude Code's background bash.
2. Run `FM_AFK_STATE_PREPARED=1 bin/fm-afk-start.sh` as its own native tracked background task.
3. Run `bin/fm-afk-launch.sh start` only on a harness without a native tracked-background tool.
4. Do not wrap either daemon entry in `nohup`, shell `&`, or another fire-and-forget shell.
5. Do not separately arm `bin/fm-watch-arm.sh` or `bin/fm-watch.sh` while `state/.afk` exists.
6. Acknowledge that away mode is active and that any real captain message ends it.

`bin/fm-afk-launch.sh` owns the durable flag, stale-artifact clearing, terminal record, rollback, and stop ordering.
The native launch record makes `bin/fm-afk-start.sh` select `reap-wake` delivery automatically.
The terminal-backed path remains a compatibility mode for harnesses without a native background completion notification.
Never manufacture a daemon terminal by splitting the captain's active pane.

## Native reap-wake lifecycle

On Claude, the tracked away daemon is the parked LLM's wake task.
The daemon keeps that task running across routine signal, stale, and heartbeat events while its bash classifier absorbs them.
When a batched captain-relevant escalation becomes due, the daemon prints one line beginning `afk-reap-wake:` and exits cleanly.
Claude Code's native background-task completion notification then wakes the parked LLM through the same primitive used by normal Claude supervision.
The native delivery path does not inspect a pane, type into the composer, use a busy guard, classify composer text, or call `send-keys`.

Treat a completed tracked away task whose output includes a line beginning `afk-reap-wake:` as an internal escalation rather than a captain return message.
Stay in away mode, drain `state/.wake-queue`, process the distilled batch, and surface only captain-relevant outcomes.
If `state/.afk` still exists at the end of that turn, run `bin/fm-afk-launch.sh start-native` and start a fresh `FM_AFK_STATE_PREPARED=1 bin/fm-afk-start.sh` native background task as the turn's final supervision action.
Restart the away daemon, not `fm-watch-arm.sh`, because the daemon continues to own and wrap the watcher.

The durable wake queue is authoritative and lossless.
The `afk-reap-wake:` line is a pre-read reason that explains why the tracked task completed.
Routine queue records may be present beside the captain-relevant record because the daemon batches and triages before waking the LLM.

## Terminal-backed compatibility delivery

A harness without a native tracked-background tool uses `bin/fm-afk-launch.sh start` to create one non-visible tracked terminal.
That compatibility path passes `FM_SUPERVISOR_TARGET` and `FM_SUPERVISOR_BACKEND` explicitly and delivers through the existing verified pane submit path.
It retains the busy guard, affirmative-empty composer guard, type-once submit, `FM_MAX_DEFER_SECS` alarm, and `state/.subsuper-inject-wedged` marker.
The compatibility path prefixes its injected message with `FM_INJECT_MARK`, ASCII unit separator `0x1f`, so firstmate can distinguish it from a real captain message in the shared input channel.
The marker never appears on native reap-wake delivery because a background-task completion is not a user message.

## Exit away mode

No `/back` command is required.

- A completed native task whose output includes an `afk-reap-wake:` line is internal, so stay away and follow the native reap-wake lifecycle above.
- A legacy message beginning with `FM_INJECT_MARK` is an internal terminal-backed escalation, so stay away and process it.
- A message beginning with `/afk` refreshes away mode rather than ending it.
- Any other real user message means the captain is back.

On a real return message, run `bin/fm-afk-launch.sh stop` before clearing any state yourself.
The launcher stops the daemon while `state/.afk` still exists, closes any exact recorded terminal, and clears `state/.afk` last.
Native shutdown preserves any buffered escalation for catch-up, while terminal-backed compatibility shutdown may make its final guarded submit while the flag is still present.
Drain `state/.wake-queue`, summarize any pending `state/.subsuper-escalations`, surface any legacy `state/.subsuper-inject-wedged` marker, and resume the primary harness supervision protocol emitted at session start.
Bias ambiguous user-message cases toward exit because a present captain beats token savings and a false exit is self-correcting.

## Approval authority

Away mode changes wake frequency, not approval authority.
A PR ready for merge, an ask-user finding, a destructive action, an irreversible action, or a security-sensitive choice still requires the same approval it required before away mode.

## Classification and batching

The daemon wraps `bin/fm-watch.sh`, classifies each wake in bash, and self-handles the routine majority without consuming a firstmate turn.
The shared `bin/fm-classify-lib.sh` owns the captain-relevant verbs, declared-pause vocabulary, signal and stale decisions, and catch-all scan used by both normal and away supervision.
While `state/.afk` exists, the watcher reverts to one-shot enqueue-and-exit behavior and lets the daemon own triage.

- A `signal` with `done:`, `needs-decision:`, `blocked:`, `failed:`, `PR ready`, `checks green`, `ready in branch`, or `merged` escalates.
- A routine `signal` self-handles.
- A declared `paused:` external wait self-handles and re-surfaces after `FM_PAUSE_RESURFACE_SECS`, which defaults to 3600 seconds.
- A `check` always escalates because check scripts print only when firstmate should wake.
- A terminal `stale` escalates immediately.
- A non-terminal `stale` rechecks after `FM_STALE_ESCALATE_SECS`, which defaults to 240 seconds, and escalates only if it remains a possible wedge.
- A `heartbeat` self-handles while the daemon's cheap fleet scan backs up missed captain-relevant statuses.
- An unknown or uncertain reason escalates fail-safe.

Escalations batch for up to `FM_ESCALATE_BATCH_SECS`, which defaults to 90 seconds and accepts zero for immediate delivery.
Native delivery completes the tracked task at that batch deadline without any pane-dependent defer condition.
Legacy terminal-backed delivery retains `FM_MAX_DEFER_SECS` because its guarded submit can still defer.
`FM_INJECT_SKIP`, which defaults to `heartbeat`, force-self-handles matching reason prefixes and should be used sparingly.

## State lifecycle

`state/.wake-queue` is the durable work record and survives daemon crashes, notification loss, and firstmate restarts.
`state/.subsuper-escalations` and its `.since` sidecar are a transient batch cache.
`state/.subsuper-inject-wedged` is a legacy terminal-backed delivery alarm and is not created by native reap-wake delivery.
Always enter through `bin/fm-afk-launch.sh`, which clears prior-session transient artifacts only on a fresh away session and preserves the current session's buffer on refresh.
Always exit through `bin/fm-afk-launch.sh stop`, which preserves the flag until daemon shutdown completes and clears it last.

## Reliability properties

These properties must hold for native tracked delivery:

- Routine wakes remain bash-only and do not complete the tracked task.
- A due captain-relevant batch completes the tracked task regardless of busy footers, composer placeholders, pending composer state, or pane readability.
- Claude's native task-completion notification delivers the wake to the parked LLM.
- The durable queue recovers the event if the daemon or harness restarts before firstmate drains it.
- Declared external waits use their own bounded recheck cadence rather than being mislabeled as wedges.
- The catch-all scan backs up the keyword classifier.
- The daemon preserves a single-instance portable lock, watcher crash-loop backoff, and signal-trapped cleanup.

The delivery guarantee assumes the daemon was started as the harness's native tracked background task as required above.
Do not substitute a detached shell process because its exit has no harness notification contract.
