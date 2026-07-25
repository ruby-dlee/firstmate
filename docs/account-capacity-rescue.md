# Automatic account-capacity rescue

Firstmate automatically hands a direct-account ship or scout task to a fresh agent when verified provider TUI chrome shows that its current account has exhausted capacity.
The handoff deliberately replays the task brief in the recorded worktree through `bin/fm-spawn.sh <id> --recover-direct-account`.
It does not migrate the exhausted provider session.

## Empirical detection signatures

The classifier matches only a bounded final pane tail from the harness recorded in task metadata.
It never treats generic API errors, task prose, documentation, or a quoted sentence without the harness chrome as account exhaustion.

The following signatures came from real local pane captures recovered from harness transcript archives on 2026-07-25.

Codex rendered this standalone warning line:

```text
⚠ Selected model is at capacity. Please try a different model.
```

The local Codex installation reported `codex-cli 0.145.0-alpha.30` when the evidence was checked.
The archived pane capture did not embed its originating Codex version, so the installed version is environment evidence rather than proof of the capture's exact producer version.

Claude rendered this tool-result line:

```text
  ⎿  You've hit your session limit · resets 5pm (America/New_York)
```

The same exhausted Claude session also rendered this complete choice dialog:

```text
What do you want to do?

❯ 1. Stop and wait for limit to reset
  2. Switch to usage credits
  3. Switch to Team plan

Enter to confirm · Esc to cancel
```

The transcript carrying that capture recorded Claude Code `2.1.207`.
The installed Claude version was `2.1.220` when the evidence was checked.

The evidence search used fixed-string scans of the machine-local `~/.claude/projects` transcript archive, followed by inspection of the surrounding captured pane and version records.
The runtime version checks were:

```sh
codex --version
claude --version
```

`provider_capacity_failure_kind` in `bin/fm-classify-lib.sh` owns the exact classifier.
Codex requires the warning glyph and full anchored sentence.
Claude requires either the result glyph and reset sentence or every line of the complete choice dialog.
An unknown harness never inherits another harness's signatures.

The watcher separately recognizes Claude's anchored `Not logged in - Please run /login` TUI line as a credential failure.
That guard does not rotate accounts, remove the endpoint, consume an attempt, or mark the current account exhausted.
It records `capacity_rescue_stopped=credentials`, appends the single keyed blocked status, and leaves the endpoint available for the required `/login`.
Ordinary prose that mentions the login message does not match, and Codex does not inherit the Claude-only guard.

## Rescue transaction

`bin/fm-watch.sh` runs the capacity classifier immediately after each bounded pane capture, before ordinary busy or stale classification.
Secondmates and legacy managed generations are outside this path because automatic direct-account recovery is defined only for recorded ship or scout tasks with `account_home=` and a direct worktree identity.

On a match, the watcher:

1. Acquires the task's existing account-lifecycle lock and revalidates that the pane still belongs to the recorded task generation.
2. Atomically records the next attempt and exhausted account in task metadata before removing anything.
3. Removes the exhausted endpoint through its recorded runtime backend and requires an affirmative `absent` state.
4. Invokes the existing guarded `bin/fm-spawn.sh <id> --recover-direct-account` path with the capacity-rescue marker.
5. Requires the replacement metadata to bind a different account before reporting success.

The spawn path preserves the task brief, project, worktree, exact Git identity, harness, model, effort, delivery mode, report requirement, and generation identity.
The capacity-rescue marker makes direct selection exclude the current account and every account previously exhausted by that task.
Codex selection also requires a fresh positive general usage score.
Claude selection cannot read config-directory-specific Keychain quota non-interactively, so it advances deterministically through unused account directories.

## Bounded stop and audit fields

The watcher allows at most `FM_CAPACITY_RESCUE_MAX_ATTEMPTS` rescue attempts per task.
The default is `5`; a zero or non-numeric override is ignored in favor of that default.

Each transaction preserves these additive metadata fields across the spawn rewrite:

```text
capacity_rescue_attempts=<count>
capacity_rescue_exhausted_account=<absolute-account-home>
capacity_rescue_attempt_<n>=<UTC>|harness=<name>|account=<absolute-account-home>|failure=<classifier-token>
capacity_rescue_result_<n>=<result>
capacity_rescue_stopped=<terminal-reason>
```

`capacity_rescue_exhausted_account=` may repeat once per exhausted account.
The attempt counter and attempt record are committed before endpoint removal, which makes an interrupted handoff visible instead of silently replayable.
An attempt without a matching result is treated as interrupted and stops without another spawn or a guess about which endpoint generation is safe to remove.
The watcher reconciles that condition from task metadata even when endpoint removal left no live pane to classify.

The selector emits the stable internal prefix `CAPACITY_UNAVAILABLE:` when no unused eligible account remains.
That result, the attempt cap, an unprovable endpoint removal, malformed recovery metadata, a same-account replacement, and a generic recovery failure all set `capacity_rescue_stopped=`, append one keyed `blocked [key=capacity-rescue]:` status, and stop automatic retries.
The Claude credential guard reaches the same durable single-blocked stop without starting a rescue transaction.
Later polls recognize the durable stop marker and absorb the unchanged provider chrome without another endpoint removal, account scan, spawn, or blocked status.

The lifecycle lock serializes capacity rescue with spawn and teardown.
There is no retry timer and no fleet-wide retry loop.
