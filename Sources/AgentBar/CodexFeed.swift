import Foundation

/// Over the shoulder for Codex: the same feed `LiveFeed` reads out of a Claude Code
/// transcript, read out of the rollout file Codex writes per thread
/// (`~/.codex/sessions/YYYY/MM/DD/rollout-…-<thread-id>.jsonl`).
///
/// Measured on rollouts from Codex CLI 0.92 to 0.157, which spell a call three ways:
/// - `response_item` / `function_call` with JSON `arguments` — `shell_command`
///   (`command`), `exec_command` (`cmd`), `spawn_agent` (`task_name`), and the
///   bookkeeping `wait`, `write_stdin`, `sleep`, `list_agents`;
/// - `response_item` / `custom_tool_call` named `apply_patch`, its input the patch;
/// - since 0.153, `response_item` / `custom_tool_call` named `exec`: a JavaScript cell
///   that calls `tools.exec_command({cmd:"…"})`, `tools.apply_patch("…")` and others.
///   Every `cmd` measured was a double-quoted literal; anything else is left out.
///
/// Read at the moment the model asked, like Claude's `tool_use`, so a long command
/// shows while it runs. The `item_completed` events 0.153 adds describe the same
/// calls after they finish and are not read, so nothing appears twice.
/// The turn starts at `event_msg` / `task_started` (0.106 on) or `user_message`
/// (older); the words are the assistant's `message` items.
enum CodexFeed {
    typealias Item = LiveFeed.Item

    /// Codex lines are long (world state, token reports, compaction), so more of the
    /// end is read than for Claude to reach the same few steps.
    static let tailBytes = 256 * 1024

    static func items(_ lines: [Substring]) -> [Item] {
        var out: [Item] = []
        for line in lines {
            guard line.contains("\"type\":\"response_item\"") || line.contains("\"type\":\"event_msg\""),
                  let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let p = o["payload"] as? [String: Any] else { continue }
            let kind = p["type"] as? String ?? ""
            if o["type"] as? String == "event_msg" {
                if kind == "task_started" || kind == "user_message" { out = [] }
                continue
            }
            switch kind {
            case "message":
                guard p["role"] as? String == "assistant" else { continue }
                let text = (p["content"] as? [[String: Any]] ?? [])
                    .filter { $0["type"] as? String == "output_text" }
                    .compactMap { $0["text"] as? String }
                    .joined(separator: " ")
                let said = LiveFeed.lastWords(text)
                if !said.isEmpty { out.append(.said(said)) }
            case "function_call":
                let args = (p["arguments"] as? String)
                    .flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                if let item = call(p["name"] as? String ?? "", args) { out.append(item) }
            case "custom_tool_call":
                let input = p["input"] as? String ?? ""
                switch p["name"] as? String {
                case "exec": out += cell(input)
                case "apply_patch": out.append(patch(input))
                default: break
                }
            case "web_search_call":
                let action = p["action"] as? [String: Any] ?? [:]
                let arg = (action["url"] as? String).flatMap { URL(string: $0)?.host } ?? (action["query"] as? String ?? "")
                out.append(.tool("Web", short(arg)))
            default:
                break
            }
        }
        return Array(out.suffix(LiveFeed.maxItems))
    }

    /// A direct function call, as a word and its argument.
    static func call(_ name: String, _ args: [String: Any]) -> Item? {
        switch name {
        case "shell_command", "exec_command", "shell":
            let cmd: String
            if let s = args["command"] as? String ?? args["cmd"] as? String { cmd = s }
            else if let argv = args["command"] as? [String] { cmd = argv.last ?? "" }  // ["bash", "-lc", "…"]
            else { cmd = "" }
            return .tool("Shell", firstLine(cmd))
        case "spawn_agent":
            return .tool("Agent", short(args["task_name"] as? String ?? ""))
        case "send_message", "followup_task":
            return .tool("Message", short(args["target"] as? String ?? ""))
        case "wait", "write_stdin", "sleep", "list_agents", "update_plan", "":
            return nil
        default:
            return .tool(name, "")
        }
    }

