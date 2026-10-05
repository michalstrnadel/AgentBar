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

# The tests borrow HOME; an inherited CLAUDE_CONFIG_DIR, COPILOT_HOME or
# CODEX_HOME would still point at the runner's real config.
unset CLAUDE_CONFIG_DIR COPILOT_HOME CODEX_HOME AGENTBAR_HOME
# F11 runs the hook's real liveness check, which an inherited override would pin;
# every other case sets it on its own command line.
unset AGENTBAR_FORCE_APP
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
  mkdir -p "$HOME/.agentbar/answers.d"
}

# Bounded poll for the request file instead of a fixed sleep; sets $REQ.
# Seconds the hook waits for an answer in tests that DO answer it. Generous on
# purpose: what those tests assert is rule matching and answer handling, not the
# timeout, and the hook exits the moment the answer lands — so a large value
# costs nothing in the happy path. At 5s a loaded CI runner could spend longer
# getting the answer written than the hook was willing to wait, and the test
# failed as if the rule logic were wrong. The deliberate timeout test keeps its
# own short value.
ANSWER_TIMEOUT=30

wait_req() {
  for _ in $(seq 100); do
    REQ="$(ls "$HOME/.agentbar/requests.d/" 2>/dev/null | head -1)"
    [ -n "$REQ" ] && return 0
    sleep 0.1
  done
  # Say so rather than letting the caller write an answer to a path built from an
  # empty REQ: that cascades into a confusing assertion failure three lines later.
  echo "FAIL wait_req: no request file appeared within 10s" >&2
  fail=$((fail + 1))
  return 1
}

EVENT='{"session_id":"testsess","prompt_id":"p1","tool_name":"Bash","tool_input":{"command":"git push origin main"},"permission_suggestions":[{"type":"rule","rule":"Bash(git push:*)"}]}'

# 1. allow round-trip
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
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
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"deny"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "deny decision on stdout"     'grep -q "\"behavior\":\"deny\"" "$HOME/out.json"'
# The request is gone with the hook, and a denied tool fires no PostToolUse: the
# row must not keep saying "waiting on you" until the agent's next event.
check "deny: row leaves permission"  'grep -q "\"state\":\"thinking\"" "$HOME/.agentbar/state.d/testsess.json"'

# 2b. allow: the row goes back to the tool PreToolUse announced, label and all
fresh_home
mkdir -p "$HOME/.agentbar/state.d"
printf '{"sessionId":"testsess","agent":"claude","state":"tool","label":"Running command","cwd":"/tmp/proj","ts":1}' \
  > "$HOME/.agentbar/state.d/testsess.json"
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"allow"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "allow: row back to the tool"  'grep -q "\"state\":\"tool\"" "$HOME/.agentbar/state.d/testsess.json" && grep -q "\"label\":\"Running command\"" "$HOME/.agentbar/state.d/testsess.json"'
check "allow: other fields kept"     'grep -q "\"cwd\":\"/tmp/proj\"" "$HOME/.agentbar/state.d/testsess.json"'

# 2c. a newer event already moved the row on: the late settle must not clobber it
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"sessionId":"testsess","agent":"claude","state":"done","label":"Finished","ts":2}' \
  > "$HOME/.agentbar/state.d/testsess.json"
printf '{"behavior":"deny"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "deny: newer state not clobbered" 'grep -q "\"state\":\"done\"" "$HOME/.agentbar/state.d/testsess.json"'

# 3. always -> allow + rule passthrough (rule matches the received suggestion verbatim)
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"always","rule":{"type":"rule","rule":"Bash(git push:*)"}}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "always returns allow"        'grep -q "\"behavior\":\"allow\"" "$HOME/out.json"'
check "always carries the rule"     'grep -q "git push:" "$HOME/out.json"'

# 4. defer -> silent exit (terminal prompt takes over)
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
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
check "no mod: no prompt marker"    '[ ! -d "$HOME/.agentbar/mods.d" ]'
# The Claude Code mod's "did a prompt reach the person" marker: written first, app
# running or not, and only where the mod already keeps its folder.
fresh_home
mkdir -p "$HOME/.agentbar/mods.d"
before=$(($(date +%s) * 1000))
AGENTBAR_FORCE_APP=0 AGENTBAR_APPROVAL_TIMEOUT=600 "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json"
check "no app: prompt still marked" '[ "$(cat "$HOME/.agentbar/mods.d/.prompted-testsess")" -ge "$before" ]'
check "marker is all it writes"     '[ "$(ls -A "$HOME/.agentbar/mods.d")" = ".prompted-testsess" ]'

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
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"always","rule":{"rule":"Bash(git push:*)","type":"rule"}}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "reordered rule keys still accepted" 'grep -q "updatedPermissions" "$HOME/out.json"'

# 10. forged rule (doesn't match any received suggestion) -> plain allow, no updatedPermissions
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"always","rule":{"type":"rule","rule":"Bash(*)"}}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "forged rule downgrades to plain allow" \
  'grep -q "\"behavior\":\"allow\"" "$HOME/out.json" && ! grep -q "updatedPermissions" "$HOME/out.json"'

# 11. Edit display relativizes file_path against cwd (file name survives truncation)
fresh_home
EDIT_EVENT='{"session_id":"testsess","prompt_id":"p2","tool_name":"Edit","tool_input":{"file_path":"/tmp/proj/Sources/App/File.swift"},"cwd":"/tmp/proj"}'
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$EDIT_EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
check "edit display is cwd-relative" 'grep -q "Edit: Sources/App/File.swift" "$HOME/.agentbar/requests.d/$REQ"'
# A rule that says "in this repository" cannot be evaluated without knowing which
# one, and joining back through state.d on sessionId to learn it is a lookup the
# hook can spare every reader: it already has the directory in hand.
check "request carries the cwd"      'grep -q "\"cwd\":\"/tmp/proj\"" "$HOME/.agentbar/requests.d/$REQ"'
# The file an edit names, as its own field: toolInputPretty is cut at 4 KB and a
# cut is not JSON, so a large edit's path could not be read back out of it.
check "request carries the file"     'grep -q "\"filePath\":\"/tmp/proj/Sources/App/File.swift\"" "$HOME/.agentbar/requests.d/$REQ"'
printf '{"behavior":"deny"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"

