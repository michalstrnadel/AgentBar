import Cocoa

/// The break game on screen: draws `BreakGame`, feeds it the keys, and runs its clock
/// — only while it is being played. Paused, closed or yielded, nothing ticks.
///
/// Left, the playfield; right, a narrow column with the score, the best, the wave,
/// the ships left, the tokens caught, and how to play. Everything is pixels from
/// `BreakGameArt`, drawn without smoothing.
final class BreakGameView: NSView, IslandGame {
    static let size = NSSize(width: 432, height: BreakGame.height)
    static let fieldWidth = CGFloat(BreakGame.width)
    static let columnX = fieldWidth + 14

    var game = BreakGame(seed: UInt64(Date().timeIntervalSince1970 * 1000))
    /// Paused by a click elsewhere, by `P`, or because work came in.
    var paused = false
    private var timer: Timer?
    private var last: CFTimeInterval = 0
    var left = false, right = false
    var newHigh = false
    private var recorded = false
    private let defaults: UserDefaults

    /// Esc, or the column's Close: the island takes it from here.
    var onClose: (() -> Void)?
    /// The view was clicked while paused: it wants the keyboard back.
    var onWantsKeys: (() -> Void)?

    private static let ship = BreakGameArt.image(BreakGameArt.ship, pixel: 2)
    private static let lifeShip = BreakGameArt.image(BreakGameArt.ship, pixel: 1)
    private static let bugs: [BreakGame.Kind: [CGImage]] = BreakGameArt.bugs.mapValues {
        $0.compactMap { BreakGameArt.image($0, pixel: 2) }
    }
    private static let bursts = BreakGameArt.burst.compactMap { BreakGameArt.image($0, pixel: 3) }
    private static let token = BreakGameArt.image(BreakGameArt.token, pixel: 1.5)
    /// Fixed once: the same sky every game, drifting unless motion is reduced.
    private static let stars: [(x: CGFloat, y: CGFloat, b: CGFloat)] = {
        var r = SplitMix64(seed: 7)
        return (0..<46).map { _ in
            (CGFloat(r.unit()) * fieldWidth, CGFloat(r.unit() * BreakGame.height), 0.25 + CGFloat(r.unit()) * 0.6)
        }
    }()

    static let demo = UserDefaults.standard.bool(forKey: "breakGameDemo")

    private var closeRect: NSRect { NSRect(x: Self.columnX, y: 10, width: 96, height: 22) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Space Bugs: a small shooting game. Arrows move, Space fires, Escape closes.")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { Self.size }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    var score: Int { game.score }

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
        guard !paused, !Self.demo else { return }
        paused = true
        left = false; right = false
        game.input = .init()
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
        let dt = now - last
        last = now
        if Self.demo { autopilot() }
        game.input = .init(left: left, right: right)
        let ev = game.step(dt: dt)
        if ev.gameOver, !recorded {
            recorded = true
            newHigh = BreakGame.Prefs.record(game.score, defaults)
            SoundCenter.shared.playGame(.over)
        } else if ev.lostLife {
            SoundCenter.shared.playGame(.lost)
        } else if ev.token {
            SoundCenter.shared.playGame(.token)
        } else if ev.hits > 0 {
            SoundCenter.shared.playGame(.hit)
        }
        needsDisplay = true
    }

    /// `breakGameDemo`, and the offscreen render: the game plays itself, so nobody
    /// has to send keys into a session — or put a panel over a working screen — to
    /// see it played.
    func autopilot() {
        if game.phase == .ready { game.fire() }
        let target = game.enemies.min { abs($0.x - game.playerX) < abs($1.x - game.playerX) }?.x ?? game.playerX
        left = target < game.playerX - 4
        right = target > game.playerX + 4
        if Int(game.clock * 10) % 3 == 0 { game.fire() }
    }

