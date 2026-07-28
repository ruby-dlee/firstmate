#!/usr/bin/env node
/**
 * Task-scoped browser lifecycle for firstmate-launched agents.
 *
 * Commands:
 *   prepare <task-id> <tasktmp> <owner-home> <real-axi> <browser-executable> [mcp-path]
 *   root <task-id> <owner-home>
 *   run <chrome-devtools-axi arguments...>
 *   reap <task-id> <tasktmp>
 *   sweep <owner-home> <state-dir>
 *   classify <ps-inventory-file>
 *
 * The internal sentinel command is launched only by this implementation.
 *
 * The spawn path prepares a home- and task-scoped private browser root under
 * /tmp/fm-browser-<home-key>-<id> and puts bin/chrome-devtools-axi ahead of the
 * real AXI on the crew PATH.
 * The wrapper launches a separate Chrome for Testing/Canary executable lazily,
 * attaches AXI through a loopback debugging endpoint, and keeps the captain's
 * stable Chrome app and profile out of the process tree.
 *
 * Teardown reaps the recorded bridge and browser before deleting the task
 * profile. The locked bootstrap sweep also removes task roots whose owning
 * home no longer has metadata. Explicit machine-wide migration cleanup also
 * recognizes legacy AXI orphans by exact bridge/headless/temp-profile markers.
 * Set FM_BROWSER_TMP_ROOT only in tests.
 */

