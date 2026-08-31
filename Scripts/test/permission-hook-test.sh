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

# 12g. a pre-question frontend pressing allow at a question -> the verdict is
# swallowed and the hook KEEPS WAITING; a proper answer afterwards still lands
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=10 "$NODE" "$HOOK" <<<"$QO_EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"allow"}' > "$HOME/.agentbar/answers.d/$REQ"
sleep 1
check "legacy verb: swallowed"        '[ ! -e "$HOME/.agentbar/answers.d/$REQ" ]'
check "legacy verb: still waiting"    'kill -0 "$hookpid" 2>/dev/null && [ -e "$HOME/.agentbar/requests.d/$REQ" ]'
printf '{"behavior":"answer","answers":[["Red"]]}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "legacy verb: real answer lands" 'grep -q "User answered \\\\\"Red\\\\\"" "$HOME/out.json"'

# 12h. a stale answer file left under the same name must not be mistaken for
# the user's decision on a fresh request
fresh_home
printf '{"behavior":"allow"}' > "$HOME/.agentbar/answers.d/testsess-p4.json"
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=5 "$NODE" "$HOOK" <<<"$QO_EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
sleep 1
check "stale answer: not consumed"    'kill -0 "$hookpid" 2>/dev/null && [ ! -s "$HOME/out.json" ]'
printf '{"behavior":"answer","answers":[["Blue"]]}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "stale answer: fresh one lands" 'grep -q "User answered \\\\\"Blue\\\\\"" "$HOME/out.json"'

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

# 15f. the Stop payload's last_assistant_message is the PRIMARY recap source —
# the transcript flushes the final text only at session end (verified live on
# Claude Code 2.1.234), so payload-first is what makes recaps exist at all.
# Markdown cleaning applies; a missing/empty transcript doesn't matter.
printf '{"session_id":"testsess","cwd":"/tmp/proj","transcript_path":"/nonexistent/x.jsonl","last_assistant_message":"## Done\\n\\n- Fixed the `late` bug — **all green**"}' | "$NODE" "$UPDATE" stop
check "recap: payload is primary source" 'grep -q "\"recap\":\"Done Fixed the late bug — all green\"" "$STATE"'

# 15g. when the payload carries the message, the transcript tail is not consulted
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"stale transcript text"}]}}' > "$FIXTURE"
printf '{"session_id":"testsess","cwd":"/tmp/proj","transcript_path":"%s","last_assistant_message":"fresh payload text"}' "$FIXTURE" | "$NODE" "$UPDATE" stop
check "recap: payload beats transcript"  'grep -q "\"recap\":\"fresh payload text\"" "$STATE"'

# 16. lifecycle start seeds started_at (fake `open` first in PATH so the test
# can't launch a real AgentBar out of nowhere)
fresh_home
FAKEBIN="$HOME/fakebin"; mkdir -p "$FAKEBIN"
printf '#!/bin/sh\ntouch "$FAKEOPEN_MARK"\nexit 0\n' > "$FAKEBIN/open"; chmod +x "$FAKEBIN/open"
export FAKEOPEN_MARK="$HOME/open-called"
printf '{"session_id":"lcsess","cwd":"/tmp/proj"}' | PATH="$FAKEBIN:$PATH" AGENTBAR_FORCE_APP=0 "$NODE" Scripts/hooks/claude/lifecycle.js start
check "lifecycle: started_at seeded" 'grep -q "\"started_at\":" "$HOME/.agentbar/state.d/lcsess.json"'
check "lifecycle: still started:false" 'grep -q "\"started\":false" "$HOME/.agentbar/state.d/lcsess.json"'

# 16a. app not running -> lifecycle launches it; app running -> it must NOT
# start a second copy (two copies on disk = LaunchServices roulette).
# The launch is a detached spawn, so give the fake `open` a beat to land.
sleep 1
check "lifecycle: launches when down"  '[ "$(uname)" != "Darwin" ] || [ -e "$FAKEOPEN_MARK" ]'
rm -f "$FAKEOPEN_MARK"
printf '{"session_id":"lcsess","cwd":"/tmp/proj"}' | PATH="$FAKEBIN:$PATH" AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/claude/lifecycle.js start
sleep 1
check "lifecycle: no relaunch when up" '[ ! -e "$FAKEOPEN_MARK" ]'
unset FAKEOPEN_MARK

