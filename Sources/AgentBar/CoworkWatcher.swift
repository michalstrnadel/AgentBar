import Cocoa

/// Live status for Claude Cowork sessions — the agent mode inside the Claude
/// desktop app.
///
/// Hooks can't reach these. Cowork spawns Claude Code with `CLAUDE_CONFIG_DIR`
/// pointing at a directory it creates *per session*
/// (`…/local-agent-mode-sessions/<account>/<org>/<session>/.claude`) and loads
/// only the `user` setting source from it, under the name `cowork_settings.json`
/// — so there is no stable file AgentBar could install hooks into, and a session
/// running in VM mode executes the CLI inside a sandbox that can't write to
/// `~/.agentbar` anyway.
///
/// What the desktop app does write, on the host, unconditionally, for every
/// session, is `<session>/audit.jsonl`: one JSON line per turn event, including
/// `permission_request` / `permission_response` pairs. That is the signal this
/// watcher reads, upserting state files on the same `~/.agentbar/state.d`
/// protocol the hooks use.
final class CoworkWatcher {
    private static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions",
                                isDirectory: true)

    private static let claudeBundleID = "com.anthropic.claudefordesktop"

    /// Session directories (and their sibling metadata JSON) are named `local_<uuid>`.
    private static let sessionPrefix = "local_"

    /// A working turn appends to the audit log constantly — measured on real
    /// transcripts the median gap is ~1s and p95 ~5s; the only longer gaps are the
    /// app waiting on the human, which we detect explicitly. 90s of silence
    /// therefore means the turn is over, even when it ended without a `result`
    /// (app quit, crash, cancelled turn).
    private static let workingWindow: TimeInterval = 90

    /// An unanswered `permission_request` stays pending until the user answers it
    /// in the app — there is no timeout on their side. Past this the session is
    /// treated as abandoned rather than waiting, so a prompt left open yesterday
    /// doesn't come back as "needs approval" when AgentBar restarts.
    private static let pendingWindow: TimeInterval = 6 * 3600

    /// A request and its response land within ~3 KB of each other, so a tail this
    /// size always holds the pair when one exists. Audit logs reach tens of MB —
    /// they are never read whole.
    private static let tailBytes: UInt64 = 1024 * 1024
    private static let tailLines = 200

    /// One audit line can be megabytes on its own (a tool result carrying a
    /// base64 image — 6.6 MB observed). Those are `user`/`assistant` payloads,
    /// never a permission or result event, so they are counted but not decoded.
    private static let maxParsableLine = 512 * 1024

    private var timer: Timer?
    /// Session dir path -> what we last published for it, so an audit log that
    /// hasn't moved isn't re-parsed. "thinking" is exempt: it ages out on its own.
    private var published: [String: (ts: TimeInterval, state: String)] = [:]
    /// Session dir path -> (metadata mtime, title).
    private var titles: [String: (stamp: Date, title: String)] = [:]

    func start() {
        guard FileManager.default.fileExists(atPath: Self.root.path) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.scan()
        }
    }

    private func scan() {
        // No app, no Cowork. Its pid also anchors every row we write: SessionStore
        // prunes on a dead pid, so quitting Claude clears the sessions by itself.
        guard let claude = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == Self.claudeBundleID
        }) else { return }
        let pid = claude.processIdentifier
        let now = Date().timeIntervalSince1970

        for dir in Self.sessionDirs() {
            let audit = dir.appendingPathComponent("audit.jsonl")
            guard let mtime = (try? FileManager.default.attributesOfItem(atPath: audit.path))?[.modificationDate]
                    as? Date else { continue }
            let ts = mtime.timeIntervalSince1970
            let age = now - ts
            guard age < Self.pendingWindow else { continue }
            // Settled state on an untouched log: nothing can have changed.
            if let prev = published[dir.path], prev.ts == ts, prev.state != "thinking" { continue }
            guard let read = Self.inspect(audit) else { continue }

            var state = "done"
            var label = ""
            if let pending = read.pending {
                let tool = pending["tool_name"] as? String ?? "tool"
                if tool == "AskUserQuestion" {
                    // Claude asking the human, not asking for permission — same
                    // distinction the Claude hook makes.
                    let q = ((pending["tool_input"] as? [String: Any])?["questions"] as? [[String: Any]])?
                        .first?["question"] as? String
                    state = "question"
                    label = "❓ " + Self.oneLine(q ?? "Waiting for your answer")
                } else {
                    state = "permission"
                    label = Self.prettyTool(tool)
                }
            } else if !read.finished, age < Self.workingWindow {
                state = "thinking"
            }

            upsert(dir: dir, state: state, label: label, ts: ts, pid: pid,
                   recap: state == "done" ? read.recap : "")
            published[dir.path] = (ts, state)
        }
    }

    // MARK: - Layout

    /// `<root>/<accountId>/<orgId>/local_*` plus the `agent/` subtree the app uses
    /// for its own background agent sessions. Both hold the same session layout.
    private static func sessionDirs() -> [URL] {
        var out: [URL] = []
        for account in directories(in: root) {
            for org in directories(in: account) {
                out += sessions(in: org)
                out += sessions(in: org.appendingPathComponent("agent", isDirectory: true))
            }
        }
        return out
    }

    private static func sessions(in dir: URL) -> [URL] {
        directories(in: dir).filter { $0.lastPathComponent.hasPrefix(sessionPrefix) }
    }

    private static func directories(in dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return items.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    /// The session's display name lives in the metadata file sitting next to its
    /// directory (`local_<uuid>.json`): `title` once the app has named the
    /// conversation, otherwise the generated process name.
    private func title(for dir: URL) -> String {
        let meta = dir.deletingLastPathComponent()
            .appendingPathComponent(dir.lastPathComponent + ".json")
        let stamp = (try? FileManager.default.attributesOfItem(atPath: meta.path))?[.modificationDate] as? Date
        if let cached = titles[dir.path], cached.stamp == stamp { return cached.title }
        var name = "Cowork session"
        if let data = try? Data(contentsOf: meta),
           let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let title = (o["title"] as? String) ?? ""
            let process = (o["processName"] as? String) ?? ""
            if !title.isEmpty { name = Self.oneLine(title) } else if !process.isEmpty { name = process }
        }
        if let stamp { titles[dir.path] = (stamp, name) }
        return name
    }

    // MARK: - Audit log

    /// Reads the tail of an audit log and answers the two questions the state
    /// machine needs: has the turn ended, and is a permission prompt open.
    ///
    /// nil means the log couldn't be read at all. An *empty* tail is not nil: a
    /// single line longer than the whole window leaves no complete line to parse,
    /// and the session must still be reported (it is plainly active — something
    /// just wrote megabytes into it) rather than dropped from the menu.
    private static func inspect(_ url: URL) -> (finished: Bool, pending: [String: Any]?, recap: String)? {
        guard let lines = tail(url) else { return nil }

        // One slot per line, so `events.last` really is the last line: an unparsed
        // blob is an event we know isn't a `result` and isn't a permission event.
        var events: [[String: Any]] = []
        events.reserveCapacity(lines.count)
        for line in lines {
            guard line.utf8.count <= maxParsableLine,
                  let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            else { events.append([:]); continue }
            events.append(o)
        }

        var pending: [String: Any]?
        if let i = events.lastIndex(where: { $0["subtype"] as? String == "permission_request" }) {
            let uuid = events[i]["uuid"] as? String ?? ""
            let answered = events[(i + 1)...].contains {
                $0["subtype"] as? String == "permission_response" && $0["uuid"] as? String == uuid
            }
            if !answered { pending = events[i] }
        }
        let finished = events.last?["type"] as? String == "result"
        // The result event carries the turn's closing words — the same recap the
        // Claude hook reads from its transcript, from the only signal Cowork has.
        let recap = finished ? cleanRecap(events.last?["result"] as? String ?? "") : ""
        return (finished, pending, recap)
    }

    /// One quiet line out of a markdown result: fences and list furniture out,
    /// link text kept (Cowork results end with a `computer://` link whose text is
    /// the deliverable's name), whitespace collapsed, capped at 160.
    private static func cleanRecap(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?m)^#{1,6}\\s+", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?m)^\\s*[-*+]\\s+", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?m)^\\s*\\d+[.)]\\s+", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "[`*_]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return String(t.prefix(160))
    }

    /// Complete lines at the end of the file, oldest first. Walks backwards in
    /// blocks until it has seen enough newlines or read `tailBytes`, then decodes
    /// from there and drops the leading fragment.
    private static func tail(_ url: URL) -> [Substring]? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        guard size > 0 else { return nil }
        let block: UInt64 = 64 * 1024
        var from = size
        var newlines = 0
        while from > 0, size - from < tailBytes, newlines <= tailLines {
            let chunk = min(block, from)
            from -= chunk
            try? fh.seek(toOffset: from)
            guard let d = try? fh.read(upToCount: Int(chunk)) else { break }
            newlines += d.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        }
        try? fh.seek(toOffset: from)
        guard let data = try? fh.readToEnd() else { return nil }
        // Lossy on purpose: the window can start mid-codepoint, and the damage is
        // confined to the partial first line, which is dropped anyway.
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        if from > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    /// `mcp__cowork__request_cowork_directory` → `request_cowork_directory`;
    /// `webfetch:github.com` → `webfetch: github.com`. Remote MCP servers are
    /// namespaced by uuid, which is worth nothing in a menu row.
    private static func prettyTool(_ raw: String) -> String {
        var tool = raw
        if tool.hasPrefix("mcp__") {
            tool = tool.components(separatedBy: "__").last ?? tool
        }
        if let colon = tool.firstIndex(of: ":"), tool.index(after: colon) < tool.endIndex,
           tool[tool.index(after: colon)] != " " {
            tool.replaceSubrange(colon...colon, with: ": ")
        }
        return oneLine(tool)
    }

    private static func oneLine(_ s: String) -> String {
        let flat = s.split(whereSeparator: { $0.isNewline || $0 == "\t" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count > 80 ? String(flat.prefix(79)) + "…" : flat
    }

    // MARK: - State file

    private func upsert(dir: URL, state: String, label: String, ts: TimeInterval, pid: Int32,
                        recap: String = "") {
        let id = String(dir.lastPathComponent.filter { $0.isLetter || $0.isNumber || "-_.".contains($0) }
            .prefix(64))
        guard !id.isEmpty else { return }
        let url = SessionStore.stateDir.appendingPathComponent(id + ".json")
        var o = ((try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
        guard (o["agent"] as? String ?? "claude") == "claude" else { return }
        // Nothing visible changed and the row already points at this app instance.
        if o["state"] as? String == state, o["label"] as? String == label,
           o["pid"] as? Int == Int(pid), (o["ts"] as? Double ?? 0) >= ts { return }
        o["agent"] = "claude"
        o["state"] = state
        o["label"] = label
        o["project"] = title(for: dir)
        o["entrypoint"] = "claude-desktop" // row clicks focus the app, not a terminal
        o["term_program"] = ""
        o["cwd"] = "" // sandboxed scratch dir; showing it would only be noise
        o["pid"] = Int(pid)
        o["started"] = true
        o["sessionId"] = id
        // Set once; elapsed in the frontends depends on it never moving.
        if o["started_at"] == nil { o["started_at"] = Int(ts) }
        // Protocol rule: recap is the LATEST turn's result — a working state must
        // drop the previous turn's line, never carry it forward.
        if state == "done", !recap.isEmpty { o["recap"] = recap } else { o.removeValue(forKey: "recap") }
        o["ts"] = Int(ts)
        guard let data = try? JSONSerialization.data(withJSONObject: o) else { return }
        try? FileManager.default.createDirectory(at: SessionStore.stateDir,
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