    /// An `apply_patch` call: the first file it touches, and how many more.
    static func patch(_ text: String) -> Item {
        let files = matches(#"\*\*\* (?:Add|Update|Delete) File: ([^\n\\"]+)"#, in: text)
            .map { $0.split(separator: "/").last.map(String.init) ?? $0 }
        let first = files.first ?? ""
        return .tool("Edit", files.count > 1 ? "\(first) +\(files.count - 1)" : first)
    }

    private static let cellCall = try! NSRegularExpression(pattern: #"tools\.([A-Za-z_][A-Za-z0-9_]*)\("#)
    private static let cmdLiteral = try! NSRegularExpression(pattern: #"^\s*\{\s*cmd\s*:\s*"((?:[^"\\]|\\.)*)""#)

    /// The calls inside a JavaScript `exec` cell, in the order they are written.
    static func cell(_ js: String) -> [Item] {
        let ns = js as NSString
        let found = cellCall.matches(in: js, range: NSRange(location: 0, length: ns.length))
        var out: [Item] = []
        for (i, m) in found.enumerated() {
            let name = ns.substring(with: m.range(at: 1))
            let end = i + 1 < found.count ? found[i + 1].range.location : ns.length
            let rest = ns.substring(with: NSRange(location: m.range.upperBound, length: end - m.range.upperBound))
            switch name {
            case "exec_command":
                let r = rest as NSString
                guard let lit = cmdLiteral.firstMatch(in: rest, range: NSRange(location: 0, length: r.length)) else {
                    out.append(.tool("Shell", ""))
                    continue
                }
                out.append(.tool("Shell", firstLine(unescape(r.substring(with: lit.range(at: 1))))))
            case "apply_patch":
                out.append(patch(rest))
            case "web__run":
                out.append(.tool("Web", ""))
            case "view_image":
                out.append(.tool("View", ""))
            case "write_stdin", "clock__curr_time":
                continue
            default:
                out.append(.tool(name, ""))
            }
        }
        return out
    }

    // MARK: - Reading

    private static var cache: [String: (mtime: Date, items: [Item])] = [:]
    /// Rollout path by thread id. Finding it walks `~/.codex/sessions`, which is too
    /// much to do every 1.5 s; a miss is retried after half a minute.
    private static var located: [String: (url: URL?, at: Date)] = [:]

    static func read(_ s: Session) -> [Item] {
        let id = s.id.hasPrefix("codex-") ? String(s.id.dropFirst(6)) : s.id
        guard !id.isEmpty, let url = rollout(id),
              let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return [] }
        if let hit = cache[url.path], hit.mtime == mtime { return hit.items }
        let items = Self.items(LiveFeed.tail(url, bytes: tailBytes))
        cache[url.path] = (mtime, items)
        return items
    }

    static func rollout(_ id: String) -> URL? {
        if let known = located[id] {
            if let url = known.url, FileManager.default.fileExists(atPath: url.path) { return url }
            if known.url == nil, Date().timeIntervalSince(known.at) < 30 { return nil }
        }
        let url = WeightReader.rollout(id: id)
        located[id] = (url, Date())
        return url
    }

    // MARK: - Helpers

    private static func firstLine(_ s: String) -> String {
        short(s.split(separator: "\n").first.map(String.init) ?? "")
    }

    private static func short(_ s: String) -> String {
        let flat = ApprovalRequest.oneLine(s)
        return flat.count > 70 ? String(flat.prefix(69)) + "…" : flat
    }

    /// A double-quoted literal's body, read the way JSON reads it; as written if not.
    private static func unescape(_ body: String) -> String {
        guard let data = "\"\(body)\"".data(using: .utf8),
              let s = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String
        else { return body.replacingOccurrences(of: "\\n", with: "\n") }
        return s
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces) }
    }
}
