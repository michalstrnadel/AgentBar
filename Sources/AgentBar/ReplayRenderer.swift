import AppKit

/// What a replay draws: the level, and the few words around it.
struct Replay: Equatable {
    var turn: ReplayTurn
    var segments: [SessionTimeline.Segment]
    var agentID: String
    /// The project's name, or "" when it may not be shown.
    var project: String
    /// Said lines and project names are in it. Off for anything shared unless the
    /// person turned names on, as on Your Day.
    var named: Bool
    private(set) var level: ReplayLevel.Level

    init(turn: ReplayTurn, segments: [SessionTimeline.Segment] = [], agentID: String = "claude",
         project: String = "", named: Bool) {
        self.turn = turn
        self.segments = segments
        self.agentID = agentID
        self.named = named
        self.project = named ? project : ""
        level = ReplayLevel.make(entries: turn.entries, failures: turn.failures, segments: segments,
                                 includeSaid: named)
    }

    /// The same turn without anything that names the work.
    func shareSafe() -> Replay {
        Replay(turn: turn, segments: segments, agentID: agentID, project: "", named: false)
    }

    var duration: Double { level.duration }
}

/// Draws a replay at any moment of its clip: Clawd walking the turn as a little
/// level on paper, the way Your Day's card is drawn — same paper, same ink, same
/// footer, his own pixels and nothing that glows.
///
/// **One deterministic function** — `draw(at:replay:size:in:)` — is the window,
/// the PNG, the GIF and the MP4, as with `WrapRenderer`: a moment of the clip
/// looks the same every time it is drawn. Flipped canvas, units of `u`.
enum ReplayRenderer {
    typealias S = WrapStyle
    typealias L = ReplayLevel

    struct Frame {
        let r: Replay
        let t: Double
        let size: CGSize
        var W: CGFloat { size.width }
        var H: CGFloat { size.height }
        var u: CGFloat { min(W, H) / 1080 }
        var square: Bool { H / max(1, W) < 1.3 }
        var m: CGFloat { (square ? 72 : 96) * u }
        var inner: CGFloat { W - 2 * m }
        /// One of Clawd's pixels.
        var px: CGFloat { (square ? 10 : 15) * u }
    }

    static func draw(at t: Double, replay: Replay, size: CGSize, in ctx: CGContext) {
        let f = Frame(r: replay, t: max(0, min(t, replay.duration)), size: size)
        ctx.saveGState()
        ctx.clip(to: CGRect(origin: .zero, size: size))
        S.fill(CGRect(origin: .zero, size: size), S.paper)
        let top = header(f, top: (f.square ? 56 : 104) * f.u)
        let below = hero(f, y: top + (f.square ? 34 : 64) * f.u)
        // The ground sits low enough for a bubble and a gate above Clawd.
        let ground = f.square
            ? max(below + 330 * f.u, f.H * 0.70)
            : max(below + 560 * f.u, f.H * 0.60)
        caption(f, y: (below + ground - (f.square ? 300 : 330) * f.u) / 2 - 20 * f.u)
        level(f, ground: ground)
        track(f, y: ground + (f.square ? 120 : 210) * f.u)
        footer(f)
        ctx.restoreGState()
    }

    // MARK: - Words

    private static func header(_ f: Frame, top: CGFloat) -> CGFloat {
        let font = S.font((f.square ? 26 : 30) * f.u, .semibold)
        S.text("Replay · " + DayWrap.clock(f.r.level.realStart), font, S.ink, x: f.m, y: top, width: f.inner)
        let right = f.r.project.isEmpty ? Agent.byID(f.r.agentID).name : f.r.project
        S.text(right, font, S.secondary, x: f.m, y: top, width: f.inner, align: .right)
        let y = top + font.pointSize * 1.25 + (f.square ? 18 : 26) * f.u
        S.fill(CGRect(x: f.m, y: y, width: f.inner, height: max(1, 2 * f.u)), S.hairline)
        return y
    }

