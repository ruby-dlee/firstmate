# Behavior test isolation

`tests/run.sh` is the authoritative entry point for every `tests/*.test.sh` behavior test.
The no-mistakes test command, CI, documented local commands, focused test execution, and direct `bash tests/<subject>.test.sh` execution all cross that runner.
Every test sources `tests/test-entry.sh` in its header, so direct execution re-enters the runner before the test body.

`tests/test-capabilities.tsv` declares exactly one lifecycle capability for every behavior test.
`hermetic` means the test cannot reach a real Herdr lifecycle.
`herdr-lab` means the runner must establish an owned, named, never-default Herdr lab before the test starts.
`herdr-mixed` means the complete test requires that same lab, while the explicit non-Herdr path still runs its hermetic assertions.
An added, removed, undeclared, duplicate, or incorrectly wired test makes admission fail with exit 97.

Before provisioning any lab, the runner verifies the complete registry and statically refuses raw Herdr server or session lifecycle commands.
For each admitted `herdr-lab` or `herdr-mixed` test on the complete path, it creates a unique session through `bin/fm-herdr-lab.sh`, installs cleanup before preparation, provisions through that helper, and binds the test to the exact session.
`tests/herdr-guard-bin/herdr` then routes non-lifecycle Herdr calls through the same helper and rejects raw server/session lifecycle or any foreign/default session selector at command execution.
The only permitted lifecycle helpers inside a real-Herdr test are the wrappers in `tests/herdr-test-safety.sh`.

Each test runs in an owned process group.
After the test exits, the runner reaps only processes still carrying that exact group identity.
After a real-Herdr test exits, the runner tears down only its exact named lab through `bin/fm-herdr-lab.sh`, whose default-session metadata, workspace/tab/pane topology, and agent identities must remain identical.
No cleanup path enumerates and kills fleet panes, adopts an existing session, or targets the default session.

The tripwire detects default server/session changes, removed or replaced fleet panes, and removed or replaced agent identities, including losses while the default server remains running.
It intentionally ignores volatile agent status and focus/activity fields, so normal work can continue during a lab test; it cannot prove preservation of pane contents or process internals that Herdr's read APIs do not expose.

## Host capabilities

Herdr is not the only thing a sealed-suite host can lack.
`tests/host-capabilities.tsv` declares every other host capability the suite depends on, the platforms that can provide it, and the exact units bound to it; `tests/host-capability-gate.sh` is the only door to that set, through `fm_require_host_capability <capability> "<label>" || return 0`.
`tests/fm-host-capability-gate.test.sh` pins the registry against the real call sites, pins the set at an exact literal count, and pins the required call shape, so the skip set cannot grow or shrink without a visible diff.

The gate never probes the capability it guards.
A probe of `command -v tmux`, `sudo -n true`, or a Keychain read is false on a BROKEN host too, which turns a real regression into an invisible skip; that is exactly how a unit gated on `command -v pi` lost two mutations of the actuator to a green CI run.
It reads facts about where the test is running instead: the platform (`uname -s`), and an explicit by-name declaration the environment makes about itself in `FM_TEST_HOST_CAPABILITIES_ABSENT`.
Everything not declared runs, so a host that is merely broken goes red.
An unknown capability name, on either side, refuses the run with exit 97 rather than skipping.

The declaration is refused outright on Darwin: macOS is the coverage of record for these units, so there they always run.
CI declares nothing, so its coverage is unchanged.
The Azure validation cell is the one declaring environment (`docs/azure-validation.md`), and its shard command carries the declaration its first live run measured.
Every skip prints one `FM_HOST_CAPABILITY_SKIP` line on stdout and stderr naming the test, the unit, the capability, what the capability is, and why it was unavailable, and `tests/run.sh` prints the whole declaration once per invocation.

Use `tests/run.sh --skip-herdr` for the explicit non-Herdr path.
That option reports each skipped `herdr-lab` test, runs every `hermetic` test normally, and runs only the hermetic assertions in each `herdr-mixed` test.
CI selects the same path explicitly with `FM_TEST_SKIP_HERDR=1` on each sealed shard command because its disposable image does not provide Herdr.
The no-mistakes test command does not skip: it requires every declared real-Herdr test to prove an owned lab or fail closed.