import { spawn, spawnSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import {
  closeSync,
  existsSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";

const TASK_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const LEGACY_PROFILE_NAME_RE = /^puppeteer_dev_chrome_profile-[A-Za-z0-9._-]+$/;
const USER_DATA_DIR_ARG_RE =
  /--user-data-dir(?:=|\s+)(["']?)(\/[^\s"']+)\1(?:\s|$)/;
const HEADLESS_ARG_RE = /(?:^|\s)--headless(?:=[^\s]+)?(?:\s|$)/;
const CHROME_PROCESS_RE =
  /(?:Google Chrome|Chromium|(?:^|[\s/])(?:chrome|chromium)(?:\s|$))/i;
const BRIDGE_PROCESS_RE =
  /(?:^|\s)(?:[^\s]*\/)?chrome-devtools-axi-bridge\.js(?:\s|$)/;
const OWNER_FILE = "owner.json";
const BROWSER_FILE = "browser.json";
const BROWSER_FAILURE_FILE = "browser.failed";
const BROWSER_SENTINEL_FILE = "browser-sentinel.json";
const AXI_PORT_FILE = "axi-port";
const LOCK_FILE = "lifecycle.lock";
const START_TIMEOUT_MS = 20_000;
const STOP_GRACE_MS = 2_000;
const CREDENTIAL_ISOLATION_ARGS = ["--use-mock-keychain", "--password-store=basic"];
const SENTINEL_HANDSHAKE_FAILURE_FIXTURE =
  "firstmate-browser-isolation-handshake-failure-v1";

function fail(message) {
  throw new Error(message);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function processAlive(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 1) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function canonicalTmpRoot() {
  const configured = process.env.FM_BROWSER_TMP_ROOT || "/tmp";
  const resolved = realpathSync(configured);
  const metadata = lstatSync(resolved);
  if (!metadata.isDirectory() || metadata.isSymbolicLink()) {
    fail(`unsafe browser temp root: ${configured}`);
  }
  if (!process.env.FM_BROWSER_TMP_ROOT && resolved !== "/tmp" && resolved !== "/private/tmp") {
    fail(`unexpected system temp root: ${resolved}`);
  }
  return resolved;
}

function validateTaskId(taskId) {
  if (!TASK_ID_RE.test(taskId)) fail(`invalid browser task id: ${taskId}`);
  return taskId;
}

function expectedTaskTmp(taskId) {
  return path.join(canonicalTmpRoot(), `fm-${validateTaskId(taskId)}`);
}

function canonicalOwnerHome(ownerHome) {
  const resolved = realpathSync(ownerHome);
  const metadata = lstatSync(resolved);
  if (!metadata.isDirectory() || metadata.isSymbolicLink()) {
    fail(`unsafe browser owner home: ${ownerHome}`);
  }
  return resolved;
}

function expectedBrowserRoot(taskId, ownerHome) {
  const homeKey = createHash("sha256")
    .update(canonicalOwnerHome(ownerHome))
    .digest("hex")
    .slice(0, 16);
  return path.join(canonicalTmpRoot(), `fm-browser-${homeKey}-${validateTaskId(taskId)}`);
}

function validateTaskTmp(taskId, taskTmp, requireExisting = true) {
  const expected = expectedTaskTmp(taskId);
  const resolved = requireExisting
    ? realpathSync(taskTmp)
    : path.join(realpathSync(path.dirname(path.resolve(taskTmp))), path.basename(taskTmp));
  if (resolved !== expected) {
    fail(`unsafe browser task temp path for ${taskId}: ${taskTmp}`);
  }
  if (requireExisting) {
    const metadata = lstatSync(resolved);
    if (!metadata.isDirectory() || metadata.isSymbolicLink()) {
      fail(`unsafe browser task temp directory for ${taskId}: ${taskTmp}`);
    }
  }
  return resolved;
}

function validateBrowserRoot(taskId, browserRoot, ownerHome) {
  const expected = expectedBrowserRoot(taskId, ownerHome);
  const resolved = realpathSync(browserRoot);
  if (resolved !== expected) {
    fail(`unsafe browser root for ${taskId}: ${browserRoot}`);
  }
  const metadata = lstatSync(resolved);
  if (!metadata.isDirectory() || metadata.isSymbolicLink()) {
    fail(`unsafe browser root directory for ${taskId}: ${browserRoot}`);
  }
  return resolved;
}

function readJson(file) {
  return JSON.parse(readFileSync(file, "utf8"));
}

function writeJson(file, value) {
  writeFileSync(file, `${JSON.stringify(value)}\n`, { mode: 0o600 });
}

function validateExecutable(file, label) {
  if (!path.isAbsolute(file)) fail(`${label} must be absolute: ${file}`);
  const resolved = realpathSync(file);
  const metadata = statSync(resolved);
  if (!metadata.isFile()) fail(`${label} is not a regular file: ${file}`);
  return resolved;
}

function validateOwner(owner, root, taskId, ownerHome, taskTmp = "") {
  if (!owner || owner.version !== 2 || owner.taskId !== taskId) {
    fail(`browser owner record does not match ${taskId}`);
  }
  if (owner.root !== root) fail(`browser owner root changed for ${taskId}`);
  owner.ownerHome = canonicalOwnerHome(owner.ownerHome);
  if (owner.ownerHome !== canonicalOwnerHome(ownerHome)) {
    fail(`browser owner home changed for ${taskId}`);
  }
  owner.taskTmp = validateTaskTmp(taskId, owner.taskTmp, existsSync(owner.taskTmp));
  if (
    taskTmp &&
    owner.taskTmp !== validateTaskTmp(taskId, taskTmp, existsSync(taskTmp))
  ) {
    fail(`browser task temp changed for ${taskId}`);
  }
  owner.realAxi = validateExecutable(owner.realAxi, "chrome-devtools-axi");
  owner.browserExecutable = owner.browserExecutable
    ? validateExecutable(owner.browserExecutable, "automation browser executable")
    : "";
  if (owner.mcpPath) owner.mcpPath = validateExecutable(owner.mcpPath, "chrome-devtools-mcp");
  return owner;
}

function loadOwner(root, taskId, ownerHome, taskTmp = "") {
  return validateOwner(readJson(path.join(root, OWNER_FILE)), root, taskId, ownerHome, taskTmp);
}

function parseInventory(text) {
  const rows = [];
  for (const line of text.split(/\r?\n/)) {
    if (!line.trim()) continue;
    const match = line.match(/^\s*(\d+)\s+(\d+)\s+(\d+)\s+(.*)$/);
    if (!match) continue;
    rows.push({
      pid: Number(match[1]),
      ppid: Number(match[2]),
      pgid: Number(match[3]),
      command: match[4],
    });
  }
  return rows;
}

function processInventory() {
  const result = spawnSync("ps", ["-axo", "pid=,ppid=,pgid=,command="], {
    encoding: "utf8",
    timeout: 5_000,
  });
  if (result.status !== 0) fail("cannot inspect process inventory for browser cleanup");
  return parseInventory(result.stdout);
}

function rowForPid(pid, rows = processInventory()) {
  return rows.find((row) => row.pid === pid) || null;
}

function isLegacyBridge(row) {
  return BRIDGE_PROCESS_RE.test(row.command);
}

function legacyProfileFromCommand(command) {
  const match = command.match(USER_DATA_DIR_ARG_RE);
  if (!match) return null;
  const profileName = path.basename(match[2]);
  if (!LEGACY_PROFILE_NAME_RE.test(profileName)) return null;
  try {
    const parent = realpathSync(path.dirname(match[2]));
    if (parent !== canonicalTmpRoot()) return null;
    return path.join(parent, profileName);
  } catch {
    return null;
  }
}

function isLegacyBrowser(row) {
  return (
    CHROME_PROCESS_RE.test(row.command) &&
    HEADLESS_ARG_RE.test(row.command) &&
    legacyProfileFromCommand(row.command) !== null
  );
}

function taskProfileFromCommand(command) {
  const match = command.match(
    /--user-data-dir(?:=|\s+)(["']?)((?:\/private)?\/tmp\/fm-browser-[a-f0-9]{16}-[A-Za-z0-9._-]+\/profile)\1(?:\s|$)/,
  );
  return match ? match[2] : null;
}

function classifyRow(row, protectedPids = new Set()) {
  if (protectedPids.has(row.pid) || taskProfileFromCommand(row.command)) {
    return "protected-task-browser";
  }
  if (isLegacyBridge(row)) return "legacy-bridge";
  if (isLegacyBrowser(row)) return "legacy-browser";
  return "unrelated";
}

function processMatchesBrowser(state, row) {
  if (!row) return false;
  return (
    row.command.includes(state.executable) &&
    row.command.includes(`--user-data-dir=${state.profile}`) &&
    HEADLESS_ARG_RE.test(row.command)
  );
}

function processMatchesSentinel(state, row) {
  return (
    row !== null &&
    Number.isSafeInteger(state.sentinelPid) &&
    state.sentinelPid === state.pgid &&
    row.pid === state.sentinelPid &&
    row.pgid === state.pgid &&
    row.command.includes("fm-browser-isolation.mjs sentinel") &&
    row.command.includes(state.profile) &&
    row.command.includes(state.sentinelNonce)
  );
}

function processMatchesBridge(row) {
  return row !== null && isLegacyBridge(row);
}

async function waitForExit(pid, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (!processAlive(pid)) return true;
    await sleep(50);
  }
  return !processAlive(pid);
}

async function terminateExactPid(pid, matches, allowGroup = false) {
  let row = rowForPid(pid);
  if (!row || !matches(row)) return false;
  const signalTarget = allowGroup && row.pgid === pid ? -pid : pid;
  try {
    process.kill(signalTarget, "SIGTERM");
  } catch {
    return true;
  }
  if (await waitForExit(pid, STOP_GRACE_MS)) return true;
  row = rowForPid(pid);
  if (!row || !matches(row)) return true;
  try {
    process.kill(signalTarget, "SIGKILL");
  } catch {
    return true;
  }
  return waitForExit(pid, 1_000);
}

function sameProcessIdentity(original, current) {
  return (
    current !== null &&
    original.pid === current.pid &&
    original.pgid === current.pgid &&
    original.command === current.command
  );
}

function descendantsOf(pid, rows) {
  const descendants = new Set([pid]);
  let changed = true;
  while (changed) {
    changed = false;
    for (const row of rows) {
      if (descendants.has(row.ppid) && !descendants.has(row.pid)) {
        descendants.add(row.pid);
        changed = true;
      }
    }
  }
  descendants.delete(pid);
  return [...descendants];
}

async function terminateOwnedBrowserTree(state) {
  const rows = processInventory();
  const root = rowForPid(state.pid, rows);
  const rootMatches = processMatchesBrowser(state, root);
  const sentinelMatches = processMatchesSentinel(
    state,
    rowForPid(state.sentinelPid, rows),
  );
  const dedicatedPgid = Number.isSafeInteger(state.pgid)
    ? state.pgid
    : rootMatches && root.pgid === root.pid
      ? root.pgid
      : 0;
  const groupLeaderPid = Number.isSafeInteger(state.sentinelPid)
    ? state.sentinelPid
    : state.pid;
  const dedicatedGroup = dedicatedPgid === groupLeaderPid;
  const groupRows =
    dedicatedGroup
      ? rows.filter((row) => row.pgid === dedicatedPgid)
      : [];
  if (!rootMatches && !sentinelMatches && groupRows.length > 0) {
    fail(`cannot verify persisted browser process group ownership: ${dedicatedPgid}`);
  }
  const ownedPids = new Set(
    rootMatches ? [root.pid, ...descendantsOf(root.pid, rows)] : [],
  );
  if ((rootMatches || sentinelMatches) && dedicatedGroup) {
    for (const row of groupRows) ownedPids.add(row.pid);
  }
  const owned = rows.filter((row) => ownedPids.has(row.pid));
  if (owned.length === 0) return false;
  if (dedicatedGroup) {
    try {
      process.kill(-dedicatedPgid, "SIGTERM");
    } catch {
      // The dedicated process group already exited.
    }
  } else {
    for (const row of owned.slice().reverse()) {
      try {
        process.kill(row.pid, "SIGTERM");
      } catch {
        // The exact process already exited.
      }
    }
  }
  await sleep(STOP_GRACE_MS);
  for (const original of owned) {
    if (!sameProcessIdentity(original, rowForPid(original.pid))) continue;
    try {
      process.kill(original.pid, "SIGKILL");
    } catch {
      // The exact process exited after verification.
    }
  }
  await sleep(100);
  const survivors = owned.filter((original) =>
    sameProcessIdentity(original, rowForPid(original.pid)),
  );
  if (survivors.length > 0) {
    fail(
      `task browser process tree survived cleanup: ${survivors
        .map((row) => row.pid)
        .join(",")}`,
    );
  }
  return true;
}

async function terminatePendingSentinel(pid, root, nonce) {
  const rows = processInventory();
  const sentinel = rowForPid(pid, rows);
  const matches =
    sentinel !== null &&
    sentinel.pid === pid &&
    sentinel.pgid === pid &&
    sentinel.command.includes("fm-browser-isolation.mjs sentinel") &&
    sentinel.command.includes(root) &&
    sentinel.command.includes(nonce);
  const groupRows = rows.filter((row) => row.pgid === pid);
  if (!matches) {
    if (groupRows.length > 0) {
      fail(`cannot verify failed browser sentinel ownership: ${pid}`);
    }
    return;
  }
  try {
    process.kill(-pid, "SIGTERM");
  } catch {}
  await sleep(STOP_GRACE_MS);
  for (const original of groupRows) {
    if (!sameProcessIdentity(original, rowForPid(original.pid))) continue;
    try {
      process.kill(original.pid, "SIGKILL");
    } catch {}
  }
  await sleep(100);
  const survivors = groupRows.filter((original) =>
    sameProcessIdentity(original, rowForPid(original.pid)),
  );
  if (survivors.length > 0) {
    fail(
      `failed browser sentinel process group survived cleanup: ${survivors
        .map((row) => row.pid)
        .join(",")}`,
    );
  }
}

async function terminateLegacyBridgeTree(pid) {
  const rows = processInventory();
  const root = rowForPid(pid, rows);
  if (!root || !isLegacyBridge(root)) return false;
  const owned = descendantsOf(pid, rows).reverse();
  for (const childPid of owned) {
    try {
      process.kill(childPid, "SIGTERM");
    } catch {
      // Already gone.
    }
  }
  await terminateExactPid(pid, isLegacyBridge, root.pgid === pid);
  await sleep(100);
  for (const childPid of owned) {
    if (!processAlive(childPid)) continue;
    try {
      process.kill(childPid, "SIGKILL");
    } catch {
      // Already gone.
    }
  }
  return true;
}

async function terminateLegacyBrowsers(rows) {
  const candidates = rows.filter(isLegacyBrowser);
  const ownedPids = new Set();
  for (const candidate of candidates) {
    ownedPids.add(candidate.pid);
    for (const childPid of descendantsOf(candidate.pid, rows)) {
      ownedPids.add(childPid);
    }
  }
  for (const pid of ownedPids) {
    try {
      process.kill(pid, "SIGTERM");
    } catch {
      // Already gone.
    }
  }
  await sleep(500);
  let killed = 0;
  for (const pid of ownedPids) {
    const current = rowForPid(pid);
    if (!current) {
      killed += 1;
      continue;
    }
    const original = rows.find((row) => row.pid === pid);
    if (!original || current.command !== original.command) continue;
    try {
      process.kill(pid, "SIGKILL");
      killed += 1;
    } catch {
      killed += 1;
    }
  }
  return killed;
}

function requestJson(port, requestPath, timeoutMs = 1_000) {
  return new Promise((resolve, reject) => {
    const request = http.get(
      { hostname: "127.0.0.1", port, path: requestPath, timeout: timeoutMs },
      (response) => {
        let body = "";
        response.setEncoding("utf8");
        response.on("data", (chunk) => {
          body += chunk;
        });
        response.on("end", () => {
          try {
            resolve(JSON.parse(body));
          } catch (error) {
            reject(error);
          }
        });
      },
    );
    request.on("timeout", () => {
      request.destroy(new Error("timeout"));
    });
    request.on("error", reject);
  });
}

async function browserReachable(port) {
  try {
    const response = await requestJson(port, "/json/version");
    return typeof response.webSocketDebuggerUrl === "string";
  } catch {
    return false;
  }
}

async function allocatePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.unref();
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const port = typeof address === "object" && address ? address.port : 0;
      server.close((error) => {
        if (error) reject(error);
        else if (port > 0) resolve(port);
        else reject(new Error("loopback port allocation failed"));
      });
    });
  });
}

async function acquireLock(root) {
  const lock = path.join(root, LOCK_FILE);
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    try {
      writeFileSync(lock, `${process.pid}\n`, { flag: "wx", mode: 0o600 });
      return lock;
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      let ownerPid = 0;
      try {
        ownerPid = Number(readFileSync(lock, "utf8").trim());
      } catch {
        ownerPid = 0;
      }
      if (!processAlive(ownerPid)) {
        try {
          rmSync(lock);
        } catch {
          // Another caller resolved it first.
        }
        continue;
      }
      await sleep(50);
    }
  }
  fail(`browser lifecycle lock stayed busy for ${root}`);
}

