#!/usr/bin/env node
// Publish and browse durable Firstmate completion reports.
//
// The report stack is machine-global and independent of FM_HOME and provider
// account homes. New tasks record report_required=1; teardown first quiesces the
// endpoint, then publishes before account release or worktree removal.
// Publication is idempotent by canonical Firstmate home + task id, serialized,
// staged, and swapped into place only after every artifact is ready.
//
// Usage: fm-report-stack.mjs publish <task-id> [--legacy]
//        fm-report-stack.mjs render
//        fm-report-stack.mjs list [--json]
//        fm-report-stack.mjs path [<task-id>]
//        fm-report-stack.mjs open [<task-id>]
//
// FM_REPORT_STACK_ROOT overrides the default. When XDG_DATA_HOME is set, the
// default is $XDG_DATA_HOME/firstmate/report-stack; otherwise it is
// ~/.local/share/firstmate/report-stack. FM_HOME, FM_STATE_OVERRIDE, and
// FM_DATA_OVERRIDE select the task source like the rest of Firstmate.

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import markdownModule from "./fm-markdown-structure.cjs";

const command = process.argv[2] || "list";
const args = process.argv.slice(3);
const fmRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const fmHome = path.resolve(process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || fmRoot);
const stateDir = path.resolve(process.env.FM_STATE_OVERRIDE || path.join(fmHome, "state"));
const dataDir = path.resolve(process.env.FM_DATA_OVERRIDE || path.join(fmHome, "data"));
const stackRoot = path.resolve(process.env.FM_REPORT_STACK_ROOT || path.join(process.env.XDG_DATA_HOME || path.join(os.homedir(), ".local", "share"), "firstmate", "report-stack"));
const entriesDir = path.join(stackRoot, "entries");
const requiredSections = ["Summary", "What changed", "Verification", "Visual evidence", "Artifacts", "Follow-ups"];
const informationalTrailLimit = 4 * 1024 * 1024;
const completionReportLimit = 16 * 1024 * 1024;
const metadataLimit = 1024 * 1024;
const manifestLimit = 1024 * 1024;
const transactionLimit = 64 * 1024;
const lockControlLimit = 4 * 1024;
const visualEntryLimit = 512;
const visualDepthLimit = 24;
const visualBytesLimit = 20 * 1024 * 1024;
const reportRetentionMs = 30 * 24 * 60 * 60 * 1000;
const containedReadHelper = path.join(fmRoot, "bin", "fm-contained-read.py");

function fail(message) {
  console.error(`error: ${message}`);
  process.exit(1);
}

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

function parseMeta(content) {
  const result = {};
  for (const line of content.split(/\r?\n/)) {
    const index = line.indexOf("=");
    if (index > 0) result[line.slice(0, index)] = line.slice(index + 1);
  }
  return result;
}

function stableReportId(taskId) {
  const scope = fs.realpathSync(fmHome);
  const digest = crypto.createHash("sha256").update(`${scope}\0${taskId}`).digest("hex").slice(0, 12);
  return `${taskId}-${digest}`;
}

