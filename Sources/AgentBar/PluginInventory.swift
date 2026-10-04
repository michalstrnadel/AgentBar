import Foundation

/// Which Claude Code plugins could answer a prompt before AgentBar ever sees one.
///
/// A plugin is allowed to decide: a classic `PreToolUse` or `PermissionRequest` hook
/// can allow or block a tool call, and a **mod** — a plugin whose code runs inside
/// Claude Code — can hold or approve one from `tool.call` or `tool.check` before a
/// prompt exists. Either way the person was not asked, and nothing in AgentBar's own
/// record says so. This reads what is installed and enabled, per Claude config dir,
/// and says in a sentence what each plugin can do. It decides nothing and changes
/// nothing.
///
/// Parsing is pure and fed from files; the one thing that runs a process —
/// `claude plugin validate --json`, which reads a mod's hooks the way Claude Code
/// does — is a closure, cached by install path, version and the hooks file's mtime,
/// with a scan of the module sources as the fallback (marked `estimated`).
enum PluginInventory {
    /// One hook a plugin registers: `tool.call` with `["tool": "Bash"]`, or a classic
    /// `classic.PreToolUse` with `["matcher": "Bash"]`.
    struct Event: Equatable, Hashable {
        let name: String
        var filter: [String: String] = [:]
    }

    enum Kind: String, Equatable {
        /// `hooks/hooks.json` lists `modules`.
        case mod
        /// Classic command hooks under `hooks`.
        case hooks
        /// Neither — skills, commands, an MCP server, an LSP.
        case other
    }

    struct Plugin: Equatable {
        /// `name@marketplace`, or the directory for one loaded inline.
        let key: String
        let name: String
        /// Every config dir that has it enabled.
        var configDirs: [URL]
        let installPath: String
        let kind: Kind
        let events: [Event]
        /// Events read off the module source rather than from Claude Code.
        let estimated: Bool
        /// AgentBar's own mod: it observes, and is never counted as answering.
        let ours: Bool

        var canAnswer: Bool { !ours && PluginInventory.canAnswer(kind: kind, events: events) }
        var sentence: String { PluginInventory.sentence(for: self) }
    }

    // MARK: - Classification

    /// The mod events that run before a tool does and may decide it.
    static let answeringModEvents: Set<String> = ["tool.check", "tool.call",
                                                  "classic.PreToolUse", "classic.PermissionRequest"]
    /// The classic hook events whose output can allow or block a call.
    static let answeringHookEvents: Set<String> = ["PreToolUse", "PermissionRequest"]

    static func canAnswer(kind: Kind, events: [Event]) -> Bool {
        switch kind {
        case .mod: return events.contains { answeringModEvents.contains($0.name) }
        case .hooks: return events.contains { answeringHookEvents.contains($0.name) }
        case .other: return false
        }
    }

    /// What the plugin can do, in the words of the person it is done to.
    static func sentence(for p: Plugin) -> String {
        if p.ours { return "observes only — passes every decision through unchanged" }
        let phrases = answeringPhrases(kind: p.kind, events: p.events)
        if !phrases.isEmpty { return phrases.joined(separator: "; ") }
        return note(kind: p.kind, events: p.events) ?? (p.kind == .other ? "adds no hooks" : "runs hooks")
    }

    /// One phrase per way of answering, in a stable order.
    static func answeringPhrases(kind: Kind, events: [Event]) -> [String] {
        var out: [String] = []
        func add(_ s: String) { if !out.contains(s) { out.append(s) } }
        switch kind {
        case .mod:
            for e in events where e.name == "tool.check" {
                add("can approve or refuse \(subject(e.filter["tool"])) without asking you")
            }
            for e in events where e.name == "classic.PermissionRequest" {
                add("can answer Claude Code's permission prompts")
            }
            for e in events where e.name == "tool.call" {
                add("can hold or refuse \(subject(e.filter["tool"])) before \(e.filter["tool"] == nil ? "it runs" : "they run")")
            }
            for e in events where e.name == "classic.PreToolUse" {
                add("can allow or block \(subject(e.filter["matcher"])) before \(e.filter["matcher"].map(isAll) ?? true ? "it runs" : "they run")")
            }
        case .hooks:
            for e in events where e.name == "PermissionRequest" {
                add("runs a hook on \(e.filter["matcher"].map { isAll($0) ? "every permission prompt" : "permission prompts for \($0)" } ?? "every permission prompt"), and that hook can answer it")
            }
            for e in events where e.name == "PreToolUse" {
                add("runs a hook before \(e.filter["matcher"].map { isAll($0) ? "every tool call" : "\($0) calls" } ?? "every tool call") that can allow or block it")
            }
        case .other:
            break
        }
        return out
    }

