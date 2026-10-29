import Cocoa

/// The last hour of one session as a 3-point strip: worked, waited on you, failed,
/// rested — drawn, not composed, and blank for what AgentBar did not see.
///
/// Under the pointer it answers "what was it doing then" (`TimelinePeek`): the
/// strip thickens into the gap above it, a hairline marks the moment, and `peek`
/// — a small card the row holds just above the strip — says the time, the phase
/// and what the transcript logged around it. Only while the pointer is on the
/// strip: nothing opens, nothing resizes, and a click is still the row's.
final class TimelineStripView: NSView {
    private let segments: [SessionTimeline.Segment]
    private let now: TimeInterval
    private let session: Session?
    /// The card the row lays over itself above the strip; hidden until hovered.
    let peek = TimelinePeekView()

    /// The view is this tall; the strip fills `rest` of it at the bottom and all
    /// of it under the pointer. The row lays it out with no spacing above, so the
    /// row is exactly as tall as with a 3-point strip and the usual gap.
    static let height: CGFloat = 6
    static let rest: CGFloat = 3

    private var tracking: NSTrackingArea?
    private var entries: [TimelinePeek.Entry]?
    /// The pointer's x while it is on the strip.
    private(set) var hoverX: CGFloat? { didSet { needsDisplay = true; updatePeek() } }

    init(segments: [SessionTimeline.Segment], now: TimeInterval, session: Session? = nil) {
        self.segments = segments
        self.now = now
        self.session = session
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        peek.isHidden = true
        peek.summary = SessionTimeline.summary(segments)
        if let session { entries = TimelinePeek.cached(session) }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(SessionTimeline.summary(segments))
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
        // A rebuild replaces the row under a pointer that has not moved: carry on
        // rather than waiting for the next twitch.
        if hoverX == nil, let window, window.isVisible {
            let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(p) { enter(p.x) }
        }
    }

    override func mouseEntered(with event: NSEvent) { enter(convert(event.locationInWindow, from: nil).x) }
    override func mouseMoved(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        if hoverX == nil { enter(x) } else { hoverX = x }
    }
    override func mouseExited(with event: NSEvent) { hoverX = nil }

    private func enter(_ x: CGFloat) {
        let first = hoverX == nil
        hoverX = x
        if first, let session {
            TimelinePeek.load(session) { [weak self] found in
                guard let self else { return }
                self.entries = found
                self.updatePeek()
            }
        }
    }

    /// Forces the hovered look at `x`, for Scripts/dev/render-preview.swift.
    func previewHover(at x: CGFloat) {
        hoverX = x
        peek.alphaValue = 1
    }

    private func updatePeek() {
        guard let x = hoverX else {
            peek.isHidden = true
            return
        }
        let t = TimelinePeek.time(atX: Double(x), width: Double(bounds.width), now: now)
        peek.heading = TimelinePeek.heading(t, phase: TimelinePeek.phase(at: t, in: segments))
        peek.items = entries.map { TimelinePeek.items($0, at: t) } ?? []
        if peek.isHidden {
            peek.isHidden = false
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                peek.alphaValue = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.12
                    peek.animator().alphaValue = 1
                }
            }
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        let from = now - SessionTimeline.window
        let band = NSRect(x: 0, y: 0, width: w, height: hoverX == nil ? Self.rest : bounds.height)
        NSColor.white.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: band, xRadius: band.height / 2, yRadius: band.height / 2).fill()
        for s in segments {
            let x0 = CGFloat((s.start - from) / SessionTimeline.window) * w
            let x1 = CGFloat((s.end - from) / SessionTimeline.window) * w
            Self.color(s.phase).setFill()
            NSRect(x: x0, y: 0, width: max(1, x1 - x0), height: band.height).fill()
        }
        if let x = hoverX {
            NSColor.white.setFill()
            NSRect(x: min(max(0, x.rounded() - 0.5), w - 1), y: 0, width: 1, height: bounds.height).fill()
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

/// The strip's answer: "14:32 · worked", the hour's summary on the right, and up
/// to three steps from the transcript around that moment — one line each. Drawn
/// over the row's own lines while the pointer is on the strip, and never takes
/// a click.
final class TimelinePeekView: NSView {
    var heading = "" { didSet { if heading != oldValue { needsDisplay = true } } }
    var summary = "" { didSet { needsDisplay = true } }
    var items: [LiveFeed.Item] = [] {
        didSet {
            guard items != oldValue else { return }
            height.constant = Self.height(items.count)
            needsDisplay = true
        }
    }

    private static let lineH: CGFloat = 15
    private static let pad: CGFloat = 5
    private static let mono = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    private static let monoBold = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold)
    private lazy var height: NSLayoutConstraint = {
        let c = heightAnchor.constraint(equalToConstant: Self.height(0))
        // The row's top edge outranks it: a short row cuts the last line.
        c.priority = .defaultHigh
        return c
    }()

    static func height(_ n: Int) -> CGFloat { pad * 2 + CGFloat(1 + n) * lineH }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        height.isActive = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        NSColor(calibratedWhite: 0.1, alpha: 1).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.1).setStroke()
        path.lineWidth = 1
        path.stroke()

        let left = Self.pad + 3, width = bounds.width - left * 2
        var y = bounds.height - Self.pad - Self.lineH
        let head = NSAttributedString(string: heading, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9)])
        Self.line(head, in: NSRect(x: left, y: y, width: width, height: Self.lineH))
        // The hour's totals take what room the heading leaves, and go first.
        let room = width - head.size().width - 12
        if room > 60, !summary.isEmpty {
            let style = NSMutableParagraphStyle()
            style.alignment = .right
            style.lineBreakMode = .byTruncatingHead
            NSAttributedString(string: summary, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.4),
                .paragraphStyle: style,
            ]).draw(with: NSRect(x: left + width - room, y: y + 1, width: room, height: Self.lineH),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        for item in items {
            y -= Self.lineH
            guard y >= Self.pad - 2 else { break }
            let line = NSMutableAttributedString()
            switch item {
            case .tool(let name, let arg):
                line.append(NSAttributedString(string: "› \(name)", attributes: [
                    .font: Self.monoBold, .foregroundColor: NSColor.white.withAlphaComponent(0.75)]))
                if !arg.isEmpty {
                    line.append(NSAttributedString(string: "  \(arg)", attributes: [
                        .font: Self.mono, .foregroundColor: NSColor.white.withAlphaComponent(0.6)]))
                }
            case .said(let text):
                line.append(NSAttributedString(string: "“\(text)”", attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.75)]))
            }
            Self.line(line, in: NSRect(x: left, y: y, width: width, height: Self.lineH))
        }
    }

    private static func line(_ s: NSAttributedString, in rect: NSRect) {
        let m = NSMutableAttributedString(attributedString: s)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        m.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: m.length))
        m.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
