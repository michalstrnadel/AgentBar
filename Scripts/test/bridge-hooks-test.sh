#!/bin/bash
# Tests the non-Claude hook bridges (cursor, gemini, antigravity, codex, and the
# report bridges for aider, goose, cline, amp) against
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

# The tests borrow HOME; an inherited CLAUDE_CONFIG_DIR, COPILOT_HOME or
# CODEX_HOME would still point at the runner's real config.
unset CLAUDE_CONFIG_DIR COPILOT_HOME CODEX_HOME AGENTBAR_HOME
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
printf '#!/bin/sh\necho "$@" > "$FAKEOPEN_MARK"\nexit 0\n' > "$FAKEBIN/open"; chmod +x "$FAKEBIN/open"

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
check "cursor: launch is --background"  '[ "$(uname)" != "Darwin" ] || grep -q -- "--args --background" "$FAKEOPEN_MARK"'
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

# agy is fail-closed on PreToolUse: silence, junk, or a non-zero exit all read as
# "deny". The bridge must answer allow and exit 0 — a status bridge is never the
# reason a tool call was refused. Only PreToolUse: no other event takes a decision.
DEC="$(printf '{"conversationId":"anti1","workspacePaths":["/tmp/proj"],"toolCall":{"name":"edit_file"}}' \
  | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/antigravity/antigravity.js PreToolUse; echo "|$?")"
check "antigravity PreToolUse allows"   '[ "$DEC" = "{\"decision\":\"allow\"}|0" ]'
DEC="$(printf '{"conversationId":"anti1"}' \
  | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/antigravity/antigravity.js Stop; echo "|$?")"
check "antigravity Stop stays silent"   '[ "$DEC" = "|0" ]'
# Unparseable stdin is the crash path: the decision must still come out.
DEC="$(printf 'not json at all' \
  | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/antigravity/antigravity.js PreToolUse; echo "|$?")"
check "antigravity allows on junk input" '[ "$DEC" = "{\"decision\":\"allow\"}|0" ]'

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

# A new thread/turn id from the SAME codex process retires the earlier rows:
# Codex has no session-end event and a live codex keeps its pid alive, so
# nothing else would clear them before the 24h staleness cut.
"$NODE" Scripts/hooks/codex/notify.js '{"type":"agent-turn-complete","thread-id":"t2","input_messages":["second task"],"cwd":"/tmp/proj"}'
check "codex new thread retires old row"  '[ ! -e "$HOME/.agentbar/state.d/codex-t1.json" ]'
check "codex new thread row is there"     'grep -q "\"prompt\":\"second task\"" "$HOME/.agentbar/state.d/codex-t2.json"'
# Another agent's row, and a codex row owned by a DIFFERENT process, both survive.
printf '{"agent":"claude","state":"tool","pid":%d,"started":true,"ts":1}' $$ \
  > "$HOME/.agentbar/state.d/keepme.json"
printf '{"agent":"codex","state":"done","pid":999999,"started":true,"ts":1}' \
  > "$HOME/.agentbar/state.d/codex-other.json"
"$NODE" Scripts/hooks/codex/notify.js '{"type":"agent-turn-complete","thread-id":"t3","cwd":"/tmp/proj"}'
check "codex sweep spares other agents"   '[ -e "$HOME/.agentbar/state.d/keepme.json" ]'
check "codex sweep spares other process"  '[ -e "$HOME/.agentbar/state.d/codex-other.json" ]'

# --- codex notify stands down once the real hooks are live ----------------------
# Both writers name the row `codex-<thread-id>`, so the cost of getting this wrong
# is two writers arguing over one file — and the window it must NOT stand down in
# is the one before a human has accepted the hooks, when notify is all there is.
CODEX_DONE='{"type":"agent-turn-complete","thread-id":"sd1","input_messages":["task"],"cwd":"/tmp/proj"}'
BLOCK='# >>> agentbar >>> written by AgentBar; edit outside these two lines'

