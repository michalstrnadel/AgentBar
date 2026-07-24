import Foundation

/// Idempotent hook installation, re-run on every launch (scripts refresh with the app
/// version; configs are only rewritten when the content actually changes). Copies the
/// bundled hook scripts to `~/.agentbar/hooks/` and wires them into each agent's own
/// hook mechanism. Never blocks the UI; failures are logged and retried on next launch.
enum HookInstaller {
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static var hooksDir: URL { home.appendingPathComponent(".agentbar/hooks", isDirectory: true) }

    /// Resolved once per launch: the fallback probes the user's login shell, which can
    /// cost hundreds of ms on nvm/fnm setups — never pay that four times.
    private static let nodePath: String? = findNode()

    static func installIfNeeded() {
        DispatchQueue.global(qos: .utility).async {
            guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("hooks") else { return }
            do {
                try copyScripts(from: bundled)
                for dir in claudeConfigDirs() { try installClaude(configDir: dir) }
                try installCodex()
                try installCursor()
                try installGemini()
                try installAntigravity()
            } catch {
                NSLog("AgentBar hook install failed: \(error)")
            }
        }
    }

    /// Every Claude config dir we should wire hooks into. Covers a custom
    /// `CLAUDE_CONFIG_DIR` (issue #4) — read from the app's environment if present, or
    /// from a hint file the installer drops (the app is launched via `open`, so it
    /// usually doesn't inherit the shell's env; install.sh rewrites or clears the hint
    /// on every run, so it can't go stale). The default `~/.claude` is always
    /// included so a user who runs Claude both ways stays covered. Deduped.
    private static func claudeConfigDirs() -> [URL] {
        var dirs = [home.appendingPathComponent(".claude")]
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !env.isEmpty {
            dirs.append(URL(fileURLWithPath: (env as NSString).expandingTildeInPath))
        }
        let hint = home.appendingPathComponent(".agentbar/claude-config-dir")
        if let raw = try? String(contentsOf: hint, encoding: .utf8) {
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { dirs.append(URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) }
        }
        var seen = Set<String>()
        return dirs.filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
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

    /// Parse an existing JSON config. Missing file → empty object (fresh install).
    /// Present-but-unparseable (JSONC comments, trailing comma, torn write) → nil:
    /// the caller must SKIP, never overwrite — rewriting from `[:]` would silently
    /// destroy the user's config.
    private static func readConfig(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            NSLog("AgentBar: \(url.path) exists but is not parseable JSON — leaving it untouched")
            return nil
        }
        return parsed
    }

