# Pi author identity capture failure, 2026-08-12

## Outcome

The exact intermittent capture cause was not established.
The evidence does not prove host load caused either failed capture.
The spawn defect was established independently: `bin/fm-spawn.sh` converted every snapshot error into a warning, wrote `author_identity_snapshot_epoch=launch-bound-v1` without `author_account_identity`, and launched an author identity state that `bin/fm-crosscheck.py` deliberately rejects.

## Direct evidence

The live metadata for `winback-promo-verify-schedule-w3` and `winback-cut-to-three-k4` contained `author_identity_snapshot_epoch=launch-bound-v1` without `author_account_identity`.
The live metadata for `crosscheck-coverage-policy-unsatisfiable` contained the same epoch plus a non-empty identity.
The task-private Pi snapshot currently retained for each of those three tasks had a readable OAuth identity in the provider slot named by its recorded model.
The two failed tasks had been relaunched, so those retained successful snapshots do not prove that the original launch capture succeeded.
They do prove that the same task and provider-slot shapes can be captured successfully on a later attempt.

The inspection used the following read-only command against each task's recorded `tasktmp` and model slot.

```sh
python3 - <<'PY'
import json
from pathlib import Path
state = Path('/Users/dongkeun/firstmate-home/state')
for task in (
    'winback-promo-verify-schedule-w3',
    'winback-cut-to-three-k4',
    'crosscheck-coverage-policy-unsatisfiable',
):
    meta = dict(
        line.split('=', 1)
        for line in (state / f'{task}.meta').read_text().splitlines()
        if '=' in line
    )
    slot = meta['model'].partition('/')[0]
    auth = json.loads(
        (Path(meta['tasktmp']) / 'pi-author-agent' / 'auth.json').read_text()
    )
    credential = auth.get(slot)
    print(
        task,
        slot in auth,
        isinstance(credential, dict) and credential.get('type') == 'oauth',
        isinstance(credential, dict)
        and isinstance(credential.get('accountId'), str)
        and bool(credential['accountId'].strip()),
    )
PY
```

It reported `True True True` for all three retained snapshots.
The exact sweep command below reported four current failed-modern-capture task records, including both named bad examples.

```sh
FM_HOME=/Users/dongkeun/firstmate-home \
FM_STATE_OVERRIDE=/Users/dongkeun/firstmate-home/state \
bin/fm-author-identity-sweep.sh
```

## Why load is not a finding

`bin/fm-pi-author-snapshot.py` has no timeout.
Host load therefore cannot directly trigger a capture timeout in this implementation.
The snapshot traverses mutable Pi configuration and rejects a source file whose device, inode, or size changes while copied.
High load could widen that race window, but no original launch stderr or structured failure record survived to show that either failed launch took this branch.
The helper can also fail for permanent reasons such as a missing provider slot, unreadable or malformed `auth.json`, an unsafe filesystem entry, a file or tree size bound, or an ordinary filesystem error.
No available artifact distinguishes those branches for the two incidents.

## Remediation

Pi ship and scout author capture now runs before endpoint creation on every backend.
A new modern Pi task must produce both the immutable epoch and a non-empty account identity, or spawn refuses and rolls back the task temp, metadata, and Treehouse lease.
Modern recovery also refuses a missing recorded identity or an account mismatch because a later credential cannot prove who authored the earlier work.
Legacy recovery keeps its absent epoch and cannot mint launch provenance retrospectively.

No automatic retry was added.
Without the original failure classification, retrying every failure would mask permanent model, credential, and filesystem defects as transient load.
The refusal preserves the helper's specific stderr so a future occurrence identifies its actual branch immediately.
A future bounded retry should be limited to a measured transient class, such as a proved source-change race, rather than applied to every identity failure.
