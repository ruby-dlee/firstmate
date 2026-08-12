# Azure Crosscheck isolation

This document owns the architecture, identity, network, cleanup, and operator contract for policy-grade Azure Crosscheck.
[`bin/fm-crosscheck-azure.py`](../bin/fm-crosscheck-azure.py) owns the local control adapter, [`docs/azure-crosscheck/compartment.json`](azure-crosscheck/compartment.json) owns the credentialed model VM, and the existing Crosscheck core remains the sole owner of the v2 finding ledger, readable report, and expected-head merge gate.

## Boundary

Azure Crosscheck moves only policy review from the local Mac.
Firstmate, authors, no-mistakes, browsers, and the primary supervisor remain local.
Remote Herdr is not required.

One review uses three fresh compartments with three different immutable VM and boot identities:

- A credentialed model compartment receives exactly one independently selected reviewer account, the bounded claims and ledger projection, and a read/tool client.
- A fresh identity-less `crosscheck-tool` runner receives the exact clean committed snapshot and executes only allow-listed repository reads and evidence commands.
- A second newly created identity-less `crosscheck-tool` runner independently replays every accepted helper with no network and no credential.

The model compartment never receives repository files or a shell against the repository.
The tool and verifier never receive the reviewer credential, Azure identity, GitHub credential, author worktree, control home, sibling task data, browser profile, shared temporary state, container socket, SSH agent, or machine-wide validation socket.
A single VM containing both provider credentials and repository commands is not accepted by this adapter.

The existing local review route remains available only when Azure mode is not selected.
Set `FM_CROSSCHECK_EXECUTION_MODE=azure`, or create a safe `config/crosscheck-azure.json` with `"enabled": true`, to select Azure.
A selected Azure run never falls back to the local Mac after any admission, transport, identity, tool, verifier, or cleanup failure.

## Exact identity

Every attempt binds these values into one canonical review generation:

- SHA-256 canonical `FM_HOME` binding.
- Task id and canonical PR URL.
- Exact live remote PR head.
- Reviewed merge base and observed base-branch tip.
- Stable PR claims digest.
- Reviewer harness, model, effort, and account-home digest.
- Complete pre-run v2 ledger digest.
- Deployment generation and request digest.
- Model, tool, and verifier resource IDs, immutable VM instance IDs, and boot IDs.

The exact review generation is carried in Azure tags, staged object prefixes, the model result, both command-runner requests, both returned compartment identities, the v2 reviewer record, and the readable report.
The reviewer-account component hashes the upstream account identity read from the exact credential, never the account-home path, because two paths may execute as one account and one path may drift to another account.
Missing or mismatched identity is a tool failure.
The merge gate revalidates the Azure identity record in addition to its existing live head, claims, durable findings, reviewer, and evidence proof checks.

A force-push changes the live head and invalidates the ordinary exact-head ledger match.
A stale claims document invalidates the claims match.
A wrong account, model, generation, VM, boot, request, transport, or cleanup identity cannot become a clear run.

## Model compartment

The model VM uses a separately built and reviewed exact Azure image resource ID supplied through `FM_CROSSCHECK_AZURE_MODEL_IMAGE_ID`.
The image pins the supported Codex, Claude, or Pi reviewer CLI, the model guest, the unprivileged tool client, and a root-owned tool bridge service.
No package or executable is downloaded after the VM begins review.

The reviewer credential is staged as a short-lived exact-object capability.
It exists only in the model compartment and is removed before result publication.
Claude Azure review requires a provider-supported Linux file credential.
The macOS Keychain is never copied.

The model process has no Azure CLI credential, managed identity, SSH agent, Docker socket, repository checkout, control-home mount, or broad shell tool.
It reaches the provider and the one declared GitHub metadata host only through the model subnet's fixed egress policy and reaches repository operations only through `/run/fm-crosscheck/tool-bridge.sock`.
The bridge is installed and root-owned in the pinned image.
Its unprivileged client cannot choose a host, subscription, resource class, credential, endpoint, or cleanup scope.

The compartment is bounded by a 4-vCPU/16-GiB reviewed SKU, 12-GiB process memory, zero swap, 1,024 PIDs, private temporary state, strict system/home/kernel protection, a 7,200-second maximum review deadline, a 16-MiB transcript ceiling, a 2-MiB verdict/result ceiling, and a 24-hour independent self-shutdown backstop.
The command implementation may lower these bounds but may not raise them.

## Tool and verifier compartments

The trusted bridge consumes the existing Azure runner's exact snapshot, request, result, fencing, admission, and cleanup contracts rather than redesigning them.
Every repository operation creates a fresh `crosscheck-tool` invocation VM in `snet-validation-shards`.
The final accepted-evidence replay creates another new invocation and rejects VM-instance reuse.

