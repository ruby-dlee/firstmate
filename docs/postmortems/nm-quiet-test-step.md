# The quiet no-mistakes test step - 2026-08-02

Four firstmate-repo validation runs were reported dead at the `test` step, and every firstmate PR was declared blocked from validating.
Two further runs were aborted to escape the same reported condition.

**None of the six steps was dead.**
All of them were executing normally.
The reported condition was a false negative produced by three independent no-mistakes signals that all read as death for a step running a configured shell command, compounded by a hand check that cannot see the processes it was looking for.
The only real damage was the two aborted runs, which were healthy work discarded on a wrong reading.

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
The two aborted runs prove the same mechanism from the other side: their logs are 39 KB and 159 KB, both with an mtime equal to the second they were aborted, so the buffered output landed only when the step ended.

**The hand check could not have found the processes.**
It searched by process name.
The test command's argv is `sh -c command -v tmux ...` and its children are `bash tests/fm-account-routing-a.test.sh` - relative paths.
Neither the run id nor the worktree path appears anywhere in any of their argv.
`ps -ef | grep 01KZ1P01GK1HJ5JGX1B1Q73VMA` genuinely returns nothing while three of the run's processes are live.
The only reliable link from a process to its run is its **working directory**.

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

`bin/fm-nm-step-liveness.sh` answers the question the tool could not: are this run's own processes alive and doing work?
It finds processes by **working directory**, which is the one attribute that reliably identifies them, and separates four outcomes that were previously indistinguishable.

- `alive` - processes present and making measurable progress.
- `stalled` - processes present but no progress in the sample window; explicitly not dead, because a command blocked on I/O or sleeping reads this way.
- `dead` - provably zero processes while the step is recorded running. This is the only verdict that justifies discarding a run.
- `unknown` - the answer could not be established. Fail-closed, following the rule `bin/fm-lock-lib.sh` already applies to `lsof`: an unreadable answer is never evidence of absence.

`bin/fm-crew-state.sh` calls it automatically whenever the active step renders quiet, so the verdict appears in the ordinary heartbeat read:

```
state: working · source: run-step · validating (running) · test alive (3 procs)
```

The verdict is appended as an observation and never overrides the run state, because a step caught momentarily between processes would otherwise be reported dead - recreating the failure in the opposite direction.
The `ci` step is exempt: its monitoring runs inside the daemon and owns no worktree process, so a verdict there would always read `dead` and mean nothing.

## Operating rule

**Never abort a run on a reported-quiet step without a `dead` verdict from `bin/fm-nm-step-liveness.sh`.**
Quiet is not evidence.
For a configured-command step, quiet is the *expected* rendering for the step's entire duration, and for this repo that duration is routinely measured in hours.

## What is still a no-mistakes defect

Two things here are the tool's to fix, and firstmate should not paper over either.

**Reporting.**
A step running a configured command should publish the command's pid the way an agent step publishes `agent_pid`, and should flush its log incrementally rather than at step end.
Either change alone would have prevented this incident, because either one makes `last_activity` advance.
The smallest correct fix is the pid: it is a single field on a record no-mistakes already writes when it spawns the process, and it makes liveness answerable from `axi status` alone with no process inspection at all.

**Recovery.**
A step whose process genuinely dies stays `running` forever.
`axi respond --action fix` refuses because the step is not `awaiting_approval`, `axi run` re-attaches to the same stuck run, and only `abort` escapes - at the cost of the entire run.
That gap is real and was correctly identified; it is simply not what happened on 2026-08-02.
The smallest correct fix is for the daemon to reap a step whose recorded process is gone and mark it failed, which makes the existing auto-fix path applicable instead of requiring an abort.

Neither can be fixed from this repo: no-mistakes is installed as a compiled binary at `~/.no-mistakes/bin/no-mistakes` with no source available here.
Until they land, `bin/fm-nm-step-liveness.sh` is the detection firstmate needs, and abort remains the only recovery for a genuinely dead step.

## Evidence

- Preserved dead-state run `01KZ1P01GK1HJ5JGX1B1Q73VMA` at head `5a4cc14c`, retained deliberately.
- The three sibling runs `01KZ1MGVG2C0D9JER58PF1ZK63`, `01KZ1MWG37CF9KGA9D10Z4BQ4V`, `01KZ1MZG7BJYGE8EJCZ52KYH7B`, all on different branches, all with the identical 344-byte log.
- The two aborted runs, whose daemon log entries read `step test: waiting for approval: cancelled: aborted by user` at 12:20:14 and 12:47:31.
- `tests/behavior-test-durations.tsv` for the measured suite runtime.
