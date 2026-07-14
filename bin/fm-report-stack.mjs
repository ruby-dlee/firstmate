#!/usr/bin/env node
// Publish and browse durable Firstmate completion reports.
//
// The report stack is machine-global and independent of FM_HOME and provider
// account homes. New tasks record report_required=1; teardown publishes them
// before its first destructive action. Publication is idempotent by canonical
// Firstmate home + task id, serialized, staged, and swapped into place only
// after every artifact is ready.
//
// Usage: fm-report-stack.mjs publish <task-id> [--legacy]
//        fm-report-stack.mjs render
//        fm-report-stack.mjs list [--json]
//        fm-report-stack.mjs path [<task-id>]
//        fm-report-stack.mjs open [<task-id>]
//
// FM_REPORT_STACK_ROOT overrides the default
// ~/.local/share/firstmate/report-stack. FM_HOME, FM_STATE_OVERRIDE, and
// FM_DATA_OVERRIDE select the task source like the rest of Firstmate.

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const command = process.argv[2] || "list";
const args = process.argv.slice(3);
const fmRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const fmHome = path.resolve(process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || fmRoot);
const stateDir = path.resolve(process.env.FM_STATE_OVERRIDE || path.join(fmHome, "state"));
const dataDir = path.resolve(process.env.FM_DATA_OVERRIDE || path.join(fmHome, "data"));
const stackRoot = path.resolve(process.env.FM_REPORT_STACK_ROOT || path.join(process.env.XDG_DATA_HOME || path.join(os.homedir(), ".local", "share"), "firstmate", "report-stack"));
const entriesDir = path.join(stackRoot, "entries");

function fail(message) {
  console.error(`error: ${message}`);
  process.exit(1);
}

