# Remote Allow/Deny Implementation Plan

> Historical working plan, kept as-is for reference — task-runner directives and
> machine-specific paths reflect the original development session. Details have
> since been superseded by shipped work (e.g. Task 4's `approveKeys: nil` for
> Antigravity — it approves via Return since 1.9.0); the normative contract is
> [`docs/protocol.md`](../protocol.md).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Answer agent permission prompts (Allow once / Always allow / Deny / Answer in terminal) straight from the AgentBar menu, per the spec in `docs/specs/2026-07-23-remote-approval-design.md`.

**Architecture:** A blocking `PermissionRequest` hook (`permission.js`) writes a request file to `~/.agentbar/requests.d/` and polls `~/.agentbar/answers.d/` for the user's decision; the app watches `requests.d/`, renders an approval submenu on permission rows, and writes answer files. Non-Claude agents get a best-effort "focus terminal + approval keystroke" backend. Every failure path degrades to today's terminal prompt.

**Tech Stack:** Node.js (hook, zero deps), Swift/AppKit (app, no new deps), bash (hook tests).

**Conventions that bind every task:** English everywhere; Conventional Commits; atomic writes = write tmp file then rename; one file one responsibility; hooks exit fast on every path except the deliberate approval wait.

---

### Task 1: `permission.js` — the blocking approval hook (TDD)

**Files:**
- Create: `Scripts/test/permission-hook-test.sh`
- Create: `Scripts/hooks/claude/permission.js`

- [x] **Step 1: Write the failing test**

Create `Scripts/test/permission-hook-test.sh` (make it executable):

```bash
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
fresh_home() {
  export HOME="$(mktemp -d)"
  mkdir -p "$HOME/.agentbar/answers.d"
}

EVENT='{"session_id":"testsess","prompt_id":"p1","tool_name":"Bash","tool_input":{"command":"git push origin main"},"permission_suggestions":[{"type":"rule","rule":"Bash(git push:*)"}]}'

# 1. allow round-trip
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=5 "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
sleep 0.5
REQ="$(ls "$HOME/.agentbar/requests.d/" 2>/dev/null | head -1)"
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
sleep 0.5
REQ="$(ls "$HOME/.agentbar/requests.d/" | head -1)"
printf '{"behavior":"deny"}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "deny decision on stdout"     'grep -q "\"behavior\":\"deny\"" "$HOME/out.json"'

# 3. always -> allow + rule passthrough
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=5 "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
sleep 0.5
REQ="$(ls "$HOME/.agentbar/requests.d/" | head -1)"
printf '{"behavior":"always","rule":{"type":"rule","rule":"Bash(git push:*)"}}' > "$HOME/.agentbar/answers.d/$REQ"
wait "$hookpid"
check "always returns allow"        'grep -q "\"behavior\":\"allow\"" "$HOME/out.json"'
check "always carries the rule"     'grep -q "git push:" "$HOME/out.json"'

# 4. defer -> silent exit (terminal prompt takes over)
fresh_home
AGENTBAR_FORCE_APP=1 AGENTBAR_APPROVAL_TIMEOUT=5 "$NODE" "$HOOK" <<<"$EVENT" >"$HOME/out.json" &
hookpid=$!
sleep 0.5
REQ="$(ls "$HOME/.agentbar/requests.d/" | head -1)"
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

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

- [x] **Step 2: Run it to make sure it fails**

Run: `chmod +x Scripts/test/permission-hook-test.sh && ./Scripts/test/permission-hook-test.sh`
Expected: FAIL — node cannot find `Scripts/hooks/claude/permission.js` (module not found), non-zero exit.

- [x] **Step 3: Verify one schema detail against the docs**

The hook's output uses the PermissionRequest decision schema. Resolved during implementation: the docs name it `decision.updatedPermissions` (an array; the hook echoes one `permission_suggestions` entry verbatim). Step 4 below already uses it. The rest of the schema (`hookSpecificOutput.hookEventName`, `decision.behavior: "allow"|"deny"`) is already verified.

- [x] **Step 4: Write the hook**

Create `Scripts/hooks/claude/permission.js`:

```js
#!/usr/bin/env node
// Claude Code PermissionRequest -> remote approval from the AgentBar menu.
// Writes a request file, then BLOCKS polling answers.d for the user's decision;
// returning a decision replaces the terminal prompt entirely.
// Deliberate exception to "hooks never block": the session is already waiting on
// a human, and every failure path (no app, app quits, timeout, junk input) exits
// silently so the ordinary terminal prompt appears instead.
// Usage: node permission.js   (PermissionRequest hook JSON on stdin)

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const base = path.join(os.homedir(), ".agentbar");
const stateDir = path.join(base, "state.d");
const reqDir = path.join(base, "requests.d");
const ansDir = path.join(base, "answers.d");

