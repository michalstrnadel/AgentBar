#!/bin/bash
# The "never an implicit approval" contract (docs/contract.md), path by path.
#
# Every failure path the contract names is driven through the REAL hook scripts,
# as each host runs them — Claude Code and Copilot CLI call permission.js, Codex
# calls it through codex/hook.js — in a throwaway AGENTBAR_HOME, and each must
# write nothing to stdout: nothing is what sends the request back to the agent's
# own prompt. At the end every byte any failure path wrote is searched for an
# allow, and a positive control per host proves the search could have found one.
#
# The ids (P1…P17, B1) are the rows of docs/contract.md. A release cannot ship
# with this red: ci.yml runs it, and a release needs that commit's CI run green.
set -uo pipefail
cd "$(dirname "$0")/../.."
NODE="${NODE:-node}"
REPO="$PWD"
# PERMISSION_JS points the Claude and Copilot runs at another copy — how a new clause
# is shown to fail on the code before its fix (docs/testing.md).
PERM="${PERMISSION_JS:-$REPO/Scripts/hooks/claude/permission.js}"
SHIM="$REPO/Scripts/hooks/codex/hook.js"
ENOSPC="$REPO/Scripts/test/lib/enospc.js"
CLOCK="$REPO/Scripts/test/lib/clock.js"

# check, contract, fresh_home, wait_req, ANSWER_TIMEOUT, $TESTROOT and summary.
. Scripts/test/lib/harness.sh

# What "nobody answered" waits in this suite. Short, because every one of these
# paths ends by the hook giving up, and the clause is that it gives up silently.
NOBODY=2
ROOT_USER=0; [ "$(id -u)" = 0 ] && ROOT_USER=1   # root ignores mode bits

# The three hosts that can be answered for, each with the payload its own hook
# event carries. The command is harmless on purpose: nothing here runs it.
CLAUDE_EVENT='{"session_id":"ctsess","prompt_id":"p1","cwd":"/tmp/ct","tool_name":"Bash","tool_input":{"command":"echo contract"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"echo:*"}],"behavior":"allow","destination":"localSettings"}]}'
COPILOT_EVENT='{"hookName":"permissionRequest","sessionId":"ctsess","cwd":"/tmp/ct","toolName":"bash","toolInput":{"command":"echo contract"},"permissionSuggestions":[]}'
CODEX_EVENT='{"hook_event_name":"PermissionRequest","session_id":"ctsess","turn_id":"t1","cwd":"/tmp/ct","tool_name":"Bash","tool_input":{"command":"echo contract"}}'
QUESTION_EVENT='{"session_id":"ctsess","prompt_id":"q1","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which one?","header":"Pick","multiSelect":false,"options":[{"label":"A"},{"label":"B"}]}]}}'
PLAN_EVENT='{"session_id":"ctsess","prompt_id":"pl1","tool_name":"ExitPlanMode","tool_input":{"plan":"1. edit\n2. test"}}'
DIALECTS="claude copilot codex"

# The request's file name, where the host makes it predictable. Copilot sends no
# prompt id, so its name carries the hook's own pid and no leftover can share it.
name_of() {
  case "$1" in
    claude) echo "ctsess-p1.json" ;;
    codex)  echo "codex-ctsess-t1.json" ;;
    *)      echo "" ;;
  esac
}

