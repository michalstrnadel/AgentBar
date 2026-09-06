#!/usr/bin/env node
// Claude Code SessionStart/SessionEnd -> seed/remove this session's state file.
// Usage: node lifecycle.js <start|end>   (hook JSON on stdin)
// Also serves agents with Claude-compatible hooks (Qwen Code): the installer
// registers the same script with AGENTBAR_AGENT set to the agent's id.

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const BUNDLE_ID = "com.michalstrnadel.agentbar";
const EXEC = "AgentBar";
const AGENT = String(process.env.AGENTBAR_AGENT || "claude").replace(/[^a-z]/g, "") || "claude";
const stateDir = path.join(os.homedir(), ".agentbar", "state.d");
const event = process.argv[2];

const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64) || "unknown";
// The macOS app, or the CLI's watch/waybar heartbeat (any platform).
// AGENTBAR_FORCE_APP=1|0 overrides for tests, same knob permission.js honors.
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

const writeAtomic = (file, obj) => {
  const tmp = file + "." + process.pid + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(obj));
  fs.renameSync(tmp, file);
};

// One diagnostic per process, never more: these hooks fire on every event, so an
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
setTimeout(run, 1000); // never hang the host session

function run() {
  if (done) return; done = true;
  // An unwritable state.d must not throw the hook out with a stack trace: report it
  // once and carry on, so the SessionEnd cleanup below still runs.
  try { fs.mkdirSync(stateDir, { recursive: true }); } catch (e) { warn("mkdir " + stateDir, e); }
  let id = "", cwd = "", source = "", model = "";
  try {
    const j = JSON.parse(input);
    id = j.session_id; cwd = j.cwd || "";
    // Why this start fired: "startup" | "resume" | "clear" | "compact" ("" on
    // older Claude Code versions — treated as a fresh start).
    source = typeof j.source === "string" ? j.source : "";
    // Model is best-effort: taken when the payload carries one, omitted otherwise.
    model = typeof j.model === "string" ? j.model : (j.model && j.model.display_name) || "";
  } catch {}
  const statePath = path.join(stateDir, safeId(id) + ".json");

  if (event === "start") {
    const appUp = running();
    // App not running -> sweep leftovers from a prior crash, but only the ones
    // whose agent process is actually gone. "The app is down" is the NORMAL
    // path here (this hook is what launches it), and other agents' sessions
    // outlive an AgentBar restart — deleting those made live work vanish.
    if (!appUp) {
      try {
        let cleared = 0;
        for (const f of fs.readdirSync(stateDir)) {
          const p = path.join(stateDir, f);
          let owner = 0;
          try { owner = Number(JSON.parse(fs.readFileSync(p, "utf8")).pid) || 0; } catch {}
          if (owner > 0) {
            // Signal 0 probes without delivering: alive (or ours to leave alone)
            // means keep. EPERM counts as alive — the pid exists.
            try { process.kill(owner, 0); continue; } catch (e) {
              if (e.code === "EPERM") continue;
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
    // Merge over what's already there (protocol rule): SessionStart also fires
    // mid-life — resume, /clear, auto-compact, all on the SAME session id — and a
    // fresh-object write reset started_at (elapsed restarted), dropped
    // prompt/model/recap, and hid a live row behind started:false until the next
    // event.
    let prev = {};
    try { prev = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch {}
    // started:false — a merely-opened conversation stays out of the dropdown until
    // real activity (update.js flips started on the first prompt/tool event).
    // A resume reopens a session that has history and a compact fires mid-turn:
    // both keep prev's visibility; compact alone also keeps state/label — the
    // session is still doing whatever it was doing.
    const continues = source === "resume" || source === "compact";
    try {
      const ts = Math.floor(Date.now() / 1000);
      writeAtomic(statePath, {
        ...prev,
        agent: AGENT,
        state: source === "compact" ? (prev.state || "idle") : "idle",
        label: source === "compact" ? (prev.label || "") : "",
        project: cwd ? path.basename(cwd) : (prev.project || ""),
        cwd: cwd || prev.cwd || "",
        sessionId: id || prev.sessionId || "",
        entrypoint: process.env.CLAUDE_CODE_ENTRYPOINT || prev.entrypoint || "",
        term_program: process.env.TERM_PROGRAM || prev.term_program || "",
        pid: process.ppid,
        started: continues ? prev.started === true : false,
        // Set once and preserved from then on — elapsed depends on it never moving.
        started_at: prev.started_at || ts,
        ...(model ? { model: String(model) } : {}),
        ts,
      });
    } catch (e) { warn("state write " + statePath, e); }
    // Launch ONLY when nothing is running. With two copies on disk (a dev build
    // next to /Applications) LaunchServices may resolve the bundle ID to the
    // OTHER copy and start a second instance — which then terminates the one
    // already running. "Make sure it's up" must never mean "start another".
    if (process.platform === "darwin" && !appUp)
      cp.spawn("open", ["-g", "-b", BUNDLE_ID], { stdio: "ignore", detached: true }).unref();
  } else if (event === "end") {
    // Removing the file drops the session; also what recovers a frozen icon after force-quit.
    try { fs.rmSync(statePath, { force: true }); } catch (e) { warn("state remove " + statePath, e); }
  }
  process.exit(0);
}
