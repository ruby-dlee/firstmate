# Behavior test sharding

`bin/fm-behavior-shards.sh` is the single owner of behavior-test shard planning, execution manifests, timing refresh, and completeness verification.

## Baseline

The 2026-07-31 `main` behavior job ran all 80 scripts serially from 16:41:30 UTC to 17:38:53 UTC, or 57 minutes 23 seconds.

The source run is [GitHub Actions run 30648119449](https://github.com/ruby-dlee/firstmate/actions/runs/30648119449).

`tests/behavior-test-durations.tsv` records the per-script measurements derived from that run.

The runner contract test added with the sharding implementation and the newly landed `tests/lavish.test.sh` are included, so the completeness guard covers both immediately.

## Assignment

The planner uses deterministic longest-processing-time assignment.

It sorts by descending recorded duration, uses the test path as the stable secondary key, assigns the next test to the currently lightest shard, and breaks load ties by the lowest shard number.

The eight-shard checked-in plan has these estimated serial loads.

| Shard | Tests | Estimated load |
|---:|---:|---:|
| 1 | 1 | 563637 ms (9m24s) |
| 2 | 1 | 475500 ms (7m56s) |
| 3 | 13 | 401927 ms (6m42s) |
| 4 | 13 | 401942 ms (6m42s) |
| 5 | 13 | 401927 ms (6m42s) |
| 6 | 10 | 401979 ms (6m42s) |
| 7 | 16 | 401935 ms (6m42s) |
| 8 | 17 | 401936 ms (6m42s) |

The expected healthy behavior-execution critical path is 9 minutes 24 seconds rather than 57 minutes 23 seconds.

The account-routing and report-stack suites keep their original test functions and assertions in shared suite files, while two runner wrappers partition each call list deterministically between isolated runners.

The largest remaining indivisible test file, `tests/fm-teardown.test.sh`, sets the 9-minute-24-second floor.

## Coverage guard

`bin/fm-behavior-shards.sh --check 8` fails when the duration inventory has a missing path, duplicate path, malformed duration, or any difference from the complete `tests/*.test.sh` inventory.

Every matrix runner writes an executed manifest while continuing through all assigned scripts and preserving each exit code.

The final `Behavior tests` job downloads all eight manifests and runs `bin/fm-behavior-shards.sh --verify 8 <manifest-dir>`.

Verification fails for a missing shard, missing test, duplicate test, wrong shard assignment, malformed row, or recorded test failure.

Shard artifacts are replaceable across workflow attempts, so rerunning failed jobs refreshes the failed shard while retaining successful shard evidence from the same workflow run.

The historical required-check name stays intact on this final union guard.

## Isolation and failure output

GitHub Actions gives every matrix leg a separate virtual machine, so shards do not share processes, ports, locks, paths, or terminal servers.

The workflow also assigns each shard private mode-0700 `TMPDIR` and `TMUX_TMPDIR` roots under that runner's `RUNNER_TEMP`.

Scripts remain serial within a shard, so no existing test needed weaker assertions, a mock conversion, a skip, a retry, or an added sleep.

Each matrix job is named `Behavior tests (shard N/8)`, and the runner emits explicit begin and end markers containing the test path and exit code.

The 15-minute per-shard timeout leaves bounded margin above the 9m24s slowest planned shard while replacing the prior 90-minute blanket.

## Teardown child-endpoint investigation

GitHub Actions run 30649486198 failed at 17:52:54 UTC after `test_forced_secondmate_child_uses_child_home_for_endpoint_verification` correctly retained the Agent Fleet lease, child metadata, and child worktree but its final message assertion expected the endpoint state to be `unknown`.

The Zellij fixture returns a live session, pane, and tab from the child firstmate home, so endpoint discovery deterministically classifies it as `present` before destructive cleanup and emits `managed endpoint ... is still alive`.

The failure was therefore an assertion-ordering mismatch introduced when the fixture became capable of proving presence, not a delayed endpoint shutdown.

Commit `d7db2dcb010cc48f4ca6d34b4386d934e6c9cdde` fixes the assertion to match the proven state while retaining the refusal and all three containment checks.

GitHub Actions run 30657355610 executed the corrected sequence at 19:51:41 UTC and passed the full behavior job without a retry or added sleep.

## Refreshing timings

Run the complete suite serially in the target environment and atomically replace the duration data only if every test passes.

```sh
bin/fm-behavior-shards.sh --record tests/behavior-test-durations.tsv
bin/fm-behavior-shards.sh --check 8
```

Review the new `--check` load summary before committing refreshed timings.
