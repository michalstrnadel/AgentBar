import Cocoa

/// First-run window: says where AgentBar lives, lets the user pick the surface it
/// shows itself on, and names the agents whose hooks were wired. Shown on launch
/// until the user unticks it, and from the menu afterwards.
final class WelcomeWindow: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindow()

    private static let showKey = "showWelcomeOnLaunch"

    /// On until the user says otherwise, so a fresh install always gets it.
    static var showOnLaunch: Bool {
        get { UserDefaults.standard.object(forKey: showKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: showKey) }
    }

    private var window: NSWindow?
    private var preview: PresentationPreview!
    private var radios: [NSButton] = []
    private var colorRadios: [NSButton] = []
    private var modeCaption: NSTextField!
    private var wiredLabel: NSTextField!
    private var showBox: NSButton!
    /// A driver of its own, fed a canned session, so the preview animates whether
    /// or not anything real is running.
    private let mascot = MascotDriver()

    func show() {
        if window == nil { build() }
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        mascot.sink("welcome") { [weak self] image, word in
            self?.preview.set(image: image, word: word)
        }
        updatePreviewMascot()
    }

    private func updatePreviewMascot() {
        mascot.update(sessions: [Session(preview: .thinking, project: "AgentBar", label: "Thinking…")],
                      systemColor: IconColor.system)
    }

    // MARK: - Build

    /// Content width, and the width every row inside the margins is laid out to.
    /// Pinned rather than derived: `fittingSize` on a stack of wrapping labels and
    /// fixed-width rows resolves narrower than its children and clips them.
    private static let contentWidth: CGFloat = 520
    private static let rowWidth = contentWidth - 40

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 460),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Welcome to AgentBar"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()

        let stack = NSStackView(views: [header(), previewBox(), picker(), colorPicker(), footer()])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        w.contentView = NSView()
        w.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: w.contentView!.topAnchor),
            stack.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.contentWidth),
        ])
        w.setContentSize(NSSize(width: Self.contentWidth, height: stack.fittingSize.height))
        window = w
    }

    private func header() -> NSView {
        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
        ])

        let title = NSTextField(labelWithString: "AgentBar is running.")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString:
            "It watches your AI coding sessions and tells you the moment one needs "
            + "you. Pick where it should show them — you can change this any time "
            + "from the menu.")
        body.font = .systemFont(ofSize: NSFont.systemFontSize)
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = Self.rowWidth - 78 // icon + spacing

        let text = NSStackView(views: [title, body])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4

        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 14
        return row
    }

    private func previewBox() -> NSView {
        preview = PresentationPreview()
        preview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            preview.widthAnchor.constraint(equalToConstant: Self.rowWidth),
            preview.heightAnchor.constraint(equalToConstant: 116),
        ])
        return preview
    }

    private func picker() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 18
        for (i, mode) in Presentation.allCases.enumerated() {
            let b = NSButton(radioButtonWithTitle: mode.title, target: self, action: #selector(pickMode(_:)))
            b.tag = i
            radios.append(b)
            row.addArrangedSubview(b)
        }
        modeCaption = NSTextField(wrappingLabelWithString: " ")
        modeCaption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        modeCaption.textColor = .secondaryLabelColor
        modeCaption.preferredMaxLayoutWidth = Self.rowWidth

        let col = NSStackView(views: [row, modeCaption])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 4
        return col
    }

    /// Colored marks or monochrome templates — the same choice both menus offer,
    /// here next to the preview that shows what it means.
    private func colorPicker() -> NSView {
        let label = NSTextField(labelWithString: "Mark color:")
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        let row = NSStackView(views: [label])
        row.orientation = .horizontal
        row.spacing = 18
        for (i, title) in ["Color", "System"].enumerated() {
            let b = NSButton(radioButtonWithTitle: title, target: self, action: #selector(pickColor(_:)))
            b.tag = i
            colorRadios.append(b)
            row.addArrangedSubview(b)
        }
        return row
    }

    private func footer() -> NSView {
        wiredLabel = NSTextField(wrappingLabelWithString: " ")
        wiredLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        wiredLabel.textColor = .secondaryLabelColor
        wiredLabel.preferredMaxLayoutWidth = Self.rowWidth

        showBox = NSButton(checkboxWithTitle: "Show this window on launch",
                           target: self, action: #selector(toggleShowOnLaunch))

        let quit = NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .rounded
        let close = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [quit, spacer, close])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true

        let col = NSStackView(views: [wiredLabel, showBox, buttons])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 10
        col.setCustomSpacing(16, after: showBox)
        return col
    }

    // MARK: - State

    private func reload() {
        let mode = Presentation.current
        for (i, b) in radios.enumerated() {
            b.state = Presentation.allCases[i] == mode ? .on : .off
        }
        for (i, b) in colorRadios.enumerated() {
            b.state = (i == 1) == IconColor.system ? .on : .off
        }
        preview.mode = mode
        modeCaption.stringValue = mode.caption
        showBox.state = Self.showOnLaunch ? .on : .off
        refreshWired()
    }

    /// The install pass runs off the main queue and usually finishes after this
    /// window is up, so the line fills in when it reports done.
    func refreshWired() {
        guard wiredLabel != nil else { return }
        let names = HookInstaller.wired.map { Agent.byID($0).name }
        wiredLabel.stringValue = names.isEmpty
            ? "Setting up hooks…"
            : "Hooks wired up for: " + names.joined(separator: ", ")
    }

    @objc private func pickMode(_ sender: NSButton) {
        let mode = Presentation.allCases[sender.tag]
        Presentation.current = mode
        reload()
    }

    @objc private func pickColor(_ sender: NSButton) {
        IconColor.system = sender.tag == 1
        reload()
        updatePreviewMascot()
    }

    @objc private func toggleShowOnLaunch() {
        Self.showOnLaunch = showBox.state == .on
    }

    @objc private func closeClicked() {
        window?.performClose(nil)
    }

    /// The preview's timer has no reason to run against a closed window.
    func windowWillClose(_ notification: Notification) {
        mascot.sink("welcome", nil)
        // Idle the driver too: fed a permanent "thinking" session, its animation
        // timer would keep ticking at 12.5 fps forever, rendering frames for zero
        // sinks. An empty session set stops every timer; show() re-seeds it.
        mascot.update(sessions: [], systemColor: IconColor.system)
    }
}

