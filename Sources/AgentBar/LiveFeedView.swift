import Cocoa

/// Over the shoulder, on the island: under the first row of a working Claude Code or Codex
/// session, the last few things it reached for and the last thing it said — and,
/// under the newest shell command that has finished, the last lines it printed.
///
/// It keeps itself current — re-reading the transcript's end every 1.5 s while it
/// is on screen — rather than asking the panel to rebuild, because a rebuild would
/// end a hold on Allow halfway through. It is inside a panel the person opened and
/// goes with it; nothing here opens anything. Off in Settings ▸ Island.
///
/// The box hugs what it draws: its height is fixed when the row is built (the panel
/// was sized around it), and a refresh that brings more than fits drops the oldest
/// lines instead of growing past the panel. The next rebuild sizes it afresh.
final class LiveFeedView: NSView {
    static let prefKey = "islandLiveFeed"
    static var enabled: Bool { UserDefaults.standard.object(forKey: prefKey) as? Bool ?? true }

    private let session: Session
    private var feed: LiveFeed.Feed
    private var timer: Timer?
    private static let pad: CGFloat = 5
    private static let lineH: CGFloat = 15
    private static let outputH: CGFloat = 13
    private static let mono = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    private static let monoBold = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold)
    private static let monoSmall = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
    /// Output sits under the command's name, past the "› ".
    private static let outputIndent: CGFloat = 8 + ("› " as NSString).size(withAttributes: [.font: monoBold]).width

    private enum Line {
        case item(LiveFeed.Item, newest: Bool)
        case output(String, error: Bool)
        var height: CGFloat {
            if case .output = self { return LiveFeedView.outputH }
            return LiveFeedView.lineH
        }
    }

    init?(session: Session) {
        guard Self.enabled, session.state.isWorking else { return nil }
        let feed = LiveFeed.read(session)
        guard !feed.isEmpty else { return nil }
        self.session = session
        self.feed = feed
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let content = Self.lines(feed).reduce(0) { $0 + $1.height }
        heightAnchor.constraint(equalToConstant: content + 2 * Self.pad).isActive = true
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
        guard next != feed, !next.isEmpty else { return }
        feed = next
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
        var spoken = feed.items.map(Self.spoken)
        if let o = feed.output, o.after < spoken.count {
            spoken[o.after] += (o.isError ? ", failed: " : ", printed: ") + o.lines.joined(separator: " / ")
        }
        setAccessibilityLabel("Right now: " + spoken.joined(separator: ", "))
    }

    private static func spoken(_ i: LiveFeed.Item) -> String {
        switch i {
        case .tool(let n, let a): return a.isEmpty ? n : "\(n) \(a)"
        case .said(let t): return "said \(t)"
        }
    }

    /// The feed in drawing order: each item, and the output under its command.
    private static func lines(_ feed: LiveFeed.Feed) -> [Line] {
        var out: [Line] = []
        for (n, item) in feed.items.enumerated() {
            out.append(.item(item, newest: n == feed.items.count - 1))
            if let o = feed.output, o.after == n {
                out += o.lines.map { .output($0, error: o.isError) }
            }
        }
        return out
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.05).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        // Newest at the bottom, like the terminal it stands in for — but drawn from
        // the top down, so the box has no empty band above its first line. What
        // does not fit the height the panel gave it loses its oldest lines.
        var room = bounds.height - 2 * Self.pad
        var shown: [Line] = []
        for line in Self.lines(feed).reversed() {
            guard line.height <= room + 0.5 else { break }
            room -= line.height
            shown.insert(line, at: 0)
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        var y = bounds.height - Self.pad
        for line in shown {
            y -= line.height
            let text = NSMutableAttributedString()
            var x: CGFloat = 8
            switch line {
            case .item(.tool(let name, let arg), let newest):
                text.append(NSAttributedString(string: "› \(name)", attributes: [
                    .font: Self.monoBold, .foregroundColor: NSColor.white.withAlphaComponent(newest ? 0.85 : 0.5)]))
                if !arg.isEmpty {
                    text.append(NSAttributedString(string: "  \(arg)", attributes: [
                        .font: Self.mono, .foregroundColor: NSColor.white.withAlphaComponent(newest ? 0.75 : 0.42)]))
                }
            case .item(.said(let said), let newest):
                text.append(NSAttributedString(string: "“\(said)”", attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.white.withAlphaComponent(newest ? 0.92 : 0.55)]))
            case .output(let out, let error):
                x = Self.outputIndent
                let ink = error ? IconRenderer.legibleOnDark(IconRenderer.amberDot).withAlphaComponent(0.8)
                                : NSColor.white.withAlphaComponent(0.4)
                text.append(NSAttributedString(string: out, attributes: [.font: Self.monoSmall, .foregroundColor: ink]))
            }
            text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
            let rect = NSRect(x: x, y: y, width: bounds.width - x - 8, height: line.height)
            text.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    deinit { timer?.invalidate() }
}
