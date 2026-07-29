#!/usr/bin/env node
// Claude Code SessionStart/SessionEnd -> seed/remove this session's state file.
// Usage: node lifecycle.js <start|end>   (hook JSON on stdin)

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const BUNDLE_ID = "com.michalstrnadel.agentbar";
const EXEC = "AgentBar";
const stateDir = path.join(os.homedir(), ".agentbar", "state.d");
const event = process.argv[2];

const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64) || "unknown";
// The macOS app, or the CLI's watch/waybar heartbeat (any platform).
const running = () => {
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

let input = "", done = false;
process.stdin.on("data", (d) => (input += d));
process.stdin.on("end", run);
process.stdin.on("error", run);
setTimeout(run, 1000); // never hang the host session

function run() {
  if (done) return; done = true;
  fs.mkdirSync(stateDir, { recursive: true });
  let id = "", cwd = "";
  try { const j = JSON.parse(input); id = j.session_id; cwd = j.cwd || ""; } catch {}
  const statePath = path.join(stateDir, safeId(id) + ".json");

  if (event === "start") {
    // App not running -> leftover files are stale (prior crash); start honest.
    if (!running()) { try { for (const f of fs.readdirSync(stateDir)) fs.rmSync(path.join(stateDir, f), { force: true }); } catch {} }
    // started:false — a merely-opened conversation stays out of the dropdown until real
    // activity (update.js flips started on the first prompt/tool event).
    try {
      const ts = Math.floor(Date.now() / 1000);
      // Model is best-effort: taken when the payload carries one, omitted otherwise.
      let model = "";
      try {
        const j = JSON.parse(input);
        model = typeof j.model === "string" ? j.model : (j.model && j.model.display_name) || "";
      } catch {}
      writeAtomic(statePath, {
        agent: "claude", state: "idle", label: "",
        project: cwd ? path.basename(cwd) : "", cwd, sessionId: id || "",
        entrypoint: process.env.CLAUDE_CODE_ENTRYPOINT || "",
        term_program: process.env.TERM_PROGRAM || "",
        pid: process.ppid, started: false, started_at: ts,
        ...(model ? { model: String(model) } : {}), ts,
      });
    } catch {}
    if (process.platform === "darwin")
      cp.spawn("open", ["-g", "-b", BUNDLE_ID], { stdio: "ignore", detached: true }).unref();
  } else if (event === "end") {
    // Removing the file drops the session; also what recovers a frozen icon after force-quit.
    try { fs.rmSync(statePath, { force: true }); } catch {}
  }
  process.exit(0);
}