fresh_home
mkdir -p "$HOME/.codex"
printf 'model = "o3"\n' > "$HOME/.codex/config.toml"
"$NODE" Scripts/hooks/codex/notify.js "$CODEX_DONE"
check "codex: writes with no hooks"     '[ -f "$HOME/.agentbar/state.d/codex-sd1.json" ]'

fresh_home
mkdir -p "$HOME/.codex"
printf 'model = "o3"\n%s\ncommand = "/x/.agentbar/hooks/codex/hook.js"\n' "$BLOCK" > "$HOME/.codex/config.toml"
"$NODE" Scripts/hooks/codex/notify.js "$CODEX_DONE"
check "codex: writes while untrusted"   '[ -f "$HOME/.agentbar/state.d/codex-sd1.json" ]'

fresh_home
mkdir -p "$HOME/.codex"
CFG="$HOME/.codex/config.toml"
printf 'model = "o3"\n%s\ncommand = "/x/.agentbar/hooks/codex/hook.js"\n[hooks.state."%s:session_start:0:0"]\ntrusted_hash = "sha256:x"\n' "$BLOCK" "$CFG" > "$CFG"
"$NODE" Scripts/hooks/codex/notify.js "$CODEX_DONE"
check "codex: stands down when trusted" '[ ! -e "$HOME/.agentbar/state.d/codex-sd1.json" ]'

# An unreadable config must not silence it: a Codex session disappearing for a
# reason nobody can see is worse than a duplicate row.
fresh_home
mkdir -p "$HOME/.codex"
"$NODE" Scripts/hooks/codex/notify.js "$CODEX_DONE"
check "codex: writes with no config"    '[ -f "$HOME/.agentbar/state.d/codex-sd1.json" ]'

# --- the codex shim: Claude's scripts, told who is asking ------------------------
# Codex handlers carry no `env`, so the shim is where AGENTBAR_AGENT and the row
# prefix are set — and it loads the script in its own process, because a spawned
# child's parent would be the shim, which exits at once, and `pid` is what the
# frontends prune dead rows by.
fresh_home
printf '{"session_id":"shim1","cwd":"/tmp/proj","prompt":"hello there","model":"gpt-6"}' \
  | "$NODE" Scripts/hooks/codex/hook.js update.js prompt
check "shim: row is prefixed"           '[ -f "$HOME/.agentbar/state.d/codex-shim1.json" ]'
check "shim: filed under codex"         'grep -q "\"agent\":\"codex\"" "$HOME/.agentbar/state.d/codex-shim1.json"'
check "shim: a live state, not done"    'grep -q "\"state\":\"thinking\"" "$HOME/.agentbar/state.d/codex-shim1.json"'
check "shim: keeps prompt and model"    'grep -q "hello there" "$HOME/.agentbar/state.d/codex-shim1.json" && grep -q "\"model\":\"gpt-6\"" "$HOME/.agentbar/state.d/codex-shim1.json"'
# The file name is the identity; a row spelling its own id two ways is a trap.
check "shim: id agrees with file name"  'grep -q "\"sessionId\":\"codex-shim1\"" "$HOME/.agentbar/state.d/codex-shim1.json"'
check "shim: pid is its own parent"     'grep -q "\"pid\":$$" "$HOME/.agentbar/state.d/codex-shim1.json"'

# A script name it cannot vouch for runs nothing at all: for PermissionRequest,
# silence is what falls through to Codex's own prompt.
fresh_home
printf '{"session_id":"shim2"}' | "$NODE" Scripts/hooks/codex/hook.js ../claude/update.js prompt
check "shim: refuses a path"            '[ -z "$(ls "$HOME/.agentbar/state.d/" 2>/dev/null)" ]'
fresh_home
printf '{"session_id":"shim3"}' | "$NODE" Scripts/hooks/codex/hook.js
check "shim: refuses an empty script"   '[ -z "$(ls "$HOME/.agentbar/state.d/" 2>/dev/null)" ]'

# The session's end is the row's deletion, which Codex never had before.
fresh_home
printf '{"session_id":"shim4","cwd":"/tmp/proj"}' \
  | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/codex/hook.js lifecycle.js start
