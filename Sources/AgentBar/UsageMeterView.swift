import Cocoa

/// What each provider has left, as a short stack of meters in the menu.
///
/// The question this answers is *how much have I spent and how much is left* —
/// who, which window, a bar, and what remains. Since 1.44 also *will it last*:
/// when `UsagePace` says a window runs out before it resets, a line under it says
/// when. No history and no per-model breakdown; those are other questions.
///
/// It lives in the **menu** and not on the island. The island's one dim usage line
/// already says the same thing in a sentence, and the island's height is exactly
/// what got pushed back on the last time something new wanted to live down there.
/// The menu is the surface you open when you want the detail.
///
/// Drawn rather than composed, like `TodayStripView`: a stack of labels and
/// progress views rebuilt whenever a menu opens costs more than the whole rest of
/// the menu, and buys nothing a `draw(_:)` can't do.
final class UsageMeterView: NSView {
    /// Where the block is being drawn.
    ///
    /// **menu** is the stacked form: one row per window, names in a column, room
    /// for a reset time. **islandFooter** is the same information folded onto the
    /// single line the island already spends on usage — the meter instead of the
    /// sentence, at the same height, because the island's height is the thing that
    /// got pushed back on the last time something new wanted to live down there.
    enum Style { case menu, islandFooter }

    /// One line of the block. A window row carries a meter; a plain row is a
    /// provider that publishes no ceiling and gets a number instead — which is
    /// the honest shape, not a lesser one.
    struct Row {
        let provider: String     // "" on a provider's second window: said once
        let window: String       // "5h" / "weekly" / "" for a plain row
        let used: Double?        // nil = no meter
        let trailing: String
        /// This row is a sentence, not a value: a note under a provider, or a
        /// provider whose whole truth is a phrase because it publishes no
        /// ceiling. It starts at the margin and takes the width, because held in
        /// the numbers column it both reads as a number it isn't and runs out of
        /// room to be read at all — "~654k tok this 5h block · resets 12:00"
        /// arrived as "~654k tok this 5h block…", losing the half that answers
        /// the question.
        var spans = false
        /// Drawn in amber: a window about to run out.
        var warn = false
    }

    private static let rowHeight: CGFloat = 17
    private static let vPad: CGFloat = 3
    private static let meterWidth: CGFloat = 70
    private static let meterHeight: CGFloat = 4
    private static let windowWidth: CGFloat = 46
    /// Lines the block up with the menu's own text, like `ApprovalContextView`.
    private static let leading: CGFloat = 22
    private static let trailingPad: CGFloat = 14

    private static let label = NSFont.systemFont(ofSize: 11, weight: .medium)
    private static let small = NSFont.systemFont(ofSize: 11)
    private static let digits = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    private let rows: [Row]
    private let providerColumn: CGFloat
    private let style: Style
    /// A column exists when some row uses it, and then it is held open for every
    /// row — so each sentence begins in the same place and a missing meter reads
    /// as missing rather than as a shorter line. A block with no meters at all
    /// (only Copilot, say) keeps neither column and sits flush.
    private let windowColumn: CGFloat
    private let meterColumn: CGFloat

    /// Flattens the readings into rows. A provider's name is said once, on its
    /// first window, so two windows read as one thing with two parts rather than
    /// as two providers with similar names.
    static func rows(for readings: [UsageCenter.Reading]) -> [Row] {
        var out: [Row] = []
        for r in readings {
            defer {
                // Outside the branch on purpose: a provider with no windows is
                // the one most likely to have something to explain, and an
                // early return once swallowed exactly that note.
                if let note = r.note {
                    out.append(Row(provider: "", window: "", used: nil, trailing: note,
                                   spans: true))
                }
            }
            if r.windows.isEmpty {
                out.append(Row(provider: r.provider, window: "", used: nil, trailing: r.text,
                               spans: true))
                continue
            }
            for (i, w) in r.windows.enumerated() {
                // A window past its reset gets no meter. Nobody has written a
                // number since it rolled over: a full bar would be the last
                // window's news, and an empty one a zero nobody measured.
                out.append(Row(provider: i == 0 ? r.provider : "",
                               window: w.name,
                               used: w.expired() ? nil : w.usedPercent,
                               trailing: UsageCenter.short(w)))
                if !w.expired(), let f = UsagePace.shared.forecast(provider: r.provider, window: w) {
                    out.append(Row(provider: "", window: "", used: nil, trailing: UsagePace.sentence(f),
                                   spans: true, warn: true))
                }
            }
        }
        return out
    }