The allow-listed operation vocabulary is:

- bounded regular-file read;
- bounded `rg` over declared repository roots;
- bounded regular-file inventory and one-directory listing;
- exact `git diff` for the bound base and head;
- non-profile Bash execution of a helper under `.crosscheck/reproductions/`; and
- final replay of at most 32 accepted helpers.

No free-form login shell, generic command launcher, arbitrary absolute path, symlink traversal, upload, SSH, Azure CLI, container runtime, package install, background daemon interface, or mutable endpoint is exposed.
Every command child is further bounded by the `crosscheck-tool` runner class: three CPU cores, 12 GiB memory, zero swap, 1,024 PIDs, 40-GiB task filesystem, 8-MiB per-stream logs, 128-MiB artifacts, and two-hour wall time.
Repository networking is zero bytes.

Accepted evidence is replayed in a second new networkless and credentialless invocation.
The verifier sees only the exact snapshot and accepted reproduction helpers.
A verifier command failure, output overflow, identity mismatch, transport loss, or cleanup ambiguity is a tool failure and blocks merge.
Ambiguous result or evidence remains retained for investigation instead of being labeled clear.

## Network and cloud authority

All VMs have private NICs and no public IP, password, SSH key, public load balancer, inbound NAT, or public listener.
Azure Managed Run Command is the control transport.
The model compartment uses `snet-policy-review`.
Tool invocations use the foundation's private validation-shard contract.
The verifier attempt has no repository network and no cloud identity.

The foundation must additionally apply role-specific egress rules before live acceptance:

- Model egress permits DNS, the exact provider endpoint and port, and the exact required GitHub metadata endpoint only.
- Tool and verifier repository execution deny all IP networking after the snapshot and fixed image closure are staged.
- Link-local metadata and Azure Instance Metadata Service are denied.
- Cross-compartment VNet, private-endpoint, control, author, validation, browser, and sibling traffic are denied.

A broad NAT route without those exact rules is not policy-grade even if the model VM itself has no managed identity.
The real acceptance inspection must prove effective NSG, guest firewall, DNS, route, and metadata behavior.

The local controller requires exact tenant, subscription, resource group, storage, VNet, private endpoint, deployment generation, SKU, quota, budget, and current-cost proofs from the accepted foundation and runner.
It never changes the ambient Azure CLI default.
It creates no role assignment, provider registration, public path, support ticket, quota request, or deployment foundation.

## Parallelism, admission, and cleanup

There is no warm review compute and no review queue daemon.
Zero waiting reviews means zero model, tool, or verifier VMs.
The software cap defaults to four active model compartments and can be configured from one through eight.
Regional and exact-family quota can impose a lower cap.
Review admission is separate from author, no-mistakes, browser, and supervisor capacity.

Two admitted reviews have distinct review generations, staged object prefixes, model VMs, tool invocations, verifier invocations, process trees, scratch, credentials, and cleanup authorization.
They do not share a database or writable account disk.
The durable v2 per-task lock and ledger remain home-local and keep one writer per task.

Cleanup starts only after a complete digest-bound result and exact compartment identities are retained.
The controller re-reads tags and ETags before conditional deletion.
It deletes only the attempt's review and safety Managed Run Commands, model VM, NIC, OS disk, exact staged request, exact staged credential, and exact staged result.
Every conditional deletion is followed by an exact absence proof, and an authorization, transport, or inventory error remains ambiguity rather than being treated as absence.
The reused Azure runner independently performs the same identity-pinned cleanup for tool and verifier invocations.
Foreign, missing, replaced, unreadable, or partially deleted resources retain state and fail closed.
No resource group, subnet, shared storage account, foundation resource, sibling prefix, author VM, validation run, browser, supervisor, or another review can be deleted.

## Operator setup

The Azure foundation and disposable runner are now released on `main`, but the current foundation deployment is only partial, has zero VMs, and is not accepted for review reconciliation.
Do not apply or reconcile any Azure resource until Firstmate explicitly reports the corrected released foundation safe for that exact operation.
After that authorization, accept the released foundation and runner contracts, then build a pinned model image containing the tracked model guest, tool client, root bridge service, exact reviewer CLIs, and no ambient credential.
Record the exact image resource ID.

The home-local configuration is optional and gitignored:

```json
{
  "enabled": true,
  "provider_host": "exact-provider-host.example",
  "provider_port": 443,
  "github_metadata_host": "api.github.com",
  "reviewer_sku": "Standard_D4as_v6",
  "model_image_id": "/subscriptions/.../resourceGroups/.../providers/Microsoft.Compute/images/..."
}
```

