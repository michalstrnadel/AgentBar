import Cocoa

/// Settings ▸ Keep Awake. One switch that says what it is doing, the mode it
/// starts, and — in a second card — what happens while it is on. Rows that would
/// only say "nothing to see" are hidden until they have something to say. When it
/// starts or pauses by itself lives on its own page (`KeepAwakeTriggersPage`).
/// `SettingsWindow` hosts it.
final class KeepAwakeSettingsPage: NSObject {
    /// Fired after a control wrote a preference.
    var onChange: (() -> Void)?

    private var onBox: NSSwitch!
    private let statusRow = NSTextField(labelWithString: "")
    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let untilPicker = NSDatePicker()
    private var untilRow: NSView!
    private var displayBox: NSSwitch!
    private var keyboardBox: NSSwitch!
    private var keyboardRow: NSView!
    private var lockBox: NSSwitch!
    private let lockPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var lockRow: NSView!
    private var nudgeBox: NSSwitch!
    private let header = SettingsChrome.header("")
    private var grantRow: NSView!
    private var lidBox: NSSwitch!
    private let lidStatus = SettingsChrome.caption("")
    private var restoreButton: NSButton!
    private var lidStatusRow: NSView!

    /// The page's cards, built once.
    private(set) lazy var views: [NSView] = build()

