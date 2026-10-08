// AgentBar's Claude Code mod: observe, write one file per session, answer nothing.
//
// Contract: docs/protocol.md, "mods.d". One file per session,
// `<root>/mods.d/<session_id>.json`, holding what Claude Code measures (context,
// rate limits, running subagents) and the verdicts it reached WITHOUT a prompt.
//
// Every hook here is observe-only. Each one calls `next` exactly once and returns
// what `next` returned, untouched; the bookkeeping runs after, inside a try, and
// each registration's `.catch` hands back `next(e)` — which, in a catch handler, is
// replay-safe: when the hook had already called `next`, it resolves to that same
// result and nothing beneath runs again. A bug in this file can lose a row of
// bookkeeping; it can never change, delay or answer a tool call.
//
// What it never does: approve, deny or ask anything; write `answers.d/`; open a
// window. The optional band (off unless `<root>/mods/config.json` says
// `{"band": true}`) only *reads* `state.d/` and offers a Jump link.
//
// The host reads `on(...)` and `$.noun.method(...)` from this source to list what
// the module hooks and calls (`claude plugin validate`), so every call on `$` is
// spelled literally inside a top-level function whose parameter is `$`.
// Scripts/test/mod-test.sh holds that list to an allow-list.

export const VERSION = "1.49.0";

// ---- Limits (docs/protocol.md, "mods.d") ------------------------------------

const RING = 200;                 // newest verdicts kept
const INPUT_KEYS = ["command", "file_path", "url", "description"];
const INPUT_BYTES = 2048;         // each kept input field, UTF-8
const REASON_CHARS = 300;
const WRITE_EVERY_MS = 1000;      // debounce: at most one write a second, trailing write guaranteed
const READ_ONLY = new Set([
  "Read", "Glob", "Grep", "LS", "TodoWrite", "NotebookRead", "WebSearch", "ToolSearch", "BashOutput",
]);

// A call that has not reached tool.check this long after tool.call began is held
// by something beneath this mod in tool.call (see onCallStart).
const HOLD_MS = 3000;

// Band
const CONFIG_EVERY_MS = 30000;
const POLL_EVERY_MS = 2000;
const STALE_S = 600;              // a state.d row older than this is not "waiting" any more
const MAX_ROWS = 64;              // state.d files read per poll
// The waiting-on-the-person states of state.d (docs/protocol.md, "state.d").
const WAITING = { permission: "needs your approval", question: "has a question" };
// A Claude Code session whose own mod reports a call held before it runs
// (mods.d `held`) is waiting on the person too, though its row says working.
const HELD = "is holding a command for you";
const WORKING = new Set(["thinking", "tool"]);
const AGENT_NAMES = {
  claude: "Claude", codex: "Codex", copilot: "Copilot", antigravity: "Antigravity",
  cursor: "Cursor", gemini: "Gemini", qwen: "Qwen", opencode: "OpenCode", devin: "Devin",
};

// ---- Module state (a reload starts it over; session.start fires again) ------

const S = {
  root: null,          // state root, resolved once per session.start
  sessionId: null,     // the state.d row name this session writes under
  cwd: "",
  context: null,       // { percent?, tokens?, window? }
  rateLimits: [],      // [{ kind, percent_used, resets_at? }]
  decisions: [],       // ring, oldest first
  seen: new Set(),     // tool_use_ids already in the ring (bounded with it)
  asked: new Set(),    // tool_use_ids that reached the person: never a "hook deny"
  asking: new Map(),   // tool_use_id -> { at } while an ask is unsettled
  pending: new Map(),  // tool_use_id -> { tool, input, at, timer } until tool.check or the end
  held: null,          // { id, tool, input, since } while a call is held before it runs
  running: new Map(),  // subagent id -> { background }
  finished: new Set(), // subagent ids whose turn.complete came before their spawn resolved
  ended: new Set(),    // session ids already written with ended:true
  timer: null,
  writing: false,
  dirty: false,
  band: false,
  isMac: false,
  waiting: [],         // [{ id, agent, name, project, state, ts }]
  waitingKey: "",
  pollTimer: null,
  configTimer: null,
};

// ---- Pure helpers -----------------------------------------------------------

const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64);

// A lone surrogate makes Swift's JSONSerialization reject the whole file; strip
// them on the way out, as the hooks do (Scripts/hooks/claude/update.js).
const paired = (_k, v) => (typeof v === "string"
  ? v.replace(/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/g, "")
  : v);

