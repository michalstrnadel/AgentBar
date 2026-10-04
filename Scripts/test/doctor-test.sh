#!/bin/bash
# Tests `agentbar doctor` against throwaway HOMEs. Everything an integration can
# fail at fails *silently* in real life — a hook that is not wired is an absence,
# not an error — so these assert that each silent failure comes back named, under
# the check id the macOS app uses for the same thing (docs/diagnostics.md).
set -uo pipefail
cd "$(dirname "$0")/../.."
CLI="Scripts/cli/agentbar"
NODE="${NODE:-node}"

# install-hooks honors CLAUDE_CONFIG_DIR, COPILOT_HOME and CODEX_HOME; an
# inherited value would point the assertions at the runner's real config.
unset CLAUDE_CONFIG_DIR COPILOT_HOME CODEX_HOME AGENTBAR_FORCE_APP AGENTBAR_APPROVAL_TIMEOUT AGENTBAR_HOME

pass=0; fail=0
check() {
  if eval "$2"; then echo "ok   $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi
}

TESTROOT="$(mktemp -d)"
cleanup() { chmod -R u+w "$TESTROOT" 2>/dev/null; /bin/rm -rf "$TESTROOT"; }
trap cleanup EXIT

# A counter, not $RANDOM: two draws out of 32768 collide about once in three
# hundred runs, and a "fresh" home that is really a previous one still holds its
# files — which fails exactly the checks that assert a directory is empty, on a
# machine nobody is watching. (Caught in CI: "codex non-complete event ignored".)
HOME_SEQ=0
fresh_home() {
  HOME_SEQ=$((HOME_SEQ + 1))
  export HOME="$TESTROOT/home.$$.$HOME_SEQ"
  mkdir -p "$HOME/.agentbar/state.d" "$HOME/.agentbar/requests.d" "$HOME/.agentbar/answers.d"
}

# The status of one check id, read out of --json so the wording stays free to change.
status_of() { # $1 id
  "$CLI" doctor --json | "$NODE" -e '
let s = "";
process.stdin.on("data", (d) => s += d).on("end", () => {
  const c = JSON.parse(s).find((x) => x.id === process.argv[1]);
  process.stdout.write(c ? c.status : "absent");
});' "$1"
}

# --- a clean install reports clean
fresh_home
mkdir -p "$HOME/.codex"
"$CLI" install-hooks >/dev/null 2>&1
check "wired agent passes"              '[ "$(status_of agent.codex.wired)" = ok ]'
check "directories pass"                '[ "$(status_of dirs.state.d)" = ok ]'
check "hook scripts pass"               '[ "$(status_of hooks.copied)" = ok ]'
# Neither Cursor nor Antigravity is here, and the installer only pins a script when
# it wires that agent — so an unpinned copy of cursor.js is not a problem to solve.
check "shebang skipped without cursor"  '[ "$(status_of hooks.shebang)" = skipped ]'
# An agent you don't have is not a problem to solve.
check "absent agent is skipped"         '[ "$(status_of agent.qwen)" = skipped ]'
check "absent agent has no wired row"   '[ "$(status_of agent.qwen.wired)" = absent ]'

# --- the headline: an interpreter that moved
# Every hook is a node script, so a node that is gone means every hook silently
# never runs. Nothing reports that today except this.
sed -i.bak "s|notify = \[\"[^\"]*\"|notify = [\"$HOME/.nvm/versions/node/v0.0.0/bin/node\"|" \
  "$HOME/.codex/config.toml"
check "dead interpreter is a failure"   '[ "$(status_of agent.codex.interpreter)" = fail ]'
check "dead interpreter names the path" '"$CLI" doctor | grep -q "v0.0.0"'
check "dead interpreter offers a fix"   '"$CLI" doctor | grep -q "install-hooks"'

# --- an agent installed but not wired
fresh_home
mkdir -p "$HOME/.cursor"
echo '{"version":1}' > "$HOME/.cursor/hooks.json"
check "unwired agent is a failure"      '[ "$(status_of agent.cursor.wired)" = fail ]'

# --- with Cursor present, its shebang has to name a real node: a GUI-launched
# Cursor inherits the launchd PATH, which usually has no node on it, so
# `#!/usr/bin/env node` is a hook that silently never fires.
"$CLI" install-hooks >/dev/null 2>&1
check "pinned shebang passes"           '[ "$(status_of hooks.shebang)" = ok ]'
printf '#!/usr/bin/env node\n' > "$HOME/.agentbar/hooks/cursor/cursor.js"
check "unpinned shebang is a warning"   '[ "$(status_of hooks.shebang)" = warn ]'

