import AppKit

/// Draws Your Day: one card, at any moment of the two seconds it takes to build.
///
/// A recap you open every evening is read, not watched, so it is one card with
/// everything on it rather than a story of slides — the card is the point, and a
/// story was a longer way to the same numbers. It builds once (the words rise,
/// the time counts up, the hours grow, the tiles land) and then holds still.
///
/// **One deterministic function** — `draw(at:wrap:size:in:still:)` — is the window,
/// the PNG, the GIF and the MP4. Nothing here keeps state between frames: the card
/// at 1.3 s looks the same every time it is drawn, which is what lets an export be
/// exactly what was on screen and lets a test hold a frame still.
///
/// The canvas is flipped (y down). Layout is in units of `u`, the canvas's short
/// side over 1080, so the 405-point window and the 1080-pixel export are the same
/// picture at two sizes. Portrait (9:16) and square share one layout that gives
/// the square less room, not a second design.
enum WrapRenderer {
    /// How long the card takes to build. Past this every frame is the still card.
    static let buildSeconds: Double = 2.6

    struct Frame {
        let w: DayWrap
        /// Seconds into the build.
        let s: Double
        let size: CGSize
        let ctx: CGContext
        let still: Bool
        var W: CGFloat { size.width }
        var H: CGFloat { size.height }
        var u: CGFloat { min(W, H) / 1080 }
        /// Side margin.
        var m: CGFloat { (square ? 72 : 84) * u }
        var square: Bool { H / max(1, W) < 1.3 }
        var inner: CGFloat { W - 2 * m }
        func a(_ delay: Double, _ dur: Double = 0.7) -> Double {
            still ? 1 : WrapStyle.appear(s, delay, dur)
        }
        /// Entrance offset: slides up `by` units as `a` goes 0 → 1.
        func rise(_ a: Double, _ by: CGFloat = 60) -> CGFloat { CGFloat(1 - WrapStyle.easeOut(a)) * by * u }
    }

    /// Draws the card `seconds` into its build. `still` draws the finished card —
    /// the PNG, Reduce Motion, and any frame a test wants to hold.
    static func draw(at seconds: Double, wrap: DayWrap, size: CGSize, in ctx: CGContext, still: Bool = false) {
        let f = Frame(w: wrap, s: still ? 99 : seconds, size: size, ctx: ctx, still: still)
        ctx.saveGState()
        ctx.clip(to: CGRect(origin: .zero, size: size))
        card(f)
        ctx.restoreGState()
    }

    typealias S = WrapStyle

    // MARK: - The card

    private static func card(_ f: Frame) {
        let w = f.w
        let brand = S.colour(for: w.topAgent?.id ?? "claude")
        S.fill(CGRect(origin: .zero, size: f.size), S.night)
        S.glow(CGPoint(x: f.W * 0.95, y: f.H * 0.02), f.W * 0.95, brand.withAlphaComponent(0.55), in: f.ctx)
        S.glow(CGPoint(x: f.W * 0.0, y: f.H * 0.62), f.W * 0.75, S.violet.withAlphaComponent(0.32), in: f.ctx)
        S.glow(CGPoint(x: f.W * 0.9, y: f.H * 1.0), f.W * 0.7, S.blue.withAlphaComponent(0.28), in: f.ctx)

        var y = header(f, top: (f.square ? 56 : 112) * f.u)
        if w.isEmpty {
            empty(f, y: y)
        } else {
            y = hero(f, y: y + (f.square ? 18 : 52) * f.u)
            y = chart(f, y: y + (f.square ? 6 : 44) * f.u)
            tiles(f, y: y + (f.square ? 8 : 48) * f.u)
        }
        footer(f)
    }

    // MARK: Header — who you were

