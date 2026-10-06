import Cocoa

/// First-run window: says where AgentBar lives, lets the user pick the surface it
/// shows itself on, and names the agents whose hooks were wired. Shown on the
/// first launch, on later ones only if the user ticks the box, and from the menu.
final class WelcomeWindow: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindow()

    private static let showKey = "showWelcomeOnLaunch"
    private static let shownKey = "welcomeShownOnce"

    /// A fresh install gets it once. After that it is the person's choice: a
    /// window that took focus on every launch — including the silent relaunch an
    /// update waits for you to step away to make — is a window unfolding over the
    /// screen on its own, which rule 2 does not allow.
    static var showOnLaunch: Bool {
        get { UserDefaults.standard.object(forKey: showKey) as? Bool
                ?? !UserDefaults.standard.bool(forKey: shownKey) }
        set { UserDefaults.standard.set(newValue, forKey: showKey) }
    }

    static func markShownOnce() { UserDefaults.standard.set(true, forKey: shownKey) }

    /// An install that has run before has seen this window already. Called before
    /// anything this launch writes a preference, while an empty domain still means
    /// a copy that has never run here.
    static func seedForExistingInstall(domain: [String: Any]?) {
        guard let domain, !domain.isEmpty,
              UserDefaults.standard.object(forKey: shownKey) == nil else { return }
        markShownOnce()
    }

    private var window: NSWindow?
    private var preview: PresentationPreview!
    private var radios: [NSButton] = []
    private var colorRadios: [NSButton] = []
    private var displayRow: NSView!
    private var displayPicker: DisplayPicker!
    private var todayRow: NSView!
    private var todayTotalBox: NSButton!
    private var todayBarsBox: NSButton!
    private var todayCaption: NSTextField!
    private var displayCaption: NSTextField!
    private var modeCaption: NSTextField!
    private var wiredLabel: NSTextField!
    private var changesButton: NSButton!
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

        let stack = NSStackView(views: [header(), previewBox(), picker(), displayPickerRow(),
                                        todayStripRow(), colorPicker(), footer()])
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
    /// Which display the island lives on. Hidden unless it can matter — one
    /// display leaves nothing to choose, and in menu-bar mode there is no island
    /// to place. `reload()` shows and hides it as those change.
    private func displayPickerRow() -> NSView {
        let label = NSTextField(labelWithString: "Island on:")
        label.font = .systemFont(ofSize: 13, weight: .medium)

        displayPicker = DisplayPicker()
        displayPicker.availableWidth = Self.rowWidth
        displayPicker.onPick = { [weak self] in self?.reload() }

        displayCaption = NSTextField(wrappingLabelWithString: "")
        displayCaption.font = .systemFont(ofSize: 11)
        displayCaption.textColor = .secondaryLabelColor
        displayCaption.preferredMaxLayoutWidth = Self.rowWidth

        let col = NSStackView(views: [label, displayPicker, displayCaption])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 6
        col.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
        displayRow = col
        return col
    }

    /// The day's account along the bottom of the island. It lives here rather than
    /// in Settings because this is the window that decides what the island *looks
    /// like* — where it sits, which display, which marks — and this is one of those,
    /// not a behaviour.
    ///
    /// Two switches, not one, because the halves cost different things: the line is a
    /// row of small text that says what happened, the strip is taller and only pays
    /// for itself on a day spread across several sessions. Both off by default, and
    /// hidden entirely in menu-bar mode along with the display picker.
    private func todayStripRow() -> NSView {
        let label = NSTextField(labelWithString: "Today, along the bottom:")
        label.font = .systemFont(ofSize: 13, weight: .medium)

        todayTotalBox = NSButton(checkboxWithTitle: "The day's total",
                                 target: self, action: #selector(toggleTodayStrip))
        todayBarsBox = NSButton(checkboxWithTitle: "A bar per session",
                                target: self, action: #selector(toggleTodayStrip))
        todayCaption = NSTextField(wrappingLabelWithString: "")
        todayCaption.font = .systemFont(ofSize: 11)
        todayCaption.textColor = .secondaryLabelColor
        todayCaption.preferredMaxLayoutWidth = Self.rowWidth

        let boxes = NSStackView(views: [todayTotalBox, todayBarsBox])
        boxes.orientation = .horizontal
        boxes.spacing = 18

        let col = NSStackView(views: [label, boxes, todayCaption])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 6
        col.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
        todayRow = col
        return col
    }

    @objc private func toggleTodayStrip() {
        TodayStripView.showsTotal = todayTotalBox.state == .on
        TodayStripView.showsBars = todayBarsBox.state == .on
        reload()
    }

    /// Says what the current pair actually produces, rather than describing both and
    /// leaving the reader to work out which half they switched on.
    private func todayCaptionText() -> String {
        switch (TodayStripView.showsTotal, TodayStripView.showsBars) {
        case (true, true):
            return "\"12 sessions · 3h 40m · 4.1M tokens\", and under it a bar per "
                + "session — wider the longer it ran, red for what failed."
        case (true, false):
            return "One line: how many sessions finished, how long they took, what "
                + "they cost and what failed."
        case (false, true):
            return "A bar per session that finished today — wider the longer it ran, "
                + "red for what failed. Point at one for its numbers."
        case (false, false):
            return "The island stays as it is. Today's account is still under its ⋯, "
                + "and in the menu bar's Today row."
        }
    }

    private func colorPicker() -> NSView {
        let label = NSTextField(labelWithString: "Icon color:")
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        let row = NSStackView(views: [label])
        row.orientation = .horizontal
        row.spacing = 18
        for (i, title) in ["Colorful", "Monochrome"].enumerated() {
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

        // The install that just ran edited files of the user's. Saying which agents
        // it wired is half of being honest about that; the other half is one click
        // to the exact lines, and where the originals went.
        changesButton = SettingsChrome.smallButton("See what changed…", target: self,
                                                   action: #selector(showChanges))
        changesButton.isHidden = true

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

        let col = NSStackView(views: [wiredLabel, changesButton, showBox, buttons])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 10
        col.setCustomSpacing(6, after: wiredLabel)
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
        // Same rule as the display picker: no island, nothing to decorate.
        todayRow.isHidden = !mode.showsIsland
        todayTotalBox.state = TodayStripView.showsTotal ? .on : .off
        todayBarsBox.state = TodayStripView.showsBars ? .on : .off
        todayCaption.stringValue = todayCaptionText()
        reloadDisplayRow(mode: mode)
        refreshWired()
    }

    private func reloadDisplayRow(mode: Presentation) {
        displayRow.isHidden = !mode.showsIsland
        if mode.showsIsland {
            displayPicker.rebuild()
            if IslandScreen.pinnedDisplayMissing {
                displayCaption.stringValue = "The display you picked isn't connected — "
                    + "the island follows the pointer until it's back."
            } else if DisplayPicker.singleDisplay {
                displayCaption.stringValue = "One display, so there's nothing to choose "
                    + "yet — this is where you'll pin it once a second one is plugged in."
            } else if case .pinned = IslandScreen.choice {
                displayCaption.stringValue = "The island stays on this display, "
                    + "wherever the pointer goes."
            } else {
                displayCaption.stringValue = "The island appears on whichever display "
                    + "the pointer is on."
            }
        }
        // Re-fit whether the row appeared OR disappeared: skipping the hidden case
        // is what left an empty gap where the row had been.
        if let w = window, let content = w.contentView {
            w.setContentSize(NSSize(width: Self.contentWidth,
                                    height: content.fittingSize.height))
        }
    }

    /// The install pass runs off the main queue and usually finishes after this
    /// window is up, so the line fills in when it reports done.
    func refreshWired() {
        guard wiredLabel != nil else { return }
        let names = HookInstaller.wired.map { Agent.byID($0).name }
        wiredLabel.stringValue = names.isEmpty
            ? (HookInstaller.finished
                ? "No agents wired yet. Install Claude Code, Codex, Gemini CLI or another supported "
                  + "agent and relaunch AgentBar; Settings ▸ Diagnostics shows what it looked for."
                : "Setting up hooks…")
            : "Hooks wired up for: " + names.joined(separator: ", ")
                + ". New sessions show up from now on; ones already open started before the hooks."
        // Only once there is something to show: a machine where every file was
        // already wired has no diff, and a button that opens an empty sheet is noise.
        changesButton.isHidden = !FileManager.default.fileExists(atPath: ConfigBackup.defaultLog.path)
        // The line can grow after the window is up (the install pass reports late),
        // so the window re-fits rather than clipping it.
        if let w = window, let content = w.contentView {
            w.setContentSize(NSSize(width: Self.contentWidth, height: content.fittingSize.height))
        }
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

    @objc private func showChanges() {
        guard let window else { return }
        ConfigChangesSheet.present(on: window)
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

extension WelcomeWindow {
    /// The window as it looks in `mode`, drawn to an image without opening it and
    /// **without saving the choice** — the radios, preview and captions are set
    /// for the picture only, and `Presentation.current` is never written. What the
    /// demo generator (`Scripts/demo/feature-gifs.swift`) draws the appearance
    /// scene from; `radioFrames` says where each choice sits, so a pointer can land
    /// on it. Frames are in the image's own coordinates, bottom-left origin, points.
    /// `wired` stands in for what the installer reports: a process that never ran
    /// the install pass would otherwise draw "Setting up hooks…".
    func renderForVerification(mode: Presentation, mark: NSImage?, word: String,
                               wired: [String] = [])
        -> (image: NSBitmapImageRep, radioFrames: [NSRect])? {
        if window == nil { build() }
        reload()
        if !wired.isEmpty {
            wiredLabel.stringValue = "Hooks wired up for: "
                + wired.map { Agent.byID($0).name }.joined(separator: ", ")
                + ". New sessions show up from now on; ones already open started before the hooks."
        }
        for (i, b) in radios.enumerated() { b.state = Presentation.allCases[i] == mode ? .on : .off }
        preview.mode = mode
        if let mark { preview.set(image: mark, word: word) }
        modeCaption.stringValue = mode.caption
        todayRow.isHidden = !mode.showsIsland
        reloadDisplayRow(mode: mode)
        guard let root = window?.contentView?.superview ?? window?.contentView else { return nil }
        root.layoutSubtreeIfNeeded()
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return nil }
        root.cacheDisplay(in: root.bounds, to: rep)
        let frames = radios.map { b -> NSRect in
            var r = b.convert(b.bounds, to: root)
            if root.isFlipped { r.origin.y = root.bounds.height - r.maxY }
            return r
        }
        return (rep, frames)
    }
}
