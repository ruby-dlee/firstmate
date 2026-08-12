# Azure validation cells

This document owns the architecture, identity, admission, recovery, credential, cleanup, and operator contract for elastic Azure no-mistakes validation cells.
[`bin/fm-azure-validation.sh`](../bin/fm-azure-validation.sh) owns exact host commands, [`bin/fm-azure-validation.py`](../bin/fm-azure-validation.py) owns the state machine, and [`docs/azure-validation/cell.json`](azure-validation/cell.json) owns the per-cell Azure declaration.
The private foundation remains owned by [`docs/azure-pilot.md`](azure-pilot.md), and credential-free command VMs remain owned by [`docs/azure-runner.md`](azure-runner.md).

## Boundary

Firstmate and its primary supervisor remain local.
The local dispatcher may inspect Git identity, package an exact clean Git bundle, make bounded Azure control-plane calls, and verify returned protocol objects.
It never executes lint, tests, review commands, fixes, no-mistakes, a model provider, GitHub mutation, or CI control on the primary machine.
A queued request is non-billable and creates no Azure resource.

One admitted cell owns one no-mistakes run or a deliberately bounded continuation of that exact run.
It has its own VM, boot identity, systemd cgroup, process namespace, no-mistakes daemon and database, home, temp root, cache root, logs, encrypted durable worktree disk, credential-lease disk, cell storage identity, and private shard container.
No cell mounts `FM_HOME`, another task worktree, another credential lease, or another cell container.
No operation stops, starts, updates, or inspects a local legacy no-mistakes daemon.

Remote Herdr is not part of this path.
Later Herdr proxy tabs may display state, but validation submission, ask-user responses, recovery, evidence collection, and cleanup use Azure Resource Manager, Managed Run Command, and the private storage endpoint.

No Azure resource was created while implementing this feature.
The first live cell remains blocked until the exact foundation candidate is independently accepted, applied, and the stacked validation change is reviewed and explicitly approved for the exact subscription.

## Capacity and cost shape

The default `validation-heavy` control cell requires 8 vCPUs and at least 32 GiB.
The dispatcher live-selects the lowest current Linux consumption rate among the reviewed `Standard_D8as_v5`, `Standard_D8s_v5`, `Standard_D8ads_v5`, and `Standard_D8ds_v5` shapes that still proves x64 Gen2 Trusted Launch, encryption at host, all three East US zones, exact family quota, and no overlap with an active author-worker family.
Those v5 families are intentionally separate from the foundation's v6/v7 mixed author plan.
The allowlist is not a quota or price claim, so every allocation re-reads SKU restrictions, capabilities, family usage, regional usage, and retail pricing.

The regional target is 128 vCPUs.
The local-control deployment divides that target into an independently enforced 64-vCPU author budget and 64-vCPU validation/review budget.
A validation control cell consumes 8 of the validation vCPUs.
Eight requested behavior shards use eight separate 4-vCPU command VMs across the runner's reviewed mixed families, so the complete default validation shape peaks at 40 validation vCPUs and leaves replacement/review room inside the reserved 64.
Author admission is required to preserve its side of the same reservation.
Quota is only capacity and never turns into a warm allocation.

The default active-cell ceiling is eight, but processor reservation, exact-family quota, regional free quota, and current runner inventory may impose a lower ceiling.
`FM_AZURE_VALIDATION_MAX_ACTIVE` accepts only 1 through 8.
`FM_AZURE_VALIDATION_RESERVED_VCPUS` accepts only 8 through 64.
An optional owner-only `$FM_HOME/config/azure-validation-classes.json` policy binds repository slugs to `validation-heavy` or `validation-standard`; an explicit submit class must match the project policy instead of overriding it.
The policy schema is `fm.azure-validation-classes/v1` with a `default` class and a `projects` object keyed by `owner/repository`.
Saturation leaves requests queued instead of oversubscribing a host or silently falling back to the Mac.

The commissioning cost ceiling remains $1,500, while normal admission uses the $1,000 target.
Admission adds the foundation's conservative $210 shared-meter reserve, an $80 validation meter reserve, and 24 hours of the selected cell rate to both actual and forecast cost before accepting a new cell.
The default validation worker-hour planning budget is 400 hours per month.
`FM_AZURE_VALIDATION_MONTHLY_HOURS` may lower or explicitly revise that planning limit without changing infrastructure.
Unreadable cost, forecast, rate, usage, queue, or quota state fails closed.
Budget pressure stops only new admission and never terminates active work, a pending decision, an uncollected result, or retained recovery storage.

