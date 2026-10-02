import AppKit
import ApplicationServices

/// Why an agent isn't showing up.
///
/// Every integration here fails the same way: silently. A hook that is not wired
/// is not an error, it is an absence; a hook wired to an interpreter that has
/// moved never runs, so it never complains; a config with a stray comma is skipped
/// by the installer with one line in Console.app that nobody reads. The user sees
/// "Codex doesn't appear" and has nowhere to look.
///
/// So: re-derive the whole installation from disk and say what is wrong in the
/// words of the fix. Nothing here writes anything, and nothing runs an agent —
/// it reads configs, stats paths, and probes one directory for writability.
///
/// The catalogue of check ids is `docs/diagnostics.md`; the Linux CLI's `agentbar
/// doctor` answers with the same ids, which is what keeps the two honest.
enum Diagnostics {
    enum Status: String {
        case ok, warn, fail
        /// Not applicable — most often "you don't have this agent installed".
        case skipped
    }

    struct Check {
        let id: String
        let title: String
        let status: Status
        /// What was actually found. Shown under the title.
        var detail: String?
        /// What to do about it. Only set when there is something to do.
        var fix: String?
        /// …and, when the app can do that itself, the thing it would do.
        ///
        /// Only where the fix is genuinely AgentBar's to make. A `chmod` on a
        /// directory the user made unwritable is theirs, and a button that silently
        /// changed permissions on a path in their home would be a worse product than
        /// a sentence telling them the command.
        var repair: Repair?
    }

    /// What a **Fix it** button actually does. Deliberately a short list: three
    /// things AgentBar already does on its own at launch, offered on demand instead
    /// of asking somebody to quit and reopen the app to get them.
    enum Repair: String, Equatable {
        /// Re-run the installer: wiring, the node path that moved, the script copies.
        case reinstallHooks
        /// Create the `~/.agentbar` directories the hooks write into.
        case makeDirectories
        /// Delete the files past their pruning window.
        case sweepOrphans

        var title: String {
            switch self {
            case .reinstallHooks:  return "Re-install hooks"
            case .makeDirectories: return "Create them"
            case .sweepOrphans:    return "Clear them"
            }
        }
    }

    /// Performs a repair and says whether anything threw. Synchronous and slow
    /// enough to matter (`reinstallHooks` probes the login shell for node), so
    /// callers run it off the main thread.
    @discardableResult
    static func apply(_ repair: Repair,
                      base: URL = FileManager.default.homeDirectoryForCurrentUser
                          .appendingPathComponent(".agentbar", isDirectory: true)) -> Bool {
        let fm = FileManager.default
        switch repair {
        case .reinstallHooks:
            HookInstaller.installIfNeeded()
            return true
        case .makeDirectories:
            var ok = true
            for name in ["state.d", "requests.d", "answers.d"] {
                do {
                    try fm.createDirectory(at: base.appendingPathComponent(name, isDirectory: true),
                                           withIntermediateDirectories: true)
                } catch { ok = false }
            }
            return ok
        case .sweepOrphans:
            // The same windows the pruning rules use, so this button removes exactly
            // what a running AgentBar would have removed anyway — never more.
            let now = Date().timeIntervalSince1970
            for (name, maxAge) in [("state.d", 86_400.0), ("requests.d", 660.0), ("answers.d", 60.0)] {
                let dir = base.appendingPathComponent(name, isDirectory: true)
                let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for url in files {
                    let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate?.timeIntervalSince1970 ?? now
                    if now - mtime > maxAge { try? fm.removeItem(at: url) }
                }
            }
            return true
        }
    }

    /// One wired integration, as seen from the outside.
    ///
    /// This mirrors `HookInstaller`'s per-agent knowledge rather than sharing it:
    /// the installer's logic is bespoke per config format, while a diagnosis only
    /// needs "where does it live, and what says it is ours". `DiagnosticsTests`
    /// asserts the list stays in step with `Agent.all` and `Scripts/hooks/`.
    struct Integration {
        let id: String
        let name: String
        /// Any one of these existing means the user has this agent.
        let presence: [String]
        /// Config files we write into.
        let configs: [String]
        /// What identifies our entry inside them.
        let marker: String

        /// Whether this Mac has the agent at all — the question every row for it
        /// starts from, here and on the Agents card in Settings.
        func isPresent(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
            presence.contains { FileManager.default.fileExists(atPath: home.appendingPathComponent($0).path) }
        }
    }

