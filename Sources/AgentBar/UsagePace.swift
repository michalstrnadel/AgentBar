import Foundation

/// When a quota window runs out at the pace you are going.
///
/// "73 % used" is a fact about the past; the question at 14:00 is whether the
/// afternoon fits. This keeps the last few hours of each window's readings and
/// fits a line through the recent ones. It speaks only when the line says the
/// window ends **before it resets** — a forecast that changes nothing would be
/// a number to read and nothing to do — and it never notifies: a forecast wants
/// no answer (CLAUDE.md rule 2).
final class UsagePace {
    static let shared = UsagePace()

    struct Sample: Equatable { let t: TimeInterval; let used: Double }

    struct Forecast: Equatable {
        /// When the window reaches 100 % at this pace.
        let runsOutAt: Date
        /// Percent per hour, for the tooltip.
        let perHour: Double
    }

    /// How far back the fit looks, and how much it needs before it says anything.
    static let fitWindow: TimeInterval = 45 * 60
    static let minSpan: TimeInterval = 10 * 60
    static let minSamples = 4
    static let keep: TimeInterval = 3 * 3600

    private var series: [String: [Sample]] = [:]
    private var resets: [String: Date] = [:]
    private let lock = NSLock()

    static func key(_ provider: String, _ window: String) -> String { provider + "\u{0}" + window }

    /// Called with every refresh's readings. A window whose reset moved, or whose
    /// percentage went down, started over: its history is dropped.
    func record(_ readings: [UsageCenter.Reading], now: TimeInterval = Date().timeIntervalSince1970) {
        lock.lock(); defer { lock.unlock() }
        for r in readings {
            for w in r.windows where !w.expired() {
                let k = Self.key(r.provider, w.name)
                var s = series[k] ?? []
                if let reset = w.resetsAt, let was = resets[k], abs(reset.timeIntervalSince(was)) > 60 { s = [] }
                if let last = s.last, w.usedPercent < last.used - 0.5 { s = [] }
                if let reset = w.resetsAt { resets[k] = reset }
                if s.last?.used != w.usedPercent || (s.last.map { now - $0.t > 300 } ?? true) {
                    s.append(Sample(t: now, used: w.usedPercent))
                }
                s.removeAll { now - $0.t > Self.keep }
                series[k] = s
            }
        }
    }

    func forecast(provider: String, window: UsageWindow,
                  now: TimeInterval = Date().timeIntervalSince1970) -> Forecast? {
        lock.lock()
        let s = series[Self.key(provider, window.name)] ?? []
        lock.unlock()
        return Self.forecast(s, used: window.usedPercent, resetsAt: window.resetsAt, now: now)
    }

    /// The fit, pure. Least squares over the samples of the last `fitWindow`; a
    /// flat or falling line, too few points, or too short a span says nothing.
    static func forecast(_ samples: [Sample], used: Double, resetsAt: Date?,
                         now: TimeInterval) -> Forecast? {
        let recent = samples.filter { now - $0.t <= fitWindow }
        guard recent.count >= minSamples, let first = recent.first, let last = recent.last,
              last.t - first.t >= minSpan, used < 100 else { return nil }
        let n = Double(recent.count)
        let mt = recent.reduce(0) { $0 + $1.t } / n
        let mu = recent.reduce(0) { $0 + $1.used } / n
        var num = 0.0, den = 0.0
        for s in recent { num += (s.t - mt) * (s.used - mu); den += (s.t - mt) * (s.t - mt) }
        guard den > 0 else { return nil }
        let slope = num / den                       // percent per second
        guard slope * 3600 >= 1 else { return nil }  // under 1 %/h is not a pace
        let eta = now + (100 - used) / slope
        // Only a window that ends before it starts over is worth a sentence; with
        // no reset known, only one that ends within the working day.
        if let resetsAt { guard eta < resetsAt.timeIntervalSince1970 else { return nil } }
        else { guard eta - now < 12 * 3600 else { return nil } }
        return Forecast(runsOutAt: Date(timeIntervalSince1970: eta), perHour: slope * 3600)
    }

    /// "out ~15:40", the island's half-line.
    static func short(_ f: Forecast, now: Date = Date()) -> String {
        "out ~" + UsageCenter.when(f.runsOutAt, now: now)
    }

    /// "At this pace: limit ~15:40 (+18 %/h)".
    static func sentence(_ f: Forecast, now: Date = Date()) -> String {
        "At this pace: limit ~\(UsageCenter.when(f.runsOutAt, now: now)) (+\(Int(f.perHour.rounded())) %/h)"
    }

    /// Less than half an hour left at this pace.
    static func urgent(_ f: Forecast, now: Date = Date()) -> Bool {
        f.runsOutAt.timeIntervalSince(now) < 30 * 60
    }
}