    /// The date, then the persona as the headline and its reason under it, with
    /// the persona's symbol large and faint behind them. Returns the bottom.
    private static func header(_ f: Frame, top: CGFloat) -> CGFloat {
        let w = f.w
        if !w.isEmpty, let sym = S.symbol(w.persona.symbol, size: (f.square ? 300 : 420) * f.u, weight: .black,
                                          color: S.cream.withAlphaComponent(0.11)) {
            let pop = S.easeBack(f.a(0.1, 1.0))
            let sz = sym.size
            f.ctx.saveGState()
            f.ctx.translateBy(x: f.W - f.m - sz.width * 0.38, y: top + sz.height * 0.42)
            f.ctx.scaleBy(x: CGFloat(pop), y: CGFloat(pop))
            S.image(sym, in: CGRect(x: -sz.width / 2, y: -sz.height / 2, width: sz.width, height: sz.height))
            f.ctx.restoreGState()
        }

        let a = f.a(0.0, 0.5)
        S.text((w.range.title + " with agents · " + dateLine(w)).uppercased(), S.font(24 * f.u, .heavy),
               S.cream.withAlphaComponent(0.6), x: f.m, y: top - f.rise(a, 16), width: f.inner,
               tracking: 120, alpha: CGFloat(a))
        var y = top + 50 * f.u
        if w.isEmpty { return y }

        let lead = w.range == .today ? "Today you were" : "This week you were"
        let b = f.a(0.1, 0.6)
        y += S.text(lead, S.font((f.square ? 34 : 40) * f.u, .bold), S.cream.withAlphaComponent(0.85),
                    x: f.m, y: y + f.rise(b, 24), width: f.inner, alpha: CGFloat(b))
        y += 4 * f.u
        // The title, its last word in lime: "The Orchestrator".
        let words = w.persona.title.split(separator: " ").map(String.init)
        let tf = S.fitting(w.persona.title, max: (f.square ? 120 : 156) * f.u, width: f.inner, tracking: -45)
        var x = f.m
        var lineH: CGFloat = 0
        for (i, word) in words.enumerated() {
            let c = f.a(0.2 + Double(i) * 0.12, 0.7)
            let piece = i == words.count - 1 ? word : word + " "
            S.text(piece, tf, i == words.count - 1 ? S.lime : S.cream, x: x, y: y + f.rise(c, 70),
                   width: f.inner * 2, tracking: -45, lineHeight: 0.95, alpha: CGFloat(c))
            x += S.measure(piece, tf, tracking: -45).width
            lineH = tf.pointSize * 0.95
        }
        y += lineH + 18 * f.u
        let r = f.a(0.55)
        y += S.text(w.persona.reason, S.font((f.square ? 30 : 36) * f.u, .semibold), S.cream.withAlphaComponent(0.75),
                    x: f.m, y: y + f.rise(r, 24), width: f.inner, lineHeight: 1.15, alpha: CGFloat(r))
        return y
    }

    private static func empty(_ f: Frame, y: CGFloat) {
        let w = f.w
        let a = f.a(0.15, 0.8)
        let title = w.range == .today ? "A quiet day." : "A quiet week."
        let h = S.text(title, S.font((f.square ? 120 : 150) * f.u, .black), S.cream, x: f.m, y: y + f.rise(a, 60),
                       width: f.inner, tracking: -45, lineHeight: 0.95, alpha: CGFloat(a))
        let b = f.a(0.5)
        S.text("Nothing has finished yet \(w.range == .today ? "today" : "this week"). "
               + "Come back when your agents have worked.",
               S.font(38 * f.u, .semibold), S.cream.withAlphaComponent(0.7),
               x: f.m, y: y + h + 30 * f.u + f.rise(b, 24), width: f.inner, lineHeight: 1.2, alpha: CGFloat(b))
    }

    // MARK: Hero — agent time

    /// The day's one big number, counting up, and what it is made of.
    private static func hero(_ f: Frame, y: CGFloat) -> CGFloat {
        let w = f.w
        let a = f.a(0.45, 1.4)
        let p = S.easeOut(a)
        let big: String, what: String
        if w.timed > 0 {
            big = S.duration(w.agentSeconds, progress: p)
            var s = "of agent time · \(w.sessions) session\(w.sessions == 1 ? "" : "s")"
            if w.busySeconds > 0, w.busySeconds < w.agentSeconds - 60 {
                s += " · \(HistoryDigest.duration(w.busySeconds)) on the clock"
            }
            if w.timed < w.sessions { s += " · timed on \(w.timed)" }
            what = s
        } else {
            big = S.grouped(Int((Double(w.sessions) * p).rounded()))
            what = "session\(w.sessions == 1 ? "" : "s") finished"
        }
        // Sized for the widest number the count passes through ("10h 59m" on its
        // way to "11h"), so it neither changes size nor wraps as it runs.
        let widest = w.timed > 0 && w.agentSeconds >= 3_600
            ? "\(Int(w.agentSeconds / 3_600))h 59m" : (w.timed > 0 ? "59m" : S.grouped(w.sessions))
        let font = S.fitting(widest, max: (f.square ? 132 : 236) * f.u, width: f.inner, rounded: true, tracking: -50)
        let shown = f.a(0.4, 0.3)
        let h = S.text(big, font, S.cream, x: f.m - 6 * f.u, y: y, width: f.W * 2, tracking: -50,
                       lineHeight: 0.9, alpha: CGFloat(shown))
        let b = f.a(0.75)
        // The number's box carries room for descenders it has none of.
        let below = y + h - font.pointSize * 0.1
        let h2 = S.text(what, S.font((f.square ? 26 : 32) * f.u, .bold), S.cream.withAlphaComponent(0.6),
                        x: f.m, y: below + f.rise(b, 20), width: f.inner, lineHeight: 1.15,
                        alpha: CGFloat(b))
        return below + h2
    }