# 11a. A host that sends no cwd leaves the field OUT rather than empty. An empty
# string would compare equal to nothing and be indistinguishable from "/" in a
# prefix test; absent is a state readers already handle.
fresh_home
NOCWD_EVENT='{"session_id":"testsess","prompt_id":"p2b","tool_name":"Bash","tool_input":{"command":"ls"}}'
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$NOCWD_EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
check "no cwd: the field is absent"  '! grep -q "\"cwd\"" "$HOME/.agentbar/requests.d/$REQ"'
check "no file: the field is absent" '! grep -q "\"filePath\"" "$HOME/.agentbar/requests.d/$REQ"'
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
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$QO_EVENT" >"$HOME/out.json" &
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
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$QO_EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"answer","answers":[["Green"]]}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "forged answer: silent"        '[ ! -s "$HOME/out.json" ]'
check "forged answer: state stays"   'grep -q "\"state\":\"question\"" "$HOME/.agentbar/state.d/testsess.json"'

# 12c. multiSelect + two questions -> enumerated message, one line per question
fresh_home
QM_EVENT='{"session_id":"testsess","prompt_id":"p5","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which layers?","header":"Layers","multiSelect":true,"options":[{"label":"API"},{"label":"UI"},{"label":"DB"}]},{"question":"Ship now?","header":"","multiSelect":false,"options":[{"label":"Yes"},{"label":"No"}]}]}}'
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$QM_EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"answer","answers":[["API","DB"],["Yes"]]}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "multi: deny decision out"     'grep -q "\"behavior\":\"deny\"" "$HOME/out.json"'
check "multi: first answer listed"   'grep -q "Layers: API, DB" "$HOME/out.json"'
check "multi: headerless falls back" 'grep -q "Ship now?: Yes" "$HOME/out.json"'

# 12d. single-select answered with two labels -> off-shape, silent defer
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$QO_EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"answer","answers":[["Red","Blue"]]}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "overfull answer: silent"      '[ ! -s "$HOME/out.json" ]'

# 12e. defer on a question -> silent exit (wizard already on screen)
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$QO_EVENT" >"$HOME/out.json" &
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
# the user's decision on a fresh request. This is also what guards the ordering:
# the clear happens BEFORE the request is published, so a frontend answering the
# instant it appears cannot have its answer swept away by this cleanup.
fresh_home
printf '{"behavior":"allow"}' > "$HOME/.agentbar/answers.d/testsess-p4.json"
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$QO_EVENT" >"$HOME/out.json" &
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

# 15h. the activity ring: tool steps accumulate oldest → newest, consecutive
# duplicates collapse, the ring caps at 5, it rides through post/stop — and a
# new prompt starts it clean, same reset rule the recap follows
ACT="$HOME/.agentbar/state.d/actsess.json"
printf '{"session_id":"actsess","prompt":"task"}' | "$NODE" "$UPDATE" prompt
check "activity: none before tools"     '! grep -q "\"activity\"" "$ACT"'
printf '{"session_id":"actsess","tool_name":"Read"}' | "$NODE" "$UPDATE" pre
printf '{"session_id":"actsess","tool_name":"Read"}' | "$NODE" "$UPDATE" pre
printf '{"session_id":"actsess","tool_name":"Grep"}' | "$NODE" "$UPDATE" pre
check "activity: accumulates, deduped"  'grep -q "\"activity\":\[\"Reading\",\"Searching\"\]" "$ACT"'
printf '{"session_id":"actsess","tool_name":"Grep"}' | "$NODE" "$UPDATE" post
check "activity: survives post"         'grep -q "\"activity\":\[\"Reading\",\"Searching\"\]" "$ACT"'
for t in Bash Edit Write WebFetch; do
  printf '{"session_id":"actsess","tool_name":"%s"}' "$t" | "$NODE" "$UPDATE" pre
done
check "activity: ring capped at 5"      'grep -q "\"activity\":\[\"Searching\",\"Running command\",\"Editing\",\"Writing\",\"Browsing web\"\]" "$ACT"'
printf '{"session_id":"actsess","prompt":"next"}' | "$NODE" "$UPDATE" prompt
check "activity: cleared on new prompt" '! grep -q "\"activity\"" "$ACT"'

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

