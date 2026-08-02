# Behavior test isolation

Firstmate behavior tests must run through `tests/run.sh`.

That POSIX-shell suite entry discards ambient `BASH_ENV`, creates a fresh sandbox for each `tests/*.test.sh` file, and delegates to the internal `tests/run-test.sh` helper.
The per-test runner exports a private `HOME`, `FM_HOME`, `FM_STATE_OVERRIDE`, `FM_TREEHOUSE_ROOT`, `TMPDIR`, and `TMUX_TMPDIR` before the test process starts.
It also clears inherited `TMUX`, so lifecycle tests create a private tmux server and socket inside the sandbox instead of reaching the operator's server.
When Herdr is installed, the public suite entry provisions or adopts one owned `fm-lab-*` session through `bin/fm-herdr-lab.sh` and rotates that lab between test files.
The sealed Herdr launcher rejects foreign sessions and sends every real CLI call through the lab helper.
Provisioning failure still invokes guarded teardown and records the default-session after snapshot before the proof driver returns the primary error.
Lab startup waits up to 120 seconds by default so ordinary fleet load does not become a false provisioning failure; `FM_HERDR_LAB_PROVISION_TIMEOUT_SECONDS` may select a bounded 1-to-600-second deadline.
Neither the helper nor the suite adopts a lab from a successful create/start return code alone: both poll the named session until status reports that exact session as running, with `FM_TEST_HERDR_ADOPTION_TIMEOUT_SECONDS` providing a bounded 1-to-600-second deadline.
Failed adoption preserves the session listing and bounded server-log tail before guarded teardown, so a stale stopped directory or server-side startup refusal remains diagnosable.
Fleet proofs may pass `--reuse-lab` to provision one owned lab and serialize multiple checks inside it.
The suite then closes every exact owned-lab workspace and proves the workspace inventory empty between test files; without reuse it tears down and re-provisions the owned lab between entries.
Ordinary calls get the required trailing session argument; the helper's narrowly validated `run-argv` route inserts it immediately before `agent start`'s `-- <agent argv>` boundary, where Herdr requires it.
Each test runner is also launched in a detached process group by `tests/run-detached.py`.
The shared library verifies that the sealed runner is its process-group leader and reaps every remaining group member during cleanup.
The detached runner keeps a caller-fatal lifecycle test from terminating the suite driver, remains a hard-fail backstop if shared cleanup leaves descendants behind, and writes combined stdout/stderr to `FM_TEST_OUTPUT_DIR` when the caller requests durable artifacts.
CI and the no-mistakes test command both use this same entry point.

Native Herdr agents are a special process boundary: the lab server, not the test runner, becomes their OS parent.
The backend injects the complete sealed operational environment through Herdr's native `agent start --env` channel.
Only a process carrying the owned lab session, a valid Herdr pane identity, and the authenticated test-lab marker may rebase itself as a new guarded subtree root; a foreign or default session cannot claim that authority.

Live-fleet verification uses `tests/fleet-proof.py` with the external lab helper, the default Herdr server PID, and an explicit set of stable pane PIDs.
Pass the default session's persisted state file with `--default-session-state`; the proof records its logical workspace/pane identities before and after without copying pane launch arguments.
It also records the complete default-session process identity inventory before and after the run, while continuously aborting only if the server or a declared stable identity changes or disappears.
Ordinary task panes are deliberately not count-based abort conditions: they may complete and be reaped during a long suite run.
Their disappearance remains visible in `default-diff.json` with `lifecycle_reconciliation_required: true` and must be reconciled against a known completion or teardown event before the proof is accepted.
This avoids both unsafe silent loss and a raw-count alarm that routinely cries wolf.
When given the real Treehouse root, watcher lock, and away-mode flag, the same driver also records the pool/control manifest, follows and hashes every watcher-lock owner record, and inventories every watcher/daemon process.
Root supervisor and watcher identities are compared as the stable lifecycle set; nested watcher subprocess churn remains visible but does not cause a false failure.
If a stable lifecycle identity or away-mode state changes, the proof requires reconciliation against the corresponding known away-mode or teardown event.
Pass the real supervisor log with `--supervise-log`; the proof driver accepts a PID/lock rotation only when the append-only log records the reap-wake completion, clean shutdown, exact replacement PID, and a wake under the same logical watcher home/path.
Pass `--watch-home` and `--watcher-path` to declare the operator watcher's stable ownership set; idle-to-active, active-to-idle, and PID rotations are then reconciled only when every present lock and watcher command matches that exact home and tracked script.
It distinguishes the timestamp stored inside a still-present `.afk` marker from an actual away-mode presence change.
`host_unchanged` remains the strict byte/identity result, while `host_unchanged_or_reconciled` is the acceptance result after those narrow lifecycle proofs.
Pool mutation, away-mode presence changes, watcher owner changes, and unexplained process rotations remain hard failures.

`tests/lib.sh` sources `tests/test-env-guard.sh` before exposing any fixture helper.
Direct execution therefore fails before a behavior test can resolve operational state.
The POSIX-shell runner discards ambient `BASH_ENV` before doing any setup, then explicitly installs the same guard for the sealed test and ordinary Bash child processes.

The guard fails with exit 97 and names the offending path or PID when any of these boundaries are violated:

- firstmate home, state, lock, pool, data, config, project, report, account, XDG, or temporary paths outside the per-test sandbox;
- a path whose lexical location is private but whose symlink resolution leaves the sandbox;
- a daemon or watcher PID that is not descended from the sealed test runner;
- a `command kill` attempt that tries to bypass the Bash function guard.

The runner removes the complete sandbox at exit.
Tests may execute tracked scripts from the real repository, but operational home, state, and pool resolution must remain private.

The harness protects trusted project tests from accidental fleet escape, including stale or hostile `BASH_ENV` inherited from an operator or outer validation process.
A child can deliberately bypass the in-shell guard only by setting or unsetting `BASH_ENV`, removing `tests/sealed-bin` from `PATH`, and invoking real system Bash directly or through an env-Bash shebang.
The parent shell cannot intercept that child startup before Bash reads `BASH_ENV`; preventing it requires an OS-enforced sandbox, container, or equivalent process boundary and is outside this trusted-test threat model.

## Lifecycle stops

Bare `bin/fm-afk-launch.sh stop` and `reconcile` are intentionally invalid.
Callers must use `bin/fm-afk-launch.sh stop --home <path>` or `reconcile --home <path>`.
The launcher canonicalizes that explicitly named home before resolving lifecycle state and refuses to act unless the daemon-terminal record names the same home.
Explicit lifecycle authority also pins state to `<home>/state`; an inherited `FM_STATE_OVERRIDE` cannot redirect the record lookup to a different fleet.
The record check happens before any daemon signal or terminal teardown.

Other home-scoped lifecycle paths retain their existing identity proofs.
For example, watcher restart verifies the recorded watcher path, process identity, and recorded home before signaling its exact PID.

## Adding or running tests

Every behavior test sources `tests/lib.sh`, including tests that otherwise carry their own assertions and cleanup.
Run one file with `tests/run.sh tests/<subject>.test.sh`.
Run the suite with `tests/run.sh`.
Use `tests/run.sh` for both public paths; `tests/run-test.sh` is the suite's internal per-test helper.
Never add a direct test loop to CI, documentation, or a validation command.
