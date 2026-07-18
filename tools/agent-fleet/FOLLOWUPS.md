# Agent Fleet versioned follow-ups

## AF-ENROLLMENT-V1 — generational credential maintenance

Status: open, nonblocking for the sealed Bridge cutover release.

The current release intentionally refuses missing credentials and any change to
an already pinned remote identity before invoking provider login or a browser.
A future release may restore enrollment only as a provider-wide generational
transaction with all of these properties:

- stage a new credential generation without mutating the live worker home;
- verify the exact credential source and remote identity before promotion;
- treat Claude's path-scoped Keychain service as transaction-owned state, with
  an exact preimage or an independently reversible generation;
- atomically publish one provider identity bundle only after every worker proof
  and external base/Desktop conflict check passes;
- keep the old generation and rollback journal until post-promotion canaries
  complete; and
- crash-recover to exactly one complete generation without exposing secret
  bytes in logs, snapshots, or registry state.

Until that contract is implemented and reviewed, operators must not use raw
provider login/logout as an Agent Fleet maintenance substitute.