check "shim: lifecycle seeds a row"     '[ -f "$HOME/.agentbar/state.d/codex-shim4.json" ]'
printf '{"session_id":"shim4"}' \
  | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/codex/hook.js lifecycle.js end
check "shim: lifecycle ends the row"    '[ ! -e "$HOME/.agentbar/state.d/codex-shim4.json" ]'

# --- a lone surrogate that ARRIVED that way, not one a cut made ------------------
# The cut has been guarded since the bridges were written. What went through
# untouched was a surrogate already unpaired in the payload: it reaches the file as
# an escape Swift's JSONSerialization refuses, and the session disappears from every
# frontend until the next clean write. Now every value is paired on the way out.
fresh_home
"$NODE" -e 'process.stdout.write(JSON.stringify({hook_event_name:"sessionStart",conversation_id:"cur9",prompt:"fix \ud800 this"}))' \
  | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/cursor/cursor.js
check "cursor keeps a lone surrogate out" 'utf16_clean "$HOME/.agentbar/state.d/cur9.json" prompt'
check "and still wrote the row"           '[ -e "$HOME/.agentbar/state.d/cur9.json" ]'

fresh_home
"$NODE" -e 'process.stdout.write(JSON.stringify({hook_event_name:"SessionStart",session_id:"gem9",prompt:"fix \ud800 this"}))' \
  | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/gemini/gemini.js
check "gemini keeps one out too"          'utf16_clean "$HOME/.agentbar/state.d/gem9.json" prompt'

# Through the one free-text field notify.js copies into the row: the last of the
# turn's input messages becomes `prompt`. It never reads last-assistant-message, so
# a surrogate there proved nothing — and utf16_clean passes on a missing key, so the
# prompt is also required to be there.
fresh_home
"$NODE" Scripts/hooks/codex/notify.js "$("$NODE" -e 'process.stdout.write(JSON.stringify({type:"agent-turn-complete","thread-id":"ntf9",cwd:"/tmp","input-messages":["fix \ud800 this"]}))')"
check "notify keeps one out as well"      'utf16_clean "$HOME/.agentbar/state.d/codex-ntf9.json" prompt'
check "and the prompt is still there"     'grep -q "\"prompt\":\"fix  this\"" "$HOME/.agentbar/state.d/codex-ntf9.json"'

# --- antigravity, handed payloads nobody sane would send -------------------------
# The stakes here are the opposite way round from every other bridge: agy reads
# silence, a crash, or any stdout that is not a valid decision as **deny**. So for
# each of these the allow has to come out anyway — a status bridge is never the
# reason a tool call was refused — and whatever row it leaves has to be readable.
anti_hostile() {   # anti_hostile <name> <json>
  fresh_home
  local out
  out="$(printf '%s' "$2" | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/antigravity/antigravity.js PreToolUse 2>/dev/null; echo "|$?")"
  check "anti: $1 still allows" '[ "$out" = "{\"decision\":\"allow\"}|0" ]'
}

BIGA=$("$NODE" -e 'process.stdout.write("A".repeat(200000))')
anti_hostile "a tool name longer than a book" \
  "{\"conversationId\":\"h1\",\"toolCall\":{\"name\":\"$BIGA\"}}"
anti_hostile "a conversation id shaped like a path" \
  '{"conversationId":"../../../../tmp/pwned","toolCall":{"name":"edit_file"}}'
anti_hostile "a lone surrogate in the tool name" \
  '{"conversationId":"h3","toolCall":{"name":"edit \ud800 file"}}'
anti_hostile "workspacePaths that is a string" \
  '{"conversationId":"h4","workspacePaths":"/tmp/proj","toolCall":{"name":"edit_file"}}'
anti_hostile "a toolCall that is an array" \
  '{"conversationId":"h5","toolCall":[1,2,3]}'
anti_hostile "every field null" \
  '{"conversationId":null,"workspacePaths":null,"toolCall":null}'
anti_hostile "an empty document" '{}'