# --- the escaped-slash trap
# JSONSerialization escapes forward slashes, so every config the macOS app writes
# reads "\/.agentbar\/hooks\/..." on disk. Searching the raw text for the plain
# marker reported a perfectly wired Mac as entirely unwired.
fresh_home
mkdir -p "$HOME/.cursor"
printf '{"hooks":{"stop":[{"command":"\\/Users\\/x\\/.agentbar\\/hooks\\/cursor\\/cursor.js"}]}}' \
  > "$HOME/.cursor/hooks.json"
check "escaped slashes still count"     '[ "$(status_of agent.cursor.wired)" = ok ]'

# --- a config the installer refuses to touch
fresh_home
mkdir -p "$HOME/.gemini"
printf '{"theme": "dark" // mine\n}' > "$HOME/.gemini/settings.json"
check "unparseable config is named"     '[ "$(status_of agent.gemini.parseable)" = fail ]'

# --- directories that exist but cannot be written to
# The failure hooks hit most often, and the one they have nowhere to report.
fresh_home
chmod a-w "$HOME/.agentbar/state.d"
check "unwritable dir is a failure"     '[ "$(status_of dirs.state.d)" = fail ]'
chmod u+w "$HOME/.agentbar/state.d"
rmdir "$HOME/.agentbar/answers.d"
check "missing dir is a failure"        '[ "$(status_of dirs.answers.d)" = fail ]'

# --- last seen comes from history.jsonl, because state.d forgets
fresh_home
mkdir -p "$HOME/.codex"
"$CLI" install-hooks >/dev/null 2>&1
# History only starts when a frontend starts keeping it, so a freshly updated
# machine is blank everywhere — and nothing is wrong.
check "no record yet is not a problem"  '[ "$(status_of agent.codex.lastSeen)" = ok ]'
printf '{"agent":"codex","sessionId":"a","state":"done","endedAt":%s}\n' \
  "$(( $(date +%s) - 259200 ))" > "$HOME/.agentbar/history.jsonl"
check "last seen reads the history"     '[ "$(status_of agent.codex.lastSeen)" = ok ]'
check "last seen counts the days"       '"$CLI" doctor | grep -q "3 days ago"'
# Wired and silent for a fortnight is the shape of a broken integration that passes
# every other check: the hooks are in place and simply never fire.
printf '{"agent":"codex","sessionId":"a","state":"done","endedAt":%s}\n' "$(( $(date +%s) - 1500000 ))" \
  > "$HOME/.agentbar/history.jsonl"
check "long silence is a warning"       '[ "$(status_of agent.codex.lastSeen)" = warn ]'

# --- --json is what goes into a bug report
check "json carries id and status"      '"$CLI" doctor --json | grep -q "\"id\": \"hooks.copied\"" && "$CLI" doctor --json | grep -q "\"status\""'
# A diagnostic that changes what it diagnoses is worse than none.
check "doctor leaves state.d alone"     '[ -z "$(ls -A "$HOME/.agentbar/state.d")" ]'
check "doctor leaves no probe behind"   '[ -z "$(ls -A "$HOME/.agentbar/requests.d")" ]'

# --- Codex runs no hook until a human accepts it ---------------------------------
# An inert integration looks exactly like nothing happening, so it gets a row of
# its own: `agent.codex.wired` is satisfied by the notify key alone.
fresh_home
mkdir -p "$HOME/.codex"
check "no block, no trust row"          '[ "$(status_of codex.hooks)" = absent ]'
"$CLI" install-hooks >/dev/null 2>&1
check "codex hooks await acceptance"    '[ "$(status_of codex.hooks)" = warn ]'
DCFG="$HOME/.codex/config.toml"
printf '\n[hooks.state."%s:session_start:0:0"]\ntrusted_hash = "sha256:deadbeef"\n' "$DCFG" >> "$DCFG"
check "codex hooks accepted passes"     '[ "$(status_of codex.hooks)" = ok ]'

# --- Claude is checked in every config dir install-hooks writes -----------------
# doctor read ~/.claude alone, so a machine whose sessions run under
# CLAUDE_CONFIG_DIR (or the claude-config-dir hint) passed while the settings
# those sessions actually read had no hooks in them.
fresh_home
mkdir -p "$HOME/.claude" "$HOME/.claude-work"
"$CLI" install-hooks >/dev/null 2>&1   # wires ~/.claude only
check "claude: default dir alone passes"   '[ "$(status_of agent.claude.wired)" = ok ]'
check "claude: an unwired CLAUDE_CONFIG_DIR fails" '[ "$(CLAUDE_CONFIG_DIR="$HOME/.claude-work" status_of agent.claude.wired)" = fail ]'
check "claude: and names the file"         'CLAUDE_CONFIG_DIR="$HOME/.claude-work" "$CLI" doctor | grep -q "claude-work/settings.json"'
CLAUDE_CONFIG_DIR="$HOME/.claude-work" "$CLI" install-hooks >/dev/null 2>&1
check "claude: wired there too passes"     '[ "$(CLAUDE_CONFIG_DIR="$HOME/.claude-work" status_of agent.claude.wired)" = ok ]'