The required environment is the accepted foundation's existing `FM_HOME`, `FM_AZURE_TENANT_ID`, `FM_AZURE_SUBSCRIPTION_ID`, `FM_AZURE_NAMING_PREFIX`, `FM_AZURE_STORAGE_NAME`, `FM_AZURE_OWNER_TAG`, `FM_AZURE_DEPLOYMENT_GENERATION`, and independently accepted `FM_AZURE_BLOB_PE_NIC_RESOURCE_GUID`, plus the exact image through the config or `FM_CROSSCHECK_AZURE_MODEL_IMAGE_ID`.
The standard Crosscheck reviewer roster remains `config/crosscheck-reviewer.json` and keeps its existing account/model policy.

After acceptance, the operator flow remains unchanged:

```sh
bin/fm-crosscheck.sh run <task-id> <full-pr-url>
bin/fm-crosscheck.sh verify <task-id> <full-pr-url>
```

The same `data/<task-id>/crosscheck-ledger.json` and `data/<task-id>/crosscheck.md` are written.
Only the reviewer execution record gains `execution_mode: azure-compartment-v1` and the complete compartment identity.

## Focused local verification

The implementation's deterministic checks use fake Azure/runner/model fixtures only and never create a cloud resource:

```sh
tests/run.sh tests/fm-crosscheck-azure.test.sh
bash -n bin/fm-crosscheck-azure-model-guest.sh
python3 -m py_compile bin/fm-crosscheck.py bin/fm-crosscheck-azure*.py
python3 -m json.tool docs/azure-crosscheck/compartment.json
bin/fm-lint.sh
```

This emergency lane must not invoke no-mistakes or the full repository suite locally.

## Live acceptance after exact foundation approval

Policy-grade usability remains unclaimed until the approved Azure deployment records dated Linux evidence for every leg below.
Every denied malicious probe needs an allowed positive control that proves the harness could observe the counterpart.

1. Review a real open PR from a fresh remote exact head with a model/account independent from the author.
2. Prove the model sees allowed claims, ledger projection, tool output, and provider completion while reviewer-token reads from tool/verifier are denied.
3. Prove allowed repository-file read, allowed exact diff, and allowed helper output while control-home, sibling, author-worktree, browser-profile, validation socket, container socket, SSH agent, cloud metadata, private-neighbor, and network escape probes are denied.
4. Prove an allowed regular artifact and allowed in-tree path while symlink swaps, rename races, devices, FIFOs, absolute paths, parent escapes, and oversized output/artifacts are denied.
5. Prove a bounded child command while fork, daemon, detached descendant, PID, CPU, memory, disk, and wall exhaustion remain bounded and complete guest destruction removes residue.
6. Submit wrong reviewer account, model, head, base, claims digest, home, task, review generation, request digest, VM instance, boot identity, and stale endpoint/result fixtures; each must become a tool failure.
7. Run two real reviews concurrently and prove distinct accounts, model VMs, tool VMs, verifier VMs, process trees, scratch, object prefixes, ledgers, and cleanup authority with no shared residue.
8. Kill one model compartment and prove the other review, one author, one no-mistakes validation run, and the primary supervisor remain healthy.
9. Kill one tool VM and prove its review fails closed while the other review continues.
10. Replay accepted evidence in a second fresh VM with networking and credentials absent; compare output/exit digests and reject any difference.
11. Force-push the reviewed PR and prove `fm-crosscheck.sh verify` rejects the stale ledger before merge.
12. Run the merge-gate verification for the current head and prove it prints only the reviewed SHA.
13. Inspect Azure inventory after collection and prove all disposable model/tool/verifier Managed Run Commands, VMs, NICs, disks, and per-review staging objects are gone while foundation, author, validation, browser, supervisor, and other review resources are unchanged.
14. Record exact image, CLI versions, commands, VM/boot identities, NSG/route/firewall facts, cleanup inventory, Azure cost, and Mac CPU/memory/swap/process responsiveness in a dated evidence document.

Cloud-default acceptance additionally requires that the real PR's current head has a clear v2 ledger, the expected-head merge gate succeeds, and every disposable review resource is destroyed without affecting the rest of the fleet.
If any leg fails, Azure Crosscheck is not policy-grade, the PR remains unmergeable, and the local path is not an automatic fallback.

## Deliberate limits

This service does not move Firstmate, authors, no-mistakes coordination, browsers, Herdr, or general elastic workers to Azure.
It does not provide remote terminal visibility.
A later Herdr proxy may display a review, but authoritative liveness and cleanup remain the exact Azure review/VM/boot identities.

The tracked image build and live network policy must be deployed and evidenced before real acceptance.
The controller-to-model tool transport and its exact clean source staging must also be exercised end to end; a model-resident bridge may not gain broad Azure authority or receive the repository as a shortcut.
The adapter deliberately refuses to infer that an arbitrary Ubuntu image contains a reviewer or tool closure.