function releaseLock(lock) {
  try {
    const ownerPid = Number(readFileSync(lock, "utf8").trim());
    if (ownerPid === process.pid) rmSync(lock);
  } catch {
    // Cleanup is best effort after the protected operation has finished.
  }
}

async function ensureAxiPort(root) {
  const file = path.join(root, AXI_PORT_FILE);
  if (existsSync(file)) {
    const current = Number(readFileSync(file, "utf8").trim());
    if (Number.isInteger(current) && current > 1024 && current < 65536) return current;
  }
  const port = await allocatePort();
  writeFileSync(file, `${port}\n`, { mode: 0o600 });
  return port;
}

function readBrowserState(root) {
  const file = path.join(root, BROWSER_FILE);
  if (!existsSync(file)) return null;
  try {
    const state = readJson(file);
    if (
      Number.isSafeInteger(state.pid) &&
      (!("pgid" in state) || Number.isSafeInteger(state.pgid)) &&
      (!("sentinelPid" in state) || Number.isSafeInteger(state.sentinelPid)) &&
      (!("sentinelNonce" in state) || typeof state.sentinelNonce === "string") &&
      Number.isSafeInteger(state.port) &&
      typeof state.profile === "string" &&
      typeof state.executable === "string"
    ) {
      return state;
    }
  } catch {
    // Invalid state is treated as stale and replaced only after process checks.
  }
  return null;
}