Cells and shard VMs are created only on demand.
A safely closed run deletes its control VM, Managed Run Command, NIC, OS disk, worktree disk, private cell container, direct role assignments, and cell identity after collecting the exact report and evidence.
The task-owned credential disk is detached and returned to its lease owner rather than deleted.
The expected idle VM count is zero.

## Run identity

The canonical request schema is `fm.azure-validation/v1`.
Its digest binds all of these identities before queueing:

- A SHA-256 binding of the canonical local `FM_HOME` path without sending that path to Azure.
- Task id and task generation.
- Validation generation.
- Foundation deployment generation.
- Cell id and random fence.
- Exact GitHub repository, named branch, pushed head, tree, and Git-bundle digest.
- Captain intent passed unchanged to no-mistakes.
- Resource class, resource limits, and requested shard count.
- Secret-free credential lease descriptor and its digest.
- Credential-free runtime bundle manifest and digest.
- Trusted guest and shard-bridge digests.

Azure tags repeat the non-secret home, task, generation, validation, cell, fence, branch, head, worktree, credential-lease, SKU-family, processor-reservation, and cost-attribution bindings.
The host records every resource id, ETag, VM instance id, identity client/principal id, and guest boot id before accepting a result or deleting anything.
The guest independently re-reads IMDS and requires the exact VM instance plus worktree and credential disk ids before unlocking either disk.
The credential disk's recorded LUKS UUID is checked after unlock.

A result schema `fm.azure-validation-result/v1` repeats the home, task, task generation, validation generation, cell, fence, branch, submitted head, current head, remote head, worktree disk, credential lease, no-mistakes run, VM, instance, and boot identities.
A passed result additionally requires a full PR URL, CI-green marker, exact remote-current head, and the complete independent behavior-shard receipt set.
Wrong-head, wrong-run, wrong-disk, wrong-VM, wrong-boot, stale, partial, or malformed results are retained and refused.

## Credential lease

Credential bytes never enter the repository bundle, runtime bundle, request JSON, local state JSON, Azure tags, ARM parameters, snapshots, reports, command logs, shard requests, shard responses, or identity-less command VMs.
They live only on a task-owned LUKS2 credential disk attached as data LUN 1 with `deleteOption: Detach`.
The disk denies public and export network access and is not snapshotted, cloned, imaged, or backed up.
The LUKS unlock value is read from an owner-only local file and supplied only as an Azure protected parameter.
The host state stores no unlock value or unlock-file path.

The secret-free lease descriptor uses schema `fm.azure-credential-lease/v1` and must itself be mode 0600.
It binds exactly one task and generation, provider adapter, provider-account identity hash, credential-disk content hash, disk id, ETag, LUKS UUID, zone, expiry, provider-home relative path, GitHub-token relative path, and GitHub authority.
The descriptor rejects keys named like tokens, secrets, passwords, private keys, credentials, or authorization values.

The GitHub authority must declare exactly one repository and exactly these operations:

- `contents:write`
- `pull_requests:write`
- `checks:read`

The authority kind must be a fine-grained token or GitHub App installation token.
The guest gives the coordinator the exact token file and installs a repository-local Git credential helper that reads only that file.
No token value is printed.
The credential lease remains attached until the exact run is closed, including through ask-user gates and VM replacement.

A descriptor has this secret-free shape:

```json
{
  "schema": "fm.azure-credential-lease/v1",
  "lease_id": "lease-task-generation",
  "task": "task-id",
  "task_generation": "generation-id",
  "provider": "codex",
  "provider_account_binding": "sha256:<64 hex>",
  "disk_content_binding": "sha256:<64 hex>",
  "disk": {
    "id": "/subscriptions/<id>/resourceGroups/<group>/providers/Microsoft.Compute/disks/<name>",
    "etag": "<exact Azure ETag>",
    "luks_uuid": "<exact UUID>",
    "zone": "1"
  },
  "paths": {
    "provider_home": "provider",
    "github_token": "github/token"
  },
  "github_authority": {
    "kind": "fine-grained-token",
    "repository": "owner/repository",
    "permissions": ["contents:write", "pull_requests:write", "checks:read"]
  },
  "expires_at": "2026-08-13T12:00:00Z"
}
```

