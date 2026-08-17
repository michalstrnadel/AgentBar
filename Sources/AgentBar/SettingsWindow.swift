import Carbon.HIToolbox
import Cocoa

/// AgentBar's Settings: one small window, three quiet sections — Sounds, the
/// global Allow/Deny shortcut, and the island. Every control writes UserDefaults
/// directly and fires `onChange`, so changes apply live; the app delegate owns
/// the fan-out to whichever surfaces care.
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    var onChange: (() -> Void)?

    private var window: NSWindow?
    private var enableBox: NSButton!
    private var allowRecorder: ShortcutRecorder!
    private var denyRecorder: ShortcutRecorder!
    private var soundsBox: NSButton!
    private var volumeSlider: NSSlider!
    private var testButton: NSButton!
    private var volumeRow: NSStackView!
    private var hideIslandBox: NSButton!

    func show() {
        if window == nil { build() }
        cancelCaptures() // a stale recorder must not swallow keys after re-show
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The menu quick-toggle flips the same defaults this window shows; a visible
    /// stale checkbox would look like the click didn't land.
    func refreshIfVisible() {
        guard window?.isVisible == true else { return }
        reload()
    }

    private func cancelCaptures() {
        allowRecorder.cancelCapture()
        denyRecorder.cancelCapture()
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "AgentBar Settings"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()

        // ---- Sounds ----
        soundsBox = NSButton(checkboxWithTitle: "Play sounds for agent events",
                             target: self, action: #selector(toggleSounds))
        let soundsCap = caption(
            "A soft cue when a session needs approval, asks a question,\nor finishes. Nothing plays while agents are working.")

        volumeSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1,
                                target: self, action: #selector(volumeChanged(_:)))
        volumeSlider.isContinuous = true
        volumeSlider.widthAnchor.constraint(equalToConstant: 168).isActive = true
        volumeSlider.setAccessibilityLabel("Sound volume")
        testButton = NSButton(title: "Test", target: self, action: #selector(testClicked))
        testButton.bezelStyle = .rounded
        volumeRow = NSStackView(views: [speakerGlyph("speaker.fill"), volumeSlider,
                                        speakerGlyph("speaker.wave.3.fill"), testButton])
        volumeRow.orientation = .horizontal
        volumeRow.alignment = .centerY
        volumeRow.spacing = 8
        volumeRow.setCustomSpacing(12, after: volumeRow.arrangedSubviews[2])

        // ---- Shortcuts ----
        enableBox = NSButton(checkboxWithTitle: "Global Allow / Deny shortcut",
                             target: self, action: #selector(toggleEnabled))
        let enableCaption = caption(
            "Answer the newest pending permission request from anywhere,\nwithout opening the menu. No Accessibility permission needed.")

        allowRecorder = ShortcutRecorder(defaultsKey: "allowHotKey", fallback: .defaultAllow)
        denyRecorder = ShortcutRecorder(defaultsKey: "denyHotKey", fallback: .defaultDeny)
        for recorder in [allowRecorder!, denyRecorder!] {
            recorder.onCaptureChange = { [weak self, weak recorder] capturing in
                guard let self else { return }
                if capturing {
                    // One recorder at a time, and while recording the current combo
                    // must reach the recorder, not the Carbon hotkey — suspend,
                    // then re-register on the way out.
                    let other = recorder === self.allowRecorder ? self.denyRecorder : self.allowRecorder
                    other?.cancelCapture()
                    HotKeyCenter.shared.suspend()
                } else {
                    self.onChange?()
                }
            }
            recorder.rejectCombo = { [weak self, weak recorder] combo in
                // The two actions may not share one combo.
                let other = recorder === self?.allowRecorder ? self?.denyRecorder : self?.allowRecorder
                return combo == other?.combo
            }
            recorder.onRecord = { [weak self] in self?.onChange?() }
        }

        let grid = NSGridView(views: [
            [gridLabel("Allow:"), allowRecorder!],
            [gridLabel("Deny:"), denyRecorder!],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing

        // ---- Island ----
        hideIslandBox = NSButton(checkboxWithTitle: "Hide island when no sessions",
                                 target: self, action: #selector(toggleHideIsland))
        let islandCaption = caption(
            "The pill slips away when nothing is running and returns with\nthe next session. Applies when the menu bar mark is shown too.")

        let sep1 = separator(), sep2 = separator()
        let stack = NSStackView(views: [
            sectionLabel("Sounds"), soundsBox, soundsCap, volumeRow, sep1,
            sectionLabel("Shortcuts"), enableBox, enableCaption, grid, sep2,
            sectionLabel("Island"), hideIslandBox, islandCaption,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(12, after: stack.arrangedSubviews[2]) // caption → volume row
        stack.setCustomSpacing(16, after: volumeRow)
        stack.setCustomSpacing(16, after: sep1)
        stack.setCustomSpacing(14, after: enableCaption)
        stack.setCustomSpacing(16, after: grid)
        stack.setCustomSpacing(16, after: sep2)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The grid indents to line up under the checkbox title, not its box.
        grid.translatesAutoresizingMaskIntoConstraints = false
        w.contentView = NSView()
        w.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: w.contentView!.topAnchor),
            stack.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 38),
            volumeRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 38),
            sep1.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            sep2.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        w.setContentSize(stack.fittingSize)
        window = w
    }

    private func reload() {
        enableBox.state = UserDefaults.standard.bool(forKey: "globalApprovalShortcut") ? .on : .off
        allowRecorder.reload()
        denyRecorder.reload()
        soundsBox.state = SoundCenter.enabled ? .on : .off
        volumeSlider.doubleValue = SoundCenter.volume
        hideIslandBox.state = UserDefaults.standard.bool(forKey: "hideIslandWhenEmpty") ? .on : .off
        syncRecorderState()
        syncSoundControls()
    }

    @objc private func toggleEnabled() {
        UserDefaults.standard.set(enableBox.state == .on, forKey: "globalApprovalShortcut")
        syncRecorderState()
        onChange?()
    }

    @objc private func toggleSounds() {
        SoundCenter.enabled = soundsBox.state == .on
        syncSoundControls()
        if SoundCenter.enabled { SoundCenter.shared.preview() }
        onChange?()
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        SoundCenter.volume = sender.doubleValue
        // Audition on release, not per tick — matches the system alert-volume slider.
        if NSApp.currentEvent?.type == .leftMouseUp { SoundCenter.shared.preview() }
    }

    @objc private func testClicked() {
        SoundCenter.shared.preview()
    }

    @objc private func toggleHideIsland() {
        UserDefaults.standard.set(hideIslandBox.state == .on, forKey: "hideIslandWhenEmpty")
        onChange?()
    }

    private func syncRecorderState() {
        let on = enableBox.state == .on
        allowRecorder.isEnabled = on
        denyRecorder.isEnabled = on
    }

    private func syncSoundControls() {
        let on = soundsBox.state == .on
        volumeSlider.isEnabled = on
        testButton.isEnabled = on
        volumeRow.alphaValue = on ? 1 : 0.5 // dims the glyphs too; NSImageView has no isEnabled
    }

    func windowWillClose(_ notification: Notification) {
        cancelCaptures()
    }

    /// Clicking away mid-recording: a background window can't see key events, so a
    /// still-armed recorder would leave the hotkeys suspended forever. End it now.
    func windowDidResignKey(_ notification: Notification) {
        cancelCaptures()
    }

    private func caption(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return l
    }

    private func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    private func speakerGlyph(_ symbol: String) -> NSImageView {
        let v = NSImageView()
        v.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        v.contentTintColor = .secondaryLabelColor
        return v
    }

    private func gridLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: NSFont.systemFontSize)
        return l
    }
}

/// A button that shows the current combo and, when clicked, records the next
/// keystroke as the new one. Esc cancels; a combo needs ⌘, ⌥ or ⌃ so a plain
/// letter typed anywhere can never become a global hotkey.
final class ShortcutRecorder: NSButton {
    private let defaultsKey: String
    private let fallback: KeyCombo
    private(set) var combo: KeyCombo
    var onRecord: (() -> Void)?
    var onCaptureChange: ((Bool) -> Void)?
    var rejectCombo: ((KeyCombo) -> Bool)?
    private var monitor: Any?

    init(defaultsKey: String, fallback: KeyCombo) {
        self.defaultsKey = defaultsKey
        self.fallback = fallback
        self.combo = KeyCombo.stored(defaultsKey, fallback: fallback)
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginCapture)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func reload() {
        combo = KeyCombo.stored(defaultsKey, fallback: fallback)
        title = combo.display
    }

    @objc private func beginCapture() {
        guard monitor == nil else { return }
        title = "Type shortcut… (esc cancels)"
        onCaptureChange?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil // swallow the keystroke while recording
        }
    }

    func cancelCapture() {
        // Only a live capture may end — a plain call must not re-fire
        // onCaptureChange(false) and needlessly re-register the hotkeys.
        if monitor != nil { endCapture() }
    }

    private func endCapture() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        title = combo.display
        onCaptureChange?(false)
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == UInt32(kVK_Escape) { endCapture(); return }
        let carbon = Self.carbonFlags(event.modifierFlags)
        guard carbon & UInt32(cmdKey | optionKey | controlKey) != 0 else {
            NSSound.beep()
            return // keep capturing until a real combo (or esc) arrives
        }
        let recorded = KeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: carbon,
                                display: Self.display(for: event))
        if rejectCombo?(recorded) == true {
            NSSound.beep()
            return
        }
        combo = recorded
        combo.store(as: defaultsKey)
        endCapture()
        onRecord?()
    }

    private static func carbonFlags(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var c: UInt32 = 0
        if flags.contains(.control) { c |= UInt32(controlKey) }
        if flags.contains(.option) { c |= UInt32(optionKey) }
        if flags.contains(.shift) { c |= UInt32(shiftKey) }
        if flags.contains(.command) { c |= UInt32(cmdKey) }
        return c
    }

    private static func display(for event: NSEvent) -> String {
        var s = ""
        let f = event.modifierFlags
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        return s + keyName(event)
    }

    private static func keyName(_ event: NSEvent) -> String {
        if let n = fKeyNumber(event.keyCode) { return "F\(n)" }
        switch Int(event.keyCode) {
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default:
            return event.charactersIgnoringModifiers?.uppercased() ?? "?"
        }
    }

    private static func fKeyNumber(_ code: UInt16) -> Int? {
        let map: [Int: Int] = [kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5, kVK_F6: 6,
                               kVK_F7: 7, kVK_F8: 8, kVK_F9: 9, kVK_F10: 10, kVK_F11: 11, kVK_F12: 12]
        return map[Int(code)]
    }
}