# 16b. SessionStart also fires mid-life (resume, /clear, auto-compact) on the
# SAME session id — it must MERGE, not reset: started_at is load-bearing for
# elapsed time, prompt/model name the task, and a compact mid-turn must not
# hide (started:false) or idle a session that is still working.
fresh_home
LC_STATE="$HOME/.agentbar/state.d/mgsess.json"
printf '{"session_id":"mgsess","cwd":"/tmp/proj","prompt":"fix the auth bug","model":"claude-opus-5"}' | "$NODE" Scripts/hooks/claude/update.js prompt
"$NODE" -e 'const fs=require("fs");const f=process.argv[1];const j=JSON.parse(fs.readFileSync(f));j.started_at=4444;fs.writeFileSync(f,JSON.stringify(j))' "$LC_STATE"
printf '{"session_id":"mgsess","cwd":"/tmp/proj","source":"compact"}' | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/claude/lifecycle.js start
check "compact: started_at preserved" 'grep -q "\"started_at\":4444" "$LC_STATE"'
check "compact: prompt survives"      'grep -q "\"prompt\":\"fix the auth bug\"" "$LC_STATE"'
check "compact: model survives"       'grep -q "\"model\":\"claude-opus-5\"" "$LC_STATE"'
check "compact: stays visible"        'grep -q "\"started\":true" "$LC_STATE"'
check "compact: state preserved"      'grep -q "\"state\":\"thinking\"" "$LC_STATE"'
printf '{"session_id":"mgsess","cwd":"/tmp/proj","source":"resume"}' | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/claude/lifecycle.js start
check "resume: back at the prompt"    'grep -q "\"state\":\"idle\"" "$LC_STATE"'
check "resume: history stays visible" 'grep -q "\"started\":true" "$LC_STATE"'
check "resume: started_at preserved"  'grep -q "\"started_at\":4444" "$LC_STATE"'
printf '{"session_id":"mgsess","cwd":"/tmp/proj","source":"clear"}' | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/claude/lifecycle.js start
check "clear: hidden until activity"  'grep -q "\"started\":false" "$LC_STATE"'

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

# 18. ExitPlanMode -> plan context carried whole; deny = keep-planning message.
# (Verified live on 2.1.234: the plan dialog renders alongside the hook; deny
# dismisses it, a bare denial ends the turn — hence the explicit message.)
fresh_home
PLAN_EVENT='{"session_id":"testsess","prompt_id":"p9","tool_name":"ExitPlanMode","tool_input":{"plan":"## Plan\n1. Edit `auth.ts`\n2. Run tests"}}'
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=5 "$NODE" "$HOOK" <<<"$PLAN_EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
check "plan: request written"       '[ -n "$REQ" ]'
check "plan: context kind"          'grep -q "\"kind\":\"plan\"" "$HOME/.agentbar/requests.d/$REQ"'
check "plan: markdown carried"      'grep -q "Edit \`auth.ts\`" "$HOME/.agentbar/requests.d/$REQ"'
check "plan: display line"          'grep -q "Plan ready for review" "$HOME/.agentbar/requests.d/$REQ"'
check "plan: state is permission"   'grep -q "\"state\":\"permission\"" "$HOME/.agentbar/state.d/testsess.json"'
printf '{"behavior":"deny"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "plan: deny -> deny decision" 'grep -q "\"behavior\":\"deny\"" "$HOME/out.json"'
check "plan: keep-planning message" 'grep -q "keep planning" "$HOME/out.json"'