async function stopTaskBrowser(root) {
  const state = readBrowserState(root);
  if (!state) return false;
  const stopped = await terminateOwnedBrowserTree(state);
  const stillOwned = processInventory().filter(
    (row) => row.command.includes(`--user-data-dir=${state.profile}`),
  );
  for (const row of stillOwned) {
    try {
      process.kill(row.pid, "SIGTERM");
    } catch {
      // Already gone.
    }
  }
  await sleep(200);
  for (const row of stillOwned) {
    const current = rowForPid(row.pid);
    if (!current || !current.command.includes(`--user-data-dir=${state.profile}`)) continue;
    try {
      process.kill(row.pid, "SIGKILL");
    } catch {
      // Already gone.
    }
  }
  const remaining = processInventory().filter(
    (row) => row.command.includes(`--user-data-dir=${state.profile}`),
  );
  if (remaining.length > 0) {
    fail(
      `task browser processes survived cleanup: ${remaining
        .map((row) => row.pid)
        .join(",")}`,
    );
  }
  rmSync(path.join(root, BROWSER_FILE), { force: true });
  rmSync(path.join(root, BROWSER_SENTINEL_FILE), { force: true });
  return stopped || stillOwned.length > 0;
}

async function ensureBrowser(root, owner) {
  if (!owner.browserExecutable) {
    fail("no separate automation browser is installed; install Chrome Canary, Chrome for Testing, or Chromium");
  }
  if (existsSync(path.join(root, BROWSER_FAILURE_FILE))) {
    fail("automation browser is latched after a failure; run chrome-devtools-axi stop before retrying");
  }
  const existing = readBrowserState(root);
  if (existing) {
    const row = rowForPid(existing.pid);
    if (processMatchesBrowser(existing, row) && (await browserReachable(existing.port))) {
      return existing;
    }
    await stopTaskBrowser(root);
    writeFileSync(
      path.join(root, BROWSER_FAILURE_FILE),
      "automation browser exited unexpectedly; explicit stop is required before relaunch\n",
      { mode: 0o600 },
    );
    fail("automation browser exited unexpectedly; refusing to respawn it implicitly");
  }

  const profile = path.join(root, "profile");
  const home = path.join(root, "home");
  mkdirSync(profile, { recursive: true, mode: 0o700 });
  mkdirSync(home, { recursive: true, mode: 0o700 });
  for (const singleton of ["SingletonCookie", "SingletonLock", "SingletonSocket"]) {
    rmSync(path.join(profile, singleton), { force: true });
  }

  const logFile = path.join(root, "browser.log");
  const args = [
    "--headless=new",
    ...CREDENTIAL_ISOLATION_ARGS,
    "--no-first-run",
    "--no-default-browser-check",
    "--noerrdialogs",
    "--disable-breakpad",
    "--disable-crash-reporter",
    "--disable-background-networking",
    "--disable-component-update",
    "--disable-sync",
    "--remote-debugging-address=127.0.0.1",
    "--remote-debugging-port=0",
    "--remote-allow-origins=*",
    `--user-data-dir=${profile}`,
    "about:blank",
  ];
  const sentinelNonce = randomUUID();
  rmSync(path.join(root, BROWSER_SENTINEL_FILE), { force: true });
  const sentinel = spawn(process.execPath, [
    path.resolve(process.argv[1]),
    "sentinel",
    root,
    sentinelNonce,
    owner.browserExecutable,
    logFile,
    ...args,
  ], {
    detached: true,
    env: { ...process.env, HOME: home },
    stdio: "ignore",
  });
  sentinel.unref();
  const sentinelDeadline = Date.now() + START_TIMEOUT_MS;
  let sentinelState = null;
  let sentinelReady = false;
  while (Date.now() < sentinelDeadline) {
    if (!processAlive(sentinel.pid)) break;
    try {
      sentinelState = readJson(path.join(root, BROWSER_SENTINEL_FILE));
      if (
        sentinelState.pid === sentinel.pid &&
        sentinelState.pgid === sentinel.pid &&
        sentinelState.nonce === sentinelNonce &&
        Number.isSafeInteger(sentinelState.browserPid)
      ) {
        sentinelReady = true;
        break;
      }
      break;
    } catch {
      sentinelState = null;
    }
    await sleep(25);
  }
  if (!sentinelReady) {
    try {
      await terminatePendingSentinel(sentinel.pid, root, sentinelNonce);
    } catch (error) {
      writeFileSync(
        path.join(root, BROWSER_FAILURE_FILE),
        `automation browser sentinel handshake failed and cleanup was not verified: ${error.message}\n`,
        { mode: 0o600 },
      );
      fail("automation browser sentinel failed to start and cleanup could not be verified");
    }
    rmSync(path.join(root, BROWSER_SENTINEL_FILE), { force: true });
    rmSync(path.join(root, BROWSER_FILE), { force: true });
    rmSync(profile, { recursive: true, force: true });
    writeFileSync(
      path.join(root, BROWSER_FAILURE_FILE),
      "automation browser sentinel handshake failed; process group cleanup verified\n",
      { mode: 0o600 },
    );
    fail("automation browser sentinel failed to start");
  }

  const state = {
    pid: sentinelState.browserPid,
    pgid: sentinel.pid,
    sentinelPid: sentinel.pid,
    sentinelNonce,
    port: 0,
    profile,
    executable: owner.browserExecutable,
    startedAt: new Date().toISOString(),
  };
  writeJson(path.join(root, BROWSER_FILE), state);

  const activePortFile = path.join(profile, "DevToolsActivePort");
  const deadline = Date.now() + START_TIMEOUT_MS;
  while (Date.now() < deadline) {
    if (!processAlive(state.pid)) break;
    if (existsSync(activePortFile)) {
      const port = Number(readFileSync(activePortFile, "utf8").split(/\r?\n/, 1)[0]);
      if (Number.isInteger(port) && port > 0 && (await browserReachable(port))) {
        state.port = port;
        writeJson(path.join(root, BROWSER_FILE), state);
        rmSync(path.join(root, BROWSER_FAILURE_FILE), { force: true });
        return state;
      }
    }
    await sleep(100);
  }

  await stopTaskBrowser(root);
  writeFileSync(
    path.join(root, BROWSER_FAILURE_FILE),
    "automation browser failed to start; explicit stop is required before relaunch\n",
    { mode: 0o600 },
  );
  let diagnostic = "";
  try {
    diagnostic = readFileSync(logFile, "utf8").trim().split(/\r?\n/).slice(-3).join(" ");
  } catch {
    diagnostic = "";
  }
  fail(`automation browser failed to start${diagnostic ? `: ${diagnostic}` : ""}`);
}