    // MARK: Chart — the shape of the day

    /// The hours (or days) as bars in the colour of the agent that had most of
    /// each, with the moment the most ran at once marked on them. Returns the bottom.
    private static func chart(_ f: Frame, y: CGFloat) -> CGFloat {
        let w = f.w
        let bins = w.bins
        guard let maxBin = bins.max(), maxBin > 0 else { return y }
        let chartH = (f.square ? 96 : 250) * f.u
        let top = y + (f.square ? 50 : 56) * f.u   // room for the peak's label
        let bottom = top + chartH
        let today = w.range == .today
        let gap = (today ? 7 : 18) * f.u
        let bw = (f.inner - gap * CGFloat(bins.count - 1)) / CGFloat(bins.count)
        let best = w.range == .week ? bins.indices.max { bins[$0] < bins[$1] } : nil

        for (i, v) in bins.enumerated() {
            let g = S.easeBack(f.a(0.75 + Double(i) * (today ? 0.025 : 0.08), 0.55))
            let h = max(5 * f.u, chartH * CGFloat(v / maxBin)) * CGFloat(max(0, g))
            let agent = w.binAgents.indices.contains(i) ? w.binAgents[i] : ""
            S.pill(CGRect(x: f.m + CGFloat(i) * (bw + gap), y: bottom - h, width: bw, height: h),
                   v > 0 ? S.colour(for: agent) : S.cream.withAlphaComponent(0.10),
                   radius: min(bw / 2, (today ? 10 : 16) * f.u))
        }

        // The axis: a few hours, or every day's initial.
        let labels: [(Int, String)] = today
            ? [(0, "0"), (6, "6"), (12, "12"), (18, "18"), (23, "23")]
            : (0..<bins.count).map { ($0, weekday(w.binStart($0), short: true)) }
        let la = f.a(0.9)
        for (i, l) in labels {
            let x = f.m + CGFloat(i) * (bw + gap)
            S.text(l, S.font(24 * f.u, .bold), (i == best ? S.lime : S.cream).withAlphaComponent(i == best ? 1 : 0.5),
                   x: x - 40 * f.u, y: bottom + 12 * f.u, width: bw + 80 * f.u, align: .center, alpha: CGFloat(la))
        }

        // The day's peak, or the week's best day: a line through the chart with a label.
        let mark: (x: CGFloat, label: String)? = {
            if let best {
                return (f.m + CGFloat(best) * (bw + gap) + bw / 2,
                        "Best day · \(weekday(w.binStart(best), short: false)) · \(HistoryDigest.duration(bins[best]))")
            }
            if w.peak >= 2 {
                let span = w.binLength * Double(bins.count)
                let x = f.m + f.inner * CGFloat(S.clamp((w.peakAt - w.start) / span))
                return (x, "\(w.peak) at once · \(DayWrap.clock(w.peakAt))")
            }
            return nil
        }()
        if let mark {
            let d = f.a(1.6, 0.45)
            let lineTop = top - 8 * f.u
            S.fill(CGRect(x: mark.x - 2 * f.u, y: lineTop, width: 4 * f.u,
                          height: (bottom - lineTop) * CGFloat(S.easeOut(d))), S.pink)
            let font = S.font(24 * f.u, .heavy, rounded: true)
            let tw = S.measure(mark.label, font).width + 36 * f.u
            let px = min(max(f.m, mark.x - tw / 2), f.W - f.m - tw)
            let pill = CGRect(x: px, y: lineTop - 44 * f.u + f.rise(d, 16), width: tw, height: 44 * f.u)
            S.pill(pill, S.pink.withAlphaComponent(CGFloat(d)))
            S.text(mark.label, font, S.night, x: pill.minX, y: pill.minY + 9 * f.u, width: tw, align: .center,
                   alpha: CGFloat(d))
        }
        return bottom + (f.square ? 36 : 44) * f.u
    }

    // MARK: Tiles — the rest of the day

