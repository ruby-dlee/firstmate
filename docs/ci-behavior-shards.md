# Behavior test sharding

`bin/fm-behavior-shards.sh` is the single owner of behavior-test shard planning, execution manifests, timing refresh, and completeness verification.

## Baseline

The 2026-07-31 `main` behavior job ran all 80 scripts serially from 16:41:30 UTC to 17:38:53 UTC, or 57 minutes 23 seconds.

The source run is [GitHub Actions run 30648119449](https://github.com/ruby-dlee/firstmate/actions/runs/30648119449).

`tests/behavior-test-durations.tsv` records the per-script measurements derived from that run.

The runner contract test added with the sharding implementation is included with a conservative two-second initial estimate, so the completeness guard covers it immediately.

## Assignment

The planner uses deterministic longest-processing-time assignment.

It sorts by descending recorded duration, uses the test path as the stable secondary key, assigns the next test to the currently lightest shard, and breaks load ties by the lowest shard number.

The six-shard checked-in plan has these estimated serial loads.

| Shard | Tests | Estimated load |
|---:|---:|---:|
| 1 | 1 | 673400 ms (11m13s) |
| 2 | 1 | 620746 ms (10m21s) |
| 3 | 1 | 563637 ms (9m24s) |
| 4 | 22 | 528938 ms (8m49s) |
| 5 | 28 | 528929 ms (8m49s) |
| 6 | 28 | 528933 ms (8m49s) |

The expected healthy critical path is therefore about 11 minutes rather than 57 minutes.

The largest single test file, `tests/fm-account-routing.test.sh`, sets the remaining floor.

## Coverage guard

`bin/fm-behavior-shards.sh --check 6` fails when the duration inventory has a missing path, duplicate path, malformed duration, or any difference from the complete `tests/*.test.sh` inventory.

Every matrix runner writes an executed manifest while continuing through all assigned scripts and preserving each exit code.

The final `Behavior tests` job downloads all six manifests and runs `bin/fm-behavior-shards.sh --verify 6 <manifest-dir>`.

Verification fails for a missing shard, missing test, duplicate test, wrong shard assignment, malformed row, or recorded test failure.

Shard artifacts are replaceable across workflow attempts, so rerunning failed jobs refreshes the failed shard while retaining successful shard evidence from the same workflow run.

The historical required-check name stays intact on this final union guard.

## Isolation and failure output

GitHub Actions gives every matrix leg a separate virtual machine, so shards do not share processes, ports, locks, paths, or terminal servers.

The workflow also assigns each shard private mode-0700 `TMPDIR` and `TMUX_TMPDIR` roots under that runner's `RUNNER_TEMP`.

Scripts remain serial within a shard, so no existing test needed weaker assertions, a mock conversion, a skip, a retry, or an added sleep.

Each matrix job is named `Behavior tests (shard N/6)`, and the runner emits explicit begin and end markers containing the test path and exit code.

The 15-minute per-shard timeout leaves bounded margin above the measured 11m13s slowest shard while replacing the prior 90-minute blanket.

## Refreshing timings

Run the complete suite serially in the target environment and atomically replace the duration data only if every test passes.

```sh
bin/fm-behavior-shards.sh --record tests/behavior-test-durations.tsv
bin/fm-behavior-shards.sh --check 6
```

Review the new `--check` load summary before committing refreshed timings.
