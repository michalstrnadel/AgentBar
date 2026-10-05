#!/bin/bash
# Tests Scripts/cli/agentbar against a throwaway HOME: status/requests listing,
# approve/deny answers, pruning rules, waybar output, install-hooks safety.
set -uo pipefail
cd "$(dirname "$0")/../.."
CLI="Scripts/cli/agentbar"
NODE="${NODE:-node}"

# install-hooks honors CLAUDE_CONFIG_DIR — a value inherited from the runner's
# shell would make the test wire hooks into the runner's REAL Claude config,
# pointing at this suite's throwaway temp dir (learned the hard way). COPILOT_HOME
# and CODEX_HOME are honoured the same way and would do the same to Copilot/Codex.
unset CLAUDE_CONFIG_DIR COPILOT_HOME CODEX_HOME AGENTBAR_FORCE_APP AGENTBAR_APPROVAL_TIMEOUT AGENTBAR_HOME

pass=0; fail=0
check() {
  if eval "$2"; then echo "ok   $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi
}

TESTROOT="$(mktemp -d)"
trap 'rm -rf "$TESTROOT"' EXIT

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

seed_session() { # $1 id, $2 state, $3 pid, $4 cwd (optional)
  printf '{"agent":"claude","state":"%s","label":"x","project":"proj","cwd":"%s","sessionId":"%s","pid":%s,"started":true,"ts":%s}' \
    "$2" "${4:-}" "$1" "$3" "$(date +%s)" > "$HOME/.agentbar/state.d/$1.json"
}

seed_request() { # $1 name, $2 hookPid
  printf '{"sessionId":"s1","agent":"claude","toolName":"Bash","display":"Bash: ls","toolInputPretty":"{}","ruleSuggestion":{"type":"addRules"},"pid":%s,"hookPid":%s,"ts":%s}' \
    "$2" "$2" "$(date +%s)" > "$HOME/.agentbar/requests.d/$1.json"
}

# --- status: live session listed, dead pid pruned, started:false hidden
fresh_home
seed_session live tool $$
seed_session deadpid tool 999999
printf '{"agent":"claude","state":"idle","pid":%s,"started":false,"ts":%s}' $$ "$(date +%s)" > "$HOME/.agentbar/state.d/unstarted.json"
OUT="$("$CLI" status --json)"
check "status lists live session"      'echo "$OUT" | grep -q "\"id\": \"live\""'
check "status hides unstarted"         '! echo "$OUT" | grep -q unstarted'
check "status prunes dead pid"         '[ ! -f "$HOME/.agentbar/state.d/deadpid.json" ]'

# --- history: state.d is a live set, so an ended session has to be recorded
# somewhere or nothing can say when an agent last reported anything.
fresh_home
seed_session h1 tool $$
"$CLI" status >/dev/null 2>&1
check "history first run is a baseline" '[ ! -f "$HOME/.agentbar/history.jsonl" ]'
rm -f "$HOME/.agentbar/state.d/h1.json"
"$CLI" status >/dev/null 2>&1
check "vanished session recorded"      'grep -q "\"sessionId\":\"h1\"" "$HOME/.agentbar/history.jsonl"'
"$CLI" status >/dev/null 2>&1
check "vanished session not repeated"  '[ "$(wc -l < "$HOME/.agentbar/history.jsonl" | tr -d " ")" = 1 ]'
# A finished turn is recorded while the row is still readable; the row lingering
# in `done` for hours must not append a line per tick.
fresh_home
seed_session h2 tool $$
"$CLI" status >/dev/null 2>&1
seed_session h2 done $$
"$CLI" status >/dev/null 2>&1
"$CLI" status >/dev/null 2>&1
check "finished turn recorded once"    '[ "$(grep -c "\"sessionId\":\"h2\"" "$HOME/.agentbar/history.jsonl")" = 1 ]'
check "finished turn keeps its state"  'grep -q "\"state\":\"done\"" "$HOME/.agentbar/history.jsonl"'
# `idle` is where a session waits between turns — not an ending.
fresh_home
seed_session h3 tool $$
"$CLI" status >/dev/null 2>&1
seed_session h3 idle $$
"$CLI" status >/dev/null 2>&1
check "idle is not an ending"          '[ ! -f "$HOME/.agentbar/history.jsonl" ]'

# --- history: the day's account, read back out of history.jsonl
# The clock is pinned to noon. Seeded as "an hour ago" against the real clock,
# this block means today at 14:00 and YESTERDAY at 00:30 — it passed every
# afternoon and failed for the first hour of every day, CI included.
fresh_home
export AGENTBAR_NOW="$(node -e 'const d = new Date(); d.setHours(12, 0, 0, 0); console.log(Math.floor(d / 1000))')"
NOW="$AGENTBAR_NOW"
{
  printf '{"agent":"claude","sessionId":"h1","project":"Alpha","state":"done","startedAt":%s,"endedAt":%s}\n' "$((NOW-3600))" "$((NOW-1800))"
  printf '{"agent":"codex","sessionId":"h2","project":"Beta","state":"error","startedAt":%s,"endedAt":%s}\n' "$((NOW-900))" "$((NOW-300))"
  # Yesterday: a digest called Today that counts backwards 24h from whenever you
  # look at it is not a day.
  printf '{"agent":"claude","sessionId":"h3","project":"Old","state":"done","startedAt":%s,"endedAt":%s}\n' "$((NOW-200000))" "$((NOW-190000))"
} > "$HOME/.agentbar/history.jsonl"
OUT="$("$CLI" history)"
check "history lists today"            'echo "$OUT" | grep -q Alpha && echo "$OUT" | grep -q Beta'
check "history excludes yesterday"     '! echo "$OUT" | grep -q Old'
check "history counts failures"        'echo "$OUT" | grep -q "1 failed"'
check "history totals the durations"   'echo "$OUT" | grep -q "40m"'
check "history --days reaches back"    '"$CLI" history --days 5 | grep -q Old'
check "history --json is machine-readable" '"$CLI" history --json | grep -q "\"sessionId\": \"h2\""'
# A duration is a LENGTH, not an age: passing one to the live-row helper renders
# decades, because that one subtracts its argument from now.
check "history duration is not an age" '! echo "$OUT" | grep -qE "[0-9]{4,}h"'
fresh_home
check "history with no record says so" '"$CLI" history | grep -qi "nothing"'

# --- history: what a session cost, and what moved in the repo. Both are optional
# in the protocol, and "absent" has to survive as absent — a zero would be quoted.
# Clock pinned to noon, for the reason the block above gives.
fresh_home
export AGENTBAR_NOW="$(node -e 'const d = new Date(); d.setHours(12, 0, 0, 0); console.log(Math.floor(d / 1000))')"
NOW="$AGENTBAR_NOW"
{
  printf '{"agent":"claude","sessionId":"w1","project":"Alpha","state":"done","startedAt":%s,"endedAt":%s,"weight":{"in":1330,"out":622024,"cacheWrite":1453897,"cacheRead":220795232,"src":"claude-transcript"},"change":{"files":7,"added":210,"removed":80,"base":"3a30264"}}\n' "$((NOW-3600))" "$((NOW-1800))"
  printf '{"agent":"gemini","sessionId":"w2","project":"Beta","state":"done","startedAt":%s,"endedAt":%s}\n' "$((NOW-900))" "$((NOW-300))"
} > "$HOME/.agentbar/history.jsonl"
OUT="$("$CLI" history)"
# 1330 + 622024 + 1453897 = 2_077_251. Cache reads are stored and never shown:
# including them would make the same session read as 222.9M.
check "history shows the token total"  'echo "$OUT" | grep -q "2.1M"'
check "history hides cache reads"      '! echo "$OUT" | grep -q "222"'
check "history shows what changed"     'echo "$OUT" | grep -q "7 files +210"'
# Seven of the ten agents publish nothing to measure, so a partial total is the
# normal case — presenting it as the day's spend would be wrong most days.
check "partial token total says so"    'echo "$OUT" | grep -q "tokens across 1"'
check "an unmeasured row stays blank"  '! echo "$OUT" | grep -E "Beta.*[0-9]+(k|M)"'

unset AGENTBAR_NOW

# An agent that keeps a readable number gets one written for it. Claude Code's
# session id IS its transcript's file name, which is what makes the lookup exact.
fresh_home
PROJ="$HOME/.claude/projects/-tmp-cliweight"
mkdir -p "$PROJ"
{
  printf '{"type":"assistant","timestamp":"2026-09-16T12:00:00.000Z","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":5,"cache_read_input_tokens":900}}}\n'
  # The same message again — one message spans several transcript lines, each
  # repeating the usage object. Counting lines would double the answer.
  printf '{"type":"assistant","timestamp":"2026-09-16T12:00:00.000Z","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":5,"cache_read_input_tokens":900}}}\n'
} > "$PROJ/cw1.jsonl"
mkdir -p "$HOME/.agentbar/state.d"
printf '{"agent":"claude","state":"tool","started":true,"ts":%s,"pid":%s,"cwd":"/tmp/cliweight","project":"CliWeight","sessionId":"cw1"}' "$(date +%s)" "$$" \
  > "$HOME/.agentbar/state.d/cw1.json"
"$CLI" status >/dev/null 2>&1
printf '{"agent":"claude","state":"done","started":true,"ts":%s,"pid":%s,"cwd":"/tmp/cliweight","project":"CliWeight","sessionId":"cw1"}' "$(date +%s)" "$$" \
  > "$HOME/.agentbar/state.d/cw1.json"
"$CLI" status >/dev/null 2>&1
check "weight is recorded for claude"  'grep -q "\"src\":\"claude-transcript\"" "$HOME/.agentbar/history.jsonl"'
check "duplicate lines counted once"   'grep -q "\"out\":20" "$HOME/.agentbar/history.jsonl"'

# An agent with nothing on disk must leave the field out entirely rather than
# writing zeroes somebody then reads as "it cost nothing".
fresh_home
seed_session nw tool $$
"$CLI" status >/dev/null 2>&1
rm -f "$HOME/.agentbar/state.d/nw.json"
"$CLI" status >/dev/null 2>&1
check "no source means no weight key"  '! grep -q "weight" "$HOME/.agentbar/history.jsonl"'
check "no repo means no change key"    '! grep -q "change" "$HOME/.agentbar/history.jsonl"'

unset AGENTBAR_NOW

