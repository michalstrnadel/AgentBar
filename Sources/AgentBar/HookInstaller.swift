import Foundation

/// Idempotent hook installation, re-run on every launch (scripts refresh with the app
/// version; configs are only rewritten when the content actually changes). Copies the
/// bundled hook scripts to `~/.agentbar/hooks/` and wires them into each agent's own
/// hook mechanism. Never blocks the UI; failures are logged and retried on next launch.
/// A config write that changes anything first keeps a dated copy of the file beside
/// it and records the diff (`ConfigBackup`); `preview` answers what the next pass
/// would write, from the same code, without writing it.
enum HookInstaller {
    /// The real home and the real interpreter. Only `Context.live` and the script copy
    /// read these; every per-agent function goes through its pass's `Context`, so a
    /// test can point a whole pass at a temporary home and nothing else.
    private static let realHome = FileManager.default.homeDirectoryForCurrentUser
    /// Where the scripts are copied. Under `AGENTBAR_HOME` that is the sandbox's own
    /// folder, so the self-test runs the copy this build shipped without touching
    /// the installed one.
    private static var realHooksDir: URL { AgentBarHome.url("hooks", isDirectory: true) }

    /// Resolved once per launch: the fallback probes the user's login shell, which can
    /// cost hundreds of ms on nvm/fnm setups — never pay that four times.
    private static let liveNode: String? = findNode()
    /// The interpreter and the scripts, for anything that needs to *run* a hook
    /// rather than install one — `ApprovalSelfTest` is the only caller.
    static var resolvedNode: String? { liveNode }
    static var installedHooks: URL { realHooksDir }

    /// Everything a pass reads from the machine, in one place: where home is, the
    /// environment (`CLAUDE_CONFIG_DIR`, `COPILOT_HOME`), the node to write into the
    /// configs, where the change record goes, and the agents the user switched off
    /// (`WiringPrefs`).
    struct Context {
        var home: URL
        var environment: [String: String] = [:]
        var node: String?
        /// `ConfigBackup`'s record; nil keeps none.
        var log: URL?
        /// `wire-disabled` as read.
        var disabled: Set<String> = []
        /// `wire-enabled` as read: the default-off integrations switched on. A test
        /// that leaves it empty gets them off, exactly like a fresh machine.
        var enabled: Set<String> = []
        /// Only a pass over the real machine tells the welcome window what it wired.
        var publishes = false
        /// The Claude Code installed here, for the mod's version gate. nil is "could
        /// not tell", which does not block: an older Claude Code ignores the setting.
        var claudeVersion: String?

        var hooksDir: URL { home.appendingPathComponent(".agentbar/hooks", isDirectory: true) }
        /// Where the Claude Code mod is loaded from — the real home's copy, never a
        /// sandbox's: a sandbox wires nothing at all.
        var claudeModDir: URL { home.appendingPathComponent(".agentbar/mods/claude", isDirectory: true) }

        /// Whether a pass unwires `id`: switched off, or off by default and never
        /// switched on (`WiringPrefs.effectiveDisabled`).
        func isOff(_ id: String) -> Bool {
            WiringPrefs.effectiveDisabled(disabled: disabled, enabled: enabled).contains(id)
        }

        static func live() -> Context {
            Context(home: realHome, environment: ProcessInfo.processInfo.environment,
                    node: liveNode, log: ConfigBackup.defaultLog,
                    disabled: WiringPrefs.load(home: realHome),
                    enabled: WiringPrefs.loadEnabled(home: realHome), publishes: true,
                    claudeVersion: claudeCodeVersion())
        }
    }

    /// Agent ids whose hooks this launch actually wired — the tools the user has,
    /// minus any whose config we refused to touch. The welcome window reports it, so
    /// an otherwise invisible side effect becomes something the user can check.
    /// Mutated and read on the MAIN queue only: the install pass runs on a utility
    /// queue and hands each note to main, so a welcome window shown mid-pass reads
    /// a consistent (possibly still growing) list instead of racing the append.
    /// `onFinish` is enqueued after every note, so "done" really is complete.
    private(set) static var wired: [String] = []
    /// Called on the main queue when the install pass finishes.
    static var onFinish: (() -> Void)?
    /// Whether a pass has finished this launch. Main queue only. Lets the welcome
    /// window tell "still wiring" from "found nothing to wire".
    private(set) static var finished = false

    /// One run over every integration: either the real one (launch, **Re-install
    /// hooks**), or a preview that works out every config write and makes none.
    ///
    /// The preview exists so "what would AgentBar change?" is answered by the same
    /// code that changes it, not by a second description of it that drifts. Every
    /// per-agent function below builds its bytes exactly as before and hands them to
    /// `write` instead of to disk; only the side effects that are not a config
    /// write — copying the scripts, pinning a shebang, creating a directory, the
    /// "wired" note — are skipped when previewing.
    private final class Pass {
        let preview: Bool
        let ctx: Context
        /// One agent's steps only — the Agents switch in Settings, which previews and
        /// then writes exactly what it showed and nothing for anybody else.
        let only: String?
        /// The agent whose step is running, so every record says whose file it was.
        var currentAgent: String?
        /// What a preview pass would write, in pass order. Touched only on the
        /// pass's own queue.
        private(set) var planned: [ConfigBackup.Record] = []
        /// What this pass wired, whether or not it publishes it.
        private(set) var noted: [String] = []
        /// What this pass meant to do and did not — a step that threw, a config it
        /// refused to rewrite, no node to point the hooks at — as one sentence per
        /// problem, naming the agent. A repair that left any of these behind did not
        /// repair anything, and the button that ran it says so.
        private(set) var problems: [(agent: String?, text: String)] = []

        func problem(_ text: String) {
            NSLog("AgentBar: \(text)")
            problems.append((currentAgent, text))
        }

        init(preview: Bool, ctx: Context, only: String? = nil) {
            self.preview = preview
            self.ctx = ctx
            self.only = only
        }

        var home: URL { ctx.home }
        var hooksDir: URL { ctx.hooksDir }
        var node: String? { ctx.node }

        /// An agent's config: backed up and recorded (`ConfigBackup`) when real,
        /// collected when previewing. A write that changes nothing is neither.
        func write(_ data: Data, to url: URL) throws {
            if preview {
                if let r = ConfigBackup.preview(data, for: url, agent: currentAgent) { planned.append(r) }
                return
            }
            guard let r = try ConfigBackup.write(data, to: url, log: ctx.log, agent: currentAgent)
            else { return }
            // The launch that rewrote a file says so where a launch can: one line,
            // naming the copy it kept. The diff itself is in the record.
            NSLog("AgentBar: wrote \(r.path)"
                  + (r.backup.map { " (the previous version is kept as \($0))" } ?? " (new file)"))
        }

