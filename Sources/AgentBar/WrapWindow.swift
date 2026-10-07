import AppKit
import UniformTypeIdentifiers

/// Your Day: the recap, played as a story in a small window of its own.
///
/// A window the person opens — from **Your Day…** in either menu or an
/// `agentbar://day` link — and nothing else ever does: a recap nobody asked for
/// would be a window unfolding on its own (CLAUDE.md rule 2). Its clock runs only
/// while it is on screen, the way the games' does.
final class WrapWindow: NSObject, NSWindowDelegate {
    static let shared = WrapWindow()

    private var window: NSWindow?
    private var player: WrapPlayerView!
    private var rangeControl: NSSegmentedControl!
    private var namesBox: NSButton!
    private var status: NSTextField!
    private var exportButtons: [NSButton] = []

    private(set) var range: DayWrap.Range = .today

    func show(_ range: DayWrap.Range = .today) {
        if window == nil { build() }
        self.range = range
        rangeControl.selectedSegment = range == .today ? 0 : 1
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(player)
        player.play(from: 0)
    }

    @objc func openFromMenu(_ sender: Any?) { show(.today) }

    private func reload() {
        let wrap = DayWrap.make(range, history: HistoryStore.read(), ledger: DecisionLedger.read())
        player.load(wrap)
        status.stringValue = ""
    }

    // MARK: - Build

    private func build() {
        let size = WrapPlayerView.size
        let barHeight: CGFloat = 92
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height + barHeight),
                         styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Your Day"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.backgroundColor = WrapStyle.night
        w.appearance = NSAppearance(named: .darkAqua)
        w.delegate = self
        w.center()

        player = WrapPlayerView(frame: NSRect(origin: NSPoint(x: 0, y: barHeight), size: size))
        player.autoresizingMask = [.width, .height]

