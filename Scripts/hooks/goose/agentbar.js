#!/usr/bin/env node
// AgentBar bridge for goose's lifecycle hooks (goose plugins, hooks/hooks.json).
// Maps the stdin payload's `event` to `agentbar report`. Observe-only: it prints
// nothing — on PreToolUse an empty stdout with exit 0 is goose's "allow", the
// same as no hook at all — and every failure path still exits 0.
"use strict";
const fs = require("fs"), path = require("path"), cp = require("child_process");

process.on("uncaughtException", () => process.exit(0));

// The CLI: $AGENTBAR_CLI, then `agentbar` on PATH, then the one in this checkout
// (this file is Scripts/hooks/goose/agentbar.js; node resolves a symlinked plugin
// directory to its real path, so the relative one holds for a linked install).
const resolveCli = () => {
  const env = process.env.AGENTBAR_CLI;
  if (env && path.isAbsolute(env) && fs.existsSync(env)) return env;
  for (const d of (process.env.PATH || "").split(path.delimiter)) {
    const p = d && path.join(d, "agentbar");
    try { if (p && fs.statSync(p).isFile()) return p; } catch {}
  }
  const local = path.join(__dirname, "..", "..", "cli", "agentbar");
  return fs.existsSync(local) ? local : null;
};

// goose runs a hook through `sh -c`, so the hook's parent may be that shell — a
// process gone the moment the hook is. The row needs a pid that lives as long as
// goose: walk up past any shell to the first process that is not one.
const SHELLS = /^-?(sh|bash|dash|zsh|ksh|mksh)$/;
const agentPid = () => {
  let pid = process.ppid;
  for (let i = 0; i < 4 && pid > 1; i++) {
    let out = "";
    try { out = cp.execFileSync("ps", ["-o", "ppid=,comm=", "-p", String(pid)], { encoding: "utf8", timeout: 1000 }).trim(); }
    catch { break; }
    const m = /^(\d+)\s+(.+)$/.exec(out);
    if (!m || !SHELLS.test(path.basename(m[2]))) break;
    pid = Number(m[1]);
  }
  return pid;
};

// "developer__shell" -> "shell: ls -la"; the CLI one-lines and caps it.
const toolLabel = (name, input) => {
  const short = String(name || "tool").split("__").pop();
  const i = input && typeof input === "object" ? input : {};
  const arg = [i.command, i.path, i.source].find((v) => typeof v === "string" && v);
  return arg ? `${short}: ${arg}` : short;
};

const STATE = {
  SessionStart: "idle",
  UserPromptSubmit: "thinking",
  PreToolUse: "tool",
  PostToolUse: "thinking",
  PostToolUseFailure: "thinking",
  Stop: "done",
  SessionEnd: "end",
};

let raw = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (c) => { raw += c; });
process.stdin.on("end", () => {
  let p = {};
  try { p = JSON.parse(raw) || {}; } catch {}
  if (typeof p !== "object" || Array.isArray(p)) p = {};
  const state = STATE[p.event];
  const cli = state && p.session_id ? resolveCli() : null;
  if (!cli) process.exit(0);

  const args = ["report", "--agent", "goose", "--name", "Goose",
    "--session", "goose-" + String(p.session_id), "--state", state, "--pid", String(agentPid())];
  // Tool events carry the session's directory; the others inherit goose's cwd.
  const cwd = typeof p.working_dir === "string" && path.isAbsolute(p.working_dir) ? p.working_dir : "";
  // --project too: the CLI otherwise keeps the name the first report gave the row.
  if (cwd) args.push("--cwd", cwd, "--project", path.basename(cwd));
  if (state === "tool") args.push("--label", toolLabel(p.tool_name, p.tool_input));
  if (p.event === "UserPromptSubmit" && typeof p.message === "string") args.push("--prompt", p.message);
  if (p.event === "Stop" && typeof p.last_assistant_message === "string") args.push("--recap", p.last_assistant_message);

  try {
    cp.execFileSync(process.execPath, [cli, ...args], { stdio: "ignore", timeout: 5000 });
  } catch {}
  process.exit(0);
});