const TIMEOUT_MS = 1000 * Number(process.env.AGENTBAR_APPROVAL_TIMEOUT || 600);
const POLL_MS = 100;

const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64) || "unknown";
const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
const writeAtomic = (file, obj) => {
  const tmp = file + "." + process.pid + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(obj));
  fs.renameSync(tmp, file);
};
const appRunning = () => {
  if (process.env.AGENTBAR_FORCE_APP === "1") return true;
  if (process.env.AGENTBAR_FORCE_APP === "0") return false;
  try { cp.execSync("pgrep -x AgentBar", { stdio: "ignore" }); return true; } catch { return false; }
};

const oneLine = (s, n = 60) => {
  s = String(s || "").split("\n")[0].trim();
  return s.length > n ? s.slice(0, n - 1) + "…" : s;
};

function displaySummary(tool, input) {
  const t = String(tool || "unknown");
  const i = input || {};
  if (t === "Bash") return "Bash: " + oneLine(i.command);
  if (["Edit", "Write", "MultiEdit", "NotebookEdit", "Read"].includes(t))
    return t + ": " + oneLine(i.file_path || i.notebook_path);
  if (t === "WebFetch") return "WebFetch: " + oneLine(i.url);
  if (t === "WebSearch") return "WebSearch: " + oneLine(i.query);
  const m = t.match(/^mcp__(.+?)__(.+)$/);
  if (m) return m[1] + ": " + m[2];
  return t;
}

let raw = "", started = false;
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", run);
setTimeout(run, 1000); // stdin never arrived: bail, never hang the session start

