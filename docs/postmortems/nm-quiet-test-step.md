# The quiet no-mistakes test step - 2026-08-02

Four firstmate-repo validation runs were reported dead at the `test` step, and every firstmate PR was declared blocked from validating.
Three further runs were aborted to escape the same reported condition, the last of them during this investigation.

**None of those steps was dead.**
All of them were executing normally.
The reported condition was a false negative produced by three independent no-mistakes signals that all read as death for a step running a configured shell command, compounded by a hand check that cannot see the processes it was looking for.
The only real damage was the aborted runs, which were healthy work discarded on a wrong reading.

## What was reported

`no-mistakes axi status --run 01KZ1P01GK1HJ5JGX1B1Q73VMA` rendered:

```
active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
  test,running,22m14s,"quiet 22m14s ago: log: running tests: command -v tmux ...","",starting
```

Three signals, all pointing at death: the step is `quiet`, `agent_pid` is empty, and `round` reads `starting`.
A fourth check was made by hand - a search for processes belonging to the run - and found nothing.

## What was actually true

At the moment that status was rendered, the run's test command was a live child of the no-mistakes daemon and had been working for 22 minutes:

```
57496 54967 12:53:35 23:28 sh -c command -v tmux >/dev/null || { ... }
57509 57496 12:53:35 23:28 python3.11 -m unittest -v tests.test_build_quota_axi_offline_proof ...
```

Its CPU time advanced from `9:03.23` to `9:11.21` across a 60-second sample.
The other three "dead" runs were spawning fresh child processes seconds before they were inspected.

## Why every signal was wrong

**`agent_pid` is empty because the step runs a command, not an agent.**
no-mistakes records `agent_pid` only for agent invocations.
Across every step in flight that day, `review,running` and `test,fixing` carried a pid while all four `test,running` steps carried none - because firstmate is the only repo in this fleet that configures `commands.test` in `.no-mistakes.yaml`; every other repo lets an agent drive testing.
An empty `agent_pid` is therefore normal for a configured-command step and is not evidence about liveness.

**`round: starting` is a placeholder, not a stall.**
A `step_rounds` row is written when a round ends.
A step in its first round has no round row yet, and the status renderer prints `starting`.
It reads as "stuck at startup" and means "has not finished its first round".

**`quiet` is the misleading one.**
The step log for a configured command is not written until the step ends.
Measured directly: run `01KZ1P01GK1HJ5JGX1B1Q73VMA`'s `test.log` stayed byte-identical at 344 bytes with an unchanged mtime across 90 seconds while its child process consumed CPU throughout.
Every one of the four affected runs had exactly the same 344-byte, two-line log - the header line and nothing else.
Because `last_activity` advances only when the log is written, it stays pinned to the step's start time for the step's entire duration, and `axi status` renders a healthy multi-hour step as `quiet 1h28m ago`.
The aborted runs prove the same mechanism from the other side: their logs are 39 KB and 159 KB, both with an mtime equal to the second they were aborted, so the buffered output landed only when the step ended.

The cleanest proof arrived during this investigation.
Run `01KZ1P01GK1HJ5JGX1B1Q73VMA` - the run preserved as evidence - was aborted at 13:45:50 after 52.3 minutes in its test step.
Its log went from 344 bytes to 45,501 bytes at that instant, and the flushed content shows it had printed `tmux 3.7b`, worked through `tests/bridge-cutover-python.test.sh`, and was emitting `ok -` lines from the account-routing suite the entire time it was being rendered as quiet.
It was a third healthy run destroyed on the same false reading.

**The hand check could not have found the processes.**
It searched by process name.
The test command's argv is `sh -c command -v tmux ...` and its children are `bash tests/fm-account-routing-a.test.sh` - relative paths.
Neither the run id nor the worktree path appears anywhere in any of their argv.
`ps -ef | grep 01KZ1P01GK1HJ5JGX1B1Q73VMA` genuinely returns nothing while three of the run's processes are live.
The only reliable link from a process to its run is its **working directory**.

**And the check is worse than simply wrong: it is nondeterministic.**
Some tests invoke a helper by absolute path, which puts the worktree into that process's argv; most do not.
So the same check returns a different answer depending on which test happens to be executing.
Measured across five live steps at one instant:

| run | processes found by argv | processes found by working directory |
| --- | --- | --- |
| `01KZ0RAW7V8H4PWKMW60AWNP5F` | 0 | 42 |
| `01KZ1MGVG2C0D9JER58PF1ZK63` | 1 | 5 |
| `01KZ1MZG7BJYGE8EJCZ52KYH7B` | 1 | 5 |
| `01KZ0Q9CZ4B4170FSBM0HX1F0M` | 3 | 8 |
| `01KZ1MWG37CF9KGA9D10Z4BQ4V` | 7 | 9 |

