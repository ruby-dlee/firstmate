# `fm-send` modal safety

`fm-send` does not stage text into any pane-backed composer.
The earlier empty-composer preflight was necessary while delivery used split literal text plus Enter, but that transport could not bind submission atomically to the registered agent session.
The stronger current boundary is `fm_backend_send_steering`, which refuses every tmux, Herdr, Zellij, Orca, and cmux text route before pane input until an adapter supplies one atomic agent-session-bound operation.

## Route-complete predicate

- Scope: every text request routed through `bin/fm-send.sh`.
- Trigger: after exact target and managed lifecycle verification and before any text input.
- Predicate: the backend must atomically bind the registered agent session and return `confirmed`, after which `fm-send` must complete a fresh identity-bound target read.
- Failure mode: no current backend satisfies the atomic predicate, so text delivery exits nonzero and the target receives neither text nor Enter.
- Modal consequence: empty, pending, modal, unreadable, and malformed composer states are all untouched because composer inspection and split submission are unreachable from `fm-send`.

## Evidence

`tests/fm-send-permission-modal-probe.sh` drives all five Herdr TUI states through the production route and proves each refusal records no text, key, approval, or turn-start event.
`tests/fm-daemon.test.sh` proves tmux split literal-plus-Enter remains unreachable.
`tests/fm-send-strict.test.sh` uses a test-lab-only atomic adapter to exercise the future accepted route and proves that backend confirmation alone is insufficient without a fresh target read.
