import Cocoa

/// Keeps chat apps from marking you Away while the Mac is kept awake: after four
/// minutes without input (Teams goes Away at five), a mouse-moved event at the
/// pointer's own position. Zero distance — the pointer does not move, nothing is
/// clicked or typed — but it is a real input event, which is what those apps watch.
///
/// Off unless switched on, only while Keep Mac Awake is holding the Mac up, and only
/// with the Accessibility permission AgentBar already asks for keystroke approval
/// (posting events needs it). Every nudge is recorded in `InputIdle`, so AgentBar's
/// own sense of whether you are away is not fooled by it.
final class PresenceNudge {
    static let interval: TimeInterval = 60
    static let threshold: TimeInterval = 4 * 60

    private var timer: Timer?

    var isRunning: Bool { timer != nil }

    func setRunning(_ run: Bool) {
        if run, timer == nil {
            let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.tick() }
            t.tolerance = 10
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !run {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Whether a tick should nudge, from plain values. The system clock, not the
    /// human one: it is the system clock the chat app reads, and the last nudge
    /// already reset it.
    static func shouldNudge(systemIdle: TimeInterval, trusted: Bool) -> Bool {
        trusted && systemIdle >= threshold
    }

    private func tick() {
        guard Self.shouldNudge(systemIdle: InputIdle.systemSeconds(), trusted: KeystrokeApprover.trusted)
        else { return }
        let idleBefore = InputIdle.seconds()
        // NSEvent's origin is bottom-left of the main screen; CGEvent's is top-left.
        let p = NSEvent.mouseLocation
        let height = NSScreen.screens.first?.frame.height ?? 0
        guard let e = CGEvent(mouseEventSource: CGEventSource(stateID: .combinedSessionState),
                              mouseType: .mouseMoved,
                              mouseCursorPosition: CGPoint(x: p.x, y: height - p.y),
                              mouseButton: .left) else { return }
        e.post(tap: .cghidEventTap)
        InputIdle.noteNudge(idleBefore: idleBefore)
    }
}
