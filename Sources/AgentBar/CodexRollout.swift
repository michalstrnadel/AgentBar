import Foundation

/// What a Codex rollout says about the session beside its feed: how full the
/// context is, and which subagents are working for the current turn. The same two
/// things the Claude Code mod reports through `mods.d`, read here out of the file
/// Codex already writes (`~/.codex/sessions/YYYY/MM/DD/rollout-…-<thread-id>.jsonl`).
///
/// Measured on rollouts from Codex CLI 0.153–0.157:
///
/// - **Context.** Every model response is followed by an `event_msg` /
///   `token_count` whose `info` holds `total_token_usage` (cumulative for the
///   thread), `last_token_usage` (that one request) and `model_context_window`
///   (258 400 on every line measured). `info` is `null` on a few lines; those say
///   nothing and the figure before them stands. The fill is
///   `last_token_usage.total_tokens / model_context_window`: what the last request
///   put into the window (its whole input) plus what it wrote back, which is what
///   the next request starts from. `total_token_usage` is a running sum over every
///   request — tens of millions on a long thread — and is no measure of a window.
///   Codex counts cached input *inside* `input_tokens` (cached never exceeded input
///   on any of 961 lines), so input plus cached would count the cache twice.
///   Codex's own "context left" is believed to subtract a fixed baseline for its
///   system prompt before dividing; that is not applied here, so this figure can
///   read a few points higher than Codex's own. A compaction shows as the drop it
///   is, which is what `ContextTrend` resets on.
///
/// - **Subagents** (0.153+). A `spawn_agent` call is followed by an `event_msg` /
///   `item_completed` whose item is `SubAgentActivity` with `kind` `started`, the
///   child's `agent_thread_id` and `agent_path` (`/root/<task_name>`). A message to
///   a running child is `interacted`; a finished child is `completed`, also in the
///   parent's rollout. A subagent counts while its last word is `started` or
///   `interacted` and no `completed` followed — inside the current turn only. A
///   turn that ended (`task_complete`, `turn_aborted`) clears them: one measured
///   turn sent follow-ups to three children and ended with no `completed` for any
///   of them, so after a turn ends the file cannot tell running from abandoned, and
///   saying nothing beats a row that claims work forever. Rollouts older than 0.153
///   carry no `SubAgentActivity` and show none.
struct CodexRollout: Equatable {
    /// Whole percent of the window, 0–100; nil until a `token_count` said.
    private(set) var contextPercent: Int?
    /// The current turn's subagents still at work, oldest first.
    private(set) var agents: [ModReport.Subagent] = []
    private var paths: [String] = []   // `agent_path` of each entry in `agents`

    init() {}

    /// Folds lines in file order.
    init<S: Sequence>(_ lines: S) where S.Element: StringProtocol {
        for line in lines { feed(line) }
    }

    /// Cheap substring checks first: a rollout is megabytes of world state and
    /// compaction, and only a few kinds of line matter here.
    mutating func feed<L: StringProtocol>(_ line: L) {
        guard line.contains("\"event_msg\""),
              line.contains("token_count") || line.contains("SubAgentActivity")
                || line.contains("task_started") || line.contains("task_complete")
                || line.contains("turn_aborted"),
              let data = String(line).data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              o["type"] as? String == "event_msg",
              let p = o["payload"] as? [String: Any] else { return }
        switch p["type"] as? String {
        case "token_count":
            if let pct = Self.percent(p["info"] as? [String: Any]) { contextPercent = pct }
        case "task_started", "task_complete", "turn_aborted":
            agents = []
            paths = []
        case "item_completed":
            guard let item = p["item"] as? [String: Any],
                  item["type"] as? String == "SubAgentActivity" else { return }
            activity(item, at: Self.seconds(p["started_at_ms"]) ?? Self.seconds(p["completed_at_ms"]))
        default:
            return
        }
    }

    /// `last_token_usage.total_tokens` over `model_context_window` (see above).
    static func percent(_ info: [String: Any]?) -> Int? {
        guard let info,
              let window = number(info["model_context_window"]), window > 0,
              let last = info["last_token_usage"] as? [String: Any] else { return nil }
        let used = number(last["total_tokens"])
            ?? (number(last["input_tokens"]).map { $0 + (number(last["output_tokens"]) ?? 0) })
        guard let used, used >= 0 else { return nil }
        return Int(min(100, max(0, (used / window * 100).rounded())))
    }

