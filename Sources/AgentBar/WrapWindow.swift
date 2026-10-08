import AppKit
import UniformTypeIdentifiers

/// Your Day: the recap, as one card in a small window of its own.
///
/// A window the person opens — from **Your Day…** in either menu or an
/// `agentbar://day` link — and nothing else ever does: a recap nobody asked for
/// would be a window unfolding on its own (CLAUDE.md rule 2). The card builds once
/// when it opens and then holds still; its clock runs only for those two seconds.
final class WrapWindow: NSObject, NSWindowDelegate {
    static let shared = WrapWindow()

    private var window: NSWindow?
    private var player: WrapCardView!
    private var rangeControl: NSSegmentedControl!
    private var status: NSTextField!
    private var copyButton: NSButton!
    private var shareButton: NSButton!
    /// Off by default: a card you post should not name your private repositories.
    private var includeNames = false
    private var loading = 0

    private(set) var range: DayWrap.Range = .today

    func show(_ range: DayWrap.Range = .today) {
        if window == nil { build() }
        self.range = range
        rangeControl.selectedSegment = range == .today ? 0 : 1
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(player)
    }

    @objc func openFromMenu(_ sender: Any?) { show(.today) }

    /// The recap is read off the main queue — the transcripts behind the agent
    /// time can be megabytes — and the card builds once it is in.
    private func reload() {
        loading += 1
        let ticket = loading, range = self.range
        say("")
        player.load(.placeholder(range))
        player.finish()
        DispatchQueue.global(qos: .userInitiated).async {
            let wrap = DayWrap.load(range)
            DispatchQueue.main.async { [weak self] in
                guard let self, ticket == self.loading else { return }
                self.player.load(wrap)
                self.player.build()
            }
        }
    }

    // MARK: - Build

    private static let barHeight: CGFloat = 60

    private func build() {
        let size = WrapCardView.size
        let barHeight = Self.barHeight
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height + barHeight),
                         styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Your Day"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.backgroundColor = WrapStyle.paper
        w.appearance = NSAppearance(named: .aqua)
        w.delegate = self
        w.center()

        player = WrapCardView(frame: NSRect(origin: NSPoint(x: 0, y: barHeight), size: size))
        player.autoresizingMask = [.width, .height]

