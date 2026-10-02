import Cocoa

/// The day, along the bottom of the island — as a sentence, as a shape, or both.
///
/// The menu already carries "Today" as a line of text, and a line of text is the
/// right answer for a menu. The island is a different surface: it is the one you
/// glance at without deciding to, and a run of bars answers "was today busy, and did
/// anything fall over" before you have finished reading the words above it.
///
/// **The two halves are off by default and switch on separately**, because they cost
/// different things and suit different days. The line is one row of small text and
/// says what actually happened. The strip is taller, and only earns its height when
/// the day was spread across several sessions — spend it in a single agent and it
/// draws one bar the width of the panel. Either can be switched on in
/// **Appearance…**, and the same numbers stay under the island's ⋯ regardless.
///
/// It lives in the island's footer, pinned rather than scrolling, for the same reason
/// the ⋯ button does — a panel full of approval cards must not push the day out of
/// sight. The bars are drawn, not composed from rows: thirty views rebuilt once a
/// second while an agent works would cost more than the whole rest of the panel.
final class TodayStripView: NSView, NSViewToolTipOwner {
    /// Past this the bars are thinner than the gaps between them and the shape stops
    /// meaning anything. The oldest fall off the left with a count in their place —
    /// the newest work is the part you are trying to see.
    static let maxBars = 30

    /// "12 sessions · 3h 40m · 4.1M tokens" — the line the menu's Today row carries.
    static var showsTotal: Bool {
        get { UserDefaults.standard.bool(forKey: "islandTodayTotal") }
        set { write(newValue, forKey: "islandTodayTotal") }
    }

    /// One bar per session that finished today.
    static var showsBars: Bool {
        get { UserDefaults.standard.bool(forKey: "islandTodayBars") }
        set { write(newValue, forKey: "islandTodayBars") }
    }

    static var enabled: Bool { showsTotal || showsBars }

    private static func write(_ value: Bool, forKey key: String) {
        guard value != UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(value, forKey: key)
        onChange?()
    }

    /// Fired after either switch changes, so the island takes the strip in or out
    /// without a relaunch. Owned by the app delegate, like `IconColor.onChange` and
    /// `Presentation.onChange` — the windows never reach into a surface themselves.
    static var onChange: (() -> Void)?

    private static let lineHeight: CGFloat = 14
    private static let barHeight: CGFloat = 6
    private static let barGap: CGFloat = 2
    /// Between the line and the bars, when both are on.
    private static let stackGap: CGFloat = 5
    /// Every session gets at least this much, however short it was. A one-minute run
    /// next to a four-hour one would otherwise be invisible, and "invisible" reads as
    /// "did not happen".
    private static let barFloor: CGFloat = 3
    private static let overflowWidth: CGFloat = 20

    private let headline = NSTextField(labelWithString: "")
    private var shown: [HistoryDigest.Entry] = []
    private var overflow = 0
    /// Captured at build time rather than read while drawing: the view is cached and
    /// reused, and a switch flipped underneath it must produce a new view, not a
    /// half-redrawn old one.
    private let withBars: Bool

    static func height(total: Bool = showsTotal, bars: Bool = showsBars) -> CGFloat {
        (total ? lineHeight : 0) + (bars ? barHeight : 0) + (total && bars ? stackGap : 0)
    }

    /// What the strip is drawn from, so a rebuild that would produce the same picture
    /// can be skipped. The two switches are part of it: flipping one has to invalidate
    /// the cached view. See `IslandController.todayStrip`.
    static func signature(_ summary: HistoryDigest.Summary, _ entries: [HistoryDigest.Entry]) -> String {
        "\(showsTotal):\(showsBars):\(summary.sessions):\(summary.failed)"
            + ":\(Int(summary.seconds)):\(summary.tokens):\(Int(entries.first?.endedAt ?? 0))"
    }