function run() {
  if (started) return; started = true;
  if (!appRunning()) process.exit(0); // nobody to answer -> terminal prompt

  let p = {};
  try { p = JSON.parse(raw || "{}"); } catch {}
  const name = safeId(p.session_id) + "-" + safeId(p.prompt_id || String(process.pid));
  const reqPath = path.join(reqDir, name + ".json");
  const ansPath = path.join(ansDir, name + ".json");
  const display = displaySummary(p.tool_name, p.tool_input);

  let pretty = "";
  try { pretty = JSON.stringify(p.tool_input || {}, null, 2); } catch {}
  if (pretty.length > 4096) pretty = pretty.slice(0, 4096) + "\n…";

  // Rule suggestions come from Claude Code and go back verbatim on "Always allow";
  // the hook never invents permission rules itself.
  const suggestion = Array.isArray(p.permission_suggestions) ? p.permission_suggestions[0] : null;

  fs.mkdirSync(reqDir, { recursive: true });
  fs.mkdirSync(ansDir, { recursive: true });

  // The session row itself shows what's pending, even before the submenu opens.
  try {
    const statePath = path.join(stateDir, safeId(p.session_id) + ".json");
    fs.mkdirSync(stateDir, { recursive: true });
    let prev = {};
    try { prev = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch {}
    writeAtomic(statePath, { ...prev, agent: "claude", state: "permission", label: display,
      sessionId: p.session_id || "", pid: process.ppid, started: true,
      ts: Math.floor(Date.now() / 1000) });
  } catch {}

  writeAtomic(reqPath, {
    sessionId: p.session_id || "", agent: "claude",
    toolName: p.tool_name || "", display, toolInputPretty: pretty,
    ruleSuggestion: suggestion, pid: process.ppid,
    ts: Math.floor(Date.now() / 1000),
  });

  const cleanup = () => {
    try { fs.rmSync(reqPath, { force: true }); } catch {}
    try { fs.rmSync(ansPath, { force: true }); } catch {}
  };
  process.on("exit", cleanup);

  const deadline = Date.now() + TIMEOUT_MS;
  let ticks = 0;
  while (Date.now() < deadline) {
    if (fs.existsSync(ansPath)) {
      let a = {};
      try { a = JSON.parse(fs.readFileSync(ansPath, "utf8")); } catch {}
      const b = a.behavior;
      if (b === "allow" || b === "always") {
        const decision = { behavior: "allow" };
        // Echoing a permission_suggestions entry as updatedPermissions == "always allow".
        if (b === "always" && a.rule) decision.updatedPermissions = [a.rule];
        respond(decision);
      } else if (b === "deny") {
        respond({ behavior: "deny" });
      }
      process.exit(0); // "defer"/junk: silent exit -> terminal prompt
    }
    if (++ticks % 20 === 0 && !appRunning()) process.exit(0); // app quit mid-wait
    sleep(POLL_MS);
  }
  process.exit(0); // timeout -> terminal prompt
}

function respond(decision) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: "PermissionRequest", decision },
  }));
}
```

- [x] **Step 5: Run the tests until green**

Run: `./Scripts/test/permission-hook-test.sh`
Expected: all checks green, 0 failed, exit 0 (20 checks after the review-fix rounds).

- [x] **Step 6: Commit**

```bash
git add Scripts/hooks/claude/permission.js Scripts/test/permission-hook-test.sh
git commit -m "feat: blocking PermissionRequest hook for remote approval"
```

---

### Task 2: Register the hook in `HookInstaller`

**Files:**
- Modify: `Sources/AgentBar/HookInstaller.swift:72-95` (the `events` array and rule building inside `installClaude()`)

- [x] **Step 1: Support per-event timeouts and swap the PermissionRequest command**

In `installClaude()`, replace the `events` declaration and the loop body that builds `rule` with:

```swift
        let events: [(event: String, cmd: String, matcher: Bool, timeout: Int?)] = [
            ("SessionStart",     "\"\(node)\" \"\(dir)/lifecycle.js\" start", false, nil),
            ("SessionEnd",       "\"\(node)\" \"\(dir)/lifecycle.js\" end", false, nil),
            ("UserPromptSubmit", "\"\(node)\" \"\(dir)/update.js\" prompt", false, nil),
            ("PreToolUse",       "\"\(node)\" \"\(dir)/update.js\" pre", true, nil),
            ("PostToolUse",      "\"\(node)\" \"\(dir)/update.js\" post", true, nil),
            ("Notification",     "\"\(node)\" \"\(dir)/update.js\" notify", false, nil),
            // Blocking approval hook: its own wait is 600s, so give Claude Code slack.
            ("PermissionRequest","\"\(node)\" \"\(dir)/permission.js\"", true, 630),
            ("Stop",             "\"\(node)\" \"\(dir)/update.js\" stop", false, nil),
        ]

        for e in events {
            var rules = hooks[e.event] as? [[String: Any]] ?? []
            // Drop any earlier AgentBar entries (path match), keep everything else untouched.
            rules.removeAll { rule in
                ((rule["hooks"] as? [[String: Any]]) ?? []).contains { cmd in
                    (cmd["command"] as? String)?.contains("/.agentbar/hooks/claude/") == true
                }
            }
            var hookEntry: [String: Any] = ["type": "command", "command": e.cmd]
            if let t = e.timeout { hookEntry["timeout"] = t }
            var rule: [String: Any] = ["hooks": [hookEntry]]
            if e.matcher { rule["matcher"] = "*" }
            rules.append(rule)
            hooks[e.event] = rules
        }
```

(The existing path-match removal already deletes the old `update.js permreq` entry on upgrade; `update.js` keeps its `permreq` branch as dead code tolerance — no change there.)

- [x] **Step 2: Build**

Run: `./Scripts/build.sh`
Expected: `Built build/AgentBar.app` (permission.js is bundled automatically by the `cp -R Scripts/hooks` line).

- [x] **Step 3: Commit**

```bash
git add Sources/AgentBar/HookInstaller.swift
git commit -m "feat: install permission.js hook with extended timeout"
```

---

### Task 3: App model layer — `ApprovalRequest`, `RequestStore`, `AnswerWriter`

**Files:**
- Create: `Sources/AgentBar/ApprovalRequest.swift`
- Create: `Sources/AgentBar/RequestStore.swift`
- Create: `Sources/AgentBar/AnswerWriter.swift`

- [x] **Step 1: Create `Sources/AgentBar/ApprovalRequest.swift`**

```swift
import Foundation

