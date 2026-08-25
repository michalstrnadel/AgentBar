// Cursor cloud agents -> normalized runs.
// API: https://cursor.com/docs/cloud-agent/api/endpoints — GET /v1/agents lists
// the account's agents (lifecycle status only); the live status of the work is
// on the latest *run*. v0 (legacy) carries the run status on the agent itself;
// `apiVersion: "v0"` in cloud.json switches to it if v1 listing proves lacking.

const { epoch } = require("../lib/policy");

const vendor = "cursor";
const agentId = "cursor";
const prefix = "cloud-cursor-";

const RUN_STATES = {
  CREATING: "thinking", PENDING: "thinking", QUEUED: "thinking", RUNNING: "thinking",
  FINISHED: "done", COMPLETED: "done",
  ERROR: "error", FAILED: "error",
  CANCELLED: null, EXPIRED: null, ARCHIVED: null,
};
const terminalStatus = (s) => ["done", "error", null].includes(RUN_STATES[String(s || "").toUpperCase()]);

const get = async (url, apiKey) => {
  const res = await fetch(url, { headers: { Authorization: `Bearer ${apiKey}` } });
  if (!res.ok) throw new Error(`cursor ${new URL(url).pathname}: HTTP ${res.status}`);
  return res.json();
};

// agentId -> { latestRunId, run }: a run that reached a terminal status never
// changes again, so it is fetched once. Keeps the poll at 1 list call + one
// call per still-moving run.
const runCache = new Map();
// Agents whose run fetch already failed once — logged once, not every 30s.
const warnedAgents = new Set();

const fetchRaw = async (cfg) => {
  const base = "https://api.cursor.com";
  if (cfg.apiVersion === "v0") {
    const r = await get(`${base}/v0/agents?limit=40`, cfg.apiKey);
    return { agents: r.agents || r.items || [], runs: {} };
  }
  const agents = [];
  let cursor = "";
  for (let page = 0; page < 2; page++) {
    const u = new URL(`${base}/v1/agents`);
    u.searchParams.set("limit", "40");
    if (cursor) u.searchParams.set("cursor", cursor);
    const r = await get(u.toString(), cfg.apiKey);
    agents.push(...(r.agents || r.items || []));
    cursor = r.nextCursor || "";
    if (!cursor) break;
  }
  const runs = {};
  for (const a of agents) {
    if (String(a.status || "").toUpperCase() === "ARCHIVED" || !a.latestRunId) continue;
    const cached = runCache.get(a.id);
    if (cached && cached.latestRunId === a.latestRunId && terminalStatus(cached.run.status)) {
      runs[a.id] = cached.run;
      continue;
    }
    // The runs LIST is the working endpoint (newest first); run-by-id 404s in
    // practice despite being documented. Best-effort per agent: one broken
    // agent must not blank the whole vendor's rows.
    try {
      const r = await get(`${base}/v1/agents/${a.id}/runs`, cfg.apiKey);
      const items = r.items || r.runs || [];
      const run = items.find((x) => x.id === a.latestRunId) || items[0];
      if (run) {
        runs[a.id] = run;
        runCache.set(a.id, { latestRunId: a.latestRunId, run });
      }
    } catch (e) {
      if (!warnedAgents.has(a.id)) {
        warnedAgents.add(a.id);
        console.error(`[cursor] runs fetch failed for ${a.id}: ${e.message}`);
      }
    }
  }
  return { agents, runs };
};

const LABELS = { thinking: "Working", done: "Ready for review", error: "Failed" };

const repoName = (a) => {
  const repo = (a.repos && a.repos[0]) || a.source?.repository || "";
  const s = typeof repo === "string" ? repo : repo.repository || repo.name || "";
  return s.replace(/\.git$/, "").split("/").filter(Boolean).pop() || "";
};

const normalize = (raw, cfg, now) => {
  const rows = [];
  const warnings = [];
  for (const a of raw.agents || []) {
    if (String(a.status || "").toUpperCase() === "ARCHIVED") continue;
    const run = raw.runs?.[a.id];
    const rawStatus = String((run || a).status || "").toUpperCase();
    if (!(rawStatus in RUN_STATES)) {
      if (rawStatus && rawStatus !== "ACTIVE") warnings.push(`unknown cursor status "${rawStatus}"`);
      if (rawStatus !== "ACTIVE" || !run) continue; // ACTIVE with no run detail: nothing to show
    }
    const state = RUN_STATES[rawStatus] ?? null;
    const prUrl = run?.git?.branches?.find((b) => b.prUrl)?.prUrl || "";
    rows.push({
      id: a.id,
      state,
      label: LABELS[state] || "",
      project: a.name || repoName(a) || "Cursor agent",
      prompt: a.name || "",
      recap: state === "done" && prUrl ? prUrl : "",
      url: cfg.openIn === "app"
        ? `cursor://anysphere.cursor-deeplink/background-agent?bcId=${encodeURIComponent(a.id)}`
        : a.url || `https://cursor.com/agents/${encodeURIComponent(a.id)}`,
      started_at: epoch(run?.createdAt || a.createdAt) || 0,
      updated_at: epoch(run?.updatedAt || run?.finishedAt || run?.createdAt || a.createdAt) || now,
      recentHours: cfg.recentHours,
    });
  }
  return { rows, warnings };
};

module.exports = { vendor, agentId, prefix, fetchRaw, normalize };
