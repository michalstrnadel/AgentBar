import Foundation

/// What "keep the Mac awake" means at this moment, worked out from plain values.
///
/// Caffeine and Amphetamine keep a Mac awake for as long as you say. AgentBar can
/// say something they cannot: *while your agents work*. The rest — an hour, two,
/// until a time, until you turn it off — is the familiar set, so nobody has to keep
/// a second app for it.
///
/// No AppKit, IOKit or timers here: `KeepAwake` gathers the inputs, asks `decide`,
/// and applies the answer. That keeps every rule below a test away from proven.
enum KeepAwakeMode: Equatable, Codable {
    /// Awake while a session on this Mac works, and `KeepAwakePolicy.grace` after.
    case whileAgentsWork
    /// Awake until a wall-clock moment. Wall clock, not a countdown: a Mac that
    /// sleeps through the deadline anyway (lid closed) ends the mode on waking.
    case until(Date)
    /// Awake until the person turns it off.
    case indefinite
}

/// What a click remembers and the menu offers. "For 1 hour" is a choice; once
/// made it becomes `.until(now + 1h)`, so the mode itself never counts.
enum KeepAwakeChoice: String, CaseIterable, Equatable {
    case whileAgentsWork, oneHour, twoHours, untilTime, indefinite

    /// `untilMinutes` is minutes past midnight for "Until 18:00".
    func title(untilMinutes: Int) -> String {
        switch self {
        case .whileAgentsWork: return "While Agents Work"
        case .oneHour:         return "For 1 Hour"
        case .twoHours:        return "For 2 Hours"
        case .untilTime:       return "Until \(KeepAwakePolicy.clock(untilMinutes))"
        case .indefinite:      return "Indefinitely"
        }
    }

    func mode(now: Date, untilMinutes: Int, calendar: Calendar = .current) -> KeepAwakeMode {
        switch self {
        case .whileAgentsWork: return .whileAgentsWork
        case .oneHour:         return .until(now.addingTimeInterval(3600))
        case .twoHours:        return .until(now.addingTimeInterval(7200))
        case .untilTime:       return .until(KeepAwakePolicy.nextOccurrence(of: untilMinutes, after: now,
                                                                             calendar: calendar))
        case .indefinite:      return .indefinite
        }
    }

    /// The choice a live mode came from, for the checkmark. A deadline cannot say
    /// which of the three timed choices made it, so the caller passes what was
    /// last picked and a timed mode keeps that one ticked.
    static func matching(_ mode: KeepAwakeMode?, lastChoice: KeepAwakeChoice) -> KeepAwakeChoice? {
        switch mode {
        case nil:              return nil
        case .whileAgentsWork: return .whileAgentsWork
        case .indefinite:      return .indefinite
        case .until:
            return [.oneHour, .twoHours, .untilTime].contains(lastChoice) ? lastChoice : .untilTime
        }
    }
}

struct BatteryReading: Equatable {
    var onBattery: Bool
    var percent: Int
}

struct KeepAwakeSettings: Equatable {
    var keepDisplayOn = false
    var batteryGuard = true
    var batteryFloor = 20
    var nudge = false
}

enum KeepAwakeAssertion: Equatable {
    case none
    /// The Mac does not idle-sleep; the display may still dim and lock.
    case system
    /// Neither the Mac nor its display sleeps.
    case systemAndDisplay
}

struct KeepAwakeDecision: Equatable {
    enum Pause: Equatable {
        case battery(Int)
        case otherUser
    }

    var assertion: KeepAwakeAssertion = .none
    /// One line for a tooltip or a menu row: what is happening and until when.
    var reason = "Off"
    /// When it stops by itself, if it will: a deadline, or the end of the grace.
    var endsAt: Date?
    var paused: Pause?
    /// A timed mode whose deadline has passed — the coordinator clears it.
    var expired = false
    /// Local sessions working (or waiting on you, within the cap) right now.
    var working = 0

    var isOn: Bool { assertion != .none }
}

enum KeepAwakePolicy {
    /// How long the Mac stays up after the last agent stops. Claude Code enters
    /// `done` after every turn; five minutes covers reading the answer and typing
    /// the next prompt, and is short enough that a session left idle lets the Mac
    /// sleep soon after.
    static let grace: TimeInterval = 5 * 60
    /// A request waiting on you is mid-work — the agent is blocked, not finished —
    /// but one nobody answers must not hold the Mac up all night.
    static let humanWaitCap: TimeInterval = 30 * 60

