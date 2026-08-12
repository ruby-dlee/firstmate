# Process-tree supervisor health

`bin/fm-process-tree-lib.sh` owns the bounded shell command runner, and `bin/fm-process-tree-health.py` owns its read-only host census and explicitly authorized legacy-orphan reaper.

## Failure mechanism

The runner starts a foreground Perl supervisor, which forks a process-group anchor, which forks the wrapped command.
After the command exits, the anchor writes its status and waits on a finish pipe for the supervisor to confirm that group cleanup was verified.
The old wait loop accepted only the one-byte finish record.
If the supervisor died after the status write but before that finish record, the pipe returned EOF, the loop ignored it, and the anchor slept and retried forever after launchd adopted it.
The anchor retained the complete inline Perl program in its arguments, so every leaked process contributed a large argument vector.

The supervisor also had no liveness channel for the shell caller that owned its temporary files.
A caller that died left the supervisor running until some later timeout or external cleanup, widening the window in which the anchor could be stranded.

The fixed anchor treats finish-pipe EOF as the precise portable parent-death record already provided by its one-writer pipe unless the supervisor first wrote an explicit retain record for an unverified cleanup.
The foreground supervisor separately samples its original parent PID every 100 milliseconds and enters its ordinary group cleanup when that parent changes.
Periodic `getppid()` was chosen over macOS `kqueue NOTE_EXIT` because the library also runs on Linux, Perl ships the required high-resolution timer in core on the supported hosts, and the existing finish pipe remains more precise for the inner anchor relationship.
The timer is disarmed in both forked children before they execute any inherited handler.

## Diagnosis trap

The visible fleet failure can be `gh-axi` reporting that its own bounded process arguments inventory is oversized.
That message identifies the component performing the bounded census, not the component that filled it.
Firstmate's leaked inline Perl supervisors were the source of the pressure, which made GitHub reads, merge polls, and exact-head Crosscheck reviews fail closed while appearing to blame `gh-axi`.

`bin/fm-process-tree-health.py report` prints the leaked-supervisor count, the same-user parentless process-argument census in bytes, whether the census completed within its bounds, and the number of proven safe legacy reaper candidates.
Session-start bootstrap remains silent for a complete low census with no leak, but emits `PROCESS_TREE_HEALTH:` for any leaked supervisor, an incomplete census, or parentless argument pressure at or above 2 MiB.
This early line names Firstmate before the 4 MiB cleanup census used by downstream gates fails.

## Legacy orphan reaper

The reaper is not an automatic landing or bootstrap side effect.
Existing orphans can span multiple Firstmate homes and may represent pending cleanup records, so running it requires the captain's explicit approval and the literal `reap --apply` flag.

A reaper candidate must pass every condition in one complete bounded census and a second complete revalidation census: it is a same-user Perl process parented by init, its arguments carry all exact Firstmate supervisor markers, its PID is its process-group ID, it is the only member of that group, and no readable Firstmate guard file still retains that PID.
That shape identifies the already-finished legacy anchor whose parent disappeared, not a live supervisor with a wrapped command or descendants.
macOS signaling uses an audit-token-bound PID identity and processes at most 32 candidates per invocation.
The helper refuses destructive operation on other platforms, on a partial census, on identity drift, or without `--apply`.

Use the read-only report first:

```sh
bin/fm-process-tree-health.py report
```

Only after explicit captain approval, run one bounded batch and inspect the result before deciding whether another batch is warranted:

```sh
bin/fm-process-tree-health.py reap --apply --limit 16
bin/fm-process-tree-health.py report
```

Never replace this path with a name-based or command-line-based mass kill.

## Regression proof

`tests/fm-process-tree.test.sh` creates an isolated runner tree, parks the outer supervisor after the anchor has written command status, kills only that test-owned supervisor, and asserts that the now-orphaned anchor exits on finish-pipe EOF.
A second case kills the shell caller and asserts that the foreground supervisor and wrapped command exit well before the declared command timeout.
The tests prove orphan exit directly and do not infer correctness from the machine's ambient leaked-process count.
