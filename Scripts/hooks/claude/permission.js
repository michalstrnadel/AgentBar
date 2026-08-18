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

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const base = path.join(os.homedir(), ".agentbar");
const stateDir = path.join(base, "state.d");
const reqDir = path.join(base, "requests.d");
const ansDir = path.join(base, "answers.d");

const timeoutSecRaw = Number(process.env.AGENTBAR_APPROVAL_TIMEOUT);
const timeoutSec = Number.isFinite(timeoutSecRaw) && timeoutSecRaw > 0 ? timeoutSecRaw : 600;
const TIMEOUT_MS = 1000 * timeoutSec;
const POLL_MS = 100;

const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64) || "unknown";
const writeAtomic = (file, obj) => {
  const tmp = file + "." + process.pid + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(obj));
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

const oneLine = (s, n = 60) => {
  s = String(s || "").split("\n")[0].trim();
  return s.length > n ? s.slice(0, n - 1) + "…" : s;
};

const cap = (s, n) => {
  s = String(s == null ? "" : s);
  if (s.length <= n) return s;
  let cut = s.slice(0, n);
  // Never end on a lone high surrogate: JSON.stringify escapes it, but Swift's
  // JSONSerialization refuses the file — and an unreadable request blocks the
  // whole approval while the hook waits on an answer no frontend can give.
  const last = cut.charCodeAt(cut.length - 1);
  if (last >= 0xd800 && last <= 0xdbff) cut = cut.slice(0, -1);
  return cut + "…";
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
function answerMessage(questions, answers) {
  if (questions.length === 1)
    return 'User answered "' + answers[0].join('", "') + '" (via AgentBar). ' +
           "Proceed with this answer; do not ask again.";
  return "User answered (via AgentBar):\n" +
    questions.map((q, i) => "- " + (q.header || q.question) + ": " + answers[i].join(", ")).join("\n") +
    "\nProceed with these answers; do not ask again.";
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
  return t;
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
        const statePath = path.join(stateDir, safeId(p.session_id) + ".json");
        fs.mkdirSync(stateDir, { recursive: true });
        let prev = {};
        try { prev = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch {}
        writeAtomic(statePath, { ...prev, agent: "claude", state: "question",
          label: "❓ " + oneLine(q.question || "Waiting for your answer"),
          sessionId: p.session_id || "", pid: process.ppid, started: true,
          ts: Math.floor(Date.now() / 1000) });
      } catch {}
      process.exit(0);
    }

    const name = safeId(p.session_id) + "-" + safeId(p.prompt_id || String(process.pid));
    const reqPath = path.join(reqDir, name + ".json");
    const ansPath = path.join(ansDir, name + ".json");
    const display = isQuestion ? "Question: " + oneLine(questions[0].question)
                               : displaySummary(p.tool_name, p.tool_input, p.cwd);

    let pretty = "";
    try { pretty = JSON.stringify(p.tool_input || {}, null, 2); } catch {}
    if (pretty.length > 4096) pretty = pretty.slice(0, 4096) + "\n…";

    // Rule suggestions come from Claude Code and go back verbatim on "Always allow";
    // the hook never invents permission rules itself. Questions carry none.
    const suggestions = Array.isArray(p.permission_suggestions) ? p.permission_suggestions : [];
    const suggestion = isQuestion ? null : suggestions[0] || null;

    fs.mkdirSync(reqDir, { recursive: true });
    fs.mkdirSync(ansDir, { recursive: true });

    // The session row itself shows what's pending, even before the menu opens.
    try {
      const statePath = path.join(stateDir, safeId(p.session_id) + ".json");
      fs.mkdirSync(stateDir, { recursive: true });
      let prev = {};
      try { prev = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch {}
      writeAtomic(statePath, { ...prev, agent: "claude",
        state: isQuestion ? "question" : "permission",
        label: isQuestion ? "❓ " + oneLine(questions[0].question) : display,
        sessionId: p.session_id || "", pid: process.ppid, started: true,
        ts: Math.floor(Date.now() / 1000) });
    } catch {}

    writeAtomic(reqPath, {
      // safeId to match Session.id, which the app derives from the state file name.
      sessionId: safeId(p.session_id), agent: "claude",
      toolName: p.tool_name || "", display, toolInputPretty: pretty,
      context: buildContext(p.tool_name, p.tool_input),
      ruleSuggestion: suggestion, pid: process.ppid, hookPid: process.pid,
      ts: Math.floor(Date.now() / 1000),
    });
    // A leftover answer under this name (orphan of a crashed twin, prompt_id
    // reuse) must not be mistaken for the user's decision on THIS request.
    try { fs.rmSync(ansPath, { force: true }); } catch {}

    const cleanup = () => {
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
    const statePath = path.join(stateDir, safeId(p.session_id) + ".json");
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
    let ticks = 0;
    const timer = setInterval(() => {
      try {
        if (fs.existsSync(ansPath)) {
          let a = {};
          // Contract: the app writes answers atomically (tmp+rename), so a plain
          // read here never observes a partially written file.
          try { a = JSON.parse(fs.readFileSync(ansPath, "utf8")); } catch {}
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
              try {
                let prev = {};
                try { prev = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch {}
                if (prev.state === "question") {
                  writeAtomic(statePath, { ...prev, agent: "claude", state: "thinking",
                    label: "Thinking…", ts: Math.floor(Date.now() / 1000) });
                }
              } catch {}
            }
            process.exit(0);
          }
          if (isPlan && b === "deny") {
            // "Keep planning": without the message the model reads a bare tool
            // denial as "stop" and ends the turn instead of refining the plan.
            respond({ behavior: "deny", message:
              "The user reviewed this plan and wants it refined before any " +
              "changes are made. Stay in plan mode and keep planning." });
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
          } else if (b === "deny") {
            respond({ behavior: "deny" });
          }
          process.exit(0); // "defer"/junk: silent exit -> terminal prompt
        } else if (++ticks % 20 === 0 &&
                   (((isQuestion || isPlan) && answeredElsewhere()) || !appRunning())) {
          clearInterval(timer);
          process.exit(0); // wizard/plan dialog answered it, or app quit mid-wait
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
  const json = JSON.stringify({
    hookSpecificOutput: { hookEventName: "PermissionRequest", decision },
  });
  fs.writeSync(1, json);
}
