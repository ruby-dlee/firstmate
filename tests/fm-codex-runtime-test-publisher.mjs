#!/usr/bin/env node
// Publish one synthetic Codex rollout for fake-endpoint spawn fixtures.
// fm-spawn.sh reaches this only through its exact, temp-root-confined test token.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const [runtimeHome, worktree, model, effort, generation, runtimeStartArg] = process.argv.slice(2);
if (!runtimeHome || !worktree || !model || !effort || !generation
  || !/^\d+$/.test(runtimeStartArg || "")) {
  console.error("error: invalid synthetic Codex runtime record request");
  process.exit(1);
}

const runtimeStartNs = BigInt(runtimeStartArg);
const eventNs = runtimeStartNs + 1n;
const seconds = eventNs / 1000000000n;
const fraction = String(eventNs % 1000000000n).padStart(9, "0");
const timestamp = `${new Date(Number(seconds) * 1000).toISOString().slice(0, 19)}.${fraction}Z`;
const token = crypto.createHash("sha256")
  .update(`${generation}\0${runtimeStartArg}`)
  .digest("hex")
  .slice(0, 24);
const session = `test-${token}`;
const sessionDir = path.join(runtimeHome, "sessions", "test-lab");
const rollout = path.join(sessionDir, `rollout-${token}.jsonl`);
fs.mkdirSync(sessionDir, { recursive: true });
fs.writeFileSync(rollout, [
  JSON.stringify({ timestamp, type: "session_meta", payload: { id: session } }),
  JSON.stringify({
    timestamp,
    type: "turn_context",
    payload: { cwd: fs.realpathSync(worktree), model, reasoning_effort: effort },
  }),
  "",
].join("\n"), { flag: "wx" });