# hook DIALECT [VAR=value …] — run the real hook the way DIALECT's host does, with
# the payload in $PAYLOAD (or the host's default), stdout to $HOME/out.json. $PRELOAD
# names a module for `node -r`. Background it with & like any command.
hook() {
  local d="$1"; shift
  local pre=(); [ -n "${PRELOAD:-}" ] && pre=(-r "$PRELOAD")
  case "$d" in
    claude)  env AGENTBAR_HOME="$HOME/.agentbar" "$@" "$NODE" "${pre[@]+"${pre[@]}"}" "$PERM" \
               <<<"${PAYLOAD:-$CLAUDE_EVENT}" >"$HOME/out.json" ;;
    copilot) env AGENTBAR_HOME="$HOME/.agentbar" AGENTBAR_AGENT=copilot "$@" "$NODE" "${pre[@]+"${pre[@]}"}" "$PERM" \
               <<<"${PAYLOAD:-$COPILOT_EVENT}" >"$HOME/out.json" ;;
    codex)   env AGENTBAR_HOME="$HOME/.agentbar" "$@" "$NODE" "${pre[@]+"${pre[@]}"}" "$SHIM" permission.js \
               <<<"${PAYLOAD:-$CODEX_EVENT}" >"$HOME/out.json" ;;
  esac
}

# The pid of the hook that is waiting — read from its own request file, which is
# where the protocol says it lives, so a wrapper process cannot be signalled by
# mistake.
hook_pid() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hookPid"])' \
    "$HOME/.agentbar/requests.d/$REQ" 2>/dev/null
}

# Every failure path's stdout is kept, so the last check can search all of it.
OUTS="$TESTROOT/outs"; mkdir -p "$OUTS"; NOUT=0
falls() { # falls "Pn label" — the run that just ended wrote nothing at all
  NOUT=$((NOUT + 1))
  cp "$HOME/out.json" "$OUTS/$NOUT" 2>/dev/null || : >"$OUTS/$NOUT"
  contract "$1" '[ ! -s "$HOME/out.json" ]'
}

# A pgrep that never finds the app, so the hook's real liveness check runs on
# watcher.json alone, and a copy of AgentBar running on this machine answers for
# nothing here.
NOPGREP="$TESTROOT/nopgrep"; mkdir -p "$NOPGREP"
printf '#!/bin/sh\nexit 1\n' >"$NOPGREP/pgrep"; chmod +x "$NOPGREP/pgrep"
heartbeat() { printf '{"pid":1,"ts":%s}' "${1:-$(date +%s)}" >"$HOME/.agentbar/watcher.json"; }

# --- controls: the harness can see an allow when one is given ------------------
# Without these, a hook that broke and printed nothing at all would pass every
# clause below.
for d in $DIALECTS; do
  fresh_home
  hook "$d" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT &
  w=$!; wait_req
  printf '{"behavior":"allow"}' >"$HOME/.agentbar/answers.d/$REQ"
  wait "$w"
  check "control $d: a clicked allow is an allow" 'grep -q "\"behavior\":\"allow\"" "$HOME/out.json"'
done

