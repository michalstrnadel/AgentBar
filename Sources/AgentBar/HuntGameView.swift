import Cocoa

/// Bug Hunt on screen: draws `HuntGame`, turns clicks into shots, and runs its
/// clock only while it is played. Paused, closed or yielded, nothing ticks.
///
/// The field fills the island: sky, a tree, the tall grass the bugs rise out of
/// and the dog pops up from, and a dirt strip with the scoreboard (round and shells,
/// the hit bar, the score). Aim with the mouse (a crosshair over the field) or
/// with the arrows and Space; P pauses, Esc closes.
final class HuntGameView: NSView, IslandGame {
    static let size = NSSize(width: HuntGame.width, height: HuntGame.height)

    var game = HuntGame(seed: UInt64(Date().timeIntervalSince1970 * 1000))
    var paused = false
    var newHigh = false
    /// Where the sight is: the pointer, or wherever the arrows moved it.
    var aim = CGPoint(x: HuntGame.width / 2, y: 300)
    /// The arrows were used last: draw a sight, since the pointer is not it.
    var keyAim = false
    private var keys: Set<UInt16> = []
    private var timer: Timer?
    private var last: CFTimeInterval = 0
    private var recorded = false
    private var puffs: [(x: CGFloat, y: CGFloat, age: Double)] = []
    private var autoCooldown: Double = 0
    private let defaults: UserDefaults

    var onClose: (() -> Void)?
    var onWantsKeys: (() -> Void)?

    var score: Int { game.score }

    // MARK: - Pictures, rendered once

    private static let fly: [BreakGame.Kind: [CGImage]] = Dictionary(uniqueKeysWithValues: BreakGame.Kind.allCases.map { k in
        (k, HuntGameArt.flyTemplate.compactMap { HuntGameArt.image(HuntGameArt.colour($0, k), pixel: 3) })
    })
    private static let flyLeft: [BreakGame.Kind: [CGImage]] = Dictionary(uniqueKeysWithValues: BreakGame.Kind.allCases.map { k in
        (k, HuntGameArt.flyTemplate.compactMap { HuntGameArt.image(HuntGameArt.flipped(HuntGameArt.colour($0, k)), pixel: 3) })
    })
    private static let front: [BreakGame.Kind: CGImage] = BreakGameArt.bugs.compactMapValues {
        $0.first.flatMap { HuntGameArt.image($0, pixel: 3.6) }
    }
    private static let upsideDown: [BreakGame.Kind: CGImage] = BreakGameArt.bugs.compactMapValues {
        $0.first.flatMap { HuntGameArt.image(HuntGameArt.flipped($0, horizontally: false), pixel: 3.6) }
    }
    private static let held: [BreakGame.Kind: CGImage] = BreakGameArt.bugs.compactMapValues {
        $0.first.flatMap { HuntGameArt.image(HuntGameArt.flipped($0, horizontally: false), pixel: 2.8) }
    }
    private static let hold = HuntGameArt.dogHold.compactMap { HuntGameArt.image($0, pixel: 4) }
    private static let laugh = HuntGameArt.dogLaugh.compactMap { HuntGameArt.image($0, pixel: 4) }
    private static let walk = HuntGameArt.dogWalk.compactMap { HuntGameArt.image($0, pixel: 4) }
    private static let sniff = HuntGameArt.image(HuntGameArt.dogSniff, pixel: 4)
    private static let tree = HuntGameArt.image(HuntGameArt.tree, pixel: 6)
    private static let bush = HuntGameArt.image(HuntGameArt.bush, pixel: 4)
    private static let grassEdge = HuntGameArt.image(HuntGameArt.grassEdge, pixel: 3)
    private static let iconWhite = HuntGameArt.image(HuntGameArt.icon, pixel: 2)
    private static let iconRed = HuntGameArt.image(HuntGameArt.icon.replacingOccurrences(of: "w", with: "r"), pixel: 2)
    private static let shell = HuntGameArt.image(HuntGameArt.shell, pixel: 2)
    private static let puff = BreakGameArt.burst.first.flatMap { BreakGameArt.image($0, pixel: 2) }