# 18a. a hook allow cannot approve a plan -> swallowed, hook keeps waiting and
# times out silently instead of pretending it worked
fresh_home
start=$(date +%s)
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=3 "$NODE" "$HOOK" <<<"$PLAN_EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"allow"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"; end=$(date +%s)
check "plan: allow swallowed"       '[ ! -s "$HOME/out.json" ]'
check "plan: waited out the clock"  '[ $((end-start)) -ge 2 ]'
check "plan: request cleaned"       '[ ! -e "$HOME/.agentbar/requests.d/$REQ" ]'

# 18b. dialog answered in the terminal -> state leaves "permission" and the
# hook retires on its own (same elsewhere-retire questions have)
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=30 "$NODE" "$HOOK" <<<"$PLAN_EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
python3 - "$HOME/.agentbar/state.d/testsess.json" <<'PYEOF'
import json, sys
p = sys.argv[1]
s = json.load(open(p))
s["state"] = "tool"
json.dump(s, open(p, "w"))
PYEOF
start=$(date +%s)
wait "$hookpid"; end=$(date +%s)
check "plan: retires when answered elsewhere" '[ $((end-start)) -le 10 ] && [ ! -s "$HOME/out.json" ]'
check "plan: elsewhere-retire cleans request" '[ ! -e "$HOME/.agentbar/requests.d/$REQ" ]'

# 19. Qwen identity: AGENTBAR_AGENT renames the state writer's agent field
fresh_home
printf '{"session_id":"qwsess","cwd":"/tmp/proj","prompt":"add tests"}' \
  | AGENTBAR_AGENT=qwen "$NODE" Scripts/hooks/claude/update.js prompt
check "qwen: agent id in state"     'grep -q "\"agent\":\"qwen\"" "$HOME/.agentbar/state.d/qwsess.json"'
check "qwen: state thinking"        'grep -q "\"state\":\"thinking\"" "$HOME/.agentbar/state.d/qwsess.json"'
printf '{"session_id":"qwsess","tool_name":"run_shell_command"}' \
  | AGENTBAR_AGENT=qwen "$NODE" Scripts/hooks/claude/update.js pre
check "qwen: tool label mapped"     'grep -q "\"label\":\"Running command\"" "$HOME/.agentbar/state.d/qwsess.json"'
# junk in the env var must not fabricate an agent id the app never heard of
printf '{"session_id":"qwsess"}' \
  | AGENTBAR_AGENT='Qw3n!/..' "$NODE" Scripts/hooks/claude/update.js post
check "qwen: junk env sanitized"    'grep -q "\"agent\":\"wn\"" "$HOME/.agentbar/state.d/qwsess.json"'

# 19a. a failed turn is its own state — never a green "done"
fresh_home
printf '{"session_id":"failsess","cwd":"/tmp/proj"}' \
  | AGENTBAR_AGENT=qwen "$NODE" Scripts/hooks/claude/update.js fail
check "fail: error state"           'grep -q "\"state\":\"error\"" "$HOME/.agentbar/state.d/failsess.json"'
check "fail: not done"              '! grep -q "\"state\":\"done\"" "$HOME/.agentbar/state.d/failsess.json"'

# 20. the OpenCode plugin is loadable and maps the bus to protocol states
fresh_home
check "opencode: plugin parses"     '"$NODE" --input-type=module --check < Scripts/hooks/opencode/agentbar.js'
check "opencode: error not done"    'grep -q "state: \"error\"" Scripts/hooks/opencode/agentbar.js'
check "opencode: retires finished"  'grep -q "retireLater" Scripts/hooks/opencode/agentbar.js'

# 21. update.js must never park on a stdin that has no EOF — its whole job runs
# in the stdin handler, so without a self-timeout a stalled pipe froze the tool
# call until Claude Code's 60s hook timeout.
fresh_home
mkfifo "$HOME/stall"
# A writer that holds the pipe open without ever sending EOF.
( exec 3>"$HOME/stall"; sleep 8; exec 3>&- ) &
stallpid=$!
start=$(date +%s)
"$NODE" Scripts/hooks/claude/update.js prompt < "$HOME/stall" >/dev/null 2>&1
end=$(date +%s)
kill "$stallpid" 2>/dev/null; wait "$stallpid" 2>/dev/null
check "update: self-timeout on stalled stdin" '[ $((end-start)) -le 4 ]'