# And the row it wrote for the surrogate case is one a frontend can read.
fresh_home
printf '{"conversationId":"h6","workspacePaths":["/tmp/proj"],"toolCall":{"name":"edit \ud800 file"}}' \
  | AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/antigravity/antigravity.js PreToolUse >/dev/null
check "anti: the row it leaves is readable" 'utf16_clean "$HOME/.agentbar/state.d/h6.json" label'

# --- AGENTBAR_HOME (docs/protocol.md "Where state lives") ---------------------
# Every bridge writes under the root it names, and nothing under ~/.agentbar. A
# HOME with no ~/.agentbar at all, so one stray write shows up as it existing; a
# trailing slash on the value is the same root.
HOME_SEQ=$((HOME_SEQ + 1))
export HOME="$TESTROOT/home.$$.$HOME_SEQ"; mkdir -p "$HOME"
ROOT="$TESTROOT/root.$$.$HOME_SEQ"
printf '{"hook_event_name":"preToolUse","conversation_id":"ah-cur","tool_name":"Shell"}' \
  | AGENTBAR_HOME="$ROOT/" AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/cursor/cursor.js
printf '{"hook_event_name":"BeforeAgent","session_id":"ah-gem","cwd":"/tmp/proj","prompt":"x"}' \
  | AGENTBAR_HOME="$ROOT/" AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/gemini/gemini.js
printf '{"conversationId":"ah-anti","workspacePaths":["/tmp/proj"]}' \
  | AGENTBAR_HOME="$ROOT/" AGENTBAR_FORCE_APP=1 "$NODE" Scripts/hooks/antigravity/antigravity.js PreInvocation
AGENTBAR_HOME="$ROOT/" "$NODE" Scripts/hooks/codex/notify.js '{"type":"agent-turn-complete","thread-id":"ah","cwd":"/tmp/proj"}'
for f in ah-cur ah-gem ah-anti codex-ah; do
  check "AGENTBAR_HOME: $f written under the root" '[ -f "$ROOT/state.d/$f.json" ]'
done
check "AGENTBAR_HOME: nothing under ~/.agentbar" '[ ! -e "$HOME/.agentbar" ]'
# A relative value is ignored, never an error: the hook still exits 0 and writes
# to the default, and nothing appears relative to its working directory.
mkdir -p "$HOME/cwd"
RC="$(cd "$HOME/cwd" && printf '{"hook_event_name":"BeforeAgent","session_id":"ah-rel","prompt":"x"}' \
  | AGENTBAR_HOME=rel/root AGENTBAR_FORCE_APP=1 "$NODE" "$OLDPWD/Scripts/hooks/gemini/gemini.js"; echo $?)"
check "AGENTBAR_HOME relative: hook exits 0"       '[ "$RC" = 0 ]'
check "AGENTBAR_HOME relative: falls back to default" '[ -f "$HOME/.agentbar/state.d/ah-rel.json" ] && [ ! -e "$HOME/cwd/rel" ]'

# --- report bridges: aider, goose, cline, amp (docs/protocol.md "Bring your own agent")
# These four call `agentbar report` instead of writing state.d themselves. AGENTBAR_CLI
# pins the CLI under test; a fake `open` stays first in PATH so nothing in here can
# start a real AgentBar (`report` launches nothing, and this checks that it stays so).
CLI_ABS="$PWD/Scripts/cli/agentbar"
SD() { echo "$HOME/.agentbar/state.d/$1.json"; }
field() { "$NODE" -e 'try{const v=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))[process.argv[2]];process.stdout.write(v===undefined?"":String(v))}catch{}' "$1" "$2"; }

# A stand-in for an agent that runs its hooks the way goose and Cline do: a
# long-lived parent that starts `sh -c <command>` with the payload on stdin.
# Prints the parent's pid, then whatever the hook wrote to stdout.
fake_host() {
  python3 -c 'import os,subprocess,sys
r=subprocess.run(["sh","-c",sys.argv[1]],input=sys.argv[2].encode(),stdout=subprocess.PIPE)
sys.stdout.write(str(os.getpid())+"\n"+r.stdout.decode()+"\nrc="+str(r.returncode))' "$1" "$2"
}

