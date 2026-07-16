#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

function fail(message) {
  throw new Error(message);
}

function identity(stat) {
  return `${stat.dev}:${stat.ino}`;
}

function inspectRoot(root, expectedIdentity, expectedReal) {
  const stat = fs.lstatSync(root, { bigint: true });
  if (!stat.isDirectory() || stat.isSymbolicLink()) fail("root is not a real directory");
  if (identity(stat) !== expectedIdentity) fail("root identity changed");
  if (fs.realpathSync(root) !== expectedReal) fail("root containment changed");
}

function main() {
  const root = path.resolve(process.argv[2] || "");
  const file = path.resolve(process.argv[3] || "");
  const maximum = Number(process.argv[4]);
  if (!root || !file || !Number.isSafeInteger(maximum) || maximum < 0) fail("usage: fm-contained-read.cjs <root> <file> <maximum-bytes>");

  const rootStat = fs.lstatSync(root, { bigint: true });
  if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) fail("root is not a real directory");
  const rootReal = fs.realpathSync(root);
  const rootIdentity = identity(rootStat);
  const rootFd = fs.openSync(root, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW);
  try {
    const openedRoot = fs.fstatSync(rootFd, { bigint: true });
    if (!openedRoot.isDirectory() || identity(openedRoot) !== rootIdentity) fail("opened root identity differs");
    inspectRoot(root, rootIdentity, rootReal);
    const relative = path.relative(root, file);
    if (!relative || relative === ".." || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) fail("source escapes its root");
    const helper = path.join(__dirname, "fm-contained-read.py");
    const framed = execFileSync("python3", [helper, "read-fd", relative, String(maximum), "strict"], {
      encoding: null,
      maxBuffer: maximum + 1024 * 1024,
      stdio: ["ignore", "pipe", "pipe", rootFd],
    });
    const newline = framed.indexOf(10);
    if (newline < 0) fail("contained reader returned an invalid response");
    const header = JSON.parse(framed.subarray(0, newline).toString("utf8"));
    const source = header.items?.[0];
    if (!source || source.missing) fail("source is missing");
    if (source.oversized) fail(`source exceeds ${maximum} bytes`);
    const content = framed.subarray(newline + 1);
    if (content.length !== source.bytes) fail("contained reader returned an incomplete response");
    inspectRoot(root, rootIdentity, rootReal);
    process.stdout.write(content);
  } finally {
    fs.closeSync(rootFd);
  }
}

try {
  main();
} catch (error) {
  console.error(`error: contained read failed: ${error.message}`);
  process.exitCode = 1;
}
