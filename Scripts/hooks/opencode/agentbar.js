// AgentBar bridge for OpenCode. Loaded as an OpenCode plugin
// (~/.config/opencode/plugins/agentbar.js), it maps the event bus to a
// per-session state file in ~/.agentbar/state.d/. Observe-only: writes state,
// decides nothing, and every handler swallows its own errors — a status bridge
// must never take an OpenCode session down with it.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, execSync } from "node:child_process";

const AGENT = "opencode";
const BUNDLE_ID = "com.michalstrnadel.agentbar";
const base = path.join(os.homedir(), ".agentbar");
const stateDir = path.join(base, "state.d");

const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64) || "unknown";
// Never end a cut on a lone high surrogate: JSON.stringify escapes one happily,
// but Swift's JSONSerialization rejects the whole file — and an unreadable state
// file hides the session from every frontend until the next clean write.
const sliceSafe = (s, n) => {
  const cut = s.slice(0, n);
  const last = cut.charCodeAt(cut.length - 1);
  return last >= 0xd800 && last <= 0xdbff ? cut.slice(0, -1) : cut;
};
const oneLine = (s) => sliceSafe(String(s).replace(/\s+/g, " ").trim(), 120);
const writeAtomic = (file, obj) => {
  const tmp = file + "." + process.pid + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(obj));
  fs.renameSync(tmp, file);
};
// The macOS app, or the CLI's watch/waybar heartbeat (any platform).
const running = () => {
  if (process.platform === "darwin") {
    try { execSync("pgrep -x AgentBar", { stdio: "ignore" }); return true; } catch {}
  }
  try {
    const w = JSON.parse(fs.readFileSync(path.join(base, "watcher.json"), "utf8"));
    return Date.now() / 1000 - w.ts < 60;
  } catch { return false; }
};

export const AgentBar = async ({ directory }) => {
  const cwd = directory || process.cwd();

  // OpenCode has no per-session "the window closed" event, and every session
  // shares the server's pid — so the app's pid-based pruning can only ever drop
  // them all at once. Retire finished rows on our own clock instead: the "Done"
  // line stays readable for a while, then the file goes.
  const RETIRE_MS = 10 * 60 * 1000;
  const retireTimers = new Map();
  const cancelRetire = (id) => {
    const t = retireTimers.get(id);
    if (t) { clearTimeout(t); retireTimers.delete(id); }
  };

  const write = (id, patch) => {
    // Any new activity on a session means it is not finished after all.
    cancelRetire(id);
    try {
      fs.mkdirSync(stateDir, { recursive: true });
      const statePath = path.join(stateDir, safeId(id) + ".json");
      let prev = {};
      try { prev = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch {}
      writeAtomic(statePath, {
        agent: AGENT, project: path.basename(cwd), cwd,
        sessionId: String(id), entrypoint: "cli",
        term_program: process.env.TERM_PROGRAM || "",
        // The plugin runs inside the opencode process, so this pid is the
        // session's own liveness handle.
        pid: process.pid, started: true,
        started_at: prev.started_at || Math.floor(Date.now() / 1000),
        ...(prev.prompt ? { prompt: prev.prompt } : {}),
        ...patch, ts: Math.floor(Date.now() / 1000),
      });
    } catch {}
  };
  const remove = (id) => {
    cancelRetire(id);
    try { fs.rmSync(path.join(stateDir, safeId(id) + ".json"), { force: true }); } catch {}
  };
  const retireLater = (id) => {
    cancelRetire(id);
    const t = setTimeout(() => { retireTimers.delete(id); remove(id); }, RETIRE_MS);
    // Never hold the OpenCode server open just to tidy a status file.
    if (typeof t.unref === "function") t.unref();
    retireTimers.set(id, t);
  };
  // Session ids appear in different shapes across the event bus.
  const sid = (p) => p?.sessionID || p?.info?.id || p?.info?.sessionID || "";
  // Whatever the error payload chose to call itself; "failed" when it says
  // nothing useful.
  const errorText = (p) => {
    const e = p?.error;
    if (typeof e === "string" && e.trim()) return e;
    return e?.data?.message || e?.message || e?.name || "";
  };

  let launched = false;
  const launchOnce = () => {
    // Latch on the first call either way: the pgrep is a blocking exec inside
    // OpenCode's own event loop, and once is all it's owed.
    if (launched || process.platform !== "darwin") return;
    launched = true;
    if (running()) return;
    try { spawn("open", ["-g", "-b", BUNDLE_ID], { stdio: "ignore", detached: true }).unref(); }
    catch {}
  };
  // Subagent child sessions ride inside their parent's work — a row per child
  // would triple the list every time OpenCode fans out.
  const children = new Set();
  // OpenCode publishes session.error and then, for the same turn, session.idle.
  // Taken at face value the idle overwrites the failure with a green "done"
  // and a celebration cue, so the error claims the turn until real work starts.
  const failed = new Set();

  return {
    "tool.execute.before": async (input) => {
      const id = input?.sessionID; if (!id || children.has(id)) return;
      failed.delete(id); // real work: the last turn's failure is history
      write(id, { state: "tool", label: oneLine(input?.tool || "Using tool") });
    },
    "tool.execute.after": async (input) => {
      const id = input?.sessionID; if (!id || children.has(id)) return;
      write(id, { state: "thinking", label: "Thinking…" });
    },
    event: async ({ event }) => {
      const type = event?.type || "";
      const p = event?.properties || {};
      const id = sid(p);
      if (id && children.has(id)) return;
      switch (type) {
        case "session.created":
          launchOnce();
          if (id && p?.info?.parentID) { children.add(id); break; }
          if (id) write(id, { state: "idle", label: "", started: false });
          break;
        case "message.updated":
          // A user message opens the turn — the row starts thinking even when
          // no tool ever runs, so text-only turns don't pop up already done.
          if (id && p?.info?.role === "user") {
            failed.delete(id);
            write(id, { state: "thinking", label: "Thinking…" });
          }
          break;
        case "session.updated": {
          // The session title is OpenCode's own one-line name for the task.
          if (!id) break;
          const title = p?.info?.title;
          if (typeof title === "string" && title.trim()) {
            try {
              const statePath = path.join(stateDir, safeId(id) + ".json");
              const prev = JSON.parse(fs.readFileSync(statePath, "utf8"));
              writeAtomic(statePath, { ...prev, prompt: oneLine(title),
                                       ts: Math.floor(Date.now() / 1000) });
            } catch {}
          }
          break;
        }
        case "permission.asked":
          if (id) write(id, { state: "permission",
                              label: oneLine(p?.title || p?.permission?.title || "needs approval") });
          break;
        case "permission.replied":
          if (id) write(id, { state: "thinking", label: "Thinking…" });
          break;
        case "session.idle":
          if (!id) break;
          // The idle that trails a failure is bookkeeping, not a finish.
          if (failed.has(id)) break;
          write(id, { state: "done", label: "" });
          retireLater(id);
          break;
        case "session.error":
          // A failed turn is its own state — reporting it as "done" would put a
          // green tick and a celebration cue on an error.
          if (id) {
            failed.add(id);
            write(id, { state: "error", label: oneLine(errorText(p)) });
            retireLater(id);
          }
          break;
        case "session.deleted":
          if (id) { children.delete(id); failed.delete(id); remove(id); }
          break;
        default:
          break;
      }
    },
  };
};
