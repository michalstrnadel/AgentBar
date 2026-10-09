import Foundation

/// How long Keep Mac Awake held the Mac up, for Your Day: "Mac kept awake
/// 3 h 20 min".
///
/// One stretch per line in `~/.agentbar/awake.jsonl`, append-only like
/// `HistoryStore` and for the same reasons. A stretch is written when it starts,
/// again every ten minutes while it lasts, and once more when it ends; the reader
/// keeps the last line for each `id`, so a crash costs at most ten minutes of one
/// stretch and never the stretch.
final class AwakeLog {
    static let shared = AwakeLog()
    static let fileURL = AgentBarHome.url("awake.jsonl")
    static let maxAge: TimeInterval = 30 * 86_400
    static let checkpoint: TimeInterval = 10 * 60

    struct Stretch: Equatable {
        enum Kind: String { case agents, timed, indefinite, trigger }
        var id: String
        var start: Date
        var end: Date
        var kind: Kind

        var json: [String: Any] {
            ["id": id, "start": start.timeIntervalSince1970, "end": end.timeIntervalSince1970,
             "kind": kind.rawValue]
        }

        init(id: String, start: Date, end: Date, kind: Kind) {
            self.id = id
            self.start = start
            self.end = end
            self.kind = kind
        }

        init?(jsonLine: String) {
            guard let data = jsonLine.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = o["id"] as? String, let s = o["start"] as? Double, let e = o["end"] as? Double,
                  e >= s, let kind = (o["kind"] as? String).flatMap(Kind.init(rawValue:))
            else { return nil }
            self.init(id: id, start: Date(timeIntervalSince1970: s), end: Date(timeIntervalSince1970: e), kind: kind)
        }
    }

    private let url: URL
    private var open: Stretch?
    private var timer: Timer?

    init(url: URL = AwakeLog.fileURL) {
        self.url = url
    }

    /// The Mac started being held up (`kind`), or stopped (`nil`). The same kind
    /// again is the same stretch.
    func holding(_ kind: Stretch.Kind?, now: Date = Date()) {
        if let current = open, current.kind == kind { return }
        if var current = open {
            current.end = now
            append(current)
            open = nil
            timer?.invalidate()
            timer = nil
        }
        guard let kind else { return }
        let s = Stretch(id: UUID().uuidString, start: now, end: now, kind: kind)
        open = s
        append(s)
        let t = Timer(timeInterval: Self.checkpoint, repeats: true) { [weak self] _ in self?.touch() }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func touch(now: Date = Date()) {
        guard var current = open else { return }
        current.end = now
        open = current
        append(current)
    }

    private func append(_ s: Stretch) {
        guard let data = try? JSONSerialization.data(withJSONObject: s.json, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let line = data + Data("\n".utf8)
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// Every stretch, the last line for each id winning; a torn line is skipped.
    static func read(url: URL = AwakeLog.fileURL) -> [Stretch] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var byID: [String: Stretch] = [:]
        var order: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let s = Stretch(jsonLine: String(line)) else { continue }
            if byID[s.id] == nil { order.append(s.id) }
            byID[s.id] = s
        }
        return order.compactMap { byID[$0] }
    }

    /// Drops stretches that ended more than a month ago, and the duplicates. At launch.
    static func prune(url: URL = AwakeLog.fileURL, now: Date = Date()) {
        let all = read(url: url)
        let kept = all.filter { now.timeIntervalSince($0.end) < maxAge }
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              text.split(separator: "\n").count != kept.count else { return }
        let lines = kept.compactMap { s -> String? in
            (try? JSONSerialization.data(withJSONObject: s.json, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) }
        }
        try? (lines.map { $0 + "\n" }.joined()).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Time held up inside `range`, and how much of it was for agents.
    static func total(_ stretches: [Stretch], in range: DateInterval) -> (all: TimeInterval, agents: TimeInterval) {
        var all: TimeInterval = 0, agents: TimeInterval = 0
        for s in stretches {
            let start = max(s.start, range.start), end = min(s.end, range.end)
            guard end > start else { continue }
            let d = end.timeIntervalSince(start)
            all += d
            if s.kind == .agents { agents += d }
        }
        return (all, agents)
    }
}