# aider: a fake aider that plays one turn — a prompt goes into the input history,
# then the notification command fires — and snapshots the row at each step.
fresh_home
export FAKEOPEN_MARK="$HOME/open-called"
AIDERBIN="$TESTROOT/fakeaider"; mkdir -p "$AIDERBIN" "$HOME/proj"
cat > "$AIDERBIN/aider" <<'AIDER'
#!/bin/bash
notify=""; prev=""
for a in "$@"; do [ "$prev" = "--notifications-command" ] && notify="$a"; prev="$a"; done
printf '%s\n' "$@" > "$HOME/aider-args"
ROW="$HOME/.agentbar/state.d/aider-$PPID.json"
echo "$PPID" > "$HOME/aider-wrapper-pid"
cp "$ROW" "$HOME/at-start.json" 2>/dev/null
printf '\n# 2026-10-07 10:00:00\n+fix the login bug\n' >> .aider.input.history
for i in 1 2 3 4 5 6 7 8 9 10; do grep -q '"thinking"' "$ROW" 2>/dev/null && break; sleep 0.2; done
cp "$ROW" "$HOME/at-work.json" 2>/dev/null
sh -c "$notify"
cp "$ROW" "$HOME/at-done.json" 2>/dev/null
exit 3
AIDER
chmod +x "$AIDERBIN/aider"
( cd "$HOME/proj" && PATH="$FAKEBIN:$AIDERBIN:$PATH" AGENTBAR_CLI="$CLI_ABS" AGENTBAR_AIDER_POLL=0.2 \
    bash "$OLDPWD/Scripts/hooks/aider/agentbar-aider" --model sonnet app.py ); RC=$?
WPID="$(cat "$HOME/aider-wrapper-pid" 2>/dev/null)"
check "aider: start is idle"                  '[ "$(field "$HOME/at-start.json" state)" = idle ]'
check "aider: row is agent aider, named Aider" '[ "$(field "$HOME/at-start.json" agent)" = aider ] && [ "$(field "$HOME/at-start.json" agent_name)" = Aider ]'
check "aider: row carries the wrapper pid"    '[ -n "$WPID" ] && [ "$(field "$HOME/at-start.json" pid)" = "$WPID" ]'
check "aider: a history line is thinking"     '[ "$(field "$HOME/at-work.json" state)" = thinking ] && [ "$(field "$HOME/at-work.json" prompt)" = "fix the login bug" ]'
check "aider: the notification is done"       '[ "$(field "$HOME/at-done.json" state)" = done ]'
check "aider: exit removes the row"           '[ -z "$(ls "$HOME/.agentbar/state.d")" ]'
check "aider: exit code passes through"       '[ "$RC" = 3 ]'
check "aider: user args pass through"         'grep -qx -- "--model" "$HOME/aider-args" && grep -qx "app.py" "$HOME/aider-args"'
check "aider: notifications switched on"      'grep -qx -- "--notifications" "$HOME/aider-args"'
check "aider: nothing launched"               '[ ! -e "$FAKEOPEN_MARK" ]'

# A one-shot --message run starts as thinking on that task.
fresh_home
export FAKEOPEN_MARK="$HOME/open-called"
mkdir -p "$HOME/proj"
( cd "$HOME/proj" && PATH="$FAKEBIN:$AIDERBIN:$PATH" AGENTBAR_CLI="$CLI_ABS" \
    bash "$OLDPWD/Scripts/hooks/aider/agentbar-aider" -m "add a README" ) >/dev/null
check "aider -m: starts thinking on the task" '[ "$(field "$HOME/at-start.json" state)" = thinking ] && [ "$(field "$HOME/at-start.json" prompt)" = "add a README" ]'

