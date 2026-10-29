import Cocoa

/// The office on screen (`Office`): a small room drawn in pixels, a desk for each
/// session, Clawd at his in the pose he is in right now and every other agent's
/// mark at theirs, helpers on the floor beside the desk. It keeps no score; its
/// clock only turns the poses over, and only while it is looked at.
///
/// A click on a desk goes there — the terminal, or for a raised hand the island's
/// rows with that request in them (`onPick`, handled by the island). Esc and Close
/// close it, like a game.
final class OfficeView: NSView, IslandGame, NSViewToolTipOwner {
    static let size = NSSize(width: Office.size.width, height: Office.size.height)
    /// The reels' own rate: the island plays Clawd's scenes at it.
    static let fps = 12.5

    var score: Int { 0 }
    var onClose: (() -> Void)?
    var onWantsKeys: (() -> Void)?
    /// A desk was clicked: where it leads is `Office.target(for:)`.
    var onPick: ((Office.Target) -> Void)?

    private(set) var sessions: [Session] = []
    private(set) var requests: [ApprovalRequest] = []
    private(set) var layout = Office.Layout(desks: [], overflow: 0)
    private var timer: Timer?
    private var frame_ = 0
    private var paused = true
    private var hovered: String?
    private var tips: [NSView.ToolTipTag: String] = [:]
    /// What the tooltips were last built from: rebuilt only when it changes, so a
    /// tooltip on screen does not blink away on every store change.
    private var tipSource: [String] = []

    private var closeRect: NSRect {
        NSRect(x: Office.size.width - Office.margin - 96, y: 9, width: 96, height: 22)
    }

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        updateAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { Self.size }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    // MARK: - Who is in

    /// The island's sessions, in its order, and its requests — on every store change.
    func update(sessions: [Session], requests: [ApprovalRequest], now: TimeInterval = Date().timeIntervalSince1970) {
        self.sessions = sessions
        self.requests = requests
        layout = Office.layout(sessions, now: now)
        rebuildTips(now: now)
        updateAccessibility()
        needsDisplay = true
    }

    /// The session ids at a desk now.
    var seated: Set<String> { Set(layout.desks.map(\.sessionID)) }

    // MARK: - The clock

    func resume() {
        paused = false
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1 / Self.fps, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        needsDisplay = true
    }

    func pause() {
        paused = true
        timer?.invalidate()
        timer = nil
    }

    func stop() { pause() }

    private func tick() {
        // Reduce Motion: everyone holds still; the room still updates on change.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        frame_ &+= 1
        needsDisplay = true
    }

    /// For the offscreen render: a moment in the loop.
    func seek(frame: Int) { frame_ = frame; needsDisplay = true }