The provider home and GitHub token path must be distinct, bounded disk-relative paths.
The disk must be detached and carry the exact `credential-lease` tag before admission.
A shared account disk, attached disk, expired lease, broad GitHub declaration, unreadable account binding, or wrong task/generation fails before VM creation.

## Runtime bundle

The cell image is pinned Ubuntu 24.04, but no ambient installed provider or no-mistakes version is trusted.
Submission requires a credential-free `runtime.tar.gz` with a `runtime.json` manifest using schema `fm.azure-validation-runtime/v1`.
The manifest binds the exact provider, no-mistakes semantic version, no-mistakes executable path, and SHA-256 digest of every regular runtime file.
The bundle rejects links, devices, escaping paths, files over 512 MiB, total size over 1 GiB, and credential-like paths such as provider homes, GitHub config, auth files, credentials, tokens, secrets, cookies, or Keychain material.
The guest re-verifies the complete file inventory and every digest before execution.

A minimal manifest shape is:

```json
{
  "schema": "fm.azure-validation-runtime/v1",
  "provider": "codex",
  "no_mistakes_version": "1.41.2",
  "no_mistakes_path": "bin/no-mistakes",
  "files": [
    {"path": "bin/no-mistakes", "digest": "sha256:<64 hex>"},
    {"path": "bin/provider", "digest": "sha256:<64 hex>"},
    {"path": "bin/gh", "digest": "sha256:<64 hex>"},
    {"path": "bin/gh-axi", "digest": "sha256:<64 hex>"}
  ]
}
```

The runtime bundle is code, not a credential transport.
Credential renewal or login is never performed by the dispatcher.

## Cell process and storage isolation

The cell template has no public IP, password, SSH key, inbound listener, load balancer, or public storage path.
It uses the foundation's private `snet-validation` subnet, isolated NSG, NAT egress, Trusted Launch, Secure Boot, vTPM, encryption at host, a disposable OS disk, a retained worktree disk, and an externally leased credential disk.
The VM receives one user-assigned identity created for that cell.
That identity and the exact local operator receive Blob Data Contributor only on the cell's unique private container.
The identity receives no subscription, resource-group, VM, network, Key Vault, sibling-container, or general validation-shards authority.

The guest creates or opens the LUKS2 worktree volume and opens the independently encrypted credential lease.
No-mistakes state, SQLite database, repository, temp, cache, logs, evidence, report, and shard exchange live on the worktree volume.
A replacement VM attaches that same volume.
The provider and GitHub lease live on the separate credential volume.

No-mistakes runs under one transient systemd cgroup with a 700-percent CPU cap, class-specific memory maximum, zero swap, bounded tasks, bounded wall time, control-group kill mode, private temp/devices, no new privileges, strict system/home/kernel/control-group protection, empty capability bounding set, and a cell-specific writable-path allowlist.
The no-mistakes database and daemon never share a restart boundary or connection with another cell or local home.
Stopping or losing one VM cannot stop a peer cell, shard VM, local supervisor, author worker, or legacy daemon.

## True behavior sharding

The trusted default-branch `.no-mistakes.yaml` preserves the ordinary local commands outside a validation cell.
Inside a cell it invokes only the root-owned shard bridge for lint and tests.
A worktree branch cannot replace that absolute bridge path.

For behavior parallelism, the bridge creates one exact clean Git bundle and eight `fm.azure-validation-shard/v1` requests.
Each request binds the cell, round, shard index/count, branch, current head, tree, bundle, fixed command, command digest, and declared manifest artifact.
The fixed behavior command is the existing sealed `bin/fm-behavior-shards.sh --run <N> 8` route with the explicit Azure/Linux non-Herdr selection already used by isolated CI.
The local dispatcher downloads only that credential-free bundle, materializes a temporary Git checkout, and prepares one existing Azure runner invocation per shard.
It does not run the command locally.

The dispatcher rotates the eight requests across the runner's eight reviewed mixed 4-vCPU families and sets the runner concurrency ceiling to eight.
The one-shot runner still re-proves live family quota, regional quota, rate, budget, private network, image, command bounds, and global admission under its own contract.
Every shard therefore receives a separate VM, OS disk, process namespace, port space, lock space, temp root, terminal-server space, boot id, and VM instance id.