async function commandSentinel(args) {
  if (args.length < 5) fail("invalid browser sentinel invocation");
  const [rootInput, nonce, executableInput, logFile, ...browserArgs] = args;
  setInterval(() => {}, 60_000);
  try {
    const ownerRecord = readJson(path.join(rootInput, OWNER_FILE));
    const root = validateBrowserRoot(
      ownerRecord.taskId,
      rootInput,
      ownerRecord.ownerHome,
    );
    const executable = validateExecutable(executableInput, "automation browser executable");
    if (executable !== ownerRecord.browserExecutable) {
      fail("browser sentinel executable changed");
    }
    const logFd = openSync(logFile, "a", 0o600);
    const browser = spawn(executable, browserArgs, {
      env: process.env,
      stdio: ["ignore", logFd, logFd],
    });
    const browserExit = new Promise((resolve) => {
      browser.once("exit", resolve);
      browser.once("error", resolve);
    });
    closeSync(logFd);
    if (
      process.env.FM_BROWSER_TEST_SENTINEL_HANDSHAKE_FAILURE ===
      SENTINEL_HANDSHAKE_FAILURE_FIXTURE
    ) {
      const groupRecord = process.env.FM_FAKE_BROWSER_GROUP_RECORD;
      const deadline = Date.now() + 2_000;
      while (groupRecord && !existsSync(groupRecord) && Date.now() < deadline) {
        await sleep(10);
      }
      writeJson(path.join(root, BROWSER_SENTINEL_FILE), {
        version: 1,
        pid: process.pid,
        pgid: process.pid,
        nonce,
        error: "injected browser sentinel handshake failure",
      });
      await browserExit;
      await new Promise(() => {});
    }
    writeJson(path.join(root, BROWSER_SENTINEL_FILE), {
      version: 1,
      pid: process.pid,
      pgid: process.pid,
      nonce,
      browserPid: browser.pid,
    });
    await browserExit;
  } catch (error) {
    try {
      writeJson(path.join(rootInput, BROWSER_SENTINEL_FILE), {
        version: 1,
        pid: process.pid,
        pgid: process.pid,
        nonce,
        error: error.message,
      });
    } catch {}
  }
  await new Promise(() => {});
}