for d in $DIALECTS; do
  N="$(name_of "$d")"

  # --- P1 the app is not running ------------------------------------------------
  fresh_home
  hook "$d" AGENTBAR_FORCE_APP=0
  falls "P1 $d: no frontend"
  # The real check: no app process, no heartbeat — and an allow waiting under the
  # request's own name, which nothing may read when nobody is there.
  fresh_home
  [ -n "$N" ] && printf '{"behavior":"allow"}' >"$HOME/.agentbar/answers.d/$N"
  hook "$d" PATH="$NOPGREP:$PATH"
  falls "P1 $d: no app process, no heartbeat"

  # --- P2 the app quits mid-wait ------------------------------------------------
  fresh_home
  heartbeat
  hook "$d" PATH="$NOPGREP:$PATH" AGENTBAR_APPROVAL_TIMEOUT=30 &
  w=$!; wait_req
  rm -f "$HOME/.agentbar/watcher.json"
  start=$(date +%s); wait "$w"; end=$(date +%s)
  falls "P2 $d: frontend quit mid-wait"
  check "P2 $d: noticed within the ~2 s sweep" '[ $((end - start)) -le 5 ]'

  # --- P3 answers.d missing -----------------------------------------------------
  fresh_home
  hook "$d" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$NOBODY &
  w=$!; wait_req
  rm -rf "$HOME/.agentbar/answers.d"
  wait "$w"
  falls "P3 $d: answers.d removed mid-wait"
  fresh_home
  rmdir "$HOME/.agentbar/answers.d"; printf 'not a directory' >"$HOME/.agentbar/answers.d"
  hook "$d" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$NOBODY
  falls "P3 $d: answers.d is a file"
  fresh_home
  rm -rf "$HOME/.agentbar"; printf 'not a directory' >"$HOME/.agentbar"
  hook "$d" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$NOBODY 2>/dev/null
  falls "P3 $d: the state root is a file"

  # --- P4 answers.d / requests.d not writable -----------------------------------
  if [ "$ROOT_USER" = 0 ]; then
    fresh_home
    chmod 555 "$HOME/.agentbar/answers.d"
    hook "$d" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$NOBODY
    chmod 755 "$HOME/.agentbar/answers.d"
    falls "P4 $d: answers.d not writable"
    if [ -n "$N" ]; then
      fresh_home
      printf '{"behavior":"allow"}' >"$HOME/.agentbar/answers.d/$N"
      chmod 555 "$HOME/.agentbar/answers.d"
      hook "$d" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$NOBODY
      chmod 755 "$HOME/.agentbar/answers.d"
      falls "P4 $d: answers.d not writable, a leftover allow in it (F23)"
    fi
    fresh_home
    mkdir -p "$HOME/.agentbar/requests.d"; chmod 555 "$HOME/.agentbar/requests.d"
    hook "$d" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$NOBODY
    chmod 755 "$HOME/.agentbar/requests.d"
    falls "P4 $d: requests.d not writable"
  fi

  # --- P5 a malformed answer ----------------------------------------------------
  # Each is read once and ends the wait: an answer nobody can parse is not one.
  for body in 'junk not json' '' '[]' 'null' '"allow"' '{"behavior":"ALLOW"}' \
              '{"behavior":"allow "}' '{"behavior":["allow"]}' '{"behavior":{"allow":true}}' \
              '{"behavior":null}' '{"decision":"allow"}' '{"permissionDecision":"allow"}'; do
    fresh_home
    hook "$d" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT &
    w=$!; wait_req
    printf '%s' "$body" >"$HOME/.agentbar/answers.d/$REQ"
    wait "$w"
    falls "P5 $d: malformed answer ${body:-<empty>}"
  done
  fresh_home
  hook "$d" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT &
  w=$!; wait_req
  mkdir "$HOME/.agentbar/answers.d/$REQ"
  wait "$w"
  falls "P5 $d: the answer is a directory"

  # --- P6 an answer for another session -----------------------------------------
  fresh_home
  hook "$d" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$NOBODY &
  w=$!; wait_req
  for other in "othersess-p1.json" "codex-othersess-t1.json" "ctsess-p2.json" \
               "codex-ctsess-t2.json" "${REQ%.json}.json.tmp" "ctsess.json"; do
    [ "$other" = "$REQ" ] || printf '{"behavior":"allow"}' >"$HOME/.agentbar/answers.d/$other"
  done
  wait "$w"
  falls "P6 $d: allows under every other name"

  # --- P7 a stale answer: left under this name before the request existed -------
  if [ -n "$N" ]; then
    fresh_home
    printf '{"behavior":"allow"}' >"$HOME/.agentbar/answers.d/$N"
    hook "$d" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$NOBODY
    falls "P7 $d: a leftover allow from before the request"
    fresh_home
    printf '{"behavior":"always","rule":{"type":"addRules"}}' >"$HOME/.agentbar/answers.d/$N"
    hook "$d" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$NOBODY
    falls "P7 $d: a leftover always from before the request"
  fi

  # --- P8 a duplicate answer: the second click lands after the first ended it ---
  if [ -n "$N" ]; then
    fresh_home
    hook "$d" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT &
    w=$!; wait_req
    printf '{"behavior":"deny"}' >"$HOME/.agentbar/answers.d/$REQ"
    wait "$w"
    check "P8 $d: the first answer was the deny" 'grep -q "\"behavior\":\"deny\"" "$HOME/out.json"'
    printf '{"behavior":"allow"}' >"$HOME/.agentbar/answers.d/$N"   # the late duplicate
    hook "$d" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$NOBODY  # next tool, same name
    falls "P8 $d: the duplicate never answers the next request"
  fi

  # --- P9 an answer for another request under the same name ---------------------
  fresh_home
  hook "$d" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=3 &
  w=$!; wait_req
  printf '{"behavior":"allow","hookPid":999999}' >"$HOME/.agentbar/answers.d/$REQ"
  sleep 0.5
  check "P9 $d: swallowed, still waiting" '[ ! -e "$HOME/.agentbar/answers.d/$REQ" ] && kill -0 "$(hook_pid)" 2>/dev/null'
  wait "$w"
  falls "P9 $d: an answer naming another hook"
  # The request changed hands: a successor hook owns the file name now.
  fresh_home
  hook "$d" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT &
  w=$!; wait_req
  python3 - "$HOME/.agentbar/requests.d/$REQ" <<'PY'
