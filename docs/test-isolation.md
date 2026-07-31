# Behavior test isolation

Firstmate behavior tests must run through `tests/run.sh`.

That suite entry creates a fresh sandbox for each `tests/*.test.sh` file and delegates to `tests/run-test.sh`.
The per-test runner exports a private `HOME`, `FM_HOME`, `FM_STATE_OVERRIDE`, `FM_TREEHOUSE_ROOT`, and `TMPDIR` before the test process starts.
CI and the no-mistakes test command both use this same entry point.

`tests/lib.sh` sources `tests/test-env-guard.sh` before exposing any fixture helper.
Direct execution therefore fails before a behavior test can resolve operational state.
`BASH_ENV` installs the same guard in every Bash child process.

The guard fails with exit 97 and names the offending path or PID when any of these boundaries are violated:

- firstmate home, state, lock, pool, data, config, project, report, account, XDG, or temporary paths outside the per-test sandbox;
- a path whose lexical location is private but whose symlink resolution leaves the sandbox;
- a daemon or watcher PID that is not descended from the sealed test runner;
- a `command kill` attempt that tries to bypass the Bash function guard.

The runner removes the complete sandbox at exit.
Tests may execute tracked scripts from the real repository, but operational home, state, and pool resolution must remain private.

## Lifecycle stops

`bin/fm-afk-launch.sh stop` is intentionally invalid.
Callers must use `bin/fm-afk-launch.sh stop --home <path>`.
The launcher canonicalizes that explicitly named home before resolving lifecycle state and refuses to act unless the daemon-terminal record names the same home.
The record check happens before any daemon signal or terminal teardown.

Other home-scoped lifecycle paths retain their existing identity proofs.
For example, watcher restart verifies the recorded watcher path, process identity, and recorded home before signaling its exact PID.

## Adding or running tests

Every behavior test sources `tests/lib.sh`, including tests that otherwise carry their own assertions and cleanup.
Run one file with `tests/run.sh tests/<subject>.test.sh`.
Run the suite with `tests/run.sh`.
Never add a direct test loop to CI, documentation, or a validation command.