function axiEnvironment(root, owner, browserState, axiPort) {
  const environment = { ...process.env };
  environment.HOME = path.join(root, "home");
  environment.CHROME_DEVTOOLS_AXI_SESSION = `fm-${owner.taskId}`;
  environment.CHROME_DEVTOOLS_AXI_PORT = String(axiPort);
  if (browserState && browserState.port > 0) {
    environment.CHROME_DEVTOOLS_AXI_BROWSER_URL = `http://127.0.0.1:${browserState.port}`;
  } else {
    delete environment.CHROME_DEVTOOLS_AXI_BROWSER_URL;
  }
  if (owner.mcpPath) environment.CHROME_DEVTOOLS_AXI_MCP_PATH = owner.mcpPath;
  else delete environment.CHROME_DEVTOOLS_AXI_MCP_PATH;
  environment.CHROME_DEVTOOLS_AXI_CHROME_ARGS = CREDENTIAL_ISOLATION_ARGS.join(" ");
  delete environment.CHROME_DEVTOOLS_AXI_AUTO_CONNECT;
  delete environment.CHROME_DEVTOOLS_AXI_USER_DATA_DIR;
  delete environment.CHROME_DEVTOOLS_AXI_CHANNEL;
  delete environment.CHROME_DEVTOOLS_AXI_HEADED;
  return environment;
}

function invokeAxi(owner, args, environment, stdio = "inherit", timeout) {
  return new Promise((resolve, reject) => {
    const child = spawn(owner.realAxi, args, {
      env: environment,
      stdio,
    });
    let timedOut = false;
    let timer;
    let killTimer;
    const forwardedSignals = ["SIGINT", "SIGTERM", "SIGHUP"];
    const handlers = new Map();

    const finish = (callback) => {
      if (timer) clearTimeout(timer);
      if (killTimer) clearTimeout(killTimer);
      for (const [signal, handler] of handlers) {
        process.off(signal, handler);
      }
      callback();
    };

    for (const signal of forwardedSignals) {
      const handler = () => {
        try {
          child.kill(signal);
        } catch {
          // The AXI command already exited.
        }
        if (!killTimer) {
          killTimer = setTimeout(() => {
            try {
              child.kill("SIGKILL");
            } catch {
              // The AXI command exited during the signal grace period.
            }
          }, STOP_GRACE_MS);
          killTimer.unref();
        }
      };
      handlers.set(signal, handler);
      process.on(signal, handler);
    }
    if (timeout) {
      timer = setTimeout(() => {
        timedOut = true;
        child.kill("SIGTERM");
        killTimer = setTimeout(() => {
          try {
            child.kill("SIGKILL");
          } catch {
            // The AXI command exited during the timeout grace period.
          }
        }, STOP_GRACE_MS);
        killTimer.unref();
      }, timeout);
      timer.unref();
    }
    child.on("error", (error) => finish(() => reject(error)));
    child.on("close", (status, signal) => {
      finish(() => {
        if (timedOut) resolve(124);
        else if (signal) resolve(128 + (os.constants.signals[signal] || 1));
        else resolve(status ?? 1);
      });
    });
  });
}

function bridgePidFile(root, taskId) {
  return path.join(
    root,
    "home",
    ".chrome-devtools-axi",
    "sessions",
    `fm-${taskId}`,
    "bridge.pid",
  );
}

