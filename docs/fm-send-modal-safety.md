# `fm-send` modal safety

## Security invariant

Canonical `fm-send` text steering now refuses before literal pane input on every backend because no adapter supplies one atomic operation bound to the expected agent session.
A permission modal, pending composer, unreadable pane, malformed capture, missing composer row, or unrecognized detector result therefore cannot be crossed by a production text submission.
Gate B in [`docs/structural-gates.md`](structural-gates.md) owns the current route inventory, predicate, and fail-closed result.

This protects the distinction that matters at the terminal boundary: a composer awaiting text is not a modal awaiting consent.

## Confirmed incident mechanism

The legacy Herdr send path staged text and then retried Enter until a turn started or composer inspection ended the loop.
A deterministic permission-modal TUI showed the first Enter approving the modal without starting a turn and the second Enter submitting the already-staged steer.
The pre-fix modal event stream was `text`, `enter`, `modal-approved`, `enter`, `turn-started`.
The ordinary empty-composer control was `text`, `enter`, `turn-started` and contained no approval event.

This establishes a live security defect in Firstmate's input automation without invoking a real provider or granting a real capability.

## Guard definition

- Scope: the retained legacy Herdr split-submit helper and its compatibility tests, not canonical production text steering.
- Representation: the existing structural `empty|pending|unknown` composer classification, derived from the rendered agent-composer row rather than permission-dialog wording or a human pane inspection.
- Observed layer: the historical `fm-send.sh` to `fm_backend_composer_state` to Herdr pane-read boundary immediately before literal staging began.
- Production admission criterion: a future route must provide the atomic agent-session-bound confirmation and post-submit identity read required by Gate B; composer emptiness alone cannot admit it.

The guard does not match a permission prompt's spelling.
It positively proves the safe representation instead: a structurally recognized empty composer.
This makes novel modal wording and malformed screens conservative refusals rather than false permissions.

## Outcome classes

| Observation | Action | Boundary evidence |
|---|---|---|
| `empty` | Legacy helper stages text and runs its regression-only submit flow. | The stub records one text event, one Enter, and one started turn. |
| `pending` | Refuse before staging or Enter. | Existing text remains byte-for-byte unchanged and the stub records no event. |
| `unknown` from an already-open permission modal | Refuse before staging or Enter. | The modal remains unapproved and the stub records no event. |
| `unknown` from an unreadable or failed capture | Refuse before staging or Enter. | The stub records no event and `fm-send` returns a blocker. |
| Malformed or unrecognized classifier output | Treat as UNKNOWN and refuse. | The shell `case` permits only the literal `empty` success value. |

These outcome classes document the historical guard and retained helper tests; canonical `fm-send.sh` refuses before reaching them.

## Violation and refusal proof

The controllable TUI in `tests/fixtures/herdr-permission-tui.py`, now driven by `tests/fm-send-permission-modal-probe.sh` from the existing strict send suite, first ran manually against the unmodified production path.
Its modal was approved and the staged text was submitted, proving the violation was reachable at the boundary.

The same modal then ran after the guard was added.
The guard returned non-zero, the TUI stayed in modal mode with `approved=false`, and its event list remained empty.
This proves the guard fired on the exact behaviour it exists to prevent rather than merely returning a reassuring internal value.

The positive control still ran end to end after the historical guard.
An empty composer received the staged text and exactly one Enter and reported a started turn.

## Current runtime-profile boundary

The old requested-versus-observed design notes are superseded by Gate A in [`docs/structural-gates.md`](structural-gates.md).
Current Codex generations bind `provider_session_id`, launch only under the exact admitted profile, and are reverified from Codex-owned runtime records at startup, before managed steering can proceed, and periodically in flight.
That runtime verifier and Gate B's unconditional current steering refusal replace the former modal-between-Enters proposal; this incident document remains the evidence for why a split submit cannot be promoted back to production.
