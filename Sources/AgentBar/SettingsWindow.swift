import Carbon.HIToolbox
import Cocoa

/// AgentBar's one window: a small Settings panel (the app is otherwise menu bar
/// only). Currently hosts the global Allow/Deny shortcut — an enable toggle plus
/// recorders to rebind either combo. State lives in UserDefaults; after any change
/// the panel calls `onChange` so the controller re-registers the hotkeys.
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    var onChange: (() -> Void)?

    private var window: NSWindow?
    private var enableBox: NSButton!
    private var allowRecorder: ShortcutRecorder!
    private var denyRecorder: ShortcutRecorder!

    func show() {
        if window == nil { build() }
        cancelCaptures() // a stale recorder must not swallow keys after re-show
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
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

        let stack = NSStackView(views: [enableBox, enableCaption, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(14, after: enableCaption)
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
        ])
        w.setContentSize(stack.fittingSize)
        window = w
    }

    private func reload() {
        enableBox.state = UserDefaults.standard.bool(forKey: "globalApprovalShortcut") ? .on : .off
        allowRecorder.reload()
        denyRecorder.reload()
        syncRecorderState()
    }

    @objc private func toggleEnabled() {
        UserDefaults.standard.set(enableBox.state == .on, forKey: "globalApprovalShortcut")
        syncRecorderState()
        onChange?()
    }

    private func syncRecorderState() {
        let on = enableBox.state == .on
        allowRecorder.isEnabled = on
        denyRecorder.isEnabled = on
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