    /// The island's line has room for one window per provider, and it is the one
    /// about to run out — the same choice the sentence made. Everything else stays
    /// in the ⋯ menu, which is where detail belongs.
    static func compactRows(for readings: [UsageCenter.Reading]) -> [Row] {
        readings.compactMap { r in
            guard let w = r.windows.first(where: { !$0.expired() }) ?? r.windows.first else {
                guard !r.text.isEmpty else { return nil }
                // A provider with no meter and a reason for it says the reason
                // here too. The island is meant for numbers, and a missing bar
                // with no explanation is not a number — it is an app that looks
                // broken, which is exactly how it was read.
                let why = r.note.map { " · \($0)" } ?? ""
                return Row(provider: r.provider, window: "", used: nil,
                           trailing: r.text + why)
            }
            guard !w.expired() else {
                return Row(provider: r.provider, window: "", used: nil, trailing: "window reset")
            }
            // "3%" beside a bar that is almost entirely full reads as a
            // contradiction at a glance — the bar says what is gone, the number
            // says what is left. One word settles it.
            let left = "\(Int(w.remainingPercent.rounded()))% left"
            // The pace, only when it ends before the reset — and amber only when
            // that is within the half hour.
            if let f = UsagePace.shared.forecast(provider: r.provider, window: w) {
                return Row(provider: r.provider, window: "", used: w.usedPercent,
                           trailing: left + " · " + UsagePace.short(f), warn: UsagePace.urgent(f))
            }
            return Row(provider: r.provider, window: "", used: w.usedPercent, trailing: left)
        }
    }

