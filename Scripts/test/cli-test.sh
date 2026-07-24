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
rm -f "$HOME/.agentbar/answers.d/r1.json"
"$CLI" approve --always >/dev/null
check "approve --always carries rule"  'grep -q "\"behavior\":\"always\"" "$HOME/.agentbar/answers.d/r1.json" && grep -q addRules "$HOME/.agentbar/answers.d/r1.json"'
rm -f "$HOME/.agentbar/answers.d/r1.json"
"$CLI" deny >/dev/null
check "deny writes deny answer"        'grep -q "\"behavior\":\"deny\"" "$HOME/.agentbar/answers.d/r1.json"'
check "dead-hook request pruned"       'seed_request dead 999999; "$CLI" requests >/dev/null; [ ! -f "$HOME/.agentbar/requests.d/dead.json" ]'

# --- waybar: heartbeat + JSON shape
fresh_home
seed_session live permission $$
OUT="$("$CLI" waybar)"
check "waybar emits permission class"  'echo "$OUT" | grep -q "\"class\":\"permission\""'
check "waybar writes heartbeat"        'grep -q "\"ts\":" "$HOME/.agentbar/watcher.json"'

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
mkdir -p "$HOME/.gemini" "$HOME/.cursor" "$HOME/.claude"
echo '{"theme":"dark"}' > "$HOME/.gemini/settings.json"
"$CLI" install-hooks >/dev/null 2>&1
check "gemini wired, existing kept"    'grep -q BeforeAgent "$HOME/.gemini/settings.json" && grep -q theme "$HOME/.gemini/settings.json"'
check "cursor wired with pinned node"  'grep -q afterAgentResponse "$HOME/.cursor/hooks.json" && head -1 "$HOME/.agentbar/hooks/cursor/cursor.js" | grep -qv "env node"'
check "claude wired"                   'grep -q PermissionRequest "$HOME/.claude/settings.json"'
SNAP="$(cat "$HOME/.gemini/settings.json")"
"$CLI" install-hooks >/dev/null 2>&1
check "install-hooks idempotent"       '[ "$SNAP" = "$(cat "$HOME/.gemini/settings.json")" ]'
echo '{broken' > "$HOME/.gemini/settings.json"
"$CLI" install-hooks >/dev/null 2>&1
check "unparseable config untouched"   '[ "$(cat "$HOME/.gemini/settings.json")" = "{broken" ]'
CLAUDE_CONFIG_DIR="$HOME/.claude-custom" "$CLI" install-hooks >/dev/null 2>&1
check "CLAUDE_CONFIG_DIR wired (contained)" 'grep -q PermissionRequest "$HOME/.claude-custom/settings.json"'

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
