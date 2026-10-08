import CoreGraphics
import Foundation

/// How long the human has kept their hands off this Mac. Several things ask: the
/// notifier, which only calls a day quiet once nobody is watching; the island,
/// which steps aside while nobody is there to see it; the updater, which installs
/// while you are away; and the presence nudge. One measurement, so they can never
/// disagree about whether the user is away.
enum InputIdle {
    /// When AgentBar last moved the pointer itself (`PresenceNudge`), and how idle
    /// the human was at that moment. The system's idle clock cannot tell our
    /// synthetic event from a real one, so without this a nudge would make AgentBar
    /// believe the person never leaves: the island would never hide while away, no
    /// quiet banner would fire, and an update would never install.
    private static var lastNudge: (at: Date, idleBefore: TimeInterval)?

    static func noteNudge(idleBefore: TimeInterval, at date: Date = Date()) {
        lastNudge = (date, idleBefore)
    }

    /// Seconds since the human last touched a keyboard, mouse or trackpad.
    static func seconds() -> TimeInterval {
        humanIdle(system: systemSeconds(), nudge: lastNudge, now: Date())
    }

    /// Seconds since the last input event of any kind, ours included.
    /// `kCGAnyInputEventType` spelled out, because `CGEventType` has no case for it —
    /// it is the sentinel `0xFFFFFFFF`, not a real event type. Needs no permission
    /// and no entitlement, and it is one cheap call into the window server, cheap
    /// enough for the island's pointer poll to ask on every tick.
    static func systemSeconds() -> TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    /// The human's idle time, given the system's and our last nudge. If nothing has
    /// happened since the nudge (the system clock is at least as old as it), the
    /// last event was ours: the person has been away for as long as they had been
    /// before it, plus the time since. A real event after the nudge resets the
    /// system clock below that, and the system is right again.
    static func humanIdle(system: TimeInterval, nudge: (at: Date, idleBefore: TimeInterval)?,
                          now: Date) -> TimeInterval {
        guard let nudge else { return system }
        let sinceNudge = now.timeIntervalSince(nudge.at)
        guard sinceNudge >= 0, system >= sinceNudge - 1 else { return system }
        return nudge.idleBefore + sinceNudge
    }
}
