import Foundation

/// Liveness for Google Antigravity beyond its sparse hooks: the desktop engine
/// (2.3.x) fires only PostToolUse, and the `agy` CLI (2.x) loads hooks.json but
/// never runs the handlers at all — so chat-only turns, and CLI sessions
/// entirely, emit no hook events. The per-conversation turn transcript under
/// brain/<id>/ is appended to only while the agent actually generates — a fresh
/// mtime is the "working" signal. (The conversation .db files are NOT usable for
/// this: the app also touches them during background housekeeping, which kept
/// sessions "working" forever.) The watcher upserts state files on the same
/// ~/.agentbar/state.d protocol the hooks use (hooks stay authoritative: a newer
/// hook write wins), and SessionStore's decay turns quiet sessions to done.
final class AntigravityWatcher {
    /// One Antigravity install root. Each product keeps its own brain/ tree under
    /// ~/.gemini and they run side by side, so all of them have to be scanned.
    private struct Root {
        let brain: URL
        /// "antigravity-app" -> row clicks focus the app; "cli" -> the terminal.
        let entrypoint: String
        /// CLI only: JSONL of user prompts, the one place a conversation id is
        /// tied to its workspace path.
        let history: URL?
    }

    private static let gemini = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini", isDirectory: true)

    private static func root(_ dir: String, entrypoint: String, history: Bool = false) -> Root {
        let base = gemini.appendingPathComponent(dir, isDirectory: true)
        return Root(brain: base.appendingPathComponent("brain", isDirectory: true),
                    entrypoint: entrypoint,
                    history: history ? base.appendingPathComponent("history.jsonl") : nil)
    }

    private static let roots = [
        root("antigravity", entrypoint: "antigravity-app"),
        root("antigravity-cli", entrypoint: "cli", history: true),
    ]

    private var timer: Timer?
    /// conversation id -> workspace path, rebuilt when history.jsonl changes.
    private var workspaces: [String: String] = [:]
    private var historyStamp: Date?
    /// conversation id -> hosting `agy` process, resolved once per session.
    private var hosts: [String: (pid: Int32, term: String)] = [:]
    private var resolving: Set<String> = []

