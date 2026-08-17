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

# 9. reordered-keys rule (same structure as the suggestion) -> still accepted; the app's
# JSON round trip may reorder keys, so matching must be structural, not byte-wise
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=5 "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"always","rule":{"rule":"Bash(git push:*)","type":"rule"}}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "reordered rule keys still accepted" 'grep -q "updatedPermissions" "$HOME/out.json"'

# 10. forged rule (doesn't match any received suggestion) -> plain allow, no updatedPermissions
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=5 "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"always","rule":{"type":"rule","rule":"Bash(*)"}}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "forged rule downgrades to plain allow" \
  'grep -q "\"behavior\":\"allow\"" "$HOME/out.json" && ! grep -q "updatedPermissions" "$HOME/out.json"'

# 11. Edit display relativizes file_path against cwd (file name survives truncation)
fresh_home
EDIT_EVENT='{"session_id":"testsess","prompt_id":"p2","tool_name":"Edit","tool_input":{"file_path":"/tmp/proj/Sources/App/File.swift"},"cwd":"/tmp/proj"}'
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=5 "$NODE" "$HOOK" <<<"$EDIT_EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
check "edit display is cwd-relative" 'grep -q "Edit: Sources/App/File.swift" "$HOME/.agentbar/requests.d/$REQ"'
printf '{"behavior":"deny"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"

# 12. AskUserQuestion with no decodable options -> "question" state, immediate
# exit, no request file (nothing to answer remotely; the wizard owns it)
fresh_home
Q_EVENT='{"session_id":"testsess","prompt_id":"p3","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which direction should we take?","header":"Direction","options":[]}]}}'
start=$(date +%s)
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=600 "$NODE" "$HOOK" <<<"$Q_EVENT" >"$HOME/out.json"
end=$(date +%s)
check "question: exits immediately"  '[ $((end-start)) -le 2 ] && [ ! -s "$HOME/out.json" ]'
check "question: no request file"    '[ -z "$(ls "$HOME/.agentbar/requests.d/" 2>/dev/null)" ]'
check "question: state + label"      'grep -q "\"state\":\"question\"" "$HOME/.agentbar/state.d/testsess.json" && grep -q "Which direction" "$HOME/.agentbar/state.d/testsess.json"'

# 12a. AskUserQuestion with options -> request file with question context, blocks,
# answer round-trips into a deny-with-message the model reads as the answer
fresh_home
QO_EVENT='{"session_id":"testsess","prompt_id":"p4","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which color do you prefer?","header":"Color","multiSelect":false,"options":[{"label":"Red","description":"Warm"},{"label":"Blue","description":"Cool"}]}]}}'
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=5 "$NODE" "$HOOK" <<<"$QO_EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
check "question: request written"    '[ -n "$REQ" ]'
check "question: context kind"       'grep -q "\"kind\":\"question\"" "$HOME/.agentbar/requests.d/$REQ"'
check "question: options carried"    'grep -q "\"label\":\"Blue\"" "$HOME/.agentbar/requests.d/$REQ"'
check "question: state flipped"      'grep -q "\"state\":\"question\"" "$HOME/.agentbar/state.d/testsess.json"'
printf '{"behavior":"answer","answers":[["Blue"]]}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "question: deny decision out"  'grep -q "\"behavior\":\"deny\"" "$HOME/out.json"'
check "question: message has answer" 'grep -q "User answered \\\\\"Blue\\\\\"" "$HOME/out.json"'
check "question: do-not-ask-again"   'grep -q "do not ask again" "$HOME/out.json"'
check "question: state -> thinking"  'grep -q "\"state\":\"thinking\"" "$HOME/.agentbar/state.d/testsess.json"'
check "question: request cleaned"    '[ ! -e "$HOME/.agentbar/requests.d/$REQ" ]'

# 12b. forged answer (label the request never offered) -> silent defer, no output
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=5 "$NODE" "$HOOK" <<<"$QO_EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"answer","answers":[["Green"]]}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "forged answer: silent"        '[ ! -s "$HOME/out.json" ]'
check "forged answer: state stays"   'grep -q "\"state\":\"question\"" "$HOME/.agentbar/state.d/testsess.json"'

