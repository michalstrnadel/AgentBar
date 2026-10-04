#!/bin/bash
# Tests Scripts/mods/claude — the AgentBar Claude Code mod — three ways:
#
#   1. `claude plugin validate --strict`, and the capabilities it reports held to an
#      allow-list: the hooks the module registers, the `$` calls it makes and the
#      environment variables it reads. A future edit that quietly gains a capability
#      (an `answers.d` write is just `$.fs.write`, but an approval is a `tool.check`
#      answer, a network call is `$.http.fetch`) fails here, not in review.
#   2. `claude plugin test` — the mod's own tests (Scripts/mods/claude/tests), run
#      against Claude Code's engine with every `$` call answered in memory.
#   3. Only with AGENTBAR_LIVE_TESTS=1: one real `claude -p` turn with the mod loaded
#      (costs about a cent), asserting the sidecar it wrote.
#
# Without a `claude` new enough to load mods, it prints SKIP and exits 0: the mod
# is optional, and a runner without Claude Code is not a failure of this repo.
set -uo pipefail
cd "$(dirname "$0")/../.."
MOD="${AGENTBAR_MOD_DIR:-Scripts/mods/claude}"   # override: check a copy
NODE="${NODE:-node}"
MIN_VERSION="2.1.287"

pass=0; fail=0
ok()  { echo "ok   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }
skip() { echo "SKIP mod-test: $1"; exit 0; }

command -v claude >/dev/null 2>&1 || skip "claude is not on PATH (npm i -g @anthropic-ai/claude-code)"
command -v "$NODE" >/dev/null 2>&1 || skip "node is not on PATH"

have="$(claude --version 2>/dev/null | awk '{print $1}')"
if ! "$NODE" -e '
  const [a, b] = process.argv.slice(1).map(v => v.split(".").map(Number));
  for (let i = 0; i < 3; i++) { if ((a[i] || 0) !== (b[i] || 0)) process.exit((a[i] || 0) > (b[i] || 0) ? 0 : 1); }
' "${have:-0}" "$MIN_VERSION"; then
  skip "claude ${have:-unknown} predates mods (needs $MIN_VERSION or later)"
fi

# Auth is never needed for validate or test; if a future release starts asking,
# say so and stand down rather than fail a runner that has no account.
needs_login() { grep -qiE 'not logged in|please (run )?/?login|authentication required|invalid api key' <<<"$1"; }

# ---- 1. validate + allow-list ------------------------------------------------
validated="$(claude plugin validate --json --strict "$MOD" 2>&1)"; rc=$?
needs_login "$validated" && skip "claude plugin validate wants a login: $(head -1 <<<"$validated")"
if [ $rc -eq 0 ]; then ok "validate --strict"; else bad "validate --strict"; echo "$validated"; fi

audit="$(VALIDATED="$validated" "$NODE" -e '
  const HOOKS = new Set(["session.start", "session.end", "session.measure", "turn.complete",
    "agent.spawn", "tool.check", "tool.call", "ui.render", "ui.press"]);
  const CALLS = new Set(["env.get", "fs.read", "fs.write", "fs.list", "fs.exists", "fs.stat",
    "session.id", "session.usage", "session.cwd", "clock.every", "clock.after", "clock.now",
    "ui.resolve", "ui.invalidate", "process.run"]);
  const ENV = new Set(["AGENTBAR_HOME", "HOME"]);
  let out;
  try { out = JSON.parse(process.env.VALIDATED); } catch { console.log("FAIL validate output is not JSON"); process.exit(0); }
  const notes = (out.contents || []).flatMap(c => c.notes || []);
  const listed = (label) => {
    const line = notes.find(n => n.includes(` ${label}: `));
    if (!line) return null;
    const rest = line.slice(line.indexOf(` ${label}: `) + label.length + 3);
    if (rest.trim() === "nothing") return [];
    // "$.fs.write (via writeNow), $.clock.now (via a, b)": drop the "(via …)" parts.
    return rest.replace(/\([^)]*\)/g, "").split(",").map(s => s.trim()).filter(Boolean);
  };
  const report = (what, got, allowed, strip) => {
    if (got === null) { console.log(`FAIL validate lists no "${what}:" line`); return; }
    const names = got.map(n => strip(n));
    const extra = names.filter(n => !allowed.has(n));
    console.log(extra.length ? `FAIL ${what} outside the allow-list: ${extra.join(", ")}`
                             : `ok   ${what} within the allow-list (${names.join(", ")})`);
  };
  report("hooks", listed("hooks"), HOOKS, n => n.replace(/\{.*$/, ""));
  report("calls", listed("calls"), CALLS, n => n.replace(/^\$\./, ""));
  report("env reads", listed("env reads"), ENV, n => n);
  const writes = listed("env writes");
  console.log(writes && writes.length === 0 ? "ok   env writes: nothing" : `FAIL env writes: ${writes}`);
')"
while IFS= read -r line; do
  case "$line" in ok*) ok "${line#ok   }" ;; FAIL*) bad "${line#FAIL }" ;; esac