# 22. a lingering hook must not delete (or answer) a SUCCESSOR request that took
# its file name over — request names repeat across the tools of one turn.
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=20 "$NODE" "$HOOK" <<<"$PLAN_EVENT" >"$HOME/out.json" &
lingering=$!
wait_req
# Simulate the next tool of the same turn rewriting the same path.
python3 - "$HOME/.agentbar/requests.d/$REQ" <<'PYEOF'
import json, sys
p = sys.argv[1]
r = json.load(open(p))
r.update({"toolName": "Bash", "display": "Bash: echo successor", "hookPid": 999999,
          "context": {"kind": "bash", "command": "echo successor"}})
json.dump(r, open(p, "w"))
PYEOF
# The answer now belongs to the successor; the lingering hook must not eat it.
printf '{"behavior":"allow"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$lingering"
check "successor request survives"  '[ -e "$HOME/.agentbar/requests.d/$REQ" ]'
check "successor answer survives"   '[ -e "$HOME/.agentbar/answers.d/$REQ" ]'
check "lingering hook stays silent" '[ ! -s "$HOME/out.json" ]'

# 22a. the mirror image: an answer that NAMES a different hook (frontends stamp
# the hookPid from the request they displayed) was aimed at a predecessor of
# this request — swallowed, the wait continues; one naming this hook lands.
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=10 "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"allow","hookPid":999999}' > "$HOME/.agentbar/answers.d/$REQ"
sleep 1
check "foreign hookPid: swallowed, still waiting" \
  '[ ! -e "$HOME/.agentbar/answers.d/$REQ" ] && kill -0 "$hookpid" 2>/dev/null'
printf '{"behavior":"allow","hookPid":%s}' "$hookpid" > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "own hookPid: answer lands"   'grep -q "\"behavior\":\"allow\"" "$HOME/out.json"'

# 23. lifecycle's stale sweep may only remove state files whose agent is gone
fresh_home
mkdir -p "$HOME/.agentbar/state.d"
printf '{"agent":"codex","state":"tool","label":"x","pid":%d,"started":true,"ts":1}' $$ \
  > "$HOME/.agentbar/state.d/livesess.json"
printf '{"agent":"claude","state":"tool","label":"x","pid":999999,"started":true,"ts":1}' \
  > "$HOME/.agentbar/state.d/deadsess.json"
printf '{"session_id":"newsess","cwd":"/tmp/proj"}' \
  | PATH="$TESTROOT/nobin:$PATH" AGENTBAR_FORCE_APP=0 "$NODE" Scripts/hooks/claude/lifecycle.js start
check "sweep keeps live session"    '[ -e "$HOME/.agentbar/state.d/livesess.json" ]'
check "sweep drops dead session"    '[ ! -e "$HOME/.agentbar/state.d/deadsess.json" ]'

# 24. the 4KB toolInputPretty cut must never split a surrogate pair: Swift's
# JSONSerialization rejects the whole file over one lone half, which blocks the
# approval while the hook waits for an answer no frontend can render. The
# payload is sized so the cut lands exactly on an emoji's high surrogate.
fresh_home
"$NODE" -e 'const e={session_id:"testsess",prompt_id:"p9",tool_name:"Bash",tool_input:{command:"a".repeat(3999)+"\u{1F41B}".repeat(100)}};process.stdout.write(JSON.stringify(e))' \
  | AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=5 "$NODE" "$HOOK" >"$HOME/out.json" &
hookpid=$!
wait_req
check "pretty cut: utf16-clean" \
  'python3 -c "import json,sys;json.load(open(sys.argv[1]))[\"toolInputPretty\"].encode(\"utf-8\")" "$HOME/.agentbar/requests.d/$REQ"'
printf '{"behavior":"deny"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