# 16c. PreCompact says "Compacting…", and the SessionStart that ends the
# compaction puts back what the row said before it. A manual /compact after a
# finished turn must land on done again — with its recap — not stay "Compacting…"
# until the next prompt.
fresh_home
LC_STATE="$HOME/.agentbar/state.d/cpsess.json"
printf '{"session_id":"cpsess","cwd":"/tmp/proj","prompt":"ship it"}' | "$NODE" Scripts/hooks/claude/update.js prompt
printf '{"session_id":"cpsess","cwd":"/tmp/proj","last_assistant_message":"Shipped the fix."}' | "$NODE" Scripts/hooks/claude/update.js stop
printf '{"session_id":"cpsess","cwd":"/tmp/proj","trigger":"manual"}' | "$NODE" Scripts/hooks/claude/update.js compact
check "compact: says Compacting…"       'grep -q "\"label\":\"Compacting…\"" "$LC_STATE"'
check "compact: is working"             'grep -q "\"state\":\"thinking\"" "$LC_STATE"'
check "compact: remembers done"         'grep -q "\"resume\":{\"state\":\"done\"" "$LC_STATE"'
check "compact: task survives"          'grep -q "\"prompt\":\"ship it\"" "$LC_STATE"'
# A second PreCompact before the end must not remember "Compacting…".
printf '{"session_id":"cpsess","cwd":"/tmp/proj","trigger":"auto"}' | "$NODE" Scripts/hooks/claude/update.js compact
check "compact twice: still remembers done" 'grep -q "\"resume\":{\"state\":\"done\"" "$LC_STATE"'
printf '{"session_id":"cpsess","cwd":"/tmp/proj","source":"compact"}' | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/claude/lifecycle.js start
check "compacted: back to done"         'grep -q "\"state\":\"done\"" "$LC_STATE"'
check "compacted: label cleared"        'grep -q "\"label\":\"\"" "$LC_STATE"'
check "compacted: recap back"           'grep -q "\"recap\":\"Shipped the fix.\"" "$LC_STATE"'
check "compacted: record dropped"       '! grep -q "\"resume\"" "$LC_STATE"'
check "compacted: still visible"        'grep -q "\"started\":true" "$LC_STATE"'
# Mid-turn (auto-compact while a tool runs): back to what it was doing.
printf '{"session_id":"cpsess","cwd":"/tmp/proj","prompt":"next"}' | "$NODE" Scripts/hooks/claude/update.js prompt
printf '{"session_id":"cpsess","cwd":"/tmp/proj","trigger":"auto"}' | "$NODE" Scripts/hooks/claude/update.js compact
printf '{"session_id":"cpsess","cwd":"/tmp/proj","source":"compact"}' | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/claude/lifecycle.js start
check "auto-compact: back to thinking"  'grep -q "\"state\":\"thinking\"" "$LC_STATE" && grep -q "\"label\":\"Thinking…\"" "$LC_STATE"'
# Any real event after a compaction replaces the record with a fresh row.
printf '{"session_id":"cpsess","cwd":"/tmp/proj","trigger":"auto"}' | "$NODE" Scripts/hooks/claude/update.js compact
printf '{"session_id":"cpsess","cwd":"/tmp/proj","tool_name":"Bash"}' | "$NODE" Scripts/hooks/claude/update.js post
check "event after compact: record gone" '! grep -q "\"resume\"" "$LC_STATE" && grep -q "\"label\":\"Thinking…\"" "$LC_STATE"'

# 17. the permission hook's own state write must carry the optional task fields
# through — its {...prev} merge is exactly what the protocol relies on
fresh_home
mkdir -p "$HOME/.agentbar/state.d"
printf '{"agent":"claude","state":"tool","label":"x","prompt":"fix the auth bug","started_at":2222,"model":"claude-opus-5","started":true,"ts":1}' > "$HOME/.agentbar/state.d/testsess.json"
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
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
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$PLAN_EVENT" >"$HOME/out.json" &
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

# 19b. Copilot's ErrorOccurred carries `recoverable`: an error the CLI intends to
# retry is mid-turn noise, not the end of the turn. Qwen's StopFailure has no such
# field, so the case above must keep behaving exactly as it did.
fresh_home
printf '{"session_id":"recsess","cwd":"/tmp/proj","recoverable":true}' \
  | AGENTBAR_AGENT=copilot "$NODE" Scripts/hooks/claude/update.js fail
check "recoverable: stays working"  'grep -q "\"state\":\"thinking\"" "$HOME/.agentbar/state.d/recsess.json"'
check "recoverable: not error"      '! grep -q "\"state\":\"error\"" "$HOME/.agentbar/state.d/recsess.json"'
printf '{"session_id":"recsess","cwd":"/tmp/proj","recoverable":false}' \
  | AGENTBAR_AGENT=copilot "$NODE" Scripts/hooks/claude/update.js fail
check "unrecoverable: error state"  'grep -q "\"state\":\"error\"" "$HOME/.agentbar/state.d/recsess.json"'
check "copilot: agent id in state"  'grep -q "\"agent\":\"copilot\"" "$HOME/.agentbar/state.d/recsess.json"'
# The PascalCase dialect remaps Copilot's tool ids to Claude's, so TOOL_LABELS hits.
printf '{"session_id":"recsess","tool_name":"Bash"}' \
  | AGENTBAR_AGENT=copilot "$NODE" Scripts/hooks/claude/update.js pre
check "copilot: tool label mapped"  'grep -q "\"label\":\"Running command\"" "$HOME/.agentbar/state.d/recsess.json"'

# 19c. A session that opens with a prompt already in flight is working at once.
# Copilot fires SessionStart and UserPromptSubmit concurrently and SessionStart
# can land second, so a seed that ignored initial_prompt dragged a working row
# back to idle/started:false — which hides it from every frontend.
fresh_home
printf '{"session_id":"racesess","cwd":"/tmp/proj","prompt":"do the thing"}' \
  | AGENTBAR_AGENT=copilot AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/claude/update.js prompt
printf '{"session_id":"racesess","cwd":"/tmp/proj","source":"new","initial_prompt":"do the thing"}' \
  | AGENTBAR_AGENT=copilot AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/claude/lifecycle.js start
check "late seed keeps started"     'grep -q "\"started\":true" "$HOME/.agentbar/state.d/racesess.json"'
check "late seed keeps working"     'grep -q "\"state\":\"thinking\"" "$HOME/.agentbar/state.d/racesess.json"'
# Without initial_prompt it is an ordinary fresh session and still seeds hidden.
fresh_home
printf '{"session_id":"seedsess","cwd":"/tmp/proj","source":"startup"}' \
  | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/claude/lifecycle.js start
check "plain seed stays hidden"     'grep -q "\"started\":false" "$HOME/.agentbar/state.d/seedsess.json"'

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
  | AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" >"$HOME/out.json" &
hookpid=$!
wait_req
check "pretty cut: utf16-clean" \
  'python3 -c "import json,sys;json.load(open(sys.argv[1]))[\"toolInputPretty\"].encode(\"utf-8\")" "$HOME/.agentbar/requests.d/$REQ"'
printf '{"behavior":"deny"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"


