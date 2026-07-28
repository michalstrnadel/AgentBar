#!/bin/bash
# Integration test for CoworkWatcher against the RUNNING AgentBar app: stages a
# synthetic Cowork session under the Claude desktop app's session store and
# asserts the state.d upserts walk thinking -> permission -> thinking ->
# question -> done. The watcher lives inside the app process bound to the real
# HOME, so like the Antigravity test this cannot run in a throwaway HOME — it
# skips (exit 0) when the app isn't up.
#
# Claude.app must be running too: the watcher stamps its pid on every row so a
# quit of the desktop app clears the sessions through SessionStore's normal
# dead-pid prune, and it does nothing at all while the app is closed.
#
# The fixture goes under an account id of its own (`agentbar-test-*`), never the
# user's: the desktop app only ever reads the account/org path it is signed in
# to, so a session parked outside it can't surface in the Cowork UI.
set -uo pipefail

if [ "$(uname)" != "Darwin" ] || ! pgrep -xq AgentBar; then
  echo "skip: AgentBar app not running (this test needs the live watcher)"
  exit 0
fi
if ! pgrep -xq Claude; then
  echo "skip: Claude desktop not running (the watcher is idle without it)"
  exit 0
fi

pass=0; fail=0
check() {
  if eval "$2"; then echo "ok   $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi
}

ROOT="$HOME/Library/Application Support/Claude/local-agent-mode-sessions/agentbar-test-$$/org"
ID="local_agbwtest$$"
DIR="$ROOT/$ID"
A="$DIR/audit.jsonl"
S="$HOME/.agentbar/state.d/$ID.json"
trap 'rm -rf "$HOME/Library/Application Support/Claude/local-agent-mode-sessions/agentbar-test-$$" "$S"' EXIT
mkdir -p "$DIR"
printf '{"sessionId":"%s","title":"Watcher fixture","processName":"test-process"}\n' "$ID" > "$ROOT/$ID.json"

state() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$S" "$1" 2>/dev/null; }

# Bounded poll until the session state equals $1 (seconds in $2).
wait_state() {
  for _ in $(seq $(($2 * 2))); do
    [ "$(state state)" = "$1" ] && return 0
    sleep 0.5
  done
  return 1
}

# 1. a live turn: audit events flowing, no `result` yet
echo '{"type":"assistant","uuid":"a1","session_id":"cli1"}' > "$A"
check "live audit -> thinking"        'wait_state thinking 8'
check "project is the session title"  '[ "$(state project)" = "Watcher fixture" ]'
check "entrypoint is claude-desktop"  '[ "$(state entrypoint)" = "claude-desktop" ]'
check "row is anchored to Claude.app" '[ "$(state pid)" = "$(pgrep -xn Claude)" ]'
check "no terminal is claimed"        '[ -z "$(state term_program)" ]'

# 2. an unanswered permission_request: the app is holding a prompt open
echo '{"type":"system","subtype":"permission_request","uuid":"p1","tool_name":"mcp__cowork__request_cowork_directory","tool_input":{"path":"~/Downloads"}}' >> "$A"
check "open request -> permission"    'wait_state permission 8'
check "label is the bare tool name"   '[ "$(state label)" = "request_cowork_directory" ]'

# 3. answered, and the turn continues
echo '{"type":"system","subtype":"permission_response","uuid":"p1","tool_name":"mcp__cowork__request_cowork_directory","decision":"once","granted":true}' >> "$A"
echo '{"type":"assistant","uuid":"a2","session_id":"cli1"}' >> "$A"
check "answered request -> thinking"  'wait_state thinking 8'

# 4. AskUserQuestion is Claude asking the human, not asking for permission
echo '{"type":"system","subtype":"permission_request","uuid":"q1","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which layout?"}]}}' >> "$A"
check "AskUserQuestion -> question"   'wait_state question 8'
check "label carries the question"    '[ "$(state label)" = "❓ Which layout?" ]'

# 5. a tool result carrying a base64 image is one line, megabytes long — longer
#    than the whole tail window. The session must stay visible (regression: a
#    fixed-size tail held no complete line, `inspect` bailed, the row vanished).
echo '{"type":"system","subtype":"permission_response","uuid":"q1","tool_name":"AskUserQuestion","decision":"once","granted":true}' >> "$A"
python3 -c 'import sys;sys.stdout.write("{\"type\":\"user\",\"uuid\":\"big\",\"message\":\""+"x"*2_000_000+"\"}\n")' >> "$A"
check "oversized line -> still live"  'wait_state thinking 8'

# 6. turn end
echo '{"type":"result","subtype":"success","uuid":"r1","is_error":false}' >> "$A"
check "result event -> done"          'wait_state done 8'

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
