import Cocoa

/// Over the shoulder, on the island: under the first row of a working Claude Code
/// session, the last few things it reached for and the last thing it said.
///
/// It keeps itself current — re-reading the transcript's end every 1.5 s while it
/// is on screen — rather than asking the panel to rebuild, because a rebuild would
/// end a hold on Allow halfway through. It is inside a panel the person opened and
/// goes with it; nothing here opens anything. Off in Settings ▸ Island.
final class LiveFeedView: NSView {
    static let prefKey = "islandLiveFeed"
    static var enabled: Bool { UserDefaults.standard.object(forKey: prefKey) as? Bool ?? true }

    private let session: Session
    private var items: [LiveFeed.Item]
    private var timer: Timer?
    private static let lineH: CGFloat = 15
    private static let mono = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    private static let monoBold = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold)

    init?(session: Session) {
        guard Self.enabled, session.state.isWorking else { return nil }
        let items = LiveFeed.read(session)
        guard !items.isEmpty else { return nil }
        self.session = session
        self.items = items
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: CGFloat(LiveFeed.maxItems) * Self.lineH + 10).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        updateAccessibility()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func refresh() {
        guard window?.isVisible == true else { return }
        let next = LiveFeed.read(session)
        guard next != items, !next.isEmpty else { return }
        items = next
        updateAccessibility()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            wantsLayer = true
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.2
            layer?.add(fade, forKey: "feed")
        }
        needsDisplay = true
    }

    private func updateAccessibility() {
        setAccessibilityLabel("Right now: " + items.map(Self.spoken).joined(separator: ", "))
    }

    private static func spoken(_ i: LiveFeed.Item) -> String {
        switch i {
        case .tool(let n, let a): return a.isEmpty ? n : "\(n) \(a)"
        case .said(let t): return "said \(t)"
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.05).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        // Newest at the bottom, like the terminal it stands in for.
        let top = bounds.height - 5
        let start = LiveFeed.maxItems - items.count
        for (n, item) in items.enumerated() {
            let y = top - CGFloat(start + n + 1) * Self.lineH
            let newest = n == items.count - 1
            let line = NSMutableAttributedString()
            switch item {
            case .tool(let name, let arg):
                line.append(NSAttributedString(string: "› \(name)", attributes: [
                    .font: Self.monoBold, .foregroundColor: NSColor.white.withAlphaComponent(newest ? 0.85 : 0.5)]))
                if !arg.isEmpty {
                    line.append(NSAttributedString(string: "  \(arg)", attributes: [
                        .font: Self.mono, .foregroundColor: NSColor.white.withAlphaComponent(newest ? 0.75 : 0.42)]))
                }
            case .said(let text):
                line.append(NSAttributedString(string: "“\(text)”", attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.white.withAlphaComponent(newest ? 0.92 : 0.55)]))
            }
            let rect = NSRect(x: 8, y: y, width: bounds.width - 16, height: Self.lineH)
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            line.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    deinit { timer?.invalidate() }
}
