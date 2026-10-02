import Cocoa
import QuartzCore

/// The island's mascot with a little life in it: Clawd's eyes follow the pointer
/// and blink, a mark in the open panel reacts when it is clicked, and a long task
/// finishing gets a sparkle in the pill. Island-only by construction — it decorates
/// the frames `MascotDriver` hands the island's sink and owns the island's mark
/// views; the menu bar's sink never passes through here (CLAUDE.md, rule 2).
///
/// It keeps no timer running. The gaze and the blink ride the controller's existing
/// 0.12 s pointer poll and do nothing but compare numbers when there is nothing to
/// draw; the squish, the dizzy beat and the sparkle are Core Animation, played by
/// the render server and gone when they finish. The one timer is the launch hello's,
/// about a second long, once per launch, invalidated when the wave ends. The
/// decisions are `MascotPersonality`'s.
final class IslandMascot {
    private var gaze = MascotPersonality.Gaze()
    private var blink = MascotPersonality.Blink(firstAt: CACurrentMediaTime() + 4)
    private var celebrations = MascotPersonality.Celebrations()
    private var pokes: [String: MascotPersonality.Pokes] = [:]
    private var pupil = MascotPersonality.Pupil.ahead
    private var closed = false
    /// Any session working means the walk cycle (or a dot cluster) owns the mark,
    /// and the walk's first frame IS the resting frame — decorating it would make
    /// the eyes jump once per stride.
    private var working = false
    /// Once per launch, not per controller: the island is stopped and started
    /// again when the presentation changes, and that is not a new launch.
    private static var greeting = MascotPersonality.Greeting()
    /// The wave frame on screen, while the hello plays; nil the rest of the time.
    private var waveStep: Int?
    private var waveTimer: Timer?