# 25. lifecycle end deletes the row — the protocol never writes state "end".
fresh_home
printf '{"session_id":"endsess","cwd":"/tmp/proj"}' | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/claude/lifecycle.js start
check "lifecycle: start seeds the row"   '[ -e "$HOME/.agentbar/state.d/endsess.json" ]'
printf '{"session_id":"endsess"}' | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/claude/lifecycle.js end
check "lifecycle: end removes the row"   '[ ! -e "$HOME/.agentbar/state.d/endsess.json" ]'

# 26. the hookPid guard applies to question answers too: a stale answer aimed at
# a predecessor is swallowed, the wizard stays answerable, the right one lands.
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=10 "$NODE" "$HOOK" <<<"$QO_EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"answer","answers":[["Red"]],"hookPid":999999}' > "$HOME/.agentbar/answers.d/$REQ"
sleep 1
check "question: foreign hookPid swallowed" '[ ! -e "$HOME/.agentbar/answers.d/$REQ" ] && kill -0 "$hookpid" 2>/dev/null && grep -q "\"state\":\"question\"" "$HOME/.agentbar/state.d/testsess.json"'
printf '{"behavior":"answer","answers":[["Blue"]],"hookPid":%s}' "$hookpid" > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "question: own hookPid answer lands"  'grep -q "User answered \\\\\"Blue\\\\\"" "$HOME/out.json"'

# 27. junk answer files must not crash the poll loop or count as decisions
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=6 "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf 'not json at all' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "junk answer: silent defer"        '[ ! -s "$HOME/out.json" ]'
check "junk answer: request cleaned"     '[ ! -e "$HOME/.agentbar/requests.d/$REQ" ]'

# 28. GitHub Copilot CLI's permissionRequest — the same hook, the other dialect.
# This event alone speaks camelCase and carries RAW tool ids, so a handler that
# assumes the snake_case shape every other Copilot event uses reads undefined
# throughout; and Copilot reads the decision bare rather than wrapped in
# hookSpecificOutput.
COPILOT_EVENT='{"hookName":"permissionRequest","sessionId":"copsess","timestamp":1789563619837,"cwd":"/tmp/x","toolName":"bash","toolInput":{"command":"echo hello-agentbar"},"permissionSuggestions":[]}'

fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_AGENT=copilot AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT \
  "$NODE" "$HOOK" <<<"$COPILOT_EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
check "copilot: camelCase payload decoded" 'grep -q "Bash: echo hello-agentbar" "$HOME/.agentbar/requests.d/$REQ"'
# The row must be filed under Copilot, or an approval shows up on a Claude session.
check "copilot: request names the agent"   'grep -q "\"agent\":\"copilot\"" "$HOME/.agentbar/requests.d/$REQ"'
check "copilot: session id from sessionId" '[ -f "$HOME/.agentbar/state.d/copsess.json" ]'
check "copilot: state row is copilot"      'grep -q "\"agent\":\"copilot\"" "$HOME/.agentbar/state.d/copsess.json"'
printf '{"behavior":"allow"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
# Bare {behavior}, NOT Claude's hookSpecificOutput wrapper.
check "copilot: bare allow on stdout"      '[ "$(cat "$HOME/out.json")" = "{\"behavior\":\"allow\"}" ]'

fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_AGENT=copilot AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT \
  "$NODE" "$HOOK" <<<"$COPILOT_EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"deny"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "copilot: bare deny on stdout"       '[ "$(cat "$HOME/out.json")" = "{\"behavior\":\"deny\"}" ]'

# "Always" has nowhere to go: GitHub documents the output contract as
# {behavior, message, interrupt} — no channel for a standing rule at all — so it
# must degrade to a one-shot allow rather than inventing an updatedPermissions
# field Copilot would ignore, or worse, misread.
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_AGENT=copilot AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT \
  "$NODE" "$HOOK" <<<"$COPILOT_EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"always","rule":{"type":"rule","rule":"Bash(echo:*)"}}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "copilot: always is a one-shot allow" '[ "$(cat "$HOME/out.json")" = "{\"behavior\":\"allow\"}" ]'

# Rule 3: the blocking hook must ALWAYS time out silently to the terminal prompt.
# Copilot's own hook timeouts fail open since 1.0.67, so even that path is safe —
# but the hook has to give up first, which is why its timeoutSec is set above this.
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_AGENT=copilot AGENTBAR_APPROVAL_TIMEOUT=2 \
  "$NODE" "$HOOK" <<<"$COPILOT_EVENT" >"$HOME/out.json"
check "copilot: timeout says nothing"      '[ ! -s "$HOME/out.json" ]'

# Nobody able to answer -> straight through, no blocking, no row.
fresh_home
AGENTBAR_FORCE_APP=0 AGENTBAR_AGENT=copilot "$NODE" "$HOOK" <<<"$COPILOT_EVENT" >"$HOME/out.json"
check "copilot: no frontend, no block"     '[ ! -s "$HOME/out.json" ] && [ ! -d "$HOME/.agentbar/requests.d" ]'

# A tool id with no mapping keeps Copilot's own name rather than being renamed into
# a Claude tool whose input shape it may not share — and still says something useful.
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_AGENT=copilot AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" \
  <<<'{"hookName":"permissionRequest","sessionId":"copsess","cwd":"/tmp/x","toolName":"view","toolInput":{"path":"/tmp/x/README.md"}}' \
  >"$HOME/out.json" &
hookpid=$!
wait_req
check "copilot: unmapped tool keeps its id" 'grep -q "\"toolName\":\"view\"" "$HOME/.agentbar/requests.d/$REQ"'
check "copilot: unmapped tool still reads"  'grep -q "view: /tmp/x/README.md" "$HOME/.agentbar/requests.d/$REQ"'
printf '{"behavior":"deny"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"

# And the Claude dialect must be untouched by all of the above: still wrapped.
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"allow"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "claude: still wrapped in hookSpecificOutput" 'grep -q "hookSpecificOutput" "$HOME/out.json"'
check "claude: still files under claude"   'grep -q "\"agent\":\"claude\"" "$HOME/.agentbar/state.d/testsess.json"'

