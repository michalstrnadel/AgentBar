#!/bin/bash
# Integration test for AntigravityWatcher against the RUNNING AgentBar app:
# stages a synthetic per-turn transcript under each Antigravity brain root and
# asserts the state.d upserts walk thinking -> permission -> done. The watcher
# lives inside the app process bound to the real HOME, so unlike the hook tests
# this cannot run in a throwaway HOME — it skips (exit 0) when the app isn't up.
#
# Both roots are covered because they are the whole reason the watcher exists:
# the desktop app fires only PostToolUse, and the `agy` CLI loads hooks.json but
# never runs the handlers, so CLI sessions are transcript-only.
#
# Timing notes: the watcher scans every 2s; "permission" additionally requires
# the transcript to be quiet for >=6s with an unexecuted tool_call as the last
# entry. Never backdate mtimes to fake quietness — the upsert guard rejects a
# ts older than the one already recorded (real mtimes only ever age forward).
set -uo pipefail

if [ "$(uname)" != "Darwin" ] || ! pgrep -xq AgentBar; then
  echo "skip: AgentBar app not running (this test needs the live watcher)"
  exit 0
fi

pass=0; fail=0
check() {
  if eval "$2"; then echo "ok   $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi
}

state() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$S" "$1" 2>/dev/null; }

# Bounded poll until the session state equals $1 (seconds in $2).
wait_state() {
  for _ in $(seq $(($2 * 2))); do
    [ "$(state state)" = "$1" ] && return 0
    sleep 0.5
  done
  return 1
}

# walk <gemini-subdir> <expected-entrypoint>
walk() {
  ID="agbwtest$$$(echo "$1" | tr -dc 'a-z')"
  BRAIN="$HOME/.gemini/$1/brain/$ID"
  T="$BRAIN/.system_generated/logs/transcript_full.jsonl"
  S="$HOME/.agentbar/state.d/$ID.json"
  trap 'rm -rf "$BRAIN" "$S"' EXIT
  mkdir -p "$BRAIN/.system_generated/logs"
  echo "-- $1"

  # 1. a fresh unexecuted tool_call line: live turn -> thinking
  echo '{"source":"MODEL","status":"DONE","type":"PLANNER_RESPONSE","tool_calls":[{"name":"run_command"}]}' > "$T"
  check "fresh write -> thinking"   'wait_state thinking 6'
  check "entrypoint is $2"          '[ "$(state entrypoint)" = "'"$2"'" ]'

  # 2. same line quiet past the 6s threshold -> the agent is sitting on its prompt
  check "quiet tool_call -> permission" 'wait_state permission 14'
  check "label is the pending tool"     '[ "$(state label)" = "run_command" ]'

  # 3. final MODEL response appended -> done immediately, no decay wait
  echo '{"source":"MODEL","status":"DONE","type":"PLANNER_RESPONSE","text":"answer"}' >> "$T"
  check "final response -> done"    'wait_state done 6'

  rm -rf "$BRAIN" "$S"
}

walk antigravity     antigravity-app   # desktop app: row clicks focus the app
walk antigravity-cli cli               # `agy` in a terminal: row clicks focus it

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
