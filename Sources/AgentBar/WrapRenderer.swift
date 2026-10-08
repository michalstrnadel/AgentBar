import AppKit

/// Draws Your Day: one card, at any moment of the two seconds it takes to build.
///
/// A recap you open every evening is read, not watched, so it is one card with
/// everything on it rather than a story of slides — the card is the point, and a
/// story was a longer way to the same numbers. It builds once (the words rise,
/// the time counts up, the hours grow, the rows land) and then holds still.
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
        var m: CGFloat { (square ? 72 : 96) * u }
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

    /// Paper, ink, and the agents' own colours on the bars and nowhere else. A
    /// recap people post is a thing they put their name to; it should look made,
    /// not generated — no glows, no badges, no headline in a colour of its own.
    private static func card(_ f: Frame) {
        S.fill(CGRect(origin: .zero, size: f.size), S.paper)
        var y = header(f, top: (f.square ? 56 : 104) * f.u)
        if f.w.pending {
            adding(f, y: y + (f.square ? 40 : 80) * f.u)
        } else if f.w.isEmpty {
            empty(f, y: y + (f.square ? 40 : 80) * f.u)
        } else {
            y = hero(f, y: y + (f.square ? 34 : 64) * f.u)
            y = chart(f, y: y + (f.square ? 34 : 70) * f.u)
            rows(f, y: y + (f.square ? 26 : 56) * f.u)
        }
        footer(f)
    }

    // MARK: Header

    /// The date on the left, the range on the right, a hairline under both.
    /// Returns the hairline's y.
    private static func header(_ f: Frame, top: CGFloat) -> CGFloat {
        let a = f.a(0.0, 0.5)
        let font = S.font((f.square ? 26 : 30) * f.u, .semibold)
        S.text(dateLine(f.w), font, S.ink, x: f.m, y: top, width: f.inner, alpha: CGFloat(a))
        S.text(f.w.range.title, font, S.secondary, x: f.m, y: top, width: f.inner, align: .right, alpha: CGFloat(a))
        let y = top + font.pointSize * 1.25 + (f.square ? 18 : 26) * f.u
        S.fill(CGRect(x: f.m, y: y, width: f.inner * CGFloat(S.easeOut(f.a(0.05, 0.6))), height: max(1, 2 * f.u)),
               S.hairline)
        return y
    }

    /// The numbers are still being read: one quiet line, nothing that looks like
    /// a result.
    private static func adding(_ f: Frame, y: CGFloat) {
        S.text("Adding up \(f.w.range == .today ? "your day" : "your week")…",
               S.font(36 * f.u, .regular), S.secondary, x: f.m, y: y, width: f.inner, lineHeight: 1.3, alpha: 1)
    }

    private static func empty(_ f: Frame, y: CGFloat) {
        let w = f.w
        let a = f.a(0.15, 0.7)
        let h = S.text(w.range == .today ? "A quiet day." : "A quiet week.",
                       S.font((f.square ? 110 : 140) * f.u, .semibold), S.ink, x: f.m, y: y + f.rise(a, 30),
                       width: f.inner, tracking: -30, lineHeight: 1.0, alpha: CGFloat(a))
        let b = f.a(0.4)
        S.text("Nothing has finished yet \(w.range == .today ? "today" : "this week"). "
               + "Come back when your agents have worked.",
               S.font(36 * f.u, .regular), S.secondary,
               x: f.m, y: y + h + 24 * f.u + f.rise(b, 20), width: f.inner, lineHeight: 1.3, alpha: CGFloat(b))
    }

    // MARK: Hero — agent time, and who you were

    private static func hero(_ f: Frame, y: CGFloat) -> CGFloat {
        let w = f.w
        let p = S.easeOut(f.a(0.2, 1.3))
        let big = w.timed > 0 ? S.duration(w.agentSeconds, progress: p)
            : S.grouped(Int((Double(w.sessions) * p).rounded()))
        // Sized for the widest number the count passes through ("10h 59m" on its
        // way to "11h"), so it neither changes size nor wraps as it runs.
        let widest = w.timed > 0 && w.agentSeconds >= 3_600
            ? "\(Int(w.agentSeconds / 3_600))h 59m" : (w.timed > 0 ? "59m" : S.grouped(w.sessions))
        let font = S.fitting(widest, max: (f.square ? 150 : 210) * f.u, width: f.inner, weight: .semibold,
                             tracking: -35)
        let h = S.text(big, font, S.ink, x: f.m - 4 * f.u, y: y, width: f.W * 2, tracking: -35,
                       lineHeight: 0.95, alpha: CGFloat(f.a(0.15, 0.3)))
        var below = y + h - font.pointSize * 0.06

        let b = f.a(0.5)
        var what = w.timed > 0 ? "of agent time across \(w.sessions) session\(w.sessions == 1 ? "" : "s")"
            : "session\(w.sessions == 1 ? "" : "s") finished"
        if w.timed > 0, w.timed < w.sessions { what += ", \(w.timed) of them timed" }
        if w.busySeconds > 0, w.busySeconds < w.agentSeconds - 60 {
            what += " — \(HistoryDigest.duration(w.busySeconds)) on the clock"
        }
        below += S.text(what, S.font((f.square ? 28 : 34) * f.u, .regular), S.secondary, x: f.m,
                        y: below + f.rise(b, 14), width: f.inner, lineHeight: 1.25, alpha: CGFloat(b))

        // Who you were, as a sentence rather than a title card.
        let c = f.a(0.75)
        let p2 = w.persona
        let line = NSMutableAttributedString(string: p2.title + ". ",
                                             attributes: [.font: S.font((f.square ? 32 : 40) * f.u, .semibold),
                                                          .foregroundColor: S.ink.withAlphaComponent(CGFloat(c))])
        line.append(NSAttributedString(string: p2.reason, attributes: [
            .font: S.font((f.square ? 32 : 40) * f.u, .regular),
            .foregroundColor: S.secondary.withAlphaComponent(CGFloat(c))]))
        below += (f.square ? 16 : 30) * f.u
        below += S.rich(line, x: f.m, y: below + f.rise(c, 14), width: f.inner, lineHeight: 1.25)
        return below
    }

    // MARK: Chart — the shape of the day

    private static func chart(_ f: Frame, y: CGFloat) -> CGFloat {
        let w = f.w
        let bins = w.bins
        guard let maxBin = bins.max(), maxBin > 0 else { return y }
        let today = w.range == .today
        let la = f.a(0.6)
        let titleFont = S.font((f.square ? 24 : 28) * f.u, .semibold)
        if !f.square {
            S.text(today ? "Through the day" : "Through the week", titleFont, S.secondary, x: f.m, y: y,
                   width: f.inner, alpha: CGFloat(la))
        }
        let chartH = (f.square ? 120 : 260) * f.u
        let top = y + (f.square ? 40 : 96) * f.u
        let bottom = top + chartH
        let gap = (today ? 8 : 22) * f.u
        let bw = (f.inner - gap * CGFloat(bins.count - 1)) / CGFloat(bins.count)
        let best = today ? nil : bins.indices.max { bins[$0] < bins[$1] }

        S.fill(CGRect(x: f.m, y: bottom, width: f.inner, height: max(1, 2 * f.u)), S.hairline)
        for (i, v) in bins.enumerated() where v > 0 {
            let g = S.easeOut(f.a(0.55 + Double(i) * (today ? 0.02 : 0.07), 0.6))
            let h = max(4 * f.u, chartH * CGFloat(v / maxBin)) * CGFloat(g)
            let agent = w.binAgents.indices.contains(i) ? w.binAgents[i] : ""
            S.pill(CGRect(x: f.m + CGFloat(i) * (bw + gap), y: bottom - h, width: bw, height: h),
                   S.onPaper(agent), radius: min(bw / 2, 6 * f.u))
        }
        let labels: [(Int, String)] = today
            ? [(0, "00"), (6, "06"), (12, "12"), (18, "18"), (23, "23")]
            : (0..<bins.count).map { ($0, weekday(w.binStart($0), short: true)) }
        for (i, l) in labels {
            let x = f.m + CGFloat(i) * (bw + gap)
            S.text(l, S.font(22 * f.u, i == best ? .semibold : .regular), i == best ? S.ink : S.tertiary,
                   x: x - 40 * f.u, y: bottom + 14 * f.u, width: bw + 80 * f.u, align: .center, alpha: CGFloat(la))
        }

        // One thin line and a few words: the peak on a day, the best day in a week.
        let mark: (x: CGFloat, label: String)? = {
            if let best {
                return (f.m + CGFloat(best) * (bw + gap) + bw / 2,
                        "Best day, \(weekday(w.binStart(best), short: false)): \(HistoryDigest.duration(bins[best]))")
            }
            guard w.peak >= 2 else { return nil }
            let span = w.binLength * Double(bins.count)
            return (f.m + f.inner * CGFloat(S.clamp((w.peakAt - w.start) / span)),
                    "\(w.peak) at once, \(DayWrap.clock(w.peakAt))")
        }()
        if let mark {
            let d = f.a(1.4, 0.5)
            let lineTop = top - 34 * f.u
            S.fill(CGRect(x: mark.x - 1 * f.u, y: lineTop, width: max(1, 2 * f.u), height: bottom - lineTop),
                   S.ink.withAlphaComponent(0.55 * CGFloat(d)))
            let font = S.font(24 * f.u, .medium)
            let tw = S.measure(mark.label, font).width
            let left = mark.x + 12 * f.u + tw <= f.W - f.m
            S.text(mark.label, font, S.ink, x: left ? mark.x + 12 * f.u : mark.x - 12 * f.u - tw, y: lineTop - 6 * f.u,
                   width: tw + 4 * f.u, alpha: CGFloat(d))
        }
        // You, under the agents: a dot per hour you typed a prompt or answered a
        // request, bigger the more you did — the day's other half.
        let maxYou = w.youBins.max() ?? 0
        let youY = bottom + (f.square ? 50 : 66) * f.u
        if maxYou > 0 {
            for (i, c) in w.youBins.enumerated() where c > 0 {
                let d = f.a(0.9 + Double(i) * (today ? 0.015 : 0.05), 0.4)
                let r = (3 + 8 * CGFloat((Double(c) / Double(maxYou)).squareRoot())) * f.u * CGFloat(S.easeOut(d))
                S.circle(CGPoint(x: f.m + CGFloat(i) * (bw + gap) + bw / 2, y: youY), r, S.ink.withAlphaComponent(0.8))
            }
        }

        // Which colour is whom: the agents that own a bar, in the order of the day,
        // and you.
        var seen: [String] = []
        for a in w.binAgents where !a.isEmpty && !seen.contains(a) { seen.append(a) }
        var lx = f.m
        let ly = (maxYou > 0 ? youY + 22 * f.u : bottom) + (f.square ? 44 : 56) * f.u - (maxYou > 0 ? 24 * f.u : 0)
        let lf = S.font(22 * f.u, .regular)
        for id in seen.prefix(5) {
            let name = Agent.byID(id).name
            let sw = 14 * f.u
            guard lx + sw + 10 * f.u + S.measure(name, lf).width <= f.W - f.m else { break }
            S.pill(CGRect(x: lx, y: ly + 5 * f.u, width: sw, height: sw), S.onPaper(id).withAlphaComponent(CGFloat(la)),
                   radius: 3 * f.u)
            lx += sw + 10 * f.u
            S.text(name, lf, S.secondary, x: lx, y: ly, width: 300 * f.u, alpha: CGFloat(la))
            lx += S.measure(name, lf).width + 28 * f.u
        }
        if maxYou > 0, lx + 140 * f.u <= f.W - f.m {
            S.circle(CGPoint(x: lx + 7 * f.u, y: ly + 12 * f.u), 7 * f.u, S.ink.withAlphaComponent(0.8 * CGFloat(la)))
            S.text("You — prompts and answers", lf, S.secondary, x: lx + 24 * f.u, y: ly, width: 400 * f.u,
                   alpha: CGFloat(la))
        }
        return ly + (seen.isEmpty && maxYou == 0 ? 0 : 40 * f.u) + (f.square ? 10 : 30) * f.u
    }

    // MARK: Rows — the rest of the day

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

    /// The facts that exist, in the order they are worth: the top agent, the code,
    /// your answers and prompts, the longest run and the busiest hour, then the
    /// projects, the agents and what failed.
    static func tileFacts(_ w: DayWrap) -> [Tile] {
        var out: [Tile] = []
        if let top = w.topAgent {
            let share = w.agentSeconds > 0
                ? "\(Int((top.seconds / w.agentSeconds * 100).rounded())) % · \(HistoryDigest.duration(top.seconds))"
                : "\(top.sessions) of \(w.sessions) sessions"
            out.append(Tile(caption: "Top agent", value: top.name, detail: share, color: S.onPaper(top.id),
                            agent: top.id))
        }
        if w.changeMeasured > 0, w.linesAdded + w.linesRemoved > 0 {
            var detail = "\(S.grouped(w.filesChanged)) file\(w.filesChanged == 1 ? "" : "s")"
            if w.changeMeasured < w.sessions { detail += ", \(w.changeMeasured) of \(w.sessions) sessions" }
            out.append(Tile(caption: "Changed", value: "+" + S.grouped(w.linesAdded), detail: detail, color: S.added,
                            second: ("−" + S.grouped(w.linesRemoved), S.removed)))
        }
        let decided = w.waits.answered + w.waits.byRules
        if decided > 0 {
            var bits: [String] = []
            if w.waits.byRules > 0 { bits.append("\(w.waits.byRules) by your rules") }
            if w.waits.waited >= 60 { bits.append("they waited \(HistoryDigest.duration(w.waits.waited))") }
            else if let fast = w.waits.fastest { bits.append("fastest \(S.shortWait(fast))") }
            out.append(Tile(caption: "Your answers", value: S.grouped(decided),
                            detail: bits.joined(separator: ", "), color: S.ink))
        }
        if w.prompts > 0 {
            let at = w.yourBin.map { "most around \(hourLabel(w, $0))" } ?? ""
            out.append(Tile(caption: "Your prompts", value: S.grouped(w.prompts), detail: at, color: S.ink))
        }
        if let l = w.longest, l.seconds >= 60 {
            out.append(Tile(caption: "Longest run", value: HistoryDigest.duration(l.seconds),
                            detail: l.task.isEmpty ? Agent.byID(l.agent).name : "“\(Handoff.clip(l.task, 60))”",
                            color: S.ink))
        }
        if let b = w.busiestBin {
            out.append(Tile(caption: w.range == .today ? "Busiest hour" : "Busiest day", value: hourLabel(w, b),
                            detail: "\(HistoryDigest.duration(w.bins[b])) of agent work", color: S.ink))
        }
        if let p = w.projects.first {
            let rest = w.projects.dropFirst().map(\.name)
            let detail = rest.isEmpty
                ? (p.seconds > 0 ? HistoryDigest.duration(p.seconds) : "\(p.sessions) session\(p.sessions == 1 ? "" : "s")")
                : "then " + rest.joined(separator: ", ")
            out.append(Tile(caption: "Top project", value: p.name, detail: detail, color: S.ink))
        }
        if w.agents.count >= 2 {
            out.append(Tile(caption: "Agents", value: "\(w.agents.count)",
                            detail: w.agents.dropFirst().prefix(3).map(\.name).joined(separator: ", "), color: S.ink))
        }
        if w.failed > 0 {
            out.append(Tile(caption: "Failed", value: "\(w.failed)", detail: "of \(w.sessions) sessions", color: S.removed))
        }
        return out
    }

    /// The facts as a list: label on the left, value on the right, a hairline
    /// between. A table reads faster than a grid of boxes, and needs no boxes.
    private static func rows(_ f: Frame, y: CGFloat) {
        let facts = tileFacts(f.w)
        let rowH = (f.square ? 74 : 104) * f.u
        let footerTop = f.H - footerHeight(f)
        let fit = max(0, Int((footerTop - y) / rowH))
        let labelFont = S.font((f.square ? 26 : 32) * f.u, .regular)
        let valueFont = S.font((f.square ? 30 : 38) * f.u, .semibold)
        let detailFont = S.font((f.square ? 24 : 28) * f.u, .regular)
        for (i, t) in facts.prefix(min(fit, f.square ? 3 : 6)).enumerated() {
            let a = f.a(1.0 + Double(i) * 0.1, 0.5)
            let ry = y + CGFloat(i) * rowH + f.rise(a, 12)
            let mid = ry + rowH / 2
            if i > 0 {
                S.fill(CGRect(x: f.m, y: y + CGFloat(i) * rowH, width: f.inner, height: max(1, 2 * f.u)),
                       S.hairline.withAlphaComponent(CGFloat(a)))
            }
            S.text(t.caption, labelFont, S.secondary, x: f.m, y: mid - labelFont.pointSize * 0.62,
                   width: f.inner * 0.4, alpha: CGFloat(a))

            // Right-aligned: detail, then value, then the second value — read from
            // the right edge in.
            var right = f.W - f.m
            func put(_ s: String, _ font: NSFont, _ color: NSColor, gap: CGFloat = 0) {
                let w = S.measure(s, font).width
                right -= w
                S.text(s, font, color, x: right, y: mid - font.pointSize * 0.62, width: w + 4 * f.u, alpha: CGFloat(a))
                right -= gap
            }
            if let (s, c) = t.second { put(s, valueFont, c, gap: 14 * f.u) }
            // Colour only where it means something: the lines added and removed.
            put(t.value, valueFont, t.second == nil ? S.ink : t.color, gap: 16 * f.u)
            if let id = t.agent {
                let side = valueFont.pointSize * 0.95
                if id == "claude" {
                    let px = side / 12
                    right -= 22 * px
                    S.clawd(S.clawdPoses(.think).first ?? "", origin: CGPoint(x: right, y: mid - 6 * px), pixel: px,
                            alpha: CGFloat(a))
                } else if let mark = S.mark(for: id) {
                    let ratio = mark.size.width / max(1, mark.size.height)
                    let mw = min(side * ratio, side * 1.4)
                    right -= mw
                    S.image(mark, in: CGRect(x: right, y: mid - mw / ratio / 2, width: mw, height: mw / ratio),
                            alpha: CGFloat(a))
                }
                right -= 16 * f.u
            }
            if !t.detail.isEmpty, !f.square {
                let room = right - (f.m + f.inner * 0.34)
                var d = t.detail
                while d.count > 4, S.measure(d, detailFont).width > room { d = String(d.dropLast(2)) + "…" }
                if S.measure(d, detailFont).width <= room { put(d, detailFont, S.tertiary) }
            }
        }
    }

    // MARK: Footer

    /// "14:00–15:00" for a day's bin, "Tuesday" for a week's.
    static func hourLabel(_ w: DayWrap, _ i: Int) -> String {
        guard w.range == .today else { return weekday(w.binStart(i), short: false) }
        return String(format: "%02d:00–%02d:00", i, (i + 1) % 24)
    }

    private static func footerHeight(_ f: Frame) -> CGFloat { (f.square ? 90 : 150) * f.u }

    private static func footer(_ f: Frame) {
        let a = f.a(1.5, 0.6)
        let base = f.H - (f.square ? 48 : 80) * f.u
        S.fill(CGRect(x: f.m, y: base - (f.square ? 44 : 60) * f.u, width: f.inner, height: max(1, 2 * f.u)),
               S.hairline.withAlphaComponent(CGFloat(a)))
        let px = (f.square ? 2.4 : 3) * f.u
        S.clawd(S.clawdPoses(.think).first ?? "", origin: CGPoint(x: f.m, y: base - 9 * px), pixel: px,
                alpha: CGFloat(a))
        let font = S.font((f.square ? 22 : 26) * f.u, .regular)
        let x = f.m + 22 * px + 14 * f.u
        let line = NSMutableAttributedString(string: "AgentBar", attributes: [
            .font: S.font((f.square ? 22 : 26) * f.u, .semibold), .foregroundColor: S.ink.withAlphaComponent(CGFloat(a))])
        line.append(NSAttributedString(string: "  ·  free and open source for macOS", attributes: [
            .font: font, .foregroundColor: S.secondary.withAlphaComponent(CGFloat(a))]))
        S.rich(line, x: x, y: base - font.pointSize * 1.05, width: f.inner)
    }

    // MARK: - Words

    private static func dateLine(_ w: DayWrap) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        switch w.range {
        case .today:
            f.dateFormat = "EEEE, d MMMM"
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
