import Foundation

/// First-launch, idempotent hook installation. Copies the bundled hook scripts to
/// `~/.agentbar/hooks/` and wires them into each agent's own hook mechanism.
/// Never blocks the UI; failures are logged and retried on next launch.
enum HookInstaller {
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static var hooksDir: URL { home.appendingPathComponent(".agentbar/hooks", isDirectory: true) }

    static func installIfNeeded() {
        DispatchQueue.global(qos: .utility).async {
            guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("hooks") else { return }
            do {
                try copyScripts(from: bundled)
                try installClaude()
                try installCodex()
            } catch {
                NSLog("AgentBar hook install failed: \(error)")
            }
        }
    }

    /// Always refresh the script copies — they're versioned with the app.
    private static func copyScripts(from bundled: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        for agent in (try? fm.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil)) ?? [] {
            let dest = hooksDir.appendingPathComponent(agent.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: agent, to: dest)
        }
    }

    /// Find a node binary the hooks can rely on (login-shell PATHs vary wildly).
    private static func findNode() -> String? {
        let candidates = [
            "/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node",
            home.appendingPathComponent(".local/bin/node").path,
        ]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return hit
        }
        // Version-manager setups (nvm/fnm) and Cellar paths: ask the user's shell once.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v node"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }

    // MARK: - Claude Code (~/.claude/settings.json)

    private static func installClaude() throws {
        guard let node = findNode() else { NSLog("AgentBar: node not found, Claude hooks skipped"); return }
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        let dir = hooksDir.appendingPathComponent("claude").path
        let events: [(event: String, cmd: String, matcher: Bool, timeout: Int?)] = [
            ("SessionStart",     "\"\(node)\" \"\(dir)/lifecycle.js\" start", false, nil),
            ("SessionEnd",       "\"\(node)\" \"\(dir)/lifecycle.js\" end", false, nil),
            ("UserPromptSubmit", "\"\(node)\" \"\(dir)/update.js\" prompt", false, nil),
            ("PreToolUse",       "\"\(node)\" \"\(dir)/update.js\" pre", true, nil),
            ("PostToolUse",      "\"\(node)\" \"\(dir)/update.js\" post", true, nil),
            // Blocking approval hook: its own wait is 600s, so give Claude Code slack.
            // (No Notification hook: late permission notifications used to overwrite
            // newer state and strand sessions on "needs approval".)
            ("PermissionRequest","\"\(node)\" \"\(dir)/permission.js\"", true, 630),
            ("Stop",             "\"\(node)\" \"\(dir)/update.js\" stop", false, nil),
        ]

        // Drop earlier AgentBar entries from EVERY event (path match), so events we
        // no longer register (e.g. Notification) don't linger from old installs.
        for (event, value) in hooks {
            guard var rules = value as? [[String: Any]] else { continue }
            rules.removeAll { rule in
                ((rule["hooks"] as? [[String: Any]]) ?? []).contains { cmd in
                    (cmd["command"] as? String)?.contains("/.agentbar/hooks/claude/") == true
                }
            }
            if rules.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = rules }
        }

        for e in events {
            var rules = hooks[e.event] as? [[String: Any]] ?? []
            var hookEntry: [String: Any] = ["type": "command", "command": e.cmd]
            if let t = e.timeout { hookEntry["timeout"] = t }
            var rule: [String: Any] = ["hooks": [hookEntry]]
            if e.matcher { rule["matcher"] = "*" }
            rules.append(rule)
            hooks[e.event] = rules
        }
        root["hooks"] = hooks

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL)
    }

    // MARK: - Codex (~/.codex/config.toml, notify hook)

    private static func installCodex() throws {
        guard let node = findNode() else { return }
        let codexDir = home.appendingPathComponent(".codex")
        guard FileManager.default.fileExists(atPath: codexDir.path) else { return } // not a Codex user
        let configURL = codexDir.appendingPathComponent("config.toml")
        var config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        if config.contains("/.agentbar/hooks/codex/") { return } // already ours
        if config.range(of: #"^\s*notify\s*="#, options: .regularExpression) != nil {
            NSLog("AgentBar: ~/.codex/config.toml already has a notify hook, not touching it")
            return
        }
        let script = hooksDir.appendingPathComponent("codex/notify.js").path
        if !config.isEmpty && !config.hasSuffix("\n") { config += "\n" }
        config += "notify = [\"\(node)\", \"\(script)\"]\n"
        try config.write(to: configURL, atomically: true, encoding: .utf8)
    }
}