    /// The turn's length, big, and what was in it, in a sentence.
    private static func hero(_ f: Frame, y: CGFloat) -> CGFloat {
        let l = f.r.level
        let big = l.steps == 0 && l.errors == 0 ? "A quiet turn" : clockLength(l.realSeconds)
        let font = S.fitting(big, max: (f.square ? 130 : 180) * f.u, width: f.inner, weight: .semibold, tracking: -35)
        let h = S.text(big, font, S.ink, x: f.m - 4 * f.u, y: y, width: f.W * 2, tracking: -35, lineHeight: 0.95)
        let below = y + h - font.pointSize * 0.06
        let words = sentence(l)
        let h2 = S.text(words, S.font((f.square ? 28 : 34) * f.u, .regular), S.secondary, x: f.m, y: below,
                        width: f.inner, lineHeight: 1.25)
        return below + h2
    }

    /// "one turn — 23 steps, 1 error, waited on you 2m".
    static func sentence(_ l: L.Level) -> String {
        var bits = ["\(l.steps) step\(l.steps == 1 ? "" : "s")"]
        if l.errors > 0 { bits.append("\(l.errors) error\(l.errors == 1 ? "" : "s")") }
        if l.waited >= 1 { bits.append("waited on you \(S.shortWait(l.waited))") }
        return "one turn — " + bits.joined(separator: ", ")
    }

    /// "4m 12s", "38 s", "1h 05m".
    static func clockLength(_ s: TimeInterval) -> String {
        let n = Int(s.rounded())
        if n < 60 { return "\(max(1, n)) s" }
        if n < 3_600 { return "\(n / 60)m \(String(format: "%02d", n % 60))s" }
        return "\(n / 3_600)h \(String(format: "%02d", n % 3_600 / 60))m"
    }

    /// What Clawd is doing now, in words, above the level: the clip read as a
    /// story by someone who never saw the island.
    static func caption(at t: Double, in l: L.Level) -> String {
        guard let b = l.beats.last(where: { $0.arrive <= t }) else {
            return l.earlier > 0 ? "…and on it goes" : "Off it goes"
        }
        switch b.kind {
        case let .station(scene, word, count):
            let doing: String
            switch scene {
            case .hammer:   doing = "Running a command"
            case .read:     doing = "Reading"
            case .type:     doing = word == "Write" ? "Writing" : "Editing"
            case .search:   doing = "Searching"
            case .web:      doing = "On the web"
            case .delegate: doing = "Handing off to an agent"
            default:        doing = word == "Tool" ? "Using a tool" : "Using \(word)"
            }
            return count > 1 ? "\(doing) ×\(count)" : doing
        case .pit(let tests):
            return tests ? "Tests failed — hop" : "An error — hop"
        case .gate(let waited):
            return t < b.leave ? "Waiting on you" : "You answered after \(S.shortWait(waited))"
        case .flag:
            return "Done"
        }
    }

    private static func caption(_ f: Frame, y: CGFloat) {
        let l = f.r.level
        let s = caption(at: f.t, in: l)
        let since = f.t - (l.beats.last(where: { $0.arrive <= f.t })?.arrive ?? 0)
        let a = CGFloat(S.easeOut(min(1, since / 0.25)))
        S.text(s, S.font((f.square ? 44 : 56) * f.u, .semibold), S.ink, x: f.m, y: y + (1 - a) * 10 * f.u, width: f.inner,
               tracking: -15, alpha: 0.35 + 0.65 * a)
    }

    // MARK: - The level

    /// Screen x of a level x, with the camera following Clawd: he walks at a
    /// third of the way across, and the level's ends stay on screen.
    private static func camera(_ f: Frame) -> CGFloat {
        let (cx, _) = L.clawd(at: f.t, in: f.r.level)
        let want = CGFloat(cx) * f.px - f.inner * 0.3
        let far = CGFloat(f.r.level.length + 10) * f.px - f.inner
        return max(0, min(want, max(0, far)))
    }