# 12c. multiSelect + two questions -> enumerated message, one line per question
fresh_home
QM_EVENT='{"session_id":"testsess","prompt_id":"p5","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which layers?","header":"Layers","multiSelect":true,"options":[{"label":"API"},{"label":"UI"},{"label":"DB"}]},{"question":"Ship now?","header":"","multiSelect":false,"options":[{"label":"Yes"},{"label":"No"}]}]}}'
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=5 "$NODE" "$HOOK" <<<"$QM_EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"answer","answers":[["API","DB"],["Yes"]]}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "multi: deny decision out"     'grep -q "\"behavior\":\"deny\"" "$HOME/out.json"'
check "multi: first answer listed"   'grep -q "Layers: API, DB" "$HOME/out.json"'
check "multi: headerless falls back" 'grep -q "Ship now?: Yes" "$HOME/out.json"'

# 12d. single-select answered with two labels -> off-shape, silent defer
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=5 "$NODE" "$HOOK" <<<"$QO_EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"answer","answers":[["Red","Blue"]]}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "overfull answer: silent"      '[ ! -s "$HOME/out.json" ]'

# 12e. defer on a question -> silent exit (wizard already on screen)
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=5 "$NODE" "$HOOK" <<<"$QO_EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"defer"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "question defer: silent"       '[ ! -s "$HOME/out.json" ]'

# 12f. question answered in the terminal wizard (PostToolUse moves the state off
# "question") -> the waiting hook retires its request within ~2s, silently
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=30 "$NODE" "$HOOK" <<<"$QO_EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
start=$(date +%s)
printf '{"session_id":"testsess","tool_name":"AskUserQuestion"}' | "$NODE" Scripts/hooks/claude/update.js post
wait "$hookpid"
end=$(date +%s)
check "wizard answer: hook retires fast" '[ $((end-start)) -le 4 ]'
check "wizard answer: silent"            '[ ! -s "$HOME/out.json" ]'
check "wizard answer: request cleaned"   '[ ! -e "$HOME/.agentbar/requests.d/$REQ" ]'

# 13. update.js prompt event: stamps started_at, one-lines the prompt, keeps model
fresh_home
STATE="$HOME/.agentbar/state.d/testsess.json"
UPDATE="Scripts/hooks/claude/update.js"
printf '{"session_id":"testsess","cwd":"/tmp/proj","prompt":"fix the   auth\\n bug","model":"claude-opus-5"}' | "$NODE" "$UPDATE" prompt
check "update: started_at stamped"   'grep -q "\"started_at\":" "$STATE"'
check "update: prompt one-lined"     'grep -q "\"prompt\":\"fix the auth bug\"" "$STATE"'
check "update: model captured"       'grep -q "\"model\":\"claude-opus-5\"" "$STATE"'

# 14. later events must PRESERVE started_at and carry prompt/model along —
# elapsed time in the frontends depends on started_at never moving
"$NODE" -e 'const fs=require("fs");const f=process.argv[1];const j=JSON.parse(fs.readFileSync(f));j.started_at=1111;fs.writeFileSync(f,JSON.stringify(j))' "$STATE"
printf '{"session_id":"testsess","tool_name":"Bash"}' | "$NODE" "$UPDATE" pre
check "update: started_at preserved" 'grep -q "\"started_at\":1111" "$STATE"'
check "update: prompt survives tool events" 'grep -q "\"prompt\":\"fix the auth bug\"" "$STATE"'
check "update: model survives tool events"  'grep -q "\"model\":\"claude-opus-5\"" "$STATE"'

