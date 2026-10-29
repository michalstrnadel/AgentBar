import Foundation

/// "What was it doing then": a point on the hero row's hour strip, answered from
/// the session's own transcript — the time, what AgentBar saw it doing, and the
/// few tool calls and words logged around that moment.
///
/// Read-only and local, like `LiveFeed`: the transcript is the file Claude Code
/// already writes, only its end is read, off the main thread, and nothing here
/// leaves the Mac. A session without a transcript answers with the time and phase.
enum TimelinePeek {
    /// One step out of the transcript, with the moment it was logged.
    struct Entry: Equatable {
        var at: TimeInterval
        var item: LiveFeed.Item
    }

    /// How far either side of the hovered moment counts as "then".
    static let window: TimeInterval = 60
    static let maxItems = 3
    /// The strip covers an hour; this much of the transcript's end covers it for
    /// any session that is not writing megabytes of its own output an hour.
    static let tailBytes = 2 * 1024 * 1024

    // MARK: - Pure

    /// The moment under `x` on a strip `width` wide that ends at `now` and reaches
    /// `span` back. Outside the strip clamps to its edges.
    static func time(atX x: Double, width: Double, now: TimeInterval,
                     span: TimeInterval = SessionTimeline.window) -> TimeInterval {
        guard width > 0, x.isFinite else { return now }
        let f = min(max(x / width, 0), 1)
        return now - span + f * span
    }

    /// The phase AgentBar saw at `t`, or nil where it saw nothing.
    static func phase(at t: TimeInterval, in segments: [SessionTimeline.Segment]) -> SessionTimeline.Phase? {
        // The later segment wins a shared edge: that is when the change happened.
        segments.last { $0.start <= t && t <= $0.end }?.phase
    }

    static func word(_ p: SessionTimeline.Phase?) -> String {
        switch p {
        case .working: return "worked"
        case .waiting: return "waited on you"
        case .failed:  return "failed"
        case .rest:    return "rested"
        case nil:      return "not seen"
        }
    }

    /// Every tool call and said line in these transcript lines, with its time.
    /// A line with no readable timestamp is skipped, never guessed; subagents'
    /// lines are their own story and are left out. `since` skips lines before it
    /// without parsing them.
    static func entries(_ lines: [Substring], since: TimeInterval = -.infinity) -> [Entry] {
        var out: [Entry] = []
        for line in lines {
            guard line.contains("\"type\":\"assistant\""), !line.contains("\"isSidechain\":true") else { continue }
            let bytes = Array(line.utf8)
            guard let at = bytes.withUnsafeBytes({ WorkSpans.ClaudeScan.timestamp($0) }), at >= since,
                  let o = (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any],
                  let message = o["message"] as? [String: Any] else { continue }
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    let said = LiveFeed.lastWords(block["text"] as? String ?? "")
                    if !said.isEmpty { out.append(Entry(at: at, item: .said(said))) }
                case "tool_use":
                    let name = block["name"] as? String ?? ""
                    if let item = LiveFeed.tool(name, block["input"] as? [String: Any] ?? [:]) {
                        out.append(Entry(at: at, item: item))
                    }
                default:
                    break
                }
            }
        }
        return out
    }

    /// The entries within `window` of `t`: the `maxItems` closest to it, told in
    /// the order they happened.
    static func items(_ entries: [Entry], at t: TimeInterval, window: TimeInterval = window,
                      max: Int = maxItems) -> [LiveFeed.Item] {
        let near = entries.enumerated().filter { abs($0.element.at - t) <= window }
        let closest = near.sorted {
            let a = abs($0.element.at - t), b = abs($1.element.at - t)
            return a != b ? a < b : $0.offset < $1.offset
        }.prefix(max)
        return closest.sorted { $0.offset < $1.offset }.map(\.element.item)
    }

    /// The transcript lines' steps within `window` of `at`, at most three.
    static func items(lines: [Substring], at: Date, window: TimeInterval = window) -> [LiveFeed.Item] {
        items(entries(lines), at: at.timeIntervalSince1970, window: window)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// "14:32 · worked".
    static func heading(_ t: TimeInterval, phase: SessionTimeline.Phase?) -> String {
        clock.string(from: Date(timeIntervalSince1970: t)) + " · " + word(phase)
    }

    // MARK: - Reading

    /// Fixed entries by session id, for Scripts/dev/render-preview.swift.
    static var preview: [String: [Entry]] = [:]

    private struct Cached { var path: String; var mtime: Date; var entries: [Entry] }
    /// Touched on the main thread only.
    private static var cache: [String: Cached] = [:]
    private static var loading: Set<String> = []
    private static let queue = DispatchQueue(label: "agentbar.timeline-peek", qos: .utility)

    /// What is known now for this session, without touching the disk.
    static func cached(_ s: Session) -> [Entry]? {
        if let fixed = preview[s.id] { return fixed }
        return cache[s.id]?.entries
    }

    /// Re-reads the transcript's end off the main thread when it moved since the
    /// last read, and calls back on the main thread with what it found. Call on
    /// the main thread.
    static func load(_ s: Session, then done: @escaping ([Entry]) -> Void) {
        if let fixed = preview[s.id] { done(fixed); return }
        guard s.agentID == "claude", !loading.contains(s.id) else { return }
        loading.insert(s.id)
        let known = cache[s.id]
        let id = s.id, cwd = s.cwd
        queue.async {
            var result: Cached?
            if let url = WeightReader.transcript(sessionId: id, cwd: cwd),
               let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                if let known, known.path == url.path, known.mtime == mtime {
                    result = known
                } else {
                    let since = Date().timeIntervalSince1970 - SessionTimeline.window - window
                    result = Cached(path: url.path, mtime: mtime, entries: entries(tail(url), since: since))
                }
            }
            DispatchQueue.main.async {
                loading.remove(id)
                guard let result else { return }
                cache[id] = result
                done(result.entries)
            }
        }
    }

    private static func tail(_ url: URL) -> [Substring] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd() else { return [] }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        // A read that began mid-line has a broken first line.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }
}
