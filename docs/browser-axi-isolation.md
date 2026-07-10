# Browser AXI Isolation

Date: 2026-07-10.

`bin/fm-spawn.sh` provisions a browser automation identity for every ship, scout, and secondmate launch.
The identity is harness-neutral, so Claude, Codex, OpenCode, Pi, and Grok receive the same browser environment contract.
The contract uses `chrome-devtools-axi` as the worker browser path.
Each worker receives a sanitized `CHROME_DEVTOOLS_AXI_SESSION` derived from the firstmate home fingerprint and the task id.
Each worker receives an explicit free localhost `CHROME_DEVTOOLS_AXI_PORT` from the reserved `19000..20999` range when a probe can find one with `lsof` or `nc`.
The explicit port avoids relying on AXI's named-session port hash, because AXI documents and prior testing reproduced hash collisions on a busy machine.
If no probe tool is available or the reserved range is full, spawn leaves `CHROME_DEVTOOLS_AXI_PORT` unset, warns, and lets AXI use its session-hash fallback.
Persistent mode is the default.
Persistent mode sets `CHROME_DEVTOOLS_AXI_USER_DATA_DIR` to `$HOME/.fm-browser-profiles/<session>`.
That profile directory gives a task its own cookies, localStorage, IndexedDB, service workers, and login state.
Set `FM_BROWSER_AXI_PROFILE_MODE=ephemeral` before spawning a task when the task should use AXI's clean-slate isolated browser mode.
Ephemeral mode omits `CHROME_DEVTOOLS_AXI_USER_DATA_DIR`, so AXI launches with its own isolated temporary browser behavior.
Spawn always unsets `CHROME_DEVTOOLS_AXI_AUTO_CONNECT` and `CHROME_DEVTOOLS_AXI_BROWSER_URL` for the worker launch.
That prevents firstmate workers from attaching to the captain's real Chrome session or a globally configured browser endpoint.
Spawn also clears any ambient `CHROME_DEVTOOLS_AXI_USER_DATA_DIR` before applying the task-specific profile decision.
When a usable `chrome-devtools-mcp` script path is discoverable, spawn exports `CHROME_DEVTOOLS_AXI_MCP_PATH` for the worker.
That avoids depending on cold `npx chrome-devtools-mcp@latest` startup during the first browser action.
If no usable MCP script path is discoverable, spawn leaves the path unset and lets AXI use its normal fallback.
Task metadata records `browser_axi_session`, `browser_axi_profile_mode`, and the persistent profile, explicit port, or MCP path when present.
`bin/fm-teardown.sh` reads those metadata fields and runs `chrome-devtools-axi stop` best-effort before removing the task endpoint.
Teardown removes the persistent browser profile directory recorded in task metadata after the AXI bridge has been stopped.
Persistent profile retention lasts only while the task remains live, so same-id recovery respawns keep their browser identity until final teardown.
Profile removal is guarded to paths under `.fm-browser-profiles`, so metadata cannot direct teardown to remove an arbitrary directory.
The mechanism was validated before implementation with concurrent persistent workers, persistent restart, and ephemeral clean-slate sessions.
The validation covered both Claude CLI and Codex CLI workers.