/// One pending permission request, decoded from `~/.agentbar/requests.d/*.json`
/// (written by the blocking permission hook while it waits for the user's answer).
struct ApprovalRequest {
    let fileName: String            // shared key: the answer file must use the same name
    let sessionId: String
    let agentID: String
    let toolName: String
    let display: String             // one line, e.g. "Bash: git push origin main"
    let toolInputPretty: String     // full tool input for the tooltip
    let ruleSuggestion: [String: Any]?  // Claude-supplied; passed back verbatim on Always allow
    let pid: Int32                  // the waiting hook's parent (the claude process)
    let hookPid: Int32              // the waiting hook itself; primary liveness handle
    let ts: TimeInterval

    init?(fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        fileName        = fileURL.lastPathComponent
        sessionId       = o["sessionId"] as? String ?? ""
        agentID         = o["agent"] as? String ?? "claude"
        toolName        = o["toolName"] as? String ?? ""
        display         = o["display"] as? String ?? (o["toolName"] as? String ?? "request")
        toolInputPretty = o["toolInputPretty"] as? String ?? ""
        ruleSuggestion  = o["ruleSuggestion"] as? [String: Any]
        pid             = Int32(o["pid"] as? Int ?? 0)
        hookPid         = Int32(o["hookPid"] as? Int ?? 0)
        ts              = o["ts"] as? TimeInterval ?? 0
    }

    /// Text of the rule "Always allow" would persist — shown verbatim in the menu item.
    var ruleDescription: String? {
        guard let r = ruleSuggestion else { return nil }
        if let s = r["rule"] as? String { return s }
        guard let data = try? JSONSerialization.data(withJSONObject: r) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
```

- [x] **Step 2: Create `Sources/AgentBar/RequestStore.swift`**

```swift
import Foundation

/// Watches `~/.agentbar/requests.d/` — one JSON per permission request a blocking
/// hook is currently waiting on. Same folder-is-the-protocol pattern as SessionStore.
final class RequestStore {
    static let requestsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agentbar/requests.d", isDirectory: true)
    static let answersDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agentbar/answers.d", isDirectory: true)

    /// Longest a request can be pending: the hook's 600s wait plus slack.
    private static let maxAge: TimeInterval = 660

    private(set) var requests: [ApprovalRequest] = []
    var onChange: (() -> Void)?

    private var dirSource: DispatchSourceFileSystemObject?
    private var lastSnapshot: [String] = []

    func start() {
        try? FileManager.default.createDirectory(at: Self.requestsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.answersDir, withIntermediateDirectories: true)
        watchDirectory()
        refresh()
    }

    private func watchDirectory() {
        dirSource?.cancel()
        let fd = open(Self.requestsDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in
            self?.refresh()
            if src.data.contains(.delete) || src.data.contains(.rename) {
                self?.watchDirectory() // directory replaced: re-arm on the new inode
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirSource = src
    }

    func refresh() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Self.requestsDir, includingPropertiesForKeys: nil)) ?? []
        var found: [ApprovalRequest] = []
        for url in files where url.pathExtension == "json" {
            guard let r = ApprovalRequest(fileURL: url) else { continue }
            // Orphans: the waiting hook died (SIGKILL leaves no cleanup), or expired.
            let watched = r.hookPid > 0 ? r.hookPid : r.pid
            let dead = watched > 0 && kill(watched, 0) != 0 && errno == ESRCH
            let expired = r.ts > 0 && Date().timeIntervalSince1970 - r.ts > Self.maxAge
            if dead || expired {
                try? fm.removeItem(at: url)
                continue
            }
            found.append(r)
        }
        found.sort { $0.ts > $1.ts }
        pruneOrphanAnswers(liveNames: Set(found.map(\.fileName)))

        let snapshot = found.map(\.fileName)
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        requests = found
        onChange?()
    }

    func requests(for sessionId: String) -> [ApprovalRequest] {
        requests.filter { $0.sessionId == sessionId }
    }

    /// Answers nobody consumed (hook died between click and pickup): delete after 60s.
    private func pruneOrphanAnswers(liveNames: Set<String>) {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Self.answersDir,
                     includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files where !liveNames.contains(url.lastPathComponent) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(modified) > 60 {
                try? fm.removeItem(at: url)
            }
        }
    }
}
```

- [x] **Step 3: Create `Sources/AgentBar/AnswerWriter.swift`**

```swift
import Foundation