# No CLI anywhere: Aider still runs, untouched, and nothing is written.
fresh_home
mkdir -p "$TESTROOT/lonely" "$HOME/proj"
cp Scripts/hooks/aider/agentbar-aider "$TESTROOT/lonely/"
RC="$(cd "$HOME/proj" && PATH="$AIDERBIN:/usr/bin:/bin" bash "$TESTROOT/lonely/agentbar-aider" x >/dev/null 2>&1; echo $?)"
check "aider without a CLI: still runs aider" '[ "$RC" = 3 ] && [ -f "$HOME/aider-args" ] && ! grep -qx -- "--notifications" "$HOME/aider-args"'
check "aider without a CLI: writes nothing"   '[ -z "$(ls "$HOME/.agentbar/state.d")" ]'
unset FAKEOPEN_MARK

# goose: the plugin's hooks.json command, run the way goose runs it.
fresh_home
GOOSE_CMD="AGENTBAR_CLI='$CLI_ABS' PATH='$FAKEBIN':\"\$PATH\" node '$PWD/Scripts/hooks/goose/agentbar.js'"
OUT="$(fake_host "$GOOSE_CMD" '{"event":"SessionStart","session_id":"g1","matcher_context":""}')"
HPID="$(echo "$OUT" | head -1)"
check "goose: SessionStart writes idle"       '[ "$(field "$(SD goose-g1)" state)" = idle ] && [ "$(field "$(SD goose-g1)" agent)" = goose ]'
check "goose: pid is goose, not its sh -c"    '[ "$(field "$(SD goose-g1)" pid)" = "$HPID" ]'
check "goose: prints nothing (allow)"         '[ "$(echo "$OUT" | sed -n 2p)" = "" ] && echo "$OUT" | grep -q "^rc=0$"'
fake_host "$GOOSE_CMD" '{"event":"UserPromptSubmit","session_id":"g1","matcher_context":"x","message":"rename the module"}' >/dev/null
check "goose: prompt is thinking"             '[ "$(field "$(SD goose-g1)" state)" = thinking ] && [ "$(field "$(SD goose-g1)" prompt)" = "rename the module" ]'
OUT="$(fake_host "$GOOSE_CMD" '{"event":"PreToolUse","session_id":"g1","matcher_context":"developer__shell","tool_name":"developer__shell","tool_input":{"command":"ls -la"},"working_dir":"/tmp/gproj"}')"
check "goose: PreToolUse is a labelled tool"  '[ "$(field "$(SD goose-g1)" state)" = tool ] && [ "$(field "$(SD goose-g1)" label)" = "shell: ls -la" ]'
check "goose: working_dir is the row cwd"     '[ "$(field "$(SD goose-g1)" cwd)" = /tmp/gproj ] && [ "$(field "$(SD goose-g1)" project)" = gproj ]'
check "goose: PreToolUse prints nothing"      '[ "$(echo "$OUT" | sed -n 2p)" = "" ] && echo "$OUT" | grep -q "^rc=0$"'
fake_host "$GOOSE_CMD" '{"event":"Stop","session_id":"g1","matcher_context":"","last_assistant_message":"Renamed it."}' >/dev/null
check "goose: Stop is done with the recap"    '[ "$(field "$(SD goose-g1)" state)" = done ] && [ "$(field "$(SD goose-g1)" recap)" = "Renamed it." ]'
fake_host "$GOOSE_CMD" '{"event":"SessionEnd","session_id":"g1","matcher_context":""}' >/dev/null
check "goose: SessionEnd removes the row"     '[ ! -e "$(SD goose-g1)" ]'
for bad in 'not json' '[]' '{}' '{"event":"PreToolUse"}' '{"event":"Nope","session_id":"g2"}'; do
  OUT="$(fake_host "$GOOSE_CMD" "$bad")"
  check "goose: survives $bad"                '[ "$(echo "$OUT" | sed -n 2p)" = "" ] && echo "$OUT" | grep -q "^rc=0$" && [ -z "$(ls "$HOME/.agentbar/state.d")" ]'
