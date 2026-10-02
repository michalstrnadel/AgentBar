#!/usr/bin/env node
// Claude Code PermissionRequest -> remote approval (and remote question answering)
// from the AgentBar menu and island.
// Writes a request file, then BLOCKS polling answers.d for the user's decision;
// for permissions, returning a decision replaces the terminal prompt entirely;
// for AskUserQuestion, the terminal wizard renders alongside the wait and whoever
// answers first — terminal or AgentBar — wins.
// Deliberate exception to "hooks never block": the session is already waiting on
// a human, and every failure path (no app, app quits, timeout, junk input, signal,
// filesystem error) exits silently so the ordinary terminal prompt appears instead.
// Usage: node permission.js   (PermissionRequest hook JSON on stdin)
//
// Serves GitHub Copilot CLI too, the same way lifecycle.js and update.js already
// do — but its `permissionRequest` is the one event in either dialect that speaks
// camelCase and carries RAW tool ids, so it is normalised on the way in and its
// decision is spelled differently on the way out. Everything between is shared.

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

// The state root (docs/protocol.md, "Where state lives"): AGENTBAR_HOME when it is
// an absolute path, ~/.agentbar otherwise. A relative value is ignored, not refused:
// a hook must never fail its host.
const stateRoot = () => {
  const v = process.env.AGENTBAR_HOME || "";
  return path.isAbsolute(v) ? v.replace(/\/+$/, "") || "/" : path.join(os.homedir(), ".agentbar");
};
const base = stateRoot();
const stateDir = path.join(base, "state.d");
const reqDir = path.join(base, "requests.d");
const ansDir = path.join(base, "answers.d");

const timeoutSecRaw = Number(process.env.AGENTBAR_APPROVAL_TIMEOUT);
const timeoutSec = Number.isFinite(timeoutSecRaw) && timeoutSecRaw > 0 ? timeoutSecRaw : 600;
const TIMEOUT_MS = 1000 * timeoutSec;
const POLL_MS = 100;

// Set by the hook config, the same reuse Qwen and Copilot already get on the other
// scripts. It names the session rows, so getting it wrong would file a Copilot
// permission under Claude.
const agent = process.env.AGENTBAR_AGENT || "claude";
// Which host is asking, decided from the payload itself in run(). Module-level
// because respond() needs it and runs long after.
let dialect = "claude";

const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64) || "unknown";
// A prefix on the row's name, for an agent whose rows another writer already
// names. Codex's notify bridge has always written `codex-<thread-id>`, and
// `Weight.codex` finds the rollout by stripping that prefix straight back off —
// so the hooks have to agree with it, or the token weight quietly disappears and
// one session turns into two rows. Empty for every other agent, which is why
// nothing else changes shape.
const idPrefix = String(process.env.AGENTBAR_ID_PREFIX || "").replace(/[^A-Za-z0-9_.-]/g, "");
const rowId = (s) => (idPrefix ? safeId(idPrefix + safeId(s)) : safeId(s));
const writeAtomic = (file, obj) => {
  const tmp = file + "." + process.pid + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(obj, paired));
  fs.renameSync(tmp, file);
};
// "Somebody can answer": the macOS app (pgrep), or the cross-platform CLI's
// watch/waybar mode, which heartbeats ~/.agentbar/watcher.json while it runs.
const appRunning = () => {
  if (process.env.AGENTBAR_FORCE_APP === "1") return true;
  if (process.env.AGENTBAR_FORCE_APP === "0") return false;
  if (process.platform === "darwin") {
    try { cp.execSync("pgrep -x AgentBar", { stdio: "ignore" }); return true; } catch {}
  }
  try {
    const w = JSON.parse(fs.readFileSync(path.join(base, "watcher.json"), "utf8"));
    return Date.now() / 1000 - w.ts < 60;
  } catch { return false; }
};

