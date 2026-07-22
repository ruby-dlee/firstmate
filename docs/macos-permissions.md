# macOS permissions for firstmate

Firstmate can report macOS privacy state and open the right System Settings pane, but it cannot approve itself.

On an unmanaged Mac, every Full Disk Access and Accessibility grant marked below requires the captain to click in System Settings.

Automation instead asks the captain to click Allow in the first target-specific dialog, while System Settings is where the captain reviews or changes that relationship later.

Screen & System Audio Recording can ask the captain to click Allow or Allow While Using the App in the first-use dialog, while denied, disabled, or manually added access requires the captain to use System Settings.

macOS TCC intentionally provides no shell command that force-grants these approvals, and `tccutil` resets decisions rather than granting them.

The helper never edits a TCC database, invokes `tccutil`, sends a test Apple Event, captures the screen, synthesizes input, or restarts a process.

A supervised Mac can receive Privacy Preferences Policy Control through device management, but that managed deployment path is outside this local helper.

Apple describes the four controls in [Privacy & Security settings](https://support.apple.com/guide/mac-help/mchl211c911f/mac), and its deployment guide documents the separate managed-device path in [Privacy Preferences Policy Control](https://support.apple.com/guide/deployment/dep38df53c2a/web).

## What actually needs TCC

The default tmux backend controls panes through the tmux Unix socket, so tmux window creation, capture, and `send-keys` require none of these four TCC grants.

The default macOS wedge notification uses `osascript` to display a notification, not to control System Events or another application, so that notification does not require an Automation relationship.

`chrome-devtools-axi` takes page screenshots through the Chrome DevTools Protocol, so those screenshots do not require macOS Screen & System Audio Recording.

Native desktop capture and Codex Computer Use are different because they read pixels outside the browser protocol.

Native UI control is also different because it uses macOS Accessibility APIs and may use Apple Events for app-specific operations.

TCC grants the responsible application or executable, which is not always the leaf command that encountered the denial.

Ghostty is normally responsible for `claude`, `codex`, and their descendants launched from a Ghostty shell or its tmux server.

The no-mistakes daemon is launched independently by launchd, so a Ghostty grant does not cover gate agents spawned by that daemon.

When macOS lists a different responsible entry than this guide predicts, grant only that observed entry and preserve the controller-to-target relationship shown for Automation.

Apple recommends the TCC attribution log for finding that responsible app or binary on managed machines, and the same read-only log is useful during local diagnosis.

## Ghostty

- **Full Disk Access - captain must click when protected data is in scope.**
  Add `/Applications/Ghostty.app` when firstmate or a terminal-launched agent must read Mail, Messages, Safari, Home, Time Machine backups, or protected administrative data.
  Firstmate state and repositories stored under ordinary unprotected home-directory paths do not require this grant.
- **Automation - captain must approve each requested target when Apple Events are in scope.**
  Click Allow in the first target-specific dialog for Ghostty controlling System Events or the other named application.
  If that request was denied or later disabled, review or enable the relationship under Automation in System Settings.
  Do not grant Automation for tmux control because tmux never uses Apple Events.
- **Screen & System Audio Recording - captain must approve when native desktop capture is in scope.**
  This unlocks `screencapture`, ScreenCaptureKit, or native Computer Use when TCC attributes the request to Ghostty.
  Click Allow or Allow While Using the App if macOS presents the first-use dialog, or add or enable Ghostty in System Settings if access was denied, disabled, or must be added manually.
  It is not needed for `chrome-devtools-axi` page screenshots.
- **Accessibility - captain must click when native application control is in scope.**
  This unlocks accessibility-tree inspection, focus changes, clicks, typing, and other UI control when TCC attributes the request to Ghostty.
  It is not needed for tmux or Chrome DevTools Protocol control.

## Claude Code

- **Full Disk Access - no separate grant is needed for normal Ghostty-launched work.**
  The responsible Ghostty grant covers the ordinary launch tree, while a Claude Code entry that macOS attributes separately must be granted only when protected data is in scope.
- **Automation - captain must approve each requested target when Claude sends Apple Events.**
  The relationship is Claude Code controlling System Events or another named application, and it appears only after that target-specific request.
  Click Allow in the first dialog, or use Automation in System Settings to review or change a recorded relationship.
  Claude Code does not need Automation for tmux.
- **Screen & System Audio Recording - no baseline grant is needed.**
  Grant the responsible entry only if a Claude-launched native visual tool captures the desktop rather than a browser page through DevTools.
  Approve a first-use dialog if macOS presents one, or use System Settings after denial or when adding the entry manually.
- **Accessibility - no baseline grant is needed.**
  Grant the responsible entry only if a Claude-launched native UI tool inspects or controls another application.

## Codex

- **Full Disk Access - no separate grant is needed for normal Ghostty-launched work.**
  The responsible Ghostty grant covers the ordinary launch tree, while a separately attributed Codex entry needs its own grant only for protected data.
- **Automation - captain must approve each requested target when Codex sends Apple Events.**
  The helper reports Codex Automation capability as `UNKNOWN` because a command found on `PATH` does not establish the active TCC controller identity.
  When possible, it separately reports the exact `codesign` result for that current command filesystem target without applying the result to another installation or running process.
  Click Allow in the first dialog, or use Automation in System Settings to review or change a recorded relationship.
  Apple documents that entitlement as permission to prompt rather than permission to bypass the prompt in [Apple Events Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events).
- **Screen & System Audio Recording - captain must approve for native Codex Computer Use.**
  This unlocks desktop pixels for Computer Use when the responsible entry is Codex, Ghostty, or the Codex Computer Use helper shown by macOS.
  Click Allow or Allow While Using the App if macOS presents the first-use dialog, or add or enable the responsible entry in System Settings if access was denied, disabled, or must be added manually.
  It is not needed for `chrome-devtools-axi` page screenshots.
- **Accessibility - captain must click for native Codex Computer Use.**
  This unlocks the accessibility tree and native input control for the responsible entry shown by macOS.

## no-mistakes and its daemon

- **The interactive no-mistakes CLI needs no separate grant for its core coordination work.**
  It communicates with the daemon, and the daemon becomes the independent TCC responsibility root for its gate agents.
- **Full Disk Access - captain must click when a daemon-launched gate agent needs protected data.**
  The helper can identify one running launch job and its configured program target, but it cannot prove that a replaced file or retargeted symlink still matches the process image already loaded by that job.
  Use the exact responsible entry shown by macOS or TCC attribution, and treat the configured path printed by the helper as diagnostic evidence only.
  A Ghostty Full Disk Access grant cannot cover the launchd-managed daemon.
- **Automation - captain approval is necessary but not sufficient for daemon-launched Apple Events.**
  Automation is still a pair such as no-mistakes controlling System Events or another named application.
  The helper reports the running daemon capability as `UNKNOWN` because inspecting the configured path cannot establish the entitlement of an already loaded process image.
  Apple documents the entitlement as target-signing-dependent, so a separate current-image inspection is required before making any capability claim.
- **Screen & System Audio Recording - captain must approve for daemon-launched Codex Computer Use.**
  Live TCC attribution on 2026-07-21 identified `~/.no-mistakes/bin/no-mistakes` as the responsible path for ScreenCaptureKit access by a gate agent.
  Approve a first-use dialog if macOS presents one, or add and enable the exact current entry shown by macOS rather than assuming a Ghostty, Codex, configured launch-job, or interactive no-mistakes path covers it.
- **Accessibility - captain must click for daemon-launched Codex Computer Use.**
  Add and enable the same responsible daemon binary so its Computer Use child can inspect UI and deliver input.

## Check and open the panes

Run the read-only report first.

```sh
bin/fm-macos-permissions.sh
```

The report uses `ACCESSIBLE`, `DENIED`, `UNKNOWN`, and `PER TARGET` literally.

Its Full Disk Access probe attempts to enumerate known protected directories without reading file contents.

That behavioral result applies only to the TCC-responsible context that launched the helper.

`ACCESSIBLE` and `DENIED` describe only the protected directories actually probed and never attribute that result to Ghostty or another candidate identity.

The helper queries stored TCC decisions read-only only when macOS permits access to a TCC database.

Reading either TCC database normally requires Full Disk Access, so an inaccessible expected database is a real chicken-and-egg limitation and the helper reports `UNKNOWN` rather than guessing from partial evidence.

Stored TCC rows can be stale after an executable replacement, so every stored allow, denial, absent row, or identity disagreement remains an `UNKNOWN` effective status.

The helper does not perform screen capture or Accessibility actions merely to probe them because either action would be invasive and could trigger a prompt.

Automation has no global status because every grant is one controller-to-target relationship, so the helper reports `PER TARGET` and directs the operator to the pane.

When a TCC database is readable, the helper prints matching stored Automation controller and target pairs as `UNKNOWN` evidence, including one explicit conflict status when duplicate decisions disagree.

Command lookup output says `UNKNOWN: not found on PATH` when no command is found because that observation cannot establish whether software is installed elsewhere.

Open exactly one pane at a time.

For Full Disk Access or Accessibility, add or enable the exact listed entry in System Settings.

For Screen & System Audio Recording, click Allow or Allow While Using the App in the first-use dialog, or use System Settings to review, change, or manually add the exact responsible entry.

For Automation, trigger the target-specific request and click Allow in its dialog, then use the pane only to review or change recorded relationships.

```sh
bin/fm-macos-permissions.sh --open full-disk-access
bin/fm-macos-permissions.sh --open automation
bin/fm-macos-permissions.sh --open screen-recording
bin/fm-macos-permissions.sh --open accessibility
```

The deep links below were verified on macOS 26.5.2 build 25F84 on 2026-07-22 by opening each URL in the background and observing System Settings navigate to the named pane.

- `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` opens Full Disk Access.
- `x-apple.systempreferences:com.apple.preference.security?Privacy_Automation` opens Automation.
- `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` opens Screen & System Audio Recording.
- `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` opens Accessibility.

System Settings may require the affected application to quit and reopen before a new grant becomes effective.

A pre-existing tmux server can retain its original TCC responsibility context, so restart it only after preserving all sessions and unlanded work.

Restart the shared no-mistakes daemon only when no pipeline is active, and never let this helper do that automatically.
