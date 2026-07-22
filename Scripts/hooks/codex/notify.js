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
const id = "codex-" + safeId(p["thread-id"] || p["turn-id"] || String(process.ppid));
const cwd = p.cwd || p["working-directory"] || process.cwd() || "";

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
  ts: Math.floor(Date.now() / 1000),
};

try {
  fs.mkdirSync(stateDir, { recursive: true });
  const file = path.join(stateDir, id + ".json");
  const tmp = file + "." + process.pid + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(out));
  fs.renameSync(tmp, file);
} catch {}
