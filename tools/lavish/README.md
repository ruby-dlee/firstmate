# Lavish

Lavish is firstmate's durable decision inbox.
It stores complete requests and answers under `$FM_HOME/data/decisions/` and uses short-lived terminal commands only.

The core file protocol has no server, URL, listener, long poll, idle timeout, or resident process.
The optional Firstmate board wrapper opens a bounded dedicated Chrome profile and arms one ordinary watcher check; the durable request and answer files remain authoritative.
An unanswered request remains answerable until the files are deliberately removed.

## Human commands

The captain-facing command contract is owned by the [`lavish-decisions` skill](../../.agents/skills/lavish-decisions/SKILL.md).
`lavish-axi create` follows that contract by printing an answer command with the resolved absolute home path.
For direct human use, pass the same explicit home to every command, replacing this example path with the fleet home's resolved absolute path:

```sh
lavish inbox --home '/Users/example/firstmate-home'
lavish show <decision-id> --home '/Users/example/firstmate-home'
lavish answer <decision-id> --home '/Users/example/firstmate-home'
bin/fm-lavish-board.sh <decision-id> --home '/Users/example/firstmate-home'
```

`lavish answer` renders the complete request, collects one numbered choice for every ordered question, accepts an optional note, shows the whole batch, and requires one explicit confirmation.
It validates everything before atomically renaming a same-directory temporary file to `answer.toon`.
It then queues a redundant wake pointer and exits without waiting for firstmate.

If wake enqueueing fails, the durable answer remains authoritative.
The command prints `answer saved; wake not queued`, exits nonzero, and the next ordinary intake scan recovers it.

`bin/fm-lavish-board.sh` renders the same immutable request into self-contained HTML and opens it with a decision-specific Chrome profile below the effective state root (`FM_STATE_OVERRIDE` or `$FM_HOME/state`).
Submit first writes and reads back a browser-profile record, then shows a confirmation describing that durable record; the optional browser download is not treated as confirmed delivery.
The armed check recovers the record from the same profile even after the visible browser closes, validates it through `lavish-axi collect`, and runs intake.

## Agent commands

Create a complete Markdown request and a JSON question definition:

```json
[
  {
    "key": "deployment",
    "prompt": "Which deployment policy should we adopt?",
    "options": [
      {"value": "a", "label": "Adopt policy A"},
      {"value": "b", "label": "Adopt policy B"}
    ]
  }
]
```

Then create the durable decision:

```sh
lavish-axi create \
  --id deployment-policy \
  --title "Deployment policy" \
  --request /path/to/request.md \
  --questions /path/to/questions.json \
  --destination data/deployment-policy/captain-answer.toon
```

`request.md` must contain the complete context, recommendation, alternatives, consequences, and next actions.
`create` computes its digest, validates the ordered question set, and writes the request plus `manifest.toon`.

At firstmate's existing wake and session-start boundaries:

```sh
lavish-axi intake
```

Intake validates every unreceipted answer, writes the declared destination first, then writes `receipt.toon`.
An existing matching destination or receipt is an idempotent success.
A conflicting destination fails closed.
New manifests declare `destination_format`; `.json` destinations receive the schema-version-2 browser payload, while other destinations receive the authoritative TOON answer.
Protocol-1 manifests without `destination_format` retain the original byte-for-byte TOON copy behavior regardless of filename.

All commands require either `FM_HOME` or an explicit `--home <path>` and never guess a fleet home.
Firstmate's internal commands use `FM_HOME`; captain-facing commands carry the resolved absolute `--home` path.
Tests and recovery tools may also pass `--home <path>` explicitly.
The firstmate bootstrap install command also records the checkout's narrow wake adapter with `lavish-axi configure-wake`; this local pointer is not inherited into other homes.

## Protocol

Manifest and receipt schema version `1` remain current; answers may be schema version `1` or annotation-capable schema version `2`.
TOON's strict decoder validates every encoded array count before Lavish applies the schema rules below.

`manifest.toon` contains:

- `kind: lavish-decision-manifest`
- `schema_version`, stable `decision_id`, `title`, and `created_at`
- an `$FM_HOME`-relative durable `destination`
- optional `destination_format` (`answer-toon` or `payload-json-v2`); absence retains protocol-1 TOON copy semantics
- `expected_count` and the ordered `questions` array
- each question's nonempty unique key and ordered nonempty options
- `request_sha256`, formatted as `sha256:<hex>`
- optional `legacy_source` provenance for migration-created records

`answer.toon` contains:

- `kind: lavish-decision-answer`
- `schema_version`, `decision_id`, `request_sha256`, and `submitted_at`
- exactly one ordered answer for every expected question key
- each selected option value and label
- schema version `2` also carries string question notes, per-option string comments, and an overall string note

`receipt.toon` contains:

- `kind: lavish-decision-receipt`
- `schema_version`, `decision_id`, `answer_sha256`, and `consumed_at`
- the declared destination and its content digest

The initial `answer.toon` is write-once.
Later answer revisions require a future numbered-revision protocol and are not part of either accepted answer schema.

## Legacy migration

Migration is explicit and source-preserving:

```sh
lavish-axi migrate-legacy \
  --state ~/.lavish-axi/state.json \
  --snapshot-dir /durable/audit/location \
  --pending-map /path/to/reconciled-pending-decisions.json
```

The command first snapshots the complete source state and never edits or deletes it.
It imports every queued legacy prompt into a durable answered decision record.
It creates unanswered replacements only for entries explicitly named by the reconciled pending map.
It never treats an upstream session's `open` status as a work queue.

The pending map is a JSON array whose entries contain `session_key`, `decision_id`, `title`, `destination`, `request_md`, and `questions` in the same shape accepted by `create`.
