# Browser automation isolation

Firstmate owns browser automation through `bin/fm-browser.sh`.
The script header owns the exact prepare, wrapper, ownership, reap, and sweep mechanics.
This document records the safety boundary and its empirical basis.

## Safety boundary

Every spawned crew receives a task-local `chrome-devtools-axi` wrapper before its harness starts.
The wrapper pins `CHROME_DEVTOOLS_AXI_CHANNEL=canary` and a unique `CHROME_DEVTOOLS_AXI_SESSION=fm-<task-id>`.
It removes auto-connect, browser-URL, user-data-dir, port, headed, and extra Chrome-argument overrides before invoking the real tool.
Those removals prevent a caller from attaching to the captain's running Chrome or selecting the captain's profile.
The wrapper checks for the dedicated Canary executable before any browser action can start a bridge.
When Canary is absent, browser automation fails nonzero and stable Google Chrome is never used as a fallback.
Help, version, and stop commands remain available without Canary.
Firstmate never changes the machine's default browser.

Spawn records `browser_session=` and `browser_channel=` in task metadata.
It also creates a generation-bound owner marker beside the named bridge session state.
Teardown reaps the bridge's detached process group before deleting task metadata.
That group contains the bridge, chrome-devtools-mcp transport, and headless browser children.
The locked session-start bootstrap sweep considers only sessions with Firstmate's owner-marker format.
A marker is live when its exact metadata file still records the same task, generation, session, and channel.
The sweep never touches a live marker, an unmarked session, the default session, or a process whose PID, command, start time, UID, and process-group identity do not all match.

## Empirical record

The behavior below was verified on 2026-07-23 with `chrome-devtools-axi 0.1.26` on macOS.

The installed tool advertises channel selection and named bridge sessions:

```text
$ chrome-devtools-axi --help
CHROME_DEVTOOLS_AXI_CHANNEL       Chrome release channel to target: stable (default), beta,
                                  canary, or dev.
CHROME_DEVTOOLS_AXI_SESSION       Named session for concurrent isolation.
```

Only stable Google Chrome was installed:

```text
absent: /Applications/Google Chrome Canary.app
absent: /Applications/Google Chrome Beta.app
absent: /Applications/Google Chrome Dev.app
absent: /Applications/Chromium.app
installed: /Applications/Google Chrome.app
```

The upstream CLI reports a missing Canary as command output but incorrectly exits zero:

```text
$ CHROME_DEVTOOLS_AXI_CHANNEL=canary CHROME_DEVTOOLS_AXI_SESSION=fm-canary-probe chrome-devtools-axi open about:blank
page:
  url: "about:blank"
snapshot:
Could not find Google Chrome executable for channel 'canary' at:
 - /Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary.
$ echo $?
0
```

That reproduction is the upstream defect Firstmate contains.
The wrapper performs its own executable preflight so the false success cannot silently start or retain a bridge.

The focused process test launched a detached fake bridge and browser child with the same process-group topology as chrome-devtools-axi:

```text
$ ./tests/fm-browser.test.sh
browser process evidence before reap:
49581     1 49581 /Users/dongkeun/.nvm/versions/node/v20.19.0/bin/node /tmp/fm-browser-tests.2eeKrR/case/chrome-devtools-axi-bridge.js
49599 49581 49581 /Users/dongkeun/.nvm/versions/node/v20.19.0/bin/node /tmp/fm-browser-tests.2eeKrR/case/fake-headless-chrome.js
browser process evidence after reap: <none>
ok - browser sweep: live generation preserved; orphan bridge and child reaped
ok - browser wrapper: stop does not wedge a live crew; next open relaunches
```

The teardown integration test proved the same before and after boundary through `fm-teardown.sh`:

```text
$ FM_TEST_FOCUSED=browser-reap ./tests/fm-teardown.test.sh
teardown browser evidence before:
52151     1 52151 /Users/dongkeun/.nvm/versions/node/v20.19.0/bin/node /tmp/fm-teardown-tests.6ykqxN/browser-reap/chrome-devtools-axi-bridge.js
52172 52151 52151 /Users/dongkeun/.nvm/versions/node/v20.19.0/bin/node /tmp/fm-teardown-tests.6ykqxN/browser-reap/fake-headless-chrome.js
teardown browser evidence after: <none>
ok - teardown reaps the crew's owned bridge and browser process group
```

The missing-Canary test also proves that the underlying CLI is never invoked and no bridge PID file appears.
The override test supplies stable-channel, auto-connect, browser-URL, captain-profile, fixed-port, headed, and Chrome-argument values and proves that the invoked tool sees only Canary, the task session, and unset unsafe overrides.

## Operational diagnostics

Bootstrap reports `MISSING_MANUAL: chrome-canary` when the dedicated application is unavailable.
The captain must install Canary manually before crews can use browser automation.
Successful orphan cleanup emits `BROWSER_SWEEP: orphaned session fm-<id>: reaped`.
An ownership-proof mismatch emits `BROWSER_SWEEP: orphaned session fm-<id>: refused unsafe reap` and leaves the process untouched.

The separately known `chrome-devtools-axi screenshot` false-success behavior is outside this mechanism and remains out of scope.