# --- 29. Codex CLI's PermissionRequest — the same hook, the same dialect --------
# Codex copied Claude's hook contract: the same event names, the same snake_case
# payload, the same hookSpecificOutput envelope. What it has no channel for is a
# permission suggestion, so every "Always" has to degrade to a one-shot allow —
# and its rows are named `codex-<id>`, because its notify bridge already named
# them that and the token weight is found by stripping that prefix back off.
CODEX_EVENT='{"hook_event_name":"PermissionRequest","session_id":"cdx1","turn_id":"trn1","cwd":"/repo","tool_name":"Bash","tool_input":{"command":"git push origin main"},"model":"gpt-6","permission_mode":"default","transcript_path":null}'
CODEX_ENV=(AGENTBAR_AGENT=codex AGENTBAR_ID_PREFIX=codex-)

fresh_home
env "${CODEX_ENV[@]}" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$CODEX_EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
check "codex: request is prefixed"     '[ "$REQ" = "codex-cdx1-trn1.json" ]'
check "codex: row is prefixed too"     '[ -f "$HOME/.agentbar/state.d/codex-cdx1.json" ]'
check "codex: filed under codex"       'grep -q "\"agent\":\"codex\"" "$HOME/.agentbar/requests.d/$REQ"'
check "codex: carries the command"     'grep -q "Bash: git push origin main" "$HOME/.agentbar/requests.d/$REQ"'
check "codex: carries its cwd"         'grep -q "\"cwd\":\"/repo\"" "$HOME/.agentbar/requests.d/$REQ"'
# No suggestion channel upstream, so the frontend must not offer an Always.
check "codex: no rule suggestion"      'grep -q "\"ruleSuggestion\":null" "$HOME/.agentbar/requests.d/$REQ"'
printf '{"behavior":"allow"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "codex: allow in claude envelope" 'grep -q "\"hookEventName\":\"PermissionRequest\"" "$HOME/out.json" && grep -q "\"behavior\":\"allow\"" "$HOME/out.json"'
check "codex: request cleaned up"      '[ ! -e "$HOME/.agentbar/requests.d/$REQ" ]'

fresh_home
env "${CODEX_ENV[@]}" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$CODEX_EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"deny"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "codex: deny answered"           'grep -q "\"behavior\":\"deny\"" "$HOME/out.json"'

# "Always" with nothing to pin it to is a one-shot allow, never an invented rule.
fresh_home
env "${CODEX_ENV[@]}" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$CODEX_EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"always","rule":{"type":"rule","rule":"Bash(git push:*)"}}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "codex: always degrades to allow" 'grep -q "\"behavior\":\"allow\"" "$HOME/out.json" && ! grep -q "updatedPermissions" "$HOME/out.json"'

# Every failure path is the same one: say nothing, and Codex asks at the terminal.
fresh_home
start=$(date +%s)
env "${CODEX_ENV[@]}" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=2 "$NODE" "$HOOK" <<<"$CODEX_EVENT" >"$HOME/out.json"
end=$(date +%s)
check "codex: timeout says nothing"    '[ ! -s "$HOME/out.json" ]'
check "codex: timeout within budget"   '[ $((end-start)) -le 4 ]'
check "codex: timeout cleans request"  '[ -z "$(ls "$HOME/.agentbar/requests.d/" 2>/dev/null)" ]'

fresh_home
env "${CODEX_ENV[@]}" AGENTBAR_FORCE_APP=0 "$NODE" "$HOOK" <<<"$CODEX_EVENT" >"$HOME/out.json"
check "codex: no frontend, no output"  '[ ! -s "$HOME/out.json" ]'
check "codex: no frontend, no request" '[ -z "$(ls "$HOME/.agentbar/requests.d/" 2>/dev/null)" ]'

# The prefix is opt-in: every other agent's rows keep the names they always had.
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
check "claude: name still unprefixed"  '[ "$REQ" = "testsess-p1.json" ]'
check "claude: row still unprefixed"   '[ -f "$HOME/.agentbar/state.d/testsess.json" ]'
printf '{"behavior":"allow"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "claude: still wrapped as before" 'grep -q "hookSpecificOutput" "$HOME/out.json"'

# --- the fall-through contract, clause by clause ---------------------------------
# SECURITY.md publishes these as F1..F18: every way this hook can fail must write
# nothing to stdout, because writing nothing is what sends the question back to the
# agent's own terminal. Several are asserted elsewhere in this file already; they
# are gathered here under their numbers so that a clause nobody checks is visible
# as a gap rather than hidden in a scenario. F15-F18 are the rules engine's, in
# RuleEngineTests and RulesStoreTests.
contract() { # $1 clause, $2 condition
  check "$1 falls through" "$2"
}

fresh_home
AGENTBAR_FORCE_APP=0 "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json"
contract "F1 no frontend"          '[ ! -s "$HOME/out.json" ]'

fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=30 "$NODE" "$HOOK" >"$HOME/out.json" < <(sleep 3)
contract "F2 stdin never closes"   '[ ! -s "$HOME/out.json" ]'

fresh_home
AGENTBAR_FORCE_APP=1 "$NODE" "$HOOK" </dev/null >"$HOME/out.json"
contract "F3 empty stdin"          '[ ! -s "$HOME/out.json" ]'

fresh_home
AGENTBAR_FORCE_APP=1 "$NODE" "$HOOK" <<<'not json at all' >"$HOME/out.json"
contract "F4 stdin is not JSON"    '[ ! -s "$HOME/out.json" ]'

fresh_home
AGENTBAR_FORCE_APP=1 "$NODE" "$HOOK" <<<'[1,2,3]' >"$HOME/out.json"
contract "F5 payload is an array"  '[ ! -s "$HOME/out.json" ]'