function readBridgePid(root, taskId) {
  try {
    const data = readJson(bridgePidFile(root, taskId));
    return Number.isSafeInteger(data.pid) ? data.pid : 0;
  } catch {
    return 0;
  }
}

async function stopTaskAxi(root, owner) {
  const axiPort = await ensureAxiPort(root);
  const browserState = readBrowserState(root);
  const environment = axiEnvironment(root, owner, browserState, axiPort);
  const bridgePid = readBridgePid(root, owner.taskId);
  let status = 1;
  try {
    status = await invokeAxi(owner, ["stop"], environment, "ignore", 5_000);
  } catch {
    status = 1;
  } finally {
    if (bridgePid > 0) {
      await terminateExactPid(bridgePid, processMatchesBridge, true);
    }
  }
  return status;
}

async function commandPrepare(args) {
  if (args.length < 5 || args.length > 6) {
    fail("usage: prepare <task-id> <tasktmp> <owner-home> <real-axi> <browser-executable> [mcp-path]");
  }
  const [taskId, taskTmpInput, ownerHomeInput, realAxiInput, browserInput, mcpInput = ""] =
    args;
  validateTaskId(taskId);
  const taskTmp = validateTaskTmp(taskId, taskTmpInput);
  const ownerHome = canonicalOwnerHome(ownerHomeInput);
  const realAxi = validateExecutable(realAxiInput, "chrome-devtools-axi");
  const browserExecutable = browserInput
    ? validateExecutable(browserInput, "automation browser executable")
    : "";
  const mcpPath = mcpInput ? validateExecutable(mcpInput, "chrome-devtools-mcp") : "";
  const root = expectedBrowserRoot(taskId, ownerHome);
  const rootExisted = existsSync(root);
  try {
    mkdirSync(root, { recursive: true, mode: 0o700 });
    const canonicalRoot = validateBrowserRoot(taskId, root, ownerHome);
    mkdirSync(path.join(canonicalRoot, "home"), { recursive: true, mode: 0o700 });
    mkdirSync(path.join(canonicalRoot, "profile"), { recursive: true, mode: 0o700 });
    writeJson(path.join(canonicalRoot, OWNER_FILE), {
      version: 2,
      taskId,
      root: canonicalRoot,
      ownerHome,
      taskTmp,
      realAxi,
      browserExecutable,
      mcpPath,
    });
  } catch (error) {
    if (!rootExisted) rmSync(root, { recursive: true, force: true });
    throw error;
  }
}

async function commandRun(args) {
  const taskId = validateTaskId(process.env.FM_BROWSER_TASK_ID || "");
  const ownerHome = canonicalOwnerHome(process.env.FM_BROWSER_OWNER_HOME || "");
  const root = validateBrowserRoot(taskId, process.env.FM_BROWSER_ROOT || "", ownerHome);
  const owner = loadOwner(root, taskId, ownerHome);
  const lock = await acquireLock(root);
  try {
    const command = args[0] || "";
    const axiPort = await ensureAxiPort(root);
    if (command === "stop") {
      const status = await stopTaskAxi(root, owner);
      await stopTaskBrowser(root);
      rmSync(path.join(root, BROWSER_FAILURE_FILE), { force: true });
      process.exitCode = status;
      return;
    }
    const noBrowser =
      command === "" ||
      command === "setup" ||
      command === "--help" ||
      command === "-h" ||
      command === "--version" ||
      command === "-v" ||
      command === "-V";
    const browserState = noBrowser ? null : await ensureBrowser(root, owner);
    const status = await invokeAxi(
      owner,
      args,
      axiEnvironment(root, owner, browserState, axiPort),
    );
    if (status !== 0) {
      await stopTaskAxi(root, owner);
      await stopTaskBrowser(root);
      writeFileSync(
        path.join(root, BROWSER_FAILURE_FILE),
        `chrome-devtools-axi exited ${status}; explicit stop is required before relaunch\n`,
        { mode: 0o600 },
      );
    }
    process.exitCode = status;
  } finally {
    releaseLock(lock);
  }
}

async function reapRoot(taskId, taskTmp, ownerHome, removeRoot = true) {
  const expectedTmp = validateTaskTmp(taskId, taskTmp, false);
  const root = expectedBrowserRoot(taskId, ownerHome);
  if (!existsSync(root)) return { bridge: 0, browser: 0 };
  const canonicalRoot = validateBrowserRoot(taskId, root, ownerHome);
  const owner = loadOwner(canonicalRoot, taskId, ownerHome, expectedTmp);
  const lock = await acquireLock(canonicalRoot);
  let bridge = 0;
  let browser = 0;
  try {
    const bridgePid = readBridgePid(canonicalRoot, taskId);
    await stopTaskAxi(canonicalRoot, owner);
    if (bridgePid > 0 && !processAlive(bridgePid)) bridge = 1;
    if (await stopTaskBrowser(canonicalRoot)) browser = 1;
    const profile = path.join(canonicalRoot, "profile");
    const inUse = processInventory().some((row) => row.command.includes(profile));
    if (inUse) fail(`browser profile is still in use for ${taskId}`);
    if (removeRoot) rmSync(canonicalRoot, { recursive: true, force: true });
  } finally {
    if (existsSync(canonicalRoot)) releaseLock(lock);
  }
  return { bridge, browser };
}

async function commandReap(args) {
  if (args.length !== 3) fail("usage: reap <task-id> <tasktmp> <owner-home>");
  await reapRoot(validateTaskId(args[0]), args[1], args[2]);
}

