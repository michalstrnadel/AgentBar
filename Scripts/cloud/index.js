#!/usr/bin/env node
// agentbar-cloud: polls cloud coding-agent vendors and mirrors their runs into
// ~/.agentbar/state.d/ as protocol rows (entrypoint "cloud", url, this process's
// pid). The menu bar app needs no wiring beyond the protocol — rows appear like
// any other session and die with this poller. Usage: index.js [--once]
//
// Lifecycle rules (see docs/protocol.md):
// - after each *successful* vendor poll, that vendor's on-disk rows are
//   reconciled to exactly the fresh set — vanished runs disappear;
// - a vendor that keeps failing gets its rows dropped and one clickable
//   "<vendor>: auth failed" row instead; other vendors are never touched;
// - SIGTERM/SIGINT deletes our rows on the way out (the app would reap them
//   from the dead pid anyway — this just makes it immediate).

const fs = require("fs");
const os = require("os");
const path = require("path");

const config = require("./lib/config");
const { writeRow, readRow, reconcile } = require("./lib/state");
const { keepRow, toProtocolRow } = require("./lib/policy");

const ADAPTERS = [
  require("./adapters/cursor"),
  require("./adapters/devin"),
  require("./adapters/codex"),
];

const MAX_FAILURES = 10; // ~5 min at the default cadence before rows are declared stale
const FIX_URLS = {
  cursor: "https://cursor.com/dashboard",
  devin: "https://app.devin.ai/settings",
  codex: "https://chatgpt.com/codex",
};
const FIX_LABELS = {
  cursor: "Cursor: check API key (cloud.json)",
  devin: "Devin: check API key (cloud.json)",
  codex: "Codex: run `codex login`",
};

const stateDir = path.join(os.homedir(), ".agentbar", "state.d");
const log = (msg) => console.error(`[${new Date().toISOString()}] ${msg}`);

const now = () => Math.floor(Date.now() / 1000);

const pollVendor = async (v) => {
  const cfg = v.cfg;
  const raw = await v.adapter.fetchRaw(cfg);
  const { rows, warnings } = v.adapter.normalize(raw, cfg, now());
  for (const w of warnings) if (!v.warned.has(w)) { v.warned.add(w); log(`${v.adapter.vendor}: ${w}`); }

  const t = now();
  // Vendor default first, so an adapter's per-row recentHours (e.g. Devin's
  // shorter suspended window) survives the merge.
  const kept = rows.filter((r) => keepRow({ recentHours: cfg.recentHours, ...r }, v.global, t));
  const written = [];
  for (const r of kept) {
    const row = toProtocolRow(r, v.adapter, t, process.pid);
    written.push(row.sessionId);
    // Terminal rows freeze (ts pinned to the vendor's update): skip identical
    // rewrites so the app's directory watch isn't churned for nothing. Active
    // rows always differ (ts = now) and get their freshness write.
    const prev = readRow(stateDir, row.sessionId);
    if (prev && JSON.stringify(prev) === JSON.stringify(row)) continue;
    writeRow(stateDir, row);
  }
  reconcile(stateDir, v.adapter.prefix, written);
  if (v.failures > 0) log(`${v.adapter.vendor}: recovered`);
  v.failures = 0;
};

const failVendor = (v, err) => {
  v.failures += 1;
  if (v.failures === 1 || v.failures === MAX_FAILURES) log(`${err.message} (failure ${v.failures})`);
  if (v.failures < MAX_FAILURES || !v.global.syntheticErrorRow) return;
  // Persistent: last-good rows are stale enough to mislead — replace them with
  // one row that says what's broken and opens where to fix it.
  const vendor = v.adapter.vendor;
  const errorRow = toProtocolRow({
    id: "auth",
    state: "error",
    label: FIX_LABELS[vendor] || `${vendor}: polling failed`,
    project: vendor[0].toUpperCase() + vendor.slice(1),
    url: FIX_URLS[vendor] || "",
    updated_at: now(),
  }, v.adapter, now(), process.pid);
  reconcile(stateDir, v.adapter.prefix, [errorRow.sessionId]);
  writeRow(stateDir, errorRow);
};

const main = async () => {
  const cfg = config.load();
  fs.mkdirSync(stateDir, { recursive: true });

  const vendors = ADAPTERS.map((adapter) => ({
    adapter,
    cfg: cfg[adapter.vendor],
    global: cfg,
    everySeconds: cfg[adapter.vendor].pollSeconds || cfg.pollSeconds,
    due: 0, // poll immediately on start (also covers the restart flicker window)
    busy: false,
    failures: 0,
    warned: new Set(),
  }));

  // A key-based vendor without a key can only fail — treat it as disabled
  // rather than burning its failure budget into a misleading error row.
  for (const v of vendors) {
    if (v.cfg.enabled && "apiKey" in v.cfg && !v.cfg.apiKey) {
      log(`${v.adapter.vendor}: no API key in ~/.agentbar/cloud.json — skipping`);
      v.cfg.enabled = false;
    }
  }
  // Rows of a vendor the user disabled must not linger until the 24h expiry.
  for (const v of vendors) {
    if (!v.cfg.enabled) reconcile(stateDir, v.adapter.prefix, []);
  }
  const enabled = vendors.filter((v) => v.cfg.enabled);
  if (enabled.length === 0) {
    log("no vendors enabled in ~/.agentbar/cloud.json — nothing to do");
    return;
  }
  log(`polling ${enabled.map((v) => v.adapter.vendor).join(", ")} (pid ${process.pid})`);

  const tick = async () => {
    const t = now();
    for (const v of enabled) {
      if (v.busy || t < v.due) continue;
      v.busy = true;
      v.due = t + v.everySeconds;
      try {
        await pollVendor(v);
      } catch (e) {
        failVendor(v, e);
      } finally {
        v.busy = false;
      }
    }
  };

  await tick();
  if (process.argv.includes("--once")) return;

  setInterval(tick, 5000);

  const cleanup = () => {
    for (const v of enabled) reconcile(stateDir, v.adapter.prefix, []);
    process.exit(0);
  };
  process.on("SIGTERM", cleanup);
  process.on("SIGINT", cleanup);
};

main().catch((e) => {
  log(`fatal: ${e.stack || e.message}`);
  process.exit(1);
});
