# Browser isolation verification

## 2026-07-28 macOS evidence

The real separate automation browser completed a browser-heavy AXI workload without attaching to or changing stable Chrome.
The run used macOS 26.5.2 and Google Chrome for Testing 143.0.7499.40.
The stable-routing mutation was not repeated because this fix round forbade touching the captain's stable Chrome.
The existing opt-in assertion remains in `tests/fm-browser-isolation-macos-smoke.sh`: stable Chrome must gain a window while the unique routing URL remains absent from automation.

Command:

```sh
FM_BROWSER_ROUTING_TEST=0 tests/fm-browser-isolation-macos-smoke.sh
```

Measured output:

```text
live_browser_mock_keychain=1
live_browser_basic_password_store=1
dialog_monitor_samples=51
automation_visible_windows_seen=0
screenshots=15
owned_processes_during_run=8
owned_processes_after_stop=0
browser_tree_processes_during_run=8
browser_tree_processes_after_stop=0
bridge_alive_after_stop=0
profile_exists_after_reap=0
stable_chrome_identity_preserved=1
ok - macOS credential isolation and teardown smoke test passed
```

The browser was Chrome for Testing selected by the smoke test on macOS.
The live process arguments contained `--use-mock-keychain` and `--password-store=basic`.
