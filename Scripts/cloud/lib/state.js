// Protocol-file plumbing for the cloud poller: safe ids, atomic writes, and
// prefix-scoped reconciliation of ~/.agentbar/state.d/cloud-<vendor>-*.json.
// Pure helpers up top; the fs edge lives in the exported functions below.

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

// Same rules as docs/protocol.md: sanitized [A-Za-z0-9_.-], max 64 chars. A too-long
// id keeps its head plus a hash of the whole, so it stays stable *and* unique.
const safeId = (s) => {
  const clean = String(s || "").replace(/[^A-Za-z0-9_.-]/g, "-");
  if (!clean) return "unknown";
  if (clean.length <= 64) return clean;
  const hash = crypto.createHash("sha256").update(String(s)).digest("hex").slice(0, 8);
  return `${clean.slice(0, 55)}-${hash}`;
};

// Never end a cut on a lone high surrogate: Swift's JSONSerialization rejects the
// file, which hides the session from every frontend. (Same guard as the hooks.)
const sliceSafe = (s, n) => {
  const cut = String(s).slice(0, n);
  const last = cut.charCodeAt(cut.length - 1);
  return last >= 0xd800 && last <= 0xdbff ? cut.slice(0, -1) : cut;
};
const oneLine = (s, n) => sliceSafe(String(s || "").replace(/\s+/g, " ").trim(), n);

const fileFor = (stateDir, id) => path.join(stateDir, `${id}.json`);

// Atomic per protocol: <file>.<pid>.tmp -> rename. The tmp name is not *.json,
// so the app's directory watch never parses a half-written file.
const writeRow = (stateDir, row) => {
  const file = fileFor(stateDir, row.sessionId);
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(row));
  fs.renameSync(tmp, file);
};

const readRow = (stateDir, id) => {
  try {
    return JSON.parse(fs.readFileSync(fileFor(stateDir, id), "utf8"));
  } catch {
    return null;
  }
};

// Every session id currently on disk for one vendor prefix ("cloud-devin-").
const listIds = (stateDir, prefix) => {
  let names;
  try {
    names = fs.readdirSync(stateDir);
  } catch {
    return [];
  }
  return names
    .filter((n) => n.startsWith(prefix) && n.endsWith(".json"))
    .map((n) => n.slice(0, -".json".length));
};

// Delete this vendor's rows that a fresh successful poll no longer contains.
// Prefix-scoped on purpose: one vendor's outage must never touch another's rows.
const reconcile = (stateDir, prefix, keepIds) => {
  const keep = new Set(keepIds);
  for (const id of listIds(stateDir, prefix)) {
    if (!keep.has(id)) {
      try { fs.unlinkSync(fileFor(stateDir, id)); } catch {}
    }
  }
};

module.exports = { safeId, oneLine, writeRow, readRow, listIds, reconcile };