    /// `Bash` → "Bash commands", `Edit` → "Edit calls", none → "any tool call".
    private static func subject(_ tool: String?) -> String {
        guard let tool, !isAll(tool) else { return "any tool call" }
        return tool == "Bash" ? "Bash commands" : "\(tool) calls"
    }

    private static func isAll(_ matcher: String) -> Bool { matcher.isEmpty || matcher == "*" }

    /// For a plugin that cannot answer: the short note beside its name on the
    /// "Also loaded" line. nil when there is nothing worth a word.
    static func note(kind: Kind, events: [Event]) -> String? {
        switch kind {
        case .other: return nil
        case .hooks: return "runs hooks"
        case .mod:
            var out: [String] = []
            if events.contains(where: { $0.name == "ui.render" }) { out.append("draws in the terminal") }
            for e in events where e.name == "command.run" {
                if let c = e.filter["command"], !out.contains("adds /\(c)") { out.append("adds /\(c)") }
            }
            if out.isEmpty, events.contains(where: { $0.name.hasPrefix("session.") || $0.name.hasPrefix("turn.") }) {
                out.append("watches the session")
            }
            return out.isEmpty ? nil : out.joined(separator: ", ")
        }
    }

    // MARK: - Reading the files (pure)

    /// `installed_plugins.json`: `{"version":2,"plugins":{"name@mkt":[{"scope","installPath","version"}]}}`.
    /// The user-scope install wins over a project one; anything malformed is skipped.
    static func registry(_ data: Data) -> [String: (path: String, version: String)] {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = o["plugins"] as? [String: Any] else { return [:] }
        var out: [String: (path: String, version: String)] = [:]
        for (key, value) in plugins {
            let installs = (value as? [[String: Any]]) ?? []
            let pick = installs.first { $0["scope"] as? String == "user" } ?? installs.first
            guard let path = pick?["installPath"] as? String, !path.isEmpty else { continue }
            out[key] = (path, pick?["version"] as? String ?? "")
        }
        return out
    }

    /// The keys `enabledPlugins` switches on — `true` only, not merely present.
    static func enabled(settings: [String: Any]) -> [String] {
        ((settings["enabledPlugins"] as? [String: Any]) ?? [:])
            .filter { ($0.value as? Bool) == true }.map(\.key).sorted()
    }

    /// The directories `env.CLAUDE_CODE_PLUGIN_DIRS` loads inline.
    static func inlineDirs(settings: [String: Any]) -> [String] {
        let value = ((settings["env"] as? [String: Any])?[ClaudeModWiring.envKey]) as? String
        return ClaudeModWiring.entries(value)
    }

    /// What a plugin's hooks file says, before any process runs: a mod's module
    /// files (absolute), or a classic plugin's events with their matchers.
    struct HooksFile: Equatable {
        var modules: [URL] = []
        var classic: [Event] = []
        var url: URL?
    }