    private mutating func activity(_ item: [String: Any], at: TimeInterval?) {
        guard let path = item["agent_path"] as? String,
              path.split(separator: "/").count > 1 else { return }  // `/root` is the parent itself
        let i = paths.firstIndex(of: path)
        switch item["kind"] as? String {
        case "started", "interacted":
            guard i == nil else { return }  // already counted, since its start
            let name = path.split(separator: "/").last.map(String.init) ?? path
            paths.append(path)
            agents.append(ModReport.Subagent(type: "agent", what: String(ApprovalRequest.oneLine(name).prefix(60)),
                                             since: at ?? 0))
        case "completed":
            if let i { paths.remove(at: i); agents.remove(at: i) }
        default:
            return  // a kind not measured: change nothing rather than guess
        }
    }

    private static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    private static func seconds(_ v: Any?) -> TimeInterval? {
        number(v).flatMap { $0 > 0 ? $0 / 1000 : nil }
    }
}

/// Reads each Codex row's rollout as it grows: only the bytes appended since the
/// last pass, folded into the `CodexRollout` kept for that file. A rollout runs to
/// megabytes (the first read of an 8 MB one measured ~0.3 s), so reads run on a
/// queue of their own and land on the next store pass; every later read is a few
/// kilobytes. A file that shrank (replaced) is read again from the start.
/// `merge` is called on the store's pass, on the main queue, and owns `files`.
final class CodexRolloutReader {
    static let shared = CodexRolloutReader()

    struct File { var offset: UInt64 = 0; var mtime = Date.distantPast; var fold = CodexRollout() }
    private var files: [String: File] = [:]
    private var reading: Set<String> = []
    private let queue = DispatchQueue(label: "agentbar.codex-rollout", qos: .utility)

    /// Codex rows the Claude mod did not report for, given what their rollouts
    /// said as of the last finished read. A cloud row, or a row whose file is not
    /// found or not read yet, comes back untouched.
    func merge(into sessions: [Session]) -> [Session] {
        var live = Set<String>()
        let out = sessions.map { s -> Session in
            guard s.agentID == "codex", !s.modSeen, s.entrypoint != "cloud",
                  let url = CodexFeed.rollout(Self.thread(s.id)) else { return s }
            live.insert(url.path)
            refresh(url)
            guard let f = files[url.path] else { return s }
            return Self.apply(f.fold, to: s)
        }
        for path in files.keys where !live.contains(path) { files[path] = nil }
        return out
    }

    static func thread(_ id: String) -> String {
        id.hasPrefix("codex-") ? String(id.dropFirst(6)) : id
    }

    /// Pure: the rollout's figures onto the row. A figure the rollout lacks leaves
    /// the row's own (nil, empty) in place rather than writing a zero.
    static func apply(_ r: CodexRollout, to s: Session) -> Session {
        var out = s
        if let p = r.contextPercent { out.contextPercent = p }
        out.subagentDetails = r.agents
        return out
    }

    /// Starts a read when the file moved on since the last one and none is running.
    private func refresh(_ url: URL) {
        let path = url.path
        guard !reading.contains(path), let mtime = Self.mtime(path),
              files[path]?.mtime != mtime else { return }
        reading.insert(path)
        let prior = files[path]
        queue.async { [weak self] in
            let next = Self.advance(prior, url: url)
            DispatchQueue.main.async {
                guard let self else { return }
                self.reading.remove(path)
                if let next { self.files[path] = next }
            }
        }
    }

    /// The same read, synchronously — for tests; nothing on the main queue calls it.
    func read(_ url: URL) -> CodexRollout? {
        guard let next = Self.advance(files[url.path], url: url) else { return files[url.path]?.fold }
        files[url.path] = next
        return next.fold
    }

    /// Asked of the file system each time: a URL caches its resource values, and
    /// the same URL comes back from `CodexFeed.rollout` on every pass.
    private static func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private static let eventMsg = Data("\"event_msg\"".utf8)

    /// `prior` advanced over what was appended since; nil when the file is gone.
    static func advance(_ prior: File?, url: URL) -> File? {
        guard let mtime = mtime(url.path) else { return nil }
        if let prior, prior.mtime == mtime { return prior }
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        var f = prior ?? File()
        if size < f.offset { f = File() }
        try? h.seek(toOffset: f.offset)
        let data = (try? h.readToEnd()) ?? Data()
        // Only whole lines: a line still being appended is read on the next pass.
        if let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
            let whole = data[data.startIndex...lastNewline]
            for line in whole.split(separator: UInt8(ascii: "\n"))
            where line.range(of: eventMsg) != nil {   // the rest is never decoded
                f.fold.feed(String(decoding: line, as: UTF8.self))
            }
            f.offset += UInt64(whole.count)
        }
        f.mtime = mtime
        return f
    }
}
