// Codex cloud tasks -> normalized runs.
// No REST API exists; the official surface is `codex cloud list --json` riding
// the CLI's ChatGPT login. Known gap: code-review tasks are absent from the
// listing (openai/codex#23853). The status vocabulary is undocumented — unknown
// values map to idle and surface as warnings so the map can grow from evidence.

const { execFile } = require("child_process");
const { epoch } = require("../lib/policy");

const vendor = "codex";
const agentId = "codex";
const prefix = "cloud-codex-";

const STATES = {
  // Observed ("ready" = finished, awaiting review) + documented-adjacent guesses.
  ready: "done", completed: "done", applied: "done", merged: "done", done: "done",
  error: "error", failed: "error",
  pending: "thinking", queued: "thinking", creating: "thinking",
  running: "thinking", in_progress: "thinking", "in-progress": "thinking", working: "thinking",
  needs_input: "question", blocked: "question", awaiting_input: "question",
  cancelled: null, expired: null,
};

const fetchRaw = (cfg) =>
  new Promise((resolve, reject) => {
    execFile(cfg.bin || "codex", ["cloud", "list", "--json", "--limit", "20"],
      { timeout: 30_000, maxBuffer: 4 * 1024 * 1024 },
      (err, stdout, stderr) => {
        if (err) return reject(new Error(`codex cloud list: ${String(stderr || err.message).trim().slice(0, 200)}`));
        try { resolve(JSON.parse(stdout)); }
        catch { reject(new Error("codex cloud list: unparseable JSON")); }
      });
  });

const LABELS = { thinking: "Working", question: "Needs your input", done: "Ready for review", error: "Failed" };

const recapFor = (t) => {
  const s = t.summary;
  if (!s || typeof s !== "object") return "";
  const parts = [];
  if (s.files_changed != null) parts.push(`${s.files_changed} file${s.files_changed === 1 ? "" : "s"}`);
  if (s.lines_added != null || s.lines_removed != null) parts.push(`+${s.lines_added ?? 0} −${s.lines_removed ?? 0}`);
  return parts.join(" · ");
};

const normalize = (raw, cfg, now) => {
  const rows = [];
  const warnings = [];
  for (const t of raw.tasks || []) {
    const key = String(t.status || "").toLowerCase();
    let state = STATES[key];
    if (state === undefined) {
      warnings.push(`unknown codex status "${key}"`);
      state = "idle";
    }
    rows.push({
      id: String(t.id || ""),
      state,
      label: LABELS[state] || "",
      project: t.environment_label || "Codex",
      prompt: t.title || "",
      recap: state === "done" ? recapFor(t) : "",
      url: t.url || "",
      started_at: 0, // the listing carries no creation time
      updated_at: epoch(t.updated_at) || now,
      recentHours: cfg.recentHours,
    });
  }
  return { rows, warnings };
};

module.exports = { vendor, agentId, prefix, fetchRaw, normalize };
