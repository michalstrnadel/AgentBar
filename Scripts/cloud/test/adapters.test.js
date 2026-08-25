// Pure-function tests for the cloud poller: adapter normalization, retention
// policy, and protocol-row assembly. Run: node --test Scripts/cloud/test/
const { test } = require("node:test");
const assert = require("node:assert");

const cursor = require("../adapters/cursor");
const devin = require("../adapters/devin");
const codex = require("../adapters/codex");
const { keepRow, toProtocolRow, epoch } = require("../lib/policy");
const { safeId } = require("../lib/state");
const { DEFAULTS } = require("../lib/config");

const NOW = 1_787_600_000;
const iso = (secondsAgo) => new Date((NOW - secondsAgo) * 1000).toISOString();

// --- codex: fixture captured from a real `codex cloud list --json` (2026-08-24)

const codexFixture = {
  tasks: [
    {
      id: "task_e_69dd92b48e5c83249b2cf0fcf2eaafbe",
      url: "https://chatgpt.com/codex/tasks/task_e_69dd92b48e5c83249b2cf0fcf2eaafbe",
      title: "Fix ModelHTTPError 500 in production",
      status: "ready",
      updated_at: iso(600),
      environment_id: null,
      environment_label: "mtwr-two",
      summary: { files_changed: 2, lines_added: 150, lines_removed: 73 },
      is_review: false,
      attempt_total: 1,
    },
    { id: "task_x", url: "https://chatgpt.com/codex/tasks/task_x", title: "Weird",
      status: "somenewstatus", updated_at: iso(60), environment_label: "env", summary: null },
  ],
};

