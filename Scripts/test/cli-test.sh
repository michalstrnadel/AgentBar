#!/bin/bash
# Tests Scripts/cli/agentbar against a throwaway HOME: status/requests listing,
# approve/deny answers, pruning rules, waybar output, install-hooks safety.
set -uo pipefail
cd "$(dirname "$0")/../.."
CLI="Scripts/cli/agentbar"
NODE="${NODE:-node}"

# install-hooks honors CLAUDE_CONFIG_DIR — a value inherited from the runner's
# shell would make the test wire hooks into the runner's REAL Claude config,
# pointing at this suite's throwaway temp dir (learned the hard way).
unset CLAUDE_CONFIG_DIR AGENTBAR_FORCE_APP AGENTBAR_APPROVAL_TIMEOUT

pass=0; fail=0
check() {
  if eval "$2"; then echo "ok   $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi
}

TESTROOT="$(mktemp -d)"
trap 'rm -rf "$TESTROOT"' EXIT

fresh_home() {
  export HOME="$TESTROOT/home.$$.$RANDOM"
  mkdir -p "$HOME/.agentbar/state.d" "$HOME/.agentbar/requests.d" "$HOME/.agentbar/answers.d"
}

seed_session() { # $1 id, $2 state, $3 pid
  printf '{"agent":"claude","state":"%s","label":"x","project":"proj","cwd":"","sessionId":"%s","pid":%s,"started":true,"ts":%s}' \
    "$2" "$1" "$3" "$(date +%s)" > "$HOME/.agentbar/state.d/$1.json"
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

# --- install-hooks: wiring, idempotence, unparseable config untouched
fresh_home
mkdir -p "$HOME/.gemini" "$HOME/.cursor" "$HOME/.claude" "$HOME/.qwen" "$HOME/.codex" "$HOME/.config/opencode"
echo '{"theme":"dark"}' > "$HOME/.gemini/settings.json"
"$CLI" install-hooks >/dev/null 2>&1
check "gemini wired, existing kept"    'grep -q BeforeAgent "$HOME/.gemini/settings.json" && grep -q theme "$HOME/.gemini/settings.json"'
check "cursor wired with pinned node"  'grep -q afterAgentResponse "$HOME/.cursor/hooks.json" && head -1 "$HOME/.agentbar/hooks/cursor/cursor.js" | grep -qv "env node"'
check "claude wired"                   'grep -q PermissionRequest "$HOME/.claude/settings.json"'
check "qwen wired with its identity"   'grep -q StopFailure "$HOME/.qwen/settings.json" && grep -q AGENTBAR_AGENT "$HOME/.qwen/settings.json"'
check "codex notify wired"             'grep -q "/.agentbar/hooks/codex/" "$HOME/.codex/config.toml"'
check "opencode plugin installed"      '[ -f "$HOME/.config/opencode/plugins/agentbar.js" ]'
SNAP="$(cat "$HOME/.gemini/settings.json")"
QWEN_SNAP="$(cat "$HOME/.qwen/settings.json")"
"$CLI" install-hooks >/dev/null 2>&1
check "install-hooks idempotent"       '[ "$SNAP" = "$(cat "$HOME/.gemini/settings.json")" ] && [ "$QWEN_SNAP" = "$(cat "$HOME/.qwen/settings.json")" ]'
echo '{broken' > "$HOME/.gemini/settings.json"
"$CLI" install-hooks >/dev/null 2>&1
check "unparseable config untouched"   '[ "$(cat "$HOME/.gemini/settings.json")" = "{broken" ]'
CLAUDE_CONFIG_DIR="$HOME/.claude-custom" "$CLI" install-hooks >/dev/null 2>&1
check "CLAUDE_CONFIG_DIR wired (contained)" 'grep -q PermissionRequest "$HOME/.claude-custom/settings.json"'


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

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
