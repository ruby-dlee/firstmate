# Agent Fleet contributor rules

- Agent Fleet is machine-global and provider-neutral. Firstmate is a client, not a dependency.
- Work only from a feature-branch worktree. Never edit, commit, or push `main` directly.
- Never read, print, copy, back up, or commit provider credential values.
- Profile ids are stable opaque local labels; never use account emails as ids.
- Missing profiles, session mappings, leases, or auth must fail closed in enforce/resume paths.
- Selection and lease acquisition are one atomic operation using a macOS-portable lock.
- JSON is the shell integration contract. TOON is the default agent-facing structured output.
- Tests must use temporary homes and fake provider/quota binaries. They must not touch real provider homes.

Run before commit:

```sh
uv run pytest
uv run python -m compileall -q src
```
