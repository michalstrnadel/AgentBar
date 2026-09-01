#!/bin/bash
# Tests the non-Claude hook bridges (cursor, gemini, antigravity, codex) against
# a throwaway HOME: stale-sweep safety, launch-guard behaviour, and protocol
# compliance of what they write. Env knobs the bridges honor for tests:
#   AGENTBAR_FORCE_APP  "1"/"0" overrides the app/watcher liveness check
set -uo pipefail
cd "$(dirname "$0")/../.."
NODE="${NODE:-node}"

pass=0; fail=0
check() {
  if eval "$2"; then echo "ok   $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi
}

TESTROOT="$(mktemp -d)"
trap 'rm -rf "$TESTROOT"' EXIT

fresh_home() {
  export HOME="$TESTROOT/home.$$.$RANDOM"
  mkdir -p "$HOME/.agentbar/state.d"
}

# The value under $2 in JSON file $1 must be well-formed UTF-16 (encodable to
# UTF-8) — a lone surrogate left by a careless cut makes Swift's
# JSONSerialization reject the whole file.
utf16_clean() {
  python3 -c 'import json,sys;json.load(open(sys.argv[1])).get(sys.argv[2],"").encode("utf-8")' "$1" "$2"
}

# A fake `open` first in PATH, so launch tests can't start a real AgentBar.
FAKEBIN="$TESTROOT/fakebin"; mkdir -p "$FAKEBIN"
printf '#!/bin/sh\ntouch "$FAKEOPEN_MARK"\nexit 0\n' > "$FAKEBIN/open"; chmod +x "$FAKEBIN/open"

# --- cursor bridge -----------------------------------------------------------

# sessionStart with no frontend running sweeps ONLY files whose agent process is
# gone — other agents' live sessions must survive an AgentBar restart.
fresh_home
printf '{"agent":"codex","state":"tool","pid":%d,"started":true,"ts":1}' $$ \
  > "$HOME/.agentbar/state.d/livesess.json"
printf '{"agent":"claude","state":"tool","pid":999999,"started":true,"ts":1}' \
  > "$HOME/.agentbar/state.d/deadsess.json"
printf '{"hook_event_name":"sessionStart","conversation_id":"cur1","cwd":"/tmp/proj"}' \
  | AGENTBAR_FORCE_APP=0 "$NODE" Scripts/hooks/cursor/cursor.js
check "cursor sweep keeps live session" '[ -e "$HOME/.agentbar/state.d/livesess.json" ]'
check "cursor sweep drops dead session" '[ ! -e "$HOME/.agentbar/state.d/deadsess.json" ]'
check "cursor start writes its state"   'grep -q "\"agent\":\"cursor\"" "$HOME/.agentbar/state.d/cur1.json"'
check "cursor start hidden until work"  'grep -q "\"started\":false" "$HOME/.agentbar/state.d/cur1.json"'

# With a frontend up there is nothing stale to explain — no sweep at all.
fresh_home
printf '{"agent":"claude","state":"tool","pid":999999,"started":true,"ts":1}' \
  > "$HOME/.agentbar/state.d/deadsess.json"
printf '{"hook_event_name":"sessionStart","conversation_id":"cur1"}' \
  | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/cursor/cursor.js
check "cursor no sweep when app is up"  '[ -e "$HOME/.agentbar/state.d/deadsess.json" ]'

# The 120-char prompt cut must not split a surrogate pair (119 ASCII chars put
# the cut exactly on an emoji's high half).
fresh_home
"$NODE" -e 'const p={hook_event_name:"sessionStart",conversation_id:"cur2",prompt:"a".repeat(119)+"\u{1F41B}".repeat(3)};process.stdout.write(JSON.stringify(p))' \
  | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/cursor/cursor.js
check "cursor prompt cut utf16-clean"   'utf16_clean "$HOME/.agentbar/state.d/cur2.json" prompt'

# Launch guard: never start a second copy next to a running one; do launch when
# nothing runs. The spawn is darwin-only, so the positive half is too.
fresh_home
export FAKEOPEN_MARK="$HOME/open-called"
printf '{"hook_event_name":"sessionStart","conversation_id":"cur3"}' \
  | PATH="$FAKEBIN:$PATH" AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/cursor/cursor.js