    static var plays: Bool {
        MascotPersonality.plays(enabled: MascotPersonality.Prefs.enabled,
                                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// Store tick. True when the pill should sparkle — the caller still decides
    /// whether the pill is there to do it.
    func observe(_ sessions: [Session]) -> Bool {
        working = sessions.contains { $0.state.isWorking }
        let live = Set(sessions.map(\.id))
        pokes = pokes.filter { live.contains($0.key) }
        // Observed whether or not it plays, so switching it on mid-turn measures
        // the turn from when it actually started.
        let fire = celebrations.observe(
            sessions.map { .init(id: $0.id, state: $0.state, decayed: $0.decayed) },
            now: CACurrentMediaTime())
        return fire && Self.plays
    }

    /// Pointer poll. `mark` is the pill's mark on screen, or nil when the pill is
    /// not showing it (hidden, open, flashing) — then the eyes rest. True when what
    /// the mark should look like changed and the pill has to be handed it again.
    func look(pointer: NSPoint, from mark: NSPoint?) -> Bool {
        let before = (pupil, closed)
        if let mark, Self.plays, !working, Crab.shared != nil {
            let now = CACurrentMediaTime()
            pupil = gaze.follow(dx: Double(pointer.x - mark.x), dy: Double(pointer.y - mark.y),
                                pointer: (Double(pointer.x), Double(pointer.y)), now: now)
            closed = blink.closed(at: now)
        } else {
            rest()
        }
        return before != (pupil, closed)
    }

    /// Eyes ahead and open, now — the pill is about to stop being the mascot's
    /// (a flash takes it over), and it should come back looking the way it left.
    func rest() {
        gaze.rest()
        pupil = .ahead
        closed = false
    }

    /// The frame the island should draw in place of `image`. Only Clawd's bare
    /// resting mark is ever changed; everything else — the walk, a badge dot, a
    /// hop's offset copy, the multi-agent row — passes through untouched.
    func decorate(_ image: NSImage?) -> NSImage? {
        guard let image, Self.plays, !working, let crab = Crab.shared,
              image === crab.color || image === crab.template
        else { return image }
        let template = image === crab.template
        // Mid-wave the wave owns the mark: the driver's frames and the pointer poll
        // both come through here, and either would put the resting frame back.
        if let step = waveStep, let frames = crab.wave(template: template),
           frames.indices.contains(step) {
            return frames[step]
        }
        guard pupil != .ahead || closed else { return image }
        return crab.variant(template: template, pupil: pupil, closed: closed)
    }

    // MARK: - Hello

    /// The launch's one chance at a hello — see `MascotPersonality.Greeting`. The
    /// caller says what the pill is doing; `mark` is what it shows, and only
    /// Clawd's bare resting mark waves. True when the wave started; `redraw` is
    /// called for each frame and once more when it is over, and from then on
    /// nothing is left running.
    @discardableResult
    func greet(pillVisible: Bool, collapsed: Bool, flashing: Bool, mark: NSImage?,
               redraw: @escaping () -> Void) -> Bool {
        let go = Self.greeting.consider(plays: Self.plays, pillVisible: pillVisible,
                                        collapsed: collapsed, flashing: flashing,
                                        working: working)
        guard go, waveTimer == nil, let crab = Crab.shared, let mark,
              mark === crab.color || mark === crab.template,
              let frames = crab.wave(template: mark === crab.template)
        else { return false }
        waveStep = 0
        redraw()
        waveTimer = Timer.scheduledTimer(withTimeInterval: MascotPersonality.Greeting.frameLength,
                                         repeats: true) { [weak self] timer in
            guard let self, let step = self.waveStep else { timer.invalidate(); return }
            if step + 1 < frames.count {
                self.waveStep = step + 1
            } else {
                self.endGreeting()
            }
            redraw()
        }
        return true
    }

    /// Stop a wave where it is — the island is going away.
    func endGreeting() {
        waveTimer?.invalidate()
        waveTimer = nil
        waveStep = nil
    }

    /// Wire a row's mark for pokes, and pick up a reaction that was still playing
    /// on the row this one replaces — rows are rebuilt on every store tick, which
    /// while an agent works is about once a second.
    func attach(_ view: IslandMascotView, session id: String) {
        guard Self.plays else { view.onPoke = nil; return }
        view.onPoke = { [weak self] in
            guard let self else { return nil }
            let now = CACurrentMediaTime()
            var p = self.pokes[id] ?? MascotPersonality.Pokes()
            let r = p.poke(at: now)
            self.pokes[id] = p
            return r
        }
        if let playing = pokes[id]?.current(at: CACurrentMediaTime()) {
            view.play(playing.reaction, elapsed: playing.elapsed)
        }
    }

    /// Clawd's two resting marks, where his eyes are, and every variant drawn so
    /// far. Nine pupils × open/shut × two colour modes is the most there can be.
    private final class Crab {
        static let shared: Crab? = Crab()

        let color: NSImage
        let template: NSImage
        private let eyes: MascotEyes.Eyes
        private let claw: MascotEyes.Claw?
        private var cache: [String: NSImage] = [:]
        private var waves: [Bool: [NSImage]] = [:]

        private init?() {
            let sprite = IconRenderer.shared.sprite(for: Agent.byID("claude"))
            guard let eyes = MascotEyes.find(in: sprite.restingColor) else { return nil }
            color = sprite.restingColor
            template = sprite.restingTemplate
            self.eyes = eyes
            // Searched on the colour frame and used for both: the template one is
            // the same ink at the same size.
            claw = MascotEyes.findClaw(in: color)
        }

        /// The hello, drawn once per colour mode. Nil when no claw was found —
        /// then there is no wave, and nothing else changes.
        func wave(template: Bool) -> [NSImage]? {
            if let hit = waves[template] { return hit }
            guard let claw,
                  let frames = MascotEyes.waveFrames(of: template ? self.template : color, claw: claw)
            else { return nil }
            waves[template] = frames
            return frames
        }

        func variant(template: Bool, pupil: MascotPersonality.Pupil, closed: Bool) -> NSImage {
            let key = "\(template)|\(pupil.dx)|\(pupil.dy)|\(closed)"
            if let hit = cache[key] { return hit }
            let out = MascotEyes.redraw(template ? self.template : color, eyes: eyes,
                                        pupil: pupil, closed: closed)
            cache[key] = out
            return out
        }
    }
}

/// A mark on the island that can move without being redrawn: the image sits in a
/// layer of its own, anchored at its feet, so a squish squashes towards the floor
/// and a wobble rocks on it. Stands in for the `NSImageView` the pill and the rows
/// used, and draws exactly what that did when nothing is playing.
///
/// With `onPoke` set it takes the click for itself — the mark is something to
/// poke, not a second way to jump to the session, and the rest of the row still
/// jumps. Without it (personality off, Reduce Motion on) the click goes on to the
/// row as it always did.
final class IslandMascotView: NSView {
    var image: NSImage? {
        didSet {
            guard image !== oldValue else { return }
            if image?.size != oldValue?.size { invalidateIntrinsicContentSize() }
            refreshContents()
            needsLayout = true
        }
    }
    var onPoke: (() -> MascotPersonality.Pokes.Reaction?)?

    private let imageLayer = CALayer()
    /// A reaction handed over before this view had a frame — see `play`. Kept as
    /// the moment it started, so however long the first layout takes, it resumes
    /// at the right point rather than from wherever it was when it was handed in.
    private var pending: (reaction: MascotPersonality.Pokes.Reaction, since: CFTimeInterval)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageLayer.anchorPoint = CGPoint(x: 0.5, y: 0)
        // A squish stretches pixel art; stretched pixel art should stay pixels.
        imageLayer.magnificationFilter = .nearest
        layer?.addSublayer(imageLayer)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        image?.size ?? NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    /// On screen the view's own layer draws nothing — the image layer does it all,
    /// so it can move. `cacheDisplay` (the render harness, the feature GIFs) takes
    /// the drawing path instead and never sees sublayer contents, so that path
    /// draws the mark at rest, where `NSImageView` would have put it.
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let f = imageLayer.frame
        image.draw(in: NSRect(x: f.minX, y: f.minY, width: image.size.width,
                              height: image.size.height))
    }

    override func layout() {
        super.layout()
        let size = image?.size ?? .zero
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.bounds = CGRect(origin: .zero, size: size)
        // Centred like `NSImageView`'s `.scaleNone`, on whole points so a 1× screen
        // keeps the art sharp.
        imageLayer.position = CGPoint(x: ((bounds.width - size.width) / 2).rounded() + size.width / 2,
                                      y: ((bounds.height - size.height) / 2).rounded())
        CATransaction.commit()
        if let p = pending, !bounds.isEmpty {
            pending = nil
            let elapsed = CACurrentMediaTime() - p.since
            if elapsed < p.reaction.length { play(p.reaction, elapsed: elapsed) }
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshContents()
    }

    private var scale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func refreshContents() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let s = scale
        imageLayer.contentsScale = s
        imageLayer.contents = image?.layerContents(forContentsScale: s)
        CATransaction.commit()
    }

    // MARK: - Pokes

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if onPoke == nil { super.mouseDown(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let onPoke else { return super.mouseUp(with: event) }
        if let reaction = onPoke() { play(reaction, elapsed: 0) }
    }

    /// Start a reaction `elapsed` seconds in — 0 for a fresh poke, more for one
    /// carried over from the row this view replaced.
    ///
    /// A carried-over one arrives the moment the new row is built, before Auto
    /// Layout has given this view a size — and the dizzy stars are placed from
    /// where the image sits, which until the first `layout` is the origin. So a
    /// view with no frame yet holds the reaction and starts it from `layout`; a
    /// squish would survive either way, but a ring of stars round its feet would
    /// not.
    func play(_ reaction: MascotPersonality.Pokes.Reaction, elapsed: TimeInterval) {
        if bounds.isEmpty {
            pending = (reaction, CACurrentMediaTime() - elapsed)
            needsLayout = true
            return
        }
        let begin = imageLayer.convertTime(CACurrentMediaTime(), from: nil) - elapsed
        switch reaction {
        case .squish:
            let a = CAKeyframeAnimation(keyPath: "transform")
            a.values = [CATransform3DIdentity,
                        CATransform3DMakeScale(1.18, 0.78, 1),
                        CATransform3DMakeScale(0.9, 1.12, 1),
                        CATransform3DMakeScale(1.04, 0.97, 1),
                        CATransform3DIdentity].map { NSValue(caTransform3D: $0) }
            a.keyTimes = [0, 0.2, 0.5, 0.75, 1]
            a.duration = reaction.length
            a.beginTime = begin
            imageLayer.add(a, forKey: "poke")
        case .dizzy:
            let a = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            a.values = [0, 0.22, -0.22, 0.16, -0.16, 0.08, 0]
            a.duration = reaction.length
            a.beginTime = begin
            imageLayer.add(a, forKey: "poke")
            orbitStars(begin: begin, duration: reaction.length)
        }
    }

    /// Two little stars circling over its head — the cartoon's own shorthand for
    /// dizzy. A flattened ring, so the orbit reads as going round, not up and down.
    private func orbitStars(begin: CFTimeInterval, duration: CFTimeInterval) {
        guard let host = layer else { return }
        let mark = imageLayer.frame
        let ring = CALayer()
        ring.frame = CGRect(x: mark.midX - 8, y: mark.maxY - 1, width: 16, height: 16)
        ring.transform = CATransform3DMakeScale(1, 0.35, 1)
        let spinner = CALayer()
        spinner.frame = ring.bounds
        for dx: CGFloat in [-6, 6] {
            let star = Self.star(size: 4, color: NSColor(srgbRed: 1, green: 0.86, blue: 0.4, alpha: 1))
            star.position = CGPoint(x: ring.bounds.midX + dx, y: ring.bounds.midY)
            spinner.addSublayer(star)
        }
        ring.addSublayer(spinner)
        ring.opacity = 0
        host.addSublayer(ring)

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -CGFloat.pi * 4
        spin.duration = duration
        spin.beginTime = begin
        spinner.add(spin, forKey: "spin")
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.15, 0.75, 1]
        fade.duration = duration
        fade.beginTime = begin
        ring.add(fade, forKey: "fade")
        let left = max(0, begin + duration - ring.convertTime(CACurrentMediaTime(), from: nil))
        DispatchQueue.main.asyncAfter(deadline: .now() + left + 0.05) { ring.removeFromSuperlayer() }
    }

    // MARK: - Sparkle

    /// The finish, in the pill: a few stars blink up around the mark and are gone
    /// inside a second. No hop of its own — `MascotDriver` already hops the mark on
    /// every finish, and a second hop stacked on that one would jump it clean out
    /// of the pill.
    func celebrate() {
        guard let host = layer else { return }
        let mark = imageLayer.frame
        guard mark.width > 0 else { return }
        let now = host.convertTime(CACurrentMediaTime(), from: nil)
        // Around the head and shoulders, staggered so they read as twinkling
        // rather than as one flash.
        let spots: [(x: CGFloat, y: CGFloat, size: CGFloat, delay: CFTimeInterval)] = [
            (mark.minX - 3, mark.maxY - 2, 5, 0.00),
            (mark.maxX + 3, mark.maxY - 1, 6, 0.12),
            (mark.maxX + 5, mark.midY - 2, 4, 0.26),
            (mark.minX - 5, mark.midY - 3, 4, 0.38),
        ]
        let gold = NSColor(srgbRed: 1, green: 0.86, blue: 0.4, alpha: 1)
        let length: CFTimeInterval = 0.55
        var stars: [CALayer] = []
        for spot in spots {
            let star = Self.star(size: spot.size, color: gold)
            star.position = CGPoint(x: spot.x, y: spot.y)
            star.opacity = 0
            host.addSublayer(star)
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [0.2, 1.15, 0.5]
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0, 1, 0]
            let group = CAAnimationGroup()
            group.animations = [scale, opacity]
            group.duration = length
            group.beginTime = now + spot.delay
            star.add(group, forKey: "sparkle")
            stars.append(star)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            for star in stars { star.removeFromSuperlayer() }
        }
    }

    /// A four-pointed pixel-ish star: a plus whose arms taper, which at four to six
    /// points is what reads as a twinkle rather than a blob.
    private static func star(size: CGFloat, color: NSColor) -> CAShapeLayer {
        let r = size / 2, w = max(0.6, size / 6)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: r))
        path.addLine(to: CGPoint(x: w, y: w))
        path.addLine(to: CGPoint(x: r, y: 0))
        path.addLine(to: CGPoint(x: w, y: -w))
        path.addLine(to: CGPoint(x: 0, y: -r))
        path.addLine(to: CGPoint(x: -w, y: -w))
        path.addLine(to: CGPoint(x: -r, y: 0))
        path.addLine(to: CGPoint(x: -w, y: w))
        path.closeSubpath()
        let l = CAShapeLayer()
        l.path = path
        l.fillColor = color.cgColor
        l.bounds = CGRect(x: -r, y: -r, width: size, height: size)
        return l
    }
}
