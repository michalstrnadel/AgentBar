import Foundation
import Testing
@testable import AgentBar

/// Claude's windows as Claude Code itself reported them: fresh or nothing, the
/// newest session's, under the names the other two doors use — and first.
struct ClaudeLiveQuotaTests {
    private static let now = Date(timeIntervalSince1970: 1_791_146_583)

    private func report(_ id: String, age: TimeInterval, five: Double? = 62, seven: Double? = 28,
                        fiveResets: TimeInterval = 3_600) -> ModReport {
        var r = ModReport(sessionId: id, ts: Self.now.timeIntervalSince1970 - age)
        if let five {
            r.rateLimits.append(.init(kind: "five_hour", percentUsed: five,
                                      resetsAt: Self.now.addingTimeInterval(fiveResets)))
        }
        if let seven {
            r.rateLimits.append(.init(kind: "seven_day", percentUsed: seven,
                                      resetsAt: Self.now.addingTimeInterval(5 * 86_400)))
        }
        return r
    }

    /// The quota is the account's: when the last session ends and its sidecar is
    /// cleaned up, the meter keeps the last reading until it is too old to trust.
    @Test func theLastReadingOutlivesItsSession() {
        let live = ClaudeLiveQuota(refreshUsage: {})
        live.update([report("a", age: 60)], now: Self.now)
        live.update([], now: Self.now)
        #expect(live.latest(now: Self.now)?.windows.count == 2)
        #expect(live.latest(now: Self.now.addingTimeInterval(ClaudeLiveQuota.maxAge)) == nil)
    }

    @Test func theWindowsCarryTheNamesTheOtherDoorsUse() throws {
        let snap = try #require(ClaudeLiveQuota.snapshot(from: [report("a", age: 10)], now: Self.now))
        #expect(snap.windows.map(\.name) == ["5h", "weekly"])
        #expect(snap.windows[0].usedPercent == 62)
        #expect(snap.account == nil)
        #expect(snap.at == Self.now.addingTimeInterval(-10))
    }

    @Test func theNewestSessionSpeaks() throws {
        let snap = try #require(ClaudeLiveQuota.snapshot(
            from: [report("old", age: 600, five: 10), report("new", age: 5, five: 70)], now: Self.now))
        #expect(snap.windows.first?.usedPercent == 70)
    }

    /// Half an hour, the same stance the network door takes: past it, silence.
    @Test func aStaleReportIsSilence() {
        #expect(ClaudeLiveQuota.snapshot(from: [report("a", age: 31 * 60)], now: Self.now) == nil)
        #expect(ClaudeLiveQuota.snapshot(from: [report("a", age: 29 * 60)], now: Self.now) != nil)
        // A clock running ahead is not news from later.
        #expect(ClaudeLiveQuota.snapshot(from: [report("a", age: -3_600)], now: Self.now) == nil)
    }

    /// A window that has already reset says nothing about the one now running.
    @Test func aWindowThatResetIsDropped() throws {
        let snap = try #require(ClaudeLiveQuota.snapshot(
            from: [report("a", age: 10, fiveResets: -60)], now: Self.now))
        #expect(snap.windows.map(\.name) == ["weekly"])
        // Both gone: no reading at all, rather than an empty one.
        var r = report("b", age: 10, seven: nil, fiveResets: -60)
        r.rateLimits.append(.init(kind: "seven_day", percentUsed: 5, resetsAt: Self.now.addingTimeInterval(-1)))
        #expect(ClaudeLiveQuota.snapshot(from: [r], now: Self.now) == nil)
    }

    /// An older session with windows still speaks when the newest has none.
    @Test func aReportWithoutWindowsIsPassedOver() throws {
        let empty = ModReport(sessionId: "x", ts: Self.now.timeIntervalSince1970)
        let snap = try #require(ClaudeLiveQuota.snapshot(from: [empty, report("a", age: 60)], now: Self.now))
        #expect(snap.windows.count == 2)
    }

    @Test func anExceededLimitFillsTheMeterAndNoMore() throws {
        let snap = try #require(ClaudeLiveQuota.snapshot(from: [report("a", age: 1, five: 130)], now: Self.now))
        #expect(snap.windows[0].usedPercent == 100)
        #expect(snap.windows[0].remainingPercent == 0)
    }

    @Test func unknownKindsAreNotMeters() {
        let w = ClaudeLiveQuota.windows([.init(kind: "seven_day_opus", percentUsed: 5, resetsAt: nil)],
                                        now: Self.now)
        #expect(w.isEmpty)
    }

    /// First in line: when Claude Code has spoken, neither the network nor the
    /// local token estimate is consulted, and the reading says where it came from.
    @Test func theLiveDoorIsTriedFirstAndSaysSo() throws {
        let live = ClaudeQuota.Snapshot(
            windows: [UsageWindow(name: "5h", usedPercent: 40, resetsAt: Date().addingTimeInterval(3_600))],
            account: nil, at: Date())
        let reading = try #require(UsageCenter().claudeReading(live: live))
        #expect(reading.provider == "Claude")
        #expect(reading.windows.map(\.name) == ["5h"])
        #expect(reading.text.hasPrefix("60% left"))
        #expect(reading.detail?.contains(ClaudeLiveQuota.sourceLine) == true)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    @Test func aBurstOfWritesRedrawsOnce() async throws {
        let calls = Counter()
        let quota = ClaudeLiveQuota(refreshUsage: { calls.bump() })
        let now = Date()
        let r = ModReport(sessionId: "a", ts: now.timeIntervalSince1970, rateLimits: [
            .init(kind: "five_hour", percentUsed: 10, resetsAt: now.addingTimeInterval(3_600))])
        await MainActor.run {
            quota.update([r], now: now)
            var moved = r
            moved.rateLimits[0].percentUsed = 11
            quota.update([moved], now: now)
            quota.update([moved], now: now)
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(calls.value == 1)
        #expect(quota.latest(now: now)?.windows.first?.usedPercent == 11)
    }
}
