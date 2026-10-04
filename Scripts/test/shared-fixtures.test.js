// The CLI's half of every rule the macOS app implements too. Each fixture under
// Tests/Fixtures/ is language-neutral JSON that Tests/AgentBarTests/SharedFixtureTests.swift
// reads as well, against the app's own code — so the two halves cannot drift apart
// without one of the two suites going red. A new case goes into the fixture, never
// into one side's test. Run by Scripts/test/cli-test.sh: node --test this file.
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs"), os = require("os"), path = require("path");
const { spawnSync } = require("child_process");

const root = path.resolve(__dirname, "../..");
const CLI = path.join(root, "Scripts/cli/agentbar");
const fixture = (name) => JSON.parse(fs.readFileSync(path.join(root, "Tests/Fixtures", name, "cases.json"), "utf8"));
// `$FEFF` is a U+FEFF that has to reach a file as it is; see SharedFixtureTests.raw.
const raw = (text) => text.replace(/\$FEFF/g, "\uFEFF");

// A borrowed HOME, and none of the variables that would point a write at the real
// one: an inherited CLAUDE_CONFIG_DIR once rewrote a real Claude config from a test.
for (const k of ["CLAUDE_CONFIG_DIR", "COPILOT_HOME", "CODEX_HOME", "AGENTBAR_NOW", "AGENTBAR_FORCE_APP",
                 "AGENTBAR_ALLOW_CONFIG_OUTSIDE_HOME"]) delete process.env[k];
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "agentbar-fixtures-"));
process.env.HOME = path.join(scratch, "home");
fs.mkdirSync(path.join(process.env.HOME, ".agentbar", "state.d"), { recursive: true });
test.after(() => fs.rmSync(scratch, { recursive: true, force: true }));

// Required, so nothing runs: the CLI hands over the functions instead.
const cli = require(CLI);

test("rule matching: the shape a rule is matched on, and every rule set loads", () => {
  const f = fixture("rule-matching");
  for (const [name, rules] of Object.entries(f.rulesets)) {
    const file = path.join(scratch, `ruleset-${name}.json`);
    fs.writeFileSync(file, JSON.stringify({ v: 1, rules }));
    const loaded = cli.readRules(file);
    assert.equal(loaded.state, "rules", `rule set ${name}: ${loaded.why}`);
  }
  assert.ok(f.cases.length > 60);
  for (const c of f.cases) {
    // The expansion SharedFixtureTests.request(of:) makes.
    const request = c.requestText !== undefined ? JSON.parse(raw(c.requestText))
      : c.request || { agent: c.agent || "claude", toolName: "Bash", cwd: c.cwd !== undefined ? c.cwd : "/work/proj",
                       context: { kind: "bash", command: c.command || "" } };
    assert.equal(cli.decisionShape(request), c.expect.shape, `${c.name}: shape`);
  }
});

test("tool shape: a call Claude Code decided itself has the same shape", () => {
  const f = fixture("tool-shape");
  assert.ok(f.cases.length >= 15);
  for (const c of f.cases) assert.equal(cli.decisionShapeOfCall(c.tool, c.input), c.shape, c.name);
});

test("rules file: in force, or refused for the same reason", () => {
  const f = fixture("rules-file");
  f.cases.forEach((c, i) => {
    const file = path.join(scratch, `rules-${i}.json`);
    if (c.file !== null) fs.writeFileSync(file, raw(c.file));
    const loaded = cli.readRules(file);
    assert.equal(loaded.state, c.expect.state, `${c.name}: state (${loaded.why || ""})`);
    if (c.expect.state === "rules") assert.deepEqual(loaded.rules.map((r) => r.id), c.expect.ids, `${c.name}: ids`);
    if (c.expect.state === "invalid") {
      const needle = f.classes[c.expect.class] && f.classes[c.expect.class].cli;
      assert.ok(needle, `${c.name}: unknown class ${c.expect.class}`);
      assert.ok(loaded.why.includes(needle), `${c.name}: expected ${c.expect.class}, got "${loaded.why}"`);
    }
  });
});

test("wire-disabled: the same agents switched off", () => {
  const file = path.join(process.env.HOME, ".agentbar", "wire-disabled");
  for (const c of fixture("wire-disabled").cases) {
    fs.rmSync(file, { force: true });
    if (c.file !== null) fs.writeFileSync(file, raw(c.file));
    assert.deepEqual([...cli.loadWireDisabled()].sort(), c.ids, c.name);
  }
});

