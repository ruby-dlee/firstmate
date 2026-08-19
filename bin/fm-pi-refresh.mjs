#!/usr/bin/env node
// fm-pi-refresh.mjs - rotate Pi OAuth credentials through Pi's own refresh and
// its own credential lock.
//
// Usage:
//   fm-pi-refresh.mjs --pi-root <dir> --pool <auth.json> --slot <name> [--slot <name>...]
//                     [--timeout-ms <n>]
//
// This is the actuator half of `bin/fm-pi-refresh.py`, which owns selection,
// backup, re-projection, and the operator contract. This file owns exactly one
// thing: performing the rotation the way Pi itself performs it.
//
// Why Node rather than a Python HTTP call: the rotation has two halves and only
// one of them is the HTTP request. The other is the write-back, which must land
// under the same lock Pi takes, or a running Pi overwrites it. Pi's lock is
// `proper-lockfile` on the credential path, held across the refresh so a
// concurrent refresher cannot burn the same refresh token twice. Reimplementing
// that protocol in another language would be re-deriving an interop contract;
// calling Pi's own `AuthStorage` uses it. `~/.pi/agent/fm-patches/reauth.sh` is
// the prior art that writes the pool WITHOUT the lock, and its own header warns
// that a running Pi may overwrite what it writes. This does not have that flaw.
//
// The two modules are imported by absolute path because Pi's package `exports`
// map publishes neither: `@earendil-works/pi-coding-agent/dist/core/...` is
// refused with ERR_PACKAGE_PATH_NOT_EXPORTED, and `@earendil-works/pi-ai` is a
// nested dependency that does not resolve as a bare specifier at all. The
// package barrel is not an option either: it exports `ModelRuntime` but not
// `AuthStorage`, and importing it pulls in the whole TUI.
//
// Output is one JSON record per slot on stdout, diagnostics on stderr. No token
// value is ever emitted: accounts and tokens appear only as truncated digests.