    private static func level(_ f: Frame, ground: CGFloat) {
        let cam = camera(f)
        let px = f.px
        /// Level pixels → screen x, snapped so Clawd's squares stay square.
        func sx(_ x: Double) -> CGFloat { (f.m + CGFloat(x) * px - cam).rounded() }
        let l = f.r.level
        let (cx, pose) = L.clawd(at: f.t, in: l)

        // The ground, with the pits cut out of it.
        let pits: [ClosedRange<CGFloat>] = l.beats.compactMap { b in
            guard case .pit = b.kind else { return nil }
            return sx(b.x0 + 13)...sx(b.x0 + 13 + L.pitWidth)
        }
        groundBand(f, y: ground, pits: pits)

        let labelFont = S.font((f.square ? 22 : 24) * f.u, .medium)
        let labelY = ground + 4 * px + 14 * f.u
        // A label centred under `x`, clipped to the screen.
        func label(_ s: String, _ x: CGFloat, _ color: NSColor) {
            let w = S.measure(s, labelFont).width
            S.text(s, labelFont, color, x: x - w / 2, y: labelY, width: w + 4 * f.u)
        }

        if l.earlier > 0 {
            sign("\(l.earlier) earlier step\(l.earlier == 1 ? "" : "s")", x: sx(4), ground: ground, f)
        }
        // Where the ground is clear after each beat: past its prop, gate or pit.
        var clear = L.start
        for b in l.beats {
            let visible = sx(b.x0 - 30) < f.W && sx(b.x1 + 40) > 0
            if b.gapBefore >= L.signAfter, visible {
                sign(later(b.gapBefore), x: sx((clear + b.x0) / 2 + 1), ground: ground, f)
            }
            switch b.kind {
            case .station: clear = b.x1 + 22
            case .gate:    clear = b.x1 + 31
            default:       clear = b.x1 + 12
            }
            guard visible else { continue }
            switch b.kind {
            case let .station(scene, word, count):
                let here = f.t >= b.arrive && f.t < b.leave
                let done = f.t >= b.leave
                if !here {
                    prop(scene, x: sx(b.x0 + 13), ground: ground, px: px, alpha: done ? 0.4 : 1)
                }
                label(count > 1 ? "\(word) ×\(count)" : word, sx(b.x0 + 17), done || here ? S.secondary : S.tertiary)
            case let .pit(tests):
                label(tests ? "tests failed" : "error", sx(b.x0 + 13 + L.pitWidth / 2), S.removed)
            case let .gate(waited):
                let open = f.t >= b.leave ? 1 : (f.t >= b.arrive
                    ? max(0, min(1, ((f.t - b.arrive) / max(0.01, b.leave - b.arrive) - 0.45) / 0.45)) : 0)
                gate(x: sx(b.x0 + 22), ground: ground, px: px, open: open)
                label("waited \(S.shortWait(waited))", sx(b.x0 + 26.5), S.secondary)
            case .flag:
                let raised = f.t >= b.arrive ? S.easeOut((f.t - b.arrive) / 0.6) : 0
                flag(x: sx(b.x0 + 18), ground: ground, px: px, raised: raised)
                label("done " + DayWrap.clock(l.realEnd), sx(b.x0 + 18), S.secondary)
            }
        }

        // Clawd, standing on the ground: his twelve rows end at it.
        let head = ground - 12 * px
        let (art, lift) = clawdArt(pose, t: f.t)
        S.clawd(art, origin: CGPoint(x: sx(cx), y: (head - lift * px).rounded()), pixel: px)

        // What he said, over his head.
        if let b = l.bubbles.first(where: { f.t >= $0.from && f.t < $0.to }) {
            let a = min(1, (f.t - b.from) / 0.15, (b.to - f.t) / 0.15)
            bubble(b.text, anchor: CGPoint(x: sx(cx) + 6 * px, y: head - 2 * px), f, alpha: CGFloat(max(0, a)))
        }
    }

