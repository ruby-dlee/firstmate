---
name: eks-usage
description: >-
  Agent-only operating guide for safe Amazon EKS context verification, kubeconfig setup, authentication diagnosis, and connectivity retries.
  Use before running kubectl or EKS commands, when an EKS IAM, authenticator, Unauthorized, Forbidden, TLS, i/o, or connectivity error appears, or when the active cluster or context is uncertain.
user-invocable: false
metadata:
  internal: true
---

# EKS usage

This skill owns generic EKS client access and diagnosis, not permission to change a cluster or deploy an application.
Project runbooks and deployment skills remain authoritative for the intended cluster, lane, namespace, and allowed mutations.

## During deployments

Before contacting the cluster control plane during a deploy, read the project's deployment map or runbook and confirm that direct cluster access belongs to the documented lane.
Most managed production deploys use CI, declarative synchronization, or a platform release lane and do not contact the raw cluster API.
If transient TLS, i/o, DNS, or network failures repeat after kubeconfig refresh during a deploy, treat them as a likely wrong-path signal, stop direct cluster retries, and switch to the documented deploy lane.
Reserve the bounded retry procedure below for a confirmed correct direct-access path, because a wrong deploy path is resolved by switching lanes rather than by retrying or escalating it as a connectivity blocker.

## Establish identity and context

1. Run `aws sts get-caller-identity` and confirm the expected AWS account and principal without exposing credentials.
2. Run `kubectl config current-context` and `kubectl config view --minify` to inspect the active cluster, user, and namespace or its default.
3. Before any mutating command, state the intended cluster, context, and namespace and stop if they do not match or cannot be proved.
4. Treat a context change as safety-significant, because `aws eks update-kubeconfig` sets the written file's current context to the selected cluster.
5. Bind mutations to the verified context and namespace instead of relying on ambient defaults.

## Understand `update-kubeconfig`

`aws eks update-kubeconfig --name <cluster> --region <region>` retrieves the cluster endpoint and certificate authority from the EKS control plane and creates or merges kubeconfig entries for the cluster, context, and AWS-backed user.
The AWS identity used for that metadata lookup must be allowed to describe the cluster, while any configured authentication role governs later `kubectl` token generation.
It writes the explicitly selected kubeconfig path, otherwise the first path in `KUBECONFIG`, otherwise the default kubeconfig file.
It replaces an existing entry for the same EKS cluster in that file and makes the generated context current.
The user entry invokes AWS to obtain short-lived authentication when `kubectl` runs; the file does not contain a reusable static Kubernetes bearer token.
Use dry-run when the destination or merge effect is uncertain, and consult `aws eks update-kubeconfig help` for current flags and precedence.
Refreshing kubeconfig fixes stale endpoint, certificate, or generated-entry state, but it cannot grant IAM, EKS access-entry, Kubernetes RBAC, or network access.

## Classify the exact failure

| Signal | Layer | Response |
| --- | --- | --- |
| `AccessDeniedException` from EKS describe or kubeconfig update | AWS IAM before the Kubernetes API | Confirm the AWS identity and intended role, then escalate an actual missing IAM grant instead of debugging the network. |
| `ExpiredToken`, `InvalidClientTokenId`, or missing credentials | Local AWS credential chain before the Kubernetes request | Refresh or select the intended profile or role, then re-run the identity check without printing a token. |
| A generic exec-plugin failure | Local exec invocation or a wrapped nested failure | Classify the nested error first; check for a missing AWS executable, malformed exec stanza, or unsupported exec `apiVersion`, and refresh credentials only when the nested error identifies a credential failure. |
| `Unauthorized` or a server request for credentials from `kubectl` | Kubernetes API authentication after reaching the endpoint | Confirm the generated user role and the cluster's authorized IAM principal or access entry. |
| `Forbidden` from `kubectl` | Kubernetes authorization after successful authentication | Check the verb, resource, and namespace with `kubectl auth can-i`, then escalate the RBAC change if it is outside authority. |
| `dial tcp`, `i/o timeout`, `TLS handshake timeout`, `no route`, or `connection refused` | DNS, route, proxy, firewall, or API-endpoint reachability | Follow the bounded connectivity retry path below rather than requesting IAM. |
| `x509` or certificate validation failure | Kubeconfig CA, clock, or TLS-intercepting proxy | Refresh kubeconfig and inspect clock and proxy state, but never disable certificate verification as a workaround. |

Messages such as `couldn't get current server API group list` are wrappers, so classify the nested final error rather than the wrapper.
A successful `aws eks describe-cluster` proves AWS control-plane authorization and cluster metadata access, not Kubernetes endpoint reachability or workload authorization.
A certificate-verified HTTPS response from the cluster endpoint, including HTTP 401, proves DNS, routing, and TLS reached the API server, but it does not prove `kubectl` authentication.

## Troubleshoot in cheapest-first order

1. Capture the exact command and full error, then verify AWS identity, region, `KUBECONFIG`, current context, cluster, and namespace.
2. For an isolated TLS or transport timeout, retry the same non-mutating probe once after a short pause; a single transient timeout is never a blocker.
3. Confirm the intended target, refresh kubeconfig, recheck the now-current context, and retry a harmless version or namespace read once more after a short bounded backoff.
4. Use EKS describe to confirm that the cluster is active and inspect its endpoint-access mode without changing it.
5. If transport still fails, test DNS and HTTPS reachability to the configured endpoint and inspect VPN, proxy, firewall, private-endpoint routing, and allowed-source requirements.
6. If the endpoint is reachable, return to the IAM, token, access-entry, and RBAC classification instead of continuing network changes.
7. Use `aws eks`, `aws sts`, `aws eks get-token`, `kubectl config`, `kubectl auth`, and `kubectl get --help` for current flags rather than copying stale invocations from old incidents.

## Retry and escalation line

Continue when any bounded retry succeeds, and record the transient only when it affects operational evidence or repeats.
Apply the three-probe budget only to transient connectivity failures such as TLS handshake timeout, i/o timeout, or transient DNS or network errors; escalate when identity and context checks, kubeconfig refresh, and three total non-mutating attempts still fail.
Correct an expired or misselected local credential or role first, because those caller-controlled authentication failures do not require escalation.
Escalate immediately when the intended target cannot be proved or classification confirms an owner-controlled AWS IAM, Kubernetes authentication, EKS access-entry, RBAC, or certificate failure, without spending the connectivity retry budget.
Also escalate persistent evidence of a non-active control plane, private-route or allowlist boundary, or owner-controlled proxy fault.
Include the redacted exact commands and errors, timestamps and attempt count, current context and namespace, AWS identity and region, cluster status and endpoint-access mode, and DNS or HTTPS observations.
Never self-grant IAM or RBAC, edit access entries, expose a private endpoint, widen endpoint CIDRs or security groups, disable TLS verification, or mutate an uncertain context merely to get past an access failure.
