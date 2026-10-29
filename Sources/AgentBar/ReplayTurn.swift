import Foundation

/// One turn of a Claude Code session, read out of its transcript for a replay:
/// the tool calls and said lines with their times, and which tool results came
/// back as errors. A turn starts at a prompt the person typed, like `LiveFeed`'s.
///
/// Read-only and local, like `TimelinePeek`: only the transcript's end is read,
/// off the main thread, and nothing leaves the Mac unless the person saves it.
struct ReplayTurn: Equatable {
    var entries: [TimelinePeek.Entry] = []
    var failures: [ReplayLevel.Failure] = []
    /// When the prompt that started it was typed, when it is in what was read.
    var prompted: TimeInterval?

    var isEmpty: Bool { entries.isEmpty && failures.isEmpty }

    /// What a replay is of: a session, and optionally a moment the turn reached —
    /// "the turn that was going on then" for a row in Your Day.
    struct Subject: Equatable {
        var sessionID: String
        var cwd: String
        var project: String
        var agentID: String = "claude"
        /// Nil for the session's last turn.
        var by: TimeInterval?
    }

    static let tailBytes = 2 * 1024 * 1024

    // MARK: - Pure

    /// The last turn in these transcript lines — or, given `by`, the last one that
    /// had started by then, cut at that moment. Subagents' lines are their own
    /// story and are left out; a line without a readable time is skipped, never
    /// guessed.
    static func last(_ lines: [Substring], by: TimeInterval? = nil) -> ReplayTurn {
        var turn = ReplayTurn()
        // Tool calls in this turn by id, for matching their results.
        var commands: [String: String] = [:]
        for line in lines {
            let isUser = line.contains("\"type\":\"user\"")
            guard isUser || line.contains("\"type\":\"assistant\""),
                  !line.contains("\"isSidechain\":true") else { continue }
            let bytes = Array(line.utf8)
            guard let at = bytes.withUnsafeBytes({ WorkSpans.ClaudeScan.timestamp($0) }) else { continue }
            if let by, at > by { break }
            guard let o = (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any],
                  let message = o["message"] as? [String: Any] else { continue }
            if isUser {
                if o["isMeta"] as? Bool != true, LiveFeed.isPrompt(message["content"]) {
                    turn = ReplayTurn(prompted: at)
                    commands = [:]
                    continue
                }
                for block in message["content"] as? [[String: Any]] ?? []
                where block["type"] as? String == "tool_result" && block["is_error"] as? Bool == true {
                    let id = block["tool_use_id"] as? String ?? ""
                    turn.failures.append(ReplayLevel.Failure(
                        at: at, tests: commands[id].map(AwayFailure.isTestRun) ?? false))
                }
                continue
            }
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    let said = LiveFeed.lastWords(block["text"] as? String ?? "")
                    if !said.isEmpty { turn.entries.append(TimelinePeek.Entry(at: at, item: .said(said))) }
                case "tool_use":
                    let name = block["name"] as? String ?? ""
                    let input = block["input"] as? [String: Any] ?? [:]
                    if let id = block["id"] as? String, name == "Bash" {
                        commands[id] = input["command"] as? String ?? ""
                    }
                    if let item = LiveFeed.tool(name, input) {
                        turn.entries.append(TimelinePeek.Entry(at: at, item: item))
                    }
                default:
                    break
                }
            }
        }
        return turn
    }

    // MARK: - Reading

    /// Fixed turns by session id, for previews and the demo.
    static var preview: [String: ReplayTurn] = [:]

    /// Reads the subject's turn off the main thread and calls back on it.
    static func load(_ subject: Subject, then done: @escaping (ReplayTurn) -> Void) {
        if let fixed = preview[subject.sessionID] { return done(fixed) }
        DispatchQueue.global(qos: .userInitiated).async {
            var turn = ReplayTurn()
            if subject.agentID == "claude",
               let url = WeightReader.transcript(sessionId: subject.sessionID, cwd: subject.cwd) {
                turn = last(LiveFeed.tail(url, bytes: tailBytes), by: subject.by)
            }
            DispatchQueue.main.async { done(turn) }
        }
    }
}