function taskRoots(tmpRoot) {
  const roots = [];
  for (const entry of readdirSync(tmpRoot, { withFileTypes: true })) {
    if (!entry.isDirectory() || !entry.name.startsWith("fm-browser-")) continue;
    const browserRoot = path.join(tmpRoot, entry.name);
    if (!existsSync(path.join(browserRoot, OWNER_FILE))) continue;
    roots.push(browserRoot);
  }
  return roots;
}

function protectedTaskPids(tmpRoot) {
  const protectedPids = new Set();
  for (const root of taskRoots(tmpRoot)) {
    let owner;
    try {
      owner = readJson(path.join(root, OWNER_FILE));
    } catch {
      continue;
    }
    const taskId = owner.taskId;
    const browserState = readBrowserState(root);
    if (browserState?.pid) protectedPids.add(browserState.pid);
    const bridgePid = readBridgePid(root, taskId);
    if (bridgePid > 0) protectedPids.add(bridgePid);
  }
  return protectedPids;
}

function removeLegacyProfiles(tmpRoot) {
  const rows = processInventory();
  let removed = 0;
  for (const entry of readdirSync(tmpRoot, { withFileTypes: true })) {
    if (!LEGACY_PROFILE_NAME_RE.test(entry.name)) continue;
    const profile = path.join(tmpRoot, entry.name);
    if (rows.some((row) => legacyProfileFromCommand(row.command) === profile)) continue;
    const metadata = lstatSync(profile);
    if (!metadata.isDirectory() || metadata.isSymbolicLink()) continue;
    rmSync(profile, { recursive: true, force: true });
    removed += 1;
  }
  return removed;
}

async function commandSweep(args) {
  if (args.length !== 2) fail("usage: sweep <owner-home> <state-dir>");
  const ownerHome = realpathSync(args[0]);
  const stateDir = realpathSync(args[1]);
  const tmpRoot = canonicalTmpRoot();
  let taskRootsReaped = 0;
  let bridgesReaped = 0;
  let browsersReaped = 0;

  for (const root of taskRoots(tmpRoot)) {
    let owner;
    try {
      owner = readJson(path.join(root, OWNER_FILE));
    } catch {
      continue;
    }
    if (owner.ownerHome !== ownerHome || !TASK_ID_RE.test(owner.taskId || "")) continue;
    if (existsSync(path.join(stateDir, `${owner.taskId}.meta`))) continue;
    if (canonicalOwnerHome(owner.ownerHome) !== ownerHome) continue;
    const result = await reapRoot(owner.taskId, owner.taskTmp, ownerHome);
    taskRootsReaped += 1;
    bridgesReaped += result.bridge;
    browsersReaped += result.browser;
  }

  if (process.env.FM_BROWSER_MACHINE_WIDE_LEGACY_CLEANUP !== "1") return;

  const activeRootLocks = [];
  let profilesReaped = 0;
  try {
    for (const root of taskRoots(tmpRoot)) {
      let owner;
      try {
        owner = readJson(path.join(root, OWNER_FILE));
      } catch {
        continue;
      }
      const taskId = owner.taskId;
      let canonicalRoot;
      try {
        canonicalRoot = validateBrowserRoot(taskId, root, owner.ownerHome);
      } catch {
        continue;
      }
      activeRootLocks.push(await acquireLock(canonicalRoot));
    }

    const protectedPids = protectedTaskPids(tmpRoot);
    let rows = processInventory();
    for (const row of rows) {
      if (protectedPids.has(row.pid) || !isLegacyBridge(row)) continue;
      if (await terminateLegacyBridgeTree(row.pid)) bridgesReaped += 1;
    }
    rows = processInventory();
    browsersReaped += await terminateLegacyBrowsers(
      rows.filter((row) => !protectedPids.has(row.pid)),
    );
    profilesReaped = removeLegacyProfiles(tmpRoot);
  } finally {
    for (const lock of activeRootLocks.reverse()) {
      releaseLock(lock);
    }
  }

  if (taskRootsReaped || bridgesReaped || browsersReaped || profilesReaped) {
    process.stdout.write(
      `BROWSER_GC: reaped task_roots=${taskRootsReaped} bridges=${bridgesReaped} browser_processes=${browsersReaped} profiles=${profilesReaped}\n`,
    );
  }
}

function commandClassify(args) {
  if (args.length !== 1) fail("usage: classify <ps-inventory-file>");
  const rows = parseInventory(readFileSync(args[0], "utf8"));
  for (const row of rows) {
    process.stdout.write(`${row.pid}\t${classifyRow(row)}\n`);
  }
}

async function main() {
  const [command, ...args] = process.argv.slice(2);
  switch (command) {
    case "prepare":
      await commandPrepare(args);
      break;
    case "sentinel":
      await commandSentinel(args);
      break;
    case "root":
      if (args.length !== 2) fail("usage: root <task-id> <owner-home>");
      process.stdout.write(`${expectedBrowserRoot(validateTaskId(args[0]), args[1])}\n`);
      break;
    case "run":
      await commandRun(args);
      break;
    case "reap":
      await commandReap(args);
      break;
    case "sweep":
      await commandSweep(args);
      break;
    case "classify":
      commandClassify(args);
      break;
    default:
      fail("usage: fm-browser-isolation.mjs <prepare|root|run|reap|sweep|classify> ...");
  }
}

main().catch((error) => {
  process.stderr.write(`error: ${error.message}\n`);
  process.exitCode = 1;
});