fresh_home
mkdir -p "$HOME/.claude" "$HOME/.claude-hint"
"$CLI" install-hooks >/dev/null 2>&1
printf '%s\n' "$HOME/.claude-hint" > "$HOME/.agentbar/claude-config-dir"
check "claude: an unwired hint dir fails"  '[ "$(status_of agent.claude.wired)" = fail ]'
"$CLI" install-hooks >/dev/null 2>&1
check "claude: the hint dir wired passes"  '[ "$(status_of agent.claude.wired)" = ok ]'

# Only a custom dir, no ~/.claude: Claude is installed, not absent.
fresh_home
mkdir -p "$HOME/.claude-only"
check "claude: a custom dir alone is not skipped" '[ "$(CLAUDE_CONFIG_DIR="$HOME/.claude-only" status_of agent.claude)" = absent ]'

# Outside HOME the same guard install-hooks applies: not wired, so not checked —
# unless the person said so, and then it must be wired like the rest.
fresh_home
mkdir -p "$HOME/.claude"
"$CLI" install-hooks >/dev/null 2>&1
OUTSIDE_CFG="$TESTROOT/outside-cfg.$HOME_SEQ"; mkdir -p "$OUTSIDE_CFG"
check "claude: outside HOME is not checked" '[ "$(CLAUDE_CONFIG_DIR="$OUTSIDE_CFG" status_of agent.claude.wired)" = ok ]'
check "claude: unless allowed, then it counts" '[ "$(CLAUDE_CONFIG_DIR="$OUTSIDE_CFG" AGENTBAR_ALLOW_CONFIG_OUTSIDE_HOME=1 status_of agent.claude.wired)" = fail ]'

# --- the rules file, reported the way the app reports it -------------------------
# A rules file that will not parse is the one failure that is invisible by design:
# nothing fires, every prompt comes back, and that is exactly what a working
# AgentBar looks like. The app says so in its own Diagnostics; this half said
# nothing at all, and `doctor --json` is what people paste into a bug report.
fresh_home
check "no rules file is skipped"        '[ "$(status_of rules.file)" = skipped ]'

printf '{"v":1,"rules":[{"id":"r-1","decision":"deny","shape":"bash:curl","mode":"on"},{"id":"r-2","decision":"allow","shape":"bash:git status","cwd":"/repo","mode":"watch"}]}' \
  > "$HOME/.agentbar/rules.json"
check "a readable rules file is ok"     '[ "$(status_of rules.file)" = ok ]'
check "and it counts them by mode"      '"$CLI" doctor | grep -q "1 answering, 1 watching"'

printf '{"v":1,"rules":[{"id":"r-1","decision":"allow","shape":"bash:git status","mode":"on"}]}' \
  > "$HOME/.agentbar/rules.json"
check "an approval with no directory fails" '[ "$(status_of rules.file)" = fail ]'

printf 'not json at all' > "$HOME/.agentbar/rules.json"
check "junk fails rather than passes"   '[ "$(status_of rules.file)" = fail ]'
check "and says nothing is applied"     '"$CLI" doctor | grep -q "No rule is being applied"'

# The app refuses the whole file on either of these, so the CLI must too — or it
# reports "ok" for a file from which nothing is being applied.
printf '{"v":1,"rules":[{"id":"r-1","decision":"deny","shape":"bash:curl","cwd":"proj"}]}' \
  > "$HOME/.agentbar/rules.json"
check "a relative cwd fails"            '[ "$(status_of rules.file)" = fail ]'
printf '{"v":1,"rules":[{"id":"r-1","decision":"deny","shape":"bash:curl"},{"id":"r-1","decision":"deny","shape":"bash:wget"}]}' \
  > "$HOME/.agentbar/rules.json"
check "a repeated id fails"             '[ "$(status_of rules.file)" = fail ]'

# --- an agent the person switched off ----------------------------------------------
# Unwired on purpose is not a failure: one skipped row, no wired or lastSeen row, and
# out of hooks.shebang, the same as the app's Diagnostics.
fresh_home
mkdir -p "$HOME/.codex" "$HOME/.cursor"
"$CLI" install-hooks >/dev/null 2>&1
"$CLI" unwire cursor >/dev/null 2>&1
check "disabled agent is skipped"       '[ "$(status_of agent.cursor)" = skipped ]'
check "disabled agent has no wired row" '[ "$(status_of agent.cursor.wired)" = absent ] && [ "$(status_of agent.cursor.lastSeen)" = absent ]'
check "disabled agent says why"         '"$CLI" doctor | grep -q "Turned off by you — AgentBar leaves its settings alone."'
check "disabled agent is no failure"    '"$CLI" doctor --json | "$NODE" -e "let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>process.exit(JSON.parse(s).some(c=>c.status===\"fail\")?1:0))"'
check "shebang skipped when all are off" '[ "$(status_of hooks.shebang)" = skipped ]'
check "the others are still checked"    '[ "$(status_of agent.codex.wired)" = ok ]'

