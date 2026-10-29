import AppKit
import UniformTypeIdentifiers

/// Replay: one turn of a session as a little level, shown in Your Day's window —
/// not a window of its own. It borrows the window's content while it plays and
/// gives the card back the moment Your Day is asked for.
///
/// Opened only by a click: **Replay last turn…** on an island row's right-click
/// menu, or a Replay button on a Your Day row. No link opens it (CLAUDE.md rule 2:
/// a window the person did not ask for is a window unfolding on its own). Its clock
/// runs only while it plays, and stops when the window closes or hides.
extension WrapWindow {
    /// The session's last turn, from the island's row menu.
    func showReplay(session s: Session) {
        showReplay(ReplayTurn.Subject(sessionID: s.id, cwd: s.cwd, project: s.project, agentID: s.agentID))
    }

    /// A turn by session id — the hook for Your Day's rows: `by` is the moment
    /// the row is about, and the replay is the turn that had started by then.
    func showReplay(_ subject: ReplayTurn.Subject) {
        let pane = enterReplay()
        pane.loading(subject)
        // AgentBar's own record of the waits only reaches back an hour and only
        // for sessions it still holds; an older turn has no gates rather than
        // made-up ones.
        let segments = subject.by == nil ? SessionTimeline.shared.strip(for: subject.sessionID) : []
        ReplayTurn.load(subject) { [weak pane] turn in
            guard let pane, pane.subject == subject else { return }
            pane.load(turn: turn, segments: segments)
        }
        NSApp.activate(ignoringOtherApps: true)
        hostWindow.makeKeyAndOrderFront(nil)
        hostWindow.makeFirstResponder(pane.player)
    }

    /// Puts the card back where the replay was. Called by `show(_:)`.
    func leaveReplay() {
        guard let pane = ReplayPane.current, let window = pane.window, let card = ReplayPane.card else { return }
        pane.player.stop()
        window.contentView = card
        window.title = "Your Day"
        ReplayPane.current = nil
        ReplayPane.card = nil
    }

    private func enterReplay() -> ReplayPane {
        let window = hostWindow
        if let pane = ReplayPane.current { return pane }
        ReplayPane.card = window.contentView
        let pane = ReplayPane(frame: window.contentView?.frame ?? .zero)
        window.contentView = pane
        window.title = "Replay"
        ReplayPane.current = pane
        return pane
    }

    /// The replay pane at `t`, drawn to a file without putting it on screen.
    func renderReplayForVerification(_ r: Replay, at t: Double, to url: URL) -> Bool {
        let pane = enterReplay()
        pane.show(r, at: t)
        defer { leaveReplay() }
        guard let rep = pane.bitmapImageRepForCachingDisplay(in: pane.bounds) else { return false }
        pane.wantsLayer = true
        pane.layer?.backgroundColor = WrapStyle.paper.cgColor
        pane.cacheDisplay(in: pane.bounds, to: rep)
        return (try? rep.representation(using: .png, properties: [:])?.write(to: url)) != nil
    }
}

/// The canvas and its bar: play, scrub, share.
final class ReplayPane: NSView {
    fileprivate static var current: ReplayPane?
    fileprivate static var card: NSView?

    let player: ReplayView
    private var playButton: NSButton!
    private var slider: NSSlider!
    private var status: NSTextField!
    private var shareButton: NSButton!
    fileprivate var subject: ReplayTurn.Subject?
    /// Off by default, as on the card: a clip you post should not say what the
    /// agent said or name your repositories.
    private var includeNames = false
    private var sayUntil: Date?

