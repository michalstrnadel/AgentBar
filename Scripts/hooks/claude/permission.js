#!/usr/bin/env node
// Claude Code PermissionRequest -> remote approval from the AgentBar menu.
// Writes a request file, then BLOCKS polling answers.d for the user's decision;
// returning a decision replaces the terminal prompt entirely.
// Deliberate exception to "hooks never block": the session is already waiting on
// a human, and every failure path (no app, app quits, timeout, junk input, signal,
// filesystem error) exits silently so the ordinary terminal prompt appears instead.
// Usage: node permission.js   (PermissionRequest hook JSON on stdin)

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const base = path.join(os.homedir(), ".agentbar");
const stateDir = path.join(base, "state.d");
const reqDir = path.join(base, "requests.d");
const ansDir = path.join(base, "answers.d");

const timeoutSecRaw = Number(process.env.AGENTBAR_APPROVAL_TIMEOUT);
const timeoutSec = Number.isFinite(timeoutSecRaw) && timeoutSecRaw > 0 ? timeoutSecRaw : 600;
const TIMEOUT_MS = 1000 * timeoutSec;
const POLL_MS = 100;

const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64) || "unknown";
const writeAtomic = (file, obj) => {
  const tmp = file + "." + process.pid + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(obj));
  fs.renameSync(tmp, file);
};
// "Somebody can answer": the macOS app (pgrep), or the cross-platform CLI's
// watch/waybar mode, which heartbeats ~/.agentbar/watcher.json while it runs.
const appRunning = () => {
  if (process.env.AGENTBAR_FORCE_APP === "1") return true;
  if (process.env.AGENTBAR_FORCE_APP === "0") return false;
  if (process.platform === "darwin") {
    try { cp.execSync("pgrep -x AgentBar", { stdio: "ignore" }); return true; } catch {}
  }
  try {
    const w = JSON.parse(fs.readFileSync(path.join(base, "watcher.json"), "utf8"));
    return Date.now() / 1000 - w.ts < 60;
  } catch { return false; }
};

// Stable JSON: objects re-keyed in sorted order at every depth, so two parses of
// the same document compare equal regardless of serializer key ordering.
const canonical = (v) => {
  if (Array.isArray(v)) return "[" + v.map(canonical).join(",") + "]";
  if (v && typeof v === "object")
    return "{" + Object.keys(v).sort().map((k) => JSON.stringify(k) + ":" + canonical(v[k])).join(",") + "}";
  return JSON.stringify(v);
};

const oneLine = (s, n = 60) => {
  s = String(s || "").split("\n")[0].trim();
  return s.length > n ? s.slice(0, n - 1) + "…" : s;
};

const cap = (s, n) => { s = String(s == null ? "" : s); return s.length > n ? s.slice(0, n) + "…" : s; };

// Structured, per-field-capped detail so the menu can show a mini-diff / full command
// inline (not just a hover tooltip). Null for tools where the one-line display is enough.
function buildContext(tool, input) {
  const t = String(tool || ""), i = input || {};
  if (t === "Bash") return { kind: "bash", command: cap(i.command, 2000) };
  if (t === "Edit") return { kind: "diff", old: cap(i.old_string, 1500), new: cap(i.new_string, 1500), more: 0 };
  if (t === "MultiEdit") {
    const edits = Array.isArray(i.edits) ? i.edits : [];
    const first = edits[0] || {};
    return { kind: "diff", old: cap(first.old_string, 1500), new: cap(first.new_string, 1500),
             more: Math.max(0, edits.length - 1) };
  }
  if (t === "Write") return { kind: "write", preview: cap(i.content, 1200) };
  return null;
}

function displaySummary(tool, input, cwd) {
  const t = String(tool || "unknown");
  const i = input || {};
  if (t === "Bash") return "Bash: " + oneLine(i.command);
  if (["Edit", "Write", "MultiEdit", "NotebookEdit", "Read"].includes(t)) {
    // Relative to the session's cwd, so the 60-char cut keeps the file name visible.
    let f = String(i.file_path || i.notebook_path || "");
    if (cwd && f.startsWith(cwd + "/")) f = f.slice(cwd.length + 1);
    return t + ": " + oneLine(f);
  }
  if (t === "WebFetch") return "WebFetch: " + oneLine(i.url);
  if (t === "WebSearch") return "WebSearch: " + oneLine(i.query);
  const m = t.match(/^mcp__(.+?)__(.+)$/);
  if (m) return m[1] + ": " + m[2];
  return t;
}

let raw = "", started = false;
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", run);
process.stdin.on("error", run);
setTimeout(run, 1000); // stdin never arrived: bail, never hang the session start