A step running 42 processes reported zero.
Repeating the same measurement a minute later gave 2 against 46 for that row, and different numbers again for the others: the argv answer changes while nothing about the step changes.
That intermittency is why the check survived four uses.
It sometimes returns a plausible number, so it looks like a working check, and it reads zero exactly when a long-running test is between absolute-path invocations - which is most of the time.

## Why the timing looked damning but was not

The firstmate behavior suite is genuinely slow.
`tests/behavior-test-durations.tsv` records **59.2 minutes of serial runtime** measured on an unloaded CI runner across 92 scripts, and the gate runs them serially in one loop.
Locally the same suite shares a 14-core laptop with the rest of the fleet.

Historical `test` step durations for this repo: 116, 121, 124, 129, 136, 187, 226, 228, 335, 347 and 401 minutes.
**This step has never once completed in under an hour.**
The runs declared dead had been running 22 and 89 minutes - comfortably inside the normal range, and in the case of the 22-minute one, faster than every recorded completion.

Machine load was ruled out as an explanation because one incident happened at load 13.
That reasoning was sound but answered the wrong question: load explains *how much* slower, not *whether* the step is alive.

## What changed here

The configured lint and test commands now `exec bin/fm-nm-command-supervisor.sh` as the exact process no-mistakes waits on.
The supervisor records its PID, process group, process start identity, run id, step, and physical worktree atomically under the no-mistakes home.
It redirects every descendant away from no-mistakes' captured pipe, propagates the command's exit status, and reaps its process group on every normal, failed, or signalled exit.
A watchdog reaps the group if the supervisor itself disappears.
That ownership makes a dead command close no-mistakes' wait and become an ordinary failed step, so the existing retry and fix path remains usable without aborting the run.

`bin/fm-nm-step-liveness.sh` verifies that exact identity and separates three outcomes.

- `alive` - the recorded PID still has the recorded process group and start identity.
- `dead` - the same recorded identity is absent across two checks.
- `unknown` - the supervisor record is missing, invalid, unreadable, or changing; worktree process presence is reported only as supporting detail.

An unrelated background process holding the worktree cwd can no longer prove the command alive.
An empty cwd scan without a supervisor record can no longer prove it dead.

`bin/fm-crew-state.sh` calls it automatically whenever the active step renders quiet, so the verdict appears in the ordinary heartbeat read:

```
state: working · source: run-step · validating (running) · test alive (3 procs) supervised pid 57496, pgid 57496 on bash tests/fm-teardown-a.test.sh (38:37)
```

Only an exact `alive` verdict preserves `state: working`.
Every `dead` or `unknown` verdict makes the current-state read `unknown`, so the shared absorb classifier surfaces it instead of treating inactive or uninspectable work as healthy.
The `ci` step is exempt: its monitoring runs inside the daemon and owns no worktree process, so a verdict there would always read `dead` and mean nothing.

The unit of work and its age ride along on that line because "alive" alone still leaves hours of runtime unexplained.
They are carried on the heartbeat read rather than left to a second command, since the follow-up question - alive, but stuck on the same script for three hours? - is asked every time the first one is.
Run the probe directly for the full detail:

```
liveness: alive · run: 01KZ0Q9CZ4B4170FSBM0HX1F0M · procs: 7 · supervised pid 57496, pgid 57496 · doing: bash tests/fm-teardown-a.test.sh (38:37)
```

That is what makes slow separable from hung without spending a run to find out: a step that keeps changing what it is on is slow, and one sitting on the same script past any plausible budget is worth investigating.

## Operating rule

**Never abort a run to recover a reported-quiet configured command.**
Quiet is not evidence.
An exact live supervisor reports working, missing identity reports unknown, and a missing supervised command returns through no-mistakes as a failed step.
For a configured-command step, quiet is the *expected* rendering for the step's entire duration, and for this repo that duration is routinely measured in hours.

## What is still a no-mistakes defect

The root reporting and recovery gaps remain defects in no-mistakes itself.

**Reporting.**
A step running a configured command should publish the command's pid the way an agent step publishes `agent_pid`, and should flush its log incrementally rather than at step end.
Either change alone would have prevented this incident, because either one makes `last_activity` advance.
The smallest correct fix is the pid: it is a single field on a record no-mistakes already writes when it spawns the process, and it makes liveness answerable from `axi status` alone with no process inspection at all.

**Recovery.**
no-mistakes should record and reap its configured-command child directly.
This repo fixes the running system at the command boundary it controls: `exec` makes the supervisor the exact child already owned by no-mistakes, and pipe isolation guarantees that the existing wait observes its death and writes the failed step.
That is recovery rather than containment for every configured command in this repo, while the general no-mistakes implementation still needs the same ownership natively.

## Separate finding: is a multi-hour test step legitimate or hung?

This is a different question from the one above and was established on its own evidence, because "dead" and "slow" had already been conflated once.