    struct Inputs {
        var mode: KeepAwakeMode?
        var sessions: [Session]
        var now: Date
        /// When work was last seen; the coordinator keeps it, so this stays pure.
        var lastWorkAt: Date?
        var battery: BatteryReading?
        var userSessionActive = true
        var settings = KeepAwakeSettings()
    }

    /// Work on this Mac. A cloud or ssh row (`entrypoint: "cloud"`) runs on a
    /// machine whose sleep is not ours, and a decayed row is already a guess.
    static func isLocalWork(_ s: Session, now: Date) -> Bool {
        guard s.entrypoint != "cloud", !s.decayed else { return false }
        if s.state.isWorking { return true }
        if s.state.waitsOnHuman {
            return s.ts <= 0 || now.timeIntervalSince1970 - s.ts < humanWaitCap
        }
        return false
    }

    static func decide(_ i: Inputs) -> KeepAwakeDecision {
        var d = KeepAwakeDecision()
        guard let mode = i.mode else { return d }
        let kind: KeepAwakeAssertion = i.settings.keepDisplayOn || i.settings.nudge
            ? .systemAndDisplay : .system
        d.working = i.sessions.filter { isLocalWork($0, now: i.now) }.count

        switch mode {
        case .until(let end):
            guard i.now < end else {
                d.expired = true
                return d
            }
            d.endsAt = end
            d.reason = "Awake until \(clock(end)) · \(left(end.timeIntervalSince(i.now)))"
        case .indefinite:
            d.reason = "Awake until you turn it off"
        case .whileAgentsWork:
            if d.working > 0 {
                d.reason = d.working == 1 ? "Awake while 1 agent works" : "Awake while \(d.working) agents work"
            } else if let last = i.lastWorkAt, i.now.timeIntervalSince(last) < grace {
                let end = last.addingTimeInterval(grace)
                d.endsAt = end
                d.reason = "Agents done · sleeps in \(span(end.timeIntervalSince(i.now)))"
            } else {
                // Armed, nothing to hold up: the Mac sleeps as usual until an agent starts.
                d.reason = "Waiting for an agent to start"
                return d
            }
        }

        // Paused, not ended: the mode stays, and comes back by itself.
        if !i.userSessionActive {
            d.paused = .otherUser
            d.reason = "Paused — another user is signed in"
            return d
        }
        if i.settings.batteryGuard, let b = i.battery, b.onBattery, b.percent < i.settings.batteryFloor {
            d.paused = .battery(b.percent)
            d.reason = "Paused — battery at \(b.percent)%"
            return d
        }
        d.assertion = kind
        return d
    }

    /// The next moment the answer can change without anything else happening: a
    /// deadline, the end of the grace, a waiting request reaching its cap, and —
    /// while a countdown shows — the next minute, so "42 min left" stays true.
    static func nextEvaluation(_ i: Inputs) -> Date? {
        guard let mode = i.mode else { return nil }
        var candidates: [Date] = []
        let d = decide(i)
        if let end = d.endsAt {
            candidates.append(end)
            candidates.append(i.now.addingTimeInterval(60))
        }
        if case .whileAgentsWork = mode {
            for s in i.sessions where s.state.waitsOnHuman && isLocalWork(s, now: i.now) && s.ts > 0 {
                candidates.append(Date(timeIntervalSince1970: s.ts + humanWaitCap))
            }
        }
        return candidates.filter { $0 > i.now }.min()
    }

    // MARK: - Words

    static func clock(_ minutesPastMidnight: Int) -> String {
        let m = ((minutesPastMidnight % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return clock((c.hour ?? 0) * 60 + (c.minute ?? 0))
    }

    /// "42 min", "1 h 20 min", "under a minute".
    static func span(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if seconds < 60 { return "under a minute" }
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// "42 min left".
    static func left(_ seconds: TimeInterval) -> String { "\(span(seconds)) left" }

    /// The short form for a menu badge: "42m", "1h 20m".
    static func badge(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// The next time the clock reads `minutesPastMidnight`, strictly after `now`:
    /// "Until 18:00" picked at 19:00 means tomorrow evening, not a mode that has
    /// already ended.
    static func nextOccurrence(of minutesPastMidnight: Int, after now: Date,
                               calendar: Calendar = .current) -> Date {
        let m = ((minutesPastMidnight % 1440) + 1440) % 1440
        var c = calendar.dateComponents([.year, .month, .day], from: now)
        c.hour = m / 60
        c.minute = m % 60
        c.second = 0
        let today = calendar.date(from: c) ?? now
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }
}