# --- requests + approve/deny
fresh_home
seed_request r1 $$
OUT="$("$CLI" requests --json)"
check "requests lists pending"         'echo "$OUT" | grep -q "Bash: ls"'
"$CLI" approve >/dev/null
check "approve writes allow answer"    'grep -q "\"behavior\":\"allow\"" "$HOME/.agentbar/answers.d/r1.json"'
# Answers name the hook they are for — request names repeat within a turn, and
# the hook discards answers aimed at a predecessor (docs/protocol.md).
check "approve stamps hookPid"         'grep -q "\"hookPid\":'"$$"'" "$HOME/.agentbar/answers.d/r1.json"'
rm -f "$HOME/.agentbar/answers.d/r1.json"
"$CLI" approve --always >/dev/null
check "approve --always carries rule"  'grep -q "\"behavior\":\"always\"" "$HOME/.agentbar/answers.d/r1.json" && grep -q addRules "$HOME/.agentbar/answers.d/r1.json"'
rm -f "$HOME/.agentbar/answers.d/r1.json"
"$CLI" deny >/dev/null
check "deny writes deny answer"        'grep -q "\"behavior\":\"deny\"" "$HOME/.agentbar/answers.d/r1.json"'
rm -f "$HOME/.agentbar/answers.d/r1.json"
OUT="$("$CLI" deny --note "use pnpm
here" 2>&1)"
check "deny --note carries the note"   'grep -q "\"message\":\"use pnpm here\"" "$HOME/.agentbar/answers.d/r1.json"'
check "deny --note echoes what it said" 'echo "$OUT" | grep -q "told it: \"use pnpm here\""'
rm -f "$HOME/.agentbar/answers.d/r1.json"
"$CLI" deny -m "   " >/dev/null
check "a blank note is no note"        '! grep -q message "$HOME/.agentbar/answers.d/r1.json"'
rm -f "$HOME/.agentbar/answers.d/r1.json"
"$CLI" deny --note "$(printf 'x%.0s' $(seq 498))😀tail" >/dev/null
check "a long note never ends on half an emoji" '! grep -qi "\\\\ud83d" "$HOME/.agentbar/answers.d/r1.json"'
rm -f "$HOME/.agentbar/answers.d/r1.json"
check "a note on approve is refused"   '! "$CLI" approve --note "x" >/dev/null 2>&1 && [ ! -f "$HOME/.agentbar/answers.d/r1.json" ]'
check "dead-hook request pruned"       'seed_request dead 999999; "$CLI" requests >/dev/null; [ ! -f "$HOME/.agentbar/requests.d/dead.json" ]'

# --- questions: rendering, queue priority, the answer command
seed_question() { # $1 name, $2 ts, $3 multiSelect
  printf '{"sessionId":"s2","agent":"claude","toolName":"AskUserQuestion","display":"Question: Which color?","toolInputPretty":"{}","context":{"kind":"question","questions":[{"question":"Which color?","header":"Color","multiSelect":%s,"options":[{"label":"Red","description":"warm"},{"label":"Blue","description":"cool"}]}]},"pid":%s,"hookPid":%s,"ts":%s}' \
    "$3" $$ $$ "$2" > "$HOME/.agentbar/requests.d/$1.json"
}
fresh_home
NOW=$(date +%s)
seed_request perm $$; python3 - "$HOME/.agentbar/requests.d/perm.json" $((NOW-5)) <<'PY'
import json, sys
f, ts = sys.argv[1], int(sys.argv[2])
j = json.load(open(f)); j["ts"] = ts; json.dump(j, open(f, "w"))
PY
seed_question quest "$NOW" false
check "requests renders question options" '"$CLI" requests | grep -q "1) Red"'
"$CLI" approve >/dev/null 2>&1
check "bare approve skips the question"   'grep -q "\"behavior\":\"allow\"" "$HOME/.agentbar/answers.d/perm.json" && [ ! -f "$HOME/.agentbar/answers.d/quest.json" ]'
rm -f "$HOME/.agentbar/answers.d/perm.json"
check "explicit index on question errors" '! "$CLI" approve 1 >/dev/null 2>&1'
"$CLI" answer Blue >/dev/null
check "answer by label"                   'grep -q "\"answers\":\[\[\"Blue\"\]\]" "$HOME/.agentbar/answers.d/quest.json"'
check "answer stamps hookPid"             'grep -q "\"hookPid\":'"$$"'" "$HOME/.agentbar/answers.d/quest.json"'
rm -f "$HOME/.agentbar/answers.d/quest.json"
"$CLI" answer 1 Red >/dev/null   # explicit request index 1 (the question), option by name
check "answer with explicit index"        'grep -q "\"answers\":\[\[\"Red\"\]\]" "$HOME/.agentbar/answers.d/quest.json"'
rm -f "$HOME/.agentbar/answers.d/quest.json"
check "answer rejects unknown label"      '! "$CLI" answer Green >/dev/null 2>&1'
check "answer rejects two on single-select" '! "$CLI" answer Red Blue >/dev/null 2>&1'
seed_question multi "$((NOW+1))" true
"$CLI" answer Red Blue >/dev/null
check "multiSelect takes several labels"  'grep -q "\"answers\":\[\[\"Red\",\"Blue\"\]\]" "$HOME/.agentbar/answers.d/multi.json"'

# --- waybar: heartbeat + JSON shape
fresh_home
seed_session live permission $$
OUT="$("$CLI" waybar)"
check "waybar emits permission class"  'echo "$OUT" | grep -q "\"class\":\"permission\""'
check "waybar writes heartbeat"        'grep -q "\"ts\":" "$HOME/.agentbar/watcher.json"'
# A session waiting on an AskUserQuestion is waiting on the human like a
# permission is — it must not render as a quiet "idle".
fresh_home
seed_session ask question $$
OUT="$("$CLI" waybar)"
check "waybar surfaces question class" 'echo "$OUT" | grep -q "\"class\":\"question\""'

# --- heartbeat makes the permission hook block (watcher path, no app)
fresh_home
"$CLI" waybar >/dev/null   # fresh heartbeat
unset AGENTBAR_FORCE_APP
printf '{"session_id":"s1","prompt_id":"p1","tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"/tmp"}' |
  AGENTBAR_APPROVAL_TIMEOUT=5 "$NODE" Scripts/hooks/claude/permission.js > "$TESTROOT/hookout" &
HOOKPID=$!
REQ=""
for _ in $(seq 50); do
  REQ="$(ls "$HOME/.agentbar/requests.d/" 2>/dev/null | head -1)"
  [ -n "$REQ" ] && break
  sleep 0.1
done
check "hook blocks on CLI heartbeat"   '[ -n "$REQ" ]'
"$CLI" approve >/dev/null 2>&1
wait "$HOOKPID"
check "CLI answer reaches the hook"    'grep -q "\"behavior\":\"allow\"" "$TESTROOT/hookout"'

# --- watch keeps presence alive on its own clock, whatever -i says
# A redraw every 10 minutes must not let the 60s heartbeat lapse: the beat is
# refreshed every 20s independently of render(). Removing the file after the first
# frame and seeing it come back long before the next frame proves the second clock.
fresh_home
"$CLI" watch -i 600 </dev/null >/dev/null 2>&1 &
WATCHPID=$!
for _ in $(seq 50); do [ -e "$HOME/.agentbar/watcher.json" ] && break; sleep 0.1; done
check "watch writes its heartbeat"     '[ -e "$HOME/.agentbar/watcher.json" ]'
rm -f "$HOME/.agentbar/watcher.json"
for _ in $(seq 250); do [ -e "$HOME/.agentbar/watcher.json" ] && break; sleep 0.1; done
check "watch -i 600 still beats within the TTL" '[ -e "$HOME/.agentbar/watcher.json" ]'
kill -TERM "$WATCHPID" 2>/dev/null; wait "$WATCHPID" 2>/dev/null
check "watch takes its heartbeat with it" '[ ! -e "$HOME/.agentbar/watcher.json" ]'

# --- install-hooks: wiring, idempotence, unparseable config untouched
fresh_home
mkdir -p "$HOME/.gemini" "$HOME/.cursor" "$HOME/.claude" "$HOME/.qwen" "$HOME/.codex" "$HOME/.config/opencode" "$HOME/.copilot"
echo '{"theme":"dark"}' > "$HOME/.gemini/settings.json"
# A hooks file of the user's own, next to ours: Copilot loads every *.json in the
# dir, so ours must be a separate file and theirs must come back untouched.
mkdir -p "$HOME/.copilot/hooks"
echo '{"version":1,"hooks":{"SessionStart":[{"type":"command","bash":"true"}]}}' > "$HOME/.copilot/hooks/mine.json"
"$CLI" install-hooks >/dev/null 2>&1
check "gemini wired, existing kept"    'grep -q BeforeAgent "$HOME/.gemini/settings.json" && grep -q theme "$HOME/.gemini/settings.json"'
check "cursor wired with pinned node"  'grep -q afterAgentResponse "$HOME/.cursor/hooks.json" && head -1 "$HOME/.agentbar/hooks/cursor/cursor.js" | grep -qv "env node"'
check "claude wired"                   'grep -q PermissionRequest "$HOME/.claude/settings.json"'
check "qwen wired with its identity"   'grep -q StopFailure "$HOME/.qwen/settings.json" && grep -q AGENTBAR_AGENT "$HOME/.qwen/settings.json"'
check "codex notify wired"             'grep -q "/.agentbar/hooks/codex/" "$HOME/.codex/config.toml"'
check "opencode plugin installed"      '[ -f "$HOME/.config/opencode/plugins/agentbar.js" ]'
check "copilot wired with its identity" 'grep -q ErrorOccurred "$HOME/.copilot/hooks/agentbar.json" && grep -q "\"copilot\"" "$HOME/.copilot/hooks/agentbar.json"'
# exec+args, never a shell line: a bash wrapper would make the hook'"'"'s parent a
# shell that exits at once, and ppid is what prunes dead rows.
check "copilot runs node directly"     'grep -q "\"exec\"" "$HOME/.copilot/hooks/agentbar.json" && ! grep -q "\"bash\"" "$HOME/.copilot/hooks/agentbar.json"'
# Copilot's permissionRequest blocks and decides — that is remote Allow/Deny. Its
# timeout must sit ABOVE the hook's own 600s wait, or Copilot kills the hook
# mid-wait instead of letting it fall through to the terminal prompt.
check "copilot approval wired"        'grep -q "permissionRequest" "$HOME/.copilot/hooks/agentbar.json"'
APPROVAL_HOOK="$("$NODE" -e '
const fs=require("fs"),os=require("os"),path=require("path");
const h=JSON.parse(fs.readFileSync(path.join(os.homedir(),".copilot/hooks/agentbar.json"),"utf8"))
  .hooks.permissionRequest[0];
process.stdout.write([h.timeoutSec, h.exec ? "exec" : "shell", path.basename(h.args[0])].join(" "));')"
check "copilot approval outlasts hook" '[ "$(echo "$APPROVAL_HOOK" | cut -d" " -f1)" -gt 600 ]'
check "copilot approval runs node directly" '[ "$APPROVAL_HOOK" = "630 exec permission.js" ]'
check "copilot leaves other hook files" 'grep -q "\"bash\":\"true\"" "$HOME/.copilot/hooks/mine.json"'
# The node path written into every config must name the SAME interpreter this CLI
# runs on, and must prefer a stable alias over the version-pinned path execPath
# resolves to — a hook config outlives the next node upgrade, and a hook whose
# interpreter has moved silently never fires.
WROTE_NODE="$("$NODE" -e '
const fs=require("fs"),os=require("os"),path=require("path");
const cfg=JSON.parse(fs.readFileSync(path.join(os.homedir(),".copilot/hooks/agentbar.json"),"utf8"));
process.stdout.write(cfg.hooks.SessionStart[0].exec);')"
check "node path is executable"        '[ -x "$WROTE_NODE" ]'
check "node path is the same binary"   '[ "$("$NODE" -e "console.log(require(\"fs\").realpathSync(process.argv[1]))" "$WROTE_NODE")" = "$("$NODE" -e "console.log(require(\"fs\").realpathSync(process.execPath))")" ]'
# When a stable alias for this node exists, it must have been chosen over execPath.
STABLE="$("$NODE" -e '
const fs=require("fs"),os=require("os"),path=require("path");
const real=(p)=>{try{return fs.realpathSync(p)}catch{return null}};
const self=real(process.execPath);
const c=["/usr/bin/node","/usr/local/bin/node","/opt/homebrew/bin/node",path.join(os.homedir(),".local/bin/node")]
  .find((x)=>x!==process.execPath&&real(x)===self);