import json, sys
f = sys.argv[1]; d = json.load(open(f)); d["hookPid"] = 999999; json.dump(d, open(f, "w"))
PY
  printf '{"behavior":"allow"}' >"$HOME/.agentbar/answers.d/$REQ"
  wait "$w"
  falls "P9 $d: the request is a successor's"

  # --- P10 a version or verb this hook does not know ----------------------------
  for body in '{"v":2,"behavior":"approve"}' '{"behavior":"grant"}' '{"behavior":"yes"}' \
              '{"v":2,"behavior":"defer"}' '{"behavior":"defer"}' '{"behavior":"answer","answers":[["A"]]}'; do
    fresh_home
    hook "$d" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT &
    w=$!; wait_req
    printf '%s' "$body" >"$HOME/.agentbar/answers.d/$REQ"
    wait "$w"
    falls "P10 $d: unknown verb $body"
  done

  # --- P11 a rules file nobody can read -----------------------------------------
  # The hook never reads rules.json — only the app applies rules, and it voids a
  # file it cannot read whole (RulesStoreTests, F16/F17/F20). What is asserted here
  # is the hook's half: no rules file, however wrong, answers anything by itself.
  for rules in 'not json' '{"v":2,"rules":[{"id":"r","decision":"allow","shape":"bash:echo","cwd":"","mode":"on"}]}' \
               '{"v":1,"rules":[{"id":"r","decision":"allow","shape":"bash:echo","cwd":"/tmp/ct","mode":"loud"}]}' \
               '{"v":1,"rules":[{"id":"r","decision":"allow","shape":"bash:echo","cwd":"/tmp/ct","mode":"on"},]}' \
               'unreadable'; do
    fresh_home
    if [ "$rules" = unreadable ]; then
      printf '{"v":1,"rules":[]}' >"$HOME/.agentbar/rules.json"; chmod 000 "$HOME/.agentbar/rules.json"
    else
      printf '%s' "$rules" >"$HOME/.agentbar/rules.json"
    fi
    hook "$d" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$NOBODY
    chmod 644 "$HOME/.agentbar/rules.json" 2>/dev/null
    falls "P11 $d: rules.json ${rules:0:24}…"
  done

  # --- P12 the wait times out ---------------------------------------------------
  fresh_home
  start=$(date +%s)
  hook "$d" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$NOBODY
  end=$(date +%s)
  falls "P12 $d: nobody answers"
  check "P12 $d: gives up on time" '[ $((end - start)) -le 5 ]'
  check "P12 $d: takes its request with it" '[ -z "$(ls "$HOME/.agentbar/requests.d")" ]'
  for bad in 0 -1 abc; do  # a timeout nobody can read is the default, not "forever" or "now-and-allow"
    fresh_home
    hook "$d" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$bad &
    w=$!; wait_req; sleep 0.5
    check "P12 $d: timeout '$bad' still waits" 'kill -0 "$(hook_pid)" 2>/dev/null'
    kill -TERM "$(hook_pid)" 2>/dev/null; wait "$w"
    falls "P12 $d: timeout '$bad', ended"
  done

  # --- P13 a full disk ----------------------------------------------------------
  fresh_home
  PRELOAD="$ENOSPC" hook "$d" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$NOBODY
  falls "P13 $d: every write fails ENOSPC"
  check "P13 $d: no request half-written" '[ -z "$(ls "$HOME/.agentbar/requests.d" 2>/dev/null)" ]'

  # --- P14 the clock is wrong, or moves -----------------------------------------
  fresh_home
  start=$(date +%s)
  PRELOAD="$CLOCK" hook "$d" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=30 \
    CLOCK_JUMP_AFTER_MS=500 CLOCK_JUMP_MS=$((365 * 86400 * 1000))
  end=$(date +%s)
  falls "P14 $d: the clock jumps a year forward mid-wait"
  check "P14 $d: forward jump ends the wait, it does not answer it" '[ $((end - start)) -le 5 ]'
  # Backwards: the deadline recedes, but the liveness sweep counts poll ticks, not
  # clock time, so a frontend that quits is still noticed.
  fresh_home
  heartbeat
  PRELOAD="$CLOCK" hook "$d" PATH="$NOPGREP:$PATH" AGENTBAR_APPROVAL_TIMEOUT=30 \
    CLOCK_JUMP_AFTER_MS=300 CLOCK_JUMP_MS=$((-365 * 86400 * 1000)) &
  w=$!; wait_req
  rm -f "$HOME/.agentbar/watcher.json"
  start=$(date +%s); wait "$w"; end=$(date +%s)
  falls "P14 $d: the clock jumps a year back, then the frontend quits"
  check "P14 $d: backward jump still notices the quit" '[ $((end - start)) -le 5 ]'
  # A heartbeat stamped by a clock ahead of this one reads as fresh for too long:
  # the hook waits on, nobody answers, and the wait still ends in nothing.
  fresh_home
  heartbeat $(( $(date +%s) + 86400 ))
  hook "$d" PATH="$NOPGREP:$PATH" AGENTBAR_APPROVAL_TIMEOUT=$NOBODY
  falls "P14 $d: a heartbeat from the future"
  fresh_home
  PRELOAD="$CLOCK" hook "$d" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$NOBODY CLOCK_SKEW_MS=$((-20 * 365 * 86400 * 1000))
  falls "P14 $d: the whole clock twenty years behind"

  # --- P15 the hook is killed ---------------------------------------------------
  for sig in TERM INT HUP KILL; do
    fresh_home
    # The subshell's stderr is where bash announces the signal as a death; mute it.
    ( hook "$d" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$ANSWER_TIMEOUT ) 2>/dev/null &
    w=$!; wait_req
    kill -"$sig" "$(hook_pid)" 2>/dev/null
    wait "$w" 2>/dev/null
    falls "P15 $d: SIG$sig"
    # The card it left (SIGKILL runs no cleanup) is answered after it died; the
    # next tool's hook, same name, must not take that answer as its own.
    if [ "$sig" = KILL ] && [ -n "$N" ]; then
      printf '{"behavior":"allow"}' >"$HOME/.agentbar/answers.d/$N"
      hook "$d" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$NOBODY
      falls "P15 $d: the dead hook's card answered, next hook same name"
    fi
  done