The dispatcher returns one `fm.azure-validation-shard-result/v1` object per request.
The in-cell bridge verifies every request/head/command identity, requires a distinct VM instance and boot for every shard, reconstructs the eight executed manifests, and runs only the existing completeness verifier in the control cell.
No behavior test process runs in the credentialed cell or on the Mac.
A missing, duplicate, failed, wrong-head, wrong-command, reused-boot, or reused-VM shard fails the no-mistakes test step with exact failure attribution.

The same bridge sends lint through one identity-less runner VM.
Repository command children receive no provider home, GitHub token, cell identity capability, control home, credential disk, or sibling staging path.

## Queue and admission

`submit` proves a clean named branch whose exact head is already present at `origin`, validates the lease/runtime boundaries, creates a Git bundle, and writes one atomic mode-0600 queue record under `$FM_HOME/state/azure-validation`.
It does not contact Azure or run a repository command.
The default local queue depth bound is 128.

`dispatch` requires `--confirm-dispatch` and an exact subscription confirmation.
Before creating capacity it proves the tenant/subscription, private foundation, credential disk, selected SKU, family quota, 128-vCPU regional target, regional free quota, separate author/validation processor budgets, queue depth, active-cell count, worker-hour budget, actual cost, forecast cost, and current retail rate.
A renewable blob lease in `validation-shards/validation-cells/admission.lock` serializes count-and-create admission across Firstmate homes.
The lease is rechecked immediately before the cell starts.

A saturated request remains `queued`.
The dispatcher does not spin, overcommit, evict active work, change the ambient Azure subscription, request quota, register a provider, create a support ticket, buy a support plan, weaken network policy, or fall back to local validation.

## Submit and operate

Set the already reviewed foundation values from [`docs/azure-pilot.md`](azure-pilot.md), plus owner-only disk key files:

```sh
export FM_AZURE_VALIDATION_WORKTREE_KEY_FILE='<owner-only LUKS key file>'
export FM_AZURE_VALIDATION_CREDENTIAL_KEY_FILE='<owner-only LUKS key file>'
```

Queue without Azure mutation:

```sh
bin/fm-azure-validation.sh submit \
  --task '<task-id>' \
  --task-generation '<task-generation>' \
  --validation-generation '<validation-generation>' \
  --intent-file '<intent.txt>' \
  --credential-lease '<lease.json>' \
  --runtime-bundle '<runtime.tar.gz>' \
  --resource-class validation-heavy \
  --repo '<exact task worktree>'
```

Inspect the queue:

```sh
bin/fm-azure-validation.sh queue
bin/fm-azure-validation.sh status --cell '<azv-id>'
```

After explicit approval, admit one queued request:

```sh
bin/fm-azure-validation.sh dispatch \
  --confirm-dispatch \
  --confirm-subscription "$FM_AZURE_SUBSCRIPTION_ID"
```

Drive pending shard requests without executing them locally, then observe and collect:

```sh
bin/fm-azure-validation.sh drive --cell '<azv-id>' --wait-seconds 60
bin/fm-azure-validation.sh observe --cell '<azv-id>'
bin/fm-azure-validation.sh collect --cell '<azv-id>'
```

When no-mistakes owns an ask-user gate, write the exact response to an owner-only file and send it through a protected run command:

```sh
bin/fm-azure-validation.sh respond \
  --cell '<azv-id>' \
  --response-file '<response.txt>'
```

The response command first re-proves the exact VM instance.
The guest re-proves the cell, request, branch, current head, worktree disk, credential lease, stored no-mistakes run id, and database status before `axi respond` or reattach.
No new intent is supplied during reattach.

After an exact passed result is collected and the remote branch still resolves to the result head, close with that explicit head:

```sh
bin/fm-azure-validation.sh close \
  --cell '<azv-id>' \
  --confirm-close \
  --confirm-subscription "$FM_AZURE_SUBSCRIPTION_ID" \
  --confirm-head '<exact validated head>'
```

## Failure and replacement

A missing pane, terminal, process, Run Command, or VM never authorizes a duplicate no-mistakes run.
`replace` first requires an exact Azure inventory to prove the old VM absent, the retained worktree disk present with its recorded id and ETag, the credential lease unchanged and detached, and a recoverable phase.
It creates a new fenced VM/boot attempt but reuses the same cell identity, private container, encrypted worktree, no-mistakes home/database, credential lease, task, branch, and validation generation.

