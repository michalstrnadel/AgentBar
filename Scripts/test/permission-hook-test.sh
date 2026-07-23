#!/bin/bash
# Tests Scripts/hooks/claude/permission.js end-to-end against a throwaway HOME.
# Env knobs the hook honors for tests:
#   AGENTBAR_APPROVAL_TIMEOUT  seconds to wait for an answer (default 600)
#   AGENTBAR_FORCE_APP         "1"/"0" overrides the pgrep AgentBar liveness check
set -uo pipefail
cd "$(dirname "$0")/../.."
HOOK="Scripts/hooks/claude/permission.js"
NODE="${NODE:-node}"

pass=0; fail=0
check() {
  if eval "$2"; then echo "ok   $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi
}
fresh_home() {
  export HOME="$(mktemp -d)"
  mkdir -p "$HOME/.agentbar/answers.d"
}

EVENT='{"session_id":"testsess","prompt_id":"p1","tool_name":"Bash","tool_input":{"command":"git push origin main"},"permission_suggestions":[{"type":"rule","rule":"Bash(git push:*)"}]}'

# 1. allow round-trip
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=5 "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
sleep 0.5
REQ="$(ls "$HOME/.agentbar/requests.d/" 2>/dev/null | head -1)"
check "request file written"        '[ -n "$REQ" ]'
check "request carries display"     'grep -q "Bash: git push origin main" "$HOME/.agentbar/requests.d/$REQ"'
check "state flipped to permission" 'grep -q "\"state\":\"permission\"" "$HOME/.agentbar/state.d/testsess.json"'
printf '{"behavior":"allow"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "allow decision on stdout"    'grep -q "\"behavior\":\"allow\"" "$HOME/out.json"'
check "request cleaned up"          '[ ! -e "$HOME/.agentbar/requests.d/$REQ" ]'
check "answer cleaned up"           '[ ! -e "$HOME/.agentbar/answers.d/$REQ" ]'

# 2. deny round-trip
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=5 "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
sleep 0.5
REQ="$(ls "$HOME/.agentbar/requests.d/" | head -1)"
printf '{"behavior":"deny"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "deny decision on stdout"     'grep -q "\"behavior\":\"deny\"" "$HOME/out.json"'

# 3. always -> allow + rule passthrough
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=5 "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
sleep 0.5
REQ="$(ls "$HOME/.agentbar/requests.d/" | head -1)"
printf '{"behavior":"always","rule":{"type":"rule","rule":"Bash(git push:*)"}}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "always returns allow"        'grep -q "\"behavior\":\"allow\"" "$HOME/out.json"'
check "always carries the rule"     'grep -q "git push:" "$HOME/out.json"'

# 4. defer -> silent exit (terminal prompt takes over)
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=5 "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
sleep 0.5
REQ="$(ls "$HOME/.agentbar/requests.d/" | head -1)"
printf '{"behavior":"defer"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "defer produces no output"    '[ ! -s "$HOME/out.json" ]'

# 5. timeout -> silent exit within budget, request removed
fresh_home
start=$(date +%s)
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=2 "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json"
end=$(date +%s)
check "timeout exits silently"      '[ ! -s "$HOME/out.json" ]'
check "timeout within budget"       '[ $((end-start)) -le 4 ]'
check "timeout cleans request"      '[ -z "$(ls "$HOME/.agentbar/requests.d/" 2>/dev/null)" ]'

# 6. app not running -> instant silent no-op
fresh_home
AGENTBAR_FORCE_APP=0 AGENTBAR_APPROVAL_TIMEOUT=600 "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json"
check "no app: no output"           '[ ! -s "$HOME/out.json" ]'
check "no app: no request dir"      '[ ! -d "$HOME/.agentbar/requests.d" ]'

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