test("codex: ready maps to done with a diffstat recap", () => {
  const { rows, warnings } = codex.normalize(codexFixture, DEFAULTS.codex, NOW);
  assert.equal(rows[0].state, "done");
  assert.equal(rows[0].recap, "2 files · +150 −73");
  assert.equal(rows[0].project, "mtwr-two");
  assert.match(rows[0].url, /^https:\/\/chatgpt\.com\/codex\/tasks\//);
  assert.equal(rows[1].state, "idle"); // unknown status degrades, never hides silently
  assert.deepEqual(warnings, ['unknown codex status "somenewstatus"']);
});

// --- devin

const devinFixture = {
  sessions: [
    { session_id: "devin-abc123", status_enum: "working", title: "Migrate billing to v2",
      created_at: iso(7200), updated_at: iso(30) },
    { session_id: "devin-blocked1", status_enum: "blocked", title: "Refactor auth",
      created_at: iso(7200), updated_at: iso(300) },
    { session_id: "devin-fin", status_enum: "finished", title: "Done thing",
      created_at: iso(9000), updated_at: iso(120), pull_request: { url: "https://github.com/x/y/pull/7" } },
    { session_id: "devin-susp", status_enum: "suspend_requested", title: "Paused thing",
      created_at: iso(9000), updated_at: iso(120) },
    { session_id: "devin-old", status_enum: "expired", title: "Gone", updated_at: iso(900000) },
  ],
};

test("devin: status_enum mapping — blocked is question, never permission", () => {
  const { rows, warnings } = devin.normalize(devinFixture, DEFAULTS.devin, NOW);
  const byId = Object.fromEntries(rows.map((r) => [r.id, r]));
  assert.equal(byId["devin-abc123"].state, "thinking");
  assert.equal(byId["devin-blocked1"].state, "question");
  assert.equal(byId["devin-fin"].state, "done");
  assert.equal(byId["devin-fin"].recap, "https://github.com/x/y/pull/7");
  assert.equal(byId["devin-susp"].state, "idle"); // suspended = Devin's resting state, shown
  assert.equal(byId["devin-susp"].recentHours, DEFAULTS.devin.suspendedHours);
  assert.equal(byId["devin-old"].state, null);    // expired: dropped
  assert.equal(byId["devin-abc123"].url, // default: exact thread in Devin Desktop
    "devin://acp/session?sessionId=devin-abc123&connectorId=devin-cloud");
  assert.deepEqual(warnings, []);
});

test("devin: v3 shape — numeric timestamps, unprefixed ids, bare status", () => {
  const v3 = { items: [
    { session_id: "082c8b0459464c6c9ce3ea47da31a0d2", status: "suspended",
      title: "Sentry errors 24 hours", created_at: String(NOW - 7200), updated_at: String(NOW - 600) },
    { session_id: "f9b766226d0000000000000000000000", status: "running", // v3 for v1's "working"
      title: "Validate backfill plan", created_at: String(NOW - 120), updated_at: String(NOW - 60) },
  ] };
  const { rows, warnings } = devin.normalize(v3, DEFAULTS.devin, NOW);
  assert.equal(rows[0].state, "idle");
  assert.equal(rows[0].updated_at, NOW - 600); // numeric-string epoch parsed, not defaulted to now
  assert.equal(rows[0].url, // ACP store keys sessions WITH the devin- prefix
    "devin://acp/session?sessionId=devin-082c8b0459464c6c9ce3ea47da31a0d2&connectorId=devin-cloud");
  assert.equal(rows[1].state, "thinking"); // a running session is active, never idle-filed
  assert.deepEqual(warnings, []);
});

test("devin: openIn web yields the thread-precise browser URL, prefix stripped", () => {
  const { rows } = devin.normalize(devinFixture, { ...DEFAULTS.devin, openIn: "web" }, NOW);
  assert.equal(rows.find((r) => r.id === "devin-abc123").url,
    "https://app.devin.ai/sessions/abc123");
});

test("devin: showSuspended false hides suspended sessions", () => {
  const { rows } = devin.normalize(devinFixture, { ...DEFAULTS.devin, showSuspended: false }, NOW);
  assert.equal(rows.find((r) => r.id === "devin-susp").state, null);
});

// --- cursor (v1 doc shape: lifecycle on the agent, live status on the run)

const cursorFixture = {
  agents: [
    { id: "bc-11111111-2222-3333-4444-555555555555", name: "Fix login bug", status: "ACTIVE",
      latestRunId: "run-1", url: "https://cursor.com/agents/bc-11111111-2222-3333-4444-555555555555",
      repos: ["github.com/acme/webapp.git"], createdAt: iso(3600) },
    { id: "bc-archived", name: "Old", status: "ARCHIVED", latestRunId: "run-9" },
    { id: "bc-errored", name: "Broken run", status: "ACTIVE", latestRunId: "run-2", createdAt: iso(3600) },
  ],
  runs: {
    "bc-11111111-2222-3333-4444-555555555555":
      { id: "run-1", status: "RUNNING", createdAt: iso(3600), updatedAt: iso(10) },
    "bc-errored":
      { id: "run-2", status: "ERROR", createdAt: iso(3600), updatedAt: iso(60),
        git: { branches: [{ prUrl: "https://github.com/x/y/pull/9" }] } },
  },
};

test("cursor: run status wins; archived agents are dropped", () => {
  const { rows, warnings } = cursor.normalize(cursorFixture, DEFAULTS.cursor, NOW);
  assert.equal(rows.length, 2);
  assert.equal(rows[0].state, "thinking");
  assert.equal(rows[0].project, "Fix login bug");
  assert.match(rows[0].url, /^cursor:\/\/anysphere\.cursor-deeplink\/background-agent\?bcId=/);
  assert.equal(rows[1].state, "error");
  assert.deepEqual(warnings, []);
});

test("cursor: openIn web switches the url to the browser link", () => {
  const { rows } = cursor.normalize(cursorFixture, { ...DEFAULTS.cursor, openIn: "web" }, NOW);
  assert.match(rows[0].url, /^https:\/\/cursor\.com\/agents\//);
});

test("cursor: v0 shape (status on the agent, no runs) still normalizes", () => {
  const v0 = { agents: [{ id: "bc-v0", name: "Old style", status: "FINISHED", createdAt: iso(120) }], runs: {} };
  const { rows } = cursor.normalize(v0, DEFAULTS.cursor, NOW);
  assert.equal(rows[0].state, "done");
});

// --- retention / policy

test("keepRow: thinking always kept; done/error age out by retention", () => {
  const cfg = { retentionMinutes: { done: 60, error: 240 }, syntheticErrorRow: true };
  assert.ok(keepRow({ state: "thinking", updated_at: NOW - 900000 }, cfg, NOW));
  assert.ok(keepRow({ state: "done", updated_at: NOW - 59 * 60 }, cfg, NOW));
  assert.ok(!keepRow({ state: "done", updated_at: NOW - 61 * 60 }, cfg, NOW));
  assert.ok(!keepRow({ state: "error", updated_at: NOW - 241 * 60 }, cfg, NOW));
  assert.ok(!keepRow({ state: null, updated_at: NOW }, cfg, NOW));
  assert.ok(keepRow({ state: "question", updated_at: NOW - 3600, recentHours: 48 }, cfg, NOW));
  assert.ok(!keepRow({ state: "question", updated_at: NOW - 49 * 3600, recentHours: 48 }, cfg, NOW));
});

test("toProtocolRow: cloud invariants — cwd empty, entrypoint cloud, ts frozen when terminal", () => {
  const meta = { agentId: "devin", prefix: "cloud-devin-" };
  const active = toProtocolRow({ id: "s1", state: "thinking", label: "Working", project: "P",
    url: "https://x", updated_at: NOW - 500 }, meta, NOW, 4242);
  assert.equal(active.cwd, "");
  assert.equal(active.entrypoint, "cloud");
  assert.equal(active.pid, 4242);
  assert.equal(active.started, true);
  assert.equal(active.ts, NOW);
  assert.equal(active.sessionId, "cloud-devin-s1");
  const finished = toProtocolRow({ id: "s2", state: "done", label: "", project: "P",
    url: "https://x", updated_at: NOW - 500 }, meta, NOW, 4242);
  assert.equal(finished.ts, NOW - 500); // frozen: the row must age out, not stay fresh
  const suspended = toProtocolRow({ id: "s3", state: "idle", label: "", project: "P",
    url: "https://x", updated_at: NOW - 900 }, meta, NOW, 4242);
  assert.equal(suspended.ts, NOW - 900); // frozen too: ts = when it last worked (sort key)
});

test("safeId: sanitizes and stays unique past 64 chars", () => {
  assert.equal(safeId("cloud-codex-task_e_69dd"), "cloud-codex-task_e_69dd");
  assert.equal(safeId("we/ird id!"), "we-ird-id-");
  const long = "cloud-cursor-" + "x".repeat(100);
  const a = safeId(long);
  const b = safeId(long + "y");
  assert.equal(a.length, 64);
  assert.notEqual(a, b); // head-only truncation would collide
});

test("epoch: ISO, numeric seconds, numeric ms; garbage in, 0 out", () => {
  assert.equal(epoch("2026-08-24T10:00:00.000Z"), 1787565600);
  assert.equal(epoch("1787641783"), 1787641783);      // Devin v3: seconds as string
  assert.equal(epoch(1787641783), 1787641783);
  assert.equal(epoch(1787641783199), 1787641783);     // milliseconds collapse to seconds
  assert.equal(epoch("nope"), 0);
  assert.equal(epoch(undefined), 0);
});