    override init(frame: NSRect) {
        let barHeight: CGFloat = 60
        player = ReplayView(frame: NSRect(x: 0, y: barHeight, width: frame.width, height: frame.height - barHeight))
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        player.autoresizingMask = [.width, .height]
        player.onTick = { [weak self] in self?.sync() }
        player.onCopy = { [weak self] in self?.copyFrame() }

        playButton = NSButton(image: NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")!,
                              target: self, action: #selector(togglePlay))
        playButton.bezelStyle = .rounded
        playButton.toolTip = "Play or pause (Space)"
        slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: self, action: #selector(scrubbed))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.setContentHuggingPriority(.init(1), for: .horizontal)
        slider.setAccessibilityLabel("Moment in the replay")
        status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.isHidden = true
        shareButton = NSButton(title: "Share", image: NSImage(systemSymbolName: "square.and.arrow.up",
                                                              accessibilityDescription: nil)!,
                               target: self, action: #selector(showShareMenu(_:)))
        shareButton.imagePosition = .imageLeading
        shareButton.bezelStyle = .rounded
        shareButton.toolTip = "Save this moment or the whole replay, or send it somewhere"

        let bar = NSStackView(views: [playButton, slider, status, shareButton])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 10
        bar.translatesAutoresizingMaskIntoConstraints = false

        let line = NSBox(frame: NSRect(x: 16, y: barHeight - 1, width: frame.width - 32, height: 1))
        line.boxType = .custom
        line.borderWidth = 0
        line.fillColor = WrapStyle.hairline
        line.autoresizingMask = [.width]

        addSubview(player)
        addSubview(bar)
        addSubview(line)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: barHeight),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        // The clock runs only while someone can see it.
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowWentAway), name: name, object: window)
        }
    }

    @objc private func windowWentAway() {
        player.stop()
        sync()
    }

    // MARK: - Content

    fileprivate func loading(_ s: ReplayTurn.Subject) {
        subject = s
        includeNames = false
        player.load(nil)
        sync()
    }

    fileprivate func load(turn: ReplayTurn, segments: [SessionTimeline.Segment]) {
        let project = subject?.project ?? ""
        player.load(Replay(turn: turn, segments: segments, agentID: subject?.agentID ?? "claude",
                           project: project, named: true))
        player.play(from: 0)
        sync()
    }

    /// A fixed replay at a fixed moment, for verification.
    fileprivate func show(_ r: Replay, at t: Double) {
        player.load(r)
        player.seek(t)
        sync()
    }

    private func sync() {
        playButton.image = NSImage(systemSymbolName: player.isPlaying ? "pause.fill" : "play.fill",
                                   accessibilityDescription: player.isPlaying ? "Pause" : "Play")
        playButton.isEnabled = player.replay != nil
        slider.isEnabled = player.replay != nil
        slider.doubleValue = player.replay.map { player.t / max(0.01, $0.duration) } ?? 0
        if let until = sayUntil, until < Date() { say("") }
    }

    @objc private func togglePlay() { player.toggle(); sync() }

    @objc private func scrubbed() {
        guard let r = player.replay else { return }
        player.stop()
        player.seek(slider.doubleValue * r.duration)
        sync()
    }

    // MARK: - Share

    private var exported: Replay? {
        guard let r = player.replay else { say("Still reading the turn — one moment."); return nil }
        return includeNames ? r : r.shareSafe()
    }

    @objc private func showShareMenu(_ sender: NSButton) {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, _ symbol: String, _ shape: String? = nil) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            i.representedObject = shape
            menu.addItem(i)
        }
        item("Share…", #selector(shareFrame), "square.and.arrow.up")
        menu.addItem(.separator())
        item("Save Image…", #selector(saveImage(_:)), "photo", "story")
        item("Save Square Image…", #selector(saveImage(_:)), "square", "square")
        item("Save Video…", #selector(saveVideo), "film")
        item("Save GIF…", #selector(saveGIF), "sparkles.rectangle.stack")
        menu.addItem(.separator())
        let names = NSMenuItem(title: "Include Project Names and Words", action: #selector(toggleNames),
                               keyEquivalent: "")
        names.target = self
        names.state = includeNames ? .on : .off
        names.toolTip = "Off by default: a replay you post should not name your repositories or quote your agent."
        menu.addItem(names)
        menu.addItem(.separator())
        item("Back to Your Day", #selector(backToDay), "chevron.left")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func toggleNames() { includeNames.toggle() }

    @objc private func backToDay() { WrapWindow.shared.show(.today) }

    private func copyFrame() {
        guard let r = exported, let rep = ReplayExport.frame(r, at: player.t, shape: .story),
              let data = WrapExport.png(rep) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
        say("This moment copied — paste it anywhere.")
    }

    @objc private func shareFrame() {
        guard let r = exported, let rep = ReplayExport.frame(r, at: player.t, shape: .story),
              let data = WrapExport.png(rep) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName("png"))
        guard (try? data.write(to: url)) != nil else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: shareButton.bounds, of: shareButton, preferredEdge: .minY)
    }

    @objc private func saveImage(_ sender: NSMenuItem) {
        guard let r = exported else { return }
        let shape: WrapExport.Shape = sender.representedObject as? String == "square" ? .square : .story
        let t = player.t
        save(name: fileName("png", shape == .square ? "-square" : ""), type: .png) { url in
            guard let rep = ReplayExport.frame(r, at: t, shape: shape), let data = WrapExport.png(rep) else {
                throw WrapExport.ExportError("the frame could not be drawn")
            }
            try data.write(to: url)
        }
    }

    @objc private func saveVideo() {
        guard let r = exported else { return }
        save(name: fileName("mp4"), type: .mpeg4Movie) { [weak self] url in
            try ReplayExport.writeMP4(r, to: url) { p in
                DispatchQueue.main.async { self?.say("Rendering video… \(Int(p * 100)) %", hold: false) }
            }
        }
    }

    @objc private func saveGIF() {
        guard let r = exported else { return }
        save(name: fileName("gif"), type: .gif) { [weak self] url in
            try ReplayExport.writeGIF(r, to: url) { p in
                DispatchQueue.main.async { self?.say("Rendering GIF… \(Int(p * 100)) %", hold: false) }
            }
        }
    }

    private func fileName(_ ext: String, _ suffix: String = "") -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        let at = player.replay?.level.realStart ?? Date().timeIntervalSince1970
        return "AgentBar replay \(f.string(from: Date(timeIntervalSince1970: at)))\(suffix).\(ext)"
    }

    private func save(name: String, type: UTType, work: @escaping (URL) throws -> Void) {
        guard let window else { return }
        player.stop()
        sync()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.shareButton.isEnabled = false
            self?.say("Rendering…", hold: false)
            DispatchQueue.global(qos: .userInitiated).async {
                let error: Error?
                do { try work(url); error = nil } catch let e { error = e }
                DispatchQueue.main.async {
                    self?.shareButton.isEnabled = true
                    if let error {
                        self?.say("Not saved: \(error.localizedDescription)")
                    } else {
                        self?.say("Saved \(url.lastPathComponent)")
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
        }
    }

    /// A line in place of the scrubber; it gives the scrubber back after a while.
    private func say(_ s: String, hold: Bool = true) {
        status.stringValue = s
        status.isHidden = s.isEmpty
        slider.isHidden = !s.isEmpty
        sayUntil = s.isEmpty ? nil : (hold ? Date().addingTimeInterval(3) : Date.distantFuture)
        if hold, !s.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.1) { [weak self] in self?.sync() }
        }
    }
}

/// The replay itself: plays once when it opens and stops at the flag. Space plays
/// or pauses, ←/→ step half a second, Esc closes, ⌘C copies the moment.
final class ReplayView: NSView {
    private(set) var replay: Replay?
    private(set) var t: Double = 0
    private var timer: Timer?
    private var last: CFTimeInterval = 0
    var onTick: (() -> Void)?
    var onCopy: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var isPlaying: Bool { timer != nil }

    func load(_ r: Replay?) {
        stop()
        replay = r
        t = 0
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(r.map { "Replay of one turn: " + ReplayRenderer.sentence($0.level) } ?? "Reading the turn")
        needsDisplay = true
    }

    /// From `start`, or — under Reduce Motion — the moment there, still.
    func play(from start: Double? = nil) {
        guard let r = replay else { return }
        stop()
        if let start { t = start }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, start != nil {
            t = r.duration
            needsDisplay = true
            return
        }
        if t >= r.duration { t = 0 }
        last = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func toggle() { isPlaying ? stop() : play() }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func seek(_ to: Double) {
        t = max(0, min(to, replay?.duration ?? 0))
        needsDisplay = true
    }

    private func tick() {
        guard let r = replay else { return stop() }
        let now = CACurrentMediaTime()
        t += min(0.1, now - last)
        last = now
        if t >= r.duration { t = r.duration; stop() }
        needsDisplay = true
        onTick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if let r = replay {
            ReplayRenderer.draw(at: t, replay: r, size: bounds.size, in: ctx)
        } else {
            WrapStyle.fill(bounds, WrapStyle.paper)
            let u = min(bounds.width, bounds.height) / 1080
            WrapStyle.text("Reading the turn…", WrapStyle.font(36 * u, .regular), WrapStyle.secondary,
                           x: 96 * u, y: bounds.height * 0.4, width: bounds.width - 192 * u)
        }
    }

    override func mouseUp(with event: NSEvent) { toggle(); onTick?() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: toggle()                                   // Space
        case 123: stop(); seek(t - 0.5)                     // ←
        case 124: stop(); seek(t + 0.5)                     // →
        case 53: window?.performClose(nil)                  // Esc
        default:
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" { onCopy?() }
            else { super.keyDown(with: event) }
        }
        onTick?()
    }
}