done

# --- P16 the Codex shim cannot tell what to run --------------------------------
for args in "" "../claude/permission.js" "permission" "/abs/permission.js" "nosuch.js"; do
  fresh_home
  # shellcheck disable=SC2086
  AGENTBAR_HOME="$HOME/.agentbar" AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$NOBODY \
    "$NODE" "$SHIM" $args <<<"$CODEX_EVENT" >"$HOME/out.json" 2>/dev/null
  falls "P16 codex shim: '${args:-<none>}'"
done

# --- P17 questions and plans (Claude Code only) --------------------------------
# A question is answered with labels, a plan by its own dialog: an allow at either
# is swallowed and the wait goes on, so it can only end in silence or a real answer.
for body in '{"behavior":"allow"}' '{"behavior":"always"}' '{"behavior":"answer","answers":[["Nope"]]}' \
            '{"behavior":"answer","answers":[["A","B"]]}' '{"behavior":"answer","answers":"A"}'; do
  fresh_home
  PAYLOAD="$QUESTION_EVENT" hook claude AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$NOBODY &
  w=$!; wait_req
  printf '%s' "$body" >"$HOME/.agentbar/answers.d/$REQ"
  wait "$w"
  falls "P17 question: $body"
done
for body in '{"behavior":"allow"}' '{"behavior":"always"}'; do
  fresh_home
  PAYLOAD="$PLAN_EVENT" hook claude AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=$NOBODY &
  w=$!; wait_req
  printf '%s' "$body" >"$HOME/.agentbar/answers.d/$REQ"
  wait "$w"
  falls "P17 plan: $body"