const capChars = (s, n) => {
  const cut = String(s).slice(0, n);
  const last = cut.charCodeAt(cut.length - 1);
  return last >= 0xd800 && last <= 0xdbff ? cut.slice(0, -1) : cut;
};

const capBytes = (s, n) => {
  let bytes = 0;
  let out = "";
  for (const ch of String(s)) {
    const c = ch.codePointAt(0);
    const w = c < 0x80 ? 1 : c < 0x800 ? 2 : c < 0x10000 ? 3 : 4;
    if (bytes + w > n) break;
    bytes += w;
    out += ch;
  }
  return out;
};

export const stateRoot = (agentbarHome, home) => {
  const v = typeof agentbarHome === "string" ? agentbarHome : "";
  if (v.startsWith("/")) return v.replace(/\/+$/, "") || "/";
  if (!home || !String(home).startsWith("/")) return null;
  return String(home).replace(/\/+$/, "") + "/.agentbar";
};

export const pruneInput = (input) => {
  const out = {};
  if (!input || typeof input !== "object") return out;
  for (const k of INPUT_KEYS) {
    const v = input[k];
    if (typeof v === "string") out[k] = capBytes(v, INPUT_BYTES);
  }
  return out;
};

// Who decided a verdict Claude Code reached without asking.
//
// `tool.check`'s `next(e)` resolves to core's verdict with whatever hooks beneath
// this one did to it (we load @inline, ahead of marketplace mods, so they sit
// beneath us). What core hands back, measured on 2.1.289:
//   settings rule      {decision:"deny", rule:"Bash(echo:*)", reason:"Permission to use Bash with command echo hi has been denied."}
//   PreToolUse hook    {decision:"allow", hook:"PreToolUse"}   (no rule, no reason;
//                      `hook` is not in the d.ts, and the hook's own reason is dropped)
//   mode / own check   {decision:"allow"}                     (acceptEdits Write, `ls`, `uname -a`, Agent)
// So:
//   rule present                  -> "rule"
//   `hook` present                -> "hook"
//   neither, but a reason         -> "hook"  (a mod beneath us answered; core's own
//                                             mode and tool verdicts come back bare)
//   neither, no reason            -> "mode"  (the permission mode or the tool's own check)
// A verdict core itself phrased with a reason and no rule (none seen yet) would be
// filed as "hook"; the reason travels with the row, so a reader can see why.
export const attribute = (r) => {
  const rule = typeof r.rule === "string" ? r.rule : "";
  const reason = typeof r.reason === "string" ? r.reason : "";
  const hook = typeof r.hook === "string" ? r.hook : "";
  if (rule) return { by: "rule", rule, reason };
  if (hook || reason.trim()) return { by: "hook", rule: "", reason };
  return { by: "mode", rule: "", reason: "" };
};

const finite = (n) => typeof n === "number" && Number.isFinite(n);

export const contextOf = (c) => {
  if (!c || typeof c !== "object") return null;
  const out = {};
  if (finite(c.percent)) out.percent = c.percent;
  if (finite(c.tokens)) out.tokens = c.tokens;
  if (finite(c.window) && c.window > 0) out.window = c.window;
  return Object.keys(out).length ? out : null;
};

export const rateLimitsOf = (list) => {
  if (!Array.isArray(list)) return [];
  const out = [];
  for (const l of list) {
    if (!l || typeof l.kind !== "string" || !finite(l.percentUsed)) continue;
    const row = { kind: l.kind, percent_used: l.percentUsed };
    if (typeof l.resetsAt === "string" && l.resetsAt) row.resets_at = l.resetsAt;
    out.push(row);
  }
  return out;
};

const remember = (set, id, cap) => {
  set.add(id);
  if (set.size > cap) set.delete(set.values().next().value);
};

const pushDecision = (row) => {
  if (S.seen.has(row.id)) return false;
  S.decisions.push(row);
  S.seen.add(row.id);
  while (S.decisions.length > RING) S.seen.delete(S.decisions.shift().id);
  return true;
};

