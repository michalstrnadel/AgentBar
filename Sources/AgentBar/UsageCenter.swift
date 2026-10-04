import Foundation

/// One quota window that has a known ceiling: a percentage spent, and when it
/// starts over. Only windows a provider actually publishes get one — a meter drawn
/// against a ceiling nobody stated would be a picture of a number that does not
/// exist.
struct UsageWindow: Equatable {
    let name: String            // "5h" / "weekly"
    let usedPercent: Double     // 0...100
    let resetsAt: Date?

    /// The question people actually ask. The meter shows what is spent; the
    /// number beside it says what is left, because that is the half you act on.
    var remainingPercent: Double { max(0, 100 - usedPercent) }

    func expired(now: Date = Date()) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }
}

/// What each provider says you have spent, and what is left of it.
///
/// Almost all of it is read off this machine: Codex writes the exact
/// `used_percent` of its 5-hour and weekly windows into every rollout file,
/// Copilot keeps its own priced ledger in a SQLite database, Claude's transcripts
/// carry tokens. The one exception is Claude's *windows*, which exist nowhere
/// local and are asked for over the network only when someone switches that on —
/// see `ClaudeQuota`.
///
/// Stale data is worse than none (a March window shown in August), so every
/// reading carries a freshness guard and quietly disappears when its source stops
/// updating. A provider that publishes no ceiling gets no meter rather than a
/// meter against a guess.
final class UsageCenter {
    static let shared = UsageCenter()

    struct Reading {
        let provider: String        // "Codex", "Claude", "Copilot"
        let text: String            // "3% left · resets 14:00" — the one-line form
        let detail: String?         // longer companion line for tooltips
        /// Zero, one or two meters. Empty means this provider publishes no
        /// ceiling and `text` is the whole truth it has.
        let windows: [UsageWindow]
        /// Something true that isn't a window — a credit balance. Kept apart from
        /// `text` so a surface that draws meters can place it without having to
        /// take a sentence back apart.
        let note: String?

        init(provider: String, text: String, detail: String? = nil,
             windows: [UsageWindow] = [], note: String? = nil) {
            self.provider = provider
            self.text = text
            self.detail = detail
            self.windows = windows
            self.note = note
        }
    }

    private(set) var readings: [Reading] = []
    /// Fired on the main queue whenever a refresh changed what should be shown.
    var onChange: (() -> Void)?

    private var timer: Timer?
    private let queue = DispatchQueue(label: "agentbar.usage", qos: .utility)

    /// How old a data point may be and still speak for the present. Codex only
    /// writes while a session runs; beyond this the window has long rolled over.
    static let maxAge: TimeInterval = 24 * 3600

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

    /// Parsed token entries per transcript, plus how far into the file they
    /// account for. Transcripts are append-only, so a tick reads only the bytes
    /// added since the last one — a tail cut would miss the start of a long
    /// block (this machine keeps 120 MB of transcripts inside the window, one
    /// of them 23 MB), and re-reading all of it every minute is not an option
    /// either. Only the serial queue touches this.
    private var transcriptCache: [String: (offset: UInt64, entries: [(Date, Int)])] = [:]

    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            var fresh: [Reading] = []
            if let codex = Self.codexReading() { fresh.append(codex) }
            if let claude = self.claudeReading() { fresh.append(claude) }
            if let copilot = Self.copilotReading() { fresh.append(copilot) }
            // Off by default and rate-limited from the inside; when it lands it
            // asks for another pass rather than editing anything from under us.
            ClaudeQuota.shared.refreshIfDue { [weak self] in self?.refresh() }
            ClaudeWebQuota.shared.refreshIfDue { [weak self] in self?.refresh() }
            DispatchQueue.main.async {
                let changed = fresh.map(Self.signature) != self.readings.map(Self.signature)
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
        guard let file = newestRollout(), let tail = tail(of: file, bytes: 64 * 1024),
              let usage = codexUsage(tail: tail)
        else { return nil }
        return reading(provider: "Codex", windows: usage.windows, note: usage.creditsNote)
    }

