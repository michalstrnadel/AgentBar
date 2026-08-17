#!/usr/bin/env node
// Claude Code hook -> ~/.agentbar/state.d/<session_id>.json
// Usage: node update.js <prompt|pre|post|stop>   (hook JSON on stdin)
// Permission state is owned solely by permission.js: it writes richer labels and,
// unlike Notification events, can never land late and overwrite a newer state.
// Event-to-state mapping ported from AI Status Notifier (proven in daily use).

const fs = require("fs");
const os = require("os");
const path = require("path");

const stateDir = path.join(os.homedir(), ".agentbar", "state.d");
const event = process.argv[2] || "";

const TOOL_LABELS = {
  Bash: "Running command", Edit: "Editing", Write: "Writing", MultiEdit: "Editing",
  NotebookEdit: "Editing", Read: "Reading", Grep: "Searching", Glob: "Searching",
  WebFetch: "Browsing web", WebSearch: "Searching web", Task: "Delegating",
  TodoWrite: "Planning",
};

const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64) || "unknown";
// One display line: the prompt names the task in a row, not a transcript.
const oneLine = (s) => String(s).replace(/\s+/g, " ").trim().slice(0, 120);

// One line of what the agent last said — read from the transcript's tail on
// "stop", so a done row can say WHAT finished. Best-effort by design: any miss
// (no path, unreadable file, format drift) returns "" and the field is simply
// omitted. Bounded work — one 64 KB read, at most 200 lines parsed — so it can
// never meaningfully delay the hook's exit.
const RECAP_TAIL = 64 * 1024;
const RECAP_MAX = 160;
const recapFromTranscript = (file) => {
  try {
    if (typeof file !== "string" || !file) return "";
    const fd = fs.openSync(file, "r");
    let chunk = "";
    try {
      const size = fs.fstatSync(fd).size;
      const len = Math.min(size, RECAP_TAIL);
      const buf = Buffer.alloc(len);
      fs.readSync(fd, buf, 0, len, size - len);
      chunk = buf.toString("utf8");
    } finally { fs.closeSync(fd); }
    const lines = chunk.split("\n");
    // Newest first. The first line of the window may be torn mid-JSON by the
    // 64 KB cut — its parse fails and the loop just skips it.
    for (let i = lines.length - 1, scanned = 0; i >= 0 && scanned < 200; i--, scanned++) {
      let e;
      try { e = JSON.parse(lines[i]); } catch { continue; }
      if (!e || e.type !== "assistant" || e.isSidechain || e.isApiErrorMessage) continue;
      const content = e.message && e.message.content;
      if (!Array.isArray(content)) continue;
      const text = content
        .filter((c) => c && c.type === "text" && typeof c.text === "string")
        .map((c) => c.text).join(" ");
      const cleaned = text
        .replace(/```[^]*?```/g, " ")    // fenced code blocks ([^] spans newlines)
        .replace(/^#{1,6}\s+/gm, "")     // heading markers
        .replace(/^\s*[-*+]\s+/gm, "")   // bullet markers
        .replace(/^\s*\d+[.)]\s+/gm, "") // numbered-list markers
        .replace(/[`*_]/g, "")           // inline backticks / bold / italics
        .replace(/\s+/g, " ")
        .trim();
      if (cleaned) return cleaned.slice(0, RECAP_MAX);
      // tool_use- or thinking-only assistant entry — keep walking back.
    }
  } catch {}
  return "";
};

// One diagnostic per process, never more: this hook fires on every event, so an
// unconditional log would flood the host agent's stderr. Self-swallowing and
// stderr-only — it can neither throw nor delay the exit.
let warned = false;
const warn = (what, err) => {
  if (warned) return;
  warned = true;
  try { console.error("[agentbar] " + what + " failed: " + ((err && err.message) || err)); } catch {}
};

let raw = "";
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", () => {
  let p = {};
  try { p = JSON.parse(raw || "{}"); } catch {}

  // The session's own file is both the unit of state and the liveness marker; writing it on
  // any event also picks up sessions that predate the hook install (no SessionStart fired).
  const sid = safeId(p.session_id);
  const statePath = path.join(stateDir, sid + ".json");

  let prev = {};
  try { prev = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch {}

  const cwd = p.cwd || prev.cwd || "";
  const project = cwd ? path.basename(cwd) : prev.project || "";
  const ts = Math.floor(Date.now() / 1000);
  let state = "idle", label = "";

  switch (event) {
    case "prompt": state = "thinking"; label = "Thinking…"; break;
    case "pre":    state = "tool"; label = TOOL_LABELS[p.tool_name] || "Using tool"; break;
    case "post":   state = "thinking"; label = "Thinking…"; break;
    case "stop":    state = "done"; label = ""; break;
    default: return;
  }

  const out = {
    agent: "claude",
    state, label,
    project, cwd,
    sessionId: p.session_id || "",
    // "cli" | "claude-desktop" | … — which surface runs the session; used for row clicks.
    entrypoint: process.env.CLAUDE_CODE_ENTRYPOINT || prev.entrypoint || "",
    // Terminal app for CLI sessions (Apple_Terminal, iTerm.app, WarpTerminal, …).
    term_program: process.env.TERM_PROGRAM || prev.term_program || "",
    // Hooks are spawned directly by the session's `claude` process, so ppid is that process;
    // the app probes it with kill(pid, 0) to prune dead sessions.
    pid: process.ppid,
    started: true,
    // Set once and preserved from then on — elapsed time depends on it never moving.
    // First-write fallback covers sessions that predate the field (or the hook).
    started_at: prev.started_at || ts,
    ts,
  };
  // The latest prompt names the task the session is on; older fields ride along.
  // Not everything arriving as a "prompt" is the user's task: the harness injects
  // system turns (task notifications, local-command wrappers — they start with
  // "<"), and slash commands are commands, not tasks. Those must never rename
  // the row, so the previous task survives them.
  const cand = event === "prompt" && typeof p.prompt === "string" ? p.prompt.trim() : "";
  if (cand && !cand.startsWith("<") && !cand.startsWith("/"))
    out.prompt = oneLine(cand);
  else if (prev.prompt) out.prompt = prev.prompt;
  const model = typeof p.model === "string" ? p.model : (p.model && p.model.display_name) || "";
  if (model) out.model = String(model);
  else if (prev.model) out.model = prev.model;
  // What the agent last said, for done rows. Only "stop" carries it — every other
  // event omits the field (out is built fresh, not {...prev}), so the next prompt
  // naturally clears the previous turn's recap and a working session never shows
  // a stale result.
  if (event === "stop") {
    const recap = recapFromTranscript(p.transcript_path);
    if (recap) out.recap = recap;
  }
  try {
    fs.mkdirSync(stateDir, { recursive: true });
    const tmp = statePath + "." + process.pid + ".tmp";
    fs.writeFileSync(tmp, JSON.stringify(out));
    fs.renameSync(tmp, statePath);
  } catch (e) { warn("state write " + statePath, e); }
});