process.stdout.write(c||"");')"
check "stable node alias preferred"    '[ -z "$STABLE" ] || [ "$WROTE_NODE" = "$STABLE" ]'
SNAP="$(cat "$HOME/.gemini/settings.json")"
QWEN_SNAP="$(cat "$HOME/.qwen/settings.json")"
COPILOT_SNAP="$(cat "$HOME/.copilot/hooks/agentbar.json")"
CODEX_SNAP="$(cat "$HOME/.codex/config.toml")"
"$CLI" install-hooks >/dev/null 2>&1
check "install-hooks idempotent"       '[ "$SNAP" = "$(cat "$HOME/.gemini/settings.json")" ] && [ "$QWEN_SNAP" = "$(cat "$HOME/.qwen/settings.json")" ] && [ "$COPILOT_SNAP" = "$(cat "$HOME/.copilot/hooks/agentbar.json")" ] && [ "$CODEX_SNAP" = "$(cat "$HOME/.codex/config.toml")" ]'
# A node that has moved (nvm upgrade, Cellar bump) must be repaired on the next run.
# Codex is the one config that used to stop at the marker and never re-check, so a
# stale interpreter there was permanent: every other agent healed on the next run
# and Codex stayed broken until someone hand-edited the TOML.
sed -i.bak "s|^notify = \[\"[^\"]*\"|notify = [\"$HOME/.nvm/versions/node/v0.0.0/bin/node\"|" "$HOME/.codex/config.toml"
check "codex dead node path seeded"    'grep -q "v0.0.0" "$HOME/.codex/config.toml"'
"$CLI" install-hooks >/dev/null 2>&1
check "codex dead node path repaired"  '! grep -q "v0.0.0" "$HOME/.codex/config.toml" && grep -q "/.agentbar/hooks/codex/" "$HOME/.codex/config.toml"'
check "codex repair keeps one notify"  '[ "$(grep -c "^notify = " "$HOME/.codex/config.toml")" = 1 ]'
echo '{broken' > "$HOME/.gemini/settings.json"
"$CLI" install-hooks >/dev/null 2>&1
check "unparseable config untouched"   '[ "$(cat "$HOME/.gemini/settings.json")" = "{broken" ]'
CLAUDE_CONFIG_DIR="$HOME/.claude-custom" "$CLI" install-hooks >/dev/null 2>&1
check "CLAUDE_CONFIG_DIR wired (contained)" 'grep -q PermissionRequest "$HOME/.claude-custom/settings.json"'
OUTSIDE="$TESTROOT/outside-home.$$"; mkdir -p "$OUTSIDE"
CLAUDE_CONFIG_DIR="$OUTSIDE" "$CLI" install-hooks >/dev/null 2>&1
check "CLAUDE_CONFIG_DIR outside HOME skipped" '[ ! -e "$OUTSIDE/settings.json" ]'
CLAUDE_CONFIG_DIR="$OUTSIDE" AGENTBAR_ALLOW_CONFIG_OUTSIDE_HOME=1 "$CLI" install-hooks >/dev/null 2>&1
check "outside HOME wired when allowed"  'grep -q PermissionRequest "$OUTSIDE/settings.json"'
# HookInstaller.wiredClaudeDirs: a ~/.claude-* wired once from a shell with the
# variable is kept current without it; one nobody wired is left alone.
mkdir -p "$HOME/.claude-mine" && echo '{}' > "$HOME/.claude-mine/settings.json"
node -e 'const f=process.argv[1],j=JSON.parse(require("fs").readFileSync(f));delete j.hooks.PermissionRequest;require("fs").writeFileSync(f,JSON.stringify(j))' "$HOME/.claude-custom/settings.json"
"$CLI" install-hooks >/dev/null 2>&1
check "wired ~/.claude-* kept without the variable" 'grep -q PermissionRequest "$HOME/.claude-custom/settings.json"'
check "unwired ~/.claude-* left alone"  '[ "$(cat "$HOME/.claude-mine/settings.json")" = "{}" ]'


# --- plan requests: the hook can't carry a plan approval, so the CLI must say so
seed_plan() { # $1 name
  printf '{"sessionId":"s3","agent":"claude","toolName":"ExitPlanMode","display":"Plan ready for review","toolInputPretty":"{}","context":{"kind":"plan","plan":"## Plan\\n1. Edit auth.ts\\n2. Run tests"},"pid":%s,"hookPid":%s,"ts":%s}' \
    $$ $$ "$(date +%s)" > "$HOME/.agentbar/requests.d/$1.json"
}
fresh_home
seed_plan plan1
check "requests renders the plan"          '"$CLI" requests | grep -q "Edit auth.ts"'
check "requests explains plan semantics"   '"$CLI" requests | grep -q "keep planning"'
check "approve on a plan refuses"          '! "$CLI" approve >/dev/null 2>&1 && [ ! -f "$HOME/.agentbar/answers.d/plan1.json" ]'
"$CLI" deny >/dev/null
check "deny on a plan = keep planning"     'grep -q "\"behavior\":\"deny\"" "$HOME/.agentbar/answers.d/plan1.json"'

# --- answer: multi-question calls can't be answered from a one-liner
fresh_home
printf '{"sessionId":"s4","agent":"claude","toolName":"AskUserQuestion","display":"Question: Which?","toolInputPretty":"{}","context":{"kind":"question","questions":[{"question":"Which layers?","header":"Layers","multiSelect":true,"options":[{"label":"API"},{"label":"UI"}]},{"question":"Ship?","header":"","multiSelect":false,"options":[{"label":"Yes"},{"label":"No"}]}]},"pid":%s,"hookPid":%s,"ts":%s}' \
  $$ $$ "$(date +%s)" > "$HOME/.agentbar/requests.d/multiq.json"
check "answer refuses multi-question calls" '! "$CLI" answer API >/dev/null 2>&1 && [ ! -f "$HOME/.agentbar/answers.d/multiq.json" ]'

# --- waybar: the remaining classes
fresh_home
OUT="$("$CLI" waybar)"
check "waybar empty class with no sessions" 'echo "$OUT" | grep -q "\"class\":\"empty\""'
seed_session busy tool $$
OUT="$("$CLI" waybar)"
check "waybar working class"                'echo "$OUT" | grep -q "\"class\":\"working\"" && echo "$OUT" | grep -q "● 1"'
seed_session waiting permission $$
OUT="$("$CLI" waybar)"
check "waybar permission outranks working"  'echo "$OUT" | grep -q "\"class\":\"permission\""'

# --- status text: a failed turn reads as failed, a question as waiting
fresh_home
printf '{"agent":"claude","state":"error","label":"provider returned 429","project":"proj","pid":%s,"started":true,"ts":%s}' $$ "$(date +%s)" > "$HOME/.agentbar/state.d/err.json"
check "status shows failed + reason"        '"$CLI" status | grep -q "failed" && "$CLI" status | grep -q "provider returned 429"'

# --- usage: what's left of each provider's quota
# A rollout carries more than one bucket and the LAST token_count line is often the
# "premium" one, whose windows are null. Reading only that line loses the whole row.
fresh_home
export CODEX_HOME="$HOME/.codex"
export COPILOT_HOME="$HOME/.copilot-empty"
mkdir -p "$CODEX_HOME/sessions/2026/09/17"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SOON=$(($(date +%s) + 3600))
LATER=$(($(date +%s) + 86400))
{
  printf '{"timestamp":"%s","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","primary":{"used_percent":97.0,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":27.0,"window_minutes":10080,"resets_at":%s},"credits":null}}}\n' "$STAMP" "$SOON" "$LATER"
  printf '{"timestamp":"%s","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"premium","primary":null,"secondary":null,"credits":{"has_credits":false,"balance":"0"}}}}\n' "$STAMP"
} > "$CODEX_HOME/sessions/2026/09/17/rollout-2026-09-17T10-00-00-abc.jsonl"
OUT="$("$CLI" usage)"
check "usage reads past the premium line"   'echo "$OUT" | grep -q "3% left"'
check "usage shows the weekly window too"   'echo "$OUT" | grep -q "73% left"'
check "usage says who it cannot ask"        'echo "$OUT" | grep -q "Claude keeps its windows"'
check "usage omits a Copilot with no db"    '! echo "$OUT" | grep -q "AIU"'
check "usage --json carries the windows"    '"$CLI" usage --json | grep -q "\"used\": 97"'
check "no credit line without credits"      '! echo "$OUT" | grep -q "credits left"'

# A window whose reset has passed: nobody has written a number since it rolled
# over, so there must be no bar and no percentage — only the fact.
printf '{"timestamp":"%s","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","primary":{"used_percent":97.0,"window_minutes":300,"resets_at":%s},"secondary":null,"credits":null}}}\n' \
  "$STAMP" "$(($(date +%s) - 60))" > "$CODEX_HOME/sessions/2026/09/17/rollout-2026-09-17T11-00-00-def.jsonl"
OUT="$("$CLI" usage)"
check "a rolled-over window says so"        'echo "$OUT" | grep -q "window reset" && ! echo "$OUT" | grep -q "3% left"'

# Stale beats wrong: a rollout nobody has touched for two days speaks for nothing.
fresh_home
export CODEX_HOME="$HOME/.codex"
mkdir -p "$CODEX_HOME/sessions/2026/09/17"
OLD="$(date -u -r $(($(date +%s) - 172800)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d @$(($(date +%s) - 172800)) +%Y-%m-%dT%H:%M:%SZ)"
printf '{"timestamp":"%s","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","primary":{"used_percent":97.0,"window_minutes":300,"resets_at":%s},"secondary":null,"credits":null}}}\n' \
  "$OLD" "$SOON" > "$CODEX_HOME/sessions/2026/09/17/rollout-2026-09-17T10-00-00-old.jsonl"
check "a stale rollout speaks for nothing"  '! "$CLI" usage | grep -q "% left"'
unset CODEX_HOME COPILOT_HOME

# --- decisions: what the human decided, kept so the next prompt can say so
fresh_home
seed_session s1 permission $$
printf '{"sessionId":"s1","agent":"claude","toolName":"Bash","display":"Bash: git push origin main","toolInputPretty":"{}","context":{"kind":"bash","command":"git push origin main"},"ruleSuggestion":{"type":"addRules"},"pid":%s,"hookPid":%s,"ts":%s}' \
  $$ $$ "$(($(date +%s) - 45))" > "$HOME/.agentbar/requests.d/d1.json"