    struct CodexUsage: Equatable {
        var windows: [UsageWindow] = []
        /// Only for an account that actually has credits — for that account the
        /// balance *is* "what is left", and for every other one it is a zero that
        /// would read as bad news.
        var creditsNote: String?
    }

    /// What a rollout's tail says about the account, as a pure function.
    ///
    /// A rollout carries **more than one bucket**: the account-wide `codex` one
    /// with the 5-hour and weekly windows, and a `premium` one that is mostly
    /// nulls but holds the credit balance. Which lands *last* is arbitrary — on
    /// the machine this was written the final `token_count` line was `premium`,
    /// with both windows null. Taking the newest matching line was enough when
    /// there was one bucket; with two it is how a 97 % window can read as nothing
    /// at all. So walk back once, keep the newest entry per `limit_id`, merge.
    static func codexUsage(tail: String, now: Date = Date(),
                           maxAge: TimeInterval = UsageCenter.maxAge) -> CodexUsage? {
        var seen = Set<String>()
        var out = CodexUsage()
        var found = false
        for line in tail.split(separator: "\n").reversed() {
            guard line.contains("\"token_count\""), line.contains("\"rate_limits\""),
                  let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = o["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let limits = payload["rate_limits"] as? [String: Any]
            else { continue }
            // Stale is worse than absent — a March window shown in August. Lines
            // run newest-first here, so the first old one ends the walk.
            if let stamp = o["timestamp"] as? String, let at = parseISO(stamp),
               now.timeIntervalSince(at) >= maxAge { break }
            // Model-specific buckets ("codex_<model>") answer a different
            // question; a missing id predates the field and is the account one.
            let id = limits["limit_id"] as? String ?? "codex"
            guard seen.insert(id).inserted else { continue }
            found = true
            if id == "codex" {
                if let w = codexWindow(limits["primary"], fallback: "5h") { out.windows.append(w) }
                if let w = codexWindow(limits["secondary"], fallback: "weekly") {
                    out.windows.append(w)
                }
            }
            if let credits = limits["credits"] as? [String: Any],
               credits["has_credits"] as? Bool == true,
               let balance = credits["balance"] as? String, !balance.isEmpty {
                out.creditsNote = "\(balance) credits left"
            }
        }
        guard found, !(out.windows.isEmpty && out.creditsNote == nil) else { return nil }
        return out
    }

    private static func codexWindow(_ any: Any?, fallback: String) -> UsageWindow? {
        // A window the account doesn't have comes back as null, and that is an
        // answer: no window, no meter, never a confident zero.
        guard let o = any as? [String: Any],
              let percent = o["used_percent"] as? Double, percent.isFinite
        else { return nil }
        return UsageWindow(name: windowName(o, fallback: fallback),
                           usedPercent: min(max(percent, 0), 100),
                           resetsAt: (o["resets_at"] as? Double).flatMap(resetTime))
    }

    /// A reset time out of somebody else's file, or nil when the number is not one.
    ///
    /// `1e19` is an ordinary JSON number — finite, parseable, and past `Int.max`, so
    /// `Int(_:)` on it is not a wrong answer but a **runtime trap**. This is the one
    /// number in a rollout that travels from the file into a `Date` and back out
    /// through `Int` in the redraw signature, which runs on every refresh, so a
    /// single silly timestamp took the whole app down rather than the one row.
    /// The ceiling is the year 2100: a window that resets after that is not a
    /// window resetting, and no reset time is the honest reading of it.
    static func resetTime(_ seconds: Double) -> Date? {
        guard seconds.isFinite, seconds > 0, seconds < 4_102_444_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func windowName(_ window: [String: Any], fallback: String) -> String {
        switch window["window_minutes"] as? Int {
        case .some(10080): return "weekly"
        case .some(let m) where m % 60 == 0: return "\(m / 60)h"
        case .some(let m): return "\(m)m"
        case nil: return fallback
        }
    }

    // MARK: - Copilot (what it charged itself, in its own unit)

    /// Copilot keeps an exact ledger of its own spend, priced in its own AIU, and
    /// no entitlement at all — the ceiling lives on github.com, not on this
    /// machine. So this reading carries **no meter**: a number sitting plainly
    /// beside two bars reads, correctly, as "this one has no known limit", where
    /// a bar drawn against a ceiling nobody stated would be a picture of a number
    /// that does not exist.
    private static func copilotReading() -> Reading? {
        guard let spend = WeightReader.copilotSpend(), spend.events > 0 else { return nil }
        return Reading(provider: "Copilot",
                       text: "\(aiu(spend.nanoAIU)) AIU today",
                       detail: "\(compact(spend.tokens)) tokens across \(spend.events) requests")
    }

    /// Nano-AIU as the unit people are billed in. Two decimals under 1, because a
    /// morning of small edits is 0.03 and "0" would be a lie by rounding.
    static func aiu(_ nano: Int) -> String {
        let v = Double(nano) / 1e9
        switch v {
        case 10...: return String(format: "%.0f", v)
        case 1...:  return String(format: "%.1f", v)
        default:    return String(format: "%.2f", v)
        }
    }

    // MARK: - Shaping a reading

    /// The one-line form, for the island footer and any surface too narrow for
    /// meters. The short window leads, because it is the one about to run out —
    /// **unless it has just rolled over**, in which case it has nothing to say and
    /// the weekly one leads instead. "Codex window reset" on its own is a whole
    /// line spent on the absence of news while "74 % of the week left" sits in a
    /// tooltip nobody opens.
    static func reading(provider: String, windows: [UsageWindow], now: Date = Date(),
                        note: String? = nil, account: String? = nil,
                        source: String? = nil) -> Reading? {
        let lead = windows.first { !$0.expired(now: now) } ?? windows.first
        var parts: [String] = []
        if let lead { parts.append(short(lead, now: now)) }
        if let note { parts.append(note) }
        guard !parts.isEmpty else { return nil }
        var extras = windows.filter { $0.name != lead?.name }
            .map { "\($0.name): \(short($0, now: now))" }
        if let account { extras.append("account: \(account)") }
        // Where the number came from, when that is worth knowing.
        if let source { extras.append(source) }
        return Reading(provider: provider, text: parts.joined(separator: " · "),
                       detail: extras.isEmpty ? nil : extras.joined(separator: "\n"),
                       windows: windows, note: note)
    }

    /// What is left, and when it starts over.
    static func short(_ w: UsageWindow, now: Date = Date()) -> String {
        guard !w.expired(now: now) else { return "window reset" }
        var out = "\(Int(w.remainingPercent.rounded()))% left"
        if let r = w.resetsAt { out += " · resets \(when(r, now: now))" }
        return out
    }

    /// A clock for something happening today, a weekday for anything further out
    /// — "resets 14:31" and "resets Thu" are both answers; "resets 14:31" for next
    /// Thursday is not.
    static func when(_ d: Date, now: Date = Date()) -> String {
        if d.timeIntervalSince(now) < 18 * 3600 { return clock(d) }
        let f = DateFormatter()
        // A weekday is a word, and every other word in this app is English — a
        // Czech "po" sitting inside an English sentence reads as a truncation.
        // Clock times stay with the system, because those are numbers.
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEE"
        return f.string(from: d)
    }

    // MARK: - Which of them the island's one line is for

    /// The usage provider an agent's sessions spend from. Several ids can share
    /// one — Claude Code and Cowork are the same account and the same window —
    /// and most agents have no provider here at all, which is its own answer.
    ///
    /// Exact ids, not prefixes: any tool may write a row under an id it picks, and
    /// a `codex-fork` claiming Codex's quota would put somebody else's spending on
    /// your meter. Cowork's rows already say `claude` (`CoworkWatcher`); `cowork`
    /// stays for a writer that names it.
    static func provider(forAgent id: String) -> String? {
        switch id {
        case "claude", "cowork": return "Claude"
        case "codex":            return "Codex"
        case "copilot":          return "Copilot"
        default:                 return nil
        }
    }

    /// At or past this, a window stays on the island whatever else is happening.
    /// The same number the meter turns amber at: running low is the one quota
    /// fact worth showing unasked, and it should look and behave like one thing.
    static let lowWaterMark: Double = 80

    /// What the island's single line shows, given what is running.
    ///
    /// The line is a status surface, not a dashboard. Codex's window is no less
    /// true while Codex is asleep, but it is not *news* — and the line is one
    /// line, shared with the ⋯ button. So: the providers you are actually
    /// running, in the order they are running, and the rest one click away in
    /// the menu, which is where the full block has always lived.
    ///
    /// Two things keep that from lying:
    ///
    /// - A provider at `lowWaterMark` or more stays whether or not it is
    ///   running. The moment worth hearing about is the one where you are about
    ///   to start something you have no room for.
    /// - When nothing is running, the last thing that did stays. Otherwise the
    ///   line blinks out the instant a session ends and back in when the next
    ///   begins, and a status surface that flickers is worse than a busy one.
    static func relevant(_ readings: [Reading], active: Set<String>,
                         lastUsed: String? = nil) -> [Reading] {
        let ordered = readings.enumerated().sorted { a, b in
            let (x, y) = (active.contains(a.element.provider), active.contains(b.element.provider))
            return x == y ? a.offset < b.offset : x
        }.map(\.element)
        let keep = ordered.filter { r in
            active.contains(r.provider)
                || r.windows.contains { !$0.expired() && $0.usedPercent >= lowWaterMark }
        }
        if !keep.isEmpty { return keep }
        if let lastUsed, let r = readings.first(where: { $0.provider == lastUsed }) { return [r] }
        return Array(readings.prefix(1))
    }

    /// Everything a redraw would depend on. `text` alone missed a meter moving
    /// while its sentence stayed the same.
    static func signature(_ r: Reading) -> String {
        r.provider + "|" + r.text + "|" + r.windows.map {
            "\($0.name):\(Int($0.usedPercent.rounded())):\(Int($0.resetsAt?.timeIntervalSince1970 ?? 0))"
        }.joined(separator: ",")
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

    /// `live` is a parameter so the order of the doors is testable without a
    /// running mod; every caller takes the default.
    func claudeReading(live: ClaudeQuota.Snapshot? = ClaudeLiveQuota.shared.latest()) -> Reading? {
        // The real windows when the switch is on and the answer arrived; the
        // local half-measure otherwise. Never both — two Claude rows saying
        // different things is worse than either of them alone.
        // First Claude Code's own figures, through the AgentBar mod: no network,
        // no Keychain, and as fresh as its last request.
        if let live {
            return Self.reading(provider: "Claude", windows: live.windows,
                                source: ClaudeLiveQuota.sourceLine)
        }
        // Two doors to the same numbers: the login you signed into here, and
        // Claude Code's own stored token. Either is a real answer; whichever
        // answered is the one shown, and never both.
        if let snap = ClaudeWebQuota.shared.latest() ?? ClaudeQuota.shared.latest() {
            return Self.reading(provider: "Claude", windows: snap.windows,
                                account: snap.account)
        }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        // Split-config layouts (~/.claude-work and friends) coexist with the
        // default; whichever exist contribute. Merged into one line — this is
        // "what this machine spent", not per-account bookkeeping. Discovery,
        // resolution and deduping live in WeightReader.claudeRoots, so the live
        // quota and the per-session weight read the same set of transcripts.
        let roots = WeightReader.claudeRoots(home: home)
        guard !roots.isEmpty else { return nil }

        // Only files touched inside the scan window can contribute; everything
        // older is settled history.
        let horizon = Date().addingTimeInterval(-Self.scanWindow)
        var files: [(url: URL, mtime: Date, size: Int)] = []
        var seenFiles = Set<String>()
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
                    guard mtime > horizon else { continue }
                    // Belt and braces: a symlink deeper than the root would
                    // otherwise reintroduce the double count.
                    let resolved = f.resolvingSymlinksInPath()
                    guard seenFiles.insert(resolved.path).inserted else { continue }
                    files.append((resolved, mtime, values?.fileSize ?? 0))
                }
            }
        }
        guard !files.isEmpty else { return nil }

        // Read only what was appended since last time. A file that shrank was
        // replaced, so it starts over. Files that fell out of the window take
        // their cache with them.
        var entries: [(Date, Int)] = []
        var nextCache: [String: (offset: UInt64, entries: [(Date, Int)])] = [:]
        for f in files {
            let key = f.url.path
            var known = transcriptCache[key] ?? (offset: 0, entries: [])
            if known.offset > UInt64(f.size) { known = (offset: 0, entries: []) }
            if known.offset < UInt64(f.size) {
                let (fresh, consumed) = Self.tokenEntries(in: f.url, from: known.offset)
                known.entries.append(contentsOf: fresh)
                known.offset += consumed
            }
            // Old entries can never re-enter the window; drop them so a
            // long-lived process doesn't accumulate a day's worth forever.
            known.entries.removeAll { $0.0 <= horizon }
            nextCache[key] = known
            entries.append(contentsOf: known.entries)
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
        // The switch is on and there is still no percentage: say why, once, in
        // the menu block where the meter would have been — and, since 21d172a,
        // on the island too, where a missing bar with no explanation was read as
        // a broken app. It stays out of `text` so the two surfaces can each
        // decide: `UsageMeterView.compactRows` appends it, and the island's line
        // truncates it when there is no room.
        let why = ClaudeQuota.enabled
            ? ClaudeQuota.shortReason(for: ClaudeWeb.connected ? ClaudeWebQuota.shared.status
                                                               : ClaudeQuota.shared.status)
            : nil
        return Reading(provider: "Claude",
                       text: "~\(Self.compact(total)) tok this 5h block · resets \(Self.clock(resets))",
                       detail: why.map { "Percentages: \($0)." },
                       note: why)
    }

    /// (timestamp, tokens) for the assistant messages in the bytes a transcript
    /// gained since `offset`, plus how many bytes were actually consumed —
    /// always up to a line boundary, so the next read resumes cleanly even if
    /// this one caught a half-written final line.
    ///
    /// A single message spans several transcript lines (one per content block),
    /// each repeating the same usage object, so message ids are deduped or the
    /// totals come out several times too high. The dedupe is per read; a
    /// message's blocks are written together, so a boundary can't split them in
    /// practice, and one duplicate would be a rounding error in a "~" figure.
    private static func tokenEntries(in file: URL, from offset: UInt64) -> ([(Date, Int)], UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return ([], 0) }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return ([], 0) }
        // Everything after the last newline is a line still being written.
        guard let lastBreak = data.lastIndex(of: UInt8(ascii: "\n")) else { return ([], 0) }
        let complete = data[data.startIndex...lastBreak]
        let consumed = UInt64(complete.count)

        var out: [(Date, Int)] = []
        var seen = Set<String>()
        // Lossy decode: a transcript can carry anything, and one bad byte must
        // not cost the whole read.
        for line in String(decoding: complete, as: UTF8.self).split(separator: "\n") {
            guard line.contains("\"usage\""), line.contains("\"assistant\""),
                  let lineData = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  // One decode of `message.usage`, shared with the per-session reader.
                  // Two copies of these field names drift the moment a provider adds
                  // a fifth category.
                  let parsed = WeightReader.usage(inLine: o), let t = parsed.at
            else { continue }
            if let id = parsed.id {
                guard seen.insert(id).inserted else { continue }
            }
            out.append((t, parsed.weight.total))
        }
        return (out, consumed)
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

    /// "4.1M" / "820k" / "412". Internal because the day's digest quotes token
    /// counts too, and two formatters that must agree are one that will not.
    static func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:     return String(format: "%.0fk", Double(n) / 1_000)
        default:           return "\(n)"
        }
    }
}
