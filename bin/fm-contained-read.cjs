#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

function fail(message) {
  throw new Error(message);
}

function identity(stat) {
  return `${stat.dev}:${stat.ino}`;
}

function fileIdentity(stat) {
  return `${identity(stat)}:${stat.size}:${stat.mtimeNs}:${stat.ctimeNs}`;
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
  let fileFd;
  try {
    const openedRoot = fs.fstatSync(rootFd, { bigint: true });
    if (!openedRoot.isDirectory() || identity(openedRoot) !== rootIdentity) fail("opened root identity differs");
    inspectRoot(root, rootIdentity, rootReal);

    const fileReal = fs.realpathSync(file);
    if (fileReal !== rootReal && !fileReal.startsWith(`${rootReal}${path.sep}`)) fail("source escapes its root");
    const before = fs.lstatSync(file, { bigint: true });
    if (!before.isFile() || before.isSymbolicLink()) fail("source is not a real regular file");
    if (before.size > BigInt(maximum)) fail(`source exceeds ${maximum} bytes`);

    inspectRoot(root, rootIdentity, rootReal);
    fileFd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    const opened = fs.fstatSync(fileFd, { bigint: true });
    if (!opened.isFile() || fileIdentity(opened) !== fileIdentity(before)) fail("source identity changed while opening");
    inspectRoot(root, rootIdentity, rootReal);
    if (fs.realpathSync(file) !== fileReal) fail("source containment changed while opening");
    const afterOpen = fs.lstatSync(file, { bigint: true });
    if (fileIdentity(afterOpen) !== fileIdentity(opened)) fail("source path changed while opening");

    const content = Buffer.alloc(Number(opened.size));
    let offset = 0;
    while (offset < content.length) {
      const count = fs.readSync(fileFd, content, offset, content.length - offset, offset);
      if (count === 0) fail("source ended before its recorded size");
      offset += count;
    }
    const afterRead = fs.fstatSync(fileFd, { bigint: true });
    if (fileIdentity(afterRead) !== fileIdentity(opened)) fail("source changed while reading");
    inspectRoot(root, rootIdentity, rootReal);
    if (fs.realpathSync(file) !== fileReal) fail("source containment changed while reading");
    const finalPath = fs.lstatSync(file, { bigint: true });
    if (fileIdentity(finalPath) !== fileIdentity(opened)) fail("source path changed while reading");
    process.stdout.write(content);
  } finally {
    if (fileFd !== undefined) fs.closeSync(fileFd);
    fs.closeSync(rootFd);
  }
}

try {
  main();
} catch (error) {
  console.error(`error: contained read failed: ${error.message}`);
  process.exitCode = 1;
}
