// Poller configuration: ~/.agentbar/cloud.json (chmod 600 — it holds API keys),
// deep-merged over these defaults. API keys may instead come from the environment
// (CURSOR_API_KEY, DEVIN_API_KEY) so the file can stay key-free if preferred.

const fs = require("fs");
const os = require("os");
const path = require("path");

const DEFAULTS = {
  pollSeconds: 30,
  // How long a finished/errored run stays in the menu after its last vendor
  // update. Expired/cancelled/archived runs are dropped immediately.
  retentionMinutes: { done: 60, error: 240 },
  syntheticErrorRow: true, // one clickable "<vendor>: auth failed" row per broken vendor
  // openIn "app" = the vendor's desktop app (cursor:// run deep link; devin://
  // focuses Devin Desktop — no per-session deep link exists); "web" = the
  // thread-precise browser URL.
  cursor: { enabled: true, apiKey: "", openIn: "app", recentHours: 48 },
  devin: { enabled: true, apiKey: "", orgId: "", openIn: "app", recentHours: 48,
           showSuspended: true, suspendedHours: 24 },
  codex: { enabled: true, bin: "codex", pollSeconds: 60, recentHours: 48 },
};

const merge = (base, over) => {
  const out = { ...base };
  for (const [k, v] of Object.entries(over || {})) {
    out[k] = v && typeof v === "object" && !Array.isArray(v) ? merge(base[k] || {}, v) : v;
  }
  return out;
};

const load = () => {
  const file = path.join(os.homedir(), ".agentbar", "cloud.json");
  let user = {};
  try {
    user = JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (e) {
    if (e.code !== "ENOENT") console.error(`cloud.json unreadable, using defaults: ${e.message}`);
  }
  const cfg = merge(DEFAULTS, user);
  cfg.cursor.apiKey = cfg.cursor.apiKey || process.env.CURSOR_API_KEY || "";
  cfg.devin.apiKey = cfg.devin.apiKey || process.env.DEVIN_API_KEY || "";
  return cfg;
};

module.exports = { load, DEFAULTS, merge };