function parseMeta(file) {
  const result = {};
  if (!fs.existsSync(file)) return result;
  for (const line of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
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

function firstSummary(markdown, fallback) {
  const summarySection = markdown.match(/^## Summary\s*\n+([\s\S]*?)(?=\n## |$)/mi)?.[1];
  const text = (summarySection || markdown)
    .replace(/^#{1,6}\s+/gm, "")
    .replace(/```[\s\S]*?```/g, "")
    .replace(/!\[[^\]]*\]\([^)]*\)/g, "")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/[*_`>#-]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  return (text || fallback).slice(0, 320);
}

function gitValue(worktree, gitArgs) {
  if (!worktree || !fs.existsSync(worktree)) return "";
  try {
    return execFileSync("git", ["-C", worktree, ...gitArgs], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch {
    return "";
  }
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

function escapeHtml(value) {
  return String(value).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&#39;");
}

function redactSensitive(value) {
  return String(value)
    .replace(/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g, "[REDACTED PRIVATE KEY]")
    .replace(/\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9_]{16,})\b/g, "[REDACTED TOKEN]")
    .replace(/^(\s*(?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret|authorization|cookie)\s*[:=]\s*).+$/gim, "$1[REDACTED]");
}

function safeHttpUrl(value) {
  if (!value) return "";
  try {
    const parsed = new URL(value);
    return parsed.protocol === "https:" || parsed.protocol === "http:" ? parsed.href : "";
  } catch {
    return "";
  }
}

function sharedCss() {
  return `:root{color-scheme:light dark;--bg:#f4f1e8;--panel:#fffdf7;--ink:#1c2623;--muted:#68736f;--accent:#17745b;--line:#d8d7ce}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.55 ui-sans-serif,system-ui,-apple-system,sans-serif}main{max-width:1080px;margin:auto;padding:48px 24px 80px}nav{margin-bottom:36px}a{color:var(--accent)}header{max-width:820px;margin-bottom:28px}.eyebrow{text-transform:uppercase;letter-spacing:.12em;font-size:.75rem;color:var(--accent);font-weight:700}h1{font:700 clamp(2rem,6vw,4.5rem)/1.02 ui-serif,Georgia,serif;margin:.2em 0}h2{font:700 1.5rem/1.2 ui-serif,Georgia,serif;margin-top:2.2rem}dl{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px}dl div,.card,pre.report,figure{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:16px}dt{font-size:.75rem;text-transform:uppercase;letter-spacing:.08em;color:var(--muted)}dd{margin:4px 0 0;overflow-wrap:anywhere}.gallery{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:16px}.gallery img{width:100%;max-height:420px;object-fit:contain;border-radius:8px}.gallery figure{margin:0}.gallery figcaption{margin-top:8px;color:var(--muted);font-size:.85rem}pre.report{white-space:pre-wrap;overflow-wrap:anywhere;font:15px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace}.muted,.meta{color:var(--muted)}.toolbar{display:flex;gap:12px;flex-wrap:wrap;margin:28px 0}.toolbar input,.toolbar select{font:inherit;padding:12px 14px;border:1px solid var(--line);border-radius:10px;background:var(--panel);color:var(--ink)}.toolbar input{flex:1;min-width:240px}.cards{display:grid;gap:14px}.card h2{margin:.2rem 0 .35rem}.card p{margin:.35rem 0}.card a{text-decoration:none;color:inherit}.empty{padding:40px;text-align:center;color:var(--muted)}@media(prefers-color-scheme:dark){:root{--bg:#14201d;--panel:#1d2b27;--ink:#f4f1e8;--muted:#a9b5b0;--accent:#74d2b3;--line:#344640}}`;
}

function reportPage(manifest, markdown, visuals) {
  const gallery = visuals.length
    ? `<section><h2>Visual evidence</h2><div class="gallery">${visuals.map((visual) => {
      const label = escapeHtml(path.basename(visual));
      const href = escapeHtml(visual);
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
<dl><div><dt>Task</dt><dd>${escapeHtml(manifest.taskId)}</dd></div><div><dt>Completed</dt><dd>${escapeHtml(manifest.completedAt)}</dd></div><div><dt>Project</dt><dd>${escapeHtml(manifest.project)}</dd></div><div><dt>Harness</dt><dd>${escapeHtml(manifest.harness)}</dd></div><div><dt>Account profile</dt><dd>${escapeHtml(manifest.accountProfile || "unmanaged")}</dd></div><div><dt>Commit</dt><dd>${escapeHtml(manifest.commit || "not recorded")}</dd></div></dl>
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
  const lock = path.join(stackRoot, ".publish.lock");
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      fs.mkdirSync(lock, { mode: 0o700 });
      try {
        const startedAt = processStartIdentity(process.pid);
        if (!startedAt) throw new Error(`cannot identify report publisher process ${process.pid}`);
        fs.writeFileSync(path.join(lock, "owner"), `${JSON.stringify({ pid: process.pid, startedAt })}\n`, { mode: 0o600 });
      } catch (error) {
        fs.rmSync(lock, { recursive: true, force: true });
        throw error;
      }
      return () => fs.rmSync(lock, { recursive: true, force: true });
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      try {
        let owner = Number.NaN;
        let ownerStartedAt = "";
        try {
          const rawOwner = fs.readFileSync(path.join(lock, "owner"), "utf8").trim();
          try {
            const parsedOwner = JSON.parse(rawOwner);
            owner = Number(parsedOwner.pid);
            ownerStartedAt = typeof parsedOwner.startedAt === "string" ? parsedOwner.startedAt : "";
          } catch {
            owner = Number.parseInt(rawOwner, 10);
          }
        } catch (ownerError) {
          if (ownerError.code !== "ENOENT") throw ownerError;
        }
        let ownerAlive = Number.isInteger(owner) && owner > 0 && Boolean(ownerStartedAt);
        if (ownerAlive) {
          try { process.kill(owner, 0); } catch (killError) { if (killError.code === "ESRCH") ownerAlive = false; }
        }
        if (ownerAlive) ownerAlive = processStartIdentity(owner) === ownerStartedAt;
        if (!ownerAlive && Date.now() - fs.statSync(lock).mtimeMs > 60_000) {
          fs.rmSync(lock, { recursive: true, force: true });
          continue;
        }
      } catch (statError) {
        if (statError.code !== "ENOENT") throw statError;
      }
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
    }
  }
  throw new Error(`report stack is busy at ${lock}`);
}

function copyVisuals(source, destination) {
  const copied = [];
  if (!fs.existsSync(source)) return copied;
  const sourceStat = fs.lstatSync(source);
  if (sourceStat.isSymbolicLink() || !sourceStat.isDirectory()) {
    throw new Error(`visual evidence root must be a real directory at ${source}`);
  }
  const sourceReal = fs.realpathSync(source);
  let total = 0;
  function visit(current, relative = "") {
    const currentReal = fs.realpathSync(current);
    const currentRelative = path.relative(sourceReal, currentReal);
    if (currentRelative === ".." || currentRelative.startsWith(`..${path.sep}`) || path.isAbsolute(currentRelative)) {
      throw new Error(`visual evidence escapes its task directory at ${current}`);
    }
    for (const dirent of fs.readdirSync(current, { withFileTypes: true })) {
      const nextRelative = path.join(relative, dirent.name);
      const input = path.join(current, dirent.name);
      if (dirent.isSymbolicLink()) throw new Error(`visual evidence must not contain symlinks at ${input}`);
      if (dirent.isDirectory()) visit(input, nextRelative);
      if (!dirent.isFile()) continue;
      const inputReal = fs.realpathSync(input);
      const inputRelative = path.relative(sourceReal, inputReal);
      if (inputRelative === ".." || inputRelative.startsWith(`..${path.sep}`) || path.isAbsolute(inputRelative)) {
        throw new Error(`visual evidence escapes its task directory at ${input}`);
      }
      total += fs.statSync(inputReal).size;
      if (total > 20 * 1024 * 1024) throw new Error("visual evidence exceeds the 20 MiB report limit");
      const output = path.join(destination, "visuals", nextRelative);
      fs.mkdirSync(path.dirname(output), { recursive: true });
      fs.copyFileSync(inputReal, output);
      copied.push(path.posix.join("visuals", ...nextRelative.split(path.sep)));
    }
  }
  visit(source);
  return copied.sort();
}

function readManifests() {
  if (!fs.existsSync(entriesDir)) return [];
  return fs.readdirSync(entriesDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && !entry.name.startsWith("."))
    .map((entry) => path.join(entriesDir, entry.name, "manifest.json"))
    .filter((file) => fs.existsSync(file))
    .map((file) => JSON.parse(fs.readFileSync(file, "utf8")))
    .sort((a, b) => b.completedAt.localeCompare(a.completedAt));
}

function renderIndex() {
  fs.mkdirSync(entriesDir, { recursive: true, mode: 0o700 });
  const temp = path.join(stackRoot, `.index.html.${process.pid}.tmp`);
  fs.writeFileSync(temp, indexPage(readManifests()), { mode: 0o600 });
  fs.renameSync(temp, path.join(stackRoot, "index.html"));
}

function publish(taskId, legacy) {
  if (!taskId || !/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(taskId)) throw new Error("publish requires a safe task id");
  const metaFile = path.join(stateDir, `${taskId}.meta`);
  if (!fs.existsSync(metaFile)) throw new Error(`no task metadata at ${metaFile}`);
  const meta = parseMeta(metaFile);
  if (meta.kind === "secondmate") throw new Error("persistent secondmate retirement is not a completion report");
  const taskData = path.join(dataDir, taskId);
  const briefFile = path.join(taskData, "brief.md");
  const statusFile = path.join(stateDir, `${taskId}.status`);
  const brief = redactSensitive(fs.existsSync(briefFile) ? fs.readFileSync(briefFile, "utf8") : "");
  const status = redactSensitive(fs.existsSync(statusFile) ? fs.readFileSync(statusFile, "utf8") : "");
  const sourceFile = meta.kind === "scout" ? path.join(taskData, "report.md") : path.join(taskData, "completion.md");
  let markdown;
  if (fs.existsSync(sourceFile)) markdown = redactSensitive(fs.readFileSync(sourceFile, "utf8"));
  else if (legacy) markdown = `# ${titleFromBrief(taskId, brief)}\n\n## Summary\n\n${lastStatus(status)}\n\n## Preserved trail\n\nThis compatibility report was synthesized for a task created before completion reports were required.\nSee the attached task brief and status trail for details.\n`;
  else throw new Error(`required completion report is missing at ${sourceFile}`);
  if (!markdown.trim()) throw new Error(`completion report is empty at ${sourceFile}`);

  const id = stableReportId(taskId);
  const destination = path.join(entriesDir, id);
  const previous = path.join(entriesDir, `.${id}.previous`);
  if (fs.existsSync(previous)) {
    if (fs.existsSync(destination)) fs.rmSync(previous, { recursive: true, force: true });
    else fs.renameSync(previous, destination);
  }
  let previousManifest;
  if (fs.existsSync(destination)) {
    if (!fs.existsSync(path.join(destination, "manifest.json"))) throw new Error(`existing report entry is incomplete at ${destination}`);
    previousManifest = JSON.parse(fs.readFileSync(path.join(destination, "manifest.json"), "utf8"));
  }
  const staged = path.join(entriesDir, `.${id}.${process.pid}.tmp`);
  fs.rmSync(staged, { recursive: true, force: true });
  fs.mkdirSync(staged, { recursive: true, mode: 0o700 });
  try {
    const visuals = copyVisuals(path.join(taskData, "visuals"), staged);
    const manifest = {
      schemaVersion: 1,
      reportId: id,
      taskId,
      title: titleFromBrief(taskId, brief),
      summary: firstSummary(markdown, lastStatus(status)),
      completedAt: previousManifest?.completedAt || new Date().toISOString(),
      kind: meta.kind || "ship",
      mode: meta.mode || "no-mistakes",
      project: meta.project ? path.basename(meta.project) : "unknown",
      harness: meta.harness || "unknown",
      accountProfile: meta.account_profile || "",
      prUrl: safeHttpUrl(meta.pr),
      commit: gitValue(meta.worktree, ["rev-parse", "--short=12", "HEAD"]),
      branch: gitValue(meta.worktree, ["branch", "--show-current"]),
      visuals,
    };
    fs.writeFileSync(path.join(staged, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600 });
    fs.writeFileSync(path.join(staged, "report.md"), markdown, { mode: 0o600 });
    fs.writeFileSync(path.join(staged, "brief.md"), brief || "Task brief unavailable.\n", { mode: 0o600 });
    fs.writeFileSync(path.join(staged, "status.log"), status || "Status trail unavailable.\n", { mode: 0o600 });
    fs.writeFileSync(path.join(staged, "report.html"), reportPage(manifest, markdown, visuals), { mode: 0o600 });

    if (fs.existsSync(destination)) fs.renameSync(destination, previous);
    try {
      fs.renameSync(staged, destination);
    } catch (error) {
      if (!fs.existsSync(destination) && fs.existsSync(previous)) fs.renameSync(previous, destination);
      throw error;
    }
    fs.rmSync(previous, { recursive: true, force: true });
    renderIndex();
    console.log(`published ${taskId} ${path.join(destination, "report.html")}`);
  } finally {
    fs.rmSync(staged, { recursive: true, force: true });
  }
}

function resolveReportPath(taskId) {
  if (!taskId) return path.join(stackRoot, "index.html");
  const match = readManifests().find((row) => row.taskId === taskId || row.reportId === taskId);
  if (!match) throw new Error(`no report found for ${taskId}`);
  return path.join(entriesDir, match.reportId, "report.html");
}

try {
  if (command === "publish") {
    const release = acquireLock();
    try { publish(args.find((arg) => !arg.startsWith("--")), args.includes("--legacy")); } finally { release(); }
  } else if (command === "render") {
    const release = acquireLock();
    try { renderIndex(); } finally { release(); }
    console.log(path.join(stackRoot, "index.html"));
  } else if (command === "list") {
    const rows = readManifests();
    if (args.includes("--json")) console.log(JSON.stringify(rows, null, 2));
    else for (const row of rows) console.log(`${row.completedAt}\t${row.taskId}\t${row.kind}\t${row.title}`);
  } else if (command === "path") {
    console.log(resolveReportPath(args[0]));
  } else if (command === "open") {
    const release = acquireLock();
    try { renderIndex(); } finally { release(); }
    const target = resolveReportPath(args[0]);
    execFileSync(process.platform === "darwin" ? "open" : "xdg-open", [target], { stdio: "ignore" });
    console.log(target);
  } else {
    fail(`unknown command: ${command}`);
  }
} catch (error) {
  fail(error.message);
}
