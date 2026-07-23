#!/usr/bin/env node
// AgentBar bridge for Cursor CLI hooks. Maps Cursor's hook events (read from the
// stdin payload's hook_event_name) to a per-session state file in
// ~/.agentbar/state.d/, the same "folder is the protocol" the app already watches.
// Observe-only: writes state, emits nothing, exits fast — never affects the agent.
const fs = require("fs"), os = require("os"), path = require("path"), cp = require("child_process");

const AGENT = "cursor";
const BUNDLE_ID = "com.michalstrnadel.agentbar";
const EXEC = "AgentBar";
const stateDir = path.join(os.homedir(), ".agentbar", "state.d");

// Cursor event name -> AgentBar state. Exactly the events HookInstaller registers;
// the permission-gating before* hooks are deliberately not used by this bridge.
const STATE = {
  sessionStart: "idle", sessionEnd: "end",
  preToolUse: "tool", postToolUse: "thinking",
  stop: "done", afterAgentResponse: "done",
};

const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64) || "unknown";
const running = () => { try { cp.execSync(`pgrep -x ${EXEC}`, { stdio: "ignore" }); return true; } catch { return false; } };
const writeAtomic = (f, o) => { const t = f + "." + process.pid + ".tmp"; fs.writeFileSync(t, JSON.stringify(o)); fs.renameSync(t, f); };

let input = "", done = false;
process.stdin.on("data", (d) => (input += d));
process.stdin.on("end", run);
process.stdin.on("error", run);
setTimeout(run, 1000); // never hang the host

function run() {
  if (done) return; done = true;
  let j = {}; try { j = JSON.parse(input); } catch {}
  const event = j.hook_event_name || "";
  const state = STATE[event];
  if (!state) return process.exit(0);

  const id = j.conversation_id || j.generation_id || j.session_id || "";
  const cwd = j.cwd || (Array.isArray(j.workspace_roots) && j.workspace_roots[0]) || "";
  const statePath = path.join(stateDir, safeId(id) + ".json");

  try { fs.mkdirSync(stateDir, { recursive: true }); } catch {}
  if (state === "end") { try { fs.rmSync(statePath, { force: true }); } catch {} return process.exit(0); }
  if (state === "idle" && !running()) {
    try { for (const f of fs.readdirSync(stateDir)) fs.rmSync(path.join(stateDir, f), { force: true }); } catch {}
  }

  let prev = {}; try { prev = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch {}
  try {
    writeAtomic(statePath, {
      ...prev, agent: AGENT, state,
      label: j.tool_name ? String(j.tool_name) : (state === "done" ? "Done" : ""),
      project: cwd ? path.basename(cwd) : "", cwd, sessionId: id,
      entrypoint: "cli", term_program: process.env.TERM_PROGRAM || "",
      // Cursor execs the script directly, so ppid is the agent process (liveness handle).
      pid: process.ppid, started: state !== "idle" ? true : (prev.started || false),
      ts: Math.floor(Date.now() / 1000),
    });
  } catch {}
  if (state === "idle") cp.spawn("open", ["-g", "-b", BUNDLE_ID], { stdio: "ignore", detached: true }).unref();
  process.exit(0);
}
