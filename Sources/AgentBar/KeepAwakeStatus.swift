import Foundation

/// The line at the top of every Keep Mac Awake menu and the figure beside the
/// island's cup: what is happening, and — whenever it will stop by itself — how
/// long is left, to the second.
///
/// 1.48.0 to 1.52.0 said "Awake until 17:10 · 15 min left" once, in a grey row,
/// and the minutes only moved when the menu happened to be rebuilt: you picked
/// "For 15 Minutes" and nothing on screen counted. This is the countdown. It is
/// plain data — the clock is a date, not a number of seconds — so a view can tick
/// it every second without asking `KeepAwake` anything, and a test can read it at
/// any moment it likes.
struct KeepAwakeStatusLine: Equatable {
    enum Clock: Equatable {
        /// Nothing to count: working agents, a trigger, off, paused.
        case none
        /// Counts down to `end`. `from` is where the span began, for the bar;
        /// nil draws no bar.
        case remaining(end: Date, from: Date?)
        /// Counts up: "Indefinitely" has no end, so it says how long it has run.
        case elapsed(since: Date)
    }

    /// The headline when nothing counts, and the row's title for anything that
    /// reads titles (a test, VoiceOver before the view draws).
    var title: String
    /// The second line: what happens next.
    var detail: String
    var clock: Clock = .none
    var on = false
    var paused = false

    static let off = KeepAwakeStatusLine(title: "Off", detail: "The Mac sleeps as usual")

    /// "12:34 left", "On for 1:02:03", or the title.
    func headline(now: Date) -> String {
        switch clock {
        case .none:
            return title
        case .remaining(let end, _):
            return "\(KeepAwakePolicy.countdown(end.timeIntervalSince(now))) left"
        case .elapsed(let since):
            return "On for \(KeepAwakePolicy.countdown(now.timeIntervalSince(since).rounded(.down)))"
        }
    }

    /// The share of the span still to run, 1 at the start and 0 at the end; nil
    /// when there is no span to draw.
    func remainingFraction(now: Date) -> Double? {
        guard case .remaining(let end, let from?) = clock else { return nil }
        let total = end.timeIntervalSince(from)
        guard total > 0 else { return nil }
        return min(1, max(0, end.timeIntervalSince(now) / total))
    }

    /// The deadline, when there is one to count to.
    var endsAt: Date? {
        if case .remaining(let end, _) = clock { return end }
        return nil
    }

    /// Worked out from what `KeepAwake` already knows. `since` is when the click
    /// that started the mode happened, nil after a relaunch from a build that did
    /// not keep it; `lastWorkAt` starts the five-minute grace.
    static func make(mode: KeepAwakeMode?, decision d: KeepAwakeDecision, since: Date?,
                     lastWorkAt: Date?) -> KeepAwakeStatusLine {
        guard mode != nil || d.trigger != nil else { return .off }
        var line = KeepAwakeStatusLine(title: d.reason, detail: "", on: true)
        if d.paused != nil {
            line.paused = true
            line.detail = "Comes back by itself"
            return line
        }
        let grace = KeepAwakePolicy.grace
        switch mode ?? d.trigger?.mode {
        case .until(let end)?:
            line.clock = .remaining(end: end, from: since)
            line.detail = "Until \(KeepAwakePolicy.clock(end)), then the Mac sleeps as usual"
        case .indefinite?:
            if d.trigger != nil {
                line.detail = "Started by itself · Turn Off snoozes it"
            } else {
                line.clock = since.map { .elapsed(since: $0) } ?? .none
                line.detail = "Until you turn it off"
            }
        case .whileAgentsWork?:
            if d.working > 0 {
                line.detail = "Then \(KeepAwakePolicy.span(grace)) more, and the Mac may sleep"
            } else if let end = d.endsAt {
                line.title = "Agents done"
                line.clock = .remaining(end: end, from: lastWorkAt ?? end.addingTimeInterval(-grace))
                line.detail = "Then the Mac sleeps — unless an agent starts"
            } else {
                line.detail = "The Mac sleeps as usual until one does"
            }
        case nil:
            return .off
        }
        return line
    }
}
