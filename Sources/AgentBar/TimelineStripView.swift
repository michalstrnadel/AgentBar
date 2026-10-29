import Cocoa

/// The last hour of one session as a 3-point strip: worked, waited on you, failed,
/// rested — drawn, not composed, and blank for what AgentBar did not see.
final class TimelineStripView: NSView {
    private let segments: [SessionTimeline.Segment]
    private let now: TimeInterval

    init(segments: [SessionTimeline.Segment], now: TimeInterval) {
        self.segments = segments
        self.now = now
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 3).isActive = true
        toolTip = SessionTimeline.summary(segments)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(SessionTimeline.summary(segments))
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        let from = now - SessionTimeline.window
        NSColor.white.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 1.5, yRadius: 1.5).fill()
        for s in segments {
            let x0 = CGFloat((s.start - from) / SessionTimeline.window) * w
            let x1 = CGFloat((s.end - from) / SessionTimeline.window) * w
            Self.color(s.phase).setFill()
            NSRect(x: x0, y: 0, width: max(1, x1 - x0), height: bounds.height).fill()
        }
    }

    private static func color(_ p: SessionTimeline.Phase) -> NSColor {
        switch p {
        case .working: return NSColor.white.withAlphaComponent(0.6)
        case .waiting: return IconRenderer.amberDot
        case .failed:  return .systemRed
        case .rest:    return NSColor.white.withAlphaComponent(0.14)
        }
    }
}
