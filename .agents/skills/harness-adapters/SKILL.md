---
name: harness-adapters
description: >-
  Agent-only decision-time reference for firstmate harness operations.
  Use before spawning or recovering a crewmate or secondmate, handling a trust or permission dialog, sending a harness-specific skill invocation, interrupting or exiting an agent, resuming an exited agent, or verifying a new harness adapter.
  Contains compact, version-scoped operation facts for claude, codex, opencode, pi, and grok; mechanics and empirical transcripts stay with their script and documentation owners.
user-invocable: false
metadata:
  internal: true
---

# Harness adapters

Use this reference only for the human decision at a harness boundary.
Resolve current mechanics from their owners instead of copying them here.

## Safety boundary

The verified adapter identifiers are `claude`, `codex`, `opencode`, `pi`, and `grok`.
Never dispatch a crewmate or secondmate on an adapter outside that verified set.
If a harness config names an unverified adapter, report it and fall back to firstmate's own verified harness until the new adapter is empirically verified.
Treat `unknown` detection as unknown; never guess a harness.
A verified identifier does not make stale UI facts current for every newer binary version.
Use the version state in the operation table before relying on a busy signature, key, dialog, or resume command.

For a new adapter, use a trivial supervised raw-launch trial through `bin/fm-spawn.sh` and verify every operation-table field.
Record launch and recovery mechanics in `bin/fm-spawn.sh`, detection in `bin/fm-harness.sh`, busy classification in the watcher/backend owners, and empirical transcripts in the relevant docs.
Add the adapter to this list and table only after that evidence exists.

## Authoritative owners

- `bin/fm-harness.sh` owns detection and crewmate/secondmate harness resolution.
- `bin/fm-spawn.sh` owns launch flags, autonomy, recovery, model/effort mapping, and per-task turn-end hooks.
- `bin/fm-send.sh` owns popup settling and verified text submission.
- `state/<id>.meta` owns the target task's recorded `harness=` value; read it before interrupt, exit, resume, or skill invocation.
- `bin/fm-watch.sh` and `docs/permission-stall-detection.md` own permission-stall detection and captured dialog evidence.
- `docs/turnend-guard.md` owns primary turn-end integrations and validation transcripts.
- `docs/arm-pretool-check.md` owns primary PreToolUse integrations and validation transcripts.
- `docs/supervision-protocols/` owns each primary harness's watcher protocol.
- `docs/tmux-backend.md`, `docs/herdr-backend.md`, `docs/zellij-backend.md`, `docs/orca-backend.md`, and `docs/cmux-backend.md` own runtime-backend behavior and incidents.
- `docs/configuration.md` preserves the historical harness launch-axis validation record.

## Current machine check

Only binary presence and version output were checked on 2026-08-01; no interactive operation was reverified.

| Harness | Current machine | Operation-record status |
| --- | --- | --- |
| `claude` | Installed: `2.1.220 (Claude Code)`. | Legacy operation row did not record its exact version or date and is unverified on 2.1.220; related launch-axis evidence was recorded at 2.1.196 and Stop-hook evidence at 2.1.204, but neither verifies this whole row. |
| `codex` | Installed: `codex-cli 0.146.0-alpha.9.2`. | Operation row last verified 2026-06-11 on 0.139.0; unverified since 0.139.0 and not reverified on the installed version. |
| `opencode` | Not installed. | Operation row last recorded 2026-06-11 across 1.15.7-1.17.6; current behavior is unknown. |
| `pi` | Not installed. | Operation row recorded 2026-06-11 without a binary version, so current behavior is unknown; related primary-hook evidence at 0.80.5 does not verify this whole row. |
| `grok` | Not installed. | Base operation row last verified 2026-06-29 on 0.2.73; slash submission was reverified 2026-07-03 on 0.2.82; all other current behavior is unknown. |

## Compact operation table

Every fact in a row below inherits that harness's operation-record status above.
When a field says unknown, use natural language or the recovery owner instead of inventing a command.

| Harness | Busy signature | Exit / interrupt | Skill invocation | Startup dialog | Resume and load-bearing quirk |
| --- | --- | --- | --- | --- | --- |
| `claude` | `esc to interrupt` | `/exit`; single Escape | `/<skill>` | Workspace trust or bypass-permissions confirmation; `Hooks need review` may require `Trust all on first launch`. | Resume procedure unknown in this record, so use the recovery owner; disable predicted-prompt ghost text only through the launch owner. |
| `codex` | `esc to interrupt` | `/quit`; single Escape | `$<skill>`; `/<skill>` is not the Codex form. | `Do you trust the contents of this directory?` with `Yes, continue` / `No, quit`. | Use `codex resume <session-id>` with the id printed on quit; `$` autocomplete can swallow a fast Enter, so send through `fm-send.sh`. |
| `opencode` | `esc interrupt` | `/exit`; double Escape, historically flaky during long shell calls | No separately verified form; use natural language. | No trust dialog in the last record. | Relaunch with `--continue`, then steer after the TUI appears because `--prompt` did not auto-submit with it; the last record observed a background auto-upgrade from 1.15.7 to 1.17.3 terminating a running TUI. |
| `pi` | `Working...` | `/quit`; single Escape | No separately verified form; use natural language. | Per-path project trust may appear on first run. | Resume procedure unknown in this record, so use the recovery owner; keep a brief as one positional argument because multiple arguments became queued messages. |
| `grok` | `Ctrl+c:cancel` | Double `Ctrl+Q` within 1000 ms; single `Ctrl+C` interrupts; Escape does not interrupt | `/<skill>` | Non-project launches may show `Run Grok Build in a project directory?`; normal spawn starts in a git worktree. | `grok --resume <session-id>` or `grok -c`; slash autocomplete may need a second Enter, so send through `fm-send.sh`. |

## Dialog boundary

Peek after every spawn before assuming the brief started.
Accept a startup trust choice only while the pane is still in its initial spawn handshake, then verify that the brief begins processing.
Once work has started, never reinterpret a trust-looking pane as harmless startup state.
On any mid-run permission or trust prompt, load `stuck-crewmate-recovery`, preserve the pane, and escalate without pressing an approval or denial key.
The dialog shapes below inherit the version status of their operation row.

- Claude protected shapes include `Do you want to proceed?` with `Esc to cancel · Tab to amend`, and `Quick safety check: Is this a project you created or one you trust?` with its trust/exit choices.
- Codex protected shapes include command, permission, edit, or host-network approval questions with `Press enter to confirm or esc to cancel`; a mid-run directory-trust prompt is protected too.
- Pi's recorded project-trust dialog is startup-only; its last record had no permission system after launch.
- OpenCode's last record had no startup trust dialog.
- Grok's recorded project picker applied only outside a project directory; do not turn that old observation into a claim about an unavailable current binary.

## Historical evidence pointers

The detailed primary-hook narratives formerly duplicated here remain in `docs/turnend-guard.md` and `docs/arm-pretool-check.md`.
The 2026-07-03 Grok slash-submit incident and the 2026-07-10 ghost/TRUECOLOR incident remain in `docs/herdr-backend.md`.
The unresolved single-row tmux/Grok placeholder observation is preserved, version-scoped, in `docs/tmux-backend.md`.
Launch-profile version records formerly embedded here are preserved as historical, non-current evidence in `docs/configuration.md`.
Read those owners before modifying an integration; do not promote their old transcripts into a current-version claim without a fresh live verification.
