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
A Lavish board is a live surface, so reconcile it against live fleet state before serving or updating it and never render it from a remembered snapshot; `AGENTS.md` section 9 owns the serve-fresh rule.

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

## Show the actionable plan

- Include every in-flight item; silently omitted work makes the board incomplete.
- For each item, show the real end-to-end path to done: every remaining step, the owner or condition gating it, and the concrete downstream consequence when it lands; never substitute a bare status label.
- When work spans execution resources, show its capacity-aware distribution by lane, harness, and model using current capacity and quota without embedding values that will rot.
- State the pacing and concurrency limits being held to protect fleet health.
- Clearly separate work proceeding autonomously under standing rules from items that genuinely require the captain's decision, and give decision controls only to the latter.

## Serve and verify

1. Serve the board with `lavish-axi <file> --no-open --no-gate`.
   `--no-open` suppresses the auto-open, and `LAVISH_AXI_NO_OPEN=1` does the same.
   `--no-gate` skips the open-time layout curtain, which is the difference between a working board and a blank one.
   The curtain is CSS, not a hang: Lavish renders the shell with `body.layout-gate-active`, and `body.layout-gate-active iframe#artifact { opacity: 0 }` keeps the artifact invisible while the chrome paints, until the layout audit clears or a safety timer expires.
   The gate is decided per request from the query string, so `?no-gate=1` on any already-served session URL uncurtains it with no re-serve; `?gate=0` is equivalent.
   `--no-gate` sets no server-side state - it only stamps `?no-gate=1` onto the URL it prints, so the curtain returns the moment that parameter is dropped.
   Carry the full printed URL, query string included, through every later step.
2. Extract the printed session URL without its surrounding double quotes.
   A safe extraction pattern is `grep -oE 'https?://[^ "]+'`; verify that no quote or punctuation trails the URL.
3. Open every board in its own dedicated Chrome window with `open -na "Google Chrome" --args --new-window "<url>"`.
4. Start `lavish-axi poll <file>` silently and leave it running while review continues.
   Re-run it after every response while review continues.
   Treat the board as not ready until the tool-authoritative connection signal confirms that it is genuinely connected.
   The transition to connected can take several minutes and is expected; during that lag, do not act on a poll return or prematurely re-serve, re-open, abandon, or otherwise thrash the session.
   Create and select a `chrome-devtools-axi` page for the exact served URL, then use a bounded retry to inspect that page's snapshots.
   The artifact iframe is sandboxed `allow-scripts allow-forms allow-popups allow-downloads`, without `allow-same-origin`, so parent-frame JS evaluation can never reach into it.
   Verify board content with a snapshot that crosses frames, never with an expression evaluated against the parent page.
   Diagnose a board that looks blank with `curl -s <url> | grep -o '<body class="[^"]*"'`: `lavish layout-gate-active` means the curtain is on and `lavish` alone means it is off.
   The browser tab title is not a gate indicator; verified 2026-07-30, it reads `<artifact title> · Lavish` when the artifact HTML carries a `<title>` and bare `Lavish Editor` when it does not, identically with and without the curtain.
   Pass only after the layout-audit-in-progress indicator has cleared and no layout-issue indicator is present, confirming zero error-severity `layout_warnings` for that board.
   A returned snapshot alone is not success; if the bound expires while the audit remains in progress, treat the board as unverified and do not surface it.
   Consult `chrome-devtools-axi --help` and the relevant command help for current commands and flags.
   Do not announce the board as ready until that check passes.
   If the audit finds an error while the layout gate is still holding the board, fix it and verify again before the captain can answer.
5. Name the board when surfacing it so the captain knows which decision surface is awaiting action.
   Accompany it in the CLI with only a bare pointer to the board, never the substantive decision content.

## Protect answers

- A board in front of the captain is theirs, and that ownership is absolute while it is open.
- Never navigate, reload, re-serve, or end it, never edit the file behind it, and never run browser automation against that window, including a read-only snapshot.
- Verification with `chrome-devtools-axi` belongs before the board is surfaced; once the captain has it, the window is off limits too.
- The test before any action is whether it could change what is on the captain's screen right now; if it could and their input may be unsubmitted, do not do it.
- Answer preservation takes precedence over the serve-fresh rule while the captain has unsubmitted input; a board showing slightly stale state costs one correction, while a cleared board costs the captain's answers outright.
- Never edit, refresh, or reload a served board while the captain is answering because doing so clears in-progress input.
- Fix a problem with a live board server-side or not at all; a per-request option such as `?no-gate=1` is safe because it changes only what a fresh request renders, whereas re-serving or editing the file is not.
- After submission, reconcile and refresh before continuing; if freshness must be preserved sooner, use only a strategy proven to retain the captain's current input without editing, refreshing, or reloading the served board.
- When poll feedback arrives, write every annotation to the chosen durable file immediately, before interpreting it, acting on it, or doing anything else.
- Never rely on poll output or conversation memory as the only copy because ephemeral poll output can be reaped.
- Treat a `lavish-axi poll` return as transport or lifecycle output, not automatically as the captain's answer.
- Act only after genuine connection and receipt of one unambiguous batch with `submission: "explicit-send-batch"`, a nonempty structured `answers` array, and a manifest containing `expectedQuestionKeys` and `expectedCount`.
- Accept the batch only when the manifest keys are nonempty and unique, its count equals its key count, and every manifest key has exactly one structured answer entry with the same key and a nonempty `answer` value.
- Reject absent, empty, extra, or duplicate answer keys, every manifest mismatch, and every disconnect, UI flicker, re-poll, layout or audit return, session event, unmarked return, or ambiguous return; ignore them and keep waiting.
- If a return is ambiguous or lacks a clear explicit-decision payload, treat it as not submitted and do not act until the captain's actual answer is verified in the payload.