    /// `hooks/hooks.json`, or a `hooks` entry in `.claude-plugin/plugin.json` — a
    /// path relative to the plugin, or the hooks object itself.
    static func hooksFile(installPath: String) -> HooksFile {
        let root = URL(fileURLWithPath: installPath, isDirectory: true)
        var candidates = [root.appendingPathComponent("hooks/hooks.json")]
        var inline: [String: Any]?
        if let data = try? Data(contentsOf: root.appendingPathComponent(".claude-plugin/plugin.json")),
           let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let rel = manifest["hooks"] as? String {
                candidates.insert(root.appendingPathComponent(rel), at: 0)
            } else if let o = manifest["hooks"] as? [String: Any] {
                inline = o
            }
        }
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            var file = parseHooks(o, base: url.deletingLastPathComponent())
            file.url = url
            return file
        }
        if let inline { return parseHooks(inline, base: root) }
        return HooksFile()
    }

    static func parseHooks(_ o: [String: Any], base: URL) -> HooksFile {
        var file = HooksFile()
        for m in (o["modules"] as? [Any]) ?? [] {
            guard let rel = m as? String, !rel.isEmpty else { continue }
            file.modules.append(rel.hasPrefix("/") ? URL(fileURLWithPath: rel)
                                                   : base.appendingPathComponent(rel).standardizedFileURL)
        }
        for (event, rules) in ((o["hooks"] as? [String: Any]) ?? [:]).sorted(by: { $0.key < $1.key }) {
            let list = (rules as? [[String: Any]]) ?? []
            if list.isEmpty { file.classic.append(Event(name: event)); continue }
            for rule in list {
                let matcher = rule["matcher"] as? String
                file.classic.append(Event(name: event, filter: matcher.map { ["matcher": $0] } ?? [:]))
            }
        }
        return file
    }

    /// The events in `claude plugin validate --json`: each hooks note reads
    /// `./x.mjs hooks: tool.call{tool=Bash}, ui.render{component=Pane}`. nil when
    /// the output is not that shape — the caller then reads the source instead.
    static func parseValidate(_ data: Data) -> [Event]? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contents = o["contents"] as? [[String: Any]] else { return nil }
        var out: [Event] = []
        var sawHooks = false
        for c in contents where c["type"] as? String == "hooks" {
            sawHooks = true
            for note in (c["notes"] as? [String]) ?? [] {
                guard let r = note.range(of: " hooks: ") else { continue }
                for token in topLevelSplit(String(note[r.upperBound...])) {
                    if let e = event(token), !out.contains(e) { out.append(e) }
                }
            }
        }
        return sawHooks ? out : nil
    }

    /// `a, b{x=1, y=2}, c` → the three, commas inside braces kept.
    private static func topLevelSplit(_ s: String) -> [String] {
        var parts: [String] = [], current = "", depth = 0
        for ch in s {
            if ch == "{" { depth += 1 } else if ch == "}" { depth = max(0, depth - 1) }
            if ch == ",", depth == 0 {
                parts.append(current); current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// `tool.call{tool=Bash}` → the event and its filter.
    private static func event(_ token: String) -> Event? {
        guard let open = token.firstIndex(of: "{") else {
            return token.isEmpty ? nil : Event(name: token)
        }
        let name = String(token[..<open])
        let body = token[token.index(after: open)...].replacingOccurrences(of: "}", with: "")
        var filter: [String: String] = [:]
        for pair in topLevelSplit(body) {
            let kv = pair.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            }
            if kv.count == 2 { filter[kv[0]] = kv[1] }
        }
        return name.isEmpty ? nil : Event(name: name, filter: filter)
    }

    /// The fallback: `on("tool.call", { tool: "Bash" }, …)` read straight off the
    /// module source. Claude Code reads the same calls from source, which is why a
    /// mod has to spell them literally — but this is a guess at what it reads, so
    /// the caller marks the result estimated.
    static func scanSource(_ text: String) -> [Event] {
        let pattern = #"\bon\(\s*["']([A-Za-z][A-Za-z0-9_.]*)["']\s*(?:,\s*\{([^{}]*)\})?"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var out: [Event] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            var filter: [String: String] = [:]
            if m.range(at: 2).location != NSNotFound {
                for pair in ns.substring(with: m.range(at: 2)).split(separator: ",") {
                    let kv = pair.split(separator: ":", maxSplits: 1).map {
                        $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\"'"))
                    }
                    if kv.count == 2, !kv[0].isEmpty { filter[kv[0]] = kv[1] }
                }
            }
            let e = Event(name: name, filter: filter)
            if !out.contains(e) { out.append(e) }
        }
        return out
    }

    // MARK: - Putting it together

    /// Runs `claude plugin validate --json <path>` and hands back its stdout.
    typealias Validator = (String) -> Data?

    /// Every enabled plugin across `configDirs`, one entry per plugin however many
    /// dirs enable it. `validate` nil reads sources only (and whatever the cache
    /// already holds) — what Diagnostics uses, so a launch never spawns `claude`.
    static func inventory(configDirs: [URL], validate: Validator?) -> [Plugin] {
        var byKey: [String: Plugin] = [:]
        var order: [String] = []
        for dir in configDirs {
            let settings = (try? Data(contentsOf: dir.appendingPathComponent("settings.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let installed = (try? Data(contentsOf: dir.appendingPathComponent("plugins/installed_plugins.json")))
                .map(registry) ?? [:]
            var found: [(key: String, name: String, path: String, version: String)] = []
            for key in enabled(settings: settings) {
                // Built-in plugins are not in the registry and have no files to read.
                guard let hit = installed[key] else { continue }
                let name = key.split(separator: "@", maxSplits: 1).first.map(String.init) ?? key
                found.append((key, name, hit.path, hit.version))
            }
            for path in inlineDirs(settings: settings) {
                found.append((path, inlineName(path), path, ""))
            }
            for f in found {
                if var known = byKey[f.key] {
                    if !known.configDirs.contains(dir) { known.configDirs.append(dir) }
                    byKey[f.key] = known
                    continue
                }
                byKey[f.key] = plugin(key: f.key, name: f.name, path: f.path, version: f.version,
                                      dir: dir, validate: validate)
                order.append(f.key)
            }
        }
        return order.compactMap { byKey[$0] }
    }

    /// An inline plugin's name: its manifest's, else the directory's.
    static func inlineName(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        if let data = try? Data(contentsOf: url.appendingPathComponent(".claude-plugin/plugin.json")),
           let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = o["name"] as? String, !name.isEmpty {
            return name
        }
        return url.lastPathComponent
    }

    private static func plugin(key: String, name: String, path: String, version: String,
                               dir: URL, validate: Validator?) -> Plugin {
        let file = hooksFile(installPath: path)
        let ours = path.contains(ClaudeModWiring.marker)
        guard !file.modules.isEmpty else {
            return Plugin(key: key, name: name, configDirs: [dir], installPath: path,
                          kind: file.classic.isEmpty ? .other : .hooks, events: file.classic,
                          estimated: false, ours: ours)
        }
        let (events, estimated) = modEvents(path: path, version: version, file: file, validate: validate)
        return Plugin(key: key, name: name, configDirs: [dir], installPath: path, kind: .mod,
                      events: events, estimated: estimated, ours: ours)
    }

    /// Validated events from the cache or a fresh run; the source scan otherwise.
    private static func modEvents(path: String, version: String, file: HooksFile,
                                  validate: Validator?) -> (events: [Event], estimated: Bool) {
        let mtime = file.url.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }?.timeIntervalSince1970 ?? 0
        let cacheKey = "\(path)|\(version)|\(mtime)"
        if let hit = cache.get(cacheKey) { return (hit, false) }
        if let validate, let data = validate(path), let events = parseValidate(data) {
            cache.set(cacheKey, events)
            return (events, false)
        }
        var events: [Event] = []
        for module in file.modules {
            guard let text = try? String(contentsOf: module, encoding: .utf8) else { continue }
            for e in scanSource(text) where !events.contains(e) { events.append(e) }
        }
        return (events, true)
    }

    /// Validated results, in memory for the app's lifetime. Keyed so an update
    /// (a new version, or the hooks file touched) is read again.
    private final class Cache: @unchecked Sendable {
        private var store: [String: [Event]] = [:]
        private let lock = NSLock()
        func get(_ k: String) -> [Event]? { lock.lock(); defer { lock.unlock() }; return store[k] }
        func set(_ k: String, _ v: [Event]) { lock.lock(); store[k] = v; lock.unlock() }
    }
    private static let cache = Cache()

    // MARK: - The live machine

    /// Every Claude config dir worth reading: the ones the installer wires and the
    /// `~/.claude-*` ones the weight reader finds, each once.
    static func liveConfigDirs(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        let wired = HookInstaller.claudeConfigDirs(HookInstaller.Context(home: home, environment: environment))
        var seen = Set<String>()
        return (wired + WeightReader.claudeConfigDirs(home: home))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
    }

    /// `claude plugin validate --json`, found the way the launcher finds agents,
    /// with a deadline: a hung CLI must cost ten seconds, never the page.
    static let liveValidator: Validator = { path in
        guard let claude = Launcher.resolve("claude"),
              let out = WorkDiff.run(claude, ["plugin", "validate", "--json", path],
                                     in: NSTemporaryDirectory(), timeout: 10)
        else { return nil }
        return Data(out.utf8)
    }

    /// The whole inventory, off the main queue; `done` runs on main.
    static func load(_ done: @escaping ([Plugin]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let plugins = inventory(configDirs: liveConfigDirs(), validate: liveValidator)
            DispatchQueue.main.async { done(plugins) }
        }
    }
}
