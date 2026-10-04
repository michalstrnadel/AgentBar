import Foundation

/// Claude's 5-hour and weekly windows as Claude Code itself last reported them,
/// through the AgentBar mod (`mods.d`, `rate_limits`).
///
/// The best of the three doors to the same numbers: no network call, no Keychain,
/// no login, and fresher than a five-minute poll — Claude Code knows its own
/// windows from the answer to its last request. So `UsageCenter.claudeReading`
/// asks here first and falls back to `ClaudeWebQuota` / `ClaudeQuota` only when no
/// session has spoken recently.
///
/// Every session reports the same account's windows, so the newest report wins —
/// not an average, not a sum. With several Claude logins on one Mac (split config
/// dirs) that is the login that worked last, which is also the one the person is
/// most likely looking at.
final class ClaudeLiveQuota {
    static let shared = ClaudeLiveQuota()

    /// The same stance `ClaudeQuota` takes: past half an hour a percentage is old
    /// enough to be wrong, and silence beats a stale one.
    static let maxAge: TimeInterval = 30 * 60
    /// The line a reading from here carries, next to the windows it explains.
    static let sourceLine = "from Claude Code, live"
    /// How long a burst of sidecar writes is gathered before the meters redraw.
    static let debounce: TimeInterval = 1

    private let lock = NSLock()
    private var current: [ModReport] = []
    private var lastSignature = ""
    private var pending = false
    private let refreshUsage: () -> Void

    init(refreshUsage: @escaping () -> Void = { UsageCenter.shared.refresh() }) {
        self.refreshUsage = refreshUsage
    }

    /// Every sidecar's latest report, from `SessionStore`'s pass (main queue).
    /// When the windows that would be shown moved, the meters are asked to redraw —
    /// once per burst, not once per file.
    func update(_ reports: [ModReport], now: Date = Date()) {
        let withLimits = reports.filter { !$0.rateLimits.isEmpty }
        let signature = Self.signature(Self.snapshot(from: withLimits, now: now))
        lock.lock()
        current = withLimits
        let moved = signature != lastSignature
        lastSignature = signature
        let schedule = moved && !pending
        if schedule { pending = true }
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.pending = false; self.lock.unlock()
            self.refreshUsage()
        }
    }

    /// The freshest windows, or nil when no session reported any recently. Any queue.
    func latest(now: Date = Date()) -> ClaudeQuota.Snapshot? {
        lock.lock(); defer { lock.unlock() }
        return Self.snapshot(from: current, now: now)
    }

    // MARK: - Pure

    static func snapshot(from reports: [ModReport], now: Date) -> ClaudeQuota.Snapshot? {
        let t = now.timeIntervalSince1970
        // A report from the future is a clock that is wrong, not news from later.
        let fresh = reports.filter { t - $0.ts < maxAge && $0.ts - t < 300 }
        for report in fresh.sorted(by: { $0.ts > $1.ts }) {
            let w = windows(report.rateLimits, now: now)
            if !w.isEmpty {
                return ClaudeQuota.Snapshot(windows: w, account: nil,
                                            at: Date(timeIntervalSince1970: report.ts))
            }
        }
        return nil
    }

    /// Claude Code's kinds under the names `ClaudeQuota.parse` gives the same
    /// windows, so the meter cannot tell which door a number came through. A window
    /// that has already reset is dropped: its percentage belongs to the last one.
    static func windows(_ limits: [ModReport.RateLimit], now: Date) -> [UsageWindow] {
        let names = [("five_hour", "5h"), ("seven_day", "weekly")]
        return names.compactMap { kind, name in
            guard let l = limits.first(where: { $0.kind == kind }) else { return nil }
            let w = UsageWindow(name: name, usedPercent: min(max(l.percentUsed, 0), 100),
                                resetsAt: l.resetsAt)
            return w.expired(now: now) ? nil : w
        }
    }

    private static func signature(_ s: ClaudeQuota.Snapshot?) -> String {
        (s?.windows ?? []).map {
            "\($0.name):\(Int($0.usedPercent.rounded())):\(Int($0.resetsAt?.timeIntervalSince1970 ?? 0))"
        }.joined(separator: ",")
    }
}
