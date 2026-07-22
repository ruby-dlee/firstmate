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

Build captain-facing Lavish decision boards as actionable, layout-safe surfaces.
A read-only status page is not a decision surface.

## Build

1. Copy `assets/lavish-board-template.html` from this skill directory into the board's working location.
   Use the asset as the starting point instead of recreating its typography or layout reset.
   Do not tighten its line heights, tracking, text padding, wrapping, or card spacing because those values are the layout-audit-safe baseline.
2. Run `lavish-axi playbook input` before writing the board, plus every other playbook that matches the content.
   Treat `lavish-axi --help` as the authority for current CLI behavior and flags.
3. Give every decision a native radio group or select control and a queue/submit path that calls `window.lavish.queuePrompt`.
   Queue exactly one prompt when the question is submitted, never on each option change.
   Show selected state separately from queued state so the captain can tell what will be sent.
   Keep a visible path for sending queued answers.
4. Choose a durable feedback destination before polling, such as the task spec, backlog note, or task data file.

## Serve and verify

1. Serve the board without auto-opening by passing `--no-open` or setting `LAVISH_AXI_NO_OPEN=1`.
2. Extract the printed session URL without its surrounding double quotes.
   A safe extraction pattern is `grep -oE 'https?://[^ "]+'`; verify that no quote or punctuation trails the URL.
3. Open every board in its own dedicated Chrome window with `open -na "Google Chrome" --args --new-window "<url>"`.
4. Start `lavish-axi poll <file>` silently and leave it running while review continues.
   Re-run it after every response while review continues.
   Use that file-specific poll to verify zero error-severity `layout_warnings` for the served board.
   Do not announce the board as ready until the poll's layout check passes.
   If the audit finds an error while the layout gate is still holding the board, fix it and verify again before the captain can answer.
5. Name the board when surfacing it so the captain knows which decision surface is awaiting action.
   Accompany it in the CLI with only a bare pointer to the board, never the substantive decision content.

## Protect answers

- Never edit a served board while the captain is answering because live reload clears in-progress input.
- When poll feedback arrives, write every annotation to the chosen durable file immediately, before interpreting it, acting on it, or doing anything else.
- Never rely on poll output or conversation memory as the only copy because ephemeral poll output can be reaped.