/// Draws what each mode looks like, using the real mascot frames from a real
/// `MascotDriver` — a preview built from the actual renderer can't drift from
/// what the user gets.
final class PresentationPreview: NSView {
    var mode: Presentation = .menuBar { didSet { needsDisplay = true } }
    private var mark: NSImage?
    private var word = ""

    func set(image: NSImage, word: String) {
        mark = image
        self.word = word
        needsDisplay = true
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let screen = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)

        // A neutral "desktop" so both a light and a dark menu bar read correctly.
        NSGradient(starting: NSColor(srgbRed: 0.29, green: 0.44, blue: 0.62, alpha: 1),
                   ending: NSColor(srgbRed: 0.51, green: 0.44, blue: 0.55, alpha: 1))?
            .draw(in: screen, angle: -60)
        NSColor.separatorColor.setStroke()
        screen.lineWidth = 1
        screen.stroke()

        NSGraphicsContext.saveGraphicsState()
        screen.addClip()

        let barH: CGFloat = 22
        let bar = NSRect(x: r.minX, y: r.maxY - barH, width: r.width, height: barH)
        NSColor.black.withAlphaComponent(0.22).setFill()
        bar.fill()

        if mode.showsStatusItem { drawMenuBarItem(in: bar) }
        if mode.showsIsland { drawIsland(in: r, barHeight: barH) }

        NSGraphicsContext.restoreGraphicsState()
    }

    /// The mark sitting among the other menu bar items, right-aligned.
    private func drawMenuBarItem(in bar: NSRect) {
        var x = bar.maxX - 14
        for _ in 0..<3 { // stand-ins for the system items to the right
            x -= 16
            NSColor.white.withAlphaComponent(0.5).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: bar.midY - 3, width: 6, height: 6)).fill()
        }
        var label = NSAttributedString()
        if !word.isEmpty {
            label = NSAttributedString(string: " \(word)…", attributes: [
                .font: NSFont.menuFont(ofSize: 12),
                .foregroundColor: NSColor.white,
            ])
            x -= label.size().width
            label.draw(at: NSPoint(x: x, y: bar.midY - label.size().height / 2))
        }
        if let mark {
            x -= mark.size.width + 6
            draw(mark, at: NSPoint(x: x, y: bar.midY - mark.size.height / 2), tint: .white)
        }
    }

    /// The collapsed pill, centred under the notch — the resting state, which is
    /// what the island actually looks like most of the time. Same proportions the
    /// real one uses: clear of the menu bar, rounded all round, mark then text.
    private func drawIsland(in r: NSRect, barHeight: CGFloat) {
        let text = NSAttributedString(string: word.isEmpty ? "AgentBar" : "\(word)…", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ])
        let hPad: CGFloat = 12
        let markW = mark?.size.width ?? 0
        let w = markW + 8 + text.size().width + hPad * 2
        let h: CGFloat = 26
        let panel = NSRect(x: (r.midX - w / 2).rounded(),
                           y: r.maxY - barHeight - IslandGeometry.topGap - h,
                           width: w.rounded(), height: h)
        NSColor.black.withAlphaComponent(0.94).setFill()
        let path = NSBezierPath(roundedRect: panel, xRadius: 12, yRadius: 12)
        path.fill()
        NSColor.white.withAlphaComponent(0.10).setStroke()
        path.lineWidth = 1
        path.stroke()

        var x = panel.minX + hPad
        if let mark {
            draw(mark, at: NSPoint(x: x, y: panel.midY - mark.size.height / 2), tint: .white)
            x += markW + 8
        }
        text.draw(at: NSPoint(x: x, y: panel.midY - text.size().height / 2))
    }

    /// Template marks carry no colour of their own — paint them for the surface.
    /// The tint has to happen in an image context: filling `.sourceAtop` straight
    /// into the view would land on the opaque wallpaper and paint a solid block.
    private func draw(_ img: NSImage, at origin: NSPoint, tint: NSColor) {
        let painted = img.isTemplate ? IconRenderer.tint(img, with: tint) : img
        painted.draw(in: NSRect(origin: origin, size: img.size))
    }
}
