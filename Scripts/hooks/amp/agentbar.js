// AgentBar bridge for Amp, as an Amp plugin (~/.config/amp/plugins/agentbar.js).
// Maps Amp's plugin events to `agentbar report`. Observe-only: it listens to the
// fire-and-forget events and nothing else — not `tool.call`, the one event whose
// handler returns a decision, so this plugin can never be why a tool ran or did
// not. Every handler swallows its own errors.
import fs from "node:fs";
import path from "node:path";
import { execFile, execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

// The CLI: $AGENTBAR_CLI, then `agentbar` on PATH, then the one in the checkout
// this file lives in (Scripts/hooks/amp/ -> Scripts/cli/agentbar).
const resolveCli = () => {
  const env = process.env.AGENTBAR_CLI;
  if (env && path.isAbsolute(env) && fs.existsSync(env)) return env;
  for (const d of (process.env.PATH || "").split(path.delimiter)) {
    const p = d && path.join(d, "agentbar");
    try { if (p && fs.statSync(p).isFile()) return p; } catch {}
  }
  try {
    const here = path.dirname(fs.realpathSync(fileURLToPath(import.meta.url)));
    const local = path.join(here, "..", "..", "cli", "agentbar");
    if (fs.existsSync(local)) return local;
  } catch {}
  return null;
};

// The pid the rows live and die by. Amp documents plugins as long-lived processes
// run by Bun, not whose child they are: when the parent is a shell, this process
// is the Amp the user started (plugins in-process) and its own pid is the one;
// otherwise the parent is the Amp that spawned the plugin host.
const SHELLS = /^-?(sh|bash|dash|zsh|ksh|mksh|fish)$/;
const ampPid = () => {
  try {
    const comm = execFileSync("ps", ["-o", "comm=", "-p", String(process.ppid)], { encoding: "utf8", timeout: 1000 }).trim();
    if (SHELLS.test(path.basename(comm))) return process.pid;
  } catch {}
  return process.ppid;
};

const str = (v) => (typeof v === "string" ? v : "");

export default function agentbar(amp) {
  const cli = resolveCli();
  if (!cli) return;
  const pid = String(ampPid());
  let cwd = process.cwd();
  // The plugin's own cwd need not be the workspace; Amp's docs get it via `pwd`.
  // Every report waits for the answer, so none goes out with the wrong directory.
  let pwd = Promise.resolve();
  try {
    if (typeof amp.$ === "function") {
      pwd = Promise.resolve(amp.$`pwd`)
        .then((r) => { const d = str(r && r.stdout).trim(); if (path.isAbsolute(d)) cwd = d; })
        .catch(() => {});
    }
  } catch {}

  // One report at a time, in order: a `done` overtaken by a late `thinking`
  // would leave a finished thread looking busy.
  // A `pwd` that never answers must not hold every report back.
  let chain = Promise.race([pwd, new Promise((r) => setTimeout(r, 3000).unref?.())]);
  const report = (thread, state, extra = []) => {
    const id = str(thread && thread.id);
    if (!id) return chain;
    chain = chain.then(() => new Promise((resolve) => {
      const args = ["report", "--agent", "amp", "--name", "Amp", "--session", "amp-" + id,
        "--state", state, "--pid", pid, "--cwd", cwd, "--project", path.basename(cwd), ...extra];
      try { execFile(cli, args, { timeout: 5000 }, () => resolve()); } catch { resolve(); }
    }));
    return chain;
  };

  // Handlers queue their report and return at once: Amp is never kept waiting on
  // the bar.
  const on = (event, fn) => {
    try { amp.on(event, (e) => { try { fn(e || {}); } catch {} }); } catch {}
  };
  on("session.start", (e) => report(e.thread, "idle"));
  on("agent.start", (e) => report(e.thread, "thinking", ["--prompt", str(e.message)]));
  // After the fact: Amp's only event before a tool runs is `tool.call`, which
  // decides; so the label names the tool that just finished, not the next one.
  on("tool.result", (e) => report(e.thread, "tool",
    ["--label", (str(e.tool) || "tool") + (e.status === "error" ? " failed" : "")]));
  on("agent.end", (e) => {
    if (e.status === "error") return report(e.thread, "error", ["--label", "Failed"]);
    if (e.status === "cancelled") return report(e.thread, "idle", ["--label", "Cancelled"]);
    return report(e.thread, "done");
  });
}
