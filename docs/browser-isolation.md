# Browser isolation and cleanup

Firstmate-launched crew use a task-scoped automation browser.
The captain's stable Google Chrome process and profile are never an automation target.

`bin/fm-spawn.sh` selects Chrome Canary, Chrome for Testing, or Chromium as a separate application identity and prepares `/tmp/fm-<id>/browser`.
It then places `bin/chrome-devtools-axi` first on that crew's `PATH`.
The wrapper launches the selected browser with a private profile and attaches the real AXI bridge through a loopback DevTools endpoint.

## Credential-store boundary

Every task browser launch includes both `--use-mock-keychain` and `--password-store=basic`.
The same flags are passed through `CHROME_DEVTOOLS_AXI_CHROME_ARGS` as a defense for any AXI fallback launch.
Automation also disables first-run, default-browser, crash-reporting, sync, and native error-dialog paths.
An automation browser must not present any OS dialog to the captain.

Do not launch Chrome for Testing, Chromium, or Canary directly during firstmate browser diagnostics.
Use the task wrapper so the credential flags and lifecycle owner are inseparable from the browser process.

## Lifecycle

One browser and one AXI session are owned by each task.
Successful AXI commands reuse that task browser so page state survives between commands.
`chrome-devtools-axi stop` stops the bridge and browser, verifies that no process still references the task profile, and leaves the task root ready for a clean relaunch.
`fm-teardown.sh` performs the same reap after the agent endpoint is quiescent and before deleting `/tmp/fm-<id>`.

A browser that exits unexpectedly or an AXI command that fails is cleaned immediately and writes a failure latch.
Later commands refuse to respawn it implicitly.
An explicit `chrome-devtools-axi stop` clears the latch.
This prevents a screenshot loop from recreating browsers while an operator is trying to contain an incident.

## Crash backstop

The locked `fm-bootstrap.sh` session-start path sweeps browser state that survived a crashed agent.
It reaps a task root only when its `owner.json` belongs to the current Firstmate home and no matching task metadata exists.

The legacy cleanup classifier recognizes only:

- an exact `chrome-devtools-axi-bridge.js` process;
- a Chrome process carrying both `--headless` and a `puppeteer_dev_chrome_profile-*` user-data directory directly under the system temporary root; or
- an unused `puppeteer_dev_chrome_profile-*` directory directly under the system temporary root.

Stable Chrome, partial-marker commands, headed temp-profile Chrome, headless Chrome with a non-temporary profile, and active task-owned browser roots are preserved.
The sweep prints `BROWSER_GC:` only when it reaps something or cannot verify cleanup.

## Verification

Run `tests/fm-browser-isolation.test.sh` for fake-process behavior, failure-latch, teardown, backstop, and discrimination coverage.
On macOS, run `tests/fm-browser-isolation-macos-smoke.sh` manually to launch the real separate browser, capture 15 screenshots, continuously sample on-screen windows, and prove zero bridge and browser processes after stop.
Set `FM_BROWSER_ROUTING_TEST=1` only when a new stable-Chrome window is acceptable; the smoke test then proves `open -na "Google Chrome" --args --new-window <url>` increases stable Chrome's window count and that the URL never reaches automation.