        rangeControl = NSSegmentedControl(labels: ["Today", "This week"], trackingMode: .selectOne,
                                          target: self, action: #selector(rangeChanged))
        rangeControl.controlSize = .small
        namesBox = NSButton(checkboxWithTitle: "Project names in exports", target: nil, action: nil)
        namesBox.controlSize = .small
        namesBox.font = .systemFont(ofSize: 11)
        namesBox.state = .off
        namesBox.toolTip = "Off by default: a card you post should not name your private repositories."

        func button(_ title: String, _ symbol: String, _ action: Selector, _ tip: String) -> NSButton {
            let b = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!,
                             target: self, action: action)
            b.imagePosition = .imageLeading
            b.controlSize = .small
            b.bezelStyle = .rounded
            b.toolTip = tip
            return b
        }
        exportButtons = [
            button("Copy", "doc.on.doc", #selector(copyCard), "Copy the card as an image (⌘C)"),
            button("Image", "photo", #selector(saveImage), "Save the card as a PNG — story or square"),
            button("Video", "film", #selector(saveVideo), "Save the whole story as an MP4"),
            button("GIF", "sparkles.rectangle.stack", #selector(saveGIF), "Save the whole story as a looping GIF"),
            button("Share", "square.and.arrow.up", #selector(share(_:)), "Share the card"),
        ]
        status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor

        let top = NSStackView(views: [rangeControl, NSView(), namesBox])
        top.orientation = .horizontal
        let buttons = NSStackView(views: exportButtons + [status])
        buttons.orientation = .horizontal
        buttons.spacing = 6
        let bar = NSStackView(views: [top, buttons])
        bar.orientation = .vertical
        bar.alignment = .leading
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        bar.frame = NSRect(x: 0, y: 0, width: size.width, height: barHeight)
        bar.autoresizingMask = [.width]
        top.translatesAutoresizingMaskIntoConstraints = false
        top.widthAnchor.constraint(equalToConstant: size.width - 28).isActive = true

        let content = NSView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height + barHeight))
        content.addSubview(player)
        content.addSubview(bar)
        w.contentView = content
        w.contentAspectRatio = NSSize(width: size.width, height: size.height + barHeight)
        window = w
        player.onCopy = { [weak self] in self?.copyCard() }
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) { player.stop() }
    func windowDidMiniaturize(_ notification: Notification) { player.stop() }
    func windowDidDeminiaturize(_ notification: Notification) { player.resume() }

    @objc private func rangeChanged() {
        range = rangeControl.selectedSegment == 0 ? .today : .week
        reload()
        player.play(from: 0)
    }

    // MARK: - Export

    /// The recap as it leaves the Mac: without project names and tasks unless the
    /// box says otherwise.
    private var exported: DayWrap {
        namesBox.state == .on ? player.wrap : player.wrap.shareSafe()
    }

    @objc private func copyCard() {
        guard let rep = WrapExport.card(exported, shape: .story), let data = WrapExport.png(rep) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)
        say("Card copied — paste it anywhere.")
    }

    @objc private func saveImage() {
        let menu = NSMenu()
        for (title, shape) in [("Story card (1080 × 1920)", WrapExport.Shape.story),
                               ("Square card (1080 × 1080)", .square)] {
            let item = NSMenuItem(title: title, action: #selector(saveImageShape(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = shape == .story ? "story" : "square"
            menu.addItem(item)
        }
        if let b = exportButtons.first(where: { $0.action == #selector(saveImage) }) {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
        }
    }

    @objc private func saveImageShape(_ sender: NSMenuItem) {
        let shape: WrapExport.Shape = sender.representedObject as? String == "square" ? .square : .story
        let wrap = exported
        save(name: fileName("png", shape == .square ? "-square" : ""), type: .png) { url in
            guard let rep = WrapExport.card(wrap, shape: shape), let data = WrapExport.png(rep) else {
                throw WrapExport.ExportError("the card could not be drawn")
            }
            try data.write(to: url)
        }
    }

    @objc private func saveVideo() {
        let wrap = exported
        save(name: fileName("mp4"), type: .mpeg4Movie) { [weak self] url in
            try WrapExport.writeMP4(wrap, to: url) { p in
                DispatchQueue.main.async { self?.say("Rendering video… \(Int(p * 100)) %") }
            }
        }
    }

    @objc private func saveGIF() {
        let wrap = exported
        save(name: fileName("gif"), type: .gif) { [weak self] url in
            try WrapExport.writeGIF(wrap, to: url) { p in
                DispatchQueue.main.async { self?.say("Rendering GIF… \(Int(p * 100)) %") }
            }
        }
    }

    @objc private func share(_ sender: NSButton) {
        guard let rep = WrapExport.card(exported, shape: .story), let data = WrapExport.png(rep) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName("png"))
        guard (try? data.write(to: url)) != nil else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    private func fileName(_ ext: String, _ suffix: String = "") -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let day = f.string(from: Date(timeIntervalSince1970: player.wrap.end))
        return "AgentBar \(range == .today ? "day" : "week") \(day)\(suffix).\(ext)"
    }

    /// A save panel, then the work off the main thread, then what happened.
    private func save(name: String, type: UTType, work: @escaping (URL) throws -> Void) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.exportButtons.forEach { $0.isEnabled = false }
            self?.say("Rendering…")
            DispatchQueue.global(qos: .userInitiated).async {
                let error: Error?
                do { try work(url); error = nil } catch let e { error = e }
                DispatchQueue.main.async {
                    self?.exportButtons.forEach { $0.isEnabled = true }
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

    private func say(_ s: String) { status.stringValue = s }

    /// The window as it looks a few seconds into `slide`, drawn to a file without
    /// putting it on screen.
    func renderForVerification(_ wrap: DayWrap, slide: Int, at seconds: Double, to url: URL) -> Bool {
        if window == nil { build() }
        player.load(wrap)
        player.seek(Double(slide) * WrapRenderer.slideSeconds + seconds)
        guard let view = window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.wantsLayer = true
        view.layer?.backgroundColor = WrapStyle.night.cgColor
        view.cacheDisplay(in: view.bounds, to: rep)
        return (try? rep.representation(using: .png, properties: [:])?.write(to: url)) != nil
    }
}

/// The story itself: the slides playing, the segmented progress line across the
/// top, click or arrow to move, Space to pause.
final class WrapPlayerView: NSView {
    static let size = NSSize(width: 405, height: 720)

    private(set) var wrap = DayWrap(range: .today, start: 0, end: 0)
    private var slides: [WrapSlide] = [.cover]
    private var t: Double = 0
    private var timer: Timer?
    private var last: CFTimeInterval = 0
    private(set) var paused = false
    var onCopy: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var total: Double { WrapExport.duration(of: slides) }
    private var index: Int { min(slides.count - 1, Int(t / WrapRenderer.slideSeconds)) }
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func load(_ w: DayWrap) {
        wrap = w
        slides = WrapRenderer.slides(for: w)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(w.range.title) with agents. \(w.persona.title). \(w.persona.reason)")
        needsDisplay = true
    }

    func play(from start: Double) {
        t = start
        paused = false
        resume()
    }

    func resume() {
        guard timer == nil, !paused else { return }
        last = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Holds the story still at `seconds` — for pictures of the window.
    func seek(_ seconds: Double) {
        stop()
        t = seconds
        needsDisplay = true
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(0.1, now - last)
        last = now
        t += dt
        // The card is the end: it holds rather than looping back to the cover.
        if t >= total - 0.01 {
            t = max(0, total - 0.01)
            stop()
        }
        needsDisplay = true
    }

    private func go(to i: Int) {
        let i = max(0, min(slides.count - 1, i))
        t = Double(i) * WrapRenderer.slideSeconds
        if !paused { resume() }
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let size = bounds.size
        if reduceMotion {
            // Still slides that change on the cut: the words without the motion.
            WrapRenderer.draw(slides[index], at: 0, wrap: wrap, size: size, in: ctx, still: true)
        } else {
            WrapExport.drawStory(at: t, slides: slides, wrap: wrap, size: size, in: ctx)
        }
        drawProgress(size)
    }

    /// One segment per slide, filling as it plays — the story's own clock.
    private func drawProgress(_ size: CGSize) {
        let n = slides.count
        let gap: CGFloat = 4, inset: CGFloat = 12, h: CGFloat = 3
        let top: CGFloat = 32 // under the traffic lights' row
        let w = (size.width - 2 * inset - gap * CGFloat(n - 1)) / CGFloat(n)
        for i in 0..<n {
            let x = inset + CGFloat(i) * (w + gap)
            let fill: Double = i < index ? 1 : i > index ? 0
                : (t - Double(i) * WrapRenderer.slideSeconds) / WrapRenderer.slideSeconds
            WrapStyle.pill(CGRect(x: x, y: top, width: w, height: h), NSColor.white.withAlphaComponent(0.28))
            WrapStyle.pill(CGRect(x: x, y: top, width: w * CGFloat(WrapStyle.clamp(fill)), height: h),
                           NSColor.white.withAlphaComponent(0.95))
        }
    }

    // MARK: - Input

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        go(to: index + (p.x < bounds.width / 3 ? -1 : 1))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: go(to: index - 1)                    // ←
        case 124: go(to: index + 1)                    // →
        case 49:                                       // Space
            paused.toggle()
            if paused { stop() } else { resume() }
        case 53: window?.performClose(nil)             // Esc
        default:
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" { onCopy?() }
            else { super.keyDown(with: event) }
        }
    }
}
