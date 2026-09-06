// Which normalized runs become rows, and how they map onto the state.d schema.
// Pure functions: the poller loop feeds them the clock and its pid.

const { safeId, oneLine } = require("./state");

// A run's protocol lifetime, by state:
// - thinking: always shown — an actively working run is never too old;
// - done/error: retentionMinutes since the vendor's last update, then gone;
// - question/idle (blocked, suspended): recentHours — needs-you rows matter,
//   but a session ignored for days is clutter, not a prompt.
const keepRow = (run, cfg, now) => {
  if (!run.state) return false;
  const age = now - (run.updated_at || now);
  switch (run.state) {
    case "thinking": return true;
    case "done":     return age < (cfg.retentionMinutes.done || 60) * 60;
    case "error":    return age < (cfg.retentionMinutes.error || 240) * 60;
    default:         return age < (run.recentHours || 48) * 3600;
  }
};

const isTerminal = (state) => state === "done" || state === "error";

// States whose ts pins to the vendor's last update instead of "now": terminal
// runs must age out rather than stay eternally fresh, and a resting (idle,
// e.g. suspended) run's ts should say when it last actually worked — that is
// what frontends sort finished rows by, and a frozen row also skips its
// pointless 30s rewrite. Note the protocol's 24h ts expiry therefore caps how
// long idle rows can linger, whatever suspendedHours says. Active (thinking /
// question) rows keep a fresh ts so they can never expire mid-run.
const tsFrozen = (state) => isTerminal(state) || state === "idle";

// Assemble the state.d row. cwd stays empty (no local checkout — a non-empty cwd
// would advertise the wrong git branch) and pid is the poller's own, so the rows
// die with the poller.
const toProtocolRow = (run, { agentId, prefix }, now, pid) => ({
  agent: agentId,
  state: run.state,
  label: oneLine(run.label, 80),
  project: oneLine(run.project, 40),
  cwd: "",
  sessionId: safeId(prefix + run.id),
  entrypoint: "cloud",
  term_program: "",
  pid,
  started: true,
  ts: tsFrozen(run.state) ? Math.min(run.updated_at || now, now) : now,
  ...(run.started_at ? { started_at: run.started_at } : {}),
  ...(run.prompt ? { prompt: oneLine(run.prompt, 120) } : {}),
  ...(run.recap ? { recap: oneLine(run.recap, 160) } : {}),
  url: String(run.url || ""),
});

// Timestamp -> unix seconds; 0 when unparseable (callers treat 0 as unknown).
// Accepts ISO strings (Cursor, Devin v1) and numeric seconds or milliseconds,
// as numbers or strings (Devin v3 returns "1787641783").
const epoch = (t) => {
  if (t == null || t === "") return 0;
  const n = Number(t);
  if (Number.isFinite(n) && /^\s*\d+(\.\d+)?\s*$/.test(String(t))) {
    return Math.floor(n > 1e12 ? n / 1000 : n);
  }
  const ms = Date.parse(t);
  return Number.isFinite(ms) ? Math.floor(ms / 1000) : 0;
};

module.exports = { keepRow, toProtocolRow, isTerminal, epoch };
