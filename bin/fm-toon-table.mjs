#!/usr/bin/env node
// Select fields from one TOON tabular or object-list array on stdin and validate
// its declared row count.
// Usage: fm-toon-table.mjs <field> [field...]

import fs from "node:fs";

const args = process.argv.slice(2);
let arrayName = null;
if (args[0] === "--array") {
  args.shift();
  arrayName = args.shift();
}
const wanted = args;
if (wanted.length === 0) process.exit(2);
const lines = fs.readFileSync(0, "utf8").split(/\r?\n/);
const headerPattern = arrayName === null
  ? /^(?:[A-Za-z0-9_]+)?\[\d+\](?:\{[^}]+\})?:(?: \[\])?$/
  : new RegExp(`^${arrayName}\\[\\d+\\](?:\\{[^}]+\\})?:(?: \\[\\])?$`);
const headerIndex = lines.findIndex((line) => headerPattern.test(line.trim()));
if (headerIndex < 0) {
  if (lines.some((line) => /^(?:[A-Za-z0-9_]+: *)?\[\]$/.test(line.trim()))) process.exit(0);
  console.error("error: TOON table header not found");
  process.exit(2);
}
const header = lines[headerIndex];
const match = header.trim().match(/^(?:[A-Za-z0-9_]+)?\[(\d+)\](?:\{([^}]+)\})?:(?: \[\])?$/);
const expected = Number.parseInt(match[1], 10);
const fields = match[2]?.split(",") ?? [];
const indexes = wanted.map((field) => fields.indexOf(field));
if (fields.length > 0 && indexes.some((index) => index < 0)) {
  console.error(`error: TOON table lacks required fields: ${wanted.filter((_, i) => indexes[i] < 0).join(",")}`);
  process.exit(2);
}

function parseRow(line) {
  const cells = [];
  let cell = "";
  let quoted = false;
  let escaped = false;
  for (const char of line.trimStart()) {
    if (escaped) {
      cell += char === "n" ? "\n" : char === "t" ? "\t" : char;
      escaped = false;
    } else if (quoted && char === "\\") escaped = true;
    else if (char === '"') quoted = !quoted;
    else if (char === "," && !quoted) { cells.push(cell); cell = ""; }
    else cell += char;
  }
  if (quoted || escaped) throw new Error("unterminated quoted cell");
  cells.push(cell);
  return cells;
}

if (fields.length > 0) {
  const rowIndent = header.match(/^ */)[0].length + 2;
  const rows = lines.slice(headerIndex + 1).filter((line) => line.match(/^ */)[0].length === rowIndent && line.trim() !== "");
  if (rows.length !== expected) {
    console.error(`error: TOON row count mismatch: header=${expected} rows=${rows.length}`);
    process.exit(2);
  }
  for (const row of rows) {
    const cells = parseRow(row);
    if (cells.length !== fields.length) {
      console.error(`error: TOON field count mismatch: header=${fields.length} row=${cells.length}`);
      process.exit(2);
    }
    console.log(indexes.map((index) => cells[index].replace(/[\t\n]/g, " ")).join("\t"));
  }
  process.exit(0);
}

const headerIndent = header.match(/^ */)[0].length;
const rowIndent = headerIndent + 2;
const fieldIndent = headerIndent + 4;
const rows = [];
let row = null;

function decodeScalar(value) {
  const trimmed = value.trim();
  if (trimmed.startsWith('"')) {
    try { return JSON.parse(trimmed); } catch { throw new Error("invalid quoted scalar"); }
  }
  return trimmed;
}

if (wanted.length === 1 && wanted[0] === "value") {
  const scalarRows = [];
  for (let i = headerIndex + 1; i < lines.length; i += 1) {
    const line = lines[i];
    if (line.trim() === "") continue;
    const indent = line.match(/^ */)[0].length;
    if (indent <= headerIndent) break;
    if (indent === rowIndent && line.slice(indent).startsWith("- ")) scalarRows.push(line);
  }
  if (scalarRows.length !== expected) {
    console.error(`error: TOON scalar row count mismatch: header=${expected} rows=${scalarRows.length}`);
    process.exit(2);
  }
  try {
    for (const scalarRow of scalarRows) console.log(String(decodeScalar(scalarRow.trimStart().slice(2))).replace(/[\t\n]/g, " "));
  } catch (error) {
    console.error(`error: TOON scalar-list parse failed: ${error.message}`);
    process.exit(2);
  }
  process.exit(0);
}

function assignField(target, text, prefix = "") {
  const fieldMatch = text.match(/^([A-Za-z0-9_]+):(?: +(.*))?$/);
  if (!fieldMatch) return null;
  const field = prefix ? `${prefix}.${fieldMatch[1]}` : fieldMatch[1];
  if (fieldMatch[2] === undefined || fieldMatch[2] === "") {
    if (wanted.some((name) => name.startsWith(`${field}.`))) return field;
    if (!wanted.includes(field)) return null;
    throw new Error(`required field ${field} is nested or empty`);
  }
  if (!wanted.includes(field)) return null;
  target[field] = decodeScalar(fieldMatch[2]);
  return null;
}

try {
  let nestedPrefix = null;
  for (let i = headerIndex + 1; i < lines.length; i += 1) {
    const line = lines[i];
    if (line.trim() === "") continue;
    const indent = line.match(/^ */)[0].length;
    if (indent <= headerIndent) break;
    if (indent === rowIndent && line.slice(indent).startsWith("- ")) {
      if (row !== null) rows.push(row);
      row = {};
      nestedPrefix = assignField(row, line.slice(indent + 2));
    } else if (row !== null && indent === fieldIndent) {
      nestedPrefix = assignField(row, line.slice(indent));
    } else if (row !== null && indent === fieldIndent + 2 && nestedPrefix !== null) {
      assignField(row, line.slice(indent), nestedPrefix);
    }
  }
  if (row !== null) rows.push(row);
} catch (error) {
  console.error(`error: TOON object-list parse failed: ${error.message}`);
  process.exit(2);
}

if (rows.length !== expected) {
  console.error(`error: TOON row count mismatch: header=${expected} rows=${rows.length}`);
  process.exit(2);
}
for (const object of rows) {
  const missing = wanted.filter((field) => !(field in object));
  if (missing.length > 0) {
    console.error(`error: TOON object row lacks required fields: ${missing.join(",")}`);
    process.exit(2);
  }
  console.log(wanted.map((field) => String(object[field]).replace(/[\t\n]/g, " ")).join("\t"));
}
