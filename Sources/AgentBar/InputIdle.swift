import CoreGraphics
import Foundation

/// How long the human has kept their hands off this Mac. Two things ask: the
/// notifier, which only calls a day quiet once nobody is watching, and the island,
/// which steps aside while nobody is there to see it. One measurement, so the two
/// can never disagree about whether the user is away.
enum InputIdle {
    /// Seconds since the last keyboard, mouse or trackpad event of any kind.
    /// `kCGAnyInputEventType` spelled out, because `CGEventType` has no case for it —
    /// it is the sentinel `0xFFFFFFFF`, not a real event type. Needs no permission
    /// and no entitlement, and it is one cheap call into the window server, cheap
    /// enough for the island's pointer poll to ask on every tick.
    static func seconds() -> TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }
}