export const snapshot = (now) => {
  const body = {
    v: 1, agent: "claude", session_id: S.sessionId, ts: Math.floor(now / 1000), mod: VERSION,
    cwd: S.cwd || "", ended: S.ended.has(S.sessionId),
  };
  if (S.context) body.context = S.context;
  body.rate_limits = S.rateLimits;
  body.subagents = S.running.size;
  if (S.held) {
    body.held = { tool: S.held.tool, input: S.held.input, since: Math.floor(S.held.since / 1000) };
  }
  body.decisions = S.decisions;
  return JSON.stringify(body, paired);
};

const resetSession = () => {
  S.sessionId = null;
  S.context = null;
  S.rateLimits = [];
  S.decisions = [];
  S.seen = new Set();
  S.asked = new Set();
  S.asking = new Map();
  for (const p of S.pending.values()) if (p.timer) p.timer.cancel();
  S.pending = new Map();
  S.held = null;
  S.running = new Map();
  S.finished = new Set();
  S.dirty = false;
};

// ---- Effects (each takes `$` by that name; see the header) ------------------

async function resolveRoot($) {
  const custom = await $.env.get("AGENTBAR_HOME");
  const home = await $.env.get("HOME");
  return stateRoot(custom, home);
}

async function ensureSession($) {
  if (!S.root) S.root = await resolveRoot($);
  if (!S.sessionId) S.sessionId = safeId(await $.session.id()) || null;
  if (!S.cwd) S.cwd = String((await $.session.cwd()) || "");
}

async function writeFile($) {
  await $.fs.write(`${S.root}/mods.d/${S.sessionId}.json`, snapshot(await $.clock.now()));
}

// The last word for a session: not behind the debounce's lock, so a write in
// flight cannot hold it up or overtake it with what came after the reset.
async function writeFinal($) {
  await ensureSession($);
  if (S.root && S.sessionId) await writeFile($);
}

async function writeNow($) {
  if (S.writing) { S.dirty = true; return; }
  S.writing = true;
  try {
    while (true) {
      S.dirty = false;
      await ensureSession($);
      if (!S.root || !S.sessionId) return;
      // Once ended:true is on disk, nothing but writeFinal touches that file again.
      if (S.ended.has(S.sessionId)) return;
      await writeFile($);
      if (!S.dirty) return;
    }
  } finally {
    S.writing = false;
  }
}

// Debounced: the first change schedules a write a second out; changes inside
// that second ride along. A change landing mid-write sets `dirty`, and
// writeNow loops, so the last change always reaches the disk.
function schedule($) {
  if (S.sessionId && S.ended.has(S.sessionId)) return;
  S.dirty = true;
  if (S.timer) return;
  S.timer = $.clock.after(WRITE_EVERY_MS, () => {
    S.timer = null;
    writeNow($).catch(() => {});
  });
}

// ---- Band -------------------------------------------------------------------

async function readConfig($) {
  if (!S.root) return false;
  try {
    const text = await $.fs.read(`${S.root}/mods/config.json`);
    const cfg = JSON.parse(text);
    return !!(cfg && cfg.band === true);
  } catch {
    return false;
  }
}

async function pollWaiting($) {
  const dir = `${S.root}/state.d`;
  let entries = [];
  try { entries = await $.fs.list(dir); } catch { entries = []; }
  const now = Math.floor((await $.clock.now()) / 1000);
  const found = [];
  let read = 0;
  for (const ent of entries) {
    if (read >= MAX_ROWS) break;
    if (!ent || ent.kind !== "file" || !ent.name.endsWith(".json")) continue;
    const id = ent.name.slice(0, -5);
    if (id === S.sessionId) continue;
    read += 1;
    let row;
    try { row = JSON.parse(await $.fs.read(`${dir}/${ent.name}`)); } catch { continue; }
    if (!row || typeof row !== "object" || row.started === false) continue;
    const ts = finite(row.ts) ? row.ts : 0;
    let state = row.state;
    if (!WAITING[state]) {
      if (row.agent !== "claude" || !WORKING.has(state)) continue;
      // Same rule as the app (SessionStore.isHeld): held, and the row not moved since.
      let side;
      try { side = JSON.parse(await $.fs.read(`${S.root}/mods.d/${ent.name}`)); } catch { continue; }
      const since = side && side.held && finite(side.held.since) ? side.held.since : 0;
      if (!since || ts > since) continue;
      state = "held";
    } else if (ts > 0 && now - ts > STALE_S) continue;
    const agent = typeof row.agent === "string" ? row.agent : "";
    const named = typeof row.agent_name === "string" ? row.agent_name.replace(/[\u0000-\u001f]/g, "").trim().slice(0, 24) : "";
    found.push({
      id, agent, state, ts,
      name: AGENT_NAMES[agent] || named || agent || "An agent",
      project: typeof row.project === "string" ? row.project : "",
    });
  }
  found.sort((a, b) => a.ts - b.ts || (a.id < b.id ? -1 : 1));
  return found;
}

