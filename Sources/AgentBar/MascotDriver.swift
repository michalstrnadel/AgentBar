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
    private var frameIndex = 0
    private var currentWord = ""
    private var previousTopState: Session.State?

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
            row.append((Agent.byID(s.agentID), s.state))
        }
        return row
    }

    private func render() {
        let row = agentRow
        if row.count > 1 { return renderMulti(row) }
        let agent = Agent.byID(topSession?.agentID ?? "claude")
        let sprite = IconRenderer.shared.sprite(for: agent)
        let frames = systemColor ? sprite.templateFrames : sprite.colorFrames
        let resting = systemColor ? sprite.restingTemplate : sprite.restingColor
        let state = topSession?.state
        defer { previousTopState = state }

        switch state {
        case .some(let s) where s.isWorking:
            stopHop()
            startAnimation(frames: frames, fps: sprite.fps)
            // Rotating verbs are Clawd's voice; other agents' dot clusters carry
            // the "working" signal on their own.
            if agent.id == "claude" { startWords() } else { stopWords() }
        case .permission:
            stopHop(); stopAnimation(); stopWords()
            image = IconRenderer.withPermissionDot(resting)
        case .question:
            stopHop(); stopAnimation(); stopWords()
            image = IconRenderer.withPermissionDot(resting, color: IconRenderer.questionDot)
        case .error:
            // Marked, not celebrated: the same dot the waiting states use, in
            // the failure colour, and never the finish hop.
            stopHop(); stopAnimation(); stopWords()
            image = IconRenderer.withPermissionDot(resting, color: .systemRed)
        default:
            stopAnimation()
            stopWords()
            // A task just finished → a brief celebratory hop, then settle to calm.
            // decayed = a watchdog's guess, not a reported finish — no celebration
            // (SoundCenter skips its done cue on the same condition).
            if state == .some(.done), previousTopState?.isWorking == true,
               topSession?.decayed != true {
                playHop(resting: resting)
            } else if hopTimer == nil {
                image = resting
            }
        }
    }

    /// Two or more agents live at once: their marks sit side by side, no words.
    /// Exactly one working agent animates — Claude wins (it has a real walk cycle),
    /// otherwise the most urgent working one. Everyone else shows the plain resting
    /// mark; a waiting session still carries its amber/blue dot.
    private func renderMulti(_ row: [(agent: Agent, state: Session.State)]) {
        stopHop(); stopWords()
        defer { previousTopState = topSession?.state }
        let workingIDs = row.filter { $0.state.isWorking }.map(\.agent.id)
        let animatorID = workingIDs.contains("claude") ? "claude" : workingIDs.first
        let parts = row.map { (id: $0.agent.id,
                               sprite: IconRenderer.shared.sprite(for: $0.agent),
                               state: $0.state) }
        let sys = systemColor
        let build: (Int) -> NSImage = { idx in
            IconRenderer.compose(parts.map { p in
                let resting = sys ? p.sprite.restingTemplate : p.sprite.restingColor
                switch p.state {
                case .permission:
                    return IconRenderer.withPermissionDot(resting)
                case .question:
                    return IconRenderer.withPermissionDot(resting, color: IconRenderer.questionDot)
                case let s where s.isWorking && p.id == animatorID:
                    let frames = sys ? p.sprite.templateFrames : p.sprite.colorFrames
                    return frames.isEmpty ? resting : frames[idx % frames.count]
                default:
                    return resting
                }
            })
        }
        stopAnimation()
        image = build(0)
        guard animatorID != nil else { return }
        frameIndex = 0
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.frameIndex += 1
            self.image = build(self.frameIndex)
        }
    }

    private func startAnimation(frames: [NSImage], fps: Double) {
        stopAnimation()
        guard !frames.isEmpty else { return }
        frameIndex = 0
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / fps, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.frameIndex = (self.frameIndex + 1) % frames.count
            self.image = frames[self.frameIndex]
        }
        image = frames[0]
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
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
