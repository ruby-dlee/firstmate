# Azure Crosscheck implementation evidence - 2026-08-12

## Scope

This evidence covers only the pre-deployment emergency implementation checkpoint for the Azure Crosscheck adapter.
It does not claim a live Azure review, policy-grade acceptance, or cloud-default readiness.
Azure mutation remained prohibited because the exact foundation/runner candidate was still under repair.

## Exact base

The branch was created directly at remote candidate `06de6bf8e762c72485b1fd59cc729eb7dfd0eb11` after proving `origin/fm/azure-release-integration-k7` resolved to that object.
The stacked branch is `fm/azure-crosscheck-isolation-v3`.
Before push, the branch must be rebased onto the next exact repaired `origin/fm/azure-release-integration-k7` head reported by Firstmate.

## Implementation proof

The change keeps Crosscheck-specific execution, compartment, ledger-adapter, documentation, and tests in dedicated files:

- `bin/fm-crosscheck-azure.py`
- `bin/fm-crosscheck-azure-model-guest.sh`
- `bin/fm-crosscheck-azure-tool-bridge.py`
- `bin/fm-crosscheck-azure-tool-client.py`
- `bin/fm-crosscheck-azure-tool-command.py`
- `bin/fm-crosscheck-azure-replay.py`
- `docs/azure-crosscheck.md`
- `docs/azure-crosscheck/compartment.json`
- `tests/fm-crosscheck-azure.test.sh`

The existing `bin/fm-crosscheck.py` integration is narrow: it selects the adapter, lets the adapter return an ordinary v2 ledger run, validates the Azure identity extension on load and verify, and renders the compartment identity in the readable report.
The existing finding lifecycle, exact live head/claims check, independent reviewer selection, executing account/model policy, report, and expected-head merge gate remain in their owner.

The Azure adapter consumes the emergency runner's exact snapshot, request, identity, networkless execution, result, admission, and cleanup contracts.
It does not alter runner or foundation files.

## Focused commands

The following checks are the permitted local checkpoint set:

```text
python3 -m py_compile bin/fm-crosscheck.py bin/fm-crosscheck-azure*.py
bash -n bin/fm-crosscheck-azure-model-guest.sh
python3 -m json.tool docs/azure-crosscheck/compartment.json
shellcheck bin/fm-crosscheck-azure-model-guest.sh
tests/run.sh tests/fm-crosscheck-azure.test.sh
git diff --check
```

The exact outputs and final stacked commit will be refreshed before draft PR publication.
No no-mistakes command or complete repository suite belongs in this checkpoint.

## Live acceptance still owed

Live acceptance is blocked until Firstmate reports that the repaired exact foundation/runner candidate returned GO and the foundation apply was accepted.
The complete required real PR, two-concurrent-review, fault-isolation, malicious-probe, networkless-replay, force-push-invalidation, merge-gate, zero-residue, Mac-responsiveness, and cost sequence is in `docs/azure-crosscheck.md`.

Until that sequence passes on Azure Linux, the implementation is a reviewed deployment candidate rather than a usable policy-grade service.