function setWaiting($, list) {
  const key = list.map((w) => `${w.id}:${w.state}`).join("|");
  S.waiting = list;
  if (key !== S.waitingKey) {
    S.waitingKey = key;
    $.ui.invalidate("ui.render");
  }
}

async function tick($) {
  if (!S.band || !S.root) return;
  setWaiting($, await pollWaiting($));
}

async function refreshBand($) {
  const on = await readConfig($);
  if (on === S.band) return;
  S.band = on;
  if (on) {
    S.pollTimer = $.clock.every(POLL_EVERY_MS, () => { tick($).catch(() => {}); });
    await tick($);
  } else {
    if (S.pollTimer) S.pollTimer.cancel();
    S.pollTimer = null;
    setWaiting($, []);
  }
}

export const bandLine = (waiting, columns) => {
  const first = waiting[0];
  let text = `◆ ${first.name} ${WAITING[first.state] || HELD}`;
  if (first.project) text += ` · ${first.project}`;
  if (waiting.length > 1) text += ` · and ${waiting.length - 1} more`;
  const room = Math.max(8, (columns || 80) - 12); // leave room for the Jump button
  return text.length > room ? capChars(text, room - 1) + "…" : text;
};

function jump($, id) {
  return $.process.run(["/usr/bin/open", `agentbar://focus?session=${encodeURIComponent(id)}`], { timeoutMs: 5000 });
}

function drawBand($, e, below) {
  const { Box, Text, Button } = $.ui.resolve(e);
  const first = S.waiting[0];
  const line = [
    Text({ key: "line", color: "yellow", wrap: "truncate-end", children: bandLine(S.waiting, e.props.bodyColumns) }),
  ];
  if (S.isMac) {
    line.push(Button({
      key: "agentbar-jump", label: "Jump", hotkey: "1", plain: true,
      onPress: () => { jump($, first.id).catch(() => {}); },
    }));
  }
  const ours = Box({ key: "agentbar", flexDirection: "row", gap: 2, children: line });
  if (!below) return ours;
  return Box({ flexDirection: "column", children: [ours, below] });
}

// ---- Hooks ------------------------------------------------------------------

async function onStart($, e) {
  // A reload fires session.start again for the same session; anything else is new.
  const id = safeId(await $.session.id()) || null;
  if (id !== S.sessionId) resetSession();
  S.root = await resolveRoot($);
  S.sessionId = id;
  S.cwd = String((e && e.cwd) || (await $.session.cwd()) || "");
  S.ended.delete(id);
  try {
    S.isMac = await $.fs.exists("/System/Library/CoreServices/SystemVersion.plist");
  } catch { S.isMac = false; }
  try {
    // At start Claude Code knows the window and little else: keep what it has,
    // never a zero for what it does not.
    const usage = await $.session.usage();
    S.context = contextOf(usage && usage.context) || S.context;
    const limits = rateLimitsOf(usage && usage.rateLimits);
    if (limits.length) S.rateLimits = limits;
  } catch { /* the next session.measure brings them */ }
  schedule($);
  if (S.configTimer) S.configTimer.cancel();
  S.configTimer = $.clock.every(CONFIG_EVERY_MS, () => { refreshBand($).catch(() => {}); });
  await refreshBand($);
}

function onMeasure($, e) {
  const ctx = contextOf(e.context);
  if (ctx) S.context = ctx;
  const limits = rateLimitsOf(e.rateLimits);
  // An empty list off a subscription is news; an absent one is not.
  if (Array.isArray(e.rateLimits)) S.rateLimits = limits;
  schedule($);
}

async function onCheck($, e, r) {
  const id = e && e.tool_use_id;
  if (!id || !r) return;                  // a query ($.tool.check), not a call
  settlePending($, id);
  if (r.decision === "ask") {
    remember(S.asked, id, 512);
    if (!READ_ONLY.has(e.tool)) await watchAsk($, id);
    return;
  }
  if (r.decision !== "allow" && r.decision !== "deny") return;
  if (READ_ONLY.has(e.tool)) return;
  const who = attribute(r);
  const added = pushDecision({
    id, ts: Math.floor((await $.clock.now()) / 1000), tool: String(e.tool || ""),
    input: pruneInput(e.input), verdict: r.decision, by: who.by, rule: who.rule,
    reason: capChars(who.reason, REASON_CHARS),
  });
  if (added) schedule($);
}