done
# Answered in the terminal: the row moves on and the hook retires without a word.
for ev in "$QUESTION_EVENT" "$PLAN_EVENT"; do
  fresh_home
  PAYLOAD="$ev" hook claude AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=30 &
  w=$!; wait_req
  printf '{"sessionId":"ctsess","agent":"claude","state":"tool","ts":1}' >"$HOME/.agentbar/state.d/ctsess.json"
  start=$(date +%s); wait "$w"; end=$(date +%s)
  falls "P17 answered in the terminal (${REQ%.json})"
  check "P17 retires within the sweep (${REQ%.json})" '[ $((end - start)) -le 5 ]'
done

# --- B1 the status bridges cannot be answered through --------------------------
# None of them reads answers.d. Two must print a fixed "carry on" because their
# host fails closed (Antigravity's agy, Cline); the rest print nothing. Either way
# the output is the same whether an allow is waiting or not, app up or down —
# which is what "AgentBar answers nothing through it" means.
FAKECLI="$TESTROOT/fakecli"; printf '#!/bin/sh\nexit 0\n' >"$FAKECLI"; chmod +x "$FAKECLI"
# A bridge that sees no frontend starts one with `open`; this one starts nothing.
FAKEBIN="$TESTROOT/fakebin"; mkdir -p "$FAKEBIN"
printf '#!/bin/sh\nexit 0\n' >"$FAKEBIN/open"; chmod +x "$FAKEBIN/open"
bridge() { # bridge LABEL EXPECTED SCRIPT [ARG] — payload on $PAYLOAD
  local label="$1" want="$2" script="$3" arg="${4:-}" got1 got2 got3
  fresh_home
  got1="$(AGENTBAR_HOME="$HOME/.agentbar" AGENTBAR_FORCE_APP=0 AGENTBAR_CLI="$FAKECLI" PATH="$FAKEBIN:$PATH" \
            "$NODE" "$script" $arg <<<"$PAYLOAD" 2>/dev/null)"
  for n in ctsess-p1.json codex-ctsess-t1.json cline-ctsess.json ctsess.json; do
    printf '{"behavior":"deny"}' >"$HOME/.agentbar/answers.d/$n"
  done
  got2="$(AGENTBAR_HOME="$HOME/.agentbar" AGENTBAR_FORCE_APP=1 AGENTBAR_CLI="$FAKECLI" PATH="$FAKEBIN:$PATH" \
            "$NODE" "$script" $arg <<<"$PAYLOAD" 2>/dev/null)"
  for n in ctsess-p1.json codex-ctsess-t1.json cline-ctsess.json ctsess.json; do
    printf '{"behavior":"allow"}' >"$HOME/.agentbar/answers.d/$n"
  done
  got3="$(AGENTBAR_HOME="$HOME/.agentbar" AGENTBAR_FORCE_APP=1 AGENTBAR_CLI="$FAKECLI" PATH="$FAKEBIN:$PATH" \
            "$NODE" "$script" $arg <<<"$PAYLOAD" 2>/dev/null)"
  check "B1 $label: prints only its fixed line" '[ "$got1" = "$want" ] && [ "$got2" = "$want" ] && [ "$got3" = "$want" ]'
}
H="$REPO/Scripts/hooks"
PAYLOAD='{"hook_event_name":"preToolUse","conversation_id":"ctsess","tool_name":"Shell","tool_input":{"command":"echo contract"}}' \
  bridge "cursor preToolUse" "" "$H/cursor/cursor.js"