"$CLI" approve >/dev/null
LEDGER="$HOME/.agentbar/decisions.jsonl"
check "a decision is recorded"              '[ -f "$LEDGER" ] && grep -q "\"decision\":\"allow\"" "$LEDGER"'
# The shape is what repeats are counted by: the verb, never the arguments — those
# never repeat, and they are where a path or a secret would be.
check "the shape keeps the verb"            'grep -q "\"shape\":\"bash:git push\"" "$LEDGER"'
check "the shape drops the arguments"       '! grep -q "shape\":\"bash:git push origin" "$LEDGER"'
check "the wait is measured"                'node -e "const r=JSON.parse(require(\"fs\").readFileSync(process.env.HOME+\"/.agentbar/decisions.jsonl\",\"utf8\").trim());process.exit(r.waited>=40&&r.waited<=120?0:1)"'
check "the frontend names itself"           'grep -q "\"via\":\"cli\"" "$LEDGER"'

# Two decisions about the same command are two decisions — nothing collapses here.
printf '{"sessionId":"s1","agent":"claude","toolName":"Bash","display":"Bash: git push origin main","toolInputPretty":"{}","context":{"kind":"bash","command":"git push origin main"},"pid":%s,"hookPid":%s,"ts":%s}' \
  $$ $$ "$(date +%s)" > "$HOME/.agentbar/requests.d/d2.json"
"$CLI" deny >/dev/null
check "both decisions survive"              '[ "$(wc -l < "$LEDGER" | tr -d " ")" = "2" ]'
OUT="$("$CLI" approvals)"
check "approvals counts the repeat"         'echo "$OUT" | grep -q "bash:git push"'
check "approvals counts both verdicts"      'echo "$OUT" | grep -q "1 allowed" && echo "$OUT" | grep -q "1 denied"'
check "approvals reports the waiting"       'echo "$OUT" | grep -q "waited"'
check "approvals --json carries the rows"   '"$CLI" approvals --json | grep -q "\"answered\": 2"'

check "forget empties the ledger"           '"$CLI" forget | grep -q "Forgot 2 decisions" && [ ! -f "$LEDGER" ]'

# --- rules: what the human wrote down, listed here and applied by the app
fresh_home
check "no rules says so plainly"            '"$CLI" rules | grep -q "No rules"'
printf '{"v":1,"rules":[{"id":"r-aaa111","decision":"allow","shape":"bash:git status","cwd":"%s","enabled":true},{"id":"r-bbb222","decision":"deny","shape":"bash:curl","cwd":"","enabled":true}]}' \
  "$HOME/proj" > "$HOME/.agentbar/rules.json"
OUT="$("$CLI" rules)"
check "a rule is listed with its verb"      'echo "$OUT" | grep -q "allow" && echo "$OUT" | grep -q "bash:git status"'
check "a denial may name no directory"      'echo "$OUT" | grep -q "everywhere"'
check "a rule that never fired says so"     'echo "$OUT" | grep -q "never fired"'
# The CLI lists rules; only the app answers from one. Saying so is the point — a
# Linux user must not believe their rules are running here.
check "it says it does not apply them"      'echo "$OUT" | grep -q "does not answer from them"'
check "rules --json says applied is false"  '"$CLI" rules --json | grep -q "\"applied\": false"'

# A firing is counted from the ledger, never from a counter inside rules.json.
printf '{"v":1,"ts":%s,"agent":"claude","sessionId":"s1","project":"proj","cwd":"%s","tool":"Bash","shape":"bash:git status","display":"Bash: git status","decision":"allow","waited":0,"via":"rule","rule":"r-aaa111"}\n' \
  "$(date +%s)" "$HOME/proj" > "$HOME/.agentbar/decisions.jsonl"
check "a firing is counted from the ledger" '"$CLI" rules | grep -q "1x"'
check "rules.json holds no counter"         '! grep -q "fired" "$HOME/.agentbar/rules.json"'
# A rule's row is not the person answering: it must not inflate "N answered".
OUT="$("$CLI" approvals)"
check "approvals keeps rules apart"         'echo "$OUT" | grep -q "0 answered" && echo "$OUT" | grep -q "1 by your rules"'
# Claude Code deciding before any prompt existed is not the person answering either.
printf '{"v":1,"ts":%s,"agent":"claude","sessionId":"s1","project":"proj","cwd":"%s","tool":"Bash","shape":"bash:git status","display":"Bash: git status","decision":"allow","waited":0,"via":"claude","by":"rule","claudeRule":"Bash(git status:*)","toolUseId":"toolu_1"}\n' \
  "$(date +%s)" "$HOME/proj" >> "$HOME/.agentbar/decisions.jsonl"
OUT="$("$CLI" approvals)"
check "approvals keeps Claude Code apart"   'echo "$OUT" | grep -q "0 answered" && echo "$OUT" | grep -q "1 decided by Claude Code"'
check "the export names Claude Code's rule" '"$CLI" approvals --export | grep -qF "\"claude\",\"\",\"rule\",\"Bash(git status:*)\""'

# One bad rule refuses the whole file: a policy half in force is worse than none.
printf '{"v":1,"rules":[{"id":"r-aaa111","decision":"allow","shape":"bash:git status","cwd":"%s"},{"id":"r-ccc333","decision":"allow","shape":"bash:ls"}]}' \
  "$HOME/proj" > "$HOME/.agentbar/rules.json"
OUT="$("$CLI" rules)"
check "one bad rule voids the file"         'echo "$OUT" | grep -q "No rules are in force" && ! echo "$OUT" | grep -q "bash:git status"'
printf 'not json' > "$HOME/.agentbar/rules.json"
check "junk voids the file too"             '"$CLI" rules | grep -q "not valid JSON"'

# A rule can be made to watch: it answers nothing and writes down what it would
# have done. The two are counted apart, because one of them happened.
fresh_home
printf '{"v":1,"rules":[{"id":"r-www","decision":"allow","shape":"bash:git status","cwd":"%s","mode":"watch"}]}' \
  "$HOME/proj" > "$HOME/.agentbar/rules.json"
check "a watching rule says so"             '"$CLI" rules | grep -q "(watch)"'
check "and that it matched nothing yet"     '"$CLI" rules | grep -q "nothing matched yet"'
printf '{"v":1,"ts":%s,"agent":"claude","sessionId":"s1","project":"proj","cwd":"%s","tool":"Bash","shape":"bash:git status","display":"Bash: git status","decision":"watch","would":"allow","waited":0,"via":"rule","rule":"r-www"}\n' \
  "$(date +%s)" "$HOME/proj" > "$HOME/.agentbar/decisions.jsonl"
check "it counts what it would have done"   '"$CLI" rules | grep -q "1x would have"'
# The row is not something that happened, so nothing counts it as one.
OUT="$("$CLI" approvals)"
# Neither a person nor a rule answered anything, so the day has nothing in it —
# not "0 answered", which would be a result where there is an absence.
check "a watch row answered nothing"        'echo "$OUT" | grep -q "Nothing answered yet" && ! echo "$OUT" | grep -q "by your rules"'
check "rules --json separates the two"      '"$CLI" rules --json | grep -q "\"wouldHave\": 1" && "$CLI" rules --json | grep -q "\"allowed\": 0"'
# A typo in mode must not be read as "on".
printf '{"v":1,"rules":[{"id":"r-x","decision":"deny","shape":"bash:curl","mode":"yes"}]}' > "$HOME/.agentbar/rules.json"
check "an unreadable mode voids the file"   '"$CLI" rules | grep -q "mode is not on, watch or off"'
printf '{"v":1,"rules":[{"id":"r-t","decision":"deny","shape":"bash:npm","tell":"use pnpm"}]}' > "$HOME/.agentbar/rules.json"
check "a denial lists what it tells"         '"$CLI" rules | grep -q "tells it: \"use pnpm\""'
printf '{"v":1,"rules":[{"id":"r-t","decision":"allow","shape":"bash:npm","cwd":"/r","tell":"x"}]}' > "$HOME/.agentbar/rules.json"
check "an approval that tells voids the file" '"$CLI" rules | grep -q "only a denial says anything"'
# A cwd written any way but plainly is refused, not tidied — the app compares it as
# text, so `/x/repo/` would never match and `/x/repo/../other` names somewhere else.
# Same refusal RulesStore.validate makes, and the same plain form in the message.
plain_cwd_refused() { # $1 cwd, $2 the plain form the message must offer
  printf '{"v":1,"rules":[{"id":"r-c","decision":"deny","shape":"bash:curl","cwd":"%s"}]}' "$1" > "$HOME/.agentbar/rules.json"
  "$CLI" rules | grep -q "not written plainly" && "$CLI" rules | grep -q "Write it as $2\.$"
}
check "a trailing slash voids the file"      'plain_cwd_refused /x/repo/ /x/repo'
check "a doubled slash voids the file"       'plain_cwd_refused /x//repo /x/repo'
check "a dot voids the file"                 'plain_cwd_refused /x/./repo /x/repo'
check "a dot-dot voids the file"             'plain_cwd_refused /x/repo/../other /x/other'
check "a plain cwd stays in force"           '! plain_cwd_refused /x/repo /x/repo && "$CLI" rules | grep -q "^deny  bash:curl"'
check "root is plain"                        '! plain_cwd_refused / /'

# Whether you agreed with a watching rule, from the fixture RuleAgreementTests
# reads too — so the app and this command cannot quietly count differently.
fresh_home
cp Tests/Fixtures/rule-agreement/rules.json Tests/Fixtures/rule-agreement/decisions.jsonl "$HOME/.agentbar/"
export AGENTBAR_NOW=$((1789646400 + 21600))
OUT="$("$CLI" rules)"
JSON="$("$CLI" rules --json)"
agreed_json() { # $1 rule id, $2 node expression over a = its agreement
  echo "$JSON" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const a=JSON.parse(s).rules.find(r=>r.id===process.argv[1]).agreement;process.exit(eval(process.argv[2])?0:1)})' "$1" "$2"
}
check "agreement counts only since the last save" 'echo "$OUT" | grep -q "15x would have (watch) · you did the same 10x$"'
check "unwitnessed is never agreement"        'agreed_json r-agree "a.agreed===10 && a.disagreed===0 && a.unwitnessed===5 && a.days===3"'
check "ten over three days earns the offer"   'agreed_json r-agree "a.eligible===true" && echo "$OUT" | grep -q "Let it answer"'
check "always the other way is a disagreement" 'echo "$OUT" | grep -q "you did the same 2x, the other way 1x"'
check "one disagreement blocks the offer"     'agreed_json r-split "a.eligible===false && a.agreed===2 && a.disagreed===1 && a.days===1"'
check "the last disagreement is named"        'echo "$OUT" | grep -q "last the other way: you allowed \"Bash: curl https://example.com\""'
check "listing a rule never changes its mode" '"$CLI" rules >/dev/null; cmp -s "$HOME/.agentbar/rules.json" Tests/Fixtures/rule-agreement/rules.json'
# Nine is not ten: the oldest agreement left out of the ledger takes the offer with it.
grep -v '"sessionId":"a1"' Tests/Fixtures/rule-agreement/decisions.jsonl > "$HOME/.agentbar/decisions.jsonl"
JSON="$("$CLI" rules --json)"
check "nine agreements are not enough"        'agreed_json r-agree "a.agreed===9 && a.eligible===false"'
# Two days are not three: the whole first day gone, six left over two.
grep -vE '"sessionId":"a[1-4]"' Tests/Fixtures/rule-agreement/decisions.jsonl > "$HOME/.agentbar/decisions.jsonl"
JSON="$("$CLI" rules --json)"
check "two days are not enough"               'agreed_json r-agree "a.days===2 && a.eligible===false"'
unset AGENTBAR_NOW

