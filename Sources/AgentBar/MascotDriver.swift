import Cocoa

/// Drives the mascot: picks which agent the bar should surface, animates its
/// sprite while work is happening, badges it when a session is waiting, and hops
/// once when a turn finishes. Surface-agnostic — it publishes a ready-to-draw
/// image (and Claude's current thinking verb) to any number of named sinks, so
/// the menu bar button and the island pill show the same mascot from one timer
/// instead of two copies of this state machine.
final class MascotDriver {
    /// Bare verb, e.g. "Mulling" — each surface formats it its own way.
    typealias Sink = (NSImage, String) -> Void

    private var sinks: [String: Sink] = [:]
    private var lastFrame: (image: NSImage, word: String)?

    private var sessions: [Session] = []
    private var systemColor = false

    private var animationTimer: Timer?
    private var wordTimer: Timer?
    private var hopTimer: Timer?
    /// When a session last worked or waited on the human; Clawd sleeps once
    /// this is `ClawdScene.sleepsAfter` old. Launch counts as busy, so a fresh
    /// start never opens on a sleeping crab.
    private var lastBusy = Date().timeIntervalSince1970
    private var sleepTimer: Timer?
    private var reel: MascotReel?
    /// Turns the reel's frame into the published image: as is for one agent,
    /// composed with the others' marks when several are live.
    private var draw: (NSImage) -> NSImage = { $0 }
    private var currentWord = ""
    private var previousTopState: Session.State?
    /// How fast the sessions are going: the working loop's frame rate follows it,
    /// and a session stalled while working stops walking (`Tempo`).
    private var tempo = Tempo()
    /// The frame rate the animation timer was started at, so a change of tempo
    /// re-times the loop in place rather than starting it over.
    private var timerFps = 0.0
    /// Until when a turn that just ended in an error shows Clawd sad, and the
    /// one-shot timer that puts him back at rest then.
    private var sadUntil: TimeInterval = 0
    private var sadTimer: Timer?

    private static let thinkingWords = [
        "Thinking", "Brewing", "Pondering", "Tinkering", "Cooking",
        "Weaving", "Scheming", "Crunching", "Sketching", "Mulling",
    ]

    /// Register (or, with nil, drop) a surface. A new sink is handed the current
    /// frame immediately so a just-shown island isn't blank until the next tick.
    func sink(_ name: String, _ body: Sink?) {
        sinks[name] = body
        if let body, let lastFrame { body(lastFrame.image, lastFrame.word) }
    }

    func update(sessions: [Session], systemColor: Bool) {
        self.sessions = sessions
        self.systemColor = systemColor
        tempo.observe(sessions.map { .init(id: $0.id, state: $0.state, label: $0.label) },
                      now: Date().timeIntervalSince1970)
        if sessions.contains(where: { $0.state.isWorking || $0.state.waitsOnHuman }) {
            lastBusy = Date().timeIntervalSince1970
        }
        render()
    }

    // MARK: - Publishing

    private var image: NSImage? { didSet { publish() } }
    private var word: String = "" { didSet { publish() } }

    private func publish() {
        guard let image else { return }
        lastFrame = (image, word)
        for sink in sinks.values { sink(image, word) }
    }

    // MARK: - Rendering

    private var topSession: Session? { sessions.first }

    /// One entry per agent with a live session, most urgent first. Sessions are
    /// already sorted by (priority, recency), so the first session seen for an
    /// agent is that agent's most urgent one.
    private var agentRow: [(agent: Agent, state: Session.State)] {
        var seen = Set<String>()
        var row: [(Agent, Session.State)] = []
        for s in sessions where seen.insert(s.agentID).inserted {
            row.append((s.agent, s.state))
        }
        return row
    }

