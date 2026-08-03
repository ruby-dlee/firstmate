#!/usr/bin/env node
// Read Codex's own rollout record and prove the latest runtime model/effort.
// Usage: fm-codex-runtime-profile.mjs <codex-home> <worktree> <model> <effort>
// Exit 0 = exact match, 1 = mismatch, 2 = no authoritative runtime record.

import fs from "node:fs";
import path from "node:path";

const [codexHomeArg, worktreeArg, expectedModel, expectedEffort] = process.argv.slice(2);
if (!codexHomeArg || !worktreeArg || !expectedModel || !expectedEffort) {
  console.error("error: expected <codex-home> <worktree> <model> <effort>");
  process.exit(2);
}

const codexHome = fs.realpathSync(codexHomeArg);
const worktree = fs.realpathSync(worktreeArg);
const sessions = path.join(codexHome, "sessions");
const maxFiles = Number.parseInt(process.env.FM_CODEX_PROFILE_MAX_FILES || "128", 10);
const maxBytes = Number.parseInt(process.env.FM_CODEX_PROFILE_MAX_BYTES || String(16 * 1024 * 1024), 10);

function collectRollouts(root) {
  const pending = [{ dir: root, depth: 0 }];
  const files = [];
  while (pending.length > 0) {
    const { dir, depth } = pending.pop();
    if (depth > 5) continue;
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const item = path.join(dir, entry.name);
      if (entry.isDirectory()) pending.push({ dir: item, depth: depth + 1 });
      else if (entry.isFile() && /^rollout-.*\.jsonl$/.test(entry.name)) {
        const stat = fs.statSync(item);
        files.push({ item, mtimeMs: stat.mtimeMs, size: stat.size });
      }
    }
  }
  return files.sort((a, b) => b.mtimeMs - a.mtimeMs).slice(0, maxFiles);
}

function readTail(file) {
  const length = Math.min(file.size, maxBytes);
  const offset = file.size - length;
  const fd = fs.openSync(file.item, "r");
  try {
    const buffer = Buffer.alloc(length);
    fs.readSync(fd, buffer, 0, length, offset);
    let text = buffer.toString("utf8");
    if (offset > 0) text = text.slice(text.indexOf("\n") + 1);
    return text;
  } finally {
    fs.closeSync(fd);
  }
}

let latest = null;
try {
  for (const file of collectRollouts(sessions)) {
    for (const line of readTail(file).split("\n")) {
      if (!line) continue;
      let record;
      try { record = JSON.parse(line); } catch { continue; }
      let settings = null;
      if (record.type === "turn_context" && record.payload?.cwd === worktree) {
        settings = {
          model: record.payload.model,
          effort: record.payload.reasoning_effort
            || record.payload.collaboration_mode?.settings?.reasoning_effort,
        };
      } else if (record.type === "event_msg"
        && record.payload?.type === "thread_settings_applied"
        && record.payload.thread_settings?.cwd === worktree) {
        settings = {
          model: record.payload.thread_settings.model,
          effort: record.payload.thread_settings.reasoning_effort,
        };
      }
      if (!settings?.model || !settings?.effort) continue;
      const timestamp = Date.parse(record.timestamp || "");
      if (!Number.isFinite(timestamp)) continue;
      if (!latest || timestamp > latest.timestamp) {
        latest = { ...settings, timestamp, source: file.item };
      }
    }
  }
} catch (error) {
  console.error(`unknown: Codex runtime profile could not be read (${error.message})`);
  process.exit(2);
}

if (!latest) {
  console.error(`unknown: no authoritative Codex runtime profile for worktree ${worktree}`);
  process.exit(2);
}

const observed = `model=${latest.model} effort=${latest.effort}`;
if (latest.model !== expectedModel || latest.effort !== expectedEffort) {
  console.error(`mismatch: Codex runtime ${observed}; expected model=${expectedModel} effort=${expectedEffort}`);
  process.exit(1);
}
console.log(`verified: Codex runtime ${observed}`);