test("wire-enabled: the same integrations left off", () => {
  const dir = path.join(process.env.HOME, ".agentbar");
  for (const c of fixture("wire-enabled").cases) {
    for (const f of ["wire-disabled", "wire-enabled"]) fs.rmSync(path.join(dir, f), { force: true });
    if (c.disabled !== null) fs.writeFileSync(path.join(dir, "wire-disabled"), raw(c.disabled));
    if (c.enabled !== null) fs.writeFileSync(path.join(dir, "wire-enabled"), raw(c.enabled));
    assert.deepEqual([...cli.effectiveDisabled()].sort(), c.off, c.name);
  }
  for (const f of ["wire-disabled", "wire-enabled"]) fs.rmSync(path.join(dir, f), { force: true });
});

const canonical = (v) => JSON.stringify(v, (k, x) => (x && typeof x === "object" && !Array.isArray(x)
  ? Object.keys(x).sort().reduce((o, kk) => ((o[kk] = x[kk]), o), {}) : x));
const backups = (file) => {
  let names = [];
  try { names = fs.readdirSync(path.dirname(file)); } catch {}
  return names.filter((n) => n.startsWith(path.basename(file) + ".agentbar-bak-"));
};

test("unwire: the same config left behind, agent by agent", () => {
  fixture("unwire").cases.forEach((c, i) => {
    const home = path.join(scratch, `unwire-${i}`);
    for (const [rel, text] of Object.entries(c.files)) {
      fs.mkdirSync(path.dirname(path.join(home, rel)), { recursive: true });
      fs.writeFileSync(path.join(home, rel), text);
    }
    const run = spawnSync(process.execPath, [CLI, "unwire", c.agent], {
      env: { ...process.env, HOME: home }, encoding: "utf8",
    });
    assert.equal(run.status, 0, `${c.name}: agentbar unwire exited ${run.status}\n${run.stderr}`);
    for (const [rel, want] of Object.entries(c.expect)) {
      const file = path.join(home, rel);
      const now = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : null;
      const kept = backups(file);
      if (want.unchanged) {
        assert.equal(now, c.files[rel], `${c.name}: ${rel} was rewritten`);
        assert.equal(kept.length, 0, `${c.name}: ${rel} was backed up for nothing`);
      } else if (want.removed) {
        assert.equal(now, null, `${c.name}: ${rel} is still there`);
        assert.equal(kept.length, 1, `${c.name}: ${rel} was not kept first`);
      } else if (want.text !== undefined) {
        assert.equal(now, want.text, `${c.name}: ${rel}`);
        assert.equal(kept.length, 1, `${c.name}: ${rel} was not kept first`);
      } else if (want.json !== undefined) {
        let parsed; try { parsed = JSON.parse(now); } catch { parsed = undefined; }
        assert.equal(canonical(parsed), canonical(want.json), `${c.name}: ${rel}`);
        assert.equal(kept.length, 1, `${c.name}: ${rel} was not kept first`);
      } else {
        assert.fail(`${c.name}: ${rel} expects nothing the test knows`);
      }
    }
  });
});

test("session rows: the same rows pruned, listed and named", () => {
  const stateDir = path.join(process.env.HOME, ".agentbar", "state.d");
  const now = Math.floor(Date.now() / 1000);
  for (const c of fixture("session-rows").cases) {
    for (const f of fs.readdirSync(stateDir)) fs.rmSync(path.join(stateDir, f), { force: true });
    // SharedFixtureTests.filled, placeholder for placeholder.
    const row = c.row.replace(/\$LIVE/g, String(process.pid)).replace(/\$DEAD/g, "999999")
      .replace(/\$NOW-([0-9]+)/g, (_, n) => String(now - Number(n))).replace(/\$NOW/g, String(now));
    const file = path.join(stateDir, "row.json");
    fs.writeFileSync(file, row);
    const listed = cli.sessions().find((s) => s.id === "row");
    assert.equal(fs.existsSync(file), c.expect.kept, `${c.name}: kept`);
    assert.equal(!!listed, c.expect.visible, `${c.name}: visible`);
    if (listed) assert.equal(listed.agent_name || "", c.expect.agentName, `${c.name}: agentName`);
  }
});