// Stable JSON: objects re-keyed in sorted order at every depth, so two parses of
// the same document compare equal regardless of serializer key ordering.
const canonical = (v) => {
  if (Array.isArray(v)) return "[" + v.map(canonical).join(",") + "]";
  if (v && typeof v === "object")
    return "{" + Object.keys(v).sort().map((k) => JSON.stringify(k) + ":" + canonical(v[k])).join(",") + "}";
  return JSON.stringify(v);
};

// A lone surrogate anywhere in a value — not only one a cut created — makes Swift's
// JSONSerialization reject the whole file, and an unreadable state file hides the
// session from every frontend until the next clean write. It cannot be caught after
// stringify, which escapes it into six harmless-looking characters, so it is caught
// on the values on the way out.
const paired = (k, v) => (typeof v === "string"
  ? v.replace(/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/g, "")
  : v);
// Never end a cut on a lone high surrogate. JSON.stringify happily escapes one,
// but Swift's JSONSerialization refuses the whole file — and an unreadable
// request blocks the approval while the hook waits for an answer no frontend
// can give. Every truncation in this file goes through here.
const sliceSafe = (s, n) => {
  const cut = s.slice(0, n);
  const last = cut.charCodeAt(cut.length - 1);
  return last >= 0xd800 && last <= 0xdbff ? cut.slice(0, -1) : cut;
};

const oneLine = (s, n = 60) => {
  s = String(s || "").split("\n")[0].trim();
  return s.length > n ? sliceSafe(s, n - 1) + "…" : s;
};

const cap = (s, n) => {
  s = String(s == null ? "" : s);
  return s.length > n ? sliceSafe(s, n) + "…" : s;
};

// Structured, per-field-capped detail so the menu can show a mini-diff / full command
// inline (not just a hover tooltip). Null for tools where the one-line display is enough.
function buildContext(tool, input) {
  const t = String(tool || ""), i = input || {};
  if (t === "Bash") return { kind: "bash", command: cap(i.command, 2000) };
  if (t === "Edit") return { kind: "diff", old: cap(i.old_string, 1500), new: cap(i.new_string, 1500), more: 0 };
  if (t === "MultiEdit") {
    const edits = Array.isArray(i.edits) ? i.edits : [];
    const first = edits[0] || {};
    return { kind: "diff", old: cap(first.old_string, 1500), new: cap(first.new_string, 1500),
             more: Math.max(0, edits.length - 1) };
  }
  if (t === "Write") return { kind: "write", preview: cap(i.content, 1200) };
  if (t === "AskUserQuestion") return { kind: "question", questions: cappedQuestions(i) };
  // The plan is the whole point of an ExitPlanMode request — carry it, so the
  // island can show the full text. Allow approves the plan; deny keeps planning.
  if (t === "ExitPlanMode") return { kind: "plan", plan: cap(i.plan, 8000) };
  return null;
}

// The tool allows up to 4 questions of up to 4 options; cap defensively anyway so a
// malformed payload can't balloon the request file the frontends read.
function cappedQuestions(input) {
  const qs = Array.isArray((input || {}).questions) ? input.questions : [];
  return qs.slice(0, 4).map((q) => {
    const seen = new Set();
    return {
      question: cap((q || {}).question, 300),
      header: cap((q || {}).header, 60),
      multiSelect: (q || {}).multiSelect === true,
      // Labels are the answer protocol's identity — a duplicate label would make
      // a valid-looking selection fail validation, so only the first survives.
      options: (Array.isArray((q || {}).options) ? q.options : []).slice(0, 6).map((o) => ({
        label: cap((o || {}).label, 100),
        description: cap((o || {}).description, 200),
      })).filter((o) => o.label && !seen.has(o.label) && seen.add(o.label)),
    };
  }).filter((q) => q.question && q.options.length);
}

// An answer may only say things the request itself offered — same forgery posture
// as the "always" rule check. One array of chosen labels per question; single-select
// questions take exactly one. Anything off-shape degrades to defer (terminal wizard).
function validAnswers(answers, questions) {
  if (!Array.isArray(answers) || answers.length !== questions.length) return false;
  return questions.every((q, i) => {
    const a = answers[i];
    if (!Array.isArray(a) || a.length === 0) return false;
    if (!q.multiSelect && a.length !== 1) return false;
    const labels = q.options.map((o) => o.label);
    return a.every((s) => typeof s === "string" && labels.includes(s)) &&
           new Set(a).size === a.length;
  });
}

