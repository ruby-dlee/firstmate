---
name: lavish-repair
description: >-
  Agent-only recovery playbook for a self-contained Lavish board that fails answerability preflight, default-browser open, interaction, answer download, or bounded intake.
  Use before touching a generated board or downloaded-answer artifact during a surface incident.
  Do not use it to create or present a decision; use `lavish-decisions` for that.
user-invocable: false
metadata:
  internal: true
---

# Lavish repair

Prove the failing layer before changing any durable artifact.
The Lavish fork has no server, session URL, live channel, browser automation session, listener, poller, or armed submission check to repair.
Never invoke upstream serve, poll, browser, or server-lifecycle commands.

## Start from the owners

Read `bin/fm-lavish-board.sh`'s header and `--help` output for the current preflight and default-browser-open mechanics.
Read `tools/lavish/README.md` for the durable decision, downloaded payload, and intake protocol.
Load `lavish-decisions` before completing the normal consume workflow.

Establish the exact decision id, resolved Firstmate home, helper output, generated HTML path, and browser download location before diagnosing the incident.
Preserve any downloaded answer JSON, manual payload backup, and unsubmitted captain input.
Do not edit `request.md` or `manifest.toon`, because their digest and ordered question or item set are immutable.

## Diagnose in route order

### 1. Answerability preflight

When the helper refuses an unanswerable board, read its named missing components.
Do not bypass the preflight or substitute hand-authored HTML.
Resolve checkout or installed-tool version skew against the active helper and Lavish fork before trying the helper again.

The helper has not invoked the default browser when this check fails.
Surface the exact terminal fallback emitted by `lavish-axi create` instead of reporting that a board is open.

### 2. Browser open

When preflight succeeds but the operating system cannot open the generated file, retain the helper's exact error and HTML path.
Do not launch a dedicated browser profile, Chrome DevTools process, browser automation session, server, or resident helper as a workaround.
Open the existing self-contained file through the host's ordinary default-browser surface, or use the exact terminal fallback from the creation result.

### 3. Board interaction

When the board opens but is visibly broken, protect any unsubmitted captain input before reloading or reopening the generated file.
If the rendered controls, review step, download button, or manual payload backup are missing, treat that as generator or version drift and return to the answerability-preflight branch.
Do not edit the generated page to manufacture an answer path.

### 4. Downloaded answer

The board's landing record is `lavish-answer-<decision-id>.json` in the browser's download location.
The board also exposes the exact JSON as a manual backup so a blocked automatic download does not erase the completed batch.
If needed, save that backup under the same filename in the normal or `LAVISH_DOWNLOADS_DIR` location, preserving every byte the board produced.

Do not report automatic delivery or wait for a submission prompt; neither exists.
Do not add browser-profile storage, an armed check, filesystem watcher, timer sweep, long poll, server, or resident process.
When the captain says the answer is saved, continue immediately to one bounded intake.

### 5. Intake and collection

Run `lavish-axi intake --home <resolved-absolute-home>` once and inspect its complete result.
Intake discovers the home-bound download, validates the schema, decision id, request digest, ordered keys, and declared values, commits `answer.toon`, writes the declared destination, and then writes `receipt.toon`.
Confirm receipt only after that validated path succeeds.

Treat a named payload or `lavish-axi collect` validation error as a payload or immutable-request mismatch, not a browser failure.
Preserve the rejected payload for diagnosis and do not weaken the schema, key, option, annotation, home-marker, or request-digest checks.
Do not ask the captain to answer again when the same valid answer has already been saved durably.

## Recovery boundary

A surface failure does not erase the durable decision, a downloaded payload, a manual payload backup, or a collected answer.
Use `lavish show` and `lavish inbox` with the explicit Firstmate home to distinguish pending from already answered state.
Reopen a board only when no submitted payload exists and the captain's unsubmitted input has been protected or is known to be absent.
If the browser route remains unavailable, the exact `lavish answer ... --home ...` creation fallback keeps the decision answerable without browser infrastructure.