// ---- Held before it runs ----------------------------------------------------
//
// tool.call's hooks run first, then PreToolUse, then tool.check, then the prompt
// and the tool. A mod that holds a command until the person answers it in its own
// pane (blast-radius does, for `rm -r` and a force push) sits in tool.call beneath
// this one, so the call starts, tool.check does not come, and nothing anywhere
// says the session is waiting on anybody — AgentBar showed it as working.
// Measured on 2.1.289: call.start, then 35 s of nothing until the pane answered.
// So a call with no tool.check HOLD_MS after it began is reported as `held`, and
// cleared the moment tool.check arrives or the call ends. A PreToolUse hook that
// takes longer than that reads as held too; the app words it as a wait before the
// command runs, which it is.

function onCallStart($, e) {
  const id = e && e.tool_use_id;
  if (!id || READ_ONLY.has(e.tool) || S.pending.has(id)) return;
  const p = { tool: String(e.tool || ""), input: pruneInput(e), at: 0, timer: null };
  S.pending.set(id, p);
  $.clock.now().then((now) => { p.at = now; }).catch(() => {});
  p.timer = $.clock.after(HOLD_MS, () => {
    p.timer = null;
    if (!S.pending.has(id)) return;
    S.held = { id, tool: p.tool, input: p.input, since: p.at };
    schedule($);
  });
}

function settlePending($, id) {
  const p = S.pending.get(id);
  if (!p) return;
  if (p.timer) p.timer.cancel();
  S.pending.delete(id);
  if (S.held && S.held.id === id) { S.held = null; schedule($); }
}

// ---- After an ask --------------------------------------------------------
//
// tool.check fires before the permission mode settles an ask, so on its own it
// cannot see what auto mode's classifier decides. tool.call can: it wraps the
// prompt and the tool, and resolves after both. What it cannot say is whether a
// prompt reached the person — classic.PermissionRequest never fires for a mod on
// 2.1.289, and no render component is the dialog. AgentBar's own permission hook
// says so instead: the moment a prompt is due — app running or not, answered
// anywhere — it writes the time to `mods.d/.prompted-<session>`. A call that ran,
// after an ask, with no prompt marked since the ask, was settled by the mode:
// measured, auto mode runs `mkdir` with check "ask", no prompt, and a result with
// no isError. (Reading the session's state.d row for "permission" was tried
// first and is not enough: the hook writes that only while an app is there to
// answer, so a prompt answered in the terminal with the app closed read as auto.)
// Without AgentBar's hooks there is no marker and no state.d row; the row is the
// check that they are wired, and without it nothing is recorded — a prompt the
// person answered must never read as auto mode. Only what ran is recorded: a
// refusal comes back as an error result, the same shape as a command that ran
// and failed, and a guess is worse than a gap.

async function watchAsk($, id) {
  S.asking.set(id, { at: await $.clock.now() });
}

async function markerTime($) {
  try {
    const t = Number(String(await $.fs.read(`${S.root}/mods.d/.prompted-${S.sessionId}`)).trim());
    return Number.isFinite(t) ? t : 0;
  } catch { return 0; }
}

async function rowThere($) {
  try { await $.fs.read(`${S.root}/state.d/${S.sessionId}.json`); return true; } catch { return false; }
}

export const ranUnprompted = (r) => !!r && typeof r.deny !== "string" && r.result !== undefined && r.isError !== true;

async function onCallAsked($, e, r) {
  const id = e && e.tool_use_id;
  const a = id ? S.asking.get(id) : null;
  if (!a) return false;
  S.asking.delete(id);
  if (!ranUnprompted(r)) return true;
  await ensureSession($);
  if (!S.root || !S.sessionId || !(await rowThere($))) return true;
  // A second of slack: the hook's clock and this one are the same machine's, but
  // the ask is stamped after Claude Code has already started deciding.
  if ((await markerTime($)) >= a.at - 1000) return true;
  const added = pushDecision({
    id, ts: Math.floor((await $.clock.now()) / 1000), tool: String(e.tool || ""),
    input: pruneInput(e), verdict: "allow", by: "auto", rule: "", reason: "",
  });
  if (added) schedule($);
  return true;
}