    /// The ground: a darker top row and a band of bricks, flat colours of the
    /// card's paper, under the whole width.
    private static func groundBand(_ f: Frame, y: CGFloat, pits: [ClosedRange<CGFloat>]) {
        let px = f.px
        let top = S.hex(0xCFC8BA), band = S.hairline, seam = S.hex(0xD8D2C6)
        func row(_ y0: CGFloat, _ h: CGFloat, _ c: NSColor) {
            var x: CGFloat = 0
            for p in pits.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if p.lowerBound > x { S.fill(CGRect(x: x, y: y0, width: p.lowerBound - x, height: h), c) }
                x = max(x, p.upperBound)
            }
            if x < f.W { S.fill(CGRect(x: x, y: y0, width: f.W - x, height: h), c) }
        }
        row(y, px, top)
        row(y + px, 3 * px, band)
        // Brick seams, fixed to the level so they scroll with it.
        let cam = camera(f)
        let brick = 6 * px
        var x = f.m - cam.truncatingRemainder(dividingBy: brick) - brick
        while x < f.W {
            for (i, yy) in [y + 2 * px, y + 3 * px].enumerated() {
                let bx = (x + (i == 1 ? brick / 2 : 0)).rounded()
                guard !pits.contains(where: { $0.contains(bx) }) else { continue }
                S.fill(CGRect(x: bx, y: yy, width: max(1, px / 3), height: px), seam)
            }
            x += brick
        }
        // Inside a pit: dark, as deep as the band.
        for p in pits {
            S.fill(CGRect(x: p.lowerBound, y: y, width: p.upperBound - p.lowerBound, height: 4 * px),
                   S.ink.withAlphaComponent(0.85))
        }
    }

    private static func sign(_ text: String, x: CGFloat, ground: CGFloat, _ f: Frame) {
        let font = S.font((f.square ? 20 : 22) * f.u, .regular)
        let w = S.measure(text, font).width
        S.text(text, font, S.tertiary, x: x - w / 2, y: ground - 7 * f.px, width: w + 4 * f.u, align: .center)
        S.fill(CGRect(x: x - f.px / 4, y: ground - 4 * f.px, width: max(1, f.px / 2), height: 4 * f.px), S.tertiary)
    }

    private static func later(_ gap: TimeInterval) -> String {
        gap < 3_600 ? "\(Int(gap / 60)) min later" : "\(HistoryDigest.duration(gap)) later"
    }

    // MARK: Props

    /// A station's prop, standing on the ground with its left edge at `x`: the
    /// thing Clawd holds in that scene, taken out of his own picture.
    private static func prop(_ scene: ClawdScene, x: CGFloat, ground: CGFloat, px: CGFloat, alpha: CGFloat) {
        let art = propArt(scene)
        let rows = art.split(separator: "\n")
        let origin = CGPoint(x: x, y: ground - CGFloat(rows.count) * px)
        guard alpha < 1, let ctx = NSGraphicsContext.current?.cgContext else {
            return S.clawd(art, origin: origin, pixel: px)
        }
        // Faded as one: squares that overlap by a hair would otherwise show a grid.
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        S.clawd(art, origin: origin, pixel: px)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// Worked out once: exports draw off the main thread, so nothing here is
    /// filled in lazily.
    private static let props: [ClawdScene: String] = Dictionary(
        uniqueKeysWithValues: ClawdScene.allCases.map { ($0, makeProp($0)) })

    /// The prop in a scene's first pose: its columns right of Clawd, cropped to
    /// what is drawn. The hammer leaves its anvil; a tool with no picture is a crate.
    static func propArt(_ scene: ClawdScene) -> String { props[scene] ?? crate }

    private static func makeProp(_ scene: ClawdScene) -> String {
        let art: String
        if scene == .read {
            art = books
        } else if let pose = scene.reel?.poses.first, scene != .think, scene != .walk {
            let keep: (Character) -> Bool = {
                switch scene {
                case .hammer:   return $0 == "a"
                case .delegate: return $0 != "."
                default:        return !"oO#.".contains($0)
                }
            }
            var lines = pose.split(separator: "\n").map { line -> [Character] in
                Array(line).enumerated().map { $0.offset >= 13 && keep($0.element) ? $0.element : "." }
            }
            lines.removeAll { $0.allSatisfy { $0 == "." } }
            let cols = lines.first?.indices ?? 0..<0
            let used = cols.filter { c in lines.contains { $0[c] != "." } }
            if let lo = used.first, let hi = used.last {
                art = lines.map { String($0[lo...hi]) }.joined(separator: "\n")
            } else {
                art = crate
            }
        } else {
            art = crate
        }
        return art
    }

    /// Two books on the ground: the open one he holds would lie flat as a smudge.
    private static let books = """
        .bbbbbbbbb
        .mmmmmmmmB
        .bbbbbbbbB
        BBBBBBBBB.
        mmmmmmmmmB
        bbbbbbbbbB
        """

    private static let crate = """
        TTTTTTT
        TttttqT
        TtTtTtT
        TttTttT
        TtTtTtT
        TqttttT
        TTTTTTT
        """

    // MARK: Gate and flag

    /// A portcullis: a beam, two posts, and bars that lift as it opens.
    private static func gate(x: CGFloat, ground: CGFloat, px: CGFloat, open: Double) {
        let h: CGFloat = 15, w: CGFloat = 9
        let top = ground - h * px
        let ink = S.ink.withAlphaComponent(0.85)
        S.fill(CGRect(x: x - px, y: top - px, width: (w + 2) * px, height: 2 * px), ink)
        S.fill(CGRect(x: x, y: top, width: px, height: h * px), ink)
        S.fill(CGRect(x: x + (w - 1) * px, y: top, width: px, height: h * px), ink)
        // The bars slide up behind the beam: what is left of them shows below it.
        let lift = (CGFloat(S.easeOut(open)) * (h - 2)).rounded()
        let bars = S.hex(0x8A8A8A)
        let barTop = top + px
        let barH = (h - 1 - lift) * px
        guard barH > 0 else { return }
        for i in stride(from: 2, to: Int(w) - 1, by: 2) {
            S.fill(CGRect(x: x + CGFloat(i) * px, y: barTop, width: px, height: barH), bars)
        }
        // Cross bars: the bottom one, and one higher up that rises with it.
        for up in [CGFloat(1), 7] where up * px <= barH {
            S.fill(CGRect(x: x + px, y: barTop + barH - up * px, width: (w - 2) * px, height: px), bars)
        }
    }

    private static func flag(x: CGFloat, ground: CGFloat, px: CGFloat, raised: Double) {
        let h: CGFloat = 18
        S.fill(CGRect(x: x, y: ground - h * px, width: px, height: h * px), S.ink.withAlphaComponent(0.85))
        S.fill(CGRect(x: x - px, y: ground - px, width: 3 * px, height: px), S.ink.withAlphaComponent(0.85))
        let low = ground - 6 * px, high = ground - (h - 1) * px
        let y = (low + (high - low) * CGFloat(raised)).rounded()
        let flag = S.hex(ClawdSceneArt.palette["o"] ?? 0xd77757)
        S.fill(CGRect(x: x + px, y: y, width: 6 * px, height: 4 * px), flag)
        S.fill(CGRect(x: x + 7 * px, y: y + px, width: px, height: 2 * px), flag)
    }

    // MARK: Clawd

    /// Clawd walking, side on: the scenes' own body, his legs taking turns.
    static let walk: [String] = [
        """
        oooooooooooo
        oooooooooooo
        oo##oooooo##
        oo##oooooo##
        oooooooooooo
        oooooooooooo
        oooooooooooo
        oooooooooooo
        oo....oo..oo
        oo....oo..oo
        o.....o...o.
        o.....o...o.
        """,
        """
        oooooooooooo
        oooooooooooo
        oo##oooooo##
        oo##oooooo##
        oooooooooooo
        oooooooooooo
        oooooooooooo
        oooooooooooo
        oo....oo..oo
        oo....oo..oo
        .o.....o...o
        .o.....o...o
        """,
    ]

    /// The picture for a pose at `t`, and how many pixels he is off the ground.
    private static func clawdArt(_ pose: L.Pose, t: Double) -> (String, CGFloat) {
        func reel(_ scene: ClawdScene, _ since: Double) -> String {
            guard let r = scene.reel, !r.rhythm.isEmpty else { return walk[0] }
            let i = r.rhythm[Int(since * 10) % r.rhythm.count]
            return r.poses[min(i, r.poses.count - 1)]
        }
        switch pose {
        case .walk(let step):
            // A one-pixel bob on every other step.
            return (walk[step % 2], 0)
        case .hop(let f):
            // Legs spread, the way a crab jumps.
            let lift = CGFloat(4 * f * (1 - f)) * 9
            return (walk[1], lift.rounded())
        case let .acting(scene, since):
            return (reel(scene == .walk ? .think : scene, since), 0)
        case .waiting:
            return (reel(.approve, t), 0)
        case .done(let since):
            // Two small jumps at the flag, then he stands.
            let n = since * 2.2
            let lift: CGFloat = n < 2 ? CGFloat(4 * n.truncatingRemainder(dividingBy: 1) *
                                                (1 - n.truncatingRemainder(dividingBy: 1))) * 3 : 0
            return (ClawdScene.think.reel?.poses.first ?? walk[0], lift.rounded())
        }
    }

    // MARK: Bubble

    private static func bubble(_ text: String, anchor: CGPoint, _ f: Frame, alpha: CGFloat) {
        let font = S.font((f.square ? 26 : 30) * f.u, .medium)
        let pad = 22 * f.u
        let tw = min(S.measure(text, font).width, f.inner - 2 * pad)
        let h = S.measure("Ag", font).height
        let w = tw + 2 * pad
        let bh = h + 2 * pad * 0.8
        // Over his head, kept on the canvas.
        let x = max(f.m, min(anchor.x - w * 0.3, f.W - f.m - w))
        let y = anchor.y - bh - 26 * f.u
        let rect = CGRect(x: x, y: y, width: w, height: bh)
        let path = NSBezierPath(roundedRect: rect, xRadius: 16 * f.u, yRadius: 16 * f.u)
        let tail = NSBezierPath()
        let tx = max(rect.minX + 30 * f.u, min(anchor.x, rect.maxX - 30 * f.u))
        tail.move(to: CGPoint(x: tx - 12 * f.u, y: rect.maxY - 1))
        tail.line(to: CGPoint(x: tx + 2 * f.u, y: rect.maxY + 18 * f.u))
        tail.line(to: CGPoint(x: tx + 14 * f.u, y: rect.maxY - 1))
        tail.close()
        S.paper.withAlphaComponent(alpha).setFill()
        path.fill()
        tail.fill()
        S.ink.withAlphaComponent(alpha * 0.85).setStroke()
        path.lineWidth = 3 * f.u
        path.stroke()
        // The tail's two sides, without a line across where it meets the bubble.
        let edge = NSBezierPath()
        edge.move(to: CGPoint(x: tx - 12 * f.u, y: rect.maxY))
        edge.line(to: CGPoint(x: tx + 2 * f.u, y: rect.maxY + 18 * f.u))
        edge.line(to: CGPoint(x: tx + 14 * f.u, y: rect.maxY))
        edge.lineWidth = 3 * f.u
        edge.lineJoinStyle = .round
        edge.stroke()
        S.fill(CGRect(x: tx - 10 * f.u, y: rect.maxY - 3 * f.u, width: 22 * f.u, height: 3 * f.u),
               S.paper.withAlphaComponent(alpha))
        S.text(text, font, S.ink, x: x + pad, y: y + pad * 0.8 - 2 * f.u, width: tw + 4 * f.u, alpha: alpha)
    }

    // MARK: - The track under it

    /// The whole turn on one line: a mark per beat, where Clawd is now, and the
    /// clock at both ends — the level at a glance, and a still's sense of where.
    private static func track(_ f: Frame, y: CGFloat) {
        let l = f.r.level
        let len = max(1, l.length)
        func x(_ lx: Double) -> CGFloat { f.m + f.inner * CGFloat(min(1, max(0, lx / len))) }
        S.fill(CGRect(x: f.m, y: y - f.u, width: f.inner, height: max(1, 2 * f.u)), S.hairline)
        let (cx, _) = L.clawd(at: f.t, in: l)
        S.fill(CGRect(x: f.m, y: y - 2 * f.u, width: x(cx) - f.m, height: 4 * f.u), S.ink.withAlphaComponent(0.7))
        let d = 12 * f.u
        for b in l.beats {
            let mx = x(b.x0 + 6)
            switch b.kind {
            case .station:
                S.fill(CGRect(x: mx - d / 2, y: y - d / 2, width: d, height: d), S.paper)
                S.fill(CGRect(x: mx - d / 2 + 2 * f.u, y: y - d / 2 + 2 * f.u, width: d - 4 * f.u, height: d - 4 * f.u),
                       f.t >= b.arrive ? S.ink : S.tertiary)
            case .pit:
                S.fill(CGRect(x: mx - d / 2, y: y - d / 2, width: d, height: d), S.removed)
            case .gate:
                S.fill(CGRect(x: mx - 2 * f.u, y: y - d, width: 4 * f.u, height: 2 * d), S.ink.withAlphaComponent(0.85))
            case .flag:
                S.fill(CGRect(x: mx - 1.5 * f.u, y: y - 2 * d, width: 3 * f.u, height: 2 * d), S.ink.withAlphaComponent(0.85))
                S.fill(CGRect(x: mx + 1.5 * f.u, y: y - 2 * d, width: d, height: d * 0.7),
                       S.hex(ClawdSceneArt.palette["o"] ?? 0xd77757))
            }
        }
        let font = S.font((f.square ? 22 : 24) * f.u, .regular)
        S.text(DayWrap.clock(l.realStart), font, S.tertiary, x: f.m, y: y + 22 * f.u, width: f.inner)
        S.text(DayWrap.clock(l.realEnd), font, S.tertiary, x: f.m, y: y + 22 * f.u, width: f.inner, align: .right)
        guard !f.square else { return }
        // What the marks mean, once, quietly.
        var lx = f.m
        let ly = y + 96 * f.u
        let lf = S.font(22 * f.u, .regular)
        func key(_ swatch: () -> Void, _ s: String) {
            swatch()
            lx += 22 * f.u
            S.text(s, lf, S.tertiary, x: lx, y: ly - lf.pointSize * 0.62, width: 300 * f.u)
            lx += S.measure(s, lf).width + 30 * f.u
        }
        key({ S.fill(CGRect(x: lx, y: ly - 5 * f.u, width: 10 * f.u, height: 10 * f.u), S.ink) }, "a step")
        if l.errors > 0 {
            key({ S.fill(CGRect(x: lx, y: ly - 6 * f.u, width: 12 * f.u, height: 12 * f.u), S.removed) }, "an error")
        }
        if l.waited >= 1 {
            key({ S.fill(CGRect(x: lx + 4 * f.u, y: ly - 12 * f.u, width: 4 * f.u, height: 24 * f.u),
                         S.ink.withAlphaComponent(0.85)) }, "waited on you")
        }
    }

    // MARK: - Footer

    private static func footer(_ f: Frame) {
        let base = f.H - (f.square ? 48 : 80) * f.u
        S.fill(CGRect(x: f.m, y: base - (f.square ? 44 : 60) * f.u, width: f.inner, height: max(1, 2 * f.u)), S.hairline)
        let px = (f.square ? 2.4 : 3) * f.u
        S.clawd(S.clawdPoses(.think).first ?? "", origin: CGPoint(x: f.m, y: base - 9 * px), pixel: px)
        let font = S.font((f.square ? 22 : 26) * f.u, .regular)
        let line = NSMutableAttributedString(string: "AgentBar", attributes: [
            .font: S.font((f.square ? 22 : 26) * f.u, .semibold), .foregroundColor: S.ink])
        line.append(NSAttributedString(string: "  ·  free and open source for macOS", attributes: [
            .font: font, .foregroundColor: S.secondary]))
        S.rich(line, x: f.m + 22 * px + 14 * f.u, y: base - font.pointSize * 1.05, width: f.inner)
    }

    // MARK: - To a bitmap

    static func bitmap(at t: Double, replay: Replay, pixels: CGSize) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width),
                                         pixelsHigh: Int(pixels.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let g = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cg = g.cgContext
        cg.translateBy(x: 0, y: pixels.height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        draw(at: t, replay: replay, size: pixels, in: cg)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
