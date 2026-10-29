import Foundation

/// Over the shoulder: what a working Claude Code session is doing right now, read
/// from the end of its own transcript — the tools it reached for, in a word and an
/// argument, and the last thing it said. For the island's first row, so a glance
/// answers "what is it up to" without going to the terminal.
///
/// Codex sessions get the same feed from their rollout file (`CodexFeed`).
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

    /// The tail of a shell command's output, drawn under that command's line.
    struct Output: Equatable {
        /// The last few non-empty lines, escape codes stripped, oldest first.
        var lines: [String]
        /// The command failed (its result says `is_error`).
        var isError: Bool
        /// The item it belongs under: an index into `Feed.items`.
        var after: Int
    }

    /// What the island draws: the items, and the newest finished command's output.
    struct Feed: Equatable {
        var items: [Item]
        var output: Output?
        init(items: [Item], output: Output? = nil) {
            self.items = items
            self.output = output
        }
        var isEmpty: Bool { items.isEmpty }
    }

    /// How much of the transcript's end is read — several turns' worth of steps.
    static let tailBytes = 96 * 1024
    static let maxItems = 4
    /// Lines of a command's output shown under it.
    static let maxOutputLines = 3
    /// Items and output lines together: the feed never grows the island past this.
    static let maxLines = 6

    /// The newest items in these transcript lines (oldest first), newest last.
    /// Only the current turn: everything before the last prompt the person typed
    /// belongs to an earlier task.
    static func items(_ lines: [Substring]) -> [Item] { feed(lines).items }

    /// The items, plus the output of the newest Bash call in this turn whose result
    /// is already in the transcript — matched to its call by id, never by position.
    static func feed(_ lines: [Substring]) -> Feed {
        var out: [Item] = []
        // This turn's Bash calls: tool_use id → index in `out`.
        var bash: [String: Int] = [:]
        var result: Output?
        for line in lines {
            guard line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\""),
                  let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = o["message"] as? [String: Any] else { continue }
            if o["type"] as? String == "user" {
                // A prompt typed by the person starts a new turn. A tool result is
                // part of this one, and so is what the harness injects (meta lines,
                // task notifications — they start with "<").
                if o["isMeta"] as? Bool != true, isPrompt(message["content"]) {
                    out = []
                    bash = [:]
                    result = nil
                    continue
                }
                for block in message["content"] as? [[String: Any]] ?? []
                where block["type"] as? String == "tool_result" {
                    guard let id = block["tool_use_id"] as? String, let at = bash[id],
                          at >= (result?.after ?? -1) else { continue }
                    let tail = outputTail(block["content"])
                    guard !tail.isEmpty else { continue }
                    result = Output(lines: tail, isError: block["is_error"] as? Bool == true, after: at)
                }
                continue
            }
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    let said = lastWords(block["text"] as? String ?? "")
                    if !said.isEmpty { out.append(.said(said)) }
                case "tool_use":
                    let name = block["name"] as? String ?? ""
                    if let item = tool(name, block["input"] as? [String: Any] ?? [:]) {
                        if name == "Bash", let id = block["id"] as? String { bash[id] = out.count }
                        out.append(item)
                    }
                default:
                    break
                }
            }
        }
        var items = Array(out.suffix(maxItems))
        guard var output = result else { return Feed(items: items) }
        output.after -= out.count - items.count
        // Its command scrolled off the top: the output goes with it.
        guard output.after >= 0 else { return Feed(items: items) }
        // Keep the total bounded: older items go first, then older output lines.
        while items.count + output.lines.count > maxLines {
            if output.after > 0 {
                items.removeFirst()
                output.after -= 1
            } else {
                output.lines.removeFirst()
            }
        }
        return Feed(items: items, output: output)
    }

    /// The last non-empty lines of a tool result as plain text. The content is a
    /// string or an array of text blocks; escape codes and carriage-return
    /// redraws (a progress bar's earlier states) are dropped, tabs become spaces.
    static func outputTail(_ content: Any?, max: Int = maxOutputLines) -> [String] {
        let text: String
        if let s = content as? String {
            text = s
        } else if let blocks = content as? [[String: Any]] {
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
        } else {
            return []
        }
        // Only the end matters; a huge result is not scanned whole.
        let clean = stripANSI(String(text.suffix(8 * 1024)))
        var kept: [String] = []
        for raw in clean.split(separator: "\n").reversed() {
            let last = raw.split(separator: "\r").last.map(String.init) ?? ""
            let line = last.replacingOccurrences(of: "\t", with: "  ").trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            kept.append(line.prefixed(200))
            if kept.count == max { break }
        }
        return kept.reversed()
    }

    /// Terminal escape sequences out: CSI (colours, cursor moves), OSC (titles,
    /// links), and any stray ESC left over.
    static func stripANSI(_ s: String) -> String {
        guard s.contains("\u{1B}") || s.contains("\u{9B}") else { return s }
        return s
            .replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(\u{1B}\\[|\u{9B})[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}[@-_]?", with: "", options: .regularExpression)
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
            arg = withoutCd(s("command").split(separator: "\n").first.map(String.init) ?? "")
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

    /// The command without the `cd <dir> &&` agents put in front of it, so the part
    /// that does something is what fits: `cd "/Users/…/AgentBar" && swift test` is
    /// `swift test`. A `cd` that is the whole command stays.
    static func withoutCd(_ command: String) -> String {
        var c = Substring(command.trimmingCharacters(in: .whitespaces))
        let pattern = #"^cd\s+("[^"]*"|'[^']*'|[^\s;&|]+)\s*(&&|;)\s*"#
        while let r = c.range(of: pattern, options: .regularExpression), r.upperBound < c.endIndex {
            c = c[r.upperBound...]
        }
        return String(c)
    }

    /// What the island shows unless asked for more: the newest step and the newest
    /// thing it said, and a command's output only when it failed — two lines, three
    /// with a failure, instead of a log to read through.
    static func calm(_ feed: Feed) -> Feed {
        let lastTool = feed.items.lastIndex { if case .tool = $0 { return true }; return false }
        let lastSaid = feed.items.lastIndex { if case .said = $0 { return true }; return false }
        let keep = [lastTool, lastSaid].compactMap { $0 }.sorted()
        let items = keep.map { feed.items[$0] }
        guard var out = feed.output, out.isError, let at = keep.firstIndex(of: out.after) else {
            return Feed(items: items)
        }
        out.after = at
        out.lines = Array(out.lines.suffix(2))
        return Feed(items: items, output: out)
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

    private static var cache: [String: (mtime: Date, feed: Feed)] = [:]

    /// Fixed feeds by session id, for Scripts/dev/render-preview.swift.
    static var preview: [String: Feed] = [:]

    /// The feed for a Claude Code or Codex session, re-read only when its file moved.
    static func read(_ s: Session) -> Feed {
        if let fixed = preview[s.id] { return fixed }
        if s.agentID == "codex" { return Feed(items: CodexFeed.read(s)) }
        guard s.agentID == "claude",
              let url = WeightReader.transcript(sessionId: s.id, cwd: s.cwd),
              let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return Feed(items: []) }
        if let hit = cache[url.path], hit.mtime == mtime { return hit.feed }
        let feed = Self.feed(tail(url))
        cache[url.path] = (mtime, feed)
        return feed
    }

    static func tail(_ url: URL, bytes: Int = tailBytes) -> [Substring] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
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