    /// `tooltipReadings` is what the hover says when the island is showing a
    /// shortlist: the line holds what is running, and the tooltip still holds
    /// everything, so nothing disappears without a way back to it.
    init?(readings: [UsageCenter.Reading], style: Style = .menu,
          tooltipReadings: [UsageCenter.Reading]? = nil) {
        let described = tooltipReadings ?? readings
        let rows = style == .menu ? Self.rows(for: readings) : Self.compactRows(for: readings)
        guard !rows.isEmpty else { return nil }
        self.rows = rows
        self.style = style
        // The label column is as wide as the widest name and no wider — a fixed
        // one would leave a gap on a machine running only Codex.
        self.providerColumn = rows.map {
            $0.provider.isEmpty ? 0
                : ($0.provider as NSString).size(withAttributes: [.font: Self.label]).width
        }.max().map { $0 + 10 } ?? 0
        self.windowColumn = rows.contains { !$0.window.isEmpty } ? Self.windowWidth : 0
        self.meterColumn = rows.contains { $0.used != nil } ? Self.meterWidth + 10 : 0
        let height = style == .menu
            ? CGFloat(rows.count) * Self.rowHeight + Self.vPad * 2
            : Self.rowHeight
        // The menu's block is stretched to the menu's width by its autoresizing
        // mask. The island's line is not stretched by anything — it sits in a
        // stack beside the ⋯ button — so it has to state its own width or the
        // solver is free to pick one, and one of the widths it is free to pick
        // is zero. See `intrinsicContentSize`.
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: style == .menu ? 320 : Self.compactWidth(of: rows),
                                 height: height))
        if style == .menu { autoresizingMask = [.width] }
        // On the island the whole line is one tooltip: the full sentence for every
        // provider, including the window the line had no room for.
        toolTip = style == .menu
            ? described.compactMap { r in r.detail.map { "\(r.provider)\n\($0)" } }
                .joined(separator: "\n\n")
            : described.map { r in
                ([r.provider + " " + r.text] + (r.detail.map { [$0] } ?? [])).joined(separator: "\n")
            }.joined(separator: "\n")
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// What the island's line actually needs.
    ///
    /// Without this the view had no intrinsic width at all: `NSView` answers
    /// `noIntrinsicMetric`, the footer stack put it next to a spacer with the
    /// same hugging priority, and the solver was free to resolve that ambiguity
    /// either way. When it resolved against the line, the line was given zero
    /// width and drew nothing — the quota simply vanished from the island, and
    /// came back on the next rebuild, which is what made it look intermittent.
    override var intrinsicContentSize: NSSize {
        style == .menu
            ? NSSize(width: NSView.noIntrinsicMetric, height: frame.height)
            : NSSize(width: Self.compactWidth(of: rows), height: Self.rowHeight)
    }

    /// What the line wants, measured as the layout that draws it — so a width
    /// that disagrees with the drawing is not a thing that can happen. Pure,
    /// over the rows alone, so it can be checked without a view.
    static func compactWidth(of rows: [Row]) -> CGFloat {
        // The gap goes *between* readings; the last one does not need one after
        // it, so the line ends where its last piece ends.
        compactLayout(of: rows, in: .greatestFiniteMagnitude)
            .last.map { $0.x + $0.width } ?? 0
    }

    /// Rows are laid out top-down, in the order they are read. Without this they
    /// come out bottom-up: the first provider at the foot of the block, its
    /// weekly window above its 5-hour one. (Found by rendering the thing, which
    /// is the whole reason `renderForVerification` exists.)
    override var isFlipped: Bool { true }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard style == .menu else { return drawCompact() }
        var y = Self.vPad
        for row in rows {
            draw(row, atTop: y)
            y += Self.rowHeight
        }
    }

    // MARK: - The island's single line

    private static let compactMeter: CGFloat = 34
    private static let compactGap: CGFloat = 14

    /// One piece of the island's line: a provider's name, its bar, or its number.
    enum Piece: Equatable {
        case name(String)
        case meter(Double)
        case trailing(String)
        /// A trailing number about to run out, drawn in amber.
        case warning(String)
    }

    /// Where every piece lands, given the width the layout actually handed the
    /// line — which is not always the width the line asked for. The ⋯ button and
    /// the panel's edge are both to the right of it, so each piece gets
    /// `min(what it wants, what is left)` and the one that runs out ends in an
    /// ellipsis.
    ///
    /// That clamp is the whole fix for a line that used to draw straight through
    /// the button and out past the panel: text drawn `at:` a point ignores the
    /// view it is in, and since macOS 14 so does AppKit — `clipsToBounds` is
    /// false by default, so nothing downstream was going to stop it either.
    ///
    /// `drawCompact` draws this list and nothing else, and `compactWidth`
    /// measures it, so the measurement and the drawing cannot disagree.
    static func compactLayout(of rows: [Row], in limit: CGFloat)
        -> [(x: CGFloat, width: CGFloat, piece: Piece)] {
        var out: [(x: CGFloat, width: CGFloat, piece: Piece)] = []
        var x: CGFloat = 0
        // A piece with nothing left to be drawn into is left out rather than
        // placed at zero width past the edge, so the list is exactly what is on
        // screen and "does it fit" is a question about the list.
        func place(_ piece: Piece, wanting want: CGFloat) {
            let room = max(0, min(want, limit - x))
            if room > 0 { out.append((x, room, piece)) }
        }

        for row in rows {
            // Truncate rather than overflow — but never draw nothing. A line
            // squeezed narrower than its first reading used to come out empty,
            // which looks like a broken app rather than a narrow one.
            guard x == 0 || x < limit - 40 else { break }

            let name = (row.provider as NSString)
                .size(withAttributes: [.font: compactLabel]).width
            place(.name(row.provider), wanting: name)
            x += name + 6

            if let used = row.used {
                place(.meter(used), wanting: compactMeter)
                x += compactMeter + 6
            }
            let trailing = (row.trailing as NSString)
                .size(withAttributes: [.font: compactDigits]).width
            place(row.warn ? .warning(row.trailing) : .trailing(row.trailing), wanting: trailing)
            x += trailing + compactGap
        }
        return out
    }

    /// `Codex ▔▔▔▔ 74%   Claude ▔▔ 43%` — one line, the height the sentence it
    /// replaces already had. White rather than label colours: this one is drawn on
    /// the island's black card, where `labelColor` is whatever the menu bar's
    /// appearance says and not what is under it.
    private func drawCompact() {
        let top: CGFloat = 2
        for (x, width, piece) in Self.compactLayout(of: rows, in: bounds.width) {
            let box = NSRect(x: x, y: top, width: width, height: Self.rowHeight)
            switch piece {
            case .name(let text):
                (text as NSString).draw(in: box, withAttributes: [
                    .font: Self.compactLabel,
                    .foregroundColor: NSColor.white.withAlphaComponent(0.72),
                    .paragraphStyle: Self.truncating,
                ])
            case .meter(let used):
                drawMeter(in: NSRect(x: x, y: (bounds.height - Self.meterHeight) / 2,
                                     width: width, height: Self.meterHeight),
                          used: used, onDark: true)
            case .trailing(let text), .warning(let text):
                let warn: Bool = { if case .warning = piece { return true } else { return false } }()
                (text as NSString).draw(in: box, withAttributes: [
                    .font: Self.compactDigits,
                    .foregroundColor: warn ? IconRenderer.amberDot : IslandInk.quiet,
                    .paragraphStyle: Self.truncating,
                ])
            }
        }
    }

    private static let compactLabel = NSFont.systemFont(ofSize: 10, weight: .medium)
    private static let compactDigits = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    private func draw(_ row: Row, atTop y: CGFloat) {
        // Text sits on the row's baseline; the meter centres on the same line, so
        // the bar reads as part of the sentence and not as a separate object.
        let textY = y + 2
        var x = Self.leading

        if row.spans {
            if !row.provider.isEmpty {
                let name = row.provider as NSString
                name.draw(at: NSPoint(x: x, y: textY),
                          withAttributes: [.font: Self.label,
                                           .foregroundColor: NSColor.secondaryLabelColor])
                x += name.size(withAttributes: [.font: Self.label]).width + 10
            }
            (row.trailing as NSString).draw(
                in: NSRect(x: x, y: textY, width: max(0, bounds.width - x - Self.trailingPad),
                           height: Self.rowHeight),
                withAttributes: [
                    .font: row.provider.isEmpty ? Self.small : Self.digits,
                    // A note is quieter than the thing it is about; a provider's
                    // own sentence is the answer and reads like one.
                    .foregroundColor: row.provider.isEmpty
                        ? (row.warn ? NSColor.systemOrange : NSColor.tertiaryLabelColor)
                        : NSColor.secondaryLabelColor,
                    .paragraphStyle: Self.truncating,
                ])
            return
        }

        if !row.provider.isEmpty {
            (row.provider as NSString).draw(
                at: NSPoint(x: x, y: textY),
                withAttributes: [.font: Self.label, .foregroundColor: NSColor.secondaryLabelColor])
        }
        x += providerColumn

        if !row.window.isEmpty {
            (row.window as NSString).draw(
                at: NSPoint(x: x, y: textY),
                withAttributes: [.font: Self.small, .foregroundColor: NSColor.tertiaryLabelColor])
        }
        x += windowColumn

        if let used = row.used {
            drawMeter(in: NSRect(x: x, y: y + (Self.rowHeight - Self.meterHeight) / 2,
                                 width: Self.meterWidth, height: Self.meterHeight),
                      used: used, onDark: false)
        }
        x += meterColumn

        let width = max(0, bounds.width - x - Self.trailingPad)
        (row.trailing as NSString).draw(
            in: NSRect(x: x, y: textY, width: width, height: Self.rowHeight),
            withAttributes: [.font: Self.digits,
                             // The number is the answer; it gets the readable
                             // grey, and the window's name beside it the quiet one.
                             .foregroundColor: NSColor.secondaryLabelColor,
                             .paragraphStyle: Self.truncating])
    }

    /// Colour only where it means something. A meter that is orange at every
    /// value has told you nothing; one that turns amber at four fifths and red at
    /// nineteen twentieths is saying the only thing a colour can usefully say
    /// here.
    private func drawMeter(in rect: NSRect, used: Double, onDark: Bool) {
        // A bar squeezed to nothing draws nothing, rather than the one rounded
        // cap the minimum width below would otherwise put past the right edge.
        guard rect.width > 0 else { return }
        let ink = onDark ? NSColor.white : NSColor.labelColor
        let radius = rect.height / 2
        ink.withAlphaComponent(onDark ? 0.16 : 0.12).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        let fraction = min(max(used, 0), 100) / 100
        guard fraction > 0 else { return }
        // Never thinner than the cap it is drawn with: 1 % has to look like a
        // sliver rather than like nothing at all.
        let width = min(rect.width, max(rect.height, rect.width * CGFloat(fraction)))
        let fill: NSColor
        switch used {
        case 95...:  fill = NSColor.systemRed
        case 80...:  fill = NSColor.systemOrange
        default:     fill = ink.withAlphaComponent(onDark ? 0.5 : 0.55)
        }
        fill.setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY,
                                         width: width, height: rect.height),
                     xRadius: radius, yRadius: radius).fill()
    }

    private static let truncating: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return p
    }()
}

