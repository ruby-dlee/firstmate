# Azure Crosscheck implementation evidence - 2026-08-12

## Scope

This evidence covers the resumed pre-deployment implementation checkpoint for the Azure Crosscheck adapter.
It does not claim a live Azure review, policy-grade acceptance, or cloud-default readiness.
Azure mutation remained prohibited because the released foundation is only partially deployed with zero VMs and has not been reported safe for reconciliation.

## Exact integration base

PR 129 has merged, so the stacked integration branch is no longer the base.
Immediately before rebase, `origin/main` resolved to `b5c1b75df6aff6965242058bfdcda3925f90d96f`, PR 130's fetched head and `origin/fm/azure-crosscheck-isolation-v3` both resolved to `4f67fc2c691f1f33b50004e6e1f92cc488ad126a`, and the existing implementation was rebased onto that released main commit.
PR 130 must now target `main`.
Remote PR head and branch state remain authoritative before every later rebase or push.

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

The existing `bin/fm-crosscheck.py` integration remains narrow.
It selects the adapter, lets the adapter return an ordinary v2 ledger run, validates the Azure identity extension on load and verify, and renders the compartment identity in the readable report.
The existing finding lifecycle, exact live head and claims check, independent reviewer selection, report, and expected-head merge gate remain in their owner.

The resumed implementation binds review generation to the executing upstream reviewer account identity instead of the account-home path.
It re-proves same-provider author separation before credential staging, conditionally removes exact model resources and staging objects by ETag, refuses ambiguous reads as absence, includes the safety Run Command in cleanup, and proves absence after deletion.
Tool invocations now carry the trusted adapter implementation inline rather than assuming the reviewed repository contains Firstmate's Crosscheck helpers.
The exact diff places revisions before Git's path separator, the runner receives no phantom `.crosscheck` artifact declaration, and oversized regular-file reads fail instead of becoming truncated review input.

The released Azure runner on `main` is now the integration contract.
Its exact environment also requires `FM_AZURE_OWNER_TAG` and the independently accepted `FM_AZURE_BLOB_PE_NIC_RESOURCE_GUID`; the operator documentation names both.

## Focused commands and outcomes

The resumed checkpoint ran only the permitted focused checks:

```text
bash tests/fm-crosscheck-azure.test.sh
python3 -m py_compile bin/fm-crosscheck.py bin/fm-crosscheck-azure*.py
bash -n bin/fm-crosscheck-azure-model-guest.sh
python3 -m json.tool docs/azure-crosscheck/compartment.json
git diff --check
```

The focused Crosscheck suite passed its named static-boundary, explicit-selection, exact-identity, account-binding, ambiguous-cleanup, allow-listed bridge, symlink denial, oversized-output denial, networkless replay, and documented-acceptance cases.
The compile, Bash syntax, ARM JSON parse, and diff checks passed.
No no-mistakes command, full repository suite, shared validation-daemon operation, Azure apply, VM creation, cloud cleanup, PR merge, or default-branch push was performed.

## Live acceptance still owed

Live acceptance remains blocked until Firstmate reports the corrected released foundation safe for the exact reconciliation or invocation.
The complete required real PR, two-concurrent-review, fault-isolation, malicious-probe with positive controls, networkless replay, force-push invalidation, merge-gate, zero-residue, Mac-responsiveness, and cost sequence is in `docs/azure-crosscheck.md`.
The controller-to-model bounded tool transport and exact clean source staging must be proven in that path without granting broad Azure authority to the credentialed model compartment or copying the repository into it.
Until every leg passes on Azure Linux, the implementation is a deployment candidate rather than a usable policy-grade service.