# --- the Codex hooks block: the real integration, beside the older notify key ----
fresh_home
mkdir -p "$HOME/.codex"
printf 'model = "o3"\n\n[profiles.mine]\nmodel = "o4"\n' > "$HOME/.codex/config.toml"
"$CLI" install-hooks >/dev/null 2>&1
CODEX_CFG="$HOME/.codex/config.toml"
check "codex hooks block written"      'grep -q "^# >>> agentbar >>>" "$CODEX_CFG"'
check "codex hooks cover every event"  'for e in SessionStart SessionEnd UserPromptSubmit PreToolUse PostToolUse Stop PermissionRequest; do grep -q "^\[\[hooks.$e\]\]" "$CODEX_CFG" || exit 1; done'
# Above permission.js's own 600s wait, so the hook gives up first.
check "codex approval outlasts hook"   '[ "$(grep -c "^timeout = 630$" "$CODEX_CFG")" = 1 ]'
# Codex clamps SessionEnd to 3s; asking for more earns a warning every session.
check "codex session end within cap"   '[ "$(grep -c "^timeout = 3$" "$CODEX_CFG")" = 1 ]'
check "codex hooks run the shim"       'grep -q "/.agentbar/hooks/codex/hook.js" "$CODEX_CFG"'
check "codex block written once"       '[ "$(grep -c "^# >>> agentbar >>>" "$CODEX_CFG")" = 1 ]'
# The trap this had to fix first: the block carries the same path as the notify
# key, so a blind marker match reads it as "notify is wired" and never installs it.
check "hooks block keeps notify too"   '[ "$(grep -c "^notify = " "$CODEX_CFG")" = 1 ]'
check "codex keeps the user's keys"    'grep -q "^model = \"o3\"" "$CODEX_CFG" && grep -q "^\[profiles.mine\]" "$CODEX_CFG"'
# A bare key after a [table] header belongs to that table: notify must sit above
# the first one, or Codex reads it as profiles.mine.notify and sees none at all.
notify_is_top_level() { [ "$(grep -n "^notify = " "$CODEX_CFG" | cut -d: -f1)" -lt "$(grep -n "^\[" "$CODEX_CFG" | head -1 | cut -d: -f1)" ]; }
check "codex notify is top-level"      'notify_is_top_level'
CODEX_SNAP2="$(cat "$CODEX_CFG")"
"$CLI" install-hooks >/dev/null 2>&1
check "codex hooks install idempotent" '[ "$CODEX_SNAP2" = "$(cat "$CODEX_CFG")" ]'

# A config that has the block but lost its notify key must get notify back.
grep -v "^notify = " "$CODEX_CFG" > "$HOME/.codex/c.tmp" && mv "$HOME/.codex/c.tmp" "$CODEX_CFG"
check "notify removed for the test"    '! grep -q "^notify = " "$CODEX_CFG"'
"$CLI" install-hooks >/dev/null 2>&1
check "notify reinstalled beside block" 'grep -q "^notify = " "$CODEX_CFG" && grep -q "^# >>> agentbar >>>" "$CODEX_CFG"'
check "reinstalled notify is top-level" 'notify_is_top_level'
# ...and one an older release appended below every table is moved up.
grep -v "^notify = " "$CODEX_CFG" > "$HOME/.codex/c.tmp" && mv "$HOME/.codex/c.tmp" "$CODEX_CFG"
printf 'notify = ["%s", "%s"]\n' "$(command -v node)" "$HOME/.agentbar/hooks/codex/notify.js" >> "$CODEX_CFG"
"$CLI" install-hooks >/dev/null 2>&1
check "stranded notify moved to the top" 'notify_is_top_level && [ "$(grep -c "^notify = " "$CODEX_CFG")" = 1 ]'

# A settings file kept private stays private: the rewrite used to land at 0644.
fresh_home
mkdir -p "$HOME/.gemini"
printf '{}\n' > "$HOME/.gemini/settings.json" && chmod 600 "$HOME/.gemini/settings.json"
"$CLI" install-hooks >/dev/null 2>&1
check "install-hooks keeps a 0600 file 0600" '[ "$(stat -c %a "$HOME/.gemini/settings.json" 2>/dev/null || stat -f %Lp "$HOME/.gemini/settings.json")" = 600 ] && grep -q agentbar "$HOME/.gemini/settings.json"'

# --- backups and the diff: what install-hooks does to a file you wrote -----------
# The original is kept beside the file before anything is written; a run that
# changes nothing prints nothing and keeps nothing; only the newest three of
# AgentBar's own copies stay, and a copy the person named themselves is theirs.
fresh_home
mkdir -p "$HOME/.gemini"
echo '{"theme":"dark"}' > "$HOME/.gemini/settings.json"
echo 'mine' > "$HOME/.gemini/settings.json.agentbar-bak-mine"
OUT="$(AGENTBAR_NOW=1790000000 "$CLI" install-hooks 2>&1)"
GB() { ls "$HOME/.gemini" | grep -c '^settings\.json\.agentbar-bak-[0-9]\{8\}-[0-9]\{6\}' ; }
check "diff printed before the write"  'echo "$OUT" | grep -q "^-{\"theme\":\"dark\"}" && echo "$OUT" | grep -q "^+++ .*/.gemini/settings.json"'
check "original kept beside the file"  '[ "$(GB)" = 1 ] && [ "$(cat "$HOME"/.gemini/settings.json.agentbar-bak-2*)" = "{\"theme\":\"dark\"}" ]'
check "new file is not backed up"      '! ls "$HOME/.claude" | grep -q agentbar-bak'
OUT="$(AGENTBAR_NOW=1790000100 "$CLI" install-hooks 2>&1)"
check "no-op prints no diff"           '! echo "$OUT" | grep -q "^+++ "'
check "no-op keeps no backup"          '[ "$(GB)" = 1 ]'
for i in 1 2 3 4; do
  echo "{\"theme\":\"v$i\"}" > "$HOME/.gemini/settings.json"
  AGENTBAR_NOW=$((1790000000 + i * 100)) "$CLI" install-hooks >/dev/null 2>&1
done
check "only the last three backups stay" '[ "$(GB)" = 3 ] && grep -q v4 "$(ls -d "$HOME"/.gemini/settings.json.agentbar-bak-2* | sort | tail -1)"'
check "a backup you named is yours"    '[ "$(cat "$HOME/.gemini/settings.json.agentbar-bak-mine")" = mine ]'
# A node that moved changes both Codex keys at once. One write, so one backup of the
# file as it was — and the repaired notify line must survive the block rewrite.
fresh_home
mkdir -p "$HOME/.codex"
printf 'model = "o3"\n' > "$HOME/.codex/config.toml"
"$CLI" install-hooks >/dev/null 2>&1
sed -i.tmp "s|\"[^\"]*node\"|\"$HOME/gone/node\"|; s|\\\\\"[^\\\\]*node\\\\\"|\\\\\"$HOME/gone/node\\\\\"|g" "$HOME/.codex/config.toml" && rm -f "$HOME/.codex/config.toml.tmp"
check "codex dead node seeded in both" 'grep -q "^notify = \[\"$HOME/gone/node\"" "$HOME/.codex/config.toml" && grep -q "gone/node.*hook.js" "$HOME/.codex/config.toml"'
AGENTBAR_NOW=1790009999 "$CLI" install-hooks >/dev/null 2>&1
check "codex both keys repaired in one run" '! grep -q "gone/node" "$HOME/.codex/config.toml"'
check "codex one backup per run"       '[ "$(ls "$HOME/.codex" | grep -c agentbar-bak)" = 2 ]'
# Present but not UTF-8, or present but unreadable, is not empty: read as "" it was
# replaced by AgentBar's two keys. Left alone, the way HookInstaller leaves it.
fresh_home
mkdir -p "$HOME/.codex"
printf 'model = "o3"\n# caf\xe9\n' > "$HOME/.codex/config.toml"
CODEX_BYTES="$(od -An -tx1 "$HOME/.codex/config.toml")"
ERR="$("$CLI" install-hooks 2>&1 >/dev/null)"
check "codex non-UTF-8 config untouched" '[ "$CODEX_BYTES" = "$(od -An -tx1 "$HOME/.codex/config.toml")" ] && [ -z "$(ls "$HOME/.codex" | grep agentbar-bak)" ]'
check "codex non-UTF-8 config says so"   'echo "$ERR" | grep -q "is not UTF-8 — left untouched"'
fresh_home
mkdir -p "$HOME/.codex"
printf 'model = "o3"\n' > "$HOME/.codex/config.toml"
chmod 000 "$HOME/.codex/config.toml"
ERR="$("$CLI" install-hooks 2>&1 >/dev/null)"
chmod 644 "$HOME/.codex/config.toml"
if [ "$(id -u)" = 0 ]; then
  echo "skip codex unreadable config (root reads everything)"
else
  check "codex unreadable config untouched" '[ "$(cat "$HOME/.codex/config.toml")" = "model = \"o3\"" ]'
  check "codex unreadable config says so"   'echo "$ERR" | grep -q "could not be read .* left untouched"'
fi

# --- the record, as something you can hand to somebody ---------------------------
fresh_home
printf '%s\n%s\n' \
  '{"ts":1789646400,"agent":"claude","cwd":"/repo","tool":"Bash","shape":"bash:git status","display":"Bash: git status","decision":"allow","via":"app","waited":12}' \
  '{"ts":1789646500,"agent":"codex","cwd":"/repo","tool":"Bash","shape":"bash:rm","display":"=cmd|/bin/sh","decision":"deny","via":"rule","rule":"r-1","waited":0}' \
  > "$HOME/.agentbar/decisions.jsonl"
CSV="$("$CLI" approvals --export --days 9999)"
check "export has a header row"        'echo "$CSV" | head -1 | grep -q "^when,agent,directory"'
check "export is one row per decision" '[ "$(echo "$CSV" | wc -l | tr -d " ")" = 3 ]'
check "export is oldest first"         'echo "$CSV" | sed -n 2p | grep -q claude'
check "export carries the wait"        'echo "$CSV" | sed -n 2p | grep -q "\"12\""'
check "export names the rule"          'echo "$CSV" | sed -n 3p | grep -q "\"r-1\""'
# The export carries commands an agent wanted to run; a spreadsheet must not be
# handed one as a formula to evaluate.
check "export defuses a formula"       'echo "$CSV" | sed -n 3p | grep -q "\"'"'"'=cmd"'
check "export writes a date, not a number" 'echo "$CSV" | sed -n 2p | grep -q "2026-"'

fresh_home
CSV="$("$CLI" approvals --export)"
check "export with nothing is headers" '[ "$(echo "$CSV" | wc -l | tr -d " ")" = 1 ] && echo "$CSV" | grep -q "^when,"'

# --- usage: a reset time nobody could meet ---------------------------------------
# The number comes out of a rollout AgentBar does not write. The app drops one past
# the year 2100 because converting it is a crash there; here it would only print
# "resets Invalid Date", and the two halves answer the same way on purpose.
fresh_home
export CODEX_HOME="$HOME/.codex"
export COPILOT_HOME="$HOME/.copilot-empty"
mkdir -p "$CODEX_HOME/sessions/2026/09/17"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"timestamp":"%s","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","primary":{"used_percent":40.0,"window_minutes":300,"resets_at":1e19},"secondary":null,"credits":null}}}\n' "$STAMP" \
  > "$CODEX_HOME/sessions/2026/09/17/rollout-2026-09-17T10-00-00-abc.jsonl"