// A refusal that never reached tool.check: a hook beneath us in tool.call (a mod
// holding a command, the person cancelling it there) answered `{ deny }`.
async function onCall($, e, r) {
  if (e && e.tool_use_id) settlePending($, e.tool_use_id);
  if (await onCallAsked($, e, r)) return;
  const id = e && e.tool_use_id;
  if (!id || !r || typeof r.deny !== "string") return;
  if (S.seen.has(id) || S.asked.has(id) || READ_ONLY.has(e.tool)) return;
  const added = pushDecision({
    id, ts: Math.floor((await $.clock.now()) / 1000), tool: String(e.tool || ""),
    input: pruneInput(e), verdict: "deny", by: "hook", rule: "",
    reason: capChars(r.deny, REASON_CHARS),
  });
  if (added) schedule($);
}

function onSpawn($, e, r) {
  const agentId = r && typeof r.agentId === "string" ? r.agentId : "";
  if (!agentId) return;
  // Already finished before the spawn resolved: never counted, never leaked.
  if (S.finished.delete(agentId)) return;
  S.running.set(agentId, { background: !!(e && e.background) });
  schedule($);
}

function onTurn($, e) {
  const agentId = e && typeof e.agentId === "string" ? e.agentId : "";
  if (agentId) {
    if (S.running.delete(agentId)) schedule($);
    else remember(S.finished, agentId, 64);
    return;
  }
  // The main loop's turn ended: a foreground subagent cannot outlive it, so any
  // still counted lost its turn.complete. Background ones may run on.
  let changed = false;
  for (const [id, a] of S.running) {
    if (!a.background) { S.running.delete(id); changed = true; }
  }
  if (changed) schedule($);
}

async function onEnd($, e) {
  if (S.timer) { S.timer.cancel(); S.timer = null; }
  const id = safeId(e && e.sessionId) || S.sessionId;
  if (id) S.sessionId = id;
  S.running.clear();
  if (S.sessionId) S.ended.add(S.sessionId);
  await writeFinal($);
  // /clear ends this session and carries on under a new id with no
  // session.start; the next event resolves it afresh.
  resetSession();
  if (S.pollTimer) { S.pollTimer.cancel(); S.pollTimer = null; }
  if (S.configTimer) { S.configTimer.cancel(); S.configTimer = null; }
  S.band = false;
  S.waiting = [];
  S.waitingKey = "";
}

const passThrough = ($, e, next) => next(e);

export function register(on) {
  on("session.start", async ($, e, next) => {
    const r = await next(e);
    try { await onStart($, e); } catch { /* bookkeeping only */ }
    return r;
  }).catch(passThrough);

  on("session.measure", async ($, e, next) => {
    const r = await next(e);
    try { onMeasure($, e); } catch { /* bookkeeping only */ }
    return r;
  }).catch(passThrough);

  on("tool.check", async ($, e, next) => {
    const r = await next(e);
    try { await onCheck($, e, r); } catch { /* bookkeeping only */ }
    return r;
  }).catch(passThrough);

  on("tool.call", async ($, e, next) => {
    try { onCallStart($, e); } catch { /* bookkeeping only */ }
    const r = await next(e);
    try { await onCall($, e, r); } catch { /* bookkeeping only */ }
    return r;
  }).catch(passThrough);

  on("agent.spawn", async ($, e, next) => {
    const r = await next(e);
    try { onSpawn($, e, r); } catch { /* bookkeeping only */ }
    return r;
  }).catch(passThrough);

  on("turn.complete", async ($, e, next) => {
    const r = await next(e);
    try { onTurn($, e); } catch { /* bookkeeping only */ }
    return r;
  }).catch(passThrough);

  on("session.end", async ($, e, next) => {
    // Our write first: session.end has a 1.5 s budget, and the file is the point.
    try { await onEnd($, e); } catch { /* bookkeeping only */ }
    return next(e);
  }).catch(passThrough);

  on("ui.render", { component: "AbovePrompt" }, async ($, e, next) => {
    const below = await next(e);
    if (!S.band || S.waiting.length === 0 || (e.props && e.props.hasSurvey)) return below;
    try { return drawBand($, e, below); } catch { return below; }
  }).catch(passThrough);
}