    static let integrations: [Integration] = [
        .init(id: "claude", name: "Claude Code", presence: [".claude"],
              configs: [".claude/settings.json"], marker: "/.agentbar/hooks/claude/"),
        .init(id: "codex", name: "Codex CLI", presence: [".codex"],
              configs: [".codex/config.toml"], marker: "/.agentbar/hooks/codex/"),
        .init(id: "copilot", name: "Copilot CLI", presence: [".copilot"],
              configs: [".copilot/hooks/agentbar.json"], marker: "/.agentbar/hooks/claude/"),
        .init(id: "cursor", name: "Cursor CLI", presence: [".cursor"],
              configs: [".cursor/hooks.json"], marker: "/.agentbar/hooks/cursor/"),
        .init(id: "gemini", name: "Gemini CLI", presence: [".gemini"],
              configs: [".gemini/settings.json"], marker: "/.agentbar/hooks/gemini/"),
        .init(id: "qwen", name: "Qwen Code", presence: [".qwen"],
              configs: [".qwen/settings.json"], marker: "/.agentbar/hooks/claude/"),
        .init(id: "antigravity", name: "Antigravity",
              presence: [".gemini/antigravity", ".gemini/antigravity-cli"],
              configs: [".gemini/antigravity/hooks.json", ".gemini/antigravity-cli/hooks.json"],
              marker: "agentbar"),
        .init(id: "opencode", name: "OpenCode", presence: [".config/opencode"],
              configs: [".config/opencode/plugins/agentbar.js"], marker: "agentbar"),
    ]

    /// Wired and silent for this long is worth saying out loud. Two weeks rather than
    /// a few days: people go on holiday, and an agent you simply did not use must not
    /// be reported as broken.
    static let quietDays = 14

    /// Hook script directories that must have survived the copy into `~/.agentbar/hooks/`.
    static let hookDirs = ["claude", "codex", "cursor", "gemini", "antigravity", "opencode"]
    /// Scripts run through their own shebang rather than an explicit interpreter —
    /// a GUI-launched host inherits the launchd PATH, so `env node` never fires.
    /// Keyed by the agent that runs them: the installer only pins a script when its
    /// agent is installed, so checking the others would flag a healthy machine.
    static let shebangScripts = ["cursor": "cursor/cursor.js",
                                 "antigravity": "antigravity/antigravity.js"]

    /// The last background pass, so the menu can carry the verdict without doing
    /// file I/O every time it opens. Main queue only.
    ///
    /// This is the point of the whole feature: a silent failure that waits to be
    /// looked for is still silent. The row says "2 problems" and the user finds out
    /// without having gone looking.
    private(set) static var failures = 0
    /// Fired after a background pass changes the count, so the menu can redraw.
    static var onVerdict: (() -> Void)?

    /// Runs off the main queue and publishes the failure count. Call after the hook
    /// installer has finished — running it before would report a machine as unwired
    /// while the install that wires it is still in flight.
    static func runInBackground() {
        DispatchQueue.global(qos: .utility).async {
            let found = run().filter { $0.status == .fail }.count
            DispatchQueue.main.async {
                guard found != failures else { return }
                failures = found
                onVerdict?()
            }
        }
    }

    // MARK: - Entry point

    static func run(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                    now: TimeInterval = Date().timeIntervalSince1970) -> [Check] {
        let base = home.appendingPathComponent(".agentbar", isDirectory: true)
        // The agents the user switched off (`WiringPrefs`): unwired on purpose, so
        // nothing about them is a failure or something to repair.
        let off = WiringPrefs.load(home: home)
        var out: [Check] = []
        out += nodeChecks(home: home)
        out += directoryChecks(base: base)
        out += hookScriptChecks(base: base, home: home, off: off)
        out += integrations.flatMap { integrationChecks($0, home: home, base: base, now: now, off: off) }
        out += claudeConfigDirCheck(home: home)
        out += ruleChecks(base: base)
        out += orphanChecks(base: base, now: now)
        out += appChecks()
        return out
    }