# F6: anything that throws. ~/.agentbar as a FILE makes the very first mkdir fail,
# which is the same catch that guards a poll tick.
fresh_home
rmdir "$HOME/.agentbar/answers.d" "$HOME/.agentbar" 2>/dev/null
printf 'not a directory' > "$HOME/.agentbar"
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=5 "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" 2>/dev/null
contract "F6 setup throws"         '[ ! -s "$HOME/out.json" ]'

fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf 'junk not json' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
contract "F7 junk answer"          '[ ! -s "$HOME/out.json" ]'

fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"defer"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
contract "F8 defer"                '[ ! -s "$HOME/out.json" ]'

fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"allow","hookPid":999999}' > "$HOME/.agentbar/answers.d/$REQ"
sleep 1
contract "F9 another hook's answer" 'kill -0 "$hookpid" 2>/dev/null && [ ! -s "$HOME/out.json" ]'
printf '{"behavior":"allow"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"

fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
python3 - "$HOME/.agentbar/requests.d/$REQ" <<'PY'
import json, sys
f = sys.argv[1]
d = json.load(open(f))
d["hookPid"] = 999999          # a successor claimed it
json.dump(d, open(f, "w"))
PY
printf '{"behavior":"allow"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
contract "F10 request is not ours" '[ ! -s "$HOME/out.json" ]'

# F11: the frontend goes away mid-wait. Not under AGENTBAR_FORCE_APP — that pins
# "somebody can answer" to true and the hook would only ever fall through by its
# timeout. The real liveness check runs instead: a pgrep that never finds the app
# (so a copy of AgentBar running on this machine cannot answer for the test) and a
# CLI heartbeat that is fresh when the hook starts and gone halfway through. The
# hook must notice on its ~2s sweep, well inside the 30s it would otherwise wait.
fresh_home
mkdir -p "$TESTROOT/nopgrep"
printf '#!/bin/sh\nexit 1\n' > "$TESTROOT/nopgrep/pgrep"; chmod +x "$TESTROOT/nopgrep/pgrep"
printf '{"ts":%s}' "$(date +%s)" > "$HOME/.agentbar/watcher.json"
PATH="$TESTROOT/nopgrep:$PATH" AGENTBAR_APPROVAL_TIMEOUT=30 "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
sleep 2.5
check "F11 waits while the heartbeat is fresh" 'kill -0 "$hookpid" 2>/dev/null'
rm -f "$HOME/.agentbar/watcher.json"
start=$(date +%s)
wait "$hookpid" 2>/dev/null || true
end=$(date +%s)
contract "F11 frontend quit"       '[ ! -s "$HOME/out.json" ]'
check "F11 notices within the sweep"  '[ $((end-start)) -le 5 ]'
check "F11 takes its request with it" '[ ! -e "$HOME/.agentbar/requests.d/$REQ" ]'

# The same quit, as a heartbeat that went stale rather than one that was removed:
# a CLI killed with SIGKILL leaves its last watcher.json behind.
fresh_home
printf '{"ts":%s}' "$(date +%s)" > "$HOME/.agentbar/watcher.json"
PATH="$TESTROOT/nopgrep:$PATH" AGENTBAR_APPROVAL_TIMEOUT=30 "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"ts":%s}' "$(( $(date +%s) - 120 ))" > "$HOME/.agentbar/watcher.json"
start=$(date +%s)
wait "$hookpid" 2>/dev/null || true
end=$(date +%s)
contract "F11 stale heartbeat"     '[ ! -s "$HOME/out.json" ]'
check "F11 stale: notices within the sweep" '[ $((end-start)) -le 5 ]'

fresh_home
start=$(date +%s)
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=2 "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json"
end=$(date +%s)
contract "F12 timeout"             '[ ! -s "$HOME/out.json" ]'
check "F12 gives up on time"       '[ $((end-start)) -le 4 ]'

fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
kill -TERM "$hookpid"
wait "$hookpid" 2>/dev/null
contract "F13 SIGTERM"             '[ ! -s "$HOME/out.json" ]'
check "F13 takes its request with it" '[ ! -e "$HOME/.agentbar/requests.d/$REQ" ]'

fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$QO_EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"answer","answers":[["NotAnOption"]]}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
contract "F14 an answer nobody offered" '[ ! -s "$HOME/out.json" ]'

# --- 31. A row's id and the name of the file it lives in are the same thing ----
# The app takes a session's id from the state file's NAME; the Linux CLI matches a
# request against the `sessionId` written INSIDE it. This hook wrote the raw id
# into a row whose file name carried the prefix, so for any agent that has one the
# two disagreed — invisible while every prefix was empty, and a session that reads
# as two the moment one is not. Every other writer of this row already used the
# prefixed form.
fresh_home
env "${CODEX_ENV[@]}" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$CODEX_EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
check "codex: the row names itself"    'grep -q "\"sessionId\":\"codex-cdx1\"" "$HOME/.agentbar/state.d/codex-cdx1.json"'
check "codex: and the request agrees"  'grep -q "\"sessionId\":\"codex-cdx1\"" "$HOME/.agentbar/requests.d/$REQ"'
printf '{"behavior":"allow"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"

# An agent with no prefix is byte-unchanged: the id is the id.
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
check "claude: the row still names itself" 'grep -q "\"sessionId\":\"testsess\"" "$HOME/.agentbar/state.d/testsess.json"'
printf '{"behavior":"allow"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"

