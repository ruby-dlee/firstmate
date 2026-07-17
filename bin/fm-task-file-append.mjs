#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import transactionModule from "./fm-file-transaction.cjs";

const fmRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

// Gate refusal replicated from bin/fm-gate-refuse-lib.sh (same signals, same
// messages, same exit code), because a Node entrypoint cannot source the shell
// library. fm-report-stack.mjs carries the same replica - keep them in lockstep.
function gitCommonDirectory(checkout) {
  try {
    const raw = execFileSync("git", ["-C", checkout, "rev-parse", "--git-common-dir"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    if (!raw) return "";
    return fs.realpathSync(path.isAbsolute(raw) ? raw : path.resolve(checkout, raw));
  } catch {
    return "";
  }
}

function refuseIfGateAgent() {
  if (process.env.FM_GATE_REFUSE_BYPASS === "1") return;
  if (Object.prototype.hasOwnProperty.call(process.env, "NO_MISTAKES_GATE")) {
    console.error("error: no-mistakes gate agent must not drive the fleet (NO_MISTAKES_GATE set)");
    process.exit(3);
  }
  for (const checkout of [process.cwd(), fmRoot]) {
    const common = gitCommonDirectory(checkout);
    if (/(?:^|[\\/])\.no-mistakes[\\/]repos[\\/][^\\/]+\.git$/.test(common)) {
      console.error(`error: refusing fleet lifecycle from inside a no-mistakes gate worktree (${common})`);
      process.exit(3);
    }
  }
}

// Fail closed before any filesystem access: durable data/<task> trails feed
// continuation packets, so a no-mistakes gate agent must never append to them
// (see bin/fm-gate-refuse-lib.sh).
refuseIfGateAgent();

const [dataDir, taskId, fileName, header = ""] = process.argv.slice(2);
if (!dataDir || !taskId || !fileName) {
  console.error("usage: fm-task-file-append.mjs <data-dir> <task-id> <file-name> [header]");
  process.exit(2);
}

try {
  const addition = fs.readFileSync(0);
  transactionModule.pinnedTaskFileTransaction(dataDir, taskId, fileName, (content, { existed }) => {
    const prefix = !existed && header ? Buffer.from(`${header}\n\n`) : Buffer.alloc(0);
    return Buffer.concat([content, prefix, addition]);
  });
} catch (error) {
  console.error(`error: task file transaction failed for ${taskId}/${fileName}: ${error.message}`);
  process.exit(1);
}