sleep 1
check "cursor: no relaunch when up"     '[ ! -e "$FAKEOPEN_MARK" ]'
printf '{"hook_event_name":"sessionStart","conversation_id":"cur3"}' \
  | PATH="$FAKEBIN:$PATH" AGENTBAR_FORCE_APP=0 "$NODE" Scripts/hooks/cursor/cursor.js
sleep 1
check "cursor: launches when down"      '[ "$(uname)" != "Darwin" ] || [ -e "$FAKEOPEN_MARK" ]'
unset FAKEOPEN_MARK

# --- gemini bridge -----------------------------------------------------------

fresh_home
printf '{"agent":"codex","state":"tool","pid":%d,"started":true,"ts":1}' $$ \
  > "$HOME/.agentbar/state.d/livesess.json"
printf '{"agent":"claude","state":"tool","pid":999999,"started":true,"ts":1}' \
  > "$HOME/.agentbar/state.d/deadsess.json"
printf '{"hook_event_name":"SessionStart","session_id":"gem1","cwd":"/tmp/proj"}' \
  | AGENTBAR_FORCE_APP=0 "$NODE" Scripts/hooks/gemini/gemini.js
check "gemini sweep keeps live session" '[ -e "$HOME/.agentbar/state.d/livesess.json" ]'
check "gemini sweep drops dead session" '[ ! -e "$HOME/.agentbar/state.d/deadsess.json" ]'

fresh_home
export FAKEOPEN_MARK="$HOME/open-called"
printf '{"hook_event_name":"SessionStart","session_id":"gem2"}' \
  | PATH="$FAKEBIN:$PATH" AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/gemini/gemini.js
sleep 1
check "gemini: no relaunch when up"     '[ ! -e "$FAKEOPEN_MARK" ]'
printf '{"hook_event_name":"SessionStart","session_id":"gem2"}' \
  | PATH="$FAKEBIN:$PATH" AGENTBAR_FORCE_APP=0 "$NODE" Scripts/hooks/gemini/gemini.js
sleep 1
check "gemini: launches when down"      '[ "$(uname)" != "Darwin" ] || [ -e "$FAKEOPEN_MARK" ]'
unset FAKEOPEN_MARK

# --- antigravity bridge ------------------------------------------------------

# Event rides in argv (the payload carries no event name); tool name lands as
# the label, the session as started.
fresh_home
printf '{"conversationId":"anti1","workspacePaths":["/tmp/proj"],"toolCall":{"name":"edit_file"}}' \
  | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/antigravity/antigravity.js PreToolUse
check "antigravity tool state"          'grep -q "\"state\":\"tool\"" "$HOME/.agentbar/state.d/anti1.json"'
check "antigravity tool label"          'grep -q "\"label\":\"edit_file\"" "$HOME/.agentbar/state.d/anti1.json"'
check "antigravity project from ws"     'grep -q "\"project\":\"proj\"" "$HOME/.agentbar/state.d/anti1.json"'

# Launch condition: only the FIRST write of a session may launch, and only when
# nothing is running (the guard used to be inverted — it launched into a running
# app and never launched a stopped one).
fresh_home
export FAKEOPEN_MARK="$HOME/open-called"
printf '{"conversationId":"anti2"}' \
  | PATH="$FAKEBIN:$PATH" AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/antigravity/antigravity.js Stop
sleep 1
check "antigravity: no relaunch when up" '[ ! -e "$FAKEOPEN_MARK" ]'
printf '{"conversationId":"anti3"}' \
  | PATH="$FAKEBIN:$PATH" AGENTBAR_FORCE_APP=0 "$NODE" Scripts/hooks/antigravity/antigravity.js Stop
sleep 1
check "antigravity: launches when down" '[ "$(uname)" != "Darwin" ] || [ -e "$FAKEOPEN_MARK" ]'
rm -f "$FAKEOPEN_MARK"
printf '{"conversationId":"anti3"}' \
  | PATH="$FAKEBIN:$PATH" AGENTBAR_FORCE_APP=0 "$NODE" Scripts/hooks/antigravity/antigravity.js Stop
sleep 1
check "antigravity: launches once per session" '[ ! -e "$FAKEOPEN_MARK" ]'
unset FAKEOPEN_MARK

# --- codex notify ------------------------------------------------------------

