#!/usr/bin/env node
// Codex CLI notify adapter -> ~/.agentbar/state.d/codex-<id>.json
// Codex invokes the configured notify program with one JSON argument per event.
// Upstream only emits completion-type events (agent-turn-complete), so a Codex session
// appears after its first finished turn and rests; there is no live "working" signal.
// Install (HookInstaller does this automatically when ~/.codex exists):
//   ~/.codex/config.toml:  notify = ["node", "<abs path to this file>"]

const fs = require("fs");
const os = require("os");
const path = require("path");

const stateDir = path.join(os.homedir(), ".agentbar", "state.d");

let p = {};
try { p = JSON.parse(process.argv[2] || "{}"); } catch {}

const type = p.type || "";
if (!type.includes("complete")) process.exit(0);

const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64) || "unknown";
const oneLine = (s) => String(s).replace(/\s+/g, " ").trim().slice(0, 120);
const id = "codex-" + safeId(p["thread-id"] || p["turn-id"] || String(process.ppid));
const cwd = p.cwd || p["working-directory"] || process.cwd() || "";
const file = path.join(stateDir, id + ".json");

let prev = {};
try { prev = JSON.parse(fs.readFileSync(file, "utf8")); } catch {}
// The notify payload carries the turn's user messages; the last one names the task.
const msgs = p["input_messages"] || p["input-messages"];
const lastMsg = Array.isArray(msgs) && msgs.length ? oneLine(msgs[msgs.length - 1]) : "";

const out = {
  agent: "codex",
  state: "done", label: "",
  project: cwd ? path.basename(cwd) : "",
  cwd,
  sessionId: id,
  entrypoint: "cli",
  term_program: process.env.TERM_PROGRAM || "",
  pid: process.ppid, // the codex process; the app prunes the session when it exits
  started: true,
  // First notify is the end of the first turn — the closest to a start this
  // adapter ever sees. Preserved from then on so elapsed doesn't reset per turn.
  started_at: prev.started_at || Math.floor(Date.now() / 1000),
  ...(lastMsg ? { prompt: lastMsg } : prev.prompt ? { prompt: prev.prompt } : {}),
  ts: Math.floor(Date.now() / 1000),
};

try {
  fs.mkdirSync(stateDir, { recursive: true });
  const tmp = file + "." + process.pid + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(out));
  fs.renameSync(tmp, file);
} catch (e) {
  // Single stderr line per invocation — enough of a trail to explain "AgentBar
  // shows nothing", too little to be noise. Self-swallowing: never throws, never
  // delays the exit.
  try { console.error("[agentbar] state write " + file + " failed: " + ((e && e.message) || e)); } catch {}
}
