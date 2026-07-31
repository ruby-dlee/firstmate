---
name: memory-hygiene
description: >-
  Agent-only discipline for keeping firstmate's private memory lean and robust.
  Use before writing, rewriting, pruning, deduplicating, or otherwise leaning entries in data/captain.md or data/learnings.md.
user-invocable: false
metadata:
  internal: true
---

# memory-hygiene

Keep each private-memory entry at the essence of what future firstmate sessions need to act correctly.
This skill owns entry shape for `data/captain.md` and `data/learnings.md` only.
`AGENTS.md` section 6 owns knowledge routing and the files' inspect-then-update, rewrite-in-place contract.
The `/stow` skill owns session sweeps, and `firstmate-coding-guidelines` owns repository-wide knowledge placement and one-owner discipline.

## Promote or delete

Learnings must live where they are read, so this is the first decision on every candidate entry, before any question of wording.

- A rule that should change behavior belongs in the instruction surface that loads at the moment it applies: `AGENTS.md` when every session needs it, or the skill that loads at the triggering moment.
  Promote it there and do not also keep it here.
- Private memory holds only what cannot live in the shared repo: machine-specific and fleet-local facts such as service regions, credential locations, environment drift, and tool quirks specific to this box.
- Promote or delete is the default outcome for a candidate entry; keeping it is the exception that has to earn itself against those two.
- A general rule parked in a private file is the failure mode, not a safe backup.
  Length is not diligence: a file nobody reads at the moment it matters lets its lessons be re-learned the expensive way.
- Convert an incident narrative to the durable fact plus a one-line `[[pointer]]`, or delete it.
- Delete stale and superseded entries outright rather than preserving them for safety.

## Entry standard

- Record only the actionable rule or durable fact.
- Strip emotion, emphasis, interpersonal interpretation, and incident drama.
- Do not preserve that anyone was furious, shocked, disappointed, emphatic, or otherwise emotionally affected.
- Preserve the operational instruction or evidence-backed fact that remains after the mood is removed.
- Limit an entry to the rule or fact plus, at most, a one-line example or a `[[pointer]]` to its detailed source.
- Put incident chronology, rationale, logs, and supporting narrative in their proper detailed source, not private memory.
- Apply `firstmate-coding-guidelines`' one-owner rule when deduplicating memory.
- Fold a new lesson into the existing entry it sharpens instead of adding a near-duplicate.
- Rewrite or prune the owning entry in place so the file converges instead of growing as a log.

## Update practice

1. Apply "Promote or delete" first, then use `AGENTS.md` section 6 to confirm that what remains belongs in one of these private-memory files.
2. Inspect the current file and the candidate owning entry before writing.
3. Search nearby entries for overlap, stale wording, and superseded variants.
4. Reduce the new information to one actionable rule or durable fact.
5. Rewrite the existing owner when one exists; add a new entry only when no owner exists.
6. Remove superseded or duplicate wording in the same update.
7. Read the result once more and cut any detail that does not change future action.

Use a one-line example only when the rule would otherwise be ambiguous.
Use a `[[pointer]]` when a future session may need evidence or context beyond the essence.
Do not use either device to smuggle a narrative back into the memory file.

## Before and after

Before:

> 2026-07-22: The captain was furious after an agent tried to deploy while checks were failing, and stated very firmly that this was completely unacceptable because the incident wasted hours and created a stressful rollback.

After:

> Require green CI before deployment. `[[deploy-incident-2026-07-22]]`

The rewrite retains the future action and a route to evidence.
It drops mood, drama, chronology, and commentary that do not change the rule.

## Final check

Reject the update if any answer is yes:

- Is it a general rule that belongs in `AGENTS.md` or a skill that loads at the triggering moment?
- Does it describe emotion or intensity instead of changing future action?
- Does it retell an incident beyond one short example or pointer?
- Does another entry already own the same rule or fact?
- Could the existing owner be sharpened instead of adding a new entry?
- Did the file grow without stale or duplicate wording being considered?

Private memory is a curated operating aid, not an incident log.
