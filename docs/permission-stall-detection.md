# Permission-stall detection

Firstmate must surface a command permission prompt or a possible blocking macOS privacy dialog instead of treating the affected work as indefinitely healthy.
The two cases have different evidence quality, so the watcher reports them differently.

## Harness prompts are directly recognizable

The watcher recognizes the stable question, numbered choices, and footer near the bottom of a non-busy pane rather than matching a question alone.
This prevents ordinary transcript text from impersonating an active confirmation prompt.

The following captures were recorded on 2026-07-22 in an isolated task worktree on Claude Code 2.1.216 and Codex CLI 0.145.0-alpha.27.
Each harness was launched without its normal Firstmate autonomy flag and was asked to run a harmless `touch` command.
Neither prompt was approved, and neither probe file was created.

Claude was launched in an isolated tmux session with this command.

```sh
claude --safe-mode --no-chrome --permission-mode manual --tools Bash \
  'Use Bash now to run exactly: touch .permission-probe-claude. Do not use another tool and do not explain.'
```

Its rendered permission gate contained this stable pair.

```text
Do you want to proceed?
...
Esc to cancel · Tab to amend · ctrl+e to explain
```

Codex was launched in an isolated tmux session with this command.

```sh
codex --no-alt-screen -a untrusted -s workspace-write \
  'Use the shell tool now to run exactly: touch .permission-probe-codex. Do not use another tool and do not explain.'
```

Its rendered permission gate contained this stable pair.

```text
Would you like to run the following command?
...
Press enter to confirm or esc to cancel
```

The installed Codex binary also carries the sibling question strings `Would you like to grant these permissions?` and `Would you like to make the following edits?` with the same confirmation footer.
`bin/fm-watch.sh` matches those verified shapes on the first capture and emits an explicit `permission-prompt detected` stale wake.
An unchanged prompt re-surfaces on the same bounded cadence as the system-dialog heuristic until it is cleared.
`stuck-crewmate-recovery` owns the response: inspect what is being requested, do not auto-approve it, and ask the captain to approve or deny it.

## A general macOS TCC probe is not reliable without prior grants

The capability probes below were recorded on 2026-07-22 on macOS 26.5.2 build 25F84.
They intentionally did not request a new TCC grant or create a real TCC prompt.
A real prompt was not induced because macOS requires the user to grant or deny it and the test could have left the desktop blocked.

The non-prompting Accessibility preflight succeeded in this execution context.

```sh
$ osascript -l JavaScript -e 'ObjC.import("ApplicationServices"); $.AXIsProcessTrusted()'
true
```

[Apple documents `AXIsProcessTrusted()` as a check for whether the current process is already a trusted Accessibility client](https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted).
This result means Accessibility inspection happened to be available on this host, not that Firstmate can assume it on another host or launch context.

The non-prompting Screen Recording preflight failed.

```sh
$ xcrun swift -e 'import CoreGraphics; print(CGPreflightScreenCaptureAccess())'
false
```

[Apple exposes `CGPreflightScreenCaptureAccess()` specifically to check existing screen-capture access](https://developer.apple.com/documentation/coregraphics/cgpreflightscreencaptureaccess%28%29?language=objc).
[Apple requires the user to control Screen and System Audio Recording access in Privacy & Security](https://support.apple.com/guide/mac-help/control-access-screen-system-audio-recording-mchld6aa7d23/mac).

Core Graphics still returned 97 on-screen window records and their owning process names in that unprivileged screen-capture state.
The relevant owners included `Control Center`, `Notification Center`, and `System Settings`.
The same records returned no window titles for those owners, so process presence could not distinguish a TCC prompt from ordinary system UI.
`Control Center` contributed many always-present windows, and `Notification Center` contributed both ordinary windows and an Accessibility `AXSystemDialog` titled `Notification Center`.
Those observations make both owner-name matching and `AXSystemDialog` matching unsafe as standalone detectors.

Direct Accessibility inspection could read current window titles and subroles only because `AXIsProcessTrusted()` was already true.
The exact read used `NSWorkspace.shared.runningApplications`, `AXUIElementCreateApplication`, and `AXUIElementCopyAttributeValue` for `kAXWindowsAttribute`, `kAXTitleAttribute`, and `kAXSubroleAttribute`.
It returned `AXError` zero for the inspected system processes and showed the ordinary Notification Center `AXSystemDialog`, demonstrating the false-positive risk.

`System Events` UI scripting was not used as a production detector.
[Apple documents that Accessibility and Automation capabilities require user permission](https://support.apple.com/en-mide/guide/security/secddd1d86a6/web), so an `osascript` query can require the same prior grants that a portable detector cannot assume.
Prompting for Accessibility, Automation, or Screen Recording merely to detect a prompt would create the failure mode this feature is intended to report.

The investigation therefore did not establish a system-process/window signature that is both observable without prior grants and specific to a blocking TCC dialog.
Firstmate does not ship a fragile direct macOS dialog probe.

## Timeout fallback for a suspected system dialog

A TCC dialog can block a foreground tool while the harness continues to render a busy footer.
The ordinary stale path sees the busy footer as positive activity and would otherwise reset its wedge timer forever.

While a pane remains busy, the watcher now keeps a separate semantic progress fingerprint.
It excludes the verified harness busy-footer lines whose spinners and elapsed counters change continuously.
It preserves command output and folds in status-file and turn-end signatures, so meaningful pane output or either signal resets the clock.

After `FM_PERMISSION_STALL_ESCALATE_SECS` without semantic progress, the watcher emits `permission/system-dialog suspected` with the elapsed time and an explicit `timeout heuristic, not direct OS detection` qualifier.
The default is 900 seconds.
Repeated unchanged stalls use the existing escalation count and eventually add `demand-deep-inspection`.

The recovery playbook requires a pane inspection before reporting the heuristic to the captain.
Clear evidence of ordinary progress makes it a conservative false positive and supervision resumes.
Otherwise the captain receives an actionable request to inspect the visible macOS dialog or Privacy & Security in System Settings and grant or deny the permission there.

## Known limitations

- A legitimate command that produces no meaningful output for longer than the threshold can trigger a conservative false positive.
- An unrecognized harness prompt that keeps changing meaningful pane content can delay the timeout fallback.
- The heuristic can report that a system dialog is possible, but it cannot name an OS capability that never appears in the pane.
- Firstmate never grants or dismisses TCC permissions programmatically.