# File name stays inside the protocol's 64-char session-id cap even for a huge
# thread id, and the prompt cut is surrogate-safe.
fresh_home
"$NODE" Scripts/hooks/codex/notify.js \
  "$("$NODE" -e 'process.stdout.write(JSON.stringify({type:"agent-turn-complete","thread-id":"t".repeat(100),input_messages:["x".repeat(119)+"\u{1F41B}".repeat(3)],cwd:"/tmp/proj"}))')"
CODEX_FILE="$(ls "$HOME/.agentbar/state.d/" | head -1)"
check "codex writes a state file"       '[ -n "$CODEX_FILE" ]'
check "codex file name within cap"      '[ "${#CODEX_FILE}" -le 69 ]'  # 64 + ".json"
check "codex id keeps its prefix"       'case "$CODEX_FILE" in codex-*) true;; *) false;; esac'
check "codex prompt cut utf16-clean"    'utf16_clean "$HOME/.agentbar/state.d/$CODEX_FILE" prompt'


# --- lifecycle & state mapping across the bridges -----------------------------

# Cursor: sessionEnd deletes the row (state "end" is never written); stop and
# afterAgentResponse are the turn-finished signals and read as "Done".
fresh_home
printf '{"hook_event_name":"sessionStart","conversation_id":"cur9"}' \
  | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/cursor/cursor.js
printf '{"hook_event_name":"preToolUse","conversation_id":"cur9","tool_name":"Shell"}' \
  | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/cursor/cursor.js
check "cursor preToolUse → tool + label" 'grep -q "\"state\":\"tool\"" "$HOME/.agentbar/state.d/cur9.json" && grep -q "\"label\":\"Shell\"" "$HOME/.agentbar/state.d/cur9.json"'
check "cursor tool event flips started" 'grep -q "\"started\":true" "$HOME/.agentbar/state.d/cur9.json"'
printf '{"hook_event_name":"sessionStart","conversation_id":"cur8","cwd":"/tmp/proj"}' \
  | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/cursor/cursor.js
printf '{"hook_event_name":"preToolUse","conversation_id":"cur8","tool_name":"Shell"}' \
  | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/cursor/cursor.js
check "cursor event w/o cwd keeps project" 'grep -q "\"project\":\"proj\"" "$HOME/.agentbar/state.d/cur8.json"'
printf '{"hook_event_name":"stop","conversation_id":"cur9"}' \
  | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/cursor/cursor.js
check "cursor stop → done"               'grep -q "\"state\":\"done\"" "$HOME/.agentbar/state.d/cur9.json" && grep -q "\"label\":\"Done\"" "$HOME/.agentbar/state.d/cur9.json"'
printf '{"hook_event_name":"sessionEnd","conversation_id":"cur9"}' \
  | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/cursor/cursor.js
check "cursor sessionEnd removes row"    '[ ! -e "$HOME/.agentbar/state.d/cur9.json" ]'
printf '{"hook_event_name":"somethingElse","conversation_id":"cur9"}' \
  | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/cursor/cursor.js
check "cursor unknown event writes nothing" '[ ! -e "$HOME/.agentbar/state.d/cur9.json" ]'

# Gemini: BeforeAgent is the turn start (life on text-only turns), BeforeTool
# names the step, AfterAgent finishes, SessionEnd removes.
fresh_home
printf '{"hook_event_name":"BeforeAgent","session_id":"gem9","cwd":"/tmp/proj","prompt":"add  tests"}' \
  | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/gemini/gemini.js
check "gemini BeforeAgent → thinking"    'grep -q "\"state\":\"thinking\"" "$HOME/.agentbar/state.d/gem9.json"'
check "gemini prompt one-lined"          'grep -q "\"prompt\":\"add tests\"" "$HOME/.agentbar/state.d/gem9.json"'
printf '{"hook_event_name":"BeforeTool","session_id":"gem9","tool_name":"run_shell_command"}' \
  | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/gemini/gemini.js
check "gemini BeforeTool → tool + label" 'grep -q "\"state\":\"tool\"" "$HOME/.agentbar/state.d/gem9.json" && grep -q "\"label\":\"run_shell_command\"" "$HOME/.agentbar/state.d/gem9.json"'
check "gemini prompt survives tool event" 'grep -q "\"prompt\":\"add tests\"" "$HOME/.agentbar/state.d/gem9.json"'
check "gemini event w/o cwd keeps project" 'grep -q "\"project\":\"proj\"" "$HOME/.agentbar/state.d/gem9.json"'
"$NODE" -e 'const fs=require("fs");const f=process.argv[1];const j=JSON.parse(fs.readFileSync(f));j.started_at=5555;fs.writeFileSync(f,JSON.stringify(j))' "$HOME/.agentbar/state.d/gem9.json"
printf '{"hook_event_name":"AfterAgent","session_id":"gem9"}' \
  | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/gemini/gemini.js