# --- 32. Payloads nobody sane would send ---------------------------------------
# The blocking hook reads whatever its host hands it. Every case below must end
# the same way: exit 0, nothing on stdout, and nothing written outside
# ~/.agentbar. Writing nothing is the contract; crashing is not a way of writing
# nothing, because a host that treats a crash as a refusal (agy does) would turn
# a malformed payload into a denial nobody made.
hostile() {   # hostile <name> <json>
  fresh_home
  printf 'not pwned\n' > "$TESTROOT/canary"
  local code=0
  AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=1 "$NODE" "$HOOK" \
    <<<"$2" >"$HOME/out.json" 2>"$HOME/err.txt" || code=$?
  check "hostile: $1 exits 0"        "[ $code -eq 0 ]"
  check "hostile: $1 says nothing"   '[ ! -s "$HOME/out.json" ]'
  # Everything it wrote is under ~/.agentbar. `safeId` drops the separators, and
  # this is the check that says so about the result rather than about the regex.
  check "hostile: $1 stays put" \
    '[ "$(cat "$TESTROOT/canary")" = "not pwned" ] && [ ! -e /tmp/pwned ] &&
     [ -z "$(find "$HOME" -type f -not -path "$HOME/.agentbar/*" -not -name out.json -not -name err.txt)" ]'
}

BIG=$("$NODE" -e 'process.stdout.write("A".repeat(300000))')
hostile "a command longer than any screen" \
  "{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"h1\",\"prompt_id\":\"p1\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$BIG\"}}"

DEEP=$("$NODE" -e 'let s="{\"a\":".repeat(2000)+"1"+"}".repeat(2000);process.stdout.write(s)')
hostile "a tool input nested 2000 deep" \
  "{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"h2\",\"prompt_id\":\"p2\",\"tool_name\":\"Bash\",\"tool_input\":$DEEP}"

# A session id that looks like a path. `safeId` drops the separators, which is
# what stops it from being one — the dots survive and must not be enough.
hostile "a session id shaped like a path" \
  '{"hook_event_name":"PermissionRequest","session_id":"../../../../tmp/pwned","prompt_id":"p3","tool_name":"Bash","tool_input":{"command":"echo hi"}}'

# A lone high surrogate: JSON.stringify escapes it happily and Swift refuses the
# whole file, which would hide the session from every frontend.
hostile "a lone surrogate in the command" \
  '{"hook_event_name":"PermissionRequest","session_id":"h4","prompt_id":"p4","tool_name":"Bash","tool_input":{"command":"echo \ud800"}}'

hostile "a tool input that is an array" \
  '{"hook_event_name":"PermissionRequest","session_id":"h5","prompt_id":"p5","tool_name":"Bash","tool_input":[1,2,3]}'

hostile "a tool name that is a number" \
  '{"hook_event_name":"PermissionRequest","session_id":"h6","prompt_id":"p6","tool_name":7,"tool_input":{"command":"echo hi"}}'

hostile "every field null" \
  '{"hook_event_name":"PermissionRequest","session_id":null,"prompt_id":null,"tool_name":null,"tool_input":null,"cwd":null}'

# The state row is what the app reads; after all of that it must still parse.
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=1 "$NODE" "$HOOK" \
  <<<'{"hook_event_name":"PermissionRequest","session_id":"h7","prompt_id":"p7","tool_name":"Bash","tool_input":{"command":"echo \ud800 done"}}' >/dev/null 2>&1
check "hostile: the row it leaves still parses" \
  '"$NODE" -e "JSON.parse(require(\"fs\").readFileSync(process.env.HOME + \"/.agentbar/state.d/h7.json\", \"utf8\"))"'

# --- 33. The quiet hooks, handed the same nonsense --------------------------------
# update.js and lifecycle.js never block anybody, so their failure is silent: a row
# that does not appear, or — worse — a state file Swift refuses to decode, which
# hides the session from every frontend until the next clean write. A lone high
# surrogate does exactly that: JSON.stringify escapes one happily and
# JSONSerialization rejects the whole file, which is why sliceSafe exists.
LIFECYCLE="Scripts/hooks/claude/lifecycle.js"
# A state file nothing can read is the failure being hunted, so the check is the
# decoded string, not the bytes: the file is valid UTF-8 either way.
# Every string in a written file must survive a UTF-8 encode: python refuses a lone
# surrogate, which is the same refusal Swift's JSONSerialization makes — and an
# unreadable file is the failure being hunted. Same idiom as the request check
# further up, and as `utf16_clean` in the bridge suite.
utf8_clean() {
  python3 -c '
import json, sys, os
def walk(v):
    if isinstance(v, str): v.encode("utf-8")
    elif isinstance(v, dict):
        for x in v.values(): walk(x)
    elif isinstance(v, list):
        for x in v: walk(x)
d = sys.argv[1]
for name in os.listdir(d):
    with open(os.path.join(d, name)) as fh: walk(json.load(fh))
' "$1"
}
readable='utf8_clean "$HOME/.agentbar/state.d"'

quiet() {   # quiet <name> <script> <verb> <json>
  fresh_home
  local code=0
  printf '%s' "$4" | "$NODE" "$2" "$3" >/dev/null 2>&1 || code=$?
  check "quiet: $1 exits 0"      "[ $code -eq 0 ]"
  check "quiet: $1 stays readable" "$readable"
}

BIGP=$("$NODE" -e 'process.stdout.write("B".repeat(200000))')
quiet "a prompt longer than a book" "$UPDATE" prompt \
  "{\"session_id\":\"q1\",\"prompt\":\"$BIGP\"}"
quiet "a lone surrogate in the prompt" "$UPDATE" prompt \
  '{"session_id":"q2","prompt":"fix \ud800 this"}'
quiet "a lone surrogate in the label" "$UPDATE" pre \
  '{"session_id":"q3","tool_name":"Bash","tool_input":{"command":"echo \ud800"}}'
quiet "a tool input that is an array" "$UPDATE" pre \
  '{"session_id":"q4","tool_name":"Bash","tool_input":[1,2,3]}'
quiet "every field null" "$UPDATE" post \
  '{"session_id":null,"tool_name":null,"tool_input":null,"cwd":null}'
quiet "a session id shaped like a path" "$LIFECYCLE" start \
  '{"session_id":"../../../../tmp/pwned","cwd":"/tmp"}'
quiet "nothing at all on stdin" "$LIFECYCLE" start ''

# And a malformed event must not cost a row that was already there: losing the
# session is the same outcome as never writing it, arrived at more expensively.
fresh_home
printf '{"session_id":"keepme","cwd":"/tmp/proj","prompt":"real work"}' | "$NODE" "$UPDATE" prompt
printf 'not json at all' | "$NODE" "$UPDATE" pre >/dev/null 2>&1
check "quiet: junk leaves the row alone" 'grep -q "\"prompt\":\"real work\"" "$HOME/.agentbar/state.d/keepme.json"'

# The request file is the worse half of the same failure: unreadable, no card ever
# appears and the hook waits out its whole ten minutes for an answer nobody can give.
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" \
  <<<'{"hook_event_name":"PermissionRequest","session_id":"sg1","prompt_id":"p1","tool_name":"Bash","tool_input":{"command":"echo \ud800 hi"}}' >"$HOME/out.json" &
hookpid=$!
wait_req
check "a request with a lone surrogate is readable" \
  'utf8_clean "$HOME/.agentbar/requests.d"'
check "and it still carries the command" 'grep -q "echo" "$HOME/.agentbar/requests.d/$REQ"'
printf '{"behavior":"allow"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"

# Deny with a note: the one channel that steers rather than stops. The note goes
# out as the deny message, flattened to one line and capped; a note that isn't a
# string — or is only whitespace — leaves the bare deny exactly as it always was.
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"deny","message":"use pnpm here,\\nnot npm"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "note: still a deny"              'grep -q "\"behavior\":\"deny\"" "$HOME/out.json"'
check "note: carried as the message"    'grep -q "said: \\\\\"use pnpm here, not npm\\\\\"" "$HOME/out.json"'
check "note: tells it not to retry"     'grep -q "Do not retry" "$HOME/out.json"'

fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"deny","message":"   "}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "note: blank note = bare deny"    '! grep -q "message" "$HOME/out.json"'

fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"deny","message":{"x":1}}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "note: non-string note = bare deny" '! grep -q "message" "$HOME/out.json"'

fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
LONG="$(printf 'x%.0s' $(seq 900))"
printf '{"behavior":"deny","message":"%s"}' "$LONG" > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
# The ellipsis has to be there AND the run of x before it has to be short: either
# alone passes with no cap at all (no "…" left grep empty, and empty counted as 0).
# NOTE_MAX is 500 with the ellipsis, so 499 x then "…".
NOTE_RUN="$(grep -o "x*…" "$HOME/out.json" | head -1)"
# Counted as x rather than as characters: "…" is one character or three bytes
# depending on the runner's locale.
check "note: capped at 500"             '[ -n "$NOTE_RUN" ] && [ "$(printf %s "$NOTE_RUN" | tr -cd x | wc -c | tr -d " ")" -eq 499 ]'

# A note cut mid-emoji by some frontend: the half surrogate never reaches the host.
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"deny","message":"stop \\ud83d here"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "note: a lone surrogate is dropped" '! grep -qi "ud83d" "$HOME/out.json" && grep -q "stop here" "$HOME/out.json"'

# A plan sent back with feedback keeps planning AND carries what to change.
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$PLAN_EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"deny","message":"split step 2 into two commits"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "plan note: keeps planning"       'grep -q "keep planning" "$HOME/out.json"'
check "plan note: feedback carried"     'grep -q "split step 2 into two commits" "$HOME/out.json"'

# Copilot's contract is {behavior, message, interrupt}: the note rides bare.
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_AGENT=copilot AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT \
  "$NODE" "$HOOK" <<<"$COPILOT_EVENT" >"$HOME/out.json" &
hookpid=$!
wait_req
printf '{"behavior":"deny","message":"not on main"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "copilot note: bare deny + message" 'grep -q "^{\"behavior\":\"deny\",\"message\":\".*not on main" "$HOME/out.json"'

# AGENTBAR_HOME (docs/protocol.md "Where state lives"): the request, the answer and
# the row all live under the root it names, and ~/.agentbar is never created. The
# Claude status hooks follow the same root.
HOME_SEQ=$((HOME_SEQ + 1))
export HOME="$TESTROOT/home.$$.$HOME_SEQ"; mkdir -p "$HOME"
ROOT="$TESTROOT/root.$$.$HOME_SEQ"
AGENTBAR_HOME="$ROOT/" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
REQ=""
for _ in $(seq 100); do REQ="$(ls "$ROOT/requests.d/" 2>/dev/null | head -1)"; [ -n "$REQ" ] && break; sleep 0.1; done
check "AGENTBAR_HOME: request written under the root" '[ -n "$REQ" ]'
[ -n "$REQ" ] && printf '{"behavior":"allow"}' > "$ROOT/answers.d/$REQ"
wait "$hookpid"
check "AGENTBAR_HOME: answer read from the root"      'grep -q "\"behavior\":\"allow\"" "$HOME/out.json"'
check "AGENTBAR_HOME: row under the root"             '[ -f "$ROOT/state.d/testsess.json" ]'
printf '{"session_id":"ah-life","cwd":"/tmp/proj"}' | AGENTBAR_HOME="$ROOT" AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/claude/lifecycle.js start
printf '{"session_id":"ah-upd","cwd":"/tmp/proj","prompt":"x"}' | AGENTBAR_HOME="$ROOT" AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/claude/update.js prompt
check "AGENTBAR_HOME: lifecycle.js writes the root"   '[ -f "$ROOT/state.d/ah-life.json" ]'
check "AGENTBAR_HOME: update.js writes the root"      '[ -f "$ROOT/state.d/ah-upd.json" ]'
check "AGENTBAR_HOME: nothing under ~/.agentbar"      '[ ! -e "$HOME/.agentbar" ]'
# A relative value is ignored rather than failing the host: default root, exit 0.
printf '{"session_id":"ah-rel","cwd":"/tmp/proj","prompt":"x"}' | AGENTBAR_HOME=rel AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/claude/update.js prompt; RC=$?
check "AGENTBAR_HOME relative: update.js uses the default" '[ "$RC" = 0 ] && [ -f "$HOME/.agentbar/state.d/ah-rel.json" ] && [ ! -e rel ]'

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
