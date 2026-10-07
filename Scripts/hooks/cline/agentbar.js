#!/usr/bin/env node
// AgentBar bridge for Cline's file hooks (VS Code extension and the Cline CLI).
// One script for every hook: it reads the hook's name from the stdin payload and
// maps it to `agentbar report`. Observe-only: the only thing it ever prints is
// {"cancel":false}, the documented "carry on", and every failure path exits 0.
"use strict";
const fs = require("fs"), path = require("path"), cp = require("child_process");

// Answer first: PreToolUse waits on stdout, and nothing below may change it.
try { fs.writeSync(1, '{"cancel":false}\n'); } catch {}
process.on("uncaughtException", () => process.exit(0));

// The CLI: $AGENTBAR_CLI, then `agentbar` on PATH, then the one in this checkout.
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

// The VS Code extension runs a hook through `sh -c <path>`; the row needs a pid
// that lives as long as Cline (the extension host, or the `cline` CLI), not the
// shell. Walk up past any shell to the first process that is not one.
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

const str = (v) => (typeof v === "string" ? v : "");
// The extension sends parameters as strings (objects JSON-stringified); the CLI
// sends the raw input. Either way: the first useful string in it.
const toolLabel = (name, input) => {
  const i = input && typeof input === "object" ? input : {};
  const first = (v) => (Array.isArray(v) ? v.find((x) => typeof x === "string") : undefined);
  const arg = [i.command, first(i.commands), i.path, first(i.paths), i.file_path, i.regex, i.url]
    .find((v) => typeof v === "string" && v);
  return arg ? `${name}: ${arg}` : String(name || "tool");
};

// Two dialects of the same hooks: the extension names them by file
// (TaskStart, PreToolUse, …), the CLI by event (agent_start, tool_call, …).
const map = (p) => {
  switch (str(p.hookName)) {
    case "TaskStart": case "TaskResume":
      return { state: "thinking", prompt: str(((p.taskStart || p.taskResume || {}).taskMetadata || {}).initialTask) };
    case "agent_start": case "agent_resume":
      return { state: "thinking" };
    case "UserPromptSubmit": case "prompt_submit":
      return { state: "thinking", prompt: str((p.userPromptSubmit || {}).prompt) };
    case "PreToolUse": case "tool_call": {
      const t = p.tool_call || {}, x = p.preToolUse || {};
      return { state: "tool", label: toolLabel(str(t.name) || str(x.toolName), t.input || x.parameters) };
    }
    case "PostToolUse": case "tool_result":
      return { state: "thinking" };
    case "TaskComplete": case "agent_end":
      return { state: "done", recap: str((p.turn || {}).outputText) };
    case "TaskCancel": case "agent_abort":
      return { state: "idle", label: "Cancelled" };
    case "TaskError": case "agent_error":
      return { state: "error", label: str((p.error || {}).message) || "Failed" };
    case "Notification": {
      // Wired in older extension builds only: the one hook that says Cline waits.
      const n = p.notification || {};
      if (n.waitingForUserInput || n.requiresUserAction) return { state: "question", label: str(n.message) };
      return null;
    }
    case "SessionShutdown": case "session_shutdown":
      return { state: "end" };
    default:
      return null;
  }
};

let raw = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (c) => { raw += c; });
process.stdin.on("end", () => {
  let p = {};
  try { p = JSON.parse(raw) || {}; } catch {}
  if (typeof p !== "object" || Array.isArray(p)) p = {};
  const m = map(p);
  const task = str(p.taskId);
  const cli = m && task ? resolveCli() : null;
  if (!cli) process.exit(0);

  const args = ["report", "--agent", "cline", "--name", "Cline",
    "--session", "cline-" + task, "--state", m.state, "--pid", String(agentPid())];
  const root = Array.isArray(p.workspaceRoots) ? str(p.workspaceRoots[0]) : "";
  // --project too: the CLI otherwise keeps the name the first report gave the row.
  if (root && path.isAbsolute(root)) args.push("--cwd", root, "--project", path.basename(root));
  if (m.label) args.push("--label", m.label);
  if (m.prompt) args.push("--prompt", m.prompt);
  if (m.recap) args.push("--recap", m.recap);

  try {
    cp.execFileSync(process.execPath, [cli, ...args], { stdio: "ignore", timeout: 5000 });
  } catch {}
  process.exit(0);
});