/// Writes the user's decision for a pending request; the blocking hook polls for it.
/// The answer file name must equal the request's so the hook finds its own answer.
enum AnswerWriter {
    /// behavior: "allow" | "always" | "deny" | "defer". The hook maps them to the
    /// PermissionRequest decision schema; "defer" means fall back to the terminal prompt.
    static func write(behavior: String, rule: [String: Any]? = nil, for request: ApprovalRequest) {
        let fm = FileManager.default
        try? fm.createDirectory(at: RequestStore.answersDir, withIntermediateDirectories: true)
        var obj: [String: Any] = ["behavior": behavior]
        if let rule { obj["rule"] = rule }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let final = RequestStore.answersDir.appendingPathComponent(request.fileName)
        let tmp = RequestStore.answersDir.appendingPathComponent(
            request.fileName + ".\(ProcessInfo.processInfo.processIdentifier).tmp")
        do {
            try data.write(to: tmp)
            _ = try fm.replaceItemAt(final, withItemAt: tmp) // rename: atomic for the poller
        } catch {
            try? fm.removeItem(at: tmp)
        }
    }
}
```

- [x] **Step 4: Build**

Run: `./Scripts/build.sh`
Expected: `Built build/AgentBar.app`, no warnings about these files.

- [x] **Step 5: Commit**

```bash
git add Sources/AgentBar/ApprovalRequest.swift Sources/AgentBar/RequestStore.swift Sources/AgentBar/AnswerWriter.swift
git commit -m "feat: request/answer file model for remote approval"
```

---

### Task 4: Keystroke backend for non-Claude agents

**Files:**
- Modify: `Sources/AgentBar/Agents.swift` (add `approveKeys` to the struct and every entry)
- Create: `Sources/AgentBar/KeystrokeApprover.swift`

- [x] **Step 1: Add the per-agent approval keystroke to `Agents.swift`**

Add the property after `let open: OpenAction`:

```swift
    /// Virtual key codes posted to approve a permission prompt in the agent's own UI.
    /// nil = no keystroke backend (Claude has the native hook path; Antigravity is an IDE).
    let approveKeys: [CGKeyCode]?
```

And extend each entry in `Agent.all` (keeping everything else identical):

```swift
        Agent(id: "claude", ..., open: .bundle("com.anthropic.claudefordesktop"),
              approveKeys: nil),
        Agent(id: "codex", ..., open: .terminal,
              approveKeys: [36]),          // Return — Codex prompts default to approve
        Agent(id: "copilot", ..., open: .terminal,
              approveKeys: [16, 36]),      // "y" then Return
        Agent(id: "antigravity", ..., open: .appNamed("Antigravity"),
              approveKeys: nil),
```

(`...` = the existing arguments, unchanged. Key codes are the initial mapping; the E2E task verifies them against each agent's real prompt and this is the only place to adjust.)

- [x] **Step 2: Create `Sources/AgentBar/KeystrokeApprover.swift`**

```swift
import Cocoa

/// Best-effort approval for agents without decision hooks (Codex, Copilot): bring
/// the session's terminal forward, then post the agent's approval keystroke.
/// Requires the Accessibility permission; the menu labels the action honestly
/// ("sends keystroke") because delivery to the right tab is not guaranteed.
enum KeystrokeApprover {
    static var trusted: Bool { AXIsProcessTrusted() }