OUT="$("$CLI" usage)"
check "usage still reads the window"        'echo "$OUT" | grep -q "60% left"'
check "usage drops an impossible reset"     '! echo "$OUT" | grep -q "resets"'
check "usage never prints Invalid Date"     '! echo "$OUT" | grep -q "Invalid Date"'

# --- the directory a decision was made in comes off the request ------------------
# The hook has carried `cwd` on the request since 1.28.0 precisely so no reader has
# to join back through state.d for it. The app prefers it and falls back to the
# session; this half only ever read the session, so a decision answered after its
# session row was gone landed in the ledger with no directory at all — and the
# directory is what scopes "allowed 23x here" and what a rule matches on. Caught on
# a real machine, by answering a real request with no session row behind it.
fresh_home
printf '{"sessionId":"gone","agent":"claude","toolName":"Bash","display":"Bash: git status","toolInputPretty":"{}","context":{"kind":"bash","command":"git status"},"cwd":"/repo/from-the-request","pid":%s,"hookPid":%s,"ts":%s}' \
  $$ $$ "$(date +%s)" > "$HOME/.agentbar/requests.d/c1.json"
"$CLI" approve >/dev/null
check "the ledger takes cwd off the request" 'grep -q "\"cwd\":\"/repo/from-the-request\"" "$HOME/.agentbar/decisions.jsonl"'

# And the session still wins nothing it should not: a request with no cwd of its
# own falls back to the session's, which is the older behaviour unchanged.
fresh_home
seed_session s9 permission $$ "$HOME/proj"
printf '{"sessionId":"s9","agent":"claude","toolName":"Bash","display":"Bash: git status","toolInputPretty":"{}","context":{"kind":"bash","command":"git status"},"pid":%s,"hookPid":%s,"ts":%s}' \
  $$ $$ "$(date +%s)" > "$HOME/.agentbar/requests.d/c2.json"
"$CLI" approve >/dev/null
check "and falls back to the session's cwd" 'grep -q "\"cwd\":\"$HOME/proj\"" "$HOME/.agentbar/decisions.jsonl"'

# --- a session whose whole cost is cached input still has a weight ---------------
# Every other reader — this file's own Claude one, and both of the app's — keeps a
# weight whose only non-zero number is cache reads. Codex's here dropped it, so the
# same rollout produced a weight in the app and none in the CLI. Nothing is shown
# either way (cache reads are stored, never displayed), which is exactly why it
# could sit in `history.jsonl` unnoticed and disagree with the other half.
fresh_home
export CODEX_HOME="$HOME/.codex"
mkdir -p "$CODEX_HOME/sessions/2026/09/17"
printf '{"timestamp":"2026-09-17T10:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":4000,"cached_input_tokens":4000,"output_tokens":0,"cache_write_input_tokens":0}}}}\n' \
  > "$CODEX_HOME/sessions/2026/09/17/rollout-2026-09-17T10-00-00-cacheonly.jsonl"
printf '{"agent":"codex","state":"tool","started":true,"ts":%s,"pid":%s,"cwd":"/tmp/x","project":"X","sessionId":"codex-cacheonly"}' "$(date +%s)" "$$" \
  > "$HOME/.agentbar/state.d/codex-cacheonly.json"
"$CLI" status >/dev/null 2>&1
rm -f "$HOME/.agentbar/state.d/codex-cacheonly.json"
"$CLI" status >/dev/null 2>&1
check "a cache-only codex weight is kept" 'grep -q "\"cacheRead\":4000" "$HOME/.agentbar/history.jsonl"'
check "and its input is not double-counted" 'grep -q "\"in\":0" "$HOME/.agentbar/history.jsonl"'
unset CODEX_HOME COPILOT_HOME

# --- a quiet Antigravity session decays, here as well as in the app --------------
# Antigravity 2.3.x fires only PostToolUse: there is no terminal event at all, so a
# working session that has gone quiet would animate for ever and never reach the
# history. The app's watchdog turns it into `done` after 90s and marks the row as a
# guess rather than a reported finish. This half had no watchdog, so on Linux the
# same session never ended.
fresh_home
OLD=$(( $(date +%s) - 120 ))
printf '{"agent":"antigravity","state":"tool","label":"x","project":"proj","cwd":"","sessionId":"ag1","pid":%s,"started":true,"ts":%s}' \
  "$$" "$OLD" > "$HOME/.agentbar/state.d/ag1.json"
check "a quiet antigravity row reads as done" '"$CLI" status --json | grep -q "\"state\": *\"done\""'
check "and not as still working"              '! "$CLI" status --json | grep -q "\"state\": *\"tool\""'
"$CLI" status >/dev/null 2>&1
rm -f "$HOME/.agentbar/state.d/ag1.json"
"$CLI" status >/dev/null 2>&1
check "it reaches the history as a guess"     'grep -q "\"decayed\":true" "$HOME/.agentbar/history.jsonl"'

# Ninety seconds is the window, and a session inside it is simply working.
fresh_home
printf '{"agent":"antigravity","state":"tool","label":"x","project":"proj","cwd":"","sessionId":"ag2","pid":%s,"started":true,"ts":%s}' \
  "$$" "$(date +%s)" > "$HOME/.agentbar/state.d/ag2.json"
check "a fresh antigravity row still works"   '"$CLI" status --json | grep -q "\"state\": *\"tool\""'

# And the watchdog is Antigravity's alone: every other agent reports its own ending.
fresh_home
printf '{"agent":"claude","state":"tool","label":"x","project":"proj","cwd":"","sessionId":"cl1","pid":%s,"started":true,"ts":%s}' \
  "$$" "$OLD" > "$HOME/.agentbar/state.d/cl1.json"
check "a quiet claude row is left alone"      '"$CLI" status --json | grep -q "\"state\": *\"tool\""'

# --- report: any agent, one row per call (docs/protocol.md "Bring your own agent")
fresh_home
mkdir -p "$HOME/work/myproj"
RROW="$HOME/.agentbar/state.d/aider-myproj.json"
ABS_CLI="$PWD/$CLI"   # the subshells below run from the project dir
( cd "$HOME/work/myproj" && "$ABS_CLI" report --agent aider --name Aider --state tool --label Editing --pid $$ )
check "report writes the row"                '[ -f "$RROW" ]'
check "report marks it started"              'grep -q "\"started\":true" "$RROW"'
check "report names the agent id"            'grep -q "\"agent\":\"aider\"" "$RROW"'
check "report carries agent_name"            'grep -q "\"agent_name\":\"Aider\"" "$RROW"'
check "report defaults project to the cwd"   'grep -q "\"project\":\"myproj\"" "$RROW"'
check "report stamps the given pid"          'grep -q "\"pid\":$$," "$RROW"'
SA="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).started_at)' "$RROW")"
# Pinned a minute later, so a started_at that was re-stamped would differ.
( cd "$HOME/work/myproj" && AGENTBAR_NOW=$(( $(date +%s) + 60 )) "$ABS_CLI" report --agent aider --state done --recap "Edited 3 files" --pid $$ )
check "a second report merges"               'grep -q "\"state\":\"done\"" "$RROW" && grep -q "\"agent_name\":\"Aider\"" "$RROW"'
check "a second report keeps started_at"     'grep -q "\"started_at\":$SA," "$RROW"'
check "status lists the agent's name"        '"$CLI" status | grep -q AIDER'
check "waybar tooltip uses the name"         '"$CLI" waybar | grep -q "(Aider)"'
( cd "$HOME/work/myproj" && "$ABS_CLI" report --agent aider --state end )
check "report --state end deletes the row"   '[ ! -f "$RROW" ]'

fresh_home
"$CLI" report --agent Aider --state tool --session x >/dev/null 2>&1; RC=$?
check "report refuses a bad agent id"        '[ "$RC" -ne 0 ] && [ -z "$(ls "$HOME/.agentbar/state.d")" ]'
"$CLI" report --agent "a/../b" --state tool --session x >/dev/null 2>&1; RC=$?
check "report refuses a path in the id"      '[ "$RC" -ne 0 ] && [ -z "$(ls "$HOME/.agentbar/state.d")" ]'
"$CLI" report --agent aider --state working --session x >/dev/null 2>&1; RC=$?
check "report refuses an unknown state"      '[ "$RC" -ne 0 ] && [ -z "$(ls "$HOME/.agentbar/state.d")" ]'
# An approval needs a hook waiting on the answer; a one-shot report has none.
"$CLI" report --agent aider --state permission --session x >/dev/null 2>&1; RC=$?
check "report refuses permission"            '[ "$RC" -ne 0 ] && [ -z "$(ls "$HOME/.agentbar/state.d")" ] && [ -z "$(ls "$HOME/.agentbar/requests.d")" ]'
"$CLI" report --agent aider --state tool --session "../../evil" --pid $$
check "report --session is sanitised"        '[ -f "$HOME/.agentbar/state.d/....evil.json" ]'
# 79 ASCII + an emoji: a cut at 80 lands between the surrogate halves, and a lone
# surrogate makes Swift's JSONSerialization reject the whole file.
"$CLI" report --agent aider --state tool --session sur --pid $$ --label "$(printf 'a%.0s' $(seq 79))😀" --name "$(printf 'n%.0s' $(seq 23))😀"
check "report never writes a lone surrogate" '! grep -qiE "\\\\ud[89a-f]" "$HOME/.agentbar/state.d/sur.json" && node -e "JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\"))" "$HOME/.agentbar/state.d/sur.json"'
check "report caps agent_name at 24"         'node -e "process.exit(JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\")).agent_name.length <= 24 ? 0 : 1)" "$HOME/.agentbar/state.d/sur.json"'

