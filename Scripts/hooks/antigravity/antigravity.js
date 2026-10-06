#!/usr/bin/env node
// AgentBar bridge for Google Antigravity hooks (desktop app + agy CLI, 2.x).
// Maps Antigravity's five lifecycle events to a per-session state file in
// ~/.agentbar/state.d/. Observe-only: writes state, emits nothing, exits fast.
// Payload fields differ between the desktop app and the CLI generation of the
// contract (conversationId/workspacePaths vs session_id/cwd), so both are read.
const fs = require("fs"), os = require("os"), path = require("path"), cp = require("child_process");

const AGENT = "antigravity";
const BUNDLE_ID = "com.michalstrnadel.agentbar";
const EXEC = "AgentBar";
// The state root (docs/protocol.md, "Where state lives"): AGENTBAR_HOME when it is
// an absolute path, ~/.agentbar otherwise. A relative value is ignored, not refused:
// a hook must never fail its host.
const stateRoot = () => {
  const v = process.env.AGENTBAR_HOME || "";
  return path.isAbsolute(v) ? v.replace(/\/+$/, "") || "/" : path.join(os.homedir(), ".agentbar");
};
const stateDir = path.join(stateRoot(), "state.d");

// Antigravity has no SessionStart/SessionEnd: the file appears on first activity
// and leaves via the app's pid/staleness pruning. PostInvocation fires between
// loop steps (more model calls may follow) -> thinking; Stop ends the loop -> done.
const STATE = {
  PreInvocation: "thinking", PreToolUse: "tool",
  PostToolUse: "thinking", PostInvocation: "thinking",
  Stop: "done",
};

const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64) || "unknown";
// The macOS app, or the CLI's watch/waybar heartbeat (any platform).
// AGENTBAR_FORCE_APP=1|0 overrides for tests, same knob the claude hooks honor.
const running = () => {
  if (process.env.AGENTBAR_FORCE_APP === "1") return true;
  if (process.env.AGENTBAR_FORCE_APP === "0") return false;
  if (process.platform === "darwin") {
    try { cp.execSync(`pgrep -x -U ${process.getuid()} ${EXEC}`, { stdio: "ignore" }); return true; } catch {}
  }
  try {
    const w = JSON.parse(fs.readFileSync(path.join(stateDir, "..", "watcher.json"), "utf8"));
    return Date.now() / 1000 - w.ts < 60;
  } catch { return false; }
};
// A lone surrogate anywhere in a value — not only one a cut created — makes Swift's
// JSONSerialization reject the whole file, and an unreadable state file hides the
// session from every frontend until the next clean write. It cannot be caught after
// stringify, which escapes it into six harmless-looking characters, so it is caught
// on the values on the way out.
const paired = (k, v) => (typeof v === "string"
  ? v.replace(/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/g, "")
  : v);
const writeAtomic = (f, o) => { const t = f + "." + process.pid + ".tmp"; fs.writeFileSync(t, JSON.stringify(o, paired)); fs.renameSync(t, f); };

let _isApp;
const isApp = () => {
  if (_isApp === undefined) {
    let cmd = "";
    try { cmd = cp.execSync(`ps -o comm= -p ${process.ppid}`).toString(); } catch {}
    _isApp = /language_server/.test(cmd);
  }
  return _isApp;
};

// Same reason as the PreToolUse decision below: a status bridge must never be
// why a tool call was refused, and agy reads a non-zero exit as a denial.
process.on("uncaughtException", () => process.exit(0));

let input = "", done = false;
process.stdin.on("data", (d) => (input += d));
process.stdin.on("end", run);
process.stdin.on("error", run);
setTimeout(run, 1000);

function run() {
  if (done) return; done = true;
  let j = {}; try { j = JSON.parse(input); } catch {}
  // The payload carries no event name (verified on 2.3.1) — the event is implied
  // by where the command is registered, so the installer appends it as argv[2].
  const event = process.argv[2] || j.hook_event_name || j.hookEventName || "";
  // agy is fail-closed on PreToolUse: a non-zero exit, a crash, or stdout that
  // isn't a valid decision all read as "deny". Silence — what this bridge used to
  // emit — is one parser change away from refusing every tool call in the CLI.
  // So the decision goes out first, synchronously (process.exit can truncate a
  // buffered async write), before any of the work below can go wrong. The desktop
  // app ignores stdout, so it costs that side nothing. "allow" here only means
  // "this hook does not object": agy 1.2.14 still applies its own permission
  // system on top of it (verified 2026-10-01), so nothing is approved for the user.
  if (event === "PreToolUse") { try { fs.writeSync(1, '{"decision":"allow"}'); } catch {} }
  const state = STATE[event];
  if (!state) return process.exit(0);

  const id = j.conversationId || j.conversation_id || j.session_id || j.sessionId
    || path.basename(String(j.transcriptPath || j.transcript_path || ""), ".json");
  const workspaces = j.workspacePaths || j.workspace_paths || [];
  const cwd = j.cwd || (Array.isArray(workspaces) && workspaces[0]) || "";
  const tool = j.tool_name || j.toolName
    || (j.toolCall && (j.toolCall.name || j.toolCall.tool)) || "";
  const statePath = path.join(stateDir, safeId(id) + ".json");

  try { fs.mkdirSync(stateDir, { recursive: true }); } catch {}
  let prev = {}; try { prev = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch {}
  // Not every event carries the workspace (PostToolUse/Stop often don't): a
  // blank must not erase what an earlier event knew — protocol merge rule.
  const dir = cwd || prev.cwd || "";
  try {
    writeAtomic(statePath, {
      ...prev, agent: AGENT, state,
      label: state === "tool" && tool ? String(tool) : (state === "done" ? "Done" : ""),
      project: dir ? path.basename(dir) : (prev.project || ""), cwd: dir, sessionId: id,
      // Desktop sessions come from the app's language_server; TERM_PROGRAM can't
      // be trusted (the app inherits it when launched from a terminal via `open`).
      entrypoint: isApp() ? "antigravity-app" : "cli",
      term_program: isApp() ? "" : (process.env.TERM_PROGRAM || ""),
      pid: process.ppid, started: true,
      ts: Math.floor(Date.now() / 1000),
    });
  } catch {}
  // First sighting of this session: make sure a frontend is up. Launch ONLY when
  // nothing is running — with two copies on disk LaunchServices may resolve the
  // bundle ID to the OTHER copy and start a second instance, which then
  // terminates the one already running (see lifecycle.js).
  if (!prev.agent && process.platform === "darwin" && !running())
    cp.spawn("open", ["-g", "-b", BUNDLE_ID], { stdio: "ignore", detached: true }).unref();
  process.exit(0);
}
