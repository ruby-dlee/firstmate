const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

function sameIdentity(left, right) {
  return left.dev === right.dev && left.ino === right.ino;
}

function sameSnapshot(left, right) {
  return sameIdentity(left, right) && left.size === right.size
    && left.mtimeNs === right.mtimeNs && left.ctimeNs === right.ctimeNs;
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
      source = fs.openSync(fileName, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
      sourceIdentity = fs.fstatSync(source, { bigint: true });
      if (!sourceIdentity.isFile()) throw new Error("task file is not a regular file");
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
    try {
      fs.writeFileSync(destination, replacement);
      fs.fchmodSync(destination, mode);
      fs.fsyncSync(destination);
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
    } else if (fs.existsSync(fileName) || fs.lstatSync(fileName, { throwIfNoEntry: false })) {
      throw new Error("task file appeared during transaction");
    }
    fs.renameSync(staged, fileName);
    staged = undefined;
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