PAYLOAD='{"hook_event_name":"BeforeTool","session_id":"ctsess","tool_name":"run_shell_command","tool_input":{"command":"echo contract"}}' \
  bridge "gemini BeforeTool" "" "$H/gemini/gemini.js"
PAYLOAD='{"conversationId":"ctsess","toolCall":{"name":"run_command"}}' \
  bridge "antigravity PreToolUse" '{"decision":"allow"}' "$H/antigravity/antigravity.js" PreToolUse
PAYLOAD='{"hookName":"PreToolUse","taskId":"ctsess","preToolUse":{"toolName":"execute_command"}}' \
  bridge "cline PreToolUse" '{"cancel":false}' "$H/cline/agentbar.js"
PAYLOAD='{"event":"PreToolUse","session_id":"ctsess","tool_name":"shell"}' \
  bridge "goose PreToolUse" "" "$H/goose/agentbar.js"
PAYLOAD='{"session_id":"ctsess","tool_name":"Bash","tool_input":{"command":"echo contract"}}' \
  bridge "claude update.js pre" "" "$H/claude/update.js" pre
PAYLOAD='{"session_id":"ctsess","cwd":"/tmp/ct"}' \
  bridge "claude lifecycle.js start" "" "$H/claude/lifecycle.js" start

# --- the rules engine's clauses still have their tests -------------------------
# P11's other half lives in Swift. A clause whose test was deleted would leave this
# suite green, so the numbered tests are looked for by name.
for clause in "RuleEngineTests.swift:F15" "RulesStoreTests.swift:F16" "RulesStoreTests.swift:F17" \
              "RuleEngineTests.swift:F18" "RuleEngineTests.swift:F21" "RuleEngineTests.swift:F22"; do
  f="${clause%%:*}"; n="${clause##*:}"
  check "P11/P18 $n is still held by $f" 'grep -q "\*\*$n" "Tests/AgentBarTests/$f"'
done
# F19 and F20 are held by the shared fixtures both halves read (SharedFixtureTests,
# cli-test.sh), not by a numbered test.
check "P18 F19 is still a rule-matching fixture" \
  'grep -q "a leading U+FEFF the reader drops" Tests/Fixtures/rule-matching/cases.json'
check "P11 F20 is still a rules-file fixture" \
  'grep -q "\"a trailing comma\"" Tests/Fixtures/rules-file/cases.json && grep -q "a key written twice in a rule: deny, then allow" Tests/Fixtures/rules-file/cases.json'

# --- the invariant itself, over everything the failure paths printed -----------
check "every failure path was recorded ($NOUT of them)" '[ "$NOUT" -ge 150 ]'
check "no failure path emitted an allow, anywhere" '! grep -l -e allow -e always "$OUTS"/* >/dev/null 2>&1'
check "no failure path emitted anything at all" '[ -z "$(cat "$OUTS"/*)" ]'

summary
