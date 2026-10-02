#!/usr/bin/env node
// Codex CLI notify adapter -> ~/.agentbar/state.d/codex-<id>.json
// Codex invokes the configured notify program with one JSON argument per event.
// It only emits completion-type events, so a session written from here appears
// after its first finished turn and rests: there is no live "working" signal.
//
// Since 1.28.0 this is the FALLBACK, not the integration. Codex gained real hooks
// (see ../codex/hook.js and ../claude/*), which report a session from its first
// keystroke to its end — but Codex runs no hook until the human has accepted it in
// Codex's own trust prompt, and this is the only thing that shows a Codex session in
// that window. So it stands down once the hooks are wired AND trusted, and writes
// the moment they are not. Both writers name the row `codex-<thread-id>`, so a
// mistake here costs a duplicate row rather than a lost one.
//
// Install (HookInstaller does this automatically when ~/.codex exists):
//   ~/.codex/config.toml:  notify = ["node", "<abs path to this file>"]

const fs = require("fs");
const os = require("os");
const path = require("path");

// The state root (docs/protocol.md, "Where state lives"): AGENTBAR_HOME when it is
// an absolute path, ~/.agentbar otherwise. A relative value is ignored, not refused:
// a hook must never fail its host.
const stateRoot = () => {
  const v = process.env.AGENTBAR_HOME || "";
  return path.isAbsolute(v) ? v.replace(/\/+$/, "") || "/" : path.join(os.homedir(), ".agentbar");
};
const stateDir = path.join(stateRoot(), "state.d");

let p = {};
try { p = JSON.parse(process.argv[2] || "{}"); } catch {}

const type = p.type || "";
if (!type.includes("complete")) process.exit(0);

// Have the real hooks taken over? Read Codex's own config rather than guessing from
// the row: the row after a finished turn looks the same whoever wrote it. Both
// conditions are required — a wired-but-untrusted hook never runs, and standing down
// for one would leave the session invisible.
const codexHome = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
const configPath = path.join(codexHome, "config.toml");
try {
  const toml = fs.readFileSync(configPath, "utf8");
  const wired = toml.includes("# >>> agentbar >>>") && toml.includes("/.agentbar/hooks/codex/hook.js");
  // Codex writes this entry when the human accepts the hook; the key is
  // "<source path>:<event>:<group>:<index>".
  const trusted = toml.includes(`hooks.state."${configPath}:session_start:`);
  if (wired && trusted) process.exit(0);
} catch {
  // No config, unreadable config: carry on writing. Falling silent on an unreadable
  // file would hide every Codex session for a reason nobody could see.
}

const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64) || "unknown";
// A lone surrogate anywhere in a value — not only one a cut created — makes Swift's
// JSONSerialization reject the whole file, and an unreadable state file hides the
// session from every frontend until the next clean write. It cannot be caught after
// stringify, which escapes it into six harmless-looking characters, so it is caught
// on the values on the way out.
const paired = (k, v) => (typeof v === "string"
  ? v.replace(/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/g, "")
  : v);
// Never end a cut on a lone high surrogate: JSON.stringify escapes one happily,
// but Swift's JSONSerialization rejects the whole file — and an unreadable state
// file hides the session from every frontend until the next clean write.
const sliceSafe = (s, n) => {
  const cut = s.slice(0, n);
  const last = cut.charCodeAt(cut.length - 1);
  return last >= 0xd800 && last <= 0xdbff ? cut.slice(0, -1) : cut;
};
const oneLine = (s) => sliceSafe(String(s).replace(/\s+/g, " ").trim(), 120);
// Prefix INSIDE the cap: the protocol limits session ids (= file names) to 64 chars.
const id = safeId("codex-" + (p["thread-id"] || p["turn-id"] || String(process.ppid)));
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

// Codex has no session-end event, and the id above is per thread/turn — so each
// finished turn leaves its own row behind. Neither sweeper reaches them: a codex
// that stays open keeps its pid alive (which is what normally retires a row), so
// they sat in the bar until the 24h staleness cut, three deep for one session.
// Writing this row is itself the proof that the earlier ones are over: a codex
// process shows one conversation at a time. Same pid only — a second codex in
// another tab owns its own rows, and a pid of 0 would match every one of them.
const retirePredecessors = () => {
  const owner = process.ppid;
  if (!(owner > 0)) return;
  for (const f of fs.readdirSync(stateDir)) {
    if (!f.endsWith(".json") || f === id + ".json") continue;
    let prior = null;
    try { prior = JSON.parse(fs.readFileSync(path.join(stateDir, f), "utf8")); } catch { continue; }
    if (prior && prior.agent === "codex" && Number(prior.pid) === owner)
      fs.rmSync(path.join(stateDir, f), { force: true });
  }
};

try {
  fs.mkdirSync(stateDir, { recursive: true });
  const tmp = file + "." + process.pid + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(out, paired));
  fs.renameSync(tmp, file);
  // After the write, never before: a sweep that ran first and then failed to
  // write would take the session out of the bar entirely.
  try { retirePredecessors(); } catch {}
} catch (e) {
  // Single stderr line per invocation — enough of a trail to explain "AgentBar
  // shows nothing", too little to be noise. Self-swallowing: never throws, never
  // delays the exit.
  try { console.error("[agentbar] state write " + file + " failed: " + ((e && e.message) || e)); } catch {}
}