# A row with no `started` field at all is a live session (third-party writers
# predate the field); only an explicit false hides one. The app always showed it.
fresh_home
printf '{"agent":"claude","state":"tool","pid":%s,"ts":%s}' $$ "$(date +%s)" > "$HOME/.agentbar/state.d/nostarted.json"
check "a row without started is shown"       '"$CLI" status --json | grep -q "\"id\": \"nostarted\""'

# --- turning an agent off: ~/.agentbar/wire-disabled, unwire, wire -----------------
# The same file the macOS app's WiringPrefs reads and writes. Unwiring is the
# inverse of wiring: every config comes back as it was (as the serializer writes
# it), the person's own entries stay, and AgentBar's own files go — kept first.
WD() { cat "$HOME/.agentbar/wire-disabled" 2>/dev/null; }
pretty() { "$NODE" -e '
const sort = (v) => Array.isArray(v) ? v.map(sort) : v && typeof v === "object"
  ? Object.keys(v).sort().reduce((o, k) => ((o[k] = sort(v[k])), o), {}) : v;
process.stdout.write(JSON.stringify(sort(JSON.parse(process.argv[1])), null, 2) + "\n");' "$1"; }
fresh_home
mkdir -p "$HOME/.claude" "$HOME/.qwen" "$HOME/.gemini/antigravity" "$HOME/.cursor" "$HOME/.codex" \
         "$HOME/.copilot/hooks" "$HOME/.config/opencode"
pretty '{"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"my-stop"}]}]}}' > "$HOME/.claude/settings.json"
pretty '{"model":"q","hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"mine"}]}]}}' > "$HOME/.qwen/settings.json"
pretty '{"theme":"x"}' > "$HOME/.gemini/settings.json"
pretty '{"version":1,"hooks":{"stop":[{"command":"/usr/local/bin/my-cursor-hook"}]}}' > "$HOME/.cursor/hooks.json"
pretty '{"mine":{"Stop":[{"hooks":[{"type":"command","command":"x"}]}]}}' > "$HOME/.gemini/antigravity/hooks.json"
printf 'model = "o3"\n\n[profiles.fast]\nmodel = "o4-mini"\n' > "$HOME/.codex/config.toml"
echo '{"version":1,"hooks":{}}' > "$HOME/.copilot/hooks/mine.json"
for f in .claude/settings.json .qwen/settings.json .gemini/settings.json .cursor/hooks.json .gemini/antigravity/hooks.json .codex/config.toml; do
  cp "$HOME/$f" "$HOME/$f.orig"
done
"$CLI" install-hooks >/dev/null 2>&1
check "unwire: everything wired first"  'grep -q agentbar "$HOME/.claude/settings.json" && grep -q agentbar "$HOME/.qwen/settings.json" && grep -q agentbar "$HOME/.gemini/settings.json" && grep -q agentbar "$HOME/.cursor/hooks.json" && grep -q agentbar "$HOME/.gemini/antigravity/hooks.json" && grep -q agentbar "$HOME/.codex/config.toml" && [ -f "$HOME/.copilot/hooks/agentbar.json" ] && [ -f "$HOME/.config/opencode/plugins/agentbar.js" ]'
AGENTBAR_NOW=1790100000 "$CLI" unwire claude >/dev/null 2>&1
check "unwire claude restores the file"   'cmp -s "$HOME/.claude/settings.json" "$HOME/.claude/settings.json.orig"'
check "unwire claude records the choice"  '[ "$(WD | grep -v "^#")" = claude ]'
check "unwire claude touches nobody else" 'grep -q agentbar "$HOME/.qwen/settings.json" && grep -q agentbar "$HOME/.codex/config.toml"'
AGENTBAR_NOW=1790100000 "$CLI" unwire qwen gemini cursor antigravity codex >/dev/null 2>&1
check "unwire qwen keeps the person's rule"  'cmp -s "$HOME/.qwen/settings.json" "$HOME/.qwen/settings.json.orig"'
check "unwire gemini restores the file"      'cmp -s "$HOME/.gemini/settings.json" "$HOME/.gemini/settings.json.orig"'
check "unwire cursor keeps version + theirs" 'cmp -s "$HOME/.cursor/hooks.json" "$HOME/.cursor/hooks.json.orig"'
check "unwire antigravity drops our key only" 'cmp -s "$HOME/.gemini/antigravity/hooks.json" "$HOME/.gemini/antigravity/hooks.json.orig"'
check "unwire codex restores the toml"      'cmp -s "$HOME/.codex/config.toml" "$HOME/.codex/config.toml.orig"'
check "unwire keeps a backup beside it"     'ls "$HOME/.codex" | grep -q "^config\.toml\.agentbar-bak-" && ls "$HOME/.claude" | grep -q "^settings\.json\.agentbar-bak-"'
OUT="$(AGENTBAR_NOW=1790100000 "$CLI" unwire copilot opencode 2>&1)"
check "unwire copilot deletes our file"     '[ ! -e "$HOME/.copilot/hooks/agentbar.json" ] && [ "$(cat "$HOME/.copilot/hooks/mine.json")" = "{\"version\":1,\"hooks\":{}}" ]'
check "unwire copilot keeps it first"       'ls "$HOME/.copilot/hooks" | grep -q "^agentbar\.json\.agentbar-bak-20" && ! ls "$HOME/.copilot/hooks" | grep "agentbar-bak" | grep -q "\.json$"'
check "unwire opencode deletes the plugin"  '[ ! -e "$HOME/.config/opencode/plugins/agentbar.js" ] && ls "$HOME/.config/opencode/plugins" | grep -q "^agentbar\.js\.agentbar-bak-"'
check "unwire prints the removal diff"      'echo "$OUT" | grep -q "^+++ /dev/null"'
check "wire-disabled lists all, sorted"     '[ "$(WD | grep -v "^#" | tr "\n" " ")" = "antigravity claude codex copilot cursor gemini opencode qwen " ]'
check "wire-disabled has the app header"    '[ "$(WD | head -2)" = "$(printf "# Agents AgentBar leaves unwired, one id per line.\n# Written by AgentBar (Settings > Agents) and the agentbar CLI.")" ]'
check "wire-disabled is 0644"               '[ "$(stat -c %a "$HOME/.agentbar/wire-disabled" 2>/dev/null || stat -f %Lp "$HOME/.agentbar/wire-disabled")" = 644 ]'
# A switched-off agent is not re-wired by the next install-hooks, and a second
# unwire of something already unwired writes nothing at all.
BAKS="$(ls -R "$HOME" | grep -c agentbar-bak)"
"$CLI" install-hooks >/dev/null 2>&1
check "install-hooks leaves disabled alone" 'cmp -s "$HOME/.claude/settings.json" "$HOME/.claude/settings.json.orig" && cmp -s "$HOME/.codex/config.toml" "$HOME/.codex/config.toml.orig" && [ ! -e "$HOME/.copilot/hooks/agentbar.json" ] && [ ! -e "$HOME/.config/opencode/plugins/agentbar.js" ]'
check "unwiring twice writes nothing"       '[ "$(ls -R "$HOME" | grep -c agentbar-bak)" = "$BAKS" ]'
# wire re-enables exactly one agent; saving the empty set removes the file.
"$CLI" wire gemini >/dev/null 2>&1
check "wire re-enables the agent"           'grep -q "/.agentbar/hooks/gemini/" "$HOME/.gemini/settings.json" && ! WD | grep -qx gemini'
check "wire touches nobody else"            'cmp -s "$HOME/.claude/settings.json" "$HOME/.claude/settings.json.orig"'
"$CLI" install-hooks --only claude,gemini,qwen,codex,cursor,antigravity,copilot,opencode >/dev/null 2>&1
check "--only everything removes the file"  '[ ! -e "$HOME/.agentbar/wire-disabled" ] && grep -q agentbar "$HOME/.claude/settings.json"'
"$CLI" install-hooks --skip cursor --skip=qwen >/dev/null 2>&1
check "--skip adds to the file"             '[ "$(WD | grep -v "^#" | tr "\n" " ")" = "cursor qwen " ]'
check "--skip unwires right away"           'cmp -s "$HOME/.cursor/hooks.json" "$HOME/.cursor/hooks.json.orig" && cmp -s "$HOME/.qwen/settings.json" "$HOME/.qwen/settings.json.orig"'
printf 'future-agent\n' >> "$HOME/.agentbar/wire-disabled"
"$CLI" install-hooks --only claude >/dev/null 2>&1
check "--only sets the rest disabled"       '[ "$(WD | grep -v "^#" | tr "\n" " ")" = "antigravity codex copilot cursor future-agent gemini opencode qwen " ]'
check "--only leaves the named one wired"   'grep -q "/.agentbar/hooks/claude/" "$HOME/.claude/settings.json" && ! grep -q agentbar "$HOME/.gemini/settings.json"'
"$CLI" install-hooks --skip bogus >/dev/null 2>&1; RC=$?
check "--skip refuses an unknown agent"     '[ "$RC" -ne 0 ] && ! WD | grep -q bogus'
"$CLI" unwire >/dev/null 2>&1; RC=$?
check "unwire needs an id"                  '[ "$RC" -ne 0 ]'

# Foreign entries in the same event survive, and so does someone else's notify.
fresh_home
mkdir -p "$HOME/.claude" "$HOME/.codex"
printf 'notify = ["/usr/bin/my-notifier"]\nmodel = "o3"\n' > "$HOME/.codex/config.toml"
cp "$HOME/.codex/config.toml" "$HOME/.codex/config.toml.orig"
"$CLI" install-hooks >/dev/null 2>&1
"$NODE" -e '
const fs=require("fs"),f=process.argv[1],j=JSON.parse(fs.readFileSync(f,"utf8"));
j.hooks.Stop.push({hooks:[{type:"command",command:"theirs"}]});
fs.writeFileSync(f, JSON.stringify(j));' "$HOME/.claude/settings.json"
"$CLI" unwire claude codex >/dev/null 2>&1
check "unwire keeps a foreign rule"         'grep -q "\"theirs\"" "$HOME/.claude/settings.json" && ! grep -q agentbar "$HOME/.claude/settings.json" && [ "$("$NODE" -e "console.log(Object.keys(JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\")).hooks).join())" "$HOME/.claude/settings.json")" = Stop ]'
check "unwire codex keeps their notify"     'cmp -s "$HOME/.codex/config.toml" "$HOME/.codex/config.toml.orig"'
# The app's codexUnwiredIsTheInverseOfBothPlans cases, through the CLI's installer.
for ORIG in '' 'model = "o3"\n' 'model = "o3"\n\n' 'a = 1\n[t]\nb = 2\n'; do
  fresh_home
  mkdir -p "$HOME/.codex"
  printf "$ORIG" > "$HOME/.codex/config.toml"; cp "$HOME/.codex/config.toml" "$HOME/codex.orig"
  "$CLI" install-hooks >/dev/null 2>&1
  W=$(cmp -s "$HOME/codex.orig" "$HOME/.codex/config.toml" && echo same || echo changed)
  "$CLI" unwire codex >/dev/null 2>&1
  check "codex wire+unwire round-trips $(printf %q "$ORIG")" '[ "$W" = changed ] && cmp -s "$HOME/codex.orig" "$HOME/.codex/config.toml"'
done
# Our marker in a comment is not a line the notify pattern reads: it stays, and a
# file holding nothing of ours is never rewritten.
fresh_home
mkdir -p "$HOME/.codex" "$HOME/.gemini"
printf '# wired by agentbar: /u/.agentbar/hooks/codex/notify.js\n' > "$HOME/.codex/config.toml"
printf '{"theme":"dark"}' > "$HOME/.gemini/settings.json"
"$CLI" unwire codex gemini >/dev/null 2>&1
check "unwire keeps our marker in a comment" '[ "$(cat "$HOME/.codex/config.toml")" = "# wired by agentbar: /u/.agentbar/hooks/codex/notify.js" ]'
check "unwire never reformats a foreign file" '[ "$(cat "$HOME/.gemini/settings.json")" = "{\"theme\":\"dark\"}" ] && ! ls "$HOME/.gemini" | grep -q agentbar-bak'

# The file's reading rules, the app's WiringPrefsTests: comments, any case, junk
# skipped, an unknown id kept — and kept again when the CLI rewrites the file.
fresh_home
mkdir -p "$HOME/.gemini"
printf '# a comment\ncursor\n\n  Gemini   # trailing comment\n\tqwen\r\n#codex\nnot an id\n../etc\nfuture-agent\n' > "$HOME/.agentbar/wire-disabled"
"$CLI" install-hooks >/dev/null 2>&1
check "wire-disabled parse honours case + comments" '! grep -q agentbar "$HOME/.gemini/settings.json" 2>/dev/null'
"$CLI" wire cursor >/dev/null 2>&1
check "wire-disabled rewrite keeps unknown ids, drops junk" '[ "$(WD | grep -v "^#" | tr "\n" " ")" = "future-agent gemini qwen " ]'

# --- the Claude Code mod: off unless switched on (~/.agentbar/wire-enabled) ---------
# One entry in env.CLAUDE_CODE_PLUGIN_DIRS, beside the person's own. install-hooks
# never puts it there by itself; `wire claude-mod` (or --only naming it) does, and
# unwiring gives the file back byte for byte.
fresh_home
mkdir -p "$HOME/.claude" "$HOME/.agentbar/mods/claude" "$HOME/.local/share/claude/versions/2.1.289"
pretty '{"theme":"dark","env":{"CLAUDE_CODE_PLUGIN_DIRS":"/opt/mine","FOO":"1"}}' > "$HOME/.claude/settings.json"
"$CLI" install-hooks >/dev/null 2>&1
cp "$HOME/.claude/settings.json" "$HOME/claude.hooked"
MODENV() { "$NODE" -e 'const e=(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).env||{});process.stdout.write(String(e.CLAUDE_CODE_PLUGIN_DIRS))' "$HOME/.claude/settings.json"; }
check "install-hooks leaves the mod off"     '[ "$(MODENV)" = /opt/mine ] && [ ! -e "$HOME/.agentbar/wire-enabled" ]'
"$CLI" wire claude-mod >/dev/null 2>&1
check "wire claude-mod adds our dir last"    '[ "$(MODENV)" = "/opt/mine:$HOME/.agentbar/mods/claude" ]'
check "wire claude-mod writes wire-enabled"  '[ "$(grep -v "^#" "$HOME/.agentbar/wire-enabled")" = claude-mod ] && [ ! -e "$HOME/.agentbar/wire-disabled" ]'
check "wire claude-mod keeps a backup"       'ls "$HOME/.claude" | grep -q "^settings\.json\.agentbar-bak-"'
BAKS="$(ls "$HOME/.claude" | grep -c agentbar-bak)"
"$CLI" install-hooks >/dev/null 2>&1
check "install-hooks keeps it once on"       '[ "$(MODENV)" = "/opt/mine:$HOME/.agentbar/mods/claude" ] && [ "$(ls "$HOME/.claude" | grep -c agentbar-bak)" = "$BAKS" ]'
"$CLI" unwire claude-mod >/dev/null 2>&1
check "unwire claude-mod gives the bytes back" 'cmp -s "$HOME/.claude/settings.json" "$HOME/claude.hooked"'
check "unwire claude-mod clears wire-enabled"  '[ ! -e "$HOME/.agentbar/wire-enabled" ] && [ ! -e "$HOME/.agentbar/wire-disabled" ]'
"$CLI" install-hooks --only claude,claude-mod >/dev/null 2>&1
check "--only naming it switches it on"      '[ "$(MODENV)" = "/opt/mine:$HOME/.agentbar/mods/claude" ]'
"$CLI" install-hooks --only claude >/dev/null 2>&1
check "--only leaving it out switches it off" '[ "$(MODENV)" = /opt/mine ] && ! grep -qx claude-mod "$HOME/.agentbar/wire-disabled" 2>/dev/null'
"$CLI" wire claude-mod >/dev/null 2>&1
"$CLI" install-hooks --skip claude-mod >/dev/null 2>&1
check "--skip claude-mod unwires it"         '[ "$(MODENV)" = /opt/mine ] && grep -qx claude-mod "$HOME/.agentbar/wire-disabled"'
# A Claude Code too old to load mods: switched on, still not written.
fresh_home
mkdir -p "$HOME/.claude" "$HOME/.agentbar/mods/claude" "$HOME/.local/share/claude/versions/2.1.200"
printf '{"theme":"dark"}' > "$HOME/.claude/settings.json"
ERR="$("$CLI" wire claude-mod 2>&1 >/dev/null)"
check "an old Claude Code is not wired"      '! grep -q CLAUDE_CODE_PLUGIN_DIRS "$HOME/.claude/settings.json" && echo "$ERR" | grep -q "predates mods"'
# Someone else's value of the wrong type is refused, never repaired.
fresh_home
mkdir -p "$HOME/.claude" "$HOME/.agentbar/mods/claude" "$HOME/.local/share/claude/versions/2.1.289"
printf '{"env":{"CLAUDE_CODE_PLUGIN_DIRS":["/opt/mine"]}}' > "$HOME/.claude/settings.json"
"$CLI" wire claude-mod >/dev/null 2>&1
check "a list where a string belongs is left" '[ "$(cat "$HOME/.claude/settings.json")" = "{\"env\":{\"CLAUDE_CODE_PLUGIN_DIRS\":[\"/opt/mine\"]}}" ]'
# The person's config.json beside the mod survives the copy.
printf '{"band":true}' > "$HOME/.agentbar/mods/config.json"
"$CLI" install-hooks --only claude >/dev/null 2>&1
check "the mod copy keeps mods/config.json"   '[ "$(cat "$HOME/.agentbar/mods/config.json")" = "{\"band\":true}" ]'

# --- AGENTBAR_HOME moves the state root, and only the state root (docs/protocol.md
# "Where state lives"). A HOME with no ~/.agentbar at all, so a single stray write
# into the default shows up as the directory existing.
HOME_SEQ=$((HOME_SEQ + 1))
export HOME="$TESTROOT/home.$$.$HOME_SEQ"
ROOT="$TESTROOT/root.$$.$HOME_SEQ"
mkdir -p "$HOME/work/myproj" "$ROOT/state.d"
( cd "$HOME/work/myproj" && AGENTBAR_HOME="$ROOT//" "$ABS_CLI" report --agent aider --state tool --label Editing --pid $$ )
check "report under AGENTBAR_HOME writes there"       '[ -f "$ROOT/state.d/aider-myproj.json" ]'
check "report under AGENTBAR_HOME leaves ~/.agentbar"  '[ ! -e "$HOME/.agentbar" ]'
printf '{"agent":"claude","state":"tool","label":"x","project":"p","cwd":"","sessionId":"elsewhere","pid":%s,"started":true,"ts":%s}' \
  "$$" "$(date +%s)" > "$ROOT/state.d/elsewhere.json"
OUT="$(AGENTBAR_HOME="$ROOT" "$CLI" status --json)"
check "status under AGENTBAR_HOME reads that root"     'echo "$OUT" | grep -q "\"id\": \"elsewhere\""'
check "status under AGENTBAR_HOME leaves ~/.agentbar"  '[ ! -e "$HOME/.agentbar" ]'
ERR="$( cd "$HOME/work/myproj" && AGENTBAR_HOME=rel/root "$ABS_CLI" report --agent aider --state tool --pid $$ 2>&1 >/dev/null )"; RC=$?
check "a relative AGENTBAR_HOME is refused"            '[ "$RC" -ne 0 ] && [ "$(printf "%s\n" "$ERR" | wc -l | tr -d " ")" = 1 ] && echo "$ERR" | grep -q AGENTBAR_HOME'
check "...and writes nothing anywhere"                 '[ ! -e "$HOME/work/myproj/rel" ] && [ ! -e "$HOME/.agentbar" ]'
AGENTBAR_HOME="~/x" "$CLI" status >/dev/null 2>&1; RC=$?
check "AGENTBAR_HOME gets no ~ expansion"              '[ "$RC" -ne 0 ] && [ ! -e "$HOME/x" ]'
OUT="$(AGENTBAR_HOME= "$CLI" status --json)"
check "an empty AGENTBAR_HOME is the default"          '[ -d "$HOME/.agentbar" ] && ! echo "$OUT" | grep -q elsewhere'
OUT="$(AGENTBAR_HOME="$ROOT" "$CLI" doctor 2>&1)"
check "doctor names the root it checked"               'echo "$OUT" | grep -qF "$ROOT/state.d"'
# install-hooks, wire and unwire write the agents' real configs, which AGENTBAR_HOME
# does not move: refused, and nothing is touched.
mkdir -p "$HOME/.claude"
printf '{"theme":"dark"}' > "$HOME/.claude/settings.json"
for c in install-hooks "wire claude" "unwire claude"; do
  AGENTBAR_HOME="$ROOT" "$CLI" $c >/dev/null 2>&1; RC=$?
  check "$c refused under AGENTBAR_HOME" '[ "$RC" -ne 0 ] && [ "$(cat "$HOME/.claude/settings.json")" = "{\"theme\":\"dark\"}" ] && [ ! -e "$ROOT/hooks" ] && [ ! -e "$ROOT/wire-disabled" ]'
done
AGENTBAR_HOME="$HOME/.agentbar/" "$CLI" install-hooks --only claude >/dev/null 2>&1; RC=$?
check "install-hooks runs when AGENTBAR_HOME is the default spelled out" '[ "$RC" -eq 0 ] && grep -q "/.agentbar/hooks/claude/" "$HOME/.claude/settings.json"'

# --- the fixtures the app's SharedFixtureTests reads too ---------------------------
# Rule matching, the rules file, wire-disabled, unwiring and session rows: every rule
# this CLI implements a second time, held to the same answers as the app. A case is
# added to Tests/Fixtures/*/cases.json, never to one side alone.
FIXTURES_OUT="$("$NODE" --test Scripts/test/shared-fixtures.test.js 2>&1)"; FIXTURES_RC=$?
[ "$FIXTURES_RC" -eq 0 ] || echo "$FIXTURES_OUT"
check "shared fixtures: the CLI answers as the app does" '[ "$FIXTURES_RC" -eq 0 ]'

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