# 15. system-injected turns and slash commands must not rename the task —
# the harness feeds them through the same prompt event as real input
printf '{"session_id":"testsess","prompt":"<task-notification>noise</task-notification>"}' | "$NODE" "$UPDATE" prompt
check "update: injected turn keeps task"  'grep -q "\"prompt\":\"fix the auth bug\"" "$STATE"'
printf '{"session_id":"testsess","prompt":"/compact"}' | "$NODE" "$UPDATE" prompt
check "update: slash command keeps task"  'grep -q "\"prompt\":\"fix the auth bug\"" "$STATE"'

# 15b. stop event extracts a recap from the transcript tail: skips tool_use-only
# assistant entries and sidechains, strips markdown, one-lines and caps the text
FIXTURE="$HOME/transcript.jsonl"
{
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"do the thing"}}'
  printf '%s\n' '{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"subagent noise, must not surface"}]}}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"## Done\n\n- Fixed the `auth` bug\n- Added **3** regression tests\n\n```js\nconsole.log(1)\n```"}]}}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{}}]}}'
} > "$FIXTURE"
printf '{"session_id":"testsess","cwd":"/tmp/proj","transcript_path":"%s"}' "$FIXTURE" | "$NODE" "$UPDATE" stop
check "recap: extracted from tail"    'grep -q "\"recap\":\"Done Fixed the auth bug Added 3 regression tests\"" "$STATE"'
check "recap: state done"             'grep -q "\"state\":\"done\"" "$STATE"'

# 15c. the next prompt clears the recap (built fresh, never carried forward)
printf '{"session_id":"testsess","prompt":"next task"}' | "$NODE" "$UPDATE" prompt
check "recap: cleared on new prompt"  '! grep -q "\"recap\"" "$STATE"'

# 15d. missing/unreadable transcript: stop still lands, just without a recap
printf '{"session_id":"testsess","cwd":"/tmp/proj","transcript_path":"/nonexistent/x.jsonl"}' | "$NODE" "$UPDATE" stop
check "recap: missing transcript ok"  'grep -q "\"state\":\"done\"" "$STATE" && ! grep -q "\"recap\"" "$STATE"'

# 15e. the walk-back stops at the turn boundary: a turn that ended without any
# assistant text must NOT surface the previous turn's text as its recap
{
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"previous turn result, stale"}]}}'
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"new prompt"}}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{}}]}}'
  printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ran"}]}}'
} > "$FIXTURE"
printf '{"session_id":"testsess","cwd":"/tmp/proj","transcript_path":"%s"}' "$FIXTURE" | "$NODE" "$UPDATE" stop
check "recap: stops at turn boundary" '! grep -q "\"recap\"" "$STATE"'

# 16. lifecycle start seeds started_at (fake `open` first in PATH so the test
# can't launch a real AgentBar out of nowhere)
fresh_home
FAKEBIN="$HOME/fakebin"; mkdir -p "$FAKEBIN"; printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/open"; chmod +x "$FAKEBIN/open"
printf '{"session_id":"lcsess","cwd":"/tmp/proj"}' | PATH="$FAKEBIN:$PATH" "$NODE" Scripts/hooks/claude/lifecycle.js start
check "lifecycle: started_at seeded" 'grep -q "\"started_at\":" "$HOME/.agentbar/state.d/lcsess.json"'
check "lifecycle: still started:false" 'grep -q "\"started\":false" "$HOME/.agentbar/state.d/lcsess.json"'

# 17. the permission hook's own state write must carry the optional task fields
# through — its {...prev} merge is exactly what the protocol relies on
fresh_home
mkdir -p "$HOME/.agentbar/state.d"
printf '{"agent":"claude","state":"tool","label":"x","prompt":"fix the auth bug","started_at":2222,"model":"claude-opus-5","started":true,"ts":1}' > "$HOME/.agentbar/state.d/testsess.json"
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=5 "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
check "permission: task fields survive" \
  'grep -q "\"prompt\":\"fix the auth bug\"" "$HOME/.agentbar/state.d/testsess.json" && grep -q "\"started_at\":2222" "$HOME/.agentbar/state.d/testsess.json" && grep -q "\"model\":\"claude-opus-5\"" "$HOME/.agentbar/state.d/testsess.json"'
printf '{"behavior":"deny"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