    struct Tile {
        let caption: String
        let value: String
        let detail: String
        let color: NSColor
        /// An agent whose mark sits beside the value.
        var agent: String? = nil
        /// The value in two colours: "+3,160" in green, then "−1,000" in red.
        var second: (String, NSColor)? = nil
    }

    /// The facts that exist, in the order they are worth: the top agent, the
    /// code, you, the projects; then the plainer ones if room is left.
    static func tileFacts(_ w: DayWrap) -> [Tile] {
        var out: [Tile] = []
        if let top = w.topAgent {
            let share = w.agentSeconds > 0
                ? "\(Int((top.seconds / w.agentSeconds * 100).rounded())) % of the time · \(HistoryDigest.duration(top.seconds))"
                : "\(top.sessions) of \(w.sessions) sessions"
            out.append(Tile(caption: "Top agent", value: top.name, detail: share, color: S.colour(for: top.id),
                            agent: top.id))
        }
        if w.changeMeasured > 0, w.linesAdded + w.linesRemoved > 0 {
            var detail = "lines across \(S.grouped(w.filesChanged)) file\(w.filesChanged == 1 ? "" : "s")"
            if w.changeMeasured < w.sessions { detail += " · in \(w.changeMeasured) of \(w.sessions) sessions" }
            out.append(Tile(caption: "Code", value: "+" + S.grouped(w.linesAdded), detail: detail, color: S.green,
                            second: ("−" + S.grouped(w.linesRemoved), S.red)))
        }
        let decided = w.waits.answered + w.waits.byRules
        if decided > 0 {
            var bits: [String] = []
            if w.waits.byRules > 0 { bits.append("\(w.waits.byRules) by your rules") }
            if w.waits.waited >= 60 { bits.append("they waited \(HistoryDigest.duration(w.waits.waited))") }
            else if let fast = w.waits.fastest { bits.append("fastest \(S.shortWait(fast))") }
            out.append(Tile(caption: "You", value: "\(S.grouped(decided)) answer\(decided == 1 ? "" : "s")",
                            detail: bits.joined(separator: " · "), color: S.pink))
        }
        if let p = w.projects.first {
            let rest = w.projects.dropFirst().map(\.name)
            let detail = rest.isEmpty
                ? (p.seconds > 0 ? HistoryDigest.duration(p.seconds) : "\(p.sessions) session\(p.sessions == 1 ? "" : "s")")
                : "then " + rest.joined(separator: ", ")
            out.append(Tile(caption: "Top project", value: p.name, detail: detail, color: S.orange))
        }
        if w.agents.count >= 2 {
            out.append(Tile(caption: "Agents", value: "\(w.agents.count)",
                            detail: w.agents.prefix(4).map(\.name).joined(separator: ", "), color: S.violet))
        }
        if w.failed > 0 {
            out.append(Tile(caption: "Failed", value: "\(w.failed)", detail: "of \(w.sessions) sessions", color: S.red))
        }
        return out
    }

