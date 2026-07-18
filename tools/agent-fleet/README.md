# Agent Fleet

Agent Fleet is a machine-global account routing layer for local Claude Code and Codex CLI agents.
It gives an orchestrator a dynamic pool of named account profiles without making the orchestrator or session backend responsible for credentials.

The profile registry contains policy and opaque labels only. Provider logins
remain in private per-profile homes owned by the provider CLI.

## Source and installation

Agent Fleet ships as a provider-neutral component of the public Firstmate
repository under `tools/agent-fleet`.
Its original standalone history and import boundary are recorded in
[PROVENANCE.md](PROVENANCE.md).

Installing and developing the package requires `uv` and Python 3.11 or newer.
Managed routing also requires configured Claude Code or Codex CLI binaries and a profile-aware `quota-axi` executable.
Default TOON output requires the `toon` executable on `PATH`; pass `--format json` when TOON output is not needed.

Install a tagged release directly from the public repository:

```sh
uv tool install --force \
  "agent-fleet @ git+https://github.com/ruby-dlee/firstmate.git@agent-fleet-v0.2.0#subdirectory=tools/agent-fleet"
agent-fleet --format json version
```

For development from a Firstmate checkout, install the local package instead:

```sh
uv tool install --force ./tools/agent-fleet
```

Reinstalling is idempotent and updates the existing `agent-fleet` tool
environment in place.
It does not modify provider profile homes or Fleet state.

## Boundaries

The launch stack is deliberately split:

1. Firstmate (or another client) chooses the task, provider, and account pool.
2. Agent Fleet atomically selects and leases one concrete profile.
3. The session backend hosts the process.
4. Claude Code or Codex CLI reads credentials from that profile's isolated home.

Herdr native restore must remain disabled for multi-account panes. A bare
`codex resume` or `claude --resume` does not contain enough information to
recover the account home. Agent Fleet records task-to-profile and
task-to-provider-session mappings and resumes through the original profile.

## Initial setup

```sh
agent-fleet init --claude 1 --codex 1
agent-fleet project register --provider claude /absolute/path/to/project
agent-fleet project register --provider codex /absolute/path/to/project
agent-fleet profile provision --all
agent-fleet profile identity adopt claude-1 --allow-keychain-prompt
agent-fleet profile identity adopt codex-1
```

Before `init`, set `AGENT_FLEET_CLAUDE_BIN`, `AGENT_FLEET_CODEX_BIN`, or `AGENT_FLEET_QUOTA_BIN` when the executable defaults in "State" do not match the local installation.
The generated registry pins the resolved executable paths.

Register every Git project that may host a managed worker before enrollment and launch.
Registration stores the canonical worktree root, while launch authorization compares Git common directories so linked Treehouse worktrees remain eligible.
Broad, symlinked, unrelated, and unregistered working directories fail closed before a provider process or lease starts.

The sealed cutover release never starts provider login or a browser. Credentials
must already exist in each isolated worker home. `profile identity adopt` is a
browser-free, provider-batch operation: every same-provider worker must be
disabled, drained, provisioned, freshly source-attested, remotely verified, and
identity-distinct before one atomic provider bundle is written. Enable remains
a separate phase:

```sh
agent-fleet profile verify claude-1 --allow-keychain-prompt
agent-fleet profile verify codex-1
agent-fleet profile enable claude-1
agent-fleet profile enable codex-1
```

`profile enroll` and its `profile login` alias have a deliberately narrow
three-state contract:

- An already pinned credential with the exact same live identity and source is
  a verified no-op; no provider login is invoked.
- A fresh existing credential that is not yet durably pinned directs the
  operator to the provider-batch `profile identity adopt` command.
- Missing, remotely unverifiable, or identity-replacing credentials are refused
  before any provider/browser login. They require future transactional
  maintenance tooling.

Do not run raw provider login/logout, relogin the Desktop apps, or treat login as
idempotent. Those actions can rotate or revoke sessions shared by other
processes. The versioned follow-up for safe generational enrollment is tracked
in [FOLLOWUPS.md](FOLLOWUPS.md).

Add or remove profiles at any time; the registry has no fixed account count:

```sh
agent-fleet profile add claude-4 --provider claude
agent-fleet profile add codex-3 --provider codex --max-concurrent 3
agent-fleet profile disable codex-3
agent-fleet profile remove codex-3
```

Profile ids are operational labels such as `claude-1`; emails are rejected.
Registry mutations share the provider maintenance lock with enrollment and
selection, so a concurrent `profile add`, verify, login, quota refresh, or worker
start either completes under the lock or fails closed.

Worker profiles must use an identity distinct from the provider's base CLI and
Desktop identities. Use `manual_only` or `desktop_shared` for a human reserve;
those policies cannot join a crew pool or be enabled for worker routing. Claude
worker launches also set `DISABLE_LOGIN_COMMAND=1` and
`DISABLE_LOGOUT_COMMAND=1`, preventing an in-flight session from replacing its
managed login. Agent Fleet re-reads Claude Desktop's identity immediately before
each selection rather than trusting a TTL cache.

