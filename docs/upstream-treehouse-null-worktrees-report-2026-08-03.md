## Summary

Running `treehouse status` against a genuinely empty pool rewrites `treehouse-state.json` from `{"worktrees":[]}` to `{"worktrees":null}`.
The state writer therefore changes a known-empty container into a value that downstream readers must treat as unknown or malformed.
This reproduces with released versions v2.0.0 and v2.1.1 on macOS arm64.

## Affected versions

- v2.0.0 reproduces the defect.
- v2.1.1 reproduces the defect.
- v2.1.1 was the latest available release when this report was prepared on 2026-08-03.

## Reproduction

The following sequence creates one leased worktree, returns it, destroys it, proves that the resulting pool is represented by an empty array, and then runs the command that rewrites it as `null`.

```bash
scratch=$(mktemp -d)
repo="$scratch/repo"
pool_root="$scratch/pools"

git init -q -b main "$repo"
git -C "$repo" config user.name treehouse-repro
git -C "$repo" config user.email treehouse-repro@example.invalid
touch "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -qm initial
printf 'root = "%s"\n' "$pool_root" > "$repo/treehouse.toml"

cd "$repo"
worktree=$(TREEHOUSE_NO_UPDATE_CHECK=1 treehouse get --lease --lease-holder null-repro)
TREEHOUSE_NO_UPDATE_CHECK=1 treehouse return --force "$worktree"
TREEHOUSE_NO_UPDATE_CHECK=1 treehouse destroy "$worktree" --yes

state=$(find "$pool_root" -name treehouse-state.json -type f -print -quit)
python3 - "$state" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    print(repr(json.load(stream)["worktrees"]))
PY

TREEHOUSE_NO_UPDATE_CHECK=1 treehouse status

python3 - "$state" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    print(repr(json.load(stream)["worktrees"]))
PY
```

The first Python check prints the known-empty value.

```text
[]
```

`treehouse status` then reports that the pool is empty.

```text
🌳 No worktrees in pool.
```

The second Python check prints the rewritten value.

```text
None
```

The serialized file changes as follows.

```diff
 {
-  "worktrees": []
+  "worktrees": null
 }
```

## Root cause

The writer path is `internal/pool/pool.go` function `healState`.
It declares `var healed []WorktreeEntry`, appends surviving entries, assigns that slice to `state.Worktrees`, and returns the state.
When the input pool is empty, the loop performs no append and `healed` remains a nil slice.

`List` calls `healState` and then calls `WriteState`, so the read-only-looking `treehouse status` command persists the nil slice.
`internal/pool/state.go` function `WriteState` uses `json.MarshalIndent`, which encodes a nil Go slice as JSON `null`.

`State.Worktrees` is the only container-valued field in the persisted state schema at these releases.
No other persisted container field was found with the same serialization risk.

## Expected behavior

A completely enumerated pool with zero worktrees should serialize as an empty array.

```json
{
  "worktrees": []
}
```

A missing or explicitly null `worktrees` field should remain distinguishable from a known-empty pool.
It should produce an explicit refusal or conservative recovery path rather than being silently accepted as empty.

## Suggested regression coverage

- A known-empty state passed through `healState` and `WriteState` should persist `worktrees` as `[]`.
- A state file containing `"worktrees": null` should take the unknown or malformed-state path and should not be normalized to `[]` merely because the Go slice decoded as nil.
- The known-empty test should fail if `healState` returns to a nil accumulator.

Initializing the known-result accumulator with `make([]WorktreeEntry, 0, len(state.Worktrees))` would preserve the empty-array encoding for a complete enumeration.
Separately validating presence and JSON type while decoding would preserve the distinction between known empty and unknown input.

## Impact

Downstream safety code commonly requires `worktrees` to be an array before it can inspect leases or paths.
Such readers correctly reject `null` because treating it as empty could hide worktrees whose state was not actually known.
A routine status operation can therefore turn a safe empty pool into a state that blocks guarded consumers until an operator proves the pool empty and repairs the serialization.