    private static func tiles(_ f: Frame, y: CGFloat) {
        let facts = tileFacts(f.w)
        let cols = f.square ? 3 : 2
        let rows = f.square ? 1 : 2
        let gap = 20 * f.u
        let footerTop = f.H - footerHeight(f) - 24 * f.u
        let tw = (f.inner - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let th = min((f.square ? 250 : 270) * f.u, (footerTop - y - gap * CGFloat(rows - 1)) / CGFloat(rows))
        guard th > 150 * f.u else { return }
        for (i, t) in facts.prefix(cols * rows).enumerated() {
            let b = S.easeBack(f.a(1.15 + Double(i) * 0.12, 0.6))
            let alpha = CGFloat(min(1, max(0, b)))
            let x = f.m + CGFloat(i % cols) * (tw + gap)
            let ty = y + CGFloat(i / cols) * (th + gap) + CGFloat(1 - b) * 40 * f.u
            let pad = (f.square ? 26 : 32) * f.u
            S.pill(CGRect(x: x, y: ty, width: tw, height: th), S.cream.withAlphaComponent(0.075 * alpha), radius: 34 * f.u)
            S.circle(CGPoint(x: x + pad + 7 * f.u, y: ty + pad + 14 * f.u), 7 * f.u, t.color.withAlphaComponent(alpha))
            S.text(t.caption.uppercased(), S.font((f.square ? 20 : 22) * f.u, .heavy), S.cream.withAlphaComponent(0.6),
                   x: x + pad + 24 * f.u, y: ty + pad, width: tw - 2 * pad, tracking: 110, alpha: alpha)

            var vx = x + pad
            let maxValue = (f.square ? 54 : 72) * f.u
            let valueTop = ty + pad + (f.square ? 46 : 54) * f.u
            var room = tw - 2 * pad
            if let id = t.agent {
                let side = maxValue * 0.9
                let r = CGRect(x: vx, y: valueTop + 4 * f.u, width: side, height: side)
                if id == "claude" {
                    let px = side / 16
                    S.clawd(S.clawdPoses(.think).first ?? "", origin: CGPoint(x: r.minX - 2 * px, y: r.minY + 2 * px),
                            pixel: px, alpha: alpha)
                } else if let mark = S.mark(for: id) {
                    let ratio = mark.size.width / max(1, mark.size.height)
                    let mw = min(side * ratio, side * 1.4)
                    S.image(mark, in: CGRect(x: r.minX, y: r.midY - mw / ratio / 2, width: mw, height: mw / ratio),
                            alpha: alpha)
                }
                vx += side + 16 * f.u
                room -= side + 16 * f.u
            }
            let whole = t.second.map { t.value + " " + $0.0 } ?? t.value
            let vf = S.fitting(whole, max: maxValue, width: room, rounded: true, tracking: -30)
            let vy = valueTop + (maxValue - vf.pointSize) * 0.5
            // A pair reads in its own colours: "+3,160" green, "−1,000" red.
            S.text(t.value, vf, t.second == nil ? S.cream : t.color, x: vx, y: vy, width: room + 4 * f.u,
                   tracking: -30, alpha: alpha)
            if let (s, c) = t.second {
                let off = S.measure(t.value + " ", vf, tracking: -30).width
                S.text(s, vf, c, x: vx + off, y: vy, width: room - off + 4 * f.u, tracking: -30, alpha: alpha)
            }
            S.text(t.detail, S.font((f.square ? 21 : 24) * f.u, .semibold), S.cream.withAlphaComponent(0.6),
                   x: x + pad, y: ty + th - pad - 2 * 24 * f.u * 1.15, width: tw - 2 * pad, lineHeight: 1.15,
                   alpha: alpha)
        }
    }

    // MARK: Footer — where this came from

    private static func footerHeight(_ f: Frame) -> CGFloat { (f.square ? 84 : 150) * f.u }

    private static func footer(_ f: Frame) {
        let px = (f.square ? 5 : 7) * f.u
        let clawdH = 12 * px
        let base = f.H - (f.square ? 40 : 92) * f.u
        let a = f.a(1.7, 0.6)
        // Clawd hops up into place once the card is built.
        let hop = f.still ? 0 : CGFloat(1 - S.easeBack(a)) * 40 * f.u
        S.clawd(S.clawdPoses(.think).first ?? "", origin: CGPoint(x: f.m, y: base - clawdH + hop), pixel: px,
                alpha: CGFloat(a))
        let tx = f.m + 22 * px + 18 * f.u
        S.text("AgentBar", S.font((f.square ? 28 : 34) * f.u, .heavy), S.cream, x: tx, y: base - clawdH - 2 * f.u,
               width: 400 * f.u, tracking: -10, alpha: CGFloat(a))
        S.text("free & open source for macOS", S.font((f.square ? 20 : 24) * f.u, .medium),
               S.cream.withAlphaComponent(0.55), x: tx, y: base - clawdH + (f.square ? 34 : 42) * f.u,
               width: 500 * f.u, alpha: CGFloat(a))
    }

    // MARK: - Words

    private static func dateLine(_ w: DayWrap) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        switch w.range {
        case .today:
            f.dateFormat = "EEEE d MMMM"
            return f.string(from: Date(timeIntervalSince1970: w.start))
        case .week:
            f.dateFormat = "d MMM"
            return f.string(from: Date(timeIntervalSince1970: w.start)) + " – "
                + f.string(from: Date(timeIntervalSince1970: w.end))
        }
    }

    private static func weekday(_ t: TimeInterval, short: Bool) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US")
        df.dateFormat = short ? "EEEEE" : "EEEE"
        return df.string(from: Date(timeIntervalSince1970: t))
    }

    // MARK: - To a bitmap

    /// One frame as a bitmap at `pixels`.
    static func bitmap(at seconds: Double, wrap: DayWrap, pixels: CGSize, still: Bool = false) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width),
                                         pixelsHigh: Int(pixels.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let g = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cg = g.cgContext
        cg.translateBy(x: 0, y: pixels.height)
        cg.scaleBy(x: 1, y: -1)
        let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = flipped
        draw(at: seconds, wrap: wrap, size: pixels, in: cg, still: still)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