    // MARK: - Keys and clicks

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onClose?() }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if closeRect.contains(p) { onClose?(); return }
        if let desk = Office.desk(at: p, in: layout) {
            onPick?(Office.target(for: desk))
            return
        }
        onWantsKeys?()
        if paused { resume() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let id = Office.desk(at: convert(event.locationInWindow, from: nil), in: layout)?.sessionID
        if id != hovered { hovered = id; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil { hovered = nil; needsDisplay = true }
    }

    override func resetCursorRects() {
        for d in layout.desks { addCursorRect(d.rect, cursor: .pointingHand) }
        addCursorRect(closeRect, cursor: .pointingHand)
    }

    // MARK: - Words

    private func session(_ id: String) -> Session? { sessions.first { $0.id == id } }

    private func rebuildTips(now: TimeInterval) {
        var wanted: [(CGRect, String)] = []
        for d in layout.desks {
            guard let s = session(d.sessionID) else { continue }
            var tip = "\(s.project.isEmpty ? s.agent.name : s.project) · \(s.agent.name) — "
                + Office.stateWord(d, label: s.label)
            if d.handRaised {
                if let r = requests.first(where: { $0.sessionId == s.id }) { tip += "\n" + r.display }
                tip += "\nClick to see the request in the island."
            } else {
                tip += "\nClick to go to its terminal."
            }
            // The helpers first: the desk's own rect holds theirs.
            for (i, a) in s.subagentDetails.prefix(min(d.subagents, Self.helpersShown)).enumerated() {
                wanted.append((helperRect(d, i), SubagentLine.text(a, now: now)))
            }
            wanted.append((d.rect, tip))
        }
        let source = wanted.map { "\($0.0)\u{0}\($0.1)" }
        guard source != tipSource else { return }
        tipSource = source
        removeAllToolTips()
        tips = [:]
        for (rect, text) in wanted { tips[addToolTip(rect, owner: self, userData: nil)] = text }
        window?.invalidateCursorRects(for: self)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        tips[tag] ?? ""
    }

    private func updateAccessibility() {
        let desks = layout.desks.compactMap { d -> String? in
            guard let s = session(d.sessionID) else { return nil }
            return "\(s.project.isEmpty ? s.agent.name : s.project), \(s.agent.name), "
                + Office.stateWord(d, label: s.label)
        }
        var label = "Office: "
        label += desks.isEmpty ? "nobody is in." : "\(desks.count) desk\(desks.count == 1 ? "" : "s"). "
            + desks.joined(separator: "; ") + "."
        if layout.overflow > 0 { label += " \(layout.overflow) more without a desk." }
        label += " Click a desk to go to it. Escape closes."
        setAccessibilityLabel(label)
    }

    // MARK: - Drawing

    private static let ink = NSColor(white: 0.86, alpha: 1)
    private static let dim = NSColor(white: 0.46, alpha: 1)
    private static let amber = PixelFont.color(0xf5c542)
    private static let blue = PixelFont.color(0x8ab4f8)
    private static let red = PixelFont.color(0xe5534b)
    static let helpersShown = 2

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .none
        fill(ctx, bounds, 0x0f0f10)
        drawRoom(ctx)
        drawWall(ctx)
        if layout.desks.isEmpty {
            PixelFont.banner(ctx, "NOBODY IS IN", y: bounds.midY, pixel: 3, color: Self.dim, mid: bounds.midX)
        }
        for d in layout.desks { drawDesk(ctx, d) }
        drawFooter(ctx)
    }

    private func drawRoom(_ ctx: CGContext) {
        // The floor: dark boards, a seam every row.
        let floor = CGRect(x: 0, y: Office.footerHeight, width: bounds.width,
                           height: bounds.height - Office.wallHeight - Office.footerHeight)
        fill(ctx, floor, 0x17140f)
        for row in 0..<Office.rows {
            let y = Office.deskRect(row * Office.columns).minY
            fill(ctx, CGRect(x: 0, y: y, width: bounds.width, height: 1), 0x201b15)
        }
    }

    private func drawWall(_ ctx: CGContext) {
        let top = bounds.height
        let wall = CGRect(x: 0, y: top - Office.wallHeight, width: bounds.width, height: Office.wallHeight)
        fill(ctx, wall, 0x1b1e23)
        fill(ctx, CGRect(x: 0, y: wall.minY, width: bounds.width, height: 3), 0x2a2e35)
        PixelFont.text(ctx, "OFFICE", x: Office.margin + 2, y: top - 24, pixel: 3, color: Self.ink)
        PixelFont.text(ctx, headline(), x: Office.margin + 2, y: top - 40, pixel: 1.5, color: Self.dim)

        // A window: the sky outside follows the clock, dark after eight.
        let hour = Calendar.current.component(.hour, from: Date())
        let night = hour < 7 || hour >= 20
        let win = CGRect(x: 292, y: top - 42, width: 64, height: 32)
        fill(ctx, win, 0x3a3f47)
        let panes = win.insetBy(dx: 3, dy: 3)
        fill(ctx, panes, night ? 0x16203a : 0x5d7fa6)
        fill(ctx, CGRect(x: panes.midX - 1, y: panes.minY, width: 2, height: panes.height), 0x3a3f47)
        if night {
            for (x, y) in [(8, 18), (22, 8), (40, 20), (52, 10)] {
                fill(ctx, CGRect(x: panes.minX + CGFloat(x), y: panes.minY + CGFloat(y), width: 1, height: 1), 0xcfd6e0)
            }
        } else {
            fill(ctx, CGRect(x: panes.minX + 8, y: panes.minY + 16, width: 12, height: 3), 0xc9d6e6)
            fill(ctx, CGRect(x: panes.minX + 36, y: panes.minY + 8, width: 10, height: 3), 0xc9d6e6)
        }
        // A plant on the sill side of the room.
        let px = CGFloat(380), py = top - Office.wallHeight + 3
        fill(ctx, CGRect(x: px + 4, y: py, width: 14, height: 12), 0xa8763e)
        fill(ctx, CGRect(x: px + 3, y: py + 10, width: 16, height: 3), 0x8e6234)
        for (x, y, w, h) in [(9, 13, 3, 14), (4, 17, 5, 3), (2, 20, 4, 3), (12, 19, 5, 3), (16, 22, 4, 3),
                             (6, 24, 4, 3), (11, 27, 3, 3)] {
            fill(ctx, CGRect(x: px + CGFloat(x), y: py + CGFloat(y), width: CGFloat(w), height: CGFloat(h)), 0x4f8a4b)
        }
    }

    private func headline() -> String {
        let working = layout.desks.filter { $0.state.isWorking }.count
        let waiting = layout.desks.filter(\.handRaised).count
        var parts: [String] = []
        if working > 0 { parts.append("\(working) AT WORK") }
        if waiting > 0 { parts.append("\(waiting) WAITING ON YOU") }
        if parts.isEmpty, !layout.desks.isEmpty { parts.append("ALL QUIET") }
        if layout.overflow > 0 { parts.append("+\(layout.overflow) MORE") }
        return parts.joined(separator: " · ")
    }

    private func drawFooter(_ ctx: CGContext) {
        fill(ctx, CGRect(x: 0, y: 0, width: bounds.width, height: Office.footerHeight), 0x0f0f10)
        PixelFont.text(ctx, "CLICK A DESK TO GO THERE · ESC CLOSE", x: Office.margin + 2, y: 16, pixel: 1.5,
                       color: NSColor(white: 0.42, alpha: 1))
        let r = closeRect
        ctx.setStrokeColor(NSColor(white: 0.35, alpha: 1).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.strokePath()
        let w = PixelFont.width("CLOSE", pixel: 1.5)
        PixelFont.text(ctx, "CLOSE", x: r.midX - w / 2, y: r.midY - 4, pixel: 1.5, color: NSColor(white: 0.8, alpha: 1))
    }

    // MARK: - A desk

    /// Where the pieces of a desk sit, from its cell's bottom left.
    private enum Spot {
        static let seatX: CGFloat = 6, seatY: CGFloat = 30
        static let deskX: CGFloat = 76, deskW: CGFloat = 70, deskTop: CGFloat = 50
        static let helperX: CGFloat = 150
    }

    private func helperRect(_ d: Office.Desk, _ i: Int) -> CGRect {
        CGRect(x: d.rect.minX + Spot.helperX + CGFloat(i) * 24, y: d.rect.minY + Spot.seatY, width: 22, height: 12)
    }

    private func drawDesk(_ ctx: CGContext, _ d: Office.Desk) {
        let o = d.rect.origin
        if hovered == d.sessionID {
            fill(ctx, d.rect.insetBy(dx: 1, dy: 1), 0x1f1a14)
        }
        // A rug under the chair, the desk, its legs.
        fill(ctx, CGRect(x: o.x + 2, y: o.y + Spot.seatY - 3, width: d.rect.width - 4, height: 2), 0x231d16)
        let top = o.y + Spot.deskTop
        fill(ctx, CGRect(x: o.x + Spot.deskX, y: top, width: Spot.deskW, height: 4), 0x8a6844)
        fill(ctx, CGRect(x: o.x + Spot.deskX, y: top - 2, width: Spot.deskW, height: 2), 0x5e4430)
        fill(ctx, CGRect(x: o.x + Spot.deskX + 3, y: o.y + Spot.seatY - 1, width: 3, height: top - o.y - Spot.seatY - 1), 0x5e4430)
        fill(ctx, CGRect(x: o.x + Spot.deskX + Spot.deskW - 6, y: o.y + Spot.seatY - 1, width: 3,
                         height: top - o.y - Spot.seatY - 1), 0x5e4430)
        drawMonitor(ctx, d, x: o.x + Spot.deskX + 13, y: top + 4)
        drawSitter(ctx, d)
        drawHelpers(ctx, d)

        let s = session(d.sessionID)
        let name = (s?.project.isEmpty == false ? s!.project : (s?.agent.name ?? "")).uppercased()
        let maxChars = Int((d.rect.width - 10) / 8)
        PixelFont.text(ctx, String(name.prefix(maxChars)), x: o.x + Spot.seatX, y: o.y + 13, pixel: 2,
                       color: d.state.isFinished ? Self.dim : Self.ink)
        let word = Office.stateWord(d, label: s?.label ?? "").uppercased()
        let color: NSColor = d.state == .permission ? Self.amber : d.state == .question ? Self.blue
            : d.state == .error ? Self.red : Self.dim
        PixelFont.text(ctx, String(word.prefix(Int((d.rect.width - 10) / 6))), x: o.x + Spot.seatX, y: o.y + 3,
                       pixel: 1.5, color: color)
    }

    private func drawMonitor(_ ctx: CGContext, _ d: Office.Desk, x: CGFloat, y: CGFloat) {
        fill(ctx, CGRect(x: x + 19, y: y - 4, width: 6, height: 4), 0x3a3a3a)
        let body = CGRect(x: x, y: y, width: 44, height: 28)
        fill(ctx, body, 0x3a3a3a)
        let screen = body.insetBy(dx: 2, dy: 2)
        switch d.state {
        case .permission, .question:
            fill(ctx, screen, 0x241f12)
            let c: UInt32 = d.state == .permission ? 0xf5c542 : 0x8ab4f8
            PixelFont.banner(ctx, d.state == .permission ? "!" : "?", y: screen.midY - 5, pixel: 2,
                             color: PixelFont.color(c), mid: screen.midX)
        case .thinking, .tool:
            fill(ctx, screen, 0x15232b)
            // Lines of code going in, one more character at a time.
            let seed = d.sessionID.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
            let widths = [22, 14, 30, 18, 26, 10, 24]
            let colors: [UInt32] = [0x7fb2a0, 0x8ab4f8, 0xd8d8d8, 0xd77757]
            let typed = frame_ / 2
            for line in 0..<5 {
                let n = (typed / 12 + line + seed) % widths.count
                var w = CGFloat(widths[n])
                if line == 4 { w = CGFloat(min(widths[n], (typed % 12) * 3)) }
                fill(ctx, CGRect(x: screen.minX + 3 + CGFloat(line % 2) * 4, y: screen.maxY - 5 - CGFloat(line) * 4.5,
                                 width: w, height: 2), colors[(n + line) % colors.count])
            }
        case .error:
            fill(ctx, screen, 0x15232b)
            fill(ctx, CGRect(x: screen.minX + 3, y: screen.midY - 1, width: 26, height: 2), 0xe5534b)
        case .done, .idle:
            fill(ctx, screen, 0x141414)
        }
    }

    private func drawSitter(_ ctx: CGContext, _ d: Office.Desk) {
        let seat = CGPoint(x: d.rect.minX + Spot.seatX, y: d.rect.minY + Spot.seatY)
        if d.agentID == "claude", let img = Self.pose(d.scene, frame: frame_, pixel: 3) {
            ctx.draw(img, in: CGRect(x: seat.x, y: seat.y, width: 66, height: 36))
            return
        }
        let agent = session(d.sessionID)?.agent ?? Agent.byID(d.agentID)
        let sprite = IconRenderer.shared.sprite(for: agent)
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let image: NSImage
        if d.state.isWorking, !still, !sprite.colorFrames.isEmpty {
            let i = Int(Double(frame_) / Self.fps * sprite.fps) % sprite.colorFrames.count
            image = sprite.colorFrames[i]
        } else {
            image = sprite.restingColor
        }
        let h: CGFloat = 34
        let w = (image.size.width / max(image.size.height, 1) * h).rounded()
        let rect = CGRect(x: seat.x + max(0, (66 - w) / 2 - 8), y: seat.y, width: w, height: h)
        NSGraphicsContext.current?.imageInterpolation = .none
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: d.state.isFinished ? 0.55 : 1)
        // Its sign, beside the mark the way Clawd holds his: "!" or "?", or a z.
        let blink = still || (frame_ / 8) % 4 != 3
        if d.handRaised, blink {
            PixelFont.text(ctx, d.state == .permission ? "!" : "?", x: rect.maxX + 4, y: seat.y + 18, pixel: 3,
                           color: d.state == .permission ? Self.amber : Self.blue)
        } else if d.state == .done || d.state == .idle {
            PixelFont.text(ctx, "Z", x: rect.maxX + 3, y: seat.y + 26, pixel: 1.5, color: Self.dim)
        }
    }

    private func drawHelpers(_ ctx: CGContext, _ d: Office.Desk) {
        guard d.subagents > 0 else { return }
        let shown = min(d.subagents, Self.helpersShown)
        for i in 0..<shown {
            // Out of step with each other, so two helpers don't type as one.
            if let img = Self.pose(.type, frame: frame_ + i * 5, pixel: 1) {
                ctx.draw(img, in: helperRect(d, i))
            }
        }
        if d.subagents > shown {
            PixelFont.text(ctx, "+\(d.subagents - shown)", x: d.rect.minX + Spot.helperX, y: d.rect.minY + Spot.seatY + 16,
                           pixel: 1.5, color: Self.dim)
        }
    }

    // MARK: - Pieces

    private static var poses: [String: CGImage] = [:]

    /// Frame `frame` of `scene`'s reel at `pixel`, held on its first pose while
    /// motion is reduced.
    static func pose(_ scene: ClawdScene, frame: Int, pixel: CGFloat) -> CGImage? {
        guard let reel = scene.reel, !reel.rhythm.isEmpty else { return nil }
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let index = still ? 0 : reel.rhythm[frame % reel.rhythm.count]
        let key = "\(scene)-\(index)-\(pixel)"
        if let cached = poses[key] { return cached }
        let image = ClawdSceneArt.image(reel.poses[index], pixel: pixel,
                                        canvasWidth: CGFloat(ClawdSceneArt.columns) * pixel)
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        poses[key] = cg
        return cg
    }

    private func fill(_ ctx: CGContext, _ r: CGRect, _ rgb: UInt32) {
        ctx.setFillColor(PixelFont.color(rgb).cgColor)
        ctx.fill(r)
    }
}