    /// Atomic write, skipped when the file already has exactly this content — avoids
    /// mtime churn (tools watch these configs) and shrinks the window for racing a
    /// tool that is writing its own settings at the same moment.
    private static func writeIfChanged(_ data: Data, to url: URL) throws {
        if let existing = try? Data(contentsOf: url), existing == data { return }
        try data.write(to: url, options: .atomic)
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

    // MARK: - Claude Code (<configDir>/settings.json)

    private static func installClaude(configDir: URL) throws {
        guard let node = nodePath else { NSLog("AgentBar: node not found, Claude hooks skipped"); return }
        let settingsURL = configDir.appendingPathComponent("settings.json")
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        guard var root = readConfig(at: settingsURL) else { return }
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
        try writeIfChanged(data, to: settingsURL) // never leave settings.json half-written
    }

    // MARK: - Codex (~/.codex/config.toml, notify hook)

    private static func installCodex() throws {
        guard let node = nodePath else { return }
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

    // MARK: - Cursor CLI (~/.cursor/hooks.json)

    private static func installCursor() throws {
        // ~/.cursor also exists for IDE-only users; that's intentional — the same
        // hooks.json drives IDE agent sessions, and the bridge is observe-only.
        let cursorDir = home.appendingPathComponent(".cursor")
        guard FileManager.default.fileExists(atPath: cursorDir.path) else { return } // not a Cursor user
        let cfgURL = cursorDir.appendingPathComponent("hooks.json")
        let scriptURL = hooksDir.appendingPathComponent("cursor/cursor.js")
        try pinNodeShebang(of: scriptURL)

        guard var root = readConfig(at: cfgURL) else { return }
        root["version"] = root["version"] ?? 1
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let marker = "/.agentbar/hooks/cursor/"

        // Cursor's command is a single executable path (our script is +x with a shebang).
        // Only observational events: the before* hooks gate permissions and belong to
        // the user, not to a status bridge.
        for event in ["sessionStart", "sessionEnd", "preToolUse", "postToolUse",
                      "afterAgentResponse", "stop"] {
            var rules = (hooks[event] as? [[String: Any]] ?? [])
                .filter { ($0["command"] as? String)?.contains(marker) != true }
            rules.append(["command": scriptURL.path])
            hooks[event] = rules
        }
        root["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try writeIfChanged(data, to: cfgURL)
    }

    /// Cursor runs the script directly via its shebang, and a GUI-launched Cursor
    /// inherits the launchd PATH — often without /opt/homebrew/bin — so
    /// `#!/usr/bin/env node` would silently never fire. Pin the resolved node path.
    private static func pinNodeShebang(of scriptURL: URL) throws {
        guard let node = nodePath,
              var text = try? String(contentsOf: scriptURL, encoding: .utf8),
              text.hasPrefix("#!") else { return }
        let rest = text.drop(while: { $0 != "\n" })
        text = "#!\(node)\(rest)"
        try text.write(to: scriptURL, atomically: false, encoding: .utf8) // keep inode + mode
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    // MARK: - Antigravity (~/.gemini/antigravity{,-cli}/hooks.json)

    /// Antigravity 2.x (desktop app and `agy` CLI) reads hooks.json from its own
    /// customization dir. Top level is named rule groups; we own exactly one key
    /// ("agentbar") and never touch the rest. The script runs via its shebang, so
    /// the node path is pinned the same way as Cursor's bridge.
    private static func installAntigravity() throws {
        let scriptURL = hooksDir.appendingPathComponent("antigravity/antigravity.js")
        let dirs = ["antigravity", "antigravity-cli"].map {
            home.appendingPathComponent(".gemini/\($0)", isDirectory: true)
        }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !dirs.isEmpty else { return } // not an Antigravity user
        try pinNodeShebang(of: scriptURL)

        // Observational events only; PreToolUse stays decision-free (no stdout).
        // The stdin payload carries no event name, so it rides along as an argument.
        var group: [String: Any] = [:]
        for event in ["PreInvocation", "PreToolUse", "PostToolUse", "PostInvocation", "Stop"] {
            let entry: [String: Any] = ["type": "command",
                                        "command": "\"\(scriptURL.path)\" \(event)",
                                        "timeout": 5]
            var rule: [String: Any] = ["hooks": [entry]]
            if event.hasSuffix("ToolUse") { rule["matcher"] = "*" }
            group[event] = [rule]
        }
        for dir in dirs {
            let cfgURL = dir.appendingPathComponent("hooks.json")
            guard var root = readConfig(at: cfgURL) else { continue }
            root["agentbar"] = group
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try writeIfChanged(data, to: cfgURL)
        }
    }

    // MARK: - Gemini CLI (~/.gemini/settings.json)

    private static func installGemini() throws {
        guard let node = nodePath else { return }
        let geminiDir = home.appendingPathComponent(".gemini")
        guard FileManager.default.fileExists(atPath: geminiDir.path) else { return } // not a Gemini user
        let cfgURL = geminiDir.appendingPathComponent("settings.json")
        let script = hooksDir.appendingPathComponent("gemini/gemini.js").path
        let command = "\"\(node)\" \"\(script)\""

        guard var root = readConfig(at: cfgURL) else { return }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let marker = "/.agentbar/hooks/gemini/"

        // Gemini groups hooks as [{ hooks: [{type:"command", command}] }].
        func ours(_ group: [String: Any]) -> Bool {
            ((group["hooks"] as? [[String: Any]]) ?? []).contains {
                ($0["command"] as? String)?.contains(marker) == true
            }
        }
        // timeout is in milliseconds (Gemini docs; default 60000) → 5s.
        // BeforeAgent gives "thinking" at turn start, so a no-tool turn still shows life.
        for event in ["SessionStart", "SessionEnd", "BeforeAgent", "BeforeTool",
                      "AfterTool", "AfterAgent"] {
            var groups = (hooks[event] as? [[String: Any]] ?? []).filter { !ours($0) }
            groups.append(["hooks": [["type": "command", "command": command, "timeout": 5000]]])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try writeIfChanged(data, to: cfgURL)
    }
}