import { createHash } from "node:crypto";
import { statSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { join } from "node:path";

// A rotation is one HTTPS round trip. Pi itself allows 15s; this is a little
// wider because it runs unattended and a retry costs a whole scheduled cycle.
const DEFAULT_TIMEOUT_MS = 20_000;

// Digest prefix length. Long enough that two accounts in one fleet cannot
// collide in practice, short enough that it is obviously not a token.
const DIGEST_CHARACTERS = 12;

// Anything longer than this in the base64url alphabet is treated as token
// material and redacted out of an error message. Pi's own refresh error text
// interpolates the provider's JSON response, and one failure mode of that
// response is "carries an access_token but no expires_in" - so the error path
// is a real leak path, not a theoretical one.
const TOKEN_LIKE = /[A-Za-z0-9_-]{40,}/g;
const MAX_ERROR_CHARACTERS = 300;

class RefreshError extends Error {}

function fail(message) {
  throw new RefreshError(message);
}

export function digest(value) {
  if (typeof value !== "string" || value.trim() === "") return "none";
  return createHash("sha256").update(value).digest("hex").slice(0, DIGEST_CHARACTERS);
}

export function instant(milliseconds) {
  if (typeof milliseconds !== "number" || !Number.isFinite(milliseconds)) return null;
  return new Date(milliseconds).toISOString();
}

/** Strip token-shaped runs out of a provider error before it is reported. */
export function safeErrorText(error) {
  const raw = error instanceof Error ? error.message : String(error);
  return raw.replace(TOKEN_LIKE, "[redacted]").slice(0, MAX_ERROR_CHARACTERS);
}

/**
 * Load Pi's credential store and its OpenAI Codex OAuth flow from one install.
 *
 * Both paths are asserted before import so a moved or upgraded Pi produces an
 * operator sentence naming the file, rather than a Node module-resolution
 * stack trace.
 */
export async function loadPiModules(piRoot) {
  const storeModule = join(piRoot, "dist/core/auth-storage.js");
  const oauthModule = join(
    piRoot,
    "node_modules/@earendil-works/pi-ai/dist/auth/oauth/openai-codex.js",
  );
  for (const path of [storeModule, oauthModule]) {
    try {
      if (!statSync(path).isFile()) fail(`Pi module is not a regular file at ${path}`);
    } catch (error) {
      if (error instanceof RefreshError) throw error;
      fail(
        `Pi install at ${piRoot} does not carry ${path}; this Pi version moved or ` +
          "renamed the module this refresher drives",
      );
    }
  }
  const { AuthStorage } = await import(pathToFileURL(storeModule).href);
  const { openaiCodexOAuth } = await import(pathToFileURL(oauthModule).href);
  if (typeof AuthStorage?.create !== "function") {
    fail(`Pi credential store at ${storeModule} exposes no AuthStorage.create`);
  }
  if (typeof openaiCodexOAuth?.refresh !== "function") {
    fail(`Pi OAuth flow at ${oauthModule} exposes no openaiCodexOAuth.refresh`);
  }
  return { storeFactory: (path) => AuthStorage.create(path), oauth: openaiCodexOAuth };
}

/**
 * Rotate each named slot in place, one at a time.
 *
 * Sequential on purpose: Pi's store serializes on one lock per credential file,
 * so concurrent slots would queue on that lock anyway while each held an open
 * HTTPS request against the same deadline.
 *
 * The refresh runs INSIDE `modify`, which is where Pi runs its own, because
 * that is what makes the read, the rotation, and the write one critical
 * section. Refreshing outside the lock and writing after would let two
 * refreshers spend the same refresh token, and a rotating provider invalidates
 * the loser.
 */
export async function refreshSlots({ storeFactory, oauth, poolPath, slots, timeoutMs }) {
  const store = storeFactory(poolPath);
  const deadline = typeof timeoutMs === "number" ? timeoutMs : DEFAULT_TIMEOUT_MS;
  const records = [];
  for (const slot of slots) {
    const before = await store.read(slot);
    if (!before) {
      records.push({ slot, outcome: "absent", detail: `no credential stored under ${slot}` });
      continue;
    }
    if (before.type !== "oauth") {
      records.push({
        slot,
        outcome: "not-oauth",
        detail: `credential under ${slot} is ${before.type}, which has no refresh`,
      });
      continue;
    }
    let after;
    try {
      after = await store.modify(slot, async (current) => {
        // Re-read under the lock. A slot that stopped being an OAuth credential
        // between the optimistic read and the lock was logged out or replaced,
        // and returning undefined leaves it exactly as the other writer left it.
        if (current?.type !== "oauth") return undefined;
        return await oauth.refresh(current, AbortSignal.timeout(deadline));
      });
    } catch (error) {
      records.push({ slot, outcome: "failed", detail: safeErrorText(error) });
      continue;
    }
    if (after?.type !== "oauth") {
      records.push({
        slot,
        outcome: "not-oauth",
        detail: `credential under ${slot} stopped being an oauth credential during refresh`,
      });
      continue;
    }
    // `modify` returns the stored credential unchanged when its callback
    // returns undefined, so a rotation cannot be inferred from a truthy
    // result. Only a changed access token proves one happened.
    const rotated = digest(before.access) !== digest(after.access);
    records.push({
      slot,
      outcome: rotated ? "refreshed" : "unchanged",
      account: digest(after.accountId),
      account_stable: digest(before.accountId) === digest(after.accountId),
      access_rotated: rotated,
      refresh_rotated: digest(before.refresh) !== digest(after.refresh),
      expires_before: instant(before.expires),
      expires_after: instant(after.expires),
    });
  }
  return records;
}

function parseArguments(argv) {
  const options = { slots: [], timeoutMs: DEFAULT_TIMEOUT_MS };
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    const value = argv[index + 1];
    switch (flag) {
      case "--pi-root":
        options.piRoot = value;
        index += 1;
        break;
      case "--pool":
        options.poolPath = value;
        index += 1;
        break;
      case "--slot":
        if (value === undefined) fail("--slot needs a slot name");
        options.slots.push(value);
        index += 1;
        break;
      case "--timeout-ms":
        options.timeoutMs = Number(value);
        index += 1;
        break;
      default:
        fail(`unknown argument ${flag}`);
    }
  }
  if (!options.piRoot) fail("--pi-root is required");
  if (!options.poolPath) fail("--pool is required");
  if (options.slots.length === 0) fail("name at least one --slot");
  if (!Number.isFinite(options.timeoutMs) || options.timeoutMs <= 0) {
    fail("--timeout-ms must be a positive number of milliseconds");
  }
  return options;
}

export async function main(argv) {
  const options = parseArguments(argv);
  const { storeFactory, oauth } = await loadPiModules(options.piRoot);
  const records = await refreshSlots({
    storeFactory,
    oauth,
    poolPath: options.poolPath,
    slots: options.slots,
    timeoutMs: options.timeoutMs,
  });
  for (const record of records) process.stdout.write(JSON.stringify(record) + "\n");
  return records.every((record) => record.outcome === "refreshed") ? 0 : 1;
}

// `import.meta.main` is not available on every Node this repo runs on, so the
// entrypoint check compares the resolved argv path instead.
if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  try {
    process.exitCode = await main(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`PI REFRESH ADAPTER REFUSED: ${safeErrorText(error)}\n`);
    process.exitCode = 2;
  }
}