## Routing contract

Shell integrations should request compact JSON explicitly:

```sh
agent-fleet --format json lease choose \
  --task fm:crew:example --pool codex-crew --provider codex \
  --workspace /absolute/path/to/task-worktree

agent-fleet exec \
  --task fm:crew:example --pool codex-crew --provider codex \
  --workspace /absolute/path/to/task-worktree -- \
  --dangerously-bypass-approvals-and-sandbox "$(cat brief.md)"

agent-fleet resume --task fm:crew:example \
  --workspace /absolute/path/to/task-worktree -- \
  --dangerously-bypass-approvals-and-sandbox
agent-fleet --format json session status --task fm:crew:example
agent-fleet --format json lease recover --task fm:crew:example \
  --workspace /absolute/path/to/task-worktree
agent-fleet --format json lease release --task fm:crew:example
agent-fleet --format json session remove --task fm:crew:example
```

`exec` binds the lease to its own PID and then replaces itself with the provider
CLI, preserving a verifiable owner identity. A standalone `lease choose`
creates a short reservation that must be followed by `exec`; expired or dead
owners are reclaimed under the same portable directory lock used for
selection. A reservation may be released normally when pane creation fails,
while a live worker lease requires an explicit forced release after the worker
has stopped. Worker `exec` and `resume` require a managed task id, and every live
lease and lock requires a verified process-start token; missing tokens fail
closed. Selection, execution, and recovery require the intended task worktree
explicitly and never infer the orchestrator's working directory. A live task
can never be rebound to a different process.
Provider arguments use a strict operation-aware positive grammar matching FirstMate's Claude and Codex launch templates.
`exec` requires the provider autonomy flag, accepts only FirstMate's optional model, effort, and Codex turn-end notification fields, and requires exactly one prompt.
Agent Fleet reconstructs the provider argv from the parsed fields and inserts a provider-level `--` before that prompt, so prompt text that resembles a command remains prompt text.
`resume` accepts the same safe option family but no caller prompt, session id, alternate command, attached flag form, or arbitrary provider config.

Claude provisioning writes a closed `settings.json` and a closed `.claude.json` containing only onboarding plus registered-project trust state; it strips opaque oauth, refresh, MCP, plugin, and unrelated project keys rather than preserving unknown state.
Credential identity remains solely in the source-attested `.credentials.json` or exact path-scoped Keychain service, never in `.claude.json`.
Static fixtures prove this closed rewrite and idempotence. The first real Claude canary is still a mandatory rollback boundary: an auth/onboarding prompt or any mutation of the closed state aborts activation, disables routing, and must not be "fixed" by widening the schema ad hoc.
Readiness derives the command and source hash independently, so stale, duplicate, spoofed, co-tampered, unsafe, or source-drifted hook files fail closed.
Provisioning also sets completed onboarding and project trust for every canonical registered project; a linked worktree receives its matching active-root trust only immediately before execution.
Codex launches require an exact current-version profile hook set derived from the declared hook source plus Agent Fleet SessionStart, disable `plugins` and `plugin_sharing`, and apply trust only to the validated active root.
Every provisioned profile requires a directly configured non-symlink provider executable and records its opened regular-file identity, size, mode, modification time, and SHA-256 digest.
Selection, doctor, and the final managed/login/resume argv build recompute that authoritative opened-object identity and refuse path replacement or in-place binary drift until locked reprovisioning updates the marker.
Provider-reported version text is diagnostic only and is deliberately not an integrity authority.
The only pre-provision provider execution is the declared base-home identity anchor probe, which reopens and verifies the exact configured non-symlink regular executable immediately before Quota AXI or auth uses it.
Managed launches refuse active-root provider control files, including Claude project settings, Codex project config or hooks, and `.mcp.json`, while continuing to allow instruction files such as `CLAUDE.md` and `AGENTS.md`.

Task resume is fail-closed: it requires the recorded provider session and
reuses that session's exact profile. The new-task quota reserve does not block
recovery of an existing conversation, but disabled, unprovisioned, cooled-down,
or capacity-exhausted profiles still do.

Orchestrators that create a terminal endpoint before launching its command use
`lease recover` for an atomic, below-reserve-safe recovery reservation, then
launch `resume --task` inside the endpoint. Recovery refuses when the task still
has a live worker lease.

TOON is the default structured output for agent-facing inspection. Use
`--format json` for shell parsing and `--format human` for a simple terminal
view.

## Selection policy

