#!/bin/bash
# Tests Scripts/hooks/opencode/agentbar.js — the OpenCode plugin — by loading it
# the way OpenCode does (ESM import, factory call) and driving its handlers with
# synthetic event-bus payloads against a throwaway HOME. Each scenario runs in
# one plugin instance, since the plugin keeps per-session bookkeeping (child
# sessions, failed turns) in memory.
set -uo pipefail
cd "$(dirname "$0")/../.."
NODE="${NODE:-node}"
PLUGIN="$PWD/Scripts/hooks/opencode/agentbar.js"

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
state() { cat "$HOME/.agentbar/state.d/$1.json" 2>/dev/null; }

# The driver: `node drive.mjs <scenario>` loads the plugin, runs one scripted
# sequence of bus events, and exits; the shell then asserts the state files.
DRIVER="$TESTROOT/drive.mjs"
cat > "$DRIVER" <<'JS'
import { pathToFileURL } from "node:url";
const { AgentBar } = await import(pathToFileURL(process.env.PLUGIN).href);
const h = await AgentBar({ directory: "/tmp/proj" });
const ev = (type, properties) => h.event({ event: { type, properties } });
const S = { info: { id: "oc1" } };
switch (process.argv[2]) {
  case "basic":
    await ev("session.created", S);
    await ev("message.updated", { info: { sessionID: "oc1", role: "user" } });
    await h["tool.execute.before"]({ sessionID: "oc1", tool: "bash" });
    break;
  case "tool-after":
    await ev("session.created", S);
    await h["tool.execute.before"]({ sessionID: "oc1", tool: "bash" });
    await h["tool.execute.after"]({ sessionID: "oc1", tool: "bash" });
    break;
  case "permission":
    await ev("session.created", S);
    await ev("permission.asked", { sessionID: "oc1", title: "Run  rm -rf\nbuild/" });
    break;
  case "permission-replied":
    await ev("session.created", S);
    await ev("permission.asked", { sessionID: "oc1", title: "Run rm" });
    await ev("permission.replied", { sessionID: "oc1" });
    break;
  case "idle":
    await ev("session.created", S);
    await ev("message.updated", { info: { sessionID: "oc1", role: "user" } });
    await ev("session.idle", { sessionID: "oc1" });
    break;
  case "error-then-idle":
    await ev("session.created", S);
    await ev("message.updated", { info: { sessionID: "oc1", role: "user" } });
    await ev("session.error", { sessionID: "oc1", error: { data: { message: "provider returned 429" } } });
    await ev("session.idle", { sessionID: "oc1" }); // the bookkeeping idle that trails a failure
    break;
  case "error-then-work":
    await ev("session.created", S);
    await ev("session.error", { sessionID: "oc1", error: "boom" });
    await h["tool.execute.before"]({ sessionID: "oc1", tool: "edit" }); // real work clears the failure
    await ev("session.idle", { sessionID: "oc1" });
    break;
  case "title":
    await ev("session.created", S);
    await ev("session.updated", { info: { id: "oc1", title: "  Refactor   the\nauth  module  " } });
    break;
  case "long-title":
    await ev("session.created", S);
    await ev("session.updated", { info: { id: "oc1", title: "a".repeat(119) + "\u{1F41B}".repeat(3) } });
    break;
  case "child":
    await ev("session.created", S);
    await ev("session.created", { info: { id: "child1", parentID: "oc1" } });
    await h["tool.execute.before"]({ sessionID: "child1", tool: "bash" });
    break;
  case "deleted":
    await ev("session.created", S);
    await ev("message.updated", { info: { sessionID: "oc1", role: "user" } });
    await ev("session.deleted", S);
    break;
  case "unknown":
    await ev("something.else", { sessionID: "oc1" });
    break;
}
JS
drive() { PLUGIN="$PLUGIN" "$NODE" "$DRIVER" "$1"; }

# Loads and constructs: the same shape OpenCode expects (async factory → handlers).
fresh_home
check "plugin loads as ESM"           '"$NODE" --input-type=module --check < "$PLUGIN"'

# session.created seeds a hidden row; a user message opens the turn; a tool
# call names the step. Rows carry the protocol's required fields.
fresh_home; drive basic
check "created+prompt+tool → tool"    'state oc1 | grep -q "\"state\":\"tool\""'
check "tool label is the tool name"   'state oc1 | grep -q "\"label\":\"bash\""'
check "agent id is opencode"          'state oc1 | grep -q "\"agent\":\"opencode\""'
check "project from directory"        'state oc1 | grep -q "\"project\":\"proj\""'
check "started after real work"       'state oc1 | grep -q "\"started\":true"'
check "pid is the plugin process"     'state oc1 | grep -q "\"pid\":[0-9]"'
check "started_at stamped"            'state oc1 | grep -q "\"started_at\":"'

fresh_home; drive tool-after
check "tool.execute.after → thinking" 'state oc1 | grep -q "\"state\":\"thinking\""'

# permission.asked is the only waiting state OpenCode exposes; its title is the
# label, flattened to one line.
fresh_home; drive permission
check "permission.asked → permission" 'state oc1 | grep -q "\"state\":\"permission\""'
check "permission label one-lined"    'state oc1 | grep -q "\"label\":\"Run rm -rf build/\""'
fresh_home; drive permission-replied
check "permission.replied → thinking" 'state oc1 | grep -q "\"state\":\"thinking\""'

fresh_home; drive idle
check "session.idle → done"           'state oc1 | grep -q "\"state\":\"done\""'

# A failed turn is its own state, and the idle that trails it must not repaint
# it green; real work afterwards clears the failure so the next idle IS done.
fresh_home; drive error-then-idle
check "session.error → error"         'state oc1 | grep -q "\"state\":\"error\""'
check "error label carries reason"    'state oc1 | grep -q "\"label\":\"provider returned 429\""'
check "trailing idle keeps error"     '! state oc1 | grep -q "\"state\":\"done\""'
fresh_home; drive error-then-work
check "work after error → done"       'state oc1 | grep -q "\"state\":\"done\""'

# The session title becomes the row's task line, whitespace collapsed and cut
# surrogate-safe.
fresh_home; drive title
check "title → prompt, one-lined"     'state oc1 | grep -q "\"prompt\":\"Refactor the auth module\""'
fresh_home; drive long-title
check "long title cut utf16-clean"    'python3 -c "import json,sys;json.load(open(sys.argv[1]))[\"prompt\"].encode(\"utf-8\")" "$HOME/.agentbar/state.d/oc1.json"'

# Subagent children ride inside the parent — no row of their own, ever.
fresh_home; drive child
check "child session has no row"      '[ ! -e "$HOME/.agentbar/state.d/child1.json" ]'
check "parent row unaffected"         '[ -e "$HOME/.agentbar/state.d/oc1.json" ]'

fresh_home; drive deleted
check "session.deleted removes row"   '[ ! -e "$HOME/.agentbar/state.d/oc1.json" ]'

fresh_home; drive unknown
check "unknown event writes nothing"  '[ -z "$(ls "$HOME/.agentbar/state.d/")" ]'

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