    private func render() {
        let row = agentRow
        if row.count > 1 { return renderMulti(row) }
        let agent = topSession?.agent ?? Agent.byID("claude")
        let sprite = IconRenderer.shared.sprite(for: agent)
        let resting = systemColor ? sprite.restingTemplate : sprite.restingColor
        let state = topSession?.state
        defer { previousTopState = state }

        switch state {
        case .some(let s) where s.isWorking:
            stopHop(); stopSleep(); stopSad()
            // Redrawn even when the reel carries on: coming back from several
            // agents to one, the image on screen is still the composed one.
            play(reel(for: agent, sprite: sprite), fps: sprite.fps * pace(of: topSession), redraw: true)
            // Rotating verbs are Clawd's voice; other agents' dot clusters carry
            // the "working" signal on their own. A fixed word (compacting) is not
            // a mood but a fact, so it holds still and shows for any agent. The id
            // check is exact on purpose: an id AgentBar does not know is a generic
            // agent now, never Claude, so it bobs its monogram and says nothing.
            if let fixed = Self.fixedWord(for: topSession) {
                stopWords(); word = fixed
            } else if agent.id == "claude" { startWords() } else { stopWords() }
        case .permission, .question:
            stopHop(); stopWords(); stopSleep(); stopSad()
            // Clawd raises a hand with the "!" or "?" in the badge's colour,
            // in place of the badge; everyone else wears the dot.
            let scene: ClawdScene = state == .permission ? .approve : .ask
            if let loop = sprite.scenes[scene] {
                let frames = systemColor ? loop.template : loop.color
                play(MascotReel(key: "\(agent.id) \(scene) \(systemColor)", frames: frames), fps: sprite.fps)
            } else {
                stopAnimation()
                image = IconRenderer.withPermissionDot(
                    resting, color: state == .permission ? IconRenderer.amberDot : IconRenderer.questionDot)
            }
        case .error:
            // Marked, not celebrated: the same dot the waiting states use, in
            // the failure colour, and never the finish hop.
            // A turn that was working a moment ago shows Clawd sad for
            // `ClawdScene.sadFor` first — a still picture, held, then rest.
            stopHop(); stopAnimation(); stopWords(); stopSleep()
            let now = Date().timeIntervalSince1970
            if previousTopState?.isWorking == true, sprite.scenes[.sad]?.still != nil {
                stopSad()
                sadUntil = now + ClawdScene.sadFor
                sadTimer = Timer.scheduledTimer(withTimeInterval: ClawdScene.sadFor, repeats: false) { [weak self] _ in
                    self?.sadTimer = nil
                    self?.render()
                }
            }
            var mark = resting
            if now < sadUntil, let still = sprite.scenes[.sad]?.still {
                mark = systemColor ? still.template : still.color
            }
            image = IconRenderer.withPermissionDot(mark, color: .systemRed)
        default:
            stopSad()
            stopAnimation()
            stopWords()
            // A task just finished → a brief celebratory hop, then settle to calm.
            // decayed = a watchdog's guess, not a reported finish — no celebration
            // (SoundCenter skips its done cue on the same condition).
            // Reduce Motion skips it: a hop after every turn is exactly the motion
            // that setting asks to be spared.
            if state == .some(.done), previousTopState?.isWorking == true,
               topSession?.decayed != true,
               !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                playHop(resting: resting)
            } else if hopTimer == nil {
                image = restingOrAsleep(sprite: sprite, resting: resting)
            }
        }
    }

    /// Two or more agents live at once: their marks sit side by side, no words.
    /// Exactly one working agent animates — Claude wins (it has a real walk cycle),
    /// otherwise the most urgent working one. Everyone else shows the plain resting
    /// mark; a waiting session still carries its amber/blue dot.
    private func renderMulti(_ row: [(agent: Agent, state: Session.State)]) {
        stopHop(); stopWords(); stopSleep(); stopSad()
        defer { previousTopState = topSession?.state }
        let workingIDs = row.filter { $0.state.isWorking }.map(\.agent.id)
        let animatorID = workingIDs.contains("claude") ? "claude" : workingIDs.first
        let parts = row.map { (id: $0.agent.id,
                               sprite: IconRenderer.shared.sprite(for: $0.agent),
                               state: $0.state) }
        let sys = systemColor
        let build: (NSImage?) -> NSImage = { frame in
            IconRenderer.compose(parts.map { p in
                let resting = sys ? p.sprite.restingTemplate : p.sprite.restingColor
                switch p.state {
                case .permission:
                    return IconRenderer.withPermissionDot(resting)
                case .question:
                    return IconRenderer.withPermissionDot(resting, color: IconRenderer.questionDot)
                case let s where s.isWorking && p.id == animatorID:
                    return frame ?? resting
                default:
                    return resting
                }
            })
        }
        guard let animator = row.first(where: { $0.agent.id == animatorID }) else {
            stopAnimation()
            image = build(nil)
            return
        }
        let sprite = IconRenderer.shared.sprite(for: animator.agent)
        // Redrawn now, not at the next tick: a store tick may have put a dot on
        // someone else's mark.
        let pace = pace(of: sessions.first { $0.agentID == animator.agent.id })
        if !play(reel(for: animator.agent, sprite: sprite), fps: sprite.fps * pace, draw: build, redraw: true) {
            image = build(nil)
        }
    }

    /// The loop a working agent plays. Clawd's is a reel of scenes, re-chosen at
    /// the end of each from whatever his session is doing by then; everyone
    /// else's is their one loop.
    private func reel(for agent: Agent, sprite: IconRenderer.Sprite) -> MascotReel {
        let sys = systemColor
        guard !sprite.scenes.isEmpty else {
            let frames = sys ? sprite.templateFrames : sprite.colorFrames
            return MascotReel(key: frames.first.map { AnyHashable(ObjectIdentifier($0)) } ?? AnyHashable(agent.id),
                              frames: frames)
        }
        let pick: () -> [NSImage] = { [weak self] in
            let session = self?.sessions.first { $0.agentID == agent.id }
            let now = Date().timeIntervalSince1970
            let scene = session.map {
                ClawdScene.scene(for: $0, now: now, stalled: self?.tempo.stalled($0.id, now: now) ?? false)
            } ?? .walk
            guard let loop = sprite.scenes[scene] ?? sprite.scenes[.walk] else { return [] }
            return sys ? loop.template : loop.color
        }
        return MascotReel(key: "\(agent.id) scenes \(sys)", frames: pick(), next: pick)
    }

    /// Plays `candidate` unless a reel with the same key is already playing — then
    /// that one keeps its place. Every store tick lands here while a turn runs,
    /// several a second during tool calls, and starting over each time would
    /// replay the first frames forever.
    /// False when there was nothing to play, and so nothing was drawn.
    @discardableResult
    private func play(_ candidate: MascotReel, fps: Double,
                      draw: @escaping (NSImage) -> NSImage = { $0 }, redraw: Bool = false) -> Bool {
        self.draw = draw
        if animationTimer != nil, reel?.key == candidate.key {
            if redraw, let frame = reel?.current { image = draw(frame) }
            // The same loop at a new tempo: re-timed where it is, and only for a
            // change worth seeing — every store tick nudges the rate a little.
            if abs(fps / max(timerFps, 0.001) - 1) >= 0.1 { startTimer(fps: fps) }
            return true
        }
        stopAnimation()
        guard let first = candidate.current else { return false }
        reel = candidate
        image = draw(first)
        startTimer(fps: fps)
        return true
    }

    private func startTimer(fps: Double) {
        animationTimer?.invalidate()
        timerFps = fps
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / fps, repeats: true) { [weak self] _ in
            guard let self, let frame = self.reel?.advance() else { return }
            self.image = self.draw(frame)
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        reel = nil
    }

    /// The tempo a working session's loop plays at; 1 for anything else.
    private func pace(of session: Session?) -> Double {
        guard let session, session.state.isWorking else { return 1 }
        return tempo.multiplier(for: session.id, now: Date().timeIntervalSince1970)
    }

    private func stopSad() {
        sadTimer?.invalidate()
        sadTimer = nil
        sadUntil = 0
    }

    /// A word that says what the session is actually doing, in place of the
    /// rotating verbs. Nil means "rotate as usual".
    static func fixedWord(for session: Session?) -> String? {
        guard let session, session.isCompacting else { return nil }
        return "Compacting"
    }

    private func startWords() {
        guard wordTimer == nil else { return }
        rotateWord()
        wordTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.rotateWord()
        }
    }

    private func rotateWord() {
        currentWord = Self.thinkingWords.filter { $0 != currentWord }.randomElement() ?? "Thinking"
        word = currentWord
    }

    private func stopWords() {
        wordTimer?.invalidate()
        wordTimer = nil
        word = ""
    }

    /// One-shot "yay, done" hop: two small bounces over ~0.5s, then rest. Art-free —
    /// just redraws the resting mark at a vertical offset.
    private func playHop(resting: NSImage) {
        stopHop()
        let steps = 12
        var i = 0
        image = resting
        hopTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            guard let self else { return }
            if i >= steps { self.stopHop(); self.image = resting; return }
            let dy = abs(sin(Double(i) / Double(steps) * .pi * 2)) * 3.0  // two hops
            self.image = Self.offset(resting, dy: CGFloat(dy))
            i += 1
        }
    }

    /// Clawd at rest, or asleep once nothing has happened for a while. Asleep
    /// is a still picture here: the menu bar mark does not move at rest, and
    /// only the island, with the mascot's personality on, lets him breathe.
    /// Until then a one-shot timer waits for the moment, so he nods off even
    /// when no store tick arrives to say so.
    private func restingOrAsleep(sprite: IconRenderer.Sprite, resting: NSImage) -> NSImage {
        guard let still = sprite.scenes[.sleep]?.still else { return resting }
        let now = Date().timeIntervalSince1970
        if ClawdScene.asleep(lastBusy: lastBusy, now: now) {
            stopSleep()
            return systemColor ? still.template : still.color
        }
        if sleepTimer == nil {
            let wait = lastBusy + ClawdScene.sleepsAfter - now
            sleepTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
                self?.sleepTimer = nil
                self?.render()
            }
        }
        return resting
    }

    private func stopSleep() {
        sleepTimer?.invalidate()
        sleepTimer = nil
    }

    private func stopHop() {
        hopTimer?.invalidate()
        hopTimer = nil
    }

    /// Copy of a mark drawn shifted up by `dy` points (top clips a hair; fine for a hop).
    private static func offset(_ img: NSImage, dy: CGFloat) -> NSImage {
        let out = NSImage(size: img.size)
        out.lockFocus()
        img.draw(at: NSPoint(x: 0, y: dy), from: .zero, operation: .sourceOver, fraction: 1)
        out.unlockFocus()
        out.isTemplate = img.isTemplate
        return out
    }
}