    private func build() -> [NSView] {
        onBox = SettingsChrome.toggle(target: self, action: #selector(toggleOn))
        statusRow.font = .systemFont(ofSize: 11.5)
        statusRow.textColor = .secondaryLabelColor
        statusRow.lineBreakMode = .byTruncatingTail

        modePopup.controlSize = .small
        for c in KeepAwakeChoice.allCases {
            modePopup.addItem(withTitle: c.title(untilMinutes: KeepAwakePrefs.untilMinutes()))
            modePopup.lastItem?.representedObject = c.rawValue
        }
        modePopup.target = self
        modePopup.action = #selector(modeChanged)

        untilPicker.datePickerElements = .hourMinute
        untilPicker.datePickerStyle = .textFieldAndStepper
        untilPicker.controlSize = .small
        untilPicker.target = self
        untilPicker.action = #selector(untilChanged)

        displayBox = SettingsChrome.toggle(target: self, action: #selector(toggleDisplay))
        keyboardBox = SettingsChrome.toggle(target: self, action: #selector(toggleKeyboard))
        keyboardRow = SettingsChrome.row("Keyboard light off while you're away",
                                         "Dark 30 seconds after your last keystroke, lit again at the next.",
                                         control: keyboardBox)
        lockBox = SettingsChrome.toggle(target: self, action: #selector(toggleLock))
        lockPopup.controlSize = .small
        for m in KeepAwakePrefs.lockChoices {
            lockPopup.addItem(withTitle: "After \(m) min")
            lockPopup.lastItem?.tag = m
        }
        lockPopup.target = self
        lockPopup.action = #selector(lockMinutesChanged)
        let lockControls = NSStackView(views: [lockPopup, lockBox])
        lockControls.spacing = SettingsChrome.Space.tight
        lockRow = SettingsChrome.row("Lock the screen when you leave",
                                     "Agents keep working; the locked screen may sleep.", control: lockControls)

        nudgeBox = SettingsChrome.toggle(target: self, action: #selector(toggleNudge))
        let grant = SettingsChrome.smallButton("Allow Accessibility…", target: self,
                                               action: #selector(grantAccessibility))
        lidBox = SettingsChrome.toggle(target: self, action: #selector(toggleLid))
        restoreButton = SettingsChrome.smallButton("Restore Sleep…", target: self, action: #selector(restoreLid))

        // The switch's row: the status line in place of a subtitle, so the answer
        // to "is it on, and why" sits right under the question.
        let title = NSTextField(labelWithString: "Keep this Mac awake")
        title.font = .systemFont(ofSize: 13.5, weight: .medium)
        let text = NSStackView(views: [title, statusRow])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        untilRow = SettingsChrome.row("Until", control: untilPicker)
        grantRow = SettingsChrome.customRow(line(SettingsChrome.caption(
            "Needs Accessibility — the permission keystroke approval uses."), grant))
        lidStatusRow = SettingsChrome.customRow(line(lidStatus, restoreButton))

        return [
            SettingsChrome.card([
                SettingsChrome.customRow(line(text, onBox), height: 56),
                SettingsChrome.row("Mode", control: modePopup),
                untilRow,
            ]),
            SettingsChrome.card([
                SettingsChrome.row("Keep the screen on",
                                   "Off: the screen dims and locks as usual; the Mac keeps working.",
                                   control: displayBox),
                keyboardRow,
                lockRow,
                SettingsChrome.row("Stay available in chat apps",
                                   "Keeps Teams and Slack from showing you Away.", control: nudgeBox),
                grantRow,
                SettingsChrome.row("Stay awake with the lid closed",
                                   "Asks for your password. Ends with Keep Awake, after 12 hours, "
                                   + "or if the Mac runs hot.", control: lidBox),
                lidStatusRow,
            ]),
            header,
        ]
    }

    private func line(_ label: NSView, _ control: NSView) -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, spacer, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        return row
    }

    /// Hides a row of a card and the hairline above it, so a hidden row leaves no
    /// double line behind.
    private func show(_ row: NSView, _ visible: Bool) {
        row.isHidden = !visible
        guard let stack = row.superview as? NSStackView,
              let i = stack.arrangedSubviews.firstIndex(of: row), i > 0 else { return }
        stack.arrangedSubviews[i - 1].isHidden = !visible
    }

    /// Re-reads everything; called whenever the window is shown or refreshed.
    func reload() {
        _ = views
        let k = KeepAwake.shared
        onBox.state = k.isOn ? .on : .off
        statusRow.stringValue = k.isOn ? k.decision.reason : "Off — the Mac sleeps as usual."

        let untilMinutes = KeepAwakePrefs.untilMinutes()
        for (i, c) in KeepAwakeChoice.allCases.enumerated() {
            modePopup.item(at: i)?.title = c.title(untilMinutes: untilMinutes)
        }
        let shown = k.currentChoice ?? KeepAwakePrefs.lastChoice()
        modePopup.selectItem(at: KeepAwakeChoice.allCases.firstIndex(of: shown) ?? 0)
        show(untilRow, shown == .untilTime)
        var c = DateComponents()
        c.hour = untilMinutes / 60
        c.minute = untilMinutes % 60
        untilPicker.dateValue = Calendar.current.date(from: c) ?? Date()

        header.stringValue = "Quickest: the cup in the island's footer; right-click it for every mode"
            + (KeepAwakePrefs.shortcut() ? ", or press \(KeyCombo.awake.display) anywhere." : ".")
        let s = KeepAwakePrefs.settings()
        displayBox.state = s.keepDisplayOn ? .on : .off
        keyboardBox.state = KeepAwakePrefs.keyboardDark() ? .on : .off
        // An iMac or a Mac mini has no backlit keyboard to turn off.
        show(keyboardRow, KeyboardLight.isAvailable)
        lockBox.state = s.lockWhenAway ? .on : .off
        lockPopup.selectItem(withTag: Int(s.lockAfter / 60))
        lockPopup.isEnabled = s.lockWhenAway
        show(lockRow, ScreenLock.shared.canLock)
        nudgeBox.state = s.nudge ? .on : .off
        show(grantRow, s.nudge && !KeystrokeApprover.trusted)

        let lid = LidSleep.shared
        lidBox.state = KeepAwakePrefs.lid() || lid.isOn ? .on : .off
        var note = ""
        if lid.hasLeftover {
            note = "Sleep is still disabled from an earlier session."
        } else if lid.isStarting {
            note = "Waiting for your password…"
        } else if lid.isOn {
            note = "On — a closed Mac stays awake until the mode ends."
        } else if !lid.lastError.isEmpty {
            note = "Not started: \(lid.lastError)."
        }
        lidStatus.stringValue = note
        restoreButton.isHidden = !lid.hasLeftover
        show(lidStatusRow, !note.isEmpty)
    }

    // MARK: - Actions

    @objc private func toggleOn() {
        if onBox.state == .on { KeepAwake.shared.start(KeepAwakePrefs.lastChoice()) } else { KeepAwake.shared.stop() }
        reload()
    }

    /// Picking a mode starts it if Keep Awake is on, and only makes it the one the
    /// switch starts if it is off — a pop-up is not a place to switch things on.
    @objc private func modeChanged() {
        guard let raw = modePopup.selectedItem?.representedObject as? String,
              let c = KeepAwakeChoice(rawValue: raw) else { return }
        if KeepAwake.shared.isOn { KeepAwake.shared.start(c) } else { KeepAwakePrefs.setLastChoice(c) }
        reload()
        onChange?()
    }

    @objc private func untilChanged() {
        let c = Calendar.current.dateComponents([.hour, .minute], from: untilPicker.dateValue)
        KeepAwakePrefs.setUntilMinutes((c.hour ?? 18) * 60 + (c.minute ?? 0))
        // A running "until" mode keeps the deadline it was started with: changing the
        // default should not quietly move a promise already made.
        reload()
        onChange?()
    }

    @objc private func toggleDisplay() {
        KeepAwake.shared.setKeepDisplayOn(displayBox.state == .on)
        changed()
    }

    @objc private func toggleKeyboard() {
        KeepAwakePrefs.setKeyboardDark(keyboardBox.state == .on)
        changed()
    }

    @objc private func toggleLock() {
        KeepAwakePrefs.setLockWhenAway(lockBox.state == .on)
        changed()
    }

    @objc private func lockMinutesChanged() {
        KeepAwakePrefs.setLockMinutes(lockPopup.selectedTag())
        changed()
    }



    @objc private func toggleNudge() {
        KeepAwakePrefs.setNudge(nudgeBox.state == .on)
        if nudgeBox.state == .on, !KeystrokeApprover.trusted { KeystrokeApprover.requestAccess() }
        changed()
    }

    @objc private func grantAccessibility() {
        KeystrokeApprover.requestAccess()
    }

    @objc private func toggleLid() {
        KeepAwake.shared.setLid(lidBox.state == .on)
        reload()
        onChange?()
    }

    @objc private func restoreLid() {
        LidSleep.shared.restoreLeftover { [weak self] _ in self?.reload() }
    }

    private func changed() {
        KeepAwake.shared.settingsChanged()
        reload()
        onChange?()
    }
}