function titleFromBrief(taskId, brief) {
  const match = brief.match(/^# Task\s*\n+([\s\S]*?)(?=\n# |\n\*\*|$)/m);
  const candidate = match?.[1]?.trim().replace(/\s+/g, " ");
  return candidate && candidate !== "{TASK}" ? candidate.slice(0, 160) : taskId;
}

function lastStatus(status) {
  const lines = status.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  return lines[lines.length - 1] || "Completed task";
}

const { markdownStructure } = markdownModule;

function firstSummary(markdown, fallback) {
  const structure = markdownStructure(markdown);
  const summaryStart = structure.findIndex(({ heading }) => heading?.level === 2 && heading.content.toLowerCase() === "summary");
  let summaryLines;
  if (summaryStart >= 0) {
    const followingHeading = structure.findIndex(({ heading }, index) => index > summaryStart && heading?.level === 2);
    summaryLines = structure.slice(summaryStart + 1, followingHeading < 0 ? undefined : followingHeading).map(({ line }) => line);
  } else {
    summaryLines = structure.map(({ line }) => line);
  }
  const text = summaryLines.join("\n")
    .replace(/^#{1,6}\s+/gm, "")
    .replace(/!\[[^\]]*\]\([^)]*\)/g, "")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/[*_`>#-]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  return (text || fallback).slice(0, 320);
}

function levelTwoHeadings(markdown) {
  const headings = new Set();
  for (const { heading } of markdownStructure(markdown)) {
    if (heading?.level === 2) headings.add(heading.content.toLowerCase());
  }
  return headings;
}

function requireCompletionSections(markdown, sourceFile, taskId) {
  const headings = levelTwoHeadings(markdown);
  const missing = requiredSections.filter((section) => !headings.has(section.toLowerCase()));
  if (missing.length === 0) return;
  const required = requiredSections.map((section) => `## ${section}`).join(", ");
  const absent = missing.map((section) => `## ${section}`).join(", ");
  throw new Error(
    `completion report at ${sourceFile} is missing required section headings: ${absent}. `
    + `Update ${sourceFile} to include these level-two headings: ${required}. `
    + `Then rerun ${fmRoot}/bin/fm-report-stack.mjs publish ${taskId} or ${fmRoot}/bin/fm-teardown.sh ${taskId}. `
    + "This attempt did not replace the durable report, and teardown remains stopped before destructive cleanup.",
  );
}

function gitValue(worktree, gitArgs) {
  if (!worktree || !fs.existsSync(worktree)) return "";
  try {
    return execFileSync("git", ["-C", worktree, ...gitArgs], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch {
    return "";
  }
}

function displaySha(value) {
  const sha = String(value || "").trim();
  return /^[0-9a-f]{7,64}$/i.test(sha) ? sha.toLowerCase().slice(0, 12) : "";
}

function processStartIdentity(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return "";
  try {
    return execFileSync("ps", ["-p", String(pid), "-o", "lstart="], {
      encoding: "utf8",
      env: { ...process.env, LC_ALL: "C" },
      stdio: ["ignore", "pipe", "ignore"],
    }).trim().replace(/\s+/g, " ");
  } catch {
    return "";
  }
}

function isContained(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative === "" || (!relative.startsWith(`..${path.sep}`) && relative !== ".." && !path.isAbsolute(relative));
}

function realDirectory(directory, root, label) {
  let stat;
  try {
    stat = fs.lstatSync(directory);
  } catch (error) {
    if (error.code === "ENOENT") throw new Error(`${label} is missing at ${directory}`);
    throw error;
  }
  if (stat.isSymbolicLink() || !stat.isDirectory()) throw new Error(`${label} must be a real directory at ${directory}`);
  const real = fs.realpathSync(directory);
  if (root && !isContained(root, real)) throw new Error(`${label} escapes its configured root at ${directory}`);
  return real;
}

function pinnedDirectory(directory, root, label) {
  const initial = fs.lstatSync(directory);
  if (initial.isSymbolicLink() || !initial.isDirectory()) throw new Error(`${label} must be a real directory at ${directory}`);
  const descriptor = fs.openSync(directory, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | (fs.constants.O_NOFOLLOW || 0));
  try {
    const opened = fs.fstatSync(descriptor);
    if (!opened.isDirectory() || opened.dev !== initial.dev || opened.ino !== initial.ino) {
      throw new Error(`${label} changed while opening ${directory}`);
    }
    const real = fs.realpathSync(directory);
    if (root && !isContained(root, real)) throw new Error(`${label} escapes its configured root at ${directory}`);
    const current = fs.lstatSync(directory);
    if (current.isSymbolicLink() || !current.isDirectory()
      || current.dev !== opened.dev || current.ino !== opened.ino) {
      throw new Error(`${label} changed while opening ${directory}`);
    }
    return { path: directory, real, dev: opened.dev, ino: opened.ino, descriptor, label };
  } catch (error) {
    fs.closeSync(descriptor);
    throw error;
  }
}

function inspectPinnedDirectory(directory) {
  const stat = fs.lstatSync(directory.path);
  const opened = fs.fstatSync(directory.descriptor);
  if (!opened.isDirectory() || opened.dev !== directory.dev || opened.ino !== directory.ino
    || stat.isSymbolicLink() || !stat.isDirectory()
    || stat.dev !== directory.dev || stat.ino !== directory.ino
    || fs.realpathSync(directory.path) !== directory.real) {
    throw new Error(`${directory.label} changed while reading ${directory.path}`);
  }
  return directory.real;
}

function framedItems(buffer) {
  const newline = buffer.indexOf(10);
  if (newline < 0) throw new Error("contained reader returned an invalid response");
  const header = JSON.parse(buffer.subarray(0, newline).toString("utf8"));
  let offset = newline + 1;
  const result = new Map();
  for (const item of header.items || []) {
    const length = Number(item.bytes || 0);
    if (!Number.isSafeInteger(length) || length < 0 || offset + length > buffer.length) {
      throw new Error("contained reader returned an incomplete response");
    }
    result.set(item.name, { ...item, content: buffer.subarray(offset, offset + length) });
    offset += length;
  }
  if (offset !== buffer.length) throw new Error("contained reader returned trailing data");
  return result;
}

function runContainedHelper(arguments_, descriptors, maxBuffer) {
  try {
    return execFileSync("python3", [containedReadHelper, ...arguments_], {
      encoding: null,
      maxBuffer,
      stdio: ["ignore", "pipe", "pipe", ...descriptors],
    });
  } catch (error) {
    const detail = error.stderr?.toString("utf8").trim().replace(/^error:\s*/, "");
    throw new Error(detail || error.message);
  }
}

function readArtifact(file, root, label, options = {}) {
  inspectPinnedDirectory(root);
  const relative = path.relative(root.path, file);
  if (!relative || relative === ".." || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error(`${label} escapes its configured root at ${file}`);
  }
  const mode = options.truncate || "strict";
  let buffer;
  try {
    buffer = runContainedHelper(
      ["read-fd", relative, String(options.maxBytes), mode],
      [root.descriptor],
      options.maxBytes + 1024 * 1024,
    );
  } catch (error) {
    if (error.message.includes(`source is a symlink: ${relative}`)) {
      throw new Error(`${label} must be a real regular file at ${file}`);
    }
    throw error;
  }
  const source = framedItems(buffer).get("source");
  if (!source || source.missing) return undefined;
  if (source.oversized && !options.truncate) {
    if (options.overflowMessage) throw new Error(options.overflowMessage(source.size));
    throw new Error(`${label} exceeds its ${options.maxBytes}-byte limit at ${file}`);
  }
  const content = source.content.toString("utf8");
  if (!source.oversized) return content;
  const kept = options.truncate === "tail" ? "last" : "first";
  const marker = `[${label} truncated: original size ${source.size} bytes; kept ${kept} ${source.bytes} bytes]`;
  return options.truncate === "tail" ? `${marker}\n${content}` : `${content}\n${marker}\n`;
}

function readDescriptorAtMost(descriptor, maxBytes, overflowMessage) {
  const buffer = Buffer.alloc(maxBytes + 1);
  let bytesRead = 0;
  while (bytesRead < buffer.length) {
    const count = fs.readSync(descriptor, buffer, bytesRead, buffer.length - bytesRead, null);
    if (count === 0) break;
    bytesRead += count;
  }
  if (bytesRead > maxBytes) {
    throw new Error(overflowMessage(bytesRead));
  }
  return buffer.subarray(0, bytesRead);
}

function readBoundedRegularFile(file, maxBytes, label) {
  const initial = fs.lstatSync(file);
  if (initial.isSymbolicLink() || !initial.isFile()) throw new Error(`${label} must be a real regular file at ${file}`);
  const flags = fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0);
  const descriptor = fs.openSync(file, flags);
  try {
    const stat = fs.fstatSync(descriptor);
    if (!stat.isFile() || stat.dev !== initial.dev || stat.ino !== initial.ino) {
      throw new Error(`${label} must be a stable real regular file at ${file}`);
    }
    if (stat.size > maxBytes) throw new Error(`${label} exceeds its ${maxBytes}-byte limit at ${file}`);
    return readDescriptorAtMost(
      descriptor,
      maxBytes,
      () => `${label} exceeds its ${maxBytes}-byte limit at ${file}`,
    ).toString("utf8");
  } finally {
    fs.closeSync(descriptor);
  }
}

function readLockControl(file, label) {
  return readBoundedRegularFile(file, lockControlLimit, label);
}

function assertSafeFileDestination(file, label) {
  try {
    const stat = fs.lstatSync(file);
    if (stat.isSymbolicLink() || !stat.isFile()) throw new Error(`${label} must be absent or a real regular file at ${file}`);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
}

function escapeHtml(value) {
  return String(value).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&#39;");
}

function redactSensitive(value) {
  return String(value)
    .replace(/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g, "[REDACTED PRIVATE KEY]")
    .replace(/\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9_]{16,})\b/g, "[REDACTED TOKEN]")
    .replace(/\b(https?:\/\/)[^\s/@:]+:[^\s/@]+@/gi, "$1[REDACTED]@")
    .replace(/((["'])(?:[A-Za-z0-9]+[_-])*(?:api[_-]?key|access[_-]?key|secret[_-]?access[_-]?key|access[_-]?token|refresh[_-]?token|bot[_-]?token|password|passwd|secret|authorization|cookie)\2\s*:\s*)(["'])(?:\\.|(?!\3).)*\3/gi, "$1$3[REDACTED]$3")
    .replace(/^(\s*(?:[A-Za-z0-9]+[_-])*(?:api[_-]?key|access[_-]?key|secret[_-]?access[_-]?key|access[_-]?token|refresh[_-]?token|bot[_-]?token|password|passwd|secret|authorization|cookie)\s*[:=]\s*).+$/gim, "$1[REDACTED]");
}

function safeHttpUrl(value) {
  if (!value) return "";
  try {
    const parsed = new URL(value);
    if (parsed.username || parsed.password) return "";
    parsed.search = "";
    parsed.hash = "";
    return parsed.protocol === "https:" || parsed.protocol === "http:" ? parsed.href : "";
  } catch {
    return "";
  }
}

function relativeUrl(value) {
  return String(value).split("/").map((segment) => encodeURIComponent(segment)).join("/");
}

function sharedCss() {
  return `:root{color-scheme:light dark;--bg:#f4f1e8;--panel:#fffdf7;--ink:#1c2623;--muted:#68736f;--accent:#17745b;--line:#d8d7ce}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.55 ui-sans-serif,system-ui,-apple-system,sans-serif}main{max-width:1080px;margin:auto;padding:48px 24px 80px}nav{margin-bottom:36px}a{color:var(--accent)}header{max-width:820px;margin-bottom:28px}.eyebrow{text-transform:uppercase;letter-spacing:.12em;font-size:.75rem;color:var(--accent);font-weight:700}h1{font:700 clamp(2rem,6vw,4.5rem)/1.02 ui-serif,Georgia,serif;margin:.2em 0}h2{font:700 1.5rem/1.2 ui-serif,Georgia,serif;margin-top:2.2rem}dl{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px}dl div,.card,pre.report,figure{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:16px}dt{font-size:.75rem;text-transform:uppercase;letter-spacing:.08em;color:var(--muted)}dd{margin:4px 0 0;overflow-wrap:anywhere}.gallery{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:16px}.gallery img{width:100%;max-height:420px;object-fit:contain;border-radius:8px}.gallery figure{margin:0}.gallery figcaption{margin-top:8px;color:var(--muted);font-size:.85rem}pre.report{white-space:pre-wrap;overflow-wrap:anywhere;font:15px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace}.muted,.meta{color:var(--muted)}.toolbar{display:flex;gap:12px;flex-wrap:wrap;margin:28px 0}.toolbar input,.toolbar select{font:inherit;padding:12px 14px;border:1px solid var(--line);border-radius:10px;background:var(--panel);color:var(--ink)}.toolbar input{flex:1;min-width:240px}.cards{display:grid;gap:14px}.card h2{margin:.2rem 0 .35rem}.card p{margin:.35rem 0}.card a{text-decoration:none;color:inherit}.empty{padding:40px;text-align:center;color:var(--muted)}@media(prefers-color-scheme:dark){:root{--bg:#14201d;--panel:#1d2b27;--ink:#f4f1e8;--muted:#a9b5b0;--accent:#74d2b3;--line:#344640}}`;
}

function reportPage(manifest, markdown, visuals) {
  const worktreeHead = manifest.worktreeHead || manifest.commit || "";
  const revisionDetails = `${manifest.prHead ? `<div><dt>PR head</dt><dd>${escapeHtml(manifest.prHead)}</dd></div>` : ""}<div><dt>Worktree HEAD</dt><dd>${escapeHtml(worktreeHead || "not recorded")}</dd></div>`;
  const gallery = visuals.length
    ? `<section><h2>Visual evidence</h2><div class="gallery">${visuals.map((visual) => {
      const label = escapeHtml(path.basename(visual));
      const href = escapeHtml(relativeUrl(visual));
      return /\.(?:gif|jpe?g|png|svg|webp)$/i.test(visual)
        ? `<figure><a href="${href}"><img src="${href}" alt="${label}"></a><figcaption>${label}</figcaption></figure>`
        : `<figure><a href="${href}">${label}</a><figcaption>Visual artifact</figcaption></figure>`;
    }).join("")}</div></section>`
    : `<section><h2>Visual evidence</h2><p class="muted">No image artifacts were attached.</p></section>`;
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHtml(manifest.title)} · Firstmate report</title><style>${sharedCss()}</style></head><body><main>
<nav><a href="../../index.html">← Report stack</a></nav>
<header><p class="eyebrow">${escapeHtml(manifest.kind)} · ${escapeHtml(manifest.mode)}</p><h1>${escapeHtml(manifest.title)}</h1><p>${escapeHtml(manifest.summary)}</p></header>
<dl><div><dt>Task</dt><dd>${escapeHtml(manifest.taskId)}</dd></div><div><dt>Completed</dt><dd>${escapeHtml(manifest.completedAt)}</dd></div><div><dt>Project</dt><dd>${escapeHtml(manifest.project)}</dd></div><div><dt>Harness</dt><dd>${escapeHtml(manifest.harness)}</dd></div><div><dt>Account profile</dt><dd>${escapeHtml(manifest.accountProfile || "unmanaged")}</dd></div>${revisionDetails}</dl>
${gallery}
<section><h2>Completion report</h2><pre class="report">${escapeHtml(markdown)}</pre></section>
<section><h2>Trail</h2><p><a href="report.md">Report source</a> · <a href="brief.md">Task brief</a> · <a href="status.log">Status trail</a>${manifest.prUrl ? ` · <a href="${escapeHtml(manifest.prUrl)}">Pull request</a>` : ""}</p></section>
</main></body></html>`;
}

function indexPage(rows) {
  const data = JSON.stringify(rows).replaceAll("<", "\\u003c");
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Firstmate report stack</title><style>${sharedCss()}</style></head><body><main>
<header><p class="eyebrow">Firstmate completion ledger</p><h1>Report stack</h1><p>Durable, account-independent records of wrapped work.</p></header>
<div class="toolbar"><input id="search" type="search" placeholder="Search tasks, summaries, projects…"><select id="kind"><option value="">All task types</option><option value="ship">Ship</option><option value="scout">Scout</option></select></div><div id="cards" class="cards"></div>
<script>const reports=${data};const cards=document.querySelector('#cards');const search=document.querySelector('#search');const kind=document.querySelector('#kind');const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));function draw(){const q=search.value.toLowerCase();const rows=reports.filter(r=>(!kind.value||r.kind===kind.value)&&(!q||[r.title,r.summary,r.taskId,r.project,r.harness,r.accountProfile].join(' ').toLowerCase().includes(q)));cards.innerHTML=rows.length?rows.map(r=>'<article class="card"><a href="entries/'+encodeURIComponent(r.reportId)+'/report.html"><p class="eyebrow">'+esc(r.kind)+' · '+esc(r.completedAt.slice(0,10))+'</p><h2>'+esc(r.title)+'</h2><p>'+esc(r.summary)+'</p><p class="meta">'+esc(r.project)+' · '+esc(r.harness)+(r.accountProfile?' · '+esc(r.accountProfile):'')+'</p></a></article>').join(''):'<div class="empty">No matching reports.</div>'}search.addEventListener('input',draw);kind.addEventListener('change',draw);draw();</script>
</main></body></html>`;
}

function acquireLock() {
  fs.mkdirSync(stackRoot, { recursive: true, mode: 0o700 });
  const stackReal = realDirectory(stackRoot, undefined, "report stack root");
  try {
    fs.mkdirSync(entriesDir, { mode: 0o700 });
  } catch (error) {
    if (error.code !== "EEXIST") throw error;
  }
  realDirectory(entriesDir, stackReal, "report entries directory");
  const lock = path.join(stackRoot, ".publish.lock");
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const token = crypto.randomUUID();
    const candidate = path.join(stackRoot, `.publish.lock.candidate.${process.pid}.${token}`);
    try {
      fs.mkdirSync(candidate, { mode: 0o700 });
      try {
        const startedAt = processStartIdentity(process.pid);
        if (!startedAt) throw new Error(`cannot identify report publisher process ${process.pid}`);
        fs.writeFileSync(path.join(candidate, "owner"), `${JSON.stringify({ pid: process.pid, startedAt, token })}\n`, { mode: 0o600 });
        if (fs.existsSync(lock)) {
          fs.rmSync(candidate, { recursive: true, force: true });
          const existsError = new Error(`report lock exists at ${lock}`);
          existsError.code = "EEXIST";
          throw existsError;
        }
        fs.renameSync(candidate, lock);
      } catch (error) {
        fs.rmSync(candidate, { recursive: true, force: true });
        throw error;
      }
      return () => {
        try {
          const owner = JSON.parse(readLockControl(path.join(lock, "owner"), "report lock owner"));
          if (owner.token === token) fs.rmSync(lock, { recursive: true, force: true });
        } catch {}
      };
    } catch (error) {
      if (error.code !== "EEXIST" && error.code !== "ENOTEMPTY") throw error;
      try {
        const lockStat = fs.lstatSync(lock);
        if (lockStat.isSymbolicLink() || !lockStat.isDirectory()) {
          throw new Error(`report lock must be a real directory at ${lock}`);
        }
        let owner = Number.NaN;
        let ownerStartedAt = "";
        try {
          const rawOwner = readLockControl(path.join(lock, "owner"), "report lock owner").trim();
          try {
            const parsedOwner = JSON.parse(rawOwner);
            owner = Number(parsedOwner.pid);
            ownerStartedAt = typeof parsedOwner.startedAt === "string" ? parsedOwner.startedAt : "";
          } catch {
            owner = Number.parseInt(rawOwner, 10);
          }
        } catch {}
        let ownerAlive = Number.isInteger(owner) && owner > 0 && Boolean(ownerStartedAt);
        if (ownerAlive) {
          try { process.kill(owner, 0); } catch (killError) { if (killError.code === "ESRCH") ownerAlive = false; }
        }
        if (ownerAlive) ownerAlive = processStartIdentity(owner) === ownerStartedAt;
        let staleMtimeMs = lockStat.mtimeMs;
        try { staleMtimeMs = Math.min(staleMtimeMs, fs.lstatSync(path.join(lock, "owner")).mtimeMs); } catch (ownerStatError) { if (ownerStatError.code !== "ENOENT") throw ownerStatError; }
        if (!ownerAlive && Date.now() - staleMtimeMs > 60_000) {
          const reclaim = path.join(lock, ".reclaim");
          const reclaimToken = crypto.randomUUID();
          let claimed = false;
          try {
            const reclaimStartedAt = processStartIdentity(process.pid);
            if (!reclaimStartedAt) throw new Error(`cannot identify report lock reclaimer ${process.pid}`);
            const reclaimOwner = { pid: process.pid, startedAt: reclaimStartedAt, token: reclaimToken };
            fs.writeFileSync(reclaim, `${JSON.stringify(reclaimOwner)}\n`, { flag: "wx", mode: 0o600 });
            claimed = true;
            const claimedStat = fs.lstatSync(lock);
            if (claimedStat.dev !== lockStat.dev || claimedStat.ino !== lockStat.ino) {
              fs.rmSync(reclaim, { force: true });
              claimed = false;
              continue;
            }
            const quarantine = path.join(stackRoot, `.publish.lock.stale.${process.pid}.${reclaimToken}`);
            fs.renameSync(lock, quarantine);
            const quarantinedReclaim = JSON.parse(readLockControl(path.join(quarantine, ".reclaim"), "report reclaim marker"));
            if (quarantinedReclaim.token !== reclaimToken) {
              throw new Error(`report lock changed while reclaiming ${lock}`);
            }
            fs.rmSync(quarantine, { recursive: true, force: true });
            continue;
          } catch (reclaimError) {
            if (reclaimError.code === "EEXIST") {
              try {
                const reclaimStat = fs.lstatSync(reclaim);
                let reclaimRaw = "";
                try { reclaimRaw = readLockControl(reclaim, "report reclaim marker").trim(); } catch {}
                let reclaimOwner;
                try {
                  reclaimOwner = JSON.parse(reclaimRaw);
                } catch {
                  reclaimOwner = { pid: Number.NaN, startedAt: "", token: reclaimRaw };
                }
                let reclaimAlive = Number.isInteger(reclaimOwner.pid) && reclaimOwner.pid > 0 && typeof reclaimOwner.startedAt === "string" && reclaimOwner.startedAt.length > 0;
                if (reclaimAlive) {
                  try { process.kill(reclaimOwner.pid, 0); } catch (killError) { if (killError.code === "ESRCH") reclaimAlive = false; }
                }
                if (reclaimAlive) reclaimAlive = processStartIdentity(reclaimOwner.pid) === reclaimOwner.startedAt;
                const currentLockStat = fs.lstatSync(lock);
                if (!reclaimAlive && Date.now() - reclaimStat.mtimeMs > 60_000
                  && currentLockStat.dev === lockStat.dev && currentLockStat.ino === lockStat.ino) {
                  const quarantine = path.join(lock, `.reclaim.abandoned.${process.pid}.${crypto.randomUUID()}`);
                  fs.renameSync(reclaim, quarantine);
                  const quarantinedReclaimStat = fs.lstatSync(quarantine);
                  let quarantinedToken;
                  try {
                    quarantinedToken = JSON.parse(readLockControl(quarantine, "quarantined report reclaim marker")).token;
                  } catch {
                    try { quarantinedToken = readLockControl(quarantine, "quarantined report reclaim marker").trim(); } catch { quarantinedToken = ""; }
                  }
                  if (quarantinedReclaimStat.dev !== reclaimStat.dev || quarantinedReclaimStat.ino !== reclaimStat.ino
                    || quarantinedToken !== reclaimOwner.token) {
                    if (!fs.existsSync(reclaim)) fs.renameSync(quarantine, reclaim);
                    throw new Error(`report reclaim ownership changed while recovering ${lock}`);
                  }
                  fs.rmSync(quarantine, { recursive: true, force: true });
                }
              } catch (reclaimOwnerError) {
                if (reclaimOwnerError.code !== "ENOENT") throw reclaimOwnerError;
              }
            } else if (reclaimError.code !== "ENOENT") {
              throw reclaimError;
            }
          } finally {
            if (claimed) {
              try {
                const reclaimOwner = JSON.parse(readLockControl(reclaim, "report reclaim marker"));
                if (reclaimOwner.token === reclaimToken) fs.rmSync(reclaim, { force: true });
              } catch {}
            }
          }
        }
      } catch (statError) {
        if (statError.code !== "ENOENT") throw statError;
      }
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
    }
  }
  throw new Error(`report stack is busy at ${lock}`);
}

function withLock(callback) {
  const release = acquireLock();
  try {
    recoverPreviousEntries();
    pruneExpiredEntries();
    return callback();
  } finally {
    release();
  }
}

function snapshotTaskArtifacts(dataRoot, taskId, sourceName, staged, sourceFile) {
  const stagedDescriptor = fs.openSync(staged, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | (fs.constants.O_NOFOLLOW || 0));
  try {
    let buffer;
    try {
      buffer = runContainedHelper([
        "snapshot-task-fd",
        taskId,
        sourceName,
        String(informationalTrailLimit),
        String(completionReportLimit),
        String(visualBytesLimit),
        `${visualEntryLimit}:${visualDepthLimit}`,
      ], [dataRoot.descriptor, stagedDescriptor], informationalTrailLimit + completionReportLimit + 1024 * 1024);
    } catch (error) {
      if (error.message.includes(`source is a symlink: ${sourceName}`)) {
        throw new Error(`completion report must be a real regular file at ${sourceFile}`);
      }
      if (error.message.includes("source is a symlink: brief.md")) {
        throw new Error(`task brief must be a real regular file at ${path.join(dataDir, taskId, "brief.md")}`);
      }
      if (error.message.includes(`source is a symlink: ${taskId}`)) {
        throw new Error(`task data directory must be a real directory at ${path.join(dataDir, taskId)}`);
      }
      throw error;
    }
    const items = framedItems(buffer);
    const briefItem = items.get("brief");
    const sourceItem = items.get("source");
    const visualsItem = items.get("visuals");
    let brief = briefItem && !briefItem.missing ? briefItem.content.toString("utf8") : "";
    if (briefItem?.oversized) {
      brief += `\n[task brief truncated: original size ${briefItem.size} bytes; kept first ${briefItem.bytes} bytes]\n`;
    }
    if (sourceItem?.oversized) {
      throw new Error(`completion report at ${sourceFile} is ${sourceItem.size} bytes and exceeds the ${completionReportLimit}-byte publication limit. `
        + `Reduce ${sourceFile}, keeping every required section intact. `
        + `Then rerun ${fmRoot}/bin/fm-report-stack.mjs publish ${taskId} or ${fmRoot}/bin/fm-teardown.sh ${taskId}. `
        + "This attempt did not replace the durable report, and teardown remains stopped before destructive cleanup.");
    }
    return {
      brief,
      source: sourceItem && !sourceItem.missing ? sourceItem.content.toString("utf8") : undefined,
      visuals: visualsItem && !visualsItem.missing ? JSON.parse(visualsItem.content.toString("utf8")) : [],
    };
  } finally {
    fs.closeSync(stagedDescriptor);
  }
}

function readManifests() {
  if (!fs.existsSync(entriesDir)) return [];
  return fs.readdirSync(entriesDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && !entry.name.startsWith("."))
    .map((entry) => path.join(entriesDir, entry.name, "manifest.json"))
    .filter((file) => fs.existsSync(file))
    .map((file) => JSON.parse(readBoundedRegularFile(file, manifestLimit, "report manifest")))
    .sort((a, b) => b.completedAt.localeCompare(a.completedAt));
}

function reportTransactionPath(reportId) {
  return path.join(entriesDir, `.${reportId}.transaction`);
}

function writeReportTransaction(reportId, hadPrevious) {
  const transaction = reportTransactionPath(reportId);
  const temp = `${transaction}.${crypto.randomUUID()}.tmp`;
  try {
    fs.writeFileSync(temp, `${JSON.stringify({ schemaVersion: 1, reportId, hadPrevious })}\n`, { flag: "wx", mode: 0o600 });
    assertSafeFileDestination(transaction, "report transaction destination");
    fs.renameSync(temp, transaction);
  } finally {
    fs.rmSync(temp, { force: true });
  }
  return transaction;
}

function removeStagedReports(reportId) {
  const prefix = `.${reportId}.`;
  for (const entry of fs.readdirSync(entriesDir, { withFileTypes: true })) {
    if (entry.isDirectory() && entry.name.startsWith(prefix) && entry.name.endsWith(".tmp")) {
      fs.rmSync(path.join(entriesDir, entry.name), { recursive: true, force: true });
    }
  }
}

function removeAgedOrphanStaging(transactionIds) {
  const minimumAgeMs = 24 * 60 * 60 * 1000;
  for (const entry of fs.readdirSync(entriesDir, { withFileTypes: true })) {
    const match = entry.isDirectory() && entry.name.match(/^\.([a-zA-Z0-9][a-zA-Z0-9._-]*)\.(?:[0-9]+|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.tmp$/i);
    if (!match || transactionIds.has(match[1])) continue;
    const staged = path.join(entriesDir, entry.name);
    if (Date.now() - fs.statSync(staged).mtimeMs < minimumAgeMs) continue;
    fs.rmSync(staged, { recursive: true, force: true });
  }
}

function recoverPreviousEntries() {
  if (!fs.existsSync(entriesDir)) return;
  const transactions = [];
  const transactionIds = new Set();
  for (const entry of fs.readdirSync(entriesDir, { withFileTypes: true })) {
    const match = entry.name.match(/^\.([a-zA-Z0-9][a-zA-Z0-9._-]*)\.transaction$/);
    if (!match) continue;
    if (!entry.isFile()) throw new Error(`invalid report transaction at ${path.join(entriesDir, entry.name)}`);
    const transaction = path.join(entriesDir, entry.name);
    const record = JSON.parse(readBoundedRegularFile(transaction, transactionLimit, "report transaction"));
    const reportId = match[1];
    if (record.schemaVersion !== 1 || record.reportId !== reportId || typeof record.hadPrevious !== "boolean") {
      throw new Error(`invalid report transaction at ${transaction}`);
    }
    const destination = path.join(entriesDir, reportId);
    const previous = path.join(entriesDir, `.${reportId}.previous`);
    if (record.hadPrevious) {
      if (fs.existsSync(previous)) {
        fs.rmSync(destination, { recursive: true, force: true });
        fs.renameSync(previous, destination);
      } else if (!fs.existsSync(destination)) {
        throw new Error(`report transaction lost both generations for ${reportId}`);
      }
    } else {
      if (fs.existsSync(previous)) throw new Error(`unexpected previous report generation for ${reportId}`);
      fs.rmSync(destination, { recursive: true, force: true });
    }
    transactions.push({ reportId, transaction });
    transactionIds.add(reportId);
  }

  const recoveredPrevious = [];
  for (const entry of fs.readdirSync(entriesDir, { withFileTypes: true })) {
    const match = entry.isDirectory() && entry.name.match(/^\.([a-zA-Z0-9][a-zA-Z0-9._-]*)\.previous$/);
    if (!match) continue;
    if (transactionIds.has(match[1])) continue;
    const previous = path.join(entriesDir, entry.name);
    const destination = path.join(entriesDir, match[1]);
    const discard = fs.existsSync(destination);
    if (!discard) fs.renameSync(previous, destination);
    recoveredPrevious.push({ previous, discard });
  }

  if (transactions.length > 0 || recoveredPrevious.length > 0) renderIndex();
  for (const { reportId, transaction } of transactions) {
    removeStagedReports(reportId);
    fs.rmSync(transaction, { force: true });
  }
  for (const { previous, discard } of recoveredPrevious) {
    if (discard) fs.rmSync(previous, { recursive: true, force: true });
  }
  removeAgedOrphanStaging(transactionIds);
}

function pruneExpiredEntries() {
  const cutoff = Date.now() - reportRetentionMs;
  const expired = readManifests().filter((manifest) => {
    const completedAt = Date.parse(manifest.completedAt);
    return Number.isFinite(completedAt) && completedAt <= cutoff;
  });
  if (expired.length === 0) return;
  const moved = [];
  try {
    for (const manifest of expired) {
      const destination = path.join(entriesDir, manifest.reportId);
      const previous = path.join(entriesDir, `.${manifest.reportId}.previous`);
      if (!fs.existsSync(destination)) continue;
      if (fs.existsSync(previous)) throw new Error(`report retention found an active previous generation for ${manifest.reportId}`);
      realDirectory(destination, fs.realpathSync(entriesDir), "expired report entry");
      fs.renameSync(destination, previous);
      moved.push({ destination, previous });
    }
    renderIndex();
  } catch (error) {
    for (const { destination, previous } of moved.reverse()) {
      if (!fs.existsSync(destination) && fs.existsSync(previous)) fs.renameSync(previous, destination);
    }
    throw error;
  }
  for (const { previous } of moved) fs.rmSync(previous, { recursive: true, force: true });
}

function renderIndex() {
  const temp = path.join(stackRoot, `.index.html.${crypto.randomUUID()}.tmp`);
  const destination = path.join(stackRoot, "index.html");
  try {
    fs.writeFileSync(temp, indexPage(readManifests()), { flag: "wx", mode: 0o600 });
    assertSafeFileDestination(destination, "report index destination");
    fs.renameSync(temp, destination);
  } finally {
    fs.rmSync(temp, { force: true });
  }
}

function publish(taskId, legacy) {
  if (!taskId || !/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(taskId)) throw new Error("publish requires a safe task id");
  const dataRoot = pinnedDirectory(dataDir, undefined, "configured data root");
  const stateRoot = pinnedDirectory(stateDir, undefined, "configured state root");
  try {
    const metaFile = path.join(stateDir, `${taskId}.meta`);
    const metaSource = readArtifact(metaFile, stateRoot, "task metadata", { maxBytes: metadataLimit });
    if (metaSource === undefined) throw new Error(`no task metadata at ${metaFile}`);
    const meta = parseMeta(metaSource);
    if (meta.kind === "secondmate") throw new Error("persistent secondmate retirement is not a completion report");
    const taskData = path.join(dataDir, taskId);
    const sourceName = meta.kind === "scout" ? "report.md" : "completion.md";
    const sourceFile = path.join(taskData, sourceName);
    const statusFile = path.join(stateDir, `${taskId}.status`);
    const status = redactSensitive(readArtifact(statusFile, stateRoot, "status trail", {
      maxBytes: informationalTrailLimit,
      truncate: "tail",
    }) || "");
    const id = stableReportId(taskId);
    const destination = path.join(entriesDir, id);
    const previous = path.join(entriesDir, `.${id}.previous`);
    let previousManifest;
    if (fs.existsSync(destination)) {
      realDirectory(destination, fs.realpathSync(entriesDir), "existing report entry");
      if (!fs.existsSync(path.join(destination, "manifest.json"))) throw new Error(`existing report entry is incomplete at ${destination}`);
      previousManifest = JSON.parse(readBoundedRegularFile(path.join(destination, "manifest.json"), manifestLimit, "existing report manifest"));
    }
    const staged = path.join(entriesDir, `.${id}.${crypto.randomUUID()}.tmp`);
    let transaction;
    fs.mkdirSync(staged, { mode: 0o700 });
    try {
      const taskArtifacts = snapshotTaskArtifacts(dataRoot, taskId, sourceName, staged, sourceFile);
      const brief = redactSensitive(taskArtifacts.brief);
      const source = taskArtifacts.source;
      const visuals = taskArtifacts.visuals;
      let markdown;
      if (source !== undefined) {
        if (meta.report_required === "1") requireCompletionSections(source, sourceFile, taskId);
        markdown = redactSensitive(source);
      } else if (legacy && meta.report_required !== "1") markdown = `# ${titleFromBrief(taskId, brief)}\n\n## Summary\n\n${lastStatus(status)}\n\n## Preserved trail\n\nThis compatibility report was synthesized for a task created before completion reports were required.\nSee the attached task brief and status trail for details.\n`;
      else throw new Error(`required completion report is missing at ${sourceFile}`);
      if (!markdown.trim()) throw new Error(`completion report is empty at ${sourceFile}`);

      const worktreeHead = gitValue(meta.worktree, ["rev-parse", "--short=12", "HEAD"]);
      const prHead = displaySha(meta.pr_head);
      const generationId = meta.generation_id || "";
      const previousWorktreeHead = previousManifest?.worktreeHead || previousManifest?.commit || "";
      const sameGeneration = previousManifest && generationId && previousManifest.generationId
        ? generationId === previousManifest.generationId
        : previousManifest
          && (!worktreeHead || previousWorktreeHead === worktreeHead)
          && previousManifest.harness === (meta.harness || "unknown")
          && (previousManifest.accountProfile || "") === (meta.account_profile || "");
      const branch = gitValue(meta.worktree, ["branch", "--show-current"]);
      const publishedWorktreeHead = worktreeHead || (sameGeneration ? previousWorktreeHead : "");
      const publishedCommit = worktreeHead || (sameGeneration ? previousManifest?.commit || previousWorktreeHead : "");
      const publishedBranch = branch || (sameGeneration ? previousManifest?.branch || "" : "");
      const manifest = {
        schemaVersion: 1,
        reportId: id,
        taskId,
        title: titleFromBrief(taskId, brief),
        summary: firstSummary(markdown, lastStatus(status)),
        completedAt: sameGeneration ? previousManifest.completedAt : new Date().toISOString(),
        kind: meta.kind || "ship",
        mode: meta.mode || "no-mistakes",
        project: meta.project ? path.basename(meta.project) : "unknown",
        harness: meta.harness || "unknown",
        accountProfile: meta.account_profile || "",
        ...(generationId ? { generationId } : {}),
        prUrl: safeHttpUrl(meta.pr),
        commit: publishedCommit,
        worktreeHead: publishedWorktreeHead,
        ...(prHead ? { prHead } : {}),
        branch: publishedBranch,
        visuals,
      };
      fs.writeFileSync(path.join(staged, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600 });
      fs.writeFileSync(path.join(staged, "report.md"), markdown, { mode: 0o600 });
      fs.writeFileSync(path.join(staged, "brief.md"), brief || "Task brief unavailable.\n", { mode: 0o600 });
      fs.writeFileSync(path.join(staged, "status.log"), status || "Status trail unavailable.\n", { mode: 0o600 });
      fs.writeFileSync(path.join(staged, "report.html"), reportPage(manifest, markdown, visuals), { mode: 0o600 });

      const hadPrevious = fs.existsSync(destination);
      transaction = writeReportTransaction(id, hadPrevious);
      if (hadPrevious) fs.renameSync(destination, previous);
      try {
        fs.renameSync(staged, destination);
      } catch (error) {
        if (!fs.existsSync(destination) && fs.existsSync(previous)) fs.renameSync(previous, destination);
        throw error;
      }
      try {
        renderIndex();
      } catch (error) {
        fs.rmSync(destination, { recursive: true, force: true });
        if (fs.existsSync(previous)) fs.renameSync(previous, destination);
        throw error;
      }
      fs.rmSync(transaction, { force: true });
      transaction = undefined;
      fs.rmSync(previous, { recursive: true, force: true });
      console.log(`published ${taskId} ${path.join(destination, "report.html")}`);
    } catch (error) {
      if (transaction && fs.existsSync(transaction)) {
        try {
          recoverPreviousEntries();
        } catch (recoveryError) {
          error.message = `${error.message}; report transaction recovery remains pending: ${recoveryError.message}`;
        }
      }
      throw error;
    } finally {
      fs.rmSync(staged, { recursive: true, force: true });
    }
  } finally {
    fs.closeSync(stateRoot.descriptor);
    fs.closeSync(dataRoot.descriptor);
  }
}

function resolveReportPath(taskId) {
  if (!taskId) return path.join(stackRoot, "index.html");
  const rows = readManifests();
  const exact = rows.find((row) => row.reportId === taskId);
  if (exact) return path.join(entriesDir, exact.reportId, "report.html");
  const matches = rows.filter((row) => row.taskId === taskId);
  if (matches.length === 0) throw new Error(`no report found for ${taskId}`);
  if (matches.length > 1) {
    throw new Error(`task id ${taskId} is ambiguous; use one of these report ids: ${matches.map((row) => row.reportId).join(", ")}`);
  }
  return path.join(entriesDir, matches[0].reportId, "report.html");
}

refuseIfGateAgent();

try {
  if (command === "publish") {
    withLock(() => publish(args.find((arg) => !arg.startsWith("--")), args.includes("--legacy")));
  } else if (command === "render") {
    withLock(renderIndex);
    console.log(path.join(stackRoot, "index.html"));
  } else if (command === "list") {
    const rows = withLock(readManifests);
    if (args.includes("--json")) console.log(JSON.stringify(rows, null, 2));
    else for (const row of rows) console.log(`${row.completedAt}\t${row.taskId}\t${row.kind}\t${row.title}`);
  } else if (command === "path") {
    console.log(withLock(() => resolveReportPath(args[0])));
  } else if (command === "open") {
    const target = withLock(() => {
      renderIndex();
      return resolveReportPath(args[0]);
    });
    execFileSync(process.platform === "darwin" ? "open" : "xdg-open", [target], { stdio: "ignore" });
    console.log(target);
  } else {
    fail(`unknown command: ${command}`);
  }
} catch (error) {
  fail(error.message);
}