    /// Four moments side by side — the title, play, paused, game over — drawn
    /// offscreen: `AgentBar --render-break-game out.png`. No window, no keys.
    static func renderForVerification(to url: URL) -> Bool {
        guard let d = UserDefaults(suiteName: "agentbar-break-render-\(getpid())") else { return false }
        defer { d.removePersistentDomain(forName: "agentbar-break-render-\(getpid())") }
        func view(_ setup: (BreakGameView) -> Void) -> BreakGameView {
            let v = BreakGameView(defaults: d)
            v.game = BreakGame(seed: 42)
            setup(v)
            return v
        }
        func run(_ v: BreakGameView, seconds: Double) {
            for _ in 0..<Int(seconds * 60) {
                v.autopilot()
                v.game.input = .init(left: v.left, right: v.right)
                v.game.step(dt: 1.0 / 60)
            }
        }
        let shots = [
            view { _ in },
            view { run($0, seconds: 7) },
            view { run($0, seconds: 4); $0.paused = true },
            view { run($0, seconds: 3); $0.game.score = 4_370; $0.game.phase = .over; $0.newHigh = true },
        ]
        let gap: CGFloat = 16
        let total = NSSize(width: (size.width + gap) * CGFloat(shots.count) - gap, height: size.height)
        let image = NSImage(size: total)
        image.lockFocus()
        NSColor.black.setFill()
        NSRect(origin: .zero, size: total).fill()
        for (i, v) in shots.enumerated() {
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            rep.draw(in: NSRect(x: CGFloat(i) * (size.width + gap), y: 0, width: size.width, height: size.height))
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?
            .representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    // MARK: - Keys

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 0: left = true                       // ←, A
        case 124, 2: right = true                      // →, D
        case 49:                                       // Space
            if paused { onWantsKeys?(); resume() } else { game.fire() }
        case 36, 76:                                   // Return, Enter
            if game.phase == .over { newHigh = false; recorded = false; game.restart() }
        case 35:                                       // P
            if paused { resume() } else { pause() }
        case 53: onClose?()                            // Esc
        default: super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        switch event.keyCode {
        case 123, 0: left = false
        case 124, 2: right = false
        default: super.keyUp(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onClose?() }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if closeRect.contains(p) { onClose?(); return }
        onWantsKeys?()
        if paused { resume() }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .none
        // Its own black, not the island's: the column must read the same wherever
        // the view is drawn, offscreen included.
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(bounds)
        drawField(ctx)
        drawColumn(ctx)
    }

    private func drawField(_ ctx: CGContext) {
        let field = CGRect(x: 0, y: 0, width: Self.fieldWidth, height: CGFloat(BreakGame.height))
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: field, cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.clip()
        ctx.setFillColor(NSColor(white: 0.02, alpha: 1).cgColor)
        ctx.fill(field)

        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let drift = still ? 0 : CGFloat(game.clock * 18)
        for s in Self.stars {
            let y = (s.y - drift).truncatingRemainder(dividingBy: field.height)
            ctx.setFillColor(NSColor(white: 1, alpha: s.b).cgColor)
            ctx.fill(CGRect(x: s.x, y: y < 0 ? y + field.height : y, width: 1, height: 1))
        }

        let beat = Int(game.clock * 2.5) % 2
        for e in game.enemies {
            guard let frames = Self.bugs[e.kind], !frames.isEmpty else { continue }
            draw(frames[beat % frames.count], centeredAt: CGPoint(x: e.x, y: e.y), in: ctx)
        }
        for t in game.droppedTokens {
            if let img = Self.token { draw(img, centeredAt: CGPoint(x: t.x, y: t.y), in: ctx) }
        }
        ctx.setFillColor(Self.color(0xf5c542).cgColor)
        for s in game.shots {
            ctx.fill(CGRect(x: s.x - 1, y: s.y - 4, width: 2, height: 8))
        }
        ctx.setFillColor(Self.color(0xe5534b).cgColor)
        for s in game.enemyShots {
            ctx.fill(CGRect(x: s.x - 1, y: s.y - 4, width: 2, height: 8))
        }
        // Blinking while shielded, gone while it comes back.
        let blinkOff = game.shield > 0 && Int(game.shield * 8) % 2 == 0
        if game.respawn == 0, game.phase != .over, !blinkOff, let ship = Self.ship {
            draw(ship, centeredAt: CGPoint(x: game.playerX, y: BreakGame.playerY), in: ctx)
        }
        for b in game.bursts where !Self.bursts.isEmpty {
            let img = Self.bursts[min(b.age < 0.2 ? 0 : 1, Self.bursts.count - 1)]
            draw(img, centeredAt: CGPoint(x: b.x, y: b.y), in: ctx, scale: b.big ? 1.5 : 1)
        }
        ctx.restoreGState()

        let mid = Self.fieldWidth / 2
        let h = CGFloat(BreakGame.height)
        switch game.phase {
        case .ready:
            banner(ctx, "SPACE BUGS", y: h * 0.42, pixel: 3, color: Self.color(0xd77757), mid: mid)
            banner(ctx, "SPACE TO START", y: h * 0.42 - 28, pixel: 2, color: .white, mid: mid)
        case .intro:
            banner(ctx, "WAVE \(game.wave)", y: h * 0.42, pixel: 3, color: Self.color(0xf5c542), mid: mid)
        case .over:
            banner(ctx, "GAME OVER", y: h * 0.5, pixel: 3, color: Self.color(0xe5534b), mid: mid)
            banner(ctx, "\(game.score)", y: h * 0.5 - 28, pixel: 2, color: .white, mid: mid)
            if newHigh {
                banner(ctx, "NEW HIGH SCORE!", y: h * 0.5 - 50, pixel: 2, color: Self.color(0xf5c542), mid: mid)
            }
            banner(ctx, "RETURN PLAY AGAIN", y: h * 0.5 - 80, pixel: 1.5, color: NSColor(white: 0.6, alpha: 1), mid: mid)
            banner(ctx, "ESC CLOSE", y: h * 0.5 - 96, pixel: 1.5, color: NSColor(white: 0.6, alpha: 1), mid: mid)
        case .playing:
            break
        }
        if paused {
            ctx.setFillColor(NSColor(white: 0, alpha: 0.55).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: Self.fieldWidth, height: h))
            banner(ctx, "PAUSED", y: h * 0.5, pixel: 3, color: .white, mid: mid)
            banner(ctx, "CLICK OR SPACE TO PLAY", y: h * 0.5 - 26, pixel: 1.5,
                   color: NSColor(white: 0.7, alpha: 1), mid: mid)
        }
    }

    private func drawColumn(_ ctx: CGContext) {
        let x = Self.columnX
        var y = CGFloat(BreakGame.height) - 30
        let dim = NSColor(white: 0.5, alpha: 1)
        func stat(_ label: String, _ value: String, color: NSColor = .white) {
            text(ctx, label, x: x, y: y, pixel: 1.5, color: dim)
            y -= 22
            text(ctx, value, x: x, y: y, pixel: 3, color: color)
            y -= 30
        }
        stat("SCORE", "\(game.score)", color: Self.color(0xf5c542))
        stat("HI", "\(max(BreakGame.Prefs.highScore(defaults), game.score))")
        stat("WAVE", "\(game.wave)")
        text(ctx, "SHIPS", x: x, y: y, pixel: 1.5, color: dim)
        y -= 18
        if let mini = Self.lifeShip {
            for i in 0..<max(game.lives, 0) {
                ctx.draw(mini, in: CGRect(x: x + CGFloat(i) * 16, y: y - 2, width: 11, height: 7))
            }
        }
        y -= 26
        stat("TOKENS", "\(game.tokens)", color: Self.color(0xf08a2b))

        var hy: CGFloat = 92
        for line in ["< > MOVE", "SPACE FIRE", "P PAUSE", "ESC CLOSE"] {
            text(ctx, line, x: x, y: hy, pixel: 1.5, color: NSColor(white: 0.42, alpha: 1))
            hy -= 14
        }
        let r = closeRect
        ctx.setStrokeColor(NSColor(white: 0.35, alpha: 1).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.strokePath()
        let w = BreakGameArt.textWidth("CLOSE", pixel: 1.5)
        text(ctx, "CLOSE", x: r.midX - w / 2, y: r.midY - 4, pixel: 1.5, color: NSColor(white: 0.8, alpha: 1))
    }

    // MARK: - Pieces

    private func draw(_ img: CGImage, centeredAt p: CGPoint, in ctx: CGContext, scale: CGFloat = 1) {
        let w = CGFloat(img.width) / 2 * scale, h = CGFloat(img.height) / 2 * scale
        ctx.draw(img, in: CGRect(x: (p.x - w / 2).rounded(), y: (p.y - h / 2).rounded(), width: w, height: h))
    }

    private func banner(_ ctx: CGContext, _ s: String, y: CGFloat, pixel: CGFloat, color: NSColor, mid: CGFloat) {
        PixelFont.banner(ctx, s, y: y, pixel: pixel, color: color, mid: mid)
    }

    private func text(_ ctx: CGContext, _ s: String, x: CGFloat, y: CGFloat, pixel: CGFloat, color: NSColor) {
        PixelFont.text(ctx, s, x: x, y: y, pixel: pixel, color: color)
    }

    static func color(_ rgb: UInt32) -> NSColor { PixelFont.color(rgb) }
}
