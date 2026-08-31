#!/usr/bin/env node
// AgentBar bridge for Gemini CLI hooks. Maps Gemini's hook events (read from the
// stdin payload's hook_event_name) to a per-session state file in
// ~/.agentbar/state.d/. Observe-only: writes state, emits nothing, exits fast.
const fs = require("fs"), os = require("os"), path = require("path"), cp = require("child_process");

const AGENT = "gemini";
const BUNDLE_ID = "com.michalstrnadel.agentbar";
const EXEC = "AgentBar";
const stateDir = path.join(os.homedir(), ".agentbar", "state.d");

// Gemini event name -> AgentBar state. Exactly the events HookInstaller registers.
const STATE = {
  SessionStart: "idle", SessionEnd: "end",
  BeforeTool: "tool", AfterTool: "thinking",
  BeforeAgent: "thinking", AfterAgent: "done",
};

const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64) || "unknown";
// Never end a cut on a lone high surrogate: JSON.stringify escapes one happily,
// but Swift's JSONSerialization rejects the whole file — and an unreadable state
// file hides the session from every frontend until the next clean write.
const sliceSafe = (s, n) => {
  const cut = s.slice(0, n);
  const last = cut.charCodeAt(cut.length - 1);
  return last >= 0xd800 && last <= 0xdbff ? cut.slice(0, -1) : cut;
};
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

// One diagnostic per process, never more: this bridge fires on every event, so an
// unconditional log would flood the host agent's stderr. Self-swallowing and
// stderr-only — it can neither throw nor delay the exit.
let warned = false;
const warn = (what, err) => {
  if (warned) return;
  warned = true;
  try { console.error("[agentbar] " + what + " failed: " + ((err && err.message) || err)); } catch {}
};

let input = "", done = false;
process.stdin.on("data", (d) => (input += d));
process.stdin.on("end", run);
process.stdin.on("error", run);
setTimeout(run, 1000);

function run() {
  if (done) return; done = true;
  let j = {}; try { j = JSON.parse(input); } catch {}
  const event = j.hook_event_name || "";
  const state = STATE[event];
  if (!state) return process.exit(0);

  const id = j.session_id || j.sessionId || "";
  const cwd = j.cwd || "";
  const statePath = path.join(stateDir, safeId(id) + ".json");

  try { fs.mkdirSync(stateDir, { recursive: true }); } catch (e) { warn("mkdir " + stateDir, e); }
  if (state === "end") {
    try { fs.rmSync(statePath, { force: true }); } catch (e) { warn("state remove " + statePath, e); }
    return process.exit(0);
  }
  const appUp = state === "idle" ? running() : true;
  if (state === "idle" && !appUp) {
    // Only files whose agent process is gone: other agents' sessions outlive an
    // AgentBar restart, and wiping the folder made live work disappear.
    try {
      let cleared = 0;
      for (const f of fs.readdirSync(stateDir)) {
        const p = path.join(stateDir, f);
        let owner = 0;
        try { owner = Number(JSON.parse(fs.readFileSync(p, "utf8")).pid) || 0; } catch {}
        if (owner > 0) {
          try { process.kill(owner, 0); continue; } catch (e) {
            if (e.code === "EPERM") continue; // exists, just not ours to signal
          }
        }
        fs.rmSync(p, { force: true });
        cleared++;
      }
      // Leave a trail: "my sessions vanished" must be explainable after the fact.
      if (cleared)
        console.error("[agentbar] AgentBar not running: cleared " + cleared +
                      " dead state file(s) from " + stateDir);
    } catch (e) { warn("stale state cleanup", e); }
  }

  let prev = {}; try { prev = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch {}
  const ts = Math.floor(Date.now() / 1000);
  const oneLine = (s) => sliceSafe(String(s).replace(/\s+/g, " ").trim(), 120);
  try {
    writeAtomic(statePath, {
      ...prev, agent: AGENT, state,
      label: j.tool_name ? String(j.tool_name) : (state === "done" ? "Done" : ""),
      project: cwd ? path.basename(cwd) : "", cwd, sessionId: id,
      entrypoint: "cli", term_program: process.env.TERM_PROGRAM || "",
      // The shell running Gemini's command string execs the single command, so ppid
      // is the gemini process itself, not a dead intermediate sh (verified on macOS).
      pid: process.ppid, started: state !== "idle" ? true : (prev.started || false),
      started_at: prev.started_at || ts, // set once; elapsed depends on it never moving
      ...(typeof j.prompt === "string" && j.prompt.trim() ? { prompt: oneLine(j.prompt) } : {}),
      ts,
    });
  } catch (e) { warn("state write " + statePath, e); }
  // Launch ONLY when nothing is running: with two copies on disk LaunchServices
  // may resolve the bundle ID to the OTHER copy and start a second instance —
  // which then terminates the one already running (see lifecycle.js).
  if (state === "idle" && process.platform === "darwin" && !appUp)
    cp.spawn("open", ["-g", "-b", BUNDLE_ID], { stdio: "ignore", detached: true }).unref();
  process.exit(0);
}
