import Cocoa
import UniformTypeIdentifiers

/// Settings ▸ Awake Triggers: when Keep Mac Awake starts by itself, and when it
/// pauses or stops by itself. Every trigger is off until switched on here — the one place a
/// trigger can come from (CLAUDE.md rule 2). `SettingsWindow` hosts it.
final class KeepAwakeTriggersPage: NSObject {
    /// Fired after a control wrote a preference.
    var onChange: (() -> Void)?

    private var agentsBox: NSSwitch!
    private var chargerBox: NSSwitch!
    private var displayBox: NSSwitch!
    private let appList = NSStackView()
    private var batteryBox: NSSwitch!
    private let floorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var lowPowerBox: NSSwitch!
    private var sleepBox: NSSwitch!

    private(set) lazy var views: [NSView] = build()

    private func build() -> [NSView] {
        agentsBox = SettingsChrome.toggle(target: self, action: #selector(triggersChanged))
        chargerBox = SettingsChrome.toggle(target: self, action: #selector(triggersChanged))
        displayBox = SettingsChrome.toggle(target: self, action: #selector(triggersChanged))
        appList.orientation = .vertical
        appList.alignment = .leading
        appList.spacing = SettingsChrome.Space.tight

        batteryBox = SettingsChrome.toggle(target: self, action: #selector(toggleBattery))
        floorPopup.controlSize = .small
        for p in KeepAwakePrefs.floorChoices {
            floorPopup.addItem(withTitle: p >= KeepAwakePolicy.anyBattery ? "Always" : "Below \(p)%")
            floorPopup.lastItem?.tag = p
        }
        floorPopup.target = self
        floorPopup.action = #selector(floorChanged)
        let batteryControls = NSStackView(views: [floorPopup, batteryBox])
        batteryControls.spacing = SettingsChrome.Space.tight
        lowPowerBox = SettingsChrome.toggle(target: self, action: #selector(toggleLowPower))
        sleepBox = SettingsChrome.toggle(target: self, action: #selector(toggleSleepWhenDone))

        let appsTitle = NSTextField(labelWithString: "While these apps run")
        appsTitle.font = .systemFont(ofSize: 13.5)
        let add = SettingsChrome.smallButton("Add App…", target: self, action: #selector(addApp))
        let apps = NSStackView(views: [line(appsTitle, add), appList])
        apps.orientation = .vertical
        apps.alignment = .leading
        apps.spacing = SettingsChrome.Space.tight
        apps.arrangedSubviews.first?.widthAnchor.constraint(equalTo: apps.widthAnchor).isActive = true

        return [
            SettingsChrome.header("Start by itself. Turning the cup off snoozes a trigger until it goes away."),
            SettingsChrome.card([
                SettingsChrome.row("When an agent starts working",
                                   "Awake while one works, asleep five minutes after.", control: agentsBox),
                SettingsChrome.row("While plugged in", control: chargerBox),
                SettingsChrome.row("While an external display is connected", control: displayBox),
                SettingsChrome.customRow(apps),
            ]),
            SettingsChrome.header("Pause or stop by itself."),
            SettingsChrome.card([
                SettingsChrome.row("Pause on battery", "Plugging in picks it up again.",
                                   control: batteryControls),
                SettingsChrome.row("Pause in Low Power Mode", control: lowPowerBox),
                SettingsChrome.row("Sleep when the agents are done",
                                   "Once they finish and you've been away five minutes.", control: sleepBox),
            ]),
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

    func reload() {
        _ = views
        let t = KeepAwakePrefs.triggers()
        agentsBox.state = t.agents ? .on : .off
        chargerBox.state = t.charger ? .on : .off
        displayBox.state = t.display ? .on : .off
        appList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        appList.isHidden = t.apps.isEmpty
        for id in t.apps {
            appList.addArrangedSubview(appRow(id))
        }

        let s = KeepAwakePrefs.settings()
        batteryBox.state = s.batteryGuard ? .on : .off
        floorPopup.selectItem(withTag: s.batteryFloor)
        floorPopup.isEnabled = s.batteryGuard
        lowPowerBox.state = s.pauseInLowPower ? .on : .off
        sleepBox.state = s.sleepWhenDone ? .on : .off
    }

    private func appRow(_ bundleID: String) -> NSView {
        let icon = NSImageView()
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            icon.image = NSWorkspace.shared.icon(forFile: url.path)
        }
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let name = NSTextField(labelWithString: KeepAwakeTriggerWatch.appName(bundleID))
        name.font = .systemFont(ofSize: 12.5)
        let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove")!,
                              target: self, action: #selector(removeApp(_:)))
        remove.isBordered = false
        remove.identifier = NSUserInterfaceItemIdentifier(bundleID)
        remove.setAccessibilityLabel("Remove \(name.stringValue)")
        let row = NSStackView(views: [icon, name, remove])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = SettingsChrome.Space.tight
        return row
    }

    // MARK: - Actions

    @objc private func triggersChanged() {
        var t = KeepAwakePrefs.triggers()
        t.agents = agentsBox.state == .on
        t.charger = chargerBox.state == .on
        t.display = displayBox.state == .on
        save(t)
    }

    @objc private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Keep the Mac awake while these apps are running."
        guard panel.runModal() == .OK else { return }
        var t = KeepAwakePrefs.triggers()
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !t.apps.contains(id) { t.apps.append(id) }
        }
        save(t)
    }

    @objc private func removeApp(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        var t = KeepAwakePrefs.triggers()
        t.apps.removeAll { $0 == id }
        save(t)
    }

    private func save(_ t: KeepAwakeTriggerSettings) {
        KeepAwakePrefs.setTriggers(t)
        changed()
    }

    @objc private func toggleBattery() {
        KeepAwakePrefs.setBatteryGuard(batteryBox.state == .on)
        changed()
    }

    @objc private func floorChanged() {
        KeepAwakePrefs.setBatteryFloor(floorPopup.selectedTag())
        changed()
    }

    @objc private func toggleSleepWhenDone() {
        KeepAwakePrefs.setSleepWhenDone(sleepBox.state == .on)
        changed()
    }

    @objc private func toggleLowPower() {
        KeepAwakePrefs.setPauseInLowPower(lowPowerBox.state == .on)
        changed()
    }

    private func changed() {
        KeepAwake.shared.settingsChanged()
        reload()
        onChange?()
    }
}