// What the model reads instead of the wizard's selection. Deny-with-message is the
// only channel a PermissionRequest hook has: the message lands as the tool result,
// the wizard is dismissed, and the model continues with the answer (verified on
// Claude Code 2.1.234 — an answer given in the terminal first wins the race and the
// late deny is ignored cleanly).
// A note the human typed next to Deny — "use pnpm here", "not on main". It is the
// only way a PermissionRequest hook can steer an agent rather than just stop it:
// the deny message lands as the tool result, which the model reads. One line,
// no control characters, capped; anything that isn't a non-empty string means
// there is no note and the denial goes out exactly as it always has.
const NOTE_MAX = 500;
function cleanNote(v) {
  if (typeof v !== "string") return "";
  // Lone surrogates out too: a frontend that cut a note mid-emoji must not make
  // the decision unparseable to a host whose JSON reader refuses them (Codex's
  // serde does) — a Deny that silently failed to land is the worst outcome here.
  const s = paired("", v).replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/\s+/g, " ").trim();
  return s.length > NOTE_MAX ? sliceSafe(s, NOTE_MAX - 1) + "…" : s;
}

function denyMessage(note) {
  return 'The user denied this tool call (via AgentBar) and said: "' + note + '". ' +
    "Do not retry the same call; follow the user's instruction instead.";
}

function planMessage(note) {
  const base = "The user reviewed this plan and wants it refined before any " +
    "changes are made. Stay in plan mode and keep planning.";
  return note ? base + ' Their feedback: "' + note + '"' : base;
}

function answerMessage(questions, answers) {
  if (questions.length === 1)
    return 'User answered "' + answers[0].join('", "') + '" (via AgentBar). ' +
           "Proceed with this answer; do not ask again.";
  return "User answered (via AgentBar):\n" +
    questions.map((q, i) => "- " + (q.header || q.question) + ": " + answers[i].join(", ")).join("\n") +
    "\nProceed with these answers; do not ask again.";
}

// Copilot CLI's permissionRequest, rewritten into the shape the rest of this file
// reads. Two traps, both from a payload logged off a live 1.0.85 session:
//
//   - it is the ONLY Copilot event that speaks camelCase; every other one arrives
//     in the snake_case Claude dialect, so a handler that assumes one shape reads
//     undefined throughout;
//   - `toolName` is the raw id (`bash`), not remapped to Claude's (`Bash`) the way
//     the PascalCase events are.
//
// Only `bash` is remapped here, because it is the only tool whose *input* shape is
// verified. Renaming `view` to `Read` would make displaySummary look for a
// `file_path` that may not exist and render "Read: " with nothing after it — worse
// than showing the id Copilot actually used. Add the others as they are observed.
const COPILOT_TOOLS = { bash: "Bash" };

function normaliseCopilot(p) {
  return {
    session_id: p.sessionId,
    tool_name: COPILOT_TOOLS[p.toolName] || p.toolName,
    tool_input: p.toolInput,
    cwd: p.cwd,
    // Deliberately dropped. GitHub documents the output contract as
    // {behavior, message, interrupt} — there is no channel for a standing rule at
    // all, so "Always allow" has nowhere to go no matter what permissionSuggestions
    // turns out to contain. Empty here makes every "always" degrade to a one-shot
    // allow, which is the honest behaviour.
    permission_suggestions: [],
  };
}