**It is legitimate. The step is slow, not hung.** Three independent lines of evidence agree.

**The command terminates reliably.**
In the three days to 2026-08-02 this repo's `test` step reached a terminal status 26 times - 10 `completed` and 16 `failed`, where `failed` means the command ran to completion and reported test failures.
A step that hung would not produce that record.

**Live steps observably advance through the suite.**
Sampling the direct children of each live step shell shows the executing script changing over time: step `32590` entered `tests/fm-account-routing-a.test.sh` at 13:03:14, finished it at 13:47:11, and moved on to `tests/fm-account-routing-b.test.sh`.
Nothing was stuck; a 44-minute script was taking 44 minutes.

The flushed log of the aborted evidence run says the same thing in full.
In its 52.3 minutes, run `01KZ1P01GK1HJ5JGX1B1Q73VMA` entered three test scripts and printed 39 passing assertions, ending partway through `tests/fm-account-routing-a.test.sh`.
Steady forward progress - and also **three scripts out of 92 in 52 minutes**, which extrapolates to roughly a day for one pass at that load.
That number belongs to `fm-gate-serial-e2e-bottleneck`, not here, but it is the reason a healthy step is so easy to mistake for a dead one.

**Duration scales with concurrency, which is the signature of contention rather than a hang.**
Grouping every terminal `test` step by how many other `test` steps on this repo overlapped it:

| concurrent peers | runs | average minutes |
| --- | --- | --- |
| 0 | 9 | 90 |
| 1 | 12 | 86 |
| 2 | 7 | 94 |
| 3 | 6 | 254 |
| 6 | 10 | 184 |
| 7 | 2 | 334 |
| 8 | 3 | 423 |

Test isolation is not the problem and was checked: each case runs under its own `FM_HOME`/`FM_STATE_OVERRIDE` in a temp directory, and the tmux-backed cases use per-run dedicated sockets rather than the shared default one, so concurrent suites are not deadlocking on each other.
They are competing for 14 cores, at a load average of 26-31 during this incident.

## Why this looked exactly like a deadlock

Three separate problems compounded, and only the first is fixed here.

1. **No liveness signal for a configured-command step.** The subject of this postmortem, fixed by `bin/fm-nm-command-supervisor.sh` and `bin/fm-nm-step-liveness.sh`.
2. **The suite is an hour long serially.** `tests/behavior-test-durations.tsv` sums to 59.2 minutes across 92 scripts, and the gate runs them in one serial loop. Tracked separately as `fm-gate-serial-e2e-bottleneck`; deliberately not addressed here.
3. **Nothing bounds how many validation runs share the machine.** See the correction below.

A slow step, with no liveness signal, whose slowness is amplified by unbounded parallel runs, is indistinguishable from a hang.
That combination is what produced four wrong calls in one day, and no single one of the three explains it.
Fixing the liveness signal does not make a multi-hour gate step operable; it only makes the difference between working and dead observable, so a wrong call is no longer the default outcome.

### Correction: the gate is serialized per BRANCH, not per repo

It is natural to read the queueing as lanes waiting behind a single per-repo gate slot.
That is not what the daemon does, and the distinction changes what problem 3 actually is.

Every cancellation in the daemon log is same-branch: a push to a branch cancels that branch's active run and starts a fresh one.
At 12:30:10 a push to `fm/nomistakes-daemon-reliability-d3` cancelled run `01KZ0S6YYZWPPT8M5PGTYD947A` on that branch, while six other runs on the same repo kept running untouched.
Concurrency across branches on one repo is **unbounded**: five test steps on this repo were executing simultaneously during this incident, and seven have been observed historically.

So lanes are not queueing behind one slot.
Each lane is waiting on its own run, and every other lane's run is what makes it take 3 to 7 hours instead of 90 minutes.
The compounding factor is too much parallelism, not too little - which is the opposite of what a queueing model would suggest, and it means bounding concurrent runs would shorten the tail directly.

## Evidence

- Run `01KZ1P01GK1HJ5JGX1B1Q73VMA` at head `5a4cc14c`, preserved as evidence and inspected live before it was aborted at 13:45:50.
- The three sibling runs `01KZ1MGVG2C0D9JER58PF1ZK63`, `01KZ1MWG37CF9KGA9D10Z4BQ4V`, `01KZ1MZG7BJYGE8EJCZ52KYH7B`, all on different branches, all with the identical 344-byte log.
- The three aborted runs, whose daemon log entries read `step test: waiting for approval: cancelled: aborted by user` at 12:20:14, 12:47:31, and 13:45:50.
- The 45,501-byte flushed `test.log` of `01KZ1P01GK1HJ5JGX1B1Q73VMA`, which is the complete record of what that "dead" step actually did.
- `tests/behavior-test-durations.tsv` for the measured suite runtime.