    /// The whole report as text, for pasting into an issue — which is the point of
    /// having it at all. No colors, no emoji: it ends up in a code fence.
    static func report(_ checks: [Check]) -> String {
        var lines = ["AgentBar \(appVersion) diagnostics — macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"]
        for c in checks {
            var line = "[\(c.status.rawValue.uppercased().padding(toLength: 7, withPad: " ", startingAt: 0))] \(c.id)  \(c.title)"
            if let d = c.detail { line += "\n              \(d)" }
            if let f = c.fix { line += "\n          fix: \(f)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    // MARK: - node

    private static func nodeChecks(home: URL) -> [Check] {
        let fm = FileManager.default
        guard let node = HookInstaller.stableNodePaths.first(where: { fm.isExecutableFile(atPath: $0) })
                ?? probedNode() else {
            return [Check(id: "node.found", title: "A node interpreter", status: .fail,
                          detail: "No node found in any of \(HookInstaller.stableNodePaths.joined(separator: ", ")) or on the login shell's PATH.",
                          fix: "Install Node 16 or newer, then relaunch AgentBar — every hook is a node script.")]
        }
        var out = [Check(id: "node.found", title: "A node interpreter", status: .ok, detail: node)]

        let stable = HookInstaller.stableNodePaths.contains(node)
        out.append(Check(
            id: "node.stable",
            title: "…at a path that survives an upgrade",
            status: stable ? .ok : .warn,
            detail: stable ? nil : "\(node) looks version-pinned, and it is what gets written into every hook config.",
            fix: stable ? nil : "Link a stable alias — e.g. `ln -sf \(node) /usr/local/bin/node` — and relaunch AgentBar. Otherwise re-run the install after every major node change."))
        return out
    }

    private static func probedNode() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v node"]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }

    // MARK: - The protocol directories

    private static func directoryChecks(base: URL) -> [Check] {
        var out: [Check] = []
        for name in ["state.d", "requests.d", "answers.d"] {
            let dir = base.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue
            guard exists else {
                out.append(Check(id: "dirs.\(name)", title: "~/.agentbar/\(name)", status: .fail,
                                 detail: "Missing.",
                                 fix: "Relaunch AgentBar — it creates these on start. If it comes back, check the permissions on ~/.agentbar.",
                                 repair: .makeDirectories))
                continue
            }
            // Actually write: a directory can exist and still be unusable, and this is
            // the failure hooks hit most often — they have nowhere to report it to.
            let probe = dir.appendingPathComponent(".doctor-\(UUID().uuidString)")
            let wrote = (try? Data().write(to: probe)) != nil
            try? FileManager.default.removeItem(at: probe)
            out.append(Check(id: "dirs.\(name)", title: "~/.agentbar/\(name)",
                             status: wrote ? .ok : .fail,
                             detail: wrote ? nil : "Exists but is not writable — hooks cannot report anything.",
                             fix: wrote ? nil : "chmod u+w \(dir.path)"))
        }
        return out
    }

    /// What a check says about an agent the user turned off in Settings ▸ Diagnostics.
    static let turnedOff = "Turned off by you"

    private static func hookScriptChecks(base: URL, home: URL, off: Set<String> = []) -> [Check] {
        let fm = FileManager.default
        let hooks = base.appendingPathComponent("hooks", isDirectory: true)
        let missing = hookDirs.filter { !fm.fileExists(atPath: hooks.appendingPathComponent($0).path) }
        var out = [Check(
            id: "hooks.copied", title: "Hook scripts installed",
            status: missing.isEmpty ? .ok : .fail,
            detail: missing.isEmpty ? nil : "Missing: \(missing.joined(separator: ", ")).",
            fix: missing.isEmpty ? nil : "Relaunch AgentBar — it re-copies the scripts from the app bundle on every launch.",
            repair: missing.isEmpty ? nil : .reinstallHooks)]

        // Only for agents that are actually here: the installer pins a script when it
        // wires that agent, so a machine without Cursor keeps the bundled shebang and
        // is perfectly healthy.
        let installed = shebangScripts.filter { agent, _ in
            integrations.first { $0.id == agent }?.presence
                .contains { fm.fileExists(atPath: home.appendingPathComponent($0).path) } == true
        }
        // Turned off, the installer stops pinning that script, and that is fine.
        let relevant = installed.filter { !off.contains($0.key) }
        guard !relevant.isEmpty else {
            out.append(Check(id: "hooks.shebang", title: "Scripts that run themselves name a real node",
                             status: .skipped,
                             detail: installed.isEmpty ? "Neither Cursor nor Antigravity is installed here."
                                                       : "\(turnedOff) — AgentBar leaves those agents alone."))
            return out
        }
        let unpinned = relevant.values.filter { rel in
            guard let text = try? String(contentsOf: hooks.appendingPathComponent(rel), encoding: .utf8)
            else { return false }
            return text.hasPrefix("#!/usr/bin/env")
        }.sorted()
        out.append(Check(
            id: "hooks.shebang", title: "Scripts that run themselves name a real node",
            status: unpinned.isEmpty ? .ok : .warn,
            detail: unpinned.isEmpty ? nil : "Still on `#!/usr/bin/env node`: \(unpinned.joined(separator: ", ")).",
            fix: unpinned.isEmpty ? nil : "Relaunch AgentBar. A GUI-launched Cursor inherits the launchd PATH, which usually has no node on it, so `env node` silently never fires."))
        return out
    }

    // MARK: - Per agent

    private static func integrationChecks(_ i: Integration, home: URL, base: URL, now: TimeInterval,
                                          off: Set<String> = []) -> [Check] {
        let fm = FileManager.default
        let present = i.presence.contains { fm.fileExists(atPath: home.appendingPathComponent($0).path) }
        guard present else {
            return [Check(id: "agent.\(i.id)", title: i.name, status: .skipped,
                          detail: "Not installed on this Mac.")]
        }
        // Unwired because the person asked: not a failure, no repair, and no "has
        // not reported for a fortnight" — of course it has not.
        guard !off.contains(i.id) else {
            return [Check(id: "agent.\(i.id)", title: i.name, status: .skipped,
                          detail: "\(turnedOff) — AgentBar leaves its settings alone.")]
        }

        var out: [Check] = []
        var anyWired = false
        for rel in i.configs {
            let url = home.appendingPathComponent(rel)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                // Antigravity has two config files and only one may exist; that is
                // normal, so an absent file is only worth reporting when it is the
                // agent's only one.
                if i.configs.count == 1 {
                    out.append(Check(id: "agent.\(i.id).wired", title: "\(i.name) hooks", status: .fail,
                                     detail: "~/\(rel) does not exist.",
                                     fix: "Relaunch AgentBar to run the installer again."))
                }
                continue
            }
            // Note this is more forgiving than the Linux CLI: Foundation accepts a
            // trailing comma and Node's JSON.parse does not, so a config with one
            // is wired on macOS and skipped on Linux. Reporting it as broken here
            // would contradict the installer standing right next to it.
            if rel.hasSuffix(".json"), (try? JSONSerialization.jsonObject(with: Data(text.utf8))) == nil {
                out.append(Check(id: "agent.\(i.id).parseable", title: "\(i.name) config parses", status: .fail,
                                 detail: "~/\(rel) is not valid JSON, so the installer refuses to touch it — deliberately, it is your file.",
                                 fix: "Fix the JSON (a `//` comment or an unclosed brace is the usual cause), then relaunch AgentBar."))
                continue
            }
            let flat = unescapingSlashes(text)
            if flat.contains(i.marker) { anyWired = true }
            out += interpreterCheck(i, rel: rel, text: flat)
        }
        out.insert(Check(id: "agent.\(i.id).wired", title: "\(i.name) hooks",
                         status: anyWired ? .ok : .fail,
                         detail: anyWired ? nil : "Installed, but AgentBar is not wired into it.",
                         fix: anyWired ? nil : "Relaunch AgentBar; if it stays unwired, ~/\(i.configs[0]) may be unreadable.",
                         repair: anyWired ? nil : .reinstallHooks),
                   at: 0)
        if anyWired { out.append(lastSeenCheck(i, base: base, now: now)) }
        if i.id == "copilot" { out += copilotExecCheck(home: home) }
        if i.id == "codex" { out += codexTrustCheck(home: home) }
        return out
    }

    /// The interpreter named inside a config, which is the thing that rots.
    private static func interpreterCheck(_ i: Integration, rel: String, text: String) -> [Check] {
        let dead = nodePaths(in: text).filter { !FileManager.default.isExecutableFile(atPath: $0) }
        guard !dead.isEmpty else { return [] }
        return [Check(id: "agent.\(i.id).interpreter", title: "\(i.name)'s node still exists",
                      status: .fail,
                      detail: "~/\(rel) points at \(dead[0]), which is gone. The hooks never run, so they never complain.",
                      fix: "Relaunch AgentBar — it repairs the path now. If it comes back after every node upgrade, link a stable alias into /usr/local/bin.",
                      repair: .reinstallHooks)]
    }

    /// `JSONSerialization` escapes forward slashes, so a config AgentBar itself wrote
    /// reads `"\\/.agentbar\\/hooks\\/claude\\/"` on disk. The installers never notice,
    /// because they match against the *parsed* value — but anything searching the raw
    /// text does, and would report every macOS-written config as unwired.
    static func unescapingSlashes(_ text: String) -> String {
        text.replacingOccurrences(of: "\\/", with: "/")
    }

    /// Absolute paths ending in `/node` that a config names.
    static func nodePaths(in text: String) -> [String] {
        let pattern = #""(/[^"]*/node)""#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1))
        }
    }

    private static func copilotExecCheck(home: URL) -> [Check] {
        let url = home.appendingPathComponent(".copilot/hooks/agentbar.json")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let shelled = text.contains("\"bash\":")
        return [Check(id: "copilot.exec", title: "Copilot runs node directly",
                      status: shelled ? .fail : .ok,
                      detail: shelled ? "The hook is wrapped in a shell, so the hook's parent is a shell that exits at once — and that pid is what prunes dead rows. Every Copilot row would disappear on the next refresh." : nil,
                      fix: shelled ? "Delete ~/.copilot/hooks/agentbar.json and relaunch AgentBar." : nil)]
    }

    /// Codex runs no hook until the human has accepted it, and until then the whole
    /// integration is silently inert — the one failure this feature can have that
    /// looks exactly like nothing happening. So it gets a row of its own rather than
    /// hiding inside `agent.codex.wired`, which the notify key alone satisfies.
    ///
    /// `.warn`, not `.fail`: nothing is broken, a person simply has not been asked
    /// yet. Codex asks on its own at the start of the next session.
    static func codexTrustCheck(home: URL) -> [Check] {
        let url = home.appendingPathComponent(".codex/config.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              text.contains(HookInstaller.codexBegin) else { return [] }
        // Codex writes this key when a hook is accepted; it is
        // "<source path>:<event>:<group>:<index>", and the source is this file.
        let trusted = text.contains("hooks.state.\"\(url.path):session_start:")
        return [Check(id: "codex.hooks", title: "Codex has accepted its hooks",
                      status: trusted ? .ok : .warn,
                      detail: trusted ? nil
                        : "Written, but not yet accepted. Codex asks once before it runs a hook, and until it is answered these do nothing — Codex sessions still appear, from the older notify bridge, but they cannot be approved from here.",
                      fix: trusted ? nil
                        : "Start a Codex session and accept the hooks it asks about.")]
    }

    private static func lastSeenCheck(_ i: Integration, base: URL, now: TimeInterval) -> Check {
        let history = base.appendingPathComponent("history.jsonl")
        let last = HistoryStore.read(url: history).filter { $0.agent == i.id }.map(\.endedAt).max()
        // No record is not a problem. History only starts when AgentBar starts keeping
        // it, so on a freshly updated Mac every agent is blank — reporting that as
        // something to look at would bury the one row that matters under eight that
        // don't, on a machine where nothing is wrong.
        guard let last, last > 0 else {
            return Check(id: "agent.\(i.id).lastSeen", title: "\(i.name) has reported", status: .ok,
                         detail: "No session on record yet.")
        }
        let days = Int((now - last) / 86_400)
        // Wired and silent for a fortnight is the shape of a broken integration that
        // every other check passes — the hooks are in place and simply never fire.
        guard days < Self.quietDays else {
            return Check(id: "agent.\(i.id).lastSeen", title: "\(i.name) has reported", status: .warn,
                         detail: "Wired, but nothing for \(days) days.",
                         fix: "If you have used \(i.name) since then, its hooks are not firing — start a NEW session (hook config is read at session start) and check back.")
        }
        return Check(id: "agent.\(i.id).lastSeen", title: "\(i.name) has reported", status: .ok,
                     detail: days < 1 ? "Last session today." : "Last session \(days) day\(days == 1 ? "" : "s") ago.")
    }

    private static func claudeConfigDirCheck(home: URL) -> [Check] {
        let hint = home.appendingPathComponent(".agentbar/claude-config-dir")
        let stored = (try? String(contentsOf: hint, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let live = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        guard let stored, !stored.isEmpty else { return [] }
        let agrees = live == nil || live == stored
        return [Check(id: "claude.configDir", title: "Claude's config directory", status: agrees ? .ok : .warn,
                      detail: agrees ? stored : "The installer wires \(stored); this shell says CLAUDE_CONFIG_DIR=\(live ?? "").",
                      fix: agrees ? nil : "Update ~/.agentbar/claude-config-dir to the directory you actually use, then relaunch AgentBar.")]
    }

    // MARK: - Rules

    /// A rules file that will not parse is the one failure in this app that is
    /// invisible by design: nothing fires, every prompt comes back, and that is
    /// exactly what AgentBar looks like when it is working. So it is reported
    /// here, where somebody wondering why their rule stopped working will look.
    static func ruleChecks(base: URL) -> [Check] {
        let url = base.appendingPathComponent("rules.json", isDirectory: false)
        switch RulesStore.load(url: url) {
        case .none:
            return [Check(id: "rules.file", title: "Rules", status: .skipped,
                          detail: "None written — every prompt comes to you.")]
        case .rules(let list):
            let counts = RulesStore.Rule.Mode.allCases.map { mode in
                (mode, list.filter { $0.mode == mode }.count)
            }
            let detail = counts.filter { $0.1 > 0 }
                .map { "\($0.1) \($0.0.title.lowercased())" }
                .joined(separator: ", ")
            return [Check(id: "rules.file", title: "Rules", status: .ok,
                          detail: (detail.isEmpty ? "none" : detail)
                                  + (RulesStore.enabled ? "" : " — all paused by the switch in Settings ▸ Rules"))]
        case .invalid(let why):
            return [Check(id: "rules.file", title: "Rules", status: .fail,
                          detail: why + " No rule is being applied.",
                          fix: "Fix ~/.agentbar/rules.json, or move it aside and write the "
                               + "rules again in Settings ▸ Rules. Nothing is applied "
                               + "while any of it is wrong.")]
        }
    }

    // MARK: - Leftovers

    private static func orphanChecks(base: URL, now: TimeInterval) -> [Check] {
        let fm = FileManager.default
        var stale: [String] = []
        for (name, maxAge) in [("state.d", 86_400.0), ("requests.d", 660.0), ("answers.d", 60.0)] {
            let dir = base.appendingPathComponent(name, isDirectory: true)
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let old = files.filter { url in
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970 ?? now
                return now - mtime > maxAge
            }
            if !old.isEmpty { stale.append("\(old.count) in \(name)") }
        }
        return [Check(id: "orphans", title: "No leftovers in ~/.agentbar", status: stale.isEmpty ? .ok : .warn,
                      detail: stale.isEmpty ? nil : "Past their pruning window: \(stale.joined(separator: ", ")).",
                      fix: stale.isEmpty ? nil : "Harmless — frontends skip them. They clear on the next pass with AgentBar running.",
                      repair: stale.isEmpty ? nil : .sweepOrphans)]
    }

    // MARK: - This Mac

    private static func appChecks() -> [Check] {
        var out: [Check] = []

        let copies = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.michalstrnadel.agentbar")
        out.append(Check(id: "app.singleInstance", title: "One AgentBar running",
                         status: copies.count > 1 ? .warn : .ok,
                         detail: copies.count > 1 ? "\(copies.count) copies are running. They both watch *and write* state.d, so they overwrite each other's rows." : nil,
                         fix: copies.count > 1 ? "Quit the extra copy — usually an older one in /Applications next to a development build." : nil))

        let trusted = AXIsProcessTrusted()
        out.append(Check(id: "app.accessibility", title: "Accessibility permission",
                         status: trusted ? .ok : .warn,
                         detail: trusted ? nil : "Not granted. Everything else works; only keystroke approval for agents without a decision hook (Antigravity's desktop app, and Codex sessions older than its hooks) needs it.",
                         fix: trusted ? nil : "System Settings ▸ Privacy & Security ▸ Accessibility ▸ add AgentBar."))

        if IslandScreen.pinnedDisplayMissing {
            out.append(Check(id: "app.islandPin", title: "The island's display", status: .warn,
                             detail: "Pinned to a display that is not connected; it is following the pointer until that one is back.",
                             fix: "Pick another display in Appearance, or plug the pinned one back in — the preference is kept either way."))
        }
        return out
    }
}