function displaySummary(tool, input, cwd) {
  const t = String(tool || "unknown");
  const i = input || {};
  if (t === "Bash") return "Bash: " + oneLine(i.command);
  if (["Edit", "Write", "MultiEdit", "NotebookEdit", "Read"].includes(t)) {
    // Relative to the session's cwd, so the 60-char cut keeps the file name visible.
    let f = String(i.file_path || i.notebook_path || "");
    if (cwd && f.startsWith(cwd + "/")) f = f.slice(cwd.length + 1);
    return t + ": " + oneLine(f);
  }
  if (t === "WebFetch") return "WebFetch: " + oneLine(i.url);
  if (t === "WebSearch") return "WebSearch: " + oneLine(i.query);
  if (t === "ExitPlanMode") return "Plan ready for review";
  const m = t.match(/^mcp__(.+?)__(.+)$/);
  if (m) return m[1] + ": " + m[2];
  // A tool this file has no mapping for — every Copilot id but `bash`, and any
  // future Claude tool. The bare name says almost nothing, so borrow the first
  // string the input carries; it is nearly always the interesting part.
  const first = Object.values(i).find((v) => typeof v === "string" && v.trim());
  return first ? t + ": " + oneLine(first) : t;
}

let raw = "", started = false;
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", run);
process.stdin.on("error", run);
setTimeout(run, 1000); // stdin never arrived: bail, never hang the session start