# --- the Claude Code mod: off until switched on (Diagnostics.claudeModChecks) -------
# The installed-versions directory is the first place the version is read from, so
# each home says which Claude Code it has and no real `claude` is ever consulted.
fresh_home
mkdir -p "$HOME/.claude" "$HOME/.local/share/claude/versions/2.1.289"
echo '{}' > "$HOME/.claude/settings.json"
check "mod off is skipped"               '[ "$(status_of agent.claude-mod)" = skipped ]'
check "mod off has no wired row"         '[ "$(status_of agent.claude-mod.wired)" = absent ]'
check "mod off says how to switch it on" '"$CLI" doctor | grep -q "agentbar wire claude-mod"'
mkdir -p "$HOME/.agentbar/mods/claude"
"$CLI" wire claude-mod >/dev/null 2>&1
check "mod on: version ok"               '[ "$(status_of agent.claude-mod.version)" = ok ]'
check "mod on: copied"                   '[ "$(status_of agent.claude-mod.copied)" = ok ]'
check "mod on: wired"                    '[ "$(status_of agent.claude-mod.wired)" = ok ]'
check "mod on: nothing to judge yet"     '[ "$(status_of agent.claude-mod.reported)" = ok ]'
# A Claude Code session after the switch, and nothing in mods.d.
END=$(( $(date +%s) - 60 ))
printf '{"agent":"claude","sessionId":"s1","startedAt":%s,"endedAt":%s,"state":"done"}\n' $((END - 60)) "$END" > "$HOME/.agentbar/history.jsonl"
touch -t 202001010000 "$HOME/.agentbar/wire-enabled"
check "sessions with no sidecar: warn"   '[ "$(status_of agent.claude-mod.reported)" = warn ]'
mkdir -p "$HOME/.agentbar/mods.d" && echo '{}' > "$HOME/.agentbar/mods.d/s1.json"
check "a fresh sidecar: ok"              '[ "$(status_of agent.claude-mod.reported)" = ok ]'
"$NODE" -e 'const f=process.argv[1],j=JSON.parse(require("fs").readFileSync(f,"utf8"));delete j.env;require("fs").writeFileSync(f,JSON.stringify(j))' "$HOME/.claude/settings.json"
check "mod on but unwired: fail"         '[ "$(status_of agent.claude-mod.wired)" = fail ]'
rm -rf "$HOME/.local/share/claude/versions/2.1.289"; mkdir -p "$HOME/.local/share/claude/versions/2.1.200"
check "a Claude Code too old: fail"      '[ "$(status_of agent.claude-mod.version)" = fail ] && [ "$(status_of agent.claude-mod.wired)" = absent ]'
"$CLI" unwire claude-mod >/dev/null 2>&1
check "mod off again is skipped"         '[ "$(status_of agent.claude-mod)" = skipped ]'

# --- plugins that can answer for you: information, never a failure ----------------
fresh_home
mkdir -p "$HOME/.claude/plugins" "$HOME/p/holder/hooks"
echo '{"modules":["./h.mjs"]}' > "$HOME/p/holder/hooks/hooks.json"
echo 'on("tool.call", { tool: "Bash" }, async ($, e, next) => next())' > "$HOME/p/holder/hooks/h.mjs"
printf '{"version":2,"plugins":{"holder@m":[{"scope":"user","installPath":"%s","version":"1"}]}}' "$HOME/p/holder" > "$HOME/.claude/plugins/installed_plugins.json"
echo '{"enabledPlugins":{"holder@m":true}}' > "$HOME/.claude/settings.json"
check "a plugin that can answer is named" '[ "$(status_of claude.plugins)" = ok ] && "$CLI" doctor | grep -q "holder: can hold or refuse Bash commands"'
echo '{"enabledPlugins":{"holder@m":false}}' > "$HOME/.claude/settings.json"
check "a disabled one is not"            '"$CLI" doctor | grep -q "None — no enabled plugin"'

# --- a frontend, judged the way the hook judges it --------------------------------
# permission.js asks only whether the heartbeat is fresh. `agentbar waybar` stamps
# its own pid and exits, so a pid test said "nothing is listening" after every poll.
fresh_home
printf '{"pid":999999,"ts":%s}' "$(date +%s)" > "$HOME/.agentbar/watcher.json"
check "a fresh heartbeat is a frontend" '[ "$(status_of frontend.present)" = ok ]'

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