    /// Shows the system dialog directing the user to Privacy & Security ▸ Accessibility.
    static func requestAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func approve(session: Session, keys: [CGKeyCode]) {
        StatusItemController.focusTerminal(named: session.termProgram)
        // Give the terminal time to come forward before typing into it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            for key in keys { post(key) }
        }
    }

    private static func post(_ key: CGKeyCode) {
        let src = CGEventSource(stateID: .combinedSessionState)
        CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap)
    }
}
```

- [x] **Step 3: Build**

Run: `./Scripts/build.sh`
Expected: `Built build/AgentBar.app`.

- [x] **Step 4: Commit**

```bash
git add Sources/AgentBar/Agents.swift Sources/AgentBar/KeystrokeApprover.swift
git commit -m "feat: keystroke approval backend for non-Claude agents"
```

---

### Task 5: Menu UI + controller wiring

**Files:**
- Modify: `Sources/AgentBar/MenuBuilder.swift` (populate signature, permission-row submenu)
- Modify: `Sources/AgentBar/StatusItemController.swift` (RequestStore, new actions)

- [x] **Step 1: Add the payload class and submenu builder to `MenuBuilder.swift`**

At the bottom of the file (outside the `enum MenuBuilder` block), add:

```swift
/// Payload carried by approval menu items (NSMenuItem.representedObject needs a class).
final class ApprovalAction: NSObject {
    let request: ApprovalRequest
    let behavior: String   // "allow" | "always" | "deny" | "defer"
    let session: Session
    init(request: ApprovalRequest, behavior: String, session: Session) {
        self.request = request
        self.behavior = behavior
        self.session = session
    }
}
```

Change the `populate` signature to accept requests:

```swift
    static func populate(_ menu: NSMenu, sessions: [Session], requests: [ApprovalRequest],
                         controller: StatusItemController) {
```

In the session loop, after `item.toolTip = s.cwd`, attach the submenu for permission rows:

```swift
                if s.state == .permission {
                    item.submenu = approvalSubmenu(
                        for: s, requests: requests.filter { $0.sessionId == s.id },
                        controller: controller)
                }
```

And add the two builders inside `enum MenuBuilder`:

```swift
    /// Submenu for a session waiting on a permission prompt. Claude sessions get real
    /// Allow/Deny (the hook is blocked waiting for our answer file); agents without
    /// request files get the best-effort keystroke path.
    private static func approvalSubmenu(for s: Session, requests: [ApprovalRequest],
                                        controller: StatusItemController) -> NSMenu {
        let menu = NSMenu()
        if requests.isEmpty {
            return keystrokeSubmenu(for: s, controller: controller)
        }
        for (i, r) in requests.enumerated() {
            if i > 0 { menu.addItem(.separator()) }

            let what = NSMenuItem(title: r.display, action: nil, keyEquivalent: "")
            what.isEnabled = false
            what.toolTip = r.toolInputPretty
            menu.addItem(what)

            menu.addItem(actionItem("✓ Allow once", ApprovalAction(request: r, behavior: "allow", session: s),
                                    controller: controller))
            if let rule = r.ruleDescription {
                menu.addItem(actionItem("✓ Always allow \u{201C}\(rule)\u{201D}",
                                        ApprovalAction(request: r, behavior: "always", session: s),
                                        controller: controller))
            }
            menu.addItem(actionItem("✕ Deny", ApprovalAction(request: r, behavior: "deny", session: s),
                                    controller: controller))
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("Answer in terminal instead",
                                ApprovalAction(request: requests[0], behavior: "defer", session: s),
                                controller: controller))
        return menu
    }

    private static func keystrokeSubmenu(for s: Session, controller: StatusItemController) -> NSMenu {
        let menu = NSMenu()
        let agent = Agent.byID(s.agentID)
        let note = NSMenuItem(title: "Can't show the request for \(agent.name)",
                              action: nil, keyEquivalent: "")
        note.isEnabled = false
        menu.addItem(note)
        if agent.approveKeys != nil {
            let title = KeystrokeApprover.trusted
                ? "Approve in terminal (sends keystroke)" : "Grant Accessibility…"
            let item = NSMenuItem(title: title,
                                  action: #selector(StatusItemController.keystrokeApproveClicked(_:)),
                                  keyEquivalent: "")
            item.target = controller
            item.representedObject = s
            menu.addItem(item)
        }
        let open = NSMenuItem(title: "Open in terminal",
                              action: #selector(StatusItemController.sessionRowClicked(_:)),
                              keyEquivalent: "")
        open.target = controller
        open.representedObject = s
        menu.addItem(open)
        return menu
    }

    private static func actionItem(_ title: String, _ payload: ApprovalAction,
                                   controller: StatusItemController) -> NSMenuItem {
        let item = NSMenuItem(title: title,
                              action: #selector(StatusItemController.approvalActionClicked(_:)),
                              keyEquivalent: "")
        item.target = controller
        item.representedObject = payload
        return item
    }
```

- [x] **Step 2: Wire `RequestStore` and the actions into `StatusItemController.swift`**

Add the store next to the session store (line 7):

```swift
    private let requestStore = RequestStore()
```

In `start()`, after `store.start()`:

```swift
        requestStore.start()
```

Update `menuNeedsUpdate` to refresh and pass requests:

```swift
    func menuNeedsUpdate(_ menu: NSMenu) {
        store.refresh()
        requestStore.refresh()
        MenuBuilder.populate(menu, sessions: sessions, requests: requestStore.requests,
                             controller: self)
    }
```

Add the two actions in the Actions section:

```swift
    @objc func approvalActionClicked(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? ApprovalAction else { return }
        switch a.behavior {
        case "always":
            AnswerWriter.write(behavior: "always", rule: a.request.ruleSuggestion, for: a.request)
        case "defer":
            AnswerWriter.write(behavior: "defer", for: a.request)
            // The prompt is about to appear in the terminal: bring it forward.
            Self.focusTerminal(named: a.session.termProgram)
        default:
            AnswerWriter.write(behavior: a.behavior, for: a.request)
        }
    }

    @objc func keystrokeApproveClicked(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? Session,
              let keys = Agent.byID(s.agentID).approveKeys else { return }
        if KeystrokeApprover.trusted {
            KeystrokeApprover.approve(session: s, keys: keys)
        } else {
            KeystrokeApprover.requestAccess()
        }
    }
```

- [x] **Step 3: Build**

Run: `./Scripts/build.sh`
Expected: `Built build/AgentBar.app`.

- [x] **Step 4: Manual harness — fake request drives the real menu**

```bash
open build/AgentBar.app
SID="harness$$"
NOW=$(date +%s)
cat > ~/.agentbar/state.d/$SID.json <<EOF
{"agent":"claude","state":"permission","label":"Bash: rm -rf node_modules","project":"harness","cwd":"$HOME","sessionId":"$SID","entrypoint":"cli","term_program":"WarpTerminal","pid":$$,"started":true,"ts":$NOW}
EOF
cat > ~/.agentbar/requests.d/$SID-p1.json <<EOF
{"sessionId":"$SID","agent":"claude","toolName":"Bash","display":"Bash: rm -rf node_modules","toolInputPretty":"{\n  \"command\": \"rm -rf node_modules\"\n}","ruleSuggestion":{"type":"rule","rule":"Bash(rm -rf node_modules)"},"pid":$$,"ts":$NOW}
EOF
```

Verify by hand: menu shows the yellow `harness` row → submenu shows the command header, `✓ Allow once`, `✓ Always allow "Bash(rm -rf node_modules)"`, `✕ Deny`, `Answer in terminal instead`. Click **Allow once**, then:

```bash
cat ~/.agentbar/answers.d/$SID-p1.json   # expect: {"behavior":"allow"}
rm -f ~/.agentbar/state.d/$SID.json ~/.agentbar/requests.d/$SID-p1.json ~/.agentbar/answers.d/$SID-p1.json
```

- [x] **Step 5: Commit**

```bash
git add Sources/AgentBar/MenuBuilder.swift Sources/AgentBar/StatusItemController.swift
git commit -m "feat: Allow/Deny approval submenu on permission rows"
```

---

### Task 6: Docs, rule amendment, changelog

**Files:**
- Modify: `CLAUDE.md` (rule 3)
- Modify: `README.md` (feature section)
- Modify: `CHANGELOG.md` (new entry)
- Modify: `docs/specs/2026-07-23-agentbar-design.md` (cross-link line at the top)

- [x] **Step 1: Amend rule 3 in `CLAUDE.md`**

Replace:

```
3. Hooks must never block the host agent: async, atomic writes, exit fast.
```

with:

```
3. Hooks must never block the host agent: async, atomic writes, exit fast.
   Sole exception: `permission.js` blocks while the session is already waiting on
   the human, and must always time out silently to the normal terminal prompt.
```

- [x] **Step 2: Add the README section**

Append to `README.md` (adjust placement to fit the existing structure — after the features list):

```markdown
## Remote Allow/Deny

When a Claude Code session asks for permission, the yellow "needs approval" row in
the menu grows a submenu showing exactly what's requested (e.g. `Bash: git push
origin main`; full input in the tooltip) with **Allow once**, **Always allow
"<rule>"** (only when Claude Code suggests a rule — the literal rule is in the menu
item), **Deny**, and **Answer in terminal instead**. Decisions are returned to
Claude Code through its PermissionRequest hook, so the terminal prompt never
appears; if AgentBar is not running, quits, or you ignore the request for 10
minutes, the prompt shows in the terminal exactly as before.

Codex and Copilot have no decision hooks, so their rows offer *Approve in terminal
(sends keystroke)* — AgentBar focuses the session's terminal and presses the
approval key. This needs the Accessibility permission and is best-effort by design.

Known cosmetic issue: the terminal permission dialog can flash briefly even when
approved from the menu (upstream claude-code #12176).
```

- [x] **Step 3: Changelog entry**

Add at the top of `CHANGELOG.md` under a new version heading (match the file's existing format):

```markdown
## 1.1.0 — 2026-07-23

- Remote Allow/Deny: answer Claude Code permission prompts from the menu bar
  (allow once, always-allow with the suggested rule, deny, or defer to terminal).
- Best-effort keystroke approval for Codex and Copilot sessions (Accessibility).
```

- [x] **Step 4: Cross-link the spec**

In `docs/specs/2026-07-23-agentbar-design.md`, add under the title:

```markdown
> Extended by: [Remote Allow/Deny design](2026-07-23-remote-approval-design.md)
```

- [x] **Step 5: Commit**

```bash
git add CLAUDE.md README.md CHANGELOG.md docs/specs/2026-07-23-agentbar-design.md
git commit -m "docs: remote approval feature docs and rule amendment"
```

---

### Task 7: End-to-end verification (manual, on this machine)

**Files:** none (verification only)

- [x] **Step 1: Refresh the installed hooks**

`./Scripts/build.sh && open build/AgentBar.app` — relaunching copies the new `permission.js` to `~/.agentbar/hooks/claude/` and rewires `~/.claude/settings.json`.

This machine's sessions read `~/.claude-work/settings.json` (CLAUDE_CONFIG_DIR), which HookInstaller does not touch — update it manually:

```bash
python3 - <<'EOF'
import json
p = "/Users/michalstrnadel/.claude-work/settings.json"
d = json.load(open(p))
node = "/opt/homebrew/bin/node"
entry = {"type": "command",
         "command": f'"{node}" "/Users/michalstrnadel/.agentbar/hooks/claude/permission.js"',
         "timeout": 630}
rules = d["hooks"].get("PermissionRequest", [])
rules = [r for r in rules
         if not any("agentbar" in h.get("command", "") for h in r.get("hooks", []))]
rules.append({"matcher": "*", "hooks": [entry]})
d["hooks"]["PermissionRequest"] = rules
json.dump(d, open(p, "w"), indent=2)
print("ok")
EOF
```

- [x] **Step 2: Walk the checklist in a fresh `claude-work` session**

Start a new Claude Code session in any project, then verify each:

1. Ask Claude to run `git status` in a way that triggers a permission prompt → yellow row appears with `Bash: git status`; **Allow once** from the menu → command runs, terminal prompt never appeared (a brief flash is the known upstream race).
2. Trigger another prompt → **Deny** → Claude receives a denial and continues.
3. Trigger a prompt with a rule suggestion → **Always allow** → rule lands in the project's permission config and the next identical command doesn't prompt.
4. Trigger a prompt → **Answer in terminal instead** → terminal comes forward with the normal prompt visible.
5. Trigger a prompt → quit AgentBar while the row is pending → within ~2s the terminal prompt appears.
6. Trigger a prompt → ignore it → after `AGENTBAR_APPROVAL_TIMEOUT` (export a small value like 30 in the session's environment first, or wait 10 min) the terminal prompt appears.
7. Codex (if installed): trigger an approval, use *Approve in terminal (sends keystroke)*; verify the key mapping in `Agents.swift` matches Codex's current prompt, adjust the `approveKeys` entry if not. Same for Copilot.

- [x] **Step 3: Record results**

Note any deviations (especially item 7 key mappings and the item 1 flash) in the PR/commit message; fix `Agents.swift` mappings inline if wrong, rerun, commit as `fix: correct approval keystrokes for <agent>`.

---

## Self-review notes

- Spec coverage: hook + protocol (Task 1), installer (Task 2), app model (Task 3), keystroke backend (Task 4), menu UX incl. rule-in-item-text and tooltips (Task 5), docs/rule/changelog (Task 6), E2E incl. fallback modes (Task 7). Notifications/history remain out of scope per spec.
- The rule-persistence field was verified during Task 1: `decision.updatedPermissions` (array of echoed suggestion entries).
- Type consistency: `ApprovalRequest.fileName`/`ruleSuggestion`/`ruleDescription`, `AnswerWriter.write(behavior:rule:for:)`, `Agent.approveKeys`, `ApprovalAction(request:behavior:session:)` are used with identical spellings across Tasks 3–5.
