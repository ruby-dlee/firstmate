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
agent-fleet profile enroll claude-1
agent-fleet profile enroll codex-1
```

Before `init`, set `AGENT_FLEET_CLAUDE_BIN`, `AGENT_FLEET_CODEX_BIN`, or `AGENT_FLEET_QUOTA_BIN` when the executable defaults in "State" do not match the local installation.
The generated registry pins the resolved executable paths.

Register every Git project that may host a managed worker before enrollment and launch.
Registration stores the canonical worktree root, while launch authorization compares Git common directories so linked Treehouse worktrees remain eligible.
Broad, symlinked, unrelated, and unregistered working directories fail closed before a provider process or lease starts.

`profile enroll` is the login transaction: the profile must already be disabled
and every same-provider Fleet lease must be drained.
It provisions the isolated home and hooks, runs provider login, and attempts live remote verification and duplicate-identity checks.
Claude enrollment reports a separate verification step when Keychain access has not yet been granted.
The profile stays disabled after both success and failure.
Enable it only in a separate command after reviewing verification:

```sh
agent-fleet profile verify claude-1 --allow-keychain-prompt
agent-fleet profile verify codex-1
agent-fleet profile enable claude-1
agent-fleet profile enable codex-1
```

Codex enrollment uses device authorization by default and a fresh staging home,
so a cancelled or failed attempt cannot revoke the target profile's installed
credential. Complete the device page in a fresh private/Guest browser context,
close that entire context after success, and never select **Log out**. Login is
not idempotent at the provider: raw Codex login/logout can revoke a refresh
session. Agent Fleet therefore refuses enrollment while any same-provider Fleet
lease is active, verifies the staged identity, atomically promotes it, and keeps
a durable recovery journal until commit. Do not reauthenticate a Codex Desktop
account while it has live tasks.

For ChatGPT Business or Enterprise accounts that support Codex access tokens,
the browser-independent form is:

```sh
printenv CODEX_ACCESS_TOKEN | agent-fleet profile enroll codex-1 --access-token
```

The token is consumed directly by Codex from stdin; Agent Fleet never reads or
logs it. Profiles are disabled by default, and login remains the only interactive
step for browser/device authorization.

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
  --full-auto

agent-fleet resume --task fm:crew:example \
  --workspace /absolute/path/to/task-worktree -- --full-auto
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
Raw provider auth and resume subcommands are refused by `exec` so credential maintenance and sticky session recovery cannot bypass their dedicated paths.

Claude provisioning atomically preserves opaque profile state while setting completed onboarding and project trust for every canonical registered project; a linked worktree receives its matching active-root trust only immediately before execution.
Codex launches require an exact current-version profile hook set derived from the declared hook source plus Agent Fleet SessionStart, reject project hooks, disable `plugins` and `plugin_sharing`, and apply trust only to the validated active root.

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

`quota refresh` invokes `quota-axi` inside each profile environment and stores normalized routing evidence rather than provider payloads, including status and reason, timestamps, aggregate headroom, percentage windows, and an opaque provider-identity fingerprint when available.
Before every selection, old quota evidence is refreshed automatically.
`auth_required`, `rate_limited`, provider errors, duplicate identities, missing remote verification, and expired verification are hard blocks.
A cached response whose live probe says sign-in is required is also a hard block; cached percentages can never hide revoked credentials.

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
disabled. Enable each verified worker explicitly afterward; verification and
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
Initial profiles share only account-neutral workflow assets:

- Claude: `CLAUDE.md`, skills, plugins, and hook definitions.
- Codex: `AGENTS.md`, skills, plugins, rules, and hook definitions.

Auth files, sessions, histories, logs, caches, databases, and provider state are
never shared.

## State

Defaults:

- Registry: `~/.config/agent-fleet/accounts.toml`
- Profile homes: paths recorded in the registry, under `~/.local/share/agent-fleet/accounts/<provider>/` by default
- Leases, normalized quota, and session mappings:
  `~/.local/state/agent-fleet`
- Claude Code binary: `~/.local/bin/claude`
- Codex CLI binary: `~/.local/libexec/agent-fleet/runtime/codex`
- Profile-aware quota reader:
  `~/.local/libexec/agent-fleet/quota-axi/current/bin/quota-axi`

`AGENT_FLEET_CONFIG`, `AGENT_FLEET_STATE_DIR`, and `AGENT_FLEET_SHARE_DIR` redirect the registry, state, and share/profile-home defaults.
The init-time executable overrides documented under "Initial setup" set the three generated binary paths; afterward, the registry owns those values.

## Development and releases

The locked test, lint, build, versioning, tagging, and installation verification
procedure lives in [RELEASING.md](RELEASING.md).
