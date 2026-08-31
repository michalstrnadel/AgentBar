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
const stateDir = path.join(os.homedir(), ".agentbar", "state.d");

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
    try { cp.execSync(`pgrep -x ${EXEC}`, { stdio: "ignore" }); return true; } catch {}
  }
  try {
    const w = JSON.parse(fs.readFileSync(path.join(stateDir, "..", "watcher.json"), "utf8"));
    return Date.now() / 1000 - w.ts < 60;
  } catch { return false; }
};
const writeAtomic = (f, o) => { const t = f + "." + process.pid + ".tmp"; fs.writeFileSync(t, JSON.stringify(o)); fs.renameSync(t, f); };

let _isApp;
const isApp = () => {
  if (_isApp === undefined) {
    let cmd = "";
    try { cmd = cp.execSync(`ps -o comm= -p ${process.ppid}`).toString(); } catch {}
    _isApp = /language_server/.test(cmd);
  }
  return _isApp;
};

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
  try {
    writeAtomic(statePath, {
      ...prev, agent: AGENT, state,
      label: state === "tool" && tool ? String(tool) : (state === "done" ? "Done" : ""),
      project: cwd ? path.basename(cwd) : "", cwd, sessionId: id,
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
