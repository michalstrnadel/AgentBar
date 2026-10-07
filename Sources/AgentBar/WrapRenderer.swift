import AppKit

/// One recap slide.
enum WrapSlide: String, CaseIterable, Equatable {
    case cover, time, agent, projects, code, you, peak, bestDay, persona, card
}

/// Draws the recap, one slide at a time, at any moment of its animation.
///
/// **One deterministic function** — `draw(_:at:wrap:size:in:)` — is the player, the
/// PNG card, the GIF and the MP4. Nothing here keeps state between frames: a slide
/// at 1.3 s looks the same every time it is drawn, which is what lets the export be
/// exactly what was on screen and lets a test hold a frame still.
///
/// The canvas is flipped (y down). Layout is in units of `u`, the canvas's short
/// side over 1080, so the 405-point window and the 1080-pixel export are the same
/// picture at two sizes.
enum WrapRenderer {
    /// How long each slide plays before the next.
    static let slideSeconds: Double = 5

    /// Which slides this recap has. A fact with nothing behind it leaves its slide
    /// out — a recap padded with zeroes is a recap nobody shares.
    static func slides(for w: DayWrap) -> [WrapSlide] {
        guard !w.isEmpty else { return [.cover] }
        var out: [WrapSlide] = [.cover]
        if w.timed > 0 { out.append(.time) }
        if w.topAgent != nil { out.append(.agent) }
        if !w.projects.isEmpty { out.append(.projects) }
        if w.changeMeasured > 0, w.linesAdded + w.linesRemoved > 0 { out.append(.code) }
        if w.waits.answered + w.waits.byRules > 0 { out.append(.you) }
        if w.peak >= 2 { out.append(.peak) }
        if w.bestDay != nil { out.append(.bestDay) }
        out += [.persona, .card]
        return out
    }

    struct Frame {
        let w: DayWrap
        /// Seconds into this slide.
        let s: Double
        /// Seconds since the recap started — for the slow drift that runs across cuts.
        let g: Double
        let size: CGSize
        let ctx: CGContext
        let still: Bool
        var W: CGFloat { size.width }
        var H: CGFloat { size.height }
        var u: CGFloat { min(W, H) / 1080 }
        /// Side margin.
        var m: CGFloat { 84 * u }
        var square: Bool { abs(W - H) < 1 }
        func a(_ delay: Double, _ dur: Double = 0.7) -> Double {
            still ? 1 : WrapStyle.appear(s, delay, dur)
        }
        /// Entrance offset: slides up `by` units as `a` goes 0 → 1.
        func rise(_ a: Double, _ by: CGFloat = 60) -> CGFloat { CGFloat(1 - WrapStyle.easeOut(a)) * by * u }
    }

    /// Draws `slide` `seconds` into it. `still` draws its final state with no motion —
    /// the card, Reduce Motion, and any frame a test wants to hold.
    static func draw(_ slide: WrapSlide, at seconds: Double, global: Double? = nil, wrap: DayWrap,
                     size: CGSize, in ctx: CGContext, still: Bool = false) {
        let f = Frame(w: wrap, s: still ? 99 : seconds, g: still ? 0 : (global ?? seconds),
                      size: size, ctx: ctx, still: still)
        ctx.saveGState()
        ctx.clip(to: CGRect(origin: .zero, size: size))
        switch slide {
        case .cover:    cover(f)
        case .time:     time(f)
        case .agent:    agent(f)
        case .projects: projects(f)
        case .code:     code(f)
        case .you:      you(f)
        case .peak:     peak(f)
        case .bestDay:  bestDay(f)
        case .persona:  persona(f)
        case .card:     card(f)
        }
        ctx.restoreGState()
    }

    typealias S = WrapStyle

    // MARK: - Shared furniture

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

    /// The small label every slide opens with.
    private static func kicker(_ f: Frame, _ s: String, _ color: NSColor, y: CGFloat) {
        let a = f.a(0.05, 0.5)
        S.text(s.uppercased(), S.font(30 * f.u, .heavy), color, x: f.m, y: y - f.rise(a, 20),
               width: f.W - 2 * f.m, tracking: 140, alpha: CGFloat(a))
    }

    /// The wordmark in a corner, so a shared frame says where it came from.
    private static func signature(_ f: Frame, _ color: NSColor) {
        let y = f.H - 96 * f.u
        S.text("AgentBar", S.font(28 * f.u, .heavy), color, x: f.m, y: y, width: 400 * f.u,
               tracking: -10, alpha: 0.9)
        S.text(f.w.range == .today ? "your day" : "your week", S.font(28 * f.u, .medium), color,
               x: f.W - f.m - 400 * f.u, y: y, width: 400 * f.u, align: .right, alpha: 0.6)
    }

    /// Big soft shapes drifting behind a slide.
    private static func blobs(_ f: Frame, _ colors: [NSColor], seed: Double) {
        for (i, c) in colors.enumerated() {
            let k = Double(i) + seed
            let x = f.W * CGFloat(0.5 + 0.42 * sin(k * 2.1 + f.g * 0.17))
            let y = f.H * CGFloat(0.5 + 0.40 * cos(k * 1.7 + f.g * 0.13))
            S.glow(CGPoint(x: x, y: y), f.W * CGFloat(0.75 + 0.1 * sin(k)), c, in: f.ctx)
        }
    }

