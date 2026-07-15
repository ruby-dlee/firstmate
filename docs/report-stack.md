# Completion report stack

Firstmate publishes one durable report for every task created after the report-stack cutover.
The default store is `~/.local/share/firstmate/report-stack`, outside every Firstmate home and Claude or Codex account profile.
Set `FM_REPORT_STACK_ROOT` to relocate it.

## Completion contract

New task metadata carries `report_required=1`.
A ship task writes `data/<id>/completion.md`, while a scout keeps using `data/<id>/report.md`.
Both may attach screenshots, diagrams, or other review artifacts under `data/<id>/visuals/`.
Every post-cutover ship and scout report must use the level-two sections Summary, What changed, Verification, Visual evidence, Artifacts, and Follow-ups.

For `report_required` tasks, `fm-teardown.sh` runs all non-destructive safety checks, quiesces the endpoint and confirms it gone while failing closed on an alive or unknown state, then publishes before releasing an account lease or removing a worktree.
If a required heading is absent, publication names every missing heading, identifies the exact report source to edit, and gives the publish and teardown retry commands.
Publication failure leaves the prior durable entry unchanged and stops teardown before destructive cleanup, preserving the task for repair and retry.
Tasks that were already in flight at cutover lack the marker and retain the earlier teardown contract.
An explicit `--force` teardown is a discard and does not create a completion report.
Retiring a persistent secondmate is also not a completion; ordinary tasks completed inside its home publish to the same machine-global stack.

## Stored entry

Each entry contains a manifest, the completion report, the original task brief, the status trail, optional visual artifacts, and a standalone HTML review page.
The entry id is deterministic from the canonical Firstmate home path plus task id, so publication retries replace the same entry instead of duplicating it.
The manifest records routing labels useful for review but never stores provider session ids, auth material, environment values, or account-home contents.
Text artifacts receive defense-in-depth redaction for common credential assignments, private keys, and token formats before storage.
Task briefs and completion reports must still avoid secrets because no heuristic redactor can recognize every credential shape.

The generated `index.html` is an offline searchable card stack with task-type filtering and links to each report page.
Run `bin/fm-report-stack.mjs open` or use `/reports` to regenerate and open it.
Use `list`, `path`, and `render` for terminal or automation access.
Use `publish <id> --legacy` only when intentionally archiving a pre-cutover task; it synthesizes a compatibility report if no normal report source exists.