// MARK: - Offline verification

extension UsageMeterView {
    /// Renders the block to a PNG without opening a menu, so the one drawn surface
    /// this release adds can actually be looked at. The precedent is
    /// `SoundCenter.renderAllForVerification`: a surface nobody can see while
    /// building it ships with whatever it happens to look like — 1.18.0's island
    /// strip had one bar eating 97 % of the width, and only a screenshot found it.
    ///
    /// The set is fixed rather than live: it is a specification of every case the
    /// view has to handle at once — a calm window, one near its limit, one past it,
    /// a rolled-over window with no meter, a credit balance, and a provider with no
    /// ceiling at all.
    static func renderForVerification(to url: URL) -> Bool {
        let now = Date()
        let readings: [UsageCenter.Reading] = [
            UsageCenter.Reading(
                provider: "Codex", text: "", detail: "account: someone",
                windows: [UsageWindow(name: "5h", usedPercent: 97,
                                      resetsAt: now.addingTimeInterval(1_800)),
                          UsageWindow(name: "weekly", usedPercent: 27,
                                      resetsAt: now.addingTimeInterval(4 * 86_400))],
                note: "12.50 credits left"),
            UsageCenter.Reading(
                provider: "Claude", text: "",
                windows: [UsageWindow(name: "5h", usedPercent: 84,
                                      resetsAt: now.addingTimeInterval(7_200)),
                          UsageWindow(name: "weekly", usedPercent: 3,
                                      resetsAt: now.addingTimeInterval(-60))]),
            UsageCenter.Reading(provider: "Copilot", text: "2.4 AIU today"),
        ]
        // The state this feature is mostly in before somebody answers a Keychain
        // prompt: a provider with a sentence, no ceiling, and a reason. Its own
        // panel because a note under a provider that has no windows was, until a
        // test said otherwise, dropped on the floor.
        let unavailable: [UsageCenter.Reading] = [
            readings[0],
            UsageCenter.Reading(provider: "Claude",
                                text: "~654k tok this 5h block · resets 12:00",
                                note: "waiting on Keychain permission"),
        ]
        guard let menu = UsageMeterView(readings: readings),
              let waiting = UsageMeterView(readings: unavailable),
              // What the island shows while only Claude is running: the shortlist,
              // not the block. See `UsageCenter.relevant`.
              let island = UsageMeterView(readings: UsageCenter.relevant(readings,
                                                                         active: ["Claude"]),
                                          style: .islandFooter, tooltipReadings: readings),
              // The same line given less room than it wants — the state it is
              // actually in whenever a provider's whole truth is a sentence. It
              // used to keep drawing anyway, through the ⋯ button and out past
              // the panel's edge, and a screenshot is the only place that was
              // ever going to be visible.
              let squeezed = UsageMeterView(readings: unavailable, style: .islandFooter)
        else { return false }
        menu.frame = NSRect(x: 0, y: 0, width: 340, height: menu.frame.height)
        waiting.frame = NSRect(x: 0, y: 0, width: 340, height: waiting.frame.height)
        island.frame = NSRect(x: 0, y: 0, width: 400, height: island.frame.height)
        squeezed.frame = NSRect(x: 0, y: 0, width: 380, height: squeezed.frame.height)

        // Every style in one image, the island's line on its own black card the way
        // it is actually seen — a light-on-light screenshot of a dark surface has
        // told nobody anything.
        let gap: CGFloat = 12
        let size = NSSize(width: 400,
                          height: menu.frame.height + waiting.frame.height + island.frame.height
                              + squeezed.frame.height + gap * 5)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: size.width,
               height: island.frame.height + squeezed.frame.height + gap * 2).fill()
        // Each view is cached with the background it is actually seen on:
        // `cacheDisplay` on a view with no window fills opaque white, which drew
        // the island's white-on-black line as white on white and looked, from the
        // outside, exactly like text that was never drawn at all.
        let islandTop = island.frame.height + squeezed.frame.height + gap * 2
        let panels: [(UsageMeterView, NSPoint, NSColor)] = [
            (menu, NSPoint(x: 0, y: islandTop + gap * 2 + waiting.frame.height), .white),
            (waiting, NSPoint(x: 0, y: islandTop + gap), .white),
            (island, NSPoint(x: 10, y: squeezed.frame.height + gap), .black),
            (squeezed, NSPoint(x: 10, y: gap / 2), .black),
        ]
        for (view, origin, back) in panels {
            view.wantsLayer = true
            view.layer?.backgroundColor = back.cgColor
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            rep.draw(in: NSRect(origin: origin, size: view.frame.size))
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return false }
        return (try? data.write(to: url)) != nil
    }
}