    init(summary: HistoryDigest.Summary, entries: [HistoryDigest.Entry], width: CGFloat) {
        withBars = Self.showsBars
        let h = Self.height()
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: h))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: h).isActive = true

        // Oldest on the left: a day is read in the direction it happened. `digest`
        // hands them back newest first because that is what a list wants.
        let all = Array(entries.reversed())
        shown = Array(all.suffix(Self.maxBars))
        overflow = all.count - shown.count

        guard Self.showsTotal else { return }
        headline.stringValue = HistoryDigest.headline(summary)
        headline.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        headline.textColor = NSColor.white.withAlphaComponent(0.38)
        headline.lineBreakMode = .byTruncatingTail
        headline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headline)
        NSLayoutConstraint.activate([
            headline.leadingAnchor.constraint(equalTo: leadingAnchor),
            headline.trailingAnchor.constraint(equalTo: trailingAnchor),
            headline.topAnchor.constraint(equalTo: topAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard withBars, !shown.isEmpty else { return }
        for (rect, entry) in layoutBars() {
            color(for: entry).setFill()
            NSBezierPath(roundedRect: rect, xRadius: Self.barHeight / 2,
                         yRadius: Self.barHeight / 2).fill()
        }
        guard overflow > 0 else { return }
        "+\(overflow)".draw(at: NSPoint(x: 0, y: 0), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.3),
        ])
    }

    /// One rectangle per session: longer ran, wider bar.
    ///
    /// **Widths are square-rooted, not linear.** A real day is one eight-hour session
    /// and a handful of two-minute ones, and drawn to scale the long one takes 97% of
    /// the strip and everything else disappears — which is the opposite of what a
    /// glance is for. The square root keeps the order and the sense of "that one was
    /// much bigger" while leaving the short sessions visible. Nothing here is offered
    /// as a measurement: the real numbers are in the line above and in each bar's
    /// tooltip, and that is the only reason a compressed scale is honest.
    ///
    /// Sessions the protocol could not time (`started_at` is optional, and several
    /// agents omit it) take the floor width and nothing more — they must not be given
    /// an invented share of the day, and they must not be dropped either.
    private func layoutBars() -> [(NSRect, HistoryDigest.Entry)] {
        let leading = overflow > 0 ? Self.overflowWidth : 0
        let available = bounds.width - leading
        let n = CGFloat(shown.count)
        let gaps = (n - 1) * Self.barGap
        let extra = max(0, available - gaps - n * Self.barFloor)
        let weights = shown.map { $0.duration.map { CGFloat(($0).squareRoot()) } ?? 0 }
        let totalWeight = weights.reduce(0, +)

        var x = leading
        var out: [(NSRect, HistoryDigest.Entry)] = []
        for (e, weight) in zip(shown, weights) {
            var w = Self.barFloor
            if totalWeight > 0 {
                w += extra * (weight / totalWeight)
            } else {
                // Nothing could be timed at all: an equal share is the only division
                // that claims nothing.
                w += extra / n
            }
            out.append((NSRect(x: x, y: 0, width: w, height: Self.barHeight), e))
            x += w + Self.barGap
        }
        return out
    }

    private func color(for e: HistoryDigest.Entry) -> NSColor {
        // The same red the live rows use for a failed turn, so one vocabulary covers
        // "this went wrong" everywhere on the panel.
        guard !e.failed else { return NSColor(srgbRed: 1, green: 0.45, blue: 0.42, alpha: 1) }
        let brand = IconRenderer.legibleOnDark(e.resolvedAgent.brand)
        // Half-lit when it could not be timed: the bar is a placeholder at floor
        // width, and it should not look like a measurement.
        return e.duration == nil ? brand.withAlphaComponent(0.45) : brand
    }

    // MARK: - Tooltips

    override func layout() {
        super.layout()
        removeAllToolTips()
        guard withBars else { return }
        for (rect, entry) in layoutBars() {
            // The bars are 6pt tall; the hit target is the whole strip height, or
            // nobody would ever land on one.
            let target = NSRect(x: rect.minX, y: 0, width: rect.width, height: bounds.height)
            addToolTip(target, owner: self, userData: nil)
            tips.append((target, HistoryDigest.line(entry)))
        }
    }

    private var tips: [(NSRect, String)] = []

    override func removeAllToolTips() {
        super.removeAllToolTips()
        tips.removeAll()
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        tips.first { $0.0.contains(point) }?.1 ?? ""
    }
}
