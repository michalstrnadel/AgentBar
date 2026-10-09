import Cocoa

/// Calls `tick` once a second while it runs — only while its view is in a window,
/// so a closed menu or a hidden island counts nothing. The ticks are lined up on
/// `anchor` (the deadline, or the moment counting up began), so the figure turns
/// over on the second it changes rather than up to a second late.
final class SecondTicker {
    private var timer: Timer?
    private let tick: () -> Void

    init(_ tick: @escaping () -> Void) { self.tick = tick }

    func run(_ on: Bool, anchor: Date?) {
        timer?.invalidate()
        timer = nil
        guard on else { return }
        let now = Date().timeIntervalSince1970
        let phase = (anchor?.timeIntervalSince1970 ?? 0).truncatingRemainder(dividingBy: 1)
        var next = now.rounded(.down) + phase + 0.02
        while next <= now { next += 1 }
        let t = Timer(fire: Date(timeIntervalSince1970: next), interval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        t.tolerance = 0.05
        // .common: an open menu tracks in its own run loop mode.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit { timer?.invalidate() }
}

/// The first row of every Keep Mac Awake menu: the countdown in large digits, what
/// happens when it ends, and a thin bar that empties as it runs. It ticks itself
/// while the menu is open, so it is true to the second without the menu being
/// rebuilt; a refresh hands it a new line with `update`.
final class KeepAwakeStatusView: NSView {
    static let width: CGFloat = 264
    private static let inset: CGFloat = 20

    private(set) var line: KeepAwakeStatusLine
    private let headline = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let bar = CountdownBar()
    private lazy var ticker = SecondTicker { [weak self] in self?.redraw() }

    init(_ line: KeepAwakeStatusLine) {
        self.line = line
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 10))
        autoresizingMask = [.width]
        headline.font = .monospacedDigitSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize + 1,
                                                   weight: .semibold)
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        for field in [headline, detail] {
            field.lineBreakMode = .byTruncatingTail
            field.cell?.truncatesLastVisibleLine = true
            addSubview(field)
        }
        addSubview(bar)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        apply()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ line: KeepAwakeStatusLine) {
        guard line != self.line else { return }
        self.line = line
        apply()
        restartTicker()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        redraw()
        restartTicker()
    }

    private func restartTicker() {
        switch line.clock {
        case .none:                  ticker.run(false, anchor: nil)
        case .remaining(let end, _): ticker.run(window != nil, anchor: end)
        case .elapsed(let since):    ticker.run(window != nil, anchor: since)
        }
    }

    /// Lays out for the line's shape: a bar only for a span with a known start.
    private func apply() {
        let showsBar = line.remainingFraction(now: Date()) != nil
        let height: CGFloat = showsBar ? 60 : 46
        setFrameSize(NSSize(width: max(frame.width, Self.width), height: height))
        let w = frame.width - Self.inset * 2
        headline.frame = NSRect(x: Self.inset - 2, y: height - 26, width: w, height: 20)
        detail.frame = NSRect(x: Self.inset - 2, y: height - 42, width: w, height: 15)
        bar.isHidden = !showsBar
        bar.frame = NSRect(x: Self.inset, y: 9, width: w, height: 4)
        bar.autoresizingMask = [.width]
        headline.autoresizingMask = [.width]
        detail.autoresizingMask = [.width]
        bar.tint = line.paused ? .systemYellow : .controlAccentColor
        detail.stringValue = line.detail
        detail.toolTip = line.detail
        redraw()
    }

    private func redraw() {
        let now = Date()
        let text = line.headline(now: now)
        headline.stringValue = text
        headline.textColor = line.paused ? .systemYellow : line.on ? .labelColor : .secondaryLabelColor
        bar.fraction = line.remainingFraction(now: now) ?? 0
        setAccessibilityLabel("Keep Mac Awake: \(text). \(line.detail)")
    }
}

/// A rounded track with the remaining share filled from the left; it empties toward it.
final class CountdownBar: NSView {
    var fraction: Double = 0 { didSet { if fraction != oldValue { needsDisplay = true } } }
    var tint: NSColor = .controlAccentColor { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        guard fraction > 0 else { return }
        let fill = NSRect(x: 0, y: 0, width: max(bounds.height, bounds.width * fraction), height: bounds.height)
        tint.setFill()
        NSBezierPath(roundedRect: fill, xRadius: r, yRadius: r).fill()
    }
}
