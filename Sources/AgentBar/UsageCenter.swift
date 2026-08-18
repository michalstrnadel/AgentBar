import Foundation

/// Provider quota readings from data the CLIs already keep on disk — no network,
/// no keychain, nothing leaves the machine. Codex rollout files carry the exact
/// `used_percent` of the account's 5-hour and weekly windows; Claude transcripts
/// yield the tokens spent in the current 5-hour block. Stale data is worse than
/// none (a March window shown in August), so every reading carries a freshness
/// guard and quietly disappears when its source stops updating.
final class UsageCenter {
    static let shared = UsageCenter()

    struct Reading {
        let provider: String   // "Codex", "Claude"
        let text: String       // "5% of 5h · resets 14:00"
        let detail: String?    // longer companion line for tooltips (weekly window)
    }

    private(set) var readings: [Reading] = []
    /// Fired on the main queue whenever a refresh changed what should be shown.
    var onChange: (() -> Void)?

    private var timer: Timer?
    private let queue = DispatchQueue(label: "agentbar.usage", qos: .utility)

    /// How old a data point may be and still speak for the present. Codex only
    /// writes while a session runs; beyond this the window has long rolled over.
    private static let maxAge: TimeInterval = 24 * 3600

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 10
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Parsed token entries per transcript file, valid while the file's
    /// (mtime, size) hold. Without it every tick re-read and re-parsed the same
    /// unchanged megabytes; only the queue touches it.
    private var transcriptCache: [String: (mtime: Date, size: Int, entries: [(Date, Int)])] = [:]

    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            var fresh: [Reading] = []
            if let codex = Self.codexReading() { fresh.append(codex) }
            if let claude = self.claudeReading() { fresh.append(claude) }
            DispatchQueue.main.async {
                let changed = fresh.map(\.text) != self.readings.map(\.text)
                self.readings = fresh
                if changed { self.onChange?() }
            }
        }
    }

    // MARK: - Codex (exact percentages from rollout files)

    /// Newest `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. Directory and file
    /// names are zero-padded timestamps, so the maximum name at each level is the
    /// newest — no tree walk.
    private static func newestRollout() -> URL? {
        let env = ProcessInfo.processInfo.environment["CODEX_HOME"]
        var dir = env.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        dir.appendPathComponent("sessions")
        let fm = FileManager.default
        for _ in 0..<3 { // year / month / day
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path),
                  let newest = names.filter({ !$0.hasPrefix(".") }).sorted().last
            else { return nil }
            dir.appendPathComponent(newest)
        }
        // Within the day, pick by mtime rather than name: a RESUMED session
        // appends fresh data to an old-named file.
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }
        return items
            .filter { $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl" }
            .max { a, b in
                let ma = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let mb = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return ma < mb
            }
    }

    private static func codexReading() -> Reading? {
        guard let file = newestRollout(), let tail = tail(of: file, bytes: 64 * 1024)
        else { return nil }
        // Newest matching line wins; model-specific buckets (limit_id
        // "codex_<model>") are skipped in favour of the account-wide "codex" one.
        // limit_id is absent entirely in pre-0.106 rollouts — treat nil as match.
        for line in tail.split(separator: "\n").reversed() {
            guard line.contains("\"token_count\""), line.contains("\"rate_limits\""),
                  let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = o["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let limits = payload["rate_limits"] as? [String: Any]
            else { continue }
            if let id = limits["limit_id"] as? String, id != "codex" { continue }
            guard let primary = limits["primary"] as? [String: Any],
                  let percent = primary["used_percent"] as? Double
            else { continue }
            guard let stamp = o["timestamp"] as? String,
                  let seen = parseISO(stamp), Date().timeIntervalSince(seen) < maxAge
            else { return nil } // the newest data is stale — better silent than wrong
            var text = "\(Int(percent.rounded()))% of \(windowName(primary))"
            if let resets = primary["resets_at"] as? Double {
                let reset = Date(timeIntervalSince1970: resets)
                if reset < Date() {
                    text = "window reset"
                } else {
                    text += " · resets \(clock(reset))"
                }
            }
            var detail: String?
            if let secondary = limits["secondary"] as? [String: Any],
               let weekly = secondary["used_percent"] as? Double {
                detail = "\(Int(weekly.rounded()))% of \(windowName(secondary)) window"
            }
            return Reading(provider: "Codex", text: text, detail: detail)
        }
        return nil
    }

    private static func windowName(_ window: [String: Any]) -> String {
        switch window["window_minutes"] as? Int {
        case .some(10080): return "weekly"
        case .some(let m) where m % 60 == 0: return "\(m / 60)h"
        case .some(let m): return "\(m)m"
        case nil: return "5h"
        }
    }

    // MARK: - Claude (tokens in the current 5h block, from local transcripts)

    /// Claude Code doesn't write its quota percentages anywhere local, so this is
    /// the honest half-measure: sum the tokens its transcripts record for the
    /// current 5-hour block (anchored, like the provider's own windows, at the
    /// full hour of the first activity after a ≥5h gap) and say when it rolls
    /// over. Token counts are real; the ceiling is the provider's secret, and
    /// the "~" owns the two approximations left in here (the scan window and
    /// the per-file tail).
    private static let blockLength: TimeInterval = 5 * 3600
    /// How far back to look for the block chain. Bounded on purpose — a fully
    /// exact anchor needs unbounded history — but wide enough to find the real
    /// gap that started today's chain, even after a long unbroken session.
    /// Same 24h stance as the Codex staleness guard.
    private static let scanWindow: TimeInterval = maxAge
    private static let tailBytes = 2 * 1024 * 1024

    private func claudeReading() -> Reading? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        // Split-config layouts (~/.claude-work, ~/.claude-personal) coexist with
        // the default; whichever exist contribute. Merged into one line — this
        // is "what this machine spent", not per-account bookkeeping.
        let roots = [".claude", ".claude-work", ".claude-personal"]
            .map { home.appendingPathComponent($0).appendingPathComponent("projects") }
            .filter { fm.fileExists(atPath: $0.path) }
        guard !roots.isEmpty else { return nil }

        // Only files touched inside the scan window can contribute; everything
        // older is settled history.
        let horizon = Date().addingTimeInterval(-Self.scanWindow)
        var files: [(url: URL, mtime: Date, size: Int)] = []
        for root in roots {
            guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                         options: .skipsHiddenFiles)
            else { continue }
            for dir in dirs {
                guard let items = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                    options: .skipsHiddenFiles)
                else { continue }
                for f in items where f.pathExtension == "jsonl" {
                    let values = try? f.resourceValues(forKeys: [.contentModificationDateKey,
                                                                 .fileSizeKey])
                    let mtime = values?.contentModificationDate ?? .distantPast
                    if mtime > horizon {
                        files.append((f, mtime, values?.fileSize ?? 0))
                    }
                }
            }
        }
        guard !files.isEmpty else { return nil }

        // Re-read only what changed; an unchanged file's entries are already
        // parsed. Everything outside the window drops out of the cache with it.
        var entries: [(Date, Int)] = []
        var nextCache: [String: (mtime: Date, size: Int, entries: [(Date, Int)])] = [:]
        for f in files {
            let key = f.url.path
            if let hit = transcriptCache[key], hit.mtime == f.mtime, hit.size == f.size {
                nextCache[key] = hit
                entries.append(contentsOf: hit.entries)
                continue
            }
            let parsed = Self.tokenEntries(in: f.url)
            nextCache[key] = (f.mtime, f.size, parsed)
            entries.append(contentsOf: parsed)
        }
        transcriptCache = nextCache

        // One assistant message spans several transcript lines (one per content
        // block), each repeating the same usage object — the per-file parse
        // already deduped by message id; the horizon cut happens here so a
        // cached file stays valid as the window slides.
        let usageByStamp = entries.filter { $0.0 > horizon }
        let stamps = usageByStamp.map(\.0)
        guard let first = stamps.min() else { return nil }
        var anchor = Self.floorToHour(first)
        // Walk the block chain forward: each block is 5h from the top of the
        // hour of its first message; the current block is the one reaching now.
        while anchor.addingTimeInterval(Self.blockLength) < Date() {
            let nextStart = anchor.addingTimeInterval(Self.blockLength)
            guard let next = stamps.filter({ $0 >= nextStart }).min() else { return nil }
            anchor = Self.floorToHour(next)
        }
        let total = usageByStamp.filter { $0.0 >= anchor }.map(\.1).reduce(0, +)
        guard total > 0 else { return nil }
        let resets = anchor.addingTimeInterval(Self.blockLength)
        return Reading(provider: "Claude",
                       text: "~\(Self.compact(total)) tok this 5h block · resets \(Self.clock(resets))",
                       detail: nil)
    }

    /// (timestamp, tokens) for every assistant message in one transcript's tail.
    /// A single message spans several transcript lines — one per content block,
    /// each repeating the same usage object — so message ids are deduped here or
    /// the totals come out several times too high.
    private static func tokenEntries(in file: URL) -> [(Date, Int)] {
        guard let text = tail(of: file, bytes: tailBytes) else { return [] }
        var out: [(Date, Int)] = []
        var seen = Set<String>()
        for line in text.split(separator: "\n") {
            guard line.contains("\"usage\""), line.contains("\"assistant\""),
                  let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  o["type"] as? String == "assistant",
                  let stamp = o["timestamp"] as? String, let t = parseISO(stamp),
                  let message = o["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { continue }
            if let id = message["id"] as? String {
                guard seen.insert(id).inserted else { continue }
            }
            out.append((t, (usage["input_tokens"] as? Int ?? 0)
                + (usage["output_tokens"] as? Int ?? 0)
                + (usage["cache_creation_input_tokens"] as? Int ?? 0)))
        }
        return out
    }

    // MARK: - Small helpers

    private static func tail(of file: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        // Lossy on purpose: a byte-offset cut can land mid-UTF-8-sequence, and a
        // strict decode would then drop the whole file over one torn character.
        return String(decoding: data, as: UTF8.self)
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    private static func parseISO(_ s: String) -> Date? {
        isoFrac.date(from: s) ?? isoPlain.date(from: s)
    }

    private static func floorToHour(_ d: Date) -> Date {
        Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }

    private static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: d)
    }

    private static func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:     return String(format: "%.0fk", Double(n) / 1_000)
        default:           return "\(n)"
        }
    }
}