    // MARK: - Cover

    private static func cover(_ f: Frame) {
        let top = f.w.topAgent?.id ?? "claude"
        S.fill(CGRect(origin: .zero, size: f.size), S.night)
        blobs(f, [S.colour(for: top).withAlphaComponent(0.55), S.violet.withAlphaComponent(0.45),
                  S.pink.withAlphaComponent(0.25)], seed: 0.3)

        // Concentric rings opening out from the top-right, like a record.
        for i in 0..<6 {
            let a = f.a(0.1 + Double(i) * 0.08, 1.2)
            let r = CGFloat(140 + i * 110) * f.u * CGFloat(S.easeOut(a))
            S.ring(CGPoint(x: f.W * 0.86, y: f.H * 0.16), r, width: 3 * f.u, fraction: 1,
                   S.cream.withAlphaComponent(0.10 + 0.04 * CGFloat(6 - i)), track: nil, in: f.ctx)
        }

        kicker(f, dateLine(f.w), S.cream.withAlphaComponent(0.7), y: f.H * 0.30)
        let lines = f.w.range == .today ? ["Your day", "with your", "agents."] : ["Your week", "with your", "agents."]
        var y = f.H * 0.30 + 70 * f.u
        for (i, line) in lines.enumerated() {
            let a = f.a(0.25 + Double(i) * 0.14, 0.8)
            let font = S.font(150 * f.u, .black)
            let h = S.text(line, font, i == 2 ? S.lime : S.cream, x: f.m, y: y + f.rise(a, 90),
                           width: f.W - 2 * f.m, tracking: -45, lineHeight: 0.92, alpha: CGFloat(a))
            y += h
        }
        if f.w.isEmpty {
            let a = f.a(0.9)
            S.text("Nothing has finished yet \(f.w.range == .today ? "today" : "this week"). Come back when your agents have worked.",
                   S.font(40 * f.u, .semibold), S.cream.withAlphaComponent(0.75),
                   x: f.m, y: y + 40 * f.u, width: f.W - 2 * f.m, lineHeight: 1.2, alpha: CGFloat(a))
        }

        // Clawd walks in along the bottom and stops to look at you.
        let poses = S.clawdPoses(.think)
        let px = 14 * f.u
        let walkIn = S.easeOut(f.a(0.6, 1.4))
        let x = -400 * f.u + CGFloat(walkIn) * (f.m + 400 * f.u)
        let frame = poses.isEmpty ? "" : poses[Int(f.g * 3) % min(poses.count, 3)]
        S.clawd(frame, origin: CGPoint(x: x, y: f.H - 330 * f.u), pixel: px)
        signature(f, S.cream)
    }

    // MARK: - Time

    private static func time(_ f: Frame) {
        S.fill(CGRect(origin: .zero, size: f.size), S.lime)
        let ink = S.night
        kicker(f, "Agent time", ink.withAlphaComponent(0.65), y: 150 * f.u)

        let a = f.a(0.15, 1.6)
        let shown = S.duration(f.w.agentSeconds, progress: S.easeOut(a))
        let font = S.fitting(shown, max: 300 * f.u, width: f.W - 2 * f.m, rounded: true, tracking: -50)
        S.text(shown, font, ink, x: f.m, y: 210 * f.u, width: f.W - 2 * f.m, tracking: -50,
               lineHeight: 0.95)

        let ofWhat: String = {
            var s = "of agents at work, across \(f.w.timed) timed session\(f.w.timed == 1 ? "" : "s")"
            if f.w.timed < f.w.sessions { s += " of \(f.w.sessions)" }
            return s + "."
        }()
        let b = f.a(0.6)
        S.text(ofWhat, S.font(44 * f.u, .bold), ink, x: f.m, y: 540 * f.u + f.rise(b, 30),
               width: f.W - 2 * f.m, lineHeight: 1.15, alpha: CGFloat(b))
        if f.w.busySeconds > 0, f.w.busySeconds < f.w.agentSeconds - 60 {
            let c = f.a(0.9)
            S.text("In \(HistoryDigest.duration(f.w.busySeconds)) on the clock — they overlapped.",
                   S.font(36 * f.u, .semibold), ink.withAlphaComponent(0.6),
                   x: f.m, y: 680 * f.u + f.rise(c, 30), width: f.W - 2 * f.m, alpha: CGFloat(c))
        }

        // The day as bars, rising one after another.
        let bins = f.w.bins
        guard let maxBin = bins.max(), maxBin > 0 else { signature(f, ink); return }
        let chartTop = f.H * 0.55, chartBottom = f.H - 220 * f.u
        let gap = 8 * f.u
        let bw = (f.W - 2 * f.m - gap * CGFloat(bins.count - 1)) / CGFloat(bins.count)
        let busiest = bins.firstIndex(of: maxBin) ?? 0
        for (i, v) in bins.enumerated() {
            let grow = S.easeBack(f.a(0.8 + Double(i) * 0.035, 0.6))
            let h = max(6 * f.u, (chartBottom - chartTop) * CGFloat(v / maxBin)) * CGFloat(max(0, grow))
            let x = f.m + CGFloat(i) * (bw + gap)
            S.pill(CGRect(x: x, y: chartBottom - h, width: bw, height: h),
                   i == busiest ? S.pink : ink.withAlphaComponent(v > 0 ? 0.9 : 0.15), radius: bw / 2)
        }
        let labels = f.w.range == .today
            ? [(0, "0"), (6, "6"), (12, "12"), (18, "18"), (23, "23")]
            : (0..<7).map { ($0, weekday(f.w.binStart($0), short: true)) }
        for (i, l) in labels {
            let x = f.m + CGFloat(i) * (bw + gap)
            S.text(l, S.font(26 * f.u, .bold), ink.withAlphaComponent(0.6), x: x - 40 * f.u,
                   y: chartBottom + 16 * f.u, width: bw + 80 * f.u, align: .center)
        }
        let d = f.a(1.8)
        let when = f.w.range == .today ? "Busiest hour: \(busiest):00" : "Busiest: \(weekday(f.w.binStart(busiest), short: false))"
        S.text(when, S.font(30 * f.u, .heavy), S.pink, x: f.m, y: chartTop - 60 * f.u,
               width: f.W - 2 * f.m, alpha: CGFloat(d))
        signature(f, ink)
    }