done
check "goose: hooks.json is valid and names the script" \
  '"$NODE" -e "const h=require(\"./Scripts/hooks/goose/hooks/hooks.json\").hooks;process.exit(h.PreToolUse[0].hooks[0].command.includes(\"agentbar.js\")&&!h.PreToolUse[0].hooks[0].on_failure?0:1)"'

# cline: the VS Code extension's dialect, then the CLI's.
fresh_home
CLINE_CMD="AGENTBAR_CLI='$CLI_ABS' PATH='$FAKEBIN':\"\$PATH\" '$PWD/Scripts/hooks/cline/agentbar.js'"
OUT="$(fake_host "$CLINE_CMD" '{"clineVersion":"3.40.0","hookName":"TaskStart","taskId":"c1","workspaceRoots":["/tmp/cproj"],"taskStart":{"taskMetadata":{"taskId":"c1","initialTask":"write the tests"}}}')"
HPID="$(echo "$OUT" | head -1)"
check "cline: TaskStart is thinking on the task" '[ "$(field "$(SD cline-c1)" state)" = thinking ] && [ "$(field "$(SD cline-c1)" prompt)" = "write the tests" ]'
check "cline: workspace root is the row cwd" '[ "$(field "$(SD cline-c1)" cwd)" = /tmp/cproj ] && [ "$(field "$(SD cline-c1)" agent_name)" = Cline ]'
check "cline: pid is the host, not sh -c"    '[ "$(field "$(SD cline-c1)" pid)" = "$HPID" ]'
check "cline: answers only cancel:false"     '[ "$(echo "$OUT" | sed -n 2p)" = "{\"cancel\":false}" ] && echo "$OUT" | grep -q "^rc=0$"'
OUT="$(fake_host "$CLINE_CMD" '{"hookName":"PreToolUse","taskId":"c1","workspaceRoots":["/tmp/cproj"],"preToolUse":{"toolName":"execute_command","parameters":{"command":"npm test"}}}')"
check "cline: PreToolUse is a labelled tool" '[ "$(field "$(SD cline-c1)" state)" = tool ] && [ "$(field "$(SD cline-c1)" label)" = "execute_command: npm test" ]'
check "cline: PreToolUse never cancels"      '[ "$(echo "$OUT" | sed -n 2p)" = "{\"cancel\":false}" ]'
fake_host "$CLINE_CMD" '{"hookName":"TaskComplete","taskId":"c1","taskComplete":{"taskMetadata":{}}}' >/dev/null
check "cline: TaskComplete is done"          '[ "$(field "$(SD cline-c1)" state)" = done ]'
fake_host "$CLINE_CMD" '{"hookName":"Notification","taskId":"c1","notification":{"event":"user_attention","message":"Which file?","waitingForUserInput":true}}' >/dev/null
check "cline: waiting Notification is question" '[ "$(field "$(SD cline-c1)" state)" = question ]'
fake_host "$CLINE_CMD" '{"hookName":"tool_call","taskId":"c2","workspaceRoots":["/tmp/cproj"],"tool_call":{"id":"t","name":"run_commands","input":{"commands":["git status"]}}}' >/dev/null
check "cline CLI: tool_call is a labelled tool" '[ "$(field "$(SD cline-c2)" state)" = tool ] && [ "$(field "$(SD cline-c2)" label)" = "run_commands: git status" ]'
fake_host "$CLINE_CMD" '{"hookName":"agent_error","taskId":"c2","error":{"message":"rate limited"}}' >/dev/null
check "cline CLI: agent_error is error"      '[ "$(field "$(SD cline-c2)" state)" = error ] && [ "$(field "$(SD cline-c2)" label)" = "rate limited" ]'
fake_host "$CLINE_CMD" '{"hookName":"session_shutdown","taskId":"c2"}' >/dev/null
check "cline CLI: session_shutdown removes the row" '[ ! -e "$(SD cline-c2)" ]'
rm -f "$(SD cline-c1)"
for bad in 'not json' '[]' '{}' '{"hookName":"PreToolUse"}' '{"hookName":"TaskStart","taskId":null}'; do
  OUT="$(fake_host "$CLINE_CMD" "$bad")"
  check "cline: survives $bad"               '[ "$(echo "$OUT" | sed -n 2p)" = "{\"cancel\":false}" ] && echo "$OUT" | grep -q "^rc=0$" && [ -z "$(ls "$HOME/.agentbar/state.d")" ]'