function run() {
  if (started) return; started = true;
  if (!appRunning()) process.exit(0); // nobody to answer -> terminal prompt
  if (!raw) process.exit(0); // stdin closed (or never arrived) empty: nothing to request

  // Junk on stdin is not a permission request. Bail here rather than posting a
  // garbled "unknown" row and blocking the session for the whole approval
  // timeout — same silent-to-terminal-prompt behaviour as empty stdin.
  let p;
  try { p = JSON.parse(raw); } catch { process.exit(0); }
  if (!p || typeof p !== "object" || Array.isArray(p)) process.exit(0);

  try {

    // AskUserQuestion is Claude asking the human, not asking for permission: the
    // question UI renders regardless of any hook decision, so blocking here would
    // be pointless. Mark the session "question" and get out of the way —
    // PostToolUse flips the state back once the user answers.
    if (p.tool_name === "AskUserQuestion") {
      try {
        const q = (((p.tool_input || {}).questions || [])[0] || {});
        const statePath = path.join(stateDir, safeId(p.session_id) + ".json");
        fs.mkdirSync(stateDir, { recursive: true });
        let prev = {};
        try { prev = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch {}
        writeAtomic(statePath, { ...prev, agent: "claude", state: "question",
          label: "❓ " + oneLine(q.question || "Waiting for your answer"),
          sessionId: p.session_id || "", pid: process.ppid, started: true,
          ts: Math.floor(Date.now() / 1000) });
      } catch {}
      process.exit(0);
    }

    const name = safeId(p.session_id) + "-" + safeId(p.prompt_id || String(process.pid));
    const reqPath = path.join(reqDir, name + ".json");
    const ansPath = path.join(ansDir, name + ".json");
    const display = displaySummary(p.tool_name, p.tool_input, p.cwd);

    let pretty = "";
    try { pretty = JSON.stringify(p.tool_input || {}, null, 2); } catch {}
    if (pretty.length > 4096) pretty = pretty.slice(0, 4096) + "\n…";

    // Rule suggestions come from Claude Code and go back verbatim on "Always allow";
    // the hook never invents permission rules itself.
    const suggestions = Array.isArray(p.permission_suggestions) ? p.permission_suggestions : [];
    const suggestion = suggestions[0] || null;

    fs.mkdirSync(reqDir, { recursive: true });
    fs.mkdirSync(ansDir, { recursive: true });

    // The session row itself shows what's pending, even before the menu opens.
    try {
      const statePath = path.join(stateDir, safeId(p.session_id) + ".json");
      fs.mkdirSync(stateDir, { recursive: true });
      let prev = {};
      try { prev = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch {}
      writeAtomic(statePath, { ...prev, agent: "claude", state: "permission", label: display,
        sessionId: p.session_id || "", pid: process.ppid, started: true,
        ts: Math.floor(Date.now() / 1000) });
    } catch {}

    writeAtomic(reqPath, {
      // safeId to match Session.id, which the app derives from the state file name.
      sessionId: safeId(p.session_id), agent: "claude",
      toolName: p.tool_name || "", display, toolInputPretty: pretty,
      context: buildContext(p.tool_name, p.tool_input),
      ruleSuggestion: suggestion, pid: process.ppid, hookPid: process.pid,
      ts: Math.floor(Date.now() / 1000),
    });

    const cleanup = () => {
      try { fs.rmSync(reqPath, { force: true }); } catch {}
      try { fs.rmSync(ansPath, { force: true }); } catch {}
    };
    process.on("exit", cleanup);
    // Claude Code kills hooks that overrun its own hook timeout; Node does not run
    // "exit" listeners on the default SIGTERM/SIGINT death, which would strand the
    // request file forever. Handling the signals ourselves guarantees cleanup runs.
    process.on("SIGTERM", () => { cleanup(); process.exit(0); });
    process.on("SIGINT", () => { cleanup(); process.exit(0); });

    const deadline = Date.now() + TIMEOUT_MS;
    let ticks = 0;
    const timer = setInterval(() => {
      try {
        if (fs.existsSync(ansPath)) {
          clearInterval(timer);
          let a = {};
          // Contract: the app writes answers atomically (tmp+rename), so a plain
          // read here never observes a partially written file.
          try { a = JSON.parse(fs.readFileSync(ansPath, "utf8")); } catch {}
          const b = a.behavior;
          if (b === "allow" || b === "always") {
            const decision = { behavior: "allow" };
            // Only pin a standing rule when it's structurally one Claude Code itself
            // suggested for this request. Same-user forgery of a single one-shot
            // "allow" is out of scope, but a forged "always" must not be able to
            // mint a permission Claude never offered. Key-order-insensitive: the app
            // round-trips the suggestion through JSONSerialization, which may reorder.
            const isSuggested = b === "always" && a.rule &&
              suggestions.some((s) => canonical(s) === canonical(a.rule));
            if (isSuggested) decision.updatedPermissions = [a.rule];
            respond(decision);
          } else if (b === "deny") {
            respond({ behavior: "deny" });
          }
          process.exit(0); // "defer"/junk: silent exit -> terminal prompt
        } else if (++ticks % 20 === 0 && !appRunning()) {
          clearInterval(timer);
          process.exit(0); // app quit mid-wait
        } else if (Date.now() >= deadline) {
          clearInterval(timer);
          process.exit(0); // timeout -> terminal prompt
        }
      } catch {
        clearInterval(timer);
        process.exit(0);
      }
    }, POLL_MS);
  } catch {
    process.exit(0); // any setup failure (e.g. disk full, ~/.agentbar not a dir) -> terminal prompt
  }
}

function respond(decision) {
  const json = JSON.stringify({
    hookSpecificOutput: { hookEventName: "PermissionRequest", decision },
  });
  fs.writeSync(1, json);
}