    private static func weekday(_ t: TimeInterval, short: Bool) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US")
        df.dateFormat = short ? "EEEEE" : "EEEE"
        return df.string(from: Date(timeIntervalSince1970: t))
    }

    // MARK: - Top agent

    private static func agent(_ f: Frame) {
        guard let top = f.w.topAgent else { return }
        let brand = S.colour(for: top.id)
        let bg = S.mix(brand, S.night, 0.72)
        S.fill(CGRect(origin: .zero, size: f.size), bg)
        blobs(f, [brand.withAlphaComponent(0.55), S.mix(brand, S.cream, 0.4).withAlphaComponent(0.25)], seed: 1.1)

        kicker(f, "Your top agent", S.cream.withAlphaComponent(0.7), y: 150 * f.u)

        let share = f.w.agentSeconds > 0 ? top.seconds / f.w.agentSeconds
            : Double(top.sessions) / Double(max(1, f.w.sessions))
        let center = CGPoint(x: f.W / 2, y: f.H * 0.36)
        let r = 250 * f.u
        let fill = S.easeInOut(f.a(0.4, 1.6))
        S.ring(center, r, width: 34 * f.u, fraction: share * fill, brand,
               track: S.cream.withAlphaComponent(0.12), in: f.ctx)

        let pop = S.easeBack(f.a(0.25, 0.8))
        let side = 300 * f.u * CGFloat(max(0, pop))
        if top.id == "claude" {
            let poses = S.clawdPoses(.type)
            let px = side / 20
            let frame = poses.isEmpty ? "" : poses[Int(f.g * 4) % poses.count]
            S.clawd(frame, origin: CGPoint(x: center.x - 11 * px, y: center.y - 6 * px), pixel: px)
        } else if let mark = S.mark(for: top.id) {
            let ratio = mark.size.width / max(1, mark.size.height)
            let h = side, w = h * ratio
            S.image(mark, in: CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h))
        }

        let a = f.a(0.7)
        let nameFont = S.fitting(top.name, max: 170 * f.u, width: f.W - 2 * f.m, tracking: -45)
        S.text(top.name, nameFont, S.cream, x: f.m, y: f.H * 0.58 + f.rise(a), width: f.W - 2 * f.m,
               align: .center, tracking: -45, alpha: CGFloat(a))
        let pct = Int((share * 100 * S.easeOut(f.a(0.4, 1.6))).rounded())
        let b = f.a(1.0)
        let what = f.w.agentSeconds > 0
            ? "\(pct) % of the agent time · \(HistoryDigest.duration(top.seconds)) · \(top.sessions) session\(top.sessions == 1 ? "" : "s")"
            : "\(top.sessions) of \(f.w.sessions) sessions"
        S.text(what, S.font(40 * f.u, .bold, rounded: true), brand.blended(withFraction: 0.35, of: .white) ?? brand,
               x: f.m, y: f.H * 0.58 + 200 * f.u + f.rise(b, 30), width: f.W - 2 * f.m,
               align: .center, alpha: CGFloat(b))

        // The rest of the field, as chips.
        let others = Array(f.w.agents.dropFirst().prefix(4))
        var y = f.H * 0.74
        for (i, o) in others.enumerated() {
            let c = f.a(1.3 + Double(i) * 0.12)
            let share = f.w.agentSeconds > 0 ? Int((o.seconds / f.w.agentSeconds * 100).rounded()) : 0
            let label = f.w.agentSeconds > 0 ? "\(o.name)  \(share) %" : "\(o.name)  \(o.sessions)"
            let font = S.font(34 * f.u, .heavy)
            let w = S.measure(label, font).width + 64 * f.u
            let rect = CGRect(x: (f.W - w) / 2, y: y + f.rise(c, 20), width: w, height: 64 * f.u)
            S.pill(rect, S.cream.withAlphaComponent(0.10 * CGFloat(c)))
            S.circle(CGPoint(x: rect.minX + 30 * f.u, y: rect.midY), 9 * f.u, S.colour(for: o.id).withAlphaComponent(CGFloat(c)))
            S.text(label, font, S.cream, x: rect.minX + 48 * f.u, y: rect.minY + 12 * f.u,
                   width: w, alpha: CGFloat(c))
            y += 80 * f.u
        }
        signature(f, S.cream)
    }

    // MARK: - Projects

    private static func projects(_ f: Frame) {
        S.fill(CGRect(origin: .zero, size: f.size), S.pink)
        let ink = S.hex(0x1A0B14)
        kicker(f, "Where the work went", ink.withAlphaComponent(0.65), y: 150 * f.u)

        let top = f.w.projects
        let first = top.first?.name ?? ""
        let a = f.a(0.15, 0.8)
        let font = S.fitting(first, max: 190 * f.u, width: f.W - 2 * f.m, tracking: -45)
        S.text(first, font, ink, x: f.m, y: 210 * f.u + f.rise(a, 80), width: f.W - 2 * f.m,
               tracking: -45, lineHeight: 0.95, alpha: CGFloat(a))

        // A bar race: the top three, longest first.
        let maxS = max(1, top.map(\.seconds).max() ?? 1)
        var y = f.H * 0.33
        for (i, p) in top.enumerated() {
            let g = S.easeOut(f.a(0.5 + Double(i) * 0.2, 1.2))
            let frac = p.seconds > 0 ? p.seconds / maxS : 0.25
            let w = (f.W - 2 * f.m) * CGFloat(frac * g)
            let h = 120 * f.u
            S.pill(CGRect(x: f.m, y: y, width: f.W - 2 * f.m, height: h), ink.withAlphaComponent(0.08),
                   radius: 28 * f.u)
            S.pill(CGRect(x: f.m, y: y, width: max(h, w), height: h),
                   i == 0 ? ink : ink.withAlphaComponent(0.22), radius: 28 * f.u)
            let label = "\(i + 1)  \(p.name)"
            S.text(label, S.font(42 * f.u, .heavy), i == 0 ? S.pink : ink, x: f.m + 32 * f.u,
                   y: y + 16 * f.u, width: f.W - 2 * f.m - 64 * f.u, alpha: CGFloat(g))
            let detail = p.seconds > 0
                ? "\(HistoryDigest.duration(p.seconds)) · \(p.sessions) session\(p.sessions == 1 ? "" : "s")"
                : "\(p.sessions) session\(p.sessions == 1 ? "" : "s")"
            S.text(detail, S.font(30 * f.u, .bold, rounded: true),
                   (i == 0 ? S.pink : ink).withAlphaComponent(0.75),
                   x: f.m + 32 * f.u, y: y + 66 * f.u, width: f.W - 2 * f.m, alpha: CGFloat(g))
            y += h + 26 * f.u
        }

        if let l = f.w.longest {
            let b = f.a(1.4)
            let y0 = f.H * 0.68 + f.rise(b, 40)
            S.text("LONGEST RUN", S.font(28 * f.u, .heavy), ink.withAlphaComponent(0.6), x: f.m, y: y0,
                   width: f.W - 2 * f.m, tracking: 140, alpha: CGFloat(b))
            S.text(HistoryDigest.duration(l.seconds), S.font(130 * f.u, .black, rounded: true), ink,
                   x: f.m, y: y0 + 44 * f.u, width: f.W - 2 * f.m, tracking: -40, alpha: CGFloat(b))
            let what = l.task.isEmpty
                ? "\(Agent.byID(l.agent).name)\(l.project.isEmpty ? "" : " in \(l.project)")"
                : "“\(l.task)”"
            S.text(what, S.font(36 * f.u, .bold), ink, x: f.m, y: y0 + 190 * f.u,
                   width: f.W - 2 * f.m, lineHeight: 1.15, alpha: CGFloat(b) * 0.85)
        }
        signature(f, ink)
    }

    // MARK: - Code

    private static func code(_ f: Frame) {
        S.fill(CGRect(origin: .zero, size: f.size), S.night)
        blobs(f, [S.green.withAlphaComponent(0.22), S.red.withAlphaComponent(0.18)], seed: 2.4)
        kicker(f, "What changed in your repos", S.cream.withAlphaComponent(0.65), y: 150 * f.u)

        let p = S.easeOut(f.a(0.2, 1.8))
        let plus = "+" + S.grouped(Int(Double(f.w.linesAdded) * p))
        let minus = "−" + S.grouped(Int(Double(f.w.linesRemoved) * p))
        let big = S.fitting(plus.count > minus.count ? plus : minus, max: 230 * f.u,
                            width: f.W - 2 * f.m, rounded: true, tracking: -50)
        S.text(plus, big, S.green, x: f.m, y: 220 * f.u, width: f.W - 2 * f.m, tracking: -50)
        S.text(minus, big, S.red, x: f.m, y: 220 * f.u + big.pointSize * 1.0, width: f.W - 2 * f.m, tracking: -50)

        let a = f.a(0.9)
        let files = "lines across \(S.grouped(f.w.filesChanged)) file\(f.w.filesChanged == 1 ? "" : "s")"
            + (f.w.changeMeasured < f.w.sessions
               ? ", in the \(f.w.changeMeasured) session\(f.w.changeMeasured == 1 ? "" : "s") AgentBar saw from the start."
               : ".")
        S.text(files, S.font(42 * f.u, .bold), S.cream, x: f.m, y: 240 * f.u + big.pointSize * 2.05 + f.rise(a, 30),
               width: f.W - 2 * f.m, lineHeight: 1.15, alpha: CGFloat(a))

        // Two stacks of blocks, green over red, in proportion.
        let total = Double(max(1, f.w.linesAdded + f.w.linesRemoved))
        let blocks = 40
        let addBlocks = Int((Double(f.w.linesAdded) / total * Double(blocks)).rounded())
        let cols = 10
        let side = (f.W - 2 * f.m - CGFloat(cols - 1) * 12 * f.u) / CGFloat(cols)
        let baseY = f.H - 220 * f.u
        for i in 0..<blocks {
            let b = S.easeBack(f.a(1.0 + Double(i) * 0.025, 0.4))
            let col = i % cols, row = i / cols
            let r = CGRect(x: f.m + CGFloat(col) * (side + 12 * f.u),
                           y: baseY - CGFloat(row + 1) * (side + 12 * f.u) + 12 * f.u,
                           width: side, height: side)
            let scaled = r.insetBy(dx: r.width * CGFloat(1 - b) / 2, dy: r.height * CGFloat(1 - b) / 2)
            S.pill(scaled, i < addBlocks ? S.green : S.red, radius: 14 * f.u)
        }
        S.text("What changed in the repo while they ran — not only their work.",
               S.font(26 * f.u, .medium), S.cream.withAlphaComponent(0.45),
               x: f.m, y: baseY + 24 * f.u, width: f.W - 2 * f.m)
        signature(f, S.cream)
    }

    // MARK: - You

    private static func you(_ f: Frame) {
        S.fill(CGRect(origin: .zero, size: f.size), S.blue)
        blobs(f, [S.violet.withAlphaComponent(0.6), S.hex(0x00D1FF, 0.25)], seed: 3.3)
        let ink = S.cream
        kicker(f, "You and your agents", ink.withAlphaComponent(0.7), y: 150 * f.u)

        let w = f.w.waits
        let a = f.a(0.15, 1.4)
        let waited = w.waited > 0 ? S.duration(w.waited, progress: S.easeOut(a)) : "0m"
        S.text("They waited", S.font(70 * f.u, .heavy), ink, x: f.m, y: 220 * f.u, width: f.W - 2 * f.m,
               tracking: -30, alpha: CGFloat(f.a(0.1)))
        S.text(waited, S.font(260 * f.u, .black, rounded: true), S.lime, x: f.m, y: 290 * f.u,
               width: f.W - 2 * f.m, tracking: -50)
        S.text("on you.", S.font(70 * f.u, .heavy), ink, x: f.m, y: 560 * f.u, width: f.W - 2 * f.m,
               tracking: -30, alpha: CGFloat(f.a(0.5)))

        var tiles: [(String, String)] = []
        if w.answered > 0 { tiles.append((S.grouped(w.answered), "answered by you")) }
        if w.byRules > 0 { tiles.append((S.grouped(w.byRules), "by rules you wrote")) }
        if let fast = w.fastest { tiles.append((S.shortWait(fast), "your fastest answer")) }
        if let med = w.median, w.answered >= 3 { tiles.append((S.shortWait(med), "your typical answer")) }
        let cols = 2
        let gap = 24 * f.u
        let tw = (f.W - 2 * f.m - gap) / CGFloat(cols), th = 230 * f.u
        for (i, t) in tiles.prefix(4).enumerated() {
            let b = S.easeBack(f.a(0.8 + Double(i) * 0.15, 0.6))
            let x = f.m + CGFloat(i % cols) * (tw + gap)
            let y = 720 * f.u + CGFloat(i / cols) * (th + gap) + CGFloat(1 - b) * 60 * f.u
            S.pill(CGRect(x: x, y: y, width: tw, height: th), S.cream.withAlphaComponent(0.14 * CGFloat(min(1, b))),
                   radius: 40 * f.u)
            S.text(t.0, S.font(96 * f.u, .black, rounded: true), S.cream, x: x + 36 * f.u, y: y + 28 * f.u,
                   width: tw - 72 * f.u, tracking: -30, alpha: CGFloat(min(1, b)))
            S.text(t.1, S.font(32 * f.u, .bold), S.cream.withAlphaComponent(0.8), x: x + 36 * f.u,
                   y: y + 150 * f.u, width: tw - 72 * f.u, alpha: CGFloat(min(1, b)))
        }

        // The day as a line, every decision a dot on it: yours sized by how long
        // it waited, a rule's small and lime.
        let lineY = f.H - 330 * f.u
        let span = max(1, f.w.end - f.w.start)
        let draw = S.easeInOut(f.a(1.3, 1.2))
        S.fill(CGRect(x: f.m, y: lineY - 2 * f.u, width: (f.W - 2 * f.m) * CGFloat(draw), height: 4 * f.u),
               S.cream.withAlphaComponent(0.35))
        let longest = max(1, f.w.moments.map(\.waited).max() ?? 1)
        for (i, mo) in f.w.moments.enumerated() {
            let x = f.m + (f.W - 2 * f.m) * CGFloat((mo.ts - f.w.start) / span)
            let shown = (x - f.m) / max(1, f.W - 2 * f.m) <= CGFloat(draw)
            guard shown else { continue }
            let pop = S.easeBack(f.a(1.3 + 1.2 * Double((x - f.m) / (f.W - 2 * f.m)) + Double(i % 3) * 0.02, 0.4))
            let r = (mo.byRule ? 9 : 10 + 26 * CGFloat(sqrt(mo.waited / longest))) * f.u * CGFloat(max(0, pop))
            let lane: CGFloat = mo.byRule ? 46 : -CGFloat(i % 2) * 40 - 30
            S.circle(CGPoint(x: x, y: lineY + lane * f.u), r, mo.byRule ? S.lime : S.cream)
        }
        let c = f.a(2.2)
        S.text("each dot one answer · bigger waited longer · lime by your rules", S.font(26 * f.u, .semibold),
               S.cream.withAlphaComponent(0.6), x: f.m, y: lineY + 90 * f.u, width: f.W - 2 * f.m,
               alpha: CGFloat(c))
        signature(f, ink)
    }

    // MARK: - Peak

    private static func peak(_ f: Frame) {
        S.fill(CGRect(origin: .zero, size: f.size), S.cream)
        let ink = S.night
        kicker(f, "Your peak", ink.withAlphaComponent(0.55), y: 150 * f.u)
        let a = f.a(0.15, 0.8)
        S.text("\(f.w.peak)", S.font(420 * f.u, .black, rounded: true), ink, x: f.m - 10 * f.u,
               y: 160 * f.u + f.rise(a, 100), width: f.W, tracking: -60, alpha: CGFloat(a))
        S.text("agents at once, at \(DayWrap.clock(f.w.peakAt))\(f.w.range == .week ? " on \(weekday(f.w.peakAt, short: false))" : "").",
               S.font(56 * f.u, .heavy), ink, x: f.m, y: 640 * f.u + f.rise(f.a(0.5), 30),
               width: f.W - 2 * f.m, tracking: -20, lineHeight: 1.05, alpha: CGFloat(f.a(0.5)))

        // Lanes, one per agent at work, sliding in staggered like parallel runs.
        let ids = f.w.agents.map(\.id)
        let laneH = 70 * f.u, gap = 22 * f.u
        let top = f.H * 0.52
        for i in 0..<min(f.w.peak, 8) {
            let id = ids.isEmpty ? "" : ids[i % ids.count]
            let start = 0.10 + 0.08 * Double(i % 3)
            let len = 0.55 + 0.1 * Double((i * 7) % 4)
            let g = S.easeOut(f.a(0.6 + Double(i) * 0.12, 1.0))
            let x0 = f.m + (f.W - 2 * f.m) * CGFloat(start)
            let w = (f.W - 2 * f.m) * CGFloat(len) * CGFloat(g)
            let y = top + CGFloat(i) * (laneH + gap)
            S.pill(CGRect(x: x0, y: y, width: max(laneH, w), height: laneH), S.colour(for: id))
        }
        // The moment they all ran: a line through the lanes.
        let line = f.a(1.6, 0.5)
        let lx = f.m + (f.W - 2 * f.m) * 0.5
        S.fill(CGRect(x: lx - 3 * f.u, y: top - 30 * f.u, width: 6 * f.u,
                      height: (CGFloat(min(f.w.peak, 8)) * (laneH + gap) + 40 * f.u) * CGFloat(line)), ink)
        signature(f, ink)
    }

    // MARK: - Best day (week)

    private static func bestDay(_ f: Frame) {
        guard let best = f.w.bestDay else { return }
        S.fill(CGRect(origin: .zero, size: f.size), S.orange)
        let ink = S.hex(0x1A0B14)
        kicker(f, "Your best day", ink.withAlphaComponent(0.6), y: 150 * f.u)
        let name = weekday(best.start, short: false)
        let a = f.a(0.15, 0.8)
        let font = S.fitting(name, max: 220 * f.u, width: f.W - 2 * f.m, tracking: -50)
        S.text(name, font, ink, x: f.m, y: 220 * f.u + f.rise(a, 80), width: f.W - 2 * f.m,
               tracking: -50, alpha: CGFloat(a))
        S.text("\(HistoryDigest.duration(best.seconds)) of agent time.", S.font(56 * f.u, .heavy), ink,
               x: f.m, y: 480 * f.u + f.rise(f.a(0.5), 30), width: f.W - 2 * f.m, alpha: CGFloat(f.a(0.5)))

        let maxBin = max(1, f.w.bins.max() ?? 1)
        let chartBottom = f.H - 260 * f.u, chartTop = f.H * 0.45
        let gap = 22 * f.u
        let bw = (f.W - 2 * f.m - gap * 6) / 7
        for (i, v) in f.w.bins.enumerated() {
            let g = S.easeBack(f.a(0.7 + Double(i) * 0.08, 0.6))
            let h = max(10 * f.u, (chartBottom - chartTop) * CGFloat(v / maxBin)) * CGFloat(max(0, g))
            let x = f.m + CGFloat(i) * (bw + gap)
            let isBest = f.w.binStart(i) == best.start
            S.pill(CGRect(x: x, y: chartBottom - h, width: bw, height: h),
                   isBest ? S.cream : ink.withAlphaComponent(0.85), radius: 24 * f.u)
            S.text(weekday(f.w.binStart(i), short: true), S.font(34 * f.u, .heavy), ink,
                   x: x, y: chartBottom + 18 * f.u, width: bw, align: .center)
        }
        signature(f, ink)
    }

    // MARK: - Persona

    private static func persona(_ f: Frame) {
        let p = f.w.persona
        let brand = S.colour(for: f.w.topAgent?.id ?? "claude")
        S.fill(CGRect(origin: .zero, size: f.size), S.hex(0x1B1240))
        blobs(f, [S.violet.withAlphaComponent(0.7), brand.withAlphaComponent(0.45), S.pink.withAlphaComponent(0.3)], seed: 4.2)

        // The symbol, huge and slowly turning behind the words.
        if let sym = S.symbol(p.symbol, size: 600 * f.u, weight: .black, color: S.cream.withAlphaComponent(0.10)) {
            let sz = sym.size
            f.ctx.saveGState()
            f.ctx.translateBy(x: f.W * 0.62, y: f.H * 0.36)
            f.ctx.rotate(by: CGFloat(sin(f.g * 0.4) * 0.06))
            let pop = S.easeBack(f.a(0.1, 1.0))
            f.ctx.scaleBy(x: CGFloat(pop), y: CGFloat(pop))
            S.image(sym, in: CGRect(x: -sz.width / 2, y: -sz.height / 2, width: sz.width, height: sz.height))
            f.ctx.restoreGState()
        }

        kicker(f, f.w.range == .today ? "Today you were" : "This week you were", S.cream.withAlphaComponent(0.7),
               y: f.H * 0.42)
        let words = p.title.split(separator: " ").map(String.init)
        var y = f.H * 0.42 + 64 * f.u
        for (i, word) in words.enumerated() {
            let a = f.a(0.35 + Double(i) * 0.18, 0.8)
            let font = S.fitting(word, max: 200 * f.u, width: f.W - 2 * f.m, tracking: -50)
            y += S.text(word, font, i == words.count - 1 ? S.lime : S.cream, x: f.m, y: y + f.rise(a, 90),
                        width: f.W - 2 * f.m, tracking: -50, lineHeight: 0.92, alpha: CGFloat(a))
        }
        let b = f.a(1.0)
        S.text(p.reason, S.font(46 * f.u, .bold), S.cream.withAlphaComponent(0.85), x: f.m,
               y: y + 40 * f.u + f.rise(b, 30), width: f.W - 2 * f.m, lineHeight: 1.15, alpha: CGFloat(b))

        // Clawd celebrates down in the corner.
        let poses = S.clawdPoses(.hammer)
        let frame = poses.isEmpty ? "" : poses[Int(f.g * 5) % poses.count]
        let c = f.a(1.2, 0.6)
        S.clawd(frame, origin: CGPoint(x: f.W - f.m - 22 * 12 * f.u, y: f.H - 330 * f.u + f.rise(c, 60)),
                pixel: 12 * f.u, alpha: CGFloat(c))
        signature(f, S.cream)
    }

    // MARK: - Card

    /// Everything on one poster: the frame people share. Portrait or square.
    private static func card(_ f: Frame) {
        let brand = S.colour(for: f.w.topAgent?.id ?? "claude")
        S.fill(CGRect(origin: .zero, size: f.size), S.night)
        S.glow(CGPoint(x: f.W * 0.9, y: f.H * 0.05), f.W * 0.9, brand.withAlphaComponent(0.55), in: f.ctx)
        S.glow(CGPoint(x: f.W * 0.05, y: f.H * 0.95), f.W * 0.8, S.violet.withAlphaComponent(0.45), in: f.ctx)

        let a = f.a(0.05, 0.6)
        let m = f.m
        var y = (f.square ? 70 : 120) * f.u
        S.text(("\(f.w.range.title) with agents · " + dateLine(f.w)).uppercased(), S.font(26 * f.u, .heavy),
               S.cream.withAlphaComponent(0.65), x: m, y: y, width: f.W - 2 * m, tracking: 120, alpha: CGFloat(a))
        y += 56 * f.u
        let title = f.w.isEmpty ? "A quiet day" : f.w.persona.title
        let tf = S.fitting(title, max: (f.square ? 120 : 150) * f.u, width: f.W - 2 * m, tracking: -45)
        y += S.text(title, tf, S.cream, x: m, y: y, width: f.W - 2 * m, tracking: -45, lineHeight: 0.95,
                    alpha: CGFloat(a))
        if !f.w.persona.reason.isEmpty, !f.w.isEmpty {
            y += 14 * f.u
            y += S.text(f.w.persona.reason, S.font(34 * f.u, .semibold), S.lime, x: m, y: y,
                        width: f.W - 2 * m, lineHeight: 1.15, alpha: CGFloat(a))
        }
        y += (f.square ? 36 : 64) * f.u

        // The tiles: the facts that exist, in a 2-column grid.
        var tiles: [(String, String, NSColor)] = []
        if f.w.timed > 0 { tiles.append((HistoryDigest.duration(f.w.agentSeconds), "agent time", S.lime)) }
        tiles.append((S.grouped(f.w.sessions), "session\(f.w.sessions == 1 ? "" : "s")", S.cream))
        if let top = f.w.topAgent { tiles.append((top.name, "top agent", brand)) }
        if f.w.changeMeasured > 0, f.w.linesAdded + f.w.linesRemoved > 0 {
            tiles.append(("+\(S.grouped(f.w.linesAdded))", "lines changed", S.green))
        }
        if f.w.waits.answered + f.w.waits.byRules > 0 {
            tiles.append((S.grouped(f.w.waits.answered + f.w.waits.byRules),
                          f.w.waits.byRules > 0 ? "answers · \(f.w.waits.byRules) by rules" : "answers from you", S.pink))
        }
        if f.w.peak >= 2 { tiles.append(("\(f.w.peak)×", "agents at once", S.hex(0x00D1FF))) }
        if let p = f.w.projects.first { tiles.append((p.name, "top project", S.orange)) }
        let cols = 2, gap = 22 * f.u
        let rows = f.square ? 2 : 3
        let tw = (f.W - 2 * m - gap) / CGFloat(cols)
        let th = f.square ? 196 * f.u : 236 * f.u
        for (i, t) in tiles.prefix(cols * rows).enumerated() {
            let b = S.easeBack(f.a(0.3 + Double(i) * 0.1, 0.6))
            let x = m + CGFloat(i % cols) * (tw + gap)
            let ty = y + CGFloat(i / cols) * (th + gap) + CGFloat(1 - b) * 40 * f.u
            let alpha = CGFloat(min(1, max(0, b)))
            S.pill(CGRect(x: x, y: ty, width: tw, height: th), S.cream.withAlphaComponent(0.08 * alpha), radius: 36 * f.u)
            S.fill(CGRect(x: x + 32 * f.u, y: ty + 32 * f.u, width: 44 * f.u, height: 8 * f.u),
                   t.2.withAlphaComponent(alpha))
            let vf = S.fitting(t.0, max: (f.square ? 66 : 84) * f.u, width: tw - 64 * f.u, rounded: true, tracking: -30)
            S.text(t.0, vf, S.cream, x: x + 32 * f.u, y: ty + 56 * f.u, width: tw - 64 * f.u,
                   tracking: -30, alpha: alpha)
            S.text(t.1, S.font(26 * f.u, .semibold), S.cream.withAlphaComponent(0.6), x: x + 32 * f.u,
                   y: ty + th - 52 * f.u, width: tw - 64 * f.u, alpha: alpha)
        }
        let shown = min(tiles.count, cols * rows)
        y += CGFloat((shown + cols - 1) / cols) * (th + gap) + 20 * f.u

        // The day itself, as the bars from the time slide: the shape of it is the
        // part nobody else's card has.
        let footerTop = f.H - (f.square ? 70 : 110) * f.u - 12 * (f.square ? 6 : 8) * f.u - 40 * f.u
        if let maxBin = f.w.bins.max(), maxBin > 0, footerTop - y > 80 * f.u {
            let bins = f.w.bins
            let bgap = (f.w.range == .today ? 6 : 16) * f.u
            let bw = (f.W - 2 * m - bgap * CGFloat(bins.count - 1)) / CGFloat(bins.count)
            let chartH = min(footerTop - y, (f.square ? 150 : 300) * f.u)
            let bottom = y + chartH
            for (i, v) in bins.enumerated() {
                let g = S.easeBack(f.a(0.8 + Double(i) * 0.02, 0.5))
                let h = max(4 * f.u, chartH * CGFloat(v / maxBin)) * CGFloat(max(0, g))
                let agent = f.w.binAgents.indices.contains(i) ? f.w.binAgents[i] : ""
                S.pill(CGRect(x: m + CGFloat(i) * (bw + bgap), y: bottom - h, width: bw, height: h),
                       v > 0 ? S.colour(for: agent) : S.cream.withAlphaComponent(0.12), radius: min(bw / 2, 10 * f.u))
            }
        }

        // Footer: Clawd and where this came from.
        let poses = S.clawdPoses(.think)
        let px = (f.square ? 6 : 8) * f.u
        S.clawd(poses.first ?? "", origin: CGPoint(x: m, y: f.H - (f.square ? 70 : 110) * f.u - 12 * px), pixel: px)
        S.text("AgentBar", S.font(34 * f.u, .heavy), S.cream, x: m + 22 * px + 20 * f.u,
               y: f.H - (f.square ? 70 : 110) * f.u - 12 * px + 4 * f.u, width: 400 * f.u, tracking: -10)
        S.text("free & open source for macOS", S.font(24 * f.u, .medium), S.cream.withAlphaComponent(0.55),
               x: m + 22 * px + 20 * f.u, y: f.H - (f.square ? 70 : 110) * f.u - 12 * px + 48 * f.u,
               width: 500 * f.u)
    }

    // MARK: - To a bitmap

    /// One frame as a bitmap at `pixels`, drawn at `scale` pixels per canvas unit.
    static func bitmap(_ slide: WrapSlide, at seconds: Double, global: Double? = nil, wrap: DayWrap,
                       pixels: CGSize, still: Bool = false) -> NSBitmapImageRep? {
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
        draw(slide, at: seconds, global: global, wrap: wrap, size: pixels, in: cg, still: still)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