done

# amp: load the plugin with a stand-in for Amp's PluginAPI and fire its events.
fresh_home
mkdir -p "$HOME/aproj"
cat > "$TESTROOT/amp-driver.mjs" <<'DRIVER'
import { pathToFileURL } from "node:url";
const [plugin, cwd, ...events] = process.argv.slice(2);
const handlers = {};
const amp = { on: (e, f) => { handlers[e] = f; }, $: async () => ({ exitCode: 0, stdout: cwd + "\n", stderr: "" }) };
(await import(pathToFileURL(plugin))).default(amp);
console.log(JSON.stringify({ self: process.pid, events: Object.keys(handlers) }));
for (const e of events) { const [name, json] = e.split(/=(.*)/s); handlers[name](JSON.parse(json)); }
DRIVER
amp_run() {  # under a non-shell parent, as Amp's plugin host would be
  python3 -c 'import os,subprocess,sys
subprocess.run(sys.argv[1:]); print(os.getpid())' env AGENTBAR_CLI="$CLI_ABS" PATH="$FAKEBIN:$PATH" \
    "$NODE" "$TESTROOT/amp-driver.mjs" "$PWD/Scripts/hooks/amp/agentbar.js" "$HOME/aproj" "$@"
}
OUT="$(amp_run 'session.start={"thread":{"id":"T-1"}}' 'agent.start={"thread":{"id":"T-1"},"message":"bump deps","id":1}' \
  'tool.result={"thread":{"id":"T-1"},"toolUseID":"u","tool":"Bash","input":{},"status":"done"}')"
check "amp: listens to no deciding event"    'echo "$OUT" | head -1 | grep -q "session.start" && ! echo "$OUT" | grep -q "tool.call"'
check "amp: tool.result labels the tool"     '[ "$(field "$(SD amp-T-1)" state)" = tool ] && [ "$(field "$(SD amp-T-1)" label)" = Bash ]'
check "amp: the prompt is kept"              '[ "$(field "$(SD amp-T-1)" prompt)" = "bump deps" ] && [ "$(field "$(SD amp-T-1)" agent_name)" = Amp ]'
check "amp: cwd is what amp.\$ pwd says"      '[ "$(field "$(SD amp-T-1)" cwd)" = "$HOME/aproj" ]'
check "amp: pid is the plugin host parent"   '[ "$(field "$(SD amp-T-1)" pid)" = "$(echo "$OUT" | tail -1)" ]'
amp_run 'agent.end={"thread":{"id":"T-1"},"message":"","id":1,"status":"done","messages":[]}' >/dev/null
check "amp: agent.end done is done"          '[ "$(field "$(SD amp-T-1)" state)" = done ]'
amp_run 'agent.end={"thread":{"id":"T-1"},"status":"error"}' >/dev/null
check "amp: agent.end error is error"        '[ "$(field "$(SD amp-T-1)" state)" = error ]'
amp_run 'agent.end={"thread":{}}' 'tool.result={}' >/dev/null; RC=$?
check "amp: events without a thread are ignored" '[ "$RC" = 0 ] && [ "$(ls "$HOME/.agentbar/state.d")" = amp-T-1.json ]'
# Started straight from a shell, the plugin is in Amp's own process: its own pid.
OUT="$(AGENTBAR_CLI="$CLI_ABS" "$NODE" "$TESTROOT/amp-driver.mjs" "$PWD/Scripts/hooks/amp/agentbar.js" "$HOME/aproj" \
  'session.start={"thread":{"id":"T-2"}}')"
check "amp: under a shell, its own pid"      '[ "$(field "$(SD amp-T-2)" pid)" = "$("$NODE" -e "console.log(JSON.parse(process.argv[1]).self)" "$(echo "$OUT" | head -1)")" ]'

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