done <<<"$audit"

# The mod reports its version in every sidecar; it must be the app's.
app_version="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' Scripts/build.sh)"
manifest_version="$("$NODE" -e 'console.log(require(require("path").resolve(process.argv[1])).version)' "$MOD/.claude-plugin/plugin.json")"
module_version="$(sed -n 's/^export const VERSION = "\(.*\)";$/\1/p' "$MOD/hooks/register.js")"
if [ -n "$app_version" ] && [ "$manifest_version" = "$app_version" ] && [ "$module_version" = "$app_version" ]; then
  ok "mod version matches the app ($app_version)"
else
  bad "mod version: build.sh $app_version, plugin.json $manifest_version, register.js $module_version"
fi

# ---- 2. the mod's own tests ----------------------------------------------------
tested="$(claude plugin test "$MOD" 2>&1)"; rc=$?
needs_login "$tested" && skip "claude plugin test wants a login: $(head -1 <<<"$tested")"
summary="$(grep -E '^ *[0-9]+ (pass|fail)$' <<<"$tested" | tr -s ' ' | tr '\n' ' ')"
if [ $rc -eq 0 ]; then ok "plugin test:${summary:+ $summary}"; else bad "plugin test"; echo "$tested" | grep -v '^(pass)'; fi

# ---- 3. live smoke (opt-in) -----------------------------------------------------
if [ "${AGENTBAR_LIVE_TESTS:-}" = "1" ]; then
  live="$(mktemp -d)"
  echo 'Reply hi' | AGENTBAR_HOME="$live" claude -p --model haiku --plugin-dir "$MOD" >/dev/null 2>&1
  sidecar="$(ls "$live"/mods.d/*.json 2>/dev/null | head -1)"
  if [ -n "$sidecar" ] && "$NODE" -e '
      const f = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      const ok = f.agent === "claude" && f.ended === true && f.context && f.context.window > 0
        && typeof f.context.tokens === "number" && Array.isArray(f.rate_limits);
      process.exit(ok ? 0 : 1);
    ' "$sidecar"; then
    ok "live: $(basename "$sidecar") has context and rate_limits, ended"
  else
    bad "live: no usable sidecar in $live/mods.d"; cat "$sidecar" 2>/dev/null; echo
  fi
  # Precise cleanup: the files a run leaves, then the folders.
  rm -f "$live"/mods.d/*.json "$live"/state.d/*.json "$live"/*.json "$live"/*.jsonl 2>/dev/null
  rmdir "$live"/mods.d "$live"/state.d "$live"/requests.d "$live"/answers.d "$live"/hooks "$live" 2>/dev/null
else
  echo "skip live smoke test (AGENTBAR_LIVE_TESTS=1 runs one real claude -p turn)"
fi

echo "mod-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