    func start() {
        let fm = FileManager.default
        guard Self.roots.contains(where: { fm.fileExists(atPath: $0.brain.path) }) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.scan()
        }
    }

    private func scan() {
        let fm = FileManager.default
        let now = Date().timeIntervalSince1970
        for r in Self.roots {
            loadHistory(r)
            let dirs = (try? fm.contentsOfDirectory(at: r.brain, includingPropertiesForKeys: nil)) ?? []
            for dir in dirs {
                let transcript = dir.appendingPathComponent(".system_generated/logs/transcript_full.jsonl")
                guard let mtime = (try? fm.attributesOfItem(atPath: transcript.path))?[.modificationDate]
                        as? Date else { continue }
                let ts = mtime.timeIntervalSince1970
                let age = now - ts
                let id = dir.lastPathComponent
                if age < 6 {
                    // Live turn. A final MODEL …_RESPONSE without tool_calls means the
                    // agent has answered — flip to done immediately, no decay wait.
                    let last = Self.lastEntry(transcript)
                    upsert(id: id, root: r, ts: ts,
                           state: Self.isFinalResponse(last) ? "done" : "thinking")
                } else if age < 900 {
                    // Quiet with an unexecuted tool request as the last entry: the agent
                    // is sitting on its own approval prompt (auto-allowed tools append
                    // their result within moments).
                    if let tool = Self.pendingToolCall(Self.lastEntry(transcript)) {
                        // ask_permission is the prompt itself, not a tool worth naming
                        upsert(id: id, root: r, ts: ts, state: "permission",
                               label: tool == "ask_permission" ? "" : tool)
                    }
                }
            }
        }
    }

    /// The CLI appends one line per user prompt, carrying `conversationId` and
    /// `workspace` — the only cheap source for a CLI session's project name.
    private func loadHistory(_ r: Root) {
        guard let history = r.history,
              let stamp = (try? FileManager.default.attributesOfItem(atPath: history.path))?[.modificationDate]
                as? Date, stamp != historyStamp
        else { return }
        historyStamp = stamp
        guard let text = try? String(contentsOf: history, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let id = o["conversationId"] as? String, let ws = o["workspace"] as? String
            else { continue }
            workspaces[id] = ws
        }
    }

    /// The `agy` process serving a conversation holds files under its brain/<id>
    /// open, and its environment names the hosting terminal. Resolved off the main
    /// thread once per session; the answer lands on a later tick.
    private func host(for id: String) -> (pid: Int32, term: String)? {
        if let h = hosts[id] { return h }
        guard !resolving.contains(id) else { return nil }
        resolving.insert(id)
        DispatchQueue.global(qos: .utility).async {
            let found = Self.findHost(conversation: id)
            DispatchQueue.main.async { [weak self] in
                self?.resolving.remove(id)
                if let found { self?.hosts[id] = found }
            }
        }
        return nil
    }

    private static func findHost(conversation id: String) -> (pid: Int32, term: String)? {
        // lsof -F prints one field per line: "p<pid>" opens a process block, "n<path>"
        // is a name inside it.
        guard let out = run("/usr/sbin/lsof", ["-c", "agy", "-Fpn"]) else { return nil }
        var pid: Int32 = 0
        for line in out.split(separator: "\n") {
            switch line.first {
            case "p": pid = Int32(line.dropFirst()) ?? 0
            case "n" where pid > 0 && line.contains("/brain/" + id + "/"):
                let env = run("/bin/ps", ["-Eww", "-p", String(pid)]) ?? ""
                let term = env.split(whereSeparator: { $0 == " " || $0 == "\n" })
                    .first { $0.hasPrefix("TERM_PROGRAM=") }
                    .map { String($0.dropFirst("TERM_PROGRAM=".count)) } ?? ""
                return (pid, term)
            default: break
            }
        }
        return nil
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    private static func lastEntry(_ url: URL) -> [String: Any]? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: size - min(size, 8192))
        guard let data = try? fh.readToEnd(),
              let text = String(data: data, encoding: .utf8),
              let last = text.split(separator: "\n")
                .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(last.utf8))) as? [String: Any]
    }

    private static func isFinalResponse(_ o: [String: Any]?) -> Bool {
        guard let o else { return false }
        return o["source"] as? String == "MODEL"
            && o["status"] as? String == "DONE"
            && (o["type"] as? String ?? "").hasSuffix("RESPONSE")
            && o["tool_calls"] == nil
    }

    private static func pendingToolCall(_ o: [String: Any]?) -> String? {
        guard let o, o["source"] as? String == "MODEL",
              let calls = o["tool_calls"] as? [[String: Any]], let first = calls.first
        else { return nil }
        return first["name"] as? String ?? "tool"
    }

    private func upsert(id: String, root r: Root, ts: TimeInterval, state: String, label: String? = nil) {
        let safe = String(id.filter { $0.isLetter || $0.isNumber || "-_.".contains($0) }.prefix(64))
        guard !safe.isEmpty else { return }
        let url = SessionStore.stateDir.appendingPathComponent(safe + ".json")
        var o = ((try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
        guard (o["agent"] as? String ?? "antigravity") == "antigravity" else { return }
        // A hook write with a newer ts is authoritative; a same-ts state change
        // (thinking → permission after the quiet threshold) must still land.
        let prevTs = o["ts"] as? Double ?? 0
        guard ts > prevTs || (ts >= prevTs && state != (o["state"] as? String)) else { return }
        o["agent"] = "antigravity"
        o["state"] = state
        o["started"] = true
        if let label { o["label"] = label }
        o["ts"] = Int(ts)
        o["sessionId"] = safe
        o["entrypoint"] = r.entrypoint
        if r.entrypoint == "cli" {
            if let cwd = workspaces[id] {
                o["cwd"] = cwd
                o["project"] = URL(fileURLWithPath: cwd).lastPathComponent
            }
            // Terminal identity and pid come from the live `agy` process. Without them
            // the row still shows; it just falls back to the preferred terminal and to
            // the 24h staleness prune instead of dying with the process.
            if let h = host(for: id) {
                o["term_program"] = h.term
                o["pid"] = Int(h.pid)
            }
        } else {
            // Desktop sessions belong to the app — row clicks must focus it, not a
            // terminal (an early bridge version misdetected "cli" here).
            o["term_program"] = ""
        }
        guard let data = try? JSONSerialization.data(withJSONObject: o) else { return }
        try? FileManager.default.createDirectory(at: SessionStore.stateDir,
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