function run() {
  if (started) return; started = true;
  if (!appRunning()) process.exit(0); // nobody to answer -> terminal prompt
  if (!raw) process.exit(0); // stdin closed (or never arrived) empty: nothing to request

  // Junk on stdin is not a permission request. Bail here rather than posting a
  // garbled "unknown" row and blocking the session for the whole approval
  // timeout — same silent-to-terminal-prompt behaviour as empty stdin.
  let p;
  try { p = JSON.parse(raw); } catch { process.exit(0); }
  if (!p || typeof p !== "object" || Array.isArray(p)) process.exit(0);

  // `hookName` is the only field that tells the two dialects apart — Claude's
  // payload has no such key, and Copilot's is this event's own name.
  if (p.hookName === "permissionRequest") { dialect = "copilot"; p = normaliseCopilot(p); }

  try {

    // AskUserQuestion is Claude asking the human, not asking for permission. The
    // terminal wizard renders regardless of the hook while it waits, so blocking
    // costs the terminal nothing — it opens a second way to answer: the request
    // file carries the options, the frontend writes the chosen labels back, and
    // the hook turns them into a deny-with-message the model reads as the answer.
    // Whoever answers first wins; the loser's decision is ignored upstream.
    const isQuestion = p.tool_name === "AskUserQuestion";
    const questions = isQuestion ? cappedQuestions(p.tool_input) : null;
    // ExitPlanMode renders its own plan dialog alongside the hook the same way
    // (verified on 2.1.234): a hook deny dismisses it, but a hook allow is
    // IGNORED — approval picks the next permission mode, which a hook decision
    // cannot express. So a frontend approves plans by answering the dialog
    // itself (keystroke), and this hook's job is: carry the plan out, turn
    // "deny" into an explicit keep-planning message (a bare denial reads as
    // "stop" and ends the turn), and retire once the dialog is answered.
    const isPlan = p.tool_name === "ExitPlanMode";

    // A question whose options didn't decode can't be answered remotely: mark the
    // session and get out of the way — PostToolUse flips the state back after the
    // wizard is answered.
    if (isQuestion && questions.length === 0) {
      try {
        const q = (((p.tool_input || {}).questions || [])[0] || {});
        const statePath = path.join(stateDir, rowId(p.session_id) + ".json");
        fs.mkdirSync(stateDir, { recursive: true });
        let prev = {};
        try { prev = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch {}
        writeAtomic(statePath, { ...prev, agent, state: "question",
          label: "❓ " + oneLine(q.question || "Waiting for your answer"),
          // rowId, like the file this is being written into and like every other
          // writer of this row: a raw id here means the field and the file name
          // disagree for any agent that carries a prefix.
          sessionId: rowId(p.session_id), pid: process.ppid, started: true,
          ts: Math.floor(Date.now() / 1000) });
      } catch {}
      process.exit(0);
    }

    // Codex has no `prompt_id`; its `turn_id` repeats across the tools of one
    // turn exactly the way Claude's prompt id does, which is what the successor
    // guard below is built on.
    const name = rowId(p.session_id) + "-"
      + safeId(p.prompt_id || p.turn_id || String(process.pid));
    const reqPath = path.join(reqDir, name + ".json");
    const ansPath = path.join(ansDir, name + ".json");
    const display = isQuestion ? "Question: " + oneLine(questions[0].question)
                               : displaySummary(p.tool_name, p.tool_input, p.cwd);

    let pretty = "";
    try { pretty = JSON.stringify(p.tool_input || {}, null, 2); } catch {}
    if (pretty.length > 4096) pretty = sliceSafe(pretty, 4096) + "\n…";

    // Rule suggestions come from Claude Code and go back verbatim on "Always allow";
    // the hook never invents permission rules itself. Questions carry none.
    const suggestions = Array.isArray(p.permission_suggestions) ? p.permission_suggestions : [];
    const suggestion = isQuestion ? null : suggestions[0] || null;

    // The directory this session is working in. Both dialects send it and it was
    // dropped here until 1.28.0, which forced every reader to join back through
    // state.d on sessionId just to learn where a command was about to run — and a
    // rule that says "in this repository" cannot be evaluated without it. Omitted
    // rather than truncated when it is implausible: half a path is not a path, and
    // a prefix comparison against half a path would match the wrong directory.
    const cwd = typeof p.cwd === "string" && p.cwd.length <= 1024 ? p.cwd : "";

    // The file an edit names, as its own field. `toolInputPretty` is cut at 4 KB
    // and a cut is not JSON, so the app could not read the path back out of any
    // edit larger than that — its shape fell to `tool:Edit` and a deny rule for
    // `edit:migrations/*.sql` missed exactly the big migrations. Omitted when
    // implausible, for the reason `cwd` is.
    const ti = p.tool_input || {};
    const named = [ti.file_path, ti.notebook_path, ti.path, ti.filePath]
      .find((v) => typeof v === "string" && v);
    const filePath = named && named.length <= 1024 ? named : "";

    fs.mkdirSync(reqDir, { recursive: true });
    fs.mkdirSync(ansDir, { recursive: true });

    // The session row itself shows what's pending, even before the menu opens.
    // What it said just before is kept: an allowed tool goes back to being the
    // tool PreToolUse announced.
    let before = {};
    try {
      const statePath = path.join(stateDir, rowId(p.session_id) + ".json");
      fs.mkdirSync(stateDir, { recursive: true });
      let prev = {};
      try { prev = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch {}
      before = prev;
      writeAtomic(statePath, { ...prev, agent,
        state: isQuestion ? "question" : "permission",
        label: isQuestion ? "❓ " + oneLine(questions[0].question) : display,
        sessionId: rowId(p.session_id), pid: process.ppid, started: true,
        ts: Math.floor(Date.now() / 1000) });
    } catch {}

    // A leftover answer under this name (orphan of a crashed twin, prompt_id
    // reuse) must not be mistaken for the user's decision on THIS request.
    //
    // BEFORE the request is published, not after. The rename below is what makes
    // the request visible, and a frontend watching requests.d can answer within
    // microseconds of it — the app watches by fs event, not by poll. Clearing
    // afterwards left a window in which that prompt answer was deleted by this
    // cleanup, and the hook then waited out its full 10 minutes for a decision it
    // had already been given. Nobody can answer a request that does not exist yet,
    // so doing it first closes the window instead of narrowing it.
    try { fs.rmSync(ansPath, { force: true }); } catch {}

    writeAtomic(reqPath, {
      // safeId to match Session.id, which the app derives from the state file name.
      sessionId: rowId(p.session_id), agent,
      toolName: p.tool_name || "", display, toolInputPretty: pretty,
      ...(cwd ? { cwd } : {}),
      ...(filePath ? { filePath } : {}),
      context: buildContext(p.tool_name, p.tool_input),
      ruleSuggestion: suggestion, pid: process.ppid, hookPid: process.pid,
      ts: Math.floor(Date.now() / 1000),
    });

    // Request files are named <session>-<prompt>, and prompt ids repeat across
    // the tools of ONE turn — so a later tool's hook writes the same path we
    // did. This hook can outlive its own answer (a question answered in the
    // wizard, a plan approved in the dialog: both retire on a ~2s poll), so
    // "is this file still mine?" has to gate every destructive move. Deleting
    // a successor's request would strand its session on a prompt nobody can
    // answer, and eating its answer would be just as bad.
    const ownsRequest = () => {
      try {
        return JSON.parse(fs.readFileSync(reqPath, "utf8")).hookPid === process.pid;
      } catch { return true; } // unreadable or gone: nobody else claimed it
    };
    const cleanup = () => {
      if (!ownsRequest()) return;
      try { fs.rmSync(reqPath, { force: true }); } catch {}
      try { fs.rmSync(ansPath, { force: true }); } catch {}
    };
    process.on("exit", cleanup);
    // Claude Code kills hooks that overrun its own hook timeout; Node does not run
    // "exit" listeners on the default SIGTERM/SIGINT death, which would strand the
    // request file forever. Handling the signals ourselves guarantees cleanup runs.
    process.on("SIGTERM", () => { cleanup(); process.exit(0); });
    process.on("SIGINT", () => { cleanup(); process.exit(0); });

    const deadline = Date.now() + TIMEOUT_MS;
    const statePath = path.join(stateDir, rowId(p.session_id) + ".json");
    // The wizard renders alongside a question wait — and the plan dialog
    // alongside a plan wait — so both can be answered in the terminal while
    // this hook still polls. The next event then moves the session off the
    // waiting state — that's the retire signal: without it, the island card
    // would stay up (and answerable, uselessly) for the rest of the wait.
    const waitingState = isQuestion ? "question" : "permission";
    const answeredElsewhere = () => {
      try {
        const s = JSON.parse(fs.readFileSync(statePath, "utf8"));
        return s.state !== waitingState;
      } catch { return false; }
    };
    // Once this hook has answered, the row must stop saying "waiting on you": the
    // request file is gone with the hook, and a denied tool fires no PostToolUse,
    // so nothing else would move the row until the agent's next event — the bar
    // showed a wait for a request that no longer existed. Only while the row
    // still IS this hook's waiting state, so a newer event is never clobbered;
    // best-effort, like every other write here — the decision is already out.
    const settle = (state, label) => {
      try {
        let prev = {};
        try { prev = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch {}
        if (prev.state === waitingState) {
          writeAtomic(statePath, { ...prev, agent, state, label,
            ts: Math.floor(Date.now() / 1000) });
        }
      } catch {}
    };
    let ticks = 0;
    const timer = setInterval(() => {
      try {
        if (fs.existsSync(ansPath)) {
          // Checked here rather than every tick: an answer is the only thing
          // worth reading the request file for, and consuming one addressed to
          // a successor is exactly what the ownership guard exists to prevent.
          if (!ownsRequest()) {
            clearInterval(timer);
            process.exit(0);
          }
          let a = {};
          // Contract: the app writes answers atomically (tmp+rename), so a plain
          // read here never observes a partially written file.
          try { a = JSON.parse(fs.readFileSync(ansPath, "utf8")); } catch {}
          if (typeof a.hookPid === "number" && a.hookPid !== process.pid) {
            // The answer names the hook it was meant for — and it isn't this
            // one. Frontends stamp the hookPid from the request they displayed,
            // and request names repeat across the tools of one turn: executing a
            // predecessor's answer would approve a tool the user never saw.
            // Swallow it and keep waiting.
            try { fs.rmSync(ansPath, { force: true }); } catch {}
            return;
          }
          const b = a.behavior;
          if (isQuestion && (b === "allow" || b === "always" || b === "deny")) {
            // A frontend speaking the pre-question protocol pressed its verbs at
            // a question. That's not an answer — swallow the stale verdict and
            // keep polling, so the question stays pending and answerable instead
            // of silently deferring under a frontend that just showed "allowed".
            try { fs.rmSync(ansPath, { force: true }); } catch {}
            return;
          }
          if (isPlan && (b === "allow" || b === "always")) {
            // A hook allow cannot approve a plan (it carries no mode choice and
            // Claude Code ignores it at the plan dialog) — swallow it and keep
            // polling rather than pretending it worked. Frontends approve plans
            // by answering the dialog directly.
            try { fs.rmSync(ansPath, { force: true }); } catch {}
            return;
          }
          clearInterval(timer);
          if (isQuestion) {
            // Only a well-formed answer speaks for the user; anything else exits
            // silently and the wizard (already on screen) stays the way to answer.
            if (b === "answer" && validAnswers(a.answers, questions)) {
              respond({ behavior: "deny", message: answerMessage(questions, a.answers) });
              // A denied tool fires no PostToolUse, so nothing else would clear
              // the question state until the next event — flip it here. Only
              // while it still IS "question": if the wizard won the race a beat
              // ago, newer real state must not be clobbered by this stale write.
              settle("thinking", "Thinking…");
            }
            process.exit(0);
          }
          if (isPlan && b === "deny") {
            // "Keep planning": without the message the model reads a bare tool
            // denial as "stop" and ends the turn instead of refining the plan.
            respond({ behavior: "deny", message: planMessage(cleanNote(a.message)) });
            settle("thinking", "Thinking…");
            process.exit(0);
          }
          if (b === "allow" || b === "always") {
            const decision = { behavior: "allow" };
            // Only pin a standing rule when it's structurally one Claude Code itself
            // suggested for this request. Same-user forgery of a single one-shot
            // "allow" is out of scope, but a forged "always" must not be able to
            // mint a permission Claude never offered. Key-order-insensitive: the app
            // round-trips the suggestion through JSONSerialization, which may reorder.
            const isSuggested = b === "always" && a.rule &&
              suggestions.some((s) => canonical(s) === canonical(a.rule));
            if (isSuggested) decision.updatedPermissions = [a.rule];
            respond(decision);
            // The tool runs now and PostToolUse moves the row on when it ends;
            // until then it is the tool PreToolUse announced, not a wait.
            settle("tool", before.state === "tool" && typeof before.label === "string"
              ? before.label : "Using tool");
          } else if (b === "deny") {
            // A bare deny stays bare: Claude Code and Copilot word their own
            // refusal, and a denial without a note has always gone out that way.
            const note = cleanNote(a.message);
            respond(note ? { behavior: "deny", message: denyMessage(note) } : { behavior: "deny" });
            // The model reads the refusal and carries on with the turn.
            settle("thinking", "Thinking…");
          }
          process.exit(0); // "defer"/junk: silent exit -> terminal prompt
        } else if (++ticks % 20 === 0 &&
                   (((isQuestion || isPlan) && answeredElsewhere()) || !ownsRequest() ||
                    !appRunning())) {
          clearInterval(timer);
          // Wizard/plan dialog answered it, a later tool took the file name
          // over, or the app quit mid-wait.
          process.exit(0);
        } else if (Date.now() >= deadline) {
          clearInterval(timer);
          process.exit(0); // timeout -> terminal prompt
        }
      } catch {
        clearInterval(timer);
        process.exit(0);
      }
    }, POLL_MS);
  } catch {
    process.exit(0); // any setup failure (e.g. disk full, ~/.agentbar not a dir) -> terminal prompt
  }
}

function respond(decision) {
  // Copilot CLI reads the decision bare; Claude wraps the same {behavior, message}
  // in hookSpecificOutput. Writing *nothing* means "no decision" in both, which is
  // what every failure path in this file relies on to fall through to the terminal
  // prompt — so only these two shapes are ever emitted.
  const json = JSON.stringify(dialect === "copilot"
    ? decision
    : { hookSpecificOutput: { hookEventName: "PermissionRequest", decision } });
  fs.writeSync(1, json);
}
