# Crosscheck bounded I/O

Crosscheck treats every external byte stream, artifact, item collection, and process tree as hostile to availability.
The shared implementation is `bin/fm_bounded_io.py`.

One absolute deadline covers command execution, output draining, final wait, and cleanup.
Stdout and stderr share one aggregate byte ceiling, and the command's whole process group is terminated after either failure or a successful leader exit.
Structured artifacts must be stable regular files within a byte ceiling before decoding, and decoded depth, item count, and string bytes are bounded separately.
Review and evidence batches share a deadline and item counter rather than multiplying a per-item timeout by repository-controlled array length.

These controls close a recurring fleet failure class: a nominal limit does not provide a bound when an alternate byte channel, descendant process, or repeated item can bypass it.
The defects were found by deeper review of the pre-fix branch; they were not caused by the preceding eight-finding fix round.
That is good news about those fixes, but it also records unusually high defect density in the original Crosscheck review surface.

The deterministic suite is `tests/fm-bounded-io.test.sh`.
Every named case can run independently so mutation evidence can prove that it becomes red when its corresponding bound is removed.

## Mutation evidence

The following mutations were executed on 2026-08-03 and restored before the final green run.

| Named case | Executed mutation | Observed red result |
| --- | --- | --- |
| `output-limit` | Replaced the aggregate `captured > output_limit` guard with an unreachable condition. | `FAIL: noisy process crossed the aggregate output ceiling` |
| `final-wait` | Extended the command deadline beyond the declared wall-clock deadline. | `FAIL: closed output pipes escaped the command deadline` |
| `residual-group` | Skipped process-group cleanup after a successful leader exit. | `FAIL: successful leader left residual process ... alive` |
| `artifact` | Disabled both encoded artifact byte checks and read through the declared ceiling. | The expected byte-limit diagnostic disappeared, so the named case failed through the independent decoded-string ceiling. |
| `decoded-strings` | Disabled decoded key and value string-byte accounting. | `FAIL: decoded strings bypassed their aggregate ceiling` |
| `batch-items` | Disabled the incremental item-count guard. | `AssertionError: batch item ceiling was not enforced` |