The replacement guest refuses unless the retained identity file matches the request, branch, current head, worktree disk, credential lease, and exact no-mistakes run id.
It then requires `no-mistakes axi status` from the retained database to contain that exact run id before invoking `no-mistakes axi run` without an intent.
A missing or ambiguous proof retains both disks and starts nothing.

Replace only after the old VM is independently known absent:

```sh
bin/fm-azure-validation.sh replace \
  --cell '<azv-id>' \
  --confirm-replace \
  --confirm-subscription "$FM_AZURE_SUBSCRIPTION_ID"
```

If a run fails or its result is ambiguous, remove only its exact disposable compute while retaining the encrypted worktree, lease, private container, and evidence for diagnosis:

```sh
bin/fm-azure-validation.sh retain-failure \
  --cell '<azv-id>' \
  --confirm-retain \
  --confirm-subscription "$FM_AZURE_SUBSCRIPTION_ID"
```

No failure path deletes a worktree disk, credential disk, private container, or result object.
No command names or deletes a resource group, subnet, foundation identity, another cell, another shard, another task prefix, or a local daemon.

## Cleanup order

Successful close occurs only after complete result/report/evidence collection, CI-green proof, exact remote-current head proof, and explicit head confirmation.
It removes resources in this exact scope and order:

1. The cell's attributed validation Managed Run Command.
2. The exact cell VM.
3. The exact NIC.
4. The disposable OS disk.
5. The exact encrypted worktree disk.
6. The two direct role assignments on the cell's private container after proving their exact principal inventory.
7. The exact private container.
8. The exact cell identity.
9. Local transient payloads after the durable result is retained.

The credential disk is detached and returned to the lease owner only after that exact close.
A missing ETag, changed instance, foreign tag, foreign principal, extra role assignment, partial delete, unreadable absence, wrong head, failed run, pending decision, or incomplete result changes the state to retained cleanup and stops.

## Acceptance after foundation approval

Focused fake-cloud and static tests do not claim real Azure usability.
After the exact foundation is accepted and this stack is explicitly approved, the first live acceptance must record all of these results:

1. Record Mac wall time, CPU, memory, swap, process count, and interactive latency before admission.
2. Queue more work than the configured processor/concurrency limit and prove saturation remains queued with no oversubscription.
3. Admit multiple no-mistakes runs concurrently and prove bounded status responses without the previous shared singleton timeout.
4. Prove every run has a different daemon home, database, temp root, cache root, VM instance, boot, worktree disk, credential lease, container, and cgroup.
5. Run all eight behavior shards on eight separate Azure VMs and prove every manifest passes the existing completeness guard without the documented single-host lock or SIGKILL failure.
6. Include positive liveness controls for every cell and shard while active.
7. Kill one exact cell VM and prove peer cells, all shard VMs, the local supervisor, and an unrelated local task remain healthy.
8. Replace the killed cell and prove exact no-mistakes run reattach from the retained database and worktree.
9. Submit wrong head, run id, request digest, worktree disk, credential disk, VM instance, boot id, and shard receipt fixtures and prove every one refuses.
10. Drive actual-cost, forecast-cost, worker-hour, active-cell, processor-reserve, regional-quota, and family-quota saturation and prove each blocks only new admission.
11. Prove no credential byte appears in snapshots, runtime bundles, input/result archives, state JSON, tags, ARM parameter files, logs, reports, shard VMs, or uncredentialed process environments.
12. Prove one cell cannot read or write a sibling container, disk, credential lease, home, or VM.
13. Prove a failed shard is attributed to its exact VM/boot/request and is never replayed locally.
14. Run a real no-mistakes pipeline through review, test, at least one pipeline-owned fix when naturally required, push, PR creation/update, CI-green return, report publication, and cleanup entirely on the Azure validation plane.
15. Prove the local supervisor remains responsive throughout the real run and has no child process for review, lint, tests, fixes, push, or CI monitoring.
16. Record before/after wall time, cell and shard queue latency, per-cell and per-shard duration, Mac and Azure CPU/memory, actual cost, estimated cost, and cleanup latency.
17. Prove every validation VM, shard VM, NIC, OS disk, worktree disk, Run Command, cell identity, role assignment, and private cell container reaches zero after safe close while the credential lease is returned exactly once.
18. Prove the Mac rollback path remains reachable.

A failed acceptance leg means Azure validation is not the default and does not authorize local fallback, weakened identity proof, shared daemon use, retained-cost deletion, or credential broadening.
The exact failed leg, retained resources, and recovery action must be reported.
