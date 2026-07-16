const crypto = require("node:crypto");
const childProcess = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

function sameIdentity(left, right) {
  return left.dev === right.dev && left.ino === right.ino;
}

function sameSnapshot(left, right) {
  return sameIdentity(left, right) && left.size === right.size
    && left.mtimeNs === right.mtimeNs && left.ctimeNs === right.ctimeNs;
}

function samePublishedSourceSnapshot(left, right) {
  return sameIdentity(left, right) && left.size === right.size
    && left.mtimeNs === right.mtimeNs && left.mode === right.mode
    && left.uid === right.uid && left.gid === right.gid;
}

function descriptorContentEquals(descriptor, expected) {
  const actual = Buffer.alloc(expected.length);
  let offset = 0;
  while (offset < actual.length) {
    const count = fs.readSync(descriptor, actual, offset, actual.length - offset, offset);
    if (count === 0) break;
    offset += count;
  }
  return offset === expected.length && actual.equals(expected);
}

function identity(stat) {
  return `${stat.dev}:${stat.ino}`;
}

function runContained(directory, command, ...args) {
  const python = process.env.FM_REPORT_PYTHON || "python3";
  const helper = path.join(__dirname, "fm-contained-read.py");
  const result = childProcess.spawnSync(python, [helper, command, ...args], {
    stdio: ["ignore", "pipe", "pipe", directory],
  });
  if (result.status !== 0) {
    throw new Error(result.stderr.toString("utf8").trim() || `contained ${command} failed`);
  }
}

function waitForTestGate() {
  const ready = process.env.FM_FILE_TRANSACTION_TEST_READY;
  const proceed = process.env.FM_FILE_TRANSACTION_TEST_PROCEED;
  if (!ready || !proceed) return;
  fs.writeFileSync(ready, "ready\n", { flag: "wx" });
  const deadline = Date.now() + 5000;
  while (!fs.existsSync(proceed)) {
    if (Date.now() >= deadline) throw new Error("file transaction test gate timed out");
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
  }
}

function waitForPublicationTestGate() {
  const ready = process.env.FM_FILE_TRANSACTION_PUBLISH_TEST_READY;
  const proceed = process.env.FM_FILE_TRANSACTION_PUBLISH_TEST_PROCEED;
  if (!ready || !proceed) return;
  fs.writeFileSync(ready, "ready\n", { flag: "wx" });
  const deadline = Date.now() + 5000;
  while (!fs.existsSync(proceed)) {
    if (Date.now() >= deadline) throw new Error("file transaction publication test gate timed out");
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
  }
}

function pinnedTaskFileTransaction(dataDir, taskId, fileName, transform) {
  if (!/^[A-Za-z0-9_][A-Za-z0-9._-]*$/.test(taskId)) throw new Error("invalid task id");
  if (path.basename(fileName) !== fileName || fileName === "." || fileName === "..") {
    throw new Error("invalid task file name");
  }

  const expectedData = fs.realpathSync(dataDir);
  process.chdir(dataDir);
  if (fs.realpathSync(".") !== expectedData) throw new Error("data directory changed before transaction");
  const taskPath = path.join(expectedData, taskId);
  const taskEntry = fs.lstatSync(taskId, { bigint: true });
  if (taskEntry.isSymbolicLink() || !taskEntry.isDirectory()) throw new Error("task directory is not a real directory");
  process.chdir(taskId);
  if (fs.realpathSync(".") !== taskPath) throw new Error("task directory changed before transaction");

  const directory = fs.openSync(".", fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW);
  const directoryIdentity = fs.fstatSync(directory, { bigint: true });
  let source;
  let sourceIdentity;
  let content = Buffer.alloc(0);
  let existed = false;
  let staged;
  try {
    try {
      const entry = fs.lstatSync(fileName, { bigint: true });
      if (entry.isSymbolicLink() || !entry.isFile()) throw new Error("task file is not a regular file");
      source = fs.openSync(fileName,
        fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
      sourceIdentity = fs.fstatSync(source, { bigint: true });
      if (!sourceIdentity.isFile() || !sameIdentity(entry, sourceIdentity)) {
        throw new Error("task file changed while opening");
      }
      content = fs.readFileSync(source);
      existed = true;
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }

    waitForTestGate();
    const output = transform(content, { existed, stat: sourceIdentity });
    if (output === undefined || output === null) return false;
    const replacement = Buffer.isBuffer(output) ? output : Buffer.from(output);
    staged = `.${fileName}.${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
    const mode = sourceIdentity ? Number(sourceIdentity.mode & 0o7777n) : 0o600;
    const destination = fs.openSync(staged,
      fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW,
      mode);
    let replacementIdentity;
    try {
      fs.writeFileSync(destination, replacement);
      fs.fchmodSync(destination, mode);
      fs.fsyncSync(destination);
      replacementIdentity = fs.fstatSync(destination, { bigint: true });
    } finally {
      fs.closeSync(destination);
    }

    const currentTask = fs.lstatSync(taskPath, { bigint: true });
    if (currentTask.isSymbolicLink() || !currentTask.isDirectory()
      || !sameIdentity(directoryIdentity, currentTask)
      || fs.realpathSync(taskPath) !== taskPath) {
      throw new Error("task directory changed during transaction");
    }
    if (source !== undefined) {
      const finalSource = fs.fstatSync(source, { bigint: true });
      const currentFile = fs.lstatSync(fileName, { bigint: true });
      if (!sameSnapshot(sourceIdentity, finalSource) || !sameIdentity(finalSource, currentFile)
        || currentFile.isSymbolicLink() || !currentFile.isFile()) {
        throw new Error("task file changed during transaction");
      }
      waitForPublicationTestGate();
      runContained(directory, "exchange-files-fd", staged, fileName,
        identity(replacementIdentity), identity(sourceIdentity));
      const displaced = fs.lstatSync(staged, { bigint: true });
      const installed = fs.lstatSync(fileName, { bigint: true });
      const postExchangeSource = fs.fstatSync(source, { bigint: true });
      if (!sameIdentity(displaced, sourceIdentity) || !sameIdentity(installed, replacementIdentity)
        || !samePublishedSourceSnapshot(sourceIdentity, postExchangeSource)
        || !descriptorContentEquals(source, content)) {
        try {
          runContained(directory, "exchange-files-fd", staged, fileName,
            identity(displaced), identity(installed));
        } catch {
          staged = undefined;
        }
        throw new Error("task file changed during publication");
      }
      runContained(directory, "remove-owned-file-fd", staged, identity(displaced),
        `.${staged}.retired.${crypto.randomBytes(8).toString("hex")}`);
      staged = undefined;
    } else if (fs.existsSync(fileName) || fs.lstatSync(fileName, { throwIfNoEntry: false })) {
      throw new Error("task file appeared during transaction");
    } else {
      fs.linkSync(staged, fileName);
      fs.unlinkSync(staged);
      staged = undefined;
    }
    fs.fsyncSync(directory);
    return true;
  } finally {
    if (source !== undefined) fs.closeSync(source);
    if (staged !== undefined) {
      try { fs.unlinkSync(staged); } catch {}
    }
    fs.closeSync(directory);
  }
}

module.exports = { pinnedTaskFileTransaction };
