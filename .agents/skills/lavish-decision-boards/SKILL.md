---
name: lavish-decision-boards
description: >-
  Agent-only workflow for building actionable, captain-facing Lavish decision boards and approval or triage surfaces.
  Use before creating or revising any Lavish board that asks the captain to choose options, approve a plan, triage findings, set scope, or provide structured feedback.
user-invocable: false
metadata:
  internal: true
---

# lavish-decision-boards

Build a captain-facing decision surface as an actionable, layout-safe Lavish board.
A read-only status page is not a decision surface.

## Build

1. Copy `assets/lavish-board-template.html` from this skill directory into the board's working location.
   Use the asset as the starting point instead of recreating its typography or layout reset.
   Do not tighten its line heights, tracking, text padding, wrapping, or card spacing because those values are the layout-audit-safe baseline.
2. Run `lavish-axi playbook input` before writing the board, plus every other playbook that matches the content.
   Treat `lavish-axi --help` as the authority for current CLI behavior and flags.
3. Give every decision a native radio group or select control, but hold all choices in local page state until one explicit `Send answers` action.
   Never call `window.lavish.queuePrompt` on selection, change, or a per-question step; a partial selection must never be actionable.
   The single send handler must first gather and validate all current form state, then call `window.lavish.queuePrompt` exactly once with one structured batch envelope and immediately call `window.lavish.sendQueuedPrompts()` in that same click handler.
   The envelope must contain `submission: "explicit-send-batch"`, an `answers` array, and a manifest with the full expected question-key set and count.
   Reject missing or duplicate question keys before queueing.
   Acquire a one-shot in-flight lock and disable the send button before queueing so rapid clicks cannot duplicate the batch.
   This keeps the Lavish queue empty before the explicit send, so a disconnect has nothing to auto-flush and in-progress input cannot reach the agent.
4. Choose a durable feedback destination before polling, such as the task spec, backlog note, or task data file.

## Serve and verify

1. Serve the board without auto-opening by passing `--no-open` or setting `LAVISH_AXI_NO_OPEN=1`.
2. Extract the printed session URL without its surrounding double quotes.
   A safe extraction pattern is `grep -oE 'https?://[^ "]+'`; verify that no quote or punctuation trails the URL.
3. Open every board in its own dedicated Chrome window with `open -na "Google Chrome" --args --new-window "<url>"`.
4. Start `lavish-axi poll <file>` silently and leave it running while review continues.
   Re-run it after every response while review continues.
   Treat the board as not ready until the tool-authoritative connection signal confirms that it is genuinely connected.
   The transition to connected can take several minutes and is expected; during that lag, do not act on a poll return or prematurely re-serve, re-open, abandon, or otherwise thrash the session.
   Create and select a `chrome-devtools-axi` page for the exact served URL, then use a bounded retry to inspect that page's snapshots.
   Pass only after the layout-audit-in-progress indicator has cleared and no layout-issue indicator is present, confirming zero error-severity `layout_warnings` for that board.
   A returned snapshot alone is not success; if the bound expires while the audit remains in progress, treat the board as unverified and do not surface it.
   Consult `chrome-devtools-axi --help` and the relevant command help for current commands and flags.
   Do not announce the board as ready until that check passes.
   If the audit finds an error while the layout gate is still holding the board, fix it and verify again before the captain can answer.
5. Name the board when surfacing it so the captain knows which decision surface is awaiting action.
   Accompany it in the CLI with only a bare pointer to the board, never the substantive decision content.

## Protect answers

- Never edit a served board while the captain is answering because live reload clears in-progress input.
- When poll feedback arrives, write every annotation to the chosen durable file immediately, before interpreting it, acting on it, or doing anything else.
- Never rely on poll output or conversation memory as the only copy because ephemeral poll output can be reaped.
- Treat a `lavish-axi poll` return as transport or lifecycle output, not automatically as the captain's answer.
- Act only after genuine connection and receipt of one unambiguous batch with `submission: "explicit-send-batch"`, a nonempty structured `answers` array, and a manifest containing `expectedQuestionKeys` and `expectedCount`.
- Accept the batch only when the manifest keys are nonempty and unique, its count equals its key count, the answer keys are nonempty and unique, and the answer-key set exactly equals the manifest-key set.
- Disconnects, UI flicker, re-polls, layout or audit returns, session events, and empty, partial, subset, missing-answer, unmarked, or ambiguous payloads are not submissions; ignore them and keep waiting.
- If a return is ambiguous or lacks a clear explicit-decision payload, treat it as not submitted and do not act until the captain's actual answer is verified in the payload.