check "gemini AfterAgent → done"         'grep -q "\"state\":\"done\"" "$HOME/.agentbar/state.d/gem9.json"'
check "gemini started_at preserved"      'grep -q "\"started_at\":5555" "$HOME/.agentbar/state.d/gem9.json"'
printf '{"hook_event_name":"SessionEnd","session_id":"gem9"}' \
  | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/gemini/gemini.js
check "gemini SessionEnd removes row"    '[ ! -e "$HOME/.agentbar/state.d/gem9.json" ]'

# Antigravity: PreInvocation/PostInvocation/PostToolUse are all "thinking"
# (more model calls may follow), Stop ends the loop as done; the payload's own
# hook_event_name is honored when argv carries none; unknown events write
# nothing; a hook write with the CLI payload shape (session_id/cwd) maps too.
fresh_home
printf '{"conversationId":"anti9","workspacePaths":["/tmp/proj"]}' \
  | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/antigravity/antigravity.js PreInvocation
check "antigravity PreInvocation → thinking" 'grep -q "\"state\":\"thinking\"" "$HOME/.agentbar/state.d/anti9.json"'
printf '{"conversationId":"anti9"}' \
  | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/antigravity/antigravity.js PostToolUse
check "antigravity PostToolUse → thinking"   'grep -q "\"state\":\"thinking\"" "$HOME/.agentbar/state.d/anti9.json"'
check "antigravity project preserved"        'grep -q "\"project\":\"proj\"" "$HOME/.agentbar/state.d/anti9.json"'
printf '{"conversationId":"anti9"}' \
  | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/antigravity/antigravity.js Stop
check "antigravity Stop → done"              'grep -q "\"state\":\"done\"" "$HOME/.agentbar/state.d/anti9.json" && grep -q "\"label\":\"Done\"" "$HOME/.agentbar/state.d/anti9.json"'
printf '{"conversationId":"anti9"}' \
  | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/antigravity/antigravity.js Bogus
check "antigravity unknown event ignored"    'grep -q "\"state\":\"done\"" "$HOME/.agentbar/state.d/anti9.json"'
printf '{"session_id":"anti-cli","cwd":"/tmp/other","hook_event_name":"PreToolUse","tool_name":"read_file"}' \
  | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/antigravity/antigravity.js
check "antigravity CLI payload shape maps"   'grep -q "\"label\":\"read_file\"" "$HOME/.agentbar/state.d/anti-cli.json" && grep -q "\"project\":\"other\"" "$HOME/.agentbar/state.d/anti-cli.json"'

# Codex: only completion-type events count; a second notify keeps started_at
# and the previous prompt when the new payload carries no messages.
fresh_home
"$NODE" Scripts/hooks/codex/notify.js '{"type":"agent-turn-started","thread-id":"t1"}'
check "codex non-complete event ignored" '[ -z "$(ls "$HOME/.agentbar/state.d/")" ]'
"$NODE" Scripts/hooks/codex/notify.js '{"type":"agent-turn-complete","thread-id":"t1","input_messages":["first task"],"cwd":"/tmp/proj"}'
check "codex complete → done row"        'grep -q "\"state\":\"done\"" "$HOME/.agentbar/state.d/codex-t1.json" && grep -q "\"prompt\":\"first task\"" "$HOME/.agentbar/state.d/codex-t1.json"'
"$NODE" -e 'const fs=require("fs");const f=process.argv[1];const j=JSON.parse(fs.readFileSync(f));j.started_at=7777;fs.writeFileSync(f,JSON.stringify(j))' "$HOME/.agentbar/state.d/codex-t1.json"
"$NODE" Scripts/hooks/codex/notify.js '{"type":"agent-turn-complete","thread-id":"t1","cwd":"/tmp/proj"}'
check "codex second turn keeps started_at" 'grep -q "\"started_at\":7777" "$HOME/.agentbar/state.d/codex-t1.json"'
check "codex second turn keeps prompt"     'grep -q "\"prompt\":\"first task\"" "$HOME/.agentbar/state.d/codex-t1.json"'

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