        // The bar: which recap on the left, what to do with it on the right — two
        // buttons, with every way out of the window behind the second.
        rangeControl = NSSegmentedControl(labels: ["Today", "This Week"], trackingMode: .selectOne,
                                          target: self, action: #selector(rangeChanged))
        rangeControl.segmentStyle = .rounded
        rangeControl.controlSize = .regular
        rangeControl.setWidth(76, forSegment: 0)
        rangeControl.setWidth(88, forSegment: 1)

        copyButton = NSButton(title: "Copy", target: self, action: #selector(copyCard))
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .regular
        copyButton.toolTip = "Copy the card as an image (⌘C)"
        shareButton = NSButton(title: "Share", image: NSImage(systemSymbolName: "square.and.arrow.up",
                                                              accessibilityDescription: nil)!,
                               target: self, action: #selector(showShareMenu(_:)))
        shareButton.imagePosition = .imageLeading
        shareButton.bezelStyle = .rounded
        shareButton.controlSize = .regular
        shareButton.toolTip = "Save the card or a video of it, or send it somewhere"

        status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [rangeControl, status, spacer, copyButton, shareButton])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 8
        bar.setCustomSpacing(12, after: rangeControl)
        bar.translatesAutoresizingMaskIntoConstraints = false

        // A hairline between the card and the bar, the card's own.
        let line = NSBox(frame: NSRect(x: 16, y: barHeight - 1, width: size.width - 32, height: 1))
        line.boxType = .custom
        line.borderWidth = 0
        line.fillColor = WrapStyle.hairline
        line.autoresizingMask = [.width]

        let content = NSView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height + barHeight))
        content.addSubview(player)
        content.addSubview(bar)
        content.addSubview(line)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: barHeight),
        ])
        w.contentView = content
        w.contentAspectRatio = NSSize(width: size.width, height: size.height + barHeight)
        window = w
        player.onCopy = { [weak self] in self?.copyCard() }
    }

    /// Everything that takes the card somewhere, in one menu.
    @objc private func showShareMenu(_ sender: NSButton) {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, _ symbol: String, _ shape: String? = nil) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            i.representedObject = shape
            menu.addItem(i)
        }
        item("Share…", #selector(shareCard), "square.and.arrow.up")
        menu.addItem(.separator())
        item("Save Image…", #selector(saveImageShape(_:)), "photo", "story")
        item("Save Square Image…", #selector(saveImageShape(_:)), "square", "square")
        item("Save Video…", #selector(saveVideo), "film")
        item("Save GIF…", #selector(saveGIF), "sparkles.rectangle.stack")
        menu.addItem(.separator())
        let names = NSMenuItem(title: "Include Project Names", action: #selector(toggleNames), keyEquivalent: "")
        names.target = self
        names.state = includeNames ? .on : .off
        names.toolTip = "Off by default: a card you post should not name your private repositories."
        menu.addItem(names)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func toggleNames() { includeNames.toggle() }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) { player.stop() }
    func windowDidMiniaturize(_ notification: Notification) { player.stop() }

    @objc private func rangeChanged() {
        range = rangeControl.selectedSegment == 0 ? .today : .week
        reload()
    }

    // MARK: - Export

    /// The recap as it leaves the Mac: without project names and tasks unless the
    /// box says otherwise.
    private var exported: DayWrap {
        includeNames ? player.wrap : player.wrap.shareSafe()
    }

    /// Nothing leaves the Mac before the numbers are in: a copied placeholder would
    /// be a recap of nothing.
    private var ready: Bool {
        if player.wrap.pending { say("Still adding up — one moment.") }
        return !player.wrap.pending
    }

    @objc private func copyCard() {
        guard ready, let rep = WrapExport.card(exported, shape: .story), let data = WrapExport.png(rep) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)
        say("Card copied — paste it anywhere.")
    }

    @objc private func saveImageShape(_ sender: NSMenuItem) {
        guard ready else { return }
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
        guard ready else { return }
        let wrap = exported
        save(name: fileName("mp4"), type: .mpeg4Movie) { [weak self] url in
            try WrapExport.writeMP4(wrap, to: url) { p in
                DispatchQueue.main.async { self?.say("Rendering video… \(Int(p * 100)) %") }
            }
        }
    }

    @objc private func saveGIF() {
        guard ready else { return }
        let wrap = exported
        save(name: fileName("gif"), type: .gif) { [weak self] url in
            try WrapExport.writeGIF(wrap, to: url) { p in
                DispatchQueue.main.async { self?.say("Rendering GIF… \(Int(p * 100)) %") }
            }
        }
    }

    @objc private func shareCard() {
        guard ready, let rep = WrapExport.card(exported, shape: .story), let data = WrapExport.png(rep) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName("png"))
        guard (try? data.write(to: url)) != nil else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: shareButton.bounds, of: shareButton, preferredEdge: .minY)
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
            self?.setBusy(true)
            self?.say("Rendering…")
            DispatchQueue.global(qos: .userInitiated).async {
                let error: Error?
                do { try work(url); error = nil } catch let e { error = e }
                DispatchQueue.main.async {
                    self?.setBusy(false)
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

    private func say(_ s: String) { status?.stringValue = s }

    private func setBusy(_ busy: Bool) {
        copyButton.isEnabled = !busy
        shareButton.isEnabled = !busy
    }

    /// The window with its card finished, drawn to a file without putting it on
    /// screen.
    func renderForVerification(_ wrap: DayWrap, to url: URL) -> Bool {
        if window == nil { build() }
        player.load(wrap)
        player.finish()
        guard let view = window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.wantsLayer = true
        view.layer?.backgroundColor = WrapStyle.paper.cgColor
        view.cacheDisplay(in: view.bounds, to: rep)
        return (try? rep.representation(using: .png, properties: [:])?.write(to: url)) != nil
    }
}

/// The card: it builds when the window opens and then holds. A click — or
/// Space — builds it again; Esc closes; ⌘C copies.
final class WrapCardView: NSView {
    static let size = NSSize(width: 405, height: 720)

    private(set) var wrap = DayWrap.placeholder(.today)
    private var t: Double = WrapRenderer.buildSeconds
    private var timer: Timer?
    private var last: CFTimeInterval = 0
    var onCopy: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var isBuilding: Bool { timer != nil }

    func load(_ w: DayWrap) {
        wrap = w
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(Self.spoken(w))
        needsDisplay = true
    }

    /// What VoiceOver reads: the card's facts as a sentence each.
    static func spoken(_ w: DayWrap) -> String {
        if w.pending { return "\(w.range.title) with agents. Adding it up." }
        guard !w.isEmpty else { return "\(w.range.title) with agents. Nothing has finished yet." }
        var parts = ["\(w.range.title) with agents. You were \(w.persona.title). \(w.persona.reason)"]
        if w.timed > 0 { parts.append("\(HistoryDigest.duration(w.agentSeconds)) of agent time.") }
        for t in WrapRenderer.tileFacts(w).prefix(4) {
            parts.append("\(t.caption): \(t.value)\(t.second.map { " " + $0.0 } ?? ""), \(t.detail).")
        }
        return parts.joined(separator: " ")
    }

    /// Builds the card from nothing — or, under Reduce Motion, shows it finished.
    func build() {
        stop()
        guard !reduceMotion else { return finish() }
        t = 0
        last = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        needsDisplay = true
    }

    /// The finished card, at once.
    func finish() {
        stop()
        t = WrapRenderer.buildSeconds
        needsDisplay = true
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        t += min(0.1, now - last)
        last = now
        if t >= WrapRenderer.buildSeconds { return finish() }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let done = t >= WrapRenderer.buildSeconds
        WrapRenderer.draw(at: t, wrap: wrap, size: bounds.size, in: ctx, still: done)
    }

    override func mouseUp(with event: NSEvent) { build() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: build()                               // Space
        case 53: window?.performClose(nil)             // Esc
        default:
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" { onCopy?() }
            else { super.keyDown(with: event) }
        }
    }
}
