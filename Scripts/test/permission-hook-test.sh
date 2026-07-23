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

TESTROOT="$(mktemp -d)"
trap 'rm -rf "$TESTROOT"' EXIT

fresh_home() {
  export HOME="$TESTROOT/home.$$.$RANDOM"
  mkdir -p "$HOME/.agentbar/answers.d"
}

# Bounded poll for the request file instead of a fixed sleep; sets $REQ.
wait_req() {
  for _ in $(seq 50); do
    REQ="$(ls "$HOME/.agentbar/requests.d/" 2>/dev/null | head -1)"
    [ -n "$REQ" ] && return 0
    sleep 0.1
  done
  return 1
}

EVENT='{"session_id":"testsess","prompt_id":"p1","tool_name":"Bash","tool_input":{"command":"git push origin main"},"permission_suggestions":[{"type":"rule","rule":"Bash(git push:*)"}]}'

# 1. allow round-trip
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=5 "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
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
wait_req
printf '{"behavior":"deny"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "deny decision on stdout"     'grep -q "\"behavior\":\"deny\"" "$HOME/out.json"'

# 3. always -> allow + rule passthrough (rule matches the received suggestion verbatim)
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=5 "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"always","rule":{"type":"rule","rule":"Bash(git push:*)"}}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "always returns allow"        'grep -q "\"behavior\":\"allow\"" "$HOME/out.json"'
check "always carries the rule"     'grep -q "git push:" "$HOME/out.json"'

# 4. defer -> silent exit (terminal prompt takes over)
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=5 "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
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

# 7. stdin never closes -> the 1s setTimeout bails without blocking on an unknown request
fresh_home
start=$(date +%s)
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=600 "$NODE" "$HOOK" < <(sleep 3) >"$HOME/out.json"
end=$(date +%s)
check "stdin stall: exits fast, no output, no request" \
  '[ $((end-start)) -le 2 ] && [ ! -s "$HOME/out.json" ] && [ -z "$(ls "$HOME/.agentbar/requests.d/" 2>/dev/null)" ]'

# 8. SIGTERM mid-wait -> signal handler still cleans up the request file
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=30 "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
kill -TERM "$hookpid"
wait "$hookpid" 2>/dev/null
check "SIGTERM cleans up request"   '[ ! -e "$HOME/.agentbar/requests.d/$REQ" ]'

# 9. forged rule (doesn't match any received suggestion) -> plain allow, no updatedPermissions
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=5 "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"always","rule":{"type":"rule","rule":"Bash(*)"}}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "forged rule downgrades to plain allow" \
  'grep -q "\"behavior\":\"allow\"" "$HOME/out.json" && ! grep -q "updatedPermissions" "$HOME/out.json"'

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