    // MARK: - Hit areas

    private var closeRect: NSRect { NSRect(x: HuntGame.width - 74, y: HuntGame.height - 30, width: 64, height: 20) }
    private func titleRect(_ mode: HuntGame.Mode) -> NSRect {
        NSRect(x: 96, y: mode == .a ? 250 : 216, width: 240, height: 28)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Bug Hunt: shoot the bugs as they fly. Aim with the pointer or the arrows, click or Space to shoot, Escape closes.")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { Self.size }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() {
        addCursorRect(NSRect(x: 0, y: HuntGame.groundTop, width: HuntGame.width, height: HuntGame.height - HuntGame.groundTop),
                      cursor: .crosshair)
    }

    override func cursorUpdate(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        (p.y > HuntGame.groundTop ? NSCursor.crosshair : NSCursor.arrow).set()
    }

    // MARK: - The clock

    func resume() {
        paused = false
        last = CACurrentMediaTime()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        needsDisplay = true
    }

    func pause() {
        guard !paused, !BreakGameView.demo else { return }
        paused = true
        keys = []
        timer?.invalidate()
        timer = nil
        needsDisplay = true
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - last, 0.05)
        last = now
        if BreakGameView.demo { autopilot(dt: dt) }
        advance(dt: dt)
        needsDisplay = true
    }

    /// One frame: the sight, the game, the puffs, and the sounds for what happened.
    func advance(dt: Double) {
        let speed = 300 * dt
        if keys.contains(123) { aim.x -= speed }
        if keys.contains(124) { aim.x += speed }
        if keys.contains(126) { aim.y += speed }
        if keys.contains(125) { aim.y -= speed }
        aim.x = min(max(aim.x, 0), HuntGame.width)
        aim.y = min(max(aim.y, HuntGame.groundTop), HuntGame.height)
        puffs = puffs.compactMap { p in p.age + dt < 0.18 ? (p.x, p.y, p.age + dt) : nil }
        play(game.step(dt: dt))
    }

    private func play(_ ev: HuntGame.Events) {
        if ev.gameOver, !recorded {
            recorded = true
            newHigh = HuntGame.Prefs.record(game.score, mode: game.mode, defaults)
            SoundCenter.shared.playGame(.over)
        } else if ev.perfect {
            SoundCenter.shared.playGame(.perfect)
        } else if ev.roundPassed {
            SoundCenter.shared.playGame(.roundClear)
        } else if ev.hits > 0 {
            SoundCenter.shared.playGame(.fall)
        } else if ev.flyAway {
            SoundCenter.shared.playGame(.flyAway)
        } else if ev.laugh {
            SoundCenter.shared.playGame(.laugh)
        } else if ev.retrieve {
            SoundCenter.shared.playGame(.retrieve)
        } else if ev.fell {
            SoundCenter.shared.playGame(.thump)
        } else if ev.shot {
            SoundCenter.shared.playGame(.shot)
        }
    }

    private func shoot(at p: CGPoint) {
        guard game.phase == .flight, game.shotsLeft > 0 else { return }
        let ev = game.shoot(x: p.x, y: p.y)
        if ev.shot { puffs.append((p.x, p.y, 0)) }
        play(ev)
        needsDisplay = true
    }

    /// `breakGameDemo`, and the offscreen renders: the game plays itself — a hunter
    /// that tracks the nearest bug a little late and sometimes misses.
    func autopilot(dt: Double) {
        switch game.phase {
        case .title: game.start(.a)
        case .flight:
            autoCooldown -= dt
            let flying = game.bugs.filter { if case .flying = $0.state { return true }; return false }
            guard let target = flying.min(by: { hypot($0.x - aim.x, $0.y - aim.y) < hypot($1.x - aim.x, $1.y - aim.y) })
            else { return }
            let wobble = sin(game.clock * 5.3) * 14
            let tx = target.x + wobble, ty = target.y + cos(game.clock * 4.1) * 8
            let d = hypot(tx - aim.x, ty - aim.y)
            let step = min(d, 330 * dt)
            if d > 0 {
                aim.x += (tx - aim.x) / d * step
                aim.y += (ty - aim.y) / d * step
            }
            keyAim = true
            if d < 10, autoCooldown <= 0, game.flightClock > 1.4 {
                autoCooldown = 0.5
                shoot(at: aim)
            }
        default: break
        }
    }

    // MARK: - Input

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 124, 125, 126:
            keys.insert(event.keyCode)
            keyAim = true
        case 49:                                         // Space
            if paused { onWantsKeys?(); resume() }
            else if game.phase == .title { begin(.a) }
            else if case .intro = game.phase { game.skipIntro() }
            else { shoot(at: aim) }
        case 18: if game.phase == .title { begin(.a) }   // 1
        case 19: if game.phase == .title { begin(.b) }   // 2
        case 36, 76:                                     // Return, Enter
            if game.phase == .over { newHigh = false; recorded = false; game.restart() }
        case 35:                                         // P
            if paused { resume() } else { pause() }
        case 53: onClose?()                              // Esc
        default: super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if [123, 124, 125, 126].contains(event.keyCode) { keys.remove(event.keyCode) } else { super.keyUp(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onClose?() }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if p.y > HuntGame.groundTop {
            aim = p
            keyAim = false
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if closeRect.contains(p) { onClose?(); return }
        onWantsKeys?()
        if paused { resume(); return }
        switch game.phase {
        case .title:
            if titleRect(.a).contains(p) { begin(.a) } else if titleRect(.b).contains(p) { begin(.b) }
        case .intro:
            game.skipIntro()
        case .flight where p.y > HuntGame.groundTop:
            aim = p
            keyAim = false
            shoot(at: p)
        default:
            break
        }
    }

    private func begin(_ mode: HuntGame.Mode) {
        newHigh = false
        recorded = false
        game.start(mode)
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .none
        let w = CGFloat(HuntGame.width), h = CGFloat(HuntGame.height)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.clip()

        ctx.setFillColor(PixelFont.color(game.skyAlarmed ? HuntGameArt.skyAlarmed : HuntGameArt.sky).cgColor)
        ctx.fill(bounds)
        if let tree = Self.tree { place(tree, x: 2, y: HuntGame.grassTop - 40, in: ctx) }

        drawBugs(ctx)
        drawDog(ctx, front: false)
        drawGrass(ctx)
        drawDog(ctx, front: true)
        for p in puffs {
            if let img = Self.puff { centre(img, at: CGPoint(x: p.x, y: p.y), in: ctx, scale: 1 + p.age * 3) }
        }
        drawBoard(ctx)
        if keyAim, game.phase == .flight { drawSight(ctx) }
        drawClose(ctx)
        drawOverlays(ctx, mid: w / 2, h: h)
        ctx.restoreGState()
    }

    private func drawBugs(_ ctx: CGContext) {
        for b in game.bugs {
            let p = CGPoint(x: b.x, y: b.y)
            switch b.state {
            case .flying, .escaping:
                let rate = b.state == .escaping ? 18.0 : 11.0
                let frame = [0, 1, 2, 1][Int(game.clock * rate) % 4]
                let set = b.vx < 0 && b.state != .escaping ? Self.flyLeft[b.kind] : Self.fly[b.kind]
                if let img = set?[frame] { centre(img, at: p, in: ctx) }
            case .hit:
                if let img = Self.front[b.kind] { centre(img, at: p, in: ctx) }
            case .falling:
                // Spinning on the way down: the picture flips side to side.
                if let img = Self.upsideDown[b.kind] {
                    let flip = Int(game.clock * 12) % 2 == 0
                    ctx.saveGState()
                    if flip {
                        ctx.translateBy(x: p.x * 2, y: 0)
                        ctx.scaleBy(x: -1, y: 1)
                    }
                    centre(img, at: p, in: ctx)
                    ctx.restoreGState()
                }
            case .gone:
                break
            }
        }
    }

    /// The dog: in front of the grass while he walks in, behind it when he pops up.
    private func drawDog(_ ctx: CGContext, front: Bool) {
        let grass = CGFloat(HuntGame.grassTop)
        switch game.phase {
        case .intro(let t):
            let walkEnd = 1.3, sniffEnd = 1.9
            let groundY = CGFloat(HuntGame.groundTop) + 6
            if t < walkEnd, front {
                let x = -30 + CGFloat(t / walkEnd) * 210
                if let img = Self.walk[safe: Int(t * 7) % 2] { bottom(img, x: x, y: groundY, in: ctx) }
            } else if t < sniffEnd, front {
                let bob = Int(t * 6) % 2 == 0 ? 0 : 2
                if let img = Self.sniff { bottom(img, x: 180, y: groundY - CGFloat(bob), in: ctx) }
            } else if t >= sniffEnd {
                // The jump: up in front of the grass, down behind it.
                let k = (t - sniffEnd) / (HuntGame.introTime - sniffEnd)
                let y = groundY + CGFloat(sin(k * .pi)) * 70 - CGFloat(max(0, k - 0.5)) * 80
                let falling = k > 0.5
                if falling != front, let img = Self.walk.first { bottom(img, x: 180 + CGFloat(k) * 30, y: y, in: ctx) }
            }
        case .retrieve(let t, let x, let kinds) where !front:
            let y = grass - 62 + popUp(t, length: HuntGame.retrieveTime) * 56
            guard let img = Self.hold[safe: kinds.count > 1 ? 1 : 0] else { return }
            bottom(img, x: CGFloat(x), y: y, in: ctx)
            // Held up by the raised paws (one, or both for two).
            let paws: [CGFloat] = kinds.count == 1 ? [38] : [-42, 34]
            for (i, k) in kinds.prefix(2).enumerated() {
                if let bug = Self.held[k] { bottom(bug, x: CGFloat(x) + paws[i], y: y + 54, in: ctx) }
            }
        case .laugh(let t) where !front:
            let y = grass - 62 + popUp(t, length: HuntGame.laughTime) * 54
            let frame = Int(t * 8) % 2
            if let img = Self.laugh[safe: frame] { bottom(img, x: CGFloat(HuntGame.width / 2), y: y + CGFloat(frame * 2), in: ctx) }
        case .over where !front:
            let frame = Int(game.clock * 8) % 2
            if let img = Self.laugh[safe: frame] { bottom(img, x: CGFloat(HuntGame.width / 2), y: grass - 8 + CGFloat(frame * 2), in: ctx) }
        default:
            break
        }
    }

    /// 0 → 1 → 0 over `length`: up quickly, hold, down quickly.
    private func popUp(_ t: Double, length: Double) -> CGFloat {
        let edge = 0.3
        if t < edge { return CGFloat(t / edge) }
        if t > length - edge { return CGFloat(max(0, (length - t) / edge)) }
        return 1
    }

    private func drawGrass(_ ctx: CGContext) {
        let top = CGFloat(HuntGame.grassTop)
        ctx.setFillColor(PixelFont.color(HuntGameArt.grass).cgColor)
        ctx.fill(CGRect(x: 0, y: CGFloat(HuntGame.groundTop), width: CGFloat(HuntGame.width), height: top - 20 - CGFloat(HuntGame.groundTop)))
        if let edge = Self.grassEdge {
            let tw = CGFloat(edge.width) / 2, th = CGFloat(edge.height) / 2
            var x: CGFloat = 0
            while x < CGFloat(HuntGame.width) {
                ctx.draw(edge, in: CGRect(x: x, y: top - th, width: tw, height: th))
                x += tw
            }
        }
        if let bush = Self.bush { place(bush, x: CGFloat(HuntGame.width) - 104, y: top - 14, in: ctx) }
    }

    private func drawBoard(_ ctx: CGContext) {
        let gt = CGFloat(HuntGame.groundTop)
        ctx.setFillColor(PixelFont.color(HuntGameArt.dirt).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(HuntGame.width), height: gt))
        ctx.setFillColor(PixelFont.color(HuntGameArt.dirtDark).cgColor)
        ctx.fill(CGRect(x: 0, y: gt - 3, width: CGFloat(HuntGame.width), height: 3))

        func box(_ r: CGRect) {
            ctx.setFillColor(NSColor(white: 0, alpha: 0.82).cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.fillPath()
        }
        let label = NSColor(srgbRed: 0.55, green: 0.85, blue: 0.35, alpha: 1)
        // Round and shells.
        box(CGRect(x: 8, y: 8, width: 76, height: 38))
        PixelFont.text(ctx, "R=\(game.round)", x: 14, y: 32, pixel: 2, color: label)
        for i in 0..<HuntGame.shotsPerFlight where i < game.shotsLeft {
            if let s = Self.shell { place(s, x: 16 + CGFloat(i) * 12, y: 12, in: ctx) }
        }
        PixelFont.text(ctx, "SHOT", x: 52, y: 14, pixel: 1.5, color: label)
        // The hit bar: sorted at the round's end, the hits to the left.
        box(CGRect(x: 92, y: 8, width: 222, height: 38))
        PixelFont.text(ctx, "HIT", x: 98, y: 32, pixel: 2, color: label)
        var shown = game.results
        var blinkHits = false
        if case .roundEnd(let t, _) = game.phase {
            if t > 0.6 { shown = shown.filter { $0 == .hit } + shown.filter { $0 != .hit } }
            blinkHits = t > 0.6 && Int(t * 6) % 2 == 0
        }
        let flightSlots = game.phase == .flight ? Set(game.slot..<(game.slot + game.mode.bugsPerFlight)) : []
        for (i, r) in shown.enumerated() {
            let x = 98 + CGFloat(i) * 21
            let blinkNow = flightSlots.contains(i) && Int(game.clock * 4) % 2 == 0
            if blinkNow { continue }
            let red = r == .hit && !(blinkHits)
            if let img = red ? Self.iconRed : Self.iconWhite { place(img, x: x, y: 13, in: ctx) }
        }
        // Under the bar: how many this round needs.
        ctx.setFillColor(PixelFont.color(0x6aa8ff).cgColor)
        for i in 0..<HuntGame.needed(round: game.round) {
            ctx.fill(CGRect(x: 98 + CGFloat(i) * 21, y: 10, width: 14, height: 2))
        }
        // The score.
        box(CGRect(x: 322, y: 8, width: 102, height: 38))
        let digits = String(format: "%06d", min(game.score, 999_999))
        PixelFont.text(ctx, digits, x: 330, y: 28, pixel: 2.5, color: .white)
        PixelFont.text(ctx, "SCORE", x: 330, y: 13, pixel: 1.5, color: label)
    }

    private func drawSight(_ ctx: CGContext) {
        ctx.setFillColor(NSColor.white.cgColor)
        let x = aim.x.rounded(), y = aim.y.rounded()
        for (dx, dy, w, h) in [(-11.0, -1.0, 7.0, 2.0), (4.0, -1.0, 7.0, 2.0), (-1.0, -11.0, 2.0, 7.0), (-1.0, 4.0, 2.0, 7.0)] {
            ctx.fill(CGRect(x: x + dx, y: y + dy, width: w, height: h))
        }
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: CGRect(x: x - 8, y: y - 8, width: 16, height: 16))
    }

    private func drawClose(_ ctx: CGContext) {
        let r = closeRect
        ctx.setFillColor(NSColor(white: 0, alpha: 0.45).cgColor)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.fillPath()
        PixelFont.banner(ctx, "CLOSE", y: r.midY - 4, pixel: 1.5, color: .white, mid: r.midX)
    }

    private func panel(_ ctx: CGContext, _ r: CGRect) {
        ctx.setFillColor(NSColor(white: 0, alpha: 0.78).cgColor)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()
    }

    private func drawOverlays(_ ctx: CGContext, mid: CGFloat, h: CGFloat) {
        let amber = PixelFont.color(0xf5c542), orange = PixelFont.color(0xd77757)
        let dim = NSColor(white: 0.7, alpha: 1)
        switch game.phase {
        case .title:
            panel(ctx, CGRect(x: 56, y: 140, width: 320, height: 250))
            PixelFont.banner(ctx, "BUG HUNT", y: 340, pixel: 5, color: orange, mid: mid)
            for mode in HuntGame.Mode.allCases {
                let r = titleRect(mode)
                let label = mode == .a ? "GAME A  1 BUG" : "GAME B  2 BUGS"
                PixelFont.banner(ctx, label, y: r.midY - 5, pixel: 2.5, color: .white, mid: mid)
            }
            let topA = HuntGame.Prefs.highScore(.a, defaults), topB = HuntGame.Prefs.highScore(.b, defaults)
            PixelFont.banner(ctx, "TOP SCORE A=\(topA)  B=\(topB)", y: 184, pixel: 1.5, color: PixelFont.color(0x8fd14f), mid: mid)
            PixelFont.banner(ctx, "CLICK A GAME OR PRESS 1 OR 2", y: 160, pixel: 1.5, color: dim, mid: mid)
        case .banner:
            panel(ctx, CGRect(x: mid - 80, y: 270, width: 160, height: 56))
            PixelFont.banner(ctx, "ROUND", y: 304, pixel: 2.5, color: .white, mid: mid)
            PixelFont.banner(ctx, "\(game.round)", y: 280, pixel: 3, color: amber, mid: mid)
        case .flight where game.skyAlarmed:
            panel(ctx, CGRect(x: mid - 80, y: 280, width: 160, height: 34))
            PixelFont.banner(ctx, "FLY AWAY", y: 292, pixel: 2.5, color: .white, mid: mid)
        case .perfect:
            panel(ctx, CGRect(x: mid - 110, y: 260, width: 220, height: 66))
            PixelFont.banner(ctx, "PERFECT!!", y: 300, pixel: 3, color: amber, mid: mid)
            PixelFont.banner(ctx, "\(HuntGame.perfectBonus(round: game.round))", y: 272, pixel: 2.5, color: .white, mid: mid)
        case .over:
            panel(ctx, CGRect(x: mid - 120, y: 220, width: 240, height: 140))
            PixelFont.banner(ctx, "GAME OVER", y: 326, pixel: 3, color: PixelFont.color(0xe5534b), mid: mid)
            PixelFont.banner(ctx, "\(game.score)", y: 298, pixel: 2.5, color: .white, mid: mid)
            if newHigh { PixelFont.banner(ctx, "NEW HIGH SCORE!", y: 274, pixel: 2, color: amber, mid: mid) }
            PixelFont.banner(ctx, "RETURN PLAY AGAIN", y: 248, pixel: 1.5, color: dim, mid: mid)
            PixelFont.banner(ctx, "ESC CLOSE", y: 232, pixel: 1.5, color: dim, mid: mid)
        default:
            break
        }
        if paused {
            ctx.setFillColor(NSColor(white: 0, alpha: 0.55).cgColor)
            ctx.fill(bounds)
            PixelFont.banner(ctx, "PAUSED", y: h * 0.5, pixel: 3, color: .white, mid: mid)
            PixelFont.banner(ctx, "CLICK OR SPACE TO PLAY", y: h * 0.5 - 26, pixel: 1.5, color: dim, mid: mid)
        }
    }

    // MARK: - Pieces

    /// Images are 2× device pixels: drawn at half their pixel size in points.
    private func centre(_ img: CGImage, at p: CGPoint, in ctx: CGContext, scale: CGFloat = 1) {
        let w = CGFloat(img.width) / 2 * scale, h = CGFloat(img.height) / 2 * scale
        ctx.draw(img, in: CGRect(x: (p.x - w / 2).rounded(), y: (p.y - h / 2).rounded(), width: w, height: h))
    }

    private func bottom(_ img: CGImage, x: CGFloat, y: CGFloat, in ctx: CGContext) {
        let w = CGFloat(img.width) / 2, h = CGFloat(img.height) / 2
        ctx.draw(img, in: CGRect(x: (x - w / 2).rounded(), y: y.rounded(), width: w, height: h))
    }

    private func place(_ img: CGImage, x: CGFloat, y: CGFloat, in ctx: CGContext) {
        ctx.draw(img, in: CGRect(x: x, y: y, width: CGFloat(img.width) / 2, height: CGFloat(img.height) / 2))
    }

    // MARK: - Looking at it without a panel

    /// Six moments side by side — the title, the dog's walk-in, a flight, a hit,
    /// the dog holding the catch, a fly-away laugh — and game over, drawn offscreen:
    /// `AgentBar --render-hunt-game out.png`.
    static func renderForVerification(to url: URL) -> Bool {
        guard let d = UserDefaults(suiteName: "agentbar-hunt-render-\(getpid())") else { return false }
        defer { d.removePersistentDomain(forName: "agentbar-hunt-render-\(getpid())") }
        func view(_ setup: (HuntGameView) -> Void) -> HuntGameView {
            let v = HuntGameView(defaults: d)
            v.game = HuntGame(seed: 7)
            setup(v)
            return v
        }
        func run(_ v: HuntGameView, until done: (HuntGame) -> Bool, limit: Double = 60) {
            var t = 0.0
            while !done(v.game), t < limit {
                v.autopilot(dt: 1.0 / 60)
                v.advance(dt: 1.0 / 60)
                t += 1.0 / 60
            }
        }
        let shots: [HuntGameView] = [
            view { _ in },
            view { v in v.game.start(.a); for _ in 0..<50 { v.advance(dt: 1.0 / 60) } },
            view { v in v.game.start(.b); run(v, until: { $0.phase == .flight && $0.flightClock > 0.9 }) },
            view { v in
                v.game.start(.a)
                run(v, until: { $0.phase == .flight && $0.flightClock > 0.7 })
                if let b = v.game.bugs.first { v.game.shoot(x: b.x, y: b.y) }
                v.advance(dt: 0.2)
            },
            view { v in run(v, until: { if case .retrieve(let t, _, _) = $0.phase { return t > 0.6 }; return false }) },
            view { v in
                v.game.start(.a)
                run(v, until: { $0.phase == .flight && $0.flightClock > 0.5 })
                for _ in 0..<3 { v.game.shoot(x: 1, y: 460) }
                v.advance(dt: 0.4)
            },
            view { v in v.game.start(.a); v.game.score = 12_400; v.game.phase = .over; v.newHigh = true },
        ]
        let gap: CGFloat = 16
        let total = NSSize(width: (size.width + gap) * CGFloat(shots.count) - gap, height: size.height)
        let image = NSImage(size: total)
        image.lockFocus()
        NSColor.black.setFill()
        NSRect(origin: .zero, size: total).fill()
        for (i, v) in shots.enumerated() {
            v.keyAim = true
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            rep.draw(in: NSRect(x: CGFloat(i) * (size.width + gap), y: 0, width: size.width, height: size.height))
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?
            .representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
