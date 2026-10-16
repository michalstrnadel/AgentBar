# Shared by the suites that drive permission.js end to end:
# permission-hook-test.sh and contract-test.sh. Sourced, never run.
#
# It sets up a throwaway root ($TESTROOT, removed on exit), and gives:
#   check NAME COND     eval COND; print ok/FAIL; count it
#   contract NAME COND  the same, named as a fall-through clause
#   fresh_home          a new empty HOME with ~/.agentbar/answers.d in it
#   wait_req            bounded wait for the first request file; sets $REQ
#   summary             the "N passed, M failed" line and the exit status
# and ANSWER_TIMEOUT, the wait for scenarios that do answer the hook.

pass=0; fail=0
check() {
  if eval "$2"; then echo "ok   $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi
}
contract() { # $1 clause, $2 condition
  check "$1 falls through" "$2"
}

# The tests borrow HOME; an inherited CLAUDE_CONFIG_DIR, COPILOT_HOME or
# CODEX_HOME would still point at the runner's real config.
unset CLAUDE_CONFIG_DIR COPILOT_HOME CODEX_HOME AGENTBAR_HOME
# The liveness cases run the hook's real check, which an inherited override would
# pin; every other case sets it on its own command line.
unset AGENTBAR_FORCE_APP
TESTROOT="$(mktemp -d)"
# u+rwx first: a case that took write access away from a directory must not leave
# it behind for the next run to trip over.
trap 'chmod -R u+rwx "$TESTROOT" 2>/dev/null; rm -rf "$TESTROOT"' EXIT

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

# Seconds the hook waits for an answer in tests that DO answer it. Generous on
# purpose: what those tests assert is rule matching and answer handling, not the
# timeout, and the hook exits the moment the answer lands — so a large value
# costs nothing in the happy path. At 5s a loaded CI runner could spend longer
# getting the answer written than the hook was willing to wait, and the test
# failed as if the rule logic were wrong. The deliberate timeout test keeps its
# own short value.
ANSWER_TIMEOUT=30

# Bounded poll for the request file instead of a fixed sleep; sets $REQ.
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

summary() {
  echo "---"
  echo "$pass passed, $fail failed"
  [ "$fail" -eq 0 ]
}
