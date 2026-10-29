import Foundation

/// Over the shoulder: what a working Claude Code session is doing right now, read
/// from the end of its own transcript — the tools it reached for, in a word and an
/// argument, and the last thing it said. For the island's first row, so a glance
/// answers "what is it up to" without going to the terminal.
///
/// Read-only and local: the transcript is the file Claude Code already writes, and
/// nothing here leaves the Mac. Only what the transcript says; a session without
/// one shows nothing.
enum LiveFeed {
    enum Item: Equatable {
        /// A tool call: "Read", "Session.swift".
        case tool(String, String)
        /// The agent's own words, the last sentence or so.
        case said(String)
    }

    /// How much of the transcript's end is read — several turns' worth of steps.
    static let tailBytes = 96 * 1024
    static let maxItems = 4

    /// The newest items in these transcript lines (oldest first), newest last.
    /// Only the current turn: everything before the last prompt the person typed
    /// belongs to an earlier task.
    static func items(_ lines: [Substring]) -> [Item] {
        var out: [Item] = []
        for line in lines {
            guard line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\""),
                  let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = o["message"] as? [String: Any] else { continue }
            if o["type"] as? String == "user" {
                // A prompt typed by the person starts a new turn. A tool result is
                // part of this one, and so is what the harness injects (meta lines,
                // task notifications — they start with "<").
                if o["isMeta"] as? Bool != true, isPrompt(message["content"]) { out = [] }
                continue
            }
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    let said = lastWords(block["text"] as? String ?? "")
                    if !said.isEmpty { out.append(.said(said)) }
                case "tool_use":
                    let name = block["name"] as? String ?? ""
                    if let item = tool(name, block["input"] as? [String: Any] ?? [:]) { out.append(item) }
                default:
                    break
                }
            }
        }
        return Array(out.suffix(maxItems))
    }

    static func isPrompt(_ content: Any?) -> Bool {
        if let text = content as? String { return !text.hasPrefix("<") }
        guard let blocks = content as? [[String: Any]] else { return false }
        return blocks.contains { $0["type"] as? String == "text" && !(($0["text"] as? String ?? "").hasPrefix("<")) }
            && !blocks.contains { $0["type"] as? String == "tool_result" }
    }

    /// The call as a word and its argument: a command's first line, a file's name,
    /// a pattern, a host, a subagent's task. Bookkeeping tools are left out.
    static func tool(_ name: String, _ input: [String: Any]) -> Item? {
        func s(_ k: String) -> String { (input[k] as? String) ?? "" }
        let arg: String
        switch name {
        case "Bash":
            arg = s("command").split(separator: "\n").first.map(String.init) ?? ""
        case "Read", "Edit", "Write", "MultiEdit", "NotebookEdit":
            arg = (s("file_path").isEmpty ? s("notebook_path") : s("file_path")).split(separator: "/").last.map(String.init) ?? ""
        case "Grep", "Glob":
            arg = s("pattern")
        case "WebFetch":
            arg = URL(string: s("url"))?.host ?? s("url")
        case "WebSearch":
            arg = s("query")
        case "Agent", "Task":
            arg = s("description")
        case "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "ToolSearch":
            return nil
        default:
            // An MCP tool: its own name, without the server prefix.
            let short = name.hasPrefix("mcp__") ? (name.components(separatedBy: "__").last ?? name) : name
            return name.isEmpty ? nil : .tool(short, "")
        }
        return .tool(name, ApprovalRequest.oneLine(arg).prefixed(70))
    }

    /// The last sentence of what the agent said, one line, at most 140 characters.
    static func lastWords(_ text: String) -> String {
        let flat = ApprovalRequest.oneLine(text)
        guard !flat.isEmpty else { return "" }
        var cut = flat
        if flat.count > 140 {
            // Prefer a sentence boundary inside the last 140 characters.
            let tail = String(flat.suffix(140))
            if let dot = tail.range(of: ". ") { cut = String(tail[dot.upperBound...]) } else { cut = "…" + tail }
        }
        return cut
    }

    // MARK: - Reading

    private static var cache: [String: (mtime: Date, items: [Item])] = [:]

    /// Fixed feeds by session id, for Scripts/dev/render-preview.swift.
    static var preview: [String: [Item]] = [:]

    /// The feed for a Claude Code session, re-read only when the transcript moved.
    static func read(_ s: Session) -> [Item] {
        if let fixed = preview[s.id] { return fixed }
        guard s.agentID == "claude",
              let url = WeightReader.transcript(sessionId: s.id, cwd: s.cwd),
              let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return [] }
        if let hit = cache[url.path], hit.mtime == mtime { return hit.items }
        let items = Self.items(tail(url))
        cache[url.path] = (mtime, items)
        return items
    }

    private static func tail(_ url: URL) -> [Substring] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd() else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n")
        // A read that began mid-line has a broken first line.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }
}

private extension String {
    func prefixed(_ n: Int) -> String { count > n ? String(prefix(n - 1)) + "…" : self }
}
