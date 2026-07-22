# Claude context compaction recovery

This document is the authoritative contract and empirical record for Firstmate's Claude Code context-compaction bridge.

## Contract

Tracked `.claude/settings.json` registers `bin/fm-autocompact.sh capture` for `PreCompact` and `bin/fm-autocompact.sh recover` for `SessionStart` with matcher `compact`.
The capture phase atomically replaces `data/autocompact-resume.md` with a deterministic view of durable fleet state before either manual or automatic compaction.
The anchor includes the full backlog, every in-flight `state/*.meta` file, and the complete local-only bearings projection with current task state, open decisions, held queued work, recorded PRs, reports, endpoint health, task paths, and next actions.
Hook payload parsing does not require `jq`; when `jq` is unavailable, capture logs a loud limitation and publishes the complete raw backlog and metadata while marking the derived bearings projection unavailable.
The capture path makes no GitHub or other network call.
An in-scope capture failure exits 2 and blocks compaction rather than silently crossing the boundary without a fresh anchor.

After compaction, Claude Code emits a new `SessionStart` event with `source=compact` before the next model request.
The recovery phase prints the fresh anchor and the output of `bin/fm-session-start.sh` to stdout.
If its compact-scoped hook payload is unreadable or invalid, recovery prints a loud warning and still emits durable context; only a successfully parsed non-compact `SessionStart` is a silent no-op.
Claude Code adds that stdout to the compacted context, so Firstmate receives the normal lock, bootstrap, wake-queue, backlog, task, status-tail, endpoint, and supervision reconciliation before it resumes.
That injected digest is the resumed session's single session-start pass; Firstmate does not run `bin/fm-session-start.sh` again after control returns to the model.
The compact summary is explicitly treated as lossy and subordinate to those durable sources.

The tracked hook is inert in a non-Firstmate repository and in an unmarked linked crewmate or scout worktree.
A valid secondmate home is in scope because it is a Firstmate primary in its own home.
The existing `Stop` and `PreToolUse` hooks remain separate and unchanged.

## Conversation-only boundary

A shell `PreCompact` hook cannot invoke the interactive `stow` skill or make the model judge uncaptured conversation-only knowledge.
The hook therefore captures only deterministic file state.
Long Claude primary runs periodically load `stow` while context is still available, and that skill remains the single owner of knowledge routing to captain preferences, fleet learnings, project memory, task notes, and backlog work.

`PreCompact` stdout is not the recovery transport.
Manual compaction records successful hook stdout as local-command output, but automatic compaction has no equivalent user command boundary and Claude's documented context-output contract reserves direct stdout injection for events including `SessionStart`.
The compact-sourced `SessionStart` hook is therefore the reliable transport for the anchor and reconciliation digest.

## Empirical validation - 2026-07-22

Event discovery ran in a git-initialized scratch project under `/tmp`, with project-only Claude settings and an isolated event log.
The implementation proof ran in a plain git fixture under the task worktree with an explicit fixture `FM_HOME`, and no tracked hook was registered into the live Firstmate primary settings.

Claude Code version at the final probe was `2.1.217` on Darwin.
The scratch settings registered logging commands for `PreCompact`, `PostCompact`, and `SessionStart` matcher `compact`.

Manual probe command:

```text
claude --setting-sources project --dangerously-skip-permissions --model haiku --no-chrome
/compact empirical manual probe
```

The successful manual event payloads were:

```text
PreCompact:  {"hook_event_name":"PreCompact","trigger":"manual","custom_instructions":"empirical manual probe"}
SessionStart: {"hook_event_name":"SessionStart","source":"compact","model":"claude-haiku-4-5-20251001"}
PostCompact: {"hook_event_name":"PostCompact","trigger":"manual","compact_summary":"TURN_FOUR"}
```

Automatic probe command and setup:

```text
CLAUDE_CODE_AUTO_COMPACT_WINDOW=20000 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50 \
  claude --setting-sources project --dangerously-skip-permissions --model haiku --no-chrome
```

The scratch session accumulated bounded repeated Bash results until Claude displayed `Running PreCompact hooks`, compacted in the middle of the autonomous turn, ran the compact-sourced `SessionStart` and `PostCompact` hooks, and then resumed the same turn to its requested terminal response.
The successful automatic event payloads were:

```text
PreCompact:  {"hook_event_name":"PreCompact","trigger":"auto","custom_instructions":null}
SessionStart: {"hook_event_name":"SessionStart","source":"compact","model":"claude-haiku-4-5-20251001"}
PostCompact: {"hook_event_name":"PostCompact","trigger":"auto","compact_summary":"<generated summary>"}
```

The event order for both successful paths was `PreCompact`, compact-sourced `SessionStart`, then `PostCompact`.
The manual probe also showed that `PreCompact` fires before an attempted `/compact` that later reports `Not enough messages to compact`, so capture must be safe and replace the prior anchor idempotently.
The implementation proof then compacted a fixture Firstmate session through the tracked commands, confirmed that the anchor held fixture backlog and PR markers, and asked the resumed model to repeat backlog, status-tail, and PR markers without reading files.
The model returned `RECOVERED:E2E_BACKLOG_ANCHOR_7421:E2E_IN_FLIGHT_ANCHOR_8842:9999`, proving that compact-sourced `SessionStart` stdout carried both the anchor and normal reconciliation into the resumed context.
Automated coverage in `tests/fm-autocompact.test.sh` verifies atomic refresh, complete pickup surfaces, failure blocking, primary scoping, tracked registration, and post-compact anchor plus session-start recovery.