        /// A file AgentBar owns outright, taken away — kept beside itself and
        /// recorded first, the same as a rewrite. Nothing there is nothing to do.
        func remove(_ url: URL) throws {
            if preview {
                if let r = ConfigBackup.previewRemoval(of: url, agent: currentAgent) { planned.append(r) }
                return
            }
            guard let r = try ConfigBackup.remove(url, log: ctx.log, agent: currentAgent) else { return }
            NSLog("AgentBar: removed \(r.path)" + (r.backup.map { " (kept as \($0))" } ?? ""))
        }

        func createDirectory(_ url: URL) throws {
            guard !preview else { return }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        func note(_ agentID: String) {
            guard !preview else { return }
            if !noted.contains(agentID) { noted.append(agentID) }
            guard ctx.publishes else { return }
            DispatchQueue.main.async {
                if !wired.contains(agentID) { wired.append(agentID) }
            }
        }

        /// An agent that was just unwired is no longer one the welcome window names.
        func unnote(_ agentID: String) {
            guard !preview else { return }
            noted.removeAll { $0 == agentID }
            guard ctx.publishes else { return }
            DispatchQueue.main.async { wired.removeAll { $0 == agentID } }
        }
    }

    static func installIfNeeded(then done: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            _ = installNow()
            DispatchQueue.main.async { finished = true; onFinish?(); done?() }
        }
    }

    /// The launch pass, on the calling thread, returning what it could not do —
    /// for Diagnostics' **Re-install hooks**, which must not call a repair that
    /// wrote nothing a success. Empty means every agent here is wired as asked.
    static func installNow() -> [String] {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("hooks") else {
            return ["the app bundle has no hook scripts in it"]
        }
        // Without the scripts on disk there is nothing worth wiring to.
        guard step("copy scripts", { try copyScripts(from: bundled) }) else {
            return ["the hook scripts could not be copied to \(AgentBarHome.root().path)/hooks"]
        }
        // The mod is copied whether or not anybody switched it on — it is
        // inert until Claude Code is told where it is — and a failure here
        // costs only the mod, never the hooks.
        if let mods = Bundle.main.resourceURL?.appendingPathComponent("mods") {
            step("copy mods") { try copyMods(from: mods, to: realModsDir) }
        }
        // A sandbox wires nothing. Its scripts are copied (the self-test runs
        // them), but every agent config it would write is the person's real one,
        // and pointing those at a throwaway folder is the leak `AgentBarHome`
        // exists to stop.
        guard !AgentBarHome.isSandbox else {
            NSLog("AgentBar: \(AgentBarHome.variable) is set — not wiring any agent")
            return []
        }
        let pass = Pass(preview: false, ctx: .live())
        run(pass)
        return pass.problems.map(\.text)
    }

    /// Every config write the next install pass would make, as diffs, without making
    /// any — for the changes sheet. `done` runs on the main queue. Empty means a
    /// re-install would leave every file exactly as it is.
    static func preview(_ done: @escaping ([ConfigBackup.Record]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let planned = runPass(.live(), preview: true).planned
            DispatchQueue.main.async { done(planned) }
        }
    }

    /// What switching one agent on (`wired`) or off would write, for that agent
    /// alone — the Agents switch shows this before it does anything.
    static func preview(agent: String, wired: Bool,
                        _ done: @escaping ([ConfigBackup.Record]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var ctx = Context.live()
            if wired {
                ctx.disabled.remove(agent); ctx.enabled.insert(agent)
            } else {
                ctx.disabled.insert(agent); ctx.enabled.remove(agent)
            }
            let planned = runPass(ctx, preview: true, only: agent).planned
            DispatchQueue.main.async { done(planned) }
        }
    }