`quota refresh` invokes `quota-axi` inside each profile environment and stores
only normalized status, an opaque provider-identity fingerprint when available,
and percentage windows. Every real selection obtains a same-attempt
source-before/quota/source-after proof for every enabled worker of each scoped
provider, including workers outside the requested pool. Cached quota is never
identity authority. `auth_required`, `rate_limited`, provider errors, duplicate
identities, missing remote verification, and expired verification are hard
blocks. A cached response whose live probe says sign-in is required is also a
hard block; cached percentages can never hide revoked credentials.

When fresh quota exists, Agent Fleet selects the highest safe headroom after
reserve and active-lease penalties. A transient stale/unavailable response may
use weighted least-active/LRU fallback only when that exact profile has a recent
successful remote verification (24 hours by default). A fresh profile at or
below its reserve is never selected for new work.

```sh
agent-fleet quota refresh --all
agent-fleet quota show --all
agent-fleet profile verify --all --allow-keychain-prompt
agent-fleet doctor
agent-fleet doctor --workspace ~/firstmate --project /absolute/path/to/task-worktree
```

`profile verify --all` remotely rechecks every profile while all profiles remain
disabled. Enable each verified worker explicitly afterward; each enable again
requires fresh same-attempt proof for the target and every already-enabled
same-provider worker before its single registry mutation. Verification and
routing activation are deliberately separate phases. On macOS,
`--allow-keychain-prompt` is the explicit one-time Claude Keychain grant; choose
**Always Allow** so later automatic checks stay non-interactive. Bare `enable`
never requests Keychain access and fails closed when verification is unavailable.

`doctor` checks private profile homes, cached fresh remote identity proof for enabled workers, Agent Fleet and inherited workflow hooks/assets, provider auth state, trusted-project configuration, and configured binaries.
It does not refresh quota evidence or change provider or project configuration.
Disabled and non-worker reserve profiles report remote-proof state without making it a health requirement.
`--workspace` checks for Firstmate's required Claude and Codex supervision-hook events, while `--project` independently checks provider onboarding, registered-project, profile-hook, plugin, and project-hook readiness.

## Isolation and shared workflow assets

Claude profiles set `CLAUDE_CONFIG_DIR`; Codex profiles set `CODEX_HOME` and `CODEX_SQLITE_HOME` and force file-backed credentials inside that home.
Homes and state are mode 0700; registry, lease, quota, and session files are mode 0600.
Before every provider subprocess, Agent Fleet scrubs ambient `ANTHROPIC_*`, `CLAUDE_*`, `OPENAI_*`, and `CODEX_*` variables, then sets the managed profile-home and task/workspace variables it owns.

The provider registry can declare a base home, hook source, trusted Git projects, and allowlisted shared entries.
Initial profiles may share only explicitly allowlisted account-neutral workflow
assets. Managed plugin directories are forbidden:

- Claude: declared instruction/skill assets and closed hook definitions.
- Codex: declared instruction/skill/rule assets and closed hook definitions.

Auth files, sessions, histories, logs, caches, databases, and provider state are
never shared.

## State

Defaults:

- Registry: `~/.config/agent-fleet/accounts.toml`
- Profile homes: paths recorded in the registry, under `~/.local/share/agent-fleet/accounts/<provider>/` by default
- Leases, normalized quota, and session mappings:
  `~/.local/state/agent-fleet`
- Neutral provider runtimes: `~/.local/libexec/agent-fleet/runtime`
- Hash-pinned profile-aware quota reader: the exact regular `node_modules/quota-axi/dist/bin/quota-axi.js` file inside one immutable release.
- Hash-pinned Quota interpreter: an exact regular standalone Node executable stored inside that same immutable release and invoked directly before the verified JavaScript path.

The current release layout stores those files at `~/.local/libexec/agent-fleet/quota-axi/releases/0.1.6-da603d0d/node_modules/quota-axi/dist/bin/quota-axi.js` and `~/.local/libexec/agent-fleet/quota-axi/releases/0.1.6-da603d0d/runtime/node`.

`agent-fleet init` may resolve a caller-supplied convenience symlink once, but the generated registry stores only the two resolved non-symlink release paths and their SHA-256 digests.

Legacy registries without the hashes migrate only when their configured Quota path is already an exact regular file and the exact Node runtime is available at the release path or through `AGENT_FLEET_QUOTA_NODE_BIN`.

Moving `current`, npm `.bin`, and shebang/PATH execution are rejected.

Runtime drift blocks selection and quota refresh, and Doctor reports the failed pin; inventory and worker-disable operations remain available so an operator can fail safe without executing Quota.
Registry loading, doctor, and every quota probe refuse a moved symlink, replaced release, or digest drift.

`AGENT_FLEET_CONFIG`, `AGENT_FLEET_STATE_DIR`, and `AGENT_FLEET_SHARE_DIR` redirect the registry, state, and share/profile-home defaults.
The init-time executable overrides documented under "Initial setup" set the three generated binary paths; afterward, the registry owns those values.

## Development and releases

The locked test, lint, build, versioning, tagging, and installation verification
procedure lives in [RELEASING.md](RELEASING.md).
