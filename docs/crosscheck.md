# Crosscheck

crosscheck is Firstmate's local independent adversarial PR review gate.
It replaces the old Bugbot merge property without installing anything into project repositories.

`bin/fm-crosscheck.sh run <task-id> <PR URL>` is the owner of the ledger contract.
It selects a reviewer with a different account home from the author, prefers a different model where available, reviews in a scratch checkout, and refuses merge when that separation cannot be proven.

The durable record is `data/<task-id>/crosscheck-ledger.json`.
Findings have lifecycle values `open`, `claimed-fixed`, and `verified-fixed`; `open` and `claimed-fixed` are merge-blocking.
Silence never closes a finding.
A later run must verify every active finding against the current PR head.

A new finding must include executed reproduction evidence: command, output, and file-line citations.
An unreproduced concern belongs in `suspicions`, not `findings`.
A fix is accepted only with mutation proof: the reviewer must name the mutation or revert and show the test command and failing output when that mutation is applied in the scratch checkout.

`bin/fm-pr-merge.sh` runs crosscheck immediately before `gh-axi pr merge`.
Running crosscheck earlier in parallel with no-mistakes is safe because it uses a scratch checkout and writes only Firstmate state/data, but an old clear run is not enough to merge after the PR head changes.
The merge helper reruns crosscheck against the current PR head.

## Relationship to no-mistakes

crosscheck is not just no-mistakes with another model.
The no-mistakes review step receives the author's `--intent` so it can distinguish deliberate choices from mistakes.
That is useful for cooperative validation, but it makes the review intentionally lenient toward the author's stated plan.

crosscheck receives no author intent and is explicitly told to refute the PR claims.
That difference is load-bearing for this gate: a cross-model no-mistakes run would improve independence, but it would still be a cooperative intent-aware review rather than an adversarial ledger that requires reproduction and mutation proof.