    /// The switch, confirmed: the choice is saved to `~/.agentbar/wire-disabled`
    /// first — so the next launch agrees with it even if this pass fails part way —
    /// and then that one agent is wired or unwired, exactly as the preview showed.
    /// Sessions already running keep the hooks they started with; their permission
    /// requests are still answered, because the app never looks at this file for that.
    static func setWired(_ agent: String, _ wired: Bool,
                         _ done: @escaping (Error?) -> Void) {
        guard !AgentBarHome.isSandbox else {
            return done(SandboxRefusal())
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try WiringPrefs.set(agent, disabled: !wired, home: realHome)
            } catch {
                DispatchQueue.main.async { done(error) }
                return
            }
            let problems = runPass(.live(), preview: false, only: agent).problems
            // Switched on and not wired is not success: the switch would sit there
            // saying "on" over an agent that never reports. Off has no such case —
            // nothing to find is the same as nothing left.
            let error = wired && !problems.isEmpty ? NotWired(problems: problems) : nil
            // …and the saved choice goes back with the switch, so the next launch
            // does not quietly retry what the person was just told did not work.
            if error != nil { try? WiringPrefs.set(agent, disabled: true, home: realHome) }
            DispatchQueue.main.async { onFinish?(); done(error) }
        }
    }

    /// Why a pass that ran did not do what it was asked.
    struct NotWired: LocalizedError {
        let problems: [String]
        var errorDescription: String? {
            "AgentBar could not wire it: " + problems.joined(separator: "; ") + "."
        }
    }

    /// Why a sandboxed copy's Agents switch did nothing.
    struct SandboxRefusal: LocalizedError {
        var errorDescription: String? {
            "This copy runs with \(AgentBarHome.variable) set, so it does not change any agent's settings."
        }
    }

    /// One pass over `ctx` — the entry point the tests drive with a temporary home.
    /// The script copy is not part of it; that is `installIfNeeded`'s alone.
    static func runPass(_ ctx: Context, preview: Bool, only: String? = nil)
    -> (planned: [ConfigBackup.Record], wired: [String], problems: [String]) {
        let pass = Pass(preview: preview, ctx: ctx, only: only)
        run(pass)
        return (pass.planned, pass.noted, pass.problems.map(\.text))
    }

    /// Every agent the user has not switched off is wired; every one they have is
    /// *unwired* — on every pass, so a hand-edited `wire-disabled` (or the CLI's)
    /// takes effect on the next launch too. Unwiring something already unwired
    /// writes nothing.
    private static func run(_ pass: Pass) {
        let on = { (id: String) in !pass.ctx.isOff(id) }
        for dir in claudeConfigDirs(pass.ctx) {
            step("claude (\(dir.path))", agent: "claude", pass) {
                on("claude") ? try installClaude(configDir: dir, pass)
                             : try unwireClaude(configDir: dir, pass)
            }
        }
        // Off unless switched on (`WiringPrefs.defaultOff`), so on a machine where
        // nobody asked this is an unwire that finds nothing and writes nothing.
        for dir in claudeConfigDirs(pass.ctx) {
            step("claude-mod (\(dir.path))", agent: ClaudeModWiring.id, pass) {
                on(ClaudeModWiring.id) ? try wireClaudeMod(configDir: dir, pass)
                                 : try unwireClaudeMod(configDir: dir, pass)
            }
        }
        step("codex", agent: "codex", pass) { on("codex") ? try installCodex(pass) : try unwireCodex(pass) }
        step("cursor", agent: "cursor", pass) { on("cursor") ? try installCursor(pass) : try unwireCursor(pass) }
        step("gemini", agent: "gemini", pass) { on("gemini") ? try installGemini(pass) : try unwireGemini(pass) }
        step("antigravity", agent: "antigravity", pass) {
            on("antigravity") ? try installAntigravity(pass) : try unwireAntigravity(pass)
        }
        step("qwen", agent: "qwen", pass) { on("qwen") ? try installQwen(pass) : try unwireQwen(pass) }
        step("copilot", agent: "copilot", pass) { on("copilot") ? try installCopilot(pass) : try unwireCopilot(pass) }
        // Installing is not previewed on a whole pass and not backed up: the plugin is
        // AgentBar's own code, copied verbatim, not a setting of the user's — a diff of
        // it would be a diff of our release. The one-agent preview behind the Agents
        // switch does show it, because there it is the whole answer. Taking it away
        // is always shown and always kept, like any other file AgentBar removes.
        step("opencode", agent: "opencode", pass) {
            if !on("opencode") { try unwireOpenCode(pass) }
            else if !pass.preview || pass.only == "opencode" { try installOpenCode(pass) }
        }
    }

    /// Each integration is independent: one agent's config blowing up must not cost the
    /// user every integration that comes after it in the pass. Returns whether it ran.
    @discardableResult
    private static func step(_ name: String, _ body: () throws -> Void) -> Bool {
        do {
            try body()
            return true
        } catch {
            NSLog("AgentBar hook install step '\(name)' failed: \(error)")
            return false
        }
    }

    /// One agent's step: skipped when the pass is for somebody else, and tagged so
    /// every record it leaves names the agent.
    private static func step(_ name: String, agent: String, _ pass: Pass, _ body: () throws -> Void) {
        if let only = pass.only, only != agent { return }
        pass.currentAgent = agent
        defer { pass.currentAgent = nil }
        do {
            try body()
        } catch {
            pass.problem("\(name): \(error.localizedDescription)")
        }
    }

    /// Every Claude config dir we should wire hooks into. Covers a custom
    /// `CLAUDE_CONFIG_DIR` (issue #4) — read from the app's environment if present, or
    /// from a hint file the installer drops (the app is launched via `open`, so it
    /// usually doesn't inherit the shell's env; install.sh rewrites or clears the hint
    /// on every run, so it can't go stale). The default `~/.claude` is always
    /// included so a user who runs Claude both ways stays covered. Deduped.
    ///
    /// And every `~/.claude-*` whose settings already carry AgentBar — its hooks or
    /// its mod. Someone with one alias per account (`CLAUDE_CONFIG_DIR=~/.claude-work
    /// claude`) has those directories wired by the CLI or the installer, from a shell
    /// that had the variable, while the app — launched by `open` — never sees it.
    /// Without this the app kept only `~/.claude` current: switching the mod on
    /// wrote it there and nowhere the sessions actually read. Only directories that
    /// already name AgentBar: one nobody wired stays nobody's business.
    static func claudeConfigDirs(_ ctx: Context) -> [URL] {
        let home = ctx.home
        var dirs = [home.appendingPathComponent(".claude")]
        if let env = ctx.environment["CLAUDE_CONFIG_DIR"], !env.isEmpty {
            dirs.append(URL(fileURLWithPath: (env as NSString).expandingTildeInPath))
        }
        let hint = AgentBarHome.url("claude-config-dir", home: home)
        if let raw = try? String(contentsOf: hint, encoding: .utf8) {
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { dirs.append(URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) }
        }
        dirs += wiredClaudeDirs(home: home)
        var seen = Set<String>()
        return dirs.filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
    }

    /// The `~/.claude-*` directories whose `settings.json` already names AgentBar's
    /// hooks or its mod, sorted. Read as text: a marker is a path, and a file that
    /// will not parse is the installer's to report, not this list's to hide.
    static func wiredClaudeDirs(home: URL) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: home.path) else { return [] }
        return names.filter { $0.hasPrefix(".claude-") }.sorted().compactMap { name in
            let dir = home.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("settings.json")),
                  data.count < 4 << 20,
                  let text = String(data: data, encoding: .utf8),
                  text.contains(claudeMarker) || text.contains(ClaudeModWiring.marker) else { return nil }
            return dir
        }
    }

    /// Always refresh the script copies — they're versioned with the app.
    private static func copyScripts(from bundled: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: realHooksDir, withIntermediateDirectories: true)
        for agent in (try? fm.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil)) ?? [] {
            let dest = realHooksDir.appendingPathComponent(agent.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: agent, to: dest)
        }
    }

    /// Where the bundled mods are copied — under `AGENTBAR_HOME` like the hooks.
    private static var realModsDir: URL { AgentBarHome.url("mods", isDirectory: true) }

    /// Each bundled mod (`Resources/mods/<name>`) into `dest/<name>`, replaced whole
    /// when it differs and left alone when it does not: Claude Code reloads a mod
    /// whose files change, and every launch rewriting identical bytes would reload
    /// it in every session that has it. Nothing else in `dest` is touched — least of
    /// all `config.json`, which is the person's.
    static func copyMods(from bundled: URL, to dest: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundled.path) else { return }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for mod in (try? fm.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil)) ?? [] {
            let name = mod.lastPathComponent
            guard name != "config.json", !name.hasPrefix(".") else { continue }
            let target = dest.appendingPathComponent(name)
            if sameTree(mod, target) { continue }
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: mod, to: target)
        }
    }

    /// Two directories (or files) holding the same relative paths with the same bytes.
    static func sameTree(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        func files(_ root: URL) -> [String: URL]? {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else { return nil }
            guard isDir.boolValue else { return ["": root] }
            var out: [String: URL] = [:]
            let prefix = root.resolvingSymlinksInPath().path + "/"
            for case let url as URL in fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) ?? .init() {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let path = url.resolvingSymlinksInPath().path
                out[path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path] = url
            }
            return out
        }
        guard let left = files(a), let right = files(b), Set(left.keys) == Set(right.keys) else { return false }
        return left.allSatisfy { rel, url in
            (try? Data(contentsOf: url)) == right[rel].flatMap { try? Data(contentsOf: $0) }
        }
    }

    /// Parse an existing JSON config. Missing file → empty object (fresh install).
    /// Present-but-unparseable (JSONC comments, trailing comma, torn write) → nil:
    /// the caller must SKIP, never overwrite — rewriting from `[:]` would silently
    /// destroy the user's config.
    /// An unreadable file counts as present-but-unparseable, not as missing: a
    /// permission glitch or a torn read must never look like a fresh install.
    private static func readConfig(at url: URL, _ pass: Pass? = nil) -> [String: Any]? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
            let why = "\(url.path) exists but could not be read (\(error.localizedDescription)) — left untouched"
            if let pass { pass.problem(why) } else { NSLog("AgentBar: \(why)") }
            return nil
        }
        // A trailing comma is the case the comment above names, and JSONSerialization
        // accepts it: this installer rewrote such a file while the CLI's left it alone.
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !StrictJSON.hasTrailingComma(data) else {
            let why = "\(url.path) is not valid JSON, so it was left untouched"
            if let pass { pass.problem(why) } else { NSLog("AgentBar: \(why)") }
            return nil
        }
        return parsed
    }

    /// Atomic write, skipped when the file already has exactly this content — avoids
    /// mtime churn (tools watch these configs) and shrinks the window for racing a
    /// tool that is writing its own settings at the same moment.
    ///
    /// Only for files that are AgentBar's own code (the OpenCode plugin). An agent's
    /// *settings* go through `Pass.write`, which does the same skip and also keeps a
    /// backup and a diff — see `ConfigBackup`.
    private static func writeIfChanged(_ data: Data, to url: URL) throws {
        if let existing = try? Data(contentsOf: url), existing == data { return }
        try data.write(to: url, options: .atomic)
    }

    /// Paths that keep naming *a* node across upgrades.
    ///
    /// Order matters here in a way it does not in the Linux CLI. There this list only
    /// maps an already-known-good interpreter onto an equivalent alias, so any match
    /// is the same binary and the order is arbitrary. Here it also decides which node
    /// gets used at all — so Homebrew's prefix stays ahead of `/usr/local`, where an
    /// old nodejs.org pkg tends to linger.
    static var stableNodePaths: [String] {
        ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node",
         realHome.appendingPathComponent(".local/bin/node").path]
    }

    /// Swap a version-pinned path for a stable alias that resolves to the same binary.
    ///
    /// Whatever this returns is written into config files that outlive the next node
    /// upgrade, so a pinned path is a silent time bomb: after `nvm install 22` or a
    /// Homebrew Cellar bump the interpreter named in every config is simply gone, and
    /// every hook stops firing with no error anywhere — indistinguishable from "the
    /// agent isn't reporting". The Linux CLI has done this since 5d5316c; this side
    /// never got it.
    ///
    /// The input comes back unchanged when no alias resolves to the same binary: an
    /// nvm-only machine genuinely has none, and `agentbar doctor` says so rather than
    /// this guessing at a path that does not exist.
    static func stableNodeAlias(for path: String) -> String {
        guard let target = realPath(path) else { return path }
        let fm = FileManager.default
        let alias = stableNodePaths.first {
            $0 != path && fm.isExecutableFile(atPath: $0) && realPath($0) == target
        }
        return alias ?? path
    }

    /// `realpath(3)` — symlinks resolved, exactly what the CLI's `fs.realpathSync` does.
    static func realPath(_ path: String) -> String? {
        guard let c = realpath(path, nil) else { return nil }
        defer { free(c) }
        return String(cString: c)
    }

    /// Find a node binary the hooks can rely on (login-shell PATHs vary wildly).
    private static func findNode() -> String? {
        if let hit = stableNodePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return hit
        }
        // Version-manager setups (nvm/fnm) and Cellar paths: ask the user's shell once,
        // with a deadline — a profile that blocks would otherwise hold the install
        // pass, and with it the welcome window's list and Diagnostics, for good.
        guard let answer = WorkDiff.run("/bin/zsh", ["-lc", "command -v node"],
                                        in: NSHomeDirectory(), timeout: 10) else {
            NSLog("AgentBar: the login shell named no node binary (or took longer than 10 s)")
            return nil
        }
        let out = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        // This is where the pinned paths come from: under nvm/fnm `command -v node`
        // answers with the version's own bin dir. Map it back onto a stable alias
        // when one names the same binary.
        return out.isEmpty ? nil : stableNodeAlias(for: out)
    }

    // MARK: - Claude Code (<configDir>/settings.json)

    private static func installClaude(configDir: URL, _ pass: Pass) throws {
        let hooksDir = pass.hooksDir
        guard let node = pass.node else { return pass.problem("node was not found, so Claude hooks were not wired") }
        let settingsURL = configDir.appendingPathComponent("settings.json")
        try pass.createDirectory(settingsURL.deletingLastPathComponent())

        guard var root = readConfig(at: settingsURL, pass) else { return }
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
            // "Compacting…" while the session summarises its context. There is no
            // PostCompact here on purpose: the SessionStart (source "compact") that
            // follows every compaction already ends it, and an event name an older
            // Claude Code does not know is a settings file it may refuse.
            ("PreCompact",       "\"\(node)\" \"\(dir)/update.js\" compact", false, nil),
        ]

        // Drop earlier AgentBar entries from EVERY event (path match), so events we
        // no longer register (e.g. Notification) don't linger from old installs.
        hooks = strippingOurs(hooks, marker: claudeMarker).hooks

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

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try pass.write(data, to: settingsURL) // never leave settings.json half-written
        pass.note("claude")
    }

    // MARK: - Codex (~/.codex/config.toml: the hooks block, and the notify bridge)

    private static func installCodex(_ pass: Pass) throws {
        let hooksDir = pass.hooksDir
        guard let node = pass.node else { return pass.problem("node was not found, so Codex hooks were not wired") }
        let codexDir = pass.home.appendingPathComponent(".codex")
        guard FileManager.default.fileExists(atPath: codexDir.path) else { return } // not a Codex user
        let configURL = codexDir.appendingPathComponent("config.toml")
        // The same rule `readConfig` keeps for the JSON configs: missing is a fresh
        // install, but present-and-unreadable or present-and-not-UTF-8 is not empty.
        // Read as "", it planned a fresh file and replaced the user's whole
        // config.toml with AgentBar's two keys — with no backup when the read had
        // failed, since the backup reads the same bytes.
        let config: String
        do {
            let data = try Data(contentsOf: configURL)
            guard let text = String(data: data, encoding: .utf8) else {
                NSLog("AgentBar: ~/.codex/config.toml is not UTF-8 — leaving it untouched")
                return
            }
            config = text
        } catch {
            guard !FileManager.default.fileExists(atPath: configURL.path) else {
                NSLog("AgentBar: ~/.codex/config.toml exists but could not be read (\(error)) — leaving it untouched")
                return
            }
            config = ""
        }
        let script = hooksDir.appendingPathComponent("codex/notify.js").path

        // Two independent keys in one file, applied in order. `notify` is the older
        // integration and stays: it is the only thing that reports a Codex session
        // until the human accepts the hooks in Codex's own trust prompt.
        var text = config
        switch codexPlan(config: text, node: node, script: script) {
        case .foreignNotify:
            NSLog("AgentBar: ~/.codex/config.toml already has a notify hook, not touching it")
        case .unchanged:
            break
        case .write(let next, let repaired):
            text = next
            if repaired { NSLog("AgentBar: repaired a dead node path in ~/.codex/config.toml") }
        }
        if case .write(let next, _) = codexHooksPlan(config: text, node: node,
                                                     dir: hooksDir.path) {
            text = next
        }
        // One write for both keys, so a pass that repairs the notify line *and* the
        // block leaves one backup of the file as it was, not one of a halfway state.
        if text != config { try pass.write(Data(text.utf8), to: configURL) }
        pass.note("codex")
    }

    /// The events Codex fires, and which shared script answers each.
    ///
    /// Codex speaks Claude's hook dialect, so these are the `claude/` scripts, reached
    /// through `codex/hook.js` — Codex's handler has no `env` field and runs the command
    /// without a shell, so the shim is where `AGENTBAR_AGENT` and the row prefix get set.
    ///
    /// Timeouts are per event and Codex clamps them: `SessionEnd`'s ceiling is 3s, so
    /// asking for 5 there would earn a warning on every session. `PermissionRequest`
    /// keeps its 630 — above `permission.js`'s own 600s wait, so the hook is the thing
    /// that gives up first and exits silently into Codex's own prompt, rather than being
    /// killed mid-wait. Verified against codex-cli 0.155.0; see Scripts/hooks/codex/README.md.
    static let codexEvents: [(event: String, script: String, arg: String?, timeout: Int)] = [
        ("SessionStart",     "lifecycle.js", "start",  5),
        ("SessionEnd",       "lifecycle.js", "end",    3),
        ("UserPromptSubmit", "update.js",    "prompt", 5),
        ("PreToolUse",       "update.js",    "pre",    5),
        ("PostToolUse",      "update.js",    "post",   5),
        ("Stop",             "update.js",    "stop",   5),
        ("PermissionRequest", "permission.js", nil,   630),
    ]

    static let codexBegin = "# >>> agentbar >>> written by AgentBar; edit outside these two lines"
    static let codexEnd = "# <<< agentbar <<<"

    /// The block AgentBar owns inside `~/.codex/config.toml`.
    ///
    /// Array-of-tables rather than dotted keys, because Codex writes its own
    /// `[hooks.state]` section when a human trusts a hook, and a `hooks.X = […]`
    /// dotted key would make that a redefinition TOML refuses. Appended at the end of
    /// the file for the same family of reason: a bare `key = value` written after a
    /// `[[table]]` header belongs to that table, so a block in the middle would
    /// silently capture whatever the user adds next.
    static func codexHooksBlock(node: String, dir: String) -> String {
        var out = [codexBegin]
        for e in codexEvents {
            let arg = e.arg.map { " " + $0 } ?? ""
            out += ["[[hooks.\(e.event)]]",
                    "[[hooks.\(e.event).hooks]]",
                    "type = \"command\"",
                    "command = \"\\\"\(node)\\\" \\\"\(dir)/codex/hook.js\\\" \(e.script)\(arg)\"",
                    "timeout = \(e.timeout)"]
            if e.event == "PermissionRequest" {
                out.append("statusMessage = \"Waiting for you in AgentBar\"")
            }
            out.append("")
        }
        out.append(codexEnd)
        return out.joined(separator: "\n")
    }

    /// Replace our block where it already is, or append it at the end. Pure, so the
    /// "unknown keys survive byte for byte" promise is a test rather than a hope.
    static func codexHooksPlan(config: String, node: String, dir: String) -> CodexPlan {
        let block = codexHooksBlock(node: node, dir: dir)
        if let begin = config.range(of: codexBegin),
           let end = config.range(of: codexEnd, range: begin.upperBound..<config.endIndex) {
            let current = String(config[begin.lowerBound..<end.upperBound])
            if current == block { return .unchanged }
            var next = config
            next.replaceSubrange(begin.lowerBound..<end.upperBound, with: block)
            return .write(next, repaired: true)
        }
        var next = config
        if !next.isEmpty && !next.hasSuffix("\n") { next += "\n" }
        if !next.isEmpty { next += "\n" }
        return .write(next + block + "\n", repaired: false)
    }

    /// What `installCodex` should do with the TOML it found.
    enum CodexPlan: Equatable {
        /// Wired and working, or wired in a shape we deliberately won't touch.
        case unchanged
        /// Someone else's `notify` key — Codex allows exactly one, so we stay out.
        case foreignNotify
        /// The full text to write; `repaired` distinguishes a fix from a first install.
        case write(String, repaired: Bool)
    }

    /// Pure so the repair has a test that doesn't need a `~/.codex` on the machine.
    ///
    /// The interesting case is the second one. Every other agent's config is rewritten
    /// whenever its content differs, so an interpreter that moved heals on the next
    /// launch; Codex used to stop at the marker, which made it the one integration
    /// where a stale node path was permanent — relaunching the app, reinstalling it,
    /// nothing rewrote that line, and the rows just never appeared again.
    static func codexPlan(
        config: String, node: String, script: String,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> CodexPlan {
        let ours = "notify = [\"\(node)\", \"\(script)\"]"
        let ourLine = #"(?m)^[ \t]*notify[ \t]*=[ \t]*\[[^\]]*/\.agentbar/hooks/codex/[^\]]*\]"#

        if let line = config.range(of: ourLine, options: .regularExpression) {
            let dead = firstQuoted(String(config[line])).map { !isExecutable($0) } ?? false
            // Written below a table header by an older AgentBar, the key belongs to
            // that table and Codex never sees a top-level notify — and nothing would
            // ever have noticed, because the line still reads as ours. It moves.
            let misplaced = rootTableEnd(of: config).map { line.lowerBound > $0 } ?? false
            guard dead || misplaced else { return .unchanged }
            var next = config
            guard misplaced else {
                next.replaceSubrange(line, with: ours)
                return .write(next, repaired: true)
            }
            var cut = line
            if cut.upperBound < next.endIndex, next[cut.upperBound] == "\n" {
                cut = cut.lowerBound..<next.index(after: cut.upperBound)
            }
            next.removeSubrange(cut)
            return .write(insertingAtRoot(ours, into: next), repaired: true)
        }
        // Our marker somewhere the line pattern could not read — a comment, hand-edited
        // formatting, a `notify` spread over several lines: leave it alone rather than
        // appending a second notify key.
        //
        // Our own hooks block is cut out first, and that is not a detail. It carries the
        // same path on every line, so without the cut a config holding the block and no
        // `notify` at all would read as "notify is already wired" and notify would never
        // be installed again.
        if withoutCodexBlock(config).contains("/.agentbar/hooks/codex/") { return .unchanged }
        // `(?m)`: without it `^` is the start of the file, and a user's own notify on
        // any later line was invisible — AgentBar then appended a second key, and
        // TOML refuses a file with a duplicate key, so Codex stopped loading it.
        if config.range(of: #"(?m)^[ \t]*notify[ \t]*="#, options: .regularExpression) != nil {
            return .foreignNotify
        }
        return .write(insertingAtRoot(ours, into: config), repaired: false)
    }

    /// Where the root table ends: the first table header, or the start of our own
    /// hooks block, whichever comes first; nil when the file has neither. A bare key
    /// written after a `[table]` header belongs to that table, so `notify` appended
    /// to a file with an `[mcp_servers.x]` section was `mcp_servers.x.notify`.
    static func rootTableEnd(of config: String) -> String.Index? {
        let header = config.range(of: #"(?m)^[ \t]*\[{1,2}[^\[\],=\n]*\]{1,2}[ \t]*(#.*)?$"#,
                                  options: .regularExpression)?.lowerBound
        let block = config.range(of: codexBegin)?.lowerBound
        return [header, block].compactMap { $0 }.min()
    }

    /// `line` as a top-level key: before the first table, or at the end of a file
    /// that has none.
    static func insertingAtRoot(_ line: String, into config: String) -> String {
        var next = config
        if let end = rootTableEnd(of: next) {
            next.insert(contentsOf: line + "\n", at: end)
            return next
        }
        if !next.isEmpty && !next.hasSuffix("\n") { next += "\n" }
        return next + line + "\n"
    }

    /// The config with AgentBar's own hooks block removed, for the questions that are
    /// about what the *user* put in the file.
    static func withoutCodexBlock(_ config: String) -> String {
        guard let begin = config.range(of: codexBegin),
              let end = config.range(of: codexEnd, range: begin.upperBound..<config.endIndex)
        else { return config }
        var out = config
        out.removeSubrange(begin.lowerBound..<end.upperBound)
        return out
    }

    /// The first `"…"` in a TOML line — the interpreter in `notify = ["node", "script"]`.
    static func firstQuoted(_ s: String) -> String? {
        guard let open = s.firstIndex(of: "\""),
              let close = s[s.index(after: open)...].firstIndex(of: "\"")
        else { return nil }
        return String(s[s.index(after: open)..<close])
    }

    // MARK: - Cursor CLI (~/.cursor/hooks.json)

    private static func installCursor(_ pass: Pass) throws {
        // ~/.cursor also exists for IDE-only users; that's intentional — the same
        // hooks.json drives IDE agent sessions, and the bridge is observe-only.
        let cursorDir = pass.home.appendingPathComponent(".cursor")
        guard FileManager.default.fileExists(atPath: cursorDir.path) else { return } // not a Cursor user
        let cfgURL = cursorDir.appendingPathComponent("hooks.json")
        let scriptURL = pass.hooksDir.appendingPathComponent("cursor/cursor.js")
        if !pass.preview { try pinNodeShebang(of: scriptURL, node: pass.node) }

        guard var root = readConfig(at: cfgURL, pass) else { return }
        root["version"] = root["version"] ?? 1
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let marker = cursorMarker

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
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try pass.write(data, to: cfgURL)
        pass.note("cursor")
    }

    /// Cursor runs the script directly via its shebang, and a GUI-launched Cursor
    /// inherits the launchd PATH — often without /opt/homebrew/bin — so
    /// `#!/usr/bin/env node` would silently never fire. Pin the resolved node path.
    private static func pinNodeShebang(of scriptURL: URL, node: String?) throws {
        guard let node else {
            NSLog("AgentBar: node not found, \(scriptURL.lastPathComponent) left on its bundled shebang")
            return
        }
        guard var text = try? String(contentsOf: scriptURL, encoding: .utf8),
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
    private static func installAntigravity(_ pass: Pass) throws {
        let scriptURL = pass.hooksDir.appendingPathComponent("antigravity/antigravity.js")
        let dirs = antigravityDirs(pass)
        guard !dirs.isEmpty else { return } // not an Antigravity user
        if !pass.preview { try pinNodeShebang(of: scriptURL, node: pass.node) }

        // Observational events only. PreToolUse is not decision-free: agy is
        // fail-closed on it, so antigravity.js prints `{"decision":"allow"}` first
        // (see that script and Scripts/hooks/antigravity/README.md).
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
            guard var root = readConfig(at: cfgURL, pass) else { continue }
            root["agentbar"] = group
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try pass.write(data, to: cfgURL)
            pass.note("antigravity")
        }
    }

    // MARK: - Qwen Code (~/.qwen/settings.json)

    /// Qwen Code speaks Claude-style hooks (same event names, same stdin JSON),
    /// so the claude/ scripts serve it as-is — AGENTBAR_AGENT names the rows.
    /// Observational events only: its PermissionRequest decision contract is
    /// unverified against permission.js, and a blocking hook must never be wired
    /// on faith. Timeouts here are milliseconds (Qwen), not seconds (Claude).
    private static func installQwen(_ pass: Pass) throws {
        guard let node = pass.node else { return pass.problem("node was not found, so Qwen hooks were not wired") }
        let qwenDir = pass.home.appendingPathComponent(".qwen")
        guard FileManager.default.fileExists(atPath: qwenDir.path) else { return } // not a Qwen user
        let cfgURL = qwenDir.appendingPathComponent("settings.json")
        let dir = pass.hooksDir.appendingPathComponent("claude").path

        guard var root = readConfig(at: cfgURL, pass) else { return }
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        // Drop earlier AgentBar entries from every event before re-adding.
        hooks = strippingOurs(hooks, marker: claudeMarker).hooks

        let events: [(event: String, cmd: String, matcher: Bool)] = [
            ("SessionStart",     "\"\(node)\" \"\(dir)/lifecycle.js\" start", false),
            ("SessionEnd",       "\"\(node)\" \"\(dir)/lifecycle.js\" end", false),
            ("UserPromptSubmit", "\"\(node)\" \"\(dir)/update.js\" prompt", false),
            ("PreToolUse",       "\"\(node)\" \"\(dir)/update.js\" pre", true),
            ("PostToolUse",      "\"\(node)\" \"\(dir)/update.js\" post", true),
            // Qwen splits the failure paths into their own events; without them
            // a turn that errors out keeps animating as if it were still working.
            ("PostToolUseFailure", "\"\(node)\" \"\(dir)/update.js\" post", true),
            ("Stop",             "\"\(node)\" \"\(dir)/update.js\" stop", false),
            ("StopFailure",      "\"\(node)\" \"\(dir)/update.js\" fail", false),
        ]
        for e in events {
            var rules = hooks[e.event] as? [[String: Any]] ?? []
            let entry: [String: Any] = ["type": "command", "command": e.cmd,
                                        "timeout": 5000,
                                        "env": ["AGENTBAR_AGENT": "qwen"]]
            var rule: [String: Any] = ["hooks": [entry]]
            if e.matcher { rule["matcher"] = "*" }
            rules.append(rule)
            hooks[e.event] = rules
        }
        root["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try pass.write(data, to: cfgURL)
        pass.note("qwen")
    }

    // MARK: - GitHub Copilot CLI (~/.copilot/hooks/agentbar.json)

    /// Copilot CLI hooks come in two spellings, and the PascalCase one delivers the
    /// VS Code/Claude payload shape (`session_id`, `tool_name`, Claude tool names) —
    /// so the claude/ scripts serve it unchanged, with AGENTBAR_AGENT naming the rows.
    ///
    /// `exec` + `args` rather than a `bash` line, for a reason that matters: a shell
    /// wrapper would make the hook's parent a shell that exits immediately, and
    /// `pid: process.ppid` is the liveness handle the app prunes sessions by — every
    /// row would vanish on the next refresh.
    ///
    /// `permissionRequest` blocks and decides, which is what remote Allow/Deny needs.
    /// It was left unwired until its input payload had been logged off a real
    /// session rather than taken on faith — see `Scripts/hooks/copilot/README.md`.
    /// Not `preToolUse`: those are fail-*closed* on a crash, so one unhandled
    /// exception in a status bridge would silently deny a user's tool call.
    ///
    /// AgentBar owns the whole file: Copilot loads every `*.json` in the hooks dir,
    /// so our entries live in ours and the user's live in theirs.
    private static func installCopilot(_ pass: Pass) throws {
        guard let node = pass.node else { return pass.problem("node was not found, so Copilot hooks were not wired") }
        let copilotDir = copilotDir(pass)
        guard FileManager.default.fileExists(atPath: copilotDir.path) else { return } // not a Copilot user
        let hooksFileDir = copilotDir.appendingPathComponent("hooks", isDirectory: true)
        try pass.createDirectory(hooksFileDir)
        let dir = pass.hooksDir.appendingPathComponent("claude").path

        let events: [(event: String, script: String, arg: String?)] = [
            ("SessionStart",       "lifecycle.js", "start"),
            ("SessionEnd",         "lifecycle.js", "end"),
            ("UserPromptSubmit",   "update.js", "prompt"),
            ("PreToolUse",         "update.js", "pre"),
            ("PostToolUse",        "update.js", "post"),
            // A failed tool call is still mid-turn: keep the session working.
            ("PostToolUseFailure", "update.js", "post"),
            ("Stop",               "update.js", "stop"),
            // Only Copilot reports errors as their own event; update.js reads the
            // payload's `recoverable` so a retry doesn't end the turn early.
            ("ErrorOccurred",      "update.js", "fail"),
        ]
        var hooks: [String: Any] = [:]
        for e in events {
            var args = ["\(dir)/\(e.script)"]
            if let arg = e.arg { args.append(arg) }
            hooks[e.event] = [["type": "command", "exec": node, "args": args,
                               "timeoutSec": 5, "env": ["AGENTBAR_AGENT": "copilot"]]]
        }
        // The blocking one. Its timeout must sit ABOVE the hook's own wait (600s,
        // `AGENTBAR_APPROVAL_TIMEOUT` in permission.js) so the hook is the thing that
        // gives up first and exits silently into the terminal prompt — the other way
        // round, Copilot would kill it mid-wait. Claude's entry uses 630 for exactly
        // the same reason. Copilot's own timeouts fail open (1.0.67+), so even that
        // lands on the terminal prompt rather than a denial.
        hooks["permissionRequest"] = [["type": "command", "exec": node,
                                       "args": ["\(dir)/permission.js"],
                                       "timeoutSec": 630,
                                       "env": ["AGENTBAR_AGENT": "copilot"]]]
        let root: [String: Any] = ["version": 1, "hooks": hooks]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try pass.write(data, to: hooksFileDir.appendingPathComponent("agentbar.json"))
        pass.note("copilot")
    }

    // MARK: - OpenCode (~/.config/opencode/plugins/agentbar.js)

    /// OpenCode loads JS plugins from its config dir; ours observes the event bus
    /// and mirrors it into state files. The copy refreshes with the app version.
    private static func installOpenCode(_ pass: Pass) throws {
        let configDir = pass.home.appendingPathComponent(".config/opencode")
        guard FileManager.default.fileExists(atPath: configDir.path) else { return } // not an OpenCode user
        let pluginsDir = configDir.appendingPathComponent("plugins", isDirectory: true)
        try pass.createDirectory(pluginsDir)
        let src = pass.hooksDir.appendingPathComponent("opencode/agentbar.js")
        let dest = pluginsDir.appendingPathComponent("agentbar.js")
        let data = try Data(contentsOf: src)
        // A preview only reaches here for the one-agent preview (see `run`), where
        // the plugin appearing is the whole of the answer.
        if pass.preview { try pass.write(data, to: dest) } else { try writeIfChanged(data, to: dest) }
        pass.note("opencode")
    }

    // MARK: - Gemini CLI (~/.gemini/settings.json)

    private static func installGemini(_ pass: Pass) throws {
        guard let node = pass.node else { return pass.problem("node was not found, so Gemini hooks were not wired") }
        let geminiDir = pass.home.appendingPathComponent(".gemini")
        guard FileManager.default.fileExists(atPath: geminiDir.path) else { return } // not a Gemini user
        let cfgURL = geminiDir.appendingPathComponent("settings.json")
        let script = pass.hooksDir.appendingPathComponent("gemini/gemini.js").path
        let command = "\"\(node)\" \"\(script)\""

        guard var root = readConfig(at: cfgURL, pass) else { return }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let marker = geminiMarker

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
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try pass.write(data, to: cfgURL)
        pass.note("gemini")
    }

    // MARK: - Where each agent lives

    private static func antigravityDirs(_ pass: Pass) -> [URL] {
        ["antigravity", "antigravity-cli"].map {
            pass.home.appendingPathComponent(".gemini/\($0)", isDirectory: true)
        }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// COPILOT_HOME wins when set, exactly as the CLI resolves it.
    private static func copilotDir(_ pass: Pass) -> URL {
        pass.ctx.environment["COPILOT_HOME"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        } ?? pass.home.appendingPathComponent(".copilot")
    }

    // MARK: - Unwiring (an agent the user switched off)

    /// What says a hook command is ours, per script directory. Qwen and Copilot run
    /// the claude/ scripts, so they share Claude's.
    static let claudeMarker = "/.agentbar/hooks/claude/"
    static let cursorMarker = "/.agentbar/hooks/cursor/"
    static let geminiMarker = "/.agentbar/hooks/gemini/"

    /// `hooks` without every rule that runs one of our scripts, and without any event
    /// that leaves empty. A rule is ours when `marker` is in its own `command` (Cursor's
    /// flat shape) or in any of its nested `hooks[].command` (Claude, Qwen, Gemini).
    /// Values that are not a list of rules are left exactly as they are.
    static func strippingOurs(_ hooks: [String: Any], marker: String) -> (hooks: [String: Any], removed: Bool) {
        func ours(_ rule: [String: Any]) -> Bool {
            if (rule["command"] as? String)?.contains(marker) == true { return true }
            return ((rule["hooks"] as? [[String: Any]]) ?? []).contains {
                ($0["command"] as? String)?.contains(marker) == true
            }
        }
        var out = hooks
        var removed = false
        for (event, value) in hooks {
            guard var rules = value as? [[String: Any]] else { continue }
            let before = rules.count
            rules.removeAll(where: ours)
            guard rules.count != before else { continue }
            removed = true
            if rules.isEmpty { out.removeValue(forKey: event) } else { out[event] = rules }
        }
        return (out, removed)
    }

    /// The JSON configs that keep our entries among the user's under `hooks`: our
    /// rules come out, an emptied `hooks` goes, everything else is serialized exactly
    /// the way the installer serializes it. A file holding nothing of ours is not
    /// rewritten at all — unwiring must never reformat a file it had no part in.
    private static func unwireHooksJSON(at url: URL, marker: String, _ pass: Pass) throws {
        guard FileManager.default.fileExists(atPath: url.path),
              var root = readConfig(at: url, pass),
              let hooks = root["hooks"] as? [String: Any] else { return }
        let (left, removed) = strippingOurs(hooks, marker: marker)
        guard removed else { return }
        if left.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = left }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try pass.write(data, to: url)
    }

    private static func unwireClaude(configDir: URL, _ pass: Pass) throws {
        try unwireHooksJSON(at: configDir.appendingPathComponent("settings.json"),
                            marker: claudeMarker, pass)
        pass.unnote("claude")
    }

    // MARK: - The Claude Code mod (<configDir>/settings.json → env.CLAUDE_CODE_PLUGIN_DIRS)

    /// Our mod's directory into one Claude config's plugin list, through the same
    /// backed-up, previewable write as every other setting. Skipped — with a line,
    /// never a half-measure — when that Claude Code is known to be too old, when
    /// the mod was never copied (there would be nothing at the path), when the
    /// config dir does not exist, and when the file or its `env` is not ours to read.
    /// Not noted for the welcome window: that list is agents, and this is not one.
    private static func wireClaudeMod(configDir: URL, _ pass: Pass) throws {
        guard ClaudeModWiring.supports(pass.ctx.claudeVersion) else {
            NSLog("AgentBar: Claude Code \(pass.ctx.claudeVersion ?? "?") predates mods "
                  + "(\(ClaudeModWiring.minimumVersion)) — the Claude Code mod is not wired")
            return
        }
        let modDir = pass.ctx.claudeModDir
        guard FileManager.default.fileExists(atPath: modDir.path) else {
            NSLog("AgentBar: \(modDir.path) is missing — the Claude Code mod is not wired")
            return
        }
        guard FileManager.default.fileExists(atPath: configDir.path) else { return }
        let url = configDir.appendingPathComponent("settings.json")
        guard let root = readConfig(at: url, pass) else { return }
        let (plan, next) = ClaudeModWiring.wired(root, modDir: modDir.path)
        switch plan {
        case .unchanged: return
        case .refused(let why):
            NSLog("AgentBar: \(url.path): \(why) — the Claude Code mod is not wired there")
        case .write:
            let data = try JSONSerialization.data(withJSONObject: next, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try pass.write(data, to: url)
        }
    }

    private static func unwireClaudeMod(configDir: URL, _ pass: Pass) throws {
        let url = configDir.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: url.path), let root = readConfig(at: url, pass) else { return }
        let (plan, next) = ClaudeModWiring.unwired(root)
        guard plan == .write else { return }
        let data = try JSONSerialization.data(withJSONObject: next, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try pass.write(data, to: url)
    }

    /// The Claude Code on this Mac: the cheap places first (`ClaudeQuota`), then
    /// `claude --version`, which only an npm-installed Claude Code needs.
    static func claudeCodeVersion() -> String? {
        if let v = ClaudeQuota.installedCLIVersion() { return v }
        guard let claude = Launcher.resolve("claude"),
              let out = WorkDiff.run(claude, ["--version"], in: NSTemporaryDirectory(), timeout: 5)
        else { return nil }
        return ClaudeModWiring.parseVersion(out)
    }

    private static func unwireQwen(_ pass: Pass) throws {
        try unwireHooksJSON(at: pass.home.appendingPathComponent(".qwen/settings.json"),
                            marker: claudeMarker, pass)
        pass.unnote("qwen")
    }

    private static func unwireGemini(_ pass: Pass) throws {
        try unwireHooksJSON(at: pass.home.appendingPathComponent(".gemini/settings.json"),
                            marker: geminiMarker, pass)
        pass.unnote("gemini")
    }

    /// `version` stays: the installer adds it only when missing, and Cursor wants it.
    private static func unwireCursor(_ pass: Pass) throws {
        try unwireHooksJSON(at: pass.home.appendingPathComponent(".cursor/hooks.json"),
                            marker: cursorMarker, pass)
        pass.unnote("cursor")
    }

    /// We own exactly one top-level key in each Antigravity hooks.json.
    private static func unwireAntigravity(_ pass: Pass) throws {
        for dir in antigravityDirs(pass) {
            let url = dir.appendingPathComponent("hooks.json")
            guard FileManager.default.fileExists(atPath: url.path),
                  var root = readConfig(at: url, pass), root["agentbar"] != nil else { continue }
            root.removeValue(forKey: "agentbar")
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try pass.write(data, to: url)
        }
        pass.unnote("antigravity")
    }

    /// The whole file is ours, so the whole file goes — kept beside itself first.
    private static func unwireCopilot(_ pass: Pass) throws {
        try pass.remove(copilotDir(pass).appendingPathComponent("hooks/agentbar.json"))
        pass.unnote("copilot")
    }

    private static func unwireOpenCode(_ pass: Pass) throws {
        try pass.remove(pass.home.appendingPathComponent(".config/opencode/plugins/agentbar.js"))
        pass.unnote("opencode")
    }

    /// Same refusals as `installCodex`: unreadable or not UTF-8 is left alone.
    private static func unwireCodex(_ pass: Pass) throws {
        let url = pass.home.appendingPathComponent(".codex/config.toml")
        guard let data = try? Data(contentsOf: url) else { return }
        guard let config = String(data: data, encoding: .utf8) else {
            NSLog("AgentBar: ~/.codex/config.toml is not UTF-8 — leaving it untouched")
            return
        }
        let next = codexUnwired(config: config)
        if next != config { try pass.write(Data(next.utf8), to: url) }
        pass.unnote("codex")
    }

    /// The config without AgentBar's hooks block and without AgentBar's own `notify`
    /// line — the inverse of the two plans, so wiring and then unwiring a file gives
    /// back the file (bar a final newline the install had to add). Someone else's
    /// notify is never touched, and neither is our marker in a shape the line pattern
    /// cannot read: the same line `codexPlan` draws. Pure, so it is a test.
    static func codexUnwired(config: String) -> String {
        var text = config
        if let begin = text.range(of: codexBegin),
           let end = text.range(of: codexEnd, range: begin.upperBound..<text.endIndex) {
            var lower = begin.lowerBound
            var upper = end.upperBound
            if upper < text.endIndex, text[upper] == "\n" { upper = text.index(after: upper) }
            // The blank line `codexHooksPlan` put above the block.
            if text[..<lower].hasSuffix("\n\n") { lower = text.index(before: lower) }
            text.removeSubrange(lower..<upper)
        }
        let ourLine = #"(?m)^[ \t]*notify[ \t]*=[ \t]*\[[^\]]*/\.agentbar/hooks/codex/[^\]]*\]"#
        if var line = text.range(of: ourLine, options: .regularExpression) {
            if line.upperBound < text.endIndex, text[line.upperBound] == "\n" {
                line = line.lowerBound..<text.index(after: line.upperBound)
            }
            text.removeSubrange(line)
        }
        return text
    }
}
